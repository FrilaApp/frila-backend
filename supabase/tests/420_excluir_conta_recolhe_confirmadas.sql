-- Gatilho de vaga cancelada no caminho de serviço de excluir_conta (CPD2c74A, RNF14, RF25).
--
-- No caminho de serviço de `privado.excluir_conta(p_usuario_id)` (sem JWT), `auth.uid()`
-- é nulo. A migração 20260929153712 saía cedo quando `auth.uid()` era nulo. Se uma
-- candidatura confirmava uma posição no meio da exclusão de conta (após a varredura
-- inicial de confirmadas, mas antes de `update vaga set estado = 'cancelada'`), a
-- posição sobrava confirmada numa vaga cancelada.
--
-- A correção (opção A):
--   · `privado.excluir_conta` sinaliza o autor da exclusão na transação
--     (`set_config('frila.autor_da_exclusao', v_uid::text, true)`), ao lado de
--     `frila.exclusao_de_conta`.
--   · O gatilho `privado.vaga_cancelada_recolhe_confirmadas` usa:
--     `coalesce((select auth.uid()), nullif(current_setting('frila.autor_da_exclusao', true), '')::uuid)`
--     e só sai cedo se ambos forem nulos.
--   · A posição confirmada é recolhida e cancelada sem falta (a flag de exclusão de
--     conta cobre).
--
-- Ids próprios, começando em `c5f00000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(10);

create function pg_temp.conta(id uuid, email text, perfil public.perfil_conta, fone text)
returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false);
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (id, perfil, 'Conta ' || email, fone, email,
          case when perfil = 'contratante' then date '1980-01-01' else date '1995-01-01' end,
          '2026-09-22', now());
end $$;

select pg_temp.conta('c5f00000-0000-4000-8000-0000000000d1', 'dona@excluir-recolhe.test',
                     'contratante', '+5561955550001');
select pg_temp.conta('c5f00000-0000-4000-8000-0000000000e1', 'prof1@excluir-recolhe.test',
                     'profissional', '+5561955550011');

insert into public.profissional (id, usuario_id, ponto_base)
values ('c5f00000-0000-4000-8000-0000000000f1', 'c5f00000-0000-4000-8000-0000000000e1',
        'POINT(-47.8850 -15.7900)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ('c5f00000-0000-4000-8000-0000000000c1', 'Casa Excluída', '55443322000434',
        'food_service', 'SCLN 309', 'POINT(-47.8860 -15.7910)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c5f00000-0000-4000-8000-0000000000d1', 'c5f00000-0000-4000-8000-0000000000c1',
        'administrador');

-- Vaga da casa que será excluída via serviço (sem JWT)
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, estado,
                         chave_cliente, publicado_por)
values ('c5f00000-0000-4000-8000-0000000000a1', 'c5f00000-0000-4000-8000-0000000000c1',
        (select id from public.funcao where nome = 'garçom'),
        now() + interval '12 hours', now() + interval '18 hours',
        'SCLN 309', 'POINT(-47.8860 -15.7910)'::extensions.geography,
        18000, 1, true, true, false, 'Seu Zé', 'urgencia', 'publicada',
        gen_random_uuid(), 'c5f00000-0000-4000-8000-0000000000d1');

-- Posição começa aberta
insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado)
values ('c5f00000-0000-4000-8000-0000000000b1', 'c5f00000-0000-4000-8000-0000000000a1',
        now() + interval '12 hours', now() + interval '18 hours', 'aberta');

-- Gatilho de simulação de corrida: quando excluir_conta atualiza as posições abertas
-- para canceladas, a candidatura chega exatamente ali, confirma a posição e cria o turno.
create function public.teste_candidato_chega_no_meio_da_exclusao() returns trigger
language plpgsql as $$
begin
  if old.id = 'c5f00000-0000-4000-8000-0000000000b1'
     and old.estado = 'aberta' and new.estado = 'cancelada' then
    update public.posicao
       set estado = 'confirmada',
           profissional_id = 'c5f00000-0000-4000-8000-0000000000f1',
           confirmado_em = now()
     where id = old.id;
    insert into public.candidatura (posicao_id, profissional_id, estado)
    values (old.id, 'c5f00000-0000-4000-8000-0000000000f1', 'aceita');
    insert into public.turno (posicao_id, valor_acordado_centavos)
    values (old.id, 18000);
    return null;
  end if;
  return new;
end $$;

create trigger teste_candidato_chega_no_meio_da_exclusao
  before update of estado on public.posicao
  for each row execute function public.teste_candidato_chega_no_meio_da_exclusao();

-- ── Execução de excluir_conta no caminho de serviço (sem JWT) ────────────────
-- auth.uid() é nulo, simulate service role call:
select lives_ok(
  $$ select privado.excluir_conta('c5f00000-0000-4000-8000-0000000000d1'::uuid) $$,
  'excluir_conta via serviço executa com sucesso');

-- Asserções:
-- 1. A vaga foi cancelada
select is(
  (select estado::text from public.vaga where id = 'c5f00000-0000-4000-8000-0000000000a1'),
  'cancelada',
  'a vaga do único membro foi cancelada');

-- 2. A posição que confirmou no meio NÃO sobra confirmada
select is(
  (select estado::text from public.posicao where id = 'c5f00000-0000-4000-8000-0000000000b1'),
  'cancelada',
  'a posição confirmada no meio do caminho de serviço é recolhida e cancelada');

-- 3. Nenhuma posição aberta ou confirmada na vaga cancelada
select is(
  (select count(*)::int from public.posicao
    where vaga_id = 'c5f00000-0000-4000-8000-0000000000a1'
      and estado in ('aberta', 'confirmada')),
  0,
  'nenhuma posição viva sobra na vaga cancelada');

-- 4. O turno fica como nao_verificado
select is(
  (select verificacao::text from public.turno where posicao_id = 'c5f00000-0000-4000-8000-0000000000b1'),
  'nao_verificado',
  'o turno é marcado como nao_verificado');

-- 5. Sem falta para o profissional (RN12)
select is(
  (select falta from public.posicao where id = 'c5f00000-0000-4000-8000-0000000000b1'),
  false,
  'o cancelamento na exclusão de conta não gera falta para o profissional (RN12)');

-- 6. Ocorrência gravada com autor_id = conta excluída e motivo vaga_cancelada
select ok(
  exists (
    select 1 from public.ocorrencia o
     where o.posicao_id = 'c5f00000-0000-4000-8000-0000000000b1'
       and o.tipo = 'cancelamento'
       and o.motivo = 'vaga_cancelada'
       and o.autor_id = 'c5f00000-0000-4000-8000-0000000000d1'
       and o.usuario_id = 'c5f00000-0000-4000-8000-0000000000e1'
  ),
  'ocorrência de cancelamento registra a conta excluída como autora e o profissional como afetado');

-- 7. Profissional notificado do cancelamento sem reabertura
select ok(
  exists (
    select 1 from public.notificacao n
     where n.usuario_id = 'c5f00000-0000-4000-8000-0000000000e1'
       and n.tipo = 'cancelamento'
       and n.referencia_id = 'c5f00000-0000-4000-8000-0000000000b1'
       and n.payload @> '{"reaberta": false}'
  ),
  'profissional recebe notificação de cancelamento com reaberta = false');

-- 8. Conta contratante anonimizada
select is(
  (select estado::text from public.usuario where id = 'c5f00000-0000-4000-8000-0000000000d1'),
  'anonimizada',
  'a conta do contratante foi anonimizada');

-- 9. Sem JWT e sem frila.autor_da_exclusao, gatilho continua saindo cedo sem erro
-- (como provado em 380 linha 223)
drop trigger teste_candidato_chega_no_meio_da_exclusao on public.posicao;

insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, estado,
                         chave_cliente, publicado_por)
values ('c5f00000-0000-4000-8000-0000000000a2', 'c5f00000-0000-4000-8000-0000000000c1',
        (select id from public.funcao where nome = 'garçom'),
        now() + interval '2 days', now() + interval '2 days 6 hours',
        'SCLN 309', 'POINT(-47.8860 -15.7910)'::extensions.geography,
        18000, 1, true, true, false, 'Seu Zé', 'urgencia', 'publicada',
        gen_random_uuid(), 'c5f00000-0000-4000-8000-0000000000d1');

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em)
values ('c5f00000-0000-4000-8000-0000000000b2', 'c5f00000-0000-4000-8000-0000000000a2',
        now() + interval '2 days', now() + interval '2 days 6 hours', 'confirmada',
        'c5f00000-0000-4000-8000-0000000000f1', now());

-- Cancelamento direto da vaga sem JWT e sem autor_da_exclusao: gatilho sai cedo
update public.vaga set estado = 'cancelada' where id = 'c5f00000-0000-4000-8000-0000000000a2';

select is(
  (select estado::text from public.posicao where id = 'c5f00000-0000-4000-8000-0000000000b2'),
  'confirmada',
  'sem JWT e sem frila.autor_da_exclusao, gatilho sai cedo e preserva o comportamento anterior');

select * from finish();
rollback;
