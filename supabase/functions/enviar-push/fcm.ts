// Cliente FCM HTTP v1 (OAuth2 com Conta de Serviço do Google / Firebase).
// Cartão 36fU0CEO: Envio de push pelo FCM, registro do aparelho e estado de entrega.
//
// A credencial NUNCA é lida de arquivo versionado: vem de segredo de ambiente
// (Deno.env.get("FCM_SERVICE_ACCOUNT")).

export interface FcmServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

export interface FcmMessagePayload {
  token: string;
  title: string;
  body: string;
  data?: Record<string, string>;
  plataforma?: string;
}

export interface FcmSendResult {
  ok: boolean;
  status: number;
  messageId?: string;
  unregistered?: boolean;
  transient?: boolean;
  error?: string;
}

function pemToBinary(pem: string): Uint8Array {
  const cleanPem = pem
    .replace(/-----BEGIN [A-Z ]+-----/g, "")
    .replace(/-----END [A-Z ]+-----/g, "")
    .replace(/\s+/g, "");
  const binaryString = atob(cleanPem);
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  return bytes;
}

function base64UrlEncode(data: Uint8Array | string): string {
  let str: string;
  if (typeof data === "string") {
    str = btoa(data);
  } else {
    let binary = "";
    for (let i = 0; i < data.byteLength; i++) {
      binary += String.fromCharCode(data[i]);
    }
    str = btoa(binary);
  }
  return str.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function createSignedJwt(
  sa: FcmServiceAccount,
  nowSec = Math.floor(Date.now() / 1000),
): Promise<string> {
  const tokenUri = sa.token_uri || "https://oauth2.googleapis.com/token";
  const header = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: tokenUri,
    exp: nowSec + 3600,
    iat: nowSec,
  };

  const encodedHeader = base64UrlEncode(JSON.stringify(header));
  const encodedPayload = base64UrlEncode(JSON.stringify(payload));
  const unsignedToken = `${encodedHeader}.${encodedPayload}`;

  const keyBytes = pemToBinary(sa.private_key);
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes.buffer as ArrayBuffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(unsignedToken),
  );

  const encodedSignature = base64UrlEncode(new Uint8Array(signature));
  return `${unsignedToken}.${encodedSignature}`;
}

export async function getAccessToken(
  sa: FcmServiceAccount,
  fetchFn: typeof fetch = fetch,
): Promise<string> {
  const jwt = await createSignedJwt(sa);
  const tokenUri = sa.token_uri || "https://oauth2.googleapis.com/token";

  const res = await fetchFn(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }).toString(),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Falha ao obter token OAuth do Google (${res.status}): ${text}`);
  }

  const json = await res.json();
  return json.access_token;
}

export async function sendFcmMessage(
  projectId: string,
  accessToken: string,
  payload: FcmMessagePayload,
  options?: { apiUrl?: string; fetchFn?: typeof fetch },
): Promise<FcmSendResult> {
  const fetchFn = options?.fetchFn ?? fetch;
  const url =
    options?.apiUrl ??
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

  const body: Record<string, unknown> = {
    message: {
      token: payload.token,
      notification: {
        title: payload.title,
        body: payload.body,
      },
      data: payload.data ?? {},
      apns: {
        payload: {
          aps: {
            sound: "default",
            badge: 1,
          },
        },
      },
    },
  };

  try {
    const res = await fetchFn(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });

    if (res.ok) {
      const data = await res.json().catch(() => ({}));
      return { ok: true, status: res.status, messageId: data.name };
    }

    const status = res.status;
    const errText = await res.text().catch(() => "");
    let errCode = "";
    try {
      const parsed = JSON.parse(errText);
      errCode =
        parsed?.error?.details?.[0]?.errorCode ||
        parsed?.error?.status ||
        "";
    } catch {
      // ignore
    }

    const isUnregistered =
      status === 404 ||
      status === 410 ||
      errCode === "UNREGISTERED";

    const isTransient =
      status === 429 ||
      status >= 500 ||
      errCode === "UNAVAILABLE" ||
      errCode === "INTERNAL";

    return {
      ok: false,
      status,
      unregistered: isUnregistered,
      transient: isTransient,
      error: errCode || `HTTP ${status}: ${errText.slice(0, 200)}`,
    };
  } catch (netErr) {
    return {
      ok: false,
      status: 0,
      transient: true,
      error: `Erro de rede: ${String(netErr)}`,
    };
  }
}
