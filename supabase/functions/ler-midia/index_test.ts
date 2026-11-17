// Testes da ler-midia (B-020, contrato 0.2.82). Tudo por injeção: nem rede nem banco. Quem pode ver
// a foto de quem se prova no banco (pgTAP 858) e com Postgres real (integracao_pg_test.ts); aqui se
// prova que a função só serve o que o banco resolveu, sempre a miniatura, como bytes (nunca um
// redirecionamento), com `private, no-store` em TODA resposta, e que toda recusa é o mesmo 404, sem
// token nem caminho no log.
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { handler, HandlerDeps, LIMITE_BYTES } from "./index.ts";

const MIDIA = "85800000-0000-4000-8000-0000000000a1";
const TOKEN = "c".repeat(64);
const MINIATURA = `perfil/${MIDIA}_thumb.jpg`;
const BASE = "https://projeto.supabase.test";
const CHAVE = "chave-de-servico-sintetica";
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);

interface Mundo {
  chamadas: Array<{ url: string; method: string; headers: Record<string, string> }>;
  eventos: Array<Record<string, unknown>>;
  resolvidos: Array<[string, string]>;
}

function mundo(): Mundo {
  return { chamadas: [], eventos: [], resolvidos: [] };
}

/** Banco falso: só o par (MIDIA, TOKEN) resolve. */
function resolvedor(m: Mundo, caminho: string | null = MINIATURA) {
  return async (midiaId: string, token: string) => {
    await Promise.resolve();
    m.resolvidos.push([midiaId, token]);
    if (caminho === null || midiaId !== MIDIA || token !== TOKEN) return null;
    return caminho;
  };
}

function storageFalso(m: Mundo, opcoes: { status?: number; corpo?: Uint8Array; tamanho?: string } = {}): typeof fetch {
  return (async (entrada: RequestInfo | URL, init?: RequestInit) => {
    const url = String(entrada);
    const headers = Object.fromEntries(new Headers(init?.headers).entries());
    m.chamadas.push({ url, method: init?.method ?? "GET", headers });
    const h: Record<string, string> = { "Content-Type": "image/jpeg" };
    if (opcoes.tamanho) h["Content-Length"] = opcoes.tamanho;
    return new Response((opcoes.corpo ?? JPEG) as unknown as BodyInit, { status: opcoes.status ?? 200, headers: h });
  }) as typeof fetch;
}

function deps(m: Mundo, extra: Partial<HandlerDeps> = {}): HandlerDeps {
  return {
    resolverLink: resolvedor(m),
    fetchFn: storageFalso(m),
    supabaseUrl: BASE,
    serviceRoleKey: CHAVE,
    registrar: (e) => m.eventos.push(e),
    ...extra,
  };
}

function pedido(opcoes: { metodo?: string; midia?: string; token?: string } = {}) {
  const url = `${BASE}/functions/v1/ler-midia?midia_id=${opcoes.midia ?? MIDIA}&token=${opcoes.token ?? TOKEN}`;
  return new Request(url, { method: opcoes.metodo ?? "GET" });
}

function semSegredoNoLog(m: Mundo) {
  const log = JSON.stringify(m.eventos);
  assert(!log.includes(TOKEN), "o token não vai ao log");
  assert(!log.includes("d".repeat(64)), "o token adivinhado não vai ao log");
  assert(!log.includes(MINIATURA), "o caminho no Storage não vai ao log");
  assert(!log.includes(CHAVE), "a chave de serviço não vai ao log");
}

function semCache(r: Response, contexto: string) {
  assertEquals(r.headers.get("cache-control"), "private, no-store", contexto);
  assertEquals(r.headers.get("location"), null, `${contexto}: nunca redireciona`);
}

Deno.test("ler-midia: link válido serve os bytes da miniatura, image/jpeg, private no-store, sem redirecionar", async () => {
  const m = mundo();
  const r = await handler(pedido(), deps(m));
  assertEquals(r.status, 200);
  semCache(r, "200");
  assertEquals(r.headers.get("content-type"), "image/jpeg");
  assertEquals(r.headers.get("x-content-type-options"), "nosniff");
  assertEquals(r.headers.get("referrer-policy"), "no-referrer");
  assertEquals(new Uint8Array(await r.arrayBuffer()), JPEG);
  assertEquals(m.resolvidos, [[MIDIA, TOKEN]]);
  assertEquals(m.chamadas.length, 1);
  assertEquals(m.chamadas[0].method, "GET");
  assertEquals(m.chamadas[0].url, `${BASE}/storage/v1/object/authenticated/midia-perfil/${MINIATURA}`);
  assertEquals(m.chamadas[0].headers["authorization"], `Bearer ${CHAVE}`);
  semSegredoNoLog(m);
});

Deno.test("ler-midia: o id vem do link em maiúsculas e é normalizado antes do banco", async () => {
  const m = mundo();
  const r = await handler(pedido({ midia: MIDIA.toUpperCase() }), deps(m));
  assertEquals(r.status, 200);
  assertEquals(m.resolvidos, [[MIDIA, TOKEN]]);
});

