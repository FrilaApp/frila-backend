// Edge Function excluir-conta (cartão OrS9gEfU).
//
// Obrigatória na App Store (5.1.1(v)).
// 1. Valida a confirmação explícita no corpo ({ confirmar: true }).
// 2. Valida o token JWT em auth/v1/user.
// 3. Executa a anonimização e cancelamento de turnos no Postgres via privado.excluir_conta(uuid).
// 4. Apaga a credencial em auth.users via Admin API com service_role.

import postgres from "npm:postgres@3.4.4";

export interface Erro {
  code: string;
  message: string;
  details: string | null;
}

export interface SqlClient {
  query: (userId: string) => Promise<{ dados: Record<string, unknown> }>;
}

export interface HandlerDeps {
  fetchFn?: typeof fetch;
  sqlClient?: SqlClient;
  supabaseUrl?: string;
  anonKey?: string;
  serviceRoleKey?: string;
  dbUrl?: string;
}

function resposta(status: number, corpo: unknown): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function obterVariavel(nome: string, injetada?: string): string {
  const valor = (injetada ?? Deno.env.get(nome))?.trim();
  if (!valor) {
    throw new Error(`${nome} é obrigatório e deve estar configurado no ambiente.`);
  }
  return valor;
}

export function tratarErroBanco(err: unknown): Response {
  const erroPg = err as { code?: string; message?: string; detail?: string };
  if (erroPg?.code === "PGRST" && erroPg.message) {
    try {
      const corpoErro = JSON.parse(erroPg.message) as Erro;
      let status = 400;
      if (erroPg.detail) {
        try {
          const detailObj = JSON.parse(erroPg.detail) as { status?: number };
          if (typeof detailObj.status === "number") {
            status = detailObj.status;
          }
        } catch {
          // Mantém 400 se o JSON do detail não contiver status numérico
        }
      }
      return resposta(status, corpoErro);
    } catch {
      return resposta(400, { code: erroPg.message, message: erroPg.message, details: null });
    }
  }
  return resposta(500, { code: "erro_interno", message: "erro_interno", details: null });
}

function criarSqlClient(deps?: HandlerDeps): SqlClient {
  if (deps?.sqlClient) {
    return deps.sqlClient;
  }
  const dbUrl = obterVariavel("SUPABASE_DB_URL", deps?.dbUrl);
  return {
    async query(id: string) {
      const sql = postgres(dbUrl, { max: 1, connect_timeout: 5 });
      try {
        const res = await sql`
          select privado.excluir_conta(${id}::uuid) as dados
        `;
        return { dados: (res[0]?.dados ?? {}) as Record<string, unknown> };
      } finally {
        await sql.end({ timeout: 2 });
      }
    },
  };
}

export async function handler(req: Request, deps?: HandlerDeps): Promise<Response> {
  if (req.method !== "POST") {
    return resposta(405, { code: "metodo_nao_permitido", message: "metodo_nao_permitido", details: null });
  }

  const autorizacao = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+$/i.test(autorizacao)) {
    return resposta(401, { code: "nao_autenticado", message: "nao_autenticado", details: null });
  }

  let corpo: { confirmar?: unknown };
  try {
    corpo = await req.json();
  } catch {
    return resposta(422, { code: "campo_obrigatorio", message: "campo_obrigatorio", details: "confirmar" });
  }
  if (corpo?.confirmar !== true) {
    return resposta(422, { code: "campo_obrigatorio", message: "campo_obrigatorio", details: "confirmar" });
  }

  const fetchFn = deps?.fetchFn ?? fetch;
  const origem = obterVariavel("SUPABASE_URL", deps?.supabaseUrl);
  const anon = obterVariavel("SUPABASE_ANON_KEY", deps?.anonKey);
  const serviceRole = obterVariavel("SUPABASE_SERVICE_ROLE_KEY", deps?.serviceRoleKey);
  const sqlClient = criarSqlClient(deps);

  // 1. Valida o token e obtém identidade do usuário no Supabase Auth
  const usuarioRes = await fetchFn(`${origem}/auth/v1/user`, {
    headers: {
      apikey: anon,
      Authorization: autorizacao,
      "Content-Type": "application/json",
    },
  });

  if (!usuarioRes.ok) {
    return resposta(401, { code: "nao_autenticado", message: "nao_autenticado", details: null });
  }

  const usuario = (await usuarioRes.json()) as { id?: unknown };
  if (typeof usuario.id !== "string") {
    return resposta(401, { code: "nao_autenticado", message: "nao_autenticado", details: null });
  }
  const userId = usuario.id;

  // 2. Executa privado.excluir_conta(userId) no banco através do cliente unificado
  let dadosExclusao: Record<string, unknown>;
  try {
    const res = await sqlClient.query(userId);
    dadosExclusao = res.dados;
  } catch (err: unknown) {
    return tratarErroBanco(err);
  }

  // 3. Remove credencial do auth.users via Admin API usando service_role
  const deleteRes = await fetchFn(`${origem}/auth/v1/admin/users/${encodeURIComponent(userId)}`, {
    method: "DELETE",
    headers: {
      apikey: serviceRole,
      Authorization: `Bearer ${serviceRole}`,
    },
  });

  if (!deleteRes.ok) {
    return resposta(502, { code: "erro_interno", message: "erro_interno", details: null });
  }

  return resposta(202, dadosExclusao);
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => {
    return await handler(req);
  });
}
