-- 855_ligar_foto_chamada_e_perfil_rico.sql
--
-- A 20261113220000 ligou a foto, a chamada direta e o perfil rico, e a 20261113230000 desligou de novo a foto
-- (a leitura assinada não existe sem o segredo legado; P6 do B-019). Estado final para todos no
-- iOS 1.2.0 (ordem do Cauê, 13/11/2026; B-019, pacote 10). Este teste NÃO liga nada: o estado de
-- partida é o que a migração deixou. Cobre:
--   1. A migração: mínimo ios 1.2.0 para os três, nada no Android; foto_de_perfil true só no ios;
--      chamada_direta e perfil_rico ligados;
--   2. configuracao_do_app: ios 1.2.0 e 1.2.1 → os três true; ios 1.1.0, ios sem versão e android
--      1.2.0 → os três false; checkin_por_codigo segue como estava (true no ios 1.2.0);
--   3. A volta (os três comandos do cabeçalho da migração) recua tudo para false.

begin;
select plan(17);

select is((select count(*)::int from privado.recurso_versao_minima
            where plataforma = 'ios' and versao_minima = '1.2.0'
              and recurso in ('chamada_direta', 'perfil_rico')),
          2, 'mínimo ios 1.2.0 para chamada e perfil rico');
select is((select count(*)::int from privado.recurso_versao_minima where recurso = 'foto_de_perfil'),
          0, '20261113230000: a foto fica sem mínimo (desligada até a leitura assinada)');
select is((select count(*)::int from privado.recurso_versao_minima
            where plataforma = 'android' and recurso in ('foto_de_perfil', 'chamada_direta', 'perfil_rico')),
          0, 'nenhum mínimo no Android');
select is((select foto_de_perfil from privado.configuracao_app where plataforma = 'ios'), false, '20261113230000: a foto segue desligada no ios');
select is((select foto_de_perfil from privado.configuracao_app where plataforma = 'android'), false, 'foto segue desligada no android');
select is((select count(*)::int from privado.recurso where ligado and chave in ('chamada_direta', 'perfil_rico')),
          2, 'chamada_direta e perfil_rico ligados');

create function pg_temp.rec(p text, v text) returns jsonb language sql as $$
  select public.configuracao_do_app(p, v) -> 'recursos'
$$;
create function pg_temp.tres(r jsonb) returns text language sql as $$
  select concat_ws(',', r ->> 'foto_de_perfil', r ->> 'chamada_direta', r ->> 'perfil_rico')
$$;

select is(pg_temp.tres(pg_temp.rec('ios', '1.2.0')), 'false,true,true', 'ios 1.2.0: chamada e perfil rico ligados, foto não');
select is(pg_temp.tres(pg_temp.rec('ios', '1.2.1')), 'false,true,true', 'ios 1.2.1: chamada e perfil rico ligados, foto não');
select is(pg_temp.tres(pg_temp.rec('ios', '1.1.0')), 'false,false,false', 'ios 1.1.0: nada liga');
select is(pg_temp.tres(pg_temp.rec('ios', '1.1.99')), 'false,false,false', 'ios 1.1.99: nada liga');
select is(pg_temp.tres(pg_temp.rec('ios', null)), 'false,false,false', 'ios sem versão (app 1.0): nada liga');
select is(pg_temp.tres(pg_temp.rec('android', '1.2.0')), 'false,false,false', 'android 1.2.0: nada liga');
select is(pg_temp.rec('ios', '1.2.0') ->> 'checkin_por_codigo', 'true', 'checkin_por_codigo não mudou');

-- A volta do cabeçalho da migração
update privado.recurso set ligado = false where chave in ('chamada_direta', 'perfil_rico');
update privado.configuracao_app set foto_de_perfil = false where plataforma = 'ios';
delete from privado.recurso_versao_minima
 where plataforma = 'ios' and recurso in ('foto_de_perfil', 'chamada_direta', 'perfil_rico');

select is(pg_temp.tres(pg_temp.rec('ios', '1.2.0')), 'false,false,false', 'a volta: ios 1.2.0 sem nada');
select is(pg_temp.rec('ios', '1.2.0') ->> 'checkin_por_codigo', 'true', 'a volta não toca no check-in por código');
select is((select count(*)::int from privado.recurso_versao_minima where plataforma = 'ios'), 1, 'a volta: só o mínimo do check-in fica');
select is((select foto_de_perfil from privado.configuracao_app where plataforma = 'ios'), false, 'a volta: foto desligada');

select * from finish();
rollback;
