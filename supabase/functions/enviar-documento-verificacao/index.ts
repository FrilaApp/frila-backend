// Edge Function `enviar-documento-verificacao`: recebe uma parte da evidência da verificação de
// identidade (RN14: frente, verso ou selfie) e a grava no bucket privado que o banco indicar.
//
// O token opaco de uso único e o `upload_id` vêm da URL de upload; o banco guarda só o SHA-256 do
// token (`privado.upload_verificacao_identidade`). O app faz `PUT` com a imagem e o `Content-Type`
// dela, sem o token da sessão; 2xx quer dizer gravado. Qualquer outra resposta é falha e não grava
// nada. Falha depois de o token ser consumido exige pedir novas URLs.
//
// Nenhuma RPC pública devolve a URL desta função ainda: ela fica sem tráfego até a troca da RPC.
//
// A ordem importa:
//   1. Método, formato do token, Content-Type do bucket (JPEG, PNG ou HEIC), tamanho (cabeçalho e
//      leitura limitada a 5 MiB) e assinatura real dos bytes, que tem de bater com o Content-Type
//      declarado. Corpo ruim não gasta o token.
//   2. `privado.consumir_token_upload_verificacao`: consome o token num UPDATE atômico e devolve
//      bucket e caminho. Dois PUT simultâneos com o mesmo token: só um recebe o destino.
//   3. Storage com a credencial de serviço, que só existe no ambiente desta função:
//      `POST /object/upload/sign/...` (createSignedUploadUrl) e `PUT` na URL assinada
//      (uploadToSignedUrl), sempre com `x-upsert: false`. Bucket e caminho vêm do banco, nunca
//      do pedido.
//
// verify_jwt desligado (config.toml): o envio chega sem sessão por desenho; quem autoriza é o
// token. Nada de token, URL, caminho, corpo ou chave em log: só o nome do evento e o status.

import postgres from "npm:postgres@3.4.4";

export const LIMITE_BYTES = 5_242_880;
const TIMEOUT_REDE_MS = 15_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TOKEN = /^[0-9a-f]{64}$/;
const BUCKET_VALIDO = /^[a-z0-9][a-z0-9_-]{0,62}$/;
const TIPOS = new Set(["image/jpeg", "image/png", "image/heic"]);

// Marcas ISO-BMFF que identificam HEIC. `mif1` (e `msf1`) é só a família HEIF genérica, que o AVIF
// também usa: vale apenas se uma marca compatível for HEIC.
const MARCAS_HEIC = new Set(["heic", "heix", "heim", "heis", "hevc", "hevx"]);
const MARCAS_GENERICAS = new Set(["mif1", "msf1"]);
const FTYP_MAXIMO = 256;

export interface Destino {
  bucket: string;
  storage_path: string;
  parte: string;
}

export interface HandlerDeps {
  /** Consome o token e devolve o destino reservado, ou null. Padrão: SQL em SUPABASE_DB_URL. */
  consumirToken?: (uploadId: string, token: string) => Promise<Destino | null>;
  fetchFn?: typeof fetch;
  supabaseUrl?: string;
  serviceRoleKey?: string;
  dbUrl?: string;
  registrar?: (evento: Record<string, unknown>) => void;
}

