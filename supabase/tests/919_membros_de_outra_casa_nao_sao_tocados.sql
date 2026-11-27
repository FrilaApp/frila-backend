-- 919_membros_de_outra_casa_nao_sao_tocados.sql
--
-- RAwqL6Ld (itens 86 e 87): `transferir_administracao` e `remover_membro` (migração 20261117120000) só enxergam os vínculos da casa que vem no
-- parâmetro (`m.estabelecimento_id = <casa>`). Sem esse filtro, quem administra a casa A e é só operador na casa B passaria o vínculo de B como
-- se fosse de A: promoveria a si mesmo a administrador de B, ou removeria gente de qualquer casa. O único 404 testado (883) usava um uuid inexistente.
--   A  transferir_administracao(casa A, membro de B) → 404 nao_encontrado, pelo `id` do vínculo e pelo `usuario_id`; os papéis em B não mudam
--   B  remover_membro(casa A, membro de B) → 404 nao_encontrado, pelo `id` e pelo `usuario_id` (inclusive o administrador de B e o próprio
--      vínculo do chamador em B); os vínculos de B continuam todos lá
--   C  os controles: o mesmo pedido com um membro da casa A funciona (promove, remove), então os 404 não vêm de um teste vazio
--   D  no fim, os vínculos da casa B são exatamente os do começo
-- Ids próprios (`91900000`). Só dados sintéticos.
begin;
select plan(21);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local "frila.agora" = '2026-11-17 15:00:00+00';

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

