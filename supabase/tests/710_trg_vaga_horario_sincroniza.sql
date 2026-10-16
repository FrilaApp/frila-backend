-- 710_trg_vaga_horario_sincroniza.sql
--
-- Cobertura pgTAP do trigger vaga_horario_sincroniza e da função privado.sincronizar_horario_da_posicao().
-- Regras de Negócio: Modelagem de Dados / RN21 (desnormalização de início e fim em posição).
-- Migrações: 20260922150400_vaga_e_posicao.sql:103-123 e 20260922220000_search_path_e_rls_automatico.sql:33-44.
--
-- Contexto e Conexão Arquitetural:
--   As colunas inicio_em e fim_em são desnormalizadas em public.posicao para viabilizar
--   a constraint sem_turno_sobreposto (índice GIST que impede sobreposição de turnos
--   confirmados de um mesmo profissional, pois GIST não atravessa junção).
--   O preço da desnormalização: quando o horário da vaga muda, as posições abertas
--   acompanham via trigger AFTER UPDATE OF inicio_em, fim_em.
--   Posições já confirmadas não acompanham (a mudança de horário só pode afetar vagas/posições abertas).
--
-- 1. Metadados e privilégios mínimos:
--    - Trigger registrado em public.vaga com tipo AFTER UPDATE OF inicio_em, fim_em.
--    - privado.sincronizar_horario_da_posicao() com search_path="" vazio fixado.
--    - Segurança: SECURITY INVOKER (não definer) conforme migração 20260922220000.
--    - Privilégios: service_role permitido; authenticated, anon e public negados.
-- 2. Exercício Positivo:
--    - Alteração simultânea de inicio_em e fim_em da vaga sincroniza as posições em estado 'aberta'.
--    - Posições em estado 'confirmada' preservam seus horários originais intactos.
--    - Alteração de horário em uma vaga não afeta posições de outras vagas (isolamento).
--    - Alteração unicamente de inicio_em sincroniza o início da posição aberta.
--    - Alteração unicamente de fim_em sincroniza o término da posição aberta.
-- 3. Exercício da Cláusula WHEN e Restrições de Operação:
--    - Update com inicio_em e fim_em no SET com os mesmos valores (old = new) avalia o gatilho mas é bloqueado pelo WHEN.
--    - Update em colunas normais (local, valor) sem alterar horário não aciona o gatilho.
--    - Operação de INSERT em public.vaga não aciona o gatilho (restrito a AFTER UPDATE).
-- 4. Prova de Mutação:
--    - Sem o trigger (DROP TRIGGER), a alteração do horário da vaga deixa as posições abertas inalteradas.

begin;

-- Pré-requisito canônico: habilitar ambiente de teste e congelar relógio antes de inserir dados
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local timezone = 'UTC';
set local frila.agora = '2026-10-20 12:00:00+00';

select plan(20);

-- ── 1. Metadados e Privilégios Mínimos ───────────────────────────────────────

select has_trigger(
  'public',
  'vaga',
  'vaga_horario_sincroniza',
  'tabela public.vaga possui o trigger vaga_horario_sincroniza'
);

select has_function(
  'privado',
  'sincronizar_horario_da_posicao',
  array[]::text[],
  'privado.sincronizar_horario_da_posicao() existe no schema privado'
);

select function_returns(
  'privado',
  'sincronizar_horario_da_posicao',
  array[]::text[],
  'trigger',
  'privado.sincronizar_horario_da_posicao() retorna trigger'
);

select is(
  (select prosecdef from pg_proc where proname = 'sincronizar_horario_da_posicao' and pronamespace = 'privado'::regnamespace),
  false,
  'privado.sincronizar_horario_da_posicao() é SECURITY INVOKER (não definer)'
);

select is(
  (select proconfig from pg_proc where proname = 'sincronizar_horario_da_posicao' and pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'privado.sincronizar_horario_da_posicao() possui search_path="" vazio fixado'
);

select ok(
  has_function_privilege('service_role', 'privado.sincronizar_horario_da_posicao()', 'execute'),
  'service_role pode executar privado.sincronizar_horario_da_posicao()'
);

select ok(
  not has_function_privilege('authenticated', 'privado.sincronizar_horario_da_posicao()', 'execute'),
  'authenticated não pode executar privado.sincronizar_horario_da_posicao()'
);

select ok(
  not has_function_privilege('anon', 'privado.sincronizar_horario_da_posicao()', 'execute'),
  'anon não pode executar privado.sincronizar_horario_da_posicao()'
);

select ok(
  not has_function_privilege('public', 'privado.sincronizar_horario_da_posicao()', 'execute'),
  'public não pode executar privado.sincronizar_horario_da_posicao()'
);

-- ── 2. Cenário de Teste (prefixo 710) ──────────────────────────────────────────

-- Inserção de usuários com padrão canônico (datas explícitas sem now()):
insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado
) values
  ('71000000-0000-4000-8000-000000000001', 'contratante',  'Contratante 710',  '+5561971000001', 'c710@test.com', '1985-01-01', '2026-09-22', '2026-10-20 12:00:00+00', 'ativa'),
  ('71000000-0000-4000-8000-000000000002', 'profissional', 'Profissional 710', '+5561971000002', 'p710@test.com', '1992-02-02', '2026-09-22', '2026-10-20 12:00:00+00', 'ativa');

