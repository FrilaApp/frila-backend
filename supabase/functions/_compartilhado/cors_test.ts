import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";
import {
  CABECALHOS_PERMITIDOS,
  comCors,
  lerOrigensPermitidas,
  METODOS_PERMITIDOS,
  VARIAVEL_ORIGENS_CORS,
} from "./cors.ts";

const PAGINA = "https://painel.exemplo.test";
const OUTRA = "https://outra.exemplo.test";
const LISTA = `${PAGINA}, ${OUTRA}`;

function requisicao(metodo: string, origem?: string, extras: Record<string, string> = {}): Request {
  const headers: Record<string, string> = { ...extras };
  if (origem !== undefined) headers["Origin"] = origem;
  return new Request("http://localhost/functions/v1/qualquer", { method: metodo, headers });
}

// Interno que explode se for chamado: prova que o preflight não chega ao handler.
function internoProibido(): Promise<Response> {
  throw new Error("o preflight não pode chegar ao handler");
}

function internoOk(): Promise<Response> {
  return Promise.resolve(
    new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
    }),
  );
}

Deno.test("cors: a variável de ambiente tem nome estável e documentado", () => {
  assertEquals(VARIAVEL_ORIGENS_CORS, "CORS_ORIGENS_PERMITIDAS");
});

// ── lerOrigensPermitidas ──────────────────────────────────────────────────────

Deno.test("cors: lista ausente, vazia ou só de espaços não aceita nenhuma origem", () => {
  assertEquals(lerOrigensPermitidas(undefined), []);
  assertEquals(lerOrigensPermitidas(""), []);
  assertEquals(lerOrigensPermitidas("   "), []);
  assertEquals(lerOrigensPermitidas(" , ,"), []);
});

Deno.test("cors: lista separada por vírgula é aparada e normalizada para a origem", () => {
  assertEquals(lerOrigensPermitidas(` ${PAGINA} ,${OUTRA}/ `), [PAGINA, OUTRA]);
  assertEquals(lerOrigensPermitidas("HTTPS://Painel.Exemplo.test"), [PAGINA]);
});

Deno.test("cors: asterisco, null, esquema não-http e lixo são descartados, nunca viram permissão", () => {
  const avisos: string[] = [];
  const original = console.warn;
  console.warn = (m: string) => avisos.push(m);
  try {
    assertEquals(lerOrigensPermitidas("*"), []);
    assertEquals(lerOrigensPermitidas(`*, ${PAGINA}`), [PAGINA]);
    assertEquals(lerOrigensPermitidas("null"), []);
    assertEquals(lerOrigensPermitidas("file:///tmp/x.html, ftp://x.test, javascript:alert(1)"), []);
    assertEquals(lerOrigensPermitidas("isto-nao-e-url"), []);
    assertEquals(lerOrigensPermitidas("https://*.exemplo.test"), []);
  } finally {
    console.warn = original;
  }
  assert(avisos.length >= 6, "entrada inválida deve deixar rastro no log, não sumir em silêncio");
  for (const a of avisos) {
    assert(!a.includes("exemplo.test") && !a.includes("alert"), "o aviso não ecoa o valor configurado");
  }
});

// ── Preflight ─────────────────────────────────────────────────────────────────

Deno.test("cors: preflight de origem na lista devolve 204 com ACAO igual à origem e Vary: Origin", async () => {
  const res = await comCors(
    requisicao("OPTIONS", PAGINA, {
      "Access-Control-Request-Method": "POST",
      "Access-Control-Request-Headers": "authorization, content-type",
    }),
    LISTA,
    internoProibido,
  );
  assertEquals(res.status, 204);
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), PAGINA);
  assertEquals(res.headers.get("Access-Control-Allow-Methods"), METODOS_PERMITIDOS);
  assertEquals(res.headers.get("Access-Control-Allow-Headers"), CABECALHOS_PERMITIDOS);
  assertEquals(res.headers.get("Vary"), "Origin");
  assertEquals(await res.text(), "");
});

Deno.test("cors: a segunda origem da lista recebe a si mesma, não a primeira", async () => {
  const res = await comCors(requisicao("OPTIONS", OUTRA), LISTA, internoProibido);
  assertEquals(res.status, 204);
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), OUTRA);
});

Deno.test("cors: métodos e cabeçalhos permitidos são o mínimo, sem curinga", () => {
  assertEquals(METODOS_PERMITIDOS, "POST, OPTIONS");
  assertEquals(CABECALHOS_PERMITIDOS, "authorization, content-type, apikey, x-client-info");
  assert(!METODOS_PERMITIDOS.includes("*"));
  assert(!CABECALHOS_PERMITIDOS.includes("*"));
});

Deno.test("cors: preflight de origem fora da lista não concede ACAO e segue para o handler (405 atual)", async () => {
  let chamou = false;
  const res = await comCors(requisicao("OPTIONS", "https://site-malicioso.test"), LISTA, () => {
    chamou = true;
    return Promise.resolve(new Response("{}", { status: 405 }));
  });
  assertEquals(chamou, true);
  assertEquals(res.status, 405);
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), null);
  assertEquals(res.headers.get("Access-Control-Allow-Methods"), null);
  assertEquals(res.headers.get("Access-Control-Allow-Headers"), null);
  assertEquals(res.headers.get("Vary"), "Origin", "o cache não pode servir a variante sem ACAO a quem está na lista");
});

