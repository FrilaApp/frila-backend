-- Remove do banco o que a 20261118100000 (#571) criou: a tabela privado.upload_verificacao_identidade
-- e a função privado.consumir_token_upload_verificacao(uuid, text).
--
-- Por quê: a verificação de identidade (RN14) saiu do produto em 19/11/2026 (decisão do Cauê). Nada
-- no código escreve nessa tabela nem chama essa função (só o teste e a corrida do próprio #571,
-- removidos junto), e o Prod nunca a recebeu: o pacote 23 (23/11) entrou sem a 20261118100000.
--
-- A 20261118100000 continua no repositório (imutável; o histórico do DEV já a tem). Esta migração
-- é quem a desfaz: no DEV remove os objetos; no Prod, numa próxima tag, a 20261118100000 cria os
-- objetos e esta, em seguida, os remove (nenhum cliente enxerga: a tabela tem RLS e nenhuma
-- permissão a anon/authenticated, e a função só ao service_role). Com `if exists`, rodar de novo
-- não faz nada.
--
-- A função primeiro: ela depende da tabela. Sem CASCADE: se algo mais dependesse delas, a migração
-- falharia em vez de levar o dependente junto.

select set_config('lock_timeout', '2s', true);

drop function if exists privado.consumir_token_upload_verificacao(uuid, text);
drop table if exists privado.upload_verificacao_identidade;
