import { assertEquals } from "jsr:@std/assert@1.0.19";
import { type AutenticarSocialDeps, tratarAutenticarSocial } from "./index.ts";

// Cartão qnsllUU1: só POST é aceito. GET e PUT respondem 405 metodo_nao_permitido antes de qualquer dependência
// (limite de tentativa, banco, GoTrue). O PUT leva um corpo e cabeçalhos válidos, para que sem a guarda de método a
// requisição seguisse adiante e tocasse as dependências espionadas.

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

for (const metodo of ["GET", "PUT"]) {
  Deno.test(`autenticar-social: ${metodo} responde 405 metodo_nao_permitido sem chamar nenhuma dependência`, async () => {
    const chamadas: string[] = [];
    const req = new Request("https://local/functions/v1/autenticar-social", {
      method: metodo,
      headers: {
        "Content-Type": "application/json",
        "cf-connecting-ip": "198.51.100.1",
      },
      body: metodo === "GET" ? undefined : JSON.stringify({
        provedor: "apple",
        fluxo: "iniciar_pkce",
        plataforma: "android",
        code_challenge: "c".repeat(43),
        redirect_to:
          "https://frila-web-dev.frilabr.workers.dev/app/entrar/apple/retorno",
      }),
    });

    const res = await tratarAutenticarSocial(req, depsEspionadas(chamadas));

    assertEquals(chamadas, []);
    assertEquals(res.status, 405);
    assertEquals((await res.json()).code, "metodo_nao_permitido");
  });
}
