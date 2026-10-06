// Edge Function enviar-email: consome a fila `email` e manda os e-mails transacionais.
// Cartão 7yq1flLG · RF23, RF24, RF26 · D02 · RN13, RN15.
//
// O Postgres não envia e-mail: as RPCs só enfileiram. Esta função é o outro lado.
//
//   1. Lê a fila `email` sob visibility timeout (`privado.ler_fila_email`).
//   2. Para uma ocorrência, busca em `privado.dados_do_email` o que os dois e-mails
//      precisam — protocolo, categoria, prazo, o que ainda falta enviar, o endereço de
//      quem abriu. O relato não vem, e por isso não sai.
//   3. Manda o que falta: a caixa da Equipe Frila e/ou o protocolo para quem abriu.
//   4. Registra o envio na `ocorrencia` (`privado.registrar_email_enviado`) — instante e
//      prazo comunicado, nunca assunto nem corpo.
//   5. Arquiva o pedido quando os dois saíram. Falha do provedor **não** arquiva: o
//      pedido volta à fila quando o visibility timeout vence, e o job do pg_cron
//      `processar_fila_email` acorda esta função de novo. O que já saiu não sai duas
//      vezes, porque a `ocorrencia` guarda o que foi entregue.
//
// O teto é de 5 leituras, como o do despacho e o do push. Erro definitivo do provedor
// (caixa inexistente) arquiva na hora: insistir cinco vezes num 550 não muda o 550.

import postgres from "npm:postgres@3.4.4";
import {
  criarEnvioSmtp,
  Email,
  Enviar,
  lerConfiguracaoSmtp,
  ResultadoEnvio,
} from "./provedor.ts";
import {
  alertaParaEquipe,
  DadosDaOcorrencia,
  Destino,
  modeloDe,
} from "./modelos.ts";

export const TETO_DE_LEITURAS = 5;

export interface PedidoDaFila {
  msg_id: number;
  read_ct: number;
  mensagem: Record<string, unknown>;
}

export interface DadosDoEmail extends DadosDaOcorrencia {
  equipe_pendente: boolean;
  autor_pendente: boolean;
  autor_email: string | null;
  tentativas: number;
}

export interface SqlClient {
  lerFilaEmail: (qtd: number, vt: number) => Promise<PedidoDaFila[]>;
  dadosDoEmail: (ocorrenciaId: string) => Promise<DadosDoEmail | null>;
  registrarEnviado: (
    ocorrenciaId: string,
    destino: Destino,
    prazo: string | null,
  ) => Promise<void>;
  registrarFalha: (ocorrenciaId: string, codigo: string) => Promise<number>;
  concluir: (msgId: number) => Promise<void>;
}

export interface Dependencias {
  agendadorSecret?: string;
  enviar?: Enviar;
  sqlClient?: SqlClient;
  dbUrl?: string;
  caixaDaEquipe?: string;
}

function igualEmTempoConstante(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diferenca = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diferenca |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diferenca === 0;
}

const AGENDADOR_SECRET = Deno.env.get("AGENDADOR_SECRET");
if (!AGENDADOR_SECRET || AGENDADOR_SECRET.trim() === "") {
  throw new Error("AGENDADOR_SECRET é obrigatório e deve estar configurado no ambiente.");
}

function segredoValido(req: Request, agendadorSecret?: string): boolean {
  const secret = agendadorSecret || AGENDADOR_SECRET;
  if (!secret || secret.trim() === "") return false;

  const cabecalho = req.headers.get("x-agendador-secret");
  if (cabecalho && igualEmTempoConstante(cabecalho, secret)) return true;

  const auth = req.headers.get("Authorization") ?? "";
  const m = auth.match(/^Bearer\s+(.+)$/i);
  return Boolean(m && igualEmTempoConstante(m[1], secret));
}

// A caixa da Equipe Frila é segredo de ambiente, e não linha de tabela: ela não é dado
// do produto, muda com o provedor de e-mail e não deve viajar num `db reset`.
export function caixaDaEquipe(injetada?: string): string {
  return (injetada || Deno.env.get("EMAIL_EQUIPE") || "equipe@frila.app").trim();
}

function obterDbUrl(injetada?: string): string {
  const valor = (injetada || Deno.env.get("DATABASE_URL") ||
    Deno.env.get("SUPABASE_DB_URL"))?.trim();
  if (!valor) {
    throw new Error(
      "DATABASE_URL ou SUPABASE_DB_URL é obrigatório e deve estar configurado no ambiente.",
    );
  }
  return valor;
}

