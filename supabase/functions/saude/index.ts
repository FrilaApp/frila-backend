// Probe operacional de saúde para monitoramento externo de disponibilidade (RNF12).
// Cartão 5bPJvMIo · RNF02, RNF03, RNF12 · RN15 · Cartão bB0tV5R8.
//
// Invocado periodicamente (ex.: a cada ≤15 minutos) por serviço externo de monitoramento.
// Executa probe de conectividade e monitoramento de idade dos jobs do pg_cron
// sem expor dados sensíveis, pessoais ou nomes internos de infraestrutura (RN15, condição b).
//
//   GET  /functions/v1/saude  -> 200 { "ok": true, "status": "saudavel", "timestamp": "...", "despacho_idade_segundos": ..., "vigia_idade_segundos": ... }
//   HEAD /functions/v1/saude  -> 200 (sem corpo quando saudável) / 503 (sem corpo quando atrasado ou fora)
//   POST /functions/v1/saude  -> 405 { "ok": false, "erro": "metodo_nao_permitido" }
//   Jobs cron atrasados       -> 503 { "ok": false, "status": "atrasado", "despacho_idade_segundos": ..., "vigia_idade_segundos": ... }
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

export interface SqlProbe {
  ping: () => Promise<boolean>;
  consultarJobs?: () => Promise<InfoSaudeCron>;
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

export function criarSqlProbe(dbUrl?: string): SqlProbe {
  const url = getDbUrl(dbUrl);

  const com = async <T>(fn: (sql: ReturnType<typeof postgres>) => Promise<T>): Promise<T> => {
    const sql = postgres(url, { max: 1, connect_timeout: 3 });
    try {
      return await fn(sql);
    } finally {
      await sql.end({ timeout: 2 });
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

    const agoraIso = new Date().toISOString();

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
