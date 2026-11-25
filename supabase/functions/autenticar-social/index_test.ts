import { assertEquals } from "jsr:@std/assert@1.0.19";
import { hashSha256Hex, hashTokenDispositivo } from "../_compartilhado/dispositivo_auth.ts";
import { type AutenticarSocialDb, tratarAutenticarSocial } from "./index.ts";

const SEGREDO_B116 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const CARIMBO = 1764030000;
const OPCOES_IP = { chavesBrutas: `a1:${SEGREDO_B116}`, agoraSegundos: CARIMBO + 5 };

function fakeJwt(sessionId: string): string {
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" })).replace(/=/g, "");
  const payload = btoa(JSON.stringify({ sub: "11111111-1111-4111-8111-111111111111", session_id: sessionId })).replace(/=/g, "");
  return `${header}.${payload}.sig`;
}

function sessaoFake(sessionId = "22222222-2222-4222-8222-222222222222") {
  return {
    access_token: fakeJwt(sessionId),
    token_type: "bearer",
    expires_in: 3600,
    refresh_token: `ref-${sessionId}`,
    user: { id: "11111111-1111-4111-8111-111111111111", email: "ana@frila.test" },
  };
}

async function cabecalhosWeb(ip = "203.0.113.42"): Promise<Record<string, string>> {
  const hmac = await hashTokenDispositivo(`v1|${ip}|${CARIMBO}|anon`, SEGREDO_B116);
  return {
    "Content-Type": "application/json",
    "cf-connecting-ip": "198.51.100.1",
    "x-frila-ip-visitante": ip,
    "x-frila-ip-carimbo": String(CARIMBO),
    "x-frila-ip-assinatura": `v1;k=a1;${hmac}`,
  };
}

function dbStub(overrides: Partial<AutenticarSocialDb> = {}): AutenticarSocialDb {
  return {
    consumirRateLimit: () => Promise.resolve(true),
    concluirLoginSocial: () => Promise.resolve({ ok: true, precisa_definir_senha: false }),
    revogarSessaoPontual: () => Promise.resolve(),
    ...overrides,
  };
}

Deno.test("autenticar-social: PKCE Web com B-116 válido conclui sessão verificada, renova JWT e devolve precisa_definir_senha=false", async () => {
  const chamadas: string[] = [];
  const chavesRate: string[] = [];
  const fetchFn: typeof fetch = (input) => {
    const url = String(input);
    chamadas.push(url);
    if (url.includes("grant_type=pkce")) return Promise.resolve(Response.json(sessaoFake("sess-prov")));
    if (url.includes("grant_type=refresh_token")) return Promise.resolve(Response.json(sessaoFake("sess-final")));
    throw new Error(`URL inesperada: ${url}`);
  };

  const req = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: await cabecalhosWeb("203.0.113.77"),
    body: JSON.stringify({
      provedor: "apple",
      fluxo: "pkce",
      plataforma: "web",
      codigo: "cod-oauth-1234",
      code_verifier: "v".repeat(43),
    }),
  });

  const res = await tratarAutenticarSocial(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: OPCOES_IP,
    db: dbStub({
      consumirRateLimit: (chave) => {
        chavesRate.push(chave);
        return Promise.resolve(true);
      },
    }),
  });

  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.provedor, "apple");
  assertEquals(body.precisa_definir_senha, false);
  assertEquals(body.sessao.refresh_token, "ref-sess-final");
  assertEquals(chamadas.length, 2);
  assertEquals(chamadas[0].includes("grant_type=pkce"), true);
  assertEquals(chamadas[1].includes("grant_type=refresh_token"), true);
  assertEquals(chavesRate.includes(`auth:social:ip:${await hashSha256Hex("203.0.113.77")}`), true);
});

