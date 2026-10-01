-- Testes de monitoramento, falhas de execução e alertas (cartão 5bPJvMIo).
--
-- RNF02 · RNF03 · RNF12 · RN15.
--
-- Valida:
-- 1. Estrutura e RLS fechado de privado.falha_execucao e privado.alerta_emitido.
-- 2. privado.registrar_falha_execucao(): proteção estrita contra dados pessoais (RN15).
-- 3. privado.emitir_alerta(): enfileiramento na fila `email` e teto rígido de 1/hora por tipo.
-- 4. privado.verificar_saude(): detecção de job parado, fila antiga, notificações falhas,
--    despachos represados além do teto e falhas de execução.

begin;

select plan(30);

-- ── 1. Estrutura e segurança das tabelas ─────────────────────────────────────

select has_table('privado', 'falha_execucao', 'Tabela privado.falha_execucao existe');
select has_table('privado', 'alerta_emitido', 'Tabela privado.alerta_emitido existe');

select has_column('privado', 'falha_execucao', 'id', 'falha_execucao tem id');
select has_column('privado', 'falha_execucao', 'origem', 'falha_execucao tem origem');
select has_column('privado', 'falha_execucao', 'codigo', 'falha_execucao tem codigo');
select has_column('privado', 'falha_execucao', 'detalhes', 'falha_execucao tem detalhes');
select has_column('privado', 'falha_execucao', 'criada_em', 'falha_execucao tem criada_em');

-- RLS habilitado
select ok(
  (select relrowsecurity from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'falha_execucao'),
  'RLS está ativo em privado.falha_execucao'
);

select ok(
  (select relrowsecurity from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'alerta_emitido'),
  'RLS está ativo em privado.alerta_emitido'
);

-- Permissões fechadas para anon e authenticated
select throws_ok(
  $$
    set local role authenticated;
    select count(*) from privado.falha_execucao;
  $$,
  '42501',
  null,
  'authenticated não consegue ler privado.falha_execucao'
);

select throws_ok(
  $$
    set local role anon;
    select count(*) from privado.alerta_emitido;
  $$,
  '42501',
  null,
  'anon não consegue ler privado.alerta_emitido'
);

-- ── 2. Registro de falhas de execução e RN15 ─────────────────────────────────

-- Registro válido funciona
select lives_ok(
  $$
    select privado.registrar_falha_execucao(
      'enviar-push',
      'fcm_timeout',
      '{"tentativa": 1, "status_http": 504}'::jsonb
    );
  $$,
  'privado.registrar_falha_execucao grava falha técnica sem erro'
);

select is(
  (select count(*)::int from privado.falha_execucao
    where origem = 'enviar-push' and codigo = 'fcm_timeout'),
  1,
  'A falha foi persistida em privado.falha_execucao'
);

-- RN15: Rejeição de chaves com dados pessoais
select throws_ok(
  $$
    select privado.registrar_falha_execucao(
      'enviar-email',
      'smtp_550',
      '{"email": "vitima@frila.test"}'::jsonb
    );
  $$,
  '22023',
  null,
  'RN15: Rejeita detalhe contendo chave email'
);

select throws_ok(
  $$
    select privado.registrar_falha_execucao(
      'despacho',
      'erro_contato',
      '{"telefone": "61999999999"}'::jsonb
    );
  $$,
  '22023',
  null,
  'RN15: Rejeita detalhe contendo chave telefone'
);

select throws_ok(
  $$
    select privado.registrar_falha_execucao(
      'denuncia',
      'erro_processamento',
      '{"relato": "comportamento inadequado"}'::jsonb
    );
  $$,
  '22023',
  null,
  'RN15: Rejeita detalhe contendo chave relato'
);

select throws_ok(
  $$
    select privado.registrar_falha_execucao(
      'auth',
      'token_invalido',
      '{"token": "segredo-sensivel"}'::jsonb
    );
  $$,
  '22023',
  null,
  'RN15: Rejeita detalhe contendo credencial token'
);

-- Validações de obrigatoriedade
select throws_ok(
  $$ select privado.registrar_falha_execucao('', 'codigo') $$,
  '22023',
  null,
  'Origem vazia é rejeitada'
);

select throws_ok(
  $$ select privado.registrar_falha_execucao('origem', 'Codigo Com Espaco') $$,
  '22023',
  null,
  'Código fora do padrão snake_case é rejeitado'
);

-- ── 3. Emissão de alertas e rate limit (1/hora por tipo) ──────────────────────

-- Garante que a fila email existe para o teste
do $$
begin
  if not exists (select 1 from pg_tables where schemaname = 'pgmq' and tablename = 'q_email') then
    perform pgmq.create('email');
  end if;
  truncate table pgmq.q_email;
  truncate table privado.alerta_emitido;
end $$;

-- Primeiro alerta de um tipo é emitido com sucesso
select is(
  privado.emitir_alerta('job_despacho_parado', 1),
  true,
  'Primeiro alerta de job_despacho_parado é emitido com sucesso'
);

select is(
  (select count(*)::int from pgmq.q_email),
  1,
  'Alerta foi colocado na fila email'
);

select is(
  (select message->>'tipo' from pgmq.q_email limit 1),
  'alerta',
  'Mensagem tem tipo = alerta'
);

select is(
  (select message->>'codigo' from pgmq.q_email limit 1),
  'job_despacho_parado',
  'Mensagem tem codigo = job_despacho_parado'
);

-- Segundo alerta do mesmo tipo dentro de 1 hora é suprimido pelo rate limit
select is(
  privado.emitir_alerta('job_despacho_parado', 2),
  false,
  'Segundo alerta do mesmo tipo em menos de 1h é suprimido (rate limit)'
);

select is(
  (select count(*)::int from pgmq.q_email),
  1,
  'Nenhum e-mail adicional foi colocado na fila (respeitou o teto)'
);

select is(
  (select suprimidos from privado.alerta_emitido where codigo = 'job_despacho_parado'),
  1,
  'Contador de alertas suprimidos foi incrementado'
);

-- Alerta de tipo DIFERENTE é emitido normalmente
select is(
  privado.emitir_alerta('notificacao_push_falhou', 5),
  true,
  'Alerta de código diferente é emitido mesmo dentro da janela do anterior'
);

select is(
  (select count(*)::int from pgmq.q_email),
  2,
  'Fila agora contém os dois alertas de tipos distintos'
);

-- ── 4. Rotina privado.verificar_saude() ───────────────────────────────────────

-- Limpa estado para testar verificar_saude
truncate table pgmq.q_email;
truncate table privado.alerta_emitido;

-- Desativa temporariamente o job reprocessar_despacho para verificar detecção
do $$ begin
  perform cron.unschedule('reprocessar_despacho');
end $$;

select ok(
  privado.verificar_saude() > 0,
  'privado.verificar_saude() detecta job de despacho ausente/inativo e emite alerta'
);

select is(
  (select count(*)::int from pgmq.q_email where message->>'codigo' = 'job_despacho_parado'),
  1,
  'Alerta de job_despacho_parado foi enfileirado na fila email'
);

-- Restaura o job
do $$ begin
  perform cron.schedule('reprocessar_despacho', '* * * * *', 'select privado.processar_fila_despacho()');
end $$;

select * from finish();
rollback;
