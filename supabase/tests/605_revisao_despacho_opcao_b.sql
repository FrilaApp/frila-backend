-- 605_revisao_despacho_opcao_b.sql
--
-- Teste pgTAP do ciclo de vida de revisão de despacho (Opção B, contrato 0.2.37, RF27).
-- Decisão de produto:
--   1. Primeira contestação de despacho registra com sucesso e devolve Protocolo oficial.
--   2. Segunda contestação pelo mesmo autor é recusada com 409 contestacao_ja_aberta,
--      tanto quando em análise quanto após respondida pela Equipe Frila.
--   3. Recurso posterior exclusivamente por e-mail (fora do app).
--   4. Outro profissional consegue contestar seu próprio despacho normalmente.

begin;
select plan(12);

-- Ativa ambiente de teste e fixa o relógio em data futura
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2027-07-01 12:00:00+00', true);

-- Helper como(conta, sql)
create or replace function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

-- Helper erro
create or replace function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

-- Contas de teste: dois profissionais ativos
-- c6050001: profissional A
-- c6050002: profissional B
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'c6050000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
        'profa605@frila.test', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false),
       ('00000000-0000-0000-0000-000000000002', 'c6050000-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
        'profb605@frila.test', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values ('c6050000-0000-4000-8000-000000000001', 'profissional', 'Profissional A 605', '+5561999996051', 'profa605@frila.test', '1995-01-01', '2026-09-22', now(), 'ativa'),
       ('c6050000-0000-4000-8000-000000000002', 'profissional', 'Profissional B 605', '+5561999996052', 'profb605@frila.test', '1994-01-01', '2026-09-22', now(), 'ativa')
on conflict (id) do nothing;

insert into public.profissional (usuario_id, ponto_base)
values ('c6050000-0000-4000-8000-000000000001', 'POINT(-47.8800 -15.7900)'::extensions.geography),
       ('c6050000-0000-4000-8000-000000000002', 'POINT(-47.8800 -15.7900)'::extensions.geography)
on conflict (usuario_id) do nothing;

-- ── 1. Primeira contestação do profissional A registra com sucesso ───────────
create temp table res_rev1 as select
  pg_temp.como('c6050000-0000-4000-8000-000000000001',
    'select public.pedir_revisao_despacho(''Mudei de região e gostaria de revisar os critérios do despacho'')') as p;

select is(
  ((select p from res_rev1)->>'tipo'),
  'revisao_despacho',
  'primeira contestacao devolve protocolo com tipo revisao_despacho'
);

select ok(
  ((select p from res_rev1)->>'ocorrencia_id') is not null,
  'protocolo contém ocorrencia_id'
);

select is(
  ((select p from res_rev1)->>'prazo_resposta_ate'),
  to_char(privado.prazo_de_resposta(privado.agora()), 'YYYY-MM-DD'),
  'prazo_resposta_ate é calculado com 5 dias úteis'
);

-- Nenhuma chave excedente no retorno de Protocolo
select is(
  (select array_agg(k order by k) from jsonb_object_keys((select p from res_rev1)) k),
  array['criada_em', 'ocorrencia_id', 'prazo_resposta_ate', 'tipo'],
  'chaves de Protocolo devolvido estritamente coincidentes com o contrato'
);

-- Verifica registro na tabela public.ocorrencia
select is(
  (select count(*)::int from public.ocorrencia
    where id = ((select p from res_rev1)->>'ocorrencia_id')::uuid
      and autor_id = 'c6050000-0000-4000-8000-000000000001'
      and tipo = 'revisao_despacho'
      and resolvido_em is null),
  1,
  'ocorrência gravada em análise com autor_id e tipo corretos'
);

-- ── 2. Segunda contestação pelo profissional A em análise: 409 contestacao_ja_aberta ──
select throws_ok(
  $$ select pg_temp.como('c6050000-0000-4000-8000-000000000001',
       'select public.pedir_revisao_despacho(''Segunda tentativa de contestacao enquanto a primeira esta em analise'')') $$,
  'PGRST', pg_temp.erro('contestacao_ja_aberta'),
  'segunda contestacao pelo mesmo autor em analise e recusada com 409 contestacao_ja_aberta'
);

-- ── 3. Equipe Frila responde à ocorrência (resolvido_em is not null) ──────────
update public.ocorrencia
   set resolvido_em = '2027-07-03 15:00:00+00',
       resultado = 'Pedido de revisão do despacho analisado e respondido por e-mail'
 where id = (((select p from res_rev1)->>'ocorrencia_id')::uuid);

-- ── 4. Nova tentativa após resposta: CONTINUA recusando com 409 (Opção B) ──────
-- No app só cabe 1 contestação; recurso subsequente exclusivamente por e-mail
select throws_ok(
  $$ select pg_temp.como('c6050000-0000-4000-8000-000000000001',
       'select public.pedir_revisao_despacho(''Tentativa de novo pedido pelo app apos resposta por email'')') $$,
  'PGRST', pg_temp.erro('contestacao_ja_aberta'),
  'reenvio pelo app apos contestacao ja respondida continua recusado com 409 contestacao_ja_aberta (Opcao B)'
);

-- ── 5. Profissional B consegue submeter sua própria primeira contestação ───────
create temp table res_rev_b as select
  pg_temp.como('c6050000-0000-4000-8000-000000000002',
    'select public.pedir_revisao_despacho(''Profissional B contestando despacho pela primeira vez'')') as p;

select is(
  ((select p from res_rev_b)->>'tipo'),
  'revisao_despacho',
  'profissional B submete primeira contestacao com sucesso'
);

select ok(
  ((select p from res_rev_b)->>'ocorrencia_id') is not null,
  'profissional B recebe ocorrencia_id'
);

-- Segunda contestação pelo profissional B também é barrada com 409
select throws_ok(
  $$ select pg_temp.como('c6050000-0000-4000-8000-000000000002',
       'select public.pedir_revisao_despacho(''Segunda contestacao pelo profissional B'')') $$,
  'PGRST', pg_temp.erro('contestacao_ja_aberta'),
  'segunda contestacao pelo profissional B tambem e recusada com 409 contestacao_ja_aberta'
);

-- Confirma total de ocorrências registradas para cada autor
select is(
  (select count(*)::int from public.ocorrencia where autor_id = 'c6050000-0000-4000-8000-000000000001' and tipo = 'revisao_despacho'),
  1,
  'profissional A possui exatamente 1 ocorrencia de revisao_despacho'
);

select is(
  (select count(*)::int from public.ocorrencia where autor_id = 'c6050000-0000-4000-8000-000000000002' and tipo = 'revisao_despacho'),
  1,
  'profissional B possui exatamente 1 ocorrencia de revisao_despacho'
);

select * from finish();
rollback;
