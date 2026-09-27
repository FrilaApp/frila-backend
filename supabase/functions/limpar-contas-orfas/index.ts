// Edge Function limpar-contas-orfas (cartão yClUqOpU).
//
// Rotina periódica / diária acionada com segredo do agendador:
// 1. Valida segredo compartilhado (exclusivamente via header x-agendador-secret).
// 2. Consulta contas em auth.users criadas há mais de 24 h sem cadastro em public.usuario
//    via privado.contas_auth_orfas(p_horas).
// 3. Purgar cada conta órfã no Supabase Auth via Admin API com service_role (DELETE /auth/v1/admin/users/{id}).
// 4. Executa a retenção de 15 dias e a higienização de tabelas no Postgres via privado.executar_retencao_diaria().

import postgres from "npm:postgres@3.4.4";

export interface Erro {
  code: string;
  message: string;
  details: string | null;
}

export interface SqlClient {
  contasOrfas: (horas: number) => Promise<string[]>;
  executarRetencao: () => Promise<Record<string, unknown>>;
}

export interface HandlerDeps {
  fetchFn?: typeof fetch;
  sqlClient?: SqlClient;
  supabaseUrl?: string;
  serviceRoleKey?: string;
  agendadorSecret?: string;
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

function igualEmTempoConstante(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diferenca = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diferenca |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diferenca === 0;
}

function segredoValido(req: Request, segredoEsperado: string): boolean {
  const secretHeader = req.headers.get("x-agendador-secret");
  if (secretHeader && igualEmTempoConstante(secretHeader, segredoEsperado)) {
    return true;
  }
  return false;
}

function criarSqlClient(deps?: HandlerDeps): SqlClient {
  if (deps?.sqlClient) {
    return deps.sqlClient;
  }
  const dbUrl = obterVariavel("SUPABASE_DB_URL", deps?.dbUrl);
  return {
    async contasOrfas(horas: number): Promise<string[]> {
      const sql = postgres(dbUrl, { max: 1, connect_timeout: 5 });
      try {
        const res = await sql`
          select id::text from privado.contas_auth_orfas(${horas}::integer)
        `;
        return res.map((r) => r.id as string);
      } finally {
        await sql.end({ timeout: 2 });
      }
    },
    async executarRetencao(): Promise<Record<string, unknown>> {
      const sql = postgres(dbUrl, { max: 1, connect_timeout: 5 });
      try {
        const res = await sql`
          select privado.executar_retencao_diaria() as retencao
        `;
        return (res[0]?.retencao ?? {}) as Record<string, unknown>;
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

  const agendadorSecret = obterVariavel("AGENDADOR_SECRET", deps?.agendadorSecret);
  if (!segredoValido(req, agendadorSecret)) {
    return resposta(401, { code: "nao_autenticado", message: "nao_autenticado", details: null });
  }

  let corpo: { horas?: unknown; executar_retencao_banco?: unknown } = {};
  try {
    corpo = await req.json();
  } catch {
    corpo = {};
  }

  let horas = 24;
  if (typeof corpo?.horas === "number" && Number.isFinite(corpo.horas)) {
    const horasInteiras = Math.floor(corpo.horas);
    if (horasInteiras >= 24) {
      horas = horasInteiras;
    }
  }
  const executarRetencaoBanco = corpo?.executar_retencao_banco !== false;

  const fetchFn = deps?.fetchFn ?? fetch;
  const origem = obterVariavel("SUPABASE_URL", deps?.supabaseUrl);
  const serviceRole = obterVariavel("SUPABASE_SERVICE_ROLE_KEY", deps?.serviceRoleKey);
  const sqlClient = criarSqlClient(deps);

  // 1. Identifica contas órfãs no banco
  let orfas: string[] = [];
  try {
    orfas = await sqlClient.contasOrfas(horas);
  } catch (_err) {
    return resposta(500, { code: "erro_interno", message: "erro_ao_consultar_contas_orfas", details: null });
  }

  // 2. Apaga cada conta órfã no Supabase Auth via Admin API
  const removidos: string[] = [];
  const errosRemocao: Array<{ id: string; status: number }> = [];

  for (const userId of orfas) {
    try {
      const deleteRes = await fetchFn(`${origem}/auth/v1/admin/users/${encodeURIComponent(userId)}`, {
        method: "DELETE",
        headers: {
          apikey: serviceRole,
          Authorization: `Bearer ${serviceRole}`,
        },
      });

      if (deleteRes.ok) {
        removidos.push(userId);
      } else {
        errosRemocao.push({ id: userId, status: deleteRes.status });
      }
    } catch {
      errosRemocao.push({ id: userId, status: 500 });
    }
  }

  // 3. Opcionalmente aciona retenção consolidada no Postgres
  let resultadoRetencao: Record<string, unknown> | null = null;
  if (executarRetencaoBanco) {
    try {
      resultadoRetencao = await sqlClient.executarRetencao();
    } catch (_err) {
      // Não impede retorno de sucesso das contas órfãs se o banco falhou na higiene
      resultadoRetencao = { erro: "falha_ao_executar_retencao" };
    }
  }

  return resposta(200, {
    ok: true,
    contas_orfas_encontradas: orfas.length,
    contas_orfas_removidas: removidos.length,
    usuarios_removidos: removidos,
    erros_remocao: errosRemocao,
    retencao_banco: resultadoRetencao,
  });
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => {
    return await handler(req);
  });
}
