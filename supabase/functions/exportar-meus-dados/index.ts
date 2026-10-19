// Edge Function exportar-meus-dados (cartão nUpPFCpM · US25, RF25, RNF08, UC16,
// LGPD art. 18).
//
// Devolve o JSON **no corpo da resposta**, e não um link. O contrato explica por quê: um
// link é mais um lugar onde o dado pessoal fica em repouso, com prazo de validade que
// alguém precisa lembrar de configurar. O corpo da resposta morre com a conexão.
//
//   1. Valida o token no `auth/v1/user` e pega a identidade dali — não do corpo, que é
//      do cliente, nem do `sub` decodificado sem conferir a assinatura.
//   2. Chama `privado.meus_dados(uuid)`, que é `stable` e portanto incapaz de escrever.
//   3. Devolve com `Cache-Control: no-store`.
//
// ── Por que ela não guarda nada, e como isso é verificável ───────────────────
//
// Não há bucket, não há tabela de pedidos, não há arquivo temporário e não há log do
// corpo. O único `console.error` desta função escreve uma constante — nunca o erro do
// banco, que pode trazer dado de linha (RN15). O `no-store` fecha a última porta: sem
// ele, um proxy entre o app e o Supabase poderia guardar a resposta inteira em disco.
//
// ── A conta que o token conhece e o banco não ────────────────────────────────
//
// Token válido de quem nunca chamou `criar_conta` não tem linha em `usuario`. O contrato
// declara só 200 e 401 para esta rota, e nenhum dos dois serve: 200 exigiria `conta`, que
// é obrigatória e não existe, e 401 diria que o token é inválido quando ele não é.
// Responde `404 nao_encontrado`, que é o que toda RPC deste contrato responde para o
// mesmo caso. A lacuna está registrada no PR: é o contrato que precisa declarar o 404.

import postgres from "npm:postgres@3.4.4";

export interface Erro {
  code: string;
  message: string;
  details: string | null;
}

export interface SqlClient {
  meusDados: (userId: string) => Promise<Record<string, unknown> | null>;
}

export interface HandlerDeps {
  fetchFn?: typeof fetch;
  sqlClient?: SqlClient;
  supabaseUrl?: string;
  anonKey?: string;
  dbUrl?: string;
}

function resposta(status: number, corpo: unknown): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: {
      "Content-Type": "application/json",
      // O corpo é o dado pessoal inteiro do titular. Nenhum intermediário guarda cópia.
      "Cache-Control": "no-store",
    },
  });
}

function erro(status: number, code: string, details: string | null = null): Response {
  return resposta(status, { code, message: code, details } satisfies Erro);
}

function obterVariavel(nome: string, injetada?: string): string {
  const valor = (injetada ?? Deno.env.get(nome))?.trim();
  if (!valor) {
    throw new Error(`${nome} é obrigatório e deve estar configurado no ambiente.`);
  }
  return valor;
}

export function criarSqlClient(deps?: HandlerDeps): SqlClient {
  if (deps?.sqlClient) return deps.sqlClient;
  const dbUrl = obterVariavel("SUPABASE_DB_URL", deps?.dbUrl);
  return {
    async meusDados(userId: string) {
      const sql = postgres(dbUrl, { max: 1, connect_timeout: 5 });
      try {
        const res = await sql`
          select privado.meus_dados(${userId}::uuid) as dados
        `;
        return (res[0]?.dados ?? null) as Record<string, unknown> | null;
      } finally {
        await sql.end({ timeout: 2 });
      }
    },
  };
}

export async function handler(req: Request, deps?: HandlerDeps): Promise<Response> {
  if (req.method !== "POST") {
    return erro(405, "metodo_nao_permitido");
  }

  const autorizacao = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+$/i.test(autorizacao)) {
    return erro(401, "nao_autenticado");
  }

  const fetchFn = deps?.fetchFn ?? fetch;
  const origem = obterVariavel("SUPABASE_URL", deps?.supabaseUrl);
  const anon = obterVariavel("SUPABASE_ANON_KEY", deps?.anonKey);

  // A identidade vem do Supabase Auth, e não de um `sub` lido do token sem conferir a
  // assinatura: quem exporta dado pessoal não adivinha de quem ele é.
  const usuarioRes = await fetchFn(`${origem}/auth/v1/user`, {
    headers: {
      apikey: anon,
      Authorization: autorizacao,
      "Content-Type": "application/json",
    },
  });
  if (!usuarioRes.ok) {
    return erro(401, "nao_autenticado");
  }

  const usuario = (await usuarioRes.json()) as { id?: unknown };
  if (typeof usuario.id !== "string") {
    return erro(401, "nao_autenticado");
  }

  const sqlClient = criarSqlClient(deps);

  let dados: Record<string, unknown> | null;
  try {
    dados = await sqlClient.meusDados(usuario.id);
  } catch {
    // Sem o erro no log: a mensagem do Postgres pode trazer conteúdo de linha (RN15).
    console.error("exportar-meus-dados: falha ao colher os dados");
    return erro(500, "erro_interno");
  }

  if (dados === null) {
    return erro(404, "nao_encontrado");
  }

  return resposta(200, dados);
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => await handler(req));
}