-- U1: administrador da casa A e só operador da casa B (o caso do cartão). U2: administrador da casa B. U3: operador da casa A.
-- U4: operador só da casa B.
insert into auth.users (id, email, email_confirmed_at) values
  ('91900000-0000-4000-8000-000000000001', 'u1.919@teste.invalid', now()),
  ('91900000-0000-4000-8000-000000000002', 'u2.919@teste.invalid', now()),
  ('91900000-0000-4000-8000-000000000003', 'u3.919@teste.invalid', now()),
  ('91900000-0000-4000-8000-000000000004', 'u4.919@teste.invalid', now());
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em, estado)
select id, 'contratante', 'Conta ' || right(email, 24), email, '+556195550919' || right(id::text, 1), '1985-01-01', '1.0', now(), 'ativa'
  from auth.users where email like '%.919@teste.invalid';

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('91900000-0000-4000-8000-0000000000a1', 'Casa A 919', '91911222000199', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('91900000-0000-4000-8000-0000000000b1', 'Casa B 919', '91911222000288', 'food_service', 'CLN 202', 'POINT(-47.8825 -15.7945)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('91900000-0000-4000-8000-0000000000a1', '91900000-0000-4000-8000-000000000001', 'administrador'),
  ('91900000-0000-4000-8000-0000000000a1', '91900000-0000-4000-8000-000000000003', 'operador'),
  ('91900000-0000-4000-8000-0000000000b1', '91900000-0000-4000-8000-000000000002', 'administrador'),
  ('91900000-0000-4000-8000-0000000000b1', '91900000-0000-4000-8000-000000000001', 'operador'),
  ('91900000-0000-4000-8000-0000000000b1', '91900000-0000-4000-8000-000000000004', 'operador');

-- Os vínculos de B, como estão antes de qualquer chamada, e os ids de vínculo que as chamadas usam.
create temp table vinculos_de_b_antes as
  select id, usuario_id, papel::text as papel from public.membro_estabelecimento where estabelecimento_id = '91900000-0000-4000-8000-0000000000b1';
create temp table ids as select
  (select id from public.membro_estabelecimento where estabelecimento_id = '91900000-0000-4000-8000-0000000000b1' and usuario_id = '91900000-0000-4000-8000-000000000001') as u1_em_b,
  (select id from public.membro_estabelecimento where estabelecimento_id = '91900000-0000-4000-8000-0000000000b1' and usuario_id = '91900000-0000-4000-8000-000000000004') as u4_em_b,
  (select id from public.membro_estabelecimento where estabelecimento_id = '91900000-0000-4000-8000-0000000000b1' and usuario_id = '91900000-0000-4000-8000-000000000002') as u2_em_b,
  (select id from public.membro_estabelecimento where estabelecimento_id = '91900000-0000-4000-8000-0000000000a1' and usuario_id = '91900000-0000-4000-8000-000000000003') as u3_em_a;

select is((select count(*)::int from vinculos_de_b_antes), 3, '0 a casa B tem três vínculos antes de tudo');
select ok(privado.eh_administrador('91900000-0000-4000-8000-0000000000a1') is not null, '0b o helper existe');

-- ── A. transferir_administracao com a casa de A e um membro de B ──────────────

select is((pg_temp.erro('91900000-0000-4000-8000-000000000001',
  format($$ select public.transferir_administracao(estabelecimento_id => '91900000-0000-4000-8000-0000000000a1'::uuid, novo_admin_id => %L::uuid) $$,
         (select u1_em_b from ids))))->>'code', 'nao_encontrado',
  'A1 o administrador de A passa o PRÓPRIO vínculo de operador em B (pelo id do vínculo): 404');
select is((pg_temp.erro('91900000-0000-4000-8000-000000000001',
  $$ select public.transferir_administracao(estabelecimento_id => '91900000-0000-4000-8000-0000000000a1'::uuid, novo_admin_id => '91900000-0000-4000-8000-000000000004'::uuid) $$))->>'code',
  'nao_encontrado', 'A2 passa um usuário que só é de B (pelo usuario_id): 404');
select is((pg_temp.erro('91900000-0000-4000-8000-000000000001',
  format($$ select public.transferir_administracao(estabelecimento_id => '91900000-0000-4000-8000-0000000000a1'::uuid, novo_admin_id => %L::uuid) $$,
         (select u4_em_b from ids))))->>'code', 'nao_encontrado',
  'A3 passa o vínculo de outro operador de B (pelo id do vínculo): 404');
select is((select papel::text from public.membro_estabelecimento where id = (select u1_em_b from ids)), 'operador',
  'A4 o chamador segue operador em B (não se promoveu)');
select is((select papel::text from public.membro_estabelecimento where id = (select u4_em_b from ids)), 'operador', 'A5 o operador de B segue operador');

-- ── B. remover_membro com a casa de A e um membro de B ────────────────────────

select is((pg_temp.erro('91900000-0000-4000-8000-000000000001',
  format($$ select public.remover_membro(estabelecimento_id => '91900000-0000-4000-8000-0000000000a1'::uuid, membro_id => %L::uuid) $$, (select u4_em_b from ids))))->>'code',
  'nao_encontrado', 'B1 remover o operador de B (pelo id do vínculo): 404');
select is((pg_temp.erro('91900000-0000-4000-8000-000000000001',
  $$ select public.remover_membro(estabelecimento_id => '91900000-0000-4000-8000-0000000000a1'::uuid, membro_id => '91900000-0000-4000-8000-000000000004'::uuid) $$))->>'code',
  'nao_encontrado', 'B2 remover o operador de B (pelo usuario_id): 404');
select is((pg_temp.erro('91900000-0000-4000-8000-000000000001',
  format($$ select public.remover_membro(estabelecimento_id => '91900000-0000-4000-8000-0000000000a1'::uuid, membro_id => %L::uuid) $$, (select u2_em_b from ids))))->>'code',
  'nao_encontrado', 'B3 remover o administrador de B (pelo id do vínculo): 404');
select is((pg_temp.erro('91900000-0000-4000-8000-000000000001',
  $$ select public.remover_membro(estabelecimento_id => '91900000-0000-4000-8000-0000000000a1'::uuid, membro_id => '91900000-0000-4000-8000-000000000002'::uuid) $$))->>'code',
  'nao_encontrado', 'B4 remover o administrador de B (pelo usuario_id): 404');
select is((pg_temp.erro('91900000-0000-4000-8000-000000000001',
  format($$ select public.remover_membro(estabelecimento_id => '91900000-0000-4000-8000-0000000000a1'::uuid, membro_id => %L::uuid) $$, (select u1_em_b from ids))))->>'code',
  'nao_encontrado', 'B5 o chamador não sai do próprio vínculo em B por intermédio de A: 404');
select is((select count(*)::int from public.membro_estabelecimento where estabelecimento_id = '91900000-0000-4000-8000-0000000000b1'), 3, 'B6 a casa B segue com os três vínculos');

-- ── C. Controles: o mesmo pedido com um membro da casa A funciona ─────────────

select is((pg_temp.como('91900000-0000-4000-8000-000000000001',
  format($$ select public.transferir_administracao(estabelecimento_id => '91900000-0000-4000-8000-0000000000a1'::uuid, novo_admin_id => %L::uuid) $$, (select u3_em_a from ids))))->>'papel',
  'administrador', 'C1 transferir_administracao com um membro de A promove');
select is((select papel::text from public.membro_estabelecimento where id = (select u3_em_a from ids)), 'administrador', 'C2 e o vínculo dele em A mudou');
select is((pg_temp.como('91900000-0000-4000-8000-000000000001',
  format($$ select public.remover_membro(estabelecimento_id => '91900000-0000-4000-8000-0000000000a1'::uuid, membro_id => %L::uuid) $$, (select u3_em_a from ids))))->>'removido',
  'true', 'C3 remover_membro com um membro de A remove');
select is((select count(*)::int from public.membro_estabelecimento where estabelecimento_id = '91900000-0000-4000-8000-0000000000a1'), 1, 'C4 e a casa A ficou só com o administrador');

-- ── D. A casa B, no fim, é a do começo ────────────────────────────────────────

select is((select count(*)::int from vinculos_de_b_antes a
            join public.membro_estabelecimento m on m.id = a.id and m.usuario_id = a.usuario_id and m.papel::text = a.papel
           where m.estabelecimento_id = '91900000-0000-4000-8000-0000000000b1'), 3, 'D1 os três vínculos de B, com o mesmo papel');
select is((select count(*)::int from public.membro_estabelecimento where estabelecimento_id = '91900000-0000-4000-8000-0000000000b1' and papel = 'administrador'), 1,
  'D2 e B continua com um administrador só (o U2)');
select is((select usuario_id from public.membro_estabelecimento where estabelecimento_id = '91900000-0000-4000-8000-0000000000b1' and papel = 'administrador'),
  '91900000-0000-4000-8000-000000000002'::uuid, 'D3 que é o dono de B');
select is((select count(*)::int from public.membro_estabelecimento where usuario_id = '91900000-0000-4000-8000-000000000001'), 2,
  'D4 o U1 tem os dois vínculos (A e B)');

select * from finish();
rollback;
