// Hrl32RqG (101): o que o `index_test.ts` não mede em `autenticar-social`.
//   - teto por IP (20 em 600 s, chave auth:social:ip:<sha256>): 429 quando `consumirRateLimit` recusa AQUELA chave, antes de qualquer transação,
//     consumo de código ou chamada ao GoTrue, nos três fluxos;
//   - GoTrue 429 -> 429 limite_excedido; GoTrue 5xx -> 503 indisponivel; nos dois, nada é concluído.
// Só função, sem banco: `db` e `fetch` são falsos e registram as chamadas. Só dados sintéticos.
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { hashSha256Hex } from "../_compartilhado/dispositivo_auth.ts";
import { type AutenticarSocialDb, tratarAutenticarSocial } from "./index.ts";

const TX_ID = "33333333-3333-4333-8333-333333333333";
const DEPS_BASE = { supabaseUrl: "https://proj.supabase.co", anonKey: "anon-test", loginSocialAtivo: true };

interface Registro {
  limites: { chave: string; limite: number; janela: number }[];
  transacoesCriadas: number;
  consumos: number;
  concluidos: number;
  fetch: string[];
}

function novoRegistro(): Registro {
  return { limites: [], transacoesCriadas: 0, consumos: 0, concluidos: 0, fetch: [] };
}

function dbRegistrando(reg: Registro, negar: (chave: string) => boolean = () => false): AutenticarSocialDb {
  return {
    consumirRateLimit: (chave, limite, janela) => {
      reg.limites.push({ chave, limite, janela });
      return Promise.resolve(!negar(chave));
    },
    criarTransacaoOauth: () => {
      reg.transacoesCriadas++;
      return Promise.resolve({ ok: true, transacao_id: TX_ID, expira_em: "2026-11-27T12:10:00Z" });
    },
    consumirTransacaoOauth: () => {
      reg.consumos++;
      return Promise.resolve({ ok: true, provedor: "apple" as const });
    },
    concluirLoginSocial: () => {
      reg.concluidos++;
      return Promise.resolve({ ok: true, precisa_definir_senha: false });
    },
    revogarSessaoPontual: () => Promise.resolve(),
  };
}

function fetchRegistrando(reg: Registro, status: number): typeof fetch {
  return (input) => {
    reg.fetch.push(String(input));
    return Promise.resolve(new Response("{}", { status }));
  };
}

// id_token com três partes base64url, como o servidor exige para o hash canônico.
const ID_TOKEN = [{ alg: "RS256" }, { sub: "sintetico", iss: "teste" }].map((o) => btoa(JSON.stringify(o)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_")).join(".") + ".c2ln";

const CORPOS: Record<string, Record<string, unknown>> = {
  iniciar_pkce: {
    provedor: "apple",
    fluxo: "iniciar_pkce",
    plataforma: "ios",
    code_challenge: "c".repeat(43),
    redirect_to: "https://frila-web-dev.frilabr.workers.dev/app/entrar/apple/retorno",
  },
  pkce: { provedor: "apple", fluxo: "pkce", plataforma: "ios", transacao_id: TX_ID, codigo: "cod-oauth-1234", code_verifier: "v".repeat(43) },
  id_token: { provedor: "apple", fluxo: "id_token", plataforma: "ios", id_token: ID_TOKEN, nonce: "n".repeat(32) },
};

function req(fluxo: string, ip: string): Request {
  return new Request("https://local/functions/v1/autenticar-social", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": ip },
    body: JSON.stringify(CORPOS[fluxo]),
  });
}

Deno.test("autenticar-social: teto por IP (20 em 600 s) devolve 429 antes de transação, consumo de código ou GoTrue, e só para o IP recusado", async () => {
  const ip = "198.51.100.10";
  const chaveIp = `auth:social:ip:${await hashSha256Hex(ip)}`;
  for (const fluxo of Object.keys(CORPOS)) {
    const reg = novoRegistro();
    const res = await tratarAutenticarSocial(req(fluxo, ip), {
      ...DEPS_BASE,
      fetchFn: fetchRegistrando(reg, 200),
      db: dbRegistrando(reg, (c) => c === chaveIp),
    });
    assertEquals(res.status, 429, fluxo);
    assertEquals((await res.json()).code, "limite_excedido", fluxo);
    assertEquals(reg.limites, [{ chave: chaveIp, limite: 20, janela: 600 }], fluxo);
    assertEquals([reg.transacoesCriadas, reg.consumos, reg.concluidos], [0, 0, 0], fluxo);
    assertEquals(reg.fetch, [], `${fluxo}: o GoTrue não é chamado`);
  }

  // Outro IP, com a recusa só para a chave do primeiro: o iniciar_pkce passa.
  const reg = novoRegistro();
  const res = await tratarAutenticarSocial(req("iniciar_pkce", "198.51.100.11"), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(reg, 200),
    db: dbRegistrando(reg, (c) => c === chaveIp),
  });
  assertEquals(res.status, 200);
  assertEquals(reg.transacoesCriadas, 1);
});

Deno.test("autenticar-social: GoTrue 429 devolve 429 limite_excedido e 5xx devolve 503 indisponivel, sem concluir o login", async () => {
  for (const fluxo of ["pkce", "id_token"]) {
    for (const [statusGoTrue, esperado, code] of [[429, 429, "limite_excedido"], [500, 503, "indisponivel"], [502, 503, "indisponivel"]] as const) {
      const reg = novoRegistro();
      const res = await tratarAutenticarSocial(req(fluxo, "198.51.100.20"), {
        ...DEPS_BASE,
        fetchFn: fetchRegistrando(reg, statusGoTrue),
        db: dbRegistrando(reg),
        aguardarMs: () => Promise.resolve(),
      });
      assertEquals(res.status, esperado, `${fluxo} GoTrue ${statusGoTrue}`);
      assertEquals((await res.json()).code, code, `${fluxo} GoTrue ${statusGoTrue}`);
      assertEquals(reg.concluidos, 0, `${fluxo} GoTrue ${statusGoTrue}`);
      assertEquals(reg.fetch.length >= 1, true, `${fluxo}: o GoTrue foi chamado`);
    }
  }
});
