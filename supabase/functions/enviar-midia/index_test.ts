// Testes da enviar-midia (contrato 0.2.63). Tudo por injeção: nem rede nem banco. A atomicidade
// real do token é provada no banco (pgTAP 816 e scripts/corrida-token-upload.sh); aqui se prova
// que a função só grava depois de o banco entregar o caminho, e nunca mais de uma vez por token.
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { handler, HandlerDeps, LIMITE_BYTES } from "./index.ts";

const MIDIA = "81600000-0000-4000-8000-0000000000a1";
const TOKEN = "a".repeat(64);
const CAMINHO = `perfil/${MIDIA}.jpg`;
const BASE = "https://projeto.supabase.test";
const CHAVE = "chave-de-servico-sintetica";
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);

interface Mundo {
  chamadas: Array<{ url: string; method: string; headers: Record<string, string>; bytes: number }>;
  eventos: Array<Record<string, unknown>>;
  consumidos: number;
  gravados: number;
}

function mundo(): Mundo {
  return { chamadas: [], eventos: [], consumidos: 0, gravados: 0 };
}

/** Banco falso com o mesmo contrato do UPDATE atômico: o token vale uma vez. */
function consumidorUmaVez(m: Mundo, caminho: string | null = CAMINHO) {
  let usado = false;
  return async (midiaId: string, token: string) => {
    await Promise.resolve();
    if (caminho === null || usado || midiaId !== MIDIA || token !== TOKEN) return null;
    usado = true;
    m.consumidos += 1;
    return caminho;
  };
}

function storageFalso(m: Mundo, opcoes: { assinar?: number; gravar?: number; urlAssinada?: string } = {}): typeof fetch {
  return (async (entrada: RequestInfo | URL, init?: RequestInit) => {
    const url = String(entrada);
    const headers = Object.fromEntries(new Headers(init?.headers).entries());
    const corpo = init?.body as Uint8Array | undefined;
    m.chamadas.push({ url, method: init?.method ?? "GET", headers, bytes: corpo?.byteLength ?? 0 });
    if (init?.method === "POST") {
      const status = opcoes.assinar ?? 200;
      const rel = opcoes.urlAssinada ?? `/object/upload/sign/midia-perfil/${CAMINHO}?token=assinado-pelo-storage`;
      return new Response(JSON.stringify({ url: rel }), { status });
    }
    const status = opcoes.gravar ?? 200;
    if (status < 300) m.gravados += 1;
    return new Response(JSON.stringify({ Key: CAMINHO }), { status });
  }) as typeof fetch;
}

function deps(m: Mundo, extra: Partial<HandlerDeps> = {}): HandlerDeps {
  return {
    consumirToken: consumidorUmaVez(m),
    fetchFn: storageFalso(m),
    supabaseUrl: BASE,
    serviceRoleKey: CHAVE,
    registrar: (e) => m.eventos.push(e),
    ...extra,
  };
}

function pedido(opcoes: { metodo?: string; corpo?: Uint8Array; tipo?: string; midia?: string; token?: string; extra?: string; tamanho?: string } = {}) {
  const url = `${BASE}/functions/v1/enviar-midia?midia_id=${opcoes.midia ?? MIDIA}&token=${opcoes.token ?? TOKEN}${opcoes.extra ?? ""}`;
  const headers: Record<string, string> = { "Content-Type": opcoes.tipo ?? "image/jpeg" };
  if (opcoes.tamanho) headers["Content-Length"] = opcoes.tamanho;
  return new Request(url, {
    method: opcoes.metodo ?? "PUT",
    headers,
    body: opcoes.metodo === "GET" ? undefined : (opcoes.corpo ?? JPEG) as unknown as BodyInit,
  });
}

async function erro(r: Response) {
  return (await r.json()).erro;
}

Deno.test("enviar-midia: só PUT; outro método é 405 e não toca no banco", async () => {
  for (const metodo of ["GET", "POST", "DELETE", "PATCH"]) {
    const m = mundo();
    const r = await handler(pedido({ metodo }), deps(m));
    assertEquals(r.status, 405);
    assertEquals(m.consumidos, 0);
    assertEquals(m.chamadas.length, 0);
  }
});

Deno.test("enviar-midia: midia_id ou token fora do formato é 401 e não toca no banco", async () => {
  for (const p of [{ midia: "nao-e-uuid" }, { token: "curto" }, { token: "G".repeat(64) }, { token: "" }]) {
    const m = mundo();
    const r = await handler(pedido(p), deps(m));
    assertEquals(r.status, 401);
    assertEquals(await erro(r), "token_invalido");
    assertEquals(m.consumidos, 0);
  }
});

Deno.test("enviar-midia: Content-Type fora de image/jpeg é 415 e não gasta o token", async () => {
  const m = mundo();
  const r = await handler(pedido({ tipo: "image/png" }), deps(m));
  assertEquals(r.status, 415);
  assertEquals(m.consumidos, 0);
});

