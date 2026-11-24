// Regra do lembrete de vencimento de segredo. Funções puras: o Worker só guarda DATAS.
export const LIMITE_DIAS = 14;

const DATA = /^(\d{4})-(\d{2})-(\d{2})$/;
const MS_DIA = 86_400_000;

// Dia UTC (meia-noite) de uma data AAAA-MM-DD existente no calendário; senão null.
export function diaUTC(texto) {
  const m = DATA.exec(typeof texto === 'string' ? texto : '');
  if (!m) return null;
  const [ano, mes, dia] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const t = Date.UTC(ano, mes - 1, dia);
  const d = new Date(t);
  if (d.getUTCFullYear() !== ano || d.getUTCMonth() !== mes - 1 || d.getUTCDate() !== dia) return null;
  return t;
}

// Dias inteiros do DIA UTC de `agora` até o dia do vencimento (0 = vence hoje, negativo = vencido).
export function diasAte(venceEm, agora) {
  const alvo = diaUTC(venceEm);
  if (alvo === null) return null;
  const d = new Date(agora);
  const hoje = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
  return Math.round((alvo - hoje) / MS_DIA);
}

const CURTO = /^[^\r\n]{1,300}$/;

// O JSON vem de uma var do wrangler; formato errado é erro de configuração (o Worker avisa
// genérico no log), nunca um aviso pela metade.
export function lerSegredos(texto) {
  let lista;
  try { lista = JSON.parse(texto); } catch { return { erro: 'SEGREDOS não é JSON válido' }; }
  if (!Array.isArray(lista)) return { erro: 'SEGREDOS deve ser uma lista' };
  const itens = [];
  for (const [i, x] of lista.entries()) {
    const ok = x && typeof x === 'object'
      && ['ambiente', 'segredo', 'vence_em', 'renovar', 'onde_colar'].every(c => typeof x[c] === 'string' && CURTO.test(x[c]))
      && /^[A-Za-z0-9_-]{1,20}$/.test(x.ambiente)
      && diaUTC(x.vence_em) !== null;
    if (!ok) return { erro: `SEGREDOS[${i}] inválido (campos, ambiente ou data AAAA-MM-DD)` };
    itens.push({ ...x });
  }
  return { itens };
}

// Quais avisos sair hoje: nada se faltam MAIS de `limite` dias; de `limite` até 0, um por dia
// (o cron roda 1x por dia); vencido, aviso diário de VENCIDO.
export function decidir(itens, agora, limite = LIMITE_DIAS) {
  const avisos = [];
  for (const x of itens) {
    const dias = diasAte(x.vence_em, agora);
    if (dias === null || dias > limite) continue;
    avisos.push({ ...x, dias, estado: dias < 0 ? 'vencido' : dias === 0 ? 'hoje' : 'a_vencer' });
  }
  return avisos;
}

const plural = (n, um, varios) => `${n} ${n === 1 ? um : varios}`;

export function montarTexto(a, { teste = false } = {}) {
  const passos = `Gerar o JWT novo do .p8: \`${a.renovar}\`; colar em ${a.onde_colar}; depois atualizar a data no Worker `
    + '(lembrete-segredos-cloudflare/wrangler.jsonc, `vence_em`) e publicar.';
  let cabeca;
  if (a.estado === 'vencido') {
    cabeca = `🔴 Segredo Apple do ${a.ambiente} VENCEU em ${a.vence_em} (há ${plural(-a.dias, 'dia', 'dias')}). O que depende dele parou de funcionar.`;
  } else if (a.estado === 'hoje') {
    cabeca = `⏰ Segredo Apple do ${a.ambiente} vence HOJE (${a.vence_em}).`;
  } else {
    cabeca = `⏰ Segredo Apple do ${a.ambiente} vence em ${a.vence_em} (faltam ${plural(a.dias, 'dia', 'dias')}).`;
  }
  return `${teste ? '🧪 TESTE (aviso de prova, não é vencimento): ' : ''}${cabeca} ${passos}`;
}
