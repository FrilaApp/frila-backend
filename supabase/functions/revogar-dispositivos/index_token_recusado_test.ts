// im2mnI8W (100): `revogar-dispositivos` com o token recusado pelo GoTrue não revoga nada.
//   GoTrue 429 -> 429 limite_excedido; 5xx -> 503 indisponivel; não-ok (4xx) ou resposta sem id -> 401 nao_autenticado.
// Em todos: nem a sessão é verificada nem os dispositivos são revogados, e o logout global não é chamado.
// Só função, sem banco: `db` e `fetch` são falsos e registram as chamadas. Só dados sintéticos.
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { type RevogarDispositivosDb, tratarRevogarDispositivos } from "./index.ts";

interface Registro {
  fetch: string[];
  verificacoes: number;
  revogacoes: string[];
}

function dbRegistrando(reg: Registro): RevogarDispositivosDb {
  return {
    verificarSessaoOnline: () => {
      reg.verificacoes++;
      return Promise.resolve(true);
    },
    revogarTodosDispositivos: (uid) => {
      reg.revogacoes.push(uid);
      return Promise.resolve(2);
    },
  };
}

async function chamar(resposta: () => Response) {
  const reg: Registro = { fetch: [], verificacoes: 0, revogacoes: [] };
  const res = await tratarRevogarDispositivos(
    new Request("https://local/functions/v1/revogar-dispositivos", { method: "POST", headers: { Authorization: "Bearer jwt-x" } }),
    {
      supabaseUrl: "https://proj.supabase.co",
      anonKey: "anon-test",
      fetchFn: (input) => {
        reg.fetch.push(String(input));
        return Promise.resolve(resposta());
      },
      db: dbRegistrando(reg),
    },
  );
  return { res, reg };
}

Deno.test("revogar-dispositivos: GoTrue 429 devolve 429 limite_excedido e não revoga nada", async () => {
  const { res, reg } = await chamar(() => new Response("{}", { status: 429 }));
  assertEquals(res.status, 429);
  assertEquals((await res.json()).code, "limite_excedido");
  assertEquals(reg.revogacoes, []);
  assertEquals(reg.verificacoes, 0);
  assertEquals(reg.fetch.length, 1, "só a conferência do usuário, sem logout global");
});

Deno.test("revogar-dispositivos: GoTrue 5xx devolve 503 indisponivel e não revoga nada", async () => {
  for (const status of [500, 502, 503]) {
    const { res, reg } = await chamar(() => new Response("{}", { status }));
    assertEquals(res.status, 503, `GoTrue ${status}`);
    assertEquals((await res.json()).code, "indisponivel", `GoTrue ${status}`);
    assertEquals(reg.revogacoes, [], `GoTrue ${status}`);
    assertEquals(reg.verificacoes, 0, `GoTrue ${status}`);
    assertEquals(reg.fetch.length, 1, `GoTrue ${status}`);
  }
});

Deno.test("revogar-dispositivos: token recusado (4xx) ou resposta sem id devolve 401 nao_autenticado e não revoga nada", async () => {
  const casos: (() => Response)[] = [
    () => new Response("{}", { status: 401 }),
    () => new Response("{}", { status: 403 }),
    () => new Response("{}", { status: 404 }),
    () => Response.json({ id: "user-99" }, { status: 401 }),
    () => Response.json({ id: "user-99" }, { status: 404 }),
    () => Response.json({}),
    () => Response.json({ id: "" }),
    () => new Response("não é json", { status: 200 }),
  ];
  for (const [i, caso] of casos.entries()) {
    const { res, reg } = await chamar(caso);
    assertEquals(res.status, 401, `caso ${i}`);
    assertEquals((await res.json()).code, "nao_autenticado", `caso ${i}`);
    assertEquals(reg.revogacoes, [], `caso ${i}`);
    assertEquals(reg.verificacoes, 0, `caso ${i}`);
    assertEquals(reg.fetch.length, 1, `caso ${i}`);
  }
});
