// Testes Deno da Edge Function enviar-push com simulação do FCM HTTP v1.
// Cartão 36fU0CEO: Envio de push pelo FCM, registro do aparelho e estado de entrega.
//
// Critérios testados:
// 1. Falha fechada sem AGENDADOR_SECRET e recusa de service_role como segredo do agendador.
// 2. Whitelist de payload (RN15): apenas reaberta (booleano) e UUIDs específicos no message.data.
// 3. Backoff exponencial com proxima_tentativa_em e worker não reenvia antes do vencimento.
// 4. Instante real de envio ao FCM gravado em enviada_em e aceita_em medidos no RNF02.

import "./test_setup.ts";
import { assertEquals, assert, assertMatch, assertRejects } from "jsr:@std/assert@1";
import {
  processarEnvioPush,
  carregarContaDeServico,
  titulosECorposPorTipo,
  filtrarDataPayloadFcm,
  calcularProximaTentativa,
  formatarHorario,
  buscarVariaveisDoTexto,
  capitalizar,
  criarSqlClient,
  SqlClient,
  GravarFalhaPushParams,
  GravarAceitePushParams,
  VariaveisDoTexto,
} from "./index.ts";
import { FcmServiceAccount, sendFcmMessage, getAccessToken } from "./fcm.ts";

const SEGREDO_TESTE = "frila-teste-segredo-agendador-local";

interface MockSqlOpcoes {
  notificacaoExpirada?: boolean | ((id: string) => boolean | Promise<boolean>);
  chamadasFalha?: Array<GravarFalhaPushParams>;
  chamadasAceite?: Array<GravarAceitePushParams>;
  tokensRemovidos?: string[];
  contextoDoPush?: (id: string) => Record<string, unknown> | Promise<Record<string, unknown>>;
  obterConteudoPushLembrete?: (
    turnoId: string,
    usuarioId: string,
    tipo: string,
  ) => Promise<{ title: string; body: string } | null>;
}

function criarMockSqlClient(opcoes: MockSqlOpcoes = {}): SqlClient {
  return {
    notificacaoExpirada: (id: string) => {
      if (typeof opcoes.notificacaoExpirada === "function") {
        return Promise.resolve(opcoes.notificacaoExpirada(id));
      }
      return Promise.resolve(opcoes.notificacaoExpirada ?? false);
    },
    gravarFalhaPush: (params: GravarFalhaPushParams) => {
      opcoes.chamadasFalha?.push(params);
      return Promise.resolve();
    },
    gravarAceitePush: (params: GravarAceitePushParams) => {
      opcoes.chamadasAceite?.push(params);
      return Promise.resolve();
    },
    removerTokenFcm: (token: string) => {
      opcoes.tokensRemovidos?.push(token);
      return Promise.resolve(1);
    },
    contextoDoPush: (id: string) => {
      if (typeof opcoes.contextoDoPush === "function") {
        return Promise.resolve(opcoes.contextoDoPush(id));
      }
      return Promise.resolve({});
    },
    obterConteudoPushLembrete: opcoes.obterConteudoPushLembrete
      ? opcoes.obterConteudoPushLembrete
      : () => Promise.resolve(null),
  };
}

// Helper para gerar par de chaves RSA em memória para os testes
async function gerarContaDeServicoTeste(): Promise<FcmServiceAccount> {
  const keyPair = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );

  const pkcs8 = await crypto.subtle.exportKey("pkcs8", keyPair.privateKey);
  const binary = String.fromCharCode(...new Uint8Array(pkcs8));
  const b64 = btoa(binary);
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`;

  return {
    project_id: "frila-test-project",
    client_email: "firebase-adminsdk@frila-test-project.iam.gserviceaccount.com",
    private_key: pem,
    token_uri: "http://mock-oauth/token",
  };
}

Deno.test("FCM client: obtém access token com JWT assinado e envia mensagem com sucesso (200)", async () => {
  const sa = await gerarContaDeServicoTeste();

  const mockFetch: typeof fetch = (input: RequestInfo | URL, _init?: RequestInit) => {
    const url = input.toString();

    if (url === "http://mock-oauth/token") {
      return Promise.resolve(
        new Response(
          JSON.stringify({
            access_token: "mock-google-access-token-12345",
            token_type: "Bearer",
            expires_in: 3600,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/messages:send")) {
      return Promise.resolve(
        new Response(
          JSON.stringify({
            name: "projects/frila-test-project/messages/msg_987654321",
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    return Promise.reject(new Error(`URL não tratada no mock: ${url}`));
  };

  const token = await getAccessToken(sa, mockFetch);
  assertEquals(token, "mock-google-access-token-12345");

  const sendRes = await sendFcmMessage(
    sa.project_id,
    token,
    {
      token: "fcm_device_token_teste_1234567890",
      title: "Nova vaga disponível",
      body: "Você tem um novo turno compatível",
    },
    { apiUrl: "http://mock-fcm/messages:send", fetchFn: mockFetch },
  );

  assertEquals(sendRes.ok, true);
  assertEquals(sendRes.status, 200);
  assertEquals(sendRes.messageId, "projects/frila-test-project/messages/msg_987654321");
});

// ── Bloqueio 1: Autenticação estrita do agendador ─────────────────────────────

Deno.test("Bloqueio 1: falha fechado na inicialização sem AGENDADOR_SECRET", async () => {
  // Caminho absoluto a partir deste arquivo: o teste não pode depender do diretório de onde o deno test roda.
  const modulo = new URL("./index.ts", import.meta.url).href;
  const cmd = new Deno.Command(Deno.execPath(), {
    args: ["eval", `await import(${JSON.stringify(modulo)});`],
    env: { AGENDADOR_SECRET: "" },
    clearEnv: true,
  });
  const output = await cmd.output();
  assertEquals(output.success, false);
  const stderr = new TextDecoder().decode(output.stderr);
  assert(stderr.includes("AGENDADOR_SECRET é obrigatório"), "Deve lançar erro de inicialização");
});

Deno.test("Bloqueio 1: recusa chamada sem segredo ou com segredo errado (401)", async () => {
  const sa = await gerarContaDeServicoTeste();

  const reqSemAuth = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({}),
  });

  const resSemAuth = await processarEnvioPush(reqSemAuth, { serviceAccount: sa });
  assertEquals(resSemAuth.status, 401);

  const reqErrado = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": "segredo-incorreto",
    },
    body: JSON.stringify({}),
  });

  const resErrado = await processarEnvioPush(reqErrado, { serviceAccount: sa });
  assertEquals(resErrado.status, 401);
});

Deno.test("Bloqueio 1: não aceita SUPABASE_SERVICE_ROLE_KEY como substituto do segredo", async () => {
  const sa = await gerarContaDeServicoTeste();
  const serviceKey = "service-role-key-xyz-123";

  const reqServiceRole = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": serviceKey,
    },
    body: JSON.stringify({}),
  });

  const res = await processarEnvioPush(reqServiceRole, {
    serviceAccount: sa,
    serviceRoleKey: serviceKey,
  });
  assertEquals(res.status, 401);
});

Deno.test("Bloqueio 1: aceita AGENDADOR_SECRET via x-agendador-secret ou Bearer", async () => {
  const sa = await gerarContaDeServicoTeste();

  const mockFetch: typeof fetch = (input: RequestInfo | URL) => {
    const url = input.toString();
    if (url.includes("/rest/v1/notificacao")) {
      return Promise.resolve(new Response(JSON.stringify([]), { status: 200 }));
    }
    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const reqHeader = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({}),
  });

  const resHeader = await processarEnvioPush(reqHeader, {
    serviceAccount: sa,
    fetchFn: mockFetch,
  });
  assertEquals(resHeader.status, 200);

  const reqBearer = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${SEGREDO_TESTE}`,
    },
    body: JSON.stringify({}),
  });

  const resBearer = await processarEnvioPush(reqBearer, {
    serviceAccount: sa,
    fetchFn: mockFetch,
  });
  assertEquals(resBearer.status, 200);
});

// ── Bloqueio 2: Whitelist de payload do FCM (RN15) ─────────────────────────────

Deno.test("Bloqueio 2: filtrarDataPayloadFcm só permite chaves autorizadas e tipos corretos", () => {
  const payloadBruto = {
    // Permitidos
    vaga_id: "d0000000-0000-4000-8000-000000000001",
    posicao_id: "e0000000-0000-4000-8000-000000000002",
    turno_id: "f0000000-0000-4000-8000-000000000003",
    estabelecimento_id: "c0000000-0000-4000-8000-000000000004",
    reaberta: true,
    // Proibidos / dados pessoais (RN15)
    nome: "João da Silva",
    telefone: "+556199999999",
    cpf: "123.456.789-00",
    email: "joao@example.com",
    valor_centavos: 15000,
    referencia_id: "qualquer_coisa",
    // Chave UUID permitida mas com formato inválido -> descartada
    fake_vaga_id: "123-abc",
  };

  const filtrado = filtrarDataPayloadFcm("vaga", payloadBruto);

  assertEquals(filtrado.tipo, "vaga");
  assertEquals(filtrado.vaga_id, "d0000000-0000-4000-8000-000000000001");
  assertEquals(filtrado.posicao_id, "e0000000-0000-4000-8000-000000000002");
  assertEquals(filtrado.turno_id, "f0000000-0000-4000-8000-000000000003");
  assertEquals(filtrado.estabelecimento_id, "c0000000-0000-4000-8000-000000000004");
  assertEquals(filtrado.reaberta, "true");

  // Assegura que nenhum dado pessoal ou chave não listada entrou
  assertEquals((filtrado as Record<string, string>).nome, undefined);
  assertEquals((filtrado as Record<string, string>).telefone, undefined);
  assertEquals((filtrado as Record<string, string>).cpf, undefined);
  assertEquals((filtrado as Record<string, string>).email, undefined);
  assertEquals((filtrado as Record<string, string>).valor_centavos, undefined);
  assertEquals((filtrado as Record<string, string>).referencia_id, undefined);
});

Deno.test("Bloqueio 2: reaberta não-booleana ou UUID inválido são descartados", () => {
  const payloadInvalido = {
    reaberta: "true", // string, não booleano -> descarta
    vaga_id: "nao-eh-uuid",
    posicao_id: 12345,
  };

  const filtrado = filtrarDataPayloadFcm("vagas_agrupadas", payloadInvalido as Record<string, unknown>);
  assertEquals(filtrado.tipo, "vagas_agrupadas");
  assertEquals(filtrado.reaberta, undefined);
  assertEquals(filtrado.vaga_id, undefined);
  assertEquals(filtrado.posicao_id, undefined);
});

