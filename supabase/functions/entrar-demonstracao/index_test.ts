import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  emailsDeclarados,
  extrairIpCliente,
  handler,
  HandlerDeps,
  igualEmTempoConstante,
  JANELA_MINUTOS,
  parseLimiteJanela,
  registrarTentativaIp,
  resetarLimitesIp,
  verificarLimiteIp,
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
      const aceitaParam = url.searchParams.get("aceita")?.replace(/^eq\./, "");
      const limitParam = url.searchParams.get("limit");
      let matches = estado.tentativas.filter((t) => t.email === emailParam);
      if (emParam) {
        matches = matches.filter((t) => t.em >= emParam);
      }
      if (aceitaParam !== undefined && aceitaParam !== null && aceitaParam !== "") {
        matches = matches.filter((t) => String(t.aceita) === aceitaParam);
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
    ativaAte: "2030-01-01T00:00:00Z",
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

Deno.test("entrar-demonstracao: 11 tentativas erradas seguidas de 1 correta devolve 200 (diretriz 2.1 da Apple)", async () => {
  // Diretriz 2.1 da Apple: o código correto NUNCA é bloqueado por tentativas erradas anteriores.
  // Tentativas erradas além do teto recebem 404 uniforme (sem vazar 429) e não inundam a tabela.
  resetarLimitesIp();
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

  // 10 tentativas erradas recentes recebem 404; a 11ª excede o teto e recebe 429 limite_excedido
  for (let i = 1; i <= 10; i++) {
    const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-forwarded-for": `192.168.1.${i}` },
      body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "errado" }),
    });
    const res = await handler(req, depsPadrao(estado));
    assertEquals(res.status, 404);
  }

  const req11 = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-forwarded-for": "192.168.1.11" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "errado" }),
  });
  const res11 = await handler(req11, depsPadrao(estado));
  assertEquals(res11.status, 429);
  const json11 = await res11.json();
  assertEquals(json11.code, "limite_excedido");

  // Contenção de inundação: após 10 tentativas erradas recentes (mais 1 antiga = 11 no total),
  // a 11ª tentativa errada recente NÃO gravou nova linha no banco
  assertEquals(estado.tentativas.length, 11);

  // A 12ª tentativa com o CÓDIGO CORRETO do revisor DEVE ter sucesso (200 OK)
  const reqCorreta = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-forwarded-for": "10.0.0.1" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
  });
  const resCorreta = await handler(reqCorreta, depsPadrao(estado));
  assertEquals(resCorreta.status, 200);
  const jsonCorreta = await resCorreta.json();
  assertEquals(jsonCorreta.access_token, "mock-access-token");
  assertEquals(jsonCorreta.user.email, MOCK_EMAIL_REVISOR);

  // A tentativa correta foi registrada com aceita = true
  const ultimaTentativa = estado.tentativas[estado.tentativas.length - 1];
  assertEquals(ultimaTentativa.aceita, true);
  assertEquals(ultimaTentativa.email, MOCK_EMAIL_REVISOR);
});

Deno.test("entrar-demonstracao: 10 erradas do mesmo IP seguidas da correta do MESMO IP devolve 200 (IP no teto nao bloqueia codigo correto)", async () => {
  resetarLimitesIp();
  const estado: MockState = {
    tentativas: [],
    proximoId: 1,
  };

  const ipAtacante = "203.0.113.42";

  // 10 tentativas erradas do mesmo IP
  for (let i = 1; i <= 10; i++) {
    const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
      method: "POST",
      headers: { "Content-Type": "application/json", "cf-connecting-ip": ipAtacante },
      body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "codigo-errado-invalido" }),
    });
    const res = await handler(req, depsPadrao(estado));
    assertEquals(res.status, 404);
  }

  // 11ª tentativa errada do mesmo IP: bloqueada no Edge sem nem bater no banco
  const qtdBancoAntes = estado.tentativas.length;
  const reqBloqueada = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": ipAtacante },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "codigo-errado-invalido" }),
  });
  const resBloqueada = await handler(reqBloqueada, depsPadrao(estado));
  assertEquals(resBloqueada.status, 429);
  assertEquals((await resBloqueada.json()).code, "limite_excedido");
  assertEquals(estado.tentativas.length, qtdBancoAntes);

  // BLOQUEIO 1: A tentativa com o CÓDIGO CORRETO vinda do MESMO IP (que atingiu o teto)
  // NUNCA é bloqueada e DEVE retornar 200 OK
  const reqCorretaMesmoIp = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": ipAtacante },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
  });
  const resCorretaMesmoIp = await handler(reqCorretaMesmoIp, depsPadrao(estado));
  assertEquals(resCorretaMesmoIp.status, 200);
  const jsonCorreta = await resCorretaMesmoIp.json();
  assertEquals(jsonCorreta.access_token, "mock-access-token");
  assertEquals(jsonCorreta.user.email, MOCK_EMAIL_REVISOR);

  // A tentativa correta grava aceita = true
  const ultima = estado.tentativas[estado.tentativas.length - 1];
  assertEquals(ultima.aceita, true);
});