export function criarSqlClient(deps?: Dependencias): SqlClient {
  if (deps?.sqlClient) return deps.sqlClient;
  const dbUrl = obterDbUrl(deps?.dbUrl);

  // Uma conexão por chamada, encerrada no `finally`, como o `enviar-push` faz: a Edge
  // Function pode ser congelada entre invocações e um pool sobrevivente reaparece morto.
  const com = async <T>(fn: (sql: ReturnType<typeof postgres>) => Promise<T>): Promise<T> => {
    const sql = postgres(dbUrl, { max: 1, connect_timeout: 5 });
    try {
      return await fn(sql);
    } finally {
      await sql.end({ timeout: 2 });
    }
  };

  return {
    lerFilaEmail: (qtd, vt) =>
      com(async (sql) => {
        const r = await sql`
          select msg_id, read_ct, mensagem
            from privado.ler_fila_email(${qtd}::int, ${vt}::int)
        `;
        return r.map((l: Record<string, unknown>) => ({
          msg_id: Number(l.msg_id),
          read_ct: Number(l.read_ct),
          mensagem: (l.mensagem ?? {}) as Record<string, unknown>,
        }));
      }),

    dadosDoEmail: (ocorrenciaId) =>
      com(async (sql) => {
        const r = await sql`
          select privado.dados_do_email(${ocorrenciaId}::uuid) as dados
        `;
        return (r[0]?.dados ?? null) as DadosDoEmail | null;
      }),

    registrarEnviado: (ocorrenciaId, destino, prazo) =>
      com(async (sql) => {
        await sql`
          select privado.registrar_email_enviado(
            ${ocorrenciaId}::uuid, ${destino}::text, ${prazo}::date
          )
        `;
      }),

    registrarFalha: (ocorrenciaId, codigo) =>
      com(async (sql) => {
        const r = await sql`
          select privado.registrar_falha_email(
            ${ocorrenciaId}::uuid, ${codigo}::text
          ) as tentativas
        `;
        return Number(r[0]?.tentativas ?? 0);
      }),

    concluir: (msgId) =>
      com(async (sql) => {
        await sql`select privado.concluir_email(${msgId}::bigint)`;
      }),
  };
}

export interface LinhaDoRelatorio {
  msg_id: number;
  status: "enviado" | "pendente" | "arquivado";
  detalhe?: string;
}

// Um pedido de alerta do monitoramento (cartão 5bPJvMIo). Não tem ocorrência: nada é
// registrado no banco além do arquivamento do pedido.
async function processarAlerta(
  pedido: PedidoDaFila,
  enviar: Enviar,
  equipe: string,
  sql: SqlClient,
): Promise<LinhaDoRelatorio> {
  const codigo = typeof pedido.mensagem.codigo === "string"
    ? pedido.mensagem.codigo
    : null;
  if (!codigo || !/^[a-z0-9_]{1,60}$/.test(codigo)) {
    await sql.concluir(pedido.msg_id);
    return { msg_id: pedido.msg_id, status: "arquivado", detalhe: "codigo_invalido" };
  }

  const valor = typeof pedido.mensagem.valor === "number"
    ? pedido.mensagem.valor
    : undefined;
  const modelo = alertaParaEquipe(codigo, valor);
  const r = await enviar({ para: equipe, assunto: modelo.assunto, texto: modelo.texto });

  if (r.ok) {
    await sql.concluir(pedido.msg_id);
    return { msg_id: pedido.msg_id, status: "enviado" };
  }
  if (r.transitorio && pedido.read_ct < TETO_DE_LEITURAS) {
    return { msg_id: pedido.msg_id, status: "pendente", detalhe: r.codigo };
  }
  await sql.concluir(pedido.msg_id);
  return { msg_id: pedido.msg_id, status: "arquivado", detalhe: r.codigo };
}

