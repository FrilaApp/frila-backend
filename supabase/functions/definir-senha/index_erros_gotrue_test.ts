// Cartão TRgSwxUQ: definir-senha traduz as recusas do GoTrue para os códigos do contrato.
// O #665 cobriu a validação antes do GoTrue; aqui o GoTrue (o fetch falso) é que recusa, com o corpo que ele manda
// (`{ code, error_code, msg }`), e nenhuma recusa pode concluir a definição (limpar a pendência ou revogar dispositivos).

import { assertEquals } from "jsr:@std/assert@1.0.19";
import { tratarDefinirSenha } from "./index.ts";

function fakeJwt(sessionId: string): string {
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" })).replace(
    /=/g,
    "",
  );
  const payload = btoa(JSON.stringify({ sub: "user-1", session_id: sessionId }))
    .replace(/=/g, "");
  return `${header}.${payload}.sig`;
}

interface Chamadas {
  get: number;
  put: number;
  concluir: number;
}

async function chamar(
  respostaDoGet: () => Response,
  respostaDoPut: () => Response,
): Promise<
  { status: number; corpo: Record<string, unknown>; chamadas: Chamadas }
> {
  const chamadas: Chamadas = { get: 0, put: 0, concluir: 0 };
  const fetchFn: typeof fetch = (input, init) => {
    const url = String(input);
    const metodo = init?.method ?? "GET";
    if (url.endsWith("/auth/v1/user") && metodo === "GET") {
      chamadas.get++;
      return Promise.resolve(respostaDoGet());
    }
    if (url.endsWith("/auth/v1/user") && metodo === "PUT") {
      chamadas.put++;
      return Promise.resolve(respostaDoPut());
    }
    throw new Error(`URL inesperada: ${metodo} ${url}`);
  };
  const req = new Request("https://local/functions/v1/definir-senha", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${fakeJwt("sess-1")}`,
    },
    body: JSON.stringify({ nova_senha: "NovaSenhaForte123!" }),
  });
  const res = await tratarDefinirSenha(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    pepper: "pepper-test",
    db: {
      verificarSessaoOnline: () => Promise.resolve(true),
      concluirDefinicaoSenha: () => {
        chamadas.concluir++;
        return Promise.resolve({ dispositivos_revogados: 0 });
      },
    },
  });
  return { status: res.status, corpo: await res.json(), chamadas };
}

/** O corpo de erro do GoTrue: `code` é o status HTTP; o que distingue a recusa é `error_code`. */
function erroDoGoTrue(status: number, errorCode: string | null): Response {
  const corpo: Record<string, unknown> = {
    code: status,
    msg: "recusa sintética",
  };
  if (errorCode !== null) corpo.error_code = errorCode;
  return Response.json(corpo, { status });
}

const usuario = () => Response.json({ id: "user-1" });

const tabela: Array<{
  caso: string;
  put: () => Response;
  status: number;
  code: string;
  details: string | null;
}> = [
  {
    caso: "429 com error_code de limite",
    put: () => erroDoGoTrue(429, "over_request_rate_limit"),
    status: 429,
    code: "limite_excedido",
    details: null,
  },
  {
    caso: "429 sem error_code",
    put: () => erroDoGoTrue(429, null),
    status: 429,
    code: "limite_excedido",
    details: null,
  },
  {
    caso: "422 same_password",
    put: () => erroDoGoTrue(422, "same_password"),
    status: 422,
    code: "senha_igual",
    details: "nova_senha",
  },
  {
    caso: "422 weak_password",
    put: () => erroDoGoTrue(422, "weak_password"),
    status: 422,
    code: "senha_fraca",
    details: "nova_senha",
  },
  {
    caso: "400 com outro error_code (validation_failed)",
    put: () => erroDoGoTrue(400, "validation_failed"),
    status: 422,
    code: "campo_invalido",
    details: "nova_senha",
  },
  {
    caso: "422 sem error_code nem corpo JSON",
    put: () => new Response("falha", { status: 422 }),
    status: 422,
    code: "campo_invalido",
    details: "nova_senha",
  },
];

for (const { caso, put, status, code, details } of tabela) {
  Deno.test(`definir-senha: PUT do GoTrue com ${caso} vira ${status} ${code}, sem concluir a definição`, async () => {
    const r = await chamar(usuario, put);

    assertEquals(r.status, status);
    assertEquals(r.corpo.code, code);
    assertEquals(r.corpo.details, details);
    assertEquals(r.chamadas, { get: 1, put: 1, concluir: 0 });
  });
}

Deno.test("definir-senha: 429 já no GET do GoTrue vira 429 limite_excedido, sem tentar o PUT", async () => {
  const r = await chamar(
    () => erroDoGoTrue(429, "over_request_rate_limit"),
    usuario,
  );

  assertEquals(r.status, 429);
  assertEquals(r.corpo.code, "limite_excedido");
  assertEquals(r.chamadas, { get: 1, put: 0, concluir: 0 });
});

Deno.test("definir-senha: controle, o PUT aceito conclui a definição uma vez", async () => {
  const r = await chamar(usuario, usuario);

  assertEquals(r.status, 200);
  assertEquals(r.corpo.ok, true);
  assertEquals(r.chamadas, { get: 1, put: 1, concluir: 1 });
});
