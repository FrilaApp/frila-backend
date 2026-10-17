import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  emailsDeclarados,
  handler,
  HandlerDeps,
  igualEmTempoConstante,
  JANELA_MINUTOS,
  TETO_TENTATIVAS,
} from "./index.ts";

const MOCK_ORIGEM = "http://127.0.0.1:54321";
const MOCK_SERVICE_ROLE = "mock-service-role-key";
const MOCK_ANON = "mock-anon-key";
const MOCK_CODIGO = "123456";
const MOCK_EMAIL_REVISOR = "revisor@frila.app";
const MOCK_EMAIL_CONTRATANTE = "contratante-demo@frila.app";

const MOCK_SESSAO = {
  access_token: "mock-access-token",
  token_type: "bearer",
  expires_in: 3600,
  refresh_token: "mock-refresh-token",
  user: {
    id: "00000000-0000-0000-0000-000000000001",
    email: MOCK_EMAIL_REVISOR,
  },
};

interface MockState {
  tentativas: Array<{ id: number; email: string; em: string; aceita: boolean }>;
  proximoId: number;
  gerarLinkFalha?: boolean;
  verifyFalha?: boolean;
  restGravarFalha?: boolean;
  restJanelaFalha?: boolean;
}

function criarMockFetch(estado: MockState): typeof fetch {
  return (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const urlStr = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;

    // 1. Gravação inicial da tentativa (POST rest/v1/entrada_demonstracao)
    if (urlStr.endsWith("/rest/v1/entrada_demonstracao") && init?.method === "POST") {
      if (estado.restGravarFalha) {
        return Promise.resolve(new Response("Internal Server Error", { status: 500 }));
      }
      const corpo = JSON.parse(String(init?.body ?? "{}"));
      const tentativa = {
        id: estado.proximoId++,
        email: corpo.email,
        em: new Date().toISOString(),
        aceita: corpo.aceita ?? false,
      };
      estado.tentativas.push(tentativa);
      return Promise.resolve(
        new Response(JSON.stringify([tentativa]), {
          status: 201,
          headers: { "Content-Type": "application/json" },
        }),
      );
    }

    // 2. Consulta da janela de rate limit (GET rest/v1/entrada_demonstracao?...)
    if (urlStr.includes("/rest/v1/entrada_demonstracao?") && (!init?.method || init.method === "GET")) {
      if (estado.restJanelaFalha) {
        return Promise.resolve(new Response("Internal Server Error", { status: 500 }));
      }
      const url = new URL(urlStr);
      const emailParam = url.searchParams.get("email")?.replace(/^eq\./, "") ?? "";
      const emParam = url.searchParams.get("em")?.replace(/^gte\./, "");
      const limitParam = url.searchParams.get("limit");
      let matches = estado.tentativas.filter((t) => t.email === emailParam);
      if (emParam) {
        matches = matches.filter((t) => t.em >= emParam);
      }
      if (limitParam) {
        matches = matches.slice(0, Number(limitParam));
      }
      return Promise.resolve(
        new Response(JSON.stringify(matches.map((m) => ({ id: m.id }))), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      );
    }

    // 3. Atualização da tentativa para aceita=true (PATCH rest/v1/entrada_demonstracao?id=eq.X)
    if (urlStr.includes("/rest/v1/entrada_demonstracao?id=eq.") && init?.method === "PATCH") {
      const match = urlStr.match(/id=eq\.(\d+)/);
      const id = match ? Number(match[1]) : -1;
      const t = estado.tentativas.find((item) => item.id === id);
      if (t) {
        const corpo = JSON.parse(String(init?.body ?? "{}"));
        t.aceita = corpo.aceita ?? true;
      }
      return Promise.resolve(new Response(JSON.stringify({}), { status: 200 }));
    }

    // 4. Admin API generate_link
    if (urlStr.endsWith("/auth/v1/admin/generate_link") && init?.method === "POST") {
      if (estado.gerarLinkFalha) {
        return Promise.resolve(new Response(JSON.stringify({ error: "fail" }), { status: 400 }));
      }
      return Promise.resolve(
        new Response(JSON.stringify({ email_otp: "999888" }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      );
    }

    // 5. Auth verify (troca de OTP por Sessao)
    if (urlStr.endsWith("/auth/v1/verify") && init?.method === "POST") {
      if (estado.verifyFalha) {
        return Promise.resolve(new Response(JSON.stringify({ error: "fail" }), { status: 400 }));
      }
      return Promise.resolve(
        new Response(JSON.stringify(MOCK_SESSAO), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      );
    }

    return Promise.resolve(new Response("Not Found", { status: 404 }));
  };
}

function depsPadrao(estado: MockState, sobrescritas: Partial<HandlerDeps> = {}): HandlerDeps {
  return {
    fetchFn: criarMockFetch(estado),
    supabaseUrl: MOCK_ORIGEM,
    serviceRoleKey: MOCK_SERVICE_ROLE,
    anonKey: MOCK_ANON,
    emailsDeclarados: [MOCK_EMAIL_REVISOR, MOCK_EMAIL_CONTRATANTE],
    codigoEsperado: MOCK_CODIGO,
    ...sobrescritas,
  };
}

Deno.test("entrar-demonstracao: sucesso devolve 200 com Sessao e marca tentativa aceita", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1 };
  const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
  });

  const res = await handler(req, depsPadrao(estado));
  assertEquals(res.status, 200);

  const json = await res.json();
  assertEquals(json.access_token, MOCK_SESSAO.access_token);
  assertEquals(json.token_type, "bearer");
  assertEquals(json.user.email, MOCK_EMAIL_REVISOR);

  assertEquals(estado.tentativas.length, 1);
  assertEquals(estado.tentativas[0].aceita, true);
});

