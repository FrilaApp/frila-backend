import { assertEquals } from "jsr:@std/assert@1.0.19";
import { hashSha256Hex, hashTokenDispositivo } from "../_compartilhado/dispositivo_auth.ts";
import {
  type AutenticarSocialDb,
  calcularHashCanonicoIdToken,
  ehRedirectPermitido,
  tratarAutenticarSocial,
} from "./index.ts";

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
    loginSocialAtivo: true,
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
    loginSocialAtivo: true,
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

Deno.test("autenticar-social: P2 transação Apple + request apple + código Google (mesmo challenge) é recusada via auth.flow_state antes do GoTrue", async () => {
  let chamouGoTrue = false;
  let chamouConcluir = false;
  const argsConsumo: unknown[] = [];
  const req = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: await cabecalhosWeb("203.0.113.77"),
    body: JSON.stringify({
      provedor: "apple",
      fluxo: "pkce",
      plataforma: "web",
      transacao_id: TX_ID,
      codigo: "cod-oauth-google-substituido",
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
    loginSocialAtivo: true,
    db: dbStub({
      consumirTransacaoOauth: (txId, prov, chHash, authCode, chRaw) => {
        argsConsumo.push({ txId, prov, chHash, authCode, chRaw });
        // Simula auth.flow_state.provider_type = 'google' <> 'apple' para o mesmo code_challenge.
        return Promise.resolve({ ok: false, motivo: "provedor_divergente" });
      },
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
  assertEquals(argsConsumo.length, 1);
  const chamada = argsConsumo[0] as Record<string, string>;
  assertEquals(chamada.txId, TX_ID);
  assertEquals(chamada.prov, "apple");
  assertEquals(chamada.authCode, "cod-oauth-google-substituido");
  assertEquals(chamada.chRaw.length, 43);
});

Deno.test("autenticar-social: falha 500 do GoTrue em id_token não consome hash (retry legítimo funciona); replay devolve 409 e revoga sessão provisória", async () => {
  const hashesRecebidos: (string | null)[] = [];
  let revogouLocal = false;
  let falharGoTrue = true;
  const fetchFn: typeof fetch = (input) => {
    const url = String(input);
    if (url.includes("grant_type=id_token")) {
      if (falharGoTrue) return Promise.resolve(new Response("erro transitorio", { status: 500 }));
      return Promise.resolve(Response.json(sessaoFake("sess-apple-1")));
    }
    if (url.includes("grant_type=refresh_token")) return Promise.resolve(Response.json(sessaoFake("sess-apple-2")));
    if (url.includes("/auth/v1/logout?scope=local")) {
      revogouLocal = true;
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    throw new Error(`URL inesperada: ${url}`);
  };

  const idTokenCanonico = fakeJwt("22222222-2222-4222-8222-222222222222");
  const makeReq = () =>
    new Request("https://local/functions/v1/autenticar-social", {
      method: "POST",
      headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.44" },
      body: JSON.stringify({
        provedor: "apple",
        fluxo: "id_token",
        plataforma: "ios",
        id_token: idTokenCanonico,
        nonce: "nonce-bruto-32bytes-sintetico",
      }),
    });

  // 0. Falha 500 transitória no GoTrue devolve 503 sem chamar concluirLoginSocial (não queima hash)
  const res503 = await tratarAutenticarSocial(makeReq(), {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    loginSocialAtivo: true,
    db: dbStub({
      concluirLoginSocial: (_u, _s, _p, tokenHash) => {
        hashesRecebidos.push(tokenHash);
        return Promise.resolve({ ok: true, precisa_definir_senha: false });
      },
    }),
  });
  assertEquals(res503.status, 503);
  assertEquals(hashesRecebidos.length, 0);

  // 1. Retry legítimo após 500: passa e envia hash canônico de 64 chars (nunca token bruto)
  falharGoTrue = false;
  const res1 = await tratarAutenticarSocial(makeReq(), {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    loginSocialAtivo: true,
    db: dbStub({
      concluirLoginSocial: (_u, _s, _p, tokenHash) => {
        hashesRecebidos.push(tokenHash);
        return Promise.resolve({ ok: true, precisa_definir_senha: false });
      },
    }),
  });
  assertEquals(res1.status, 200);
  assertEquals(hashesRecebidos[0]?.length, 64);
  assertEquals(hashesRecebidos[0]?.includes("eyJhbGciOi"), false);

  // 2. Replay do mesmo id_token: banco devolve token_ja_usado -> 409 + revoga scope=local
  const res2 = await tratarAutenticarSocial(makeReq(), {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    loginSocialAtivo: true,
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
    loginSocialAtivo: true,
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
    loginSocialAtivo: true,
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
    loginSocialAtivo: true,
    db: dbStub(),
  });
  assertEquals(res409Conflito.status, 409);
  assertEquals((await res409Conflito.json()).code, "conflito_identidade");

  const res409ReplayTx = await tratarAutenticarSocial(reqBase(), {
    fetchFn: () => Promise.resolve(Response.json(sessaoFake())),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    loginSocialAtivo: true,
    db: dbStub({ consumirTransacaoOauth: () => Promise.resolve({ ok: false, motivo: "desafio_ja_usado" }) }),
  });
  assertEquals(res409ReplayTx.status, 409);
  assertEquals((await res409ReplayTx.json()).code, "desafio_ja_usado");

  const res410 = await tratarAutenticarSocial(reqBase(), {
    fetchFn: () => Promise.resolve(Response.json(sessaoFake())),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    loginSocialAtivo: true,
    db: dbStub({ consumirTransacaoOauth: () => Promise.resolve({ ok: false, motivo: "desafio_expirado" }) }),
  });
  assertEquals(res410.status, 410);
  assertEquals((await res410.json()).code, "desafio_expirado");
});

Deno.test("autenticar-social: gate server-side fail-closed default OFF bloqueia antes de GoTrue e SQL", async () => {
  let chamouGoTrue = false;
  let chamouSql = false;
  const req = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.10" },
    body: JSON.stringify({
      provedor: "google",
      fluxo: "iniciar_pkce",
      plataforma: "android",
      code_challenge: "c".repeat(43),
      redirect_to: "frila-auth://auth/callback",
    }),
  });

  const res = await tratarAutenticarSocial(req, {
    fetchFn: () => {
      chamouGoTrue = true;
      return Promise.resolve(Response.json({}));
    },
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub({
      consumirRateLimit: () => {
        chamouSql = true;
        return Promise.resolve(true);
      },
      criarTransacaoOauth: () => {
        chamouSql = true;
        return Promise.resolve({ ok: true, transacao_id: TX_ID, expira_em: "2026-11-25T21:10:00Z" });
      },
    }),
  });

  assertEquals(res.status, 503);
  assertEquals((await res.json()).code, "indisponivel");
  assertEquals(res.headers.get("Cache-Control"), "no-store");
  assertEquals(chamouGoTrue, false);
  assertEquals(chamouSql, false);
});

Deno.test("autenticar-social: rejeita alias base64url com bits nao significativos alterados na assinatura do id_token", async () => {
  // Base64url de 1 byte (0x00) canônico é "AA"; "AB" decodifica para o mesmo byte 0x00 com bit extra setado.
  const header = btoa(JSON.stringify({ alg: "RS256", typ: "JWT" })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const payload = btoa(JSON.stringify({ sub: "11111111-1111-4111-8111-111111111111" })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const jwtCanonico = `${header}.${payload}.AA`;
  const jwtAlias = `${header}.${payload}.AB`;

  const hashOk = await calcularHashCanonicoIdToken("apple", jwtCanonico);
  const hashAlias = await calcularHashCanonicoIdToken("apple", jwtAlias);
  assertEquals(hashOk?.length, 64);
  assertEquals(hashAlias, null);

  let chamouGoTrue = false;
  const req = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.44" },
    body: JSON.stringify({
      provedor: "apple",
      fluxo: "id_token",
      plataforma: "ios",
      id_token: jwtAlias,
      nonce: "nonce-bruto-32bytes-sintetico",
    }),
  });

  const res = await tratarAutenticarSocial(req, {
    fetchFn: () => {
      chamouGoTrue = true;
      return Promise.resolve(Response.json(sessaoFake()));
    },
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    loginSocialAtivo: true,
    db: dbStub(),
  });

  assertEquals(res.status, 422);
  assertEquals((await res.json()).code, "campo_invalido");
  assertEquals(chamouGoTrue, false);
});

Deno.test("autenticar-social: excecao de rede no refresh executa cleanup completo (scope=local + revogarSessaoPontual) e devolve 503 sem desconsumir prova", async () => {
  let revogouLocal = false;
  let revogouPontual = false;
  const fetchFn: typeof fetch = (input) => {
    const url = String(input);
    if (url.includes("grant_type=id_token")) return Promise.resolve(Response.json(sessaoFake("sess-rede")));
    if (url.includes("grant_type=refresh_token")) return Promise.reject(new TypeError("network down"));
    if (url.includes("/auth/v1/logout?scope=local")) {
      revogouLocal = true;
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    throw new Error(`URL inesperada: ${url}`);
  };

  const req = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.44" },
    body: JSON.stringify({
      provedor: "apple",
      fluxo: "id_token",
      plataforma: "ios",
      id_token: fakeJwt("22222222-2222-4222-8222-222222222222"),
      nonce: "nonce-bruto-32bytes-sintetico",
    }),
  });

  const res = await tratarAutenticarSocial(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    loginSocialAtivo: true,
    aguardarMs: () => Promise.resolve(),
    db: dbStub({
      revogarSessaoPontual: () => {
        revogouPontual = true;
        return Promise.resolve();
      },
    }),
  });

  assertEquals(res.status, 503);
  assertEquals((await res.json()).code, "indisponivel");
  assertEquals(revogouLocal, true);
  assertEquals(revogouPontual, true);
});

Deno.test("autenticar-social: falha 503 transitoria no refresh recupera com retry interno bounded e devolve 200 sem desconsumir prova nem revogar", async () => {
  let tentativasRefresh = 0;
  let revogouLocal = false;
  let revogouPontual = false;
  let chamadasConcluir = 0;
  const fetchFn: typeof fetch = (input) => {
    const url = String(input);
    if (url.includes("grant_type=id_token")) return Promise.resolve(Response.json(sessaoFake("sess-prov")));
    if (url.includes("grant_type=refresh_token")) {
      tentativasRefresh++;
      if (tentativasRefresh < 3) {
        return Promise.resolve(new Response("temporarily unavailable", { status: 503 }));
      }
      return Promise.resolve(Response.json(sessaoFake("sess-recuperada")));
    }
    if (url.includes("/auth/v1/logout?scope=local")) {
      revogouLocal = true;
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    throw new Error(`URL inesperada: ${url}`);
  };

  const req = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.44" },
    body: JSON.stringify({
      provedor: "apple",
      fluxo: "id_token",
      plataforma: "ios",
      id_token: fakeJwt("22222222-2222-4222-8222-222222222222"),
      nonce: "nonce-bruto-32bytes-sintetico",
    }),
  });

  const res = await tratarAutenticarSocial(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    loginSocialAtivo: true,
    aguardarMs: () => Promise.resolve(),
    db: dbStub({
      concluirLoginSocial: () => {
        chamadasConcluir++;
        return Promise.resolve({ ok: true, precisa_definir_senha: false });
      },
      revogarSessaoPontual: () => {
        revogouPontual = true;
        return Promise.resolve();
      },
    }),
  });

  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.sessao.refresh_token, "ref-sess-recuperada");
  assertEquals(tentativasRefresh, 3);
  assertEquals(chamadasConcluir, 1);
  assertEquals(revogouLocal, false);
  assertEquals(revogouPontual, false);
});