Deno.test("segurança: IP desconhecido ou ausente não possui bypass e sofre rate limit de 10 tentativas por janela (T-seguranca-backend-29-10)", async () => {
  resetarLimitesIp();
  const estado: MockState = {
    tentativas: [],
    proximoId: 1,
  };

  // Alterna entre os dois e-mails de demonstração (5 tentativas em cada, totalizando 10)
  // Sem header de IP ("desconhecido"):
  for (let i = 1; i <= 5; i++) {
    const req1 = new Request("http://localhost/functions/v1/entrar-demonstracao", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "codigo-errado" }),
    });
    const res1 = await handler(req1, depsPadrao(estado));
    assertEquals(res1.status, 404);

    const req2 = new Request("http://localhost/functions/v1/entrar-demonstracao", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: MOCK_EMAIL_CONTRATANTE, codigo: "codigo-errado" }),
    });
    const res2 = await handler(req2, depsPadrao(estado));
    assertEquals(res2.status, 404);
  }

  // Neste ponto: MOCK_EMAIL_REVISOR tem 5 tentativas no banco, MOCK_EMAIL_CONTRATANTE tem 5 tentativas no banco.
  // Nenhum e-mail atingiu o teto individual de 10 do banco.
  // Porém, o IP desconhecido acumulou 10 tentativas incorretas.
  // 11ª tentativa errada SEM header de IP: DEVE ser bloqueada no Edge pelo teto de IP com 429 limite_excedido!
  const qtdBancoAntes = estado.tentativas.length;
  assertEquals(qtdBancoAntes, 10);

  const reqBloqueada = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "codigo-errado" }),
  });
  const resBloqueada = await handler(reqBloqueada, depsPadrao(estado));
  assertEquals(resBloqueada.status, 429);
  assertEquals((await resBloqueada.json()).code, "limite_excedido");
  assertEquals(estado.tentativas.length, qtdBancoAntes);

  // Código correto sem header de IP não é bloqueado (Diretriz 2.1 Apple)
  const reqCorreta = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
  });
  const resCorreta = await handler(reqCorreta, depsPadrao(estado));
  assertEquals(resCorreta.status, 200);

  resetarLimitesIp();
});

Deno.test("segurança: verificarLimiteIp e registrarTentativaIp tratam IP desconhecido e vazio sob a mesma cota restrita", () => {
  resetarLimitesIp();
  const agora = Date.now();

  for (let i = 0; i < 10; i++) {
    assertEquals(verificarLimiteIp("desconhecido", agora), true);
    registrarTentativaIp("desconhecido", agora);
  }

  // 11ª tentativa de 'desconhecido' deve retornar false
  assertEquals(verificarLimiteIp("desconhecido", agora), false);
  assertEquals(verificarLimiteIp("", agora), false);
  assertEquals(verificarLimiteIp("   ", agora), false);

  resetarLimitesIp();
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
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "errado" }),
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

Deno.test("mutação: entrar-demonstracao sem DEMONSTRACAO_CODIGO no ambiente falha fechado com 404 e registra alerta", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1 };
  const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
  });

  const logsErro: string[] = [];
  const consoleErrorOriginal = console.error;
  console.error = (...args: unknown[]) => {
    logsErro.push(args.map(String).join(" "));
  };

  const envAntigo = Deno.env.get("DEMONSTRACAO_CODIGO");
  try {
    Deno.env.delete("DEMONSTRACAO_CODIGO");
    const res = await handler(req, depsPadrao(estado, { codigoEsperado: undefined }));
    assertEquals(res.status, 404);
    const json = await res.json();
    assertEquals(json.code, "nao_encontrado");
    assertEquals(json.message, "nao_encontrado");

    // Valida que o alerta operacional explícito foi emitido
    assertEquals(
      logsErro.some((msg) => msg.includes("[ALERTA_CONFIG_DEMONSTRACAO]")),
      true,
      "Deve emitir [ALERTA_CONFIG_DEMONSTRACAO] quando segredo estiver ausente",
    );
  } finally {
    console.error = consoleErrorOriginal;
    if (envAntigo !== undefined) Deno.env.set("DEMONSTRACAO_CODIGO", envAntigo);
    else Deno.env.delete("DEMONSTRACAO_CODIGO");
  }
});

