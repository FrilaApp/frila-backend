// Testes da Edge Function expurgar-midias (cartão ZZ0WTtu4 · RN14).
//
// Tudo por injeção de dependência: nem rede nem banco. O que importa provar aqui não é a
// chamada HTTP, é a ORDEM — confirmar no banco só depois de o arquivo ter saído do bucket,
// e nunca confirmar quando ele ficou. Um teste que medisse só "retornou 200" passaria com
// a ordem invertida, que é exatamente o defeito caro: registro de conformidade sobre foto
// que continua lá.

import { assertEquals } from "jsr:@std/assert@1.0.19";
import { handler, HandlerDeps, MensagemExpurgo } from "./index.ts";

const MOCK_URL = "http://127.0.0.1:54321";
const MOCK_SERVICE_ROLE = "service-role-key-mock";
const MOCK_SECRET = "segredo-agendador-mock";
const MOCK_DB_URL = "postgresql://mock:mock@localhost:5432/mock";

const VERIF_1 = "ad000000-0000-4000-8000-000000000001";
const VERIF_2 = "ad000000-0000-4000-8000-000000000002";

function mensagem(id: string, msgId: number, readCt = 1): MensagemExpurgo {
  return {
    msg_id: msgId,
    read_ct: readCt,
    verificacao_id: id,
    bucket: "documentos-identidade",
    caminhos: [`${id}/frente.jpg`, `${id}/verso.jpg`, `${id}/selfie.jpg`],
  };
}

interface Registro {
  apagados: string[];
  confirmados: string[];
  confirmadosDetalhes?: Array<{ id: string; origem?: string }>;
  removidosDaFila: number[];
}

function mockDeps(opcoes: {
  mensagens?: MensagemExpurgo[];
  statusPorCaminho?: (caminho: string, bucket?: string) => number;
  erroAoLerFila?: boolean;
  erroAoConfirmar?: boolean;
  registro?: Registro;
}): HandlerDeps {
  const reg = opcoes.registro ?? { apagados: [], confirmados: [], confirmadosDetalhes: [], removidosDaFila: [] };
  if (!reg.confirmadosDetalhes) reg.confirmadosDetalhes = [];

  const fetchFn = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const cabecalhos = (init?.headers ?? {}) as Record<string, string>;

    // A remoção no Storage exige service_role: sem ela o bucket privado não se mexe.
    if (cabecalhos["Authorization"] !== `Bearer ${MOCK_SERVICE_ROLE}`) {
      return Promise.resolve(new Response("{}", { status: 401 }));
    }

    const m = url.match(/\/storage\/v1\/object\/([^/]+)\/(.+)$/);
    const bucket = m ? m[1] : "";
    const caminho = m ? decodeURIComponent(m[2].split("/").map(decodeURIComponent).join("/")) : "";
    const status = opcoes.statusPorCaminho ? opcoes.statusPorCaminho(caminho, bucket) : 200;
    if (status === 200) reg.apagados.push(caminho);
    return Promise.resolve(new Response("{}", { status }));
  };

  return {
    fetchFn: fetchFn as unknown as typeof fetch,
    supabaseUrl: MOCK_URL,
    serviceRoleKey: MOCK_SERVICE_ROLE,
    agendadorSecret: MOCK_SECRET,
    dbUrl: MOCK_DB_URL,
    sqlClient: {
      lerLote: (_q: number, _v: number) => {
        if (opcoes.erroAoLerFila) return Promise.reject(new Error("fila ilegivel"));
        return Promise.resolve(opcoes.mensagens ?? []);
      },
      confirmarExpurgo: (id: string, origem?: string) => {
        if (opcoes.erroAoConfirmar) return Promise.reject(new Error("banco fora"));
        reg.confirmados.push(id);
        reg.confirmadosDetalhes?.push({ id, origem });
        return Promise.resolve(true);
      },
      removerDaFila: (msgId: number) => {
        reg.removidosDaFila.push(msgId);
        return Promise.resolve();
      },
    },
  };
}

