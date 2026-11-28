// Edge Function: POST /functions/v1/definir-senha
//
// Define ou altera a senha na sessão ativa (via PUT /auth/v1/user), limpa a trava server-authoritative
// `privado.contas_senha_pendente` e revoga dispositivos confiáveis / outras sessões ativas.

import postgres from "npm:postgres@3.4.4";
import { extrairBearerToken } from "../_compartilhado/auth.ts";
import { comCors } from "../_compartilhado/cors.ts";
import {
  extrairSessionIdDoJwt,
  hashTokenDispositivo,
  recusa,
  renovarSessaoGoTrue,
  responderJson,
} from "../_compartilhado/dispositivo_auth.ts";

export interface DefinirSenhaDb {
  verificarSessaoOnline(usuarioId: string, sessionId: string | null): Promise<boolean>;
  concluirDefinicaoSenha(
    usuarioId: string,
    sessionId: string | null,
    manterTokenHash: string | null,
  ): Promise<{ dispositivos_revogados: number }>;
}

export interface DefinirSenhaDeps {
  fetchFn?: typeof fetch;
  supabaseUrl?: string;
  anonKey?: string;
  dbUrl?: string;
  pepper?: string;
  db?: DefinirSenhaDb;
}

function criarDbSql(dbUrl: string): DefinirSenhaDb & { fechar(): Promise<void> } {
  const sql = postgres(dbUrl, { max: 1, connect_timeout: 5, idle_timeout: 10 });
  return {
    async verificarSessaoOnline(usuarioId, sessionId) {
      const [row] = await sql`
        select privado.verificar_sessao_dispositivo_online(${usuarioId}::uuid, ${sessionId}::uuid) as permitido
      `;
      return Boolean(row?.permitido);
    },
    async concluirDefinicaoSenha(usuarioId, sessionId, manterTokenHash) {
      const [row] = await sql`
        select privado.concluir_definicao_senha(
          ${usuarioId}::uuid,
          ${sessionId}::uuid,
          ${manterTokenHash}
        ) as res
      `;
      return { dispositivos_revogados: Number(row?.res?.dispositivos_revogados ?? 0) };
    },
    async fechar() {
      await sql.end({ timeout: 2 }).catch(() => {});
    },
  };
}

export async function tratarDefinirSenha(req: Request, deps: DefinirSenhaDeps = {}): Promise<Response> {
  if (req.method !== "POST") return recusa(405, "metodo_nao_permitido");

  const accessToken = extrairBearerToken(req.headers.get("Authorization"));
  if (!accessToken) return recusa(401, "nao_autenticado");

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

  // Contrato: `nova_senha` é obrigatória (`campo_obrigatorio`); presente e com menos de 8 caracteres é `senha_fraca`.
  if (corpo.nova_senha === undefined || corpo.nova_senha === null) {
    return recusa(422, "campo_obrigatorio", "nova_senha");
  }
  // `nova_senha` é `type: string` no contrato: número, lista, booleano e objeto são `campo_invalido`, não `senha_fraca`.
  if (typeof corpo.nova_senha !== "string") {
    return recusa(422, "campo_invalido", "nova_senha");
  }
  const novaSenha = corpo.nova_senha;
  if (novaSenha.length < 8) {
    return recusa(422, "senha_fraca", "nova_senha");
  }

  const manterDispositivoAtual = corpo.manter_dispositivo_atual === true;
  const deviceTokenAtual = typeof corpo.device_token_atual === "string" && corpo.device_token_atual.trim().length > 0
    ? corpo.device_token_atual.trim()
    : null;
  const refreshToken = typeof corpo.refresh_token === "string" && corpo.refresh_token.trim().length > 0
    ? corpo.refresh_token.trim()
    : null;

  const fetchFn = deps.fetchFn ?? fetch;
  const supabaseUrl = (deps.supabaseUrl ?? Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
  const anonKey = deps.anonKey ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const pepper = deps.pepper ?? Deno.env.get("DISPOSITIVO_TOKEN_PEPPER") ?? "";
  const dbUrl = deps.dbUrl ?? Deno.env.get("SUPABASE_DB_URL") ?? "";

  if (!supabaseUrl || !anonKey || (!deps.db && !dbUrl)) {
    return recusa(503, "indisponivel");
  }
  // Fail-closed: manter_dispositivo_atual sem DISPOSITIVO_TOKEN_PEPPER nunca degrada para revogar o token atual.
  if (manterDispositivoAtual && !pepper) {
    return recusa(503, "indisponivel");
  }

  // Confirma identidade e guarda online de dispositivo_verificado ANTES de alterar senha no GoTrue.
  // Falha de rede (ou timeout) aqui responde como o 5xx logo abaixo: 503 indisponivel, sem lançar.
  let resUser: Response;
  try {
    resUser = await fetchFn(`${supabaseUrl}/auth/v1/user`, {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "apikey": anonKey,
      },
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
  const db: DefinirSenhaDb = deps.db ?? sqlDb!;

  try {
    const sessaoOk = await db.verificarSessaoOnline(user.id, sessionId);
    if (!sessaoOk) {
      return recusa(401, "dispositivo_nao_verificado");
    }

    const resPut = await fetchFn(`${supabaseUrl}/auth/v1/user`, {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${accessToken}`,
        "apikey": anonKey,
      },
      body: JSON.stringify({ password: novaSenha }),
    });

    if (resPut.status === 429) return recusa(429, "limite_excedido");
    if (resPut.status >= 500) return recusa(503, "indisponivel");

    const bodyPut = await resPut.json().catch(() => ({})) as Record<string, unknown>;
    if (!resPut.ok) {
      const code = String(bodyPut.error_code ?? bodyPut.code ?? "").toLowerCase();
      if (code === "reauthentication_needed") return recusa(401, "reautenticacao_necessaria");
      if (resPut.status === 401 || resPut.status === 403) return recusa(401, "nao_autenticado");
      if (code === "same_password") return recusa(422, "senha_igual", "nova_senha");
      if (code === "weak_password") return recusa(422, "senha_fraca", "nova_senha");
      return recusa(422, "campo_invalido", "nova_senha");
    }

    const manterTokenHash = manterDispositivoAtual && deviceTokenAtual && pepper
      ? await hashTokenDispositivo(deviceTokenAtual, pepper)
      : null;

    const resDb = await db.concluirDefinicaoSenha(user.id, sessionId, manterTokenHash);

    // Opcionalmente renova a sessão para já entregar o JWT com precisa_definir_senha = false.
    const sessaoRenovada = refreshToken
      ? await renovarSessaoGoTrue(supabaseUrl, anonKey, refreshToken, fetchFn)
      : null;

    return responderJson(200, {
      ok: true,
      precisa_definir_senha: false,
      dispositivos_revogados: resDb.dispositivos_revogados,
      sessao: sessaoRenovada,
    });
  } finally {
    await sqlDb?.fechar();
  }
}

if (import.meta.main) {
  Deno.serve((req) => comCors(req, undefined, () => tratarDefinirSenha(req)));
}
