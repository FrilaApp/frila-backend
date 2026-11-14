-- 857_chamada_respeita_preferencia_de_quem_ja_trabalhou.sql
--
-- chamar_profissional obedece à preferência "aceitar chamadas de quem já trabalhou comigo"
-- (migração 20261113212000; Bússola, condição para ligar a chamada direta; LGPD art. 6º, VI; B-019).
-- Antes, definir_preferencia_chamadas gravava aceita_de_quem_ja_trabalhou e nenhuma regra lia o campo.
--   A: equipe, aparelho iOS 1.2.0, desliga a preferência pela RPC     B: igual, preferência ligada (controle)
-- Casa CPF. Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-07 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-857';
select plan(8);

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;
-- O envelope inteiro da recusa ("status code details"), ou 'ok'.
create function pg_temp.r(sql text) returns text language plpgsql as $$
declare m text; d text;
begin
  perform pg_temp.como('c8570000-0000-4000-8000-000000000001', sql);
  return 'ok';
exception when others then
  get stacked diagnostics m = message_text, d = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return case when m ~ '^\s*\{' then concat_ws(' ', d::jsonb->>'status', m::jsonb->>'code', m::jsonb->>'details') else m end;
end $$;
-- Corpo válido, ou inválido (sem funcao_id: 422 campo_obrigatorio para quem passa das três).
create function pg_temp.chamar(letra text, valido boolean) returns text language sql as $$
  select format($a$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
    estabelecimento_id => 'c8570000-0000-4000-8000-0000000000e1', funcao_id => %s,
    inicio_em => '2026-11-08 18:00+00', fim_em => '2026-11-08 23:00+00', local => 'CLN 201',
    regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}',
    valor_centavos => 15000, inclui_refeicao => true, inclui_transporte => false,
    exige_material_proprio => false, responsavel_local => 'Maitre') $a$,
    (select p.id from public.profissional p join auth.users u on u.id = p.usuario_id where u.email = letra || '@t857.test'),
    case when valido then quote_literal((select id from public.funcao where nome = 'garçom')) else 'null' end) $$;

insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', ('c8570000-0000-4000-8000-00000000000' || n)::uuid,
       'authenticated', 'authenticated', (array['casa','a','b'])[n] || '@t857.test',
       privado.agora(), privado.agora(), false, false
  from generate_series(1, 3) n;
select pg_temp.como(('c8570000-0000-4000-8000-00000000000' || n)::uuid, format(
  $$ select public.criar_conta(%L, 'Pessoa %s', '+556195558570%s', '1990-01-01', '2026-09-22') $$,
  case when n = 1 then 'contratante' else 'profissional' end, n, n)) from generate_series(1, 3) n;
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c8570000-0000-4000-8000-0000000000e1', 'Casa 857', '85712345666', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c8570000-0000-4000-8000-000000000001', 'c8570000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (usuario_id, ponto_base)
select ('c8570000-0000-4000-8000-00000000000' || n)::uuid, 'POINT(-47.8822 -15.7800)'::extensions.geography
  from generate_series(2, 3) n;
insert into public.profissional_funcao
select p.id, (select id from public.funcao where nome = 'garçom') from public.profissional p
 where p.usuario_id::text like 'c8570000-%';
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select 'c8570000-0000-4000-8000-0000000000e1', p.id from public.profissional p where p.usuario_id::text like 'c8570000-%';
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app) values
  ('c8570000-0000-4000-8000-000000000002', 'tok-857-a-0000000000000000', 'ios', '1.2.0'),
  ('c8570000-0000-4000-8000-000000000003', 'tok-857-b-0000000000000000', 'ios', '1.2.0');
update privado.recurso set ligado = true where chave = 'chamada_direta';
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;

-- A desliga a preferência pela própria RPC; B a liga (controle)
select is(pg_temp.como('c8570000-0000-4000-8000-000000000002',
            $$ select public.definir_preferencia_chamadas(aceita_de_quem_ja_trabalhou => false) $$) ->> 'aceita_de_quem_ja_trabalhou',
          'false', 'A desliga "aceitar chamadas de quem já trabalhou comigo"');
select is(pg_temp.como('c8570000-0000-4000-8000-000000000003',
            $$ select public.definir_preferencia_chamadas(aceita_de_quem_ja_trabalhou => true) $$) ->> 'aceita_de_quem_ja_trabalhou',
          'true', 'B deixa ligada');

select is(pg_temp.r(pg_temp.chamar('b', true)), 'ok', 'controle: B, com a preferência ligada, recebe a chamada');
select is(pg_temp.r(pg_temp.chamar('a', true)), '422 profissional_indisponivel nao_aceita_chamadas',
  'A, com a preferência desligada, não recebe: a mesma recusa genérica');
select is(pg_temp.r(pg_temp.chamar('a', false)), '422 profissional_indisponivel nao_aceita_chamadas',
  'com corpo inválido, a recusa de A segue a genérica (vem antes da validação do corpo)');
select is((select count(*)::int from public.chamada c join public.profissional p on p.id = c.profissional_id
            where p.usuario_id = 'c8570000-0000-4000-8000-000000000002'), 0, 'nenhuma chamada nasceu para A');

-- A volta a aceitar: a chamada nasce
select is(pg_temp.como('c8570000-0000-4000-8000-000000000002',
            $$ select public.definir_preferencia_chamadas(aceita_de_quem_ja_trabalhou => true) $$) ->> 'aceita_de_quem_ja_trabalhou',
          'true', 'A volta a aceitar');
select is(pg_temp.r(pg_temp.chamar('a', true)), 'ok', 'com a preferência ligada de novo, A recebe a chamada');

select * from finish();
rollback;
