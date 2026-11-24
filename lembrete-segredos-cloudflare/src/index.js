import { decidir, lerSegredos, montarTexto } from './logica.js';

const TIMEOUT_MS = 20_000;
const MAX_CORPO = 65_536;

async function enviarAviso(texto, env, buscar, registrarErro) {
  try {
    if (!env.SLACK_BOT_TOKEN || !env.SLACK_CANAL) throw new Error('Configuração ausente');
    const resposta = await buscar('https://slack.com/api/chat.postMessage', {
      method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(TIMEOUT_MS),
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${env.SLACK_BOT_TOKEN}` },
      body: JSON.stringify({ channel: env.SLACK_CANAL, text: texto }),
    });
    const bruto = (await resposta.text()).slice(0, MAX_CORPO);
    const dados = JSON.parse(bruto);
    if (resposta.status !== 200 || dados?.ok !== true) {
      const erro = typeof dados?.error === 'string' && /^[a-z_]{1,40}$/.test(dados.error) ? ` (${dados.error})` : '';
      registrarErro(`Lembrete: falha ao enviar aviso ao Slack${erro}.`);
      return false;
    }
    return true;
  } catch {
    // A exceção pode conter URL ou token: nunca a registra.
    registrarErro('Lembrete: falha ao enviar aviso ao Slack.');
    return false;
  }
}

// Efeitos isolados; testes injetam relógio, fetch e log.
export async function executar(env, {
  buscar = globalThis.fetch,
  agora = Date.now,
  registrarErro = mensagem => console.error(mensagem),
  registrarInfo = mensagem => console.log(mensagem),
} = {}) {
  const lido = lerSegredos(env.SEGREDOS ?? '[]');
  if (lido.erro) {
    registrarErro(`Lembrete: ${lido.erro}.`);
    return { enviados: 0, erro: true };
  }
  const teste = typeof env.AVISO_TESTE === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(env.AVISO_TESTE);
  let avisos = decidir(lido.itens, agora());
  if (teste) {
    // Prova: UM aviso marcado como teste (o 1º segredo), mesmo fora da janela de 14 dias.
    const primeiro = lido.itens[0];
    if (primeiro) {
      const dias = decidir([primeiro], agora(), Infinity)[0];
      avisos = dias ? [dias] : [];
    }
  }
  let enviados = 0;
  for (const a of avisos) {
    if (await enviarAviso(montarTexto(a, { teste }), env, buscar, registrarErro)) enviados += 1;
  }
  // Só ambiente, estado e dias: nenhum texto de aviso, URL ou token no log.
  registrarInfo(`Lembrete: ${lido.itens.length} segredo(s), ${avisos.length} aviso(s), ${enviados} enviado(s)`
    + (teste ? ' (teste)' : '') + avisos.map(a => ` [${a.ambiente}:${a.estado}:${a.dias}d]`).join(''));
  return { enviados, erro: false };
}

export default {
  async scheduled(_evento, env, ctx) {
    ctx.waitUntil(executar(env));
  },
  // Sem endereço público útil: responde só `200 ok`; não executa o lembrete.
  fetch() {
    return new Response('ok');
  },
};
