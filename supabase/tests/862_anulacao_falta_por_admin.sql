-- 862_anulacao_falta_por_admin.sql
--
-- Anulação de falta operacional por administrador (Equipe Frila, RN12).
-- Migração: 20261115060000_anulacao_falta_por_admin.sql
--
-- Casos cobertos:
--   1. Estrutura e segurança:
--      - privado.anular_falta é SECURITY DEFINER com search_path="" fixado.
--      - revoke para anon e authenticated; grant exclusivo para service_role.
--      - Tabela privada privado.anulacao_falta sem SELECT para anon/authenticated (sem vazamento de dados aos clientes).
--      - public.posicao NÃO possui colunas confidenciais de auditoria.
--   2. Validações de parâmetros e permissões:
--      - posicao_id nulo -> 422 campo_obrigatorio (posicao_id).
--      - motivo nulo ou vazio -> 422 campo_obrigatorio (motivo).
--      - motivo < 10 caracteres -> 422 justificativa_insuficiente.
--      - operador_id nulo (sem sub) -> 422 campo_obrigatorio (operador_id).
--      - operador_id inexistente -> 404 nao_encontrado (operador_id).
--      - operador_id fora de privado.conta_equipe -> 403 sem_permissao (operador_id).
--      - ocorrencia_origem_id inexistente -> 404 nao_encontrado (ocorrencia_origem_id).
--   3. Validações de estado da posição:
--      - posicao_id inexistente -> 404 nao_encontrado (posicao_id).
--      - posicao com estado <> 'cancelada' (aberta ou confirmada) -> 422 posicao_nao_cancelada.
--      - só falta=true anula: posicao cancelada com falta=false (e não anulada) -> 409 falta_inexistente.
--   4. Anulação com sucesso:
--      - Altera posicao.falta para false.
--      - Grava auditoria em privado.anulacao_falta (quem, quando, motivo, ocorrencia_origem_id, ocorrencia_auditoria_id).
--      - A taxa muda: taxa_comparecimento recalculada de 0.333 para 0.500 (e depois para 1.000).
--      - Grava ocorrência de auditoria em public.ocorrencia assinada pelo operador.
--      - Resolve o chamado de suporte de origem (quando informado).
--   5. Idempotência:
--      - Segunda chamada na posição já anulada é idempotente (devolve ja_estava_anulada true).
--      - Não duplica linha em public.ocorrencia nem em privado.anulacao_falta.
--      - Preserva campos originais de auditoria e taxa intacta.
--   6. Anulação sem chamado de origem:
--      - Funciona passando apenas posicao_id, motivo e operador_id (4º parâmetro default null).

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_temp;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-11-15 12:00:00-03';

select plan(39);

-- ── 1. Estrutura e Segurança ──────────────────────────────────────────────────

select is(
  (select prosecdef from pg_proc
    where proname = 'anular_falta' and pronamespace = 'privado'::regnamespace),
  true,
  'privado.anular_falta é SECURITY DEFINER'
);

select ok(
  (select proconfig from pg_proc
    where proname = 'anular_falta' and pronamespace = 'privado'::regnamespace)
    @> array['search_path=""'],
  'privado.anular_falta tem search_path="" fixado'
);

select ok(
  not has_function_privilege('anon', 'privado.anular_falta(uuid, text, uuid, uuid)', 'execute'),
  'anon NÃO tem permissão de executar privado.anular_falta'
);

select ok(
  not has_function_privilege('authenticated', 'privado.anular_falta(uuid, text, uuid, uuid)', 'execute'),
  'authenticated NÃO tem permissão de executar privado.anular_falta'
);

select ok(
  has_function_privilege('service_role', 'privado.anular_falta(uuid, text, uuid, uuid)', 'execute'),
  'service_role tem permissão de executar privado.anular_falta'
);

select has_table('privado', 'anulacao_falta', 'tabela privado.anulacao_falta existe');

select ok(
  not has_table_privilege('anon', 'privado.anulacao_falta', 'select'),
  'anon NÃO tem SELECT em privado.anulacao_falta'
);

select ok(
  not has_table_privilege('authenticated', 'privado.anulacao_falta', 'select'),
  'authenticated NÃO tem SELECT em privado.anulacao_falta'
);

select ok(
  not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'posicao' and column_name in ('falta_anulada_motivo', 'falta_anulada_por', 'falta_anulada_em', 'falta_ocorrencia_origem_id')
  ),
  'public.posicao NÃO expõe falta_anulada_motivo nem outras colunas de auditoria a clientes'
);

