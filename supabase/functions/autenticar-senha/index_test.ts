import { assertEquals, assertExists } from "jsr:@std/assert@1.0.19";
import { hashSha256Hex, hashTokenDispositivo } from "../_compartilhado/dispositivo_auth.ts";
import { type AutenticarSenhaDb, tratarAutenticarSenha } from "./index.ts";

const SEGREDO_B116_TESTE = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const CARIMBO_B116_TESTE = 1764030000;

async function cabecalhosWebB116(ipVisitante = "203.0.113.42"): Promise<Record<string, string>> {
  const hmac = await hashTokenDispositivo(`v1|${ipVisitante}|${CARIMBO_B116_TESTE}|anon`, SEGREDO_B116_TESTE);
  return {
    "Content-Type": "application/json",
    "cf-connecting-ip": "198.51.100.1",
    "x-frila-ip-visitante": ipVisitante,
    "x-frila-ip-carimbo": String(CARIMBO_B116_TESTE),
    "x-frila-ip-assinatura": `v1;k=a1;${hmac}`,
  };
}

const OPCOES_IP_TESTE = {
  chavesBrutas: `a1:${SEGREDO_B116_TESTE}`,
  agoraSegundos: CARIMBO_B116_TESTE + 10,
};

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
    headers: await cabecalhosWebB116(),
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
    opcoesIp: OPCOES_IP_TESTE,
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
    headers: await cabecalhosWebB116(),
    body: JSON.stringify({ email: "ana@frila.test", senha: "abc", plataforma: "web" }),
  });
  const res = await tratarAutenticarSenha(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: OPCOES_IP_TESTE,
    db: dbStub({ consumirRateLimit: () => Promise.resolve(false) }),
  });
  assertEquals(res.status, 429);
  assertEquals(chamouGoTrue, false);
});

Deno.test("autenticar-senha: Web com B-116 válido usa IP do visitante; sem assinatura ou adulterada falha fechado (403/503) sem bypass de rate limit", async () => {
  const ipVisitante = "203.0.113.42";
  const ipVisitanteHash = await hashSha256Hex(ipVisitante);

  // 1. Web com B-116 válido: cria balde auth:senha:ip:<hash do visitante> (não egress nem x-forwarded-for).
  const chavesAssinado: string[] = [];
  const reqAssinado = new Request("https://local/functions/v1/autenticar-senha", {
    method: "POST",
    headers: {
      ...(await cabecalhosWebB116(ipVisitante)),
      "x-forwarded-for": "192.0.2.99",
    },
    body: JSON.stringify({ email: "ana@frila.test", senha: "err", plataforma: "web" }),
  });

  const resAssinado = await tratarAutenticarSenha(reqAssinado, {
    fetchFn: () => Promise.resolve(Response.json({}, { status: 400 })),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: OPCOES_IP_TESTE,
    db: dbStub({
      consumirRateLimit: (chave) => {
        chavesAssinado.push(chave);
        return Promise.resolve(true);
      },
    }),
  });
  assertEquals(resAssinado.status, 401);
  assertEquals(chavesAssinado.includes(`auth:senha:ip:${ipVisitanteHash}`), true);

  // 2. Web sem cabeçalhos B-116 (tentativa de bypass direto com cf-connecting-ip + x-forwarded-for):
  // falha fechado com 403 assinatura_ip_invalida antes de chamar GoTrue ou pular rate limit por IP.
  let chamouGoTrueSemAssinatura = false;
  const reqSemAssinatura = new Request("https://local/functions/v1/autenticar-senha", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "cf-connecting-ip": "198.51.100.1",
      "x-forwarded-for": "192.0.2.99",
    },
    body: JSON.stringify({ email: "ana@frila.test", senha: "err", plataforma: "web" }),
  });

  const resSemAssinatura = await tratarAutenticarSenha(reqSemAssinatura.clone(), {
    fetchFn: () => {
      chamouGoTrueSemAssinatura = true;
      return Promise.resolve(Response.json({}, { status: 400 }));
    },
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: OPCOES_IP_TESTE,
    db: dbStub(),
  });
  assertEquals(resSemAssinatura.status, 403);
  assertEquals((await resSemAssinatura.json()).code, "assinatura_ip_invalida");
  assertEquals(chamouGoTrueSemAssinatura, false);

  // 3. Web sem chaves B-116 configuradas na Edge Function: fail-closed 503 indisponivel.
  const resSemChaves = await tratarAutenticarSenha(reqSemAssinatura, {
    fetchFn: () => Promise.resolve(Response.json({}, { status: 400 })),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: { chavesBrutas: "" },
    db: dbStub(),
  });
  assertEquals(resSemChaves.status, 503);
  assertEquals((await resSemChaves.json()).code, "indisponivel");

  // 4. Mobile com cabeçalho B-116 forjado: fail-closed 403 (não permite pular rate limit por IP).
  const reqMobileForjado = new Request("https://local/functions/v1/autenticar-senha", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "cf-connecting-ip": "198.51.100.50",
      "x-frila-ip-visitante": "203.0.113.9",
      "x-frila-ip-carimbo": String(CARIMBO_B116_TESTE),
      "x-frila-ip-assinatura": "v1;k=a1;" + "0".repeat(64),
    },
    body: JSON.stringify({ email: "ana@frila.test", senha: "err", plataforma: "ios" }),
  });
  const resMobileForjado = await tratarAutenticarSenha(reqMobileForjado, {
    fetchFn: () => Promise.resolve(Response.json({}, { status: 400 })),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: OPCOES_IP_TESTE,
    db: dbStub(),
  });
  assertEquals(resMobileForjado.status, 403);
  assertEquals((await resMobileForjado.json()).code, "assinatura_ip_invalida");

  // 5. Mobile direto sem B-116: usa cf-connecting-ip e ignora x-forwarded-for.
  const chavesMobile: string[] = [];
  const cfMobileHash = await hashSha256Hex("198.51.100.77");
  const reqMobile = new Request("https://local/functions/v1/autenticar-senha", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "cf-connecting-ip": "198.51.100.77",
      "x-forwarded-for": "192.0.2.99",
    },
    body: JSON.stringify({ email: "ana@frila.test", senha: "err", plataforma: "ios" }),
  });
  await tratarAutenticarSenha(reqMobile, {
    fetchFn: () => Promise.resolve(Response.json({}, { status: 400 })),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: OPCOES_IP_TESTE,
    db: dbStub({
      consumirRateLimit: (chave) => {
        chavesMobile.push(chave);
        return Promise.resolve(true);
      },
    }),
  });
  assertEquals(chavesMobile.includes(`auth:senha:ip:${cfMobileHash}`), true);
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

