-- 780_privado_bloqueio_e_membro.sql
--
-- Cobertura pgTAP de privado.bloqueado_com_estabelecimento(conta uuid, estab uuid)
-- e privado.eh_membro(estab uuid), com provas de mutação dinâmica que matam
-- mutantes de bloqueio consigo mesmo, direcionalidade, papel de membro e controle de acesso (RF26, RN06).
--
-- Regras validadas:
--   1. Bloqueio bidirecional:
--      - Profissional que bloqueou qualquer membro do estabelecimento é detectado como bloqueado.
--      - Profissional que foi bloqueado por membro do estabelecimento é detectado como bloqueado.
--   2. Trava de auto-bloqueio (m.usuario_id <> conta):
--      - O próprio membro do estabelecimento que bloqueou um profissional NÃO é considerado bloqueado com seu próprio negócio.
--   3. Ausência de bloqueio e casos neutros:
--      - Profissional sem bloqueios retorna false.
--      - Entradas nulas ou inexistentes retornam false sem erro.
--   4. Verificação de membro do estabelecimento (privado.eh_membro):
--      - Usuário autenticado pertencente ao estabelecimento retorna true, tanto com papel administrador quanto operador.
--      - Usuário autenticado não pertencente retorna false.
--      - Usuário profissional retorna false.
--      - Sessão anônima (sem auth.uid()) retorna false.
--      - Estabelecimento nulo ou inexistente retorna false.
--   5. Provas de Mutação Dinâmica via pg_get_functiondef comprovando detecção e morte de mutantes.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(21);

create function pg_temp.autenticar_jwt(conta uuid) returns void
language plpgsql as $$
begin
  execute format('set local "request.jwt.claims" = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute format('set local "request.jwt.claim.sub" = %L', conta::text);
end $$;

create function pg_temp.limpar_jwt() returns void
language plpgsql as $$
begin
  execute 'reset "request.jwt.claims"';
  execute 'reset "request.jwt.claim.sub"';
end $$;

-- Setup de Dados de Teste
create temp table ids as select
  '78000000-0000-4000-8000-000000000001'::uuid as u_membro_e1,
  '78000000-0000-4000-8000-000000000002'::uuid as u_membro_e2,
  '78000000-0000-4000-8000-000000000003'::uuid as u_terceiro_contratante,
  '78000000-0000-4000-8000-000000000011'::uuid as u_prof_bloqueou,
  '78000000-0000-4000-8000-000000000012'::uuid as u_prof_bloqueado,
  '78000000-0000-4000-8000-000000000013'::uuid as u_prof_livre,
  '78000000-0000-4000-8000-000000000021'::uuid as e1,
  '78000000-0000-4000-8000-000000000022'::uuid as e2;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', id_usr, 'authenticated', 'authenticated',
       id_usr::text || '@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from (
  select u_membro_e1 as id_usr from ids union all
  select u_membro_e2 from ids union all
  select u_terceiro_contratante from ids union all
  select u_prof_bloqueou from ids union all
  select u_prof_bloqueado from ids union all
  select u_prof_livre from ids
) t on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('78000000-0000-4000-8000-000000000001', 'contratante',  'Gerente Bar 1',      'membro1_780@test.com',   '+5561978000001', '1985-01-01', 'ativa', '1.0', now()),
  ('78000000-0000-4000-8000-000000000002', 'contratante',  'Dono Restaurante 2', 'membro2_780@test.com',   '+5561978000002', '1986-02-02', 'ativa', '1.0', now()),
  ('78000000-0000-4000-8000-000000000003', 'contratante',  'Terceiro Dono',      'terceiro_780@test.com',  '+5561978000003', '1987-03-03', 'ativa', '1.0', now()),
  ('78000000-0000-4000-8000-000000000011', 'profissional', 'Prof Bloqueador',   'prof_bloq1_780@test.com','+5561978000011', '1990-04-04', 'ativa', '1.0', now()),
  ('78000000-0000-4000-8000-000000000012', 'profissional', 'Prof Bloqueado',    'prof_bloq2_780@test.com','+5561978000012', '1991-05-05', 'ativa', '1.0', now()),
  ('78000000-0000-4000-8000-000000000013', 'profissional', 'Prof Neutro',       'prof_livre_780@test.com','+5561978000013', '1992-06-06', 'ativa', '1.0', now());

