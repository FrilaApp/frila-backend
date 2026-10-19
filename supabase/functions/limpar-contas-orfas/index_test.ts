import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.19";
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

Deno.test("recusa chamada via Bearer token (exige exclusivamente header x-agendador-secret) (401)", async () => {
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

  assertEquals(resposta.status, 401);
  const corpo = await resposta.json();
  assertEquals(corpo.code, "nao_autenticado");
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

Deno.test("falha fechado sem SUPABASE_DB_URL no ambiente", async () => {
  await assertRejects(
    () =>
      handler(
        new Request("http://localhost", {
          method: "POST",
          headers: {
            "x-agendador-secret": MOCK_SECRET,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({}),
        }),
        {
          agendadorSecret: MOCK_SECRET,
          supabaseUrl: MOCK_URL,
          serviceRoleKey: MOCK_SERVICE_ROLE,
          dbUrl: "",
        },
      ),
    Error,
    "SUPABASE_DB_URL é obrigatório",
  );
});

Deno.test("falha fechado sem AGENDADOR_SECRET no ambiente", async () => {
  await assertRejects(
    () =>
      handler(
        new Request("http://localhost", {
          method: "POST",
          headers: {
            "x-agendador-secret": MOCK_SECRET,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({}),
        }),
        {
          agendadorSecret: "",
          supabaseUrl: MOCK_URL,
          serviceRoleKey: MOCK_SERVICE_ROLE,
          dbUrl: MOCK_DB_URL,
        },
      ),
    Error,
    "AGENDADOR_SECRET é obrigatório",
  );
});

Deno.test("falha fechado sem SUPABASE_URL no ambiente", async () => {
  await assertRejects(
    () =>
      handler(
        new Request("http://localhost", {
          method: "POST",
          headers: {
            "x-agendador-secret": MOCK_SECRET,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({}),
        }),
        {
          agendadorSecret: MOCK_SECRET,
          supabaseUrl: "",
          serviceRoleKey: MOCK_SERVICE_ROLE,
          dbUrl: MOCK_DB_URL,
        },
      ),
    Error,
    "SUPABASE_URL é obrigatório",
  );
});

Deno.test("falha fechado sem SUPABASE_SERVICE_ROLE_KEY no ambiente", async () => {
  await assertRejects(
    () =>
      handler(
        new Request("http://localhost", {
          method: "POST",
          headers: {
            "x-agendador-secret": MOCK_SECRET,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({}),
        }),
        {
          agendadorSecret: MOCK_SECRET,
          supabaseUrl: MOCK_URL,
          serviceRoleKey: "",
          dbUrl: MOCK_DB_URL,
        },
      ),
    Error,
    "SUPABASE_SERVICE_ROLE_KEY é obrigatório",
  );
});

Deno.test("trava parâmetro horas em no mínimo 24 horas", async () => {
  let horasConsultadas: number | null = null;
  const deps = mockDeps({});
  deps.sqlClient = {
    contasOrfas: (h: number) => {
      horasConsultadas = h;
      return Promise.resolve([]);
    },
    executarRetencao: () => Promise.resolve({}),
  };

  // 1. Testa com horas = 0.5 (deve travar em 24)
  await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        "x-agendador-secret": MOCK_SECRET,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ horas: 0.5 }),
    }),
    deps,
  );
  assertEquals(horasConsultadas, 24);

  // 2. Testa com horas = 1 (deve travar em 24)
  await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        "x-agendador-secret": MOCK_SECRET,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ horas: 1 }),
    }),
    deps,
  );
  assertEquals(horasConsultadas, 24);

  // 3. Testa com horas = 48 (deve respeitar 48)
  await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        "x-agendador-secret": MOCK_SECRET,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ horas: 48 }),
    }),
    deps,
  );
  assertEquals(horasConsultadas, 48);
});

Deno.test("falha ao consultar contas órfãs no banco responde 500 erro_ao_consultar_contas_orfas", async () => {
  const deps = mockDeps({ dbErro: true });
  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        "x-agendador-secret": MOCK_SECRET,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    }),
    deps,
  );

  assertEquals(resposta.status, 500);
  const corpo = await resposta.json();
  assertEquals(corpo.code, "erro_interno");
  assertEquals(corpo.message, "erro_ao_consultar_contas_orfas");
});

Deno.test("respeita executar_retencao_banco como false e não executa retenção", async () => {
  let retencaoChamada = false;
  const deps = mockDeps({});
  deps.sqlClient = {
    contasOrfas: () => Promise.resolve([]),
    executarRetencao: () => {
      retencaoChamada = true;
      return Promise.resolve({});
    },
  };

  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        "x-agendador-secret": MOCK_SECRET,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ executar_retencao_banco: false }),
    }),
    deps,
  );

  assertEquals(resposta.status, 200);
  const corpo = await resposta.json();
  assertEquals(corpo.ok, true);
  assertEquals(retencaoChamada, false);
  assertEquals(corpo.retencao_banco, null);
});

Deno.test("falha na retenção do banco não impede resposta de sucesso das contas órfãs", async () => {
  const deps = mockDeps({});
  deps.sqlClient = {
    contasOrfas: () => Promise.resolve([ORFAO_1]),
    executarRetencao: () => Promise.reject(new Error("falha_banco_retencao")),
  };

  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        "x-agendador-secret": MOCK_SECRET,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ executar_retencao_banco: true }),
    }),
    deps,
  );

  assertEquals(resposta.status, 200);
  const corpo = await resposta.json();
  assertEquals(corpo.ok, true);
  assertEquals(corpo.contas_orfas_removidas, 1);
  assertEquals(corpo.retencao_banco, { erro: "falha_ao_executar_retencao" });
});

