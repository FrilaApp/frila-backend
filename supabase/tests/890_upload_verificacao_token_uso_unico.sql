-- 890_upload_verificacao_token_uso_unico.sql
--
-- Primitiva privada do token opaco de upload da RN14. Dados inteiramente sintéticos.
-- A disputa entre duas conexões está em scripts/corrida-token-upload-verificacao.sh.

begin;
select plan(40);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local "frila.agora" = '2026-11-20 12:00:00+00';

create function pg_temp.token(n integer) returns text
language sql immutable as $$ select lpad(to_hex(n), 64, '0') $$;

create function pg_temp.hash_token(token text) returns text
language sql immutable as $$ select encode(sha256(convert_to(token, 'UTF8')), 'hex') $$;

insert into public.usuario
  (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em, estado)
values
  ('89000000-0000-4000-8000-000000000001', 'profissional', 'Pessoa ativa',
   'ativa@890.test', '+5561955508901', '1990-01-01', '1.0', now(), 'ativa'),
  ('89000000-0000-4000-8000-000000000002', 'profissional', 'Pessoa suspensa',
   'suspensa@890.test', '+5561955508902', '1990-01-01', '1.0', now(), 'suspensa'),
  ('89000000-0000-4000-8000-000000000003', 'profissional', 'Pessoa anonimizada',
   'anonima@890.test', '+5561955508903', '1990-01-01', '1.0', now(), 'ativa'),
  ('89000000-0000-4000-8000-000000000004', 'profissional', 'Pessoa em análise',
   'analise@890.test', '+5561955508904', '1990-01-01', '1.0', now(), 'ativa');

insert into privado.verificacao_identidade
  (id, usuario_id, nivel, status, documento_tipo, storage_path_frente,
   storage_path_verso, storage_path_selfie, expurgo_midia_em)
values
  ('89000000-0000-4000-8000-000000000101', '89000000-0000-4000-8000-000000000001',
   3, 'pendente', 'rg', '890/101/frente.jpg', '890/101/verso.jpg', '890/101/selfie.jpg', privado.agora() + interval '15 days'),
  ('89000000-0000-4000-8000-000000000102', '89000000-0000-4000-8000-000000000002',
   3, 'pendente', 'rg', '890/102/frente.jpg', '890/102/verso.jpg', '890/102/selfie.jpg', privado.agora() + interval '15 days'),
  ('89000000-0000-4000-8000-000000000103', '89000000-0000-4000-8000-000000000003',
   3, 'pendente', 'rg', '890/103/frente.jpg', '890/103/verso.jpg', '890/103/selfie.jpg', privado.agora() + interval '15 days'),
  ('89000000-0000-4000-8000-000000000104', '89000000-0000-4000-8000-000000000004',
   3, 'em_analise', 'rg', '890/104/frente.jpg', '890/104/verso.jpg', '890/104/selfie.jpg', privado.agora() + interval '15 days');

update public.usuario
   set estado = 'anonimizada', anonimizado_em = privado.agora()
 where id = '89000000-0000-4000-8000-000000000003';

create function pg_temp.upload(
  id uuid, verificacao uuid, parte text, caminho text, token text,
  expira timestamptz default privado.agora() + interval '2 hours'
) returns void language sql as $$
  insert into privado.upload_verificacao_identidade
    (id, verificacao_id, parte, storage_path, token_hash, expira_em)
  values (id, verificacao, parte, caminho, pg_temp.hash_token(token), expira)
$$;

select pg_temp.upload('89000000-0000-4000-8000-000000000201', '89000000-0000-4000-8000-000000000101',
  'frente', '890/101/frente.jpg', pg_temp.token(1));
select pg_temp.upload('89000000-0000-4000-8000-000000000202', '89000000-0000-4000-8000-000000000101',
  'verso', '890/101/verso.jpg', pg_temp.token(2));