insert into public.profissional (id, usuario_id, ponto_base) values
  ('78000000-0000-4000-8000-000000000011', '78000000-0000-4000-8000-000000000011', 'POINT(-47.8822 -15.7942)'::extensions.geography),
  ('78000000-0000-4000-8000-000000000012', '78000000-0000-4000-8000-000000000012', 'POINT(-47.8822 -15.7942)'::extensions.geography),
  ('78000000-0000-4000-8000-000000000013', '78000000-0000-4000-8000-000000000013', 'POINT(-47.8822 -15.7942)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('78000000-0000-4000-8000-000000000021', 'Bar 780',         '11222333000181', 'food_service', 'CLS 402 Bloco B', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('78000000-0000-4000-8000-000000000022', 'Restaurante 780', '04252011000110', 'food_service', 'CLN 105 Bloco C', 'POINT(-47.8850 -15.7800)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('78000000-0000-4000-8000-000000000021', '78000000-0000-4000-8000-000000000001', 'administrador'),
  ('78000000-0000-4000-8000-000000000022', '78000000-0000-4000-8000-000000000002', 'operador');

-- Bloqueios:
-- 1. Profissional 11 bloqueou o membro do Bar 780 (autor = prof, bloqueado = membro)
-- 2. Membro do Bar 780 bloqueou o Profissional 12 (autor = membro, bloqueado = prof)
insert into public.bloqueio (autor_id, bloqueado_id) values
  ('78000000-0000-4000-8000-000000000011', '78000000-0000-4000-8000-000000000001'),
  ('78000000-0000-4000-8000-000000000001', '78000000-0000-4000-8000-000000000012');

-- ── 1. privado.bloqueado_com_estabelecimento: Bidirecionalidade ────────────────────
select is(
  privado.bloqueado_com_estabelecimento((select u_prof_bloqueou from ids), (select e1 from ids)),
  true,
  'profissional que bloqueou membro do estabelecimento consta como bloqueado com a casa'
);

select is(
  privado.bloqueado_com_estabelecimento((select u_prof_bloqueado from ids), (select e1 from ids)),
  true,
  'profissional bloqueado por membro do estabelecimento consta como bloqueado com a casa'
);

-- ── 2. Trava de Proteção de Membro com o Próprio Negócio ──────────────────────────
select is(
  privado.bloqueado_com_estabelecimento((select u_membro_e1 from ids), (select e1 from ids)),
  false,
  'membro do estabelecimento que bloqueou um terceiro NÃO fica bloqueado com o próprio estabelecimento'
);

-- ── 3. Casos Neutros e Ausência de Bloqueio ───────────────────────────────────────
select is(
  privado.bloqueado_com_estabelecimento((select u_prof_livre from ids), (select e1 from ids)),
  false,
  'profissional sem nenhum bloqueio não está bloqueado com o estabelecimento'
);

select is(
  privado.bloqueado_com_estabelecimento((select u_membro_e2 from ids), (select e1 from ids)),
  false,
  'membro de outro estabelecimento não está bloqueado com o primeiro estabelecimento'
);

select is(
  privado.bloqueado_com_estabelecimento(null, (select e1 from ids)),
  false,
  'conta nula retorna false'
);

select is(
  privado.bloqueado_com_estabelecimento((select u_prof_bloqueou from ids), null),
  false,
  'estabelecimento nulo retorna false'
);

select is(
  privado.bloqueado_com_estabelecimento('78000000-0000-4000-8000-ffffffffffff'::uuid, (select e1 from ids)),
  false,
  'conta inexistente retorna false'
);

select is(
  privado.bloqueado_com_estabelecimento((select u_prof_bloqueou from ids), '78000000-0000-4000-8000-ffffffffffff'::uuid),
  false,
  'estabelecimento inexistente retorna false'
);

-- ── 4. privado.eh_membro: Verificação de Membro Autenticado vs Terceiros ──────────
select pg_temp.autenticar_jwt('78000000-0000-4000-8000-000000000001');
select is(
  privado.eh_membro((select e1 from ids)),
  true,
  'usuário autenticado que é membro administrador do estabelecimento 1 retorna true'
);

select is(
  privado.eh_membro((select e2 from ids)),
  false,
  'membro do estabelecimento 1 não é membro do estabelecimento 2 (retorna false)'
);

select pg_temp.autenticar_jwt('78000000-0000-4000-8000-000000000002');
select is(
  privado.eh_membro((select e2 from ids)),
  true,
  'usuário autenticado que é membro operador do estabelecimento 2 retorna true'
);

select pg_temp.autenticar_jwt('78000000-0000-4000-8000-000000000013');
select is(
  privado.eh_membro((select e1 from ids)),
  false,
  'profissional autenticado não é membro do estabelecimento (retorna false)'
);

select pg_temp.autenticar_jwt('78000000-0000-4000-8000-000000000003');
select is(
  privado.eh_membro((select e1 from ids)),
  false,
  'outro contratante terceiro autenticado não é membro do estabelecimento (retorna false)'
);

select pg_temp.limpar_jwt();
select is(
  privado.eh_membro((select e1 from ids)),
  false,
  'chamada sem sessão autenticada (auth.uid() nulo) retorna false'
);

select is(
  privado.eh_membro(null),
  false,
  'eh_membro com parâmetro nulo retorna false'
);

select is(
  privado.eh_membro('78000000-0000-4000-8000-ffffffffffff'::uuid),
  false,
  'eh_membro com estabelecimento inexistente retorna false'
);

-- ── 5. Provas de Mutação Dinâmica via pg_get_functiondef ─────────────────────────
create temp table canonicos as select
  pg_get_functiondef('privado.bloqueado_com_estabelecimento(uuid,uuid)'::regprocedure) as def_bloq,
  pg_get_functiondef('privado.eh_membro(uuid)'::regprocedure) as def_membro;

-- Mutante M1: Omissão da trava and m.usuario_id <> conta
-- Demonstra que sob M1 o próprio membro ficaria bloqueado com seu próprio negócio; morto pelo teste 3.
do $$
begin
  execute replace(
    (select def_bloq from canonicos),
    'and m.usuario_id <> conta',
    'and true'
  );
end $$;

select is(
  privado.bloqueado_com_estabelecimento((select u_membro_e1 from ids), (select e1 from ids)),
  true,
  'mutante M1 (sem trava m.usuario_id <> conta): membro fica bloqueado consigo mesmo no estabelecimento; morto pela suíte'
);

-- Restauração dinâmica de M1
do $$
begin
  execute (select def_bloq from canonicos);
end $$;

-- Mutante M2: Afrouxamento da verificação de membro autenticado
-- Demonstra que sob M2 qualquer terceiro passaria a ser reconhecido como membro.
do $$
begin
  execute replace(
    (select def_membro from canonicos),
    'and m.usuario_id = (select auth.uid())',
    'and true'
  );
end $$;

select pg_temp.autenticar_jwt('78000000-0000-4000-8000-000000000003');
select is(
  privado.eh_membro((select e1 from ids)),
  true,
  'mutante M2 (eh_membro sem checar auth.uid()): concede status de membro a qualquer terceiro; morto pela suíte'
);

-- Restauração dinâmica de M2
do $$
begin
  execute (select def_membro from canonicos);
end $$;

-- Mutante M3: Unidirecionalidade em bloqueado_com_estabelecimento (apenas autor)
-- Demonstra que sob M3 profissional bloqueado pelo membro deixaria de ser detectado como bloqueado.
do $$
begin
  execute replace(
    (select def_bloq from canonicos),
    'and conta in (b.autor_id, b.bloqueado_id)',
    'and conta = b.autor_id'
  );
end $$;

select is(
  privado.bloqueado_com_estabelecimento((select u_prof_bloqueado from ids), (select e1 from ids)),
  false,
  'mutante M3 (bloqueio unidirecional): deixa de detectar profissional bloqueado pelo membro; morto pela suíte'
);

-- Restauração dinâmica de M3
do $$
begin
  execute (select def_bloq from canonicos);
end $$;

-- Mutante M4: eh_membro restringe indevidamente para papel administrador
-- Demonstra que sob M4 um membro com papel operador (u_membro_e2) perderia o acesso; morto pela suíte.
do $$
begin
  execute replace(
    (select def_membro from canonicos),
    'and m.usuario_id = (select auth.uid())',
    'and m.usuario_id = (select auth.uid()) and m.papel = ''administrador'''
  );
end $$;

select pg_temp.autenticar_jwt('78000000-0000-4000-8000-000000000002');
select is(
  privado.eh_membro((select e2 from ids)),
  false,
  'mutante M4 (eh_membro restrito a administrador): operador deixa de ser reconhecido retornando false; morto pela suíte'
);

-- Restauração dinâmica de M4
do $$
begin
  execute (select def_membro from canonicos);
end $$;

select * from finish();

rollback;
