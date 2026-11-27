import { assertEquals } from "jsr:@std/assert@1.0.19";
import { hashSha256Hex, hashTokenDispositivo } from "../_compartilhado/dispositivo_auth.ts";
import { tratarReenviarDispositivoOtp } from "./index.ts";

Deno.test("reenviar-dispositivo-otp: mantém desafio_id, dispara OTP create_user=false usando e-mail server-side", async () => {
  const payloadsOtp: Record<string, unknown>[] = [];
  const fetchFn: typeof fetch = async (input, init) => {
    const url = String(input);
    if (url.includes("/auth/v1/otp")) {
      payloadsOtp.push(JSON.parse(String(init?.body ?? "{}")));
      return Response.json({});
    }
    throw new Error(`URL inesperada: ${url}`);
  };

  const id = "11111111-1111-4111-8111-111111111111";
  const req = new Request("https://local/functions/v1/reenviar-dispositivo-otp", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ desafio_id: id }),
  });

  const res = await tratarReenviarDispositivoOtp(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: {
      consumirRateLimit: () => Promise.resolve(true),
      reservarReenvioDesafio: () =>
        Promise.resolve({
          status: "ok",
          desafio_id: id,
          email_normalizado: "ana@frila.test",
          email_hash: "hash-ana",
          expira_em: "2026-11-25T00:15:00Z",
        }),
    },
  });

  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.ok, true);
  assertEquals(body.desafio_id, id);
  assertEquals(body.reenviar_em_segundos, 30);
  assertEquals(payloadsOtp[0]?.email, "ana@frila.test");
  assertEquals(payloadsOtp[0]?.create_user, false);
});

Deno.test("reenviar-dispositivo-otp: cooldown/teto devolve 429, expirado 410, já usado 409", async () => {
  const id = "11111111-1111-4111-8111-111111111111";
  for (const [st, codeHttp, codeErr] of [
    ["limite_excedido", 429, "limite_excedido"],
    ["desafio_expirado", 410, "desafio_expirado"],
    ["desafio_ja_usado", 409, "desafio_ja_usado"],
  ] as const) {
    const req = new Request("https://local/functions/v1/reenviar-dispositivo-otp", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ desafio_id: id }),
    });
    const res = await tratarReenviarDispositivoOtp(req, {
      fetchFn: () => Promise.resolve(Response.json({})),
      supabaseUrl: "https://proj.supabase.co",
      anonKey: "anon-test",
      db: {
        consumirRateLimit: () => Promise.resolve(true),
        reservarReenvioDesafio: () => Promise.resolve({ status: st }),
      },
    });
    assertEquals(res.status, codeHttp);
    assertEquals((await res.json()).code, codeErr);
  }
});

Deno.test("reenviar-dispositivo-otp: fecha bypass de rate limit por IP (Origin sem B-116 -> 403, B-116 inválido -> 403, mobile usa cf-connecting-ip)", async () => {
  const segredo = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  const carimbo = 1764030000;
  const opcoesIp = { chavesBrutas: `a1:${segredo}`, agoraSegundos: carimbo + 5 };
  const id = "11111111-1111-4111-8111-111111111111";

  // 1. Navegador direto (Origin presente, sem B-116): fail-closed 403.
  const reqOriginSemB116 = new Request("https://local/functions/v1/reenviar-dispositivo-otp", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Origin": "https://frilabr.com",
      "cf-connecting-ip": "198.51.100.1",
    },
    body: JSON.stringify({ desafio_id: id }),
  });
  const resOrigin = await tratarReenviarDispositivoOtp(reqOriginSemB116, {
    fetchFn: () => Promise.resolve(Response.json({})),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp,
    db: {
      consumirRateLimit: () => Promise.resolve(true),
      reservarReenvioDesafio: () => Promise.resolve({ status: "desafio_expirado" }),
    },
  });
  assertEquals(resOrigin.status, 403);
  assertEquals((await resOrigin.json()).code, "assinatura_ip_invalida");

  // 2. Cabeçalho B-116 adulterado: fail-closed 403.
  const reqForjado = new Request("https://local/functions/v1/reenviar-dispositivo-otp", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-frila-ip-visitante": "203.0.113.42",
      "x-frila-ip-carimbo": String(carimbo),
      "x-frila-ip-assinatura": "v1;k=a1;" + "f".repeat(64),
    },
    body: JSON.stringify({ desafio_id: id }),
  });
  const resForjado = await tratarReenviarDispositivoOtp(reqForjado, {
    fetchFn: () => Promise.resolve(Response.json({})),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp,
    db: {
      consumirRateLimit: () => Promise.resolve(true),
      reservarReenvioDesafio: () => Promise.resolve({ status: "desafio_expirado" }),
    },
  });
  assertEquals(resForjado.status, 403);
  assertEquals((await resForjado.json()).code, "assinatura_ip_invalida");

  // 3. Worker Web com B-116 válido: aplica rate limit pelo IP do visitante.
  const ipWeb = "203.0.113.88";
  const hmac = await hashTokenDispositivo(`v1|${ipWeb}|${carimbo}|anon`, segredo);
  const chavesWeb: string[] = [];
  const reqWebOk = new Request("https://local/functions/v1/reenviar-dispositivo-otp", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "cf-connecting-ip": "198.51.100.1",
      "x-frila-ip-visitante": ipWeb,
      "x-frila-ip-carimbo": String(carimbo),
      "x-frila-ip-assinatura": `v1;k=a1;${hmac}`,
    },
    body: JSON.stringify({ desafio_id: id }),
  });
  await tratarReenviarDispositivoOtp(reqWebOk, {
    fetchFn: () => Promise.resolve(Response.json({})),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp,
    db: {
      consumirRateLimit: (chave) => {
        chavesWeb.push(chave);
        return Promise.resolve(true);
      },
      reservarReenvioDesafio: () => Promise.resolve({ status: "desafio_expirado" }),
    },
  });
  assertEquals(chavesWeb.includes(`auth:reenvio:ip:${await hashSha256Hex(ipWeb)}`), true);

  // 4. Mobile direto sem Origin nem B-116: aplica rate limit por cf-connecting-ip (ignora x-forwarded-for).
  const chavesMobile: string[] = [];
  const reqMobile = new Request("https://local/functions/v1/reenviar-dispositivo-otp", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "cf-connecting-ip": "198.51.100.55",
      "x-forwarded-for": "192.0.2.99",
    },
    body: JSON.stringify({ desafio_id: id }),
  });
  await tratarReenviarDispositivoOtp(reqMobile, {
    fetchFn: () => Promise.resolve(Response.json({})),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    opcoesIp,
    db: {
      consumirRateLimit: (chave) => {
        chavesMobile.push(chave);
        return Promise.resolve(true);
      },
      reservarReenvioDesafio: () => Promise.resolve({ status: "desafio_expirado" }),
    },
  });
  assertEquals(chavesMobile.includes(`auth:reenvio:ip:${await hashSha256Hex("198.51.100.55")}`), true);
});
