-- O pedido de exclusão de conta deixa rastro mesmo quando a transação volta atrás
-- (cartão SHUDSozj, RF25, LGPD).
--
-- O que este arquivo protege, e por que ele não podia ser escrito de outro jeito:
--
-- `privado.excluir_conta` roda inteira numa transação só, e a Edge Function a chama num
-- único `select`. Quando ela bate em 40P01 — medido em 29/09, 6 de 50 rodadas do cenário 9
-- de `scripts/corrida-ciclo.sh` —, a transação volta atrás e leva junto qualquer linha que
-- a própria função tivesse escrito. O titular recebe erro e o sistema não guarda que ele
-- pediu a exclusão: não sobra nem referência para alguém reprocessar.
--
-- Nenhum arranjo dentro de **uma** transação resolve isso. Registrar no corpo da função e
-- reerguer o erro descarta o registro junto; engolir o erro devolveria sucesso sobre uma
-- exclusão que não aconteceu, que é pior. Por isso o registro é chamada própria,
-- `privado.registrar_pedido_de_exclusao`, que o chamador faz **antes** — como `denunciar`
-- faz ao enfileirar o e-mail.
--
-- Um teste pgTAP roda dentro de um `begin … rollback`, então ele não tem duas transações
-- para mostrar. O `savepoint` é o equivalente exato do que se quer provar: o registro fica
-- fora, a exclusão falha dentro, `rollback to savepoint` desfaz só a exclusão, e o que
-- sobra é o que sobraria de verdade.
--
-- Ids próprios, começando em `c6000000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(26);

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

select pg_temp.conta('c6000000-0000-4000-8000-0000000000d1', 'titular@rastro-exclusao.test',
                     'profissional', '+5561966660001');
select pg_temp.conta('c6000000-0000-4000-8000-0000000000d2', 'outro@rastro-exclusao.test',
                     'profissional', '+5561966660002');

insert into public.profissional (id, usuario_id, ponto_base)
values ('c6000000-0000-4000-8000-0000000000f1', 'c6000000-0000-4000-8000-0000000000d1',
        'POINT(-47.8850 -15.7900)'::extensions.geography);

-- ── A estrutura ───────────────────────────────────────────────────────────────

select has_table('public', 'pedido_de_exclusao',
                 'public.pedido_de_exclusao existe: o pedido tem onde morar');

select has_function('privado', 'registrar_pedido_de_exclusao', array['uuid'],
                    'privado.registrar_pedido_de_exclusao(uuid) existe');

select has_function('privado', 'pedidos_de_exclusao_pendentes', array[]::text[],
                    'privado.pedidos_de_exclusao_pendentes() existe');

-- RLS fechado: a tabela guarda que uma pessoa pediu para sair, e isso é dado pessoal.
select is(relrowsecurity, true, 'pedido_de_exclusao tem RLS ligado')
  from pg_class where oid = 'public.pedido_de_exclusao'::regclass;

select is((select count(*)::int from pg_policies
            where schemaname = 'public' and tablename = 'pedido_de_exclusao'
              and cmd in ('INSERT', 'UPDATE', 'DELETE')),
          0,
          'nenhuma política de escrita: quem escreve é função, nunca o app');

select is(has_table_privilege('authenticated', 'public.pedido_de_exclusao', 'select'), false,
          'authenticated não lê a tabela');
select is(has_table_privilege('anon', 'public.pedido_de_exclusao', 'select'), false,
          'anon não lê a tabela');

select is(has_function_privilege('authenticated',
            'privado.pedidos_de_exclusao_pendentes()', 'execute'), false,
          'authenticated não lista os pendentes');
select is(has_function_privilege('anon',
            'privado.registrar_pedido_de_exclusao(uuid)', 'execute'), false,
          'anon não registra pedido');
select is(has_function_privilege('service_role',
            'privado.registrar_pedido_de_exclusao(uuid)', 'execute'), true,
          'o caminho de serviço registra o pedido');

-- ── As restrições de integridade (CHECK) ──────────────────────────────────────

select throws_ok(
  $$ insert into public.pedido_de_exclusao (usuario_id, estado)
     values ('c6000000-0000-4000-8000-0000000000e1', 'invalido') $$,
  '23514', null,
  'pedido_de_exclusao_estado_conhecido: estado fora de pendente/concluido é recusado');

select throws_ok(
  $$ insert into public.pedido_de_exclusao (usuario_id, estado, concluido_em)
     values ('c6000000-0000-4000-8000-0000000000e2', 'concluido', null) $$,
  '23514', null,
  'pedido_de_exclusao_conclusao_coerente: concluido sem data de conclusão é recusado');

select throws_ok(
  $$ insert into public.pedido_de_exclusao (usuario_id, estado, concluido_em)
     values ('c6000000-0000-4000-8000-0000000000e3', 'pendente', now()) $$,
  '23514', null,
  'pedido_de_exclusao_conclusao_coerente: pendente com data de conclusão é recusado');

select throws_ok(
  $$ insert into public.pedido_de_exclusao (usuario_id, tentativas)
     values ('c6000000-0000-4000-8000-0000000000e4', 0) $$,
  '23514', null,
  'pedido_de_exclusao_tentativas_positivas: tentativas menor que 1 é recusado');

-- ── O registro, e a idempotência ──────────────────────────────────────────────

select lives_ok(
  $$select privado.registrar_pedido_de_exclusao('c6000000-0000-4000-8000-0000000000d1')$$,
  'registrar o pedido passa');

select is((select estado from public.pedido_de_exclusao
            where usuario_id = 'c6000000-0000-4000-8000-0000000000d1'),
          'pendente',
          'o pedido nasce pendente: ninguém excluiu nada ainda');

select privado.registrar_pedido_de_exclusao('c6000000-0000-4000-8000-0000000000d1');

select is((select count(*)::int from public.pedido_de_exclusao
            where usuario_id = 'c6000000-0000-4000-8000-0000000000d1'),
          1,
          'pedido repetido não cria segunda linha (idempotente por conta)');

select throws_ok(
  $$ insert into public.pedido_de_exclusao (usuario_id)
     values ('c6000000-0000-4000-8000-0000000000d1') $$,
  '23505',
  null,
  'pedido_de_exclusao_usuario_id_key: duplicar usuario_id viola unicidade');

select is((select tentativas from public.pedido_de_exclusao
            where usuario_id = 'c6000000-0000-4000-8000-0000000000d1'),
          2,
          'mas a segunda chamada conta como tentativa: quem insiste aparece');

-- Conta que nunca chegou a public.usuario é o caminho de retorno antecipado de
-- excluir_conta. O pedido dela tem de existir igual, então a coluna não tem FK.
select lives_ok(
  $$select privado.registrar_pedido_de_exclusao('c6000000-0000-4000-8000-00000000dead')$$,
  'conta que não chegou a public.usuario também deixa pedido registrado');

-- ── O rastro sobrevive ao rollback ────────────────────────────────────────────
--
-- O savepoint é a fronteira de transação que o teste não tem. O registro ficou fora dele;
-- a exclusão falha dentro; `rollback to savepoint` desfaz só a exclusão.

savepoint antes_da_exclusao;

select throws_ok(
  $$select privado.excluir_conta('c6000000-0000-4000-8000-0000000000d1'),
           1 / (select 0)$$,
  '22012',
  NULL,
  'a exclusão aborta no meio, como aborta no impasse 40P01');

rollback to savepoint antes_da_exclusao;

select is((select count(*)::int from public.pedido_de_exclusao
            where usuario_id = 'c6000000-0000-4000-8000-0000000000d1'),
          1,
          'depois do rollback da exclusão o pedido continua ali: o rastro sobreviveu');

select is((select estado from public.pedido_de_exclusao
            where usuario_id = 'c6000000-0000-4000-8000-0000000000d1'),
          'pendente',
          'e continua pendente, porque a exclusão de fato não aconteceu');

select is((select count(*)::int from privado.pedidos_de_exclusao_pendentes()
            where usuario_id = 'c6000000-0000-4000-8000-0000000000d1'),
          1,
          'e aparece na lista de pendentes, que é o que torna o pedido recuperável');

-- ── A exclusão que conclui fecha o pedido ─────────────────────────────────────

select privado.excluir_conta('c6000000-0000-4000-8000-0000000000d1');

select is((select estado from public.pedido_de_exclusao
            where usuario_id = 'c6000000-0000-4000-8000-0000000000d1'),
          'concluido',
          'exclusão que conclui marca o pedido como concluído');

select is((select count(*)::int from privado.pedidos_de_exclusao_pendentes()
            where usuario_id = 'c6000000-0000-4000-8000-0000000000d1'),
          0,
          'e ele sai da lista de pendentes');

select * from finish();
rollback;
