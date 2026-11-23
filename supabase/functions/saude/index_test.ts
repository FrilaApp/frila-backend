// Testes da Edge Function saude (cartão 5bPJvMIo).
//
//   deno test --allow-all supabase/functions/saude/

import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.19";
import {
  criarSqlProbe,
  getDbUrl,
  InfoSaudeCron,
  InfoSaudeOperacional,
  processarSaude,
  SqlProbe,
} from "./index.ts";

function probeMock(opcoes: {
  ok?: boolean;
  erro?: boolean;
  jobs?: InfoSaudeCron;
  operacional?: InfoSaudeOperacional;
  operacionalLanca?: boolean;
  onRegistrarFalha?: (origem: string, codigo: string) => void;
} = {}): SqlProbe {
  return {
    ping: async () => {
      if (opcoes.erro) {
        throw new Error("Falha simulada de conexão com o banco");
      }
      return opcoes.ok ?? true;
    },
    consultarJobs: opcoes.jobs !== undefined
      ? async () => opcoes.jobs!
      : undefined,
    consultarOperacional: opcoes.operacional !== undefined || opcoes.operacionalLanca
      ? async () => {
        if (opcoes.operacionalLanca) {
          throw new Error("Falha simulada na consulta operacional");
        }
        return opcoes.operacional!;
      }
      : undefined,
    registrarFalha: async (origem: string, codigo: string) => {
      opcoes.onRegistrarFalha?.(origem, codigo);
    },
  };
}

Deno.test("saude: GET retorna 200 OK com status saudavel quando banco responde", async () => {
  const req = new Request("http://localhost/functions/v1/saude", { method: "GET" });
  const res = await processarSaude(req, { sqlProbe: probeMock({ ok: true }) });

  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.ok, true);
  assertEquals(json.status, "saudavel");
  assertEquals(typeof json.timestamp, "string");
  // RN15: Nenhum dado confidencial no payload
  assertEquals(json.senha, undefined);
  assertEquals(json.dbUrl, undefined);
});

Deno.test("saude: HEAD retorna 200 OK sem corpo quando saudavel", async () => {
  const req = new Request("http://localhost/functions/v1/saude", { method: "HEAD" });
  const res = await processarSaude(req, { sqlProbe: probeMock({ ok: true }) });

  assertEquals(res.status, 200);
  const text = await res.text();
  assertEquals(text, "");
});

Deno.test("saude: HEAD retorna 503 sem corpo quando ping retorna falso", async () => {
  const req = new Request("http://localhost/functions/v1/saude", { method: "HEAD" });
  const res = await processarSaude(req, { sqlProbe: probeMock({ ok: false }) });

  assertEquals(res.status, 503);
  const text = await res.text();
  assertEquals(text, "");
});

Deno.test("saude: HEAD retorna 503 sem corpo quando ping lanca excecao", async () => {
  const req = new Request("http://localhost/functions/v1/saude", { method: "HEAD" });
  const res = await processarSaude(req, { sqlProbe: probeMock({ erro: true }) });

  assertEquals(res.status, 503);
  const text = await res.text();
  assertEquals(text, "");
});

Deno.test("saude: metodos que nao sejam GET nem HEAD retornam 405", async () => {
  const metodos = ["POST", "PUT", "DELETE", "PATCH"];
  for (const m of metodos) {
    const req = new Request("http://localhost/functions/v1/saude", { method: m });
    const res = await processarSaude(req, { sqlProbe: probeMock() });
    assertEquals(res.status, 405);
    const json = await res.json();
    assertEquals(json.ok, false);
    assertEquals(json.erro, "metodo_nao_permitido");
  }
});

Deno.test("saude: erro de conexao com o banco retorna 503 e registra falha", async () => {
  let falhaRegistrada: { origem: string; codigo: string } | null = null;
  const probe = probeMock({
    erro: true,
    onRegistrarFalha: (origem: string, codigo: string) => {
      falhaRegistrada = { origem, codigo };
    },
  });

  const req = new Request("http://localhost/functions/v1/saude", { method: "GET" });
  const res = await processarSaude(req, { sqlProbe: probe });

  assertEquals(res.status, 503);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.status, "indisponivel");
  assertEquals(json.erro, "conexao_falhou");
  assertEquals((falhaRegistrada as any)?.origem, "saude");
  assertEquals((falhaRegistrada as any)?.codigo, "conexao_falhou");
});