-- ── 2. Helpers e Fixtures ─────────────────────────────────────────────────────

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create function pg_temp.como_usuario(conta uuid, sql text) returns void
language plpgsql as $$
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql;
  reset role;
  execute 'reset request.jwt.claims';
end $$;

create temp table ids as
select
  '86200000-0000-4000-8000-000000000001'::uuid as user_operador,
  '86200000-0000-4000-8000-000000000002'::uuid as user_dono,
  '86200000-0000-4000-8000-000000000010'::uuid as estab_id,
  '86200000-0000-4000-8000-000000000101'::uuid as user_prof,
  '86200000-0000-4000-8000-000000000102'::uuid as prof_id;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
values
  ((select user_operador from ids), 'contratante', 'Operador Admin 862', '+5561999998621', 'admin862@test.invalid', '1985-01-01', '1.0', now(), false),
  ((select user_dono from ids), 'contratante', 'Dono Casa 862', '+5561999998622', 'dono862@test.invalid', '1988-02-02', '1.0', now(), false),
  ((select user_prof from ids), 'profissional', 'Profissional Falta 862', '+5561988888621', 'prof862@test.invalid', '1992-06-06', '1.0', now(), false);

-- Operador pertence à Equipe Frila
insert into privado.conta_equipe (usuario_id)
values ((select user_operador from ids));

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values
  ((select estab_id from ids), 'Restaurante 862', '86200000000101', 'food_service', 'Quadra 862', 'POINT(-47.88 -15.78)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values
  ((select user_dono from ids), (select estab_id from ids), 'administrador');

insert into public.profissional (id, usuario_id, ponto_base)
values
  ((select prof_id from ids), (select user_prof from ids), 'POINT(-47.88 -15.78)'::extensions.geography);

-- Helper para criar turno com presença verificada
create function pg_temp.criar_turno_verificado(p_estab uuid, p_prof uuid)
returns uuid language plpgsql as $$
declare
  v_vaga uuid := gen_random_uuid();
  v_pos  uuid := gen_random_uuid();
  v_func uuid;
  v_inicio timestamptz := '2026-11-10 10:00:00-03';
  v_fim    timestamptz := '2026-11-10 16:00:00-03';
begin
  select id into v_func from public.funcao where nome = 'garçom';
  insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em,
                           local, ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em, estado)
  values (v_vaga, p_estab, v_func, (select user_dono from ids),
          v_inicio, v_fim, 'Local 862', 'POINT(-47.88 -15.78)'::extensions.geography, 15000, 1, true, false, false,
          'Resp 862', 'urgencia', gen_random_uuid(), v_inicio - interval '2 days', 'encerrada');

  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, falta, inicio_em, fim_em)
  values (v_pos, v_vaga, p_prof, 'cumprida', v_inicio - interval '1 day', false, v_inicio, v_fim);

  insert into public.turno (id, posicao_id, checkin_em, checkout_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
  values (gen_random_uuid(), v_pos, v_inicio, v_fim, 'geolocalizado', 50, 'verificado', 15000);

  return v_pos;
end $$;

-- Helper para criar posição cancelada com falta
create function pg_temp.criar_posicao_com_falta(p_estab uuid, p_prof uuid)
returns uuid language plpgsql as $$
declare
  v_vaga uuid := gen_random_uuid();
  v_pos  uuid := gen_random_uuid();
  v_func uuid;
  v_inicio timestamptz := '2026-11-12 10:00:00-03';
  v_fim    timestamptz := '2026-11-12 16:00:00-03';
begin
  select id into v_func from public.funcao where nome = 'garçom';
  insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em,
                           local, ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em, estado)
  values (v_vaga, p_estab, v_func, (select user_dono from ids),
          v_inicio, v_fim, 'Local 862', 'POINT(-47.88 -15.78)'::extensions.geography, 15000, 1, true, false, false,
          'Resp 862', 'urgencia', gen_random_uuid(), v_inicio - interval '2 days', 'encerrada');

  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, falta, inicio_em, fim_em)
  values (v_pos, v_vaga, p_prof, 'cancelada', v_inicio - interval '1 day', true, v_inicio, v_fim);

  insert into public.turno (id, posicao_id, verificacao, valor_acordado_centavos)
  values (gen_random_uuid(), v_pos, 'pendente', 15000);

  return v_pos;
