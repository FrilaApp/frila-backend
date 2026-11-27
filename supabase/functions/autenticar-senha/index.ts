// Edge Function: POST /functions/v1/autenticar-senha
//
// Login habitual por senha com verificação server-side de dispositivo confiável (30 dias).
// - Valida credenciais no GoTrue; qualquer 4xx de credencial vira `401 credenciais_invalidas` (anti-enumeração).
// - Se `device_token` for válido no relógio do Postgres (`expira_em > now()` e `revogado_em IS NULL` para o mesmo `usuario_id`),
//   registra `session_id` em `privado.sessoes_verificadas`, renova o JWT via `grant_type=refresh_token` para o
//   `custom_access_token_hook` emitir `dispositivo_verificado = true` e devolve `{ status: "autenticado", sessao, ... }`.
// - Caso contrário, revoga APENAS a sessão provisória (`scope=local` + fallback pontual por `session_id`),
//   cria desafio de 10 minutos em `privado.desafios_dispositivo` (persistindo `email_normalizado` server-side),
//   dispara OTP com `create_user: false` e devolve `{ status: "desafio_otp", desafio_id, expira_em, descartar_device_token }`.

import postgres from "npm:postgres@3.4.4";
import { comCors } from "../_compartilhado/cors.ts";
import {
  ehPlataformaValida,
  extrairSessionIdDoJwt,
  hashSha256Hex,
  hashTokenDispositivo,
  normalizarEmail,
  type OpcoesIpVisitante,
  type PlataformaAuth,
  recusa,
  renovarSessaoGoTrue,
  resolverIpParaRateLimit,
  responderJson,
  revogarSessaoLocalGoTrue,
  validarSessaoGoTrue,
} from "../_compartilhado/dispositivo_auth.ts";

export interface AutenticarSenhaDb {
  consumirRateLimit(chave: string, limite: number, janelaSegundos: number): Promise<boolean>;
  validarEMarcarDispositivo(usuarioId: string, sessionId: string | null, tokenHash: string): Promise<{
    valido: boolean;
    expira_em?: string;
    precisa_definir_senha?: boolean;
  }>;
  criarDesafio(usuarioId: string, email: string, emailHash: string, plataforma: PlataformaAuth): Promise<{
    desafio_id: string;
    expira_em: string;
    cooldown_segundos?: number;
  }>;
  revogarSessaoPontual(sessionId: string | null, usuarioId: string): Promise<void>;
}

export interface AutenticarSenhaDeps {
  fetchFn?: typeof fetch;
  supabaseUrl?: string;
  anonKey?: string;
  dbUrl?: string;
  pepper?: string;
  origensCors?: string;
  opcoesIp?: OpcoesIpVisitante;
  db?: AutenticarSenhaDb;
}

