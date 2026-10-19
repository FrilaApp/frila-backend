-- 604_situacao_da_conta_contestacao_respondida.sql
--
-- Teste pgTAP do ciclo de vida da contestação de suspensão (Opção B, contrato 0.2.36).
-- Decisão de produto:
--   1. situacao_da_conta devolve contestacao null quando a suspensão ainda não foi contestada.
--   2. Após envio da contestação (em análise, resolvido_em is null), devolve o Protocolo.
--   3. Após resposta da Equipe Frila (contestação respondida/resolvida, resolvido_em is not null),
--      situacao_da_conta CONTINUA devolvendo o Protocolo (evita que o app reexiba o botão de contestar).
--   4. Nenhum resultado interno/decisão da Equipe Frila (RN07, RF24) é exposto na resposta.
--   5. Chaves do JSON respeitam estritamente o contrato:
--      - raiz: {"estado", "suspensao"}
--      - suspensao: {"motivo", "desde", "contestacao"}
--      - contestacao: {"ocorrencia_id", "tipo", "criada_em", "prazo_resposta_ate"}
--   6. Nova chamada a contestar_suspensao continua respondendo 409 contestacao_ja_aberta
--      tanto quando em análise quanto após respondida.
--   7. Executado com relógio congelado no futuro (frila.agora).

begin;
select plan(23);

-- Ativa ambiente de teste e fixa o relógio em data futura (+90 dias)
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2027-06-01 12:00:00+00', true);

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

