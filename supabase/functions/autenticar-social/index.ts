// Edge Function: POST /functions/v1/autenticar-social (contrato 0.2.117)
//
// Conclui login social Apple ou Google no servidor com prova autoritativa do provedor da sessão atual:
// - `iniciar_pkce`: registra transação atômica em `privado.transacoes_oauth_social` vinculando
//   (transacao_id, provedor, code_challenge_hash, callback_url) com TTL de 10 min e devolve
//   `url_autorizacao` construída no servidor com `provider=<provedor>`.
// - `pkce`: calcula `S256(code_verifier)` e consome atomicamente `transacao_id` exigindo
//   correspondência exata de `(transacao_id, provedor, code_challenge_hash)` ANTES de chamar GoTrue
//   (fecha spoof de provedor em contas multivinculadas Apple+Google e replay de transação).
// - `id_token`: GoTrue valida assinatura/iss contra `provider=<provedor>` enviado pelo servidor,
//   e `privado.concluir_login_social` consome atomicamente o hash SHA-256 do token em
//   `privado.tokens_sociais_consumidos` (sem persistir token bruto) contra replay de id_token.
// - Rate limit por IP com B-116 fail-closed na Web (403/503) e `cf-connecting-ip` no mobile.
// - Obriga `grant_type=refresh_token` para o hook emitir JWT final com `dispositivo_verificado = true`.
// - Nunca registra tokens, códigos OAuth, verifiers ou nonces em log.

import postgres from "npm:postgres@3.4.4";
import { comCors } from "../_compartilhado/cors.ts";
import {
  ehPlataformaValida,
  extrairSessionIdDoJwt,
  hashSha256Hex,
  type OpcoesIpVisitante,
  type PlataformaAuth,
  recusa,
  renovarSessaoGoTrue,
  resolverIpParaRateLimit,
  responderJson,
  revogarSessaoLocalGoTrue,
  validarSessaoGoTrue,
} from "../_compartilhado/dispositivo_auth.ts";

export type ProvedorSocial = "apple" | "google";
export type FluxoSocial = "iniciar_pkce" | "pkce" | "id_token";

