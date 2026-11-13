-- 819_recursos_por_versao_do_app.sql
--
-- Recursos do app por versão (contrato 0.2.65; 20261108150000). Um recurso só vem true em
-- configuracao_do_app com dois atos: a chave ligada e um mínimo por recurso e plataforma, com
-- a versao_app maior ou igual a ele. Sem versão, malformada ou sem mínimo: false (fechado por
-- padrão). Só dados sintéticos; o arquivo desfaz tudo no rollback.

begin;
select plan(36);

insert into privado.configuracao_app (plataforma, versao_minima, versao_recomendada, url_da_loja)
values ('android', '0.1.0', '0.1.0', 'https://play.google.com/store/apps/details?id=br.com.frila')
on conflict (plataforma) do nothing;

create function pg_temp.r(plataforma text, versao text) returns jsonb language sql as $$
  select public.configuracao_do_app(plataforma, versao)->'recursos' $$;
create function pg_temp.minimo(recurso text, plataforma text, versao text) returns void language sql as $$
  insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
  values (recurso, plataforma::public.plataforma, versao)
  on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima $$;

-- ── 1. O comparador completa com zeros ────────────────────────────────────────
select is(privado.versao_em_quatro('1.2'), '{1,2,0,0}'::int[], 'versao_em_quatro: "1.2" vira {1,2,0,0}');
select ok(privado.versao_em_quatro('1.2') = privado.versao_em_quatro('1.2.0'), 'versao_em_quatro: "1.2" é igual a "1.2.0"');
select ok(privado.versao_em_quatro('1.10') > privado.versao_em_quatro('1.9'), 'versao_em_quatro: "1.10" é maior que "1.9"');
select ok(privado.versao_em_quatro('1.2.0.1') > privado.versao_em_quatro('1.2'), 'versao_em_quatro: aceita 4 partes, como registrar_dispositivo');
select ok(privado.versao_em_quatro('v1.2') is null and privado.versao_em_quatro('1..2') is null
          and privado.versao_em_quatro('') is null and privado.versao_em_quatro(null) is null,
  'versao_em_quatro: fora do formato é null');

-- ── 2. Tudo ligado e com mínimo: só a versão decide ───────────────────────────
update privado.recurso set ligado = true where chave in ('chamada_direta', 'perfil_rico');
insert into privado.recurso (chave, ligado) values ('chamada_direta', true), ('perfil_rico', true)
on conflict (chave) do nothing;
update privado.configuracao_app set foto_de_perfil = true;
select pg_temp.minimo(r, p, '1.2.0') from unnest(array['foto_de_perfil','chamada_direta','perfil_rico']) r,
  unnest(array['ios','android']) p;

-- Desde 20261112210000 o check-in por código nasce com a chave ligada e o mínimo do iOS em 1.2.0
-- (vale para todos): o quarto recurso também vem true quando a versão alcança 1.2.0.
select is(pg_temp.r('ios', '1.2'), '{"foto_de_perfil": true, "chamada_direta": true, "perfil_rico": true, "checkin_por_codigo": true}'::jsonb,
  '"1.2" alcança o mínimo "1.2.0": os três vêm true; checkin_por_codigo também (chave ligada e mínimo do iOS, 20261112210000)');
select is(pg_temp.r('ios', '1.10.0'), '{"foto_de_perfil": true, "chamada_direta": true, "perfil_rico": true, "checkin_por_codigo": true}'::jsonb,
  '"1.10.0" passa do mínimo "1.2.0"');
select is(pg_temp.r('ios', '1.1.9'), '{"foto_de_perfil": false, "chamada_direta": false, "perfil_rico": false, "checkin_por_codigo": false}'::jsonb,
  'abaixo do mínimo ("1.1.9"): os três vêm false');
select is(public.configuracao_do_app('ios')->'recursos',
  '{"foto_de_perfil": false, "chamada_direta": false, "perfil_rico": false, "checkin_por_codigo": false}'::jsonb,
  'sem versao_app (o app 1.0, o 1.1 e o Android de hoje): os três vêm false');
select is(pg_temp.r('ios', null), '{"foto_de_perfil": false, "chamada_direta": false, "perfil_rico": false, "checkin_por_codigo": false}'::jsonb,
  'versao_app nula: os três vêm false');
select is(pg_temp.r('ios', v), '{"foto_de_perfil": false, "chamada_direta": false, "perfil_rico": false, "checkin_por_codigo": false}'::jsonb,
  'versao_app malformada (' || quote_literal(v) || '): vale como ausente, sem erro')
  from unnest(array['1.2.0.0.1', 'v1.2', '1..2', '1.2.', '', ' 1.2', '1.2 (20261108)', '1234567']) v;
