import { assertEquals, assertExists } from "jsr:@std/assert@1.0.19";
import { type ConfirmarDispositivoDb, tratarConfirmarDispositivoOtp } from "./index.ts";

function fakeJwt(sessionId: string): string {
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" })).replace(/=/g, "");
  const payload = btoa(JSON.stringify({ sub: "user-1", session_id: sessionId })).replace(/=/g, "");
  return `${header}.${payload}.sig`;
}

function sessaoFake(sessionId = "sess-otp", userId = "user-1") {
  return {
    access_token: fakeJwt(sessionId),
    token_type: "bearer",
    expires_in: 3600,
    refresh_token: "ref-" + sessionId,
    user: { id: userId, email: "ana@frila.test" },
  };
}

function dbStub(overrides: Partial<ConfirmarDispositivoDb> = {}): ConfirmarDispositivoDb {
  return {
    consumirRateLimit: () => Promise.resolve(true),
    reservarTentativaDesafio: () =>
      Promise.resolve({
        status: "ok",
        usuario_id: "user-1",
        email_normalizado: "ana@frila.test",
        plataforma: "web",
      }),
    concluirDesafioERegistrarSessao: () =>
      Promise.resolve({
        ok: true,
        dispositivo_expira_em: "2026-12-24T23:55:00Z",
        precisa_definir_senha: false,
      }),
    revogarSessaoPontual: () => Promise.resolve(),
    ...overrides,
  };
}

Deno.test("confirmar-dispositivo-otp: login_dispositivo com lembrar_dispositivo=true recupera email server-side, renova JWT e emite device_token", async () => {
  const chamadas: { url: string; body?: Record<string, unknown> }[] = [];
  const fetchFn: typeof fetch = async (input, init) => {
    const url = String(input);
    const body = typeof init?.body === "string" ? JSON.parse(init.body) : undefined;
    chamadas.push({ url, body });
    if (url.includes("/auth/v1/verify")) return Response.json(sessaoFake("sess-verify"));
    if (url.includes("grant_type=refresh_token")) return Response.json(sessaoFake("sess-final"));
    throw new Error(`URL inesperada: ${url}`);
  };

  let tokenHashSalvo: string | null = null;
  const req = new Request("https://local/functions/v1/confirmar-dispositivo-otp", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      tipo: "login_dispositivo",
      desafio_id: "11111111-1111-4111-8111-111111111111",
      codigo: "123456",
      plataforma: "web",
      lembrar_dispositivo: true,
    }),
  });

  const res = await tratarConfirmarDispositivoOtp(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    pepper: "pepper-segredo",
    gerarToken: () => "token-opaco-32bytes-sintetico",
    db: dbStub({
      concluirDesafioERegistrarSessao: (p) => {
        tokenHashSalvo = p.tokenHash;
        return Promise.resolve({
          ok: true,
          dispositivo_expira_em: "2026-12-24T23:55:00Z",
          precisa_definir_senha: false,
        });
      },
    }),
  });

  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.precisa_definir_senha, false);
  assertEquals(body.device_token, "token-opaco-32bytes-sintetico");
  assertEquals(body.dispositivo_expira_em, "2026-12-24T23:55:00Z");
  assertEquals(body.sessao.refresh_token, "ref-sess-final");
  assertExists(tokenHashSalvo);
  assertEquals(tokenHashSalvo !== "token-opaco-32bytes-sintetico", true);
  assertEquals(chamadas[0].body?.email, "ana@frila.test");
  assertEquals(chamadas[1].url.includes("grant_type=refresh_token"), true);
});

Deno.test("confirmar-dispositivo-otp: cadastro com lembrar_dispositivo=false marca precisa_definir_senha=true e device_token=null", async () => {
  const fetchFn: typeof fetch = (input) => {
    const url = String(input);
    if (url.includes("/auth/v1/verify")) return Promise.resolve(Response.json(sessaoFake("sess-cad")));
    if (url.includes("grant_type=refresh_token")) return Promise.resolve(Response.json(sessaoFake("sess-cad-final")));
    throw new Error(`URL inesperada: ${url}`);
  };

  let pendenteRecebido: string | null = null;
  const req = new Request("https://local/functions/v1/confirmar-dispositivo-otp", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      tipo: "cadastro",
      email: "novo@frila.test",
      codigo: "654321",
      plataforma: "ios",
      lembrar_dispositivo: false,
    }),
  });

  const res = await tratarConfirmarDispositivoOtp(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub({
      concluirDesafioERegistrarSessao: (p) => {
        pendenteRecebido = p.marcarSenhaPendente;
        return Promise.resolve({
          ok: true,
          dispositivo_expira_em: null,
          precisa_definir_senha: true,
        });
      },
    }),
  });

  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(pendenteRecebido, "cadastro");
  assertEquals(body.precisa_definir_senha, true);
  assertEquals(body.device_token, null);
  assertEquals(body.dispositivo_expira_em, null);
});

Deno.test("confirmar-dispositivo-otp: replay / corrida devolve 409 desafio_ja_usado e revoga sessão recém-criada", async () => {
  let revogouLocal = false;
  const fetchFn: typeof fetch = (input) => {
    const url = String(input);
    if (url.includes("/auth/v1/verify")) return Promise.resolve(Response.json(sessaoFake("sess-replay")));
    if (url.includes("/auth/v1/logout?scope=local")) {
      revogouLocal = true;
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    throw new Error(`URL inesperada: ${url}`);
  };

  const req = new Request("https://local/functions/v1/confirmar-dispositivo-otp", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      tipo: "login_dispositivo",
      desafio_id: "11111111-1111-4111-8111-111111111111",
      codigo: "123456",
      plataforma: "android",
      lembrar_dispositivo: false,
    }),
  });

  const res = await tratarConfirmarDispositivoOtp(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub({
      concluirDesafioERegistrarSessao: () => Promise.resolve({ ok: false, motivo: "desafio_ja_usado" }),
    }),
  });

  assertEquals(res.status, 409);
  const body = await res.json();
  assertEquals(body.code, "desafio_ja_usado");
  assertEquals(revogouLocal, true);
});

Deno.test("confirmar-dispositivo-otp: desafio expirado devolve 410 e excesso de tentativas devolve 429", async () => {
  for (const [statusDb, httpEsperado, codeEsperado] of [
    ["desafio_expirado", 410, "desafio_expirado"],
    ["limite_excedido", 429, "limite_excedido"],
    ["desafio_ja_usado", 409, "desafio_ja_usado"],
  ] as const) {
    const req = new Request("https://local/functions/v1/confirmar-dispositivo-otp", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        tipo: "login_dispositivo",
        desafio_id: "11111111-1111-4111-8111-111111111111",
        codigo: "123456",
        plataforma: "web",
        lembrar_dispositivo: false,
      }),
    });
    const res = await tratarConfirmarDispositivoOtp(req, {
      fetchFn: () => Promise.resolve(Response.json({})),
      supabaseUrl: "https://proj.supabase.co",
      anonKey: "anon-test",
      db: dbStub({
        reservarTentativaDesafio: () => Promise.resolve({ status: statusDb }),
      }),
    });
    assertEquals(res.status, httpEsperado);
    assertEquals((await res.json()).code, codeEsperado);
  }
});
