// Testes da Edge Function enviar-email (cartão 7yq1flLG).
//
// O provedor e o banco entram injetados. O que estes testes medem é o comportamento que
// nenhum dos dois portões de SQL alcança: o que vai dentro do e-mail, quem o recebe, e o
// que acontece quando o provedor recusa.
//
//   deno test --allow-all supabase/functions/enviar-email/

import "./test_setup.ts";
import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "jsr:@std/assert@1";

import {
  criarSqlClient,
  DadosDoEmail,
  PedidoDaFila,
  processarEnvioEmail,
  SqlClient,
  TETO_DE_LEITURAS,
} from "./index.ts";
import { Email, classificarErro, ResultadoEnvio } from "./provedor.ts";
import {
  alertaParaEquipe,
  categoria,
  denunciaParaAutor,
  denunciaParaEquipe,
  formatarData,
  modeloDe,
  protocoloCurto,
} from "./modelos.ts";

const SEGREDO = "segredo-de-teste";
const EQUIPE = "equipe@frila.test";
const OCORRENCIA = "3f2a1b9c-1111-4000-8000-000000000001";

// O relato nunca é devolvido por `privado.dados_do_email`; a constante existe para os
// testes procurarem por ela em cada corpo enviado.
const RELATO = "O gerente gritou comigo na frente dos clientes e me mandou embora.";

function dados(sobrepor: Partial<DadosDoEmail> = {}): DadosDoEmail {
  return {
    ocorrencia_id: OCORRENCIA,
    tipo: "denuncia",
    motivo: "assedio",
    criada_em: "2026-09-29T14:00:00+00:00",
    prazo_resposta_ate: "2026-10-06",
    alvo_tipo: "estabelecimento",
    equipe_pendente: true,
    autor_pendente: true,
    autor_email: "ana@frila.test",
    tentativas: 0,
    ...sobrepor,
  };
}

interface Espiao {
  sql: SqlClient;
  enviados: Email[];
  registrados: Array<{ ocorrencia: string; destino: string; prazo: string | null }>;
  falhas: Array<{ ocorrencia: string; codigo: string }>;
  arquivados: number[];
}

function espiao(
  pedidos: PedidoDaFila[],
  d: DadosDoEmail | null = dados(),
): Espiao {
  const enviados: Email[] = [];
  const registrados: Espiao["registrados"] = [];
  const falhas: Espiao["falhas"] = [];
  const arquivados: number[] = [];

  const sql: SqlClient = {
    lerFilaEmail: () => Promise.resolve(pedidos),
    dadosDoEmail: () => Promise.resolve(d),
    registrarEnviado: (ocorrencia, destino, prazo) => {
      registrados.push({ ocorrencia, destino, prazo });
      return Promise.resolve();
    },
    registrarFalha: (ocorrencia, codigo) => {
      falhas.push({ ocorrencia, codigo });
      return Promise.resolve(falhas.length);
    },
    concluir: (msgId) => {
      arquivados.push(msgId);
      return Promise.resolve();
    },
  };

  return { sql, enviados, registrados, falhas, arquivados };
}

function pedido(sobrepor: Partial<PedidoDaFila> = {}): PedidoDaFila {
  return {
    msg_id: 1,
    read_ct: 1,
    mensagem: { tipo: "denuncia", ocorrencia_id: OCORRENCIA },
    ...sobrepor,
  };
}

function requisicao(corpo: unknown = {}): Request {
  return new Request("http://localhost/enviar-email", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO,
    },
    body: JSON.stringify(corpo),
  });
}

function chamar(
  e: Espiao,
  enviar: (email: Email) => Promise<ResultadoEnvio>,
): Promise<Response> {
  return processarEnvioEmail(requisicao(), {
    agendadorSecret: SEGREDO,
    caixaDaEquipe: EQUIPE,
    sqlClient: e.sql,
    enviar: (email) => {
      e.enviados.push(email);
      return enviar(email);
    },
  });
}

const sucesso = () => Promise.resolve<ResultadoEnvio>({ ok: true });

