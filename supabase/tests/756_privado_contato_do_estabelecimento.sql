-- 756_privado_contato_do_estabelecimento.sql
--
-- Cobertura pgTAP de privado.contato_do_estabelecimento(vaga uuid).
-- Garante que:
--   1. Retorna jsonb com nome do estabelecimento, telefone do publicador,
--      whatsapp_url sanitizado e visivel_ate = vaga.fim_em + 7 dias (RN10).
--   2. Sanitização do WhatsApp: remove o prefixo '+' do padrão E.164 (wa.me não aceita '+').
--   3. Retorna NULL quando a vaga informada não existe.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(3);

-- Setup de Dados de Teste
create temp table dados as select
  '75600000-0000-4000-8000-000000000001'::uuid as user_id,
  '75600000-0000-4000-8000-000000000002'::uuid as estab_id,
  '75600000-0000-4000-8000-000000000003'::uuid as vaga_id,
  '2026-11-10 20:00:00+00'::timestamptz        as inicio_em,
  '2026-11-11 02:00:00+00'::timestamptz        as fim_em;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', user_id, 'authenticated', 'authenticated',
       'dono756@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from dados
on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em)
select user_id, 'contratante', 'Gerente Bar 756', 'dono756@test.com', '+5561988887777', '1985-05-15', 'ativa', '1.0', now()
from dados;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
select estab_id, 'Bar e Restaurante 756', '75600000000100', 'food_service', 'CLN 302 Bloco B', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'
from dados;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select user_id, estab_id, 'administrador'
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
  'CLN 302 Bloco B',
  'POINT(-47.8822 -15.7942)'::extensions.geography,
  15000,
  1,
  true,
  false,
  false,
  'Gerente Bar 756',
  'urgencia',
  gen_random_uuid(),
  user_id,
  'publicada'
from dados;

-- ── 1. Estrutura completa do retorno para vaga existente ───────────────────────────
select is(
  privado.contato_do_estabelecimento((select vaga_id from dados)),
  jsonb_build_object(
    'nome',         'Bar e Restaurante 756',
    'telefone',     '+5561988887777',
    'whatsapp_url', 'https://wa.me/5561988887777',
    'visivel_ate',  (select fim_em + interval '7 days' from dados)
  ),
  'privado.contato_do_estabelecimento retorna jsonb com nome, telefone, whatsapp_url e visivel_ate (fim_em + 7 dias)'
);

-- ── 2. Sanitização do WhatsApp: remoção do prefixo + do E.164 ──────────────────────
select is(
  (privado.contato_do_estabelecimento((select vaga_id from dados))->>'whatsapp_url'),
  'https://wa.me/5561988887777',
  'whatsapp_url sanitiza telefone E.164 removendo o prefixo +'
);

-- ── 3. Vaga inexistente retorna NULL ──────────────────────────────────────────────
select is(
  privado.contato_do_estabelecimento('75600000-0000-4000-8000-ffffffffffff'::uuid),
  null,
  'privado.contato_do_estabelecimento retorna NULL para vaga inexistente'
);

select * from finish();

rollback;
