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

function igualEmTempoConstante(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diferenca = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diferenca |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diferenca === 0;
}

function segredoValido(req: Request): boolean {
  const esperado =
    Deno.env.get("AGENDADOR_SECRET") ||
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
    "frila-agendador-segredo-local";

  const secretHeader = req.headers.get("x-agendador-secret");
  if (secretHeader && igualEmTempoConstante(secretHeader, esperado)) {
    return true;
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (match && igualEmTempoConstante(match[1], esperado)) {
    return true;
  }

  return false;
}

function getDbUrl(): string {
  return (
    Deno.env.get("SUPABASE_DB_URL") ||
    Deno.env.get("DATABASE_URL") ||
    "postgresql://postgres:postgres@supabase_db_frila-backend:5432/postgres"
  );
}

async function conectarSql() {
  const urlPadrao = getDbUrl();
  try {
    const sql = postgres(urlPadrao, { max: 3, connect_timeout: 5 });
    await sql`select 1`;
    return sql;
  } catch (_e) {
    const urlLocal = "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
    const sql = postgres(urlLocal, { max: 3, connect_timeout: 5 });
    return sql;
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ ok: false, erro: "metodo_nao_permitido" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (!segredoValido(req)) {
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

  let sql;
  try {
    sql = await conectarSql();
  } catch (err) {
    return new Response(
      JSON.stringify({ ok: false, erro: "erro_conexao_banco", detalhe: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  try {
    if (vagaId) {
      // 1. Disparo pontual de uma vaga específica
      const res = await sql`
        select privado.despachar_vaga(
          ${vagaId}::uuid,
          ${motivo},
          ${excluir}::uuid
        ) as despachos
      `;
      const despachos = Number(res[0]?.despachos ?? 0);
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

      const lotes = await sql`
        select msg_id, vaga_id, sucesso, despachos, erro
          from privado.processar_fila_despacho(${limite}, ${vt})
      `;

      const totalDespachos = lotes.reduce(
        (acc: number, row: { despachos: number }) => acc + (Number(row.despachos) || 0),
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
    return new Response(
      JSON.stringify({ ok: false, erro: "falha_processamento", detalhe: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  } finally {
    await sql.end({ timeout: 2 });
  }
});