Deno.test("saude: ping retornando falso devolve 503", async () => {
  let falhaRegistrada: { origem: string; codigo: string } | null = null;
  const probe = probeMock({
    ok: false,
    onRegistrarFalha: (origem: string, codigo: string) => {
      falhaRegistrada = { origem, codigo };
    },
  });

  const req = new Request("http://localhost/functions/v1/saude", { method: "GET" });
  const res = await processarSaude(req, { sqlProbe: probe });

  assertEquals(res.status, 503);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.status, "indisponivel");
  assertEquals((falhaRegistrada as any)?.codigo, "ping_banco_retornou_falso");
});

Deno.test("kT7NhMGV / B3: getDbUrl exige SUPABASE_DB_URL ou DATABASE_URL e remove fallbacks locais", () => {
  const dbUrlAntiga = Deno.env.get("SUPABASE_DB_URL");
  const dUrlAntiga = Deno.env.get("DATABASE_URL");

  try {
    Deno.env.delete("SUPABASE_DB_URL");
    Deno.env.delete("DATABASE_URL");

    assertThrows(
      () => getDbUrl(),
      Error,
      "SUPABASE_DB_URL ou DATABASE_URL é obrigatório",
    );

    Deno.env.set("DATABASE_URL", "postgresql://usuario:senha@host-custom:5432/db");
    assertEquals(getDbUrl(), "postgresql://usuario:senha@host-custom:5432/db");

    Deno.env.set("SUPABASE_DB_URL", "postgresql://supabase:secret@supabase-host:5432/db");
    assertEquals(getDbUrl(), "postgresql://supabase:secret@supabase-host:5432/db");

    assertEquals(getDbUrl("postgresql://injetada:senha@injetada-host:5432/db"), "postgresql://injetada:senha@injetada-host:5432/db");
  } finally {
    if (dbUrlAntiga !== undefined) Deno.env.set("SUPABASE_DB_URL", dbUrlAntiga);
    else Deno.env.delete("SUPABASE_DB_URL");
    if (dUrlAntiga !== undefined) Deno.env.set("DATABASE_URL", dUrlAntiga);
    else Deno.env.delete("DATABASE_URL");
  }
});

// ── Lacuna 10: Resiliência a falhas/timeouts no probe SQL ─────────────────────
// Nota: index.ts não possui timeout de consulta próprio (apenas connect_timeout: 3).
// Rejeições no ping (seja por timeout de statement 57014 ou erro de rede) são tratadas pelo handler.

Deno.test("saude: ping rejeitado com 57014 (statement_timeout simulado) responde 503 indisponivel com erro conexao_falhou", async () => {
  let falhaRegistrada: { origem: string; codigo: string } | null = null;
  const erroTimeout = Object.assign(
    new Error("canceling statement due to statement timeout"),
    { code: "57014" },
  );

  const probe: SqlProbe = {
    ping: () => Promise.reject(erroTimeout),
    registrarFalha: async (origem: string, codigo: string) => {
      falhaRegistrada = { origem, codigo };
    },
  };

  const req = new Request("http://localhost/functions/v1/saude", { method: "GET" });
  const res = await processarSaude(req, { sqlProbe: probe });

  assertEquals(res.status, 503);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.status, "indisponivel");
  assertEquals(json.erro, "conexao_falhou");
  assertEquals(falhaRegistrada, { origem: "saude", codigo: "conexao_falhou" });
});

Deno.test("saude: HEAD com ping rejeitado (ex.: timeout) responde 503 sem corpo", async () => {
  const probe: SqlProbe = {
    ping: () => Promise.reject(new DOMException("The operation timed out.", "TimeoutError")),
  };

  const req = new Request("http://localhost/functions/v1/saude", { method: "HEAD" });
  const res = await processarSaude(req, { sqlProbe: probe });

  assertEquals(res.status, 503);
  const text = await res.text();
  assertEquals(text, "");
});

