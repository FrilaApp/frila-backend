// Edge Function: POST /functions/v1/confirmar-dispositivo-otp
//
// Confirma o código OTP de 6 dígitos (desafio de login em novo dispositivo/vencido, cadastro ou recuperação)
// e, mediante opt-in explícito `lembrar_dispositivo: true`, emite token opaco de 32 bytes válido por 30 dias
// no relógio do Postgres (armazenado somente como HMAC-SHA256 com pepper).

import postgres from "npm:postgres@3.4.4";
import { comCors } from "../_compartilhado/cors.ts";
import {
  ehPlataformaValida,
  extrairSessionIdDoJwt,
  gerarTokenOpaco,
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

export type TipoConfirmacaoOtp = "login_dispositivo" | "cadastro" | "recuperacao";

export interface ConfirmarDispositivoDb {
  consumirRateLimit(chave: string, limite: number, janelaSegundos: number): Promise<boolean>;
  reservarTentativaDesafio(desafioId: string): Promise<{
    status: "ok" | "desafio_expirado" | "desafio_ja_usado" | "limite_excedido";
    usuario_id?: string;
    email_normalizado?: string;
    plataforma?: PlataformaAuth;
  }>;
  concluirDesafioERegistrarSessao(params: {
    desafioId: string | null;
    usuarioId: string;
    sessionId: string | null;
    plataforma: PlataformaAuth;
    tokenHash: string | null;
    marcarSenhaPendente: "cadastro" | "recuperacao" | null;
  }): Promise<{
    ok: boolean;
    motivo?: string;
    dispositivo_expira_em?: string | null;
    precisa_definir_senha?: boolean;
  }>;
  revogarSessaoPontual(sessionId: string | null, usuarioId: string): Promise<void>;
}

export interface ConfirmarDispositivoDeps {
  fetchFn?: typeof fetch;
  supabaseUrl?: string;
  anonKey?: string;
  dbUrl?: string;
  pepper?: string;
  gerarToken?: () => string;
  opcoesIp?: OpcoesIpVisitante;
  db?: ConfirmarDispositivoDb;
}

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CODIGO_OTP_REGEX = /^\d{6}$/;

function criarDbSql(dbUrl: string): ConfirmarDispositivoDb & { fechar(): Promise<void> } {
  const sql = postgres(dbUrl, { max: 1, connect_timeout: 5, idle_timeout: 10 });
  return {
    async consumirRateLimit(chave, limite, janelaSegundos) {
      const [row] = await sql`select privado.consumir_rate_limit_auth(${chave}, ${limite}, ${janelaSegundos}) as permitido`;
      return Boolean(row?.permitido);
    },
    async reservarTentativaDesafio(desafioId) {
      const [row] = await sql`select privado.reservar_tentativa_desafio(${desafioId}::uuid) as res`;
      return row.res;
    },
    async concluirDesafioERegistrarSessao(p) {
      const [row] = await sql`
        select privado.concluir_desafio_e_registrar_sessao(
          ${p.desafioId}::uuid,
          ${p.usuarioId}::uuid,
          ${p.sessionId}::uuid,
          ${p.plataforma},
          ${p.tokenHash},
          ${p.marcarSenhaPendente}
        ) as res
      `;
      return row.res;
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

export async function tratarConfirmarDispositivoOtp(
  req: Request,
  deps: ConfirmarDispositivoDeps = {},
): Promise<Response> {
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

  const tipo = corpo.tipo;
  if (tipo !== "login_dispositivo" && tipo !== "cadastro" && tipo !== "recuperacao") {
    return recusa(422, "campo_invalido", "tipo");
  }

  const codigo = typeof corpo.codigo === "string" ? corpo.codigo.trim() : "";
  if (!CODIGO_OTP_REGEX.test(codigo)) {
    return recusa(422, "campo_invalido", "codigo");
  }

  if (!ehPlataformaValida(corpo.plataforma)) {
    return recusa(422, "campo_invalido", "plataforma");
  }
  const plataforma = corpo.plataforma;

  const lembrarDispositivo = corpo.lembrar_dispositivo === true;

  let desafioId: string | null = null;
  let emailInformado: string | null = null;

  if (tipo === "login_dispositivo") {
    const rawId = typeof corpo.desafio_id === "string" ? corpo.desafio_id.trim() : "";
    if (!UUID_REGEX.test(rawId)) return recusa(422, "campo_invalido", "desafio_id");
    desafioId = rawId;
  } else {
    emailInformado = normalizarEmail(corpo.email);
    if (!emailInformado) return recusa(422, "campo_invalido", "email");
  }

  const fetchFn = deps.fetchFn ?? fetch;
  const supabaseUrl = (deps.supabaseUrl ?? Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
  const anonKey = deps.anonKey ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const pepper = deps.pepper ?? Deno.env.get("DISPOSITIVO_TOKEN_PEPPER") ?? "";
  const dbUrl = deps.dbUrl ?? Deno.env.get("SUPABASE_DB_URL") ?? "";

  if (!supabaseUrl || !anonKey || (!deps.db && !dbUrl)) {
    return recusa(503, "indisponivel");
  }
  if (lembrarDispositivo && !pepper) {
    return recusa(503, "indisponivel");
  }

  const sqlDb = deps.db ? null : criarDbSql(dbUrl);
  const db: ConfirmarDispositivoDb = deps.db ?? sqlDb!;

  try {
    const resultadoIp = await resolverIpParaRateLimit(req, plataforma, deps.opcoesIp);
    if (!resultadoIp.ok) return recusa(resultadoIp.status, resultadoIp.code);

    // Sempre aplica rate limit por email_hash em cadastro/recuperação (independente de IP).
    if (emailInformado) {
      const emailHash = await hashSha256Hex(emailInformado);
      const okEmail = await db.consumirRateLimit(`auth:verify:email:${emailHash}`, 10, 600);
      if (!okEmail) return recusa(429, "limite_excedido");
    }

    if (resultadoIp.ip) {
      const ipHash = await hashSha256Hex(resultadoIp.ip);
      const okIp = await db.consumirRateLimit(`auth:verify:ip:${ipHash}`, 25, 600);
      if (!okIp) return recusa(429, "limite_excedido");
    }

    let emailParaVerify: string;
    let usuarioEsperadoId: string | null = null;

    if (tipo === "login_dispositivo" && desafioId) {
      const reserva = await db.reservarTentativaDesafio(desafioId);
      if (reserva.status === "desafio_expirado") return recusa(410, "desafio_expirado");
      if (reserva.status === "desafio_ja_usado") return recusa(409, "desafio_ja_usado");
      if (reserva.status === "limite_excedido") return recusa(429, "limite_excedido");
      if (!reserva.email_normalizado || !reserva.usuario_id) return recusa(410, "desafio_expirado");
      emailParaVerify = reserva.email_normalizado;
      usuarioEsperadoId = reserva.usuario_id;
    } else {
      emailParaVerify = emailInformado!;
    }

    // Valida OTP via GoTrue /auth/v1/verify (nunca ecoa o e-mail resolvido em erros).
    const resVerify = await fetchFn(`${supabaseUrl}/auth/v1/verify`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": anonKey,
      },
      body: JSON.stringify({
        email: emailParaVerify,
        token: codigo,
        type: "email",
      }),
    });

    if (resVerify.status === 429) return recusa(429, "limite_excedido");
    if (resVerify.status >= 500) return recusa(503, "indisponivel");
    if (!resVerify.ok) return recusa(401, "codigo_invalido");

    const sessaoInicial = validarSessaoGoTrue(await resVerify.json().catch(() => null));
    if (!sessaoInicial) return recusa(503, "indisponivel");

    const usuarioId = sessaoInicial.user.id;
    const sessionId = extrairSessionIdDoJwt(sessaoInicial.access_token);

    if (usuarioEsperadoId && usuarioId !== usuarioEsperadoId) {
      await revogarSessaoLocalGoTrue(supabaseUrl, anonKey, sessaoInicial.access_token, fetchFn);
      await db.revogarSessaoPontual(sessionId, usuarioId);
      return recusa(401, "codigo_invalido");
    }

    const deviceToken = lembrarDispositivo ? (deps.gerarToken ?? gerarTokenOpaco)() : null;
    const tokenHash = deviceToken ? await hashTokenDispositivo(deviceToken, pepper) : null;
    const marcarSenhaPendente = tipo === "cadastro" || tipo === "recuperacao" ? tipo : null;

    const conclusao = await db.concluirDesafioERegistrarSessao({
      desafioId,
      usuarioId,
      sessionId,
      plataforma,
      tokenHash,
      marcarSenhaPendente,
    });

    if (!conclusao.ok) {
      // Concorrência / replay detectado atomicamente no Postgres: descarta a sessão recém-criada.
      await revogarSessaoLocalGoTrue(supabaseUrl, anonKey, sessaoInicial.access_token, fetchFn);
      await db.revogarSessaoPontual(sessionId, usuarioId);
      return recusa(409, "desafio_ja_usado");
    }

    // Obriga refresh_token grant para que o custom_access_token_hook emita o JWT final
    // com dispositivo_verificado = true e precisa_definir_senha atualizado.
    const sessaoFinal = await renovarSessaoGoTrue(
      supabaseUrl,
      anonKey,
      sessaoInicial.refresh_token,
      fetchFn,
    );
    if (!sessaoFinal) {
      await revogarSessaoLocalGoTrue(supabaseUrl, anonKey, sessaoInicial.access_token, fetchFn);
      await db.revogarSessaoPontual(sessionId, usuarioId);
      return recusa(503, "indisponivel");
    }

    return responderJson(200, {
      sessao: sessaoFinal,
      precisa_definir_senha: Boolean(conclusao.precisa_definir_senha),
      device_token: deviceToken,
      dispositivo_expira_em: conclusao.dispositivo_expira_em ?? null,
    });
  } finally {
    await sqlDb?.fechar();
  }
}

if (import.meta.main) {
  Deno.serve((req) => comCors(req, undefined, () => tratarConfirmarDispositivoOtp(req)));
}