insert into public.estabelecimento (
  id, nome, documento, tipo, endereco, ponto, regiao_administrativa
) values (
  '71000000-0000-4000-8000-000000000010', 'Restaurante 710', '99888777000177', 'food_service',
  'SCLN 310 Bloco E', 'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto'
);

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('71000000-0000-4000-8000-000000000010', '71000000-0000-4000-8000-000000000001', 'administrador');

insert into public.profissional (id, usuario_id, ponto_base) values
  ('71000000-0000-4000-8000-000000000020', '71000000-0000-4000-8000-000000000002', 'POINT(-47.8825 -15.7942)'::extensions.geography);

-- Criação de duas vagas com horário inicial definido:
insert into public.vaga (
  id, estabelecimento_id, funcao_id, ponto, local, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  inicio_em, fim_em, modo, estado, regiao_administrativa, chave_cliente, publicado_por, publicado_em
) values
  ('71000000-0000-4000-8000-000000000031', '71000000-0000-4000-8000-000000000010',
   (select id from public.funcao limit 1), 'POINT(-47.8825 -15.7942)'::extensions.geography,
   'Restaurante 710', 15000, 2, true, false, false, 'Gerente 710',
   '2026-10-25 18:00:00+00', '2026-10-25 23:00:00+00', 'urgencia', 'publicada', 'Plano Piloto',
   '71000000-0000-4000-8000-000000000031', '71000000-0000-4000-8000-000000000001', '2026-10-19 12:00:00+00'),
  ('71000000-0000-4000-8000-000000000032', '71000000-0000-4000-8000-000000000010',
   (select id from public.funcao limit 1), 'POINT(-47.8825 -15.7942)'::extensions.geography,
   'Restaurante 710', 15000, 1, true, false, false, 'Gerente 710',
   '2026-10-26 18:00:00+00', '2026-10-26 23:00:00+00', 'urgencia', 'publicada', 'Plano Piloto',
   '71000000-0000-4000-8000-000000000032', '71000000-0000-4000-8000-000000000001', '2026-10-19 12:00:00+00');

-- Posições das vagas:
-- Posição 1 da Vaga 1: aberta
-- Posição 2 da Vaga 1: confirmada
-- Posição 1 da Vaga 2: aberta
insert into public.posicao (
  id, vaga_id, estado, inicio_em, fim_em, profissional_id, confirmado_em
) values
  ('71000000-0000-4000-8000-000000000041', '71000000-0000-4000-8000-000000000031',
   'aberta', '2026-10-25 18:00:00+00', '2026-10-25 23:00:00+00', null, null),
  ('71000000-0000-4000-8000-000000000042', '71000000-0000-4000-8000-000000000031',
   'confirmada', '2026-10-25 18:00:00+00', '2026-10-25 23:00:00+00',
   '71000000-0000-4000-8000-000000000020', '2026-10-20 12:00:00+00'),
  ('71000000-0000-4000-8000-000000000051', '71000000-0000-4000-8000-000000000032',
   'aberta', '2026-10-26 18:00:00+00', '2026-10-26 23:00:00+00', null, null);

-- ── 3. Disparo Positivo: Atualização Completa de Horário ───────────────────────

-- Atualiza inicio_em e fim_em da Vaga 1:
update public.vaga
   set inicio_em = '2026-10-25 19:00:00+00',
       fim_em    = '2026-10-26 00:00:00+00'
 where id = '71000000-0000-4000-8000-000000000031';

select is(
  (select inicio_em from public.posicao where id = '71000000-0000-4000-8000-000000000041'),
  '2026-10-25 19:00:00+00'::timestamptz,
  'trigger sincroniza inicio_em em posicao aberta quando horario da vaga muda'
);

select is(
  (select fim_em from public.posicao where id = '71000000-0000-4000-8000-000000000041'),
  '2026-10-26 00:00:00+00'::timestamptz,
  'trigger sincroniza fim_em em posicao aberta quando horario da vaga muda'
);

select is(
  (select inicio_em from public.posicao where id = '71000000-0000-4000-8000-000000000042'),
  '2026-10-25 18:00:00+00'::timestamptz,
  'posicao confirmada preserva inicio_em original (filtro estado = aberta)'
);

