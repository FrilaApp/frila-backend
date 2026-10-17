-- 736_rpc_candidatos_da_vaga_da_equipe.sql
--
-- Cobertura pgTAP para o campo Candidato.da_equipe retornado por public.candidatos_da_vaga(uuid).
-- Contrato 0.2.38 (D7) / Achado 1 da Auditoria de Contrato:
--   - 'da_equipe': booleano obrigatório no envelope JSON (tipo boolean, nunca null/ausente);
--   - 'true' se o profissional pertence à equipe de confiança do estabelecimento da vaga (public.equipe_confianca);
--   - 'false' se o profissional NÃO pertence à equipe de confiança do estabelecimento da vaga;
--   - Isolamento societário: pertencer à equipe de outro estabelecimento NÃO concede 'da_equipe = true';
--   - Dinâmica: inclusão e remoção em public.equipe_confianca refletem imediatamente;
--   - RN06 mantida: da_equipe NÃO altera a ordem de chegada da listagem.
--   - Mutações testadas: omissão do campo, hardcoded true, hardcoded false, filtro sem estabelecimento_id.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-11-15 12:00:00-03';

select plan(16);

-- Helpers temporários de teste
create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (
    instance_id, id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    is_sso_user, is_anonymous
  ) values (
    '00000000-0000-4000-8000-000000000000', conta, 'authenticated', 'authenticated',
    email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(),
    false, false
  ) on conflict (id) do nothing;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local "request.jwt.claims" = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute format('set local "request.jwt.claim.sub" = %L', conta::text);
  execute sql into r;
  reset role;
  execute 'reset "request.jwt.claims"';
  execute 'reset "request.jwt.claim.sub"';
  return r;
end $$;

-- Snapshot da definição original para testes de mutação
create temp table pg_temp.def_original as
  select pg_get_functiondef('public.candidatos_da_vaga(uuid)'::regprocedure) as def;

-- ── Setup de Fixtures ─────────────────────────────────────────────────────────

create temp table ids as select
  -- Contratantes
  '73600000-0000-4000-8000-000000000001'::uuid as user_dono_ze,
  '73600000-0000-4000-8000-000000000002'::uuid as user_dona_rita,
  -- Profissionais (contas de usuario)
  '73600000-0000-4000-8000-000000000011'::uuid as user_ana,
  '73600000-0000-4000-8000-000000000012'::uuid as user_bruno,
  '73600000-0000-4000-8000-000000000013'::uuid as user_carlos,
  -- Profissionais (entidades)
  '73600000-0000-4000-8000-000000000021'::uuid as prof_ana,
  '73600000-0000-4000-8000-000000000022'::uuid as prof_bruno,
  '73600000-0000-4000-8000-000000000023'::uuid as prof_carlos,
  -- Estabelecimentos
  '73600000-0000-4000-8000-000000000031'::uuid as estab_ze,
  '73600000-0000-4000-8000-000000000032'::uuid as estab_rita,
  -- Vagas
  '73600000-0000-4000-8000-000000000101'::uuid as vaga_ze,
  -- Posicoes
  '73600000-0000-4000-8000-000000000201'::uuid as pos_ze,
  -- Candidaturas
  '73600000-0000-4000-8000-000000000501'::uuid as cand_bruno,
  '73600000-0000-4000-8000-000000000502'::uuid as cand_ana,
  '73600000-0000-4000-8000-000000000503'::uuid as cand_carlos;

-- Autenticações em auth.users
select pg_temp.autenticar((select user_dono_ze from ids),  'dono_ze@736.test');
select pg_temp.autenticar((select user_dona_rita from ids), 'rita@736.test');
select pg_temp.autenticar((select user_ana from ids),       'ana@736.test');
select pg_temp.autenticar((select user_bruno from ids),     'bruno@736.test');
select pg_temp.autenticar((select user_carlos from ids),    'carlos@736.test');

-- Usuários
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('73600000-0000-4000-8000-000000000001', 'contratante', 'Seu Zé 736', 'dono_ze@736.test', '+5561973600001', '1975-01-01', 'ativa', '1.0', now()),
  ('73600000-0000-4000-8000-000000000002', 'contratante', 'Dona Rita 736', 'rita@736.test', '+5561973600002', '1982-01-01', 'ativa', '1.0', now()),
  ('73600000-0000-4000-8000-000000000011', 'profissional', 'Ana 736', 'ana@736.test', '+5561973600011', '1995-05-10', 'ativa', '1.0', now()),
  ('73600000-0000-4000-8000-000000000012', 'profissional', 'Bruno 736', 'bruno@736.test', '+5561973600012', '1992-03-15', 'ativa', '1.0', now()),
  ('73600000-0000-4000-8000-000000000013', 'profissional', 'Carlos 736', 'carlos@736.test', '+5561973600013', '1990-08-20', 'ativa', '1.0', now());