Deno.test("autenticar-senha: desafio_otp devolve reenviar_em_segundos efetivo (60, 30 e fallback 60 na ausência)", async () => {
  const fetchFn: typeof fetch = (input) => {
    const url = String(input);
    if (url.includes("grant_type=password")) {
      return Promise.resolve(
        Response.json({
          access_token: fakeJwt("sess-prov"),
          token_type: "bearer",
          expires_in: 3600,
          refresh_token: "ref-prov",
          user: { id: "11111111-1111-4111-8111-111111111111", email: "ana@frila.test" },
        }),
      );
    }
    if (url.includes("/auth/v1/logout")) return Promise.resolve(new Response(null, { status: 204 }));
    if (url.includes("/auth/v1/otp")) return Promise.resolve(Response.json({}));
    throw new Error(`URL inesperada: ${url}`);
  };

  for (const [cooldownDb, esperado] of [[60, 60], [30, 30], [undefined, 60]] as const) {
    const req = new Request("https://local/functions/v1/autenticar-senha", {
      method: "POST",
      headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.88" },
      body: JSON.stringify({
        email: "ana@frila.test",
        senha: "SenhaForte123!",
        plataforma: "ios",
      }),
    });
    const res = await tratarAutenticarSenha(req, {
      fetchFn,
      supabaseUrl: "https://proj.supabase.co",
      anonKey: "anon-test",
      pepper: "pepper-test",
      db: dbStub({
        criarDesafio: () =>
          Promise.resolve({
            desafio_id: "33333333-3333-4333-8333-333333333333",
            expira_em: "2026-11-27T05:10:00Z",
            ...(cooldownDb !== undefined ? { cooldown_segundos: cooldownDb } : {}),
          }),
      }),
    });
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.status, "desafio_otp");
    assertEquals(body.reenviar_em_segundos, esperado);
  }
});
