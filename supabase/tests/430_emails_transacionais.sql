-- E-mails transacionais e a caixa da Equipe Frila (cartão 7yq1flLG · RF23, RF24, RF26,
-- RN13, RN15).
--
-- O Postgres não manda e-mail; o que se mede aqui é o lado do banco: o que a Edge
-- Function `enviar-email` consegue ler, o que ela consegue gravar, e — sobretudo — o que
-- ela **não** consegue nem ler nem gravar.
--
-- Duas asserções carregam a RN15 pela forma, e não pela boa vontade de quem escrever o
-- consumidor amanhã:
--
--   · `privado.dados_do_email` não devolve `relato`. O que a função não devolve não tem
--     como sair num e-mail por engano;
--   · `ocorrencia.email_ultimo_erro` só aceita `snake_case`. Um endereço, uma mensagem
--     do provedor com o destinatário dentro ou um pedaço de corpo são recusados pelo
--     `CHECK`, e não por uma revisão atenta.
--
-- Dados do cenário (`cenarios.sql`): Ana (a…01 / e…01) é profissional; o Bar do Cerrado
-- (c…01) é o alvo; Zélia (b…01) administra o bar.

begin;
select plan(57);

select set_config('frila.agora', '2026-09-29 11:00:00-03', true);

-- ── 1. A estrutura ────────────────────────────────────────────────────────────

select has_column('public', 'ocorrencia', 'email_equipe_em',
  'ocorrencia.email_equipe_em registra o envio à Equipe Frila');
select has_column('public', 'ocorrencia', 'email_autor_em',
  'ocorrencia.email_autor_em registra o protocolo enviado a quem abriu');
select has_column('public', 'ocorrencia', 'email_prazo_ate',
  'ocorrencia.email_prazo_ate congela o prazo comunicado');
select has_column('public', 'ocorrencia', 'email_tentativas',
  'ocorrencia.email_tentativas conta as recusas do provedor');
select has_column('public', 'ocorrencia', 'email_ultimo_erro',
  'ocorrencia.email_ultimo_erro guarda a classe do último erro');

-- Critério 3 do cartão, escrito como ausência: nenhuma coluna de `ocorrencia` serve para
-- guardar assunto ou corpo de e-mail. Se alguém acrescentar uma, este teste cai.
select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public' and table_name = 'ocorrencia'
      and column_name ~ '(assunto|corpo|html|mensagem|texto_email|email_corpo)'),
  0,
  'nenhuma coluna de ocorrencia guarda assunto ou corpo de e-mail (RN15)');

select has_function('privado', 'dados_do_email', array['uuid'],
  'privado.dados_do_email(uuid) existe');
select has_function('privado', 'ler_fila_email', array['integer', 'integer'],
  'privado.ler_fila_email(int, int) existe');
select has_function('privado', 'registrar_email_enviado', array['uuid', 'text', 'date'],
  'privado.registrar_email_enviado(uuid, text, date) existe');
select has_function('privado', 'registrar_falha_email', array['uuid', 'text'],
  'privado.registrar_falha_email(uuid, text) existe');
select has_function('privado', 'concluir_email', array['bigint'],
  'privado.concluir_email(bigint) existe');
select has_function('privado', 'disparar_email', array[]::text[],
  'privado.disparar_email() existe');

-- Nenhuma delas é alcançável pelo app: quem consome a fila é a Edge Function, com a
-- chave de serviço.
select is(
  (select bool_or(has_function_privilege('authenticated', f, 'execute'))
     from unnest(array[
       'privado.dados_do_email(uuid)',
       'privado.ler_fila_email(integer,integer)',
       'privado.registrar_email_enviado(uuid,text,date)',
       'privado.registrar_falha_email(uuid,text)',
       'privado.concluir_email(bigint)',
       'privado.disparar_email()'
     ]) f),
  false,
  'nenhuma função de e-mail é executável por authenticated');

select is(
  (select bool_and(has_function_privilege('service_role', f, 'execute'))
     from unnest(array[
       'privado.dados_do_email(uuid)',
       'privado.ler_fila_email(integer,integer)',
       'privado.registrar_email_enviado(uuid,text,date)',
       'privado.registrar_falha_email(uuid,text)',
       'privado.concluir_email(bigint)',
       'privado.disparar_email()'
     ]) f),
  true,
  'todas são executáveis por service_role');