select is(
  (select fim_em from public.posicao where id = '71000000-0000-4000-8000-000000000042'),
  '2026-10-25 23:00:00+00'::timestamptz,
  'posicao confirmada preserva fim_em original (filtro estado = aberta)'
);

select is(
  (select inicio_em from public.posicao where id = '71000000-0000-4000-8000-000000000051'),
  '2026-10-26 18:00:00+00'::timestamptz,
  'isolamento: alteracao em vaga 1 nao afeta posicao da vaga 2'
);

-- ── 4. Disparos Positivos Parciais: Unicamente Início ou Término ──────────────

-- Alteração unicamente de inicio_em da Vaga 1:
update public.vaga
   set inicio_em = '2026-10-25 19:30:00+00'
 where id = '71000000-0000-4000-8000-000000000031';

select is(
  (select inicio_em from public.posicao where id = '71000000-0000-4000-8000-000000000041'),
  '2026-10-25 19:30:00+00'::timestamptz,
  'alteracao isolada de inicio_em na vaga sincroniza inicio_em da posicao aberta'
);

select is(
  (select fim_em from public.posicao where id = '71000000-0000-4000-8000-000000000041'),
  '2026-10-26 00:00:00+00'::timestamptz,
  'alteracao isolada de inicio_em na vaga preserva fim_em inalterado na posicao aberta'
);

-- Alteração unicamente de fim_em da Vaga 1:
update public.vaga
   set fim_em = '2026-10-26 01:00:00+00'
 where id = '71000000-0000-4000-8000-000000000031';

select is(
  (select fim_em from public.posicao where id = '71000000-0000-4000-8000-000000000041'),
  '2026-10-26 01:00:00+00'::timestamptz,
  'alteracao isolada de fim_em na vaga sincroniza fim_em da posicao aberta'
);

-- ── 5. Exercício da Cláusula WHEN e Restrições de Operação ────────────────────

-- Caso 5a: Update com colunas de horário presentes no SET mas com valores idênticos (old = new)
-- O gatilho AFTER UPDATE OF inicio_em, fim_em é avaliado, mas a cláusula WHEN
-- (new.inicio_em is distinct from old.inicio_em or new.fim_em is distinct from old.fim_em)
-- é FALSA, portanto a função de sincronização não é executada.
-- Ajustamos a posição aberta para um horário divergente na sessão para provar que ela não é re-sincronizada:
update public.posicao
   set inicio_em = '2026-10-25 20:00:00+00'
 where id = '71000000-0000-4000-8000-000000000041';

-- Update na vaga passando inicio_em e fim_em no SET com valores idênticos aos atuais:
update public.vaga
   set inicio_em = '2026-10-25 19:30:00+00',
       fim_em    = '2026-10-26 01:00:00+00'
 where id = '71000000-0000-4000-8000-000000000031';

select is(
  (select inicio_em from public.posicao where id = '71000000-0000-4000-8000-000000000041'),
  '2026-10-25 20:00:00+00'::timestamptz,
  'clausula WHEN: update com inicio_em e fim_em no SET mas valores identicos nao executa sincronizacao'
);

-- Retorna a posição 1 ao horário sincronizado com a vaga para manter coerência:
update public.posicao
   set inicio_em = '2026-10-25 19:30:00+00'
 where id = '71000000-0000-4000-8000-000000000041';

-- Caso 5b: Update em coluna normal (sem inicio_em ou fim_em no SET) não dispara o gatilho:
update public.vaga
   set local = 'Restaurante 710 - Salão 2'
 where id = '71000000-0000-4000-8000-000000000031';

select is(
  (select inicio_em from public.posicao where id = '71000000-0000-4000-8000-000000000041'),
  '2026-10-25 19:30:00+00'::timestamptz,
  'update em colunas normais sem mexer em horario mantem posicoes inalteradas'
);

-- ── 6. Prova de Mutação (Sem o Gatilho Ativo) ─────────────────────────────────

-- Remove temporariamente o trigger da sessão de teste:
drop trigger vaga_horario_sincroniza on public.vaga;

-- Atualiza horário da Vaga 1 para novos valores:
update public.vaga
   set inicio_em = '2026-10-25 21:00:00+00',
       fim_em    = '2026-10-26 02:00:00+00'
 where id = '71000000-0000-4000-8000-000000000031';

select is(
  (select inicio_em from public.posicao where id = '71000000-0000-4000-8000-000000000041'),
  '2026-10-25 19:30:00+00'::timestamptz,
  'prova de mutacao: sem o trigger vaga_horario_sincroniza, alteracao de horario da vaga deixa posicao aberta inalterada'
);

select * from finish();
rollback;
