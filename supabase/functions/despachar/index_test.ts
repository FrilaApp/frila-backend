import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1.0.19";
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

Deno.test("despachar: clamp de limite e vt protege a drenagem contra valores abusivos ou negativos", async () => {
  let limiteRecebido = 0;
  let vtRecebido = 0;

  const mockSql = criarMockSqlClient({
    processarFilaDespacho: (limite, vt) => {
      limiteRecebido = limite;
      vtRecebido = vt;
      return Promise.resolve([]);
    },
  });

  // Caso 1: Valores acima do teto máximo são limitados
  const reqMax = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ limite: 99999, vt: 99999 }),
  });
  const resMax = await handler(reqMax, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: mockSql,
  });
  assertEquals(resMax.status, 200);
  assertEquals(limiteRecebido, 100);
  assertEquals(vtRecebido, 300);

  // Caso 2: Valores negativos ou zero são elevados ao piso mínimo de 1
  const reqMin = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ limite: -10, vt: 0 }),
  });
  const resMin = await handler(reqMin, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: mockSql,
  });
  assertEquals(resMin.status, 200);
  assertEquals(limiteRecebido, 1);
  assertEquals(vtRecebido, 1);
});

Deno.test("despachar: erro ao processar loga mensagem tipada e não objeto bruto no console.error", async () => {
  const mockSql = criarMockSqlClient({
    despacharVaga: () => Promise.reject(new TypeError("falha de tipo na operacao")),
  });

  const logs: unknown[] = [];
  const originalConsoleError = console.error;
  console.error = (...args: unknown[]) => {
    logs.push(args);
  };

  try {
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

    assertEquals(logs.length, 1);
    const [prefixo, errArg] = logs[0] as [string, unknown];
    assertEquals(prefixo, "despachar: falha no processamento:");
    assertEquals(typeof errArg, "string");
    assertEquals(errArg, "TypeError: falha de tipo na operacao");
  } finally {
    console.error = originalConsoleError;
  }
});

// ── Lacuna 3: Caracterização de Resiliência e Falhas no Processamento do Lote ──

Deno.test("despachar: cancelamento de query por statement_timeout no Postgres (57014) responde 500 falha_processamento", async () => {
  const erroTimeout = Object.assign(
    new Error("canceling statement due to statement timeout"),
    { code: "57014" },
  );

  const mockSql = criarMockSqlClient({
    despacharVaga: () => Promise.reject(erroTimeout),
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

Deno.test("despachar: queda de conexao abrupta com o banco (ECONNRESET) responde 500 falha_processamento", async () => {
  const mockSql = criarMockSqlClient({
    processarFilaDespacho: () => Promise.reject(new Error("read ECONNRESET - connection reset by peer")),
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

Deno.test("despachar: falha parcial na drenagem de lote responde 200 ok:true somando apenas sucessos", async () => {
  const loteMisto = [
    { msg_id: 101, vaga_id: "a1000000-0000-4000-8000-000000000001", sucesso: true, despachos: 3, erro: null },
    { msg_id: 102, vaga_id: "a1000000-0000-4000-8000-000000000002", sucesso: false, despachos: 0, erro: "vaga_inexistente" },
    { msg_id: 103, vaga_id: "a1000000-0000-4000-8000-000000000003", sucesso: true, despachos: 2, erro: null },
  ];

  const mockSql = criarMockSqlClient({
    processarFilaDespacho: () => Promise.resolve(loteMisto),
  });

  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ limite: 10, vt: 30 }),
  });

  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: mockSql,
  });

  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.ok, true);
  assertEquals(json.processados, 3);
  assertEquals(json.despachos, 5);
  assertEquals(json.mensagens.length, 3);
  assertEquals(json.mensagens[1].sucesso, false);
  assertEquals(json.mensagens[1].erro, "vaga_inexistente");
});

Deno.test("despachar: lote com 100% de falhas devolve 200 ok:true com despachos 0 (caracterizacao do comportamento atual)", async () => {
  // Caracterização do comportamento atual da Edge Function:
  // processar_fila_despacho captura exceções individualmente por mensagem e devolve o lote;
  // a Edge Function despachar devolve HTTP 200 { ok: true, processados: N, despachos: 0 }
  // mesmo quando 100% das mensagens do lote falharam.
  // Mudar o status HTTP sob falha total do lote é decisão de produto/dono ([DONO]).
  const loteTotalmenteFalho = [
    { msg_id: 201, vaga_id: "a1000000-0000-4000-8000-000000000001", sucesso: false, despachos: 0, erro: "vaga_cancelada" },
    { msg_id: 202, vaga_id: "a1000000-0000-4000-8000-000000000002", sucesso: false, despachos: 0, erro: "deadlock_transiente" },
  ];

  const mockSql = criarMockSqlClient({
    processarFilaDespacho: () => Promise.resolve(loteTotalmenteFalho),
  });

  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ limite: 10, vt: 30 }),
  });

  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: mockSql,
  });

  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.ok, true);
  assertEquals(json.processados, 2);
  assertEquals(json.despachos, 0);
  assertEquals(json.mensagens.length, 2);
  assertEquals(json.mensagens[0].sucesso, false);
  assertEquals(json.mensagens[1].sucesso, false);
});

Deno.test("despachar: lote vazio quando nao ha mensagens pendentes responde 200 ok:true com 0 despachos", async () => {
  const mockSql = criarMockSqlClient({
    processarFilaDespacho: () => Promise.resolve([]),
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

  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.ok, true);
  assertEquals(json.processados, 0);
  assertEquals(json.despachos, 0);
  assertEquals(json.mensagens, []);
});

Deno.test("despachar: mensagem arquivada por teto excedido no banco e repassada intacta no lote", async () => {
  // Confirma que a Edge Function não inspeciona nem depende de read_ct diretamente;
  // ela repassa transparentemente mensagens arquivadas pelo banco com erro teto_tentativas_excedido.
  const loteComTetoExcedido = [
    { msg_id: 301, vaga_id: "a1000000-0000-4000-8000-000000000001", sucesso: false, despachos: 0, erro: "teto_tentativas_excedido" },
  ];

  const mockSql = criarMockSqlClient({
    processarFilaDespacho: () => Promise.resolve(loteComTetoExcedido),
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

  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.ok, true);
  assertEquals(json.processados, 1);
  assertEquals(json.despachos, 0);
  assertEquals(json.mensagens[0].erro, "teto_tentativas_excedido");
});

Deno.test("despachar: recusa metodos GET, PUT e DELETE com 405 metodo_nao_permitido", async () => {
  for (const method of ["GET", "PUT", "DELETE"]) {
    const req = new Request("http://localhost/functions/v1/despachar", {
      method,
      headers: { "x-agendador-secret": SEGREDO_TESTE },
    });
    const res = await handler(req, { agendadorSecret: SEGREDO_TESTE });
    assertEquals(res.status, 405);
    const json = await res.json();
    assertEquals(json.ok, false);
    assertEquals(json.erro, "metodo_nao_permitido");
  }
});

Deno.test("despachar: corpo com JSON quebrado nao falha e processa fila com defaults", async () => {
  const mockSql = criarMockSqlClient({
    processarFilaDespacho: () => Promise.resolve([]),
  });
  const req = new Request("http://localhost/functions/v1/despachar", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: "{ json-quebrado",
  });
  const res = await handler(req, {
    agendadorSecret: SEGREDO_TESTE,
    sqlClient: mockSql,
  });
  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.ok, true);
  assertEquals(json.processados, 0);
});


