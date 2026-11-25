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

import { igualEmTempoConstante } from "./auth.ts";

export interface OpcoesIpVisitante {
  /** Chaves B-116 no formato `id1:64hex,id2:64hex` (env `IP_VISITANTE_HMAC_CHAVES`) ou par `IP_VISITANTE_HMAC_ID` + `IP_VISITANTE_HMAC`. */
  chavesBrutas?: string;
  /** Escopo da mensagem HMAC: `"anon"` em rotas anônimas, ou `<uid>` em rotas autenticadas. */
  escopo?: string;
  /** Relógio em segundos Unix (injetável em testes). */
  agoraSegundos?: number;
}

const REGEX_ASSINATURA_B116 = /^v1;k=([a-z0-9]{1,16});([0-9a-f]{64})$/;
const REGEX_CARIMBO_B116 = /^[0-9]{1,12}$/;
const REGEX_CHAVE_HEX_64 = /^[0-9a-f]{64}$/;
const JANELA_CARIMBO_B116_SEGUNDOS = 60;

export function lerChavesIpVisitante(bruto: string | undefined): Map<string, string> {
  const mapa = new Map<string, string>();
  for (const entrada of (bruto ?? "").split(",")) {
    const limpa = entrada.trim();
    if (!limpa) continue;
    const sep = limpa.indexOf(":");
    if (sep <= 0) continue;
    const id = limpa.slice(0, sep).trim();
    const segredo = limpa.slice(sep + 1).trim();
    if (/^[a-z0-9]{1,16}$/.test(id) && REGEX_CHAVE_HEX_64.test(segredo)) {
      mapa.set(id, segredo);
    }
  }
  if (mapa.size === 0 && bruto === undefined) {
    const idUnico = Deno.env.get("IP_VISITANTE_HMAC_ID")?.trim() ?? "";
    const segUnico = Deno.env.get("IP_VISITANTE_HMAC")?.trim() ?? "";
    if (/^[a-z0-9]{1,16}$/.test(idUnico) && REGEX_CHAVE_HEX_64.test(segUnico)) {
      mapa.set(idUnico, segUnico);
    }
  }
  return mapa;
}

/**
 * Valida os cabeçalhos assinados do padrão B-116 enviados pelo Cloudflare Worker:
 *   x-frila-ip-visitante: texto cru do CF-Connecting-IP (sem máscara `/`)
 *   x-frila-ip-carimbo:   segundos Unix (UTC), janela ±60s
 *   x-frila-ip-assinatura: v1;k=<id>;<hex> (HMAC-SHA256 UTF-8 de `v1|<ip>|<carimbo>|<escopo>`)
 *
 * Em chamadas anônimas, `<escopo>` é literalmente `"anon"`; em autenticadas, `<uid>` do Bearer.
 * Retorna o IP real do visitante somente se a assinatura for válida; caso contrário, `null`.
 */
export async function verificarIpVisitanteAssinado(
  req: Request,
  opcoes: OpcoesIpVisitante = {},
): Promise<string | null> {
  const ip = req.headers.get("x-frila-ip-visitante");
  const carimbo = req.headers.get("x-frila-ip-carimbo");
  const assinatura = req.headers.get("x-frila-ip-assinatura");
  if (!ip || !carimbo || !assinatura) return null;

  const match = assinatura.match(REGEX_ASSINATURA_B116);
  if (!match || !REGEX_CARIMBO_B116.test(carimbo) || ip.includes("/") || ip.trim() !== ip || ip.length > 64) {
    return null;
  }

  const agora = opcoes.agoraSegundos ?? Math.floor(Date.now() / 1000);
  const carimboNum = Number(carimbo);
  if (!Number.isFinite(carimboNum) || Math.abs(agora - carimboNum) > JANELA_CARIMBO_B116_SEGUNDOS) {
    return null;
  }

  const chaves = lerChavesIpVisitante(opcoes.chavesBrutas ?? Deno.env.get("IP_VISITANTE_HMAC_CHAVES"));
  const segredo = chaves.get(match[1]);
  if (!segredo) return null;

  const escopo = opcoes.escopo ?? "anon";
  const esperada = await hashTokenDispositivo(`v1|${ip}|${carimbo}|${escopo}`, segredo);
  return igualEmTempoConstante(esperada, match[2]) ? ip : null;
}

export type ResultadoIpRateLimit =
  | { ok: true; ip: string | null }
  | { ok: false; status: 403 | 503; code: "assinatura_ip_invalida" | "indisponivel" };

/**
 * Resolve o IP seguro para balde de rate limit, sem nunca confiar em `x-forwarded-for` bruto
 * e sem nunca agrupar tráfego Web pelo IP de egress compartilhado do Cloudflare Worker:
 * - Chamada Web (`plataforma === "web"`): fail-closed — exige chaves B-116 configuradas (503 se ausentes)
 *   e cabeçalhos B-116 assinados e válidos (403 se ausentes, adulterados ou fora da janela ±60s).
 *   Nunca degrada pulando o rate limit por IP nem cai em `cf-connecting-ip` de egress compartilhado.
 * - Qualquer chamada (inclusive mobile ou `plataforma === null`) que traga cabeçalhos B-116:
 *   fail-closed (503 sem chaves, 403 se assinatura inválida/expirada), impedindo bypass por cabeçalho forjado.
 * - Chamada com `plataforma === null` (ex.: `reenviar-dispositivo-otp`) sem cabeçalhos B-116:
 *   se vier com `Origin` (navegador direto sem Worker assinado), fail-closed 403;
 *   caso contrário (chamada direta mobile), usa apenas `cf-connecting-ip`.
 * - Chamada direta mobile (`ios`/`android`) sem cabeçalho B-116: usa apenas `cf-connecting-ip`.
 */
export async function resolverIpParaRateLimit(
  req: Request,
  plataforma: PlataformaAuth | null,
  opcoes: OpcoesIpVisitante = {},
): Promise<ResultadoIpRateLimit> {
  const temCabecalhosB116 = req.headers.has("x-frila-ip-visitante") ||
    req.headers.has("x-frila-ip-carimbo") ||
    req.headers.has("x-frila-ip-assinatura");

  if (plataforma === "web" || temCabecalhosB116) {
    const chaves = lerChavesIpVisitante(opcoes.chavesBrutas ?? Deno.env.get("IP_VISITANTE_HMAC_CHAVES"));
    if (chaves.size === 0) {
      return { ok: false, status: 503, code: "indisponivel" };
    }
    if (!temCabecalhosB116) {
      return { ok: false, status: 403, code: "assinatura_ip_invalida" };
    }
    const ipAssinado = await verificarIpVisitanteAssinado(req, opcoes);
    if (!ipAssinado) {
      return { ok: false, status: 403, code: "assinatura_ip_invalida" };
    }
    return { ok: true, ip: ipAssinado };
  }

  if (plataforma === null && req.headers.has("origin")) {
    return { ok: false, status: 403, code: "assinatura_ip_invalida" };
  }

  const cf = req.headers.get("cf-connecting-ip")?.trim();
  return { ok: true, ip: cf && cf.length > 0 ? cf : null };
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
