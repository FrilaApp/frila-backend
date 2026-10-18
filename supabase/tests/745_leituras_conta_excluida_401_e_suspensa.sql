-- Teste pgTAP: Leituras com token de conta excluída (401) e conta suspensa (200 p/ contestação) (Item 23)
-- Cobre os casos estritos exigidos pelo Oráculo e pelo contrato 0.2.44:
-- 1. Conta ativa: minha_conta() retorna 200 normalmente com estado 'ativa'.
-- 2. Conta excluída (anonimizada): todas as 7 leituras retornam 401 'nao_autenticado'.
-- 3. Contas suspensas: todas as 7 leituras retornam 200 OK (permitindo telas, conferência e contestação).

begin;
select plan(15);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- ── 1. Palco de Contas: Ativa, Anonimizada e Suspensas ─────────────────────────
create table pg_temp.palco (
  uid_ativo          uuid,
  uid_anonimo        uuid,
  uid_suspenso_prof  uuid,
  uid_suspenso_casa  uuid,
  estab_ativo_id     uuid,
  estab_suspenso_id  uuid
);

do $$
declare
  v_ativo    uuid := gen_random_uuid();
  v_anonimo  uuid := gen_random_uuid();
  v_susp_p   uuid := gen_random_uuid();
  v_susp_c   uuid := gen_random_uuid();
  v_estab_a  uuid := gen_random_uuid();
  v_estab_s  uuid := gen_random_uuid();
begin
  -- 1a. Usuário Ativo (contratante com estabelecimento)
  insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em)
  values (v_ativo, 'Usuário Ativo', 'ativo@frila.test', '+5561911110001', 'contratante', 'ativa', '1990-01-01', '1.0', now());

  insert into public.estabelecimento (id, nome, documento, endereco, ponto, tipo)
  values (v_estab_a, 'Bar Ativo', '12345678000199', 'Rua 1', 'POINT(-47.88 -15.79)'::extensions.geography, 'food_service');

  insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
  values (v_estab_a, v_ativo, 'administrador');

  -- 1b. Usuário Anonimizado (conta excluída com JWT ainda válido)
  insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em, anonimizado_em)
  values (v_anonimo, 'Conta encerrada', null, null, 'profissional', 'anonimizada', '1992-05-10', '1.0', now(), now());

  insert into public.profissional (id, usuario_id, ponto_base)
  values (gen_random_uuid(), v_anonimo, 'POINT(-47.88 -15.79)'::extensions.geography);

  -- 1c. Usuário Profissional Suspenso (mantém dados, estado suspensa para contestação)
  insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em)
  values (v_susp_p, 'Profissional Suspenso', 'suspenso_p@frila.test', '+5561911110003', 'profissional', 'suspensa', '1995-08-20', '1.0', now());

  insert into public.profissional (id, usuario_id, ponto_base)
  values (gen_random_uuid(), v_susp_p, 'POINT(-47.88 -15.79)'::extensions.geography);

  -- 1d. Usuário Contratante Suspenso (membro de casa, estado suspensa para contestação)
  insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em)
  values (v_susp_c, 'Contratante Suspenso', 'suspenso_c@frila.test', '+5561911110004', 'contratante', 'suspensa', '1988-03-15', '1.0', now());

  insert into public.estabelecimento (id, nome, documento, endereco, ponto, tipo)
  values (v_estab_s, 'Bar Suspenso', '98765432000188', 'Rua 2', 'POINT(-47.88 -15.79)'::extensions.geography, 'food_service');

  insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
  values (v_estab_s, v_susp_c, 'administrador');

  insert into pg_temp.palco values (v_ativo, v_anonimo, v_susp_p, v_susp_c, v_estab_a, v_estab_s);
end $$;

grant all on pg_temp.palco to authenticated;

-- ── 2. CASO 1: Conta Ativa (Controle Positivo) ────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claim.sub', (select uid_ativo::text from pg_temp.palco), true);

select is(
  (public.minha_conta()->>'estado'),
  'ativa',
  'conta ativa: minha_conta() retorna HTTP 200 com estado ativa'
);