select pg_temp.upload('89000000-0000-4000-8000-000000000203', '89000000-0000-4000-8000-000000000101',
  'selfie', '890/101/selfie.jpg', pg_temp.token(3), privado.agora() - interval '1 second');
select pg_temp.upload('89000000-0000-4000-8000-000000000204', '89000000-0000-4000-8000-000000000102',
  'frente', '890/102/frente.jpg', pg_temp.token(4));
select pg_temp.upload('89000000-0000-4000-8000-000000000205', '89000000-0000-4000-8000-000000000103',
  'frente', '890/103/frente.jpg', pg_temp.token(5));
select pg_temp.upload('89000000-0000-4000-8000-000000000206', '89000000-0000-4000-8000-000000000104',
  'frente', '890/104/frente.jpg', pg_temp.token(6));

-- Estrutura e isolamento.
select has_table('privado', 'upload_verificacao_identidade', 'a tabela privada existe');
select has_column('privado', 'upload_verificacao_identidade', 'id', 'coluna id');
select has_column('privado', 'upload_verificacao_identidade', 'verificacao_id', 'coluna verificacao_id');
select has_column('privado', 'upload_verificacao_identidade', 'parte', 'coluna parte');
select has_column('privado', 'upload_verificacao_identidade', 'storage_path', 'coluna storage_path');
select has_column('privado', 'upload_verificacao_identidade', 'token_hash', 'coluna token_hash');
select has_column('privado', 'upload_verificacao_identidade', 'expira_em', 'coluna expira_em');
select has_column('privado', 'upload_verificacao_identidade', 'usado_em', 'coluna usado_em');
select col_is_fk('privado', 'upload_verificacao_identidade', array['verificacao_id'],
  'verificacao_id referencia a verificação e acompanha seu ciclo de vida');
select ok((select relrowsecurity and not relforcerowsecurity
             from pg_class where oid = 'privado.upload_verificacao_identidade'::regclass),
  'RLS ligado e sem FORCE, para funções SECURITY DEFINER');
select is((select count(*)::int from pg_policies
            where schemaname = 'privado' and tablename = 'upload_verificacao_identidade'),
  0, 'nenhuma política expõe os slots');
select ok(not has_table_privilege('anon', 'privado.upload_verificacao_identidade', 'select')
          and not has_table_privilege('authenticated', 'privado.upload_verificacao_identidade', 'select'),
  'clientes não leem a tabela');
select ok(not has_table_privilege('service_role', 'privado.upload_verificacao_identidade', 'select')
          and not has_table_privilege('service_role', 'privado.upload_verificacao_identidade', 'update'),
  'service_role acessa o slot somente pela função privada');
select ok(not has_function_privilege('anon', 'privado.consumir_token_upload_verificacao(uuid, text)', 'execute')
          and not has_function_privilege('authenticated', 'privado.consumir_token_upload_verificacao(uuid, text)', 'execute'),
  'anon e authenticated não executam o consumo');
select ok(has_function_privilege('service_role', 'privado.consumir_token_upload_verificacao(uuid, text)', 'execute'),
  'service_role executa o consumo');

-- Constraints e token sem texto claro.
select throws_ok(
  $$ select pg_temp.upload('89000000-0000-4000-8000-0000000002f1', '89000000-0000-4000-8000-000000000101',
       'lateral', '890/101/lateral.jpg', pg_temp.token(241)) $$,
  '23514', null, 'parte fora de frente, verso e selfie é recusada');
select throws_ok(
  $$ select pg_temp.upload('89000000-0000-4000-8000-0000000002f2', '89000000-0000-4000-8000-000000000101',
       'frente', '890/101/outra-frente.jpg', pg_temp.token(242)) $$,
  '23505', null, 'cada verificação tem um único slot por parte');
select throws_ok(
  $$ select pg_temp.upload('89000000-0000-4000-8000-0000000002f3', '89000000-0000-4000-8000-000000000102',
       'verso', '890/102/verso.jpg', pg_temp.token(1)) $$,
  '23505', null, 'dois slots não compartilham o mesmo hash');
