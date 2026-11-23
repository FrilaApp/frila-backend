-- 806_moderacao_midia_disparo_e_teto.sql
-- B4c: Testes de estrutura, RLS e disparo da moderação de mídia (RN37, RN15).

begin;

select plan(14);

-- 1. Setup
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local "frila.agora" = '2026-11-20 12:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste';
select vault.create_secret('jwt-sintetico-806-sem-valor-real-32-caracteres', 'storage_jwt_secret');

-- 2. Estrutura e isolamento de privado.moderacao_chamada
select has_table('privado', 'moderacao_chamada', 'tabela privado.moderacao_chamada existe');
select has_column('privado', 'moderacao_chamada', 'id', 'coluna id existe');
select has_column('privado', 'moderacao_chamada', 'midia_id', 'coluna midia_id existe');
select has_column('privado', 'moderacao_chamada', 'provedor', 'coluna provedor existe');
select has_column('privado', 'moderacao_chamada', 'mes', 'coluna mes existe');
select has_column('privado', 'moderacao_chamada', 'criado_em', 'coluna criado_em existe');

-- RLS e privilégios da tabela
select ok(not has_table_privilege('anon', 'privado.moderacao_chamada', 'select'), 'anon não lê moderacao_chamada');
select ok(not has_table_privilege('authenticated', 'privado.moderacao_chamada', 'select'), 'authenticated não lê moderacao_chamada');
select ok(not has_table_privilege('authenticated', 'privado.moderacao_chamada', 'insert'), 'authenticated não insere em moderacao_chamada');
select ok(has_table_privilege('service_role', 'privado.moderacao_chamada', 'insert'), 'service_role insere em moderacao_chamada');

-- 3. Função disparar_moderar_midia
select ok(has_function_privilege('service_role', 'privado.disparar_moderar_midia()', 'execute'), 'service_role executa disparar_moderar_midia');
select ok(not has_function_privilege('authenticated', 'privado.disparar_moderar_midia()', 'execute'), 'authenticated não executa disparar_moderar_midia');

-- 4. Disparo sem segredo emite warning
set local frila.agendador_secret = '';
select is(privado.disparar_moderar_midia(), null, 'sem agendador_secret retorna null');

-- 5. Disparo com segredo enfileira chamada HTTP
set local frila.agendador_secret = 'segredo-de-teste';
select isnt(privado.disparar_moderar_midia(), null, 'disparar_moderar_midia executa com sucesso e devolve id');

rollback;
