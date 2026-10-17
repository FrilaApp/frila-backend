import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.19";
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
  ordem?: string[];
  erroAoRegistrar?: { code: string; message: string };
  timeoutMs?: number;
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
    // `ordem` registra a sequência das chamadas ao banco. O cartão SHUDSozj é sobre ordem:
    // registrar o pedido **depois** de tentar a exclusão não deixa rastro de nada.
    registrarPedido: (_userId: string) => {
      opcoes.ordem?.push("registrar");
      if (opcoes.erroAoRegistrar) {
        return Promise.reject(opcoes.erroAoRegistrar);
      }
      return Promise.resolve();
    },
    query: (_userId: string) => {
      opcoes.ordem?.push("excluir");
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
    timeoutMs: opcoes.timeoutMs,
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

Deno.test("idempotência: segunda chamada após TIMEOUT na Admin API apaga credencial em auth.users e retorna 202", async () => {
  let adminTentativas = 0;
  let apagouNoAuth = false;

  // Primeira chamada: banco ok (anonimiza), mas Admin API sofre timeout real via AbortSignal
  const deps1 = mockDeps({
    timeoutMs: 20,
    dbRetorno: {
      perfil_removido_em: "2026-09-26T12:00:00Z",
      dados_apagados_ate: "2026-10-11",
      turnos_cancelados: 1,
    },
  });
  const fetchOriginal1 = deps1.fetchFn!;
  deps1.fetchFn = (input, init) => {
    const urlStr = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (urlStr.includes(`/auth/v1/admin/users/`)) {
      return new Promise<Response>((resolve, reject) => {
        if (!init?.signal) {
          resolve(new Response(JSON.stringify({}), { status: 200 }));
          return;
        }
        if (init.signal.aborted) {
          reject(new DOMException("The signal has been aborted due to timeout.", "TimeoutError"));
          return;
        }
        init.signal.addEventListener("abort", () => {
          reject(new DOMException("The signal has been aborted due to timeout.", "TimeoutError"));
        });
      });
    }
    return fetchOriginal1(input, init);
  };

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
  const corpo1 = await resposta1.json();
  assertEquals(corpo1, { code: "erro_interno", message: "erro_interno", details: null });

  // Segunda chamada (retentativa): conta já anonimizada no Postgres, RPC retorna turnos_cancelados = 0;
  // Admin API agora responde e apaga credencial em auth.users com 202.
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

// ── SHUDSozj: o pedido de exclusão deixa rastro ───────────────────────────────
//
// O rastro só existe se o registro vier antes. `privado.excluir_conta` roda numa transação
// só; quando ela volta atrás — 40P01, medido em 6 de 50 rodadas do cenário 9 do
// corrida-ciclo.sh —, tudo que ela escreveu volta junto. Registrar depois, ou registrar
// dentro, não resolve: o pedido tem de estar comitado antes de a exclusão ser tentada.

Deno.test("SHUDSozj: o pedido é registrado antes de a exclusão ser tentada", async () => {
  const ordem: string[] = [];
  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: { Authorization: "Bearer token-valido", "Content-Type": "application/json" },
      body: JSON.stringify({ confirmar: true }),
    }),
    mockDeps({ ordem }),
  );
  assertEquals(resposta.status, 202);
  assertEquals(ordem, ["registrar", "excluir"]);
});

Deno.test("SHUDSozj: exclusão que volta atrás não desfaz o registro do pedido", async () => {
  const ordem: string[] = [];
  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: { Authorization: "Bearer token-valido", "Content-Type": "application/json" },
      body: JSON.stringify({ confirmar: true }),
    }),
    mockDeps({ ordem, dbErro: { code: "40P01", message: "deadlock detected" } }),
  );
  // O titular recebe erro, como antes. A diferença é que o pedido já ficou registrado.
  assertEquals(resposta.status >= 400, true);
  assertEquals(ordem, ["registrar", "excluir"]);
});

Deno.test("SHUDSozj: sem conseguir registrar o pedido, a exclusão não é tentada", async () => {
  const ordem: string[] = [];
  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: { Authorization: "Bearer token-valido", "Content-Type": "application/json" },
      body: JSON.stringify({ confirmar: true }),
    }),
    mockDeps({ ordem, erroAoRegistrar: { code: "53300", message: "too many connections" } }),
  );
  // Falha fechado de propósito: excluir sem rastro é o defeito que este cartão conserta.
  assertEquals(resposta.status, 500);
  assertEquals((await resposta.json()).code, "erro_interno");
  assertEquals(ordem, ["registrar"]);
});

// ── Lacuna 2: Resiliência a timeout e falhas de rede no Auth e Admin API ───────

Deno.test("resiliência: timeout na Admin API (DELETE auth.users) retorna 502 erro_interno sem quebrar processo", async () => {
  const deps = mockDeps({
    timeoutMs: 20,
  });
  const fetchOriginal = deps.fetchFn!;
  deps.fetchFn = (input, init) => {
    const urlStr = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (urlStr.includes(`/auth/v1/admin/users/`)) {
      return new Promise<Response>((resolve, reject) => {
        // Se a mutação remover signal: AbortSignal.timeout(timeoutMs), resolve com 200 fazendo o teste falhar (esperava 502, recebe 202)
        if (!init?.signal) {
          resolve(new Response(JSON.stringify({}), { status: 200 }));
          return;
        }
        if (init.signal.aborted) {
          reject(new DOMException("The signal has been aborted due to timeout.", "TimeoutError"));
          return;
        }
        init.signal.addEventListener("abort", () => {
          reject(new DOMException("The signal has been aborted due to timeout.", "TimeoutError"));
        });
      });
    }
    return fetchOriginal(input, init);
  };

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
  assertEquals(corpo, { code: "erro_interno", message: "erro_interno", details: null });
});

