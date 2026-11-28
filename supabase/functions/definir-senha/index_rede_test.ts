// Cartão NaU7YfCx (item 219): o fetch de GET /auth/v1/user (conferência do titular) não tinha try/catch; uma falha de rede, um timeout
// ou um DNS que não resolve fazia a função lançar em vez de responder. A falha de rede responde como o 5xx do mesmo endpoint
// já responde: 503 indisponivel, sem tocar em senha, banco ou GoTrue de novo. O contrato não muda.
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { tratarDefinirSenha } from "./index.ts";

function fakeJwt(sessionId: string): string {
  const b64 = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `${b64({ alg: "none" })}.${b64({ session_id: sessionId })}.sig`;
}

async function definirComFalhaNoFetch(falha: () => Promise<Response>) {
  const registro = { fetch: [] as string[], verificacoes: 0, conclusoes: 0 };
  const res = await tratarDefinirSenha(
    new Request("https://local/functions/v1/definir-senha", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${fakeJwt("sess-1")}` },
      body: JSON.stringify({ nova_senha: "NovaSenhaForte123!" }),
    }),
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
        concluirDefinicaoSenha: () => {
          registro.conclusoes++;
          return Promise.resolve({ dispositivos_revogados: 0 });
        },
      },
    },
  );
  return { res, registro };
}

Deno.test("definir-senha: falha de rede ao conferir o titular em /auth/v1/user devolve 503 indisponivel, sem trocar a senha nem tocar no banco", async () => {
  const falhas: Array<[string, () => Promise<Response>]> = [
    ["TypeError de rede", () => Promise.reject(new TypeError("error sending request"))],
    ["timeout", () => Promise.reject(new DOMException("The signal has been aborted", "TimeoutError"))],
    ["Error genérico", () => Promise.reject(new Error("dns error"))],
    ["lançamento síncrono", () => {
      throw new Error("falha síncrona");
    }],
  ];
  for (const [nome, falha] of falhas) {
    const { res, registro } = await definirComFalhaNoFetch(falha);

    assertEquals(res.status, 503, nome);
    const corpo = await res.json();
    assertEquals(corpo.code, "indisponivel", nome);
    assertEquals(registro.fetch.length, 1, `${nome}: só a conferência do titular, sem PUT de senha`);
    assertEquals(registro.verificacoes, 0, nome);
    assertEquals(registro.conclusoes, 0, nome);
  }
});

Deno.test("definir-senha: a falha de rede responde igual ao 5xx do mesmo endpoint (mesmo status, code e corpo)", async () => {
  const rede = await definirComFalhaNoFetch(() => Promise.reject(new TypeError("sem rede")));
  const cinco = await definirComFalhaNoFetch(() => Promise.resolve(new Response("{}", { status: 503 })));

  assertEquals(rede.res.status, cinco.res.status);
  assertEquals(await rede.res.json(), await cinco.res.json());
});