Deno.test("autenticar-social: erro 400 definitivo no refresh falha imediato sem retry e executa cleanup fail-closed mesmo se Postgres falhar", async () => {
  let tentativasRefresh = 0;
  let revogouLocal = false;
  const fetchFn: typeof fetch = (input) => {
    const url = String(input);
    if (url.includes("grant_type=id_token")) return Promise.resolve(Response.json(sessaoFake("sess-400")));
    if (url.includes("grant_type=refresh_token")) {
      tentativasRefresh++;
      return Promise.resolve(Response.json({ error: "invalid_grant" }, { status: 400 }));
    }
    if (url.includes("/auth/v1/logout?scope=local")) {
      revogouLocal = true;
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    throw new Error(`URL inesperada: ${url}`);
  };

  const req = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.44" },
    body: JSON.stringify({
      provedor: "apple",
      fluxo: "id_token",
      plataforma: "ios",
      id_token: fakeJwt("22222222-2222-4222-8222-222222222222"),
      nonce: "nonce-bruto-32bytes-sintetico",
    }),
  });

  const res = await tratarAutenticarSocial(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    loginSocialAtivo: true,
    aguardarMs: () => Promise.resolve(),
    db: dbStub({
      revogarSessaoPontual: () => Promise.reject(new Error("postgres indisponivel")),
    }),
  });

  assertEquals(res.status, 503);
  assertEquals((await res.json()).code, "indisponivel");
  assertEquals(tentativasRefresh, 1);
  assertEquals(revogouLocal, true);
});

