// Edge Function: POST /functions/v1/autenticar-social (contrato 0.2.117)
//
// Conclui login social Apple ou Google no servidor:
// - Rate limit por IP com B-116 fail-closed na Web (403/503 sem assinatura válida) e cf-connecting-ip no mobile.
// - Executa troca no GoTrue (`/auth/v1/token?grant_type=pkce` ou `grant_type=id_token`).
// - Comprova identidade do provedor em `auth.identities` e grava `privado.sessoes_verificadas` via
//   `privado.concluir_login_social` (sujeito a revogação online imediata).
// - Obriga `grant_type=refresh_token` para o hook emitir JWT final com `dispositivo_verificado = true`.
// - Nunca registra tokens, códigos OAuth, verifiers ou nonces em log.

import postgres from "npm:postgres@3.4.4";
import { comCors } from "../_compartilhado/cors.ts";
import {
  ehPlataformaValida,
  extrairSessionIdDoJwt,
  hashSha256Hex,
  type OpcoesIpVisitante,
  recusa,
  renovarSessaoGoTrue,
  resolverIpParaRateLimit,
  responderJson,
  revogarSessaoLocalGoTrue,
  validarSessaoGoTrue,
} from "../_compartilhado/dispositivo_auth.ts";

export type ProvedorSocial = "apple" | "google";
export type FluxoSocial = "pkce" | "id_token";

export interface AutenticarSocialDb {
  consumirRateLimit(chave: string, limite: number, janelaSegundos: number): Promise<boolean>;
  concluirLoginSocial(usuarioId: string, sessionId: string | null, provedor: ProvedorSocial): Promise<{
    ok: boolean;
    motivo?: string;
    precisa_definir_senha?: boolean;
  }>;
  revogarSessaoPontual(sessionId: string | null, usuarioId: string): Promise<void>;
}

export interface AutenticarSocialDeps {
  fetchFn?: typeof fetch;
  supabaseUrl?: string;
  anonKey?: string;
  dbUrl?: string;
  origensCors?: string;
  opcoesIp?: OpcoesIpVisitante;
  db?: AutenticarSocialDb;
}

const REGEX_VERIFIER_PKCE = /^[A-Za-z0-9_-]{43,128}$/;
const REGEX_CODIGO_OAUTH = /^[\x21-\x7e]{4,512}$/;

function ehProvedorValido(v: unknown): v is ProvedorSocial {
  return v === "apple" || v === "google";
}

function ehFluxoValido(v: unknown): v is FluxoSocial {
  return v === "pkce" || v === "id_token";
}

function ehErroConflitoIdentidade(status: number, body: Record<string, unknown> | null): boolean {
  if (status === 409) return true;
  const code = String(body?.error_code ?? body?.code ?? body?.error ?? "").toLowerCase();
  const msg = String(body?.msg ?? body?.error_description ?? "").toLowerCase();
  return code.includes("identity_already_exists") ||
    code.includes("manual_linking") ||
    code.includes("email_conflict") ||
    msg.includes("identity_already_exists") ||
    msg.includes("already registered");
}

function criarDbSql(dbUrl: string): AutenticarSocialDb & { fechar(): Promise<void> } {
  const sql = postgres(dbUrl, { max: 1, connect_timeout: 5, idle_timeout: 10 });
  return {
    async consumirRateLimit(chave, limite, janelaSegundos) {
      const [row] = await sql`select privado.consumir_rate_limit_auth(${chave}, ${limite}, ${janelaSegundos}) as permitido`;
      return Boolean(row?.permitido);
    },
    async concluirLoginSocial(usuarioId, sessionId, provedor) {
      const [row] = await sql`
        select privado.concluir_login_social(${usuarioId}::uuid, ${sessionId}::uuid, ${provedor}) as res
      `;
      return (row?.res ?? { ok: false, motivo: "erro_interno" }) as {
        ok: boolean;
        motivo?: string;
        precisa_definir_senha?: boolean;
      };
    },
    async revogarSessaoPontual(sessionId, usuarioId) {
      if (!sessionId) return;
      await sql`select privado.revogar_sessao_pontual(${sessionId}::uuid, ${usuarioId}::uuid)`;
    },
    async fechar() {
      await sql.end({ timeout: 2 }).catch(() => {});
    },
  };
}

