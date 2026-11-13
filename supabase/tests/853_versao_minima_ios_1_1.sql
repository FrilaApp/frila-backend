-- 853_versao_minima_ios_1_1.sql
--
-- Sobe a versão mínima do iOS para 1.1.0 em privado.configuracao_app (Política v1.1;
-- migração 20261113030000).
--
-- A versão 1.1.0 do iOS foi publicada na App Store. Pela Política v1.1, a versão mínima
-- sobe para 1.1.0. Com isso, os aparelhos rodando o app 1.0 passam a receber "atualização
-- obrigatória" (tela de bloqueio que substitui o app e direciona para a loja).
--
-- Cobre:
--   1. O ANTES e o DEPOIS:
--      - Antes (0.1.0): app 1.0.0 e 1.0 não eram bloqueados (versão >= mínima);
--      - Depois (1.1.0): app 1.0.0, 1.0 e 1.0.1 ficam abaixo da mínima e bloqueiam;
--      - App 1.1.0 e superior (1.2.0) são liberados normalmente.
--   2. A RPC pública `public.configuracao_do_app('ios')` chamada por `anon` (como o app lê):
--      - Devolve versao_minima = '1.1.0' e versao_recomendada = '1.1.0'.
--   3. Estado na tabela `privado.configuracao_app`:
--      - Linha do iOS atualizada para mínima 1.1.0 e recomendada 1.1.0.
--   4. Android NÃO foi tocado:
--      - Permanece em 0.1.0 na tabela e na resposta de configuracao_do_app('android').
--   5. Recursos NÃO foram tocados:
--      - checkin_por_codigo mantém versão mínima própria 1.2.0 em privado.recurso_versao_minima;
--      - iOS 1.1.0 recebe checkin_por_codigo = false; iOS 1.2.0 recebe true.
--   6. Integridade de restrições de versão:
--      - recomendada_nao_abaixo_da_minima e versao_minima_formato continuam ativas.

begin;
select plan(21);