Deno.test("entrar-demonstracao: recusa 404 metodo nao-POST sem expor detalhes", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1 };
  const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "GET",
  });

  const res = await handler(req, depsPadrao(estado));
  assertEquals(res.status, 404);
  const json = await res.json();
  assertEquals(json.code, "nao_encontrado");
  assertEquals(json.message, "nao_encontrado");
  assertEquals(json.details, null);
  assertEquals(estado.tentativas.length, 0);
});

Deno.test("entrar-demonstracao: recusa 404 para email inexistente sem gravar tentativa no banco", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1 };
  const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: "desconhecido@exemplo.com", codigo: MOCK_CODIGO }),
  });

  const res = await handler(req, depsPadrao(estado));
  assertEquals(res.status, 404);
  const json = await res.json();
  assertEquals(json.code, "nao_encontrado");
  assertEquals(json.message, "nao_encontrado");
  assertEquals(json.details, null);
  // O endereço desconhecido não grava na tabela para evitar lixo de varreduras
  assertEquals(estado.tentativas.length, 0);
});

Deno.test("entrar-demonstracao: recusa 404 para corpo malformado ou campos vazios", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1 };

  // JSON inválido
  const reqInvalido = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{ malformado",
  });
  const resInvalido = await handler(reqInvalido, depsPadrao(estado));
  assertEquals(resInvalido.status, 404);
  assertEquals(await resInvalido.json(), { code: "nao_encontrado", message: "nao_encontrado", details: null });

  // Campos vazios
  const reqVazio = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: "", codigo: "" }),
  });
  const resVazio = await handler(reqVazio, depsPadrao(estado));
  assertEquals(resVazio.status, 404);
  assertEquals(await resVazio.json(), { code: "nao_encontrado", message: "nao_encontrado", details: null });

  assertEquals(estado.tentativas.length, 0);
});

Deno.test("entrar-demonstracao: recusa 404 codigo errado, mas grava tentativa consumindo cota", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1 };
  const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "codigo-errado-999" }),
  });

  const res = await handler(req, depsPadrao(estado));
  assertEquals(res.status, 404);
  const json = await res.json();
  assertEquals(json.code, "nao_encontrado");
  assertEquals(json.message, "nao_encontrado");
  assertEquals(json.details, null);

  // Tentativa gravada com aceita = false (consome cota antes de conferir o código)
  assertEquals(estado.tentativas.length, 1);
  assertEquals(estado.tentativas[0].aceita, false);
});

Deno.test("entrar-demonstracao: normaliza email da requisicao com espacos e maiusculas", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1 };
  const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: "  REVISOR@frila.app  ", codigo: MOCK_CODIGO }),
  });

  const res = await handler(req, depsPadrao(estado));
  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.user.email, MOCK_EMAIL_REVISOR);
  assertEquals(estado.tentativas.length, 1);
  assertEquals(estado.tentativas[0].email, MOCK_EMAIL_REVISOR);
});

Deno.test("entrar-demonstracao: caracterizacao de rate limit por email (10 tentativas em 10 min, risco Apple 2.1)", async () => {
  // Teste de caracterização: decisão do dono / comportamento atual, não necessariamente o desejado.
  // O limite de 10 tentativas em 10 minutos é contabilizado por e-mail no banco.
  // Risco registrado na NOTA-AUDITORIA-EDGE-FUNCTIONS.md e na descrição do #207:
  // se um terceiro souber o e-mail do revisor, pode forjar 10 requisições e travar a revisão da App Store por 10 minutos (risco de diretriz 2.1).
  const estado: MockState = {
    tentativas: [
      // Tentativa antiga (15 minutos atrás) que deve ser ignorada pelo filtro de janela (em=gte)
      {
        id: 99,
        email: MOCK_EMAIL_REVISOR,
        em: new Date(Date.now() - 15 * 60 * 1000).toISOString(),
        aceita: false,
      },
    ],
    proximoId: 1,
  };

  // 10 tentativas recentes para o e-mail do revisor travam no literal 10
  for (let i = 1; i <= 10; i++) {
    const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "errado" }),
    });
    const res = await handler(req, depsPadrao(estado));
    assertEquals(res.status, 404);
  }
  // 1 tentativa antiga + 10 recentes
  assertEquals(estado.tentativas.length, 11);

  // A 11ª tentativa recente contra o mesmo e-mail recebe 429 limite_excedido
  const reqBloqueada = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
  });
  const resBloqueada = await handler(reqBloqueada, depsPadrao(estado));
  assertEquals(resBloqueada.status, 429);
  const jsonBloqueada = await resBloqueada.json();
  assertEquals(jsonBloqueada.code, "limite_excedido");
  assertEquals(jsonBloqueada.message, "limite_excedido");
  assertEquals(jsonBloqueada.details, "tentativas");

  // Outro e-mail de demonstração (segundo perfil) NÃO é afetado pelo bloqueio do primeiro
  const reqOutroEmail = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_CONTRATANTE, codigo: MOCK_CODIGO }),
  });
  const resOutroEmail = await handler(reqOutroEmail, depsPadrao(estado));
  assertEquals(resOutroEmail.status, 200);
});

