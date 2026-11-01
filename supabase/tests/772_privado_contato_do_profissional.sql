-- 772_privado_contato_do_profissional.sql
--
-- Cobertura pgTAP de privado.contato_do_profissional(posicao uuid)
-- e provas de mutação dinâmica que matam mutantes de sanitização de telefone
-- e de prazo de visibilidade pós-turno (RN10, RN15).
--
-- Regras validadas:
--   1. Retorna jsonb com nome, telefone, whatsapp_url sanitizado e visivel_ate = p.fim_em + 7 dias (RN10).
--   2. Sanitização do WhatsApp: remove prefixo '+' do padrão E.164 (wa.me não aceita '+').
--   3. Posição aberta sem profissional alocado (profissional_id nulo) retorna NULL.
--   4. Posição inexistente retorna NULL.
--
-- Provas de Mutação Dinâmica via pg_get_functiondef:
--   - Mutante M1: Omissão da sanitização do telefone na URL do WhatsApp
--     Demonstra que sob M1 a URL conteria '+' indevidamente (morto pelo teste 2).
--   - Mutante M2: Alteração da janela de visibilidade de contato (7 dias -> 1 dia)
--     Demonstra que sob M2 o visivel_ate divergiria da RN10 (morto pelo teste 1).

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(6);

-- Setup de Dados de Teste
create temp table dados as select
  '77200000-0000-4000-8000-000000000001'::uuid as user_dono,
  '77200000-0000-4000-8000-000000000002'::uuid as user_prof,
  '77200000-0000-4000-8000-000000000010'::uuid as estab_id,
  '77200000-0000-4000-8000-000000000020'::uuid as prof_id,
  '77200000-0000-4000-8000-000000000030'::uuid as vaga_id,
  '77200000-0000-4000-8000-0000000000a1'::uuid as pos_confirmada,
  '77200000-0000-4000-8000-0000000000a2'::uuid as pos_aberta,
  '2026-11-15 18:00:00+00'::timestamptz        as inicio_em,
  '2026-11-15 23:00:00+00'::timestamptz        as fim_em;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', user_dono, 'authenticated', 'authenticated',
       'dono772@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from dados on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', user_prof, 'authenticated', 'authenticated',
       'prof772@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from dados on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em)
select user_dono, 'contratante', 'Gerente 772', 'dono772@test.com', '+5561999990001', '1985-01-01', 'ativa', '1.0', now()
from dados;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em)
select user_prof, 'profissional', 'Bartender 772', 'prof772@test.com', '+5561988887777', '1992-05-10', 'ativa', '1.0', now()
from dados;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
select estab_id, 'Bar 772', '77200000000100', 'food_service', 'CLN 100', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'
from dados;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select user_dono, estab_id, 'administrador'
from dados;

insert into public.profissional (id, usuario_id, ponto_base)
select prof_id, user_prof, 'POINT(-47.8822 -15.7942)'::extensions.geography
from dados;

insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, chave_cliente,
  publicado_por, estado
)
select
  vaga_id,
  estab_id,
  (select id from public.funcao limit 1),
  inicio_em,
  fim_em,
  'CLN 100',
  'POINT(-47.8822 -15.7942)'::extensions.geography,
  16000,
  2,
  true,
  false,
  false,
  'Gerente 772',
  'urgencia',
  gen_random_uuid(),
  user_dono,
  'publicada'
from dados;

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select pos_confirmada, vaga_id, 'confirmada', prof_id, now(), inicio_em, fim_em
from dados;

insert into public.posicao (id, vaga_id, estado, profissional_id, inicio_em, fim_em)
select pos_aberta, vaga_id, 'aberta', null, inicio_em, fim_em
from dados;

-- ── 1. Retorno completo de contato para posição confirmada ────────────────────────
select is(
  privado.contato_do_profissional((select pos_confirmada from dados)),
  jsonb_build_object(
    'nome',         'Bartender 772',
    'telefone',     '+5561988887777',
    'whatsapp_url', 'https://wa.me/5561988887777',
    'visivel_ate',  (select fim_em + interval '7 days' from dados)
  ),
  'privado.contato_do_profissional retorna jsonb com nome, telefone, whatsapp_url e visivel_ate (fim_em + 7 dias)'
);

-- ── 2. Sanitização do WhatsApp: remove prefixo + do E.164 ─────────────────────────
select is(
  (privado.contato_do_profissional((select pos_confirmada from dados))->>'whatsapp_url'),
  'https://wa.me/5561988887777',
  'whatsapp_url sanitiza telefone E.164 removendo o prefixo +'
);

-- ── 3. Posição aberta sem profissional alocado retorna NULL ───────────────────────
select is(
  privado.contato_do_profissional((select pos_aberta from dados)),
  null,
  'privado.contato_do_profissional retorna NULL para posição sem profissional confirmado'
);

-- ── 4. Posição inexistente retorna NULL ───────────────────────────────────────────
select is(
  privado.contato_do_profissional('77200000-0000-4000-8000-ffffffffffff'::uuid),
  null,
  'privado.contato_do_profissional retorna NULL para posição inexistente'
);

-- ── 5. Prova de Mutação M1: Omissão de sanitização do telefone na URL ─────────────
do $$
begin
  execute replace(
    pg_get_functiondef('privado.contato_do_profissional(uuid)'::regprocedure),
    '''https://wa.me/'' || replace(u.telefone, ''+'', '''')',
    '''https://wa.me/'' || u.telefone'
  );
end $$;

select is(
  (privado.contato_do_profissional((select pos_confirmada from dados))->>'whatsapp_url'),
  'https://wa.me/+5561988887777',
  'mutante M1 (sem sanitização): whatsapp_url conteria +; mutante discriminado e morto pelo teste 2'
);

-- Restauração dinâmica de M1
do $$
begin
  execute replace(
    pg_get_functiondef('privado.contato_do_profissional(uuid)'::regprocedure),
    '''https://wa.me/'' || u.telefone',
    '''https://wa.me/'' || replace(u.telefone, ''+'', '''')'
  );
end $$;

-- ── 6. Prova de Mutação M2: Alteração do prazo de visibilidade (7 dias -> 1 dia) ───
do $$
begin
  execute replace(
    pg_get_functiondef('privado.contato_do_profissional(uuid)'::regprocedure),
    'interval ''7 days''',
    'interval ''1 day'''
  );
end $$;

select is(
  (privado.contato_do_profissional((select pos_confirmada from dados))->>'visivel_ate')::timestamptz,
  (select fim_em + interval '1 day' from dados),
  'mutante M2 (prazo de 1 dia): visivel_ate divergiria dos 7 dias; mutante discriminado e morto pelo teste 1'
);

-- Restauração dinâmica de M2
do $$
begin
  execute replace(
    pg_get_functiondef('privado.contato_do_profissional(uuid)'::regprocedure),
    'interval ''1 day''',
    'interval ''7 days'''
  );
end $$;

select * from finish();

rollback;