export async function tratarAutenticarSocial(req: Request, deps: AutenticarSocialDeps = {}): Promise<Response> {
  if (req.method !== "POST") return recusa(405, "metodo_nao_permitido");

  let corpo: Record<string, unknown>;
  try {
    const parsed = await req.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return recusa(422, "campo_invalido", "corpo");
    }
    corpo = parsed as Record<string, unknown>;
  } catch {
    return recusa(422, "campo_invalido", "corpo");
  }

  if (!ehProvedorValido(corpo.provedor)) return recusa(422, "campo_invalido", "provedor");
  if (!ehFluxoValido(corpo.fluxo)) return recusa(422, "campo_invalido", "fluxo");
  if (!ehPlataformaValida(corpo.plataforma)) return recusa(422, "campo_invalido", "plataforma");

  const provedor = corpo.provedor;
  const fluxo = corpo.fluxo;
  const plataforma = corpo.plataforma;

  let codigo = "";
  let codeVerifier = "";
  let idToken = "";
  let nonce = "";

  if (fluxo === "pkce") {
    codigo = typeof corpo.codigo === "string" ? corpo.codigo.trim() : "";
    codeVerifier = typeof corpo.code_verifier === "string" ? corpo.code_verifier.trim() : "";
    if (!REGEX_CODIGO_OAUTH.test(codigo)) return recusa(422, "campo_invalido", "codigo");
    if (!REGEX_VERIFIER_PKCE.test(codeVerifier)) return recusa(422, "campo_invalido", "code_verifier");
  } else {
    idToken = typeof corpo.id_token === "string" ? corpo.id_token.trim() : "";
    nonce = typeof corpo.nonce === "string" ? corpo.nonce.trim() : "";
    if (idToken.length < 16 || idToken.length > 8192) return recusa(422, "campo_invalido", "id_token");
    if (nonce.length < 16 || nonce.length > 256) return recusa(422, "campo_invalido", "nonce");
  }

  const fetchFn = deps.fetchFn ?? fetch;
  const supabaseUrl = (deps.supabaseUrl ?? Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
  const anonKey = deps.anonKey ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const dbUrl = deps.dbUrl ?? Deno.env.get("SUPABASE_DB_URL") ?? "";

  if (!supabaseUrl || !anonKey || (!deps.db && !dbUrl)) {
    return recusa(503, "indisponivel");
  }

  const sqlDb = deps.db ? null : criarDbSql(dbUrl);
  const db: AutenticarSocialDb = deps.db ?? sqlDb!;

  try {
    const resultadoIp = await resolverIpParaRateLimit(req, plataforma, deps.opcoesIp);
    if (!resultadoIp.ok) return recusa(resultadoIp.status, resultadoIp.code);

    if (resultadoIp.ip) {
      const ipHash = await hashSha256Hex(resultadoIp.ip);
      const okIp = await db.consumirRateLimit(`auth:social:ip:${ipHash}`, 20, 600);
      if (!okIp) return recusa(429, "limite_excedido");
    }

    const urlToken = fluxo === "pkce"
      ? `${supabaseUrl}/auth/v1/token?grant_type=pkce`
      : `${supabaseUrl}/auth/v1/token?grant_type=id_token`;
    const payloadToken = fluxo === "pkce"
      ? { auth_code: codigo, code_verifier: codeVerifier }
      : { provider: provedor, id_token: idToken, nonce };

    const resAuth = await fetchFn(urlToken, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": anonKey,
      },
      body: JSON.stringify(payloadToken),
    });

    if (resAuth.status === 429) return recusa(429, "limite_excedido");
    if (resAuth.status >= 500) return recusa(503, "indisponivel");

    const corpoAuth = await resAuth.json().catch(() => null) as Record<string, unknown> | null;
    if (!resAuth.ok) {
      if (ehErroConflitoIdentidade(resAuth.status, corpoAuth)) {
        return recusa(409, "conflito_identidade");
      }
      return recusa(401, "credenciais_invalidas");
    }

    const sessaoProvisoria = validarSessaoGoTrue(corpoAuth);
    if (!sessaoProvisoria) return recusa(503, "indisponivel");

    const usuarioId = sessaoProvisoria.user.id;
    const sessionId = extrairSessionIdDoJwt(sessaoProvisoria.access_token);

    const conclusao = await db.concluirLoginSocial(usuarioId, sessionId, provedor);
    if (!conclusao.ok) {
      await revogarSessaoLocalGoTrue(supabaseUrl, anonKey, sessaoProvisoria.access_token, fetchFn);
      await db.revogarSessaoPontual(sessionId, usuarioId);
      return recusa(401, "credenciais_invalidas");
    }

    // Obriga refresh_token para o custom_access_token_hook emitir JWT final com dispositivo_verificado = true.
    const sessaoFinal = await renovarSessaoGoTrue(
      supabaseUrl,
      anonKey,
      sessaoProvisoria.refresh_token,
      fetchFn,
    );
    if (!sessaoFinal) {
      await revogarSessaoLocalGoTrue(supabaseUrl, anonKey, sessaoProvisoria.access_token, fetchFn);
      await db.revogarSessaoPontual(sessionId, usuarioId);
      return recusa(503, "indisponivel");
    }

    return responderJson(200, {
      sessao: sessaoFinal,
      provedor,
      precisa_definir_senha: Boolean(conclusao.precisa_definir_senha),
    });
  } finally {
    await sqlDb?.fechar();
  }
}

if (import.meta.main) {
  Deno.serve((req) => comCors(req, undefined, () => tratarAutenticarSocial(req)));
}
