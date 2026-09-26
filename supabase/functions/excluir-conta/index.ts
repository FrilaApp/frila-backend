// Edge Function excluir-conta (cartão OrS9gEfU).
//
// Obrigatória na App Store (5.1.1(v)).
// 1. Valida a confirmação explícita no corpo ({ confirmar: true }).
// 2. Valida o token JWT em auth/v1/user.
// 3. Executa a anonimização e cancelamento de turnos no Postgres via privado.excluir_conta(uuid).
// 4. Apaga a credencial em auth.users via Admin API com service_role.

import postgres from "npm:postgres@3.4.4";

type Erro = {
  code: string;
  message: string;
  details: string | null;
};

export interface HandlerDeps {
  fetchFn?: typeof fetch;
  sqlClient?: {
    query: (userId: string) => Promise<{ dados: Record<string, unknown> }>;
  };
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

  // 2. Executa privado.excluir_conta(userId) no banco
  let dadosExclusao: Record<string, unknown>;
  if (deps?.sqlClient) {
    try {
      const res = await deps.sqlClient.query(userId);
      dadosExclusao = res.dados;
    } catch (err: unknown) {
      const erroPg = err as { code?: string; message?: string; detail?: string };
      if (erroPg.code === "PGRST" && erroPg.message) {
        try {
          const corpoErro = JSON.parse(erroPg.message) as Erro;
          const status = erroPg.detail ? (JSON.parse(erroPg.detail) as { status?: number }).status ?? 400 : 400;
          return resposta(status, corpoErro);
        } catch {
          return resposta(400, { code: erroPg.message, message: erroPg.message, details: null });
        }
      }
      return resposta(500, { code: "erro_interno", message: "erro_interno", details: null });
    }
  } else {
    const dbUrl = deps?.dbUrl ?? (Deno.env.get("SUPABASE_DB_URL") || Deno.env.get("DATABASE_URL"))?.trim();
    if (!dbUrl) {
      throw new Error("SUPABASE_DB_URL ou DATABASE_URL é obrigatório e deve estar configurado no ambiente.");
    }

    const sql = postgres(dbUrl, { max: 1, connect_timeout: 5 });
    try {
      const res = await sql`
        select privado.excluir_conta(${userId}::uuid) as dados
      `;
      dadosExclusao = (res[0]?.dados ?? {}) as Record<string, unknown>;
    } catch (err: unknown) {
      const erroPg = err as { code?: string; message?: string; detail?: string };
      if (erroPg.code === "PGRST" && erroPg.message) {
        try {
          const corpoErro = JSON.parse(erroPg.message) as Erro;
          const status = erroPg.detail ? (JSON.parse(erroPg.detail) as { status?: number }).status ?? 400 : 400;
          return resposta(status, corpoErro);
        } catch {
          return resposta(400, { code: erroPg.message, message: erroPg.message, details: null });
        }
      }
      return resposta(500, { code: "erro_interno", message: "erro_interno", details: null });
    } finally {
      await sql.end({ timeout: 2 });
    }
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
