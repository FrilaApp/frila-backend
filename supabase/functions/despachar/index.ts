// Motor de despacho do Frila (cartão 7XS6MQGg).
//
// Edge Function protegida por segredo compartilhado (x-agendador-secret ou Bearer).
// Executa o despacho de vagas para profissionais elegíveis:
// 1. Disparo pontual pós-commit (recebe { vaga_id: "..." } no corpo):
//    Chama privado.despachar_vaga(vaga_id).
// 2. Disparo periódico / reprocessamento da fila (sem vaga_id):
//    Consome lote da fila pgmq via privado.processar_fila_despacho(10, 30).
//
// Não exposta para a internet: recusa qualquer chamada sem o segredo do agendador (401).

import postgres from "npm:postgres@3.4.4";

export const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function igualEmTempoConstante(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diferenca = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diferenca |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diferenca === 0;
}

export function segredoValido(req: Request, segredoEsperado: string): boolean {
  const secretHeader = req.headers.get("x-agendador-secret");
  if (secretHeader && igualEmTempoConstante(secretHeader, segredoEsperado)) {
    return true;
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (match && igualEmTempoConstante(match[1], segredoEsperado)) {
    return true;
  }

  return false;
}

export interface SqlClient {
  despacharVaga: (
    vagaId: string,
    motivo: string | null,
    excluirConta: string | null,
  ) => Promise<number>;
  processarFilaDespacho: (
    limite: number,
    vt: number,
  ) => Promise<Array<Record<string, unknown>>>;
}

export interface HandlerDeps {
  sqlClient?: SqlClient;
  agendadorSecret?: string;
  dbUrl?: string;
}

export function obterDbUrl(injetada?: string): string {
  const url = (
    injetada ||
    Deno.env.get("SUPABASE_DB_URL") ||
    Deno.env.get("DATABASE_URL")
  )?.trim();
  if (!url) {
    throw new Error(
      "SUPABASE_DB_URL ou DATABASE_URL é obrigatório e deve estar configurado no ambiente.",
    );
  }
  return url;
}

export function criarSqlClient(deps?: HandlerDeps): SqlClient {
  if (deps?.sqlClient) return deps.sqlClient;
  const url = obterDbUrl(deps?.dbUrl);

  const com = async <T>(fn: (sql: ReturnType<typeof postgres>) => Promise<T>): Promise<T> => {
    const sql = postgres(url, { max: 3, connect_timeout: 5 });
    try {
      return await fn(sql);
    } finally {
      await sql.end({ timeout: 2 });
    }
  };

  return {
    async despacharVaga(vagaId: string, motivo: string | null, excluirConta: string | null) {
      return await com(async (sql) => {
        const res = await sql`
          select privado.despachar_vaga(
            ${vagaId}::uuid,
            ${motivo},
            ${excluirConta}::uuid
          ) as despachos
        `;
        return Number(res[0]?.despachos ?? 0);
      });
    },
    async processarFilaDespacho(limite: number, vt: number) {
      return await com(async (sql) => {
        const lotes = await sql`
          select msg_id, vaga_id, sucesso, despachos, erro
            from privado.processar_fila_despacho(${limite}, ${vt})
        `;
        return lotes as Array<Record<string, unknown>>;
      });
    },
  };
}

export async function handler(
  req: Request,
  deps: HandlerDeps = {},
): Promise<Response> {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ ok: false, erro: "metodo_nao_permitido" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const secretEsperado = (deps.agendadorSecret ?? Deno.env.get("AGENDADOR_SECRET"))?.trim();
  if (!secretEsperado) {
    throw new Error("AGENDADOR_SECRET é obrigatório e deve estar configurado no ambiente.");
  }

  if (!segredoValido(req, secretEsperado)) {
    return new Response(JSON.stringify({ ok: false, erro: "nao_autorizado" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  let corpo: Record<string, unknown> = {};
  try {
    corpo = await req.json();
  } catch {
    corpo = {};
  }

  const vagaId = typeof corpo?.vaga_id === "string" ? corpo.vaga_id : null;
  const motivo = typeof corpo?.motivo === "string" ? corpo.motivo : null;
  const excluir = typeof corpo?.excluir_conta === "string" ? corpo.excluir_conta : null;

  if (vagaId && !UUID_REGEX.test(vagaId)) {
    return new Response(
      JSON.stringify({ ok: false, erro: "campo_invalido", campo: "vaga_id" }),
      { status: 422, headers: { "Content-Type": "application/json" } },
    );
  }

  if (excluir && !UUID_REGEX.test(excluir)) {
    return new Response(
      JSON.stringify({ ok: false, erro: "campo_invalido", campo: "excluir_conta" }),
      { status: 422, headers: { "Content-Type": "application/json" } },
    );
  }

  let sqlClient: SqlClient;
  try {
    sqlClient = criarSqlClient(deps);
  } catch (err) {
    console.error("despachar: erro ao conectar ao banco:", err);
    return new Response(
      JSON.stringify({ ok: false, erro: "erro_conexao_banco" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  try {
    if (vagaId) {
      // 1. Disparo pontual de uma vaga específica
      const despachos = await sqlClient.despacharVaga(vagaId, motivo, excluir);
      return new Response(
        JSON.stringify({
          ok: true,
          vaga_id: vagaId,
          despachos,
          origem: corpo?.origem ?? "pontual",
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    } else {
      // 2. Drenagem / reprocessamento da fila pgmq
      const limite = typeof corpo?.limite === "number" ? corpo.limite : 10;
      const vt = typeof corpo?.vt === "number" ? corpo.vt : 30;

      const lotes = await sqlClient.processarFilaDespacho(limite, vt);
      const totalDespachos = lotes.reduce(
        (acc: number, row: Record<string, unknown>) => acc + (Number(row.despachos) || 0),
        0,
      );

      return new Response(
        JSON.stringify({
          ok: true,
          processados: lotes.length,
          despachos: totalDespachos,
          mensagens: lotes,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }
  } catch (err) {
    console.error("despachar: falha no processamento:", err);
    return new Response(
      JSON.stringify({ ok: false, erro: "falha_processamento" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => {
    return await handler(req);
  });
}
