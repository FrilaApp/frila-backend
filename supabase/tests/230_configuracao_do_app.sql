-- `configuracao_do_app`: a versão mínima, lida antes de haver sessão.
--
-- É a única RPC de `rest/v1` que `anon` executa (contrato 0.2.2): um app abaixo da
-- versão mínima precisa descobrir isso mesmo sem conseguir entrar. Por isso o teste
-- chama como `anon` — como `postgres` a função passaria sempre, e o critério do cartão
-- ("teste pgTAP da RPC com anon") viraria teatro.
--
--   200  a configuração da plataforma, com os cinco campos de ConfiguracaoDoApp
--   422  plataforma ausente (campo_obrigatorio) ou fora do enum (campo_invalido)
--   404  plataforma do enum sem configuração gravada — hoje android e web, que ainda
--        não têm loja. Decisão desta implementação, fora do contrato: ver a migração.
--
-- A tabela fica em `privado`: nenhuma chave do app lê a linha direto, só pela função.

begin;
select plan(29);

-- Executa `sql` como `anon`, a role da chave publicável, sem token de usuário.
create function pg_temp.anonimo(sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role anon';
  execute sql into r;
  reset role;
  return r;
end $$;

create function pg_temp.logado(sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

-- ── A função existe e tem as portas certas ────────────────────────────────────

select has_function('public', 'configuracao_do_app', array['text'],
  'public.configuracao_do_app(plataforma text) existe');

select ok(
  has_function_privilege('anon', 'public.configuracao_do_app(text)', 'execute'),
  'anon executa: o app abaixo da versão mínima ainda não tem sessão');

select ok(
  has_function_privilege('authenticated', 'public.configuracao_do_app(text)', 'execute'),
  'authenticated também: o app com sessão aberta faz a mesma pergunta');

-- A exceção é por nome. Se uma segunda função de public aparecer liberada para anon,
-- este teste acusa — a regra "anon não lê nada" tem exatamente uma exceção.
select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('rls_auto_enable')),
  array['configuracao_do_app'],
  'configuracao_do_app é a única função de public que anon executa');

-- ── 200: a configuração do iOS, como o app lê ─────────────────────────────────

select is(
  pg_temp.anonimo($$ select public.configuracao_do_app('ios') $$),
  jsonb_build_object(
    'plataforma',         'ios',
    'versao_minima',      '0.1.0',
    'versao_recomendada', '0.1.0',
    'url_da_loja',        'https://apps.apple.com/app/id6815311991',
    'mensagem',           null),
  'anon lê a configuração do iOS: a mínima inicial é a versão do build de hoje, e não bloqueia ninguém');

select is(
  (select array_agg(k order by k)
     from jsonb_object_keys(pg_temp.anonimo($$ select public.configuracao_do_app('ios') $$)) k),
  array['mensagem','plataforma','url_da_loja','versao_minima','versao_recomendada'],
  'ConfiguracaoDoApp: os cinco campos do contrato, e mensagem presente mesmo nula');

select is(
  pg_temp.anonimo($$ select public.configuracao_do_app('ios') $$) -> 'mensagem',
  'null'::jsonb,
  'mensagem nula por padrão: o app tem texto próprio para a tela de bloqueio');

select is(
  pg_temp.logado($$ select public.configuracao_do_app('ios') $$) ->> 'versao_minima',
  '0.1.0',
  'com sessão, a resposta é a mesma');

-- A função lê a tabela, e não um literal: subir a versão aparece na resposta.
update privado.configuracao_app
   set versao_minima = '1.2.10', versao_recomendada = '1.3.0',
       mensagem = 'Corrigimos um defeito grave. Atualize para continuar.'
 where plataforma = 'ios';

select is(
  pg_temp.anonimo($$ select public.configuracao_do_app('ios') $$),
  jsonb_build_object(
    'plataforma',         'ios',
    'versao_minima',      '1.2.10',
    'versao_recomendada', '1.3.0',
    'url_da_loja',        'https://apps.apple.com/app/id6815311991',
    'mensagem',           'Corrigimos um defeito grave. Atualize para continuar.'),
  'subir a versão mínima na tabela muda a resposta na hora, sem deploy de app');

select is(
  pg_temp.anonimo($$ select public.configuracao_do_app('ios') $$) ->> 'versao_minima',
  '1.2.10',
  'a versão sai como texto: 1.2.10 continua 1.2.10, e não 1.21');

-- ── 422: plataforma ausente ou fora do enum ───────────────────────────────────

select throws_ok(
  $$ select pg_temp.anonimo($x$ select public.configuracao_do_app() $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "plataforma", "hint" : null}',
  '422 campo_obrigatorio: GET sem plataforma');

