import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import worker, { executar } from '../src/index.js';
import { decidir, interpretarResposta, montarAviso, formatarDuracao } from '../src/logica.js';

const MINUTO = 60_000;
const json = (dados, status = 200) => new Response(JSON.stringify(dados), { status });

function cenario() {
  let relogio = 0;
  let salvo = null;
  let escritas = 0;
  const sondas = [];
  const mensagens = [];
  const erros = [];
  const esperas = [];
  let slack = () => json({ ok: true });
  const env = {
    URL_SAUDE: 'https://saude.invalid/sonda',
    SLACK_BOT_TOKEN: 'token-sintetico',
    SLACK_CANAL: 'canal-sintetico',
    AVISO_TESTE: '',
    ESTADO_VIGIA: {
      async get(chave, tipo) {
        assert.equal(chave, 'estado');
        assert.equal(tipo, 'json');
        return structuredClone(salvo);
      },
      async put(chave, valor) {
        assert.equal(chave, 'estado');
        escritas++;
        salvo = JSON.parse(valor);
      },
    },
  };
  const dependencias = {
    agora: () => relogio,
    esperar: async ms => { esperas.push(ms); },
    registrarErro: erro => erros.push(erro),
    buscar: async (url, opcoes) => {
      assert.equal(opcoes.redirect, 'manual');
      assert.ok(opcoes.signal instanceof AbortSignal);
      if (url === env.URL_SAUDE) {
        assert.equal(opcoes.method, 'GET');
        assert.equal(opcoes.headers.Authorization, undefined);
        assert.equal(opcoes.headers['x-region'], 'sa-east-1');
        const resposta = sondas.shift();
        assert.ok(resposta, 'Falta uma sonda de mentira');
        if (resposta instanceof Error) throw resposta;
        return resposta;
      }
      assert.equal(url, 'https://slack.com/api/chat.postMessage');
      assert.equal(opcoes.method, 'POST');
      assert.equal(opcoes.headers.Authorization, `Bearer ${env.SLACK_BOT_TOKEN}`);
      assert.equal(opcoes.headers['x-region'], undefined);
      assert.equal(opcoes.headers['Content-Type'], 'application/json');
      const mensagem = JSON.parse(opcoes.body);
      assert.equal(mensagem.channel, env.SLACK_CANAL);
      assert.doesNotMatch(mensagem.text, /https?:\/\/|token-sintetico|@/);
      mensagens.push(mensagem.text);
      return slack();
    },
  };
  return {
    env, mensagens, erros, esperas,
    get escritas() { return escritas; },
    get estado() { return salvo; },
    slack: resposta => { slack = resposta; },
    async rodar(minuto, ...respostas) {
      relogio = minuto * MINUTO;
      sondas.push(...respostas);
      return executar(env, dependencias);
    },
  };
}

test('ok → ok: nenhum aviso e só uma escrita por execução', async () => {
  const c = cenario();
  await c.rodar(0, json({ ok: true }));
  await c.rodar(5, json({ ok: true }));
  assert.deepEqual(c.mensagens, []);
  assert.deepEqual(c.esperas, []);
  assert.equal(c.escritas, 2);
  assert.equal(c.estado.ultimaExecucao, 5 * MINUTO);
});

test('primeira falha e segunda ok: espera 60 s, sem aviso de queda', async () => {
  const c = cenario();
  await c.rodar(0, json({ status: 'atrasado' }, 503), json({ ok: true }));
  assert.deepEqual(c.esperas, [60_000]);
  assert.deepEqual(c.mensagens, []);
  assert.equal(c.estado.inicioQueda, null);
});

