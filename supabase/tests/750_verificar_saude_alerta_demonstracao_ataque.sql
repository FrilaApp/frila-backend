-- Teste pgTAP: Alerta operacional 'demonstracao_sob_ataque' em privado.verificar_saude() (Item 19)
-- Vigia tentativas recusadas em public.entrada_demonstracao nos últimos 15 minutos.
-- Teto: >= 10 tentativas recusadas dispara alerta estruturado. Menos de 10 não dispara.

begin;
select plan(7);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- Congela relógio do produto e segredo do agendador
select set_config('frila.agora', '2026-10-20 10:00:00-03', true);
select set_config('frila.agendador_secret', 'segredo-de-teste-750', true);

-- Limpa estado inicial
delete from public.entrada_demonstracao;
delete from privado.alerta_emitido;
delete from pgmq.q_email;

-- ── 1. Cenário Base: Menos de 10 tentativas recusadas (< 10) ─────────────────
-- Insere 9 tentativas recusadas dentro da janela de 15 minutos
insert into public.entrada_demonstracao (email, aceita, em)
select 'revisor@apple.com', false, privado.agora() - (g || ' minutes')::interval
  from generate_series(1, 9) as g;

-- Insere também tentativas fora da janela (> 15 min) e tentativas aceitas (aceita = true)
insert into public.entrada_demonstracao (email, aceita, em)
values 
  ('revisor@apple.com', false, privado.agora() - interval '20 minutes'),
  ('revisor@apple.com', false, privado.agora() - interval '30 minutes'),
  ('revisor@apple.com', true, privado.agora() - interval '2 minutes');

-- Executa verificar_saude
select privado.verificar_saude();

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'demonstracao_sob_ataque'),
  0,
  'Não dispara demonstracao_sob_ataque quando há menos de 10 tentativas recusadas na janela recente'
);

select is(
  (select count(*)::int from pgmq.q_email where (message->>'codigo') = 'demonstracao_sob_ataque'),
  0,
  'Nenhum e-mail de alerta de demonstração sob ataque é enfileirado abaixo do teto'
);

-- ── 2. Cenário de Disparo: >= 10 tentativas recusadas na janela ──────────────
-- Insere a 10ª tentativa recusada recente
insert into public.entrada_demonstracao (email, aceita, em)
values ('revisor@apple.com', false, privado.agora() - interval '1 minute');

-- Executa verificar_saude
select privado.verificar_saude();

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'demonstracao_sob_ataque'),
  1,
  'Dispara demonstracao_sob_ataque quando atinge >= 10 tentativas recusadas na janela recente'
);

select is(
  (select count(*)::int from pgmq.q_email where (message->>'codigo') = 'demonstracao_sob_ataque'),
  1,
  'Alerta demonstracao_sob_ataque foi colocado na fila pgmq email'
);

-- Valida payload estruturado
select is(
  (select (message->'detalhes'->>'tentativas_recusadas_15min')::int from pgmq.q_email where (message->>'codigo') = 'demonstracao_sob_ataque' limit 1),
  10,
  'Payload estruturado contém tentativas_recusadas_15min = 10'
);

select is(
  (select (message->'detalhes'->>'teto')::int from pgmq.q_email where (message->>'codigo') = 'demonstracao_sob_ataque' limit 1),
  10,
  'Payload estruturado contém teto = 10'
);

-- ── 3. Cenário Rate-Limit: Segundo verificar_saude na mesma hora suprime ─────
-- Insere mais uma tentativa para elevar para 11
insert into public.entrada_demonstracao (email, aceita, em)
values ('revisor@apple.com', false, privado.agora());

select privado.verificar_saude();

select is(
  (select suprimidos from privado.alerta_emitido where codigo = 'demonstracao_sob_ataque'),
  1,
  'Segundo alerta dentro de 1 hora tem envio suprimido pelo rate limit de emitir_alerta'
);

select * from finish();
rollback;
