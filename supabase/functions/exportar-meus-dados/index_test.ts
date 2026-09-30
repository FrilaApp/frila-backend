// Testes da Edge Function exportar-meus-dados (cartão nUpPFCpM).
//
// O banco e o Supabase Auth entram injetados. O que se mede aqui é o que nenhum portão
// de SQL alcança: de onde vem a identidade, o que acontece com token ruim, e as duas
// promessas do cartão do lado HTTP — o corpo não é cacheável, e nada é escrito.
//
//   deno test --allow-all supabase/functions/exportar-meus-dados/

import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { criarSqlClient, handler, SqlClient } from "./index.ts";

const URL_BASE = "http://127.0.0.1:54321";
const ANON = "anon-de-teste";
const CONTA = "a0000000-0000-4000-8000-000000000001";

const DADOS = {
  gerado_em: "2026-09-29T14:00:00Z",
  conta: { id: CONTA, perfil: "profissional", nome: "Ana", telefone: "+5561999990001", email: "ana@frila.test", nascimento: "1998-04-02", estado: "ativa" },
  perfil_profissional: null,
  estabelecimentos: [],
  disponibilidade: [],
  turnos: [],
  avaliacoes_dadas: [],
  avaliacoes_recebidas: [],
  dispositivos: [],
};

interface Espiao {
  sql: SqlClient;
  pedidos: string[];
  fetchFn: typeof fetch;
  chamadasAuth: string[];
}

function espiao(
  dados: Record<string, unknown> | null = DADOS,
  authOk = true,
  idDoAuth: unknown = CONTA,
): Espiao {
  const pedidos: string[] = [];
  const chamadasAuth: string[] = [];

  const fetchFn = ((url: string | URL | Request, init?: RequestInit) => {
    chamadasAuth.push(String(url));
    if (!authOk) {
      return Promise.resolve(new Response("{}", { status: 401 }));
    }
    return Promise.resolve(
      new Response(JSON.stringify({ id: idDoAuth }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
  }) as unknown as typeof fetch;

  return {
    pedidos,
    chamadasAuth,
    fetchFn,
    sql: {
      meusDados: (userId: string) => {
        pedidos.push(userId);
        return Promise.resolve(dados);
      },
    },
  };
}

function requisicao(token = "token-valido", metodo = "POST"): Request {
  return new Request(`${URL_BASE}/functions/v1/exportar-meus-dados`, {
    method: metodo,
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  });
}

function chamar(e: Espiao, req = requisicao()): Promise<Response> {
  return handler(req, {
    fetchFn: e.fetchFn,
    sqlClient: e.sql,
    supabaseUrl: URL_BASE,
    anonKey: ANON,
  });
}

// ── O caminho feliz ───────────────────────────────────────────────────────────

Deno.test("nUpPFCpM: devolve o JSON no corpo, e não um link", async () => {
  const e = espiao();
  const res = await chamar(e);

  assertEquals(res.status, 200);
  const corpo = await res.json();
  assertEquals(corpo, DADOS);

  // O contrato é explícito: sem link e sem e-mail. Nenhum dos dois pode aparecer.
  const texto = JSON.stringify(corpo);
  assert(!/"(url|link|download|href)"\s*:/.test(texto), "o corpo trouxe um link");
});

Deno.test("nUpPFCpM 2: a resposta não é cacheável — nenhum proxy guarda cópia", async () => {
  const e = espiao();
  const res = await chamar(e);
  assertEquals(res.headers.get("Cache-Control"), "no-store");
  await res.body?.cancel();
});

Deno.test("nUpPFCpM: a identidade vem do auth/v1/user, não do corpo nem do token cru", async () => {
  const e = espiao();
  await chamar(e);

  assertEquals(e.chamadasAuth.length, 1);
  assertStringIncludes(e.chamadasAuth[0], "/auth/v1/user");
  assertEquals(e.pedidos, [CONTA], "o banco foi consultado com o id que o Auth devolveu");
});

Deno.test("nUpPFCpM: o id do corpo da requisição é ignorado", async () => {
  const e = espiao();
  const req = new Request(`${URL_BASE}/functions/v1/exportar-meus-dados`, {
    method: "POST",
    headers: { Authorization: "Bearer token-valido", "Content-Type": "application/json" },
    body: JSON.stringify({ usuario_id: "b0000000-0000-4000-8000-000000000099" }),
  });
  const res = await chamar(e, req);

  assertEquals(res.status, 200);
  assertEquals(e.pedidos, [CONTA], "exportou os dados de outra pessoa a pedido do cliente");
  await res.body?.cancel();
});

// ── A porta ───────────────────────────────────────────────────────────────────

Deno.test("porta: sem Authorization responde 401 e não toca no banco", async () => {
  const e = espiao();
  const req = new Request(`${URL_BASE}/functions/v1/exportar-meus-dados`, { method: "POST" });
  const res = await chamar(e, req);

  assertEquals(res.status, 401);
  assertEquals((await res.json()).code, "nao_autenticado");
  assertEquals(e.pedidos, []);
  assertEquals(e.chamadasAuth, [], "nem chegou a perguntar ao Auth");
});

Deno.test("porta: token que o Auth recusa responde 401 e não toca no banco", async () => {
  const e = espiao(DADOS, false);
  const res = await chamar(e);

  assertEquals(res.status, 401);
  assertEquals((await res.json()).code, "nao_autenticado");
  assertEquals(e.pedidos, []);
});

Deno.test("porta: Auth que devolve 200 sem id responde 401", async () => {
  const e = espiao(DADOS, true, null);
  const res = await chamar(e);

  assertEquals(res.status, 401);
  assertEquals((await res.json()).code, "nao_autenticado");
  assertEquals(e.pedidos, []);
});

Deno.test("porta: GET responde 405", async () => {
  const e = espiao();
  const res = await chamar(e, requisicao("token-valido", "GET"));
  assertEquals(res.status, 405);
  assertEquals((await res.json()).code, "metodo_nao_permitido");
});

Deno.test("token válido de conta que o banco não conhece responde 404", async () => {
  const e = espiao(null);
  const res = await chamar(e);

  assertEquals(res.status, 404);
  assertEquals((await res.json()).code, "nao_encontrado");
});

Deno.test("falha no banco responde 500 sem devolver a mensagem do Postgres (RN15)", async () => {
  const e = espiao();
  const res = await handler(requisicao(), {
    fetchFn: e.fetchFn,
    supabaseUrl: URL_BASE,
    anonKey: ANON,
    sqlClient: {
      meusDados: () =>
        Promise.reject(new Error('relation "usuario" ... ana@frila.test')),
    },
  });

  assertEquals(res.status, 500);
  const corpo = await res.json();
  assertEquals(corpo.code, "erro_interno");
  assertEquals(corpo.details, null);
  assert(
    !JSON.stringify(corpo).includes("ana@frila.test"),
    "a mensagem do Postgres vazou para o cliente",
  );
});

Deno.test("criarSqlClient exige SUPABASE_DB_URL em vez de falhar calado", () => {
  const anterior = Deno.env.get("SUPABASE_DB_URL");
  Deno.env.delete("SUPABASE_DB_URL");
  try {
    let lancou = false;
    try {
      criarSqlClient({});
    } catch {
      lancou = true;
    }
    assert(lancou, "criarSqlClient aceitou ficar sem banco");
  } finally {
    if (anterior) Deno.env.set("SUPABASE_DB_URL", anterior);
  }
});