Deno.test("entrar-demonstracao: extrairIpCliente prioriza cabecalho da borda e ignora primeiro elemento forjado do XFF (Bloqueio 2)", () => {
  // 1. cf-connecting-ip tem prioridade máxima (injetado pela Cloudflare)
  const req1 = new Request("http://localhost", {
    headers: {
      "cf-connecting-ip": "203.0.113.1",
      "x-real-ip": "198.51.100.2",
      "x-forwarded-for": "forged.ip, 192.0.2.3",
    },
  });
  assertEquals(extrairIpCliente(req1), "203.0.113.1");

  // 2. x-real-ip tem prioridade sobre x-forwarded-for se cf-connecting-ip estiver ausente
  const req2 = new Request("http://localhost", {
    headers: {
      "x-real-ip": "198.51.100.2",
      "x-forwarded-for": "forged.ip, 192.0.2.3",
    },
  });
  assertEquals(extrairIpCliente(req2), "198.51.100.2");

  // 3. Em x-forwarded-for com múltiplos IPs, o cliente controla o primeiro; a borda anexa o real ao fim
  const req3 = new Request("http://localhost", {
    headers: {
      "x-forwarded-for": "ip-forjado-do-atacante, 192.0.2.55",
    },
  });
  assertEquals(extrairIpCliente(req3), "192.0.2.55");

  // 4. Sem cabeçalhos de IP devolve "desconhecido"
  const req4 = new Request("http://localhost");
  assertEquals(extrairIpCliente(req4), "desconhecido");
});

Deno.test("entrar-demonstracao: codigo com menos de 6 caracteres falha fechado com 404 e registra alerta (Bloqueio 3)", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1 };
  const codigoCurto = "12345"; // 5 caracteres (< MIN_COMPRIMENTO_CODIGO = 6)

  const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: codigoCurto }),
  });

  const logsErro: string[] = [];
  const consoleErrorOriginal = console.error;
  console.error = (...args: unknown[]) => {
    logsErro.push(args.map(String).join(" "));
  };

  try {
    // Se DEMONSTRACAO_CODIGO tiver menos de 6 dígitos, a função DEVE falhar fechado com 404 e emitir alerta operacional
    const res = await handler(req, depsPadrao(estado, { codigoEsperado: codigoCurto }));
    assertEquals(res.status, 404);
    const json = await res.json();
    assertEquals(json.code, "nao_encontrado");
    assertEquals(json.message, "nao_encontrado");

    // Valida que o alerta operacional explícito foi emitido
    assertEquals(
      logsErro.some((msg) => msg.includes("[ALERTA_CONFIG_DEMONSTRACAO]")),
      true,
      "Deve emitir [ALERTA_CONFIG_DEMONSTRACAO] no console.error",
    );
  } finally {
    console.error = consoleErrorOriginal;
  }
});

