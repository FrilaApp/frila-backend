import { CONFIRMACAO_MS, decidir, interpretarResposta, montarAviso } from './logica.js';

const CHAVE_ESTADO = 'estado';
const TIMEOUT_MS = 20_000;
// Região do banco do Prod. Sem isto a saude roda na região mais perto do colo da Cloudflare
// que executa o Worker (ex.: Singapura) e a conexão cross-region estoura o timeout (alerta falso de 23/11/2026).
const REGIAO_SAUDE = 'sa-east-1';
const MAX_CORPO = 65_536;

async function lerCorpo(resposta) {
  if (!resposta.body) return '';
  const leitor = resposta.body.getReader();
  const partes = [];
  let tamanho = 0;
  try {
    for (;;) {
      const { done, value } = await leitor.read();
      if (done) break;
      tamanho += value.byteLength;
      if (tamanho > MAX_CORPO) {
        await leitor.cancel();
        return ''; // Não interpreta JSON parcial nem corpo sem limite.
      }
      partes.push(value);
    }
  } finally {
    leitor.releaseLock();
  }
  const bytes = new Uint8Array(tamanho);
  let posicao = 0;
  for (const parte of partes) {
    bytes.set(parte, posicao);
    posicao += parte.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

async function sondar(url, buscar) {
  try {
    const resposta = await buscar(url, {
      method: 'GET', redirect: 'manual', signal: AbortSignal.timeout(TIMEOUT_MS),
      headers: { 'User-Agent': 'frila-vigia-saude', 'x-region': REGIAO_SAUDE },
    });
    return interpretarResposta(resposta.status, await lerCorpo(resposta));
  } catch {
    // A exceção pode conter URL, token ou corpo: nunca a registra.
    return { ok: false, motivo: 'erro de rede ou sem resposta em 20 s' };
  }
}

async function enviarAviso(texto, env, buscar, registrarErro) {
  try {
    if (!env.SLACK_BOT_TOKEN || !env.SLACK_CANAL) throw new Error('Configuração ausente');
    const resposta = await buscar('https://slack.com/api/chat.postMessage', {
      method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(TIMEOUT_MS),
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${env.SLACK_BOT_TOKEN}`,
      },
      body: JSON.stringify({ channel: env.SLACK_CANAL, text: texto }),
    });
    const dados = JSON.parse(await lerCorpo(resposta));
    if (resposta.status !== 200 || dados?.ok !== true) {
      const erro = typeof dados?.error === 'string' && /^[a-z_]{1,40}$/.test(dados.error)
        ? ` (${dados.error})` : '';
      registrarErro(`Vigia: falha ao enviar aviso ao Slack${erro}.`);
    }
  } catch {
    registrarErro('Vigia: falha ao enviar aviso ao Slack.');
  }
}

// Efeitos isolados; testes injetam relógio, espera, fetch e log.
export async function executar(env, {
  buscar = globalThis.fetch,
  agora = Date.now,
  esperar = ms => new Promise(resolve => setTimeout(resolve, ms)),
  registrarErro = mensagem => console.error(mensagem),
} = {}) {
  const inicio = agora();
  const anterior = await env.ESTADO_VIGIA.get(CHAVE_ESTADO, 'json');
  let resultado = await sondar(env.URL_SAUDE, buscar);
  if (!resultado.ok) {
    await esperar(CONFIRMACAO_MS);
    resultado = await sondar(env.URL_SAUDE, buscar);
  }
  const { estado, avisos } = decidir(resultado, anterior, inicio, env.AVISO_TESTE);
  for (const aviso of avisos) {
    await enviarAviso(montarAviso(aviso, resultado.motivo), env, buscar, registrarErro);
  }
  // Uma única escrita reúne heartbeat, transições, lembrete e etiqueta de teste.
  // Falha de Slack também avança o estado: não repete avisos a cada cinco minutos.
  await env.ESTADO_VIGIA.put(CHAVE_ESTADO, JSON.stringify(estado));
  return { resultado, avisos };
}

export default {
  async scheduled(_evento, env) {
    try {
      await executar(env);
    } catch {
      console.error('Vigia: não foi possível concluir a execução ou persistir o estado.');
    }
  },
  fetch() {
    return new Response('ok', { status: 200, headers: { 'Content-Type': 'text/plain' } });
  },
};
