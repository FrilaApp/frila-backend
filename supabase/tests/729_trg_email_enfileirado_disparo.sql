-- Disparo assíncrono do processamento da fila de e-mails (RN15, RNF03).
--
-- Cobertura do gatilho `trg_email_enfileirado` e da função `privado.trg_disparar_email()`
-- (migração 20260927000000_emails_transacionais.sql).
--
-- Sempre que uma mensagem entra na fila `pgmq.q_email` (ex.: notificação transacional de ocorrência),
-- o gatilho AFTER INSERT dispara imediatamente a chamada HTTP assíncrona pós-commit via
-- `net.http_post` para acordar a Edge Function `enviar-email`.
--
-- Validação da auditoria de mutação dos triggers 14-23:
-- Os testes existentes (430 e 701) conferem apenas o catálogo `pg_trigger`. Se o corpo de
-- `privado.trg_disparar_email()` for mutado para um `RETURN NEW;` inerte, o disparo não
-- ocorre mas os testes anteriores não detectavam. Este teste fecha essa lacuna comprovando:
--
--   1. Existência, linguagem, SECURITY DEFINER e search_path="" de `privado.trg_disparar_email()`.
--   2. Controle de privilégios estrito (sem execução por anon/authenticated/public; service_role permitida).
--   3. Presença do gatilho ativo `trg_email_enfileirado` em `pgmq.q_email`.
--   4. Disparo observável: inserção em `pgmq.q_email` com `frila.agendador_secret` configurado enfileira
--      requisição em `net.http_request_queue` com método POST, URL, cabeçalhos, corpo e timeout corretos.
--   5. Comportamento defensivo com segredo ausente/vazio (não enfileira requisição mas preserva a mensagem).
--   6. Prova de mutação em transação: esvaziamento do corpo da função impede o enfileiramento da requisição HTTP.

begin;

select plan(21);

-- ── 1. Estrutura, catálogo e controle de acesso ─────────────────────────────

select has_function('privado', 'trg_disparar_email', array[]::text[],
  'privado.trg_disparar_email() existe');

select function_lang_is('privado', 'trg_disparar_email', array[]::text[], 'plpgsql',
  'trg_disparar_email é em plpgsql');

select is_definer('privado', 'trg_disparar_email', array[]::text[],
  'trg_disparar_email é SECURITY DEFINER');

select is(
  (select proconfig from pg_proc
    where proname = 'trg_disparar_email' and pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'trg_disparar_email possui search_path="" fixado'
);

select is(has_function_privilege('anon', 'privado.trg_disparar_email()', 'execute'), false,
  'anon não executa privado.trg_disparar_email');

select is(has_function_privilege('authenticated', 'privado.trg_disparar_email()', 'execute'), false,
  'authenticated não executa privado.trg_disparar_email');

select is(has_function_privilege('service_role', 'privado.trg_disparar_email()', 'execute'), true,
  'service_role pode executar privado.trg_disparar_email');

select is(
  (select count(*)::int from pg_trigger t
     join pg_class c on c.oid = t.tgrelid
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'pgmq' and c.relname = 'q_email'
      and t.tgname = 'trg_email_enfileirado' and not t.tgisinternal),
  1,
  'gatilho trg_email_enfileirado ativo em pgmq.q_email'
);

-- ── 2. Disparo determinístico com segredo configurado ────────────────────────

-- Isola as filas dentro do escopo da transação
delete from pgmq.q_email;
delete from net.http_request_queue;

set local frila.agendador_secret = 'segredo-deterministico-729';
set local frila.email_function_url = 'http://127.0.0.1:54321/functions/v1/enviar-email';

select lives_ok(
  $$ select pgmq.send('email', '{"ocorrencia_id": "72900000-0000-4000-8000-000000000001", "tipo": "alerta"}'::jsonb) $$,
  'com agendador_secret configurado, enfileiramento em q_email executa com sucesso'
);

select is(
  (select count(*)::int from net.http_request_queue),
  1,
  'gatilho trg_email_enfileirado gera exatamente 1 requisição em net.http_request_queue'
);

select is(
  (select method from net.http_request_queue order by id desc limit 1),
  'POST',
  'requisição disparada utiliza método POST'
);

select is(
  (select url from net.http_request_queue order by id desc limit 1),
  'http://127.0.0.1:54321/functions/v1/enviar-email',
  'requisição disparada aponta para URL de enviar-email configurada'
);

select is(
  (select headers->>'x-agendador-secret' from net.http_request_queue order by id desc limit 1),
  'segredo-deterministico-729',
  'cabeçalho x-agendador-secret contém segredo configurado'
);

select is(
  (select headers->>'Authorization' from net.http_request_queue order by id desc limit 1),
  'Bearer segredo-deterministico-729',
  'cabeçalho Authorization contém Bearer com segredo configurado'
);

select is(
  convert_from((select body from net.http_request_queue order by id desc limit 1), 'utf-8')::jsonb,
  '{"origem": "fila"}'::jsonb,
  'corpo da requisição contém {"origem": "fila"}'
);

select is(
  (select timeout_milliseconds from net.http_request_queue order by id desc limit 1),
  5000,
  'timeout_milliseconds configurado para 5000 ms'
);

-- ── 3. Comportamento defensivo com segredo ausente ───────────────────────────

delete from net.http_request_queue;
set local frila.agendador_secret = '';

select lives_ok(
  $$ select pgmq.send('email', '{"ocorrencia_id": "72900000-0000-4000-8000-000000000002", "tipo": "alerta"}'::jsonb) $$,
  'com segredo ausente, enfileiramento executa sem quebrar a transação'
);

select is(
  (select count(*)::int from net.http_request_queue),
  0,
  'com segredo ausente, nenhuma requisição HTTP é enfileirada em net.http_request_queue'
);

select is(
  (select count(*)::int from pgmq.q_email where (message->>'ocorrencia_id') = '72900000-0000-4000-8000-000000000002'),
  1,
  'mensagem permanece intacta na fila q_email para processamento posterior'
);

-- ── 4. Prova real de mutação do corpo da função ──────────────────────────────

-- Mutação M1: esvazia o corpo de trg_disparar_email() para provar que a asserção detecta
do $$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('privado.trg_disparar_email'::regproc);
  v_def := replace(v_def, 'perform privado.disparar_email();', '/* mutante removeu chamada */');
  execute v_def;
end;
$$;

delete from net.http_request_queue;
set local frila.agendador_secret = 'segredo-deterministico-729';

select pgmq.send('email', '{"ocorrencia_id": "72900000-0000-4000-8000-000000000003", "tipo": "mutante"}'::jsonb);

select is(
  (select count(*)::int from net.http_request_queue),
  0,
  'sob mutacao do corpo (RETURN NEW sem perform disparar_email), nenhuma requisicao entra em net.http_request_queue'
);

-- Restauração para comprovar reversibilidade e retorno do comportamento esperado
do $$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('privado.trg_disparar_email'::regproc);
  v_def := replace(v_def, '/* mutante removeu chamada */', 'perform privado.disparar_email();');
  execute v_def;
end;
$$;

delete from net.http_request_queue;

select pgmq.send('email', '{"ocorrencia_id": "72900000-0000-4000-8000-000000000004", "tipo": "restaurado"}'::jsonb);

select is(
  (select count(*)::int from net.http_request_queue),
  1,
  'apos restaurar funcao original, enfileiramento volta a gerar requisicao HTTP'
);

select * from finish();

rollback;