// ── Bloqueio 3: Backoff exponencial e proxima_tentativa_em ────────────────────

Deno.test("Bloqueio 3: calcularProximaTentativa segue backoff exponencial", () => {
  const agora = new Date("2026-09-26T10:00:00.000Z");

  // tentativa 1: 10 * 2^0 = 10s
  const p1 = calcularProximaTentativa(1, 10, agora);
  assertEquals(p1.toISOString(), "2026-09-26T10:00:10.000Z");

  // tentativa 2: 10 * 2^1 = 20s
  const p2 = calcularProximaTentativa(2, 10, agora);
  assertEquals(p2.toISOString(), "2026-09-26T10:00:20.000Z");

  // tentativa 3: 10 * 2^2 = 40s
  const p3 = calcularProximaTentativa(3, 10, agora);
  assertEquals(p3.toISOString(), "2026-09-26T10:00:40.000Z");

  // tentativa 4: 10 * 2^3 = 80s
  const p4 = calcularProximaTentativa(4, 10, agora);
  assertEquals(p4.toISOString(), "2026-09-26T10:01:20.000Z");
});

Deno.test("Bloqueio 3: worker não reenvia notificação antes do vencimento de proxima_tentativa_em", async () => {
  const sa = await gerarContaDeServicoTeste();
  let fcmDisparado = false;

  const mockFetch: typeof fetch = (input: RequestInfo | URL) => {
    const url = input.toString();

    if (url === "http://mock-oauth/token") {
      return Promise.resolve(
        new Response(
          JSON.stringify({ access_token: "token-oauth-ok", token_type: "Bearer", expires_in: 3600 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/notificacao?id=eq.")) {
      // Notificação com proxima_tentativa_em daqui a 10 minutos
      const futuro = new Date(Date.now() + 600000).toISOString();
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              id: "a1000000-0000-4000-8000-000000000001",
              usuario_id: "u1000000-0000-4000-8000-000000000001",
              tipo: "vaga",
              referencia_id: "v1000000-0000-4000-8000-000000000001",
              payload: {},
              tentativas: 1,
              estado_entrega: "pendente",
              proxima_tentativa_em: futuro,
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/messages:send")) {
      fcmDisparado = true;
      return Promise.resolve(new Response("{}", { status: 200 }));
    }

    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ notificacao_id: "a1000000-0000-4000-8000-000000000001" }),
  });

  const res = await processarEnvioPush(req, {
    serviceAccount: sa,
    fetchFn: mockFetch,
    sqlClient: criarMockSqlClient(),
  });

  assertEquals(res.status, 200);
  const data = await res.json();
  assertEquals(data.relatorio[0].status, "pendente");
  assertEquals(data.relatorio[0].detalhe, "aguardando_backoff");
  assertEquals(fcmDisparado, false, "FCM não deve ser chamado antes do vencimento do backoff");
});

Deno.test("Bloqueio 3: erro transitório agenda proxima_tentativa_em no banco", async () => {
  const sa = await gerarContaDeServicoTeste();
  const chamadasFalha: GravarFalhaPushParams[] = [];
  const sqlClient = criarMockSqlClient({ chamadasFalha });

  const mockFetch: typeof fetch = (input: RequestInfo | URL) => {
    const url = input.toString();

    if (url === "http://mock-oauth/token") {
      return Promise.resolve(
        new Response(
          JSON.stringify({ access_token: "token-oauth-ok", token_type: "Bearer", expires_in: 3600 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/notificacao?id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              id: "a3000000-0000-4000-8000-000000000003",
              usuario_id: "u3000000-0000-4000-8000-000000000003",
              tipo: "vaga",
              referencia_id: "v3000000-0000-4000-8000-000000000003",
              payload: {},
              tentativas: 1,
              estado_entrega: "pendente",
              proxima_tentativa_em: null,
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/dispositivo?usuario_id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            { id: "d3", token_fcm: "fcm_token_3", plataforma: "android" },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/messages:send")) {
      // Retorna 503 Service Unavailable (erro transitório)
      return Promise.resolve(
        new Response(
          JSON.stringify({ error: { code: 503, message: "Server Unavailable", status: "UNAVAILABLE" } }),
          { status: 503, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ notificacao_id: "a3000000-0000-4000-8000-000000000003" }),
  });

  const res = await processarEnvioPush(req, {
    serviceAccount: sa,
    fetchFn: mockFetch,
    sqlClient,
  });

  assertEquals(res.status, 200);
  const data = await res.json();
  assertEquals(data.relatorio[0].status, "pendente");

  const rpcFalha = chamadasFalha[0];
  assert(rpcFalha !== undefined, "gravar_falha_push deve ser chamada");
  assertEquals(rpcFalha.permanente, false);
  assertEquals(rpcFalha.teto, 5);
  assert(rpcFalha.proximaTentativaEm !== null, "proxima_tentativa_em deve ser preenchido");
  assert(rpcFalha.enviadaEm !== null, "enviada_em deve ser registrado com o instante do envio");
});

// ── Bloqueio 4: Instante real de envio ao FCM e medição RNF02 ────────────────

Deno.test("Bloqueio 4: 200 grava instante real de envio e aceite para medir RNF02", async () => {
  const sa = await gerarContaDeServicoTeste();
  const chamadasAceite: GravarAceitePushParams[] = [];
  const sqlClient = criarMockSqlClient({ chamadasAceite });

  const mockFetch: typeof fetch = (input: RequestInfo | URL) => {
    const url = input.toString();

    if (url === "http://mock-oauth/token") {
      return Promise.resolve(
        new Response(
          JSON.stringify({ access_token: "token-oauth-ok", token_type: "Bearer", expires_in: 3600 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/notificacao?id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              id: "a1000000-0000-4000-8000-000000000001",
              usuario_id: "u1000000-0000-4000-8000-000000000001",
              tipo: "vaga",
              referencia_id: "v1000000-0000-4000-8000-000000000001",
              payload: {
                vaga_id: "d0000000-0000-4000-8000-000000000001",
                reaberta: true,
                dado_vazado: "nao_deve_aparecer",
              },
              tentativas: 0,
              estado_entrega: "pendente",
              proxima_tentativa_em: null,
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/dispositivo?usuario_id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            { id: "disp-1", token_fcm: "fcm_token_device_1", plataforma: "ios" },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/messages:send")) {
      return Promise.resolve(
        new Response(
          JSON.stringify({ name: "projects/frila-test-project/messages/msg_1" }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ notificacao_id: "a1000000-0000-4000-8000-000000000001" }),
  });

  const res = await processarEnvioPush(req, {
    serviceAccount: sa,
    fetchFn: mockFetch,
    fcmApiUrl: "http://mock-fcm/messages:send",
    sqlClient,
  });

  assertEquals(res.status, 200);
  const data = await res.json();
  assertEquals(data.relatorio[0].status, "enviada");

  const rpcAceite = chamadasAceite[0];
  assert(rpcAceite !== undefined, "gravar_aceite_push deve ter sido invocada");
  assert(typeof rpcAceite.enviadaEm === "string", "p_enviada_em deve ser registrado com timestamp real");
  assert(typeof rpcAceite.aceitaEm === "string", "p_aceita_em deve ser registrado com timestamp de aceite");

  // Valida que o intervalo medido entre o disparo e o aceite é inferior a 60 segundos
  const tEnvio = new Date(rpcAceite.enviadaEm as string).getTime();
  const tAceite = new Date(rpcAceite.aceitaEm as string).getTime();
  const diferencaSegundos = (tAceite - tEnvio) / 1000;
  assert(diferencaSegundos <= 60, "Tempo do envio até aceite deve cumprir RNF02 (<= 60 s)");
});

// ── Casos de borda adicionais ──────────────────────────────────────────────────

Deno.test("Edge Function: 404/410 UNREGISTERED remove o token do aparelho", async () => {
  const sa = await gerarContaDeServicoTeste();
  const tokensRemovidos: string[] = [];
  const chamadasFalha: GravarFalhaPushParams[] = [];
  const sqlClient = criarMockSqlClient({ tokensRemovidos, chamadasFalha });

  const mockFetch: typeof fetch = (input: RequestInfo | URL) => {
    const url = input.toString();

    if (url === "http://mock-oauth/token") {
      return Promise.resolve(
        new Response(
          JSON.stringify({ access_token: "token-oauth-ok", token_type: "Bearer", expires_in: 3600 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/notificacao?id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              id: "a2000000-0000-4000-8000-000000000002",
              usuario_id: "u2000000-0000-4000-8000-000000000002",
              tipo: "vaga",
              referencia_id: "v2000000-0000-4000-8000-000000000002",
              payload: {},
              tentativas: 0,
              estado_entrega: "pendente",
              proxima_tentativa_em: null,
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/dispositivo?usuario_id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            { id: "d2", token_fcm: "fcm_token_invalido_unregistered", plataforma: "ios" },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/messages:send")) {
      return Promise.resolve(
        new Response(
          JSON.stringify({
            error: {
              code: 404,
              message: "Requested entity was not found.",
              status: "NOT_FOUND",
              details: [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: "UNREGISTERED" }],
            },
          }),
          { status: 404, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ notificacao_id: "a2000000-0000-4000-8000-000000000002" }),
  });

  const res = await processarEnvioPush(req, {
    serviceAccount: sa,
    fetchFn: mockFetch,
    fcmApiUrl: "http://mock-fcm/messages:send",
    sqlClient,
  });

  assertEquals(res.status, 200);
  const data = await res.json();
  assertEquals(data.relatorio[0].status, "falhou");
  assertEquals(data.relatorio[0].detalhe, "UNREGISTERED");

  assert(tokensRemovidos.includes("fcm_token_invalido_unregistered"), "remover_token_fcm deve ser chamada");
  assertEquals(chamadasFalha[0]?.motivo, "UNREGISTERED");
  assertEquals(chamadasFalha[0]?.permanente, true);
});

Deno.test("Edge Function: não reenvia se início da vaga ou turno já passou", async () => {
  const sa = await gerarContaDeServicoTeste();
  let fcmChamado = false;
  const chamadasFalha: GravarFalhaPushParams[] = [];
  const sqlClient = criarMockSqlClient({
    notificacaoExpirada: true,
    chamadasFalha,
  });

  const mockFetch: typeof fetch = (input: RequestInfo | URL) => {
    const url = input.toString();

    if (url === "http://mock-oauth/token") {
      return Promise.resolve(
        new Response(
          JSON.stringify({ access_token: "token-oauth-ok", token_type: "Bearer", expires_in: 3600 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/notificacao?id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              id: "a4000000-0000-4000-8000-000000000004",
              usuario_id: "u4000000-0000-4000-8000-000000000004",
              tipo: "vaga",
              referencia_id: "v4000000-0000-4000-8000-000000000004",
              payload: {},
              tentativas: 1,
              estado_entrega: "pendente",
              proxima_tentativa_em: null,
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/messages:send")) {
      fcmChamado = true;
      return Promise.resolve(new Response("{}", { status: 200 }));
    }

    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ notificacao_id: "a4000000-0000-4000-8000-000000000004" }),
  });

  const res = await processarEnvioPush(req, {
    serviceAccount: sa,
    fetchFn: mockFetch,
    fcmApiUrl: "http://mock-fcm/messages:send",
    sqlClient,
  });

  assertEquals(res.status, 200);
  const data = await res.json();
  assertEquals(data.relatorio[0].status, "falhou");
  assertEquals(data.relatorio[0].detalhe, "vaga_ou_turno_ja_iniciado");
  assertEquals(fcmChamado, false, "FCM não deve ser chamado para notificação de turno/vaga já iniciado");
  assertEquals(chamadasFalha[0]?.motivo, "vaga_ou_turno_ja_iniciado");
  assertEquals(chamadasFalha[0]?.permanente, true);
});

Deno.test("Segurança e Privacidade: títulos e corpos não contêm dados pessoais (RN15)", () => {
  const tipos = [
    "vaga",
    "vagas_agrupadas",
    "confirmacao",
    "lembrete_24h",
    "lembrete_3h",
    "inicio_sem_checkin",
    "atraso_15min",
    "fim_sem_checkout",
    "vaga_vazia",
    "checkin",
    "cancelamento",
    "avaliacao_disponivel",
  ];

  for (const tipo of tipos) {
    const { title, body } = titulosECorposPorTipo(tipo, {});
    assert(title.length > 0, `Título não pode ser vazio para ${tipo}`);
    assert(body.length > 0, `Corpo não pode ser vazio para ${tipo}`);
    assert(!body.includes("@"), `Corpo não pode conter e-mail (${tipo})`);
    assert(!body.includes("+55"), `Corpo não pode conter telefone (${tipo})`);
  }
});

// ── Atraso e reabertura (cartão e8XpOZJN) ─────────────────────────────────────
//
// Título e corpo copiados da planilha de notificações (casos 13, 16 e 17), e nenhum
// texto fora dela.

Deno.test("Planilha: início sem check-in (caso 13) e atraso de 15 min (caso 16)", () => {
  assertEquals(titulosECorposPorTipo("inicio_sem_checkin", {}), {
    title: "Horário de início do turno",
    body: "O horário de início chegou. Faça seu check-in ao chegar ao local.",
  });
  assertEquals(titulosECorposPorTipo("atraso_15min", {}), {
    title: "Check-in pendente há 15 min",
    body: "O profissional ainda não registrou presença. Você pode aguardar ou reabrir a vaga.",
  });
});

Deno.test("Planilha: cancelamento por reabertura por atraso (caso 17), e só ele", () => {
  assertEquals(titulosECorposPorTipo("cancelamento", {}, { reaberturaPorAtraso: true }), {
    title: "Turno cancelado por atraso",
    body: "O contratante reabriu a vaga por falta de check-in. O turno foi cancelado.",
  });
  const generico = titulosECorposPorTipo("cancelamento", {});
  assert(generico.title !== "Turno cancelado por atraso",
    "cancelamento comum não pode dizer que foi atraso");
});

Deno.test("Envio: cancelamento com ocorrência reabertura_por_atraso sai com o texto do caso 17", async () => {
  const sa = await gerarContaDeServicoTeste();
  const posicao = "e8a00000-0000-4000-8000-00000000aaaa";
  let enviado: { title?: string; body?: string } = {};
  let consultouOcorrencia = false;

  const mockFetch: typeof fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input.toString();
    const json = (corpo: unknown) =>
      Promise.resolve(new Response(JSON.stringify(corpo), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }));

    if (url === "http://mock-oauth/token") {
      return json({ access_token: "token-ok", token_type: "Bearer", expires_in: 3600 });
    }
    if (url.includes("/rest/v1/notificacao?id=eq.")) {
      return json([{
        id: "e8a00000-0000-4000-8000-00000000bbbb",
        usuario_id: "e8a00000-0000-4000-8000-0000000000e1",
        tipo: "cancelamento",
        referencia_id: posicao,
        payload: { tipo: "cancelamento", posicao_id: posicao, reaberta: true },
        tentativas: 0,
        estado_entrega: "pendente",
      }]);
    }
    if (url.includes("/rest/v1/rpc/notificacao_expirada")) return json(false);
    if (url.includes("/rest/v1/ocorrencia?")) {
      consultouOcorrencia = true;
      assert(url.includes(`posicao_id=eq.${posicao}`));
      assert(url.includes("motivo=eq.reabertura_por_atraso"));
      return json([{ id: "e8a00000-0000-4000-8000-00000000cccc" }]);
    }
    if (url.includes("/rest/v1/dispositivo?")) {
      return json([{ id: "d1", token_fcm: "token-e1", plataforma: "ios" }]);
    }
    if (url.includes("/messages:send")) {
      const corpo = JSON.parse(String(init?.body));
      enviado = corpo.message.notification;
      return json({ name: "projects/frila-test-project/messages/1" });
    }
    if (url.includes("/rest/v1/rpc/")) return json(null);
    throw new Error(`URL não tratada no mock: ${url}`);
  };

  const req = new Request("http://localhost/enviar-push", {
    method: "POST",
    headers: { "x-agendador-secret": SEGREDO_TESTE, "Content-Type": "application/json" },
    body: JSON.stringify({ notificacao_id: "e8a00000-0000-4000-8000-00000000bbbb" }),
  });

  const res = await processarEnvioPush(req, {
    supabaseUrl: "http://mock-supabase",
    serviceRoleKey: "service-role-de-teste",
    agendadorSecret: SEGREDO_TESTE,
    serviceAccount: sa,
    fetchFn: mockFetch,
    fcmApiUrl: "http://mock-fcm/messages:send",
    sqlClient: criarMockSqlClient({ notificacaoExpirada: false }),
  });

  assertEquals(res.status, 200);
  assert(consultouOcorrencia, "o motivo do cancelamento é lido do banco no envio");
  assertEquals(enviado.title, "Turno cancelado por atraso");
  assertEquals(enviado.body, "O contratante reabriu a vaga por falta de check-in. O turno foi cancelado.");
});

Deno.test("Lembretes 24h e 3h: interpolação Opção A homologada (k5R4tzjC)", async () => {
  const sa = await gerarContaDeServicoTeste();

  const notificacaoLembrete = {
    id: "e4000000-0000-4000-8000-000000000001",
    usuario_id: "a3000000-0000-4000-8000-000000000001",
    tipo: "lembrete_24h",
    referencia_id: "f4000000-0000-4000-8000-000000000001",
    payload: { turno_id: "f4000000-0000-4000-8000-000000000001" },
    tentativas: 0,
    estado_entrega: "pendente",
  };

  // deno-lint-ignore no-explicit-any
  let fcmEnviado: any = null;

  const mockFetch: typeof fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input.toString();

    if (url === "http://mock-oauth/token") {
      return Promise.resolve(new Response(JSON.stringify({ access_token: "token-123" }), { status: 200 }));
    }
    if (url.includes("/rest/v1/notificacao")) {
      return Promise.resolve(new Response(JSON.stringify([notificacaoLembrete]), { status: 200 }));
    }
    if (url.includes("/rest/v1/dispositivo")) {
      return Promise.resolve(new Response(JSON.stringify([{ id: "disp-1", token_fcm: "fcm-tok-1", plataforma: "ios" }]), { status: 200 }));
    }
    if (url.includes("/messages:send")) {
      fcmEnviado = JSON.parse(init?.body as string);
      return Promise.resolve(new Response(JSON.stringify({ name: "msg-123" }), { status: 200 }));
    }

    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "x-agendador-secret": SEGREDO_TESTE,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({}),
  });

  const res = await processarEnvioPush(req, {
    agendadorSecret: SEGREDO_TESTE,
    serviceAccount: sa,
    fetchFn: mockFetch,
    fcmApiUrl: "http://mock-fcm/messages:send",
    sqlClient: criarMockSqlClient({
      notificacaoExpirada: false,
      obterConteudoPushLembrete: () => Promise.resolve({
        title: "Lembrete de turno amanhã",
        body: "Garçom em Bar Beirute amanhã às 11:00.",
      }),
    }),
  });

  assertEquals(res.status, 200);
  if (!fcmEnviado) {
    throw new Error("fcmEnviado não deveria ser nulo");
  }
  assertEquals(fcmEnviado.message.notification.title, "Lembrete de turno amanhã");
  assertEquals(fcmEnviado.message.notification.body, "Garçom em Bar Beirute amanhã às 11:00.");
});

Deno.test("Lembretes 24h e 3h: caminho de reserva (Opção B) para profissional e contratante", () => {
  // Profissional: usa textos direcionados à pessoa do profissional (Opção B da proposta-textos.md)
  const p24 = titulosECorposPorTipo("lembrete_24h", { turno_id: "f4000000-0000-4000-8000-000000000001" });
  assertEquals(p24.title, "Lembrete de turno amanhã");
  assertEquals(p24.body, "Você tem um turno confirmado para amanhã. Confira os detalhes.");

  const p3 = titulosECorposPorTipo("lembrete_3h", { turno_id: "f4000000-0000-4000-8000-000000000001" });
  assertEquals(p3.title, "Seu turno começa em 3 horas");
  assertEquals(p3.body, "Seu turno começa em 3 horas. Toque para ver endereço e contato.");

  // Contratante: usa textos direcionados à casa/painel (Opção B da proposta-textos.md), sem dizer "Seu turno"
  const c24 = titulosECorposPorTipo("lembrete_24h", {
    turno_id: "f4000000-0000-4000-8000-000000000001",
    estabelecimento_id: "e4000000-0000-4000-8000-000000000001",
  });
  assertEquals(c24.title, "Turno agendado para amanhã");
  assertEquals(c24.body, "Você tem turno confirmado para amanhã. Confira no painel.");

  const c3 = titulosECorposPorTipo("lembrete_3h", {
    turno_id: "f4000000-0000-4000-8000-000000000001",
    estabelecimento_id: "e4000000-0000-4000-8000-000000000001",
  });
  assertEquals(c3.title, "Turno em 3 horas");
  assertEquals(c3.body, "Turno confirmado começa em 3 horas. Acompanhe pelo app.");
});

Deno.test("Lembretes 24h e 3h: envio com fallback para contratante usa textos da casa (Opção B)", async () => {
  const sa = await gerarContaDeServicoTeste();

  const notificacaoLembreteContratante = {
    id: "e4000000-0000-4000-8000-000000000002",
    usuario_id: "a3000000-0000-4000-8000-000000000002",
    tipo: "lembrete_3h",
    referencia_id: "f4000000-0000-4000-8000-000000000001",
    payload: {
      turno_id: "f4000000-0000-4000-8000-000000000001",
      estabelecimento_id: "e4000000-0000-4000-8000-000000000001",
    },
    tentativas: 0,
    estado_entrega: "pendente",
  };

  // deno-lint-ignore no-explicit-any
  let fcmEnviado: any = null;

  const mockFetch: typeof fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input.toString();

    if (url === "http://mock-oauth/token") {
      return Promise.resolve(new Response(JSON.stringify({ access_token: "token-123" }), { status: 200 }));
    }
    if (url.includes("/rest/v1/notificacao")) {
      return Promise.resolve(new Response(JSON.stringify([notificacaoLembreteContratante]), { status: 200 }));
    }
    if (url.includes("/rest/v1/dispositivo")) {
      return Promise.resolve(new Response(JSON.stringify([{ id: "disp-2", token_fcm: "fcm-tok-2", plataforma: "ios" }]), { status: 200 }));
    }
    if (url.includes("/messages:send")) {
      fcmEnviado = JSON.parse(init?.body as string);
      return Promise.resolve(new Response(JSON.stringify({ name: "msg-456" }), { status: 200 }));
    }

    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "x-agendador-secret": SEGREDO_TESTE,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({}),
  });

  const res = await processarEnvioPush(req, {
    agendadorSecret: SEGREDO_TESTE,
    serviceAccount: sa,
    fetchFn: mockFetch,
    fcmApiUrl: "http://mock-fcm/messages:send",
    sqlClient: criarMockSqlClient({
      notificacaoExpirada: false,
      obterConteudoPushLembrete: () => Promise.resolve(null),
    }),
  });

  assertEquals(res.status, 200);
  if (!fcmEnviado) {
    throw new Error("fcmEnviado não deveria ser nulo");
  }
  // Garante que contratante recebe "Turno em 3 horas" e NÃO "Seu turno começa em 3 horas"
  assertEquals(fcmEnviado.message.notification.title, "Turno em 3 horas");
  assertEquals(fcmEnviado.message.notification.body, "Turno confirmado começa em 3 horas. Acompanhe pelo app.");
});

// ── Ciclo de vida do token (cartão wpNabtCO) ──────────────────────────────────
//
// A tabela `dispositivo` simulada em memória é o estado que o banco deixa depois de
// cada passo, provado no pgTAP 300: na troca de conta o token passa para B, e na saída
// `remover_dispositivo` apaga a linha. Aqui se prova o outro lado — que a Edge Function
// só manda para os aparelhos da conta destinatária, lidos por `usuario_id`.

const CONTA_A = "a3000000-0000-4000-8000-000000000001";
const CONTA_B = "b3000000-0000-4000-8000-000000000002";
const TOKEN_COMPARTILHADO = "fcm_token_aparelho_compartilhado_0001";

function mockCicloDoToken(
  dispositivos: Array<{ usuario_id: string; token_fcm: string }>,
  notificacoes: Record<string, string>,
  enviados: string[],
): typeof fetch {
  return (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input.toString();
    const json = (corpo: unknown) =>
      Promise.resolve(
        new Response(JSON.stringify(corpo), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      );

    if (url === "http://mock-oauth/token") {
      return json({ access_token: "token-oauth-ok", token_type: "Bearer", expires_in: 3600 });
    }

    const notif = url.match(/\/rest\/v1\/notificacao\?id=eq\.([^&]+)/);
    if (notif) {
      return json([
        {
          id: notif[1],
          usuario_id: notificacoes[notif[1]],
          tipo: "vaga",
          referencia_id: "v3000000-0000-4000-8000-000000000001",
          payload: {},
          tentativas: 0,
          estado_entrega: "pendente",
          proxima_tentativa_em: null,
        },
      ]);
    }

    const disp = url.match(/\/rest\/v1\/dispositivo\?usuario_id=eq\.([^&]+)/);
    if (disp) {
      return json(
        dispositivos
          .filter((d) => d.usuario_id === disp[1])
          .map((d, i) => ({ id: `d${i}`, token_fcm: d.token_fcm, plataforma: "ios" })),
      );
    }

    if (url.includes("/messages:send") && init?.body) {
      const corpo = JSON.parse(init.body as string);
      enviados.push(corpo.message.token);
      return json({ name: "projects/frila-test-project/messages/msg_ciclo" });
    }

    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };
}

async function enviarNotificacao(
  notificacaoId: string,
  fetchFn: typeof fetch,
  sqlClient?: SqlClient,
): Promise<{ status: string; detalhe?: string }> {
  const sa = await gerarContaDeServicoTeste();
  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-agendador-secret": SEGREDO_TESTE },
    body: JSON.stringify({ notificacao_id: notificacaoId }),
  });
  const res = await processarEnvioPush(req, {
    serviceAccount: sa,
    fetchFn,
    fcmApiUrl: "http://mock-fcm/messages:send",
    sqlClient: sqlClient ?? criarMockSqlClient(),
  });
  assertEquals(res.status, 200);
  return (await res.json()).relatorio[0];
}

Deno.test("Ciclo do token: depois da troca de conta, só a conta B recebe push no aparelho", async () => {
  // Estado depois de A e em seguida B registrarem o mesmo token (troca de dono).
  const dispositivos = [{ usuario_id: CONTA_B, token_fcm: TOKEN_COMPARTILHADO }];
  const notificacoes = {
    "a3000000-0000-4000-8000-00000000000a": CONTA_A,
    "a3000000-0000-4000-8000-00000000000b": CONTA_B,
  };
  const enviados: string[] = [];
  const fetchFn = mockCicloDoToken(dispositivos, notificacoes, enviados);

  const paraA = await enviarNotificacao("a3000000-0000-4000-8000-00000000000a", fetchFn);
  assertEquals(paraA.status, "falhou");
  assertEquals(paraA.detalhe, "sem_dispositivo");
  assertEquals(enviados, [], "O push da conta A não pode sair para o aparelho que passou para B");

  const paraB = await enviarNotificacao("a3000000-0000-4000-8000-00000000000b", fetchFn);
  assertEquals(paraB.status, "enviada");
  assertEquals(enviados, [TOKEN_COMPARTILHADO]);
});

Deno.test("Ciclo do token: depois de sair da conta, nenhuma notificação sai para o aparelho", async () => {
  // Estado depois de remover_dispositivo: a linha do aparelho não existe mais.
  const dispositivos: Array<{ usuario_id: string; token_fcm: string }> = [];
  const notificacoes = { "a3000000-0000-4000-8000-00000000000c": CONTA_B };
  const enviados: string[] = [];

  const relatorio = await enviarNotificacao(
    "a3000000-0000-4000-8000-00000000000c",
    mockCicloDoToken(dispositivos, notificacoes, enviados),
  );

  assertEquals(relatorio.status, "falhou");
  assertEquals(relatorio.detalhe, "sem_dispositivo");
  assertEquals(enviados, [], "Aparelho que saiu da conta não recebe push");
});

// ── Textos de vaga e teto da RN23 (cartão ee3MT3fH) ───────────────────────────
//
// Os textos saem da planilha de notificações do design (proposta aprovada em 28/09):
// vaga única, urgente e reaberta na Opção B (o banco ainda não tem a região), e a
// agrupada na Opção A, com a quantidade interpolada no envio.

Deno.test("RN23: textos de vaga seguem a planilha (casos 01, 02 e 04)", () => {
  assertEquals(titulosECorposPorTipo("vaga", { vaga_id: "x" }), {
    title: "Nova vaga no Frila",
    body: "Nova vaga compatível com seu perfil. Toque para ver detalhes.",
  });
  assertEquals(titulosECorposPorTipo("vaga", {}, { urgente: true }), {
    title: "Vaga urgente no Frila",
    body: "Vaga com início nas próximas 2 horas. Confira agora.",
  });
  assertEquals(titulosECorposPorTipo("vaga", { reaberta: true }, { urgente: true }), {
    title: "Vaga reaberta",
    body: "Uma vaga recente está aberta novamente para candidatura.",
  });
});

Deno.test("RN23: a agrupada interpola a quantidade (caso 03) e cai na Opção B sem ela", () => {
  assertEquals(titulosECorposPorTipo("vagas_agrupadas", {}, { quantidade: 3 }), {
    title: "Vagas disponíveis",
    body: "3 vagas novas perto de você. Toque para conferir.",
  });
  assertEquals(titulosECorposPorTipo("vagas_agrupadas", {}, {}), {
    title: "Vagas disponíveis",
    body: "Novas vagas compatíveis perto de você. Toque para conferir.",
  });
  assertEquals(
    titulosECorposPorTipo("vagas_agrupadas", {}, { quantidade: 1 }).body,
    "Novas vagas compatíveis perto de você. Toque para conferir.",
  );
});

Deno.test("RN23: títulos e corpos de vaga cabem na tela bloqueada do iPhone SE", () => {
  const casos = [
    titulosECorposPorTipo("vaga", {}),
    titulosECorposPorTipo("vaga", {}, { urgente: true }),
    titulosECorposPorTipo("vaga", { reaberta: true }),
    titulosECorposPorTipo("vagas_agrupadas", {}, { quantidade: 200 }),
    titulosECorposPorTipo("vagas_agrupadas", {}, {}),
  ];
  for (const { title, body } of casos) {
    assert(title.length <= 32, `título longo: ${title}`);
    assert(body.length <= 85, `corpo longo: ${body}`);
  }
});

Deno.test("RN23: o envio da agrupada lê a contagem e usa no corpo do push", async () => {
  const corpos: string[] = [];
  const chamadas: string[] = [];
  const sa = await gerarContaDeServicoTeste();
  const mockFetch: typeof fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input.toString();
    const json = (corpo: unknown) =>
      Promise.resolve(
        new Response(JSON.stringify(corpo), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      );
    if (url.includes("oauth2") || url.includes("/token")) {
      return json({ access_token: "tok", expires_in: 3600, token_type: "Bearer" });
    }
    if (url.includes("/rest/v1/notificacao?")) {
      assert(url.includes("urgente"), "a leitura da fila traz a coluna urgente");
      return json([{
        id: "a3300000-0000-4000-8000-000000000001",
        usuario_id: "a3300000-0000-4000-8000-000000000002",
        tipo: "vagas_agrupadas",
        referencia_id: "a3300000-0000-4000-8000-000000000003",
        payload: { tipo: "vagas_agrupadas" },
        tentativas: 0,
        estado_entrega: "pendente",
        proxima_tentativa_em: null,
        urgente: false,
      }]);
    }
    if (url.includes("/rest/v1/dispositivo?usuario_id=eq.")) {
      return json([{ id: "d1", token_fcm: "fcm_token_agrupada_000000001", plataforma: "ios" }]);
    }
    if (url.includes("/messages:send")) {
      const msg = JSON.parse(String(init?.body ?? "{}"));
      corpos.push(msg?.message?.notification?.body ?? "");
      return json({ name: "projects/p/messages/1" });
    }
    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const sqlClient = criarMockSqlClient({
    contextoDoPush: () => {
      chamadas.push("contexto_do_push");
      return { quantidade: 4 };
    },
  });

  const res = await processarEnvioPush(
    new Request("http://localhost/functions/v1/enviar-push", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-agendador-secret": SEGREDO_TESTE },
      body: JSON.stringify({}),
    }),
    {
      supabaseUrl: "http://mock-db",
      serviceRoleKey: "srk",
      agendadorSecret: SEGREDO_TESTE,
      serviceAccount: sa,
      fetchFn: mockFetch,
      fcmApiUrl: "http://mock-fcm/messages:send",
      sqlClient,
    },
  );

  assertEquals(res.status, 200);
  assertEquals(chamadas, ["contexto_do_push"]);
  assertEquals(corpos, ["4 vagas novas perto de você. Toque para conferir."]);
});

// ── Alerta de vaga vazia na janela crítica (cartão vUR0Ltkb) ──────────────────
//
// Texto da planilha de notificações, push 06, Op. A aprovada em 28/09: a função e o
// horário são lidos no banco na hora do envio. Sem as duas variáveis, sai a Op. B da
// mesma planilha — nunca um texto inventado aqui.

Deno.test("vaga_vazia: Op. A com função e horário interpolados", () => {
  const { title, body } = titulosECorposPorTipo("vaga_vazia", {}, {
    funcao: "Garçom",
    horario: "18:00",
  });
  assertEquals(title, "Vaga ainda em aberto");
  assertEquals(body, "A posição de Garçom das 18:00 ainda não foi preenchida.");
  assert(title.length <= 32, "título cabe na tela bloqueada do iPhone SE");
  assert(body.length <= 85, "corpo cabe na tela bloqueada do iPhone SE");
});

Deno.test("vaga_vazia: sem as variáveis, cai na Op. B da planilha", () => {
  const { title, body } = titulosECorposPorTipo("vaga_vazia", {});
  assertEquals(title, "Vaga ainda em aberto");
  assertEquals(body, "Sua vaga ainda possui posição em aberto próxima ao horário.");
});

Deno.test("formatarHorario: horário de Brasília, 24 h", () => {
  assertEquals(formatarHorario("2026-10-03T21:00:00+00:00"), "18:00");
  assertEquals(formatarHorario("2026-10-03T22:30:00Z"), "19:30");
  assertEquals(formatarHorario("não é data"), undefined);
});

Deno.test("vaga_vazia: a enviar-push lê função e horário da posição e manda a Op. A", async () => {
  const sa = await gerarContaDeServicoTeste();
  const POSICAO = "c3400000-0000-4000-8000-000000000041";
  const VAGA = "c3400000-0000-4000-8000-000000000031";
  const enviado: { mensagem?: { notification: { title: string; body: string }; data: Record<string, string> } } = {};
  let consultaPosicao = "";

  const mockFetch: typeof fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input.toString();

    if (url === "http://mock-oauth/token") {
      return Promise.resolve(new Response(
        JSON.stringify({ access_token: "token-oauth-ok", token_type: "Bearer", expires_in: 3600 }),
        { status: 200, headers: { "Content-Type": "application/json" } }));
    }
    if (url.includes("/rest/v1/notificacao?id=eq.")) {
      return Promise.resolve(new Response(JSON.stringify([{
        id: "c3400000-0000-4000-8000-0000000000a1",
        usuario_id: "c3400000-0000-4000-8000-000000000001",
        tipo: "vaga_vazia",
        referencia_id: POSICAO,
        payload: { tipo: "vaga_vazia", vaga_id: VAGA, posicao_id: POSICAO },
        tentativas: 0,
        estado_entrega: "pendente",
        proxima_tentativa_em: null,
      }]), { status: 200, headers: { "Content-Type": "application/json" } }));
    }
    if (url.includes("/rest/v1/posicao?")) {
      consultaPosicao = url;
      return Promise.resolve(new Response(JSON.stringify([{
        inicio_em: "2026-10-03T21:00:00+00:00",
        vaga: { funcao: { nome: "Garçom" } },
      }]), { status: 200, headers: { "Content-Type": "application/json" } }));
    }
    if (url.includes("/rest/v1/dispositivo?usuario_id=eq.")) {
      return Promise.resolve(new Response(
        JSON.stringify([{ id: "disp-1", token_fcm: "fcm_token_casa", plataforma: "ios" }]),
        { status: 200, headers: { "Content-Type": "application/json" } }));
    }
    if (url.includes("/messages:send")) {
      enviado.mensagem = JSON.parse(init?.body as string).message;
      return Promise.resolve(new Response(
        JSON.stringify({ name: "projects/frila-test-project/messages/msg_vv" }),
        { status: 200, headers: { "Content-Type": "application/json" } }));
    }
    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const res = await processarEnvioPush(
    new Request("http://localhost/functions/v1/enviar-push", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-agendador-secret": SEGREDO_TESTE },
      body: JSON.stringify({ notificacao_id: "c3400000-0000-4000-8000-0000000000a1" }),
    }),
    { serviceAccount: sa, fetchFn: mockFetch, fcmApiUrl: "http://mock-fcm/messages:send", sqlClient: criarMockSqlClient() },
  );

  assertEquals(res.status, 200);
  assertMatch(consultaPosicao, new RegExp(`id=eq\\.${POSICAO}`));
  assert(enviado.mensagem !== undefined, "o FCM foi chamado");
  assertEquals(enviado.mensagem!.notification.title, "Vaga ainda em aberto");
  assertEquals(enviado.mensagem!.notification.body,
    "A posição de Garçom das 18:00 ainda não foi preenchida.");
  // O destino do toque: Minhas vagas com a vaga em alerta. Só ids (RN15).
  assertEquals(enviado.mensagem!.data, { tipo: "vaga_vazia", vaga_id: VAGA, posicao_id: POSICAO });
});

Deno.test("vaga_vazia: se a leitura da posição falha, o push sai com a Op. B", async () => {
  const sa = await gerarContaDeServicoTeste();
  const enviado: { mensagem?: { notification: { title: string; body: string }; data: Record<string, string> } } = {};

  const mockFetch: typeof fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input.toString();
    if (url === "http://mock-oauth/token") {
      return Promise.resolve(new Response(
        JSON.stringify({ access_token: "token-oauth-ok", token_type: "Bearer", expires_in: 3600 }),
        { status: 200, headers: { "Content-Type": "application/json" } }));
    }
    if (url.includes("/rest/v1/notificacao?id=eq.")) {
      return Promise.resolve(new Response(JSON.stringify([{
        id: "c3400000-0000-4000-8000-0000000000a2",
        usuario_id: "c3400000-0000-4000-8000-000000000001",
        tipo: "vaga_vazia",
        referencia_id: "c3400000-0000-4000-8000-000000000041",
        payload: { vaga_id: "c3400000-0000-4000-8000-000000000031",
                   posicao_id: "c3400000-0000-4000-8000-000000000041" },
        tentativas: 0, estado_entrega: "pendente", proxima_tentativa_em: null,
      }]), { status: 200, headers: { "Content-Type": "application/json" } }));
    }
    if (url.includes("/rest/v1/posicao?")) {
      return Promise.resolve(new Response("erro", { status: 500 }));
    }
    if (url.includes("/rest/v1/dispositivo?usuario_id=eq.")) {
      return Promise.resolve(new Response(
        JSON.stringify([{ id: "disp-1", token_fcm: "fcm_token_casa", plataforma: "ios" }]),
        { status: 200, headers: { "Content-Type": "application/json" } }));
    }
    if (url.includes("/messages:send")) {
      enviado.mensagem = JSON.parse(init?.body as string).message;
      return Promise.resolve(new Response("{}", { status: 200 }));
    }
    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const res = await processarEnvioPush(
    new Request("http://localhost/functions/v1/enviar-push", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-agendador-secret": SEGREDO_TESTE },
      body: JSON.stringify({ notificacao_id: "c3400000-0000-4000-8000-0000000000a2" }),
    }),
    { serviceAccount: sa, fetchFn: mockFetch, fcmApiUrl: "http://mock-fcm/messages:send", sqlClient: criarMockSqlClient() },
  );

  assertEquals(res.status, 200);
  assertEquals(enviado.mensagem!.notification.body,
    "Sua vaga ainda possui posição em aberto próxima ao horário.");
});

// ── Testes de SqlClient e garantia contra RPCs via PostgREST (IoQPWtWs) ───────

Deno.test("SqlClient: criarSqlClient falha fechado se DATABASE_URL ou SUPABASE_DB_URL não configurados", () => {
  const dbUrlAntes = Deno.env.get("DATABASE_URL");
  const supabaseDbUrlAntes = Deno.env.get("SUPABASE_DB_URL");
  try {
    Deno.env.delete("DATABASE_URL");
    Deno.env.delete("SUPABASE_DB_URL");
    let lancou = false;
    try {
      criarSqlClient();
    } catch (err) {
      lancou = true;
      assert(err instanceof Error);
      assert(err.message.includes("DATABASE_URL ou SUPABASE_DB_URL é obrigatório"));
    }
    assert(lancou, "Deveria ter lançado erro de variável ausente");
  } finally {
    if (dbUrlAntes) Deno.env.set("DATABASE_URL", dbUrlAntes);
    if (supabaseDbUrlAntes) Deno.env.set("SUPABASE_DB_URL", supabaseDbUrlAntes);
  }
});

Deno.test("SqlClient: criarSqlClient respeita sqlClient injetado via dependências", () => {
  const mock = criarMockSqlClient();
  const res = criarSqlClient({ sqlClient: mock });
  assertEquals(res, mock);
});

Deno.test("Segurança / PostgREST: nenhuma RPC de privado.* é chamada via PostgREST /rest/v1/rpc/", async () => {
  const sa = await gerarContaDeServicoTeste();
  const chamadasPostgrestRpc: string[] = [];
  const sqlClient = criarMockSqlClient();

  const mockFetch: typeof fetch = (input: RequestInfo | URL) => {
    const url = input.toString();

    if (url.includes("/rest/v1/rpc/")) {
      chamadasPostgrestRpc.push(url);
      return Promise.resolve(new Response(JSON.stringify({ message: "Not Found" }), { status: 404 }));
    }

    if (url === "http://mock-oauth/token") {
      return Promise.resolve(
        new Response(
          JSON.stringify({ access_token: "token-oauth-ok", token_type: "Bearer", expires_in: 3600 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/notificacao?id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              id: "a5000000-0000-4000-8000-000000000005",
              usuario_id: "u5000000-0000-4000-8000-000000000005",
              tipo: "vaga",
              referencia_id: "v5000000-0000-4000-8000-000000000005",
              payload: {},
              tentativas: 0,
              estado_entrega: "pendente",
              proxima_tentativa_em: null,
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/dispositivo?usuario_id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            { id: "d5", token_fcm: "fcm_token_5", plataforma: "android" },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/messages:send")) {
      return Promise.resolve(new Response("{}", { status: 200 }));
    }

    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ notificacao_id: "a5000000-0000-4000-8000-000000000005" }),
  });

  const res = await processarEnvioPush(req, {
    serviceAccount: sa,
    fetchFn: mockFetch,
    sqlClient,
  });

  assertEquals(res.status, 200);
  assertEquals(chamadasPostgrestRpc.length, 0, "Nenhuma RPC deve ser invocada via PostgREST /rest/v1/rpc/");
});

// ── Região Administrativa e Interpolação nos Pushes (cartão x0jkygj0) ─────────
//
// Pushes 01, 02 e 04 interpolam {funcao} e {bairro_ou_regiao} (Opção A aprovada).
// Pushes 09 e 11 interpolam local como {estabelecimento} ({regiao}) (decisão VyY2SGsX).
// Garantia de privacidade RN10 e RN15: sem telefone nem logradouro com número.

Deno.test("x0jkygj0: capitalizar primeira letra da função", () => {
  assertEquals(capitalizar("garçom"), "Garçom");
  assertEquals(capitalizar("auxiliar de cozinha"), "Auxiliar de cozinha");
  assertEquals(capitalizar(""), "");
});

Deno.test("x0jkygj0: push 01 (vaga única) interpola função e região (Opção A) e cai na Opção B se ausentes", () => {
  const comVars = titulosECorposPorTipo("vaga", { vaga_id: "00000000-0000-4000-8000-000000000001" }, {
    funcao: "garçom",
    regiao: "Plano Piloto",
  });
  assertEquals(comVars, {
    title: "Nova vaga no Frila",
    body: "Garçom em Plano Piloto. Toque para ver detalhes.",
  });
  assert(comVars.title.length <= 32, "título cabe na tela bloqueada do iPhone SE");
  assert(comVars.body.length <= 85, "corpo cabe na tela bloqueada do iPhone SE");

  const semVars = titulosECorposPorTipo("vaga", { vaga_id: "00000000-0000-4000-8000-000000000001" });
  assertEquals(semVars, {
    title: "Nova vaga no Frila",
    body: "Nova vaga compatível com seu perfil. Toque para ver detalhes.",
  });
});

Deno.test("x0jkygj0: push 02 (vaga urgente) interpola função e região (Opção A) e cai na Opção B se ausentes", () => {
  const comVars = titulosECorposPorTipo("vaga", { urgente: true }, {
    funcao: "cozinheiro",
    regiao: "Taguatinga",
  });
  assertEquals(comVars, {
    title: "Vaga urgente no Frila",
    body: "Cozinheiro com início próximo em Taguatinga. Confira agora.",
  });
  assert(comVars.title.length <= 32, "título cabe na tela bloqueada do iPhone SE");
  assert(comVars.body.length <= 85, "corpo cabe na tela bloqueada do iPhone SE");

  const semVars = titulosECorposPorTipo("vaga", { urgente: true });
  assertEquals(semVars, {
    title: "Vaga urgente no Frila",
    body: "Vaga com início nas próximas 2 horas. Confira agora.",
  });
});

Deno.test("x0jkygj0: push 04 (vaga reaberta) interpola função e região (Opção A) e cai na Opção B se ausentes", () => {
  const comVars = titulosECorposPorTipo("vaga", { reaberta: true }, {
    funcao: "bartender",
    regiao: "Águas Claras",
  });
  assertEquals(comVars, {
    title: "Vaga reaberta",
    body: "Bartender disponível novamente em Águas Claras.",
  });
  assert(comVars.title.length <= 32, "título cabe na tela bloqueada do iPhone SE");
  assert(comVars.body.length <= 85, "corpo cabe na tela bloqueada do iPhone SE");

  const semVars = titulosECorposPorTipo("vaga", { reaberta: true });
  assertEquals(semVars, {
    title: "Vaga reaberta",
    body: "Uma vaga recente está aberta novamente para candidatura.",
  });
});

Deno.test("x0jkygj0: pushes 09 e 11 interpolam local como {estabelecimento} ({regiao})", () => {
  const p09 = titulosECorposPorTipo("lembrete_24h", {}, {
    funcao: "garçom",
    estabelecimento: "Bar Beirute",
    regiao: "Asa Sul",
    horario: "19:00",
  });
  assertEquals(p09, {
    title: "Lembrete de turno amanhã",
    body: "Garçom em Bar Beirute (Asa Sul) amanhã às 19:00.",
  });
  assert(p09.title.length <= 32, "título cabe na tela bloqueada do iPhone SE");
  assert(p09.body.length <= 85, "corpo cabe na tela bloqueada do iPhone SE");

  const p11 = titulosECorposPorTipo("lembrete_3h", {}, {
    funcao: "garçom",
    estabelecimento: "Bar Beirute",
    regiao: "Asa Sul",
    horario: "19:00",
  });
  assertEquals(p11, {
    title: "Seu turno começa em 3 horas",
    body: "Garçom em Bar Beirute (Asa Sul) às 19:00. Planeje seu trajeto.",
  });
  assert(p11.title.length <= 32, "título cabe na tela bloqueada do iPhone SE");
  assert(p11.body.length <= 85, "corpo cabe na tela bloqueada do iPhone SE");

  // Fallback quando não há região: usa apenas {estabelecimento}
  const p09SemRegiao = titulosECorposPorTipo("lembrete_24h", {}, {
    funcao: "garçom",
    estabelecimento: "Bar Beirute",
    horario: "19:00",
  });
  assertEquals(p09SemRegiao, {
    title: "Lembrete de turno amanhã",
    body: "Garçom em Bar Beirute amanhã às 19:00.",
  });

  const p11SemRegiao = titulosECorposPorTipo("lembrete_3h", {}, {
    funcao: "garçom",
    estabelecimento: "Bar Beirute",
    horario: "19:00",
  });
  assertEquals(p11SemRegiao, {
    title: "Seu turno começa em 3 horas",
    body: "Garçom em Bar Beirute às 19:00. Planeje seu trajeto.",
  });
});

Deno.test("x0jkygj0: buscarVariaveisDoTexto lê função e região para vaga", async () => {
  const mockFetch = (caminho: string): Promise<Response> => {
    if (caminho.startsWith("vaga?id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              regiao_administrativa: "Plano Piloto",
              funcao: { nome: "garçom" },
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }
    return Promise.reject(new Error(`URL não tratada: ${caminho}`));
  };

  const vars = await buscarVariaveisDoTexto(
    "vaga",
    { vaga_id: "00000000-0000-4000-8000-000000000001", urgente: true },
    mockFetch,
  );
  assertEquals(vars.funcao, "garçom");
  assertEquals(vars.regiao, "Plano Piloto");
  assertEquals(vars.urgente, true);
});

Deno.test("x0jkygj0: buscarVariaveisDoTexto lê turno, estabelecimento e região para lembrete", async () => {
  const mockFetch = (caminho: string): Promise<Response> => {
    if (caminho.startsWith("turno?id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              posicao: {
                inicio_em: "2026-10-15T22:00:00Z", // 19:00 em Brasília
                vaga: {
                  regiao_administrativa: "Asa Sul",
                  funcao: { nome: "garçom" },
                  estabelecimento: { nome: "Bar Beirute" },
                },
              },
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }
    return Promise.reject(new Error(`URL não tratada: ${caminho}`));
  };

  const vars = await buscarVariaveisDoTexto(
    "lembrete_24h",
    { turno_id: "00000000-0000-4000-8000-000000000002" },
    mockFetch,
  );
  assertEquals(vars.funcao, "garçom");
  assertEquals(vars.estabelecimento, "Bar Beirute");
  assertEquals(vars.regiao, "Asa Sul");
  assertEquals(vars.horario, "19:00");
});

Deno.test("x0jkygj0: processarEnvioPush envia lembrete com {estabelecimento} ({regiao}) sem ser sobrescrito", async () => {
  const sa = await gerarContaDeServicoTeste();
  const notificacaoLembrete = {
    id: "e0000000-0000-4000-8000-000000000099",
    usuario_id: "a3000000-0000-4000-8000-000000000001",
    tipo: "lembrete_24h",
    referencia_id: "f4000000-0000-4000-8000-000000000001",
    payload: { turno_id: "f4000000-0000-4000-8000-000000000001" },
    tentativas: 0,
    estado_entrega: "pendente",
  };

  // deno-lint-ignore no-explicit-any
  let fcmEnviado: any = null;

  const mockFetch: typeof fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input.toString();

    if (url === "http://mock-oauth/token") {
      return Promise.resolve(new Response(JSON.stringify({ access_token: "token-123" }), { status: 200 }));
    }
    if (url.includes("/rest/v1/notificacao")) {
      return Promise.resolve(new Response(JSON.stringify([notificacaoLembrete]), { status: 200 }));
    }
    if (url.includes("/rest/v1/dispositivo")) {
      return Promise.resolve(new Response(JSON.stringify([{ id: "disp-1", token_fcm: "fcm-tok-1", plataforma: "ios" }]), { status: 200 }));
    }
    if (url.includes("/rest/v1/turno?id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              posicao: {
                inicio_em: "2026-10-15T22:00:00Z", // 19:00 em Brasília
                vaga: {
                  regiao_administrativa: "Asa Sul",
                  funcao: { nome: "garçom" },
                  estabelecimento: { nome: "Bar Beirute" },
                },
              },
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }
    if (url.includes("/messages:send")) {
      fcmEnviado = JSON.parse(init?.body as string);
      return Promise.resolve(new Response(JSON.stringify({ name: "msg-123" }), { status: 200 }));
    }

    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };

  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "x-agendador-secret": SEGREDO_TESTE,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({}),
  });

  const res = await processarEnvioPush(req, {
    agendadorSecret: SEGREDO_TESTE,
    serviceAccount: sa,
    fetchFn: mockFetch,
    fcmApiUrl: "http://mock-fcm/messages:send",
    sqlClient: criarMockSqlClient({
      notificacaoExpirada: false,
      obterConteudoPushLembrete: () => Promise.resolve({
        title: "Lembrete desatualizado",
        body: "Garçom em Bar Beirute amanhã às 19:00.", // sem região
      }),
    }),
  });

  assertEquals(res.status, 200);
  if (!fcmEnviado) {
    throw new Error("fcmEnviado não deveria ser nulo");
  }
  assertEquals(fcmEnviado.message.notification.title, "Lembrete de turno amanhã");
  assertEquals(fcmEnviado.message.notification.body, "Garçom em Bar Beirute (Asa Sul) amanhã às 19:00.");
});



// ── Fim sem check-out (cartão qcVimM84) ───────────────────────────────────────
//
// O tipo já existia no `tipo_notificacao` e o texto já estava aqui; o que faltava era
// quem cria a notificação, e isso entrou em `privado.alertar_fim_sem_checkout`. Estes
// dois testes fixam o outro lado do cartão: o texto, e o que ele não pode dizer.

Deno.test("qcVimM84: o texto de fim_sem_checkout pede o check-out, e nada mais", () => {
  assertEquals(titulosECorposPorTipo("fim_sem_checkout", {}), {
    title: "Check-out pendente",
    body: "O horário previsto do turno encerrou. Registre o check-out.",
  });
});

Deno.test("qcVimM84 3: nenhum texto de push fala em hora extra nem sugere cálculo", () => {
  // O critério 3 é sobre tela, e a tela é iOS. O que o backend pode garantir é que ele
  // nunca manda o número nem a palavra: o app registra, não calcula.
  const tipos = [
    "vaga",
    "vagas_agrupadas",
    "confirmacao",
    "lembrete_24h",
    "lembrete_3h",
    "inicio_sem_checkin",
    "atraso_15min",
    "fim_sem_checkout",
    "vaga_vazia",
    "checkin",
    "checkin_manual_pendente",
    "cancelamento",
    "avaliacao_disponivel",
  ];

  const proibido = /(hora|horas)\s+extra|extra\s*s?\b.*\bhora|adicional noturno/i;
  for (const tipo of tipos) {
    const { title, body } = titulosECorposPorTipo(tipo, {});
    assert(!proibido.test(title), `o título de ${tipo} fala em hora extra`);
    assert(!proibido.test(body), `o corpo de ${tipo} fala em hora extra`);
    // Nem número de minutos ou horas: o texto não carrega duração nenhuma.
    assert(
      !/\b\d+\s*(min|minutos?|h|horas?)\b/i.test(body) || tipo.startsWith("lembrete") ||
        tipo === "atraso_15min" || tipo === "lembrete_3h",
      `o corpo de ${tipo} carrega uma duração`,
    );
  }
});

// Cartão BsXIZHOw: textos de suspensão e reativação sem motivo no push (RN15)
Deno.test("BsXIZHOw: textos de suspensao e reativacao cabem no iPhone SE e nao trazem o motivo", () => {
  const susp = titulosECorposPorTipo("suspensao", { motivo: "Fraude grave confirmada" });
  assertEquals(susp, {
    title: "Aviso sobre sua conta",
    body: "Sua conta foi suspensa. Abra o aplicativo para mais detalhes.",
  });
  assert(susp.title.length <= 32, "título de suspensao cabe na tela bloqueada do iPhone SE");
  assert(susp.body.length <= 85, "corpo de suspensao cabe na tela bloqueada do iPhone SE");
  assert(!susp.body.includes("Fraude"), "o motivo da suspensão não vai no corpo do push");

  const reat = titulosECorposPorTipo("reativacao", { motivo: "Contestação aceita" });
  assertEquals(reat, {
    title: "Conta reativada",
    body: "Sua conta foi reativada e está pronta para uso.",
  });
  assert(reat.title.length <= 32, "título de reativacao cabe na tela bloqueada do iPhone SE");
  assert(reat.body.length <= 85, "corpo de reativacao cabe na tela bloqueada do iPhone SE");
  assert(!reat.body.includes("Contestação"), "o motivo da reativação não vai no corpo do push");
});

// Hardening de Produção (cartão kT7NhMGV): B7, B5, B4, B3
Deno.test("kT7NhMGV / B7: processarEnvioPush recusa notificacao_id invalido com 422 campo_invalido", async () => {
  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ notificacao_id: "invalido-not-uuid" }),
  });

  const res = await processarEnvioPush(req, {
    agendadorSecret: SEGREDO_TESTE,
  });

  assertEquals(res.status, 422);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.erro, "campo_invalido");
  assertEquals(json.campo, "notificacao_id");
});

Deno.test("kT7NhMGV / B5: carregarContaDeServico com JSON malformado nao lanca erro e retorna null", () => {
  const fcmAntigo = Deno.env.get("FCM_SERVICE_ACCOUNT");
  try {
    Deno.env.set("FCM_SERVICE_ACCOUNT", "conteudo-invalido-que-nao-e-json{");
    const sa = carregarContaDeServico();
    assertEquals(sa, null);
  } finally {
    if (fcmAntigo !== undefined) {
      Deno.env.set("FCM_SERVICE_ACCOUNT", fcmAntigo);
    } else {
      Deno.env.delete("FCM_SERVICE_ACCOUNT");
    }
  }
});

Deno.test("kT7NhMGV / B4: falha de autenticacao OAuth Google responde 500 sem detalhe interno", async () => {
  const sa: FcmServiceAccount = {
    client_email: "test@example.com",
    private_key: "-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC...\n-----END PRIVATE KEY-----",
    project_id: "test-proj",
  };

  const mockFetch: typeof fetch = (input: RequestInfo | URL) => {
    const url = input.toString();
    if (url.includes("/rest/v1/notificacao")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              id: "b1000000-0000-4000-8000-000000000001",
              usuario_id: "u1000000-0000-4000-8000-000000000001",
              tipo: "vaga",
              referencia_id: "v1000000-0000-4000-8000-000000000001",
              payload: {},
              tentativas: 0,
              estado_entrega: "pendente",
              proxima_tentativa_em: null,
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }
    // Falha o OAuth
    return Promise.reject(new Error("Falha de rede interna simulada com stack sensível"));
  };

  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({ notificacao_id: "b1000000-0000-4000-8000-000000000001" }),
  });

  const res = await processarEnvioPush(req, {
    serviceAccount: sa,
    fetchFn: mockFetch,
    sqlClient: criarMockSqlClient(),
    agendadorSecret: SEGREDO_TESTE,
  });

  assertEquals(res.status, 500);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(json.erro, "falha_oauth_google");
  assertEquals(json.detalhe, undefined, "detalhe interno com stack não deve ser exposto no payload");
});

