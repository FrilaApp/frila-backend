// Testes da Edge Function saude (cartão 5bPJvMIo).
//
//   deno test --allow-all supabase/functions/saude/

import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.19";
import { criarSqlProbe, getDbUrl, processarSaude, SqlProbe } from "./index.ts";

function probeMock(opcoes: {
  ok?: boolean;
  erro?: boolean;
  onRegistrarFalha?: (origem: string, codigo: string) => void;
} = {}): SqlProbe {
  return {
    ping: async () => {
      if (opcoes.erro) {
        throw new Error("Falha simulada de conexão com o banco");
      }
      return opcoes.ok ?? true;
    },
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



