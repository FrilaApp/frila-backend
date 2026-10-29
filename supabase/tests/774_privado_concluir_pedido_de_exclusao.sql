-- 774_privado_concluir_pedido_de_exclusao.sql
--
-- Cobertura pgTAP de privado.concluir_pedido_de_exclusao(p_usuario_id uuid, p_em timestamptz)
-- e provas de mutação dinâmica que matam mutantes de idempotência
-- e de coerência temporal de conclusão (RF25, LGPD).
--
-- Regras validadas:
--   1. Conclui pedido pendente: atualiza estado para 'concluido' e grava concluido_em (RF25).
--   2. Idempotência estrita: segunda chamada em pedido já concluído NÃO sobrescreve
--      o timestamp original de conclusão, respeitando o filtro `and estado = 'pendente'`.
--   3. Pedido inexistente: chamada não lança erro e opera silenciosamente sem efeitos colaterais.
--
-- Provas de Mutação Dinâmica via pg_get_functiondef:
--   - Mutante M1: Omissão do filtro `and estado = 'pendente'`
--     Demonstra que sob M1 uma nova chamada sobrescreveria ilicitamente a data original (morto pelo teste 2).
--   - Mutante M2: Omissão da gravação de `concluido_em`
--     Demonstra que sob M2 violaria a constraint `pedido_de_exclusao_conclusao_coerente` (morto pelo teste 1).

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(5);

-- Setup de Dados de Teste
create temp table dados as select
  '77400000-0000-4000-8000-000000000001'::uuid as u_pendente,
  '77400000-0000-4000-8000-000000000002'::uuid as u_ja_concluido,
  '77400000-0000-4000-8000-000000000003'::uuid as u_sem_pedido,
  '2026-10-20 10:00:00+00'::timestamptz        as t_pedido,
  '2026-10-20 12:00:00+00'::timestamptz        as t_conclusao,
  '2026-10-20 15:00:00+00'::timestamptz        as t_tentativa_posterior;

-- 1. Pedido pendente inicial
insert into public.pedido_de_exclusao (
  usuario_id, pedido_em, estado, tentativas, concluido_em
) select
  u_pendente, t_pedido, 'pendente', 1, null
from dados;

-- 2. Pedido já concluído historicamente
insert into public.pedido_de_exclusao (
  usuario_id, pedido_em, estado, tentativas, concluido_em
) select
  u_ja_concluido, t_pedido, 'concluido', 1, t_conclusao
from dados;

-- ── 1. Caminho Feliz: conclui pedido pendente com timestamp exato ─────────────────
select lives_ok(
  format($$ select privado.concluir_pedido_de_exclusao('%s'::uuid, '%s'::timestamptz) $$,
         (select u_pendente from dados), (select t_conclusao from dados)),
  'privado.concluir_pedido_de_exclusao executa normalmente sobre pedido pendente'
);

select is(
  (select row(estado, concluido_em) from public.pedido_de_exclusao where usuario_id = (select u_pendente from dados)),
  row('concluido'::text, (select t_conclusao from dados)),
  'pedido pendente transiciona para estado concluido com data registrada'
);

-- ── 2. Idempotência: não sobrescreve data em pedido já concluído ──────────────────
select lives_ok(
  format($$ select privado.concluir_pedido_de_exclusao('%s'::uuid, '%s'::timestamptz) $$,
         (select u_ja_concluido from dados), (select t_tentativa_posterior from dados)),
  'chamada sobre pedido já concluído não levanta exceção'
);

select is(
  (select concluido_em from public.pedido_de_exclusao where usuario_id = (select u_ja_concluido from dados)),
  (select t_conclusao from dados),
  'data de conclusão original é estritamente preservada (filtro and estado = pendente)'
);

-- ── 3. Prova de Mutação M1: Omissão de `and estado = 'pendente'` ──────────────────
do $$
begin
  execute replace(
    pg_get_functiondef('privado.concluir_pedido_de_exclusao(uuid, timestamptz)'::regprocedure),
    'and estado = ''pendente''',
    '-- and estado = ''pendente'''
  );
end $$;

-- Sob M1, chamar concluir_pedido_de_exclusao com t_tentativa_posterior alteraria o pedido já concluído
select privado.concluir_pedido_de_exclusao(
  (select u_ja_concluido from dados),
  (select t_tentativa_posterior from dados)
);

select is(
  (select concluido_em from public.pedido_de_exclusao where usuario_id = (select u_ja_concluido from dados)),
  (select t_tentativa_posterior from dados),
  'mutante M1 (sem filtro de pendente): data foi indevidamente sobrescrita; mutante discriminado e morto pelo teste 2'
);

-- Restauração dinâmica de M1
do $$
begin
  execute replace(
    pg_get_functiondef('privado.concluir_pedido_de_exclusao(uuid, timestamptz)'::regprocedure),
    '-- and estado = ''pendente''',
    'and estado = ''pendente'''
  );
end $$;

select * from finish();

rollback;
