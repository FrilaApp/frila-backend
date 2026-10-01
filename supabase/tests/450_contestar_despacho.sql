-- 450_contestar_despacho.sql
--
-- US27 (RF27, RN05, RN06, RN23, LGPD art. 20, cartão eaWhDeym)
-- Contestar o despacho ("Por que recebo vagas"):
--   1. Permissões de chamada (apenas authenticated; public e anon sem execute).
--   2. Recusas: não autenticado (401), perfil não profissional (422), conta suspensa (403),
--      relato nulo/vazio (422 campo_obrigatorio), relato < 10 caracteres (422 campo_invalido),
--      e texto ofensivo pela diretriz 1.2 (422 campo_invalido).
--   3. criterios_de_notificacao(): devolve CriteriosDeNotificacao com funcoes,
--      disponibilidades, distancia_maxima_km (15), equipes_de_confianca e
--      notificacoes_no_maximo_a_cada_min (30).
--   4. pedir_revisao_despacho(relato): grava public.ocorrencia com tipo revisao_despacho,
--      enfileira aviso na fila email do pgmq (sem relato nem dados pessoais, RN15),
--      e devolve Protocolo com prazo de resposta em até 5 dias úteis (privado.prazo_de_resposta).

begin;
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-01 12:00:00-03';
select plan(26);

create function pg_temp.como(conta uuid, sql text) returns jsonb
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

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

-- ── 1. Estrutura e privilégios ──────────────────────────────────────────────────

select ok(has_function_privilege('authenticated', 'public.criterios_de_notificacao()', 'execute'),
  'authenticated executa public.criterios_de_notificacao');
select ok(not has_function_privilege('anon', 'public.criterios_de_notificacao()', 'execute'),
  'anon não executa public.criterios_de_notificacao');

select ok(has_function_privilege('authenticated', 'public.pedir_revisao_despacho(text)', 'execute'),
  'authenticated executa public.pedir_revisao_despacho');
select ok(not has_function_privilege('anon', 'public.pedir_revisao_despacho(text)', 'execute'),
  'anon não executa public.pedir_revisao_despacho');

-- ── O Cenário ───────────────────────────────────────────────────────────────────
--
-- Prefixo `c7`
-- Usuários:
--   c70001: Paula (profissional garçom e bartender, com disponibilidade e equipe de confiança)
--   c70002: Tiago (contratante, admin do Restaurante do Tiago c70010)
--   c70003: Sara (profissional com conta suspensa)

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado) values
  ('c7000000-0000-4000-8000-000000000001', 'profissional', 'Paula', '+5561998880001', 'paula@c7.test', '1996-01-01', '2026-09-22', now(), 'ativa'),
  ('c7000000-0000-4000-8000-000000000002', 'contratante',  'Tiago', '+5561998880002', 'tiago@c7.test', '1985-01-01', '2026-09-22', now(), 'ativa'),
  ('c7000000-0000-4000-8000-000000000003', 'profissional', 'Sara',  '+5561998880003', 'sara@c7.test',  '1997-01-01', '2026-09-22', now(), 'suspensa');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('c7000000-0000-4000-8000-000000000010', 'Restaurante do Tiago', '52141555000190', 'food_service', 'CLS 302',
   'POINT(-47.8900 -15.8000)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('c7000000-0000-4000-8000-000000000002', 'c7000000-0000-4000-8000-000000000010', 'administrador');

insert into public.profissional (id, usuario_id, ponto_base) values
  ('c7000000-0000-4000-8000-000000000014', 'c7000000-0000-4000-8000-000000000001', 'POINT(-47.8800 -15.7900)'::extensions.geography),
  ('c7000000-0000-4000-8000-000000000015', 'c7000000-0000-4000-8000-000000000003', 'POINT(-47.8800 -15.7900)'::extensions.geography);

-- Funções da Paula: garçom e bartender (ativas), e sommelier (inativa)
insert into public.funcao (id, nome, categoria, ativo) values
  ('c7000000-0000-4000-8000-000000000099', 'sommelier', 'atendimento', false);

insert into public.profissional_funcao (profissional_id, funcao_id)
select 'c7000000-0000-4000-8000-000000000014'::uuid, id
  from public.funcao
 where nome in ('garçom', 'bartender', 'sommelier');

-- Disponibilidade da Paula: sexta e sábado, 18:00 às 23:59
insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim) values
  ('c7000000-0000-4000-8000-000000000014', 5, '18:00'::time, '23:59'::time),
  ('c7000000-0000-4000-8000-000000000014', 6, '18:00'::time, '23:59'::time);