function criarDbSql(dbUrl: string): AutenticarSenhaDb & { fechar(): Promise<void> } {
  const sql = postgres(dbUrl, { max: 1, connect_timeout: 5, idle_timeout: 10 });
  return {
    async consumirRateLimit(chave, limite, janelaSegundos) {
      const [row] = await sql`select privado.consumir_rate_limit_auth(${chave}, ${limite}, ${janelaSegundos}) as permitido`;
      return Boolean(row?.permitido);
    },
    async validarEMarcarDispositivo(usuarioId, sessionId, tokenHash) {
      const [row] = await sql`select privado.validar_e_marcar_dispositivo(${usuarioId}::uuid, ${sessionId}::uuid, ${tokenHash}) as res`;
      return (row?.res ?? { valido: false }) as { valido: boolean; expira_em?: string; precisa_definir_senha?: boolean };
    },
    async criarDesafio(usuarioId, email, emailHash, plataforma) {
      const [row] = await sql`select privado.criar_desafio_dispositivo(${usuarioId}::uuid, ${email}, ${emailHash}, ${plataforma}) as res`;
      return row.res as { desafio_id: string; expira_em: string; cooldown_segundos?: number };
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

export async function tratarAutenticarSenha(req: Request, deps: AutenticarSenhaDeps = {}): Promise<Response> {
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

  const email = normalizarEmail(corpo.email);
  if (!email) return recusa(422, "campo_invalido", "email");

  const senha = typeof corpo.senha === "string" ? corpo.senha : "";
  if (!senha) return recusa(422, "campo_obrigatorio", "senha");

  if (!ehPlataformaValida(corpo.plataforma)) {
    return recusa(422, "campo_invalido", "plataforma");
  }
  const plataforma = corpo.plataforma;

  const deviceToken = typeof corpo.device_token === "string" && corpo.device_token.trim().length > 0
    ? corpo.device_token.trim()
    : null;

  const fetchFn = deps.fetchFn ?? fetch;
  const supabaseUrl = (deps.supabaseUrl ?? Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
  const anonKey = deps.anonKey ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const pepper = deps.pepper ?? Deno.env.get("DISPOSITIVO_TOKEN_PEPPER") ?? "";
  const dbUrl = deps.dbUrl ?? Deno.env.get("SUPABASE_DB_URL") ?? "";

  if (!supabaseUrl || !anonKey || (!deps.db && !dbUrl)) {
    return recusa(503, "indisponivel");
  }
  // Fail-closed: nunca degradar silenciosamente validação de device_token sem pepper configurado.
  if (deviceToken && !pepper) {
    return recusa(503, "indisponivel");
  }

  const sqlDb = deps.db ? null : criarDbSql(dbUrl);
  const db: AutenticarSenhaDb = deps.db ?? sqlDb!;

  try {
    const resultadoIp = await resolverIpParaRateLimit(req, plataforma, deps.opcoesIp);
    if (!resultadoIp.ok) return recusa(resultadoIp.status, resultadoIp.code);

    const emailHash = await hashSha256Hex(email);

    const okEmail = await db.consumirRateLimit(`auth:senha:email:${emailHash}`, 10, 600);
    if (!okEmail) return recusa(429, "limite_excedido");

    if (resultadoIp.ip) {
      const ipHash = await hashSha256Hex(resultadoIp.ip);
      const okIp = await db.consumirRateLimit(`auth:senha:ip:${ipHash}`, 20, 600);
      if (!okIp) return recusa(429, "limite_excedido");
    }

    const resAuth = await fetchFn(`${supabaseUrl}/auth/v1/token?grant_type=password`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": anonKey,
      },
      body: JSON.stringify({ email, password: senha }),
    });

    if (resAuth.status === 429) return recusa(429, "limite_excedido");
    if (resAuth.status >= 500) return recusa(503, "indisponivel");
    if (!resAuth.ok) {
      // Anti-enumeração: resposta estritamente neutra para e-mail inexistente, senha errada ou conta OTP-only/social.
      return recusa(401, "credenciais_invalidas");
    }

    const sessaoProvisoria = validarSessaoGoTrue(await resAuth.json().catch(() => null));
    if (!sessaoProvisoria) return recusa(503, "indisponivel");

    const usuarioId = sessaoProvisoria.user.id;
    const sessionId = extrairSessionIdDoJwt(sessaoProvisoria.access_token);

    if (deviceToken && pepper) {
      const tokenHash = await hashTokenDispositivo(deviceToken, pepper);
      const validacao = await db.validarEMarcarDispositivo(usuarioId, sessionId, tokenHash);
      if (validacao.valido) {
        // Obriga refresh_token grant para que o custom_access_token_hook emita o JWT final
        // com app_metadata.dispositivo_verificado = true após o registro em sessoes_verificadas.
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
          status: "autenticado",
          sessao: sessaoFinal,
          precisa_definir_senha: Boolean(validacao.precisa_definir_senha),
          dispositivo_expira_em: validacao.expira_em ?? null,
        });
      }
    }

    // Dispositivo ausente, novo, de outra conta, revogado ou vencido:
    // 1. Revoga SOMENTE a sessão provisória (scope=local + fallback pontual), preservando outros aparelhos.
    const revogouHttp = await revogarSessaoLocalGoTrue(supabaseUrl, anonKey, sessaoProvisoria.access_token, fetchFn);
    if (!revogouHttp) {
      await db.revogarSessaoPontual(sessionId, usuarioId);
    }

    // 2. Rate limit específico de disparo de OTP por e-mail.
    const okOtp = await db.consumirRateLimit(`auth:otp:email:${emailHash}`, 5, 600);
    if (!okOtp) return recusa(429, "limite_excedido");

    // 3. Dispara OTP por e-mail com create_user: false.
    const resOtp = await fetchFn(`${supabaseUrl}/auth/v1/otp`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": anonKey,
      },
      body: JSON.stringify({ email, create_user: false }),
    });
    if (resOtp.status === 429) return recusa(429, "limite_excedido");
    if (!resOtp.ok) return recusa(503, "indisponivel");

    // 4. Cria desafio de curta duração (10 min) persistindo email_normalizado no servidor.
    const desafio = await db.criarDesafio(usuarioId, email, emailHash, plataforma);
    const reenviarEmSegundos = desafio.cooldown_segundos === 30 || desafio.cooldown_segundos === 60
      ? desafio.cooldown_segundos
      : 60;

    return responderJson(200, {
      status: "desafio_otp",
      desafio_id: desafio.desafio_id,
      expira_em: desafio.expira_em,
      descartar_device_token: deviceToken !== null,
      reenviar_em_segundos: reenviarEmSegundos,
    });
  } finally {
    await sqlDb?.fechar();
  }
}

if (import.meta.main) {
  Deno.serve((req) => comCors(req, undefined, () => tratarAutenticarSenha(req)));
}