Deno.test("entrar-demonstracao: igualdade correta resistente a timing em comparacao de codigo", () => {
  assertEquals(igualEmTempoConstante("123456", "123456"), true);
  assertEquals(igualEmTempoConstante("123456", "123457"), false);
  assertEquals(igualEmTempoConstante("123456", "223456"), false);
  assertEquals(igualEmTempoConstante("123456", "12345"), false);
  assertEquals(igualEmTempoConstante("123456", "1234567"), false);
  assertEquals(igualEmTempoConstante("", ""), true);
  assertEquals(igualEmTempoConstante("a", ""), false);
});

Deno.test("entrar-demonstracao: emailsDeclarados normaliza espacos e maiusculas", () => {
  const orig = Deno.env.get("DEMONSTRACAO_EMAILS");
  try {
    Deno.env.set("DEMONSTRACAO_EMAILS", " User1@frila.app ,  USER2@frila.app, ");
    const lista = emailsDeclarados();
    assertEquals(lista, ["user1@frila.app", "user2@frila.app"]);
  } finally {
    if (orig !== undefined) Deno.env.set("DEMONSTRACAO_EMAILS", orig);
    else Deno.env.delete("DEMONSTRACAO_EMAILS");
  }
});

Deno.test("entrar-demonstracao: falha do banco ao registrar tentativa retorna 500 erro_interno", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1, restGravarFalha: true };
  const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
  });

  const res = await handler(req, depsPadrao(estado));
  assertEquals(res.status, 500);
  const json = await res.json();
  assertEquals(json.code, "erro_interno");
  assertEquals(json.message, "erro_interno");
  assertEquals(json.details, null);
});

Deno.test("entrar-demonstracao: falha do banco na janela retorna 500 erro_interno", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1, restJanelaFalha: true };
  const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
  });

  const res = await handler(req, depsPadrao(estado));
  assertEquals(res.status, 500);
  const json = await res.json();
  assertEquals(json.code, "erro_interno");
});

Deno.test("entrar-demonstracao: falha no admin generate_link ou verify retorna 404 nao_encontrado", async () => {
  // Falha em generate_link
  const estado1: MockState = { tentativas: [], proximoId: 1, gerarLinkFalha: true };
  const req1 = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
  });
  const res1 = await handler(req1, depsPadrao(estado1));
  assertEquals(res1.status, 404);
  assertEquals(await res1.json(), { code: "nao_encontrado", message: "nao_encontrado", details: null });

  // Falha em verify
  const estado2: MockState = { tentativas: [], proximoId: 1, verifyFalha: true };
  const req2 = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
  });
  const res2 = await handler(req2, depsPadrao(estado2));
  assertEquals(res2.status, 404);
  assertEquals(await res2.json(), { code: "nao_encontrado", message: "nao_encontrado", details: null });
});

Deno.test("mutação: entrar-demonstracao com codigoEsperado vazio ('') nao faz fallback para DEMONSTRACAO_CODIGO do ambiente", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1 };
  const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "codigo-do-ambiente-999" }),
  });

  const envAntigo = Deno.env.get("DEMONSTRACAO_CODIGO");
  try {
    Deno.env.set("DEMONSTRACAO_CODIGO", "codigo-do-ambiente-999");
    const res = await handler(req, depsPadrao(estado, { codigoEsperado: "" }));
    assertEquals(res.status, 404);
    const json = await res.json();
    assertEquals(json.code, "nao_encontrado");
    assertEquals(json.message, "nao_encontrado");
  } finally {
    if (envAntigo !== undefined) Deno.env.set("DEMONSTRACAO_CODIGO", envAntigo);
    else Deno.env.delete("DEMONSTRACAO_CODIGO");
  }
});

Deno.test("mutação: entrar-demonstracao sem DEMONSTRACAO_CODIGO no ambiente falha fechado com 404", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1 };
  const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
  });

  const envAntigo = Deno.env.get("DEMONSTRACAO_CODIGO");
  try {
    Deno.env.delete("DEMONSTRACAO_CODIGO");
    const res = await handler(req, depsPadrao(estado, { codigoEsperado: undefined }));
    assertEquals(res.status, 404);
    const json = await res.json();
    assertEquals(json.code, "nao_encontrado");
    assertEquals(json.message, "nao_encontrado");
  } finally {
    if (envAntigo !== undefined) Deno.env.set("DEMONSTRACAO_CODIGO", envAntigo);
    else Deno.env.delete("DEMONSTRACAO_CODIGO");
  }
});