Deno.test("entrar-demonstracao: janela DEMONSTRACAO_ATIVA_ATE expira ou ausente fecha a porta com 404 e alerta (Opcao A)", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1 };
  const criarReq = () =>
    new Request("http://localhost/functions/v1/entrar-demonstracao", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
    });

  const logsErro: string[] = [];
  const consoleErrorOriginal = console.error;
  console.error = (...args: unknown[]) => {
    logsErro.push(args.map(String).join(" "));
  };

  try {
    // 1. Data no passado: a porta fecha mesmo com e-mail e código corretos
    const resExpirada = await handler(criarReq(), depsPadrao(estado, { ativaAte: "2020-01-01T00:00:00Z" }));
    assertEquals(resExpirada.status, 404);
    assertEquals(await resExpirada.json(), { code: "nao_encontrado", message: "nao_encontrado", details: null });

    // 2. Data vazia: fail-closed
    const resVazia = await handler(criarReq(), depsPadrao(estado, { ativaAte: "" }));
    assertEquals(resVazia.status, 404);

    // 3. Data ausente do ambiente e de deps: fail-closed
    const envAntigo = Deno.env.get("DEMONSTRACAO_ATIVA_ATE");
    try {
      Deno.env.delete("DEMONSTRACAO_ATIVA_ATE");
      const resSemEnv = await handler(criarReq(), depsPadrao(estado, { ativaAte: undefined }));
      assertEquals(resSemEnv.status, 404);

      // 4. Data em formato inválido ou sem fuso horário explícito
      const resInvalida = await handler(criarReq(), depsPadrao(estado, { ativaAte: "data-invalida" }));
      assertEquals(resInvalida.status, 404);

      // 4b. Data sem 'T' ou sem fuso (rejeitada para evitar ambiguidades UTC vs BRT)
      const resSemFuso1 = await handler(criarReq(), depsPadrao(estado, { ativaAte: "2099-12-31" }));
      assertEquals(resSemFuso1.status, 404);

      const resSemFuso2 = await handler(criarReq(), depsPadrao(estado, { ativaAte: "2099-12-31T23:59:00" }));
      assertEquals(resSemFuso2.status, 404);

      // 5. Data válida configurada no ambiente com fuso Z
      Deno.env.set("DEMONSTRACAO_ATIVA_ATE", "2035-01-01T00:00:00Z");
      const resEnvFuturo = await handler(criarReq(), depsPadrao(estado, { ativaAte: undefined }));
      assertEquals(resEnvFuturo.status, 200);

      // 5b. Data válida configurada com fuso de offset brasileiro (-03:00)
      Deno.env.set("DEMONSTRACAO_ATIVA_ATE", "2099-12-31T23:59:00-03:00");
      const resEnvOffset = await handler(criarReq(), depsPadrao(estado, { ativaAte: undefined }));
      assertEquals(resEnvOffset.status, 200);
    } finally {
      if (envAntigo !== undefined) Deno.env.set("DEMONSTRACAO_ATIVA_ATE", envAntigo);
      else Deno.env.delete("DEMONSTRACAO_ATIVA_ATE");
    }

    // 6. Data no futuro em deps com fuso Z ou offset: login permitido normalmente
    const resAtiva = await handler(criarReq(), depsPadrao(estado, { ativaAte: "2030-01-01T00:00:00Z" }));
    assertEquals(resAtiva.status, 200);

    const resAtivaOffset = await handler(criarReq(), depsPadrao(estado, { ativaAte: "2099-12-31T23:59:00-03:00" }));
    assertEquals(resAtivaOffset.status, 200);

    // Valida que emitiu alerta operacional para as configurações inválidas/expiradas/sem fuso
    assertEquals(
      logsErro.some((msg) => msg.includes("[ALERTA_CONFIG_DEMONSTRACAO]")),
      true,
      "Deve emitir [ALERTA_CONFIG_DEMONSTRACAO] para janela ausente ou expirada",
    );
  } finally {
    console.error = consoleErrorOriginal;
  }
});

