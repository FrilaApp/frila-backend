// Testes Deno da Edge Function enviar-push com simulação do FCM HTTP v1.
// Cartão 36fU0CEO: Envio de push pelo FCM, registro do aparelho e estado de entrega.
//
// Critérios testados:
// 1. Falha fechada sem AGENDADOR_SECRET e recusa de service_role como segredo do agendador.
// 2. Whitelist de payload (RN15): apenas reaberta (booleano) e UUIDs específicos no message.data.
// 3. Backoff exponencial com proxima_tentativa_em e worker não reenvia antes do vencimento.
// 4. Instante real de envio ao FCM gravado em enviada_em e aceita_em medidos no RNF02.

import "./test_setup.ts";
import { assertEquals, assert, assertMatch } from "jsr:@std/assert@1";
import {
  processarEnvioPush,
  titulosECorposPorTipo,
  filtrarDataPayloadFcm,
  calcularProximaTentativa,
  formatarHorario,
  criarSqlClient,
  SqlClient,
  GravarFalhaPushParams,
  GravarAceitePushParams,
} from "./index.ts";
import { FcmServiceAccount, sendFcmMessage, getAccessToken } from "./fcm.ts";

const SEGREDO_TESTE = "frila-teste-segredo-agendador-local";

interface MockSqlOpcoes {
  notificacaoExpirada?: boolean | ((id: string) => boolean | Promise<boolean>);
  chamadasFalha?: Array<GravarFalhaPushParams>;
  chamadasAceite?: Array<GravarAceitePushParams>;
  tokensRemovidos?: string[];
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
  const cmd = new Deno.Command(Deno.execPath(), {
    args: ["eval", "await import('./supabase/functions/enviar-push/index.ts');"],
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
              id: "n1000000-0000-4000-8000-000000000001",
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
    body: JSON.stringify({ notificacao_id: "n1000000-0000-4000-8000-000000000001" }),
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
              id: "n3000000-0000-4000-8000-000000000003",
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
    body: JSON.stringify({ notificacao_id: "n3000000-0000-4000-8000-000000000003" }),
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
              id: "n1000000-0000-4000-8000-000000000001",
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
    body: JSON.stringify({ notificacao_id: "n1000000-0000-4000-8000-000000000001" }),
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
              id: "n2000000-0000-4000-8000-000000000002",
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
    body: JSON.stringify({ notificacao_id: "n2000000-0000-4000-8000-000000000002" }),
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
              id: "n4000000-0000-4000-8000-000000000004",
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
    body: JSON.stringify({ notificacao_id: "n4000000-0000-4000-8000-000000000004" }),
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
    "n3000000-0000-4000-8000-00000000000a": CONTA_A,
    "n3000000-0000-4000-8000-00000000000b": CONTA_B,
  };
  const enviados: string[] = [];
  const fetchFn = mockCicloDoToken(dispositivos, notificacoes, enviados);

  const paraA = await enviarNotificacao("n3000000-0000-4000-8000-00000000000a", fetchFn);
  assertEquals(paraA.status, "falhou");
  assertEquals(paraA.detalhe, "sem_dispositivo");
  assertEquals(enviados, [], "O push da conta A não pode sair para o aparelho que passou para B");

  const paraB = await enviarNotificacao("n3000000-0000-4000-8000-00000000000b", fetchFn);
  assertEquals(paraB.status, "enviada");
  assertEquals(enviados, [TOKEN_COMPARTILHADO]);
});

Deno.test("Ciclo do token: depois de sair da conta, nenhuma notificação sai para o aparelho", async () => {
  // Estado depois de remover_dispositivo: a linha do aparelho não existe mais.
  const dispositivos: Array<{ usuario_id: string; token_fcm: string }> = [];
  const notificacoes = { "n3000000-0000-4000-8000-00000000000c": CONTA_B };
  const enviados: string[] = [];

  const relatorio = await enviarNotificacao(
    "n3000000-0000-4000-8000-00000000000c",
    mockCicloDoToken(dispositivos, notificacoes, enviados),
  );

  assertEquals(relatorio.status, "falhou");
  assertEquals(relatorio.detalhe, "sem_dispositivo");
  assertEquals(enviados, [], "Aparelho que saiu da conta não recebe push");
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
    if (url.includes("/rest/v1/rpc/notificacao_expirada")) {
      return Promise.resolve(new Response("false", { status: 200 }));
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
              id: "n5000000-0000-4000-8000-000000000005",
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
    body: JSON.stringify({ notificacao_id: "n5000000-0000-4000-8000-000000000005" }),
  });

  const res = await processarEnvioPush(req, {
    serviceAccount: sa,
    fetchFn: mockFetch,
    sqlClient,
  });

  assertEquals(res.status, 200);
  assertEquals(chamadasPostgrestRpc.length, 0, "Nenhuma RPC deve ser invocada via PostgREST /rest/v1/rpc/");
});
