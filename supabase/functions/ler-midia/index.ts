// Edge Function `ler-midia`: abre a foto de perfil por um link temporário (B-020, contrato 0.2.82).
//
// As leituras (`perfil_publico`, `candidatos_da_vaga`, `detalhe_chamada`, `minhas_midias`) conferem
// o vínculo e devolvem `foto_url`/`url` = esta função com `midia_id` e um token opaco de 1 h (o
// banco guarda só o SHA-256). O app abre a URL com `AsyncImage`, sem cabeçalho de sessão.
//
// A ordem:
//   1. Método GET, formato do id e do token. Formato ruim é 404, igual a token errado.
//   2. `privado.resolver_link_leitura_midia` RECONFERE tudo na hora: hash e validade, foto
//      aprovada, titular ativo, recurso ligado, bloqueio e vínculo. Devolve o caminho da
//      miniatura, ou nulo. Toda recusa é o mesmo 404: quem adivinha não aprende nada.
//   3. Storage com a credencial de serviço, que só existe no ambiente desta função:
//      `POST /object/sign/...` (createSignedUrl) por 60 s, e 302 para a URL assinada. Bucket e
//      caminho vêm do banco, nunca do pedido. Nenhum segredo no Postgres.
//
// verify_jwt desligado (config.toml): a imagem chega sem sessão por desenho; quem autoriza é o
// token. Nada de token, URL assinada ou caminho em log: só o evento, o status e o midia_id.

import postgres from "npm:postgres@3.4.4";

export const BUCKET = "midia-perfil";
export const VALIDADE_STORAGE_S = 60;
const TIMEOUT_REDE_MS = 10_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TOKEN = /^[0-9a-f]{64}$/;
const CAMINHO = /^perfil\/[0-9a-f-]{36}_thumb\.jpg$/;

export interface HandlerDeps {
  /** Resolve o link e devolve o caminho da miniatura, ou null. Padrão: SQL em SUPABASE_DB_URL. */
  resolverLink?: (midiaId: string, token: string) => Promise<string | null>;
  fetchFn?: typeof fetch;
  supabaseUrl?: string;
  serviceRoleKey?: string;
  dbUrl?: string;
  registrar?: (evento: Record<string, unknown>) => void;
}

const CABECALHOS_BASE = {
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

  // createSignedUrl: o Storage assina com a chave dele.
  let assinada: string;
  try {
    const r = await fetchFn(`${supabaseUrl}/storage/v1/object/sign/${BUCKET}/${caminhoCodificado(caminho)}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${serviceRoleKey}`,
        apikey: serviceRoleKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ expiresIn: VALIDADE_STORAGE_S }),
      signal: AbortSignal.timeout(TIMEOUT_REDE_MS),
    });
    if (!r.ok) {
      await r.body?.cancel().catch(() => {});
      registrar({ evento: "ler_midia_storage_falhou", status: r.status, midia_id: midiaId });
      return resposta(502, "storage_indisponivel");
    }
    const json = await r.json() as { signedURL?: string };
    if (!json.signedURL || !json.signedURL.startsWith(`/object/sign/${BUCKET}/`)) {
      registrar({ evento: "ler_midia_storage_falhou", status: r.status, midia_id: midiaId });
      return resposta(502, "storage_indisponivel");
    }
    assinada = `${supabaseUrl}/storage/v1${json.signedURL}`;
  } catch (_err) {
    registrar({ evento: "ler_midia_storage_falhou", status: 0, midia_id: midiaId });
    return resposta(502, "storage_indisponivel");
  }

  registrar({ evento: "ler_midia_redirecionada", midia_id: midiaId });
  return new Response(null, { status: 302, headers: { ...CABECALHOS_BASE, Location: assinada } });
}

if (import.meta.main) {
  Deno.serve((req: Request) => handler(req));
}