Deno.test("enviar-midia: corpo acima de 5 MB é 413, pelo cabeçalho e pela leitura, sem gastar o token", async () => {
  const m = mundo();
  const r1 = await handler(pedido({ tamanho: String(LIMITE_BYTES + 1) }), deps(m));
  assertEquals(r1.status, 413);
  const grande = new Uint8Array(LIMITE_BYTES + 1);
  grande.set([0xff, 0xd8, 0xff]);
  const r2 = await handler(pedido({ corpo: grande }), deps(m));
  assertEquals(r2.status, 413);
  assertEquals(m.consumidos, 0);
  assertEquals(m.chamadas.length, 0);
});

Deno.test("enviar-midia: exatamente 5 MB passa", async () => {
  const m = mundo();
  const limite = new Uint8Array(LIMITE_BYTES);
  limite.set([0xff, 0xd8, 0xff]);
  const r = await handler(pedido({ corpo: limite }), deps(m));
  assertEquals(r.status, 200);
  assertEquals(m.chamadas[1].bytes, LIMITE_BYTES);
});

Deno.test("enviar-midia: corpo vazio ou sem assinatura JPEG é recusado sem gastar o token", async () => {
  const m = mundo();
  assertEquals((await handler(pedido({ corpo: new Uint8Array(0) }), deps(m))).status, 400);
  assertEquals((await handler(pedido({ corpo: new Uint8Array([0x89, 0x50, 0x4e, 0x47]) }), deps(m))).status, 415);
  assertEquals(m.consumidos, 0);
});

Deno.test("enviar-midia: token que o banco não aceita é 401 e nada vai ao Storage", async () => {
  const m = mundo();
  const r = await handler(pedido(), deps(m, { consumirToken: consumidorUmaVez(m, null) }));
  assertEquals(r.status, 401);
  assertEquals(m.chamadas.length, 0);
});

Deno.test("enviar-midia: caminho feliz assina e grava no caminho do banco, sem upsert", async () => {
  const m = mundo();
  const r = await handler(pedido({ extra: "&bucket=outro&caminho=perfil/alheio.jpg" }), deps(m));
  assertEquals(r.status, 200);
  assertEquals(m.chamadas.length, 2);
  const [assinar, gravar] = m.chamadas;
  assertEquals(assinar.method, "POST");
  assertEquals(assinar.url, `${BASE}/storage/v1/object/upload/sign/midia-perfil/${CAMINHO}`);
  assertEquals(assinar.headers["x-upsert"], "false");
  assertEquals(assinar.headers["authorization"], `Bearer ${CHAVE}`);
  assertEquals(gravar.method, "PUT");
  assertEquals(gravar.url, `${BASE}/storage/v1/object/upload/sign/midia-perfil/${CAMINHO}?token=assinado-pelo-storage`);
  assertEquals(gravar.headers["x-upsert"], "false");
  assertEquals(gravar.headers["content-type"], "image/jpeg");
  assert(!("authorization" in gravar.headers), "a gravação na URL assinada não leva a chave de serviço");
  assertEquals(gravar.bytes, JPEG.byteLength);
});

Deno.test("enviar-midia: o mesmo token não grava duas vezes, nem em PUT simultâneos", async () => {
  const m = mundo();
  const d = deps(m);
  const [a, b] = await Promise.all([handler(pedido(), d), handler(pedido(), d)]);
  assertEquals([a.status, b.status].sort(), [200, 401]);
  assertEquals(m.gravados, 1);
  const r3 = await handler(pedido(), d);
  assertEquals(r3.status, 401);
  assertEquals(m.gravados, 1);
});

Deno.test("enviar-midia: falha do Storage é 502 e não diz que gravou", async () => {
  for (const opcoes of [{ assinar: 500 }, { gravar: 409 }, { gravar: 500 }, { urlAssinada: "https://outro.host/x" }]) {
    const m = mundo();
    const r = await handler(pedido(), deps(m, { fetchFn: storageFalso(m, opcoes) }));
    assertEquals(r.status, 502);
    assertEquals(m.gravados, 0);
  }
});

Deno.test("enviar-midia: banco fora do ar é 503, sem Storage", async () => {
  const m = mundo();
  const r = await handler(pedido(), deps(m, { consumirToken: () => Promise.reject(new Error("conexão recusada")) }));
  assertEquals(r.status, 503);
  assertEquals(m.chamadas.length, 0);
});

Deno.test("enviar-midia: nenhum log traz token, URL assinada ou chave de serviço", async () => {
  const m = mundo();
  await handler(pedido(), deps(m));
  await handler(pedido({ token: "b".repeat(64) }), deps(m));
  await handler(pedido(), deps(m, { fetchFn: storageFalso(m, { gravar: 500 }) }));
  const texto = JSON.stringify(m.eventos);
  assert(m.eventos.length > 0);
  for (const segredo of [TOKEN, "b".repeat(64), "assinado-pelo-storage", CHAVE, "token="]) {
    assert(!texto.includes(segredo), `log vazou ${segredo.slice(0, 8)}…`);
  }
});
