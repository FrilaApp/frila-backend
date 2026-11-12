-- A linha Android precisa existir antes do primeiro build chegar aos aparelhos.
-- A mesma RPC pública usada pelo iOS deve entregar a configuração sem sessão.

begin;
select plan(3);

create function pg_temp.anonimo(sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role anon';
  execute sql into r;
  reset role;
  return r;
end $$;

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
  pg_temp.anonimo($$ select public.configuracao_do_app('android') $$),
  jsonb_build_object(
    'plataforma',         'android',
    'versao_minima',      '0.1.0',
    'versao_recomendada', '0.1.0',
    'url_da_loja',        'https://play.google.com/store/apps/details?id=br.com.frila.app',
    'mensagem',           null,
    'recursos',           jsonb_build_object(
      'foto_de_perfil', false,
      'chamada_direta', false,
      'perfil_rico', false,
      'checkin_por_codigo', false)),
  '200: anon recebe a configuração inicial completa do Android');

delete from privado.configuracao_app where plataforma = 'android';

select throws_ok(
  $$ select pg_temp.anonimo($x$ select public.configuracao_do_app('android') $x$) $$,
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : "plataforma", "hint" : null}',
  'sem a linha Android, a RPC responde nao_encontrado');

select is(
  pg_temp.status_de($$ select pg_temp.anonimo($x$ select public.configuracao_do_app('android') $x$) $$),
  404,
  'sem a linha Android, nao_encontrado usa status 404');

select * from finish();
rollback;