// ── Critério 1: a denúncia chega à caixa da equipe com protocolo e prazo ──────

Deno.test("7yq1flLG 1: a denúncia vai para a caixa da equipe com protocolo e prazo", async () => {
  const e = espiao([pedido()]);
  const res = await chamar(e, sucesso);
  assertEquals(res.status, 200);

  const paraEquipe = e.enviados.find((m) => m.para === EQUIPE);
  assert(paraEquipe, "nenhum e-mail foi para a caixa da equipe");
  assertStringIncludes(paraEquipe.texto, OCORRENCIA);
  assertStringIncludes(paraEquipe.texto, "06/10/2026");
  assertStringIncludes(paraEquipe.assunto, "3F2A1B9C");
  assertStringIncludes(paraEquipe.assunto, "06/10/2026");
});

// ── Critério 2: quem denunciou recebe o protocolo ─────────────────────────────

Deno.test("7yq1flLG 2: quem abriu a denúncia recebe o protocolo por e-mail", async () => {
  const e = espiao([pedido()]);
  await chamar(e, sucesso);

  const paraAutor = e.enviados.find((m) => m.para === "ana@frila.test");
  assert(paraAutor, "o autor não recebeu e-mail");
  assertStringIncludes(paraAutor.texto, OCORRENCIA);
  assertStringIncludes(paraAutor.texto, "06/10/2026");
  // A Equipe Frila só responde por e-mail: a resposta tem de cair na caixa dela.
  assertEquals(paraAutor.responderPara, EQUIPE);

  assertEquals(e.registrados.map((r) => r.destino).sort(), ["autor", "equipe"]);
  assertEquals(e.arquivados, [1], "o pedido só é arquivado com os dois e-mails enviados");
});

// ── Critério 3: o corpo não passa pelo banco, e o relato não passa pelo e-mail ─

Deno.test("7yq1flLG 3: o relato não entra em nenhum corpo de e-mail (RN15)", async () => {
  const e = espiao([pedido()]);
  await chamar(e, sucesso);

  assert(e.enviados.length > 0, "nada foi enviado");
  for (const m of e.enviados) {
    assert(
      !m.texto.includes(RELATO) && !m.assunto.includes(RELATO),
      `o relato apareceu no e-mail para ${m.para}`,
    );
  }
  // O e-mail da equipe também não leva o endereço de quem denunciou.
  const paraEquipe = e.enviados.find((m) => m.para === EQUIPE)!;
  assert(
    !paraEquipe.texto.includes("ana@frila.test"),
    "o e-mail da equipe vazou o endereço de quem denunciou",
  );
});

Deno.test("7yq1flLG 3: o que é gravado no banco é instante e prazo, nunca o corpo", async () => {
  const e = espiao([pedido()]);
  await chamar(e, sucesso);

  for (const r of e.registrados) {
    assertEquals(r.ocorrencia, OCORRENCIA);
    assertEquals(r.prazo, "2026-10-06");
    // A assinatura de `registrar_email_enviado` não tem por onde receber um corpo: o
    // que o cliente manda é exatamente ocorrência, destino e prazo.
    assertEquals(Object.keys(r).sort(), ["destino", "ocorrencia", "prazo"]);
  }
});

// ── Critério 4: a falha do provedor é reenviada ───────────────────────────────

Deno.test("7yq1flLG 4: falha transitória não arquiva o pedido — ele volta à fila", async () => {
  const e = espiao([pedido({ read_ct: 1 })]);
  const res = await chamar(e, () =>
    Promise.resolve({ ok: false, codigo: "smtp_451", transitorio: true }));

  const corpo = await res.json();
  assertEquals(corpo.relatorio[0].status, "pendente");
  assertEquals(e.arquivados, [], "o pedido foi arquivado e a denúncia se perdeu");
  assertEquals(e.falhas, [{ ocorrencia: OCORRENCIA, codigo: "smtp_451" }]);
  assertEquals(e.registrados, [], "nada foi registrado como enviado");
});

