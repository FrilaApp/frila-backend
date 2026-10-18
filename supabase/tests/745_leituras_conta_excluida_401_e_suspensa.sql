-- Teste pgTAP: Leituras com token de conta excluída (401) e conta suspensa (200 p/ contestação) (Item 23)
-- Cobre os dois casos lado a lado:
-- 1. Conta excluída (anonimizada): todas as leituras retornam 401 nao_autenticado (forçando saída no app).
-- 2. Conta suspensa: minha_conta() retorna 200 (para exibir dados de contestação), enquanto leituras operacionais dão 403.
-- 3. Conta ativa: minha_conta() retorna 200 normalmente.

begin;
select plan(12);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- ── 1. Palco de Contas: Ativa, Anonimizada e Suspensa ─────────────────────────
create table pg_temp.palco (
  uid_ativo    uuid,
  uid_anonimo  uuid,
  uid_suspenso uuid,
  estab_id     uuid
);

do $$
declare
  v_ativo    uuid := gen_random_uuid();
  v_anonimo  uuid := gen_random_uuid();
  v_suspenso uuid := gen_random_uuid();
  v_estab    uuid := gen_random_uuid();
begin
  -- 1a. Usuário Ativo (contratante com estabelecimento)
  insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em)
  values (v_ativo, 'Usuário Ativo', 'ativo@frila.test', '+5561911110001', 'contratante', 'ativa', '1990-01-01', '1.0', now());

  insert into public.estabelecimento (id, nome, documento, endereco, ponto, tipo)
  values (v_estab, 'Bar Ativo', '12345678000199', 'Rua 1', 'POINT(-47.88 -15.79)'::extensions.geography, 'food_service');

  insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
  values (v_estab, v_ativo, 'administrador');

  -- 1b. Usuário Anonimizado (conta excluída com JWT ainda válido)
  insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em, anonimizado_em)
  values (v_anonimo, 'Conta encerrada', null, null, 'profissional', 'anonimizada', '1992-05-10', '1.0', now(), now());

  insert into public.profissional (id, usuario_id, ponto_base)
  values (gen_random_uuid(), v_anonimo, 'POINT(-47.88 -15.79)'::extensions.geography);

  -- 1c. Usuário Suspenso (mantém dados, estado suspensa)
  insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em)
  values (v_suspenso, 'Usuário Suspenso', 'suspenso@frila.test', '+5561911110003', 'profissional', 'suspensa', '1995-08-20', '1.0', now());

  insert into public.profissional (id, usuario_id, ponto_base)
  values (gen_random_uuid(), v_suspenso, 'POINT(-47.88 -15.79)'::extensions.geography);

  insert into pg_temp.palco values (v_ativo, v_anonimo, v_suspenso, v_estab);
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

-- ── 3. CASO 2: Conta Excluída / Anonimizada (deve dar 401 em TUDO) ───────────
select set_config('request.jwt.claim.sub', (select uid_anonimo::text from pg_temp.palco), true);

-- 3a. minha_conta
select throws_matching(
  'select public.minha_conta()',
  'nao_autenticado',
  'conta excluída/anonimizada: minha_conta() recusa com 401 nao_autenticado'
);

-- 3b. meus_turnos
select throws_matching(
  'select public.meus_turnos()',
  'nao_autenticado',
  'conta excluída/anonimizada: meus_turnos() recusa com 401 nao_autenticado'
);

-- 3c. meu_perfil_profissional
select throws_matching(
  'select public.meu_perfil_profissional()',
  'nao_autenticado',
  'conta excluída/anonimizada: meu_perfil_profissional() recusa com 401 nao_autenticado'
);

-- 3d. meu_estabelecimento
select throws_matching(
  'select public.meu_estabelecimento((select estab_id from pg_temp.palco))',
  'nao_autenticado',
  'conta excluída/anonimizada: meu_estabelecimento() recusa com 401 nao_autenticado'
);

-- 3e. painel_estabelecimento
select throws_matching(
  'select public.painel_estabelecimento((select estab_id from pg_temp.palco), now() - interval ''1 day'', now() + interval ''1 day'')',
  'nao_autenticado',
  'conta excluída/anonimizada: painel_estabelecimento() recusa com 401 nao_autenticado'
);

-- 3f. perfil_publico
select throws_matching(
  'select public.perfil_publico((select estab_id from pg_temp.palco))',
  'nao_autenticado',
  'conta excluída/anonimizada: perfil_publico() recusa com 401 nao_autenticado'
);

-- 3g. registrar_evento
select throws_matching(
  'select public.registrar_evento(''app_aberto'')',
  'nao_autenticado',
  'conta excluída/anonimizada: registrar_evento() recusa com 401 nao_autenticado'
);

-- ── 4. CASO 3: Conta Suspenso (minha_conta = 200, leituras operacionais = 403) ──
select set_config('request.jwt.claim.sub', (select uid_suspenso::text from pg_temp.palco), true);

-- 4a. minha_conta() DEVE RETORNAR 200 OK com estado suspensa para a tela de contestação
select is(
  (public.minha_conta()->>'estado'),
  'suspensa',
  'conta suspensa: minha_conta() RETORNA 200 OK com estado suspensa para permitir tela de contestação (RN13)'
);

-- 4b. meus_turnos() DEVE RECUSAR com 403 sem_permissao, conta_suspensa
select throws_matching(
  'select public.meus_turnos()',
  'sem_permissao',
  'conta suspensa: meus_turnos() recusa com 403 sem_permissao (conta_suspensa)'
);

-- 4c. meu_perfil_profissional() DEVE RECUSAR com 403 sem_permissao, conta_suspensa
select throws_matching(
  'select public.meu_perfil_profissional()',
  'sem_permissao',
  'conta suspensa: meu_perfil_profissional() recusa com 403 sem_permissao (conta_suspensa)'
);

-- 4d. registrar_evento() DEVE RECUSAR com 403 sem_permissao, conta_suspensa
select throws_matching(
  'select public.registrar_evento(''app_aberto'')',
  'sem_permissao',
  'conta suspensa: registrar_evento() recusa com 403 sem_permissao (conta_suspensa)'
);

select * from finish();
rollback;
