-- 793_verificacao_identidade.sql
--
-- Cobertura pgTAP da tabela de verificação de identidade e do expurgo de mídia.
-- Cartão aEqry9vB · RN14, RN13 · requisitos `frila-docs/requisitos/verificacao-progressiva-rn14.md`.
--
-- O que prova:
--   1. Catálogo: o enum com os cinco estados, as colunas da especificação, a FK para
--      public.usuario e a coluna do selo em public.profissional.
--   2. Invariantes do schema privado: RLS ligado, sem FORCE, sem política, sem grant para
--      anon e authenticated, e service_role sem delete (a linha é registro de apuração).
--   3. A RN14 não cria barreira: a migração não deixa nenhuma conta existente com
--      exigência aberta.
--   4. As constraints que impedem registro incoerente: nível fora de 2 e 3, nível 2 sem
--      motivo, documento fora do catálogo, desfecho sem data, mídia sem prazo de expurgo.
--   5. Deduplicação: o mesmo documento aprovado não entra em duas contas, e duas análises
--      com o mesmo documento convivem enquanto ninguém foi aprovado.
--   6. O HMAC: pepper ausente é erro, pontuação não muda o hash, documento diferente dá
--      hash diferente, e o número em claro não aparece em coluna nenhuma.
--   7. O expurgo em duas fases: enfileira e marca o pedido; não anula caminho antes da
--      confirmação (apagar a linha de storage.objects não apaga o byte no Storage); não
--      reenfileira dentro de 24 h; confirma de forma idempotente; e registra falha da
--      quinta tentativa em diante, para mídia vencida no bucket não virar silêncio.
--
-- O cenário é sintético e nasce na transação. Nenhum dado real, nenhum arquivo no Storage.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(59);

-- ── Cenário ───────────────────────────────────────────────────────────────────

select vault.create_secret('pepper-sintetico-do-teste-793', 'documento_pepper');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('aaaaaaaa-0793-0000-0000-000000000001','profissional','Um','+5561999997931','um793@t.test','1995-01-01','2026-09-22', now()),
  ('aaaaaaaa-0793-0000-0000-000000000002','profissional','Dois','+5561999997932','dois793@t.test','1995-01-01','2026-09-22', now());

insert into public.profissional (usuario_id, ponto_base) values
  ('aaaaaaaa-0793-0000-0000-000000000001','POINT(-47.8822 -15.7942)'::extensions.geography),
  ('aaaaaaaa-0793-0000-0000-000000000002','POINT(-47.8822 -15.7942)'::extensions.geography);

create function pg_temp.nova_verificacao(
  p_usuario uuid,
  p_nivel smallint default 2::smallint,
  p_status public.status_verificacao default 'pendente',
  p_motivo text default 'denuncia grave apurada',
  p_hmac bytea default null,
  p_frente text default null,
  p_expurgo timestamptz default null,
  p_respondido timestamptz default null
) returns uuid
language sql as $$
  insert into privado.verificacao_identidade
    (usuario_id, nivel, status, motivo, documento_tipo, documento_hmac,
     storage_path_frente, expurgo_midia_em, respondido_em)
  values (p_usuario, p_nivel, p_status, p_motivo, 'rg', p_hmac,
          p_frente, p_expurgo, p_respondido)
  returning id;
$$;

-- ── 1. Catálogo ───────────────────────────────────────────────────────────────

select has_type('public', 'status_verificacao', 'o enum public.status_verificacao existe');

select is(
  (select string_agg(e.enumlabel, ',' order by e.enumsortorder)
     from pg_type t join pg_enum e on e.enumtypid = t.oid
     join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'status_verificacao'),
  'nao_exigida,pendente,em_analise,aprovada,rejeitada',
  'os cinco estados da especificação, nesta ordem, e nenhum estado de suspensão');

select has_table('privado', 'verificacao_identidade', 'a tabela existe no schema privado');

select has_column('privado', 'verificacao_identidade', 'usuario_id',          'coluna usuario_id');
select has_column('privado', 'verificacao_identidade', 'status',              'coluna status');
select has_column('privado', 'verificacao_identidade', 'motivo',              'coluna motivo');
select has_column('privado', 'verificacao_identidade', 'documento_tipo',      'coluna documento_tipo');
select has_column('privado', 'verificacao_identidade', 'documento_hmac',      'coluna documento_hmac');
select has_column('privado', 'verificacao_identidade', 'storage_path_frente', 'coluna storage_path_frente');
select has_column('privado', 'verificacao_identidade', 'storage_path_verso',  'coluna storage_path_verso');
select has_column('privado', 'verificacao_identidade', 'storage_path_selfie', 'coluna storage_path_selfie');
select has_column('privado', 'verificacao_identidade', 'solicitado_em',       'coluna solicitado_em');
select has_column('privado', 'verificacao_identidade', 'prazo_envio_ate',     'coluna prazo_envio_ate');
select has_column('privado', 'verificacao_identidade', 'respondido_em',       'coluna respondido_em');
select has_column('privado', 'verificacao_identidade', 'expurgo_midia_em',    'coluna expurgo_midia_em');

