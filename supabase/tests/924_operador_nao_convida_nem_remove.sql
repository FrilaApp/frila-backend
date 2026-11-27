-- 924_operador_nao_convida_nem_remove.sql
--
-- WiWn50Pk (itens 93 e 94): `convidar_membro` e `remover_membro` (migração 20261117120000) exigem `privado.eh_administrador(<casa>)`. Os 403 testados
-- até aqui (843, 883) vêm de uma conta de FORA da casa: trocar `eh_administrador` por `eh_membro` deixava tudo verde, e o OPERADOR da própria casa
-- poderia convidar uma conta dele como administrador, ou remover os colegas.
--   A  o operador da casa chama convidar_membro (como operador e como administrador, inclusive para o e-mail dele): 403 sem_permissao, e nenhum
--      convite nasce
--   B  o operador chama remover_membro (um colega e um administrador, pelo id e pelo usuario_id), com OUTRO administrador na casa: 403, e todos
--      os vínculos ficam como estavam
--   C  controle: o administrador faz as mesmas coisas e funciona, então o 403 não vem de teste vazio
-- A casa tem dois administradores de propósito: a trava de "último administrador" não pode mascarar o 403. Ids próprios (`92400000`).
begin;
select plan(15);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local "frila.agora" = '2026-11-27 15:00:00+00';

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