-- Cada CHECK recusa sozinho: os demais valores do insert são válidos, e a mensagem
-- nomeia a restrição que disparou.
select throws_ok(
  $$ insert into privado.upload_verificacao_identidade
       (verificacao_id, parte, storage_path, token_hash, expira_em)
     values ('89000000-0000-4000-8000-000000000103', 'selfie', '',
       pg_temp.hash_token(pg_temp.token(251)), privado.agora() + interval '2 hours') $$,
  '23514',
  'new row for relation "upload_verificacao_identidade" violates check constraint "upload_verificacao_storage_path_nao_vazio"',
  'caminho vazio é recusado');
select throws_ok(
  $$ insert into privado.upload_verificacao_identidade
       (verificacao_id, parte, storage_path, token_hash, expira_em)
     values ('89000000-0000-4000-8000-000000000103', 'selfie', '   ',
       pg_temp.hash_token(pg_temp.token(252)), privado.agora() + interval '2 hours') $$,
  '23514',
  'new row for relation "upload_verificacao_identidade" violates check constraint "upload_verificacao_storage_path_nao_vazio"',
  'caminho só com espaços é recusado');
select throws_ok(
  $$ insert into privado.upload_verificacao_identidade
       (verificacao_id, parte, storage_path, token_hash, expira_em)
     values ('89000000-0000-4000-8000-000000000103', 'selfie', '890/103/selfie.jpg',
       upper(pg_temp.hash_token(pg_temp.token(253))), privado.agora() + interval '2 hours') $$,
  '23514',
  'new row for relation "upload_verificacao_identidade" violates check constraint "upload_verificacao_token_hash_valido"',
  'hash em maiúsculas é recusado');
select throws_ok(
  $$ insert into privado.upload_verificacao_identidade
       (verificacao_id, parte, storage_path, token_hash, expira_em)
     values ('89000000-0000-4000-8000-000000000103', 'selfie', '890/103/selfie.jpg',
       left(pg_temp.hash_token(pg_temp.token(254)), 63), privado.agora() + interval '2 hours') $$,
  '23514',
  'new row for relation "upload_verificacao_identidade" violates check constraint "upload_verificacao_token_hash_valido"',
  'hash com 63 caracteres é recusado');
select throws_ok(
  $$ insert into privado.upload_verificacao_identidade
       (verificacao_id, parte, storage_path, token_hash, expira_em)
     values ('89000000-0000-4000-8000-000000000103', 'selfie', '890/103/selfie.jpg',
       pg_temp.hash_token(pg_temp.token(255)) || '0', privado.agora() + interval '2 hours') $$,
  '23514',
  'new row for relation "upload_verificacao_identidade" violates check constraint "upload_verificacao_token_hash_valido"',
  'hash com 65 caracteres é recusado');
select throws_ok(
  $$ insert into privado.upload_verificacao_identidade
       (verificacao_id, parte, storage_path, token_hash, expira_em)
     values ('89000000-0000-4000-8000-000000000103', 'selfie', '890/103/selfie.jpg',
       repeat('g', 64), privado.agora() + interval '2 hours') $$,
  '23514',
  'new row for relation "upload_verificacao_identidade" violates check constraint "upload_verificacao_token_hash_valido"',
  'hash de 64 caracteres fora de hexadecimal é recusado');
select lives_ok(
  $$ insert into privado.upload_verificacao_identidade
       (verificacao_id, parte, storage_path, token_hash, expira_em)
     values ('89000000-0000-4000-8000-000000000103', 'selfie', '890/103/selfie.jpg',
       pg_temp.hash_token(pg_temp.token(256)), privado.agora() + interval '2 hours') $$,
  'caminho preenchido e SHA-256 em minúsculas entram');