-- Entidades profissional
insert into public.profissional (
  id, usuario_id, ponto_base, taxa_comparecimento, turnos_realizados, aval_positivas, aval_total
) values
  ('73600000-0000-4000-8000-000000000021', '73600000-0000-4000-8000-000000000011',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 1.000, 10, 10, 10),
  ('73600000-0000-4000-8000-000000000022', '73600000-0000-4000-8000-000000000012',
   'POINT(-47.8850 -15.7980)'::extensions.geography, 0.900, 5, 5, 5),
  ('73600000-0000-4000-8000-000000000023', '73600000-0000-4000-8000-000000000013',
   'POINT(-47.8870 -15.7990)'::extensions.geography, 0.950, 8, 8, 8);

-- Estabelecimentos
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('73600000-0000-4000-8000-000000000031', 'Bar do Zé 736', '73600000000131', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('73600000-0000-4000-8000-000000000032', 'Buffet da Rita 736', '73600000000132', 'evento', 'CLS 302', 'POINT(-47.8900 -15.8100)'::extensions.geography, 'Plano Piloto');

-- Membros dos estabelecimentos
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('73600000-0000-4000-8000-000000000001', '73600000-0000-4000-8000-000000000031', 'administrador'),
  ('73600000-0000-4000-8000-000000000002', '73600000-0000-4000-8000-000000000032', 'administrador');

-- Vaga no Bar do Zé
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values
  ('73600000-0000-4000-8000-000000000101', '73600000-0000-4000-8000-000000000031',
   (select id from public.funcao where ativo is true limit 1),
   '2026-11-20 18:00:00+00', '2026-11-20 23:00:00+00', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 18000, 1,
   true, false, false, 'Seu Zé', 'selecao', 'publicada',
   '73600000-0000-4000-8000-000000000901'::uuid,
   '73600000-0000-4000-8000-000000000001'::uuid, '2026-11-10 10:00:00+00');

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id) values
  ('73600000-0000-4000-8000-000000000201', '73600000-0000-4000-8000-000000000101', '2026-11-20 18:00:00+00', '2026-11-20 23:00:00+00', 'aberta', null);

-- Candidaturas na ordem de chegada:
-- 1. Bruno (10:00) - NÃO pertence a nenhuma equipe
-- 2. Ana (10:05) - PERTENCE à equipe de confiança do Bar do Zé
-- 3. Carlos (10:10) - PERTENCE à equipe de confiança do Buffet da Rita (outra casa)
insert into public.candidatura (id, posicao_id, profissional_id, criada_em, estado) values
  ('73600000-0000-4000-8000-000000000501', '73600000-0000-4000-8000-000000000201',
   '73600000-0000-4000-8000-000000000022', '2026-11-15 10:00:00+00', 'pendente'),
  ('73600000-0000-4000-8000-000000000502', '73600000-0000-4000-8000-000000000201',
   '73600000-0000-4000-8000-000000000021', '2026-11-15 10:05:00+00', 'pendente'),
  ('73600000-0000-4000-8000-000000000503', '73600000-0000-4000-8000-000000000201',
   '73600000-0000-4000-8000-000000000023', '2026-11-15 10:10:00+00', 'pendente');

-- Configuração inicial de equipes de confiança:
-- Ana está na equipe do Bar do Zé:
insert into public.equipe_confianca (estabelecimento_id, profissional_id, adicionado_em) values
  ('73600000-0000-4000-8000-000000000031', '73600000-0000-4000-8000-000000000021', '2026-11-01 10:00:00+00');

-- Carlos está na equipe do Buffet da Rita (outra casa):
insert into public.equipe_confianca (estabelecimento_id, profissional_id, adicionado_em) values
  ('73600000-0000-4000-8000-000000000032', '73600000-0000-4000-8000-000000000023', '2026-11-01 10:00:00+00');

-- ── 1. Presença e Tipo do Campo no Envelope Canônico ─────────────────────────

