import { assertEquals, assertExists } from "jsr:@std/assert@1.0.19";
import { hashTokenDispositivo } from "../_compartilhado/dispositivo_auth.ts";
import { type AutenticarSenhaDb, tratarAutenticarSenha } from "./index.ts";

function fakeJwt(sessionId: string): string {
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" })).replace(/=/g, "");
  const payload = btoa(JSON.stringify({ sub: "user-1", session_id: sessionId })).replace(/=/g, "");
  return `${header}.${payload}.sig`;
}

function sessaoFake(sessionId = "sess-1", userId = "user-1") {
  return {
    access_token: fakeJwt(sessionId),
    token_type: "bearer",
    expires_in: 3600,
    refresh_token: "ref-" + sessionId,
    user: { id: userId, email: "ana@frila.test" },
  };
}

function dbStub(overrides: Partial<AutenticarSenhaDb> = {}): AutenticarSenhaDb {
  return {
    consumirRateLimit: () => Promise.resolve(true),
    validarEMarcarDispositivo: () => Promise.resolve({ valido: false }),
    criarDesafio: () =>
      Promise.resolve({
        desafio_id: "11111111-1111-4111-8111-111111111111",
        expira_em: "2026-11-25T00:10:00Z",
      }),
    revogarSessaoPontual: () => Promise.resolve(),
    ...overrides,
  };
}

Deno.test("autenticar-senha: dispositivo válido renova JWT via refresh_token e devolve status autenticado", async () => {
  const chamadas: string[] = [];
  const fetchFn: typeof fetch = (input) => {
    const url = String(input);
    chamadas.push(url);
    if (url.includes("grant_type=password")) {
      return Promise.resolve(Response.json(sessaoFake("sess-provisoria")));
    }
    if (url.includes("grant_type=refresh_token")) {
      return Promise.resolve(Response.json(sessaoFake("sess-final-verificada")));
    }
    throw new Error(`URL inesperada: ${url}`);
  };

  let hashRecebido = "";
  const req = new Request("https://local/functions/v1/autenticar-senha", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      email: "Ana@Frila.test",
      senha: "SenhaForte123!",
      plataforma: "web",
      device_token: "tok-opaco-valido",
    }),
  });

  const res = await tratarAutenticarSenha(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    pepper: "pepper-teste-32-bytes",
    db: dbStub({
      validarEMarcarDispositivo: (_uid, _sid, hash) => {
        hashRecebido = hash;
        return Promise.resolve({
          valido: true,
          expira_em: "2026-12-24T23:50:00Z",
          precisa_definir_senha: false,
        });
      },
    }),
  });

  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.status, "autenticado");
  assertEquals(body.precisa_definir_senha, false);
  assertEquals(body.dispositivo_expira_em, "2026-12-24T23:50:00Z");
  assertEquals(body.sessao.refresh_token, "ref-sess-final-verificada");
  // Token nunca é passado em texto puro ao banco (HMAC-SHA256 hex de 64 chars)
  assertEquals(hashRecebido.length, 64);
  assertEquals(hashRecebido !== "tok-opaco-valido", true);
  // Confirma sequência sem circularidade: password -> refresh_token
  assertEquals(chamadas.length, 2);
  assertEquals(chamadas[0].includes("grant_type=password"), true);
  assertEquals(chamadas[1].includes("grant_type=refresh_token"), true);
});

Deno.test("autenticar-senha: dispositivo vencido/novo revoga sessão provisória com scope=local, dispara OTP create_user=false e não retorna tokens", async () => {
  const chamadas: { url: string; body?: Record<string, unknown> }[] = [];
  const fetchFn: typeof fetch = async (input, init) => {
    const url = String(input);
    const body = typeof init?.body === "string" ? JSON.parse(init.body) : undefined;
    chamadas.push({ url, body });
    if (url.includes("grant_type=password")) {
      return Response.json(sessaoFake("sess-prov"));
    }
    if (url.includes("/auth/v1/logout?scope=local")) {
      return new Response(null, { status: 204 });
    }
    if (url.includes("/auth/v1/otp")) {
      return Response.json({});
    }
    throw new Error(`URL inesperada: ${url}`);
  };

  const req = new Request("https://local/functions/v1/autenticar-senha", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      email: "ana@frila.test",
      senha: "SenhaForte123!",
      plataforma: "ios",
      device_token: "tok-vencido",
    }),
  });

  const res = await tratarAutenticarSenha(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    pepper: "pepper-teste-32-bytes",
    db: dbStub({ validarEMarcarDispositivo: () => Promise.resolve({ valido: false }) }),
  });

  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.status, "desafio_otp");
  assertExists(body.desafio_id);
  assertEquals(body.descartar_device_token, true);
  assertEquals(body.sessao, undefined);
  assertEquals(chamadas.some((c) => c.url.includes("scope=local")), true);
  assertEquals(chamadas.some((c) => c.url.includes("scope=global")), false);
  const chamadaOtp = chamadas.find((c) => c.url.includes("/auth/v1/otp"));
  assertEquals(chamadaOtp?.body?.create_user, false);
});

