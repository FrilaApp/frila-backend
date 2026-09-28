// Edge Function enviar-push: Envio de notificações push pelo FCM HTTP v1.
// Cartão 36fU0CEO: Envio de push pelo FCM, registro do aparelho e estado de entrega.
//
// 1. Lê a conta de serviço do FCM exclusivamente de variável de ambiente (FCM_SERVICE_ACCOUNT).
// 2. Envia mensagens via FCM HTTP v1 para todos os aparelhos do usuario_id da notificação.
// 3. Atualiza estado_entrega no banco:
//    - 200 grava o aceite (estado_entrega = 'enviada', enviada_em = instante real do envio, aceita_em = instante do aceite).
//    - 404/410 ou UNREGISTERED remove o token do banco e grava falha.
//    - Erro transitório faz nova tentativa com backoff exponencial respeitando o teto de 5 tentativas.
//    - Não reenvia se a vaga ou turno já tiver iniciado, nem antes de proxima_tentativa_em.

import {
  FcmServiceAccount,
  getAccessToken,
  sendFcmMessage,
  FcmSendResult,
} from "./fcm.ts";

export interface Dependencias {
  supabaseUrl?: string;
  serviceRoleKey?: string;
  agendadorSecret?: string;
  serviceAccount?: FcmServiceAccount;
  fetchFn?: typeof fetch;
  fcmApiUrl?: string;
  fcmTokenUri?: string;
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
  if (!secret || secret.trim() === "") {
    return false;
  }

