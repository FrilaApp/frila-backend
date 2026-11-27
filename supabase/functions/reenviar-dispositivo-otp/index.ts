// Edge Function: POST /functions/v1/reenviar-dispositivo-otp
//
// Reenvia o OTP de um desafio `login_dispositivo` ativo mantendo o mesmo `desafio_id`,
// sem incrementar o contador `tentativas` de verificação do código, com cooldown configurável
// em `privado.config_auth` (default seguro 60s, mínimo 30s), teto de 3 reenvios por desafio
// e rate limits por IP/e-mail.

import postgres from "npm:postgres@3.4.4";
import { comCors } from "../_compartilhado/cors.ts";
import {
  hashSha256Hex,
  type OpcoesIpVisitante,
  recusa,
  resolverIpParaRateLimit,
  responderJson,
} from "../_compartilhado/dispositivo_auth.ts";

export interface ReenviarDesafioDb {
  consumirRateLimit(chave: string, limite: number, janelaSegundos: number): Promise<boolean>;
  reservarReenvioDesafio(desafioId: string): Promise<{
    status: "ok" | "desafio_expirado" | "desafio_ja_usado" | "limite_excedido";
    desafio_id?: string;
    email_normalizado?: string;
    email_hash?: string;
    expira_em?: string;
    cooldown_segundos?: number;
  }>;
}

export interface ReenviarDesafioDeps {
  fetchFn?: typeof fetch;
  supabaseUrl?: string;
  anonKey?: string;
  dbUrl?: string;
  opcoesIp?: OpcoesIpVisitante;
  db?: ReenviarDesafioDb;
}

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function criarDbSql(dbUrl: string): ReenviarDesafioDb & { fechar(): Promise<void> } {
  const sql = postgres(dbUrl, { max: 1, connect_timeout: 5, idle_timeout: 10 });
  return {
    async consumirRateLimit(chave, limite, janelaSegundos) {
      const [row] = await sql`select privado.consumir_rate_limit_auth(${chave}, ${limite}, ${janelaSegundos}) as permitido`;
      return Boolean(row?.permitido);
    },
    async reservarReenvioDesafio(desafioId) {
      const [row] = await sql`select privado.reservar_reenvio_desafio(${desafioId}::uuid) as res`;
      return row.res;
    },
    async fechar() {
      await sql.end({ timeout: 2 }).catch(() => {});
    },
  };
}

export async function tratarReenviarDispositivoOtp(
  req: Request,
  deps: ReenviarDesafioDeps = {},
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

  const desafioId = typeof corpo.desafio_id === "string" ? corpo.desafio_id.trim() : "";
  if (!UUID_REGEX.test(desafioId)) {
    return recusa(422, "campo_invalido", "desafio_id");
  }

  const fetchFn = deps.fetchFn ?? fetch;
  const supabaseUrl = (deps.supabaseUrl ?? Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
  const anonKey = deps.anonKey ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const dbUrl = deps.dbUrl ?? Deno.env.get("SUPABASE_DB_URL") ?? "";

  if (!supabaseUrl || !anonKey || (!deps.db && !dbUrl)) {
    return recusa(503, "indisponivel");
  }

  const sqlDb = deps.db ? null : criarDbSql(dbUrl);
  const db: ReenviarDesafioDb = deps.db ?? sqlDb!;

  try {
    // Em reenviar-dispositivo-otp o payload traz apenas desafio_id (sem plataforma):
    // - Se vier do Worker Web (com cabeçalhos B-116), valida HMAC fail-closed (503 sem chaves, 403 se inválido).
    // - Se vier direto de navegador (Origin sem B-116), recusa fail-closed (403).
    // - Se vier direto do app mobile (sem Origin e sem B-116), aplica rate limit por cf-connecting-ip.
    const resultadoIp = await resolverIpParaRateLimit(req, null, deps.opcoesIp);
    if (!resultadoIp.ok) return recusa(resultadoIp.status, resultadoIp.code);

    if (resultadoIp.ip) {
      const ipHash = await hashSha256Hex(resultadoIp.ip);
      const okIp = await db.consumirRateLimit(`auth:reenvio:ip:${ipHash}`, 15, 600);
      if (!okIp) return recusa(429, "limite_excedido");
    }

    const reserva = await db.reservarReenvioDesafio(desafioId);
    if (reserva.status === "desafio_expirado") return recusa(410, "desafio_expirado");
    if (reserva.status === "desafio_ja_usado") return recusa(409, "desafio_ja_usado");
    if (reserva.status === "limite_excedido") return recusa(429, "limite_excedido");
    if (!reserva.email_normalizado || !reserva.email_hash || !reserva.expira_em) {
      return recusa(410, "desafio_expirado");
    }

    const okEmail = await db.consumirRateLimit(`auth:otp:email:${reserva.email_hash}`, 5, 600);
    if (!okEmail) return recusa(429, "limite_excedido");

    const resOtp = await fetchFn(`${supabaseUrl}/auth/v1/otp`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": anonKey,
      },
      body: JSON.stringify({ email: reserva.email_normalizado, create_user: false }),
    });

    if (resOtp.status === 429) return recusa(429, "limite_excedido");
    if (!resOtp.ok) return recusa(503, "indisponivel");

    const cooldownEfetivo =
      typeof reserva.cooldown_segundos === "number" &&
        Number.isInteger(reserva.cooldown_segundos) &&
        reserva.cooldown_segundos >= 30 &&
        reserva.cooldown_segundos <= 300
        ? reserva.cooldown_segundos
        : 60;

    return responderJson(200, {
      ok: true,
      desafio_id: reserva.desafio_id ?? desafioId,
      expira_em: reserva.expira_em,
      reenviar_em_segundos: cooldownEfetivo,
    });
  } finally {
    await sqlDb?.fechar();
  }
}

if (import.meta.main) {
  Deno.serve((req) => comCors(req, undefined, () => tratarReenviarDispositivoOtp(req)));
}