select is(
  (select relrowsecurity from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'pgmq' and c.relname = 'a_email'),
  true,
  'pgmq.a_email tem RLS ligada');

select is(
  (select count(*)::int from pg_trigger t
     join pg_class c on c.oid = t.tgrelid
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'pgmq' and c.relname = 'q_email'
      and t.tgname = 'trg_email_enfileirado' and not t.tgisinternal),
  1,
  'o gatilho trg_email_enfileirado acorda a Edge Function quando um pedido entra');

select is(
  (select schedule from cron.job where jobname = 'processar_fila_email'),
  '* * * * *',
  'o job processar_fila_email drena a fila a cada minuto');

-- ── 2. A RN15 pela forma ──────────────────────────────────────────────────────

create temp table oc as
  select id from public.ocorrencia limit 0;

insert into public.ocorrencia (id, tipo, autor_id, usuario_id, motivo, relato,
                               chave_cliente, criada_em)
values ('0c430000-0000-4000-8000-000000000001', 'denuncia',
        'a0000000-0000-4000-8000-000000000001',
        'a0000000-0000-4000-8000-000000000011',
        'assedio',
        'O gerente gritou comigo na frente dos clientes.',
        '43430000-0000-4000-8000-000000000001',
        privado.agora());

select throws_ok(
  $$ update public.ocorrencia set email_ultimo_erro = '550 <ana@frila.test> user unknown'
      where id = '0c430000-0000-4000-8000-000000000001' $$,
  '23514',
  null,
  'a mensagem crua do provedor não cabe em email_ultimo_erro (RN15)');

select throws_ok(
  $$ update public.ocorrencia set email_ultimo_erro = 'ana@frila.test'
      where id = '0c430000-0000-4000-8000-000000000001' $$,
  '23514',
  null,
  'um endereço de e-mail não cabe em email_ultimo_erro (RN15)');

select lives_ok(
  $$ update public.ocorrencia set email_ultimo_erro = 'smtp_451'
      where id = '0c430000-0000-4000-8000-000000000001' $$,
  'um código em snake_case cabe');

-- ── 3. A imutabilidade conhece as colunas do envio ────────────────────────────

select lives_ok(
  $$ update public.ocorrencia
        set email_equipe_em = privado.agora(), email_tentativas = 1
      where id = '0c430000-0000-4000-8000-000000000001' $$,
  'as colunas de envio podem mudar: o gatilho de imutabilidade as conhece');

select throws_ok(
  $$ update public.ocorrencia set motivo = 'outro'
      where id = '0c430000-0000-4000-8000-000000000001' $$,
  '23001',
  null,
  'o motivo continua imutável: abrir as colunas de e-mail não abriu o registro');

select throws_ok(
  $$ delete from public.ocorrencia where id = '0c430000-0000-4000-8000-000000000001' $$,
  '23001',
  null,
  'a ocorrência continua sem poder ser apagada');

-- Volta ao estado de antes do envio para o resto do teste.
update public.ocorrencia
   set email_equipe_em = null, email_tentativas = 0, email_ultimo_erro = null
 where id = '0c430000-0000-4000-8000-000000000001';

-- ── 4. O que a Edge Function lê ───────────────────────────────────────────────

create temp table d as
  select privado.dados_do_email('0c430000-0000-4000-8000-000000000001'::uuid) as j;

select is(
  (select j->>'ocorrencia_id' from d),
  '0c430000-0000-4000-8000-000000000001',
  'o protocolo é o id da ocorrência, como o contrato define em Protocolo');

select is(
  (select j->>'tipo' from d), 'denuncia',
  'dados_do_email traz o tipo da ocorrência');

select is(
  (select j->>'motivo' from d), 'assedio',
  'traz a categoria do motivo, que é valor de enum e não texto de ninguém');

select is(
  (select (j->>'prazo_resposta_ate')::date from d),
  privado.prazo_de_resposta(privado.agora()),
  'traz o prazo de 5 dias úteis, o mesmo que a denúncia devolveu ao app');

select is(
  (select j->>'alvo_tipo' from d), 'profissional',
  'traz o tipo do alvo sem dizer quem é');