-- 0.2.67: até quatro partes, a mesma regra de registrar_dispositivo e de recurso_na_versao.
select is(pg_temp.r('ios', '1.2.0.1')->>'perfil_rico', 'true', 'versao_app de 4 partes ("1.2.0.1") alcança o mínimo "1.2.0" (0.2.67)');

-- O resto da resposta não depende da versão.
select is(public.configuracao_do_app('ios', '1.2') - 'recursos', public.configuracao_do_app('ios') - 'recursos',
  'versao_app só decide recursos: versões, loja e mensagem são as mesmas');

-- ── 3. Fechado por padrão: sem mínimo na plataforma, false ────────────────────
delete from privado.recurso_versao_minima where plataforma = 'android' and recurso = 'perfil_rico';
select is(pg_temp.r('android', '9.9.9')->>'perfil_rico', 'false', 'sem mínimo no Android, perfil_rico vem false mesmo ligado');
select is(pg_temp.r('ios', '1.2')->>'perfil_rico', 'true', 'o mínimo é por plataforma: no iOS, perfil_rico segue true');
select is(pg_temp.r('android', '9.9.9')->>'chamada_direta', 'true', 'e por recurso: no Android, chamada_direta segue true');

-- ── 4. Com mínimo, a chave desligada ainda manda ──────────────────────────────
update privado.recurso set ligado = false where chave = 'chamada_direta';
select is(pg_temp.r('ios', '1.2')->>'chamada_direta', 'false', 'chave desligada com mínimo alcançado: false');
delete from privado.recurso where chave = 'perfil_rico';
select is(pg_temp.r('ios', '1.2')->>'perfil_rico', 'false', 'chave ausente com mínimo alcançado: false');
update privado.configuracao_app set foto_de_perfil = false where plataforma = 'android';
select is(pg_temp.r('android', '1.2')->>'foto_de_perfil', 'false', 'foto_de_perfil desligada no Android: false');
select is(pg_temp.r('ios', '1.2')->>'foto_de_perfil', 'true', 'foto_de_perfil segue por plataforma: no iOS, true');

-- ── 5. As regras da tabela do mínimo ──────────────────────────────────────────
select throws_ok($$ select pg_temp.minimo('agenda', 'ios', '1.2.0') $$, '23514', null,
  'recurso_versao_minima_recurso: só os recursos do contrato');
select throws_ok($$ select pg_temp.minimo('perfil_rico', 'ios', '1.2.0.0.1') $$, '23514', null,
  'recurso_versao_minima_formato: o mínimo tem de 1 a 4 partes, como versao_app (0.2.67)');
select lives_ok($$ select pg_temp.minimo('perfil_rico', 'android', '1.2.0.1') $$,
  'recurso_versao_minima_formato: mínimo de 4 partes é aceito (0.2.67)');
select throws_ok($$ insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
                    values ('foto_de_perfil', 'ios', '1.3.0') $$, '23505', null,
  'recurso_versao_minima_pkey: um mínimo por recurso e plataforma');

-- ── 6. Assinatura e acesso ────────────────────────────────────────────────────
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'configuracao_do_app'), 1,
  'uma configuracao_do_app só: duas com default deixariam a chamada com plataforma ambígua (PGRST203)');
select ok(has_function_privilege('anon', 'public.configuracao_do_app(text, text)', 'EXECUTE'),
  'anon lê a configuração do app antes do login');
-- anon e authenticated têm o grant de propósito; PUBLIC não, senão um papel novo herdaria a leitura
-- sem ninguém decidir (mutante O-2 da revisão do Lince no #450).
select ok(not has_function_privilege('public', 'public.configuracao_do_app(text, text)', 'EXECUTE'),
  'PUBLIC não executa configuracao_do_app: o acesso é só o que se deu a anon e authenticated');
select ok(not has_table_privilege('anon', 'privado.recurso_versao_minima', 'SELECT')
          and not has_table_privilege('authenticated', 'privado.recurso_versao_minima', 'SELECT,INSERT,UPDATE,DELETE'),
  'privado.recurso_versao_minima fechada ao cliente');
select ok(not has_function_privilege('anon', 'privado.recurso_na_versao(text, text, text)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'privado.recurso_na_versao(text, text, text)', 'EXECUTE'),
  'privado.recurso_na_versao fechada ao cliente');

select * from finish();
rollback;
