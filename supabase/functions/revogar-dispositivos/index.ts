// Edge Function: POST /functions/v1/revogar-dispositivos
//
// Ação explícita "Sair de todos os dispositivos" (perda/roubo de aparelho):
// revoga todos os `dispositivos_confiaveis`, limpa `sessoes_verificadas` e encerra todas as sessões no GoTrue (`scope=global`).

import postgres from "npm:postgres@3.4.4";
import { extrairBearerToken } from "../_compartilhado/auth.ts";
import { comCors } from "../_compartilhado/cors.ts";
import { extrairSessionIdDoJwt, recusa, responderJson, TIMEOUT_AUTH_MS } from "../_compartilhado/dispositivo_auth.ts";

export interface RevogarDispositivosDb {
  verificarSessaoOnline(usuarioId: string, sessionId: string | null): Promise<boolean>;
  revogarTodosDispositivos(usuarioId: string): Promise<number>;
}

export interface RevogarDispositivosDeps {
  fetchFn?: typeof fetch;
  supabaseUrl?: string;
  anonKey?: string;
  dbUrl?: string;
  db?: RevogarDispositivosDb;
  /** Prazo da chamada a `/auth/v1/user`; padrão `TIMEOUT_AUTH_MS`. */
  timeoutMs?: number;
}

function criarDbSql(dbUrl: string): RevogarDispositivosDb & { fechar(): Promise<void> } {
  const sql = postgres(dbUrl, { max: 1, connect_timeout: 5, idle_timeout: 10 });
  return {
    async verificarSessaoOnline(usuarioId, sessionId) {
      const [row] = await sql`
        select privado.verificar_sessao_dispositivo_online(${usuarioId}::uuid, ${sessionId}::uuid) as permitido
      `;
      return Boolean(row?.permitido);
    },
    async revogarTodosDispositivos(usuarioId) {
      const [row] = await sql`select privado.revogar_todos_dispositivos(${usuarioId}::uuid) as revogados`;
      return Number(row?.revogados ?? 0);
    },
    async fechar() {
      await sql.end({ timeout: 2 }).catch(() => {});
    },
  };
}

export async function tratarRevogarDispositivos(
  req: Request,
  deps: RevogarDispositivosDeps = {},
): Promise<Response> {
  if (req.method !== "POST") return recusa(405, "metodo_nao_permitido");

  const accessToken = extrairBearerToken(req.headers.get("Authorization"));
  if (!accessToken) return recusa(401, "nao_autenticado");

  const fetchFn = deps.fetchFn ?? fetch;
  const timeoutMs = deps.timeoutMs ?? TIMEOUT_AUTH_MS;
  const supabaseUrl = (deps.supabaseUrl ?? Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
  const anonKey = deps.anonKey ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const dbUrl = deps.dbUrl ?? Deno.env.get("SUPABASE_DB_URL") ?? "";

  if (!supabaseUrl || !anonKey || (!deps.db && !dbUrl)) {
    return recusa(503, "indisponivel");
  }

  // Confirma identidade do titular direto no GoTrue.
  // Falha de rede (ou timeout) aqui responde como o 5xx logo abaixo: 503 indisponivel, sem lançar.
  let resUser: Response;
  try {
    resUser = await fetchFn(`${supabaseUrl}/auth/v1/user`, {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "apikey": anonKey,
      },
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    return recusa(503, "indisponivel");
  }

  if (resUser.status === 429) return recusa(429, "limite_excedido");
  if (resUser.status >= 500) return recusa(503, "indisponivel");
  if (!resUser.ok) return recusa(401, "nao_autenticado");

  const user = await resUser.json().catch(() => null) as { id?: string } | null;
  if (!user?.id) return recusa(401, "nao_autenticado");

  const sessionId = extrairSessionIdDoJwt(accessToken);
  const sqlDb = deps.db ? null : criarDbSql(dbUrl);
  const db: RevogarDispositivosDb = deps.db ?? sqlDb!;

  try {
    const sessaoOk = await db.verificarSessaoOnline(user.id, sessionId);
    if (!sessaoOk) {
      return recusa(401, "dispositivo_nao_verificado");
    }

    const revogados = await db.revogarTodosDispositivos(user.id);

    // Revogação global no GoTrue (melhor esforço: auth.sessions já foi limpo no Postgres).
    await fetchFn(`${supabaseUrl}/auth/v1/logout?scope=global`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "apikey": anonKey,
      },
    }).catch(() => {});

    return responderJson(200, {
      ok: true,
      dispositivos_revogados: revogados,
    });
  } finally {
    await sqlDb?.fechar();
  }
}

if (import.meta.main) {
  Deno.serve((req) => comCors(req, undefined, () => tratarRevogarDispositivos(req)));
}