Deno.test("ler-midia: só GET; outro método é 405, no-store, e não toca no banco nem no Storage", async () => {
  for (const metodo of ["POST", "PUT", "DELETE"]) {
    const m = mundo();
    const r = await handler(pedido({ metodo }), deps(m));
    assertEquals(r.status, 405, metodo);
    semCache(r, metodo);
    assertEquals(m.resolvidos.length, 0);
    assertEquals(m.chamadas.length, 0);
  }
});

Deno.test("ler-midia: id ou token malformado é o 404 único, no-store, sem ir ao banco", async () => {
  for (const [midia, token] of [["nao-e-uuid", TOKEN], [MIDIA, "curto"], [MIDIA, "C".repeat(64)], [MIDIA, ""]]) {
    const m = mundo();
    const r = await handler(pedido({ midia, token }), deps(m));
    assertEquals(r.status, 404, `${midia} ${token}`);
    semCache(r, "404 formato");
    assertEquals(await r.json(), { ok: false, erro: "nao_encontrado" });
    assertEquals(m.resolvidos.length, 0);
    assertEquals(m.chamadas.length, 0);
  }
});

Deno.test("ler-midia: o banco recusa (token adivinhado, token de outra mídia, sem vínculo, vencido) → o MESMO 404 e o Storage não é chamado", async () => {
  const respostas: string[] = [];
  const casos: Array<[string, Partial<HandlerDeps>, { midia?: string; token?: string }]> = [
    ["token adivinhado", {}, { token: "d".repeat(64) }],
    ["token válido com o id de outra mídia", {}, { midia: "85800000-0000-4000-8000-0000000000b1" }],
    ["banco devolve nulo (sem vínculo, vencido, removida, teto)", { resolverLink: resolvedor(mundo(), null) }, {}],
  ];
  for (const [nome, extra, p] of casos) {
    const m = mundo();
    const r = await handler(pedido(p), deps(m, extra));
    assertEquals(r.status, 404, nome);
    semCache(r, nome);
    respostas.push(await r.text());
    assertEquals(m.chamadas.length, 0, nome);
    semSegredoNoLog(m);
  }
  assertEquals(new Set(respostas).size, 1, "as recusas são indistinguíveis pelo corpo");
});

Deno.test("ler-midia: caminho do banco que não é a miniatura de perfil/ é recusado (o original nunca sai)", async () => {
  for (const caminho of [`perfil/${MIDIA}.jpg`, `outra/${MIDIA}_thumb.jpg`, `perfil/../x_thumb.jpg`]) {
    const m = mundo();
    const r = await handler(pedido(), deps(m, { resolverLink: resolvedor(m, caminho) }));
    assertEquals(r.status, 404, caminho);
    assertEquals(m.chamadas.length, 0, caminho);
  }
});

Deno.test("ler-midia: banco fora do ar é 503 no-store", async () => {
  const m = mundo();
  const r = await handler(pedido(), deps(m, { resolverLink: () => Promise.reject(new Error("fora")) }));
  assertEquals(r.status, 503);
  semCache(r, "503");
  assertEquals(m.chamadas.length, 0);
});

Deno.test("ler-midia: arquivo ausente no Storage é o mesmo 404; Storage com erro, grande demais ou não JPEG é 502; tudo no-store", async () => {
  const casos: Array<[string, Parameters<typeof storageFalso>[1], number]> = [
    ["arquivo ausente (404)", { status: 404 }, 404],
    ["arquivo ausente (400)", { status: 400 }, 404],
    ["Storage 500", { status: 500 }, 502],
    ["tamanho declarado acima do teto", { tamanho: String(LIMITE_BYTES + 1) }, 502],
    ["corpo acima do teto", { corpo: new Uint8Array(LIMITE_BYTES + 1).fill(0xff) }, 502],
    ["não é JPEG", { corpo: new Uint8Array([0x89, 0x50, 0x4e, 0x47]) }, 502],
  ];
  for (const [nome, opcoes, status] of casos) {
    const m = mundo();
    const r = await handler(pedido(), deps(m, { fetchFn: storageFalso(m, opcoes) }));
    assertEquals(r.status, status, nome);
    semCache(r, nome);
    assert(r.headers.get("content-type")?.startsWith("application/json"), `${nome}: nenhum byte da imagem sai`);
    semSegredoNoLog(m);
  }
  const m = mundo();
  const r = await handler(pedido(), deps(m, { fetchFn: () => Promise.reject(new Error("rede")) }));
  assertEquals(r.status, 502);
  semCache(r, "rede");
});

Deno.test("ler-midia: sem a credencial de serviço no ambiente é 500 no-store, depois de o banco resolver", async () => {
  const m = mundo();
  const antes = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
  try {
    const r = await handler(pedido(), { ...deps(m), serviceRoleKey: undefined });
    assertEquals(r.status, 500);
    semCache(r, "500");
    assertEquals(m.chamadas.length, 0);
  } finally {
    if (antes !== undefined) Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", antes);
  }
});
