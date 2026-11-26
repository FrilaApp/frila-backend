import { assertEquals } from "jsr:@std/assert@1.0.19";
import { hashSha256Hex, hashTokenDispositivo } from "../_compartilhado/dispositivo_auth.ts";
import { type AutenticarSocialDb, tratarAutenticarSocial } from "./index.ts";

const SEGREDO_B116 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const CARIMBO = 1764030000;
const OPCOES_IP = { chavesBrutas: `a1:${SEGREDO_B116}`, agoraSegundos: CARIMBO + 5 };
const TX_ID = "33333333-3333-4333-8333-333333333333";

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
    criarTransacaoOauth: () =>
      Promise.resolve({ ok: true, transacao_id: TX_ID, expira_em: "2026-11-25T21:10:00Z" }),
    consumirTransacaoOauth: () => Promise.resolve({ ok: true, provedor: "apple" }),
    concluirLoginSocial: () => Promise.resolve({ ok: true, precisa_definir_senha: false }),
    revogarSessaoPontual: () => Promise.resolve(),
    ...overrides,
  };
}

Deno.test("autenticar-social: iniciar_pkce cria transação vinculada ao provedor e devolve url_autorizacao server-side", async () => {
  const req = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: await cabecalhosWeb("203.0.113.77"),
    body: JSON.stringify({
      provedor: "apple",
      fluxo: "iniciar_pkce",
      plataforma: "web",
      code_challenge: "c".repeat(43),
      redirect_to: "https://frila-web-dev.frilabr.workers.dev/app/entrar/apple/retorno",
    }),
  });

  const res = await tratarAutenticarSocial(req, {
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: OPCOES_IP,
    db: dbStub(),
  });

  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.transacao_id, TX_ID);
  const url = new URL(body.url_autorizacao);
  assertEquals(url.searchParams.get("provider"), "apple");
  assertEquals(url.searchParams.get("code_challenge_method"), "s256");
});

Deno.test("autenticar-social: PKCE Web com B-116 válido consome transação, conclui sessão verificada e renova JWT", async () => {
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
      transacao_id: TX_ID,
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
  assertEquals(chavesRate.includes(`auth:social:ip:${await hashSha256Hex("203.0.113.77")}`), true);
});

Deno.test("autenticar-social: P2 conta Apple+Google com provedor divergente da transação PKCE é recusada antes do GoTrue sem gravar sessão", async () => {
  let chamouGoTrue = false;
  let chamouConcluir = false;
  const req = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: await cabecalhosWeb("203.0.113.77"),
    body: JSON.stringify({
      provedor: "google",
      fluxo: "pkce",
      plataforma: "web",
      transacao_id: TX_ID,
      codigo: "cod-oauth-apple",
      code_verifier: "v".repeat(43),
    }),
  });

  const res = await tratarAutenticarSocial(req, {
    fetchFn: () => {
      chamouGoTrue = true;
      return Promise.resolve(Response.json(sessaoFake()));
    },
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp: OPCOES_IP,
    db: dbStub({
      consumirTransacaoOauth: () => Promise.resolve({ ok: false, motivo: "provedor_divergente" }),
      concluirLoginSocial: () => {
        chamouConcluir = true;
        return Promise.resolve({ ok: true });
      },
    }),
  });

  assertEquals(res.status, 401);
  assertEquals((await res.json()).code, "credenciais_invalidas");
  assertEquals(chamouGoTrue, false);
  assertEquals(chamouConcluir, false);
});

Deno.test("autenticar-social: id_token nativo Apple envia hash contra replay; replay devolve 409 e revoga sessão provisória", async () => {
  const hashesRecebidos: (string | null)[] = [];
  let revogouLocal = false;
  const fetchFn: typeof fetch = (input) => {
    const url = String(input);
    if (url.includes("grant_type=id_token")) return Promise.resolve(Response.json(sessaoFake("sess-apple-1")));
    if (url.includes("grant_type=refresh_token")) return Promise.resolve(Response.json(sessaoFake("sess-apple-2")));
    if (url.includes("/auth/v1/logout?scope=local")) {
      revogouLocal = true;
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    throw new Error(`URL inesperada: ${url}`);
  };

  const makeReq = () =>
    new Request("https://local/functions/v1/autenticar-social", {
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

  // 1. Primeira tentativa: passa e envia hash de 64 chars (nunca token bruto)
  const res1 = await tratarAutenticarSocial(makeReq(), {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub({
      concluirLoginSocial: (_u, _s, _p, tokenHash) => {
        hashesRecebidos.push(tokenHash);
        return Promise.resolve({ ok: true, precisa_definir_senha: false });
      },
    }),
  });
  assertEquals(res1.status, 200);
  assertEquals(hashesRecebidos[0]?.length, 64);
  assertEquals(hashesRecebidos[0]?.includes("eyJhbGciOiJSUzI1NiJ9"), false);

  // 2. Replay do mesmo id_token: banco devolve token_ja_usado -> 409 + revoga scope=local
  const res2 = await tratarAutenticarSocial(makeReq(), {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub({
      concluirLoginSocial: () => Promise.resolve({ ok: false, motivo: "token_ja_usado" }),
    }),
  });
  assertEquals(res2.status, 409);
  assertEquals((await res2.json()).code, "token_ja_usado");
  assertEquals(revogouLocal, true);
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
      transacao_id: TX_ID,
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

Deno.test("autenticar-social: conflito de identidade 409, replay de transação 409 e transação expirada 410", async () => {
  const reqBase = () =>
    new Request("https://local/functions/v1/autenticar-social", {
      method: "POST",
      headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.10" },
      body: JSON.stringify({
        provedor: "google",
        fluxo: "pkce",
        plataforma: "android",
        transacao_id: TX_ID,
        codigo: "cod-oauth-1234",
        code_verifier: "v".repeat(43),
      }),
    });

  const res409Conflito = await tratarAutenticarSocial(reqBase(), {
    fetchFn: () => Promise.resolve(Response.json({ error_code: "identity_already_exists" }, { status: 400 })),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub(),
  });
  assertEquals(res409Conflito.status, 409);
  assertEquals((await res409Conflito.json()).code, "conflito_identidade");

  const res409ReplayTx = await tratarAutenticarSocial(reqBase(), {
    fetchFn: () => Promise.resolve(Response.json(sessaoFake())),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub({ consumirTransacaoOauth: () => Promise.resolve({ ok: false, motivo: "desafio_ja_usado" }) }),
  });
  assertEquals(res409ReplayTx.status, 409);
  assertEquals((await res409ReplayTx.json()).code, "desafio_ja_usado");

  const res410 = await tratarAutenticarSocial(reqBase(), {
    fetchFn: () => Promise.resolve(Response.json(sessaoFake())),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub({ consumirTransacaoOauth: () => Promise.resolve({ ok: false, motivo: "desafio_expirado" }) }),
  });
  assertEquals(res410.status, 410);
  assertEquals((await res410.json()).code, "desafio_expirado");
});
