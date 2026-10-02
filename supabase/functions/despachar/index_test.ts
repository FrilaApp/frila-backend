import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { handler, obterDbUrl, SqlClient } from "./index.ts";

const SEGREDO_TESTE = "teste-segredo-agendador-despachar";

function criarMockSqlClient(opcoes: {
  despacharVaga?: (
    vagaId: string,
    motivo: string | null,
    excluirConta: string | null,
  ) => Promise<number>;
  processarFilaDespacho?: (
    limite: number,
    vt: number,
  ) => Promise<Array<Record<string, unknown>>>;
} = {}): SqlClient {
  return {
    despacharVaga:
      opcoes.despacharVaga ??
      ((_vagaId, _motivo, _excluirConta) => Promise.resolve(1)),
    processarFilaDespacho:
      opcoes.processarFilaDespacho ??
      ((_limite, _vt) =>
        Promise.resolve([
          { msg_id: 1, vaga_id: "a1000000-0000-4000-8000-000000000001", sucesso: true, despachos: 2, erro: null },
        ])),
  };
}

Deno.test("despachar: recusa métodos que não sejam POST com 405", async () => {
  const metodos = ["GET", "PUT", "DELETE", "PATCH"];
  for (const m of metodos) {
    const req = new Request("http://localhost/functions/v1/despachar", {
      method: m,
      headers: { "x-agendador-secret": SEGREDO_TESTE },
    });
    const res = await handler(req, { agendadorSecret: SEGREDO_TESTE });
    assertEquals(res.status, 405);
    const json = await res.json();
    assertEquals(json.ok, false);
    assertEquals(json.erro, "metodo_nao_permitido");
  }
});

Deno.test("despachar: recusa requisição sem autenticação válida com 401", async () => {
  const reqSemHeader = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({}),
  });
  const resSemHeader = await handler(reqSemHeader, { agendadorSecret: SEGREDO_TESTE });
  assertEquals(resSemHeader.status, 401);
  const jsonSem = await resSemHeader.json();
  assertEquals(jsonSem.ok, false);
  assertEquals(jsonSem.erro, "nao_autorizado");

  const reqHeaderInvalido = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": "segredo-incorreto",
    },
    body: JSON.stringify({}),
  });
  const resHeaderInvalido = await handler(reqHeaderInvalido, { agendadorSecret: SEGREDO_TESTE });
  assertEquals(resHeaderInvalido.status, 401);
});