  const secretHeader = req.headers.get("x-agendador-secret");
  if (secretHeader && igualEmTempoConstante(secretHeader, secret)) {
    return true;
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (match && igualEmTempoConstante(match[1], secret)) {
    return true;
  }

  return false;
}

export function carregarContaDeServico(): FcmServiceAccount | null {
  const raw =
    Deno.env.get("FCM_SERVICE_ACCOUNT") ||
    Deno.env.get("FIREBASE_SERVICE_ACCOUNT");

  if (!raw) return null;

  try {
    const texto = raw.trim().startsWith("{")
      ? raw
      : atob(raw); // suporta base64
    return JSON.parse(texto) as FcmServiceAccount;
  } catch (e) {
    console.error("Erro ao fazer parse de FCM_SERVICE_ACCOUNT:", e);
    return null;
  }
}

export const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CHAVES_UUID_PERMITIDAS = [
  "vaga_id",
  "posicao_id",
  "turno_id",
  "estabelecimento_id",
] as const;

export function filtrarDataPayloadFcm(
  tipo: string,
  payload?: Record<string, unknown> | null,
): Record<string, string> {
  const data: Record<string, string> = { tipo };
  if (!payload || typeof payload !== "object") {
    return data;
  }

  for (const chave of CHAVES_UUID_PERMITIDAS) {
    const valor = payload[chave];
    if (typeof valor === "string" && UUID_REGEX.test(valor.trim())) {
      data[chave] = valor.trim();
    }
  }

  if (typeof payload.reaberta === "boolean") {
    data.reaberta = String(payload.reaberta);
  }

  return data;
}

export function calcularProximaTentativa(
  tentativas: number,
  baseSegundos = 10,
  agora: Date = new Date(),
): Date {
  const segundos = baseSegundos * Math.pow(2, Math.max(0, tentativas - 1));
  return new Date(agora.getTime() + segundos * 1000);
}

// Variáveis do texto, lidas no banco na hora do envio (Op. A da planilha de
// notificações, aprovada em 28/09, e casos de texto variável por ocorrência).
// Só dado do turno — nome da função do catálogo e horário —, nunca de pessoa, telefone
// ou endereço (RN10, RN15). Ausentes, o texto cai na Op. B da mesma planilha.
export interface VariaveisDoTexto {
  funcao?: string;
  horario?: string;
  // Cancelamento feito por `reabrir_por_atraso` (caso 17 da planilha, cartão e8XpOZJN).
  reaberturaPorAtraso?: boolean;
}

export type ContextoDoTexto = VariaveisDoTexto;

// Horário de Brasília em 24 h ("18:00"): o DF não tem horário de verão, e o banco
// guarda UTC (RN18).
export function formatarHorario(iso: string): string | undefined {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return undefined;
  return new Intl.DateTimeFormat("pt-BR", {
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
    timeZone: "America/Sao_Paulo",
  }).format(d);
}

// Lê as variáveis de que o texto do tipo precisa. Falha de leitura não segura o push:
// devolve vazio, e o texto sai pelo fallback genérico / Op. B.
export async function buscarVariaveisDoTexto(
  tipo: string,
  payload: Record<string, unknown> | null | undefined,
  consultar: (caminho: string) => Promise<Response>,
): Promise<VariaveisDoTexto> {
  try {
    if (tipo === "vaga_vazia") {
      const posicao = payload?.posicao_id;
      if (typeof posicao !== "string" || !UUID_REGEX.test(posicao)) return {};
      const res = await consultar(
        `posicao?id=eq.${posicao}&select=inicio_em,vaga(funcao(nome))`,
      );
      if (!res.ok) return {};
      const [linha] = await res.json();
      return {
        funcao: linha?.vaga?.funcao?.nome ?? undefined,
        horario: linha?.inicio_em ? formatarHorario(linha.inicio_em) : undefined,
      };
    }
    if (tipo === "cancelamento") {
      const posicaoId = payload?.posicao_id;
      if (typeof posicaoId !== "string" || !UUID_REGEX.test(posicaoId)) return {};
      // O motivo é estável (`reabertura_por_atraso`) e fica no banco; o texto muda, o
      // payload não. Falha de leitura cai no texto genérico em vez de segurar o push.
      const ocoRes = await consultar(
        `ocorrencia?posicao_id=eq.${posicaoId}&tipo=eq.cancelamento&motivo=eq.reabertura_por_atraso&select=id&limit=1`,
      );
      if (!ocoRes.ok) return {};
      const linhas = await ocoRes.json();
      return {
        reaberturaPorAtraso: Array.isArray(linhas) && linhas.length > 0,
      };
    }
  } catch {
    // Sem log do erro: a resposta pode trazer dado do banco.
  }
  return {};
}

export function titulosECorposPorTipo(
  tipo: string,
  _payload: Record<string, unknown> = {},
  variaveis: VariaveisDoTexto = {},
): { title: string; body: string } {
  switch (tipo) {
    case "vaga":
      return {
        title: "Nova vaga disponível",
        body: "Há uma nova vaga compatível com seu perfil no Frila.",
      };
    case "vagas_agrupadas":
      return {
        title: "Vagas disponíveis",
        body: "Novas vagas compatíveis com seu perfil no Frila.",
      };
    case "confirmacao":
      return {
        title: "Turno confirmado",
        body: "O seu turno foi confirmado. Acesse os detalhes no app.",
      };
    case "lembrete_24h":
      return {
        title: "Lembrete de turno",
        body: "Você tem um turno agendado para amanhã.",
      };
    case "lembrete_3h":
      return {
        title: "Lembrete de turno",
        body: "Seu turno começa em 3 horas. Prepare-se.",
      };
    // Casos 13 e 16 da planilha de notificações (cartão e8XpOZJN).
    case "inicio_sem_checkin":
      return {
        title: "Horário de início do turno",
        body: "O horário de início chegou. Faça seu check-in ao chegar ao local.",
      };
    case "atraso_15min":
      return {
        title: "Check-in pendente há 15 min",
        body: "O profissional ainda não registrou presença. Você pode aguardar ou reabrir a vaga.",
      };
    case "fim_sem_checkout":
      return {
        title: "Check-out pendente",
        body: "O horário previsto do turno encerrou. Registre o check-out.",
      };
    // Push 06 da planilha de notificações (cartão vUR0Ltkb).
    case "vaga_vazia":
      return {
        title: "Vaga ainda em aberto",
        body: variaveis.funcao && variaveis.horario
          ? `A posição de ${variaveis.funcao} das ${variaveis.horario} ainda não foi preenchida.`
          : "Sua vaga ainda possui posição em aberto próxima ao horário.",
      };
    case "checkin":
      return {
        title: "Check-in realizado",
        body: "O profissional realizou o check-in no turno.",
      };
    case "checkin_manual_pendente":
      return {
        title: "Confirmação de check-in necessária",
        body: "Check-in manual registrado, aguardando confirmação do contratante.",
      };
    case "cancelamento":
      // Caso 17 da planilha: a casa reabriu a vaga por falta de check-in.
      if (variaveis.reaberturaPorAtraso) {
        return {
          title: "Turno cancelado por atraso",
          body: "O contratante reabriu a vaga por falta de check-in. O turno foi cancelado.",
        };
      }
      return {
        title: "Aviso de cancelamento",
        body: "Houve um cancelamento relacionado ao seu turno ou vaga.",
      };
    case "avaliacao_disponivel":
      return {
        title: "Avaliação disponível",
        body: "O turno foi concluído. Avalie a experiência no Frila.",
      };
    default:
      return {
        title: "Notificação Frila",
        body: "Você tem uma nova notificação no Frila.",
      };
  }
}

export async function processarEnvioPush(
  req: Request,
  deps: Dependencias = {},
): Promise<Response> {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ ok: false, erro: "metodo_nao_permitido" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabaseUrl =
    deps.supabaseUrl || Deno.env.get("SUPABASE_URL") || "http://127.0.0.1:54321";
  const serviceRoleKey =
    deps.serviceRoleKey || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const fetchFn = deps.fetchFn || fetch;

  if (!segredoValido(req, deps.agendadorSecret)) {
    return new Response(JSON.stringify({ ok: false, erro: "nao_autorizado" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const sa = deps.serviceAccount || carregarContaDeServico();
  if (!sa) {
    return new Response(
      JSON.stringify({
        ok: false,
        erro: "fcm_service_account_nao_configurada",
        mensagem: "Conta de serviço FCM não configurada em segredo de ambiente.",
      }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  let corpo: Record<string, unknown> = {};
  try {
    corpo = await req.json();
  } catch {
    corpo = {};
  }

  const notificacaoId =
    typeof corpo?.notificacao_id === "string" ? corpo.notificacao_id : null;
  const limite = typeof corpo?.limite === "number" ? corpo.limite : 50;

  // Headers de acesso ao PostgREST com service_role
  const dbHeaders: Record<string, string> = {
    apikey: serviceRoleKey,
    Authorization: `Bearer ${serviceRoleKey}`,
    "Content-Type": "application/json",
    Prefer: "return=representation",
  };

  // Helper para chamar RPCs privadas
  async function chamarRpc(nome: string, params: Record<string, unknown>) {
    const res = await fetchFn(`${supabaseUrl}/rest/v1/rpc/${nome}`, {
      method: "POST",
      headers: dbHeaders,
      body: JSON.stringify(params),
    });
    return res;
  }

  let notificacoes: Array<{
    id: string;
    usuario_id: string;
    tipo: string;
    referencia_id: string;
    payload: Record<string, unknown>;
    tentativas: number;
    estado_entrega: string;
    proxima_tentativa_em?: string | null;
  }> = [];

  if (notificacaoId) {
    const res = await fetchFn(
      `${supabaseUrl}/rest/v1/notificacao?id=eq.${notificacaoId}&select=id,usuario_id,tipo,referencia_id,payload,tentativas,estado_entrega,proxima_tentativa_em`,
      { headers: dbHeaders },
    );
    if (!res.ok) {
      return new Response(
        JSON.stringify({ ok: false, erro: "erro_ao_buscar_notificacao" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
    notificacoes = await res.json();
  } else {
    // Processamento da fila de pendentes (não busca notificações cujo backoff ainda não venceu)
    const agoraIso = new Date().toISOString();
    const res = await fetchFn(
      `${supabaseUrl}/rest/v1/notificacao?estado_entrega=eq.pendente&or=(proxima_tentativa_em.is.null,proxima_tentativa_em.lte.${encodeURIComponent(agoraIso)})&order=enviada_em.asc&limit=${limite}&select=id,usuario_id,tipo,referencia_id,payload,tentativas,estado_entrega,proxima_tentativa_em`,
      { headers: dbHeaders },
    );
    if (!res.ok) {
      return new Response(
        JSON.stringify({ ok: false, erro: "erro_ao_buscar_pendentes" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
    notificacoes = await res.json();
  }

  if (notificacoes.length === 0) {
    return new Response(
      JSON.stringify({ ok: true, processadas: 0, mensagem: "nenhuma_notificacao_pendente" }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }

  // Obter token de acesso do Google OAuth
  let accessToken = "";
  try {
    accessToken = await getAccessToken(sa, fetchFn);
  } catch (err) {
    console.error("Erro ao autenticar no Google OAuth:", err);
    return new Response(
      JSON.stringify({ ok: false, erro: "falha_oauth_google", detalhe: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  const relatorio: Array<{
    notificacao_id: string;
    status: string;
    detalhe?: string;
  }> = [];

  for (const n of notificacoes) {
    // 0. Não reenvia antes do vencimento do backoff exponencial
    if (n.proxima_tentativa_em && new Date(n.proxima_tentativa_em).getTime() > Date.now()) {
      relatorio.push({
        notificacao_id: n.id,
        status: "pendente",
        detalhe: "aguardando_backoff",
      });
      continue;
    }

    // 1. Verifica se a vaga ou turno já iniciou (sem reenviar depois do início)
    const expRes = await chamarRpc("notificacao_expirada", { p_notificacao_id: n.id });
    if (expRes.ok) {
      const expirada = await expRes.json();
      if (expirada === true) {
        await chamarRpc("gravar_falha_push", {
          p_notificacao_id: n.id,
          p_motivo: "vaga_ou_turno_ja_iniciado",
          p_permanente: true,
        });
        relatorio.push({
          notificacao_id: n.id,
          status: "falhou",
          detalhe: "vaga_ou_turno_ja_iniciado",
        });
        continue;
      }
    }

    // 2. Busca todos os aparelhos registrados da conta destinatária
    const dispRes = await fetchFn(
      `${supabaseUrl}/rest/v1/dispositivo?usuario_id=eq.${n.usuario_id}&select=id,token_fcm,plataforma`,
      { headers: dbHeaders },
    );

    const aparelhos: Array<{ id: string; token_fcm: string; plataforma: string }> =
      dispRes.ok ? await dispRes.json() : [];

    if (aparelhos.length === 0) {
      // Usuário sem nenhum aparelho registrado
      await chamarRpc("gravar_falha_push", {
        p_notificacao_id: n.id,
        p_motivo: "sem_dispositivo",
        p_permanente: true,
      });
      relatorio.push({
        notificacao_id: n.id,
        status: "falhou",
        detalhe: "sem_dispositivo",
      });
      continue;
    }

    const variaveis = await buscarVariaveisDoTexto(
      n.tipo,
      n.payload,
      (caminho) => fetchFn(`${supabaseUrl}/rest/v1/${caminho}`, { headers: dbHeaders }),
    );
    const { title, body } = titulosECorposPorTipo(n.tipo, n.payload, variaveis);
    const dataStrings = filtrarDataPayloadFcm(n.tipo, n.payload);

    let algumAceite = false;
    let algumUnregistered = false;
    let erroUltimo = "";
    let algumTransient = false;

    // Registra o instante real do envio ao FCM para fins de medição da RNF02
    const instanteEnvio = new Date().toISOString();

    // 4. Envia para cada aparelho
    for (const disp of aparelhos) {
      const resultado: FcmSendResult = await sendFcmMessage(
        sa.project_id,
        accessToken,
        {
          token: disp.token_fcm,
          title,
          body,
          data: dataStrings,
          plataforma: disp.plataforma,
        },
        { apiUrl: deps.fcmApiUrl, fetchFn },
      );

      if (resultado.ok) {
        algumAceite = true;
      } else {
        erroUltimo = resultado.error || "erro_desconhecido";
        if (resultado.unregistered) {
          algumUnregistered = true;
          // 404/410 UNREGISTERED remove o token do banco
          await chamarRpc("remover_token_fcm", { p_token: disp.token_fcm });
        }
        if (resultado.transient) {
          algumTransient = true;
        }
      }
    }

    // 5. Atualiza o estado da notificação
    if (algumAceite) {
      // 200 grava o aceite com instante real do envio e do aceite
      const instanteAceite = new Date().toISOString();
      await chamarRpc("gravar_aceite_push", {
        p_notificacao_id: n.id,
        p_enviada_em: instanteEnvio,
        p_aceita_em: instanteAceite,
      });
      relatorio.push({ notificacao_id: n.id, status: "enviada" });
    } else if (algumUnregistered && aparelhos.length === 1) {
      await chamarRpc("gravar_falha_push", {
        p_notificacao_id: n.id,
        p_motivo: "UNREGISTERED",
        p_permanente: true,
        p_enviada_em: instanteEnvio,
      });
      relatorio.push({
        notificacao_id: n.id,
        status: "falhou",
        detalhe: "UNREGISTERED",
      });
    } else if (algumTransient) {
      // Erro transitório faz nova tentativa com backoff exponencial e teto de 5
      const novaTentativa = n.tentativas + 1;
      const teto = 5;
      const atingiuTeto = novaTentativa >= teto;
      const proximaTentativa = atingiuTeto
        ? null
        : calcularProximaTentativa(novaTentativa);

      await chamarRpc("gravar_falha_push", {
        p_notificacao_id: n.id,
        p_motivo: `erro_transitorio: ${erroUltimo}`,
        p_permanente: false,
        p_teto: teto,
        p_proxima_tentativa_em: proximaTentativa ? proximaTentativa.toISOString() : null,
        p_enviada_em: instanteEnvio,
      });
      relatorio.push({
        notificacao_id: n.id,
        status: atingiuTeto ? "falhou" : "pendente",
        detalhe: `erro_transitorio: ${erroUltimo}`,
      });
    } else {
      await chamarRpc("gravar_falha_push", {
        p_notificacao_id: n.id,
        p_motivo: erroUltimo || "falha_envio",
        p_permanente: true,
        p_enviada_em: instanteEnvio,
      });
      relatorio.push({
        notificacao_id: n.id,
        status: "falhou",
        detalhe: erroUltimo,
      });
    }
  }

  return new Response(
    JSON.stringify({
      ok: true,
      processadas: notificacoes.length,
      relatorio,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => {
    return await processarEnvioPush(req);
  });
}
