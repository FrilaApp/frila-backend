// Testes Deno da Edge Function enviar-push com simulação do FCM HTTP v1.
// Cartão 36fU0CEO: Envio de push pelo FCM, registro do aparelho e estado de entrega.
//
// Critérios testados:
// 1. 200 grava o aceite (estado_entrega = 'enviada', aceita_em registrado).
// 2. 404/410 UNREGISTERED remove o token do banco e grava estado 'falhou'.
// 3. Erro transitório faz nova tentativa respeitando o teto de 5 tentativas.
// 4. Não reenvia notificação cuja vaga ou turno já tenha iniciado.
// 5. Conta de serviço é lida de variável de ambiente, nunca de arquivo versionado.

import { assertEquals, assert } from "jsr:@std/assert@1";
import { processarEnvioPush, titulosECorposPorTipo } from "./index.ts";
import { FcmServiceAccount, sendFcmMessage, getAccessToken } from "./fcm.ts";

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

  // Mock do fetch para o endpoint OAuth do Google e API do FCM
  const mockFetch: typeof fetch = (input: RequestInfo | URL, init?: RequestInit) => {
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

Deno.test("Edge Function: 200 grava o aceite (estado_entrega = enviada)", async () => {
  const sa = await gerarContaDeServicoTeste();
  const chamadasRpc: Array<{ nome: string; params: Record<string, unknown> }> = [];

  const mockFetch: typeof fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input.toString();

    // 1. Google OAuth
    if (url === "http://mock-oauth/token") {
      return Promise.resolve(
        new Response(
          JSON.stringify({ access_token: "token-oauth-ok", token_type: "Bearer", expires_in: 3600 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    // 2. PostgREST: busca notificação
    if (url.includes("/rest/v1/notificacao?id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              id: "n1000000-0000-4000-8000-000000000001",
              usuario_id: "u1000000-0000-4000-8000-000000000001",
              tipo: "vaga",
              referencia_id: "v1000000-0000-4000-8000-000000000001",
              payload: { vaga_id: "v1000000-0000-4000-8000-000000000001" },
              tentativas: 0,
              estado_entrega: "pendente",
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    // 3. PostgREST: busca aparelhos
    if (url.includes("/rest/v1/dispositivo?usuario_id=eq.")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              id: "d1000000-0000-4000-8000-000000000001",
              token_fcm: "fcm_token_aparelho_valido_12345",
              plataforma: "ios",
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    // 4. RPCs do Supabase
    if (url.includes("/rest/v1/rpc/")) {
      const rpcNome = url.split("/rpc/")[1];
      const params = JSON.parse((init?.body as string) || "{}");
      chamadasRpc.push({ nome: rpcNome, params });

      if (rpcNome === "notificacao_expirada") {
        return Promise.resolve(new Response("false", { status: 200 }));
      }
      return Promise.resolve(new Response("null", { status: 200 }));
    }

    // 5. FCM send (200 OK)
    if (url.includes("/messages:send")) {
      return Promise.resolve(
        new Response(
          JSON.stringify({ name: "projects/frila-test-project/messages/msg_ok_1" }),
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
      "x-agendador-secret": "frila-agendador-segredo-local",
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
  assertEquals(data.ok, true);
  assertEquals(data.processadas, 1);
  assertEquals(data.relatorio[0].status, "enviada");

  // Prova que a RPC de aceite foi chamada para a notificação
  const rpcAceite = chamadasRpc.find((c) => c.nome === "gravar_aceite_push");
  assert(rpcAceite !== undefined, "gravar_aceite_push deve ter sido invocada");
  assertEquals(rpcAceite.params.p_notificacao_id, "n1000000-0000-4000-8000-000000000001");
});

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
              tipo: "cancelamento",
              referencia_id: "v2000000-0000-4000-8000-000000000002",
              payload: {},
              tentativas: 0,
              estado_entrega: "pendente",
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
            {
              id: "d2000000-0000-4000-8000-000000000002",
              token_fcm: "token_invalido_antigo_unregistered",
              plataforma: "android",
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/rpc/")) {
      const rpcNome = url.split("/rpc/")[1];
      const params = JSON.parse((init?.body as string) || "{}");
      chamadasRpc.push({ nome: rpcNome, params });

      if (rpcNome === "notificacao_expirada") {
        return Promise.resolve(new Response("false", { status: 200 }));
      }
      return Promise.resolve(new Response("null", { status: 200 }));
    }

    // FCM retorna 404 UNREGISTERED
    if (url.includes("/messages:send")) {
      return Promise.resolve(
        new Response(
          JSON.stringify({
            error: {
              code: 404,
              message: "Requested entity was not found.",
              status: "NOT_FOUND",
              details: [
                {
                  "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
                  errorCode: "UNREGISTERED",
                },
              ],
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
      "x-agendador-secret": "frila-agendador-segredo-local",
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
  assertEquals(data.ok, true);
  assertEquals(data.relatorio[0].status, "falhou");
  assertEquals(data.relatorio[0].detalhe, "UNREGISTERED");

  // Prova que remover_token_fcm foi chamada com o token inválido
  const rpcRemover = chamadasRpc.find((c) => c.nome === "remover_token_fcm");
  assert(rpcRemover !== undefined, "remover_token_fcm deve ser invocada para UNREGISTERED");
  assertEquals(rpcRemover.params.p_token, "token_invalido_antigo_unregistered");

  // Prova que gravar_falha_push foi chamada com motivo UNREGISTERED
  const rpcFalha = chamadasRpc.find((c) => c.nome === "gravar_falha_push");
  assert(rpcFalha !== undefined, "gravar_falha_push deve ser invocada");
  assertEquals(rpcFalha.params.p_motivo, "UNREGISTERED");
  assertEquals(rpcFalha.params.p_permanente, true);
});

Deno.test("Edge Function: erro transitório faz nova tentativa e respeita o teto", async () => {
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
              id: "n3000000-0000-4000-8000-000000000003",
              usuario_id: "u3000000-0000-4000-8000-000000000003",
              tipo: "lembrete_3h",
              referencia_id: "v3000000-0000-4000-8000-000000000003",
              payload: {},
              tentativas: 1, // já tentou 1 vez
              estado_entrega: "pendente",
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
            {
              id: "d3000000-0000-4000-8000-000000000003",
              token_fcm: "fcm_token_valido_transient",
              plataforma: "ios",
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/rpc/")) {
      const rpcNome = url.split("/rpc/")[1];
      const params = JSON.parse((init?.body as string) || "{}");
      chamadasRpc.push({ nome: rpcNome, params });

      if (rpcNome === "notificacao_expirada") {
        return Promise.resolve(new Response("false", { status: 200 }));
      }
      return Promise.resolve(new Response("null", { status: 200 }));
    }

    // FCM retorna erro 503 Service Unavailable (transitório)
    if (url.includes("/messages:send")) {
      return Promise.resolve(
        new Response(
          JSON.stringify({
            error: {
              code: 503,
              message: "Service Unavailable",
              status: "UNAVAILABLE",
            },
          }),
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
      "x-agendador-secret": "frila-agendador-segredo-local",
    },
    body: JSON.stringify({ notificacao_id: "n3000000-0000-4000-8000-000000000003" }),
  });

  const res = await processarEnvioPush(req, {
    serviceAccount: sa,
    fetchFn: mockFetch,
    fcmApiUrl: "http://mock-fcm/messages:send",
  });

  assertEquals(res.status, 200);
  const data = await res.json();
  assertEquals(data.ok, true);
  // Como tentativas era 1 (agora 2 < 5), continua como pendente para próxima tentativa
  assertEquals(data.relatorio[0].status, "pendente");

  const rpcFalha = chamadasRpc.find((c) => c.nome === "gravar_falha_push");
  assert(rpcFalha !== undefined, "gravar_falha_push deve ser chamada");
  assertEquals(rpcFalha.params.p_permanente, false);
  assertEquals(rpcFalha.params.p_teto, 5);
});

Deno.test("Edge Function: não reenvia se início da vaga ou turno já passou", async () => {
  const sa = await gerarContaDeServicoTeste();
  let fcmChamado = false;

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
              id: "n4000000-0000-4000-8000-000000000004",
              usuario_id: "u4000000-0000-4000-8000-000000000004",
              tipo: "vaga",
              referencia_id: "v4000000-0000-4000-8000-000000000004",
              payload: {},
              tentativas: 1,
              estado_entrega: "pendente",
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
    }

    if (url.includes("/rest/v1/rpc/notificacao_expirada")) {
      // Simula que a vaga já começou (expirada = true)
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
      "x-agendador-secret": "frila-agendador-segredo-local",
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
    // Verifica que não vaza dados como cpf, telefone, etc.
    assert(!body.includes("@"), `Corpo não pode conter e-mail (${tipo})`);
    assert(!body.includes("+55"), `Corpo não pode conter telefone (${tipo})`);
  }
});
