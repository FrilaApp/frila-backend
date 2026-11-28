// Cartão NaU7YfCx (item 219): o fetch de GET /auth/v1/user (conferência do titular) não tinha try/catch; uma falha de rede, um timeout
// ou um DNS que não resolve fazia a função lançar em vez de responder. A falha de rede responde como o 5xx do mesmo endpoint
// já responde: 503 indisponivel, sem revogar nada. O contrato não muda.
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { tratarRevogarDispositivos } from "./index.ts";

async function revogarComFalhaNoFetch(falha: () => Promise<Response>) {
  const registro = { fetch: [] as string[], verificacoes: 0, revogacoes: 0 };
  const res = await tratarRevogarDispositivos(
    new Request("https://local/functions/v1/revogar-dispositivos", { method: "POST", headers: { Authorization: "Bearer jwt-x" } }),
    {
      supabaseUrl: "https://proj.supabase.co",
      anonKey: "anon-test",
      fetchFn: (input) => {
        registro.fetch.push(String(input));
        return falha();
      },
      db: {
        verificarSessaoOnline: () => {
          registro.verificacoes++;
          return Promise.resolve(true);
        },
        revogarTodosDispositivos: () => {
          registro.revogacoes++;
          return Promise.resolve(2);
        },
      },
    },
  );
  return { res, registro };
}

Deno.test("revogar-dispositivos: falha de rede ao conferir o titular em /auth/v1/user devolve 503 indisponivel, sem revogar nada", async () => {
  const falhas: Array<[string, () => Promise<Response>]> = [
    ["TypeError de rede", () => Promise.reject(new TypeError("error sending request"))],
    ["timeout", () => Promise.reject(new DOMException("The signal has been aborted", "TimeoutError"))],
    ["Error genérico", () => Promise.reject(new Error("dns error"))],
    ["lançamento síncrono", () => {
      throw new Error("falha síncrona");
    }],
  ];
  for (const [nome, falha] of falhas) {
    const { res, registro } = await revogarComFalhaNoFetch(falha);

    assertEquals(res.status, 503, nome);
    const corpo = await res.json();
    assertEquals(corpo.code, "indisponivel", nome);
    assertEquals(registro.fetch.length, 1, `${nome}: só a conferência do titular, sem logout global`);
    assertEquals(registro.verificacoes, 0, nome);
    assertEquals(registro.revogacoes, 0, nome);
  }
});

Deno.test("revogar-dispositivos: a falha de rede responde igual ao 5xx do mesmo endpoint (mesmo status, code e corpo)", async () => {
  const rede = await revogarComFalhaNoFetch(() => Promise.reject(new TypeError("sem rede")));
  const cinco = await revogarComFalhaNoFetch(() => Promise.resolve(new Response("{}", { status: 503 })));

  assertEquals(rede.res.status, cinco.res.status);
  assertEquals(await rede.res.json(), await cinco.res.json());
});
