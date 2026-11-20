// Testes da enviar-documento-verificacao (RN14, parte da troca do upload por token opaco). Tudo por
// injeção: nem rede nem banco. A atomicidade real do token é provada no banco (pgTAP 890 e
// scripts/corrida-token-upload-verificacao.sh); aqui se prova que a função só grava depois de o
// banco entregar o destino, que o destino vem sempre do banco e que nunca grava mais de uma vez
// por token.
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { type Destino, handler, HandlerDeps, LIMITE_BYTES } from "./index.ts";

const UPLOAD = "89100000-0000-4000-8000-0000000000a1";
const TOKEN = "a".repeat(64);
const BUCKET = "documentos-identidade";
const CAMINHO = "verificacao/89100000-0000-4000-8000-000000000101/frente.jpg";
const DESTINO: Destino = { bucket: BUCKET, storage_path: CAMINHO, parte: "frente" };
const BASE = "https://projeto.supabase.test";
const CHAVE = "chave-de-servico-sintetica";

const ASCII = (s: string) => Array.from(s, (c) => c.charCodeAt(0));
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);

/** Caixa `ftyp` de um HEIF: tamanho, "ftyp", marca principal, versão e marcas compatíveis, mais carga. */
function heif(principal: string, compativeis: string[] = [], opcoes: { tamanho?: number; sem_ftyp?: boolean } = {}): Uint8Array {
  const tamanho = opcoes.tamanho ?? 16 + 4 * compativeis.length;
  const cabeca = [
    (tamanho >>> 24) & 0xff,
    (tamanho >>> 16) & 0xff,
    (tamanho >>> 8) & 0xff,
    tamanho & 0xff,
    ...ASCII(opcoes.sem_ftyp ? "moov" : "ftyp"),
    ...ASCII(principal),
    0, 0, 0, 0,
    ...compativeis.flatMap(ASCII),
  ];
  return new Uint8Array([...cabeca, 9, 9, 9, 9]);
}

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
function consumidorUmaVez(m: Mundo, destino: unknown = DESTINO) {
  let usado = false;
  return async (uploadId: string, token: string) => {
    await Promise.resolve();
    if (destino === null || usado || uploadId !== UPLOAD || token !== TOKEN) return null;
    usado = true;
    m.consumidos += 1;
    return destino as Destino;
  };
}

