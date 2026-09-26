// Edge Function enviar-push: Envio de notificações push pelo FCM HTTP v1.
// Cartão 36fU0CEO: Envio de push pelo FCM, registro do aparelho e estado de entrega.
//
// 1. Lê a conta de serviço do FCM exclusivamente de variável de ambiente (FCM_SERVICE_ACCOUNT).
// 2. Envia mensagens via FCM HTTP v1 para todos os aparelhos do usuario_id da notificação.
// 3. Atualiza estado_entrega no banco:
//    - 200 grava o aceite (estado_entrega = 'enviada', aceita_em = now()).
//    - 404/410 ou UNREGISTERED remove o token do banco e grava falha.
//    - Erro transitório faz nova tentativa respeitando o teto de 5 tentativas.
//    - Não reenvia se a vaga ou turno já tiver iniciado.

import {
  FcmServiceAccount,
  getAccessToken,
  sendFcmMessage,
  FcmSendResult,
} from "./fcm.ts";

export interface Dependencias {
  supabaseUrl?: string;
  serviceRoleKey?: string;
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

function autorizado(req: Request, serviceRoleKey: string): boolean {
  const secret =
    Deno.env.get("AGENDADOR_SECRET") ||
    serviceRoleKey ||
    "frila-agendador-segredo-local";

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

export function titulosECorposPorTipo(
  tipo: string,
  _payload: Record<string, unknown> = {},
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
    case "inicio_sem_checkin":
      return {
        title: "Hora de iniciar o turno",
        body: "O horário do turno começou. Não se esqueça de registrar o check-in.",
      };
    case "atraso_15min":
      return {
        title: "Alerta de atraso",
        body: "Check-in ainda não registrado 15 minutos após o início do turno.",
      };
    case "fim_sem_checkout":
      return {
        title: "Check-out pendente",
        body: "O horário previsto do turno encerrou. Registre o check-out.",
      };
    case "vaga_vazia":
      return {
        title: "Vaga sem confirmação",
        body: "Sua vaga ainda possui posições abertas na janela crítica.",
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

  if (!autorizado(req, serviceRoleKey)) {
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
  }> = [];

  if (notificacaoId) {
    const res = await fetchFn(
      `${supabaseUrl}/rest/v1/notificacao?id=eq.${notificacaoId}&select=id,usuario_id,tipo,referencia_id,payload,tentativas,estado_entrega`,
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
    // Processamento da fila de pendentes
    const res = await fetchFn(
      `${supabaseUrl}/rest/v1/notificacao?estado_entrega=eq.pendente&order=enviada_em.asc&limit=${limite}&select=id,usuario_id,tipo,referencia_id,payload,tentativas,estado_entrega`,
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

    // 3. Monta o payload do FCM
    const { title, body } = titulosECorposPorTipo(n.tipo, n.payload);
    const dataStrings: Record<string, string> = {
      tipo: n.tipo,
      referencia_id: n.referencia_id,
    };
    if (n.payload && typeof n.payload === "object") {
      for (const [k, v] of Object.entries(n.payload)) {
        if (v !== null && v !== undefined) {
          dataStrings[k] = String(v);
        }
      }
    }

    let algumAceite = false;
    let algumUnregistered = false;
    let erroUltimo = "";
    let algumTransient = false;

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
      // 200 grava o aceite
      await chamarRpc("gravar_aceite_push", {
        p_notificacao_id: n.id,
      });
      relatorio.push({ notificacao_id: n.id, status: "enviada" });
    } else if (algumUnregistered && aparelhos.length === 1) {
      await chamarRpc("gravar_falha_push", {
        p_notificacao_id: n.id,
        p_motivo: "UNREGISTERED",
        p_permanente: true,
      });
      relatorio.push({
        notificacao_id: n.id,
        status: "falhou",
        detalhe: "UNREGISTERED",
      });
    } else if (algumTransient) {
      // Erro transitório faz nova tentativa com teto de 5
      await chamarRpc("gravar_falha_push", {
        p_notificacao_id: n.id,
        p_motivo: `erro_transitorio: ${erroUltimo}`,
        p_permanente: false,
        p_teto: 5,
      });
      relatorio.push({
        notificacao_id: n.id,
        status: n.tentativas + 1 >= 5 ? "falhou" : "pendente",
        detalhe: `erro_transitorio: ${erroUltimo}`,
      });
    } else {
      await chamarRpc("gravar_falha_push", {
        p_notificacao_id: n.id,
        p_motivo: erroUltimo || "falha_envio",
        p_permanente: true,
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