function pedido(comSegredo = true, corpo: unknown = {}): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (comSegredo) headers["x-agendador-secret"] = MOCK_SECRET;
  return new Request(`${MOCK_URL}/functions/v1/expurgar-midias`, {
    method: "POST",
    headers,
    body: JSON.stringify(corpo),
  });
}

Deno.test("sem x-agendador-secret é 401 e não toca em bucket nem banco", async () => {
  const reg: Registro = { apagados: [], confirmados: [], removidosDaFila: [] };
  const deps = mockDeps({ mensagens: [mensagem(VERIF_1, 1)], registro: reg });

  const resp = await handler(pedido(false), deps);
  assertEquals(resp.status, 401);
  assertEquals((await resp.json()).code, "nao_autenticado");
  // A recusa vem antes de qualquer efeito: nada apagado, nada confirmado.
  assertEquals(reg.apagados.length, 0);
  assertEquals(reg.confirmados.length, 0);
  assertEquals(reg.removidosDaFila.length, 0);
});

Deno.test("segredo errado é 401, e não 403: a função não diz se o segredo existe", async () => {
  const req = new Request(`${MOCK_URL}/functions/v1/expurgar-midias`, {
    method: "POST",
    headers: { "x-agendador-secret": "segredo-errado" },
    body: "{}",
  });
  const resp = await handler(req, mockDeps({ mensagens: [mensagem(VERIF_1, 1)] }));
  assertEquals(resp.status, 401);
});

Deno.test("método diferente de POST é 405", async () => {
  const req = new Request(`${MOCK_URL}/functions/v1/expurgar-midias`, { method: "GET" });
  const resp = await handler(req, mockDeps({}));
  assertEquals(resp.status, 405);
});

Deno.test("fila vazia é 200 com zero processados", async () => {
  const reg: Registro = { apagados: [], confirmados: [], removidosDaFila: [] };
  const resp = await handler(pedido(), mockDeps({ mensagens: [], registro: reg }));
  assertEquals(resp.status, 200);
  const corpo = await resp.json();
  assertEquals(corpo.mensagens_lidas, 0);
  assertEquals(corpo.verificacoes_confirmadas, 0);
  assertEquals(corpo.arquivos_removidos, 0);
  assertEquals(reg.confirmados.length, 0);
});

Deno.test("caminho feliz: apaga as três partes, confirma no banco e tira da fila", async () => {
  const reg: Registro = { apagados: [], confirmados: [], removidosDaFila: [] };
  const deps = mockDeps({ mensagens: [mensagem(VERIF_1, 11), mensagem(VERIF_2, 12)], registro: reg });

  const resp = await handler(pedido(), deps);
  assertEquals(resp.status, 200);
  const corpo = await resp.json();

  assertEquals(corpo.mensagens_lidas, 2);
  assertEquals(corpo.verificacoes_confirmadas, 2);
  assertEquals(corpo.arquivos_removidos, 6);
  assertEquals(corpo.pendentes, []);
  assertEquals(reg.apagados.length, 6);
  assertEquals(reg.confirmados, [VERIF_1, VERIF_2]);
  assertEquals(reg.removidosDaFila, [11, 12]);
});

Deno.test("404 no Storage conta como sucesso: o que importa é a ausência do arquivo", async () => {
  const reg: Registro = { apagados: [], confirmados: [], removidosDaFila: [] };
  const deps = mockDeps({
    mensagens: [mensagem(VERIF_1, 21)],
    statusPorCaminho: () => 404,
    registro: reg,
  });

  const resp = await handler(pedido(), deps);
  const corpo = await resp.json();
  // Reentrega depois de um expurgo parcial é normal; tratar 404 como falha travaria a
  // mensagem na fila para sempre, com o arquivo já fora do bucket.
  assertEquals(corpo.verificacoes_confirmadas, 1);
  assertEquals(reg.confirmados, [VERIF_1]);
  assertEquals(reg.removidosDaFila, [21]);
});