Deno.test("entrar-demonstracao: emite [ALERTA_DEMONSTRACAO] quando IP ou e-mail excede o teto de tentativas incorretas", async () => {
  resetarLimitesIp();
  const estado: MockState = { tentativas: [], proximoId: 1 };
  const ipAlvo = "198.51.100.77";

  const logsErro: string[] = [];
  const consoleErrorOriginal = console.error;
  console.error = (...args: unknown[]) => {
    logsErro.push(args.map(String).join(" "));
  };

  try {
    // 10 tentativas erradas do mesmo IP para o e-mail do revisor
    for (let i = 1; i <= 10; i++) {
      const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
        method: "POST",
        headers: { "Content-Type": "application/json", "cf-connecting-ip": ipAlvo },
        body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "codigo-errado" }),
      });
      const res = await handler(req, depsPadrao(estado));
      assertEquals(res.status, 404);
    }

    // 11ª tentativa errada: bate no teto por IP e emite [ALERTA_DEMONSTRACAO]
    const req11 = new Request("http://localhost/functions/v1/entrar-demonstracao", {
      method: "POST",
      headers: { "Content-Type": "application/json", "cf-connecting-ip": ipAlvo },
      body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "codigo-errado" }),
    });
    const res11 = await handler(req11, depsPadrao(estado));
    assertEquals(res11.status, 429);
    assertEquals((await res11.json()).code, "limite_excedido");

    // Valida que o alerta operacional [ALERTA_DEMONSTRACAO] foi emitido para o IP
    assertEquals(
      logsErro.some((msg) => msg.includes("[ALERTA_DEMONSTRACAO]") && msg.includes("IP")),
      true,
      "Deve emitir [ALERTA_DEMONSTRACAO] para IP excedido",
    );

    // 12ª tentativa com IP diferente mas mesmo e-mail (já tem 10 tentativas gravadas no banco):
    // bate no teto por e-mail e emite [ALERTA_DEMONSTRACAO]
    const reqEmailTeto = new Request("http://localhost/functions/v1/entrar-demonstracao", {
      method: "POST",
      headers: { "Content-Type": "application/json", "cf-connecting-ip": "203.0.113.99" },
      body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "codigo-errado" }),
    });
    const resEmailTeto = await handler(reqEmailTeto, depsPadrao(estado));
    assertEquals(resEmailTeto.status, 429);
    assertEquals((await resEmailTeto.json()).code, "limite_excedido");

    assertEquals(
      logsErro.some((msg) => msg.includes("[ALERTA_DEMONSTRACAO]") && msg.includes("e-mail")),
      true,
      "Deve emitir [ALERTA_DEMONSTRACAO] para e-mail excedido",
    );

    // O código CORRETO nunca é bloqueado, mesmo sob alertas e tetos excedidos
    const reqCorreta = new Request("http://localhost/functions/v1/entrar-demonstracao", {
      method: "POST",
      headers: { "Content-Type": "application/json", "cf-connecting-ip": ipAlvo },
      body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: MOCK_CODIGO }),
    });
    const resCorreta = await handler(reqCorreta, depsPadrao(estado));
    assertEquals(resCorreta.status, 200);
  } finally {
    console.error = consoleErrorOriginal;
  }
});

Deno.test("entrar-demonstracao: controle de memoria do mapa de IPs evita vazamento sob ataque de variacao de IP", () => {
  resetarLimitesIp();
  const agora = Date.now();

  // Registra tentativas para 1050 IPs diferentes (excedendo MAX_IPS_EM_MEMORIA = 1000)
  for (let i = 1; i <= 1050; i++) {
    registrarTentativaIp(`10.0.${Math.floor(i / 256)}.${i % 256}`, agora);
  }

  // O sistema não deve travar e o teto deve continuar funcionando
  const ipNovo = "10.0.99.99";
  for (let i = 1; i <= 10; i++) {
    registrarTentativaIp(ipNovo, agora);
  }
  assertEquals(verificarLimiteIp(ipNovo, agora), false);

  // Após expirar a janela (10 minutos), o IP é liberado
  const dezMinDepois = agora + JANELA_MINUTOS * 60_000 + 1000;
  assertEquals(verificarLimiteIp(ipNovo, dezMinDepois), true);
});

Deno.test("entrar-demonstracao: parseLimiteJanela exige formato ISO-8601 estrito com fuso explicito", () => {
  // Rejeita formatos sem fuso horário (ambíguos entre UTC e horário local)
  assertEquals(isNaN(parseLimiteJanela("")), true);
  assertEquals(isNaN(parseLimiteJanela("   ")), true);
  assertEquals(isNaN(parseLimiteJanela("2026-10-30")), true);
  assertEquals(isNaN(parseLimiteJanela("2026-10-30T23:59:00")), true);
  assertEquals(isNaN(parseLimiteJanela("30/10/2026 23:59:00")), true);
  assertEquals(isNaN(parseLimiteJanela("invalido")), true);

  // Aceita formatos com fuso UTC ('Z')
  assertEquals(isNaN(parseLimiteJanela("2030-01-01T00:00:00Z")), false);
  assertEquals(isNaN(parseLimiteJanela("2030-01-01T00:00Z")), false);
  assertEquals(isNaN(parseLimiteJanela("2030-01-01T00:00:00.000Z")), false);

  // Aceita formatos com offset numérico explícito (+HH:MM ou -HH:MM)
  assertEquals(isNaN(parseLimiteJanela("2026-10-30T23:59:00-03:00")), false);
  assertEquals(isNaN(parseLimiteJanela("2026-10-30T23:59:00+00:00")), false);
  assertEquals(isNaN(parseLimiteJanela("2026-10-30T23:59:00+02:00")), false);
});


