import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { handler, HandlerDeps, tratarErroBanco } from "./index.ts";

const MOCK_USER_ID = "a1111111-1111-4000-8000-000000000001";
const MOCK_URL = "http://127.0.0.1:54321";
const MOCK_ANON = "anon-key-mock";
const MOCK_SERVICE_ROLE = "service-role-key-mock";
const MOCK_DB_URL = "postgresql://mock:mock@localhost:5432/mock";

function mockDeps(opcoes: {
  authOk?: boolean;
  dbErro?: { code: string; message: string; detail?: string };
  dbRetorno?: Record<string, unknown>;
  adminOk?: boolean;
  onAdminDelete?: () => void;
}): HandlerDeps {
  const authOk = opcoes.authOk ?? true;
  const adminOk = opcoes.adminOk ?? true;

  const fetchFn = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const urlStr = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;

    if (urlStr.includes("/auth/v1/user")) {
      if (!authOk) {
        return Promise.resolve(new Response(JSON.stringify({ error: "invalid_jwt" }), { status: 401 }));
      }
      return Promise.resolve(new Response(JSON.stringify({ id: MOCK_USER_ID }), { status: 200 }));
    }

    if (urlStr.includes(`/auth/v1/admin/users/${MOCK_USER_ID}`)) {
      if (!adminOk) {
        return Promise.resolve(new Response(JSON.stringify({ error: "admin_error" }), { status: 500 }));
      }
      const authHeader = (init?.headers as Record<string, string>)?.["Authorization"];
      if (authHeader !== `Bearer ${MOCK_SERVICE_ROLE}`) {
        return Promise.resolve(new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 }));
      }
      opcoes.onAdminDelete?.();
      return Promise.resolve(new Response(JSON.stringify({}), { status: 200 }));
    }

    return Promise.resolve(new Response("Not Found", { status: 404 }));
  };

  const sqlClient = {
    query: (_userId: string) => {
      if (opcoes.dbErro) {
        return Promise.reject(opcoes.dbErro);
      }
      return Promise.resolve({
        dados: opcoes.dbRetorno ?? {
          perfil_removido_em: "2026-09-26T12:00:00Z",
          dados_apagados_ate: "2026-10-11",
          turnos_cancelados: 1,
        },
      });
    },
  };

  return {
    fetchFn: fetchFn as typeof fetch,
    sqlClient,
    supabaseUrl: MOCK_URL,
    anonKey: MOCK_ANON,
    serviceRoleKey: MOCK_SERVICE_ROLE,
    dbUrl: MOCK_DB_URL,
  };
}

Deno.test("recusa método que não seja POST (405)", async () => {
  const resposta = await handler(new Request("http://localhost", { method: "GET" }));
  assertEquals(resposta.status, 405);
  const corpo = await resposta.json();
  assertEquals(corpo.code, "metodo_nao_permitido");
});

Deno.test("recusa POST sem token Bearer (401)", async () => {
  const resposta = await handler(new Request("http://localhost", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ confirmar: true }),
  }));
  assertEquals(resposta.status, 401);
  const corpo = await resposta.json();
  assertEquals(corpo.code, "nao_autenticado");
});

Deno.test("exige campo confirmar como true (422)", async () => {
  const respostaFalso = await handler(new Request("http://localhost", {
    method: "POST",
    headers: {
      Authorization: "Bearer token-teste",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ confirmar: false }),
  }));
  assertEquals(respostaFalso.status, 422);

  const respostaSemCorpo = await handler(new Request("http://localhost", {
    method: "POST",
    headers: {
      Authorization: "Bearer token-teste",
      "Content-Type": "application/json",
    },
    body: "{}",
  }));
  assertEquals(respostaSemCorpo.status, 422);
});

Deno.test("recusa token rejeitado pelo Supabase Auth (401)", async () => {
  const deps = mockDeps({ authOk: false });
  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        Authorization: "Bearer token-expirado",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ confirmar: true }),
    }),
    deps,
  );
  assertEquals(resposta.status, 401);
  const corpo = await resposta.json();
  assertEquals(corpo.code, "nao_autenticado");
});

Deno.test("propaga conflito 409 administrador_unico", async () => {
  const deps = mockDeps({
    dbErro: {
      code: "PGRST",
      message: JSON.stringify({
        code: "administrador_unico",
        message: "administrador_unico",
        details: null,
      }),
      detail: JSON.stringify({ status: 409, headers: {} }),
    },
  });

  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        Authorization: "Bearer token-valido",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ confirmar: true }),
    }),
    deps,
  );

  assertEquals(resposta.status, 409);
  const corpo = await resposta.json();
  assertEquals(corpo.code, "administrador_unico");
});

