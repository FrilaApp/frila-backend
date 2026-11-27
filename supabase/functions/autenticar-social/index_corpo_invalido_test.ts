import { assertEquals } from "jsr:@std/assert@1.0.19";
import { type AutenticarSocialDeps, tratarAutenticarSocial } from "./index.ts";

// Item 140: cada validação do corpo (index.ts:320-363) recusa com 422 campo_invalido e `details` igual ao nome do campo, antes
// de qualquer dependência (limite de tentativa, banco, GoTrue). Cada linha da tabela deixa válidos os campos que vêm antes e
// quebra só o seu; sem a validação dela, a requisição seguiria até o limite de tentativa ou o GoTrue espionados.

function jwtSintetico(): string {
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" })).replace(
    /=/g,
    "",
  );
  const payload = btoa(
    JSON.stringify({ sub: "11111111-1111-4111-8111-111111111111" }),
  ).replace(/=/g, "");
  return `${header}.${payload}.sig`;
}

const NONCE = "nonce-bruto-32bytes-sintetico";
const BASE = { provedor: "google", plataforma: "android" };
const INICIAR_PKCE = {
  ...BASE,
  fluxo: "iniciar_pkce",
  code_challenge: "c".repeat(43),
  redirect_to: "https://frilabr.com/app/entrar/google/retorno",
};
const PKCE = {
  ...BASE,
  fluxo: "pkce",
  transacao_id: "33333333-3333-4333-8333-333333333333",
  codigo: "cod-oauth-1234",
  code_verifier: "v".repeat(43),
};
const ID_TOKEN = {
  ...BASE,
  fluxo: "id_token",
  id_token: jwtSintetico(),
  nonce: NONCE,
};

const casos: Array<{ rotulo: string; corpo: string; campo: string }> = [
  { rotulo: "JSON ilegível", corpo: "{nao e json", campo: "corpo" },
  {
    rotulo: "corpo em lista",
    corpo: JSON.stringify([INICIAR_PKCE]),
    campo: "corpo",
  },
  { rotulo: "corpo nulo", corpo: "null", campo: "corpo" },
  {
    rotulo: "provedor desconhecido",
    corpo: JSON.stringify({ ...INICIAR_PKCE, provedor: "facebook" }),
    campo: "provedor",
  },
  {
    rotulo: "fluxo desconhecido",
    corpo: JSON.stringify({ ...INICIAR_PKCE, fluxo: "implicito" }),
    campo: "fluxo",
  },
  {
    rotulo: "plataforma desconhecida",
    corpo: JSON.stringify({ ...INICIAR_PKCE, plataforma: "desktop" }),
    campo: "plataforma",
  },
  {
    rotulo: "code_challenge curto",
    corpo: JSON.stringify({ ...INICIAR_PKCE, code_challenge: "c".repeat(42) }),
    campo: "code_challenge",
  },
  {
    rotulo: "redirect_to fora da lista",
    corpo: JSON.stringify({
      ...INICIAR_PKCE,
      redirect_to: "https://atacante.example/app/entrar/",
    }),
    campo: "redirect_to",
  },
  {
    rotulo: "transacao_id que não é UUID",
    corpo: JSON.stringify({ ...PKCE, transacao_id: "tx-1" }),
    campo: "transacao_id",
  },
  {
    rotulo: "codigo curto",
    corpo: JSON.stringify({ ...PKCE, codigo: "abc" }),
    campo: "codigo",
  },
  {
    rotulo: "code_verifier curto",
    corpo: JSON.stringify({ ...PKCE, code_verifier: "v".repeat(42) }),
    campo: "code_verifier",
  },
  {
    rotulo: "id_token curto",
    corpo: JSON.stringify({ ...ID_TOKEN, id_token: "YQ.YQ.YQ" }),
    campo: "id_token",
  },
  // O espaço também quebra o base64url da checagem seguinte (index.ts:365), com a mesma resposta: esta linha fixa a recusa,
  // mas tirar só o `/\s/` de index.ts:362 não muda o que sai. Curto e longo usam partes base64url válidas para que só a
  // checagem de tamanho os recuse.
  {
    rotulo: "id_token com espaço",
    corpo: JSON.stringify({ ...ID_TOKEN, id_token: "aaaaaaaa.bbbb bbbb.cccc" }),
    campo: "id_token",
  },
  {
    rotulo: "id_token longo demais",
    corpo: JSON.stringify({
      ...ID_TOKEN,
      id_token: `YQ.${"YWFh".repeat(2048)}.YQ`,
    }),
    campo: "id_token",
  },
  {
    rotulo: "nonce curto",
    corpo: JSON.stringify({ ...ID_TOKEN, nonce: "curto" }),
    campo: "nonce",
  },
  {
    rotulo: "nonce longo demais",
    corpo: JSON.stringify({ ...ID_TOKEN, nonce: "n".repeat(257) }),
    campo: "nonce",
  },
  {
    rotulo: "id_token sem as três partes em base64url",
    corpo: JSON.stringify({ ...ID_TOKEN, id_token: "aaaaaaaaaaaaaaaaaaaa" }),
    campo: "id_token",
  },
];

function depsEspionadas(chamadas: string[]): AutenticarSocialDeps {
  const db = new Proxy({}, {
    get: (_alvo, nome) =>
      nome === "then" ? undefined : (..._args: unknown[]) => {
        chamadas.push(`db.${String(nome)}`);
        throw new Error(`db.${String(nome)} não deveria ser chamado`);
      },
  });
  return {
    fetchFn: (entrada: string | URL | Request) => {
      chamadas.push(
        `fetch ${entrada instanceof Request ? entrada.url : String(entrada)}`,
      );
      return Promise.reject(new Error("fetch não deveria ser chamado"));
    },
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-teste",
    dbUrl: "postgres://teste",
    loginSocialAtivo: true,
    aguardarMs: (ms) => {
      chamadas.push(`aguardarMs(${ms})`);
      return Promise.resolve();
    },
    db: db as NonNullable<AutenticarSocialDeps["db"]>,
  };
}

for (const { rotulo, corpo, campo } of casos) {
  Deno.test(`autenticar-social: ${rotulo} responde 422 campo_invalido com details ${campo}, sem banco nem GoTrue`, async () => {
    const chamadas: string[] = [];
    const req = new Request("https://local/functions/v1/autenticar-social", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "cf-connecting-ip": "198.51.100.1",
      },
      body: corpo,
    });

    const res = await tratarAutenticarSocial(req, depsEspionadas(chamadas));

    assertEquals(chamadas, []);
    assertEquals(res.status, 422);
    const erro = await res.json();
    assertEquals(erro.code, "campo_invalido");
    assertEquals(erro.details, campo);
  });
}

// Controle: os três corpos-base passam pela validação e chegam ao limite de tentativa. Sem isto, uma linha da tabela poderia
// recusar por outro campo quebrado sem querer, e a mutação de tirar a validação dela não mudaria nada.
for (const base of [INICIAR_PKCE, PKCE, ID_TOKEN]) {
  Deno.test(`autenticar-social: corpo-base ${base.fluxo} é válido e chega ao limite de tentativa`, async () => {
    const chamadas: string[] = [];
    const req = new Request("https://local/functions/v1/autenticar-social", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "cf-connecting-ip": "198.51.100.1",
      },
      body: JSON.stringify(base),
    });

    await tratarAutenticarSocial(req, depsEspionadas(chamadas)).catch(() => {});

    assertEquals(chamadas[0], "db.consumirRateLimit");
  });
}
