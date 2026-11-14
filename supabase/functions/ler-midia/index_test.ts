// Testes da ler-midia (B-020, contrato 0.2.82). Tudo por injeção: nem rede nem banco. Quem pode ver
// a foto de quem se prova no banco (pgTAP 858) e com Postgres real (integracao_pg_test.ts); aqui se
// prova que a função só assina o que o banco resolveu, sempre a miniatura, por 60 s, e que toda
// recusa é o mesmo 404, sem token, caminho ou URL assinada no log.
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { handler, HandlerDeps, VALIDADE_STORAGE_S } from "./index.ts";

const MIDIA = "85800000-0000-4000-8000-0000000000a1";
const TOKEN = "c".repeat(64);
const MINIATURA = `perfil/${MIDIA}_thumb.jpg`;
const BASE = "https://projeto.supabase.test";
const CHAVE = "chave-de-servico-sintetica";
const ASSINATURA = "assinado-pelo-storage-sintetico";

interface Mundo {
  chamadas: Array<{ url: string; method: string; headers: Record<string, string>; corpo: string }>;
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

function storageFalso(m: Mundo, opcoes: { status?: number; signedURL?: string } = {}): typeof fetch {
  return (async (entrada: RequestInfo | URL, init?: RequestInit) => {
    const url = String(entrada);
    const headers = Object.fromEntries(new Headers(init?.headers).entries());
    m.chamadas.push({ url, method: init?.method ?? "GET", headers, corpo: String(init?.body ?? "") });
    const signedURL = opcoes.signedURL ?? `/object/sign/midia-perfil/${MINIATURA}?token=${ASSINATURA}`;
    return new Response(JSON.stringify({ signedURL }), { status: opcoes.status ?? 200 });
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
  assert(!log.includes(ASSINATURA), "a URL assinada não vai ao log");
  assert(!log.includes(MINIATURA), "o caminho no Storage não vai ao log");
  assert(!log.includes(CHAVE), "a chave de serviço não vai ao log");
}

Deno.test("ler-midia: link válido assina a miniatura por 60 s e responde 302 para o Storage", async () => {
  const m = mundo();
  const r = await handler(pedido(), deps(m));
  assertEquals(r.status, 302);
  assertEquals(r.headers.get("location"), `${BASE}/storage/v1/object/sign/midia-perfil/${MINIATURA}?token=${ASSINATURA}`);
  assertEquals(r.headers.get("cache-control"), "private, no-store");
  assertEquals(r.headers.get("referrer-policy"), "no-referrer");
  assertEquals(m.resolvidos, [[MIDIA, TOKEN]]);
  assertEquals(m.chamadas.length, 1);
  assertEquals(m.chamadas[0].method, "POST");
  assertEquals(m.chamadas[0].url, `${BASE}/storage/v1/object/sign/midia-perfil/${MINIATURA}`);
  assertEquals(m.chamadas[0].headers["authorization"], `Bearer ${CHAVE}`);
  assertEquals(JSON.parse(m.chamadas[0].corpo), { expiresIn: VALIDADE_STORAGE_S });
  assertEquals(VALIDADE_STORAGE_S, 60);
  semSegredoNoLog(m);
});

Deno.test("ler-midia: o id vem do link em maiúsculas e é normalizado antes do banco", async () => {
  const m = mundo();
  const r = await handler(pedido({ midia: MIDIA.toUpperCase() }), deps(m));
  assertEquals(r.status, 302);
  assertEquals(m.resolvidos, [[MIDIA, TOKEN]]);
});

Deno.test("ler-midia: só GET; outro método é 405 e não toca no banco nem no Storage", async () => {
  for (const metodo of ["POST", "PUT", "DELETE"]) {
    const m = mundo();
    const r = await handler(pedido({ metodo }), deps(m));
    assertEquals(r.status, 405, metodo);
    assertEquals(m.resolvidos.length, 0);
    assertEquals(m.chamadas.length, 0);
  }
});

Deno.test("ler-midia: id ou token malformado é 404, sem ir ao banco", async () => {
  for (const [midia, token] of [["nao-e-uuid", TOKEN], [MIDIA, "curto"], [MIDIA, "C".repeat(64)], [MIDIA, ""]]) {
    const m = mundo();
    const r = await handler(pedido({ midia, token }), deps(m));
    assertEquals(r.status, 404, `${midia} ${token}`);
    assertEquals((await r.json()).erro, "nao_encontrado");
    assertEquals(m.resolvidos.length, 0);
    assertEquals(m.chamadas.length, 0);
  }
});

Deno.test("ler-midia: o banco recusa (sem vínculo, id adivinhado, vencido, removida) → 404 e o Storage não é chamado", async () => {
  const casos: Array<[string, Partial<HandlerDeps>, { midia?: string; token?: string }]> = [
    ["token adivinhado", {}, { token: "d".repeat(64) }],
    ["id de outra foto", {}, { midia: "85800000-0000-4000-8000-0000000000b1" }],
    ["banco devolve nulo", { resolverLink: resolvedor(mundo(), null) }, {}],
  ];
  for (const [nome, extra, p] of casos) {
    const m = mundo();
    const r = await handler(pedido(p), deps(m, extra));
    assertEquals(r.status, 404, nome);
    assertEquals((await r.json()).erro, "nao_encontrado", nome);
    assertEquals(m.chamadas.length, 0, nome);
    semSegredoNoLog(m);
  }
});

Deno.test("ler-midia: caminho do banco que não é a miniatura de perfil/ é recusado (o original nunca sai)", async () => {
  for (const caminho of [`perfil/${MIDIA}.jpg`, `outra/${MIDIA}_thumb.jpg`, `perfil/../x_thumb.jpg`]) {
    const m = mundo();
    const r = await handler(pedido(), deps(m, { resolverLink: resolvedor(m, caminho) }));
    assertEquals(r.status, 404, caminho);
    assertEquals(m.chamadas.length, 0, caminho);
  }
});

Deno.test("ler-midia: banco fora do ar é 503", async () => {
  const m = mundo();
  const r = await handler(pedido(), deps(m, { resolverLink: () => Promise.reject(new Error("fora")) }));
  assertEquals(r.status, 503);
  assertEquals(m.chamadas.length, 0);
});

Deno.test("ler-midia: Storage que falha ou devolve URL de outro bucket é 502, sem redirecionar", async () => {
  for (const opcoes of [{ status: 500 }, { signedURL: `/object/sign/outro-bucket/${MINIATURA}?token=x` }, { signedURL: "" }]) {
    const m = mundo();
    const r = await handler(pedido(), deps(m, { fetchFn: storageFalso(m, opcoes) }));
    assertEquals(r.status, 502, JSON.stringify(opcoes));
    assertEquals(r.headers.get("location"), null);
    semSegredoNoLog(m);
  }
  const m = mundo();
  const r = await handler(pedido(), deps(m, { fetchFn: () => Promise.reject(new Error("rede")) }));
  assertEquals(r.status, 502);
});

Deno.test("ler-midia: sem a credencial de serviço no ambiente é 500, depois de o banco resolver", async () => {
  const m = mundo();
  const antes = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
  try {
    const r = await handler(pedido(), { ...deps(m), serviceRoleKey: undefined });
    assertEquals(r.status, 500);
    assertEquals(m.chamadas.length, 0);
  } finally {
    if (antes !== undefined) Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", antes);
  }
});