Deno.test("saude: criarSqlProbe real possui silencio defensivo em registrarFalha sob banco inacessivel", async () => {
  // Exercita a implementação REAL de criarSqlProbe com endpoint inacessível (127.0.0.1:1).
  // O probe falha em ping() e em registrarFalha(), mas graças ao silêncio defensivo
  // (try/catch em registrarFalha) não lança exceção não tratada e o handler responde 503.
  const probe = criarSqlProbe("postgres://u:p@127.0.0.1:1/db");
  const req = new Request("http://localhost/functions/v1/saude", { method: "GET" });
  const res = await processarSaude(req, { sqlProbe: probe });

  assertEquals(res.status, 503);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.status, "indisponivel");
  assertEquals(json.erro, "conexao_falhou");
});

Deno.test("mutação: saude inclui header Cache-Control no-store para evitar cache de status por proxies ou CDN (RNF12)", async () => {
  // 1. Em 200 OK
  const reqGet = new Request("http://localhost/functions/v1/saude", { method: "GET" });
  const resOk = await processarSaude(reqGet, { sqlProbe: probeMock({ ok: true }) });
  assertEquals(resOk.status, 200);
  assertEquals(resOk.headers.get("Cache-Control"), "no-store, no-cache, must-revalidate");
  assertEquals(resOk.headers.get("Content-Type"), "application/json");

  const jsonOk = await resOk.json();
  assertEquals(typeof jsonOk.timestamp, "string");
  assertEquals(isNaN(Date.parse(jsonOk.timestamp)), false);
  assertEquals(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(jsonOk.timestamp), true);

  // 2. Em 503 Indisponível (ping falso)
  const res503Falso = await processarSaude(reqGet, { sqlProbe: probeMock({ ok: false }) });
  assertEquals(res503Falso.status, 503);
  assertEquals(res503Falso.headers.get("Cache-Control"), "no-store, no-cache, must-revalidate");

  // 3. Em 503 Indisponível (erro de conexão)
  const res503Erro = await processarSaude(reqGet, { sqlProbe: probeMock({ erro: true }) });
  assertEquals(res503Erro.status, 503);
  assertEquals(res503Erro.headers.get("Cache-Control"), "no-store, no-cache, must-revalidate");

  // 4. Em 405 Método Não Permitido
  const reqPost = new Request("http://localhost/functions/v1/saude", { method: "POST" });
  const res405 = await processarSaude(reqPost, { sqlProbe: probeMock() });
  assertEquals(res405.status, 405);
  assertEquals(res405.headers.get("Cache-Control"), "no-store, no-cache, must-revalidate");
});

Deno.test("saude: lida com probe sem registrarFalha opcional quando ping falha ou lanca erro", async () => {
  const probeSemRegistro: SqlProbe = {
    ping: async () => false,
  };
  const req = new Request("http://localhost/functions/v1/saude", { method: "GET" });
  const resFalso = await processarSaude(req, { sqlProbe: probeSemRegistro });
  assertEquals(resFalso.status, 503);

  const probeErroSemRegistro: SqlProbe = {
    ping: async () => {
      throw new Error("Falha sem registrarFalha");
    },
  };
  const resErro = await processarSaude(req, { sqlProbe: probeErroSemRegistro });
  assertEquals(resErro.status, 503);
});

Deno.test("saude: metodos OPTIONS, PUT, DELETE, PATCH retornam 405 metodo_nao_permitido", async () => {
  for (const method of ["OPTIONS", "PUT", "DELETE", "PATCH"]) {
    const req = new Request("http://localhost/functions/v1/saude", { method });
    const res = await processarSaude(req, { sqlProbe: probeMock() });
    assertEquals(res.status, 405);
    const json = await res.json();
    assertEquals(json.ok, false);
    assertEquals(json.erro, "metodo_nao_permitido");
  }
});