-- Criação de contas auth.users e public.usuario para o cenário
-- c6040001: profissional suspenso
-- c6040002: operador Frila
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'c6040000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
        'suspenso604@frila.test', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false),
       ('00000000-0000-0000-0000-000000000000', 'c6040000-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
        'operador604@frila.test', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values ('c6040000-0000-4000-8000-000000000001', 'profissional', 'Profissional Teste 604', '+5561999996041', 'suspenso604@frila.test', '1995-01-01', '2026-09-22', now(), 'ativa'),
       ('c6040000-0000-4000-8000-000000000002', 'contratante', 'Operador Teste 604', '+5561999996042', 'operador604@frila.test', '1990-01-01', '2026-09-22', now(), 'ativa');

insert into privado.conta_equipe (usuario_id) values ('c6040000-0000-4000-8000-000000000002');

-- ── 1. Conta ativa: situacao_da_conta devolve estado ativa e suspensao null ───
create temp table sit_ativa as
  select pg_temp.como('c6040000-0000-4000-8000-000000000001', 'select public.situacao_da_conta()') as s;

select is(
  ((select s from sit_ativa)->>'estado'),
  'ativa',
  'situacao_da_conta devolve estado ativa'
);

select is(
  ((select s from sit_ativa)->>'suspensao'),
  null,
  'situacao_da_conta devolve suspensao nula para conta ativa'
);

-- ── 2. Suspende a conta ────────────────────────────────────────────────────────
select privado.suspender(
  'c6040000-0000-4000-8000-000000000001',
  'Suspensão preventiva para averiguação',
  'c6040000-0000-4000-8000-000000000002'
);

-- ── 3. Leitura antes de contestar: contestacao null e estrita verificação de chaves ──
create temp table sit_sem_cont as
  select pg_temp.como('c6040000-0000-4000-8000-000000000001', 'select public.situacao_da_conta()') as s;

select is(
  ((select s from sit_sem_cont)->>'estado'),
  'suspensa',
  'situacao_da_conta devolve estado suspensa'
);

select is(
  ((select s from sit_sem_cont)->'suspensao'->>'motivo'),
  'Suspensão preventiva para averiguação',
  'situacao_da_conta expõe o motivo registrado da suspensão'
);

select is(
  ((select s from sit_sem_cont)->'suspensao'->>'contestacao'),
  null,
  'contestacao é nula antes de ser enviada'
);

-- Nenhuma chave excedente na raiz
select is(
  (select array_agg(k order by k) from jsonb_object_keys((select s from sit_sem_cont)) k),
  array['estado', 'suspensao'],
  'chaves da raiz de SituacaoDaConta estritamente coincidentes com o contrato'
);

-- Nenhuma chave excedente em suspensao
select is(
  (select array_agg(k order by k) from jsonb_object_keys((select s from sit_sem_cont)->'suspensao') k),
  array['contestacao', 'desde', 'motivo'],
  'chaves de suspensao estritamente coincidentes com o contrato'
);

-- ── 4. Envio da contestação (em análise) ────────────────────────────────────────
create temp table res_cont as
  select pg_temp.como('c6040000-0000-4000-8000-000000000001',
    'select public.contestar_suspensao(''Não cometi nenhuma irregularidade e apresento minha defesa detalhada.'')') as c;

select is(
  ((select c from res_cont)->>'tipo'),
  'contestacao',
  'contestar_suspensao devolve Protocolo com tipo contestacao'
);

-- Nenhuma chave excedente no retorno de contestar_suspensao (Protocolo)
select is(
  (select array_agg(k order by k) from jsonb_object_keys((select c from res_cont)) k),
  array['criada_em', 'ocorrencia_id', 'prazo_resposta_ate', 'tipo'],
  'chaves de Protocolo devolvido por contestar_suspensao estritamente coincidentes com o contrato'
);

-- situacao_da_conta enquanto contestação está em análise (resolvido_em is null)
create temp table sit_em_analise as
  select pg_temp.como('c6040000-0000-4000-8000-000000000001', 'select public.situacao_da_conta()') as s;

select is(
  ((select s from sit_em_analise)->'suspensao'->'contestacao'->>'tipo'),
  'contestacao',
  'situacao_da_conta reflete contestacao com tipo contestacao em analise'
);

select is(
  ((select s from sit_em_analise)->'suspensao'->'contestacao'->>'ocorrencia_id'),
  ((select c from res_cont)->>'ocorrencia_id'),
  'ocorrencia_id da contestacao em analise bate com o protocolo gerado'
);

-- Chaves de contestacao dentro de suspensao
select is(
  (select array_agg(k order by k) from jsonb_object_keys((select s from sit_em_analise)->'suspensao'->'contestacao') k),
  array['criada_em', 'ocorrencia_id', 'prazo_resposta_ate', 'tipo'],
  'chaves de Protocolo em situacao_da_conta estritamente coincidentes com o contrato'
);

-- Tentativa de segunda contestação enquanto em análise devolve 409 contestacao_ja_aberta
select throws_ok(
  $$ select pg_temp.como('c6040000-0000-4000-8000-000000000001',
       'select public.contestar_suspensao(''Segunda contestacao enquanto a primeira esta em analise'')') $$,
  'PGRST', pg_temp.erro('contestacao_ja_aberta'),
  'segunda contestacao em analise devolve 409 contestacao_ja_aberta'
);

-- ── 5. Contestação respondida pela Equipe Frila (resolvido_em preenchido) ─────
-- A equipe analisa e indefere/responde a contestação por e-mail (fora do app)
update public.ocorrencia
   set resolvido_em = '2027-06-03 15:00:00+00',
       resultado = 'Contestação analisada pela Equipe Frila e indeferida após checagem de logs internos'
 where id = (((select c from res_cont)->>'ocorrencia_id')::uuid);

-- situacao_da_conta após resposta da Equipe Frila:
-- Opção B (0.2.36): CONTINUA devolvendo o Protocolo da contestação!
create temp table sit_respondida as
  select pg_temp.como('c6040000-0000-4000-8000-000000000001', 'select public.situacao_da_conta()') as s;

select is(
  ((select s from sit_respondida)->>'estado'),
  'suspensa',
  'situacao_da_conta continua com estado suspensa apos resposta da contestacao'
);

select ok(
  ((select s from sit_respondida)->'suspensao'->'contestacao') is not null,
  'situacao_da_conta NAO volta a ser null apos resposta da contestacao (Opcao B)'
);

select is(
  ((select s from sit_respondida)->'suspensao'->'contestacao'->>'tipo'),
  'contestacao',
  'situacao_da_conta devolve contestacao com tipo contestacao mesmo apos respondida'
);

select is(
  ((select s from sit_respondida)->'suspensao'->'contestacao'->>'ocorrencia_id'),
  ((select c from res_cont)->>'ocorrencia_id'),
  'ocorrencia_id da contestacao respondida preserva o mesmo protocolo inicial'
);

-- RN07 / RF24: nenhum resultado interno ou notas de suporte vazam no JSON
select is(
  ((select s from sit_respondida)->'suspensao'->'contestacao'->>'resultado'),
  null,
  'resultado do suporte nao vaza em contestacao (RN07)'
);

select is(
  ((select s from sit_respondida)->'suspensao' ? 'resultado'),
  false,
  'resultado do suporte nao vaza em suspensao (RN07)'
);

-- Verificação estrita de chaves de situacao_da_conta após respondida
select is(
  (select array_agg(k order by k) from jsonb_object_keys((select s from sit_respondida)) k),
  array['estado', 'suspensao'],
  'chaves da raiz de SituacaoDaConta estritamente preservadas apos resolucao'
);

select is(
  (select array_agg(k order by k) from jsonb_object_keys((select s from sit_respondida)->'suspensao') k),
  array['contestacao', 'desde', 'motivo'],
  'chaves de suspensao estritamente preservadas apos resolucao'
);

select is(
  (select array_agg(k order by k) from jsonb_object_keys((select s from sit_respondida)->'suspensao'->'contestacao') k),
  array['criada_em', 'ocorrencia_id', 'prazo_resposta_ate', 'tipo'],
  'chaves de Protocolo em situacao_da_conta estritamente preservadas apos resolucao (nenhuma chave nova)'
);

-- ── 6. Bloqueio de reenvio após contestação respondida ─────────────────────────
-- O aplicativo NÃO permite novo envio e a RPC continua levantando 409 contestacao_ja_aberta
select throws_ok(
  $$ select pg_temp.como('c6040000-0000-4000-8000-000000000001',
       'select public.contestar_suspensao(''Tentativa de reenvio pelo app apos contestacao ja respondida'')') $$,
  'PGRST', pg_temp.erro('contestacao_ja_aberta'),
  'reenvio de contestacao apos resposta continua devolvendo 409 contestacao_ja_aberta (Opcao B)'
);

select * from finish();
rollback;