test('falha confirmada, lembrete após uma hora e recuperação única com duração', async () => {
  const c = cenario();
  const cair = minuto => c.rodar(minuto, json({ status: 'atrasado' }, 503), json({ status: 'degradado' }, 503));
  await cair(0);
  assert.equal(c.mensagens.length, 1);
  assert.match(c.mensagens[0], /^🔴 .*não responde/);
  assert.match(c.mensagens[0], /HTTP 503 \(status: degradado\)/);
  for (let minuto = 5; minuto <= 55; minuto += 5) await cair(minuto);
  await cair(59);
  assert.equal(c.mensagens.length, 1);
  await cair(60);
  assert.equal(c.mensagens.length, 2);
  assert.match(c.mensagens[1], /^🔴 .*continua/);
  assert.match(c.mensagens[1], /1 h/);
  await cair(65);
  assert.equal(c.mensagens.length, 2);
  await c.rodar(70, json({ ok: true }));
  assert.match(c.mensagens[2], /^🟢 .*voltou ao normal/);
  assert.match(c.mensagens[2], /1 h 10 min/);
  await c.rodar(75, json({ ok: true }));
  assert.equal(c.mensagens.length, 3);
  assert.equal(c.estado.inicioQueda, null);
});

test('vigia atrasado: somente mais de 15 min e não repete ao normalizar', async () => {
  const c = cenario();
  await c.rodar(0, json({ ok: true }));
  await c.rodar(15, json({ ok: true }));
  assert.equal(c.mensagens.length, 0);
  await c.rodar(31, json({ ok: true }));
  assert.match(c.mensagens[0], /^🟠 .*ficou sem rodar/);
  assert.match(c.mensagens[0], /16 min/);
  await c.rodar(36, json({ ok: true }));
  assert.equal(c.mensagens.length, 1);
});

test('interpretação estrita e status inválido nunca entram no aviso', () => {
  for (const status of ['https://segredo.invalid', 'A', 'a'.repeat(31), 'abc\n', '@canal', 123]) {
    const r = interpretarResposta(503, JSON.stringify({ status, detalhe: 'corpo-sensivel' }));
    assert.equal(r.motivo, 'HTTP 503');
    assert.doesNotMatch(montarAviso({ acao: 'primeiro' }, r.motivo), /sensivel|segredo|@/);
  }
  assert.equal(interpretarResposta(200, '{').ok, false);
  for (const ok of [false, 'true', 1, null]) {
    assert.equal(interpretarResposta(200, JSON.stringify({ ok })).ok, false);
  }
  assert.equal(interpretarResposta(503, '{"ok":true}').ok, false);
  assert.equal(interpretarResposta(200, '{"ok":true}').ok, true);
  assert.match(interpretarResposta(503, '{"status":"atrasado"}').motivo, /atrasado/);
});

test('erro de rede e corpo grande não vazam na mensagem nem no log', async () => {
  const c = cenario();
  await c.rodar(0, new Error('https://segredo.invalid token-sintetico'),
    new Response('segredo'.repeat(10_000)));
  assert.match(c.mensagens[0], /corpo que não é JSON/);
  assert.doesNotMatch(c.mensagens[0], /segredo/);
  assert.deepEqual(c.erros, []);
});

test('Slack fora: rede, HTTP, ok:false, JSON inválido e erro inseguro não quebram o cron', async () => {
  for (const resposta of [
    () => { throw new Error('token-sintetico https://segredo.invalid'); },
    () => json({ ok: true, error: 'ratelimited' }, 429),
    () => json({ ok: false, error: 'not_in_channel' }),
    () => new Response('corpo-sensivel'),
    () => json({ ok: false, error: 'https://segredo.invalid token-sintetico' }),
    () => json({ ok: false, error: 'a'.repeat(41) }),
  ]) {
    const c = cenario();
    c.slack(resposta);
    await c.rodar(0, json({ ok: false }), json({ ok: false }));
    assert.equal(c.escritas, 1);
    assert.equal(c.erros.length, 1);
    assert.doesNotMatch(c.erros[0], /segredo|sensivel|token-sintetico|https?:/);
    if (c.erros[0].includes('(')) assert.match(c.erros[0], /\((ratelimited|not_in_channel)\)/);
    await c.rodar(5, json({ ok: false }), json({ ok: false }));
    assert.equal(c.mensagens.length, 1, 'não repete a cada cron quando Slack falha');
  }
});