Deno.test("bB0tV5R8: GET retorna 200 com metricas de idade quando jobs cron estao saudaveis", async () => {
  const req = new Request("http://localhost/functions/v1/saude", { method: "GET" });
  const res = await processarSaude(req, {
    sqlProbe: probeMock({
      ok: true,
      jobs: {
        saudavel: true,
        status: "saudavel",
        despacho_idade_segundos: 24.5,
        vigia_idade_segundos: 110.0,
        despacho_ativo: true,
        vigia_ativo: true,
      },
    }),
  });

  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.ok, true);
  assertEquals(json.status, "saudavel");
  assertEquals(typeof json.timestamp, "string");
  assertEquals(json.despacho_idade_segundos, 24.5);
  assertEquals(json.vigia_idade_segundos, 110.0);

  // RN15 e Condição b: Sem vazamento de nomes internos de jobs ou tabelas
  assertEquals(json.reprocessar_despacho, undefined);
  assertEquals(json.verificar_saude, undefined);
  assertEquals(json.jobname, undefined);
  assertEquals(json.tabela, undefined);
  assertEquals(json.usuario_id, undefined);
});

Deno.test("bB0tV5R8: GET retorna 503 com status atrasado quando jobs cron estao atrasados", async () => {
  let falhaRegistrada: { origem: string; codigo: string } | null = null;
  const req = new Request("http://localhost/functions/v1/saude", { method: "GET" });
  const res = await processarSaude(req, {
    sqlProbe: probeMock({
      ok: true,
      jobs: {
        saudavel: false,
        status: "atrasado",
        despacho_idade_segundos: 620.0,
        vigia_idade_segundos: 120.0,
        despacho_ativo: true,
        vigia_ativo: true,
      },
      onRegistrarFalha: (origem, codigo) => {
        falhaRegistrada = { origem, codigo };
      },
    }),
  });

  assertEquals(res.status, 503);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.status, "atrasado");
  assertEquals(typeof json.timestamp, "string");
  assertEquals(json.despacho_idade_segundos, 620.0);
  assertEquals(json.vigia_idade_segundos, 120.0);
  assertEquals((falhaRegistrada as any)?.origem, "saude");
  assertEquals((falhaRegistrada as any)?.codigo, "jobs_cron_atrasados");
});

Deno.test("bB0tV5R8: HEAD retorna 503 quando jobs cron estao atrasados", async () => {
  const req = new Request("http://localhost/functions/v1/saude", { method: "HEAD" });
  const res = await processarSaude(req, {
    sqlProbe: probeMock({
      ok: true,
      jobs: {
        saudavel: false,
        status: "atrasado",
        despacho_idade_segundos: 400.0,
        vigia_idade_segundos: 200.0,
        despacho_ativo: true,
        vigia_ativo: true,
      },
    }),
  });

  assertEquals(res.status, 503);
  const text = await res.text();
  assertEquals(text, "");
});

Deno.test("bB0tV5R8: HEAD retorna 200 quando ping e jobs cron estao saudaveis", async () => {
  const req = new Request("http://localhost/functions/v1/saude", { method: "HEAD" });
  const res = await processarSaude(req, {
    sqlProbe: probeMock({
      ok: true,
      jobs: {
        saudavel: true,
        status: "saudavel",
        despacho_idade_segundos: 15.0,
        vigia_idade_segundos: 60.0,
        despacho_ativo: true,
        vigia_ativo: true,
      },
    }),
  });

  assertEquals(res.status, 200);
  const text = await res.text();
  assertEquals(text, "");
});

Deno.test("bB0tV5R8: GET retorna 503 quando job esta inativo (active = false)", async () => {
  const req = new Request("http://localhost/functions/v1/saude", { method: "GET" });
  const res = await processarSaude(req, {
    sqlProbe: probeMock({
      ok: true,
      jobs: {
        saudavel: false,
        status: "atrasado",
        despacho_idade_segundos: 10.0,
        vigia_idade_segundos: 10.0,
        despacho_ativo: false,
        vigia_ativo: true,
      },
    }),
  });

  assertEquals(res.status, 503);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.status, "atrasado");
});





// ── bB0tV5R8 Fase 2: fila de e-mail, pg_net e SMTP entram na sonda ─────────────

const JOBS_OK: InfoSaudeCron = {
  saudavel: true,
  status: "saudavel",
  despacho_idade_segundos: 10,
  vigia_idade_segundos: 20,
  despacho_ativo: true,
  vigia_ativo: true,
};