Deno.test("despachar: aceita autenticação via Bearer token", async () => {
  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${SEGREDO_TESTE}`,
    },
    body: JSON.stringify({}),
  });
  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: criarMockSqlClient(),
  });
  assertEquals(res.status, 200);
});

Deno.test("despachar: lança erro se AGENDADOR_SECRET não estiver configurado", async () => {
  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({}),
  });

  const segredoAntigo = Deno.env.get("AGENDADOR_SECRET");
  try {
    Deno.env.delete("AGENDADOR_SECRET");
    await assertRejects(
      async () => {
        await handler(req, { agendadorSecret: "" });
      },
      Error,
      "AGENDADOR_SECRET é obrigatório",
    );
  } finally {
    if (segredoAntigo !== undefined) {
      Deno.env.set("AGENDADOR_SECRET", segredoAntigo);
    }
  }
});

// Hardening B7: Validação de UUID para vaga_id e excluir_conta
Deno.test("kT7NhMGV / B7: despachar recusa vaga_id malformado com 422 campo_invalido", async () => {
  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ vaga_id: "invalido-12345" }),
  });

  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: criarMockSqlClient(),
  });

  assertEquals(res.status, 422);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.erro, "campo_invalido");
  assertEquals(json.campo, "vaga_id");
});

Deno.test("kT7NhMGV / B7: despachar recusa excluir_conta malformado com 422 campo_invalido", async () => {
  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({
      vaga_id: "a1000000-0000-4000-8000-000000000001",
      excluir_conta: "nao-e-um-uuid",
    }),
  });

  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: criarMockSqlClient(),
  });

  assertEquals(res.status, 422);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.erro, "campo_invalido");
  assertEquals(json.campo, "excluir_conta");
});

// Hardening B3: Remoção de fallbacks locais e exigência de URL de banco
Deno.test("kT7NhMGV / B3: obterDbUrl exige SUPABASE_DB_URL ou DATABASE_URL e remove fallbacks locais", () => {
  const dbUrlAntiga = Deno.env.get("SUPABASE_DB_URL");
  const dUrlAntiga = Deno.env.get("DATABASE_URL");

  try {
    Deno.env.delete("SUPABASE_DB_URL");
    Deno.env.delete("DATABASE_URL");

    assertThrows(
      () => obterDbUrl(),
      Error,
      "SUPABASE_DB_URL ou DATABASE_URL é obrigatório",
    );

    Deno.env.set("DATABASE_URL", "postgresql://usuario:senha@host-custom:5432/db");
    assertEquals(obterDbUrl(), "postgresql://usuario:senha@host-custom:5432/db");

    Deno.env.set("SUPABASE_DB_URL", "postgresql://supabase:secret@supabase-host:5432/db");
    assertEquals(obterDbUrl(), "postgresql://supabase:secret@supabase-host:5432/db");

    assertEquals(obterDbUrl("postgresql://injetada:senha@injetada-host:5432/db"), "postgresql://injetada:senha@injetada-host:5432/db");
  } finally {
    if (dbUrlAntiga !== undefined) Deno.env.set("SUPABASE_DB_URL", dbUrlAntiga);
    else Deno.env.delete("SUPABASE_DB_URL");
    if (dUrlAntiga !== undefined) Deno.env.set("DATABASE_URL", dUrlAntiga);
    else Deno.env.delete("DATABASE_URL");
  }
});

// Hardening B4: Respostas de erro sem detalhes internos/stacks
Deno.test("kT7NhMGV / B4: erro de conexao com banco retorna 500 sem vazar detalhe interno", async () => {
  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({}),
  });

  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    dbUrl: "", // Força erro em obterDbUrl ao instanciar criarSqlClient
  });

  assertEquals(res.status, 500);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.erro, "erro_conexao_banco");
  assertEquals(json.detalhe, undefined, "detalhe interno com stack não deve existir");
});

Deno.test("kT7NhMGV / B4: erro durante execucao de sqlClient retorna 500 sem vazar detalhe interno", async () => {
  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ vaga_id: "a1000000-0000-4000-8000-000000000001" }),
  });

  const mockSql = criarMockSqlClient({
    despacharVaga: () => Promise.reject(new Error("falha interna no postgres com credenciais postgres://...")),
  });

  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: mockSql,
  });

  assertEquals(res.status, 500);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.erro, "falha_processamento");
  assertEquals(json.detalhe, undefined, "detalhe interno com stack não deve existir");
});

// Operações normais (vaga_id específico e processamento em lote da fila)
Deno.test("despachar: dispara despacho pontual de vaga com sucesso", async () => {
  let chamadaRecebida: { vagaId: string; motivo: string | null; excluirConta: string | null } | null = null;
  const mockSql = criarMockSqlClient({
    despacharVaga: (vagaId, motivo, excluirConta) => {
      chamadaRecebida = { vagaId, motivo, excluirConta };
      return Promise.resolve(3);
    },
  });

  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({
      vaga_id: "a1000000-0000-4000-8000-000000000001",
      motivo: "urgente",
      excluir_conta: "a2000000-0000-4000-8000-000000000002",
    }),
  });

  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: mockSql,
  });

  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.ok, true);
  assertEquals(json.vaga_id, "a1000000-0000-4000-8000-000000000001");
  assertEquals(json.despachos, 3);
  assertEquals(json.origem, "pontual");
  assertEquals(chamadaRecebida, {
    vagaId: "a1000000-0000-4000-8000-000000000001",
    motivo: "urgente",
    excluirConta: "a2000000-0000-4000-8000-000000000002",
  });
});

Deno.test("despachar: processa lote da fila com sucesso quando vaga_id omitido", async () => {
  let chamadaFila: { limite: number; vt: number } | null = null;
  const mockSql = criarMockSqlClient({
    processarFilaDespacho: (limite, vt) => {
      chamadaFila = { limite, vt };
      return Promise.resolve([
        { msg_id: 1, vaga_id: "a1000000-0000-4000-8000-000000000001", sucesso: true, despachos: 2, erro: null },
        { msg_id: 2, vaga_id: "a1000000-0000-4000-8000-000000000002", sucesso: true, despachos: 1, erro: null },
      ]);
    },
  });

  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ limite: 25, vt: 60 }),
  });

  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: mockSql,
  });

  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.ok, true);
  assertEquals(json.processados, 2);
  assertEquals(json.despachos, 3);
  assertEquals(json.mensagens.length, 2);
  assertEquals(chamadaFila, { limite: 25, vt: 60 });
});

Deno.test("despachar: erro ao conectar ao banco responde 500 erro_conexao_banco", async () => {
  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ vaga_id: "a1000000-0000-4000-8000-000000000001" }),
  });

  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    dbUrl: "", // Força obterDbUrl a lançar erro
  });

  assertEquals(res.status, 500);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.erro, "erro_conexao_banco");
});

Deno.test("despachar: falha no sqlClient ao despachar vaga responde 500 falha_processamento", async () => {
  const mockSql = criarMockSqlClient({
    despacharVaga: () => Promise.reject(new Error("falha_postgres_pontual")),
  });

  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ vaga_id: "a1000000-0000-4000-8000-000000000001" }),
  });

  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: mockSql,
  });

  assertEquals(res.status, 500);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.erro, "falha_processamento");
});

Deno.test("despachar: falha no sqlClient ao processar fila responde 500 falha_processamento", async () => {
  const mockSql = criarMockSqlClient({
    processarFilaDespacho: () => Promise.reject(new Error("falha_postgres_fila")),
  });

  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({}),
  });

  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: mockSql,
  });

  assertEquals(res.status, 500);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.erro, "falha_processamento");
});

Deno.test("despachar: preserva campo origem customizado no disparo pontual", async () => {
  const mockSql = criarMockSqlClient({
    despacharVaga: () => Promise.resolve(4),
  });

  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({
      vaga_id: "a1000000-0000-4000-8000-000000000001",
      origem: "reabertura_automatica",
    }),
  });

  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: mockSql,
  });

  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.ok, true);
  assertEquals(json.origem, "reabertura_automatica");
  assertEquals(json.despachos, 4);
});