select is(
  (select (j->>'equipe_pendente')::boolean from d), true,
  'antes do envio, o e-mail da equipe está pendente');

select is(
  (select (j->>'autor_pendente')::boolean from d), true,
  'antes do envio, o protocolo de quem abriu está pendente');

select is(
  (select j->>'autor_email' from d),
  (select email::text from public.usuario where id = 'a0000000-0000-4000-8000-000000000001'),
  'traz o endereço de quem abriu, que é para onde o protocolo vai');

-- A asserção que sustenta o critério 3: o relato não sai do banco por esta porta.
select is(
  (select j ? 'relato' from d), false,
  'dados_do_email NÃO devolve o relato: o que não sai da função não entra no e-mail (RN15)');

select is(
  (select (select string_agg(x, ',' order by x) from jsonb_object_keys((select j from d)) x)),
  'alvo_tipo,autor_email,autor_pendente,criada_em,equipe_pendente,motivo,ocorrencia_id,prazo_resposta_ate,tentativas,tipo',
  'dados_do_email devolve exatamente estes campos, e nenhum é corpo de e-mail');

-- ── 5. Registrar o envio ──────────────────────────────────────────────────────

select privado.registrar_email_enviado(
  '0c430000-0000-4000-8000-000000000001', 'equipe',
  privado.prazo_de_resposta(privado.agora()));

select is(
  (select (email_equipe_em is not null and email_autor_em is null) from public.ocorrencia
    where id = '0c430000-0000-4000-8000-000000000001'),
  true,
  'registrar_email_enviado marca só o destino que saiu');

select is(
  (select email_prazo_ate from public.ocorrencia
    where id = '0c430000-0000-4000-8000-000000000001'),
  privado.prazo_de_resposta(privado.agora()),
  'o prazo comunicado fica congelado na ocorrência');

select is(
  (select (privado.dados_do_email('0c430000-0000-4000-8000-000000000001')->>'equipe_pendente')::boolean),
  false,
  'depois do envio, a equipe deixa de estar pendente e a retentativa não repete o e-mail');

create temp table primeiro as
  select email_equipe_em as em from public.ocorrencia
   where id = '0c430000-0000-4000-8000-000000000001';

select privado.registrar_email_enviado('0c430000-0000-4000-8000-000000000001', 'equipe', null);

select is(
  (select email_equipe_em from public.ocorrencia
    where id = '0c430000-0000-4000-8000-000000000001'),
  (select em from primeiro),
  'registrar_email_enviado é idempotente por destino: guarda o primeiro instante');

select throws_ok(
  $$ select privado.registrar_email_enviado('0c430000-0000-4000-8000-000000000001', 'marketing', null) $$,
  '22023',
  null,
  'um destino que não existe é recusado, em vez de marcar coisa nenhuma');

-- ── 6. Registrar a recusa do provedor ─────────────────────────────────────────

select is(
  privado.registrar_falha_email('0c430000-0000-4000-8000-000000000001', 'smtp_451'),
  1,
  'registrar_falha_email devolve o total de tentativas');

select is(
  (select email_ultimo_erro from public.ocorrencia
    where id = '0c430000-0000-4000-8000-000000000001'),
  'smtp_451',
  'a classe do erro fica registrada');

select is(
  privado.registrar_falha_email('0c430000-0000-4000-8000-000000000001',
                                '550 5.1.1 <ana@frila.test>: user unknown'),
  2,
  'a segunda recusa é contada');

select is(
  (select email_ultimo_erro from public.ocorrencia
    where id = '0c430000-0000-4000-8000-000000000001'),
  'erro_nao_classificado',
  'a mensagem crua do provedor vira erro_nao_classificado antes de chegar à coluna (RN15)');

select is(
  (select (email_equipe_em is not null) from public.ocorrencia
    where id = '0c430000-0000-4000-8000-000000000001'),
  true,
  'a falha não apaga o que já tinha sido enviado');

select privado.registrar_email_enviado('0c430000-0000-4000-8000-000000000001', 'autor', null);

select is(
  (select email_ultimo_erro from public.ocorrencia
    where id = '0c430000-0000-4000-8000-000000000001'),
  null,
  'o envio bem-sucedido limpa o último erro');

-- ── 7. A conta anonimizada (RF25) ─────────────────────────────────────────────

