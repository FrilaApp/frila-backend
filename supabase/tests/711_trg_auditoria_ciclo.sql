-- 711_trg_auditoria_ciclo.sql
--
-- Cobertura pgTAP agrupada dos triggers de auditoria de ciclo de vida (RNF13)
-- e da função privada geradora privado.audita_ciclo().
-- Migração: 20260925220000_trilha_de_auditoria.sql:53.
--
-- Triggers cobertos:
--   1. vaga_auditoria        (public.vaga, coluna estado)
--   2. posicao_auditoria     (public.posicao, coluna estado)
--   3. candidatura_auditoria (public.candidatura, coluna estado)
--   4. turno_auditoria       (public.turno, coluna verificacao)
--   5. ocorrencia_auditoria  (public.ocorrencia, sem coluna de estado)
--   6. avaliacao_auditoria   (verificação de catálogo e integridade)
--
-- 1. Metadados e catálogo:
--    - Registro dos 6 gatilhos AFTER nas respectivas tabelas.
--    - privado.audita_ciclo() é SECURITY DEFINER com search_path="" fixado.
--    - Menor privilégio: service_role executa; authenticated, anon e public NÃO executam.
-- 2. Transições e Registro em privado.auditoria_ciclo:
--    - INSERT registra acao = 'criou', estado_anterior = NULL, estado_novo = <estado>.
--    - UPDATE de estado registra acao = 'mudou_estado', estado_anterior e estado_novo.
--    - UPDATE de colunas vizinhas que não alteram o estado NÃO gera linha redundante de auditoria.
--    - Tabelas sem estado (ocorrencia) registram acao = 'criou' com estados nulos.

begin;

-- Pré-requisito: habilitar ambiente de teste e congelar relógio antes de inserir dados
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-16 12:00:00-03';

select plan(38);

-- ── 1. Metadados e privilégios ──────────────────────────────────────────────────

select has_trigger('public', 'vaga',        'vaga_auditoria',        'tabela public.vaga possui trigger vaga_auditoria');
select has_trigger('public', 'posicao',     'posicao_auditoria',     'tabela public.posicao possui trigger posicao_auditoria');
select has_trigger('public', 'candidatura', 'candidatura_auditoria', 'tabela public.candidatura possui trigger candidatura_auditoria');
select has_trigger('public', 'turno',       'turno_auditoria',       'tabela public.turno possui trigger turno_auditoria');
select has_trigger('public', 'ocorrencia',  'ocorrencia_auditoria',  'tabela public.ocorrencia possui trigger ocorrencia_auditoria');
select has_trigger('public', 'avaliacao',   'avaliacao_auditoria',   'tabela public.avaliacao possui trigger avaliacao_auditoria');

select is(
  (select prosecdef from pg_proc where proname = 'audita_ciclo' and pronamespace = 'privado'::regnamespace),
  true,
  'privado.audita_ciclo() é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'audita_ciclo' and pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'privado.audita_ciclo() possui search_path="" fixado'
);

select ok(
  has_function_privilege('service_role', 'privado.audita_ciclo()', 'execute'),
  'service_role executa privado.audita_ciclo()'
);

select ok(
  not has_function_privilege('authenticated', 'privado.audita_ciclo()', 'execute'),
  'authenticated não executa privado.audita_ciclo()'
);

select ok(
  not has_function_privilege('anon', 'privado.audita_ciclo()', 'execute'),
  'anon não executa privado.audita_ciclo()'
);

select ok(
  not has_function_privilege('public', 'privado.audita_ciclo()', 'execute'),
  'public não executa privado.audita_ciclo()'
);

-- ── 2. Cenário Base (prefixo 711) ──────────────────────────────────────────────

insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado
) values
  ('71100000-0000-4000-8000-000000000001', 'contratante',  'Contratante 711',  '+5561971100001', 'c711@test.com', '1985-01-01', '2026-09-22', '2026-10-16 12:00:00-03', 'ativa'),
  ('71100000-0000-4000-8000-000000000002', 'profissional', 'Profissional 711', '+5561971100002', 'p711@test.com', '1992-02-02', '2026-09-22', '2026-10-16 12:00:00-03', 'ativa');

insert into public.estabelecimento (
  id, nome, documento, tipo, endereco, ponto, regiao_administrativa
) values (
  '71100000-0000-4000-8000-000000000010',
  'Restaurante Auditoria 711',
  '11223344000199',
  'food_service',
  'SCLN 405 Bloco A',
  'POINT(-47.8800 -15.7700)'::extensions.geography,
  'Plano Piloto'
);

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('71100000-0000-4000-8000-000000000010', '71100000-0000-4000-8000-000000000001', 'administrador');

insert into public.profissional (id, usuario_id, ponto_base)
values (
  '71100000-0000-4000-8000-000000000020',
  '71100000-0000-4000-8000-000000000002',
  'POINT(-47.8800 -15.7700)'::extensions.geography
);

-- ── 3. Auditoria de Vaga (vaga_auditoria) ───────────────────────────────────────

