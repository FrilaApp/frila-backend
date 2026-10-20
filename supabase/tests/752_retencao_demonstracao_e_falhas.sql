-- Teste de retenção operacional: purga de entrada_demonstracao (> 30d) e falha_execucao (> 60d)
-- em privado.higienizar_tabelas() (Achados 5 e 6 da caçada de ciclo de vida).

begin;
select plan(4);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agendador_secret = 'segredo-de-teste';
select set_config('frila.agora', '2027-07-01 12:00:00+00', true);

-- ── 1. Cenário: public.entrada_demonstracao ─────────────────────────────────────
-- Linha antiga (> 30 dias) e linha recente (< 30 dias)
insert into public.entrada_demonstracao (email, aceita, em) values
  ('revisao-antiga@frila.app', true, privado.agora() - interval '35 days'),
  ('revisao-recente@frila.app', true, privado.agora() - interval '10 days');

-- ── 2. Cenário: privado.falha_execucao ──────────────────────────────────────────
-- Linha antiga (> 60 dias) e linha recente (< 60 dias)
insert into privado.falha_execucao (origem, codigo, detalhes, criada_em) values
  ('edge_function_teste', 'falha_antiga', '{"info":"antigo"}'::jsonb, privado.agora() - interval '65 days'),
  ('edge_function_teste', 'falha_recente', '{"info":"recente"}'::jsonb, privado.agora() - interval '20 days');

-- Executa a rotina de higienização
select privado.higienizar_tabelas();

-- ── 3. Asserções ───────────────────────────────────────────────────────────────

-- Achado 5: entrada_demonstracao com mais de 30 dias deve ser purgada
select is(
  (select count(*)::int from public.entrada_demonstracao
    where em < privado.agora() - interval '30 days'),
  0,
  'entrada_demonstracao com mais de 30 dias é purgada por privado.higienizar_tabelas()'
);

select is(
  (select count(*)::int from public.entrada_demonstracao
    where em >= privado.agora() - interval '30 days'),
  1,
  'entrada_demonstracao recente (<= 30 dias) é preservada'
);

-- Achado 6: falha_execucao com mais de 60 dias deve ser purgada
select is(
  (select count(*)::int from privado.falha_execucao
    where criada_em < privado.agora() - interval '60 days'),
  0,
  'falha_execucao com mais de 60 dias é purgada por privado.higienizar_tabelas()'
);

select is(
  (select count(*)::int from privado.falha_execucao
    where criada_em >= privado.agora() - interval '60 days'),
  1,
  'falha_execucao recente (<= 60 dias) é preservada'
);

select * from finish();
rollback;
