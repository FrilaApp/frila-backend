-- 773_privado_ultima_no_teto.sql
--
-- Cobertura pgTAP de privado.ultima_no_teto(p_usuario uuid)
-- e provas de mutação dinâmica que matam mutantes de omissão do filtro
-- de tipos do teto e de inversão temporal max/min (RN23, RNF03).
--
-- Regras validadas:
--   1. Retorna o instante exato da notificação mais recente (max enviada_em) cujo tipo
--      está listado em privado.tipo_no_teto ('vaga', 'vagas_agrupadas').
--   2. Notificações com tipos que não estão no teto (ex.: 'confirmacao', 'lembrete_24h')
--      são estritamente ignoradas, mesmo com timestamp mais recente.
--   3. Usuário sem notificações cadastradas retorna NULL.
--   4. Usuário inexistente retorna NULL.
--
-- Provas de Mutação Dinâmica via pg_get_functiondef:
--   - Mutante M1: Omissão do filtro de tipo (ignora privado.tipo_no_teto)
--     Demonstra que sob M1 o retorno seria corrompido por avisos transacionais mais recentes (morto pelo teste 1 e 2).
--   - Mutante M2: Troca da agregação max(n.enviada_em) por min(n.enviada_em)
--     Demonstra que sob M2 retornaria a primeira notificação antiga em vez da mais recente (morto pelo teste 1).

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(6);

-- Setup de Dados de Teste
create temp table dados as select
  '77300000-0000-4000-8000-000000000001'::uuid as user_prof1,
  '77300000-0000-4000-8000-000000000002'::uuid as user_prof2,
  '77300000-0000-4000-8000-000000000010'::uuid as prof1_id,
  '2026-10-25 10:00:00+00'::timestamptz        as t_antiga,
  '2026-10-25 12:00:00+00'::timestamptz        as t_recente,
  '2026-10-25 14:00:00+00'::timestamptz        as t_fora_teto;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', user_prof1, 'authenticated', 'authenticated',
       'prof1_773@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from dados on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', user_prof2, 'authenticated', 'authenticated',
       'prof2_773@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from dados on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em)
select user_prof1, 'profissional', 'Profissional 1 773', 'prof1_773@test.com', '+5561999991111', '1990-01-01', 'ativa', '1.0', now()
from dados;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em)
select user_prof2, 'profissional', 'Profissional 2 773', 'prof2_773@test.com', '+5561999992222', '1992-02-02', 'ativa', '1.0', now()
from dados;

insert into public.profissional (id, usuario_id, ponto_base)
select prof1_id, user_prof1, 'POINT(-47.8822 -15.7942)'::extensions.geography
from dados;

-- Inserção de Notificações para o profissional 1:
-- 1. Notificação antiga de vaga (tipo 'vaga' conta no teto)
insert into public.notificacao (
  id, usuario_id, profissional_id, tipo, referencia_id, enviada_em, urgente, estado_entrega
) select
  gen_random_uuid(), user_prof1, prof1_id, 'vaga', gen_random_uuid(), t_antiga, false, 'entregue'
from dados;

-- 2. Notificação recente de vagas agrupadas (tipo 'vagas_agrupadas' conta no teto) -> esperada no max
insert into public.notificacao (
  id, usuario_id, profissional_id, tipo, referencia_id, enviada_em, urgente, estado_entrega
) select
  gen_random_uuid(), user_prof1, prof1_id, 'vagas_agrupadas', gen_random_uuid(), t_recente, false, 'entregue'
from dados;

-- 3. Notificação ainda mais recente mas de tipo fora do teto ('confirmacao' não tem profissional_id nem conta no teto)
insert into public.notificacao (
  id, usuario_id, profissional_id, tipo, referencia_id, enviada_em, urgente, estado_entrega
) select
  gen_random_uuid(), user_prof1, null, 'confirmacao', gen_random_uuid(), t_fora_teto, false, 'entregue'
from dados;

-- ── 1. Retorna exatamente o max de enviada_em entre os tipos do teto ───────────────
select is(
  privado.ultima_no_teto((select user_prof1 from dados)),
  (select t_recente from dados),
  'privado.ultima_no_teto retorna o instante max das notificações do teto (t_recente = 12:00)'
);

-- ── 2. Notificações fora do teto são ignoradas ────────────────────────────────────
select is(
  privado.ultima_no_teto((select user_prof1 from dados)) < (select t_fora_teto from dados),
  true,
  'notificações fora do teto (t_fora_teto = 14:00) não são contabilizadas em privado.ultima_no_teto'
);

-- ── 3. Usuário sem notificações cadastradas retorna NULL ──────────────────────────
select is(
  privado.ultima_no_teto((select user_prof2 from dados)),
  null,
  'privado.ultima_no_teto retorna NULL para usuário sem notificações'
);

-- ── 4. Usuário inexistente retorna NULL ───────────────────────────────────────────
select is(
  privado.ultima_no_teto('77300000-0000-4000-8000-ffffffffffff'::uuid),
  null,
  'privado.ultima_no_teto retorna NULL para usuário inexistente'
);

-- ── 5. Prova de Mutação M1: Omissão do filtro de tipo do teto ─────────────────────
do $$
begin
  execute replace(
    pg_get_functiondef('privado.ultima_no_teto(uuid)'::regprocedure),
    'and n.tipo in (select t.tipo from privado.tipo_no_teto t)',
    '-- and n.tipo in (select t.tipo from privado.tipo_no_teto t)'
  );
end $$;

select is(
  privado.ultima_no_teto((select user_prof1 from dados)),
  (select t_fora_teto from dados),
  'mutante M1 (sem filtro de tipo): retornaria t_fora_teto (14:00); mutante discriminado e morto pelo teste 1'
);

-- Restauração dinâmica de M1
do $$
begin
  execute replace(
    pg_get_functiondef('privado.ultima_no_teto(uuid)'::regprocedure),
    '-- and n.tipo in (select t.tipo from privado.tipo_no_teto t)',
    'and n.tipo in (select t.tipo from privado.tipo_no_teto t)'
  );
end $$;

-- ── 6. Prova de Mutação M2: Troca de max por min ──────────────────────────────────
do $$
begin
  execute replace(
    pg_get_functiondef('privado.ultima_no_teto(uuid)'::regprocedure),
    'select max(n.enviada_em)',
    'select min(n.enviada_em)'
  );
end $$;

select is(
  privado.ultima_no_teto((select user_prof1 from dados)),
  (select t_antiga from dados),
  'mutante M2 (min em vez de max): retornaria t_antiga (10:00); mutante discriminado e morto pelo teste 1'
);

-- Restauração dinâmica de M2
do $$
begin
  execute replace(
    pg_get_functiondef('privado.ultima_no_teto(uuid)'::regprocedure),
    'select min(n.enviada_em)',
    'select max(n.enviada_em)'
  );
end $$;

select * from finish();

rollback;
