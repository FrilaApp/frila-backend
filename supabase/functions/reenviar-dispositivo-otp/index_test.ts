import { assertEquals } from "jsr:@std/assert@1.0.19";
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
  assertEquals(body.reenviar_em_segundos, 60);
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
