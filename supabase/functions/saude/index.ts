// Probe operacional de saúde para monitoramento externo de disponibilidade (RNF12).
// Cartão 5bPJvMIo · RNF02, RNF03, RNF12 · RN15 · Cartão bB0tV5R8.
//
// Invocado periodicamente (ex.: a cada ≤15 minutos) por serviço externo de monitoramento.
// Executa probe de conectividade e monitoramento de idade dos jobs do pg_cron, da fila
// de e-mail e do pg_net, e de falha recente de SMTP, sem expor dados sensíveis, pessoais
// ou nomes internos de infraestrutura (RN15, condição b). O detalhe vai só para o log.
//
//   GET  /functions/v1/saude  -> 200 { "ok": true, "status": "saudavel", "timestamp": "...", "despacho_idade_segundos": ..., "vigia_idade_segundos": ... }
//   HEAD /functions/v1/saude  -> 200 (sem corpo quando saudável) / 503 (sem corpo quando atrasado ou fora)
//   POST /functions/v1/saude  -> 405 { "ok": false, "erro": "metodo_nao_permitido" }
//   Jobs cron atrasados       -> 503 { "ok": false, "status": "atrasado", "despacho_idade_segundos": ..., "vigia_idade_segundos": ... }
//   Fila, pg_net ou SMTP      -> 503 { "ok": false, "status": "degradado", "timestamp": "..." }
//   Falha de banco            -> 503 { "ok": false, "status": "indisponivel", ... }

import postgres from "npm:postgres@3.4.4";

export interface InfoSaudeCron {
  saudavel: boolean;
  status: string;
  despacho_idade_segundos: number | null;
  vigia_idade_segundos: number | null;
  despacho_ativo: boolean;
  vigia_ativo: boolean;
}

// O que `privado.consultar_saude_operacional()` devolve. Estes campos são só para o log da
// função: o corpo público leva apenas o status (RN15).
export interface InfoSaudeOperacional {
  saudavel: boolean;
  status: string;
  entrega_idade_segundos: number | null;
  entrega_ativo: boolean;
  registro_idade_segundos: number | null;
  registro_ativo: boolean;
  fila_idade_segundos: number | null;
  transporte_falhas: number;
  transporte_legivel: boolean;
  entrega_falhas: number;
}

export interface SqlProbe {
  ping: () => Promise<boolean>;
  consultarJobs?: () => Promise<InfoSaudeCron>;
  consultarOperacional?: () => Promise<InfoSaudeOperacional>;
  registrarFalha?: (origem: string, codigo: string) => Promise<void>;
}

export interface DependenciasSaude {
  sqlProbe?: SqlProbe;
  dbUrl?: string;
}