Deno.test("kT7NhMGV / B3: processarEnvioPush exige SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY", async () => {
  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-agendador-secret": SEGREDO_TESTE,
    },
    body: JSON.stringify({}),
  });

  const urlAntiga = Deno.env.get("SUPABASE_URL");
  const keyAntiga = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  try {
    Deno.env.delete("SUPABASE_URL");
    Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");

    await assertRejects(
      async () => {
        await processarEnvioPush(req, { supabaseUrl: "", serviceRoleKey: "key-ok" });
      },
      Error,
      "SUPABASE_URL é obrigatório",
    );

    await assertRejects(
      async () => {
        await processarEnvioPush(req, { supabaseUrl: "http://localhost:54321", serviceRoleKey: "" });
      },
      Error,
      "SUPABASE_SERVICE_ROLE_KEY é obrigatório",
    );
  } finally {
    if (urlAntiga !== undefined) Deno.env.set("SUPABASE_URL", urlAntiga);
    if (keyAntiga !== undefined) Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", keyAntiga);
  }
});

Deno.test("Contrato 0.2.30 (FmgMnRx4): FCM message.data inclui vinculo_id do aparelho correspondente", async () => {
  const sa = await gerarContaDeServicoTeste();
  const mensagensEnviadas: Array<{ token: string; data?: Record<string, string> }> = [];
  const urlsDispositivoChamadas: string[] = [];

  const mockFetch: typeof fetch = (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();

    if (url.includes("/token")) {
      return Promise.resolve(
        new Response(
          JSON.stringify({ access_token: "mock_fcm_token", expires_in: 3600, token_type: "Bearer" }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/notificacao?id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              id: "a3000000-0000-4000-8000-000000000099",
              usuario_id: "c3000000-0000-4000-8000-000000000001",
              tipo: "vaga",
              referencia_id: "d0000000-0000-4000-8000-000000000001",
              payload: {
                vaga_id: "d0000000-0000-4000-8000-000000000001",
              },
              tentativas: 0,
              estado_entrega: "pendente",
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/dispositivo?usuario_id=eq.")) {
      urlsDispositivoChamadas.push(url);
      const match = url.match(/[?&]select=([^&]+)/);
      const campos = match ? match[1].split(",") : [];
      const pede = (campo: string) => campos.includes(campo);

      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              ...(pede("id") ? { id: "disp-1" } : {}),
              ...(pede("token_fcm") ? { token_fcm: "fcm_token_iphone_1" } : {}),
              ...(pede("plataforma") ? { plataforma: "ios" } : {}),
              ...(pede("vinculo_id") ? { vinculo_id: "11111111-1111-4000-8000-000000000001" } : {}),
            },
            {
              ...(pede("id") ? { id: "disp-2" } : {}),
              ...(pede("token_fcm") ? { token_fcm: "fcm_token_ipad_2" } : {}),
              ...(pede("plataforma") ? { plataforma: "ios" } : {}),
              ...(pede("vinculo_id") ? { vinculo_id: "22222222-2222-4000-8000-000000000002" } : {}),
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/messages:send") && init?.body) {
      const parsed = JSON.parse(init.body as string);
      mensagensEnviadas.push({
        token: parsed.message.token,
        data: parsed.message.data,
      });
      return Promise.resolve(
        new Response(
          JSON.stringify({ name: `projects/frila-test/messages/msg-${mensagensEnviadas.length}` }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    return Promise.reject(new Error(`URL não tratada no mock: ${url}`));
  };

  const req = new Request("http://localhost/functions/v1/enviar-push", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-agendador-secret": SEGREDO_TESTE },
    body: JSON.stringify({ notificacao_id: "a3000000-0000-4000-8000-000000000099" }),
  });

  const res = await processarEnvioPush(req, {
    serviceAccount: sa,
    fetchFn: mockFetch,
    fcmApiUrl: "http://mock-fcm/messages:send",
    sqlClient: criarMockSqlClient(),
  });

  assertEquals(res.status, 200);
  const jsonCorpo = await res.json();
  assertEquals(jsonCorpo.relatorio[0].status, "enviada");

  assertEquals(urlsDispositivoChamadas.length, 1);
  const urlDisp = urlsDispositivoChamadas[0];
  const selectMatch = urlDisp.match(/[?&]select=([^&]+)/);
  assert(selectMatch !== null, "consulta a /rest/v1/dispositivo deve ter parâmetro select");
  const camposSelect = selectMatch[1].split(",");
  assert(
    camposSelect.includes("vinculo_id"),
    "consulta a /rest/v1/dispositivo deve exigir vinculo_id no select",
  );

  assertEquals(mensagensEnviadas.length, 2);
  assertEquals(mensagensEnviadas[0].token, "fcm_token_iphone_1");
  assertEquals(mensagensEnviadas[0].data?.vinculo_id, "11111111-1111-4000-8000-000000000001");
  assertEquals(mensagensEnviadas[0].data?.tipo, "vaga");
  assertEquals(mensagensEnviadas[0].data?.vaga_id, "d0000000-0000-4000-8000-000000000001");

  assertEquals(mensagensEnviadas[1].token, "fcm_token_ipad_2");
  assertEquals(mensagensEnviadas[1].data?.vinculo_id, "22222222-2222-4000-8000-000000000002");
  assertEquals(mensagensEnviadas[1].data?.tipo, "vaga");
  assertEquals(mensagensEnviadas[1].data?.vaga_id, "d0000000-0000-4000-8000-000000000001");
});

Deno.test("Contrato 0.2.30: vinculo_id não entra em notificacao.payload e filtrarDataPayloadFcm não aceita vinculo_id do payload", () => {
  const payloadComVinculo = {
    vaga_id: "d0000000-0000-4000-8000-000000000001",
    vinculo_id: "33333333-3333-4000-8000-000000000003",
  };
  const filtrado = filtrarDataPayloadFcm("vaga", payloadComVinculo);
  assertEquals(filtrado.vaga_id, "d0000000-0000-4000-8000-000000000001");
  assertEquals((filtrado as Record<string, string>).vinculo_id, undefined);
});

// ── Auditoria de Privacidade (RN10, RN15, LGPD) ──────────────────────────────

Deno.test("RN15 / LGPD: nenhum título ou corpo vaza dados pessoais mesmo com variáveis interpoladas", () => {
  const todosOsTipos = [
    "vaga",
    "vagas_agrupadas",
    "confirmacao",
    "lembrete_24h",
    "lembrete_3h",
    "inicio_sem_checkin",
    "atraso_15min",
    "fim_sem_checkout",
    "vaga_vazia",
    "checkin",
    "checkin_manual_pendente",
    "cancelamento",
    "avaliacao_disponivel",
    "suspensao",
    "reativacao",
    "tipo_desconhecido_fallback",
  ];

  const variaveisCompletas: VariaveisDoTexto = {
    funcao: "bartender",
    estabelecimento: "Bar do Teste",
    regiao: "Plano Piloto",
    horario: "20:00",
    urgente: true,
    reaberta: true,
    reaberturaPorAtraso: true,
    quantidade: 4,
  };

  const regexCpf = /\b\d{3}\.\d{3}\.\d{3}-\d{2}\b/;
  const regexTelefone = /(?:\+55|\(?\d{2}\)?\s*\d{4,5}-?\d{4})/;
  const regexLogradouroNumero = /\b(rua|avenida|quadra|conjunto|lote|bloco|nº|numero)\b/i;

  for (const tipo of todosOsTipos) {
    // 1. Teste com variáveis completas
    const { title: t1, body: b1 } = titulosECorposPorTipo(
      tipo,
      { urgente: true, reaberta: true, estabelecimento_id: "c0000000-0000-4000-8000-000000000001" },
      variaveisCompletas,
    );
    assert(t1.length > 0, `Título vazio para ${tipo}`);
    assert(b1.length > 0, `Corpo vazio para ${tipo}`);
    assert(!b1.includes("@"), `Corpo contém e-mail em ${tipo}: ${b1}`);
    assert(!t1.includes("@"), `Título contém e-mail em ${tipo}: ${t1}`);
    assert(!regexTelefone.test(b1), `Corpo contém telefone em ${tipo}: ${b1}`);
    assert(!regexTelefone.test(t1), `Título contém telefone em ${tipo}: ${t1}`);
    assert(!regexCpf.test(b1), `Corpo contém CPF em ${tipo}: ${b1}`);
    assert(!regexCpf.test(t1), `Título contém CPF em ${tipo}: ${t1}`);
    assert(!regexLogradouroNumero.test(b1), `Corpo contém logradouro com número em ${tipo}: ${b1}`);

    // 2. Teste no papel profissional (sem estabelecimento_id no payload)
    const { title: t2, body: b2 } = titulosECorposPorTipo(
      tipo,
      { destinatario: "profissional" },
      variaveisCompletas,
    );
    assert(!b2.includes("@"), `Corpo contém e-mail em ${tipo} (prof)`);
    assert(!regexTelefone.test(b2), `Corpo contém telefone em ${tipo} (prof)`);
    assert(!regexCpf.test(b2), `Corpo contém CPF em ${tipo} (prof)`);
  }
});

Deno.test("RN15 / LGPD: filtrarDataPayloadFcm remove estritamente quaisquer campos pessoais injetados", () => {
  const payloadComDadosPessoais = {
    // Campos válidos
    vaga_id: "d0000000-0000-4000-8000-000000000001",
    posicao_id: "e0000000-0000-4000-8000-000000000002",
    turno_id: "f0000000-0000-4000-8000-000000000003",
    estabelecimento_id: "c0000000-0000-4000-8000-000000000004",
    reaberta: false,
    // Dados pessoais / sensíveis (proibidos pela RN15 e LGPD)
    nome: "Maria Oliveira da Silva",
    cpf: "012.345.678-90",
    rg: "1.234.567 SSP/DF",
    telefone: "+5561988887777",
    email: "maria.silva@exemplo.com",
    endereco: "SCS Quadra 2 Bloco C Sala 101",
    chave_pix: "01234567890",
    usuario_id: "a0000000-0000-4000-8000-000000000099",
    profissional_id: "b0000000-0000-4000-8000-000000000099",
    token: "fcm_device_token_secreto_xyz",
    token_fcm: "fcm_device_token_secreto_xyz",
  };

  const filtrado = filtrarDataPayloadFcm("lembrete_24h", payloadComDadosPessoais);

  // Apenas as chaves permitidas devem estar presentes
  const chavesPermitidas = new Set([
    "tipo",
    "vaga_id",
    "posicao_id",
    "turno_id",
    "estabelecimento_id",
    "reaberta",
  ]);

  for (const chave of Object.keys(filtrado)) {
    assert(
      chavesPermitidas.has(chave),
      `Chave não autorizada '${chave}' vazou no data payload do FCM (RN15)`,
    );
  }

  // Verificações negativas explícitas de dados pessoais
  assertEquals((filtrado as Record<string, string>).nome, undefined);
  assertEquals((filtrado as Record<string, string>).cpf, undefined);
  assertEquals((filtrado as Record<string, string>).rg, undefined);
  assertEquals((filtrado as Record<string, string>).telefone, undefined);
  assertEquals((filtrado as Record<string, string>).email, undefined);
  assertEquals((filtrado as Record<string, string>).endereco, undefined);
  assertEquals((filtrado as Record<string, string>).chave_pix, undefined);
  assertEquals((filtrado as Record<string, string>).usuario_id, undefined);
  assertEquals((filtrado as Record<string, string>).profissional_id, undefined);
  assertEquals((filtrado as Record<string, string>).token, undefined);
  assertEquals((filtrado as Record<string, string>).token_fcm, undefined);
});