select is(
  (select format_type(a.atttypid, null) from pg_attribute a
    where a.attrelid = 'privado.verificacao_identidade'::regclass and a.attname = 'documento_hmac'),
  'bytea',
  'documento_hmac é bytea: é digest, não texto de documento');

select col_is_fk('privado', 'verificacao_identidade', array['usuario_id'],
  'usuario_id é chave estrangeira para a conta');

select has_column('public', 'profissional', 'identidade_verificada', 'o selo existe em public.profissional');

select is(
  (select column_default from information_schema.columns
    where table_schema = 'public' and table_name = 'profissional' and column_name = 'identidade_verificada'),
  'false',
  'o selo nasce false: conta existente não ganha selo por deploy');

-- ── 2. Invariantes do schema privado ─────────────────────────────────────────

select is(
  (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'verificacao_identidade'),
  true,
  'RLS habilitado, como toda tabela de privado (achado 1 da AUDITORIA-RLS)');

select is(
  (select c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'verificacao_identidade'),
  false,
  'sem FORCE RLS: forçar tiraria o bypass do dono e quebraria as funções SECURITY DEFINER');

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'privado' and tablename = 'verificacao_identidade'),
  0,
  'sem política nenhuma: GRANT acidental para authenticated não devolve linha');

select ok(
  not has_table_privilege('anon', 'privado.verificacao_identidade', 'select')
  and not has_table_privilege('authenticated', 'privado.verificacao_identidade', 'select'),
  'nem anon nem authenticated leem a tabela');

select ok(
  has_table_privilege('service_role', 'privado.verificacao_identidade', 'select')
  and has_table_privilege('service_role', 'privado.verificacao_identidade', 'insert')
  and has_table_privilege('service_role', 'privado.verificacao_identidade', 'update'),
  'service_role lê, insere e atualiza: é o caminho da moderação');

select ok(
  not has_table_privilege('service_role', 'privado.verificacao_identidade', 'delete'),
  'service_role não apaga: a linha é registro de apuração (RNF13); o que sai é a mídia');

select ok(
  not has_function_privilege('anon', 'privado.documento_hmac(text)', 'execute')
  and not has_function_privilege('authenticated', 'privado.expurgar_midias_verificacao_identidade(integer)', 'execute')
  and not has_function_privilege('authenticated', 'privado.confirmar_expurgo_midia(uuid)', 'execute'),
  'nenhuma das três funções é executável por papel de API');

-- ── 3. A RN14 não cria barreira ──────────────────────────────────────────────

select is(
  (select count(*)::int from privado.verificacao_identidade
    where status in ('pendente', 'em_analise')
      and usuario_id not in ('aaaaaaaa-0793-0000-0000-000000000001',
                             'aaaaaaaa-0793-0000-0000-000000000002')),
  0,
  'RN14: a migração não deixou nenhuma conta preexistente com exigência aberta');

-- ── 4. Constraints de coerência ──────────────────────────────────────────────

select throws_ok(
  $$ select pg_temp.nova_verificacao('aaaaaaaa-0793-0000-0000-000000000001', 1::smallint) $$,
  '23514', null,
  'nível 1 não registra: o onboarding leve não produz linha');

select throws_ok(
  $$ select pg_temp.nova_verificacao('aaaaaaaa-0793-0000-0000-000000000001', 4::smallint) $$,
  '23514', null,
  'nível 4 é do contratante e não entra nesta tabela');

select throws_ok(
  $$ select pg_temp.nova_verificacao('aaaaaaaa-0793-0000-0000-000000000001', 2::smallint, 'pendente', '   ') $$,
  '23514', null,
  'nível 2 sem motivo escrito é recusado: exigência reativa tem de dizer por quê');

select throws_ok(
  $$ insert into privado.verificacao_identidade (usuario_id, nivel, status, motivo, documento_tipo)
     values ('aaaaaaaa-0793-0000-0000-000000000001', 2, 'pendente', 'motivo', 'passaporte') $$,
  '23514', null,
  'documento fora do catálogo (rg, cnh, cin) é recusado');

select throws_ok(
  $$ select pg_temp.nova_verificacao('aaaaaaaa-0793-0000-0000-000000000001', 2::smallint, 'aprovada') $$,
  '23514', null,
  'desfecho sem respondido_em é recusado: é dele que os 30 dias contam');