export function getDbUrl(injetada?: string): string {
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

// Um cliente só por isolate (no máximo 2 conexões, idle_timeout 20s), criado na 1ª chamada e
// reaproveitado entre ping, consultarJobs, consultarOperacional e requisições seguintes — em vez
// de abrir e fechar 3 conexões TCP por GET/HEAD (mesmo padrão de ler-midia). Em erro de consulta,
// o cliente é descartado e a próxima chamada cria outro.
type Sql = ReturnType<typeof postgres>;
const clientes = new Map<string, Sql>();

function clienteDoModulo(
  dbUrl: string,
  criarCliente: (url: string) => Sql = (u) => postgres(u, { max: 2, idle_timeout: 20, connect_timeout: 3 }),
): Sql {
  let sql = clientes.get(dbUrl);
  if (!sql) {
    sql = criarCliente(dbUrl);
    clientes.set(dbUrl, sql);
  }
  return sql;
}

function descartarCliente(dbUrl: string, sql: Sql): void {
  if (clientes.get(dbUrl) === sql) clientes.delete(dbUrl);
  sql.end({ timeout: 2 }).catch(() => {});
}

/** Encerra os clientes do módulo (para testes limpos sem conexão pendente). */
export async function encerrarClientes(): Promise<void> {
  const todos = [...clientes.values()];
  clientes.clear();
  await Promise.all(todos.map((sql) => sql.end({ timeout: 2 }).catch(() => {})));
}

export function criarSqlProbe(
  dbUrl?: string,
  criarCliente?: (url: string) => Sql,
): SqlProbe {
  const url = getDbUrl(dbUrl);

  const com = async <T>(fn: (sql: Sql) => Promise<T>): Promise<T> => {
    const sql = clienteDoModulo(url, criarCliente);
    try {
      return await fn(sql);
    } catch (err) {
      descartarCliente(url, sql);
      throw err;
    }
  };

  return {
    ping: async () => {
      return await com(async (sql) => {
        const res = await sql`select 1 as ping`;
        return Boolean(res && res.length > 0);
      });
    },
    consultarJobs: async () => {
      return await com(async (sql) => {
        const rows = await sql`
          select
            saudavel,
            status,
            despacho_idade_segundos,
            vigia_idade_segundos,
            despacho_ativo,
            vigia_ativo
          from privado.consultar_saude_cron()
        `;
        if (!rows || rows.length === 0) {
          return {
            saudavel: false,
            status: "atrasado",
            despacho_idade_segundos: null,
            vigia_idade_segundos: null,
            despacho_ativo: false,
            vigia_ativo: false,
          };
        }
        const r = rows[0];
        return {
          saudavel: Boolean(r.saudavel),
          status: String(r.status),
          despacho_idade_segundos: r.despacho_idade_segundos !== null ? Number(r.despacho_idade_segundos) : null,
          vigia_idade_segundos: r.vigia_idade_segundos !== null ? Number(r.vigia_idade_segundos) : null,
          despacho_ativo: Boolean(r.despacho_ativo),
          vigia_ativo: Boolean(r.vigia_ativo),
        };
      });
    },
    consultarOperacional: async () => {
      return await com(async (sql) => {
        const rows = await sql`
          select
            saudavel,
            status,
            entrega_idade_segundos,
            entrega_ativo,
            registro_idade_segundos,
            registro_ativo,
            fila_idade_segundos,
            transporte_falhas,
            transporte_legivel,
            entrega_falhas
          from privado.consultar_saude_operacional()
        `;
        if (!rows || rows.length === 0) {
          return {
            saudavel: false,
            status: "degradado",
            entrega_idade_segundos: null,
            entrega_ativo: false,
            registro_idade_segundos: null,
            registro_ativo: false,
            fila_idade_segundos: null,
            transporte_falhas: 0,
            transporte_legivel: false,
            entrega_falhas: 0,
          };
        }
        const r = rows[0];
        const numero = (v: unknown) => (v !== null && v !== undefined ? Number(v) : null);
        return {
          saudavel: Boolean(r.saudavel),
          status: String(r.status),
          entrega_idade_segundos: numero(r.entrega_idade_segundos),
          entrega_ativo: Boolean(r.entrega_ativo),
          registro_idade_segundos: numero(r.registro_idade_segundos),
          registro_ativo: Boolean(r.registro_ativo),
          fila_idade_segundos: numero(r.fila_idade_segundos),
          transporte_falhas: Number(r.transporte_falhas ?? 0),
          transporte_legivel: Boolean(r.transporte_legivel),
          entrega_falhas: Number(r.entrega_falhas ?? 0),
        };
      });
    },
    registrarFalha: async (origem: string, codigo: string) => {
      try {
        await com(async (sql) => {
          await sql`
            select privado.registrar_falha_execucao(
              ${origem}::text,
              ${codigo}::text,
              null
            )
          `;
        });
      } catch (_e) {
        // Silêncio defensivo se o próprio banco estiver fora do ar
      }
    },
  };
}

// O detalhe do que está doente fica no log da função, que só os sócios leem. A resposta
// pública não ganha nome de fila, de job nem de tabela.
function registrarDetalhe(operacional: InfoSaudeOperacional): void {
  console.log(JSON.stringify({ evento: "saude_operacional_degradada", ...operacional }));
}

export async function processarSaude(
  req: Request,
  deps: DependenciasSaude = {},
): Promise<Response> {
  const json = (corpo: unknown, status: number) =>
    new Response(JSON.stringify(corpo), {
      status,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store, no-cache, must-revalidate",
      },
    });

  if (req.method === "HEAD") {
    const probe = deps.sqlProbe ?? criarSqlProbe(deps.dbUrl);
    try {
      const ok = await probe.ping();
      if (!ok) {
        return new Response(null, { status: 503 });
      }
      if (probe.consultarJobs) {
        const jobs = await probe.consultarJobs();
        if (!jobs.saudavel) {
          return new Response(null, { status: 503 });
        }
      }
      if (probe.consultarOperacional) {
        const operacional = await probe.consultarOperacional();
        if (!operacional.saudavel) {
          registrarDetalhe(operacional);
          return new Response(null, { status: 503 });
        }
      }
      return new Response(null, { status: 200 });
    } catch {
      return new Response(null, { status: 503 });
    }
  }

  if (req.method !== "GET") {
    return json({ ok: false, erro: "metodo_nao_permitido" }, 405);
  }

  const probe = deps.sqlProbe ?? criarSqlProbe(deps.dbUrl);

  try {
    const saudavel = await probe.ping();
    if (!saudavel) {
      if (probe.registrarFalha) {
        await probe.registrarFalha("saude", "ping_banco_retornou_falso");
      }
      return json({
        ok: false,
        status: "indisponivel",
        erro: "verificacao_falhou",
      }, 503);
    }

    let jobs: InfoSaudeCron | undefined;
    if (probe.consultarJobs) {
      jobs = await probe.consultarJobs();
    }

    let operacional: InfoSaudeOperacional | undefined;
    if (probe.consultarOperacional) {
      operacional = await probe.consultarOperacional();
    }

    const agoraIso = new Date().toISOString();

    if (operacional && !operacional.saudavel) {
      registrarDetalhe(operacional);
      if (probe.registrarFalha) {
        await probe.registrarFalha("saude", "operacao_degradada");
      }
    }

    if (jobs && !jobs.saudavel) {
      if (probe.registrarFalha) {
        await probe.registrarFalha("saude", "jobs_cron_atrasados");
      }
      return json({
        ok: false,
        status: jobs.status || "atrasado",
        timestamp: agoraIso,
        despacho_idade_segundos: jobs.despacho_idade_segundos,
        vigia_idade_segundos: jobs.vigia_idade_segundos,
      }, 503);
    }

    if (operacional && !operacional.saudavel) {
      // Status fixo: o texto vindo do banco não chega a quem consulta (RN15).
      return json({ ok: false, status: "degradado", timestamp: agoraIso }, 503);
    }

    return json({
      ok: true,
      status: "saudavel",
      timestamp: agoraIso,
      despacho_idade_segundos: jobs?.despacho_idade_segundos ?? null,
      vigia_idade_segundos: jobs?.vigia_idade_segundos ?? null,
    }, 200);
  } catch (_e) {
    if (probe.registrarFalha) {
      await probe.registrarFalha("saude", "conexao_falhou");
    }
    return json({
      ok: false,
      status: "indisponivel",
      erro: "conexao_falhou",
    }, 503);
  }
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => await processarSaude(req));
}