function resposta(status: number, erro?: string): Response {
  return new Response(JSON.stringify(erro ? { ok: false, erro } : { ok: true }), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function obterVariavel(nome: string, injetada?: string): string {
  const valor = (injetada ?? Deno.env.get(nome))?.trim();
  if (!valor) throw new Error(`${nome} é obrigatório e deve estar configurado no ambiente.`);
  return valor;
}

function registrarPadrao(evento: Record<string, unknown>) {
  console.log(JSON.stringify(evento));
}

/** Lê o corpo até LIMITE_BYTES; acima disso para de ler e devolve null. */
async function lerCorpoLimitado(req: Request): Promise<Uint8Array | null> {
  if (!req.body) return new Uint8Array(0);
  const leitor = req.body.getReader();
  const partes: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await leitor.read();
    if (done) break;
    total += value.byteLength;
    if (total > LIMITE_BYTES) {
      await leitor.cancel().catch(() => {});
      return null;
    }
    partes.push(value);
  }
  const corpo = new Uint8Array(total);
  let pos = 0;
  for (const p of partes) {
    corpo.set(p, pos);
    pos += p.byteLength;
  }
  return corpo;
}

function ehJpeg(corpo: Uint8Array): boolean {
  return corpo.byteLength >= 3 && corpo[0] === 0xff && corpo[1] === 0xd8 && corpo[2] === 0xff;
}

const ASSINATURA_PNG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

function ehPng(corpo: Uint8Array): boolean {
  return corpo.byteLength > ASSINATURA_PNG.length && ASSINATURA_PNG.every((b, i) => corpo[i] === b);
}

function texto4(corpo: Uint8Array, inicio: number): string {
  return String.fromCharCode(corpo[inicio], corpo[inicio + 1], corpo[inicio + 2], corpo[inicio + 3]);
}

/** HEIC: caixa `ftyp` íntegra no começo, com marca principal HEIC ou HEIF genérica + compatível HEIC. */
function ehHeic(corpo: Uint8Array): boolean {
  if (corpo.byteLength < 16) return false;
  const tamanho = ((corpo[0] << 24) | (corpo[1] << 16) | (corpo[2] << 8) | corpo[3]) >>> 0;
  if (texto4(corpo, 4) !== "ftyp") return false;
  if (tamanho < 16 || tamanho > FTYP_MAXIMO || tamanho > corpo.byteLength || tamanho % 4 !== 0) return false;
  const principal = texto4(corpo, 8);
  if (MARCAS_HEIC.has(principal)) return true;
  if (!MARCAS_GENERICAS.has(principal)) return false;
  for (let i = 16; i + 4 <= tamanho; i += 4) {
    if (MARCAS_HEIC.has(texto4(corpo, i))) return true;
  }
  return false;
}

function bateComOTipo(tipo: string, corpo: Uint8Array): boolean {
  if (tipo === "image/jpeg") return ehJpeg(corpo);
  if (tipo === "image/png") return ehPng(corpo);
  return ehHeic(corpo);
}

/** O destino vem do banco, mas a função confere a forma antes de montar uma URL com ele. */
function destinoValido(destino: unknown): destino is Destino {
  if (!destino || typeof destino !== "object") return false;
  const { bucket, storage_path: caminho } = destino as Record<string, unknown>;
  if (typeof bucket !== "string" || !BUCKET_VALIDO.test(bucket)) return false;
  if (typeof caminho !== "string" || caminho === "" || caminho.length > 1024) return false;
  return caminho.split("/").every((s) => s !== "" && s !== "." && s !== "..");
}

function caminhoCodificado(caminho: string): string {
  return caminho.split("/").map(encodeURIComponent).join("/");
}

function consumirPadrao(deps?: HandlerDeps) {
  return async (uploadId: string, token: string): Promise<Destino | null> => {
    const sql = postgres(obterVariavel("SUPABASE_DB_URL", deps?.dbUrl), { max: 1, connect_timeout: 5 });
    try {
      const [linha] = await sql`select privado.consumir_token_upload_verificacao(${uploadId}::uuid, ${token}) as destino`;
      return linha?.destino ? linha.destino as Destino : null;
    } finally {
      await sql.end({ timeout: 2 });
    }
  };
}

export async function handler(req: Request, deps?: HandlerDeps): Promise<Response> {
  const registrar = deps?.registrar ?? registrarPadrao;

  if (req.method !== "PUT") {
    await req.body?.cancel().catch(() => {});
    return resposta(405, "metodo_nao_permitido");
  }

  const url = new URL(req.url);
  const uploadId = (url.searchParams.get("upload_id") ?? "").toLowerCase();
  const token = url.searchParams.get("token") ?? "";
  if (!UUID.test(uploadId) || !TOKEN.test(token)) {
    await req.body?.cancel().catch(() => {});
    registrar({ evento: "enviar_documento_recusado", motivo: "token_invalido" });
    return resposta(401, "token_invalido");
  }

  const tipo = (req.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (!TIPOS.has(tipo)) {
    await req.body?.cancel().catch(() => {});
    return resposta(415, "formato");
  }

  const declarado = Number(req.headers.get("content-length") ?? "");
  if (Number.isFinite(declarado) && declarado > LIMITE_BYTES) {
    await req.body?.cancel().catch(() => {});
    return resposta(413, "tamanho");
  }

  let corpo: Uint8Array | null;
  try {
    corpo = await lerCorpoLimitado(req);
  } catch (_err) {
    return resposta(400, "corpo_ilegivel");
  }
  if (corpo === null) return resposta(413, "tamanho");
  if (corpo.byteLength === 0) return resposta(400, "corpo_vazio");
  if (!bateComOTipo(tipo, corpo)) return resposta(415, "formato");

  let destino: Destino | null;
  try {
    destino = await (deps?.consumirToken ?? consumirPadrao(deps))(uploadId, token);
  } catch (_err) {
    registrar({ evento: "enviar_documento_banco_indisponivel" });
    return resposta(503, "indisponivel");
  }
  if (!destino) {
    registrar({ evento: "enviar_documento_recusado", motivo: "token_invalido", upload_id: uploadId });
    return resposta(401, "token_invalido");
  }
  if (!destinoValido(destino)) {
    registrar({ evento: "enviar_documento_destino_invalido", upload_id: uploadId });
    return resposta(500, "destino_invalido");
  }
  const { bucket, storage_path: caminho } = destino;

  let supabaseUrl: string;
  let serviceRoleKey: string;
  try {
    supabaseUrl = obterVariavel("SUPABASE_URL", deps?.supabaseUrl).replace(/\/+$/, "");
    serviceRoleKey = obterVariavel("SUPABASE_SERVICE_ROLE_KEY", deps?.serviceRoleKey);
  } catch (_err) {
    registrar({ evento: "enviar_documento_configuracao_ausente" });
    return resposta(500, "configuracao");
  }
  const fetchFn = deps?.fetchFn ?? fetch;
  const servico = { Authorization: `Bearer ${serviceRoleKey}`, apikey: serviceRoleKey };

  // createSignedUploadUrl: o Storage assina com a chave dele; nada de segredo JWT no banco.
  let assinada: string;
  try {
    const r = await fetchFn(`${supabaseUrl}/storage/v1/object/upload/sign/${bucket}/${caminhoCodificado(caminho)}`, {
      method: "POST",
      headers: { ...servico, "x-upsert": "false" },
      signal: AbortSignal.timeout(TIMEOUT_REDE_MS),
    });
    if (!r.ok) {
      await r.body?.cancel().catch(() => {});
      registrar({ evento: "enviar_documento_storage_falhou", etapa: "assinar", status: r.status, upload_id: uploadId });
      return resposta(502, "storage_indisponivel");
    }
    const json = await r.json() as { url?: string };
    if (!json.url || !json.url.startsWith(`/object/upload/sign/${bucket}/`)) {
      registrar({ evento: "enviar_documento_storage_falhou", etapa: "assinar", status: r.status, upload_id: uploadId });
      return resposta(502, "storage_indisponivel");
    }
    assinada = `${supabaseUrl}/storage/v1${json.url}`;
  } catch (_err) {
    registrar({ evento: "enviar_documento_storage_falhou", etapa: "assinar", status: 0, upload_id: uploadId });
    return resposta(502, "storage_indisponivel");
  }

  // uploadToSignedUrl: grava no caminho reservado, sem sobrescrever.
  try {
    const r = await fetchFn(assinada, {
      method: "PUT",
      headers: { "Content-Type": tipo, "x-upsert": "false" },
      body: corpo as unknown as BodyInit,
      signal: AbortSignal.timeout(TIMEOUT_REDE_MS),
    });
    await r.body?.cancel().catch(() => {});
    if (!r.ok) {
      registrar({ evento: "enviar_documento_storage_falhou", etapa: "gravar", status: r.status, upload_id: uploadId });
      return resposta(502, "storage_indisponivel");
    }
  } catch (_err) {
    registrar({ evento: "enviar_documento_storage_falhou", etapa: "gravar", status: 0, upload_id: uploadId });
    return resposta(502, "storage_indisponivel");
  }

  registrar({ evento: "enviar_documento_gravado", upload_id: uploadId, bytes: corpo.byteLength });
  return resposta(200);
}

if (import.meta.main) {
  Deno.serve((req: Request) => handler(req));
}
