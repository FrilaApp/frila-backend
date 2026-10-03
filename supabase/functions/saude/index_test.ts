// Testes da Edge Function saude (cartão 5bPJvMIo).
//
//   deno test --allow-all supabase/functions/saude/

import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { getDbUrl, processarSaude, SqlProbe } from "./index.ts";

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