select throws_ok(
  $$ select pg_temp.anonimo($x$ select public.configuracao_do_app(null) $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "plataforma", "hint" : null}',
  '422 campo_obrigatorio: plataforma nula');

select throws_ok(
  $$ select pg_temp.anonimo($x$ select public.configuracao_do_app('  ') $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "plataforma", "hint" : null}',
  '422 campo_obrigatorio: plataforma em branco é ausência, e não valor recusado');

select throws_ok(
  $$ select pg_temp.anonimo($x$ select public.configuracao_do_app('windows') $x$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "plataforma", "hint" : null}',
  '422 campo_invalido: plataforma fora do enum');

select throws_ok(
  $$ select pg_temp.anonimo($x$ select public.configuracao_do_app('iOS') $x$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "plataforma", "hint" : null}',
  '422 campo_invalido: o enum é minúsculo, como no contrato');

-- O status HTTP mora no DETAIL, que o throws_ok não enxerga. Conferido à parte.
create function pg_temp.status_de(sql text) returns int
language plpgsql as $$
declare d text;
begin
  execute sql;
  return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics d = pg_exception_detail;
  return (d::jsonb ->> 'status')::int;
end $$;

select is(
  pg_temp.status_de($$ select pg_temp.anonimo($x$ select public.configuracao_do_app('windows') $x$) $$),
  422,
  'a recusa de plataforma sai com status 422, como o contrato manda');

-- ── 404: plataforma do enum, sem configuração ─────────────────────────────────

select throws_ok(
  $$ select pg_temp.anonimo($x$ select public.configuracao_do_app('android') $x$) $$,
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : "plataforma", "hint" : null}',
  'android ainda não tem loja: 404, e não uma URL inventada');

select is(
  pg_temp.status_de($$ select pg_temp.anonimo($x$ select public.configuracao_do_app('web') $x$) $$),
  404,
  'web idem, com status 404');

-- ── A tabela: fechada para as chaves do app ───────────────────────────────────

select throws_ok(
  $$ select pg_temp.anonimo($x$ select to_jsonb(c) from privado.configuracao_app c limit 1 $x$) $$,
  '42501',
  null,
  'anon não lê a tabela direto: só pela função');

select throws_ok(
  $$ select pg_temp.logado($x$ update privado.configuracao_app set versao_minima = '0.0.0' returning null::jsonb $x$) $$,
  '42501',
  null,
  'nem o usuário logado baixa a versão mínima escrevendo na tabela');

select is(
  (select relrowsecurity from pg_class where oid = 'privado.configuracao_app'::regclass),
  true,
  'a tabela tem Row Level Security ligado');

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'privado' and tablename = 'configuracao_app'),
  0,
  'e nenhuma política: nem de leitura nem de escrita');

-- ── As restrições, uma por uma ────────────────────────────────────────────────

select throws_ok(
  $$ insert into privado.configuracao_app (plataforma, versao_minima, versao_recomendada, url_da_loja)
     values ('ios', '0.1.0', '0.1.0', 'https://apps.apple.com/app/id1') $$,
  '23505',
  null,
  'uma configuração por plataforma');

select throws_ok(
  $$ update privado.configuracao_app set versao_minima = 'v1.0' where plataforma = 'ios' $$,
  '23514',
  null,
  'versao_minima_formato: v1.0 não é versão que o app sabe comparar');

select throws_ok(
  $$ update privado.configuracao_app set versao_recomendada = '1.3' || chr(10) || '0' where plataforma = 'ios' $$,
  '23514',
  null,
  'versao_recomendada_formato: só números separados por ponto');

select throws_ok(
  $$ update privado.configuracao_app set versao_minima = '1.2.10', versao_recomendada = '1.2.9'
      where plataforma = 'ios' $$,
  '23514',
  null,
  'recomendada_nao_abaixo_da_minima: pela ordem natural, 1.2.9 fica abaixo de 1.2.10');

select lives_ok(
  $$ update privado.configuracao_app set versao_minima = '1.2.9', versao_recomendada = '1.2.10'
      where plataforma = 'ios' $$,
  'e 1.2.10 acima de 1.2.9 é aceito: a comparação é por número, não por texto');

select throws_ok(
  $$ update privado.configuracao_app set url_da_loja = 'http://apps.apple.com/app/id6815311991'
      where plataforma = 'ios' $$,
  '23514',
  null,
  'url_da_loja_https: o botão da tela de bloqueio não leva a endereço sem TLS');

select throws_ok(
  $$ update privado.configuracao_app set mensagem = '   ' where plataforma = 'ios' $$,
  '23514',
  null,
  'mensagem_nao_vazia: texto em branco seria tela de bloqueio sem texto — ausência é null');

select * from finish();
rollback;