Deno.test("7yq1flLG 4: a retentativa manda só o que faltou", async () => {
  // Segunda leitura do mesmo pedido: a equipe já recebeu na primeira.
  const e = espiao(
    [pedido({ read_ct: 2 })],
    dados({ equipe_pendente: false, autor_pendente: true }),
  );
  await chamar(e, sucesso);

  assertEquals(e.enviados.length, 1, "o e-mail da equipe foi mandado duas vezes");
  assertEquals(e.enviados[0].para, "ana@frila.test");
  assertEquals(e.registrados.map((r) => r.destino), ["autor"]);
  assertEquals(e.arquivados, [1]);
});

Deno.test("7yq1flLG 4: o teto de leituras arquiva o pedido em vez de insistir para sempre", async () => {
  const e = espiao([pedido({ read_ct: TETO_DE_LEITURAS })]);
  const res = await chamar(e, () =>
    Promise.resolve({ ok: false, codigo: "smtp_451", transitorio: true }));

  const corpo = await res.json();
  assertEquals(corpo.relatorio[0].status, "arquivado");
  assertEquals(corpo.relatorio[0].detalhe, "teto_de_leituras_excedido");
  assertEquals(e.arquivados, [1]);
});

Deno.test("7yq1flLG 4: erro definitivo do provedor arquiva sem gastar as cinco leituras", async () => {
  const e = espiao([pedido({ read_ct: 1 })]);
  const res = await chamar(e, () =>
    Promise.resolve({ ok: false, codigo: "smtp_550", transitorio: false }));

  const corpo = await res.json();
  assertEquals(corpo.relatorio[0].status, "arquivado");
  assertEquals(corpo.relatorio[0].detalhe, "smtp_550");
  assertEquals(e.falhas, [{ ocorrencia: OCORRENCIA, codigo: "smtp_550" }]);
});

Deno.test("7yq1flLG 4: a equipe recebeu e o autor falhou — só o autor é retentado", async () => {
  const e = espiao([pedido({ read_ct: 1 })]);
  await chamar(e, (m) =>
    m.para === EQUIPE
      ? Promise.resolve({ ok: true })
      : Promise.resolve({ ok: false, codigo: "smtp_451", transitorio: true }));

  assertEquals(e.registrados.map((r) => r.destino), ["equipe"]);
  assertEquals(e.arquivados, [], "o pedido precisa voltar para mandar o protocolo");
});

// ── Critério 5: os modelos ────────────────────────────────────────────────────

Deno.test("7yq1flLG 5: os textos saem dos modelos, e não do consumidor", async () => {
  const e = espiao([pedido()]);
  await chamar(e, sucesso);

  const d = dados();
  const equipe = denunciaParaEquipe(d);
  const autor = denunciaParaAutor(d);

  const enviadoEquipe = e.enviados.find((m) => m.para === EQUIPE)!;
  const enviadoAutor = e.enviados.find((m) => m.para === "ana@frila.test")!;

  assertEquals(enviadoEquipe.assunto, equipe.assunto);
  assertEquals(enviadoEquipe.texto, equipe.texto);
  assertEquals(enviadoAutor.assunto, autor.assunto);
  assertEquals(enviadoAutor.texto, autor.texto);
});

Deno.test("modelos: a categoria da denúncia vem do enum, e motivo fora dele não é interpolado", () => {
  assertEquals(categoria("assedio"), "Assédio");
  assertEquals(categoria("risco_seguranca"), "Risco à segurança");
  // `contestacao` e `suporte` gravam texto livre em `motivo`: ele não vira assunto.
  assertEquals(categoria("o gerente disse que eu não servia"), "Não classificado");
});

Deno.test("modelos: o protocolo curto é o prefixo do id, e o corpo leva o id inteiro", () => {
  assertEquals(protocoloCurto(OCORRENCIA), "3F2A1B9C");
  assertStringIncludes(denunciaParaAutor(dados()).texto, OCORRENCIA);
});