function operacional(sobrepor: Partial<InfoSaudeOperacional> = {}): InfoSaudeOperacional {
  return {
    saudavel: true,
    status: "saudavel",
    entrega_idade_segundos: 30,
    entrega_ativo: true,
    registro_idade_segundos: null,
    registro_ativo: true,
    fila_idade_segundos: null,
    transporte_falhas: 0,
    transporte_legivel: true,
    entrega_falhas: 0,
    ...sobrepor,
  };
}

const OPERACIONAL_DOENTE = operacional({
  saudavel: false,
  status: "degradado",
  fila_idade_segundos: 1200,
  entrega_falhas: 2,
});

// Palavras que identificam infraestrutura. Nenhuma pode aparecer no corpo público (RN15).
const NOMES_INTERNOS = [
  "pgmq",
  "q_email",
  "q_despacho",
  "pg_net",
  "pgnet",
  "smtp",
  "cron",
  "processar_fila_email",
  "consumir_registro_acesso",
  "falha_execucao",
  "enviar_email",
];

Deno.test("bB0tV5R8 fase 2: GET retorna 503 degradado quando a sonda operacional esta doente e os jobs estao bem", async () => {
  const falhas: string[] = [];
  const req = new Request("http://localhost/functions/v1/saude", { method: "GET" });
  const res = await processarSaude(req, {
    sqlProbe: probeMock({
      ok: true,
      jobs: JOBS_OK,
      operacional: OPERACIONAL_DOENTE,
      onRegistrarFalha: (_o, c) => falhas.push(c),
    }),
  });

  assertEquals(res.status, 503);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.status, "degradado");
  assertEquals(falhas, ["operacao_degradada"]);
  // RN15: o corpo público não ganha número nem nome de fila, pg_net ou SMTP.
  const texto = JSON.stringify(json).toLowerCase();
  for (const nome of NOMES_INTERNOS) assertEquals(texto.includes(nome), false, nome);
  assertEquals(json.fila_idade_segundos, undefined);
  assertEquals(json.entrega_falhas, undefined);
  assertEquals(json.transporte_falhas, undefined);
});

Deno.test("bB0tV5R8 fase 2: HEAD retorna 503 sem corpo quando a sonda operacional esta doente", async () => {
  const req = new Request("http://localhost/functions/v1/saude", { method: "HEAD" });
  const res = await processarSaude(req, {
    sqlProbe: probeMock({ ok: true, jobs: JOBS_OK, operacional: OPERACIONAL_DOENTE }),
  });

  assertEquals(res.status, 503);
  assertEquals(await res.text(), "");
});

Deno.test("bB0tV5R8 fase 2: GET e HEAD retornam 200 quando jobs e sonda operacional estao saudaveis", async () => {
  const sqlProbe = probeMock({ ok: true, jobs: JOBS_OK, operacional: operacional() });

  const get = await processarSaude(
    new Request("http://localhost/functions/v1/saude", { method: "GET" }),
    { sqlProbe },
  );
  assertEquals(get.status, 200);
  const json = await get.json();
  assertEquals(json.ok, true);
  assertEquals(json.status, "saudavel");

  const head = await processarSaude(
    new Request("http://localhost/functions/v1/saude", { method: "HEAD" }),
    { sqlProbe },
  );
  assertEquals(head.status, 200);
  assertEquals(await head.text(), "");
});

Deno.test("bB0tV5R8 fase 2: job parado vence a sonda operacional no status publico", async () => {
  const res = await processarSaude(
    new Request("http://localhost/functions/v1/saude", { method: "GET" }),
    {
      sqlProbe: probeMock({
        ok: true,
        jobs: { ...JOBS_OK, saudavel: false, status: "atrasado", despacho_ativo: false },
        operacional: OPERACIONAL_DOENTE,
      }),
    },
  );

  assertEquals(res.status, 503);
  assertEquals((await res.json()).status, "atrasado");
});

Deno.test("bB0tV5R8 fase 2: sonda operacional doente derruba o HEAD mesmo sem consultarJobs", async () => {
  const res = await processarSaude(
    new Request("http://localhost/functions/v1/saude", { method: "HEAD" }),
    { sqlProbe: probeMock({ ok: true, operacional: OPERACIONAL_DOENTE }) },
  );

  assertEquals(res.status, 503);
});

