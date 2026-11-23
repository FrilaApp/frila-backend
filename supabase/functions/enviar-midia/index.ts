// Edge Function `enviar-midia`: recebe o JPEG da foto de perfil e o grava no bucket privado
// `midia-perfil` (contrato 0.2.63).
//
// `solicitar_upload_midia` reserva a mídia em `enviando`, escolhe o caminho no servidor e
// devolve `upload_url` = esta função com `midia_id` e um token opaco de uso único (o banco
// guarda só o SHA-256). O app faz `PUT` com o JPEG, `Content-Type: image/jpeg`, sem o token
// da sessão; 2xx quer dizer gravado. Qualquer outra resposta é falha e não grava nada.
//
// A ordem importa:
//   1. Método, formato do token, Content-Type, tamanho (cabeçalho e leitura limitada a 5 MB) e
//      assinatura JPEG. Corpo ruim não gasta o token.
//   2. `privado.consumir_token_upload`: consome o token num UPDATE atômico e devolve o caminho
//      reservado. Dois PUT simultâneos com o mesmo token: só um recebe o caminho.
//   3. Storage com a credencial de serviço, que só existe no ambiente desta função:
//      `POST /object/upload/sign/...` (createSignedUploadUrl) e `PUT` na URL assinada
//      (uploadToSignedUrl), sempre com `x-upsert: false`. Bucket e caminho vêm do banco, nunca
//      do pedido.
//
// verify_jwt desligado (config.toml): o envio chega sem sessão por desenho; quem autoriza é o
// token. Nada de token, URL ou corpo em log: só o nome do evento e o status.

import postgres from "npm:postgres@3.4.4";

export const BUCKET = "midia-perfil";
export const LIMITE_BYTES = 5_242_880;
const TIMEOUT_REDE_MS = 15_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TOKEN = /^[0-9a-f]{64}$/;

export interface HandlerDeps {
  /** Consome o token e devolve o caminho reservado, ou null. Padrão: SQL em SUPABASE_DB_URL. */
  consumirToken?: (midiaId: string, token: string) => Promise<string | null>;
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

function caminhoCodificado(caminho: string): string {
  return caminho.split("/").map(encodeURIComponent).join("/");
}

function consumirPadrao(deps?: HandlerDeps) {
  return async (midiaId: string, token: string): Promise<string | null> => {
    const sql = postgres(obterVariavel("SUPABASE_DB_URL", deps?.dbUrl), { max: 1, connect_timeout: 5 });
    try {
      const [linha] = await sql`select privado.consumir_token_upload(${midiaId}::uuid, ${token}) as caminho`;
      return linha?.caminho ? String(linha.caminho) : null;
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
  const midiaId = (url.searchParams.get("midia_id") ?? "").toLowerCase();
  const token = url.searchParams.get("token") ?? "";
  if (!UUID.test(midiaId) || !TOKEN.test(token)) {
    await req.body?.cancel().catch(() => {});
    registrar({ evento: "enviar_midia_recusado", motivo: "token_invalido" });
    return resposta(401, "token_invalido");
  }

  const tipo = (req.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (tipo !== "image/jpeg") {
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
  if (!ehJpeg(corpo)) return resposta(415, "formato");

  let caminho: string | null;
  try {
    caminho = await (deps?.consumirToken ?? consumirPadrao(deps))(midiaId, token);
  } catch (_err) {
    registrar({ evento: "enviar_midia_banco_indisponivel" });
    return resposta(503, "indisponivel");
  }
  if (!caminho) {
    registrar({ evento: "enviar_midia_recusado", motivo: "token_invalido", midia_id: midiaId });
    return resposta(401, "token_invalido");
  }

  let supabaseUrl: string;
  let serviceRoleKey: string;
  try {
    supabaseUrl = obterVariavel("SUPABASE_URL", deps?.supabaseUrl).replace(/\/+$/, "");
    serviceRoleKey = obterVariavel("SUPABASE_SERVICE_ROLE_KEY", deps?.serviceRoleKey);
  } catch (_err) {
    registrar({ evento: "enviar_midia_configuracao_ausente" });
    return resposta(500, "configuracao");
  }
  const fetchFn = deps?.fetchFn ?? fetch;
  const servico = { Authorization: `Bearer ${serviceRoleKey}`, apikey: serviceRoleKey };

  // createSignedUploadUrl: o Storage assina com a chave dele; nada de segredo JWT no banco.
  let assinada: string;
  try {
    const r = await fetchFn(`${supabaseUrl}/storage/v1/object/upload/sign/${BUCKET}/${caminhoCodificado(caminho)}`, {
      method: "POST",
      headers: { ...servico, "x-upsert": "false" },
      signal: AbortSignal.timeout(TIMEOUT_REDE_MS),
    });
    if (!r.ok) {
      await r.body?.cancel().catch(() => {});
      registrar({ evento: "enviar_midia_storage_falhou", etapa: "assinar", status: r.status, midia_id: midiaId });
      return resposta(502, "storage_indisponivel");
    }
    const json = await r.json() as { url?: string };
    if (!json.url || !json.url.startsWith(`/object/upload/sign/${BUCKET}/`)) {
      registrar({ evento: "enviar_midia_storage_falhou", etapa: "assinar", status: r.status, midia_id: midiaId });
      return resposta(502, "storage_indisponivel");
    }
    assinada = `${supabaseUrl}/storage/v1${json.url}`;
  } catch (_err) {
    registrar({ evento: "enviar_midia_storage_falhou", etapa: "assinar", status: 0, midia_id: midiaId });
    return resposta(502, "storage_indisponivel");
  }

  // uploadToSignedUrl: grava no caminho reservado, sem sobrescrever.
  try {
    const r = await fetchFn(assinada, {
      method: "PUT",
      headers: { "Content-Type": "image/jpeg", "x-upsert": "false" },
      body: corpo as unknown as BodyInit,
      signal: AbortSignal.timeout(TIMEOUT_REDE_MS),
    });
    await r.body?.cancel().catch(() => {});
    if (!r.ok) {
      registrar({ evento: "enviar_midia_storage_falhou", etapa: "gravar", status: r.status, midia_id: midiaId });
      return resposta(502, "storage_indisponivel");
    }
  } catch (_err) {
    registrar({ evento: "enviar_midia_storage_falhou", etapa: "gravar", status: 0, midia_id: midiaId });
    return resposta(502, "storage_indisponivel");
  }

  registrar({ evento: "enviar_midia_gravada", midia_id: midiaId, bytes: corpo.byteLength });
  return resposta(200);
}

if (import.meta.main) {
  Deno.serve((req: Request) => handler(req));
}