Deno.test("modelos: a data do prazo é lida como data, e não como instante em UTC", () => {
  // `new Date('2026-10-06').toLocaleDateString('pt-BR')` devolve 05/10 em UTC−3: o
  // prazo comunicado sairia um dia mais curto do que o que o banco calculou.
  assertEquals(formatarData("2026-10-06"), "06/10/2026");
  assertEquals(formatarData("2026-09-29T14:00:00+00:00"), "29/09/2026");
});

Deno.test("modelos: a contestação tem modelo próprio nos dois destinos (RF24)", () => {
  const d = dados({ tipo: "contestacao", motivo: "suspensão indevida" });
  const equipe = modeloDe("contestacao", "equipe", d)!;
  const autor = modeloDe("contestacao", "autor", d)!;
  assertStringIncludes(equipe.assunto, "Contestação");
  assertStringIncludes(autor.assunto, "contestação");
  assertStringIncludes(equipe.texto, OCORRENCIA);
  // O texto da contestação é de quem escreveu: não sai por e-mail.
  assert(!equipe.texto.includes("suspensão indevida"));
});

Deno.test("modelos: tipo sem modelo devolve null, e o consumidor não inventa e-mail", () => {
  assertEquals(modeloDe("suporte", "equipe", dados()), null);
});

Deno.test("7yq1flLG: tipo sem modelo é arquivado com o código visível na ocorrência", async () => {
  const e = espiao([pedido({ mensagem: { tipo: "suporte", ocorrencia_id: OCORRENCIA } })]);
  const res = await chamar(e, sucesso);
  const corpo = await res.json();

  assertEquals(corpo.relatorio[0].detalhe, "tipo_desconhecido");
  assertEquals(e.enviados, [], "um tipo sem modelo não pode gerar e-mail");
  assertEquals(e.falhas, [{ ocorrencia: OCORRENCIA, codigo: "tipo_desconhecido" }]);
});

// ── O alerta do monitoramento (o motivo de a fila sair primeiro) ──────────────

Deno.test("alerta: vai só para a equipe, com código e valor, sem texto livre", async () => {
  const e = espiao([
    pedido({ mensagem: { tipo: "alerta", codigo: "fila_despacho_parada", valor: 42 } }),
  ]);
  await chamar(e, sucesso);

  assertEquals(e.enviados.length, 1);
  assertEquals(e.enviados[0].para, EQUIPE);
  assertEquals(e.enviados[0].assunto, alertaParaEquipe("fila_despacho_parada", 42).assunto);
  assertStringIncludes(e.enviados[0].texto, "42");
  assertEquals(e.arquivados, [1]);
});

Deno.test("alerta: código fora de snake_case é recusado sem enviar nada (RN15)", async () => {
  const e = espiao([
    pedido({ mensagem: { tipo: "alerta", codigo: "ana@frila.test caiu" } }),
  ]);
  const res = await chamar(e, sucesso);
  const corpo = await res.json();

  assertEquals(corpo.relatorio[0].detalhe, "codigo_invalido");
  assertEquals(e.enviados, []);
});

// ── A ocorrência que sumiu, e o pedido sem id ────────────────────────────────

Deno.test("pedido sem ocorrência no banco é arquivado em vez de tentar para sempre", async () => {
  const e = espiao([pedido()], null);
  const res = await chamar(e, sucesso);
  const corpo = await res.json();

  assertEquals(corpo.relatorio[0].detalhe, "ocorrencia_inexistente");
  assertEquals(e.enviados, []);
  assertEquals(e.arquivados, [1]);
});

Deno.test("conta anonimizada não recebe protocolo, e a equipe recebe assim mesmo (RF25)", async () => {
  const e = espiao(
    [pedido()],
    dados({ autor_pendente: false, autor_email: null }),
  );
  await chamar(e, sucesso);

  assertEquals(e.enviados.map((m) => m.para), [EQUIPE]);
  assertEquals(e.registrados.map((r) => r.destino), ["equipe"]);
  assertEquals(e.arquivados, [1]);
});

// ── A porta ───────────────────────────────────────────────────────────────────