Deno.test("resiliência: erro de rede na Admin API retorna 502 erro_interno sem vazar detalhes", async () => {
  const deps = mockDeps({});
  const fetchOriginal = deps.fetchFn!;
  deps.fetchFn = (input, init) => {
    const urlStr = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (urlStr.includes(`/auth/v1/admin/users/`)) {
      return Promise.reject(new TypeError("fetch failed: connection reset by peer"));
    }
    return fetchOriginal(input, init);
  };

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
  assertEquals(corpo, { code: "erro_interno", message: "erro_interno", details: null });
});

Deno.test("resiliência: timeout ao validar token em /auth/v1/user retorna 502 erro_interno", async () => {
  let chamouRegistrar = false;
  const deps = mockDeps({
    timeoutMs: 20,
  });
  deps.sqlClient = {
    ...deps.sqlClient!,
    registrarPedido: (_id) => {
      chamouRegistrar = true;
      return Promise.resolve();
    },
  };
  deps.fetchFn = (input, init) => {
    const urlStr = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (urlStr.includes("/auth/v1/user")) {
      return new Promise<Response>((resolve, reject) => {
        // Se a mutação remover signal: AbortSignal.timeout(timeoutMs), resolve com 200 retornando usuário válido
        if (!init?.signal) {
          resolve(new Response(JSON.stringify({ id: MOCK_USER_ID }), { status: 200 }));
          return;
        }
        if (init.signal.aborted) {
          reject(new DOMException("The signal has been aborted due to timeout.", "TimeoutError"));
          return;
        }
        init.signal.addEventListener("abort", () => {
          reject(new DOMException("The signal has been aborted due to timeout.", "TimeoutError"));
        });
      });
    }
    // Sob mutação (sem signal no /auth/v1/user), o handler avança até o DELETE que responde 200, retornando 202
    if (urlStr.includes("/auth/v1/admin/users/")) {
      return Promise.resolve(new Response("{}", { status: 200 }));
    }
    return Promise.resolve(new Response("Not Found", { status: 404 }));
  };

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
  assertEquals(corpo, { code: "erro_interno", message: "erro_interno", details: null });
  assertEquals(chamouRegistrar, false, "Sob timeout em /auth/v1/user, a execução não deve chegar ao registrarPedido");
});

Deno.test("resiliência: erro de rede ao validar token em /auth/v1/user retorna 502 erro_interno", async () => {
  let chamouRegistrar = false;
  const deps = mockDeps({});
  deps.sqlClient = {
    ...deps.sqlClient!,
    registrarPedido: (_id) => {
      chamouRegistrar = true;
      return Promise.resolve();
    },
  };
  deps.fetchFn = (input, _init) => {
    const urlStr = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (urlStr.includes("/auth/v1/user")) {
      return Promise.reject(new TypeError("fetch failed: DNS lookup failed"));
    }
    if (urlStr.includes("/auth/v1/admin/users/")) {
      return Promise.resolve(new Response("{}", { status: 200 }));
    }
    return Promise.resolve(new Response("Not Found", { status: 404 }));
  };

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
  assertEquals(corpo, { code: "erro_interno", message: "erro_interno", details: null });
  assertEquals(chamouRegistrar, false, "Sob erro de rede em /auth/v1/user, não deve registrar pedido");
});

Deno.test("resiliência: resposta malformada (JSON inválido) em /auth/v1/user retorna 502 erro_interno", async () => {
  const deps = mockDeps({});
  deps.fetchFn = (input, _init) => {
    const urlStr = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (urlStr.includes("/auth/v1/user")) {
      return Promise.resolve(
        new Response("<html>Bad Gateway from upstream proxy</html>", {
          status: 200,
          headers: { "Content-Type": "text/html" },
        }),
      );
    }
    return Promise.resolve(new Response("Not Found", { status: 404 }));
  };

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
  assertEquals(corpo, { code: "erro_interno", message: "erro_interno", details: null });
});

Deno.test("mutação: recusa Authorization fora do padrao Bearer ou sem token com 401 sem chamar Auth nem banco", async () => {
  const esquemasInvalidos = [
    "Basic dXNlcjpwYXNz",
    "Bearer",
    "Bearer ",
    "Bearer   ",
    "Token xyz",
    "Digest username=abc",
  ];

  for (const auth of esquemasInvalidos) {
    let chamouFetch = false;
    let chamouDb = false;

    const deps = mockDeps({});
    deps.fetchFn = () => {
      chamouFetch = true;
      return Promise.resolve(new Response("{}", { status: 200 }));
    };
    deps.sqlClient = {
      registrarPedido: () => {
        chamouDb = true;
        return Promise.resolve();
      },
      query: () => {
        chamouDb = true;
        return Promise.resolve({ dados: {} });
      },
    };

    const resposta = await handler(
      new Request("http://localhost", {
        method: "POST",
        headers: {
          Authorization: auth,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ confirmar: true }),
      }),
      deps,
    );

    assertEquals(resposta.status, 401, `Esquema '${auth}' deveria ser recusado com 401`);
    const corpo = await resposta.json();
    assertEquals(corpo.code, "nao_autenticado");
    assertEquals(chamouFetch, false, `Esquema '${auth}' não deve chamar Auth`);
    assertEquals(chamouDb, false, `Esquema '${auth}' não deve tocar no banco`);
  }
});

