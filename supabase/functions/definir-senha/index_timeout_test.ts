// Cartão jiOXZAno (item 221): os fetch de /auth/v1/user (GET de conferência e PUT da senha) não tinham prazo; um Auth que aceita a
// conexão e não responde prendia a função. Agora cada um leva `AbortSignal.timeout`, com o mesmo valor do `excluir-conta`.
//
// Relógio: o `FakeTime` do Deno controla o `AbortSignal.timeout` (medido), mas vem de `jsr:@std/testing`, que não está no `deno.lock`
// (dependência nova). Em vez dele, `deps.timeoutMs` pequeno e um fetch que só termina quando o sinal aborta.
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { TIMEOUT_PADRAO_MS } from "../excluir-conta/index.ts";
import { TIMEOUT_AUTH_MS } from "../_compartilhado/dispositivo_auth.ts";
import { tratarDefinirSenha } from "./index.ts";

function fakeJwt(sessionId: string): string {
  const b64 = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `${b64({ alg: "none" })}.${b64({ session_id: sessionId })}.sig`;
}

/** Fetch pendurado: só termina quando o sinal aborta (rejeita com o motivo do aborto), como um servidor que não responde. */
function pendurado(init: RequestInit | undefined): Promise<Response> {
  const sinal = init?.signal;
  return new Promise((_resolve, reject) => {
    if (!sinal) return; // sem prazo, esta promessa nunca termina: o teste cai pela guarda de tempo
    if (sinal.aborted) return reject(sinal.reason);
    sinal.addEventListener("abort", () => reject(sinal.reason), { once: true });
  });
}

/** Falha o teste em vez de pendurá-lo se a função não voltar em `ms`. */
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

function requisicao(): Request {
  return new Request("https://local/functions/v1/definir-senha", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${fakeJwt("sess-1")}` },
    body: JSON.stringify({ nova_senha: "NovaSenhaForte123!" }),
  });
}

const db = {
  verificarSessaoOnline: () => Promise.resolve(true),
  concluirDefinicaoSenha: () => Promise.resolve({ dispositivos_revogados: 0 }),
};

Deno.test("definir-senha: o prazo do Auth é o mesmo do excluir-conta", () => {
  assertEquals(TIMEOUT_AUTH_MS, TIMEOUT_PADRAO_MS);
});

Deno.test("definir-senha: GET /auth/v1/user pendurado é cortado pelo prazo e responde 503 indisponivel", async () => {
  const sinais: AbortSignal[] = [];
  const res = await emAte(
    tratarDefinirSenha(requisicao(), {
      supabaseUrl: "https://proj.supabase.co",
      anonKey: "anon-test",
      timeoutMs: 30,
      fetchFn: (_input, init) => {
        if (init?.signal) sinais.push(init.signal);
        return pendurado(init);
      },
      db,
    }),
    2_000,
    "GET /auth/v1/user pendurado",
  );

  assertEquals(res.status, 503);
  assertEquals((await res.json()).code, "indisponivel");
  assertEquals(sinais.length, 1, "o GET leva sinal");
  assert(sinais[0].aborted, "o sinal do GET abortou pelo prazo");
  assertEquals((sinais[0].reason as DOMException).name, "TimeoutError");
});

Deno.test("definir-senha: PUT /auth/v1/user pendurado é cortado pelo prazo (a resposta a essa falha é o item 220)", async () => {
  const sinais: Array<[string, AbortSignal]> = [];
  let desfecho = "voltou sem lançar";
  await emAte(
    tratarDefinirSenha(requisicao(), {
      supabaseUrl: "https://proj.supabase.co",
      anonKey: "anon-test",
      timeoutMs: 30,
      fetchFn: (_input, init) => {
        if ((init?.method ?? "GET") === "GET") return Promise.resolve(Response.json({ id: "user-1" }));
        if (init?.signal) sinais.push(["PUT", init.signal]);
        return pendurado(init);
      },
      db,
    }).then(() => {}, () => {
      // O que acontece com a falha do PUT é o item 220; aqui só importa que ela chegou, ou seja, que o PUT não ficou pendurado.
      desfecho = "lançou";
    }),
    2_000,
    "PUT /auth/v1/user pendurado",
  );

  assertEquals(sinais.length, 1, `o PUT leva sinal (${desfecho})`);
  assert(sinais[0][1].aborted, "o sinal do PUT abortou pelo prazo");
  assertEquals((sinais[0][1].reason as DOMException).name, "TimeoutError");
});

Deno.test("definir-senha: sem timeoutMs, o GET leva um sinal ainda não abortado (o prazo padrão vale)", async () => {
  const sinais: AbortSignal[] = [];
  const res = await tratarDefinirSenha(requisicao(), {
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    fetchFn: (_input, init) => {
      if (init?.signal) sinais.push(init.signal);
      return Promise.resolve(new Response("{}", { status: 503 }));
    },
    db,
  });

  assertEquals(res.status, 503);
  assertEquals(sinais.length, 1, "o GET leva sinal mesmo sem timeoutMs");
  assert(!sinais[0].aborted, "o prazo padrão (10 s) não venceu na hora");
});