Deno.test("falha 5xx no Storage não confirma no banco nem tira da fila", async () => {
  const reg: Registro = { apagados: [], confirmados: [], removidosDaFila: [] };
  const deps = mockDeps({
    mensagens: [mensagem(VERIF_1, 31)],
    statusPorCaminho: (c) => (c.endsWith("selfie.jpg") ? 503 : 200),
    registro: reg,
  });

  const resp = await handler(pedido(), deps);
  assertEquals(resp.status, 200);
  const corpo = await resp.json();

  // Esta é a asserção central do arquivo: duas partes saíram, uma ficou, e por isso NADA
  // é confirmado. Confirmar aqui anularia os caminhos no banco e deixaria a selfie no
  // bucket, sem ninguém para achá-la depois.
  assertEquals(corpo.verificacoes_confirmadas, 0);
  assertEquals(reg.confirmados.length, 0);
  assertEquals(reg.removidosDaFila.length, 0);
  assertEquals(corpo.pendentes.length, 1);
  assertEquals(corpo.pendentes[0].verificacao_id, VERIF_1);
  assertEquals(corpo.pendentes[0].status, 503);
});

Deno.test("parte que fica não impede a verificação seguinte de fechar", async () => {
  const reg: Registro = { apagados: [], confirmados: [], removidosDaFila: [] };
  const deps = mockDeps({
    mensagens: [mensagem(VERIF_1, 41), mensagem(VERIF_2, 42)],
    statusPorCaminho: (c) => (c.startsWith(VERIF_1) ? 500 : 200),
    registro: reg,
  });

  const corpo = await (await handler(pedido(), deps)).json();
  assertEquals(reg.confirmados, [VERIF_2]);
  assertEquals(reg.removidosDaFila, [42]);
  assertEquals(corpo.pendentes.length, 1);
  assertEquals(corpo.pendentes[0].verificacao_id, VERIF_1);
});

Deno.test("relido muitas vezes vira alerta na resposta, para o atraso não ser silêncio", async () => {
  const deps = mockDeps({
    mensagens: [mensagem(VERIF_1, 51, 7)],
    statusPorCaminho: () => 500,
  });

  const corpo = await (await handler(pedido(), deps)).json();
  assertEquals(corpo.alertas.length, 1);
  assertEquals(corpo.alertas[0].read_ct, 7);
  assertEquals(corpo.verificacoes_confirmadas, 0);
});

Deno.test("arquivo fora do bucket e banco fora do ar: a mensagem fica na fila", async () => {
  const reg: Registro = { apagados: [], confirmados: [], removidosDaFila: [] };
  const deps = mockDeps({
    mensagens: [mensagem(VERIF_1, 61)],
    erroAoConfirmar: true,
    registro: reg,
  });

  const corpo = await (await handler(pedido(), deps)).json();
  // O arquivo já saiu, mas o banco não soube. Tirar da fila aqui deixaria a linha com
  // caminho preenchido para sempre, e o relatório de mídia vencida mentiria.
  assertEquals(reg.apagados.length, 3);
  assertEquals(reg.removidosDaFila.length, 0);
  assertEquals(corpo.verificacoes_confirmadas, 0);
  assertEquals(corpo.pendentes[0].status, 500);
});

Deno.test("fila ilegível é 500, e não 200 com zero: fila não lida não é fila vazia", async () => {
  const resp = await handler(pedido(), mockDeps({ erroAoLerFila: true }));
  assertEquals(resp.status, 500);
  assertEquals((await resp.json()).code, "erro_interno");
});

