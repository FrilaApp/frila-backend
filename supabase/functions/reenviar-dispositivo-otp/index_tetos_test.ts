// im2mnI8W (99): o que o `index_test.ts` não mede em `reenviar-dispositivo-otp`: os tetos de reenvio.
//   - por IP (15 em 600 s, chave auth:reenvio:ip:<sha256>): 429 antes de gastar o reenvio do desafio;
//   - por e-mail (5 em 600 s, chave auth:otp:email:<email_hash do desafio>): 429 sem chamar o GoTrue;
//   - GoTrue 429 -> 429; GoTrue não-ok -> 503.
// Só função, sem banco: `db` e `fetch` são falsos e registram as chamadas. Só dados sintéticos.
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { hashSha256Hex } from "../_compartilhado/dispositivo_auth.ts";
import { type ReenviarDesafioDb, tratarReenviarDispositivoOtp } from "./index.ts";

const DESAFIO = "11111111-1111-4111-8111-111111111111";
const EMAIL_HASH = "hash-do-email-sintetico";
const DEPS_BASE = { supabaseUrl: "https://proj.supabase.co", anonKey: "anon-test" };

interface Registro {
  limites: { chave: string; limite: number; janela: number }[];
  reservas: string[];
  fetch: string[];
}

function novoRegistro(): Registro {
  return { limites: [], reservas: [], fetch: [] };
}

function dbRegistrando(reg: Registro, negar: (chave: string) => boolean = () => false): ReenviarDesafioDb {
  return {
    consumirRateLimit: (chave, limite, janela) => {
      reg.limites.push({ chave, limite, janela });
      return Promise.resolve(!negar(chave));
    },
    reservarReenvioDesafio: (id) => {
      reg.reservas.push(id);
      return Promise.resolve({
        status: "ok" as const,
        desafio_id: id,
        email_normalizado: "ana@frila.test",
        email_hash: EMAIL_HASH,
        expira_em: "2026-11-27T12:10:00Z",
      });
    },
  };
}

function fetchRegistrando(reg: Registro, status = 200): typeof fetch {
  return (input) => {
    reg.fetch.push(String(input));
    return Promise.resolve(new Response("{}", { status }));
  };
}

function req(ip: string): Request {
  return new Request("https://local/functions/v1/reenviar-dispositivo-otp", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": ip },
    body: JSON.stringify({ desafio_id: DESAFIO }),
  });
}

Deno.test("reenviar-dispositivo-otp: teto por IP (15 em 600 s) devolve 429 sem gastar o reenvio nem chamar o GoTrue, e só para o IP recusado", async () => {
  const ip = "198.51.100.10";
  const chaveIp = `auth:reenvio:ip:${await hashSha256Hex(ip)}`;

  const reg = novoRegistro();
  const res = await tratarReenviarDispositivoOtp(req(ip), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(reg),
    db: dbRegistrando(reg, (c) => c === chaveIp),
  });
  assertEquals(res.status, 429);
  assertEquals((await res.json()).code, "limite_excedido");
  assertEquals(reg.limites, [{ chave: chaveIp, limite: 15, janela: 600 }]);
  assertEquals(reg.reservas, [], "o reenvio do desafio não é gasto");
  assertEquals(reg.fetch, [], "o GoTrue não é chamado");

  const reg2 = novoRegistro();
  const res2 = await tratarReenviarDispositivoOtp(req("198.51.100.11"), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(reg2),
    db: dbRegistrando(reg2, (c) => c === chaveIp),
  });
  assertEquals(res2.status, 200, "outro IP passa");
});

Deno.test("reenviar-dispositivo-otp: teto por e-mail (5 em 600 s, chave do email_hash do desafio) devolve 429 sem chamar o GoTrue", async () => {
  const ip = "198.51.100.20";
  const chaveEmail = `auth:otp:email:${EMAIL_HASH}`;

  const reg = novoRegistro();
  const res = await tratarReenviarDispositivoOtp(req(ip), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(reg),
    db: dbRegistrando(reg, (c) => c === chaveEmail),
  });
  assertEquals(res.status, 429);
  assertEquals((await res.json()).code, "limite_excedido");
  assertEquals(reg.limites.map((l) => l.chave), [`auth:reenvio:ip:${await hashSha256Hex(ip)}`, chaveEmail]);
  assertEquals(reg.limites[1], { chave: chaveEmail, limite: 5, janela: 600 });
  assertEquals(reg.reservas, [DESAFIO]);
  assertEquals(reg.fetch, [], "o GoTrue não é chamado");
});

Deno.test("reenviar-dispositivo-otp: com os dois tetos liberados chama o GoTrue uma vez e devolve 200", async () => {
  const reg = novoRegistro();
  const res = await tratarReenviarDispositivoOtp(req("198.51.100.30"), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(reg),
    db: dbRegistrando(reg),
  });
  assertEquals(res.status, 200);
  assertEquals(reg.fetch, ["https://proj.supabase.co/auth/v1/otp"]);
  assertEquals(reg.limites.length, 2);
});

Deno.test("reenviar-dispositivo-otp: GoTrue 429 devolve 429 limite_excedido e GoTrue não-ok devolve 503 indisponivel", async () => {
  for (const [statusGoTrue, esperado, code] of [[429, 429, "limite_excedido"], [500, 503, "indisponivel"], [400, 503, "indisponivel"]] as const) {
    const reg = novoRegistro();
    const res = await tratarReenviarDispositivoOtp(req("198.51.100.40"), {
      ...DEPS_BASE,
      fetchFn: fetchRegistrando(reg, statusGoTrue),
      db: dbRegistrando(reg),
    });
    assertEquals(res.status, esperado, `GoTrue ${statusGoTrue}`);
    assertEquals((await res.json()).code, code, `GoTrue ${statusGoTrue}`);
  }
});
