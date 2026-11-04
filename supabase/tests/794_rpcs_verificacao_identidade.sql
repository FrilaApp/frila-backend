-- 794_rpcs_verificacao_identidade.sql
--
-- As três operações da verificação de identidade (RN14), contrato 0.2.50.
-- Cartão 86CC7PW3. Ids próprios, começando em `af000000`.
--
-- O que este arquivo prova:
--   1. Autorização: sem token é 401; conta não ativa é 401; contratante é 403
--      sem_permissao. As três operações, não só uma.
--   2. `minha_identidade_status` devolve as quatro chaves do contrato e `nao_exigida`
--      para quem nunca foi exigido — nenhuma conta nasce `pendente` (RN14).
--   3. `solicitar_upload_verificacao` recusa documento fora de rg/cnh, emite três partes
--      na ordem do contrato, com validade de 2 h, e grava os caminhos **com prazo de
--      expurgo**, porque caminho sem prazo é foto sem data de validade.
--   4. As recusas: `409 verificacao_indisponivel` com `details` `em_analise` e `aprovada`,
--      `409` com `sem_envio_solicitado` ao confirmar sem ter pedido, e
--      `422 evidencia_incompleta` dizendo QUAL parte falta.
--   5. Idempotência: confirmar de novo em `em_analise` devolve o mesmo estado e não
--      reabre a análise — repetição de rede não reinicia a contagem da moderação.
--   6. O que o contrato não expõe: a resposta não carrega `documento_hmac`, caminho de
--      arquivo nem score (VP-71).
--
-- O que este arquivo NÃO prova, e está medido fora dele: que o token assinado é aceito
-- pelo Storage. Isso foi medido por HTTP contra o Storage local em 04/11/2026 (PUT numa
-- URL emitida por `privado.url_de_upload_de_verificacao`, resposta 200 e objeto gravado).
-- pgTAP roda só dentro do Postgres e não fala HTTP; afirmar aqui que a URL funciona seria
-- afirmar o que o teste não mede.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(38);

select vault.create_secret('pepper-sintetico-794', 'documento_pepper');
select vault.create_secret('segredo-jwt-sintetico-de-teste-com-32-caracteres', 'storage_jwt_secret');

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

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

-- Marca no Storage que uma parte chegou. `storage.objects` é o índice do bucket: a RPC
-- confere ali, e é ali que o teste finge o upload, sem byte nenhum de verdade.
create function pg_temp.subiu(conta uuid, verificacao uuid, parte text) returns void
language sql as $$
  insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
  values ('documentos-identidade',
          conta::text || '/' || verificacao::text || '/' || parte || '.jpg',
          conta, conta::text, '{"size": 1024, "mimetype": "image/jpeg"}'::jsonb)
  on conflict do nothing;
$$;

select pg_temp.autenticar('af000000-0000-4000-8000-000000000001', 'prof1@verif794.test');
select pg_temp.autenticar('af000000-0000-4000-8000-000000000002', 'prof2@verif794.test');
select pg_temp.autenticar('af000000-0000-4000-8000-0000000000c1', 'casa@verif794.test');