Deno.test("cors: origem que apenas contém ou prefixa uma permitida não casa", async () => {
  for (
    const origem of [
      `${PAGINA}.atacante.test`,
      "https://atacante.test/" + PAGINA,
      "https://x" + PAGINA.slice("https://".length),
      "http://painel.exemplo.test",
      `${PAGINA}:8443`,
      PAGINA.toUpperCase(),
    ]
  ) {
    const res = await comCors(requisicao("OPTIONS", origem), LISTA, () => Promise.resolve(new Response(null, { status: 405 })));
    assertEquals(res.headers.get("Access-Control-Allow-Origin"), null, origem);
  }
});

Deno.test("cors: lista vazia ou ausente preserva o comportamento atual, sem nenhum cabeçalho CORS e sem Vary", async () => {
  for (const lista of [undefined, "", "  ", "*"]) {
    const res = await comCors(requisicao("OPTIONS", PAGINA), lista, () =>
      Promise.resolve(new Response("{}", { status: 405 })));
    assertEquals(res.status, 405);
    for (const [nome] of res.headers) {
      assert(!nome.toLowerCase().startsWith("access-control-"), `${nome} não deveria existir`);
    }
    assertEquals(res.headers.get("Vary"), null);
  }
});

Deno.test("cors: sem a variável injetada, a lista vem do ambiente da função", async () => {
  const anterior = Deno.env.get(VARIAVEL_ORIGENS_CORS);
  try {
    Deno.env.set(VARIAVEL_ORIGENS_CORS, PAGINA);
    const res = await comCors(requisicao("OPTIONS", PAGINA), undefined, internoProibido);
    assertEquals(res.status, 204);
    assertEquals(res.headers.get("Access-Control-Allow-Origin"), PAGINA);

    Deno.env.delete(VARIAVEL_ORIGENS_CORS);
    const semVariavel = await comCors(requisicao("OPTIONS", PAGINA), undefined, () =>
      Promise.resolve(new Response("{}", { status: 405 })));
    assertEquals(semVariavel.headers.get("Access-Control-Allow-Origin"), null);
  } finally {
    if (anterior === undefined) Deno.env.delete(VARIAVEL_ORIGENS_CORS);
    else Deno.env.set(VARIAVEL_ORIGENS_CORS, anterior);
  }
});

// ── Resposta real ─────────────────────────────────────────────────────────────

Deno.test("cors: resposta real a origem na lista leva ACAO igual à origem e Vary, e preserva o resto", async () => {
  const res = await comCors(requisicao("POST", PAGINA), LISTA, internoOk);
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), PAGINA);
  assertEquals(res.headers.get("Vary"), "Origin");
  assertEquals(res.headers.get("Cache-Control"), "no-store");
  assertEquals(res.headers.get("Content-Type"), "application/json");
  assertEquals(await res.json(), { ok: true });
});

Deno.test("cors: resposta real não concede credenciais nem curinga", async () => {
  const res = await comCors(requisicao("POST", PAGINA), LISTA, internoOk);
  assertEquals(res.headers.get("Access-Control-Allow-Credentials"), null);
  assert(res.headers.get("Access-Control-Allow-Origin") !== "*");
  const pre = await comCors(requisicao("OPTIONS", PAGINA), LISTA, internoProibido);
  assertEquals(pre.headers.get("Access-Control-Allow-Credentials"), null);
  assert(pre.headers.get("Access-Control-Allow-Origin") !== "*");
});

Deno.test("cors: resposta real a origem fora da lista não leva ACAO, mas leva Vary", async () => {
  const res = await comCors(requisicao("POST", "https://site-malicioso.test"), LISTA, internoOk);
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), null);
  assertEquals(res.headers.get("Vary"), "Origin");
});

Deno.test("cors: requisição sem Origin (app nativo, curl) passa sem ACAO", async () => {
  const res = await comCors(requisicao("POST"), LISTA, internoOk);
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), null);
});

Deno.test("cors: Vary que o handler já definiu é preservado e Origin é acrescentado sem duplicar", async () => {
  const comVary = () =>
    Promise.resolve(new Response("{}", { status: 200, headers: { Vary: "Accept-Encoding" } }));
  const res = await comCors(requisicao("POST", PAGINA), LISTA, comVary);
  const vary = res.headers.get("Vary") ?? "";
  assertStringIncludes(vary, "Accept-Encoding");
  assertStringIncludes(vary, "Origin");

  const jaTem = () =>
    Promise.resolve(new Response("{}", { status: 200, headers: { Vary: "origin" } }));
  const res2 = await comCors(requisicao("POST", PAGINA), LISTA, jaTem);
  assertEquals(res2.headers.get("Vary")?.toLowerCase(), "origin");
});

Deno.test("cors: resposta 204 sem corpo e erros do handler também levam os cabeçalhos", async () => {
  const semCorpo = await comCors(requisicao("POST", PAGINA), LISTA, () =>
    Promise.resolve(new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } })));
  assertEquals(semCorpo.status, 204);
  assertEquals(semCorpo.headers.get("Access-Control-Allow-Origin"), PAGINA);

  const erro = await comCors(requisicao("POST", PAGINA), LISTA, () =>
    Promise.resolve(new Response('{"code":"nao_autenticado"}', { status: 401 })));
  assertEquals(erro.status, 401);
  assertEquals(erro.headers.get("Access-Control-Allow-Origin"), PAGINA, "o navegador só mostra o 401 se houver ACAO");
});

Deno.test("cors: exceção do handler não é engolida", async () => {
  let capturada: unknown;
  try {
    await comCors(requisicao("POST", PAGINA), LISTA, () => Promise.reject(new Error("falha de configuração")));
  } catch (e) {
    capturada = e;
  }
  assert(capturada instanceof Error);
  assertEquals((capturada as Error).message, "falha de configuração");
});
