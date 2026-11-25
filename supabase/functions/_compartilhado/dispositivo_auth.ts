// Utilitários compartilhados das Edge Functions de autenticação por senha e dispositivo confiável (30 dias).
//
// Regras de segurança:
// - Token opaco gerado com CSPRNG (32 bytes base64url) e persistido no banco somente como HMAC-SHA256 com pepper.
// - Nunca logar senha, token, OTP, e-mail completo ou service_role.
// - Revogação de sessão provisória usa exclusivamente scope=local (ou revogação pontual por session_id), nunca scope=global.

export type PlataformaAuth = "ios" | "android" | "web";

export interface ErroResposta {
  code: string;
  message: string;
  details: string | null;
}

export interface SessaoGoTrue {
  access_token: string;
  token_type: string;
  expires_in: number;
  refresh_token: string;
  user: {
    id: string;
    email?: string;
    [k: string]: unknown;
  };
}

export const PLATAFORMAS_VALIDAS = new Set<PlataformaAuth>(["ios", "android", "web"]);

export function ehPlataformaValida(valor: unknown): valor is PlataformaAuth {
  return typeof valor === "string" && PLATAFORMAS_VALIDAS.has(valor as PlataformaAuth);
}

export function normalizarEmail(valor: unknown): string | null {
  if (typeof valor !== "string") return null;
  const limpo = valor.trim().toLowerCase();
  if (!limpo || !limpo.includes("@") || limpo.length > 254) return null;
  return limpo;
}

export function recusa(status: number, code: string, details: string | null = null): Response {
  const corpo: ErroResposta = { code, message: code, details };
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

export function responderJson(status: number, corpo: unknown): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

export function gerarTokenOpaco(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binario = "";
  for (const b of bytes) binario += String.fromCharCode(b);
  return btoa(binario).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function bytesParaHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function hashSha256Hex(texto: string): Promise<string> {
  const dados = new TextEncoder().encode(texto);
  const digest = await crypto.subtle.digest("SHA-256", dados);
  return bytesParaHex(digest);
}

export async function hashTokenDispositivo(token: string, pepper: string): Promise<string> {
  const chave = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(pepper),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const assinatura = await crypto.subtle.sign("HMAC", chave, new TextEncoder().encode(token));
  return bytesParaHex(assinatura);
}

/**
 * Extrai `session_id` do payload de um JWT recém-devolvido pelo próprio GoTrue.
 * Nunca usado isoladamente para autenticação: a assinatura já foi validada pelo GoTrue.
 */
export function extrairSessionIdDoJwt(jwt: string): string | null {
  try {
    const partes = jwt.split(".");
    if (partes.length < 2) return null;
    const base64 = partes[1].replace(/-/g, "+").replace(/_/g, "/");
    const pad = base64.length % 4 === 0 ? "" : "=".repeat(4 - (base64.length % 4));
    const json = JSON.parse(atob(base64 + pad));
    return typeof json?.session_id === "string" && json.session_id.length > 0 ? json.session_id : null;
  } catch {
    return null;
  }
}

export function extrairIpCliente(req: Request): string {
  const cf = req.headers.get("cf-connecting-ip")?.trim();
  if (cf) return cf;
  const xff = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  if (xff) return xff;
  return "desconhecido";
}

export function validarSessaoGoTrue(dados: unknown): SessaoGoTrue | null {
  if (!dados || typeof dados !== "object") return null;
  const s = dados as Record<string, unknown>;
  if (
    typeof s.access_token !== "string" || s.access_token.length === 0 ||
    typeof s.refresh_token !== "string" || s.refresh_token.length === 0 ||
    typeof s.expires_in !== "number" ||
    !s.user || typeof s.user !== "object" ||
    typeof (s.user as Record<string, unknown>).id !== "string"
  ) {
    return null;
  }
  return {
    access_token: s.access_token,
    token_type: typeof s.token_type === "string" ? s.token_type : "bearer",
    expires_in: s.expires_in,
    refresh_token: s.refresh_token,
    user: s.user as SessaoGoTrue["user"],
  };
}

export async function renovarSessaoGoTrue(
  supabaseUrl: string,
  anonKey: string,
  refreshToken: string,
  fetchFn: typeof fetch = fetch,
): Promise<SessaoGoTrue | null> {
  const res = await fetchFn(`${supabaseUrl}/auth/v1/token?grant_type=refresh_token`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": anonKey,
    },
    body: JSON.stringify({ refresh_token: refreshToken }),
  });
  if (!res.ok) return null;
  return validarSessaoGoTrue(await res.json().catch(() => null));
}

export async function revogarSessaoLocalGoTrue(
  supabaseUrl: string,
  anonKey: string,
  accessToken: string,
  fetchFn: typeof fetch = fetch,
): Promise<boolean> {
  try {
    const res = await fetchFn(`${supabaseUrl}/auth/v1/logout?scope=local`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "apikey": anonKey,
      },
    });
    return res.ok;
  } catch {
    return false;
  }
}