test('secret ausente não gera requisição ao Slack nem derruba a execução', async () => {
  const c = cenario();
  delete c.env.SLACK_BOT_TOKEN;
  await c.rodar(0, json({ ok: false }), json({ ok: false }));
  assert.equal(c.mensagens.length, 0);
  assert.equal(c.erros.length, 1);
  assert.equal(c.escritas, 1);
});

test('AVISO_TESTE vazio não envia; etiqueta nova envia uma vez entre execuções', async () => {
  const c = cenario();
  await c.rodar(0, json({ ok: true }));
  assert.equal(c.mensagens.length, 0);
  c.env.AVISO_TESTE = 'teste-1';
  await c.rodar(5, json({ ok: true }));
  await c.rodar(10, json({ ok: true }));
  assert.equal(c.mensagens.length, 1);
  assert.match(c.mensagens[0], /^TESTE: /);
  assert.equal(c.estado.avisoTeste, 'teste-1');
  c.env.AVISO_TESTE = '';
  await c.rodar(15, json({ ok: true }));
  c.env.AVISO_TESTE = 'teste-1';
  await c.rodar(20, json({ ok: true }));
  assert.equal(c.mensagens.length, 1);
  c.env.AVISO_TESTE = 'teste-2';
  await c.rodar(25, json({ ok: true }));
  assert.equal(c.mensagens.length, 2);
  assert.equal(c.escritas, 6);
});

test('decisão pura não altera entrada e combina atraso, queda e teste em uma escrita', () => {
  const anterior = Object.freeze({ ultimaExecucao: 0, inicioQueda: null, ultimoAviso: null, avisoTeste: '' });
  const { estado, avisos } = decidir({ ok: false }, anterior, 16 * MINUTO, 'teste-1');
  assert.deepEqual(avisos.map(a => a.acao), ['atraso', 'primeiro', 'teste']);
  assert.equal(estado.inicioQueda, 16 * MINUTO);
  assert.equal(anterior.inicioQueda, null);
  assert.equal(formatarDuracao(0), '0 min');
  assert.equal(formatarDuracao(60 * MINUTO), '1 h');
  assert.equal(formatarDuracao(61 * MINUTO), '1 h 01 min');
});

test('fetch público responde somente ok sem consultar configuração ou rede', async () => {
  const resposta = worker.fetch();
  assert.equal(resposta.status, 200);
  assert.equal(await resposta.text(), 'ok');
});

test('configuração: um cron, um KV e nenhuma dependência ou recurso pago', async () => {
  const pasta = new URL('../', import.meta.url);
  const config = JSON.parse((await readFile(new URL('wrangler.jsonc', pasta), 'utf8')).replace(/^\s*\/\/.*$/gm, ''));
  assert.deepEqual(config.triggers.crons, ['*/5 * * * *']);
  assert.equal(config.kv_namespaces.length, 1);
  assert.equal(config.vars.AVISO_TESTE, '');
  assert.equal(config.vars.SLACK_CANAL, 'C0CHB051JJJ');
  for (const recurso of ['durable_objects', 'queues', 'd1_databases', 'r2_buckets', 'services', 'unsafe']) {
    assert.equal(config[recurso], undefined);
  }
  const pacote = JSON.parse(await readFile(new URL('package.json', pasta), 'utf8'));
  assert.equal(pacote.type, 'module');
  assert.equal(pacote.dependencies, undefined);
  assert.equal(pacote.devDependencies, undefined);
});

test('nenhum arquivo da pasta contém endereço de webhook ou prefixo de token real', async () => {
  const proibidos = ['hooks' + '.slack.com', 'xox' + 'b-'];
  async function verificar(pasta) {
    for (const item of await readdir(pasta, { withFileTypes: true })) {
      const caminho = new URL(item.name, pasta);
      if (item.isDirectory()) await verificar(new URL(item.name + '/', pasta));
      else if (item.isFile()) {
        const conteudo = await readFile(caminho, 'utf8');
        for (const proibido of proibidos) assert.ok(!conteudo.includes(proibido), `Conteúdo proibido em ${item.name}`);
      }
    }
  }
  await verificar(new URL('../', import.meta.url));
});