insert into public.ocorrencia (id, tipo, autor_id, usuario_id, motivo, relato,
                               chave_cliente, criada_em)
values ('0c430000-0000-4000-8000-000000000002', 'denuncia',
        'a0000000-0000-4000-8000-000000000006',
        'a0000000-0000-4000-8000-000000000011',
        'outro', 'Texto qualquer do relato.',
        '43430000-0000-4000-8000-000000000002', privado.agora());

update public.usuario set estado = 'anonimizada', email = null, anonimizado_em = privado.agora()
 where id = 'a0000000-0000-4000-8000-000000000006';

select is(
  (select (privado.dados_do_email('0c430000-0000-4000-8000-000000000002')->>'autor_pendente')::boolean),
  false,
  'conta anonimizada não fica pendente de protocolo: não há para onde mandar');

select is(
  (select privado.dados_do_email('0c430000-0000-4000-8000-000000000002')->>'autor_email'),
  null,
  'e o endereço não é devolvido');

select is(
  (select (privado.dados_do_email('0c430000-0000-4000-8000-000000000002')->>'equipe_pendente')::boolean),
  true,
  'a Equipe Frila continua recebendo: a denúncia sobrevive à exclusão de quem a abriu');

select is(
  privado.dados_do_email('0c430000-0000-4000-8000-000000000099'::uuid),
  null,
  'ocorrência inexistente devolve null, e o consumidor arquiva o pedido');

-- ── 8. A fila ─────────────────────────────────────────────────────────────────

select pgmq.send('email', jsonb_build_object(
  'tipo', 'denuncia', 'ocorrencia_id', '0c430000-0000-4000-8000-000000000001'));

create temp table lido as
  select * from privado.ler_fila_email(10, 60);

select is(
  (select count(*)::int from lido
    where mensagem->>'ocorrencia_id' = '0c430000-0000-4000-8000-000000000001'),
  1,
  'ler_fila_email devolve o pedido enfileirado');

select is(
  (select mensagem from lido
    where mensagem->>'ocorrencia_id' = '0c430000-0000-4000-8000-000000000001'),
  jsonb_build_object('tipo', 'denuncia',
                     'ocorrencia_id', '0c430000-0000-4000-8000-000000000001'),
  'devolve a mensagem inteira: quem entende o formato é o consumidor');

select is(
  (select read_ct from lido
    where mensagem->>'ocorrencia_id' = '0c430000-0000-4000-8000-000000000001'),
  1,
  'o read_ct é 1 na primeira leitura, e é ele que sustenta o teto de retentativas');

-- A falha do provedor não arquiva: o pedido continua na fila para a próxima rodada.
select is(
  (select count(*)::int from pgmq.q_email
    where message->>'ocorrencia_id' = '0c430000-0000-4000-8000-000000000001'),
  1,
  'ler a fila não apaga o pedido: ele volta quando o visibility timeout vence');

select is(
  privado.concluir_email((select msg_id from lido
                           where mensagem->>'ocorrencia_id' = '0c430000-0000-4000-8000-000000000001')),
  true,
  'concluir_email arquiva o pedido');

select is(
  (select count(*)::int from pgmq.q_email
    where message->>'ocorrencia_id' = '0c430000-0000-4000-8000-000000000001'),
  0,
  'e o pedido sai da fila');

select is(
  (select count(*)::int from pgmq.a_email
    where message->>'ocorrencia_id' = '0c430000-0000-4000-8000-000000000001'),
  1,
  'indo para o arquivo, que é o que a higiene diária apaga depois de 30 dias');

-- ── 9. A higiene alcança o arquivo da fila de e-mail ──────────────────────────

update pgmq.a_email set archived_at = privado.agora() - interval '40 days'
 where message->>'ocorrencia_id' = '0c430000-0000-4000-8000-000000000001';

select is(
  (privado.higienizar_tabelas()->>'pgmq_arquivo_email')::int,
  1,
  'a higiene diária apaga o arquivo de e-mail com mais de 30 dias');

select is(
  (select count(*)::int from pgmq.a_email
    where message->>'ocorrencia_id' = '0c430000-0000-4000-8000-000000000001'),
  0,
  'e ele sai de vez');

select * from finish();
rollback;
