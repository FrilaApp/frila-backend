// Decisão pura: nenhum relógio, rede, KV ou log implícito.
export const CONFIRMACAO_MS = 60_000;
export const LEMBRETE_MS = 3_600_000;
export const ATRASO_MS = 900_000;

export function interpretarResposta(codigo, corpo) {
  let dados;
  try { dados = JSON.parse(corpo); } catch { dados = null; }
  if (codigo === 200) {
    if (dados?.ok === true) return { ok: true, motivo: '' };
    return { ok: false, motivo: dados === null
      ? 'HTTP 200 com corpo que não é JSON' : 'HTTP 200 sem ok=true' };
  }
  const status = typeof dados?.status === 'string' && /^[a-z_]{1,30}$/.test(dados.status)
    ? ` (status: ${dados.status})` : '';
  return { ok: false, motivo: `HTTP ${codigo}${status}` };
}

export function formatarDuracao(ms) {
  const minutos = Math.floor(Math.max(0, ms) / 60_000);
  if (minutos < 60) return `${minutos} min`;
  const horas = Math.floor(minutos / 60);
  const resto = minutos % 60;
  return resto ? `${horas} h ${String(resto).padStart(2, '0')} min` : `${horas} h`;
}

export function decidir(resultado, anterior, agora, avisoTeste = '') {
  const estado = {
    ultimaExecucao: agora,
    inicioQueda: anterior?.inicioQueda ?? null,
    ultimoAviso: anterior?.ultimoAviso ?? null,
    avisoTeste: anterior?.avisoTeste ?? '',
  };
  const avisos = [];
  if (anterior && agora - anterior.ultimaExecucao > ATRASO_MS) {
    avisos.push({ acao: 'atraso', duracao: agora - anterior.ultimaExecucao });
  }
  if (resultado.ok) {
    if (estado.inicioQueda !== null) {
      avisos.push({ acao: 'recuperado', duracao: agora - estado.inicioQueda });
    }
    estado.inicioQueda = null;
    estado.ultimoAviso = null;
  } else if (estado.inicioQueda === null) {
    estado.inicioQueda = agora;
    estado.ultimoAviso = agora;
    avisos.push({ acao: 'primeiro', duracao: 0 });
  } else if (agora - estado.ultimoAviso >= LEMBRETE_MS) {
    estado.ultimoAviso = agora;
    avisos.push({ acao: 'lembrete', duracao: agora - estado.inicioQueda });
  }
  // A etiqueta serve apenas à deduplicação; seu conteúdo nunca vira mensagem/log.
  if (/^[a-zA-Z0-9_-]{1,64}$/.test(avisoTeste) && estado.avisoTeste !== avisoTeste) {
    avisos.push({ acao: 'teste', duracao: 0 });
    estado.avisoTeste = avisoTeste;
  }
  return { estado, avisos };
}

export function montarAviso({ acao, duracao }, motivo) {
  const guia = 'Runbook: `docs/RunbookWalESlot.md` (seções 3 e 6).';
  switch (acao) {
    case 'primeiro':
      return '🔴 Prod: a função saude não responde\n'
        + 'A `saude` do frila-prod não respondeu 200 com `ok: true` em duas tentativas com ~60 s de intervalo.\n'
        + `*Motivo:* ${motivo}.\n`
        + 'Próximo aviso: lembrete a cada ~1 h enquanto durar e um aviso quando voltar ao normal. '
        + 'Abra o projeto no painel do Supabase antes de supor pausa. ' + guia;
    case 'lembrete':
      return '🔴 Prod: a função saude continua sem responder\n'
        + `A \`saude\` do frila-prod segue fora há pelo menos ${formatarDuracao(duracao)}.\n`
        + `*Último motivo:* ${motivo}.\n` + guia;
    case 'recuperado':
      return '🟢 Prod: a função saude voltou ao normal\n'
        + 'A `saude` do frila-prod voltou a responder 200 com `ok: true` depois de cerca de '
        + `${formatarDuracao(duracao)} de queda (medida a cada 5 min).`;
    case 'atraso':
      return '🟠 Vigia da saúde ficou sem rodar\n'
        + `A última execução do vigia da \`saude\` foi há ${formatarDuracao(duracao)} (limite: 15 min). `
        + 'O Cron Trigger do Cloudflare atrasou ou pulou execuções. Confira o Worker frila-vigia-saude e seu cron. '
        + 'Durante o intervalo, o Prod ficou sem este vigia. ' + guia;
    case 'teste':
      return 'TESTE: vigia da saúde do Prod no Cloudflare ativo. ' + guia;
    default:
      throw new Error('Ação de aviso desconhecida');
  }
}
