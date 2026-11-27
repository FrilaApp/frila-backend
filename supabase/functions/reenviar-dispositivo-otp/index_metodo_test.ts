import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  type ReenviarDesafioDeps,
  tratarReenviarDispositivoOtp,
} from "./index.ts";

// Cartão qnsllUU1: só POST é aceito. GET e PUT respondem 405 metodo_nao_permitido antes de qualquer dependência
// (limite de tentativa, banco, GoTrue). O PUT leva um corpo e cabeçalhos válidos, para que sem a guarda de método a
// requisição seguisse adiante e tocasse as dependências espionadas.

function depsEspionadas(chamadas: string[]): ReenviarDesafioDeps {
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
    db: db as NonNullable<ReenviarDesafioDeps["db"]>,
  };
}

for (const metodo of ["GET", "PUT"]) {
  Deno.test(`reenviar-dispositivo-otp: ${metodo} responde 405 metodo_nao_permitido sem chamar nenhuma dependência`, async () => {
    const chamadas: string[] = [];
    const req = new Request(
      "https://local/functions/v1/reenviar-dispositivo-otp",
      {
        method: metodo,
        headers: {
          "Content-Type": "application/json",
          "cf-connecting-ip": "198.51.100.1",
        },
        body: metodo === "GET" ? undefined : JSON.stringify({
          desafio_id: "11111111-1111-4111-8111-111111111111",
        }),
      },
    );

    const res = await tratarReenviarDispositivoOtp(
      req,
      depsEspionadas(chamadas),
    );

    assertEquals(chamadas, []);
    assertEquals(res.status, 405);
    assertEquals((await res.json()).code, "metodo_nao_permitido");
  });
}
