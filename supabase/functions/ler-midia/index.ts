// Edge Function `ler-midia`: serve a foto de perfil por um link temporário (B-020, contrato 0.2.82).
//
// As leituras (`perfil_publico`, `candidatos_da_vaga`, `detalhe_chamada`, `minhas_midias`) conferem
// o vínculo e devolvem `foto_url`/`url` = esta função com `midia_id` e um token opaco de 1 h (o
// banco guarda só o SHA-256). O app abre a URL com `AsyncImage`, sem cabeçalho de sessão.
//
// A ordem:
//   1. Método GET, formato do id e do token. Formato ruim é 404, igual a token errado.
//   2. `privado.resolver_link_leitura_midia` RECONFERE tudo na hora e conta o uso: hash preso à
//      mídia, validade, teto de 120 usos, leitor ativo, foto aprovada, titular ativo, recurso
//      ligado, casa atual, bloqueio e vínculo. Devolve o caminho da miniatura, ou nulo. Toda
//      recusa é o mesmo 404: quem adivinha não aprende nada.
//   3. Baixa a miniatura do Storage com a credencial de serviço (só no ambiente desta função) e
//      SERVE OS BYTES (`image/jpeg`). Sem redirecionamento: nem o caminho nem um link assinado
//      saem, e a CDN não entra (parecer do Lince Codex, B-020). Bucket e caminho vêm do banco.
//
// Toda resposta, de sucesso ou de erro, vai com `Cache-Control: private, no-store`.
// verify_jwt desligado (config.toml): a imagem chega sem sessão por desenho; quem autoriza é o
// token. Nada de token ou caminho em log: só o evento, o status e o midia_id.

import postgres from "npm:postgres@3.4.4";

export const BUCKET = "midia-perfil";
/** A miniatura tem 320 px (moderar-midia); acima disto algo está errado e nada é servido. */
export const LIMITE_BYTES = 2_097_152;
const TIMEOUT_REDE_MS = 10_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TOKEN = /^[0-9a-f]{64}$/;
const CAMINHO = /^perfil\/[0-9a-f-]{36}_thumb\.jpg$/;

export interface HandlerDeps {
  /** Resolve o link (e conta o uso); devolve o caminho da miniatura, ou null. Padrão: SQL em SUPABASE_DB_URL. */
  resolverLink?: (midiaId: string, token: string) => Promise<string | null>;
  fetchFn?: typeof fetch;
  supabaseUrl?: string;
  serviceRoleKey?: string;
  dbUrl?: string;
  registrar?: (evento: Record<string, unknown>) => void;
}

export const CABECALHOS_BASE = {
  "Cache-Control": "private, no-store",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};