-- Equipe de confiança: Paula pertence à equipe do Restaurante do Tiago
insert into public.equipe_confianca (estabelecimento_id, profissional_id, adicionado_em) values
  ('c7000000-0000-4000-8000-000000000010', 'c7000000-0000-4000-8000-000000000014', now());

-- Garante que a fila email existe (pode ter nascido em 20260929100000 ou posterior)
do $$
begin
  if not exists (select 1 from pgmq.meta where queue_name = 'email') then
    perform pgmq.create('email');
  end if;
end $$;

-- ── 2. Recusas ──────────────────────────────────────────────────────────────────

-- Sem token: 401
select throws_ok(
  $$ select public.criterios_de_notificacao() $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'criterios_de_notificacao sem token é 401');

select throws_ok(
  $$ select public.pedir_revisao_despacho('Relato válido com mais de dez caracteres.') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'pedir_revisao_despacho sem token é 401');

-- Perfil incompatível: contratante tentando acessar endpoint exclusivo de profissional
select throws_ok(
  $$ select pg_temp.como('c7000000-0000-4000-8000-000000000002',
     'select public.criterios_de_notificacao()') $$,
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'contratante não acessa criterios_de_notificacao (422)');

select throws_ok(
  $$ select pg_temp.como('c7000000-0000-4000-8000-000000000002',
     'select public.pedir_revisao_despacho(''Contestação legítima de mais de dez caracteres'')') $$,
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'contratante não chama pedir_revisao_despacho (422)');

-- Conta suspensa: 403 conta_suspensa
select throws_ok(
  $$ select pg_temp.como('c7000000-0000-4000-8000-000000000003',
     'select public.pedir_revisao_despacho(''Relato de conta suspensa tentando contestar'')') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'conta suspensa não pede revisão de despacho (403 conta_suspensa)');

-- Relato nulo ou vazio: 422 campo_obrigatorio
select throws_ok(
  $$ select pg_temp.como('c7000000-0000-4000-8000-000000000001',
     'select public.pedir_revisao_despacho(null)') $$,
  'PGRST', pg_temp.erro('campo_obrigatorio', 'relato'),
  'relato nulo é 422 campo_obrigatorio');

select throws_ok(
  $$ select pg_temp.como('c7000000-0000-4000-8000-000000000001',
     'select public.pedir_revisao_despacho(''   '')') $$,
  'PGRST', pg_temp.erro('campo_obrigatorio', 'relato'),
  'relato em branco é 422 campo_obrigatorio');

-- Relato menor que 10 caracteres: 422 campo_invalido
select throws_ok(
  $$ select pg_temp.como('c7000000-0000-4000-8000-000000000001',
     'select public.pedir_revisao_despacho(''curto'')') $$,
  'PGRST', pg_temp.erro('campo_invalido', 'relato'),
  'relato com menos de 10 caracteres é 422 campo_invalido');

-- Texto ofensivo (Diretriz 1.2 da App Store)
select throws_ok(
  $$ select pg_temp.como('c7000000-0000-4000-8000-000000000001',
     'select public.pedir_revisao_despacho(''Texto longo o suficiente mas com babaca nele'')') $$,
  'PGRST', pg_temp.erro('campo_invalido', 'relato'),
  'relato com termo ofensivo é 422 campo_invalido');

