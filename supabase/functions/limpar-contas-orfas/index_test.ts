import { assertEquals } from "jsr:@std/assert@1";
import { handler, HandlerDeps } from "./index.ts";

const MOCK_URL = "http://127.0.0.1:54321";
const MOCK_SERVICE_ROLE = "service-role-key-mock";
const MOCK_SECRET = "segredo-agendador-mock";
const MOCK_DB_URL = "postgresql://mock:mock@localhost:5432/mock";

const ORFAO_1 = "c3200000-0000-4000-8000-000000000001";
const ORFAO_2 = "c3200000-0000-4000-8000-000000000002";

function mockDeps(opcoes: {
  contasOrfas?: string[];
  dbErro?: boolean;
  adminFailId?: string;
  onDeleteUser?: (id: string) => void;
}): HandlerDeps {
  const contas = opcoes.contasOrfas ?? [ORFAO_1, ORFAO_2];

  const fetchFn = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const urlStr = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;

    if (urlStr.includes("/auth/v1/admin/users/")) {
      const authHeader = (init?.headers as Record<string, string>)?.["Authorization"];
      if (authHeader !== `Bearer ${MOCK_SERVICE_ROLE}`) {
        return Promise.resolve(new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 }));
      }

      const match = urlStr.match(/\/auth\/v1\/admin\/users\/([^/?]+)/);
      const userId = match ? decodeURIComponent(match[1]) : "";

      if (opcoes.adminFailId && userId === opcoes.adminFailId) {
        return Promise.resolve(new Response(JSON.stringify({ error: "fail" }), { status: 500 }));
      }

      opcoes.onDeleteUser?.(userId);
      return Promise.resolve(new Response(JSON.stringify({}), { status: 200 }));
    }

    return Promise.resolve(new Response("Not Found", { status: 404 }));
  };

  const sqlClient = {
    contasOrfas: (_horas: number) => {
      if (opcoes.dbErro) {
        return Promise.reject(new Error("db_error"));
      }
      return Promise.resolve(contas);
    },
    executarRetencao: () => {
      return Promise.resolve({
        executado_em: "2026-10-20T12:00:00Z",
        contas_anonimizadas_limpas: 1,
        higiene: { cron_job_run_details: 0, pgmq_arquivo: 1, auditoria_ciclo: 2, dispositivos_inativos: 0 },
      });
    },
  };

  return {
    fetchFn: fetchFn as typeof fetch,
    sqlClient,
    supabaseUrl: MOCK_URL,
    serviceRoleKey: MOCK_SERVICE_ROLE,
    agendadorSecret: MOCK_SECRET,
    dbUrl: MOCK_DB_URL,
  };
}

Deno.test("recusa método que não seja POST (405)", async () => {
  const deps = mockDeps({});
  const resposta = await handler(new Request("http://localhost", { method: "GET" }), deps);
  assertEquals(resposta.status, 405);
  const corpo = await resposta.json();
  assertEquals(corpo.code, "metodo_nao_permitido");
});

Deno.test("recusa chamada sem segredo do agendador (401)", async () => {
  const deps = mockDeps({});
  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    }),
    deps
  );
  assertEquals(resposta.status, 401);
  const corpo = await resposta.json();
  assertEquals(corpo.code, "nao_autenticado");
});

Deno.test("recusa chamada com segredo inválido (401)", async () => {
  const deps = mockDeps({});
  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        "x-agendador-secret": "segredo-errado",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    }),
    deps
  );
  assertEquals(resposta.status, 401);
});

Deno.test("aceita segredo via header x-agendador-secret e purga contas via Admin API (200)", async () => {
  const deletados: string[] = [];
  const deps = mockDeps({
    onDeleteUser: (id) => deletados.push(id),
  });

  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        "x-agendador-secret": MOCK_SECRET,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ horas: 24, executar_retencao_banco: true }),
    }),
    deps
  );

  assertEquals(resposta.status, 200);
  const corpo = await resposta.json();
  assertEquals(corpo.ok, true);
  assertEquals(corpo.contas_orfas_encontradas, 2);
  assertEquals(corpo.contas_orfas_removidas, 2);
  assertEquals(deletados, [ORFAO_1, ORFAO_2]);
  assertEquals(corpo.retencao_banco.contas_anonimizadas_limpas, 1);
});

Deno.test("aceita segredo via Bearer token (200)", async () => {
  const deps = mockDeps({});
  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${MOCK_SECRET}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    }),
    deps
  );

  assertEquals(resposta.status, 200);
  const corpo = await resposta.json();
  assertEquals(corpo.ok, true);
});

Deno.test("lida com falha pontual em usuário individual sem quebrar a execução geral", async () => {
  const deletados: string[] = [];
  const deps = mockDeps({
    adminFailId: ORFAO_2,
    onDeleteUser: (id) => deletados.push(id),
  });

  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        "x-agendador-secret": MOCK_SECRET,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    }),
    deps
  );

  assertEquals(resposta.status, 200);
  const corpo = await resposta.json();
  assertEquals(corpo.ok, true);
  assertEquals(corpo.contas_orfas_encontradas, 2);
  assertEquals(corpo.contas_orfas_removidas, 1);
  assertEquals(deletados, [ORFAO_1]);
  assertEquals(corpo.erros_remocao.length, 1);
  assertEquals(corpo.erros_remocao[0].id, ORFAO_2);
});
