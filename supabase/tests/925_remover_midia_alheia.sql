-- 925_remover_midia_alheia.sql
--
-- GqEzdDhW: `public.remover_midia` só enxerga a mídia do dono (foto de perfil, sem casa) ou de um MEMBRO da casa dona (`(m.estabelecimento_id is null and
-- m.dono_usuario_id = v_uid) or privado.eh_membro(m.estabelecimento_id)`); senão é 404. Só o dono removendo estava testado (802, 805). Sem a cláusula,
-- qualquer conta que conhecesse o `midia_id` marcaria a foto de outra pessoa como removida e enfileiraria o expurgo FÍSICO, que é irreversível.
--   A  outra profissional, e o dono de outra casa, tentam remover a foto de perfil de X: 404 nao_encontrado
--   B  um membro da casa B e outra profissional tentam remover o logo da casa A: 404 nao_encontrado (e é o mesmo 404 de um id que não existe)
--   C  nada muda: a mídia segue no estado de antes, com o mesmo `atualizado_em`, e nada entra na fila `expurgo_midia`
--   D  controles: o dono remove a foto dele, e um membro (administrador e operador) da casa remove o logo: estado `removida` e uma mensagem de expurgo
-- Ids próprios (`92500000`). Só dados sintéticos.
begin;
select plan(16);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local "frila.agora" = '2026-11-27 15:00:00+00';
update privado.configuracao_app set foto_de_perfil = true;

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

