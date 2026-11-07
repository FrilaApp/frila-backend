// Edge Function expurgar-midias (cartão ZZ0WTtu4 · RN14 · LGPD art. 11, II, "g").
//
// Fecha a segunda fase do expurgo de mídia da verificação de identidade. A primeira fase é
// do banco: `privado.expurgar_midias_verificacao_identidade()` acha o que venceu, enfileira
// em `pgmq.expurgo_midia` e marca `expurgo_pedido_em`.
//
// POR QUE EXISTE ESTA FUNÇÃO, e não um `delete` no Postgres: apagar a linha de
// `storage.objects` não apaga o byte no Storage — o arquivo vive no backend de objetos, e
// quem o remove é a API do Storage. Pior: sem a linha de índice, o arquivo fica órfão e
// inalcançável. O Postgres recusa a remoção direta por trigger ("Direct deletion from
// storage tables is not allowed"), o que torna esta função a única porta real.
//
// O ciclo:
// 1. Valida o segredo do agendador (exclusivamente `x-agendador-secret`).
// 2. Lê um lote de `pgmq.expurgo_midia` com visibilidade temporária (`pgmq.read`).
// 3. Para cada mensagem, apaga cada caminho no bucket privado `documentos-identidade`.
//    404 conta como sucesso: o objetivo é a ausência do arquivo, não o ato de apagar.
// 4. Só com TODOS os caminhos ausentes: chama `privado.confirmar_expurgo_midia(id)` e
//    remove a mensagem da fila.
//
// A ordem de 4 é a regra que protege o acervo: confirmar antes de apagar anularia os
// caminhos no banco e deixaria o arquivo no bucket, sem ninguém para achá-lo — um registro
// de conformidade sobre uma foto que continua lá. Falha transitória do Storage não confirma
// e não remove da fila: a mensagem reaparece quando a visibilidade expira.
//
// Nada de dado pessoal em log (RN15): o que sai daqui é id de verificação, contagem e
// status HTTP. Nome, documento e imagem nunca passam por aqui.

import postgres from "npm:postgres@3.4.4";
import { segredoAgendadorValido } from "../_compartilhado/auth.ts";

const BUCKET_PADRAO = "documentos-identidade";
const LOTE_PADRAO = 20;
const VISIBILIDADE_SEGUNDOS = 120;
/** Leituras repetidas da mesma mensagem viram sinal: algo não sai do bucket. */
const LEITURAS_PARA_ALERTA = 5;

export interface Erro {
  code: string;
  message: string;
  details: string | null;
}

export interface MensagemExpurgo {
  msg_id: number;
  read_ct: number;
  verificacao_id: string;
  bucket: string;
  caminhos: string[];
  origem?: string;
}