select ok((select token_hash = pg_temp.hash_token(pg_temp.token(1))
                  and position(pg_temp.token(1) in row_to_json(u)::text) = 0
             from privado.upload_verificacao_identidade u
            where id = '89000000-0000-4000-8000-000000000201'),
  'o banco guarda apenas SHA-256, nunca o token em claro');

-- Consumo e recusas.
select is(privado.consumir_token_upload_verificacao(
    '89000000-0000-4000-8000-000000000201', pg_temp.token(1)),
  jsonb_build_object('bucket', 'documentos-identidade', 'storage_path', '890/101/frente.jpg', 'parte', 'frente'),
  'o token certo devolve somente o destino reservado');
select ok((select usado_em = privado.agora() from privado.upload_verificacao_identidade
            where id = '89000000-0000-4000-8000-000000000201'),
  'o consumo fica datado');
select is(privado.consumir_token_upload_verificacao(
    '89000000-0000-4000-8000-000000000201', pg_temp.token(1)), null,
  'o token não vale uma segunda vez');
select is(privado.consumir_token_upload_verificacao(
    '89000000-0000-4000-8000-000000000202', pg_temp.token(99)), null,
  'token errado não entrega destino');
select is(privado.consumir_token_upload_verificacao(
    '89000000-0000-4000-8000-000000000202', pg_temp.token(3)), null,
  'token de outra parte não cruza o vínculo por id');
select is(privado.consumir_token_upload_verificacao(
    '89000000-0000-4000-8000-000000000202', 'nao-e-hex'), null,
  'formato inválido devolve NULL sem erro');
select is(privado.consumir_token_upload_verificacao(
    '89000000-0000-4000-8000-000000000203', pg_temp.token(3)), null,
  'token vencido não entrega destino');
select is(privado.consumir_token_upload_verificacao(
    '89000000-0000-4000-8000-000000000206', pg_temp.token(6)), null,
  'verificação fora de pendente não aceita upload');
select is(privado.consumir_token_upload_verificacao(
    '89000000-0000-4000-8000-000000000205', pg_temp.token(5)), null,
  'conta anonimizada não aceita upload');
select is(privado.consumir_token_upload_verificacao(
    '89000000-0000-4000-8000-000000000204', pg_temp.token(4)),
  jsonb_build_object('bucket', 'documentos-identidade', 'storage_path', '890/102/frente.jpg', 'parte', 'frente'),
  'conta suspensa continua podendo enviar durante a apuração');

update privado.verificacao_identidade set storage_path_verso = '890/101/verso-novo.jpg'
 where id = '89000000-0000-4000-8000-000000000101';
select is(privado.consumir_token_upload_verificacao(
    '89000000-0000-4000-8000-000000000202', pg_temp.token(2)), null,
  'slot cujo caminho não é mais o vigente da parte é recusado');

-- Reemissão troca o hash no mesmo slot: o token anterior morre e o novo vale.
update privado.upload_verificacao_identidade
   set token_hash = pg_temp.hash_token(pg_temp.token(22)),
       storage_path = '890/101/verso-novo.jpg',
       expira_em = privado.agora() + interval '2 hours',
       usado_em = null
 where id = '89000000-0000-4000-8000-000000000202';
select is(privado.consumir_token_upload_verificacao(
    '89000000-0000-4000-8000-000000000202', pg_temp.token(2)), null,
  'reemissão invalida o token anterior');
select is(privado.consumir_token_upload_verificacao(
    '89000000-0000-4000-8000-000000000202', pg_temp.token(22)),
  jsonb_build_object('bucket', 'documentos-identidade', 'storage_path', '890/101/verso-novo.jpg', 'parte', 'verso'),
  'o token reemitido entrega o caminho vigente');

delete from privado.verificacao_identidade where id = '89000000-0000-4000-8000-000000000104';
select is((select count(*)::int from privado.upload_verificacao_identidade
            where verificacao_id = '89000000-0000-4000-8000-000000000104'),
  0, 'apagar a verificação remove seus slots por cascade');

select * from finish();
rollback;