export interface AutenticarSocialDb {
  consumirRateLimit(chave: string, limite: number, janelaSegundos: number): Promise<boolean>;
  criarTransacaoOauth(
    provedor: ProvedorSocial,
    plataforma: PlataformaAuth,
    codeChallengeHash: string,
    callbackUrl: string,
  ): Promise<{ ok: boolean; transacao_id?: string; expira_em?: string; motivo?: string }>;
  consumirTransacaoOauth(
    transacaoId: string,
    provedor: ProvedorSocial,
    codeChallengeHash: string,
  ): Promise<{ ok: boolean; motivo?: string; provedor?: ProvedorSocial }>;
  concluirLoginSocial(
    usuarioId: string,
    sessionId: string | null,
    provedor: ProvedorSocial,
    idTokenHash: string | null,
  ): Promise<{
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

const REGEX_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REGEX_VERIFIER_PKCE = /^[A-Za-z0-9_-]{43,128}$/;
const REGEX_CHALLENGE_PKCE = /^[A-Za-z0-9_-]{43}$/;
const REGEX_CODIGO_OAUTH = /^[\x21-\x7e]{4,512}$/;

const CALLBACKS_PERMITIDOS_PREFIXOS = [
  "https://frila-web-dev.frilabr.workers.dev/app/entrar/",
  "https://frilabr.com/app/entrar/",
  "http://localhost:",
  "http://127.0.0.1:",
  "frila-auth://auth/callback",
];

function ehProvedorValido(v: unknown): v is ProvedorSocial {
  return v === "apple" || v === "google";
}

function ehFluxoValido(v: unknown): v is FluxoSocial {
  return v === "iniciar_pkce" || v === "pkce" || v === "id_token";
}

function ehRedirectPermitido(url: string): boolean {
  if (url.length < 8 || url.length > 512 || /\s/.test(url)) return false;
  return CALLBACKS_PERMITIDOS_PREFIXOS.some((prefixo) => url.startsWith(prefixo));
}

async function desafioPkceS256(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  let binario = "";
  for (const b of new Uint8Array(digest)) binario += String.fromCharCode(b);
  return btoa(binario).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
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
    async criarTransacaoOauth(provedor, plataforma, codeChallengeHash, callbackUrl) {
      const [row] = await sql`
        select privado.criar_transacao_oauth_social(${provedor}, ${plataforma}, ${codeChallengeHash}, ${callbackUrl}) as res
      `;
      return (row?.res ?? { ok: false, motivo: "erro_interno" }) as {
        ok: boolean;
        transacao_id?: string;
        expira_em?: string;
        motivo?: string;
      };
    },
    async consumirTransacaoOauth(transacaoId, provedor, codeChallengeHash) {
      const [row] = await sql`
        select privado.consumir_transacao_oauth_social(${transacaoId}::uuid, ${provedor}, ${codeChallengeHash}) as res
      `;
      return (row?.res ?? { ok: false, motivo: "transacao_invalida" }) as {
        ok: boolean;
        motivo?: string;
        provedor?: ProvedorSocial;
      };
    },
    async concluirLoginSocial(usuarioId, sessionId, provedor, idTokenHash) {
      const [row] = await sql`
        select privado.concluir_login_social(${usuarioId}::uuid, ${sessionId}::uuid, ${provedor}, ${idTokenHash}) as res
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

  let codeChallenge = "";
  let redirectTo = "";
  let transacaoId = "";
  let codigo = "";
  let codeVerifier = "";
  let idToken = "";
  let nonce = "";

  if (fluxo === "iniciar_pkce") {
    codeChallenge = typeof corpo.code_challenge === "string" ? corpo.code_challenge.trim() : "";
    redirectTo = typeof corpo.redirect_to === "string" ? corpo.redirect_to.trim() : "";
    if (!REGEX_CHALLENGE_PKCE.test(codeChallenge)) return recusa(422, "campo_invalido", "code_challenge");
    if (!ehRedirectPermitido(redirectTo)) return recusa(422, "campo_invalido", "redirect_to");
  } else if (fluxo === "pkce") {
    transacaoId = typeof corpo.transacao_id === "string" ? corpo.transacao_id.trim() : "";
    codigo = typeof corpo.codigo === "string" ? corpo.codigo.trim() : "";
    codeVerifier = typeof corpo.code_verifier === "string" ? corpo.code_verifier.trim() : "";
    if (!REGEX_UUID.test(transacaoId)) return recusa(422, "campo_invalido", "transacao_id");
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

    if (fluxo === "iniciar_pkce") {
      const challengeHash = await hashSha256Hex(codeChallenge);
      const criada = await db.criarTransacaoOauth(provedor, plataforma, challengeHash, redirectTo);
      if (!criada.ok || !criada.transacao_id || !criada.expira_em) {
        if (criada.motivo === "desafio_ja_usado") return recusa(409, "desafio_ja_usado");
        return recusa(503, "indisponivel");
      }
      const urlAuth = new URL(`${supabaseUrl}/auth/v1/authorize`);
      urlAuth.searchParams.set("provider", provedor);
      urlAuth.searchParams.set("redirect_to", redirectTo);
      urlAuth.searchParams.set("code_challenge", codeChallenge);
      urlAuth.searchParams.set("code_challenge_method", "s256");
      return responderJson(200, {
        transacao_id: criada.transacao_id,
        url_autorizacao: urlAuth.toString(),
        expira_em: criada.expira_em,
      });
    }

    if (fluxo === "pkce") {
      // Prova autoritativa do provedor da sessão atual: exige correspondência exata com a transação
      // server-side criada em iniciar_pkce (provedor + hash(S256(code_verifier))), de uso único.
      const challengeEsperado = await desafioPkceS256(codeVerifier);
      const challengeHash = await hashSha256Hex(challengeEsperado);
      const consumo = await db.consumirTransacaoOauth(transacaoId, provedor, challengeHash);
      if (!consumo.ok) {
        if (consumo.motivo === "desafio_ja_usado") return recusa(409, "desafio_ja_usado");
        if (consumo.motivo === "desafio_expirado") return recusa(410, "desafio_expirado");
        return recusa(401, "credenciais_invalidas");
      }
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
    const idTokenHash = fluxo === "id_token"
      ? await hashSha256Hex(`v1|id_token|${provedor}|${idToken}`)
      : null;

    const conclusao = await db.concluirLoginSocial(usuarioId, sessionId, provedor, idTokenHash);
    if (!conclusao.ok) {
      await revogarSessaoLocalGoTrue(supabaseUrl, anonKey, sessaoProvisoria.access_token, fetchFn);
      await db.revogarSessaoPontual(sessionId, usuarioId);
      if (conclusao.motivo === "token_ja_usado") return recusa(409, "token_ja_usado");
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