end $$;

-- Helper para criar posição aberta (não cancelada)
create function pg_temp.criar_posicao_aberta(p_estab uuid)
returns uuid language plpgsql as $$
declare
  v_vaga uuid := gen_random_uuid();
  v_pos  uuid := gen_random_uuid();
  v_func uuid;
  v_inicio timestamptz := '2026-11-20 10:00:00-03';
  v_fim    timestamptz := '2026-11-20 16:00:00-03';
begin
  select id into v_func from public.funcao where nome = 'garçom';
  insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em,
                           local, ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em, estado)
  values (v_vaga, p_estab, v_func, (select user_dono from ids),
          v_inicio, v_fim, 'Local 862', 'POINT(-47.88 -15.78)'::extensions.geography, 15000, 1, true, false, false,
          'Resp 862', 'urgencia', gen_random_uuid(), v_inicio - interval '2 days', 'publicada');

  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, falta, inicio_em, fim_em)
  values (v_pos, v_vaga, null, 'aberta', null, false, v_inicio, v_fim);

  return v_pos;
end $$;

-- Helper para criar posição cancelada SEM falta
create function pg_temp.criar_posicao_sem_falta(p_estab uuid, p_prof uuid)
returns uuid language plpgsql as $$
declare
  v_vaga uuid := gen_random_uuid();
  v_pos  uuid := gen_random_uuid();
  v_func uuid;
  v_inicio timestamptz := '2026-11-21 10:00:00-03';
  v_fim    timestamptz := '2026-11-21 16:00:00-03';
begin
  select id into v_func from public.funcao where nome = 'garçom';
  insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em,
                           local, ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em, estado)
  values (v_vaga, p_estab, v_func, (select user_dono from ids),
          v_inicio, v_fim, 'Local 862', 'POINT(-47.88 -15.78)'::extensions.geography, 15000, 1, true, false, false,
          'Resp 862', 'urgencia', gen_random_uuid(), v_inicio - interval '2 days', 'encerrada');

  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, falta, inicio_em, fim_em)
  values (v_pos, v_vaga, p_prof, 'cancelada', v_inicio - interval '1 day', false, v_inicio, v_fim);

  return v_pos;
end $$;

-- ── 3. Validações de Parâmetros e Autoria ─────────────────────────────────────