Deno.test("autenticar-social: mobile sem cf-connecting-ip falha fechado (503) sem pular rate limit nem confiar em x-forwarded-for", async () => {
  let chamouGoTrue = false;
  let chamouRateLimit = false;
  const req = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-forwarded-for": "192.0.2.99" },
    body: JSON.stringify({
      provedor: "google",
      fluxo: "iniciar_pkce",
      plataforma: "android",
      code_challenge: "c".repeat(43),
      redirect_to: "frila-auth://auth/callback",
    }),
  });

  const res = await tratarAutenticarSocial(req, {
    fetchFn: () => {
      chamouGoTrue = true;
      return Promise.resolve(Response.json({}));
    },
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    loginSocialAtivo: true,
    db: dbStub({
      consumirRateLimit: () => {
        chamouRateLimit = true;
        return Promise.resolve(true);
      },
    }),
  });

  assertEquals(res.status, 503);
  assertEquals((await res.json()).code, "indisponivel");
  assertEquals(chamouGoTrue, false);
  assertEquals(chamouRateLimit, false);
});

Deno.test("autenticar-social: allowlist aceita App Link HTTPS exato (com e sem ?tx) e rejeita variações de host/path/scheme/prefixo", async () => {
  // Positivos: callback HTTPS exato Android Release App Link
  assertEquals(ehRedirectPermitido("https://frilabr.com/app/auth/callback"), true);
  assertEquals(ehRedirectPermitido(`https://frilabr.com/app/auth/callback?tx=${TX_ID}`), true);

  // Negativos: host, path, prefixo indevido, scheme, porta, fragmento, userinfo, traversal
  const negativos = [
    "http://frilabr.com/app/auth/callback",
    "http://frilabr.com/app/auth/callback?tx=123",
    "https://evil.frilabr.com/app/auth/callback",
    "https://frilabr.com.evil.com/app/auth/callback",
    "https://frila-web-dev.frilabr.workers.dev/app/auth/callback",
    "https://frilabr.com/app/auth/callback/",
    "https://frilabr.com/app/auth/callback2",
    "https://frilabr.com/app/auth/callback/extra",
    "https://frilabr.com/app/auth/outro",
    "https://frilabr.com/app/foo/../auth/callback",
    "https://frilabr.com:443/app/auth/callback",
    "https://frilabr.com:8443/app/auth/callback",
    "https://frilabr.com/app/auth/callback#frag",
    "https://user@frilabr.com/app/auth/callback",
    "javascript://frilabr.com/app/auth/callback",
  ];
  for (const url of negativos) {
    assertEquals(ehRedirectPermitido(url), false, `deveria rejeitar: ${url}`);
  }

  // Integração iniciar_pkce (android) com App Link HTTPS exato + ?tx devolve 200
  const redirectComTx = `https://frilabr.com/app/auth/callback?tx=${TX_ID}`;
  const reqOk = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.55" },
    body: JSON.stringify({
      provedor: "google",
      fluxo: "iniciar_pkce",
      plataforma: "android",
      code_challenge: "c".repeat(43),
      redirect_to: redirectComTx,
    }),
  });
  const resOk = await tratarAutenticarSocial(reqOk, {
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub(),
    loginSocialAtivo: true,
  });
  assertEquals(resOk.status, 200);
  const bodyOk = await resOk.json();
  const urlAuth = new URL(bodyOk.url_autorizacao);
  assertEquals(urlAuth.searchParams.get("redirect_to"), redirectComTx);

  // Integração iniciar_pkce com path fora da allowlist devolve 422
  const reqBad = new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": "198.51.100.55" },
    body: JSON.stringify({
      provedor: "google",
      fluxo: "iniciar_pkce",
      plataforma: "android",
      code_challenge: "c".repeat(43),
      redirect_to: "https://frilabr.com/app/auth/callback/extra",
    }),
  });
  const resBad = await tratarAutenticarSocial(reqBad, {
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: dbStub(),
    loginSocialAtivo: true,
  });
  assertEquals(resBad.status, 422);
});
