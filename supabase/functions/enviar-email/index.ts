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
import { segredoAgendadorValido } from "../_compartilhado/auth.ts";
import {
  criarEnvioSmtp,
  Email,
  Enviar,
  lerConfiguracaoSmtp,
  ResultadoEnvio,
  validarDestinatario,
  validarTextoCabecalhoSmtp,
} from "./provedor.ts";
import {
  alertaParaEquipe,
  DadosDaOcorrencia,
  Destino,
  modeloDe,
} from "./modelos.ts";

export const TETO_DE_LEITURAS = 5;
export const LIMITE_PADRAO_EMAIL = 20;
export const LIMITE_MAXIMO_EMAIL = 200;
export const VT_PADRAO_EMAIL = 60;
export const VT_MAXIMO_EMAIL = 300;

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
  // Rastro da falha de envio em `privado.falha_execucao` (origem `enviar_email`), que o
  // `/saude` lê. Só o código, sem destinatário nem texto de erro (RN15). Cartão bB0tV5R8.
  registrarFalhaOperacional: (codigo: string) => Promise<void>;
  concluir: (msgId: number) => Promise<void>;
}

export interface Dependencias {
  agendadorSecret?: string;
  enviar?: Enviar;
  sqlClient?: SqlClient;
  dbUrl?: string;
  caixaDaEquipe?: string;
  caixaDosCasos?: string;
  caixaResponderPara?: string;
}

const AGENDADOR_SECRET = Deno.env.get("AGENDADOR_SECRET");
if (!AGENDADOR_SECRET || AGENDADOR_SECRET.trim() === "") {
  throw new Error("AGENDADOR_SECRET é obrigatório e deve estar configurado no ambiente.");
}

function segredoValido(req: Request, agendadorSecret?: string): boolean {
  const secret = agendadorSecret || AGENDADOR_SECRET;
  return segredoAgendadorValido(req, secret ?? "");
}

const CAIXA_DE_SUPORTE = "suporte@frilabr.com";

// A forma mínima de um endereço: um @ só, parte local e domínio com ponto, sem espaço.
// Fica aqui, e não no `validarDestinatario`, que só barra injeção de cabeçalho e é usado
// em outros lugares.
const FORMA_MINIMA_DE_EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

// A caixa da Equipe Frila é segredo de ambiente, e não linha de tabela: ela não é dado
// do produto, muda com o provedor de e-mail e não deve viajar num `db reset`.
// É SÓ para os alertas técnicos do monitoramento (tipo `alerta`). Os casos de usuário
// (denúncia, contestação, revisão de despacho) vão para a `caixaDosCasos`. Ela nunca vira
// o Reply-To do e-mail que sai para fora (esse é o `caixaResponderPara`).
export function caixaDaEquipe(injetada?: string): string {
  return (injetada || Deno.env.get("EMAIL_EQUIPE") || CAIXA_DE_SUPORTE).trim();
}

// Para onde vai o aviso interno de um caso de usuário: denúncia, contestação e revisão de
// despacho. Lê o EMAIL_CASOS; se faltar, vier vazio, falhar no `validarDestinatario` ou
// não tiver a forma mínima de e-mail, é a caixa de suporte. Nunca cai no EMAIL_EQUIPE:
// o caso traz dado pessoal e não pode ir parar na caixa dos alertas técnicos só porque a
// variável não foi configurada.
export function caixaDosCasos(injetada?: string): string {
  return caixaValida([injetada, Deno.env.get("EMAIL_CASOS")]);
}

// Para onde vai a resposta de quem recebeu o protocolo (o Reply-To ao autor). Lê o
// EMAIL_RESPONDER_PARA; se faltar, vier vazia, falhar no `validarDestinatario` ou não
// tiver a forma mínima de e-mail, é a caixa de suporte. Nunca
// cai no EMAIL_EQUIPE: a resposta do usuário traz dado pessoal e não pode ir parar num
// destino interno só porque a variável de atendimento não foi configurada.
export function caixaResponderPara(injetada?: string): string {
  return caixaValida([injetada, Deno.env.get("EMAIL_RESPONDER_PARA")]);
}