select throws_ok(
  $$ select privado.anular_falta(null, 'Justificativa válida com mais de dez caracteres', '86200000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST', pg_temp.erro('campo_obrigatorio', 'posicao_id'),
  'recusa posicao_id nulo'
);

select throws_ok(
  $$ select privado.anular_falta(gen_random_uuid(), null, '86200000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST', pg_temp.erro('campo_obrigatorio', 'motivo'),
  'recusa motivo nulo'
);

select throws_ok(
  $$ select privado.anular_falta(gen_random_uuid(), '   ', '86200000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST', pg_temp.erro('campo_obrigatorio', 'motivo'),
  'recusa motivo vazio com espaços'
);

select throws_ok(
  $$ select privado.anular_falta(gen_random_uuid(), 'curto', '86200000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST', pg_temp.erro('justificativa_insuficiente'),
  'recusa motivo com menos de 10 caracteres'
);

select throws_ok(
  $$ select privado.anular_falta(gen_random_uuid(), 'Justificativa válida completa', null) $$,
  'PGRST', pg_temp.erro('campo_obrigatorio', 'operador_id'),
  'recusa operador_id nulo (autoria nunca é adivinhada)'
);

select throws_ok(
  $$ select privado.anular_falta(gen_random_uuid(), 'Justificativa válida completa', gen_random_uuid()) $$,
  'PGRST', pg_temp.erro('nao_encontrado', 'operador_id'),
  'recusa operador inexistente'
);

select throws_ok(
  format($$ select privado.anular_falta(gen_random_uuid(), 'Justificativa válida completa', %L::uuid) $$, (select user_dono from ids)),
  'PGRST', pg_temp.erro('sem_permissao', 'operador_id'),
  'recusa operador que não pertence à Equipe Frila (privado.conta_equipe)'
);

select throws_ok(
  $$ select privado.anular_falta(gen_random_uuid(), 'Justificativa válida completa', '86200000-0000-4000-8000-000000000001'::uuid, gen_random_uuid()) $$,
  'PGRST', pg_temp.erro('nao_encontrado', 'ocorrencia_origem_id'),
  'recusa ocorrencia_origem_id inexistente'
);

-- ── 4. Validações de Estado da Posição ────────────────────────────────────────

select throws_ok(
  $$ select privado.anular_falta(gen_random_uuid(), 'Justificativa válida completa', '86200000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST', pg_temp.erro('nao_encontrado', 'posicao_id'),
  'recusa posicao_id inexistente'
);

create temp table posicoes_teste as
select
  (select pg_temp.criar_turno_verificado((select estab_id from ids), (select prof_id from ids))) as pos_cumprida,
  (select pg_temp.criar_posicao_aberta((select estab_id from ids))) as pos_aberta,
  (select pg_temp.criar_posicao_sem_falta((select estab_id from ids), (select prof_id from ids))) as pos_sem_falta,
  (select pg_temp.criar_posicao_com_falta((select estab_id from ids), (select prof_id from ids))) as pos_falta_1,
  (select pg_temp.criar_posicao_com_falta((select estab_id from ids), (select prof_id from ids))) as pos_falta_2;

select throws_ok(
  format($$ select privado.anular_falta(%L::uuid, 'Justificativa válida completa', '86200000-0000-4000-8000-000000000001'::uuid) $$, (select pos_aberta from posicoes_teste)),
  'PGRST', pg_temp.erro('posicao_nao_cancelada'),
  'recusa anular falta em posição aberta (não cancelada)'
);

select throws_ok(
  format($$ select privado.anular_falta(%L::uuid, 'Justificativa válida completa', '86200000-0000-4000-8000-000000000001'::uuid) $$, (select pos_sem_falta from posicoes_teste)),
  'PGRST', pg_temp.erro('falta_inexistente'),
  'só falta=true anula: recusa anular falta em posição que nunca teve falta'
);

-- ── 5. Execução com Sucesso: Anulação, Recálculo da Taxa e Auditoria ──────────

-- Taxa inicial: 1 cumprido e 2 faltas = 1 / (1 + 2) = 0.333
select is(
  (select taxa_comparecimento from public.profissional where id = (select prof_id from ids)),
  0.333::numeric,
  'taxa de comparecimento inicial reflete 1 cumprido e 2 faltas (0.333)'
);

-- Cria chamado de suporte de origem para pos_falta_1
create temp table chamado_origem as
with ins as (
  insert into public.ocorrencia (
    tipo, posicao_id, usuario_id, autor_id, motivo, criada_em
  ) values (
    'suporte',
    (select pos_falta_1 from posicoes_teste),
    (select user_prof from ids),
    (select user_prof from ids),
    'Atraso por pane no transporte público comprovado por bilhete',
    '2026-11-13 14:00:00-03'
  ) returning id
)
select id from ins;

-- Executa a anulação da pos_falta_1
create temp table res_anulacao_1 as
select privado.anular_falta(
  (select pos_falta_1 from posicoes_teste),
  'Contestação acolhida com comprovação do transporte',
  (select user_operador from ids),
  (select id from chamado_origem)
) as resultado;

-- 1. Verifica retorno JSON
select is(
  ((select resultado from res_anulacao_1)->>'falta_anulada')::boolean,
  true,
  'resultado JSON indica falta_anulada true'
);

select is(
  ((select resultado from res_anulacao_1)->>'ja_estava_anulada')::boolean,
  false,
  'resultado JSON indica ja_estava_anulada false na 1ª execução'
);

-- 2. Verifica public.posicao alterada
select is(
  (select falta from public.posicao where id = (select pos_falta_1 from posicoes_teste)),
  false,
  'posicao.falta foi alterada para false'
);

-- 3. Verifica auditoria gravada em privado.anulacao_falta (inacessível a clientes)
select is(
  (select operador_id from privado.anulacao_falta where posicao_id = (select pos_falta_1 from posicoes_teste)),
  (select user_operador from ids),
  'privado.anulacao_falta.operador_id registra o operador da Equipe Frila'
);

select is(
  (select motivo from privado.anulacao_falta where posicao_id = (select pos_falta_1 from posicoes_teste)),
  'Contestação acolhida com comprovação do transporte',
  'privado.anulacao_falta.motivo registra a justificativa limpa'
);

select is(
  (select ocorrencia_origem_id from privado.anulacao_falta where posicao_id = (select pos_falta_1 from posicoes_teste)),
  (select id from chamado_origem),
  'privado.anulacao_falta.ocorrencia_origem_id vincula o chamado de suporte'
);

-- 4. A taxa muda: agora são 1 cumprido e 1 falta = 1 / (1 + 1) = 0.500
select is(
  (select taxa_comparecimento from public.profissional where id = (select prof_id from ids)),
  0.500::numeric,
  'a taxa muda: recalculada para 0.500 após anulação de 1 falta'
);

-- 5. Ocorrência de auditoria gravada
select is(
  (select count(*)::int from public.ocorrencia
    where posicao_id = (select pos_falta_1 from posicoes_teste)
      and autor_id = (select user_operador from ids)
      and tipo = 'suporte'
      and motivo like 'Anulação de falta operacional:%'),
  1,
  'ocorrência de auditoria gravada para o operador com tipo suporte'
);

-- 6. Chamado de suporte de origem foi resolvido
select ok(
  (select resolvido_em is not null and resultado like 'Falta anulada pela Equipe Frila:%'
     from public.ocorrencia where id = (select id from chamado_origem)),
  'chamado de suporte de origem foi marcado como resolvido com resultado de anulação'
);

-- ── 6. Idempotência ───────────────────────────────────────────────────────────

create temp table res_anulacao_idempotente as
select privado.anular_falta(
  (select pos_falta_1 from posicoes_teste),
  'Tentativa repetida de anulação pelo mesmo operador',
  (select user_operador from ids),
  (select id from chamado_origem)
) as resultado;

select is(
  ((select resultado from res_anulacao_idempotente)->>'ja_estava_anulada')::boolean,
  true,
  'segunda chamada é idempotente e devolve ja_estava_anulada true'
);

select is(
  (select count(*)::int from public.ocorrencia
    where posicao_id = (select pos_falta_1 from posicoes_teste)
      and autor_id = (select user_operador from ids)
      and tipo = 'suporte'
      and motivo like 'Anulação de falta operacional:%'),
  1,
  'idempotência: não duplica ocorrência de auditoria'
);

select is(
  (select count(*)::int from privado.anulacao_falta
    where posicao_id = (select pos_falta_1 from posicoes_teste)),
  1,
  'idempotência: não duplica registro em privado.anulacao_falta'
);

select is(
  (select taxa_comparecimento from public.profissional where id = (select prof_id from ids)),
  0.500::numeric,
  'idempotência: taxa de comparecimento permanece inalterada em 0.500'
);

-- ── 7. Anulação sem Chamado de Origem (4º Parâmetro Opcional) ─────────────────

create temp table res_anulacao_2 as
select privado.anular_falta(
  (select pos_falta_2 from posicoes_teste),
  'Anulação direta por revisão interna sem chamado',
  (select user_operador from ids)
) as resultado;

select is(
  ((select resultado from res_anulacao_2)->>'falta_anulada')::boolean,
  true,
  'anulação sem chamado de origem devolve falta_anulada true'
);

select is(
  (select falta from public.posicao where id = (select pos_falta_2 from posicoes_teste)),
  false,
  'pos_falta_2 teve falta alterada para false'
);

-- Agora que ambas as faltas foram anuladas, taxa = 1 cumprido / (1 + 0 faltas) = 1.000
select is(
  (select taxa_comparecimento from public.profissional where id = (select prof_id from ids)),
  1.000::numeric,
  'taxa de comparecimento atinge 1.000 com todas as faltas anuladas'
);

-- ── 8. Blindagem e Sigilo: Clientes (Profissional e Casa) não Leem Motivo/Operador ─

-- Teste que o Trovão utilizou na reprovação: comprova que sob authenticated,
-- nem profissional nem contratante conseguem ler motivo ou operador de anulação.
select throws_ok(
  format($$ select pg_temp.como_usuario(%L::uuid, 'select motivo, operador_id from privado.anulacao_falta') $$, (select user_prof from ids)),
  '42501',
  null,
  'profissional authenticated não consegue ler motivo nem operador de privado.anulacao_falta (42501)'
);

select throws_ok(
  format($$ select pg_temp.como_usuario(%L::uuid, 'select motivo, operador_id from privado.anulacao_falta') $$, (select user_dono from ids)),
  '42501',
  null,
  'casa contratante authenticated não consegue ler motivo nem operador de privado.anulacao_falta (42501)'
);

select * from finish();
rollback;