-- 1. Toda candidatura retornada possui a chave 'da_equipe'
select ok(
  (select bool_and(elem ? 'da_equipe')
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids),
       format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze from ids)))) elem),
  'envelope canonico: toda candidatura retornada possui a chave da_equipe'
);

-- 2. O tipo de 'da_equipe' é estritamente booleano (não nulo nem string)
select ok(
  (select bool_and(jsonb_typeof(elem->'da_equipe') = 'boolean')
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids),
       format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze from ids)))) elem),
  'integridade de tipo: o valor de da_equipe e sempre um boolean JSON'
);

-- ── 2. Valores Semânticos Corretos por Candidato ─────────────────────────────

-- 3. Bruno NÃO pertence à equipe do Bar do Zé -> da_equipe = false
select is(
  (select (elem->>'da_equipe')::boolean
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids),
       format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze from ids)))) elem
    where (elem->>'candidatura_id')::uuid = (select cand_bruno from ids)),
  false,
  'Bruno nao esta na equipe de confianca do Bar do Ze: da_equipe = false'
);

-- 4. Ana PERTENCE à equipe do Bar do Zé -> da_equipe = true
select is(
  (select (elem->>'da_equipe')::boolean
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids),
       format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze from ids)))) elem
    where (elem->>'candidatura_id')::uuid = (select cand_ana from ids)),
  true,
  'Ana esta na equipe de confianca do Bar do Ze: da_equipe = true'
);

-- 5. Carlos pertence à equipe de OUTRO estabelecimento (Buffet da Rita), não do Bar do Zé -> da_equipe = false
select is(
  (select (elem->>'da_equipe')::boolean
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids),
       format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze from ids)))) elem
    where (elem->>'candidatura_id')::uuid = (select cand_carlos from ids)),
  false,
  'Carlos esta na equipe do Buffet da Rita, mas nao do Bar do Ze: da_equipe = false (isolamento societario)'
);

-- ── 3. RN06: Ordenação Estrita de Chegada Não é Afetada por da_equipe ────────

-- 6. Ordem das candidaturas permanece estritamente Bruno (10:00), Ana (10:05), Carlos (10:10)
select is(
  (select jsonb_agg(elem->>'candidatura_id')
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids),
       format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze from ids)))) elem),
  jsonb_build_array(
    (select cand_bruno from ids)::text,
    (select cand_ana from ids)::text,
    (select cand_carlos from ids)::text
  ),
  'RN06 preservada: Ana (da_equipe=true) NAO ultrapassa Bruno (chegou antes com da_equipe=false)'
);

-- ── 4. Dinâmica: Inclusão e Remoção em equipe_confianca ───────────────────────

-- 7. Adicionando Bruno à equipe do Bar do Zé -> da_equipe de Bruno vira true
insert into public.equipe_confianca (estabelecimento_id, profissional_id, adicionado_em)
values ('73600000-0000-4000-8000-000000000031', '73600000-0000-4000-8000-000000000022', now());

select is(
  (select (elem->>'da_equipe')::boolean
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids),
       format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze from ids)))) elem
    where (elem->>'candidatura_id')::uuid = (select cand_bruno from ids)),
  true,
  'apos inclusao na equipe_confianca, da_equipe de Bruno reflete true imediatamente'
);

-- 8. Removendo Ana da equipe do Bar do Zé -> da_equipe de Ana vira false
delete from public.equipe_confianca
 where estabelecimento_id = '73600000-0000-4000-8000-000000000031'
   and profissional_id = '73600000-0000-4000-8000-000000000021';

select is(
  (select (elem->>'da_equipe')::boolean
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids),
       format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze from ids)))) elem
    where (elem->>'candidatura_id')::uuid = (select cand_ana from ids)),
  false,
  'apos remocao de equipe_confianca, da_equipe de Ana reflete false imediatamente'
);

-- Restaura estado para testes de mutação: Ana na equipe, Bruno fora
delete from public.equipe_confianca
 where estabelecimento_id = '73600000-0000-4000-8000-000000000031'
   and profissional_id = '73600000-0000-4000-8000-000000000022';
insert into public.equipe_confianca (estabelecimento_id, profissional_id, adicionado_em)
values ('73600000-0000-4000-8000-000000000031', '73600000-0000-4000-8000-000000000021', now());