-- X: profissional dona da foto. Y: outra profissional. A1: administrador da casa A. A2: operador da casa A. B1: administrador da casa B.
insert into auth.users (id, email) values
  ('92500000-0000-4000-8000-000000000001', 'x.925@teste.invalid'),
  ('92500000-0000-4000-8000-000000000002', 'y.925@teste.invalid'),
  ('92500000-0000-4000-8000-000000000003', 'a1.925@teste.invalid'),
  ('92500000-0000-4000-8000-000000000004', 'a2.925@teste.invalid'),
  ('92500000-0000-4000-8000-000000000005', 'b1.925@teste.invalid');
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em, estado)
select u.id, case when right(u.id::text, 1) in ('1', '2') then 'profissional' else 'contratante' end::public.perfil_conta,
       'Conta ' || right(u.id::text, 1), u.email, '+556195550925' || right(u.id::text, 1), '1990-01-01', '1.0', now(), 'ativa'
  from auth.users u where u.email like '%.925@teste.invalid';

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('92500000-0000-4000-8000-0000000000a1', 'Casa A 925', '92511222000191', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('92500000-0000-4000-8000-0000000000b1', 'Casa B 925', '92511222000292', 'food_service', 'CLN 202', 'POINT(-47.8825 -15.7945)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('92500000-0000-4000-8000-0000000000a1', '92500000-0000-4000-8000-000000000003', 'administrador'),
  ('92500000-0000-4000-8000-0000000000a1', '92500000-0000-4000-8000-000000000004', 'operador'),
  ('92500000-0000-4000-8000-0000000000b1', '92500000-0000-4000-8000-000000000005', 'administrador');

-- Três mídias: a foto de X (aprovada), o logo da casa A (aprovado) e um segundo logo da casa A (em análise: o índice só admite uma aprovada por dono).
insert into privado.midia (id, dono_usuario_id, estabelecimento_id, dono_tipo, tipo, storage_path, mime, bytes, estado, criado_em, atualizado_em) values
  ('92500000-0000-4000-8000-0000000000d1', '92500000-0000-4000-8000-000000000001', null, 'profissional', 'foto_perfil', 'perfil/925-x.jpg', 'image/jpeg', 1024, 'aprovada', '2026-11-20 10:00:00+00', '2026-11-20 10:00:00+00'),
  ('92500000-0000-4000-8000-0000000000d2', '92500000-0000-4000-8000-000000000003', '92500000-0000-4000-8000-0000000000a1', 'estabelecimento', 'foto_perfil', 'perfil/925-a1.jpg', 'image/jpeg', 1024, 'aprovada', '2026-11-20 10:00:00+00', '2026-11-20 10:00:00+00'),
  ('92500000-0000-4000-8000-0000000000d3', '92500000-0000-4000-8000-000000000003', '92500000-0000-4000-8000-0000000000a1', 'estabelecimento', 'foto_perfil', 'perfil/925-a2.jpg', 'image/jpeg', 1024, 'em_analise', '2026-11-20 10:00:00+00', '2026-11-20 10:00:00+00');

create temp table antes as select id, estado, atualizado_em from privado.midia where id::text like '92500000-%';
select is((select count(*)::int from antes), 3, '0 três mídias antes de tudo (duas aprovadas, uma em análise)');
select is((select count(*)::int from pgmq.q_expurgo_midia where message->>'verificacao_id' like '92500000-%'), 0, '0b e nada dessas na fila de expurgo');

-- ── A. A foto de perfil de X ──────────────────────────────────────────────────

select is((pg_temp.erro('92500000-0000-4000-8000-000000000002', $$ select public.remover_midia('92500000-0000-4000-8000-0000000000d1') $$))->>'code',
  'nao_encontrado', 'A1 outra profissional tenta remover a foto de X: 404 nao_encontrado');
select is((pg_temp.erro('92500000-0000-4000-8000-000000000005', $$ select public.remover_midia('92500000-0000-4000-8000-0000000000d1') $$))->>'status',
  '404', 'A2 o dono de outra casa tenta remover a foto de X: 404');
select is((pg_temp.erro('92500000-0000-4000-8000-000000000003', $$ select public.remover_midia('92500000-0000-4000-8000-0000000000d1') $$))->>'code',
  'nao_encontrado', 'A3 nem o administrador de uma casa remove a foto pessoal de X: 404');

-- ── B. O logo da casa A ───────────────────────────────────────────────────────

select is((pg_temp.erro('92500000-0000-4000-8000-000000000005', $$ select public.remover_midia('92500000-0000-4000-8000-0000000000d2') $$))->>'code',
  'nao_encontrado', 'B1 o administrador da casa B tenta remover o logo da casa A: 404 nao_encontrado');
select is((pg_temp.erro('92500000-0000-4000-8000-000000000002', $$ select public.remover_midia('92500000-0000-4000-8000-0000000000d2') $$))->>'code',
  'nao_encontrado', 'B2 outra profissional tenta remover o logo da casa A: 404');
select is((pg_temp.erro('92500000-0000-4000-8000-000000000001', $$ select public.remover_midia('92500000-0000-4000-8000-0000000000d2') $$))->>'code',
  'nao_encontrado', 'B3 nem a dona de outra mídia remove o logo da casa A: 404');
select is(
  pg_temp.erro('92500000-0000-4000-8000-000000000005', $$ select public.remover_midia('92500000-0000-4000-8000-0000000000d2') $$),
  pg_temp.erro('92500000-0000-4000-8000-000000000005', $$ select public.remover_midia('92500000-0000-4000-8000-0000000000ff') $$),
  'B4 é o mesmo 404 de um id que não existe: não diz que a mídia existe');

-- ── C. Nada mudou ─────────────────────────────────────────────────────────────

select is((select count(*)::int from antes a join privado.midia m on m.id = a.id and m.estado = a.estado and m.atualizado_em = a.atualizado_em), 3,
  'C1 as três mídias seguem no mesmo estado, com o mesmo atualizado_em');
select is((select count(*)::int from privado.midia where id::text like '92500000-%' and estado in ('aprovada', 'em_analise')), 3, 'C2 e nenhuma virou removida');
select is((select count(*)::int from pgmq.q_expurgo_midia where message->>'verificacao_id' like '92500000-%'), 0, 'C3 nada entrou na fila de expurgo físico');

-- ── D. Controles: o dono e os membros da casa removem ─────────────────────────

select is((pg_temp.como('92500000-0000-4000-8000-000000000001', $$ select public.remover_midia('92500000-0000-4000-8000-0000000000d1') $$))->>'estado',
  'removida', 'D1 o dono remove a foto dele');
select is((pg_temp.como('92500000-0000-4000-8000-000000000003', $$ select public.remover_midia('92500000-0000-4000-8000-0000000000d2') $$))->>'estado',
  'removida', 'D2 o administrador da casa A remove o logo da casa');
select is((pg_temp.como('92500000-0000-4000-8000-000000000004', $$ select public.remover_midia('92500000-0000-4000-8000-0000000000d3') $$))->>'estado',
  'removida', 'D3 o operador da casa A (membro) remove o outro logo');
select is((select count(*)::int from pgmq.q_expurgo_midia where message->>'verificacao_id' in
  ('92500000-0000-4000-8000-0000000000d1', '92500000-0000-4000-8000-0000000000d2', '92500000-0000-4000-8000-0000000000d3')), 3,
  'D4 e cada remoção enfileirou o seu expurgo (uma mensagem por mídia)');

select * from finish();
rollback;