Deno.test("porta: sem o segredo do agendador responde 401 e não lê a fila", async () => {
  const e = espiao([pedido()]);
  const req = new Request("http://localhost/enviar-email", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}",
  });
  const res = await processarEnvioEmail(req, {
    agendadorSecret: SEGREDO,
    sqlClient: e.sql,
    enviar: sucesso,
  });
  assertEquals(res.status, 401);
  assertEquals(e.enviados, []);
});

Deno.test("porta: GET responde 405", async () => {
  const res = await processarEnvioEmail(
    new Request("http://localhost/enviar-email", { method: "GET" }),
    { agendadorSecret: SEGREDO, enviar: sucesso },
  );
  assertEquals(res.status, 405);
});

Deno.test("porta: sem provedor configurado responde 500 e deixa a fila intacta", async () => {
  const anterior = Deno.env.get("SMTP_HOST");
  Deno.env.delete("SMTP_HOST");
  try {
    const e = espiao([pedido()]);
    const res = await processarEnvioEmail(requisicao(), {
      agendadorSecret: SEGREDO,
      sqlClient: e.sql,
    });
    assertEquals(res.status, 500);
    assertEquals((await res.json()).erro, "provedor_de_email_nao_configurado");
    assertEquals(e.arquivados, []);
  } finally {
    if (anterior) Deno.env.set("SMTP_HOST", anterior);
  }
});

Deno.test("porta: fila vazia responde 200 sem enviar nada", async () => {
  const e = espiao([]);
  const res = await chamar(e, sucesso);
  assertEquals(res.status, 200);
  assertEquals((await res.json()).processados, 0);
});

// ── A classificação do erro do provedor ──────────────────────────────────────

Deno.test("provedor: 4xx é transitório, 5xx não é, e nenhum dos dois guarda a mensagem", () => {
  const a = classificarErro(new Error("451 4.3.0 Try again later"));
  assertEquals(a, { codigo: "smtp_451", transitorio: true });

  const b = classificarErro(new Error("550 5.1.1 <ana@frila.test>: user unknown"));
  assertEquals(b, { codigo: "smtp_550", transitorio: false });
  // O código que vai ao banco não tem como conter o endereço: só dígitos e `smtp_`.
  assert(/^[a-z0-9_]{1,60}$/.test(b.codigo));

  assertEquals(classificarErro(new Error("ECONNREFUSED")).transitorio, true);
  assertEquals(
    classificarErro(new Error("535 authentication failed")).codigo,
    "smtp_535",
  );
  assertEquals(classificarErro("qualquer coisa"), {
    codigo: "erro_nao_classificado",
    transitorio: true,
  });
});

Deno.test("provedor: todo código classificado cabe no CHECK de ocorrencia.email_ultimo_erro", () => {
  const amostras: unknown[] = [
    new Error("451 4.3.0 Try again later"),
    new Error("550 5.1.1 <ana@frila.test>: user unknown"),
    new Error("ECONNREFUSED"),
    new Error("authentication failed for user ana@frila.test"),
    new Error("algo completamente inesperado com acento à ü"),
    "",
    null,
  ];
  for (const a of amostras) {
    const { codigo } = classificarErro(a);
    assert(
      /^[a-z0-9_]{1,60}$/.test(codigo),
      `o código ${JSON.stringify(codigo)} seria recusado pelo banco`,
    );
  }
});

Deno.test("criarSqlClient exige DATABASE_URL em vez de silenciosamente não gravar", () => {
  const url = Deno.env.get("DATABASE_URL");
  const supa = Deno.env.get("SUPABASE_DB_URL");
  Deno.env.delete("DATABASE_URL");
  Deno.env.delete("SUPABASE_DB_URL");
  try {
    let lancou = false;
    try {
      criarSqlClient({});
    } catch {
      lancou = true;
    }
    assert(lancou, "criarSqlClient aceitou ficar sem banco");
  } finally {
    if (url) Deno.env.set("DATABASE_URL", url);
    if (supa) Deno.env.set("SUPABASE_DB_URL", supa);
  }
});