insert into public.vaga (
  id, estabelecimento_id, funcao_id, ponto, local, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  inicio_em, fim_em, modo, estado, regiao_administrativa, chave_cliente, publicado_por,
  publicado_em
) values (
  '71100000-0000-4000-8000-000000000030', '71100000-0000-4000-8000-000000000010',
  (select id from public.funcao limit 1), 'POINT(-47.8800 -15.7700)'::extensions.geography,
  'Salão 1', 17000, 1, true, false, false, 'Gerente 711',
  '2026-10-18 18:00:00-03', '2026-10-19 02:00:00-03', 'selecao', 'publicada',
  'Plano Piloto', '71100000-0000-4000-8000-0000000000c1', '71100000-0000-4000-8000-000000000001',
  '2026-10-16 12:00:00-03'
);

select is(
  (select acao from privado.auditoria_ciclo where entidade = 'vaga' and entidade_id = '71100000-0000-4000-8000-000000000030' order by id limit 1),
  'criou',
  'vaga_auditoria registra acao = criou no insert da vaga'
);

select is(
  (select estado_anterior from privado.auditoria_ciclo where entidade = 'vaga' and entidade_id = '71100000-0000-4000-8000-000000000030' order by id limit 1),
  null,
  'vaga_auditoria registra estado_anterior = null no insert'
);

select is(
  (select estado_novo from privado.auditoria_ciclo where entidade = 'vaga' and entidade_id = '71100000-0000-4000-8000-000000000030' order by id limit 1),
  'publicada',
  'vaga_auditoria registra estado_novo = publicada no insert'
);

-- UPDATE de estado na vaga
update public.vaga set estado = 'cancelada' where id = '71100000-0000-4000-8000-000000000030';

select is(
  (select acao from privado.auditoria_ciclo where entidade = 'vaga' and entidade_id = '71100000-0000-4000-8000-000000000030' order by id desc limit 1),
  'mudou_estado',
  'vaga_auditoria registra acao = mudou_estado no update de estado'
);

select is(
  (select estado_anterior from privado.auditoria_ciclo where entidade = 'vaga' and entidade_id = '71100000-0000-4000-8000-000000000030' order by id desc limit 1),
  'publicada',
  'vaga_auditoria registra estado_anterior = publicada no update'
);

select is(
  (select estado_novo from privado.auditoria_ciclo where entidade = 'vaga' and entidade_id = '71100000-0000-4000-8000-000000000030' order by id desc limit 1),
  'cancelada',
  'vaga_auditoria registra estado_novo = cancelada no update'
);

-- UPDATE em coluna vizinha sem mudar estado NÃO deve gerar nova linha de auditoria
update public.vaga set local = 'Salão Modificado' where id = '71100000-0000-4000-8000-000000000030';

select is(
  (select count(*)::int from privado.auditoria_ciclo where entidade = 'vaga' and entidade_id = '71100000-0000-4000-8000-000000000030'),
  2,
  'vaga_auditoria ignora update que nao altera a coluna de estado (return null)'
);

-- ── 4. Auditoria de Posição (posicao_auditoria) ─────────────────────────────────

insert into public.posicao (
  id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em
) values (
  '71100000-0000-4000-8000-0000000000a1', '71100000-0000-4000-8000-000000000030',
  'aberta', null, null, false, '2026-10-18 18:00:00-03', '2026-10-19 02:00:00-03'
);

select is(
  (select acao from privado.auditoria_ciclo where entidade = 'posicao' and entidade_id = '71100000-0000-4000-8000-0000000000a1' order by id limit 1),
  'criou',
  'posicao_auditoria registra acao = criou no insert de posicao'
);

select is(
  (select estado_anterior from privado.auditoria_ciclo where entidade = 'posicao' and entidade_id = '71100000-0000-4000-8000-0000000000a1' order by id limit 1),
  null,
  'posicao_auditoria registra estado_anterior = null no insert'
);

select is(
  (select estado_novo from privado.auditoria_ciclo where entidade = 'posicao' and entidade_id = '71100000-0000-4000-8000-0000000000a1' order by id limit 1),
  'aberta',
  'posicao_auditoria registra estado_novo = aberta no insert'
);

update public.posicao set estado = 'cancelada' where id = '71100000-0000-4000-8000-0000000000a1';

select is(
  (select acao from privado.auditoria_ciclo where entidade = 'posicao' and entidade_id = '71100000-0000-4000-8000-0000000000a1' order by id desc limit 1),
  'mudou_estado',
  'posicao_auditoria registra acao = mudou_estado no update de posicao'
);

select is(
  (select estado_anterior from privado.auditoria_ciclo where entidade = 'posicao' and entidade_id = '71100000-0000-4000-8000-0000000000a1' order by id desc limit 1),
  'aberta',
  'posicao_auditoria registra estado_anterior = aberta'
);

select is(
  (select estado_novo from privado.auditoria_ciclo where entidade = 'posicao' and entidade_id = '71100000-0000-4000-8000-0000000000a1' order by id desc limit 1),
  'cancelada',
  'posicao_auditoria registra estado_novo = cancelada'
);