Deno.test("mensagem sem verificacao_id sai da fila e aparece como pendente", async () => {
  const reg: Registro = { apagados: [], confirmados: [], removidosDaFila: [] };
  const deps = mockDeps({
    mensagens: [{ msg_id: 71, read_ct: 1, verificacao_id: "", bucket: "documentos-identidade", caminhos: [] }],
    registro: reg,
  });

  const corpo = await (await handler(pedido(), deps)).json();
  // Relê para sempre o que não tem como confirmar seria entupir a fila em silêncio.
  assertEquals(reg.confirmados.length, 0);
  assertEquals(reg.removidosDaFila, [71]);
  assertEquals(corpo.pendentes[0].status, 422);
});

Deno.test("o lote do corpo é respeitado e limitado a 100", async () => {
  let pedido_lote = 0;
  const deps: HandlerDeps = {
    ...mockDeps({ mensagens: [] }),
    sqlClient: {
      lerLote: (q: number) => {
        pedido_lote = q;
        return Promise.resolve([]);
      },
      confirmarExpurgo: () => Promise.resolve(true),
      removerDaFila: () => Promise.resolve(),
    },
  };

  await handler(pedido(true, { lote: 5000 }), deps);
  assertEquals(pedido_lote, 100);

  await handler(pedido(true, { lote: 7 }), deps);
  assertEquals(pedido_lote, 7);
});

Deno.test("foto de perfil apagando original e miniatura no bucket midia-perfil e confirmando com origem foto_perfil (CA4)", async () => {
  const reg: Registro = { apagados: [], confirmados: [], confirmadosDetalhes: [], removidosDaFila: [] };
  const FOTO_ID = "fd000000-0000-4000-8000-000000000001";
  const msgPerfil: MensagemExpurgo = {
    msg_id: 81,
    read_ct: 1,
    verificacao_id: FOTO_ID,
    bucket: "midia-perfil",
    caminhos: [`perfil/${FOTO_ID}.jpg`, `perfil/${FOTO_ID}_thumb.jpg`],
    origem: "foto_perfil",
  };

  const deps = mockDeps({
    mensagens: [msgPerfil],
    registro: reg,
  });

  const resp = await handler(pedido(), deps);
  assertEquals(resp.status, 200);
  const corpo = await resp.json();
  assertEquals(corpo.verificacoes_confirmadas, 1);
  assertEquals(corpo.arquivos_removidos, 2);
  assertEquals(reg.apagados, [`perfil/${FOTO_ID}.jpg`, `perfil/${FOTO_ID}_thumb.jpg`]);
  assertEquals(reg.confirmadosDetalhes, [{ id: FOTO_ID, origem: "foto_perfil" }]);
  assertEquals(reg.removidosDaFila, [81]);
});

Deno.test("mensagem antiga sem origem é verificacao e mensagem nova é foto_perfil (critério 4 de B4b)", async () => {
  const reg: Registro = { apagados: [], confirmados: [], confirmadosDetalhes: [], removidosDaFila: [] };
  const FOTO_ID = "fd000000-0000-4000-8000-000000000002";
  const msgLegadaSemOrigem: MensagemExpurgo = {
    msg_id: 91,
    read_ct: 1,
    verificacao_id: VERIF_1,
    bucket: "documentos-identidade",
    caminhos: [`${VERIF_1}/frente.jpg`],
  };
  const msgFotoPerfil: MensagemExpurgo = {
    msg_id: 92,
    read_ct: 1,
    verificacao_id: FOTO_ID,
    bucket: "midia-perfil",
    caminhos: [`perfil/${FOTO_ID}.jpg`],
    origem: "foto_perfil",
  };

  const deps = mockDeps({
    mensagens: [msgLegadaSemOrigem, msgFotoPerfil],
    registro: reg,
  });

  const resp = await handler(pedido(), deps);
  assertEquals(resp.status, 200);
  const corpo = await resp.json();
  assertEquals(corpo.verificacoes_confirmadas, 2);
  assertEquals(reg.confirmadosDetalhes, [
    { id: VERIF_1, origem: undefined },
    { id: FOTO_ID, origem: "foto_perfil" },
  ]);
  assertEquals(reg.removidosDaFila, [91, 92]);
});