select throws_ok(
  $$ select pg_temp.nova_verificacao('aaaaaaaa-0793-0000-0000-000000000001', 2::smallint, 'pendente',
       'motivo', null, 'caminho/frente.jpg', null) $$,
  '23514', null,
  'mídia sem expurgo_midia_em é recusada: prazo que depende de alguém lembrar não acontece');

-- O expurgo é em duas fases, e a ordem das duas é a regra: `expurgo_feito_em` sem
-- `expurgo_pedido_em` seria "apaguei sem ter pedido", ou seja, caminho anulado sem ninguém
-- ter ido ao Storage — o arquivo ficaria órfão e inalcançável no bucket.
select throws_ok(
  $$ insert into privado.verificacao_identidade
       (usuario_id, nivel, status, motivo, expurgo_feito_em)
     values ('aaaaaaaa-0793-0000-0000-000000000001', 2, 'pendente', 'motivo', privado.agora()) $$,
  '23514', null,
  'expurgo_feito_em sem expurgo_pedido_em é recusado: não se confirma um expurgo que ninguém pediu');

-- Prazo de envio igual ou anterior à solicitação é prazo que nasce vencido: o profissional
-- veria "faltam -2 h" e a fila de deliberação receberia o caso no mesmo instante em que a
-- exigência foi criada, sem ele ter tido chance de enviar nada.
select throws_ok(
  $$ insert into privado.verificacao_identidade
       (usuario_id, nivel, status, motivo, solicitado_em, prazo_envio_ate)
     values ('aaaaaaaa-0793-0000-0000-000000000001', 2, 'pendente', 'motivo',
             '2026-11-04T12:00:00Z'::timestamptz, '2026-11-04T12:00:00Z'::timestamptz) $$,
  '23514', null,
  'prazo_envio_ate igual à solicitação é recusado: prazo que nasce vencido não é prazo');

-- Uma exigência aberta por conta e por nível. Duas linhas `pendente`/`em_analise` para a
-- mesma pessoa seriam duas contagens de prazo para o mesmo pedido, e a moderação veria o
-- caso duplicado na fila.
insert into privado.verificacao_identidade (usuario_id, nivel, status, motivo)
values ('aaaaaaaa-0793-0000-0000-000000000001', 2, 'pendente', 'primeira exigência');

select throws_ok(
  $$ insert into privado.verificacao_identidade (usuario_id, nivel, status, motivo)
     values ('aaaaaaaa-0793-0000-0000-000000000001', 2, 'em_analise', 'segunda exigência') $$,
  '23505', null,
  'segunda exigência aberta no mesmo nível para a mesma conta é recusada pelo índice parcial');

-- Limpa a linha do cenário acima: a seção 5 precisa da conta sem exigência aberta.
delete from privado.verificacao_identidade
 where usuario_id = 'aaaaaaaa-0793-0000-0000-000000000001';

-- ── 5. Deduplicação por documento ────────────────────────────────────────────

select lives_ok(
  $$ select pg_temp.nova_verificacao('aaaaaaaa-0793-0000-0000-000000000001', 2::smallint, 'em_analise',
       'motivo', privado.documento_hmac('12345678900')) $$,
  'duas análises com o mesmo documento podem conviver: barrar no envio diria ao fraudador qual documento está em uso');

select lives_ok(
  $$ select pg_temp.nova_verificacao('aaaaaaaa-0793-0000-0000-000000000002', 2::smallint, 'em_analise',
       'motivo', privado.documento_hmac('12345678900')) $$,
  'a segunda análise com o mesmo documento, em outra conta, também entra');

update privado.verificacao_identidade
   set status = 'aprovada', respondido_em = privado.agora()
 where usuario_id = 'aaaaaaaa-0793-0000-0000-000000000001';

select throws_ok(
  $$ update privado.verificacao_identidade
        set status = 'aprovada', respondido_em = privado.agora()
      where usuario_id = 'aaaaaaaa-0793-0000-0000-000000000002' $$,
  '23505', null,
  'o mesmo documento não é aprovado em duas contas (deduplicação, risco 1 do desenho)');

delete from privado.verificacao_identidade;

-- ── 6. O HMAC ────────────────────────────────────────────────────────────────

select ok(
  privado.documento_hmac('123.456.789-00') = privado.documento_hmac('12345678900'),
  'pontuação não muda o hash: senão a deduplicação não valeria nada');

select ok(
  privado.documento_hmac('12345678900') <> privado.documento_hmac('12345678901'),
  'documentos diferentes dão hashes diferentes');

select is(
  length(privado.documento_hmac('12345678900')),
  32,
  'o digest tem 32 bytes, de SHA-256');

select throws_ok(
  $$ select privado.documento_hmac('12') $$,
  '22023', null,
  'documento curto é recusado em vez de gerar hash de lixo');

