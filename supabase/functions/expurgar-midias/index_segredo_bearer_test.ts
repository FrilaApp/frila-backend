// vt6aSi98 (116): `expurgar-midias` (que APAGA arquivo) passa `permitirBearer: false` e só aceita o segredo em `x-agendador-secret`.
// O mesmo segredo, certo, só em `Authorization: Bearer` é 401 nao_autenticado e nada é lido (fila), apagado (bucket) nem confirmado (banco).
// Só função, sem banco: `fetch` e `sqlClient` são falsos e registram as chamadas. Só dados sintéticos.
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { handler, type HandlerDeps } from "./index.ts";

const SEGREDO = "segredo-do-agendador-sintetico";
const URL_BASE = "http://127.0.0.1:54321";

function depsRegistrando(chamadas: string[]): HandlerDeps {
  return {
    agendadorSecret: SEGREDO,
    supabaseUrl: URL_BASE,
    serviceRoleKey: "service-role-sintetica",
    dbUrl: "postgresql://mock:mock@localhost:5432/mock",
    fetchFn: ((input: string | URL | Request) => {
      chamadas.push(`fetch:${typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url}`);
      return Promise.resolve(new Response("{}", { status: 200 }));
    }) as typeof fetch,
    sqlClient: {
      lerLote: () => {
        chamadas.push("lerLote");
        return Promise.resolve([{
          msg_id: 1,
          read_ct: 1,
          verificacao_id: "ad000000-0000-4000-8000-000000000001",
          bucket: "documentos-identidade",
          caminhos: ["ad000000-0000-4000-8000-000000000001/frente.jpg"],
        }]);
      },
      confirmarExpurgo: () => {
        chamadas.push("confirmarExpurgo");
        return Promise.resolve(true);
      },
      removerDaFila: () => {
        chamadas.push("removerDaFila");
        return Promise.resolve();
      },
    },
  };
}

function pedido(cabecalhos: Record<string, string>): Request {
  return new Request(`${URL_BASE}/functions/v1/expurgar-midias`, { method: "POST", headers: cabecalhos, body: "{}" });
}

Deno.test("expurgar-midias: o segredo certo só em Authorization: Bearer é 401 nao_autenticado e nada é lido, apagado ou confirmado", async () => {
  for (const autorizacao of [`Bearer ${SEGREDO}`, `bearer ${SEGREDO}`, `Bearer   ${SEGREDO}`]) {
    const chamadas: string[] = [];
    const resp = await handler(pedido({ Authorization: autorizacao }), depsRegistrando(chamadas));
    assertEquals(resp.status, 401, autorizacao);
    assertEquals((await resp.json()).code, "nao_autenticado", autorizacao);
    assertEquals(chamadas, [], `${autorizacao}: nenhum efeito (fila, bucket, banco)`);
  }
});

Deno.test("expurgar-midias: o segredo certo em x-agendador-secret lê a fila e apaga (controle)", async () => {
  const chamadas: string[] = [];
  const resp = await handler(pedido({ "x-agendador-secret": SEGREDO }), depsRegistrando(chamadas));
  assertEquals(resp.status, 200);
  assertEquals(chamadas.includes("lerLote"), true);
  assertEquals(chamadas.some((c) => c.startsWith("fetch:") && c.includes("/storage/v1/object/")), true);
});

Deno.test("expurgar-midias: o cabeçalho errado não é salvo por um Bearer certo", async () => {
  const chamadas: string[] = [];
  const resp = await handler(
    pedido({ "x-agendador-secret": "errado", Authorization: `Bearer ${SEGREDO}` }),
    depsRegistrando(chamadas),
  );
  assertEquals(resp.status, 401);
  assertEquals(chamadas, []);
});
