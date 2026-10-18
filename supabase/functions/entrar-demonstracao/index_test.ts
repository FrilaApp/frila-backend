import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  emailsDeclarados,
  extrairIpCliente,
  handler,
  HandlerDeps,
  igualEmTempoConstante,
  JANELA_MINUTOS,
  MAX_IPS_EM_MEMORIA,
  MIN_COMPRIMENTO_CODIGO,
  registrarTentativaIp,
  resetarLimitesIp,
  TETO_TENTATIVAS,
  verificarLimiteIp,
} from "./index.ts";

const MOCK_ORIGEM = "http://127.0.0.1:54321";
const MOCK_SERVICE_ROLE = "mock-service-role-key";
const MOCK_ANON = "mock-anon-key";
const MOCK_CODIGO = "codigo-demonstracao-secreto-revisor-2026";
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

  // 11 tentativas erradas recentes para o e-mail do revisor
  for (let i = 1; i <= 11; i++) {
    const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-forwarded-for": `192.168.1.${i}` },
      body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: "errado" }),
    });
    const res = await handler(req, depsPadrao(estado));
    assertEquals(res.status, 404);
  }

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
  assertEquals(resBloqueada.status, 404);
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

Deno.test("entrar-demonstracao: codigo com menos de 20 caracteres falha fechado com 404 (Bloqueio 3)", async () => {
  const estado: MockState = { tentativas: [], proximoId: 1 };
  const codigoCurto = "123456"; // 6 caracteres (< MIN_COMPRIMENTO_CODIGO)

  const req = new Request("http://localhost/functions/v1/entrar-demonstracao", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: MOCK_EMAIL_REVISOR, codigo: codigoCurto }),
  });

  // Mesmo que o cliente envie exatamente o código configurado, se for < 20 caracteres,
  // a função DEVE falhar fechado com 404 por falta de entropia mínima contra exaustão
  const res = await handler(req, depsPadrao(estado, { codigoEsperado: codigoCurto }));
  assertEquals(res.status, 404);
  const json = await res.json();
  assertEquals(json.code, "nao_encontrado");
  assertEquals(json.message, "nao_encontrado");
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