Deno.test("autenticar-senha: anti-enumeração devolve 401 credenciais_invalidas para qualquer 4xx de credencial", async () => {
  for (const status of [400, 401, 422]) {
    const fetchFn: typeof fetch = () =>
      Promise.resolve(Response.json({ error_description: "Invalid login credentials" }, { status }));
    const req = new Request("https://local/functions/v1/autenticar-senha", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: "inexistente@frila.test", senha: "x", plataforma: "android" }),
    });
    const res = await tratarAutenticarSenha(req, {
      fetchFn,
      supabaseUrl: "https://proj.supabase.co",
      anonKey: "anon-test",
      pepper: "pepper",
      db: dbStub(),
    });
    assertEquals(res.status, 401);
    const body = await res.json();
    assertEquals(body.code, "credenciais_invalidas");
  }
});

Deno.test("autenticar-senha: rate limit devolve 429 limite_excedido antes de chamar GoTrue", async () => {
  let chamouGoTrue = false;
  const fetchFn: typeof fetch = () => {
    chamouGoTrue = true;
    return Promise.resolve(Response.json({}));
  };
  const req = new Request("https://local/functions/v1/autenticar-senha", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: "ana@frila.test", senha: "abc", plataforma: "web" }),
  });
  const res = await tratarAutenticarSenha(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub({ consumirRateLimit: () => Promise.resolve(false) }),
  });
  assertEquals(res.status, 429);
  assertEquals(chamouGoTrue, false);
});

Deno.test("autenticar-senha: Web com cabeçalho B-116 assinado usa IP do visitante; sem assinatura NÃO agrupa por egress nem confia em x-forwarded-for", async () => {
  const segredo = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  const carimbo = 1764030000;
  const ipVisitante = "203.0.113.42";
  const hmac = await hashTokenDispositivo(`v1|${ipVisitante}|${carimbo}|anon`, segredo);

  const chavesAssinado: string[] = [];
  const reqAssinado = new Request("https://local/functions/v1/autenticar-senha", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "cf-connecting-ip": "198.51.100.1",
      "x-frila-ip-visitante": ipVisitante,
      "x-frila-ip-carimbo": String(carimbo),
      "x-frila-ip-assinatura": `v1;k=a1;${hmac}`,
    },
    body: JSON.stringify({ email: "ana@frila.test", senha: "err", plataforma: "web" }),
  });

  await tratarAutenticarSenha(reqAssinado, {
    fetchFn: () => Promise.resolve(Response.json({}, { status: 400 })),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: { chavesBrutas: `a1:${segredo}`, agoraSegundos: carimbo + 10 },
    db: dbStub({
      consumirRateLimit: (chave) => {
        chavesAssinado.push(chave);
        return Promise.resolve(true);
      },
    }),
  });
  assertEquals(chavesAssinado.some((c) => c.startsWith("auth:senha:ip:")), true);

  // Web sem assinatura B-116 válida (com cf-connecting-ip de egress + x-forwarded-for forjado):
  // NÃO pode criar balde auth:senha:ip:* (usa apenas email_hash, evitando 429 global por PoP).
  const chavesSemAssinatura: string[] = [];
  const reqSemAssinatura = new Request("https://local/functions/v1/autenticar-senha", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "cf-connecting-ip": "198.51.100.1",
      "x-forwarded-for": "192.0.2.99",
    },
    body: JSON.stringify({ email: "ana@frila.test", senha: "err", plataforma: "web" }),
  });

  await tratarAutenticarSenha(reqSemAssinatura, {
    fetchFn: () => Promise.resolve(Response.json({}, { status: 400 })),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: { chavesBrutas: `a1:${segredo}`, agoraSegundos: carimbo + 10 },
    db: dbStub({
      consumirRateLimit: (chave) => {
        chavesSemAssinatura.push(chave);
        return Promise.resolve(true);
      },
    }),
  });
  assertEquals(chavesSemAssinatura.some((c) => c.startsWith("auth:senha:ip:")), false);
  assertEquals(chavesSemAssinatura.some((c) => c.startsWith("auth:senha:email:")), true);
});

Deno.test("autenticar-senha: fail-closed devolve 503 se device_token presente sem DISPOSITIVO_TOKEN_PEPPER", async () => {
  const req = new Request("https://local/functions/v1/autenticar-senha", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      email: "ana@frila.test",
      senha: "SenhaForte123!",
      plataforma: "web",
      device_token: "tok-opaco",
    }),
  });
  const res = await tratarAutenticarSenha(req, {
    fetchFn: () => Promise.resolve(Response.json({})),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    pepper: "",
    db: dbStub(),
  });
  assertEquals(res.status, 503);
  assertEquals((await res.json()).code, "indisponivel");
});
