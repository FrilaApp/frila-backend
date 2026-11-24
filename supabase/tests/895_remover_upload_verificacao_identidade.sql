-- 895_remover_upload_verificacao_identidade.sql
--
-- A 20261123150000 desfaz a 20261118100000 (#571, tokens de upload da verificação de identidade,
-- RN14 fora do produto desde 19/11/2026). Depois de todas as migrações: a tabela e a função não
-- existem, as duas versões ficam no histórico (a antiga não foi apagada) e a primitiva de upload
-- de mídia (outra, de 20261108080000) segue intacta. Dados sintéticos: o teste não insere nada.

begin;
select plan(5);

select hasnt_table('privado', 'upload_verificacao_identidade',
  'a tabela dos tokens de upload da verificação não existe mais');
select hasnt_function('privado', 'consumir_token_upload_verificacao', array['uuid', 'text'],
  'a função que consome o token de upload da verificação não existe mais');
select is((select count(*)::int from supabase_migrations.schema_migrations
            where version in ('20261118100000', '20261123150000')),
  2, 'as duas versões estão no histórico: a que criou e a que desfez');
select has_function('privado', 'consumir_token_upload', array['uuid', 'text'],
  'a primitiva de upload de mídia (outra função) continua');
select ok(to_regclass('privado.verificacao_identidade') is not null,
  'a tabela privado.verificacao_identidade (da RN14, de outra migração) não é tocada aqui');

select * from finish();
rollback;
