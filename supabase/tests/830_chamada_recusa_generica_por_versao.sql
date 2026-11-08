-- 830_chamada_recusa_generica_por_versao.sql
--
-- chamar_profissional por versão do app (contrato 0.2.66; 20261108160000). O profissional sem
-- nenhum aparelho na versão mínima de chamada_direta da plataforma recebe a recusa genérica
-- (422 profissional_indisponivel, nao_aceita_chamadas), a mesma da preferência só-CNPJ e da falta
-- de vínculo. E a ordem das checagens não denuncia qual delas valeu: com corpo inválido, as três
-- seguem idênticas (revisão do Lince AG no frila-documentacao #193). Casa CPF. Só dados sintéticos.
--   A: equipe, aparelho iOS 1.2.0 (controle)     B: equipe, iOS 1.1.0 e Android sem mínimo
--   C: equipe, aparelho ok, aceita só de CNPJ     D: sem vínculo, aparelho ok
--   E: equipe, sem aparelho (sem permissão)       F: equipe, aparelho iOS "1.2" (zeros)
--   G: equipe, aparelho ok, usado só quando o mínimo some
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-07 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-830';
select plan(14);

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
  perform pg_temp.como('c8300000-0000-4000-8000-000000000001', sql);
  return 'ok';
exception when others then
  get stacked diagnostics m = message_text, d = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return case when m ~ '^\s*\{' then concat_ws(' ', d::jsonb->>'status', m::jsonb->>'code', m::jsonb->>'details') else m end;
end $$;
-- Corpo válido, ou inválido (sem funcao_id: 422 campo_obrigatorio para quem passa das três).
create function pg_temp.chamar(letra text, valido boolean) returns text language sql as $$
  select format($a$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
    estabelecimento_id => 'c8300000-0000-4000-8000-0000000000e1', funcao_id => %s,
    inicio_em => '2026-11-08 18:00+00', fim_em => '2026-11-08 23:00+00', local => 'CLN 201',
    regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}',
    valor_centavos => 15000, inclui_refeicao => true, inclui_transporte => false,
    exige_material_proprio => false, responsavel_local => 'Maitre') $a$,
    (select p.id from public.profissional p join auth.users u on u.id = p.usuario_id where u.email = letra || '@t830.test'),
    case when valido then quote_literal((select id from public.funcao where nome = 'garçom')) else 'null' end) $$;

insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', ('c8300000-0000-4000-8000-00000000000' || n)::uuid,
       'authenticated', 'authenticated', (array['casa','a','b','c','d','e','f','g'])[n] || '@t830.test',
       privado.agora(), privado.agora(), false, false
  from generate_series(1, 8) n;
select pg_temp.como(('c8300000-0000-4000-8000-00000000000' || n)::uuid, format(
  $$ select public.criar_conta(%L, 'Pessoa %s', '+556195558300%s', '1990-01-01', '2026-09-22') $$,
  case when n = 1 then 'contratante' else 'profissional' end, n, n)) from generate_series(1, 8) n;
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c8300000-0000-4000-8000-0000000000e1', 'Casa 830', '83012345666', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c8300000-0000-4000-8000-000000000001', 'c8300000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (usuario_id, ponto_base)
select ('c8300000-0000-4000-8000-00000000000' || n)::uuid, 'POINT(-47.8822 -15.7800)'::extensions.geography
  from generate_series(2, 8) n;
insert into public.profissional_funcao
select p.id, (select id from public.funcao where nome = 'garçom') from public.profissional p
 where p.usuario_id::text like 'c8300000-%';
-- Todos na equipe de confiança, menos o D.
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select 'c8300000-0000-4000-8000-0000000000e1', p.id from public.profissional p
 where p.usuario_id::text like 'c8300000-%' and p.usuario_id <> 'c8300000-0000-4000-8000-000000000005';