// A guarda das caixas que não podem cair no EMAIL_EQUIPE: a primeira candidata não vazia
// vale se passar no `validarDestinatario` e tiver a forma mínima de e-mail; senão (ou se
// todas faltarem) é a caixa de suporte.
function caixaValida(candidatas: Array<string | undefined>): string {
  for (const candidata of candidatas) {
    if (candidata === undefined || candidata.trim() === "") continue;
    const valor = candidata.trim();
    return validarDestinatario(valor) && FORMA_MINIMA_DE_EMAIL.test(valor)
      ? valor
      : CAIXA_DE_SUPORTE;
  }
  return CAIXA_DE_SUPORTE;
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

    registrarFalhaOperacional: (codigo) =>
      com(async (sql) => {
        await sql`
          select privado.registrar_falha_execucao(
            'enviar_email'::text, ${codigo}::text, null
          )
        `;
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

// Falha de envio que a sonda `/saude` precisa ver. Quando o pedido é arquivado sem ter
// saído, a fila fica vazia e nada mais denuncia o problema: o alerta que explicaria a
// falha é justamente o que não saiu. O registro não pode impedir o arquivamento, e por
// isso nunca relança.
async function registrarRastroDaFalha(sql: SqlClient, codigo: string): Promise<void> {
  try {
    await sql.registrarFalhaOperacional(codigo);
  } catch {
    // Sem detalhe: a mensagem do driver pode trazer a URL do banco.
    console.error("enviar-email: não gravei o rastro da falha de envio");
  }
}

// Recusa que diz algo sobre a infraestrutura de e-mail, e não sobre a caixa de uma
// pessoa. Um 550 para um endereço digitado errado não é incidente: acenderia a sonda por
// causa de um usuário. Já a caixa da equipe e as falhas de autenticação e de conexão são.
const CODIGOS_DE_INFRAESTRUTURA = new Set(["falha_de_autenticacao", "falha_de_conexao"]);

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
  if (!validarDestinatario(equipe) || !validarTextoCabecalhoSmtp(modelo.assunto)) {
    await registrarRastroDaFalha(sql, "destinatario_invalido");
    await sql.concluir(pedido.msg_id);
    return { msg_id: pedido.msg_id, status: "arquivado", detalhe: "destinatario_invalido" };
  }

  const r = await enviar({ para: equipe, assunto: modelo.assunto, texto: modelo.texto });

  if (r.ok) {
    await sql.concluir(pedido.msg_id);
    return { msg_id: pedido.msg_id, status: "enviado" };
  }
  if (r.transitorio && pedido.read_ct < TETO_DE_LEITURAS) {
    return { msg_id: pedido.msg_id, status: "pendente", detalhe: r.codigo };
  }
  await registrarRastroDaFalha(sql, r.codigo ?? "erro_nao_classificado");
  await sql.concluir(pedido.msg_id);
  return { msg_id: pedido.msg_id, status: "arquivado", detalhe: r.codigo };
}

async function processarOcorrencia(
  pedido: PedidoDaFila,
  tipo: string,
  enviar: Enviar,
  casos: string,
  responderParaAutor: string,
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
  if (dados.equipe_pendente) destinos.push({ destino: "equipe", para: casos });
  if (dados.autor_pendente && dados.autor_email) {
    destinos.push({ destino: "autor", para: dados.autor_email });
  }

  if (destinos.length === 0) {
    await sql.concluir(pedido.msg_id);
    return { msg_id: pedido.msg_id, status: "arquivado", detalhe: "nada_pendente" };
  }

  let ultimoErro: ResultadoEnvio | null = null;
  let rastroDaSonda: string | null = null;

  for (const { destino, para } of destinos) {
    const modelo = modeloDe(tipo, destino, dados);
    if (!modelo) {
      // Tipo que esta função não sabe escrever. Arquivar em silêncio esconderia a
      // lacuna; o código fica no banco, visível em `ocorrencia.email_ultimo_erro`.
      await sql.registrarFalha(ocorrenciaId, "tipo_desconhecido");
      await sql.concluir(pedido.msg_id);
      return { msg_id: pedido.msg_id, status: "arquivado", detalhe: "tipo_desconhecido" };
    }

    const responderPara = destino === "autor" ? responderParaAutor : undefined;

    if (
      !validarDestinatario(para) ||
      (responderPara && !validarDestinatario(responderPara)) ||
      !validarTextoCabecalhoSmtp(modelo.assunto)
    ) {
      await sql.registrarFalha(ocorrenciaId, "destinatario_invalido");
      await sql.concluir(pedido.msg_id);
      return { msg_id: pedido.msg_id, status: "arquivado", detalhe: "destinatario_invalido" };
    }

    const email: Email = {
      para,
      assunto: modelo.assunto,
      texto: modelo.texto,
      // A Equipe Frila só responde por e-mail: a resposta de quem recebeu o protocolo
      // tem de cair na caixa de atendimento, e não no remetente que não lê nem na
      // caixa dos alertas (EMAIL_EQUIPE).
      responderPara,
    };

    const r = await enviar(email);
    if (r.ok) {
      await sql.registrarEnviado(ocorrenciaId, destino, dados.prazo_resposta_ate ?? null);
    } else {
      ultimoErro = r;
      const codigoDaFalha = r.codigo ?? "erro_nao_classificado";
      if (
        rastroDaSonda === null &&
        (destino === "equipe" || CODIGOS_DE_INFRAESTRUTURA.has(codigoDaFalha))
      ) {
        rastroDaSonda = codigoDaFalha;
      }
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

  if (rastroDaSonda !== null) await registrarRastroDaFalha(sql, rastroDaSonda);
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
  const limite =
    typeof corpo.limite === "number" && Number.isFinite(corpo.limite)
      ? Math.max(1, Math.min(Math.floor(corpo.limite), LIMITE_MAXIMO_EMAIL))
      : LIMITE_PADRAO_EMAIL;
  const vt =
    typeof corpo.vt === "number" && Number.isFinite(corpo.vt)
      ? Math.max(1, Math.min(Math.floor(corpo.vt), VT_MAXIMO_EMAIL))
      : VT_PADRAO_EMAIL;

  const sql = criarSqlClient(deps);
  const equipe = caixaDaEquipe(deps.caixaDaEquipe);
  const casos = caixaDosCasos(deps.caixaDosCasos);
  const responderParaAutor = caixaResponderPara(deps.caixaResponderPara);

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
      relatorio.push(
        await processarOcorrencia(pedido, tipo, enviar, casos, responderParaAutor, sql),
      );
    }
  }

  return json({ ok: true, processados: pedidos.length, relatorio }, 200);
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => await processarEnvioEmail(req));
}
