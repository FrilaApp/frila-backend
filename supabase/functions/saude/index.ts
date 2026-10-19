// Probe operacional de saúde para monitoramento externo de disponibilidade (RNF12).
// Cartão 5bPJvMIo · RNF02, RNF03, RNF12 · RN15.
//
// Invocado periodicamente (ex.: a cada 5 minutos) por serviço externo de monitoramento.
// Executa probe de conectividade e integridade do banco sem expor dados sensíveis ou pessoais.
//
//   GET  /functions/v1/saude  -> 200 { "ok": true, "status": "saudavel", ... }
//   HEAD /functions/v1/saude  -> 200 (sem corpo)
//   POST /functions/v1/saude  -> 405 { "ok": false, "erro": "metodo_nao_permitido" }
//   Falha de banco            -> 503 { "ok": false, "status": "indisponivel", ... }

import postgres from "npm:postgres@3.4.4";

export interface SqlProbe {
  ping: () => Promise<boolean>;
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
      return new Response(null, { status: ok ? 200 : 503 });
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

    return json({
      ok: true,
      status: "saudavel",
      timestamp: new Date().toISOString(),
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
