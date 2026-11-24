import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import worker, { executar } from '../src/index.js';
import { LIMITE_DIAS, decidir, diaUTC, diasAte, lerSegredos, montarTexto } from '../src/logica.js';

const ITEM = {
  ambiente: 'DEV', segredo: 'Apple client secret (JWT do .p8)', vence_em: '2027-05-23',
  renovar: 'python3 -I ~/.config/frila/bin/apple-client-secret.py ~/.config/frila/apple-sign-in-AuthKey.p8 TEAM KEY SERVICO <saida> 180',
  onde_colar: 'Supabase DEV > Auth > Providers > Apple, pelo portal',
};
// 12:00 UTC (o horário do cron) de um dia.
const meioDia = dia => Date.parse(`${dia}T12:00:00Z`);

test('diaUTC aceita só data real AAAA-MM-DD', () => {
  assert.notEqual(diaUTC('2027-05-23'), null);
  for (const ruim of ['2027-02-30', '2027-13-01', '27-05-23', '2027-5-23', '', null, undefined, 20270523, '2027-05-23T00:00', ' 2027-05-23']) {
    assert.equal(diaUTC(ruim), null, String(ruim));
  }
});

test('diasAte conta dias de calendário UTC, sem depender da hora do cron', () => {
  assert.equal(diasAte('2027-05-23', meioDia('2027-05-09')), 14);
  assert.equal(diasAte('2027-05-23', Date.parse('2027-05-09T00:00:00Z')), 14);
  assert.equal(diasAte('2027-05-23', Date.parse('2027-05-09T23:59:59Z')), 14);
  assert.equal(diasAte('2027-05-23', meioDia('2027-05-23')), 0);
  assert.equal(diasAte('2027-05-23', meioDia('2027-05-24')), -1);
  assert.equal(diasAte('2027-05-23', meioDia('2027-04-23')), 30);
  assert.equal(diasAte('2028-03-01', meioDia('2028-02-28')), 2); // 2028 é bissexto
  assert.equal(diasAte('2027-02-30', meioDia('2027-02-01')), null);
});

test('regra: sem aviso antes de 14 dias; aviso diário de 14 a 0; VENCIDO depois', () => {
  const itens = [ITEM];
  assert.equal(LIMITE_DIAS, 14);
  assert.deepEqual(decidir(itens, meioDia('2027-05-08')), [], '15 dias: nada');
  assert.deepEqual(decidir(itens, meioDia('2026-11-24')), [], 'meses antes: nada');
  const catorze = decidir(itens, meioDia('2027-05-09'));
  assert.equal(catorze.length, 1);
  assert.equal(catorze[0].dias, 14);
  assert.equal(catorze[0].estado, 'a_vencer');
  assert.equal(decidir(itens, meioDia('2027-05-22'))[0].dias, 1);
  const hoje = decidir(itens, meioDia('2027-05-23'));
  assert.equal(hoje[0].estado, 'hoje');
  assert.equal(hoje[0].dias, 0);
  for (const dia of ['2027-05-24', '2027-06-30', '2028-01-01']) {
    const v = decidir(itens, meioDia(dia));
    assert.equal(v.length, 1, dia);
    assert.equal(v[0].estado, 'vencido');
    assert.ok(v[0].dias < 0);
  }
});

test('cada segredo decide sozinho (DEV e Prod com datas diferentes)', () => {
  const prod = { ...ITEM, ambiente: 'Prod', vence_em: '2027-11-23' };
  const r = decidir([ITEM, prod], meioDia('2027-05-20'));
  assert.deepEqual(r.map(a => a.ambiente), ['DEV']);
  const dois = decidir([ITEM, prod], meioDia('2027-11-20'));
  assert.deepEqual(dois.map(a => `${a.ambiente}:${a.estado}`), ['DEV:vencido', 'Prod:a_vencer']);
});

test('texto: ambiente, data, dias, comando de renovação e onde colar; vencido e teste marcados', () => {
  const [a] = decidir([ITEM], meioDia('2027-05-09'));
  const t = montarTexto(a);
  assert.match(t, /^⏰ Segredo Apple do DEV vence em 2027-05-23 \(faltam 14 dias\)\./);
  assert.ok(t.includes(ITEM.renovar));
  assert.ok(t.includes('Supabase DEV > Auth > Providers > Apple, pelo portal'));
  assert.match(t, /wrangler\.jsonc/);
  assert.match(montarTexto(decidir([ITEM], meioDia('2027-05-22'))[0]), /faltam 1 dia\)/);
  assert.match(montarTexto(decidir([ITEM], meioDia('2027-05-23'))[0]), /vence HOJE/);
  const v = montarTexto(decidir([ITEM], meioDia('2027-05-26'))[0]);
  assert.match(v, /VENCEU em 2027-05-23 \(há 3 dias\)/);
  assert.match(montarTexto(decidir([ITEM], meioDia('2027-05-24'))[0]), /há 1 dia\)/);
  assert.match(montarTexto(a, { teste: true }), /^🧪 TESTE \(aviso de prova, não é vencimento\): ⏰/);
  assert.doesNotMatch(t, /TESTE/);
});

test('lerSegredos recusa configuração torta em vez de avisar pela metade', () => {
  assert.equal(lerSegredos(JSON.stringify([ITEM])).itens.length, 1);
  assert.deepEqual(lerSegredos('[]'), { itens: [] });
  for (const ruim of ['nao-json', '{}', JSON.stringify([{ ...ITEM, vence_em: '23/05/2027' }]),
    JSON.stringify([{ ...ITEM, ambiente: 'DEV prod' }]), JSON.stringify([{ ...ITEM, renovar: 'a\nb' }]),
    JSON.stringify([{ ...ITEM, onde_colar: undefined }]), JSON.stringify([null])]) {
    assert.ok(lerSegredos(ruim).erro, ruim);
  }
});