-- Helper para extrair o bloco exato de 'da_equipe' da definição original
create function pg_temp.bloco_da_equipe() returns text language plpgsql as $$
declare
  v_def text := (select def from pg_temp.def_original);
  v_pos1 int := position('''da_equipe''' in v_def);
  v_pos2 int;
begin
  v_pos2 := position('and ec.profissional_id = c.profissional_id' in v_def);
  v_pos2 := position('),' in substring(v_def from v_pos2)) + v_pos2 + 1;
  return substring(v_def from v_pos1 for (v_pos2 - v_pos1 + 1));
end $$;

-- ── 5. Provas de Mutação Real via pg_get_functiondef ─────────────────────────

-- Mutante 1: Omissão de 'da_equipe' no jsonb_build_object
do $$
begin
  execute replace(
    (select def from pg_temp.def_original),
    pg_temp.bloco_da_equipe(),
    ''
  );
end $$;

-- 9. Mutante 1 quebra: chave da_equipe deixa de existir
select ok(
  not exists (
    select 1
      from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids),
        format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze from ids)))) elem
     where elem ? 'da_equipe'
  ),
  'mutante 1 pego: omissao de da_equipe faz o envelope nao conter a chave'
);

-- Restaura
do $$ begin execute (select def from pg_temp.def_original); end $$;

-- 10. Restauração após mutante 1
select is(
  pg_get_functiondef('public.candidatos_da_vaga(uuid)'::regprocedure),
  (select def from pg_temp.def_original),
  'restauracao perfeita apos mutante 1'
);

-- Mutante 2: 'da_equipe' sempre hardcoded true
do $$
begin
  execute replace(
    (select def from pg_temp.def_original),
    pg_temp.bloco_da_equipe(),
    '''da_equipe'', true,'
  );
end $$;

-- 11. Mutante 2 quebra: Bruno (que não é da equipe) viraria true
select is(
  (select (elem->>'da_equipe')::boolean
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids),
       format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze from ids)))) elem
    where (elem->>'candidatura_id')::uuid = (select cand_bruno from ids)),
  true,
  'mutante 2 detectado: hardcoded true marca indevidamente candidato que nao e da equipe'
);

-- Restaura
do $$ begin execute (select def from pg_temp.def_original); end $$;

-- 12. Restauração após mutante 2
select is(
  pg_get_functiondef('public.candidatos_da_vaga(uuid)'::regprocedure),
  (select def from pg_temp.def_original),
  'restauracao perfeita apos mutante 2'
);

-- Mutante 3: 'da_equipe' sempre hardcoded false
do $$
begin
  execute replace(
    (select def from pg_temp.def_original),
    pg_temp.bloco_da_equipe(),
    '''da_equipe'', false,'
  );
end $$;

-- 13. Mutante 3 quebra: Ana (que é da equipe) viraria false
select is(
  (select (elem->>'da_equipe')::boolean
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids),
       format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze from ids)))) elem
    where (elem->>'candidatura_id')::uuid = (select cand_ana from ids)),
  false,
  'mutante 3 detectado: hardcoded false marca indevidamente candidato que e da equipe'
);

-- Restaura
do $$ begin execute (select def from pg_temp.def_original); end $$;

-- 14. Restauração após mutante 3
select is(
  pg_get_functiondef('public.candidatos_da_vaga(uuid)'::regprocedure),
  (select def from pg_temp.def_original),
  'restauracao perfeita apos mutante 3'
);

-- Mutante 4: Checagem global sem filtro de estabelecimento_id (ec.profissional_id = c.profissional_id apenas)
do $$
begin
  execute regexp_replace(
    (select def from pg_temp.def_original),
    'ec\.estabelecimento_id\s*=\s*v_estab\s+and\s+',
    ''
  );
end $$;

-- 15. Mutante 4 quebra: Carlos (equipe do Buffet da Rita) viraria true na vaga do Seu Zé
select is(
  (select (elem->>'da_equipe')::boolean
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids),
       format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze from ids)))) elem
    where (elem->>'candidatura_id')::uuid = (select cand_carlos from ids)),
  true,
  'mutante 4 detectado: omissao do filtro de estabelecimento_id vaza equipes de outros estabelecimentos'
);

-- Restaura final
do $$ begin execute (select def from pg_temp.def_original); end $$;

-- 16. Restauração canônica final
select is(
  pg_get_functiondef('public.candidatos_da_vaga(uuid)'::regprocedure),
  (select def from pg_temp.def_original),
  'restauracao canonica final confirmada'
);

rollback;
