// vt6aSi98 (115): `enviar-email` só aceita o segredo do agendador no cabeçalho `x-agendador-secret`.
// O mesmo segredo, certo, só em `Authorization: Bearer` é 401 nao_autorizado e nada é lido (fila), enviado ou arquivado.
// O `index_test.ts` só testava segredo ausente ou errado; as irmãs (despachar, enviar-push, limpar-contas-orfas, moderar-midia) já testam este caso.
// Só função, sem banco: o `sqlClient` e o `enviar` são falsos e registram as chamadas. Só dados sintéticos.
import "./test_setup.ts";
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { processarEnvioEmail, type SqlClient } from "./index.ts";

const SEGREDO = "segredo-do-agendador-sintetico";

function sqlRegistrando(chamadas: string[]): SqlClient {
  return {
    lerFilaEmail: () => {
      chamadas.push("lerFilaEmail");
      return Promise.resolve([]);
    },
    dadosDoEmail: () => {
      chamadas.push("dadosDoEmail");
      return Promise.resolve(null);
    },
    registrarEnviado: () => {
      chamadas.push("registrarEnviado");
      return Promise.resolve();
    },
    registrarFalha: () => {
      chamadas.push("registrarFalha");
      return Promise.resolve(1);
    },
    registrarFalhaOperacional: () => {
      chamadas.push("registrarFalhaOperacional");
      return Promise.resolve();
    },
    concluir: () => {
      chamadas.push("concluir");
      return Promise.resolve();
    },
  };
}

async function chamar(cabecalhos: Record<string, string>) {
  const chamadas: string[] = [];
  const res = await processarEnvioEmail(
    new Request("http://localhost/functions/v1/enviar-email", { method: "POST", headers: cabecalhos, body: "{}" }),
    {
      agendadorSecret: SEGREDO,
      sqlClient: sqlRegistrando(chamadas),
      enviar: () => {
        chamadas.push("enviar");
        return Promise.resolve({ ok: true });
      },
    },
  );
  return { res, chamadas };
}

Deno.test("enviar-email: o segredo certo só em Authorization: Bearer é 401 nao_autorizado e nada é lido, enviado ou arquivado", async () => {
  for (const autorizacao of [`Bearer ${SEGREDO}`, `bearer ${SEGREDO}`, `Bearer   ${SEGREDO}`]) {
    const { res, chamadas } = await chamar({ Authorization: autorizacao });
    assertEquals(res.status, 401, autorizacao);
    assertEquals((await res.json()).erro, "nao_autorizado", autorizacao);
    assertEquals(chamadas, [], `${autorizacao}: nenhum efeito`);
  }
});

Deno.test("enviar-email: o segredo certo em x-agendador-secret passa a recusa e lê a fila (controle)", async () => {
  const { res, chamadas } = await chamar({ "x-agendador-secret": SEGREDO });
  assertEquals(res.status, 200);
  assertEquals(chamadas.includes("lerFilaEmail"), true);
});

Deno.test("enviar-email: o cabeçalho errado não é salvo por um Bearer certo", async () => {
  const { res, chamadas } = await chamar({ "x-agendador-secret": "errado", Authorization: `Bearer ${SEGREDO}` });
  assertEquals(res.status, 401);
  assertEquals(chamadas, []);
});