function cenario(extra = {}) {
  const envios = [];
  const erros = [];
  const infos = [];
  let slack = () => new Response(JSON.stringify({ ok: true }), { status: 200 });
  const env = { SLACK_BOT_TOKEN: 'token-sintetico', SLACK_CANAL: 'canal-sintetico', AVISO_TESTE: '',
    SEGREDOS: JSON.stringify([ITEM]), ...extra };
  const buscar = async (url, init) => {
    envios.push({ url, init, corpo: JSON.parse(init.body) });
    return slack();
  };
  return { env, envios, erros, infos, buscar, usarSlack: f => { slack = f; },
    rodar: dia => executar(env, { buscar, agora: () => meioDia(dia), registrarErro: m => erros.push(m), registrarInfo: m => infos.push(m) }) };
}

test('executar: fora da janela não posta nada', async () => {
  const c = cenario();
  const r = await c.rodar('2027-05-08');
  assert.equal(c.envios.length, 0);
  assert.deepEqual(r, { enviados: 0, erro: false });
});

test('executar: dentro da janela posta 1 mensagem no canal com o token só no cabeçalho', async () => {
  const c = cenario();
  const r = await c.rodar('2027-05-09');
  assert.deepEqual(r, { enviados: 1, erro: false });
  assert.equal(c.envios.length, 1);
  assert.equal(c.envios[0].url, 'https://slack.com/api/chat.postMessage');
  assert.equal(c.envios[0].init.headers.Authorization, 'Bearer token-sintetico');
  assert.equal(c.envios[0].corpo.channel, 'canal-sintetico');
  assert.match(c.envios[0].corpo.text, /faltam 14 dias/);
  assert.doesNotMatch(c.envios[0].corpo.text, /token-sintetico/);
  const log = [...c.infos, ...c.erros].join('\n');
  assert.doesNotMatch(log, /token-sintetico|Providers|apple-client-secret/);
  assert.match(c.infos[0], /\[DEV:a_vencer:14d\]/);
});

test('executar: AVISO_TESTE posta UM aviso marcado como teste mesmo fora da janela', async () => {
  const c = cenario({ AVISO_TESTE: 'teste-1' });
  const r = await c.rodar('2026-11-24');
  assert.equal(r.enviados, 1);
  assert.match(c.envios[0].corpo.text, /^🧪 TESTE/);
  assert.match(c.infos[0], /\(teste\)/);
  const sem = cenario({ AVISO_TESTE: 'tem espaço' });
  await sem.rodar('2026-11-24');
  assert.equal(sem.envios.length, 0, 'etiqueta inválida não liga o teste');
});

test('executar: falha do Slack vira log genérico, sem URL nem token, e não derruba', async () => {
  for (const resposta of [
    () => new Response(JSON.stringify({ ok: false, error: 'channel_not_found' }), { status: 200 }),
    () => new Response('<html>', { status: 502 }),
  ]) {
    const c = cenario();
    c.usarSlack(resposta);
    const r = await c.rodar('2027-05-20');
    assert.equal(r.enviados, 0);
    assert.match(c.erros[0], /^Lembrete: falha ao enviar aviso ao Slack/);
    assert.doesNotMatch(c.erros.join('\n'), /token-sintetico|slack\.com/);
  }
  const c = cenario();
  c.env.SLACK_BOT_TOKEN = '';
  assert.equal((await c.rodar('2027-05-20')).enviados, 0);
  assert.equal(c.envios.length, 0);
});

test('executar: configuração torta não envia nada e registra o motivo curto', async () => {
  const c = cenario({ SEGREDOS: '{nao json' });
  const r = await c.rodar('2027-05-20');
  assert.deepEqual(r, { enviados: 0, erro: true });
  assert.equal(c.envios.length, 0);
  assert.match(c.erros[0], /SEGREDOS/);
});

test('handler HTTP responde só ok e o cron agenda a execução', async () => {
  assert.equal(await worker.fetch().text(), 'ok');
  let espera = null;
  await worker.scheduled({}, { SEGREDOS: '[]' }, { waitUntil: p => { espera = p; } });
  assert.ok(espera instanceof Promise);
  assert.deepEqual(await espera, { enviados: 0, erro: false });
});

test('wrangler.jsonc: cron diário, só datas no SEGREDOS e nenhum segredo no repositório', async () => {
  const cru = await readFile(new URL('../wrangler.jsonc', import.meta.url), 'utf8');
  const config = JSON.parse(cru.replace(/^\s*\/\/.*$/gm, ''));
  assert.deepEqual(config.triggers.crons, ['0 12 * * *']);
  assert.equal(config.workers_dev, false);
  assert.equal(config.vars.AVISO_TESTE, '', 'a etiqueta de teste não pode ficar ligada no repositório');
  const lido = lerSegredos(config.vars.SEGREDOS);
  assert.ok(lido.itens?.length >= 1, lido.erro);
  assert.equal(lido.itens[0].ambiente, 'DEV');
  assert.equal(lido.itens[0].vence_em, '2027-05-23');
  for (const nome of ['src/index.js', 'src/logica.js', 'wrangler.jsonc', 'LEIAME.md']) {
    const texto = await readFile(new URL(`../${nome}`, import.meta.url), 'utf8');
    assert.doesNotMatch(texto, /BEGIN [A-Z ]*PRIVATE KEY|eyJ[A-Za-z0-9_-]{20,}|xox[bp]-/, nome);
  }
  assert.ok((await readdir(new URL('..', import.meta.url))).every(n => !n.endsWith('.p8')));
});