async function processarOcorrencia(
  pedido: PedidoDaFila,
  tipo: string,
  enviar: Enviar,
  equipe: string,
  sql: SqlClient,
): Promise<LinhaDoRelatorio> {
  const ocorrenciaId = typeof pedido.mensagem.ocorrencia_id === "string"
    ? pedido.mensagem.ocorrencia_id
    : null;
  if (!ocorrenciaId) {
    await sql.concluir(pedido.msg_id);
    return { msg_id: pedido.msg_id, status: "arquivado", detalhe: "pedido_sem_ocorrencia" };
  }

  const dados = await sql.dadosDoEmail(ocorrenciaId);
  if (!dados) {
    // A ocorrência sumiu do banco. Não existe e-mail a mandar e insistir enche a fila.
    await sql.concluir(pedido.msg_id);
    return { msg_id: pedido.msg_id, status: "arquivado", detalhe: "ocorrencia_inexistente" };
  }

  const destinos: Array<{ destino: Destino; para: string }> = [];
  if (dados.equipe_pendente) destinos.push({ destino: "equipe", para: equipe });
  if (dados.autor_pendente && dados.autor_email) {
    destinos.push({ destino: "autor", para: dados.autor_email });
  }

  if (destinos.length === 0) {
    await sql.concluir(pedido.msg_id);
    return { msg_id: pedido.msg_id, status: "arquivado", detalhe: "nada_pendente" };
  }

  let ultimoErro: ResultadoEnvio | null = null;

  for (const { destino, para } of destinos) {
    const modelo = modeloDe(tipo, destino, dados);
    if (!modelo) {
      // Tipo que esta função não sabe escrever. Arquivar em silêncio esconderia a
      // lacuna; o código fica no banco, visível em `ocorrencia.email_ultimo_erro`.
      await sql.registrarFalha(ocorrenciaId, "tipo_desconhecido");
      await sql.concluir(pedido.msg_id);
      return { msg_id: pedido.msg_id, status: "arquivado", detalhe: "tipo_desconhecido" };
    }

    const email: Email = {
      para,
      assunto: modelo.assunto,
      texto: modelo.texto,
      // A Equipe Frila só responde por e-mail: a resposta de quem recebeu o protocolo
      // tem de cair na caixa dela, e não no remetente que não lê.
      responderPara: destino === "autor" ? equipe : undefined,
    };

    const r = await enviar(email);
    if (r.ok) {
      await sql.registrarEnviado(ocorrenciaId, destino, dados.prazo_resposta_ate ?? null);
    } else {
      ultimoErro = r;
    }
  }

  if (!ultimoErro) {
    await sql.concluir(pedido.msg_id);
    return { msg_id: pedido.msg_id, status: "enviado" };
  }

  const codigo = ultimoErro.codigo ?? "erro_nao_classificado";
  await sql.registrarFalha(ocorrenciaId, codigo);

  // Transitório e dentro do teto: fica na fila. O visibility timeout devolve o pedido e
  // o job do minuto seguinte tenta de novo, mandando só o que ainda falta.
  if (ultimoErro.transitorio && pedido.read_ct < TETO_DE_LEITURAS) {
    return { msg_id: pedido.msg_id, status: "pendente", detalhe: codigo };
  }

  await sql.concluir(pedido.msg_id);
  return {
    msg_id: pedido.msg_id,
    status: "arquivado",
    detalhe: ultimoErro.transitorio ? "teto_de_leituras_excedido" : codigo,
  };
}

export async function processarEnvioEmail(
  req: Request,
  deps: Dependencias = {},
): Promise<Response> {
  const json = (corpo: unknown, status: number) =>
    new Response(JSON.stringify(corpo), {
      status,
      headers: { "Content-Type": "application/json" },
    });

  if (req.method !== "POST") {
    return json({ ok: false, erro: "metodo_nao_permitido" }, 405);
  }
  if (!segredoValido(req, deps.agendadorSecret)) {
    return json({ ok: false, erro: "nao_autorizado" }, 401);
  }

  let enviar = deps.enviar;
  if (!enviar) {
    const cfg = lerConfiguracaoSmtp();
    if (!cfg) {
      // Sem provedor não há envio, e fingir sucesso arquivaria a denúncia de alguém.
      // A fila fica intacta: configurado o SMTP, o pendente sai.
      return json({
        ok: false,
        erro: "provedor_de_email_nao_configurado",
        mensagem: "SMTP_HOST e EMAIL_REMETENTE são obrigatórios para enviar e-mail.",
      }, 500);
    }
    enviar = criarEnvioSmtp(cfg);
  }

  let corpo: Record<string, unknown> = {};
  try {
    corpo = await req.json();
  } catch {
    corpo = {};
  }
  const limite = typeof corpo.limite === "number" && corpo.limite > 0 ? corpo.limite : 20;
  const vt = typeof corpo.vt === "number" && corpo.vt > 0 ? corpo.vt : 60;

  const sql = criarSqlClient(deps);
  const equipe = caixaDaEquipe(deps.caixaDaEquipe);

  const pedidos = await sql.lerFilaEmail(limite, vt);
  if (pedidos.length === 0) {
    return json({ ok: true, processados: 0, mensagem: "nenhum_pedido_na_fila" }, 200);
  }

  const relatorio: LinhaDoRelatorio[] = [];
  for (const pedido of pedidos) {
    const tipo = typeof pedido.mensagem.tipo === "string" ? pedido.mensagem.tipo : "";
    if (tipo === "alerta") {
      relatorio.push(await processarAlerta(pedido, enviar, equipe, sql));
    } else {
      relatorio.push(await processarOcorrencia(pedido, tipo, enviar, equipe, sql));
    }
  }

  return json({ ok: true, processados: pedidos.length, relatorio }, 200);
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => await processarEnvioEmail(req));
}