export interface SqlClient {
  lerLote: (quantidade: number, visibilidade: number) => Promise<MensagemExpurgo[]>;
  validarExpurgo?: (verificacaoId: string, origem?: string, bucket?: string, caminhos?: string[]) => Promise<boolean>;
  confirmarExpurgo: (verificacaoId: string, origem?: string) => Promise<boolean>;
  removerDaFila: (msgId: number) => Promise<void>;
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

function segredoValido(req: Request, segredoEsperado: string): boolean {
  // Sem `Bearer`: o agendador manda cabeçalho próprio, e aceitar as duas formas aqui
  // ampliaria a superfície de uma função que apaga arquivo.
  return segredoAgendadorValido(req, segredoEsperado, { permitirBearer: false });
}

function criarSqlClient(deps?: HandlerDeps): SqlClient {
  if (deps?.sqlClient) {
    return deps.sqlClient;
  }
  const dbUrl = obterVariavel("SUPABASE_DB_URL", deps?.dbUrl);
  return {
    async lerLote(quantidade: number, visibilidade: number): Promise<MensagemExpurgo[]> {
      const sql = postgres(dbUrl, { max: 1, connect_timeout: 5 });
      try {
        const res = await sql`
          select msg_id,
                 read_ct,
                 message->>'verificacao_id' as verificacao_id,
                 coalesce(message->>'bucket', ${BUCKET_PADRAO}) as bucket,
                 coalesce(message->'caminhos', '[]'::jsonb) as caminhos,
                 coalesce(message->>'origem', 'verificacao') as origem
            from pgmq.read('expurgo_midia', ${visibilidade}::integer, ${quantidade}::integer)
        `;
        return res.map((r) => ({
          msg_id: Number(r.msg_id),
          read_ct: Number(r.read_ct ?? 0),
          verificacao_id: String(r.verificacao_id ?? ""),
          bucket: String(r.bucket ?? BUCKET_PADRAO),
          caminhos: Array.isArray(r.caminhos) ? (r.caminhos as string[]) : [],
          origem: String(r.origem ?? "verificacao"),
        }));
      } finally {
        await sql.end({ timeout: 2 });
      }
    },
    async validarExpurgo(
      verificacaoId: string,
      origem?: string,
      bucket?: string,
      caminhos?: string[],
    ): Promise<boolean> {
      const sql = postgres(dbUrl, { max: 1, connect_timeout: 5 });
      try {
        if (origem === "foto_perfil") {
          const res = await sql`
            select privado.validar_expurgo_midia_perfil(
              ${verificacaoId}::uuid,
              ${bucket ?? "midia-perfil"},
              ${JSON.stringify(caminhos ?? [])}::jsonb
            ) as ok
          `;
          return res[0]?.ok === true;
        } else {
          if (bucket && bucket !== "documentos-identidade") return false;
          const res = await sql`
            select 1 from privado.verificacao_identidade
             where id = ${verificacaoId}::uuid
               and expurgo_pedido_em is not null
          `;
          return Boolean(res[0]);
        }
      } finally {
        await sql.end({ timeout: 2 });
      }
    },
    async confirmarExpurgo(verificacaoId: string, origem?: string): Promise<boolean> {
      const sql = postgres(dbUrl, { max: 1, connect_timeout: 5 });
      try {
        if (origem === "foto_perfil") {
          const res = await sql`
            select privado.confirmar_expurgo_midia_perfil(${verificacaoId}::uuid) as ok
          `;
          return res[0]?.ok === true;
        } else {
          const res = await sql`
            select privado.confirmar_expurgo_midia(${verificacaoId}::uuid) as ok
          `;
          return res[0]?.ok === true;
        }
      } finally {
        await sql.end({ timeout: 2 });
      }
    },
    async removerDaFila(msgId: number): Promise<void> {
      const sql = postgres(dbUrl, { max: 1, connect_timeout: 5 });
      try {
        await sql`select pgmq.delete('expurgo_midia', ${msgId}::bigint)`;
      } finally {
        await sql.end({ timeout: 2 });
      }
    },
  };
}

/**
 * Remove um objeto do bucket. Devolve `true` quando o arquivo deixou de existir —
 * incluindo o caso em que ele já não existia (404), porque o que importa é a ausência.
 */
async function removerObjeto(
  fetchFn: typeof fetch,
  supabaseUrl: string,
  serviceRoleKey: string,
  bucket: string,
  caminho: string,
): Promise<{ ausente: boolean; status: number }> {
  const url = `${supabaseUrl.replace(/\/+$/, "")}/storage/v1/object/${bucket}/${
    caminho.split("/").map(encodeURIComponent).join("/")
  }`;

  let resp: Response;
  try {
    resp = await fetchFn(url, {
      method: "DELETE",
      headers: {
        Authorization: `Bearer ${serviceRoleKey}`,
        apikey: serviceRoleKey,
      },
    });
  } catch (_err) {
    // Rede indisponível é transitória por definição: não há como afirmar ausência.
    return { ausente: false, status: 0 };
  }

  // 404 do Storage significa ausência comprovada. 400 só é aceito se o corpo indicar explicitamente
  // objeto inexistente (ex: not_found / NoSuchKey); erro genérico (ex: InvalidRequest) não comprova ausência.
  if (resp.ok || resp.status === 404) {
    return { ausente: true, status: resp.status };
  }
  if (resp.status === 400) {
    try {
      const json = await resp.clone().json();
      const txt = JSON.stringify(json).toLowerCase();
      if (txt.includes("not_found") || txt.includes("not found") || txt.includes("nosuchkey")) {
        return { ausente: true, status: resp.status };
      }
    } catch {
      // corpo ilegível não comprova ausência
    }
  }
  return { ausente: false, status: resp.status };
}

export async function handler(req: Request, deps?: HandlerDeps): Promise<Response> {
  if (req.method !== "POST") {
    return resposta(405, { code: "metodo_nao_permitido", message: "metodo_nao_permitido", details: null });
  }

  const agendadorSecret = obterVariavel("AGENDADOR_SECRET", deps?.agendadorSecret);
  if (!segredoValido(req, agendadorSecret)) {
    return resposta(401, { code: "nao_autenticado", message: "nao_autenticado", details: null });
  }

  const supabaseUrl = obterVariavel("SUPABASE_URL", deps?.supabaseUrl);
  const serviceRoleKey = obterVariavel("SUPABASE_SERVICE_ROLE_KEY", deps?.serviceRoleKey);
  const fetchFn = deps?.fetchFn ?? fetch;
  const sqlClient = criarSqlClient(deps);

  let corpo: { lote?: unknown } = {};
  try {
    corpo = await req.json();
  } catch {
    corpo = {};
  }
  let lote = LOTE_PADRAO;
  if (typeof corpo.lote === "number" && Number.isFinite(corpo.lote)) {
    lote = Math.min(Math.max(Math.trunc(corpo.lote), 1), 100);
  }

  let mensagens: MensagemExpurgo[];
  try {
    mensagens = await sqlClient.lerLote(lote, VISIBILIDADE_SEGUNDOS);
  } catch (_err) {
    // Fila ilegível é portão não rodado, e não fila vazia: 500 para o agendador registrar.
    return resposta(500, { code: "erro_interno", message: "erro_interno", details: null });
  }

  if (mensagens.length === 0) {
    return resposta(200, {
      ok: true,
      mensagens_lidas: 0,
      verificacoes_confirmadas: 0,
      arquivos_removidos: 0,
      pendentes: [],
      alertas: [],
    });
  }

  let arquivosRemovidos = 0;
  const confirmadas: string[] = [];
  const pendentes: Array<{ verificacao_id: string; msg_id: number; status: number; read_ct: number }> = [];
  const alertas: Array<{ verificacao_id: string; msg_id: number; read_ct: number }> = [];

  for (const msg of mensagens) {
    if (!msg.verificacao_id) {
      // Mensagem sem id não tem o que confirmar, e ficar relendo não conserta: sai da fila
      // e aparece na resposta, que é o lugar onde alguém olha.
      await sqlClient.removerDaFila(msg.msg_id).catch(() => {});
      pendentes.push({ verificacao_id: "", msg_id: msg.msg_id, status: 422, read_ct: msg.read_ct });
      continue;
    }

    // Validação prévia de elegibilidade e posse do expurgo (Achado 4 Lince Codex)
    // Confere mídia, estado elegível, bucket e caminhos antes de qualquer exclusão no Storage.
    if (sqlClient.validarExpurgo) {
      let elegivel = false;
      try {
        elegivel = await sqlClient.validarExpurgo(msg.verificacao_id, msg.origem, msg.bucket, msg.caminhos);
      } catch {
        elegivel = false;
      }
      if (!elegivel) {
        pendentes.push({
          verificacao_id: msg.verificacao_id,
          msg_id: msg.msg_id,
          status: 409,
          read_ct: msg.read_ct,
        });
        continue;
      }
    }

    let todosAusentes = true;
    let ultimoStatus = 200;

    for (const caminho of msg.caminhos) {
      if (!caminho) continue;
      const r = await removerObjeto(fetchFn, supabaseUrl, serviceRoleKey, msg.bucket, caminho);
      if (r.ausente) {
        arquivosRemovidos += 1;
      } else {
        todosAusentes = false;
        ultimoStatus = r.status;
      }
    }

    if (!todosAusentes) {
      // Nem confirma no banco nem remove da fila: a mensagem volta quando a visibilidade
      // expirar. Confirmar aqui seria registrar conformidade sobre arquivo que ficou.
      pendentes.push({
        verificacao_id: msg.verificacao_id,
        msg_id: msg.msg_id,
        status: ultimoStatus,
        read_ct: msg.read_ct,
      });
      if (msg.read_ct >= LEITURAS_PARA_ALERTA) {
        alertas.push({ verificacao_id: msg.verificacao_id, msg_id: msg.msg_id, read_ct: msg.read_ct });
      }
      continue;
    }

    try {
      const confirmou = await sqlClient.confirmarExpurgo(msg.verificacao_id, msg.origem);
      if (!confirmou) {
        pendentes.push({
          verificacao_id: msg.verificacao_id,
          msg_id: msg.msg_id,
          status: 409,
          read_ct: msg.read_ct,
        });
        continue;
      }
    } catch (_err) {
      // O arquivo já saiu, mas o banco não soube. Deixar na fila é o certo: a próxima
      // rodada reencontra os caminhos ausentes (404 = sucesso) e confirma.
      pendentes.push({
        verificacao_id: msg.verificacao_id,
        msg_id: msg.msg_id,
        status: 500,
        read_ct: msg.read_ct,
      });
      continue;
    }

    await sqlClient.removerDaFila(msg.msg_id).catch(() => {});
    confirmadas.push(msg.verificacao_id);
  }

  return resposta(200, {
    ok: true,
    mensagens_lidas: mensagens.length,
    verificacoes_confirmadas: confirmadas.length,
    arquivos_removidos: arquivosRemovidos,
    pendentes,
    alertas,
  });
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => {
    return await handler(req);
  });
}