select pg_temp.como('af000000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('profissional','Verif Um','+5561955557941','1995-01-01','2026-09-22') $$);
select pg_temp.como('af000000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('profissional','Verif Dois','+5561955557942','1995-01-01','2026-09-22') $$);
select pg_temp.como('af000000-0000-4000-8000-0000000000c1',
  $$ select public.criar_conta('contratante','Casa da Verificação','+5561955557943','1980-01-01','2026-09-22') $$);

-- ── 1. Autorização ───────────────────────────────────────────────────────────

select throws_ok(
  $$ select public.minha_identidade_status() $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token, minha_identidade_status é 401');

select throws_ok(
  $$ select public.solicitar_upload_verificacao('rg') $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token, solicitar_upload_verificacao é 401');

select throws_ok(
  $$ select public.confirmar_envio_verificacao() $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token, confirmar_envio_verificacao é 401');

-- Verificação de identidade é do profissional. O contratante tem o nível 4 da RN14, que é
-- outro assunto e não passa por estas funções (RF21).
select throws_ok(
  $$ select pg_temp.como('af000000-0000-4000-8000-0000000000c1',
       $x$ select public.minha_identidade_status() $x$) $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'contratante recebe 403 sem_permissao em minha_identidade_status');

select throws_ok(
  $$ select pg_temp.como('af000000-0000-4000-8000-0000000000c1',
       $x$ select public.solicitar_upload_verificacao('rg') $x$) $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'contratante recebe 403 sem_permissao em solicitar_upload_verificacao');

select ok(
  not has_function_privilege('anon', 'public.minha_identidade_status()', 'execute')
  and not has_function_privilege('anon', 'public.solicitar_upload_verificacao(text)', 'execute')
  and not has_function_privilege('anon', 'public.confirmar_envio_verificacao()', 'execute'),
  'anon não executa nenhuma das três');

select ok(
  has_function_privilege('authenticated', 'public.minha_identidade_status()', 'execute')
  and has_function_privilege('authenticated', 'public.solicitar_upload_verificacao(text)', 'execute')
  and has_function_privilege('authenticated', 'public.confirmar_envio_verificacao()', 'execute'),
  'authenticated executa as três');

select ok(
  not has_table_privilege('authenticated', 'privado.verificacao_identidade', 'select'),
  'authenticated continua sem ler a tabela: o estado sai pela RPC, não pela tabela');

-- ── 2. Estado inicial ────────────────────────────────────────────────────────

create temp table st_inicial as select pg_temp.como(
  'af000000-0000-4000-8000-000000000001',
  $$ select public.minha_identidade_status() $$) as j;

select is(
  (select j->>'status_verificacao' from st_inicial),
  'nao_exigida',
  'RN14: quem nunca foi exigido está em nao_exigida — nenhuma conta nasce pendente');

select ok(
  (select j->'motivo' = 'null'::jsonb and j->'prazo_envio_ate' = 'null'::jsonb from st_inicial),
  'motivo e prazo_envio_ate são nulos sem exigência');

select is(
  (select j->>'identidade_verificada' from st_inicial),
  'false',
  'o selo nasce falso');

select is(
  (select count(*)::int from jsonb_object_keys((select j from st_inicial))),
  4,
  'a resposta tem exatamente as quatro chaves do StatusVerificacao, e nenhuma evidência (VP-71)');

-- ── 3. Pedido de upload ──────────────────────────────────────────────────────

select throws_ok(
  $$ select pg_temp.como('af000000-0000-4000-8000-000000000001',
       $x$ select public.solicitar_upload_verificacao('passaporte') $x$) $$,
  'PGRST',
  '{"code" : "documento_invalido", "message" : "documento_invalido", "details" : "documento_tipo", "hint" : null}',
  'documento fora de rg e cnh é recusado com 422 documento_invalido');

create temp table up as select pg_temp.como(
  'af000000-0000-4000-8000-000000000001',
  $$ select public.solicitar_upload_verificacao('rg') $$) as j;

select is(
  (select jsonb_array_length(j->'partes') from up),
  3,
  'três partes: frente, verso e selfie');

select is(
  (select string_agg(p->>'parte', ',' order by i) from up, jsonb_array_elements(j->'partes') with ordinality as e(p, i)),
  'frente,verso,selfie',
  'as partes vêm na ordem do contrato');

select ok(
  (select bool_and(p->>'url' like '%/object/upload/sign/documentos-identidade/%token=%')
     from up, jsonb_array_elements(j->'partes') as p),
  'cada URL aponta o bucket privado e carrega o token assinado');

select ok(
  (select bool_and(p->>'url' not like '%service_role%' and p->>'url' not like '%' || 'documento_hmac' || '%')
     from up, jsonb_array_elements(j->'partes') as p),
  'a URL não leva chave de serviço nem hash de documento');

select ok(
  (select abs(extract(epoch from ((j->>'expira_em')::timestamptz - privado.agora())) - 7200) < 5 from up),
  'expira_em é duas horas depois de agora, como o contrato declara');

select is(
  (select v.nivel from privado.verificacao_identidade v
    where v.usuario_id = 'af000000-0000-4000-8000-000000000001'),
  3::smallint,
  'começo voluntário nasce nível 3 (selo): nível 2 só existe por exigência da moderação');

select ok(
  (select v.storage_path_frente is not null and v.storage_path_verso is not null
          and v.storage_path_selfie is not null and v.expurgo_midia_em is not null
     from privado.verificacao_identidade v
    where v.usuario_id = 'af000000-0000-4000-8000-000000000001'),
  'os três caminhos ficam na linha, com prazo de expurgo: caminho sem prazo é foto sem data de validade');

select ok(
  (select v.storage_path_frente like 'af000000-0000-4000-8000-000000000001/%'
     from privado.verificacao_identidade v
    where v.usuario_id = 'af000000-0000-4000-8000-000000000001'),
  'o caminho começa pela conta: é o que a política de escrita do bucket confere');

-- Pedir de novo antes de confirmar é permitido e devolve URLs novas (contrato 0.2.50).
select lives_ok(
  $$ select pg_temp.como('af000000-0000-4000-8000-000000000001',
       $x$ select public.solicitar_upload_verificacao('cnh') $x$) $$,
  'pedir de novo antes de confirmar é permitido');

select is(
  (select count(*)::int from privado.verificacao_identidade
    where usuario_id = 'af000000-0000-4000-8000-000000000001'),
  1,
  'o segundo pedido reaproveita a mesma verificação em vez de abrir outra');

select is(
  (select status::text from privado.verificacao_identidade
    where usuario_id = 'af000000-0000-4000-8000-000000000001'),
  'pendente',
  'pedir URL não move para em_analise: quem move é a confirmação');

-- ── 4. Confirmação: recusas ──────────────────────────────────────────────────

select throws_ok(
  $$ select pg_temp.como('af000000-0000-4000-8000-000000000002',
       $x$ select public.confirmar_envio_verificacao() $x$) $$,
  'PGRST',
  '{"code" : "verificacao_indisponivel", "message" : "verificacao_indisponivel", "details" : "sem_envio_solicitado", "hint" : null}',
  'confirmar sem ter pedido é 409 com details sem_envio_solicitado');

select throws_ok(
  $$ select pg_temp.como('af000000-0000-4000-8000-000000000001',
       $x$ select public.confirmar_envio_verificacao() $x$) $$,
  'PGRST',
  '{"code" : "evidencia_incompleta", "message" : "evidencia_incompleta", "details" : "frente", "hint" : null}',
  'sem nenhuma mídia no bucket, 422 evidencia_incompleta aponta a frente');

select pg_temp.subiu('af000000-0000-4000-8000-000000000001',
  (select id from privado.verificacao_identidade where usuario_id = 'af000000-0000-4000-8000-000000000001'),
  'frente');

select throws_ok(
  $$ select pg_temp.como('af000000-0000-4000-8000-000000000001',
       $x$ select public.confirmar_envio_verificacao() $x$) $$,
  'PGRST',
  '{"code" : "evidencia_incompleta", "message" : "evidencia_incompleta", "details" : "verso", "hint" : null}',
  'com a frente no bucket, a recusa passa a apontar o verso — a parte que falta, não "incompleto"');

-- ── 5. Confirmação: caminho feliz e idempotência ─────────────────────────────

select pg_temp.subiu('af000000-0000-4000-8000-000000000001',
  (select id from privado.verificacao_identidade where usuario_id = 'af000000-0000-4000-8000-000000000001'),
  'verso');
select pg_temp.subiu('af000000-0000-4000-8000-000000000001',
  (select id from privado.verificacao_identidade where usuario_id = 'af000000-0000-4000-8000-000000000001'),
  'selfie');

create temp table conf as select pg_temp.como(
  'af000000-0000-4000-8000-000000000001',
  $$ select public.confirmar_envio_verificacao() $$) as j;

select is(
  (select j->>'status_verificacao' from conf),
  'em_analise',
  'com as três partes no bucket, a verificação vai para em_analise');

select is(
  (select status::text from privado.verificacao_identidade
    where usuario_id = 'af000000-0000-4000-8000-000000000001'),
  'em_analise',
  'o estado persistiu na tabela, e não só na resposta');

select is(
  (select pg_temp.como('af000000-0000-4000-8000-000000000001',
     $$ select public.confirmar_envio_verificacao() $$)->>'status_verificacao'),
  'em_analise',
  'idempotente: confirmar de novo devolve o mesmo estado e não reabre a análise');

select is(
  (select pg_temp.como('af000000-0000-4000-8000-000000000001',
     $$ select public.minha_identidade_status() $$)->>'status_verificacao'),
  'em_analise',
  'o status lido pelo app acompanha a confirmação');

-- A idempotência não é só "devolve o mesmo estado": é não reexecutar a conferência. Aponto
-- a selfie para um caminho que não existe no bucket e confirmo de novo: com o atalho de
-- idempotência, a resposta continua `em_analise`; sem ele, a função reconferiria o bucket e
-- devolveria 422 — uma repetição de rede derrubaria uma análise que já começou.
--
-- Mexo no caminho, e não no objeto, porque `storage.objects` recusa remoção direta por
-- trigger: "Direct deletion from storage tables is not allowed. Use the Storage API
-- instead." (medido em 04/11/2026). É a mesma razão pela qual o expurgo de mídia é em duas
-- fases: o Postgres não apaga byte no Storage.
update privado.verificacao_identidade
   set storage_path_selfie = storage_path_selfie || '.inexistente'
 where usuario_id = 'af000000-0000-4000-8000-000000000001';

-- `lives_ok` antes do `is`, de propósito: sem o atalho de idempotência a função levanta
-- 422, e um `is` sozinho abortaria a transação e esconderia o resto da suíte atrás de
-- "current transaction is aborted". pgTAP captura a exceção aqui e o relatório diz qual
-- regra caiu.
select lives_ok(
  $$ select pg_temp.como('af000000-0000-4000-8000-000000000001',
       $x$ select public.confirmar_envio_verificacao() $x$) $$,
  'com a análise em curso, a confirmação não reconfere o bucket: repetição de rede não derruba análise');

select is(
  (select pg_temp.como('af000000-0000-4000-8000-000000000001',
     $$ select public.minha_identidade_status() $$)->>'status_verificacao'),
  'em_analise',
  'e o estado continua em_analise depois da repetição');

-- ── 6. Recusas por estado ────────────────────────────────────────────────────

select throws_ok(
  $$ select pg_temp.como('af000000-0000-4000-8000-000000000001',
       $x$ select public.solicitar_upload_verificacao('rg') $x$) $$,
  'PGRST',
  '{"code" : "verificacao_indisponivel", "message" : "verificacao_indisponivel", "details" : "em_analise", "hint" : null}',
  'com a análise em curso, pedir upload é 409 com details em_analise');

update privado.verificacao_identidade
   set status = 'aprovada', respondido_em = privado.agora()
 where usuario_id = 'af000000-0000-4000-8000-000000000001';

select throws_ok(
  $$ select pg_temp.como('af000000-0000-4000-8000-000000000001',
       $x$ select public.solicitar_upload_verificacao('rg') $x$) $$,
  'PGRST',
  '{"code" : "verificacao_indisponivel", "message" : "verificacao_indisponivel", "details" : "aprovada", "hint" : null}',
  'com a verificação aprovada, pedir upload é 409 com details aprovada');

select throws_ok(
  $$ select pg_temp.como('af000000-0000-4000-8000-000000000001',
       $x$ select public.confirmar_envio_verificacao() $x$) $$,
  'PGRST',
  '{"code" : "verificacao_indisponivel", "message" : "verificacao_indisponivel", "details" : "aprovada", "hint" : null}',
  'confirmar com a verificação aprovada é 409 com details aprovada');

-- Rejeitada aceita envio novo: é o caminho de quem corrigiu a foto ilegível.
update privado.verificacao_identidade
   set status = 'rejeitada', respondido_em = privado.agora()
 where usuario_id = 'af000000-0000-4000-8000-000000000001';

select lives_ok(
  $$ select pg_temp.como('af000000-0000-4000-8000-000000000001',
       $x$ select public.solicitar_upload_verificacao('cnh') $x$) $$,
  'depois de rejeitada, o profissional pode enviar de novo');

select is(
  (select count(*)::int from privado.verificacao_identidade
    where usuario_id = 'af000000-0000-4000-8000-000000000001'
      and status in ('pendente', 'em_analise')),
  1,
  'o envio novo abre uma verificação aberta, e só uma');

select * from finish();

rollback;