Deno.test("autenticar-social: id_token nativo Apple no iOS envia provider=apple + nonce e renova JWT", async () => {
  const payloads: Record<string, unknown>[] = [];
  const fetchFn: typeof fetch = (_input, init) => {
    const url = String(_input);
    if (init?.body) payloads.push(JSON.parse(String(init.body)));
    if (url.includes("grant_type=id_token")) return Promise.resolve(Response.json(sessaoFake("sess-apple-1")));
    if (url.includes("grant_type=refresh_token")) return Promise.resolve(Response.json(sessaoFake("sess-apple-2")));
    throw new Error(`URL inesperada: ${url}`);
  };

  const req = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.44" },
    body: JSON.stringify({
      provedor: "apple",
      fluxo: "id_token",
      plataforma: "ios",
      id_token: "eyJhbGciOiJSUzI1NiJ9.payload.assinatura",
      nonce: "nonce-bruto-32bytes-sintetico",
    }),
  });

  const res = await tratarAutenticarSocial(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub(),
  });

  assertEquals(res.status, 200);
  assertEquals(payloads[0]?.provider, "apple");
  assertEquals(payloads[0]?.nonce, "nonce-bruto-32bytes-sintetico");
});

Deno.test("autenticar-social: Web sem assinatura B-116 falha fechado (403/503) antes do GoTrue", async () => {
  let chamouGoTrue = false;
  const req = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.1", "x-forwarded-for": "192.0.2.9" },
    body: JSON.stringify({
      provedor: "google",
      fluxo: "pkce",
      plataforma: "web",
      codigo: "cod-oauth-1234",
      code_verifier: "v".repeat(43),
    }),
  });

  const res403 = await tratarAutenticarSocial(req.clone(), {
    fetchFn: () => {
      chamouGoTrue = true;
      return Promise.resolve(Response.json({}));
    },
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: OPCOES_IP,
    db: dbStub(),
  });
  assertEquals(res403.status, 403);
  assertEquals((await res403.json()).code, "assinatura_ip_invalida");
  assertEquals(chamouGoTrue, false);

  const res503 = await tratarAutenticarSocial(req, {
    fetchFn: () => Promise.resolve(Response.json({})),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: { chavesBrutas: "" },
    db: dbStub(),
  });
  assertEquals(res503.status, 503);
  assertEquals((await res503.json()).code, "indisponivel");
});

Deno.test("autenticar-social: conflito de identidade devolve 409 e identidade ausente no banco revoga sessão provisória com scope=local", async () => {
  // 1. Conflito explícito do GoTrue -> 409 conflito_identidade
  const reqConflito = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.10" },
    body: JSON.stringify({
      provedor: "google",
      fluxo: "pkce",
      plataforma: "android",
      codigo: "cod-oauth-1234",
      code_verifier: "v".repeat(43),
    }),
  });
  const res409 = await tratarAutenticarSocial(reqConflito, {
    fetchFn: () =>
      Promise.resolve(Response.json({ error_code: "identity_already_exists" }, { status: 400 })),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub(),
  });
  assertEquals(res409.status, 409);
  assertEquals((await res409.json()).code, "conflito_identidade");

  // 2. concluirLoginSocial recusa (usuário não tem identidade do provedor declarado) -> revoga scope=local + 401
  let revogouLocal = false;
  let revogouPontual = false;
  const reqSemId = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.10" },
    body: JSON.stringify({
      provedor: "apple",
      fluxo: "pkce",
      plataforma: "android",
      codigo: "cod-oauth-1234",
      code_verifier: "v".repeat(43),
    }),
  });
  const res401 = await tratarAutenticarSocial(reqSemId, {
    fetchFn: (input) => {
      const url = String(input);
      if (url.includes("grant_type=pkce")) return Promise.resolve(Response.json(sessaoFake("sess-prov")));
      if (url.includes("/auth/v1/logout?scope=local")) {
        revogouLocal = true;
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      throw new Error(`URL inesperada: ${url}`);
    },
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub({
      concluirLoginSocial: () => Promise.resolve({ ok: false, motivo: "identidade_social_ausente" }),
      revogarSessaoPontual: () => {
        revogouPontual = true;
        return Promise.resolve();
      },
    }),
  });
  assertEquals(res401.status, 401);
  assertEquals(revogouLocal, true);
  assertEquals(revogouPontual, true);
});