-- ── 3. Caminho feliz: criterios_de_notificacao ──────────────────────────────────

create temp table res_crit as select
  pg_temp.como('c7000000-0000-4000-8000-000000000001',
               'select public.criterios_de_notificacao()') as c;

select is(
  ((select c from res_crit)->>'distancia_maxima_km')::int,
  15,
  'distancia_maxima_km é 15 (RN05)');

select is(
  ((select c from res_crit)->>'notificacoes_no_maximo_a_cada_min')::int,
  30,
  'notificacoes_no_maximo_a_cada_min é 30 (RN23)');

select is(
  jsonb_array_length((select c from res_crit)->'funcoes'),
  2,
  'funcoes retorna apenas as 2 funções ativas da Paula');

select ok(
  not exists (
    select 1
      from jsonb_array_elements((select c from res_crit)->'funcoes') f
     where f->>'nome' = 'sommelier'
  ),
  'função inativa não aparece em criterios_de_notificacao');

select is(
  jsonb_array_length((select c from res_crit)->'disponibilidades'),
  2,
  'disponibilidades retorna as 2 janelas cadastradas da Paula');

select is(
  ((select c from res_crit)->'equipes_de_confianca'->0->>'nome'),
  'Restaurante do Tiago',
  'equipes_de_confianca traz o nome do estabelecimento');

select is(
  ((select c from res_crit)->'equipes_de_confianca'->0->>'estabelecimento_id'),
  'c7000000-0000-4000-8000-000000000010',
  'equipes_de_confianca traz o ID do estabelecimento');

-- ── 4. Caminho feliz: pedir_revisao_despacho ───────────────────────────────────

create temp table res_rev as select
  pg_temp.como('c7000000-0000-4000-8000-000000000001',
    'select public.pedir_revisao_despacho(''Mudei de bairro e acho que o ponto base nao atualizou no despacho'')') as p;

select is(
  ((select p from res_rev)->>'tipo'),
  'revisao_despacho',
  'protocolo retornado tem tipo revisao_despacho');

select ok(
  ((select p from res_rev)->>'ocorrencia_id') is not null,
  'protocolo contém ocorrencia_id');

select is(
  ((select p from res_rev)->>'prazo_resposta_ate'),
  to_char(privado.prazo_de_resposta(privado.agora()), 'YYYY-MM-DD'),
  'prazo_resposta_ate é calculado com 5 dias úteis');

-- Verifica persistência na tabela ocorrencia
select is(
  (select count(*)::int from public.ocorrencia
    where id = ((select p from res_rev)->>'ocorrencia_id')::uuid
      and autor_id = 'c7000000-0000-4000-8000-000000000001'
      and tipo = 'revisao_despacho'
      and motivo = 'revisao_despacho'
      and relato = 'Mudei de bairro e acho que o ponto base nao atualizou no despacho'),
  1,
  'ocorrência gravada com autor, tipo, motivo e relato corretos');

-- Verifica enfileiramento na fila email do pgmq sem dados pessoais (RN15)
select is(
  (select count(*)::int from pgmq.q_email
    where message->>'tipo' = 'revisao_despacho'
      and message->>'ocorrencia_id' = ((select p from res_rev)->>'ocorrencia_id')),
  1,
  'mensagem enfileirada na fila email com tipo e ocorrencia_id (sem relato nem dados pessoais)');

select is(
  (select message from pgmq.q_email
    where message->>'ocorrencia_id' = ((select p from res_rev)->>'ocorrencia_id')),
  jsonb_build_object(
    'tipo',          'revisao_despacho',
    'ocorrencia_id', ((select p from res_rev)->>'ocorrencia_id')
  ),
  'o payload da fila email contém exatamente tipo e ocorrencia_id (sem relato nem dados pessoais, RN15)');

select * from finish();
rollback;