-- ── 3. CASO 2: Conta Excluída / Anonimizada (deve dar 401 em TODAS as 7 rotinas) ──
select set_config('request.jwt.claim.sub', (select uid_anonimo::text from pg_temp.palco), true);

-- 3a. minha_conta
select throws_matching(
  'select public.minha_conta()',
  'nao_autenticado',
  'conta excluída/anonimizada: 1/7 minha_conta() recusa com 401 nao_autenticado'
);

-- 3b. meus_turnos
select throws_matching(
  'select public.meus_turnos()',
  'nao_autenticado',
  'conta excluída/anonimizada: 2/7 meus_turnos() recusa com 401 nao_autenticado'
);

-- 3c. meu_perfil_profissional
select throws_matching(
  'select public.meu_perfil_profissional()',
  'nao_autenticado',
  'conta excluída/anonimizada: 3/7 meu_perfil_profissional() recusa com 401 nao_autenticado'
);

-- 3d. meu_estabelecimento
select throws_matching(
  'select public.meu_estabelecimento((select estab_ativo_id from pg_temp.palco))',
  'nao_autenticado',
  'conta excluída/anonimizada: 4/7 meu_estabelecimento() recusa com 401 nao_autenticado'
);

-- 3e. painel_estabelecimento
select throws_matching(
  'select public.painel_estabelecimento((select estab_ativo_id from pg_temp.palco), now() - interval ''1 day'', now() + interval ''1 day'')',
  'nao_autenticado',
  'conta excluída/anonimizada: 5/7 painel_estabelecimento() recusa com 401 nao_autenticado'
);

-- 3f. perfil_publico
select throws_matching(
  'select public.perfil_publico((select estab_ativo_id from pg_temp.palco))',
  'nao_autenticado',
  'conta excluída/anonimizada: 6/7 perfil_publico() recusa com 401 nao_autenticado'
);

-- 3g. registrar_evento
select throws_matching(
  'select public.registrar_evento(''app_aberto'')',
  'nao_autenticado',
  'conta excluída/anonimizada: 7/7 registrar_evento() recusa com 401 nao_autenticado'
);

-- ── 4. CASO 3: Contas Suspensas (DEVE RETORNAR 200 OK em TODAS as 7 rotinas) ──
-- Profissional Suspenso
select set_config('request.jwt.claim.sub', (select uid_suspenso_prof::text from pg_temp.palco), true);

-- 4a. minha_conta
select is(
  (public.minha_conta()->>'estado'),
  'suspensa',
  'conta suspensa: 1/7 minha_conta() RETORNA 200 OK com estado suspensa para tela de contestação'
);

-- 4b. meus_turnos
select lives_ok(
  'select public.meus_turnos()',
  'conta suspensa: 2/7 meus_turnos() RETORNA 200 OK'
);

-- 4c. meu_perfil_profissional
select lives_ok(
  'select public.meu_perfil_profissional()',
  'conta suspensa: 3/7 meu_perfil_profissional() RETORNA 200 OK'
);

-- 4d. perfil_publico
select lives_ok(
  'select public.perfil_publico((select estab_ativo_id from pg_temp.palco))',
  'conta suspensa: 4/7 perfil_publico() RETORNA 200 OK'
);

-- 4e. registrar_evento
select is(
  (public.registrar_evento('app_aberto')->>'registrado')::boolean,
  true,
  'conta suspensa: 5/7 registrar_evento() RETORNA 200 OK com registrado=true'
);

-- Contratante Suspenso
select set_config('request.jwt.claim.sub', (select uid_suspenso_casa::text from pg_temp.palco), true);

-- 4f. meu_estabelecimento
select lives_ok(
  'select public.meu_estabelecimento((select estab_suspenso_id from pg_temp.palco))',
  'conta suspensa: 6/7 meu_estabelecimento() RETORNA 200 OK'
);

-- 4g. painel_estabelecimento
select lives_ok(
  'select public.painel_estabelecimento((select estab_suspenso_id from pg_temp.palco), now() - interval ''1 day'', now() + interval ''1 day'')',
  'conta suspensa: 7/7 painel_estabelecimento() RETORNA 200 OK'
);

select * from finish();
rollback;