-- O pepper ausente é erro, não nulo: hash em branco seria deduplicação que não acontece,
-- e ninguém descobriria até o segundo cadastro com o mesmo RG ser aprovado.
select vault.update_secret(
  (select id from vault.secrets where name = 'documento_pepper'), '');

select throws_ok(
  $$ select privado.documento_hmac('12345678900') $$,
  'P0002', null,
  'pepper vazio no Vault levanta erro em vez de gravar linha sem hash');

select vault.update_secret(
  (select id from vault.secrets where name = 'documento_pepper'), 'pepper-sintetico-do-teste-793');

select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'privado' and table_name = 'verificacao_identidade'
      and column_name in ('documento_numero', 'cpf', 'rg', 'documento')),
  0,
  'não existe coluna para o número do documento em claro');

-- ── 7. Expurgo em duas fases ─────────────────────────────────────────────────

create temp table alvo on commit drop as
select pg_temp.nova_verificacao(
  'aaaaaaaa-0793-0000-0000-000000000001', 2::smallint, 'aprovada', 'denuncia apurada',
  privado.documento_hmac('98765432100'),
  'aaaaaaaa-0793-0000-0000-000000000001/frente.jpg',
  privado.agora() - interval '1 day',
  privado.agora() - interval '31 days') as id;

select is(
  (privado.expurgar_midias_verificacao_identidade() ->> 'pedidos_novos')::int,
  1,
  'a mídia vencida é enfileirada');

select is(
  (select count(*)::int from pgmq.q_expurgo_midia),
  1,
  'a mensagem está na fila expurgo_midia');

select is(
  (select m.message ->> 'bucket' from pgmq.q_expurgo_midia m limit 1),
  'documentos-identidade',
  'a mensagem aponta o bucket privado');

select ok(
  (select m.message::text not like '%98765432100%' and m.message ->> 'caminhos' is not null
     from pgmq.q_expurgo_midia m limit 1),
  'a mensagem leva caminho de arquivo, nunca número de documento');

-- A prova central: enfileirar não apaga. Antes da confirmação, o caminho continua de pé,
-- porque anulá-lo deixaria o arquivo órfão e inalcançável no Storage.
select isnt(
  (select storage_path_frente from privado.verificacao_identidade where id = (select id from alvo)),
  null,
  'enfileirar não anula o caminho: quem apaga o byte é a Edge Function, não o Postgres');

select ok(
  (select expurgo_pedido_em is not null and expurgo_feito_em is null
     from privado.verificacao_identidade where id = (select id from alvo)),
  'o pedido fica marcado e o feito continua nulo até a confirmação');

select is(
  (privado.expurgar_midias_verificacao_identidade() ->> 'pedidos_reenviados')::int,
  0,
  'não reenfileira dentro de 24 h: a fila não vira repetição de si mesma');

select ok(
  privado.confirmar_expurgo_midia((select id from alvo)),
  'a confirmação fecha o expurgo');

select ok(
  (select storage_path_frente is null and storage_path_verso is null
          and storage_path_selfie is null and expurgo_feito_em is not null
     from privado.verificacao_identidade where id = (select id from alvo)),
  'depois da confirmação, os caminhos somem e expurgo_feito_em é gravado');

select ok(
  privado.confirmar_expurgo_midia((select id from alvo)),
  'confirmar duas vezes é inofensivo: a fila pode reentregar a mesma mensagem');

select is(
  (privado.expurgar_midias_verificacao_identidade() ->> 'pedidos_novos')::int,
  0,
  'linha já expurgada não volta para a fila');

-- O silêncio quebrado: mídia vencida que não sai do bucket precisa aparecer em algum
-- lugar que alguém olhe, e o lugar que já existe é privado.falha_execucao.
update privado.verificacao_identidade
   set expurgo_tentativas = 4,
       expurgo_pedido_em  = privado.agora() - interval '48 hours',
       expurgo_feito_em   = null,
       storage_path_frente = 'aaaaaaaa-0793-0000-0000-000000000001/frente.jpg'
 where id = (select id from alvo);

select is(
  (privado.expurgar_midias_verificacao_identidade() ->> 'atrasados_5x')::int,
  1,
  'da quinta tentativa em diante, o atraso é contado');

select is(
  (select count(*)::int from privado.falha_execucao
    where codigo = 'expurgo_midia_nao_confirmado'),
  1,
  'e registrado em privado.falha_execucao, que o monitoramento já lê');

select is(
  (select count(*)::int from cron.job where jobname = 'retencao_e_limpeza_diaria'),
  1,
  'o expurgo entra na rotina diária que já existe, sem job novo para alguém esquecer');

select * from finish();

rollback;