Deno.test("sucesso: executa exclusão no banco, apaga credencial em auth.users e retorna 202", async () => {
  let chamouAdminDelete = false;
  const deps = mockDeps({
    onAdminDelete: () => {
      chamouAdminDelete = true;
    },
    dbRetorno: {
      perfil_removido_em: "2026-09-26T12:00:00Z",
      dados_apagados_ate: "2026-10-11",
      turnos_cancelados: 2,
    },
  });

  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        Authorization: "Bearer token-valido",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ confirmar: true }),
    }),
    deps,
  );

  assertEquals(resposta.status, 202);
  const corpo = await resposta.json();
  assertEquals(corpo.turnos_cancelados, 2);
  assertEquals(corpo.dados_apagados_ate, "2026-10-11");
  assertEquals(corpo.perfil_removido_em, "2026-09-26T12:00:00Z");
  assertEquals(chamouAdminDelete, true);
});

Deno.test("idempotência: segunda chamada após falha 502 no Admin API apaga credencial em auth.users e retorna 202", async () => {
  let adminTentativas = 0;
  let apagouNoAuth = false;

  // Primeira chamada: banco ok (anonimiza), mas Admin API falha com 502
  const deps1 = mockDeps({
    adminOk: false,
    dbRetorno: {
      perfil_removido_em: "2026-09-26T12:00:00Z",
      dados_apagados_ate: "2026-10-11",
      turnos_cancelados: 1,
    },
  });

  const resposta1 = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        Authorization: "Bearer token-valido",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ confirmar: true }),
    }),
    deps1,
  );
  assertEquals(resposta1.status, 502);

  // Segunda chamada (retentativa): banco vê estado anonimizada, não dá erro e retorna turnos_cancelados = 0;
  // Admin API agora funciona e apaga a credencial com 202.
  const deps2 = mockDeps({
    adminOk: true,
    onAdminDelete: () => {
      apagouNoAuth = true;
      adminTentativas++;
    },
    dbRetorno: {
      perfil_removido_em: "2026-09-26T12:00:00Z",
      dados_apagados_ate: "2026-10-11",
      turnos_cancelados: 0,
    },
  });

  const resposta2 = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        Authorization: "Bearer token-valido",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ confirmar: true }),
    }),
    deps2,
  );
  assertEquals(resposta2.status, 202);
  const corpo2 = await resposta2.json();
  assertEquals(corpo2.turnos_cancelados, 0);
  assertEquals(apagouNoAuth, true);
  assertEquals(adminTentativas, 1);
});

Deno.test("idempotência: conta autenticada sem registro em public.usuario apaga credencial em auth.users e retorna 202", async () => {
  let chamouAdmin = false;
  const deps = mockDeps({
    adminOk: true,
    onAdminDelete: () => {
      chamouAdmin = true;
    },
    dbRetorno: {
      perfil_removido_em: "2026-09-26T12:00:00Z",
      dados_apagados_ate: "2026-10-11",
      turnos_cancelados: 0,
    },
  });

  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        Authorization: "Bearer token-valido",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ confirmar: true }),
    }),
    deps,
  );

  assertEquals(resposta.status, 202);
  const corpo = await resposta.json();
  assertEquals(corpo.turnos_cancelados, 0);
  assertEquals(chamouAdmin, true);
});

Deno.test("falha no Admin API apagar auth.users devolve 502", async () => {
  const deps = mockDeps({ adminOk: false });
  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        Authorization: "Bearer token-valido",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ confirmar: true }),
    }),
    deps,
  );
  assertEquals(resposta.status, 502);
  const corpo = await resposta.json();
  assertEquals(corpo.code, "erro_interno");
});

Deno.test("falha fechado sem variáveis de ambiente obrigatórias", async () => {
  await assertRejects(
    () =>
      handler(
        new Request("http://localhost", {
          method: "POST",
          headers: {
            Authorization: "Bearer token-valido",
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ confirmar: true }),
        }),
        {
          fetchFn: (() => Promise.resolve(new Response("ok"))) as typeof fetch,
          supabaseUrl: "",
        },
      ),
    Error,
    "SUPABASE_URL é obrigatório",
  );
});

Deno.test("mapeamento de erros do banco: tratarErroBanco lida com PGRST e erros genéricos", async () => {
  // 1. Erro PGRST com status 409
  const erroPg409 = {
    code: "PGRST",
    message: JSON.stringify({ code: "administrador_unico", message: "administrador_unico", details: null }),
    detail: JSON.stringify({ status: 409, headers: {} }),
  };
  const resp409 = tratarErroBanco(erroPg409);
  assertEquals(resp409.status, 409);
  const corpo409 = await resp409.json();
  assertEquals(corpo409.code, "administrador_unico");

  // 2. Erro PGRST sem detail numérico cai no default 400
  const erroPgSemStatus = {
    code: "PGRST",
    message: JSON.stringify({ code: "invalido", message: "invalido", details: null }),
    detail: "not a json",
  };
  const respSemStatus = tratarErroBanco(erroPgSemStatus);
  assertEquals(respSemStatus.status, 400);

  // 3. Erro genérico de conexão/banco devolve 500 erro_interno
  const erroGenerico = new Error("Connection terminated");
  const resp500 = tratarErroBanco(erroGenerico);
  assertEquals(resp500.status, 500);
  const corpo500 = await resp500.json();
  assertEquals(corpo500.code, "erro_interno");
});