-- ── 5. Auditoria de Candidatura (candidatura_auditoria) ─────────────────────────

insert into public.candidatura (
  id, posicao_id, profissional_id, estado
) values (
  '71100000-0000-4000-8000-0000000000d1', '71100000-0000-4000-8000-0000000000a1',
  '71100000-0000-4000-8000-000000000020', 'pendente'
);

select is(
  (select acao from privado.auditoria_ciclo where entidade = 'candidatura' and entidade_id = '71100000-0000-4000-8000-0000000000d1' order by id limit 1),
  'criou',
  'candidatura_auditoria registra acao = criou no insert de candidatura'
);

select is(
  (select estado_novo from privado.auditoria_ciclo where entidade = 'candidatura' and entidade_id = '71100000-0000-4000-8000-0000000000d1' order by id limit 1),
  'pendente',
  'candidatura_auditoria registra estado_novo = pendente'
);

update public.candidatura set estado = 'recusada' where id = '71100000-0000-4000-8000-0000000000d1';

select is(
  (select acao from privado.auditoria_ciclo where entidade = 'candidatura' and entidade_id = '71100000-0000-4000-8000-0000000000d1' order by id desc limit 1),
  'mudou_estado',
  'candidatura_auditoria registra acao = mudou_estado'
);

select is(
  (select estado_anterior from privado.auditoria_ciclo where entidade = 'candidatura' and entidade_id = '71100000-0000-4000-8000-0000000000d1' order by id desc limit 1),
  'pendente',
  'candidatura_auditoria registra estado_anterior = pendente'
);

select is(
  (select estado_novo from privado.auditoria_ciclo where entidade = 'candidatura' and entidade_id = '71100000-0000-4000-8000-0000000000d1' order by id desc limit 1),
  'recusada',
  'candidatura_auditoria registra estado_novo = recusada'
);

-- ── 6. Auditoria de Turno (turno_auditoria) ─────────────────────────────────────

insert into public.turno (
  id, posicao_id, verificacao, valor_acordado_centavos
) values (
  '71100000-0000-4000-8000-0000000000b1', '71100000-0000-4000-8000-0000000000a1',
  'pendente', 17000
);

select is(
  (select acao from privado.auditoria_ciclo where entidade = 'turno' and entidade_id = '71100000-0000-4000-8000-0000000000b1' order by id limit 1),
  'criou',
  'turno_auditoria registra acao = criou no insert de turno'
);

select is(
  (select estado_novo from privado.auditoria_ciclo where entidade = 'turno' and entidade_id = '71100000-0000-4000-8000-0000000000b1' order by id limit 1),
  'pendente',
  'turno_auditoria registra estado_novo (coluna verificacao) = pendente'
);

update public.turno set verificacao = 'nao_verificado' where id = '71100000-0000-4000-8000-0000000000b1';

select is(
  (select acao from privado.auditoria_ciclo where entidade = 'turno' and entidade_id = '71100000-0000-4000-8000-0000000000b1' order by id desc limit 1),
  'mudou_estado',
  'turno_auditoria registra acao = mudou_estado'
);

select is(
  (select estado_anterior from privado.auditoria_ciclo where entidade = 'turno' and entidade_id = '71100000-0000-4000-8000-0000000000b1' order by id desc limit 1),
  'pendente',
  'turno_auditoria registra estado_anterior = pendente'
);

select is(
  (select estado_novo from privado.auditoria_ciclo where entidade = 'turno' and entidade_id = '71100000-0000-4000-8000-0000000000b1' order by id desc limit 1),
  'nao_verificado',
  'turno_auditoria registra estado_novo = nao_verificado'
);

-- ── 7. Auditoria de Ocorrência (ocorrencia_auditoria) ───────────────────────────

insert into public.ocorrencia (
  id, tipo, autor_id, motivo, origem, criada_em
) values (
  '71100000-0000-4000-8000-0000000000e1', 'suporte',
  '71100000-0000-4000-8000-000000000001', 'Dúvida operacional de turno', 'app',
  '2026-10-16 12:00:00-03'
);

select is(
  (select acao from privado.auditoria_ciclo where entidade = 'ocorrencia' and entidade_id = '71100000-0000-4000-8000-0000000000e1'),
  'criou',
  'ocorrencia_auditoria registra acao = criou no insert de ocorrencia'
);

select is(
  (select estado_anterior from privado.auditoria_ciclo where entidade = 'ocorrencia' and entidade_id = '71100000-0000-4000-8000-0000000000e1'),
  null,
  'ocorrencia_auditoria registra estado_anterior = null'
);

select is(
  (select estado_novo from privado.auditoria_ciclo where entidade = 'ocorrencia' and entidade_id = '71100000-0000-4000-8000-0000000000e1'),
  null,
  'ocorrencia_auditoria registra estado_novo = null (entidade sem coluna de estado)'
);

select * from finish();

rollback;
