// Cartão jiOXZAno (item 221): o fetch de GET /auth/v1/user não tinha prazo; um Auth que aceita a conexão e não responde prendia a
// função. Agora leva `AbortSignal.timeout`, com o mesmo valor do `excluir-conta`. Relógio: ver `definir-senha/index_timeout_test.ts`
// (`FakeTime` precisaria de `jsr:@std/testing`, fora do `deno.lock`; aqui `deps.timeoutMs` pequeno e um fetch que só termina ao abortar).
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { TIMEOUT_PADRAO_MS } from "../excluir-conta/index.ts";
import { TIMEOUT_AUTH_MS } from "../_compartilhado/dispositivo_auth.ts";
import { tratarRevogarDispositivos } from "./index.ts";

function pendurado(init: RequestInit | undefined): Promise<Response> {
  const sinal = init?.signal;
  return new Promise((_resolve, reject) => {
    if (!sinal) return;
    if (sinal.aborted) return reject(sinal.reason);
    sinal.addEventListener("abort", () => reject(sinal.reason), { once: true });
  });
}

async function emAte<T>(promessa: Promise<T>, ms: number, quando: string): Promise<T> {
  let temporizador: ReturnType<typeof setTimeout> | undefined;
  const guarda = new Promise<never>((_r, rejeitar) => {
    temporizador = setTimeout(() => rejeitar(new Error(`a função não voltou em ${ms} ms: ${quando}`)), ms);
  });
  try {
    return await Promise.race([promessa, guarda]);
  } finally {
    clearTimeout(temporizador);
  }
}

const requisicao = () =>
  new Request("https://local/functions/v1/revogar-dispositivos", { method: "POST", headers: { Authorization: "Bearer jwt-x" } });

function db() {
  const registro = { verificacoes: 0, revogacoes: 0 };
  return {
    registro,
    db: {
      verificarSessaoOnline: () => {
        registro.verificacoes++;
        return Promise.resolve(true);
      },
      revogarTodosDispositivos: () => {
        registro.revogacoes++;
        return Promise.resolve(1);
      },
    },
  };
}

Deno.test("revogar-dispositivos: o prazo do Auth é o mesmo do excluir-conta", () => {
  assertEquals(TIMEOUT_AUTH_MS, TIMEOUT_PADRAO_MS);
});

Deno.test("revogar-dispositivos: GET /auth/v1/user pendurado é cortado pelo prazo e responde 503 indisponivel, sem revogar nada", async () => {
  const sinais: AbortSignal[] = [];
  const { db: banco, registro } = db();
  const res = await emAte(
    tratarRevogarDispositivos(requisicao(), {
      supabaseUrl: "https://proj.supabase.co",
      anonKey: "anon-test",
      timeoutMs: 30,
      fetchFn: (_input, init) => {
        if (init?.signal) sinais.push(init.signal);
        return pendurado(init);
      },
      db: banco,
    }),
    2_000,
    "GET /auth/v1/user pendurado",
  );

  assertEquals(res.status, 503);
  assertEquals((await res.json()).code, "indisponivel");
  assertEquals(sinais.length, 1, "o GET leva sinal");
  assert(sinais[0].aborted, "o sinal do GET abortou pelo prazo");
  assertEquals((sinais[0].reason as DOMException).name, "TimeoutError");
  assertEquals(registro, { verificacoes: 0, revogacoes: 0 });
});

Deno.test("revogar-dispositivos: sem timeoutMs, o GET leva um sinal ainda não abortado (o prazo padrão vale)", async () => {
  const sinais: AbortSignal[] = [];
  const { db: banco } = db();
  const res = await tratarRevogarDispositivos(requisicao(), {
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    fetchFn: (_input, init) => {
      if (init?.signal) sinais.push(init.signal);
      return Promise.resolve(new Response("{}", { status: 503 }));
    },
    db: banco,
  });

  assertEquals(res.status, 503);
  assertEquals(sinais.length, 1, "o GET leva sinal mesmo sem timeoutMs");
  assert(!sinais[0].aborted, "o prazo padrão (10 s) não venceu na hora");
});
