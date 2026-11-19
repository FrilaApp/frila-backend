// CORS com allowlist de origens para as Edge Functions que a web chama.
//
// A lista vem da variável `CORS_ORIGENS_PERMITIDAS` da função: origens separadas por
// vírgula, no formato que o navegador manda em `Origin` (esquema, host e porta, sem caminho).
// Nenhuma origem mora no código.
//
// Variável ausente ou vazia significa nenhuma origem aceita: a função se comporta como se
// este módulo não existisse, sem `Access-Control-Allow-Origin` e sem `Vary`. O mesmo vale
// para uma entrada que não é origem válida (curinga, `null`, esquema que não é http/https):
// ela é descartada e deixa um aviso no log, sem o valor configurado.
//
// A origem recebida só é ecoada em `Access-Control-Allow-Origin` quando é igual, byte a
// byte, a uma entrada da lista. Nunca se devolve `*`, e `Access-Control-Allow-Credentials`
// nunca é enviado: a autenticação das funções vai no cabeçalho `Authorization`, não em cookie.

export const VARIAVEL_ORIGENS_CORS = "CORS_ORIGENS_PERMITIDAS";

export const METODOS_PERMITIDOS = "POST, OPTIONS";

// `apikey` e `x-client-info` são os cabeçalhos que o supabase-js envia ao invocar uma função.
export const CABECALHOS_PERMITIDOS = "authorization, content-type, apikey, x-client-info";

// Quanto tempo o navegador pode reaproveitar o preflight, em segundos.
const PREFLIGHT_MAX_AGE = "600";

/**
 * Converte o valor bruto da variável na lista de origens aceitas. Entrada inválida é
 * descartada com um aviso que não repete o valor.
 */
export function lerOrigensPermitidas(bruto: string | undefined): string[] {
  const origens: string[] = [];
  for (const parte of (bruto ?? "").split(",")) {
    const entrada = parte.trim();
    if (!entrada) continue;
    const origem = normalizarOrigem(entrada);
    if (origem === null) {
      console.warn(`cors: entrada inválida em ${VARIAVEL_ORIGENS_CORS} descartada`);
      continue;
    }
    if (!origens.includes(origem)) origens.push(origem);
  }
  return origens;
}

function normalizarOrigem(entrada: string): string | null {
  if (entrada.includes("*")) return null;
  let url: URL;
  try {
    url = new URL(entrada);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  return url.origin;
}

/**
 * Aplica CORS a um handler. Preflight de origem na lista é respondido aqui (204), sem
 * tocar no handler, no Auth nem no banco. Todo o resto passa pelo handler, e a resposta
 * dele leva os cabeçalhos quando a origem está na lista.
 *
 * `origensBrutas` existe para o teste injetar a lista; em produção vem do ambiente.
 * Exceção do handler não é capturada aqui.
 */
export async function comCors(
  req: Request,
  origensBrutas: string | undefined,
  tratar: () => Promise<Response>,
): Promise<Response> {
  const origens = lerOrigensPermitidas(origensBrutas ?? Deno.env.get(VARIAVEL_ORIGENS_CORS));
  if (origens.length === 0) return await tratar();

  const origem = req.headers.get("Origin");
  const permitida = origem !== null && origens.includes(origem);

  if (permitida && req.method === "OPTIONS") {
    const headers = new Headers({
      "Access-Control-Allow-Origin": origem,
      "Access-Control-Allow-Methods": METODOS_PERMITIDOS,
      "Access-Control-Allow-Headers": CABECALHOS_PERMITIDOS,
      "Access-Control-Max-Age": PREFLIGHT_MAX_AGE,
      "Vary": "Origin",
    });
    return new Response(null, { status: 204, headers });
  }

  const res = await tratar();
  const headers = new Headers(res.headers);
  if (permitida) headers.set("Access-Control-Allow-Origin", origem);
  acrescentarVaryOrigin(headers);
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
}

function acrescentarVaryOrigin(headers: Headers): void {
  const atual = headers.get("Vary");
  if (atual === null) {
    headers.set("Vary", "Origin");
    return;
  }
  const itens = atual.split(",").map((i) => i.trim().toLowerCase());
  if (itens.includes("origin") || itens.includes("*")) return;
  headers.set("Vary", `${atual}, Origin`);
}
