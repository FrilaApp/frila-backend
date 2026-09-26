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
} from "./index.ts";
import { FcmServiceAccount, sendFcmMessage, getAccessToken } from "./fcm.ts";

const SEGREDO_TESTE = "frila-teste-segredo-agendador-local";

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
  });

  assertEquals(res.status, 200);
  const data = await res.json();
  assertEquals(data.relatorio[0].status, "pendente");
  assertEquals(data.relatorio[0].detalhe, "aguardando_backoff");
  assertEquals(fcmDisparado, false, "FCM não deve ser chamado antes do vencimento do backoff");
});

Deno.test("Bloqueio 3: erro transitório agenda proxima_tentativa_em no banco", async () => {
  const sa = await gerarContaDeServicoTeste();
  const chamadasRpc: Array<{ nome: string; params: Record<string, unknown> }> = [];

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

    if (url.includes("/rest/v1/rpc/notificacao_expirada")) {
      return Promise.resolve(new Response("false", { status: 200 }));
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

    if (url.includes("/rest/v1/rpc/")) {
      const match = url.match(/\/rpc\/([^?]+)/);
      const nomeRpc = match ? match[1] : "";
      return Promise.resolve(new Response("null", { status: 200 })).then(async (r) => {
        chamadasRpc.push({ nome: nomeRpc, params: {} });
        return r;
      });
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
    fetchFn: (input, init) => {
      const url = input.toString();
      if (url.includes("/rest/v1/rpc/gravar_falha_push") && init?.body) {
        chamadasRpc.push({
          nome: "gravar_falha_push",
          params: JSON.parse(init.body as string),
        });
        return Promise.resolve(new Response("null", { status: 200 }));
      }
      return mockFetch(input, init);
    },
  });

  assertEquals(res.status, 200);
  const data = await res.json();
  assertEquals(data.relatorio[0].status, "pendente");

  const rpcFalha = chamadasRpc.find((c) => c.nome === "gravar_falha_push");
  assert(rpcFalha !== undefined, "gravar_falha_push deve ser chamada");
  assertEquals(rpcFalha.params.p_permanente, false);
  assertEquals(rpcFalha.params.p_teto, 5);
  assert(rpcFalha.params.p_proxima_tentativa_em !== null, "proxima_tentativa_em deve ser preenchido");
  assert(rpcFalha.params.p_enviada_em !== null, "enviada_em deve ser registrado com o instante do envio");
});

// ── Bloqueio 4: Instante real de envio ao FCM e medição RNF02 ────────────────

Deno.test("Bloqueio 4: 200 grava instante real de envio e aceite para medir RNF02", async () => {
  const sa = await gerarContaDeServicoTeste();
  const chamadasRpc: Array<{ nome: string; params: Record<string, unknown> }> = [];

  const mockFetch: typeof fetch = (input: RequestInfo | URL, init?: RequestInit) => {
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

    if (url.includes("/rest/v1/rpc/notificacao_expirada")) {
      return Promise.resolve(new Response("false", { status: 200 }));
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

    if (url.includes("/rest/v1/rpc/gravar_aceite_push") && init?.body) {
      chamadasRpc.push({
        nome: "gravar_aceite_push",
        params: JSON.parse(init.body as string),
      });
      return Promise.resolve(new Response("null", { status: 200 }));
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
  });

  assertEquals(res.status, 200);
  const data = await res.json();
  assertEquals(data.relatorio[0].status, "enviada");

  const rpcAceite = chamadasRpc.find((c) => c.nome === "gravar_aceite_push");
  assert(rpcAceite !== undefined, "gravar_aceite_push deve ter sido invocada");
  assert(typeof rpcAceite.params.p_enviada_em === "string", "p_enviada_em deve ser registrado com timestamp real");
  assert(typeof rpcAceite.params.p_aceita_em === "string", "p_aceita_em deve ser registrado com timestamp de aceite");

  // Valida que o intervalo medido entre o disparo e o aceite é inferior a 60 segundos
  const tEnvio = new Date(rpcAceite.params.p_enviada_em as string).getTime();
  const tAceite = new Date(rpcAceite.params.p_aceita_em as string).getTime();
  const diferencaSegundos = (tAceite - tEnvio) / 1000;
  assert(diferencaSegundos <= 60, "Tempo do envio até aceite deve cumprir RNF02 (<= 60 s)");
});

// ── Casos de borda adicionais ──────────────────────────────────────────────────

Deno.test("Edge Function: 404/410 UNREGISTERED remove o token do aparelho", async () => {
  const sa = await gerarContaDeServicoTeste();
  const chamadasRpc: Array<{ nome: string; params: Record<string, unknown> }> = [];

  const mockFetch: typeof fetch = (input: RequestInfo | URL, init?: RequestInit) => {
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

    if (url.includes("/rest/v1/rpc/notificacao_expirada")) {
      return Promise.resolve(new Response("false", { status: 200 }));
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

    if (url.includes("/rest/v1/rpc/remover_token_fcm") && init?.body) {
      chamadasRpc.push({ nome: "remover_token_fcm", params: JSON.parse(init.body as string) });
      return Promise.resolve(new Response("1", { status: 200 }));
    }

    if (url.includes("/rest/v1/rpc/gravar_falha_push") && init?.body) {
      chamadasRpc.push({ nome: "gravar_falha_push", params: JSON.parse(init.body as string) });
      return Promise.resolve(new Response("null", { status: 200 }));
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
  });

  assertEquals(res.status, 200);
  const data = await res.json();
  assertEquals(data.relatorio[0].status, "falhou");
  assertEquals(data.relatorio[0].detalhe, "UNREGISTERED");

  const rpcRemover = chamadasRpc.find((c) => c.nome === "remover_token_fcm");
  assert(rpcRemover !== undefined, "remover_token_fcm deve ser chamada");
  assertEquals(rpcRemover.params.p_token, "fcm_token_invalido_unregistered");
});

Deno.test("Edge Function: não reenvia se início da vaga ou turno já passou", async () => {
  const sa = await gerarContaDeServicoTeste();
  let fcmChamado = false;

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

    if (url.includes("/rest/v1/rpc/notificacao_expirada")) {
      return Promise.resolve(new Response("true", { status: 200 }));
    }

    if (url.includes("/rest/v1/rpc/gravar_falha_push")) {
      return Promise.resolve(new Response("null", { status: 200 }));
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
  });

  assertEquals(res.status, 200);
  const data = await res.json();
  assertEquals(data.relatorio[0].status, "falhou");
  assertEquals(data.relatorio[0].detalhe, "vaga_ou_turno_ja_iniciado");
  assertEquals(fcmChamado, false, "FCM não deve ser chamado para notificação de turno/vaga já iniciado");
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

    if (url.includes("/rest/v1/rpc/notificacao_expirada")) {
      return Promise.resolve(new Response("false", { status: 200 }));
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

    if (url.includes("/rest/v1/rpc/gravar_aceite_push") || url.includes("/rest/v1/rpc/gravar_falha_push")) {
      return Promise.resolve(new Response("null", { status: 200 }));
    }

    return Promise.reject(new Error(`URL não tratada: ${url}`));
  };
}

async function enviarNotificacao(
  notificacaoId: string,
  fetchFn: typeof fetch,
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