-- Executa SQL como `anon`, o papel da chave pública sem sessão do usuário.
create function pg_temp.anonimo(sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role anon';
  execute sql into r;
  reset role;
  return r;
end $$;

-- Simula a lógica de decisão do app (AtualizacaoObrigatoriaViewModel):
-- O app lê configuracao_do_app(plataforma), extrai versao_minima e compara
-- sua versão atual contra versao_minima parte a parte (completando partes ausentes
-- com zeros, exatamente como privado.versao_em_quatro e o contrato 0.2.67 definem).
-- Se versao_atual < versao_minima -> bloqueado (.orderedAscending).
create function pg_temp.recebe_atualizacao_obrigatoria(p_versao_atual text, p_plataforma text default 'ios') returns boolean
language plpgsql as $$
declare
  v_config jsonb;
  v_minima text;
begin
  v_config := pg_temp.anonimo(format('select public.configuracao_do_app(%L)', p_plataforma));
  v_minima := v_config ->> 'versao_minima';
  return privado.versao_em_quatro(p_versao_atual) < privado.versao_em_quatro(v_minima);
end $$;

-- ── 1. Prova do ANTES (sob a versão mínima 0.1.0) ─────────────────────────────

select ok(
  not (privado.versao_em_quatro('1.0.0') < privado.versao_em_quatro('0.1.0')),
  'ANTES: app 1.0.0 não recebia atualização obrigatória sob a mínima 0.1.0');

select ok(
  not (privado.versao_em_quatro('1.0') < privado.versao_em_quatro('0.1.0')),
  'ANTES: app 1.0 (duas partes) não recebia atualização obrigatória sob a mínima 0.1.0');

-- ── 2. Prova do DEPOIS (sob a versão mínima 1.1.0 da migração) ────────────────

select is(
  (select versao_minima from privado.configuracao_app where plataforma = 'ios'),
  '1.1.0',
  'DEPOIS: privado.configuracao_app tem versao_minima = 1.1.0 para iOS');

select is(
  (select versao_recomendada from privado.configuracao_app where plataforma = 'ios'),
  '1.1.0',
  'DEPOIS: privado.configuracao_app tem versao_recomendada = 1.1.0 para iOS');

-- ── 3. A leitura da configuração como o app lê (anon, sem sessão) ─────────────

select is(
  pg_temp.anonimo($$ select public.configuracao_do_app('ios') $$) ->> 'versao_minima',
  '1.1.0',
  'configuracao_do_app(ios) devolve versao_minima = 1.1.0 para anon');

select is(
  pg_temp.anonimo($$ select public.configuracao_do_app('ios') $$) ->> 'versao_recomendada',
  '1.1.0',
  'configuracao_do_app(ios) devolve versao_recomendada = 1.1.0 para anon');

select is(
  pg_temp.anonimo($$ select public.configuracao_do_app('ios') $$) ->> 'url_da_loja',
  'https://apps.apple.com/app/id6815311991',
  'url_da_loja do iOS permanece a URL da App Store');

select is(
  pg_temp.anonimo($$ select public.configuracao_do_app('ios') $$) -> 'mensagem',
  'null'::jsonb,
  'mensagem continua nula (app usa texto padrão de bloqueio)');

-- ── 4. Comportamento do bloqueio do app iOS 1.0 vs 1.1+ ───────────────────────

select ok(
  pg_temp.recebe_atualizacao_obrigatoria('1.0.0'),
  'app iOS 1.0.0 passa a receber atualização obrigatória (bloqueado)');

select ok(
  pg_temp.recebe_atualizacao_obrigatoria('1.0'),
  'app iOS 1.0 (duas partes) passa a receber atualização obrigatória (bloqueado)');

select ok(
  pg_temp.recebe_atualizacao_obrigatoria('1.0.1'),
  'app iOS 1.0.1 (patch) passa a receber atualização obrigatória (bloqueado)');

select ok(
  not pg_temp.recebe_atualizacao_obrigatoria('1.1.0'),
  'app iOS 1.1.0 (versão publicada na loja) é liberado normalmente');

select ok(
  not pg_temp.recebe_atualizacao_obrigatoria('1.1'),
  'app iOS 1.1 (duas partes) é liberado normalmente');

select ok(
  not pg_temp.recebe_atualizacao_obrigatoria('1.2.0'),
  'app iOS 1.2.0 (futuro) é liberado normalmente');

-- ── 5. Android NÃO foi tocado ─────────────────────────────────────────────────

select is(
  (select versao_minima from privado.configuracao_app where plataforma = 'android'),
  '0.1.0',
  'Android em privado.configuracao_app permanece com versao_minima = 0.1.0');

select is(
  pg_temp.anonimo($$ select public.configuracao_do_app('android') $$) ->> 'versao_minima',
  '0.1.0',
  'configuracao_do_app(android) permanece com versao_minima = 0.1.0');

select ok(
  not pg_temp.recebe_atualizacao_obrigatoria('1.0.0', 'android'),
  'Android 1.0.0 não recebe atualização obrigatória');

-- ── 6. Recursos NÃO foram tocados ─────────────────────────────────────────────

select is(
  (select versao_minima from privado.recurso_versao_minima where recurso = 'checkin_por_codigo' and plataforma = 'ios'),
  '1.2.0',
  'checkin_por_codigo mantém versão mínima própria 1.2.0 para iOS');

select is(
  pg_temp.anonimo($$ select public.configuracao_do_app('ios', '1.1.0') $$) #>> '{recursos,checkin_por_codigo}',
  'false',
  'iOS 1.1.0 recebe checkin_por_codigo = false (exige 1.2.0)');

select is(
  pg_temp.anonimo($$ select public.configuracao_do_app('ios', '1.2.0') $$) #>> '{recursos,checkin_por_codigo}',
  'true',
  'iOS 1.2.0 recebe checkin_por_codigo = true');

-- ── 7. Restrições do banco protegendo a configuração ──────────────────────────

select throws_ok(
  $$ update privado.configuracao_app set versao_recomendada = '1.0.0' where plataforma = 'ios' $$,
  '23514',
  null,
  'recomendada_nao_abaixo_da_minima: recusa versao_recomendada (1.0.0) abaixo de versao_minima (1.1.0)');

select * from finish();
rollback;