function resposta(status: number, erro: string): Response {
  return new Response(JSON.stringify({ ok: false, erro }), {
    status,
    headers: { ...CABECALHOS_BASE, "Content-Type": "application/json" },
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

function caminhoCodificado(caminho: string): string {
  return caminho.split("/").map(encodeURIComponent).join("/");
}

/** Lê o corpo até LIMITE_BYTES; acima disso para de ler e devolve null. */
async function lerCorpoLimitado(r: Response): Promise<Uint8Array | null> {
  if (!r.body) return new Uint8Array(0);
  const leitor = r.body.getReader();
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

/** O resolvedor real, por SQL; exportado para o teste de integração com Postgres. */
export function resolverPadrao(deps?: HandlerDeps) {
  return async (midiaId: string, token: string): Promise<string | null> => {
    const sql = postgres(obterVariavel("SUPABASE_DB_URL", deps?.dbUrl), { max: 1, connect_timeout: 5 });
    try {
      const [linha] = await sql`select privado.resolver_link_leitura_midia(${midiaId}::uuid, ${token}) as caminho`;
      return linha?.caminho ? String(linha.caminho) : null;
    } finally {
      await sql.end({ timeout: 2 });
    }
  };
}

export async function handler(req: Request, deps?: HandlerDeps): Promise<Response> {
  const registrar = deps?.registrar ?? registrarPadrao;

  if (req.method !== "GET") {
    await req.body?.cancel().catch(() => {});
    return resposta(405, "metodo_nao_permitido");
  }

  const url = new URL(req.url);
  const midiaId = (url.searchParams.get("midia_id") ?? "").toLowerCase();
  const token = url.searchParams.get("token") ?? "";
  if (!UUID.test(midiaId) || !TOKEN.test(token)) {
    registrar({ evento: "ler_midia_recusado", motivo: "formato" });
    return resposta(404, "nao_encontrado");
  }

  let caminho: string | null;
  try {
    caminho = await (deps?.resolverLink ?? resolverPadrao(deps))(midiaId, token);
  } catch (_err) {
    registrar({ evento: "ler_midia_banco_indisponivel" });
    return resposta(503, "indisponivel");
  }
  // O caminho vem do banco; mesmo assim, só a miniatura da pasta `perfil/` sai daqui (RN15).
  if (!caminho || !CAMINHO.test(caminho)) {
    registrar({ evento: "ler_midia_recusado", motivo: "link_invalido", midia_id: midiaId });
    return resposta(404, "nao_encontrado");
  }

  let supabaseUrl: string;
  let serviceRoleKey: string;
  try {
    supabaseUrl = obterVariavel("SUPABASE_URL", deps?.supabaseUrl).replace(/\/+$/, "");
    serviceRoleKey = obterVariavel("SUPABASE_SERVICE_ROLE_KEY", deps?.serviceRoleKey);
  } catch (_err) {
    registrar({ evento: "ler_midia_configuracao_ausente" });
    return resposta(500, "configuracao");
  }
  const fetchFn = deps?.fetchFn ?? fetch;

  let corpo: Uint8Array | null;
  try {
    const r = await fetchFn(`${supabaseUrl}/storage/v1/object/authenticated/${BUCKET}/${caminhoCodificado(caminho)}`, {
      method: "GET",
      headers: { Authorization: `Bearer ${serviceRoleKey}`, apikey: serviceRoleKey },
      signal: AbortSignal.timeout(TIMEOUT_REDE_MS),
    });
    if (!r.ok) {
      await r.body?.cancel().catch(() => {});
      registrar({ evento: "ler_midia_storage_falhou", status: r.status, midia_id: midiaId });
      // Arquivo que sumiu do Storage é o mesmo 404 de qualquer recusa.
      return r.status === 400 || r.status === 404 ? resposta(404, "nao_encontrado") : resposta(502, "storage_indisponivel");
    }
    const declarado = Number(r.headers.get("content-length") ?? "");
    if (Number.isFinite(declarado) && declarado > LIMITE_BYTES) {
      await r.body?.cancel().catch(() => {});
      registrar({ evento: "ler_midia_storage_falhou", status: r.status, motivo: "tamanho", midia_id: midiaId });
      return resposta(502, "storage_indisponivel");
    }
    corpo = await lerCorpoLimitado(r);
  } catch (_err) {
    registrar({ evento: "ler_midia_storage_falhou", status: 0, midia_id: midiaId });
    return resposta(502, "storage_indisponivel");
  }
  if (corpo === null || !ehJpeg(corpo)) {
    registrar({ evento: "ler_midia_storage_falhou", motivo: corpo === null ? "tamanho" : "formato", midia_id: midiaId });
    return resposta(502, "storage_indisponivel");
  }

  registrar({ evento: "ler_midia_servida", midia_id: midiaId, bytes: corpo.byteLength });
  return new Response(corpo as unknown as BodyInit, {
    status: 200,
    headers: {
      ...CABECALHOS_BASE,
      "Content-Type": "image/jpeg",
      "Content-Length": String(corpo.byteLength),
    },
  });
}

if (import.meta.main) {
  Deno.serve((req: Request) => handler(req));
}
