// Testes da Edge Function exportar-turnos (cartão pd7zOS5P · US20, RF22, RN09, RN17, UC13).
//
// Mede:
//   - Método HTTP permitido (apenas POST, 405 para outros).
//   - Autenticação e integridade do token via auth/v1/user (401 para sem Bearer, token recusado ou sem id).
//   - Validações de parâmetros: 'de', 'ate', 'formato', intervalo invertido e 'estabelecimento_id'.
//   - Período sem turnos devolve 204 sem corpo/arquivo (UC13 1a).
//   - Geração de CSV (200, Content-Type text/csv, colunas da RN17, valores batendo, marcação de 'não verificado').
//   - Geração de PDF (200, Content-Type application/pdf, assinatura %PDF-, Cache-Control no-store).
//   - Propagação de erros do banco (403 sem_permissao) e proteção contra vazamento de erro do Postgres (RN15, 500).
//
// Execução: deno test supabase/functions/exportar-turnos/

import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { PDFDocument } from "npm:pdf-lib@1.17.1";
import {
  handler,
  criarSqlClient,
  gerarCsv,
  gerarPdf,
  formatarCentavosReais,
  formatarHoraLocal,
  formatarDataLocal,
  tratarErroBanco,
  TurnoExportacao,
  SqlClient,
} from "./index.ts";

const URL_BASE = "http://127.0.0.1:54321";
const ANON = "anon-de-teste";
const USUARIO_ID = "a0000000-0000-4000-8000-000000000001";
const ESTABELECIMENTO_ID = "c0000000-0000-4000-8000-000000000001";

const TURNOS_MOCK: TurnoExportacao[] = [
  {
    turno_id: "f2000000-0000-4000-8000-000000000301",
    data: "2026-09-22",
    funcao: "limpeza pós-evento",
    inicio_em: "2026-09-22T18:00:00Z",
    fim_em: "2026-09-23T02:00:00Z",
    checkin_em: "2026-09-22T18:02:00Z",
    checkout_em: "2026-09-23T02:05:00Z",
    valor_acordado_centavos: 14000,
    contraparte: "João Vitor Sá",
    verificacao: "verificado",
  },
  {
    turno_id: "f2000000-0000-4000-8000-000000000303",
    data: "2026-09-22",
    funcao: "limpeza pós-evento",
    inicio_em: "2026-09-22T18:00:00Z",
    fim_em: "2026-09-23T02:00:00Z",
    checkin_em: "2026-09-22T18:25:00Z",
    checkout_em: "2026-09-23T02:00:00Z",
    valor_acordado_centavos: 14000,
    contraparte: "Carla Nunes",
    verificacao: "nao_verificado",
  },
];

interface Espiao {
  sql: SqlClient;
  pedidos: { userId: string; de: string; ate: string; estabId: string | null }[];
  fetchFn: typeof fetch;
  chamadasAuth: string[];
}