-- A recusa por inteiro: o envelope de public.erro (message) mais o status (detail).
create function pg_temp.erro(conta uuid, sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  perform pg_temp.como(conta, sql);
  return null;
exception when others then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return msg::jsonb || det::jsonb;
end $$;

-- U1 e U2: administradores da casa. U3: OPERADOR (quem faz as chamadas negadas). U4: outro operador (o colega).
insert into auth.users (id, email, email_confirmed_at) values
  ('92400000-0000-4000-8000-000000000001', 'u1.924@teste.invalid', now()),
  ('92400000-0000-4000-8000-000000000002', 'u2.924@teste.invalid', now()),
  ('92400000-0000-4000-8000-000000000003', 'u3.924@teste.invalid', now()),
  ('92400000-0000-4000-8000-000000000004', 'u4.924@teste.invalid', now());
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em, estado)
select id, 'contratante', 'Conta ' || right(email, 22), email, '+556195550924' || right(id::text, 1), '1985-01-01', '1.0', now(), 'ativa'
  from auth.users where email like '%.924@teste.invalid';

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('92400000-0000-4000-8000-0000000000a1', 'Casa 924', '92411222000191', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('92400000-0000-4000-8000-0000000000a1', '92400000-0000-4000-8000-000000000001', 'administrador'),
  ('92400000-0000-4000-8000-0000000000a1', '92400000-0000-4000-8000-000000000002', 'administrador'),
  ('92400000-0000-4000-8000-0000000000a1', '92400000-0000-4000-8000-000000000003', 'operador'),
  ('92400000-0000-4000-8000-0000000000a1', '92400000-0000-4000-8000-000000000004', 'operador');

create temp table antes as
  select id, usuario_id, papel::text as papel from public.membro_estabelecimento where estabelecimento_id = '92400000-0000-4000-8000-0000000000a1';
create temp table ids as select
  (select id from antes where usuario_id = '92400000-0000-4000-8000-000000000001') as u1,
  (select id from antes where usuario_id = '92400000-0000-4000-8000-000000000004') as u4;

select is((select count(*)::int from antes), 4, '0 a casa tem quatro vínculos: dois administradores e dois operadores');
select is((select papel from antes where usuario_id = '92400000-0000-4000-8000-000000000003'), 'operador', '0b e o U3, quem chama, é operador');

-- ── A. O operador convida ─────────────────────────────────────────────────────

select is((pg_temp.erro('92400000-0000-4000-8000-000000000003',
  $$ select public.convidar_membro(estabelecimento_id => '92400000-0000-4000-8000-0000000000a1'::uuid, email => 'novo.924@teste.invalid', papel => 'operador') $$))->>'code',
  'sem_permissao', 'A1 o operador convida um operador: 403 sem_permissao');
select is((pg_temp.erro('92400000-0000-4000-8000-000000000003',
  $$ select public.convidar_membro(estabelecimento_id => '92400000-0000-4000-8000-0000000000a1'::uuid, email => 'novo.924@teste.invalid', papel => 'administrador') $$))->>'code',
  'sem_permissao', 'A2 o operador convida um ADMINISTRADOR: 403 sem_permissao');
select is((pg_temp.erro('92400000-0000-4000-8000-000000000003',
  $$ select public.convidar_membro(estabelecimento_id => '92400000-0000-4000-8000-0000000000a1'::uuid, email => 'u3.924@teste.invalid', papel => 'administrador') $$))->>'status',
  '403', 'A3 o operador convida a própria conta como administrador: 403');
select is((select count(*)::int from privado.convite_membro where estabelecimento_id = '92400000-0000-4000-8000-0000000000a1'), 0, 'A4 nenhum convite nasceu');

-- ── B. O operador remove ──────────────────────────────────────────────────────

select is((pg_temp.erro('92400000-0000-4000-8000-000000000003',
  format($$ select public.remover_membro(estabelecimento_id => '92400000-0000-4000-8000-0000000000a1'::uuid, membro_id => %L::uuid) $$, (select u4 from ids))))->>'code',
  'sem_permissao', 'B1 o operador remove o colega (pelo id do vínculo): 403 sem_permissao');
select is((pg_temp.erro('92400000-0000-4000-8000-000000000003',
  $$ select public.remover_membro(estabelecimento_id => '92400000-0000-4000-8000-0000000000a1'::uuid, membro_id => '92400000-0000-4000-8000-000000000004'::uuid) $$))->>'code',
  'sem_permissao', 'B2 e pelo usuario_id: 403');
select is((pg_temp.erro('92400000-0000-4000-8000-000000000003',
  format($$ select public.remover_membro(estabelecimento_id => '92400000-0000-4000-8000-0000000000a1'::uuid, membro_id => %L::uuid) $$, (select u1 from ids))))->>'code',
  'sem_permissao', 'B3 o operador remove um ADMINISTRADOR (com outro presente): 403');
select is((pg_temp.erro('92400000-0000-4000-8000-000000000003',
  $$ select public.remover_membro(estabelecimento_id => '92400000-0000-4000-8000-0000000000a1'::uuid, membro_id => '92400000-0000-4000-8000-000000000001'::uuid) $$))->>'code',
  'sem_permissao', 'B4 e pelo usuario_id: 403');
select is((select count(*)::int from antes a join public.membro_estabelecimento m on m.id = a.id and m.usuario_id = a.usuario_id and m.papel::text = a.papel
           where m.estabelecimento_id = '92400000-0000-4000-8000-0000000000a1'), 4, 'B5 os quatro vínculos, com o mesmo papel, como antes');

-- ── C. Controles: o administrador faz o mesmo e funciona ──────────────────────

select ok((pg_temp.como('92400000-0000-4000-8000-000000000001',
  $$ select public.convidar_membro(estabelecimento_id => '92400000-0000-4000-8000-0000000000a1'::uuid, email => 'novo.924@teste.invalid', papel => 'administrador') $$)) ? 'token',
  'C1 o administrador convida (até um administrador): 200 com token');
select is((select count(*)::int from privado.convite_membro where estabelecimento_id = '92400000-0000-4000-8000-0000000000a1'), 1, 'C2 e o convite nasceu');
select is((pg_temp.como('92400000-0000-4000-8000-000000000001',
  format($$ select public.remover_membro(estabelecimento_id => '92400000-0000-4000-8000-0000000000a1'::uuid, membro_id => %L::uuid) $$, (select u4 from ids))))->>'removido',
  'true', 'C3 o administrador remove o mesmo colega: 200 removido');
select is((select count(*)::int from public.membro_estabelecimento where id = (select u4 from ids)), 0, 'C4 e o vínculo saiu');

select * from finish();
rollback;