insert into public.profissional_preferencia_chamada (profissional_id, aceita_de)
select p.id, 'so_cnpj' from public.profissional p where p.usuario_id = 'c8300000-0000-4000-8000-000000000004';
-- Aparelhos: o mínimo de chamada_direta é iOS 1.2.0; o Android não tem mínimo.
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app) values
  ('c8300000-0000-4000-8000-000000000002', 'tok-830-a-0000000000000000', 'ios', '1.2.0'),
  ('c8300000-0000-4000-8000-000000000003', 'tok-830-b-ios-000000000000', 'ios', '1.1.0'),
  ('c8300000-0000-4000-8000-000000000003', 'tok-830-b-android-00000000', 'android', '9.9.9'),
  ('c8300000-0000-4000-8000-000000000004', 'tok-830-c-0000000000000000', 'ios', '1.2.0'),
  ('c8300000-0000-4000-8000-000000000005', 'tok-830-d-0000000000000000', 'ios', '1.2.0'),
  ('c8300000-0000-4000-8000-000000000007', 'tok-830-f-0000000000000000', 'ios', '1.2'),
  ('c8300000-0000-4000-8000-000000000008', 'tok-830-g-0000000000000000', 'ios', '1.2.0');
update privado.recurso set ligado = true where chave = 'chamada_direta';
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0');

-- ── 1. O controle: o corpo inválido é inválido de verdade ────────────────────
select is(pg_temp.r(pg_temp.chamar('a', false)), '422 campo_obrigatorio funcao_id',
  'controle: quem passa das três recusas, com corpo sem funcao_id, recebe campo_obrigatorio');
select is(pg_temp.r(pg_temp.chamar('a', true)), 'ok', 'controle: aparelho iOS 1.2.0 no mínimo, corpo válido: a chamada nasce');
select is(pg_temp.r(pg_temp.chamar('f', true)), 'ok', 'aparelho em "1.2" alcança o mínimo "1.2.0" (zeros)');

-- ── 2. A versão recusa com a recusa genérica ──────────────────────────────────
select is(pg_temp.r(pg_temp.chamar('b', true)), '422 profissional_indisponivel nao_aceita_chamadas',
  'aparelho abaixo do mínimo (iOS 1.1.0) e Android sem mínimo: nao_aceita_chamadas');
select is(pg_temp.r(pg_temp.chamar('e', true)), '422 profissional_indisponivel nao_aceita_chamadas',
  'sem nenhum aparelho (sem permissão de notificação): não pode ser chamado');
select is(pg_temp.r(pg_temp.chamar('c', true)), '422 profissional_indisponivel nao_aceita_chamadas',
  'preferência só-CNPJ com casa CPF: nao_aceita_chamadas');
select is(pg_temp.r(pg_temp.chamar('d', true)), '422 profissional_indisponivel nao_aceita_chamadas',
  'sem vínculo com a casa: nao_aceita_chamadas');

-- ── 3. Com corpo inválido, as recusas seguem idênticas ────────────────────────
select is(pg_temp.r(pg_temp.chamar(l, false)), '422 profissional_indisponivel nao_aceita_chamadas',
  'corpo inválido não distingue (' || l || '): a recusa genérica vem antes da validação do corpo')
  from unnest(array['b', 'e', 'c', 'd']) l;
select is((select count(distinct pg_temp.r(pg_temp.chamar(l, v)))::int
             from unnest(array['b', 'e', 'c', 'd']) l, unnest(array[true, false]) v), 1,
  'versão, preferência e vínculo, com corpo válido e inválido: um envelope só');

-- ── 4. Nada nasceu para quem foi recusado ─────────────────────────────────────
select is((select count(*)::int from public.chamada c join public.profissional p on p.id = c.profissional_id
            where p.usuario_id in ('c8300000-0000-4000-8000-000000000003', 'c8300000-0000-4000-8000-000000000004',
                                   'c8300000-0000-4000-8000-000000000005', 'c8300000-0000-4000-8000-000000000006')), 0,
  'nenhuma chamada nasceu para B, C, D ou E');

-- ── 5. O mínimo manda: sem ele, nem o aparelho certo basta ────────────────────
delete from privado.recurso_versao_minima where recurso = 'chamada_direta';
select is(pg_temp.r(pg_temp.chamar('g', true)), '422 profissional_indisponivel nao_aceita_chamadas',
  'sem mínimo configurado para chamada_direta: ninguém pode ser chamado (fechado por padrão)');

select * from finish();
rollback;