function storageFalso(
  m: Mundo,
  opcoes: { assinar?: number; gravar?: number; urlAssinada?: string; bucket?: string; caminho?: string } = {},
): typeof fetch {
  return (async (entrada: RequestInfo | URL, init?: RequestInit) => {
    const url = String(entrada);
    const headers = Object.fromEntries(new Headers(init?.headers).entries());
    const corpo = init?.body as Uint8Array | undefined;
    m.chamadas.push({ url, method: init?.method ?? "GET", headers, bytes: corpo?.byteLength ?? 0 });
    if (init?.method === "POST") {
      const status = opcoes.assinar ?? 200;
      const rel = opcoes.urlAssinada ??
        `/object/upload/sign/${opcoes.bucket ?? BUCKET}/${opcoes.caminho ?? CAMINHO}?token=assinado-pelo-storage`;
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

function pedido(
  opcoes: { metodo?: string; corpo?: Uint8Array; tipo?: string; upload?: string; token?: string; extra?: string; tamanho?: string } = {},
) {
  const url = `${BASE}/functions/v1/enviar-documento-verificacao?upload_id=${opcoes.upload ?? UPLOAD}&token=${opcoes.token ?? TOKEN}${opcoes.extra ?? ""}`;
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

Deno.test("enviar-documento-verificacao: só PUT; outro método é 405 e não toca no banco", async () => {
  for (const metodo of ["GET", "POST", "DELETE", "PATCH"]) {
    const m = mundo();
    const r = await handler(pedido({ metodo }), deps(m));
    assertEquals(r.status, 405);
    assertEquals(m.consumidos, 0);
    assertEquals(m.chamadas.length, 0);
  }
});

Deno.test("enviar-documento-verificacao: upload_id ou token fora do formato é 401 e não toca no banco", async () => {
  for (const p of [{ upload: "nao-e-uuid" }, { token: "curto" }, { token: "G".repeat(64) }, { token: "" }]) {
    const m = mundo();
    const r = await handler(pedido(p), deps(m));
    assertEquals(r.status, 401);
    assertEquals(await erro(r), "token_invalido");
    assertEquals(m.consumidos, 0);
  }
});

Deno.test("enviar-documento-verificacao: Content-Type fora do bucket é 415 e não gasta o token", async () => {
  for (const tipo of ["image/gif", "image/webp", "application/pdf", "image/heif", "text/plain", ""]) {
    const m = mundo();
    const r = await handler(pedido({ tipo }), deps(m));
    assertEquals(r.status, 415, `tipo ${tipo}`);
    assertEquals(m.consumidos, 0);
  }
});

Deno.test("enviar-documento-verificacao: corpo acima de 5 MiB é 413, pelo cabeçalho e pela leitura, sem gastar o token", async () => {
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

Deno.test("enviar-documento-verificacao: cabeçalho que mente sobre o tamanho não vence a leitura real", async () => {
  const m = mundo();
  const grande = new Uint8Array(LIMITE_BYTES + 1);
  grande.set([0xff, 0xd8, 0xff]);
  const r = await handler(pedido({ corpo: grande, tamanho: "100" }), deps(m));
  assertEquals(r.status, 413);
  assertEquals(m.consumidos, 0);
  assertEquals(m.chamadas.length, 0);
});

Deno.test("enviar-documento-verificacao: exatamente 5 MiB passa", async () => {
  const m = mundo();
  const limite = new Uint8Array(LIMITE_BYTES);
  limite.set([0xff, 0xd8, 0xff]);
  const r = await handler(pedido({ corpo: limite }), deps(m));
  assertEquals(r.status, 200);
  assertEquals(m.chamadas[1].bytes, LIMITE_BYTES);
});

Deno.test("enviar-documento-verificacao: corpo vazio é 400 e não gasta o token", async () => {
  const m = mundo();
  assertEquals((await handler(pedido({ corpo: new Uint8Array(0) }), deps(m))).status, 400);
  assertEquals(m.consumidos, 0);
});

Deno.test("enviar-documento-verificacao: bytes que não são do tipo declarado são 415 e não gastam o token", async () => {
  const casos: Array<[string, Uint8Array]> = [
    ["image/jpeg", PNG],
    ["image/jpeg", heif("heic")],
    ["image/jpeg", new Uint8Array([0xff, 0xd8])],
    ["image/png", JPEG],
    ["image/png", new Uint8Array([0x89, 0x50, 0x4e, 0x47])],
    ["image/png", new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0b, 1])],
    ["image/heic", JPEG],
    ["image/heic", PNG],
    ["image/heic", new Uint8Array(ASCII("%PDF-1.7 documento qualquer"))],
  ];
  for (const [tipo, corpo] of casos) {
    const m = mundo();
    const r = await handler(pedido({ tipo, corpo }), deps(m));
    assertEquals(r.status, 415, `${tipo} com ${corpo.slice(0, 4)}`);
    assertEquals(await erro(r), "formato");
    assertEquals(m.consumidos, 0);
    assertEquals(m.chamadas.length, 0);
  }
});

Deno.test("enviar-documento-verificacao: HEIC só vale com ftyp íntegro e marca permitida", async () => {
  const recusados: Array<[string, Uint8Array]> = [
    ["marca avif sozinha", heif("avif", ["mif1", "miaf"])],
    ["marca mp42 (vídeo)", heif("mp42", ["isom"])],
    ["mif1 sem marca HEIC compatível", heif("mif1", ["miaf", "avif"])],
    ["sem a palavra ftyp", heif("heic", [], { sem_ftyp: true })],
    ["caixa ftyp maior que o corpo", heif("heic", [], { tamanho: 4096 })],
    ["caixa ftyp menor que o mínimo", heif("heic", [], { tamanho: 8 })],
    ["corpo curto demais", new Uint8Array([0, 0, 0, 16, ...ASCII("ftyp"), ...ASCII("he")])],
  ];
  for (const [nome, corpo] of recusados) {
    const m = mundo();
    const r = await handler(pedido({ tipo: "image/heic", corpo }), deps(m));
    assertEquals(r.status, 415, nome);
    assertEquals(m.consumidos, 0, nome);
    assertEquals(m.chamadas.length, 0, nome);
  }
  for (const [nome, corpo] of [
    ["heic", heif("heic")],
    ["heix", heif("heix")],
    ["mif1 com heic compatível", heif("mif1", ["miaf", "heic"])],
  ] as Array<[string, Uint8Array]>) {
    const m = mundo();
    const r = await handler(pedido({ tipo: "image/heic", corpo }), deps(m));
    assertEquals(r.status, 200, nome);
    assertEquals(m.gravados, 1, nome);
  }
});

Deno.test("enviar-documento-verificacao: token que o banco não aceita é 401 e nada vai ao Storage", async () => {
  const m = mundo();
  const r = await handler(pedido(), deps(m, { consumirToken: consumidorUmaVez(m, null) }));
  assertEquals(r.status, 401);
  assertEquals(m.chamadas.length, 0);
});

Deno.test("enviar-documento-verificacao: JPEG, PNG e HEIC gravam no destino do banco, sem upsert e com o tipo declarado", async () => {
  const casos: Array<[string, Uint8Array]> = [
    ["image/jpeg", JPEG],
    ["image/png", PNG],
    ["image/heic", heif("heic")],
    ["IMAGE/PNG; charset=binary", PNG],
  ];
  for (const [tipo, corpo] of casos) {
    const m = mundo();
    const r = await handler(pedido({ tipo, corpo, extra: "&bucket=outro&caminho=perfil/alheio.jpg&parte=verso" }), deps(m));
    assertEquals(r.status, 200, tipo);
    assertEquals(m.chamadas.length, 2);
    const [assinar, gravar] = m.chamadas;
    assertEquals(assinar.method, "POST");
    assertEquals(assinar.url, `${BASE}/storage/v1/object/upload/sign/${BUCKET}/${CAMINHO}`);
    assertEquals(assinar.headers["x-upsert"], "false");
    assertEquals(assinar.headers["authorization"], `Bearer ${CHAVE}`);
    assertEquals(gravar.method, "PUT");
    assertEquals(gravar.url, `${BASE}/storage/v1/object/upload/sign/${BUCKET}/${CAMINHO}?token=assinado-pelo-storage`);
    assertEquals(gravar.headers["x-upsert"], "false");
    assertEquals(gravar.headers["content-type"], tipo.split(";")[0].toLowerCase());
    assert(!("authorization" in gravar.headers), "a gravação na URL assinada não leva a chave de serviço");
    assertEquals(gravar.bytes, corpo.byteLength);
  }
});

Deno.test("enviar-documento-verificacao: bucket e caminho vêm do banco, nunca do pedido", async () => {
  const m = mundo();
  const destino: Destino = { bucket: "bucket-do-banco", storage_path: "cx/verso.jpg", parte: "verso" };
  const r = await handler(
    pedido({ extra: "&bucket=documentos-identidade&caminho=perfil/alheio.jpg&storage_path=x/y.jpg" }),
    deps(m, {
      consumirToken: consumidorUmaVez(m, destino),
      fetchFn: storageFalso(m, { bucket: "bucket-do-banco", caminho: "cx/verso.jpg" }),
    }),
  );
  assertEquals(r.status, 200);
  assertEquals(m.chamadas[0].url, `${BASE}/storage/v1/object/upload/sign/bucket-do-banco/cx/verso.jpg`);
  assert(m.chamadas.every((c) => !c.url.includes("alheio") && !c.url.includes("documentos-identidade")));
});

Deno.test("enviar-documento-verificacao: destino malformado do banco é 500 e não chega ao Storage", async () => {
  const ruins: unknown[] = [
    { bucket: "", storage_path: CAMINHO, parte: "frente" },
    { bucket: BUCKET, storage_path: "", parte: "frente" },
    { bucket: BUCKET, storage_path: "../outro/frente.jpg", parte: "frente" },
    { bucket: BUCKET, storage_path: "/absoluto/frente.jpg", parte: "frente" },
    { bucket: "a/b", storage_path: CAMINHO, parte: "frente" },
    { bucket: BUCKET, parte: "frente" },
    "texto",
  ];
  for (const destino of ruins) {
    const m = mundo();
    const r = await handler(pedido(), deps(m, { consumirToken: consumidorUmaVez(m, destino) }));
    assertEquals(r.status, 500, JSON.stringify(destino));
    assertEquals(await erro(r), "destino_invalido");
    assertEquals(m.chamadas.length, 0);
  }
});

Deno.test("enviar-documento-verificacao: o mesmo token não grava duas vezes, nem em PUT simultâneos", async () => {
  const m = mundo();
  const d = deps(m);
  const [a, b] = await Promise.all([handler(pedido(), d), handler(pedido(), d)]);
  assertEquals([a.status, b.status].sort(), [200, 401]);
  assertEquals(m.gravados, 1);
  const r3 = await handler(pedido(), d);
  assertEquals(r3.status, 401);
  assertEquals(m.gravados, 1);
});

Deno.test("enviar-documento-verificacao: falha do Storage é 502 e não diz que gravou", async () => {
  for (const opcoes of [{ assinar: 500 }, { gravar: 409 }, { gravar: 500 }, { urlAssinada: "https://outro.host/x" }, { bucket: "outro-bucket" }]) {
    const m = mundo();
    const r = await handler(pedido(), deps(m, { fetchFn: storageFalso(m, opcoes) }));
    assertEquals(r.status, 502, JSON.stringify(opcoes));
    assertEquals(m.gravados, 0);
  }
});

Deno.test("enviar-documento-verificacao: banco fora do ar é 503, sem Storage", async () => {
  const m = mundo();
  const r = await handler(pedido(), deps(m, { consumirToken: () => Promise.reject(new Error("conexão recusada")) }));
  assertEquals(r.status, 503);
  assertEquals(m.chamadas.length, 0);
});

Deno.test("enviar-documento-verificacao: sem chave de serviço no ambiente é 500, sem Storage", async () => {
  for (const extra of [{ serviceRoleKey: "" }, { supabaseUrl: "" }]) {
    const m = mundo();
    const r = await handler(pedido(), deps(m, extra));
    assertEquals(r.status, 500);
    assertEquals(await erro(r), "configuracao");
    assertEquals(m.chamadas.length, 0);
  }
});

Deno.test("enviar-documento-verificacao: nenhum log traz token, URL assinada, caminho, corpo ou chave de serviço", async () => {
  const m = mundo();
  const corpoSecreto = new Uint8Array([0xff, 0xd8, 0xff, ...ASCII("conteudo-do-documento")]);
  await handler(pedido({ corpo: corpoSecreto }), deps(m));
  await handler(pedido({ token: "b".repeat(64) }), deps(m));
  await handler(pedido({ corpo: corpoSecreto }), deps(m, { fetchFn: storageFalso(m, { gravar: 500 }) }));
  await handler(pedido({ corpo: corpoSecreto }), deps(m, { fetchFn: storageFalso(m, { assinar: 500 }) }));
  await handler(pedido({ corpo: corpoSecreto }), deps(m, { consumirToken: () => Promise.reject(new Error(`falha ${TOKEN}`)) }));
  const texto = JSON.stringify(m.eventos);
  assert(m.eventos.length > 0);
  for (const segredo of [TOKEN, "b".repeat(64), "assinado-pelo-storage", CHAVE, "token=", CAMINHO, "conteudo-do-documento"]) {
    assert(!texto.includes(segredo), `log vazou ${segredo.slice(0, 8)}…`);
  }
});
