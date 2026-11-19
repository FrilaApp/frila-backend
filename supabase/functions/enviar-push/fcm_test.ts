// B-038 (web B6): o corpo enviado ao FCM HTTP v1 por plataforma.
// Web leva só `data` (B-054: sem título nem corpo) e nada de `apns` nem `android`; iOS e Android
// ficam byte a byte como antes. Referência do formato:
// https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages#WebpushConfig

import "./test_setup.ts";
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { FcmMessagePayload, sendFcmMessage } from "./fcm.ts";

async function corpoEnviado(payload: FcmMessagePayload): Promise<any> {
  let corpo: any = null;
  const mockFetch: typeof fetch = (_input: RequestInfo | URL, init?: RequestInit) => {
    corpo = JSON.parse(init?.body as string);
    return Promise.resolve(
      new Response(JSON.stringify({ name: "projects/frila-test/messages/msg-1" }), { status: 200 }),
    );
  };
  const resultado = await sendFcmMessage("frila-test", "mock-token", payload, { fetchFn: mockFetch });
  assertEquals(resultado.ok, true);
  return corpo;
}

const DATA_BASE = {
  tipo: "vaga",
  vaga_id: "d0000000-0000-4000-8000-000000000001",
};

Deno.test("B-054: plataforma web leva só data (tipo e ids), sem título nem corpo em lugar nenhum", async () => {
  const corpo = await corpoEnviado({
    token: "token-teste-web",
    title: "Nova vaga no Frila",
    body: "Confira a vaga",
    plataforma: "web",
    data: { ...DATA_BASE },
  });

  assertEquals(corpo, {
    message: {
      token: "token-teste-web",
      data: { ...DATA_BASE },
      webpush: { data: { ...DATA_BASE } },
    },
  });
  // O sw.js da web mostra texto neutro (#886, decisão A): título e corpo não viajam pelo FCM.
  const json = JSON.stringify(corpo);
  assertEquals(json.includes("Nova vaga no Frila"), false);
  assertEquals(json.includes("Confira a vaga"), false);
  assertEquals(corpo.message.notification, undefined);
  assertEquals(corpo.message.webpush.notification, undefined);
  // Sem link de destino no payload, não há fcm_options (não se inventa URL).
  assertEquals(corpo.message.webpush.fcm_options, undefined);
  assertEquals(corpo.message.apns, undefined);
  assertEquals(corpo.message.android, undefined);
});

Deno.test("B-038: web não ganha titulo/corpo no data (isso é só do Android)", async () => {
  const corpo = await corpoEnviado({
    token: "token-teste-web",
    title: "Título",
    body: "Corpo",
    plataforma: "web",
    data: { tipo: "confirmacao" },
  });
  assertEquals(corpo.message.data, { tipo: "confirmacao" });
  assertEquals(corpo.message.webpush.data, { tipo: "confirmacao" });
});

Deno.test("B-038 regressão: corpo do iOS igual ao de antes", async () => {
  const corpo = await corpoEnviado({
    token: "token-teste-ios",
    title: "Nova vaga no Frila",
    body: "Confira a vaga",
    plataforma: "ios",
    data: { ...DATA_BASE, vinculo_id: "11111111-1111-4000-8000-000000000001" },
  });

  assertEquals(corpo, {
    message: {
      token: "token-teste-ios",
      data: { ...DATA_BASE, vinculo_id: "11111111-1111-4000-8000-000000000001" },
      android: { priority: "high", ttl: "86400s" },
      apns: {
        headers: { "apns-priority": "10", "apns-push-type": "alert" },
        payload: {
          aps: {
            alert: { title: "Nova vaga no Frila", body: "Confira a vaga" },
            sound: "default",
            badge: 1,
            "mutable-content": 1,
          },
          vinculo_id: "11111111-1111-4000-8000-000000000001",
        },
      },
    },
  });
  // Ordem das chaves também igual (o JSON enviado não muda nem na serialização).
  assertEquals(Object.keys(corpo.message), ["token", "data", "android", "apns"]);
});

Deno.test("B-038 regressão: corpo do Android igual ao de antes", async () => {
  const corpo = await corpoEnviado({
    token: "token-teste-android",
    title: "Nova vaga no Frila",
    body: "Confira a vaga",
    plataforma: "android",
    data: { ...DATA_BASE },
  });

  assertEquals(corpo, {
    message: {
      token: "token-teste-android",
      data: { ...DATA_BASE, titulo: "Nova vaga no Frila", corpo: "Confira a vaga" },
      android: { priority: "high", ttl: "86400s" },
      apns: {
        headers: { "apns-priority": "10", "apns-push-type": "alert" },
        payload: {
          aps: {
            alert: { title: "Nova vaga no Frila", body: "Confira a vaga" },
            sound: "default",
            badge: 1,
            "mutable-content": 1,
          },
        },
      },
    },
  });
  assertEquals(Object.keys(corpo.message), ["token", "data", "android", "apns"]);
});

Deno.test("B-038 regressão: sem plataforma, o corpo segue o formato de antes (android + apns)", async () => {
  const corpo = await corpoEnviado({
    token: "token-sem-plataforma",
    title: "T",
    body: "C",
    data: { tipo: "vaga" },
  });
  assertEquals(Object.keys(corpo.message), ["token", "data", "android", "apns"]);
  assertEquals(corpo.message.webpush, undefined);
});