Deno.test("bB0tV5R8 fase 2: sem consultarOperacional o comportamento da fase 1 continua", async () => {
  const res = await processarSaude(
    new Request("http://localhost/functions/v1/saude", { method: "GET" }),
    { sqlProbe: probeMock({ ok: true, jobs: JOBS_OK }) },
  );

  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, "saudavel");
});

Deno.test("bB0tV5R8 fase 2: consultarOperacional que lanca vira 503 indisponivel, em GET e em HEAD", async () => {
  const falhas: string[] = [];
  const get = await processarSaude(
    new Request("http://localhost/functions/v1/saude", { method: "GET" }),
    {
      sqlProbe: probeMock({
        ok: true,
        jobs: JOBS_OK,
        operacionalLanca: true,
        onRegistrarFalha: (_o, c) => falhas.push(c),
      }),
    },
  );
  assertEquals(get.status, 503);
  const json = await get.json();
  assertEquals(json.ok, false);
  assertEquals(json.status, "indisponivel");
  assertEquals(falhas, ["conexao_falhou"]);

  const head = await processarSaude(
    new Request("http://localhost/functions/v1/saude", { method: "HEAD" }),
    { sqlProbe: probeMock({ ok: true, jobs: JOBS_OK, operacionalLanca: true }) },
  );
  assertEquals(head.status, 503);
  assertEquals(await head.text(), "");
});

Deno.test("bB0tV5R8 fase 2: o detalhe da sonda operacional vai so para o log, nunca para a resposta", async () => {
  const linhas: string[] = [];
  const original = console.log;
  console.log = (...args: unknown[]) => {
    linhas.push(args.map(String).join(" "));
  };
  let res: Response;
  try {
    res = await processarSaude(
      new Request("http://localhost/functions/v1/saude", { method: "GET" }),
      { sqlProbe: probeMock({ ok: true, jobs: JOBS_OK, operacional: OPERACIONAL_DOENTE }) },
    );
  } finally {
    console.log = original;
  }

  assertEquals(res.status, 503);
  const log = linhas.join("\n");
  assertEquals(log.includes("1200"), true);
  assertEquals(log.includes("entrega_falhas"), true);
  assertEquals((await res.text()).includes("1200"), false);
});

Deno.test("bB0tV5R8 fase 2: o status vindo do banco nunca chega ao corpo público", async () => {
  const res = await processarSaude(
    new Request("http://localhost/functions/v1/saude", { method: "GET" }),
    {
      sqlProbe: probeMock({
        ok: true,
        jobs: JOBS_OK,
        operacional: operacional({ saudavel: false, status: "fila_q_email_parada" }),
      }),
    },
  );

  assertEquals(res.status, 503);
  const texto = await res.text();
  assertEquals(JSON.parse(texto).status, "degradado");
  assertEquals(texto.includes("q_email"), false);
});

// O SELECT de `criarSqlProbe` roda contra o banco, e nenhum teste Deno chega lá. Sem este
// confronto, uma coluna renomeada na migração (ou um erro de digitação aqui) só aparece em
// runtime, como 503 permanente. O pgTAP 875 prova a função; isto prova que a Edge Function
// a lê pelos mesmos nomes.
Deno.test("bB0tV5R8 fase 2: o SELECT da Edge Function lê exatamente as colunas que a migração devolve", async () => {
  const migracao = await Deno.readTextFile(
    new URL("../../migrations/20261117100000_saude_operacional.sql", import.meta.url),
  );
  const fonte = await Deno.readTextFile(new URL("./index.ts", import.meta.url));

  const retorno = /returns table \(([\s\S]*?)\)\s*language/.exec(migracao);
  const consulta = /select\s+((?:[a-z_]+,\s*)*[a-z_]+)\s+from privado\.consultar_saude_operacional\(\)/.exec(fonte);
  assertEquals(retorno !== null && consulta !== null, true);

  const colunasDaMigracao = retorno![1].split(",").map((c) => c.trim().split(/\s+/)[0]).sort();
  const colunasLidas = consulta![1].split(",").map((c) => c.trim()).sort();

  assertEquals(colunasLidas, colunasDaMigracao);
  assertEquals(colunasLidas.length, 10);
});