Deno.test("lida com exceção de rede no fetch do admin registrando erro status 500", async () => {
  const deps = mockDeps({});
  deps.fetchFn = () => Promise.reject(new TypeError("network_failure"));

  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        "x-agendador-secret": MOCK_SECRET,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    }),
    deps,
  );

  assertEquals(resposta.status, 200);
  const corpo = await resposta.json();
  assertEquals(corpo.ok, true);
  assertEquals(corpo.contas_orfas_encontradas, 2);
  assertEquals(corpo.contas_orfas_removidas, 0);
  assertEquals(corpo.erros_remocao.length, 2);
  assertEquals(corpo.erros_remocao[0].status, 500);
});

// ── Lacuna 4: Caracterização de Paginação e Volume da Admin API ───────────────

Deno.test("limpar-contas-orfas: processa volume acima de 50 contas (tamanho de pagina padrao da Admin API) sem truncamento", async () => {
  // Caracterização da arquitetura:
  // A Edge Function NÃO consome GET /auth/v1/admin/users (que sofreria truncamento
  // na paginação padrão de 50 usuários do Supabase Auth). Em vez disso, a fonte da verdade
  // é a consulta privada no PostgreSQL (privado.contas_auth_orfas), que retorna a totalidade
  // das contas elegíveis, sendo todas purgadas individualmente via DELETE na Admin API.
  const TOTAL_CONTAS = 65;
  const contasOrfasMuitas: string[] = [];
  for (let i = 1; i <= TOTAL_CONTAS; i++) {
    const hex = i.toString().padStart(12, "0");
    contasOrfasMuitas.push(`c3200000-0000-4000-8000-${hex}`);
  }

  const removidosIds: string[] = [];
  const deps = mockDeps({
    contasOrfas: contasOrfasMuitas,
    onDeleteUser: (id) => removidosIds.push(id),
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
    deps,
  );

  assertEquals(resposta.status, 200);
  const corpo = await resposta.json();
  assertEquals(corpo.ok, true);
  assertEquals(corpo.contas_orfas_encontradas, TOTAL_CONTAS);
  assertEquals(corpo.contas_orfas_removidas, TOTAL_CONTAS);
  assertEquals(removidosIds.length, TOTAL_CONTAS);
  assertEquals(corpo.erros_remocao.length, 0);
});

Deno.test("limpar-contas-orfas: lida com erro 429 Too Many Requests da Admin API registrando em erros_remocao sem abortar lote", async () => {
  const ID_RATE_LIMITED = "c3200000-0000-4000-8000-000000000099";
  const contas = [ORFAO_1, ID_RATE_LIMITED, ORFAO_2];
  const removidosIds: string[] = [];

  const deps = mockDeps({
    contasOrfas: contas,
    onDeleteUser: (id) => removidosIds.push(id),
  });

  // Sobrescreve fetchFn para simular 429 Rate Limit no usuário alvo
  const originalFetch = deps.fetchFn;
  deps.fetchFn = (input, init) => {
    const urlStr = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (urlStr.includes(ID_RATE_LIMITED)) {
      return Promise.resolve(new Response(JSON.stringify({ message: "Too many requests" }), { status: 429 }));
    }
    return originalFetch!(input, init);
  };

  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        "x-agendador-secret": MOCK_SECRET,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    }),
    deps,
  );

  assertEquals(resposta.status, 200);
  const corpo = await resposta.json();
  assertEquals(corpo.ok, true);
  assertEquals(corpo.contas_orfas_encontradas, 3);
  assertEquals(corpo.contas_orfas_removidas, 2);
  assertEquals(removidosIds, [ORFAO_1, ORFAO_2]);
  assertEquals(corpo.erros_remocao.length, 1);
  assertEquals(corpo.erros_remocao[0], { id: ID_RATE_LIMITED, status: 429 });
});

Deno.test("limpar-contas-orfas: contabilidade precisa em lote heterogeneo com falhas de rede e HTTP variadas", async () => {
  const ID_404 = "c3200000-0000-4000-8000-000000000404";
  const ID_TIMEOUT = "c3200000-0000-4000-8000-000000000504";
  const contas = [ORFAO_1, ID_404, ORFAO_2, ID_TIMEOUT];

  const deps = mockDeps({ contasOrfas: contas });
  const originalFetch = deps.fetchFn;
  deps.fetchFn = (input, init) => {
    const urlStr = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (urlStr.includes(ID_404)) {
      return Promise.resolve(new Response(JSON.stringify({ error: "User not found" }), { status: 404 }));
    }
    if (urlStr.includes(ID_TIMEOUT)) {
      return Promise.reject(new TypeError("connection timeout"));
    }
    return originalFetch!(input, init);
  };

  const resposta = await handler(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        "x-agendador-secret": MOCK_SECRET,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    }),
    deps,
  );

  assertEquals(resposta.status, 200);
  const corpo = await resposta.json();
  assertEquals(corpo.ok, true);
  assertEquals(corpo.contas_orfas_encontradas, 4);
  assertEquals(corpo.contas_orfas_removidas, 2);
  assertEquals(corpo.erros_remocao.length, 2);
  assertEquals(corpo.erros_remocao[0], { id: ID_404, status: 404 });
  assertEquals(corpo.erros_remocao[1], { id: ID_TIMEOUT, status: 500 });
});