function criarEspiao(
  turnos: TurnoExportacao[] = TURNOS_MOCK,
  authOk = true,
  idDoAuth: unknown = USUARIO_ID,
  erroBanco?: unknown,
): Espiao {
  const pedidos: { userId: string; de: string; ate: string; estabId: string | null }[] = [];
  const chamadasAuth: string[] = [];

  const fetchFn = ((url: string | URL | Request) => {
    chamadasAuth.push(String(url));
    if (!authOk) {
      return Promise.resolve(new Response("{}", { status: 401 }));
    }
    return Promise.resolve(
      new Response(JSON.stringify({ id: idDoAuth }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
  }) as unknown as typeof fetch;

  return {
    pedidos,
    chamadasAuth,
    fetchFn,
    sql: {
      turnosExportacao: (userId, de, ate, estabId) => {
        pedidos.push({ userId, de, ate, estabId });
        if (erroBanco) {
          return Promise.reject(erroBanco);
        }
        return Promise.resolve(turnos);
      },
    },
  };
}

function requisicao(
  corpo: unknown = {
    de: "2026-09-01T00:00:00Z",
    ate: "2026-09-30T23:59:59Z",
    formato: "csv",
  },
  token: string | null = "token-valido",
  metodo = "POST",
): Request {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const init: RequestInit = {
    method: metodo,
    headers,
  };
  if (metodo === "POST" && corpo !== undefined) {
    init.body = typeof corpo === "string" ? corpo : JSON.stringify(corpo);
  }

  return new Request(`${URL_BASE}/functions/v1/exportar-turnos`, init);
}

function chamar(e: Espiao, req = requisicao()): Promise<Response> {
  return handler(req, {
    fetchFn: e.fetchFn,
    sqlClient: e.sql,
    supabaseUrl: URL_BASE,
    anonKey: ANON,
  });
}

// ── 1. Porta e Métodos HTTP ───────────────────────────────────────────────────

Deno.test("recusa método diferente de POST com 405", async () => {
  const e = criarEspiao();
  const res = await chamar(e, requisicao({}, "token-valido", "GET"));
  assertEquals(res.status, 405);
  const json = await res.json();
  assertEquals(json.code, "metodo_nao_permitido");
});

Deno.test("recusa requisição sem Authorization com 401", async () => {
  const e = criarEspiao();
  const res = await chamar(e, requisicao({}, null));
  assertEquals(res.status, 401);
  const json = await res.json();
  assertEquals(json.code, "nao_autenticado");
  assertEquals(e.chamadasAuth.length, 0);
});

Deno.test("recusa token recusado pelo Supabase Auth com 401", async () => {
  const e = criarEspiao(TURNOS_MOCK, false);
  const res = await chamar(e);
  assertEquals(res.status, 401);
  const json = await res.json();
  assertEquals(json.code, "nao_autenticado");
  assertEquals(e.pedidos.length, 0);
});

Deno.test("recusa resposta de autenticação sem id de usuário com 401", async () => {
  const e = criarEspiao(TURNOS_MOCK, true, null);
  const res = await chamar(e);
  assertEquals(res.status, 401);
  const json = await res.json();
  assertEquals(json.code, "nao_autenticado");
  assertEquals(e.pedidos.length, 0);
});

// ── 2. Validação de parâmetros ────────────────────────────────────────────────

Deno.test("recusa payload que não é JSON com 422 campo_obrigatorio (formato)", async () => {
  const e = criarEspiao();
  const req = requisicao("nao-e-json", "token-valido");
  const res = await chamar(e, req);
  assertEquals(res.status, 422);
  const json = await res.json();
  assertEquals(json.code, "campo_obrigatorio");
  assertEquals(json.details, "formato");
});

Deno.test("parâmetro 'de' é opcional e aplica default dos últimos 15 dias quando omitido", async () => {
  const e = criarEspiao();
  const res = await chamar(e, requisicao({ ate: "2026-09-30T00:00:00Z", formato: "csv" }));
  assertEquals(res.status, 200);
  assertEquals(e.pedidos.length, 1);
  assertEquals(e.pedidos[0].ate, "2026-09-30T00:00:00Z");
  // 'de' deve ser exatamente 15 dias antes de 'ate'
  const deEsperado = new Date(new Date("2026-09-30T00:00:00Z").getTime() - 15 * 24 * 60 * 60 * 1000).toISOString();
  assertEquals(e.pedidos[0].de, deEsperado);
});

Deno.test("parâmetro 'ate' é opcional e aplica default de agora quando omitido", async () => {
  const e = criarEspiao();
  const agoraFixo = new Date("2026-09-20T12:00:00Z");
  const res = await handler(requisicao({ de: "2026-09-10T12:00:00Z", formato: "csv" }), {
    fetchFn: e.fetchFn,
    sqlClient: e.sql,
    supabaseUrl: URL_BASE,
    anonKey: ANON,
    agoraFn: () => agoraFixo,
  });
  assertEquals(res.status, 200);
  assertEquals(e.pedidos.length, 1);
  assertEquals(e.pedidos[0].de, "2026-09-10T12:00:00Z");
  assertEquals(e.pedidos[0].ate, agoraFixo.toISOString());
});

Deno.test("ambos 'de' e 'ate' omitidos aplicam janela dos últimos 15 dias a partir de agora", async () => {
  const e = criarEspiao();
  const agoraFixo = new Date("2026-09-25T12:00:00Z");
  const res = await handler(requisicao({ formato: "csv" }), {
    fetchFn: e.fetchFn,
    sqlClient: e.sql,
    supabaseUrl: URL_BASE,
    anonKey: ANON,
    agoraFn: () => agoraFixo,
  });
  assertEquals(res.status, 200);
  assertEquals(e.pedidos.length, 1);
  assertEquals(e.pedidos[0].ate, agoraFixo.toISOString());
  const deEsperado = new Date(agoraFixo.getTime() - 15 * 24 * 60 * 60 * 1000).toISOString();
  assertEquals(e.pedidos[0].de, deEsperado);
});

Deno.test("recusa parâmetro 'de' com data inválida com 422 campo_invalido", async () => {
  const e = criarEspiao();
  const res = await chamar(e, requisicao({ de: "data-invalida", ate: "2026-09-30T00:00:00Z", formato: "csv" }));
  assertEquals(res.status, 422);
  const json = await res.json();
  assertEquals(json.code, "campo_invalido");
  assertEquals(json.details, "de");
});

Deno.test("recusa parâmetro 'ate' com data inválida com 422 campo_invalido", async () => {
  const e = criarEspiao();
  const res = await chamar(e, requisicao({ de: "2026-09-01T00:00:00Z", ate: "data-invalida", formato: "csv" }));
  assertEquals(res.status, 422);
  const json = await res.json();
  assertEquals(json.code, "campo_invalido");
  assertEquals(json.details, "ate");
});

Deno.test("recusa período com 'de' posterior a 'ate' com 422 campo_invalido", async () => {
  const e = criarEspiao();
  const res = await chamar(
    e,
    requisicao({ de: "2026-09-30T00:00:00Z", ate: "2026-09-01T00:00:00Z", formato: "csv" }),
  );
  assertEquals(res.status, 422);
  const json = await res.json();
  assertEquals(json.code, "campo_invalido");
  assertEquals(json.details, "de");
});

Deno.test("recusa período com intervalo maior que 30 dias com 422 intervalo_maximo_excedido (pd7zOS5P)", async () => {
  const e = criarEspiao();
  const res = await chamar(
    e,
    requisicao({ de: "2026-08-01T00:00:00Z", ate: "2026-09-05T00:00:00Z", formato: "csv" }),
  );
  assertEquals(res.status, 422);
  const json = await res.json();
  assertEquals(json.code, "intervalo_maximo_excedido");
  assertEquals(json.details, null);
  assertEquals(e.pedidos.length, 0);
});

Deno.test("aceita período com exatamente 30 dias", async () => {
  const e = criarEspiao();
  const res = await chamar(
    e,
    requisicao({ de: "2026-09-01T00:00:00Z", ate: "2026-10-01T00:00:00Z", formato: "csv" }),
  );
  assertEquals(res.status, 200);
  assertEquals(e.pedidos.length, 1);
});

Deno.test("recusa parâmetro 'formato' ausente com 422 campo_obrigatorio", async () => {
  const e = criarEspiao();
  const res = await chamar(e, requisicao({ de: "2026-09-01T00:00:00Z", ate: "2026-09-30T00:00:00Z" }));
  assertEquals(res.status, 422);
  const json = await res.json();
  assertEquals(json.code, "campo_obrigatorio");
  assertEquals(json.details, "formato");
});

Deno.test("recusa parâmetro 'formato' diferente de csv ou pdf com 422 campo_invalido", async () => {
  const e = criarEspiao();
  const res = await chamar(
    e,
    requisicao({ de: "2026-09-01T00:00:00Z", ate: "2026-09-30T00:00:00Z", formato: "xlsx" }),
  );
  assertEquals(res.status, 422);
  const json = await res.json();
  assertEquals(json.code, "campo_invalido");
  assertEquals(json.details, "formato");
});

Deno.test("recusa 'estabelecimento_id' que não é UUID com 422 campo_invalido", async () => {
  const e = criarEspiao();
  const res = await chamar(
    e,
    requisicao({
      de: "2026-09-01T00:00:00Z",
      ate: "2026-09-30T00:00:00Z",
      formato: "csv",
      estabelecimento_id: "nao-e-uuid",
    }),
  );
  assertEquals(res.status, 422);
  const json = await res.json();
  assertEquals(json.code, "campo_invalido");
  assertEquals(json.details, "estabelecimento_id");
});

// ── 3. Período sem turnos devolve 204 (UC13 1a) ───────────────────────────────

Deno.test("período sem turnos devolve 204 sem corpo nem arquivo (UC13 1a)", async () => {
  const e = criarEspiao([]);
  const res = await chamar(e);

  assertEquals(res.status, 204);
  assertEquals(res.headers.get("Cache-Control"), "no-store");
  const corpo = await res.text();
  assertEquals(corpo, "");
});

// ── 4. Exportação CSV ─────────────────────────────────────────────────────────

Deno.test("exportação CSV devolve 200 com Content-Type text/csv e campos da RN17", async () => {
  const e = criarEspiao();
  const res = await chamar(
    e,
    requisicao({
      de: "2026-09-01T00:00:00Z",
      ate: "2026-09-30T23:59:59Z",
      formato: "csv",
      estabelecimento_id: ESTABELECIMENTO_ID,
    }),
  );

  assertEquals(res.status, 200);
  assertStringIncludes(res.headers.get("Content-Type") ?? "", "text/csv");
  assertStringIncludes(res.headers.get("Content-Disposition") ?? "", 'filename="turnos.csv"');
  assertEquals(res.headers.get("Cache-Control"), "no-store");

  const texto = await res.text();
  const linhas = texto.split("\r\n");

  // Cabeçalho
  assertEquals(
    linhas[0],
    "Data,Funcao,Inicio Previsto,Fim Previsto,Checkin,Checkout,Valor Acordado,Contraparte,Status",
  );

  // Turno 1: verificado
  assertStringIncludes(linhas[1], "limpeza pós-evento");
  assertStringIncludes(linhas[1], "João Vitor Sá");
  assertStringIncludes(linhas[1], "R$ 140,00");
  assertStringIncludes(linhas[1], "Verificado");

  // Turno 2: nao_verificado (UC13 2a: marcado como tal)
  assertStringIncludes(linhas[2], "Carla Nunes");
  assertStringIncludes(linhas[2], "R$ 140,00");
  assertStringIncludes(linhas[2], "Nao verificado");

  // Garante que o banco foi chamado com o id retornado pelo auth e estabelecimento_id
  assertEquals(e.pedidos.length, 1);
  assertEquals(e.pedidos[0].userId, USUARIO_ID);
  assertEquals(e.pedidos[0].estabId, ESTABELECIMENTO_ID);
});

// ── 5. Exportação PDF ─────────────────────────────────────────────────────────

Deno.test("exportação PDF devolve 200 com Content-Type application/pdf e bytes válidos", async () => {
  const e = criarEspiao();
  const res = await chamar(
    e,
    requisicao({
      de: "2026-09-01T00:00:00Z",
      ate: "2026-09-30T23:59:59Z",
      formato: "pdf",
    }),
  );

  assertEquals(res.status, 200);
  assertEquals(res.headers.get("Content-Type"), "application/pdf");
  assertStringIncludes(res.headers.get("Content-Disposition") ?? "", 'filename="turnos.pdf"');
  assertEquals(res.headers.get("Cache-Control"), "no-store");

  const bytes = new Uint8Array(await res.arrayBuffer());
  assert(bytes.length > 200, "o PDF gerado deve ter tamanho substancial");

  // Todo PDF começa com os bytes mágicos %PDF-
  const cabecalho = new TextDecoder().decode(bytes.subarray(0, 5));
  assertEquals(cabecalho, "%PDF-");
});

// ── 6. Tratamento de Erros e Proteção LGPD (RN15) ─────────────────────────────

Deno.test("propaga erro 403 sem_permissao levantado pelo banco para não membro", async () => {
  const erroPg = {
    code: "PGRST",
    message: JSON.stringify({ code: "sem_permissao", message: "sem_permissao", details: null }),
    detail: JSON.stringify({ status: 403 }),
  };
  const e = criarEspiao(TURNOS_MOCK, true, USUARIO_ID, erroPg);
  const res = await chamar(e);

  assertEquals(res.status, 403);
  const json = await res.json();
  assertEquals(json.code, "sem_permissao");
});

Deno.test("erro genérico no banco responde 500 sem vazar mensagens internas do Postgres (RN15)", async () => {
  const e = criarEspiao(TURNOS_MOCK, true, USUARIO_ID, new Error("syntax error at or near 'SELECT' usuario ana@frila.test"));
  const res = await chamar(e);

  assertEquals(res.status, 500);
  const json = await res.json();
  assertEquals(json.code, "erro_interno");
  assertEquals(json.details, null);
  assert(!JSON.stringify(json).includes("ana@frila.test"), "não deve vazar dado sensível no erro");
});

// ── 7. Funções auxiliares de formatação ────────────────────────────────────────

Deno.test("formatarCentavosReais formata centavos inteiros em reais BRL", () => {
  assertEquals(formatarCentavosReais(14000), "R$ 140,00");
  assertEquals(formatarCentavosReais(16050), "R$ 160,50");
  assertEquals(formatarCentavosReais(0), "R$ 0,00");
  assertEquals(formatarCentavosReais("22000"), "R$ 220,00");
});

Deno.test("formatarHoraLocal e formatarDataLocal tratam nulos e formatam corretamente", () => {
  assertEquals(formatarHoraLocal(null), "-");
  assertEquals(formatarDataLocal(null), "-");
  // 18:00 UTC em America/Sao_Paulo (UTC-3) é 15:00
  assertEquals(formatarHoraLocal("2026-09-22T18:00:00Z"), "15:00");
});

Deno.test("gerarCsv escapa aspas e vírgulas", () => {
  const turnosComVirgula: TurnoExportacao[] = [
    {
      turno_id: "f2000000-0000-4000-8000-000000000301",
      data: "2026-09-22",
      funcao: 'Garçom, Especialista "VIP"',
      inicio_em: "2026-09-22T18:00:00Z",
      fim_em: "2026-09-23T02:00:00Z",
      checkin_em: null,
      checkout_em: null,
      valor_acordado_centavos: 15000,
      contraparte: "Bar do Cerrado, Asa Norte",
      verificacao: "pendente",
    },
  ];
  const csv = gerarCsv(turnosComVirgula);
  assertStringIncludes(csv, '"Garçom, Especialista ""VIP"""');
  assertStringIncludes(csv, '"Bar do Cerrado, Asa Norte"');
});

Deno.test("gerarPdf cria arquivo válido com totalizador e nota da RN09", async () => {
  const bytes = await gerarPdf(TURNOS_MOCK, "2026-09-01T00:00:00Z", "2026-09-30T23:59:59Z");
  assert(bytes instanceof Uint8Array);
  assert(bytes.length > 500);
});

Deno.test("criarSqlClient exige SUPABASE_DB_URL no ambiente ou deps", () => {
  let falhou = false;
  try {
    criarSqlClient({ dbUrl: "" });
  } catch (err) {
    falhou = true;
    assert(err instanceof Error);
    assertStringIncludes(err.message, "SUPABASE_DB_URL é obrigatório");
  }
  assert(falhou, "deveria ter falhado com dbUrl vazia");
});

Deno.test("gerarPdf com grande volume de turnos quebra página e gera múltiplas páginas válidas", async () => {
  // Gera 55 turnos para forçar y < 60 e exercitar a criação de páginas subsequentes
  const muitosTurnos: TurnoExportacao[] = [];
  for (let i = 1; i <= 55; i++) {
    muitosTurnos.push({
      turno_id: `f2000000-0000-4000-8000-${String(i).padStart(12, "0")}`,
      data: "2026-09-15",
      funcao: `Função ${i}`,
      inicio_em: "2026-09-15T18:00:00Z",
      fim_em: "2026-09-16T02:00:00Z",
      checkin_em: "2026-09-15T18:05:00Z",
      checkout_em: "2026-09-16T02:00:00Z",
      valor_acordado_centavos: 12000,
      contraparte: `Estabelecimento ${i}`,
      verificacao: i % 2 === 0 ? "verificado" : "nao_verificado",
    });
  }

  const bytes = await gerarPdf(muitosTurnos, "2026-09-01T00:00:00Z", "2026-09-30T23:59:59Z");
  assert(bytes instanceof Uint8Array);
  assert(bytes.length > 2000, "o PDF multipágina deve ter tamanho adequado");
  const cabecalho = new TextDecoder().decode(bytes.subarray(0, 5));
  assertEquals(cabecalho, "%PDF-");

  // Afirma o número exato de páginas gerado (55 turnos exigem exatamente 2 páginas)
  const doc = await PDFDocument.load(bytes);
  assertEquals(doc.getPageCount(), 2, "o relatório com 55 turnos deve gerar exatamente 2 páginas");
  assertEquals(doc.getPages().length, 2, "a lista de páginas do documento deve conter 2 páginas");
});

Deno.test("formatarHoraLocal e formatarDataLocal tratam dados inválidos com segurança", () => {
  assertEquals(formatarHoraLocal("data-invalida-xyz"), "-");
  assertEquals(formatarDataLocal("data-invalida-xyz"), "data-invalida-xyz");
});

Deno.test("tratarErroBanco com erro PGRST e mensagem em texto simples devolve 400", async () => {
  const err = { code: "PGRST", message: "texto_simples_nao_json" };
  const res = tratarErroBanco(err);
  assertEquals(res.status, 400);
  const json = await res.json();
  assertEquals(json.code, "texto_simples_nao_json");
});

Deno.test("tratarErroBanco com erro PGRST e detail sem status numérico mantém 400", async () => {
  const err = {
    code: "PGRST",
    message: JSON.stringify({ code: "regra_violada", message: "regra_violada", details: null }),
    detail: "json_invalido_ou_sem_status",
  };
  const res = tratarErroBanco(err);
  assertEquals(res.status, 400);
  const json = await res.json();
  assertEquals(json.code, "regra_violada");
});

// ── Auditoria de Privacidade (RN17, RN15, LGPD) ──────────────────────────────

Deno.test("RN17 / RN15 / LGPD: CSV e PDF gerados contêm estritamente as colunas autorizadas e zero dados pessoais excessivos", async () => {
  const e = criarEspiao();
  const resCsv = await chamar(
    e,
    requisicao({
      de: "2026-09-01T00:00:00Z",
      ate: "2026-09-30T23:59:59Z",
      formato: "csv",
      estabelecimento_id: ESTABELECIMENTO_ID,
    }),
  );

  assertEquals(resCsv.status, 200);
  assertEquals(resCsv.headers.get("Cache-Control"), "no-store");
  const csvTexto = await resCsv.text();
  const linhas = csvTexto.split("\r\n");

  // 1. Cabeçalho deve bater 100% com as 9 colunas da RN17
  const cabecalhoEsperado = "Data,Funcao,Inicio Previsto,Fim Previsto,Checkin,Checkout,Valor Acordado,Contraparte,Status";
  assertEquals(linhas[0], cabecalhoEsperado, "colunas do CSV devem ser estritamente as 9 da RN17");

  // 2. Colunas proibidas não podem existir
  const colunasProibidas = [
    "telefone",
    "email",
    "cpf",
    "cnpj",
    "documento",
    "distancia",
    "distancia_m",
    "endereco",
    "latitude",
    "longitude",
    "ponto",
    "usuario_id",
    "posicao_id",
  ];
  for (const proibida of colunasProibidas) {
    assert(
      !linhas[0].toLowerCase().includes(proibida),
      `Coluna não autorizada '${proibida}' vazou no cabeçalho do CSV (RN15)`,
    );
  }

  // 3. Verificações negativas no corpo do CSV
  const regexCpf = /\b\d{3}\.\d{3}\.\d{3}-\d{2}\b/;
  const regexTelefone = /(?:\+55|\(?\d{2}\)?\s*\d{4,5}-?\d{4})/;
  assert(!csvTexto.includes("@"), "CSV não pode conter e-mail");
  assert(!regexTelefone.test(csvTexto), "CSV não pode conter telefone");
  assert(!regexCpf.test(csvTexto), "CSV não pode conter CPF");

  // 4. PDF com Cache-Control: no-store
  const resPdf = await chamar(
    e,
    requisicao({
      de: "2026-09-01T00:00:00Z",
      ate: "2026-09-30T23:59:59Z",
      formato: "pdf",
      estabelecimento_id: ESTABELECIMENTO_ID,
    }),
  );
  assertEquals(resPdf.status, 200);
  assertEquals(resPdf.headers.get("Cache-Control"), "no-store");
  assertEquals(resPdf.headers.get("Content-Type"), "application/pdf");
  const bytesPdf = new Uint8Array(await resPdf.arrayBuffer());
  assert(bytesPdf.length > 500, "PDF deve conter bytes válidos");
  assertEquals(new TextDecoder().decode(bytesPdf.subarray(0, 5)), "%PDF-");
});

