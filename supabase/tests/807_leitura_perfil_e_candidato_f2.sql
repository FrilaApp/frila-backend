-- 807_leitura_perfil_e_candidato_f2.sql
--
-- Fatia F2 / B3c: Leitura do perfil e cartão de candidato (DOC3, OpenAPI 0.2.53, RN26, RN27).
--   * Critério 1: Contratante autorizado em candidatos_da_vaga recebe preço/unidade/duração, sem telefone/nascimento/ponto base.
--   * Critério 2: Campos opcionais vazios seguem DOC3 sem quebrar decodificação do app anterior.
--   * Critério 3: Conta sem vínculo de leitura tem campos aditivos omitidos em perfil_publico e acessos não autorizados barrados.
--   * Critério 4: O dono obtém PerfilProfissionalDetalhado completo em meu_perfil_detalhado e o contratante autorizado a projeção correta.

begin;
insert into privado.ambiente values (true, true) on conflict (id) do update set eh_teste = true;
set local frila.agora = '2027-01-11 09:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste-807';
select no_plan();

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', conta, 'role', 'authenticated')::text, true);
  execute sql into r;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return r;
end $$;

create function pg_temp.como_anon(sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role anon';
  perform set_config('request.jwt.claims', '{}', true);
  execute sql into r;
  reset role;
  return r;
end $$;

create function pg_temp.erro_codigo(conta uuid, sql text) returns text language plpgsql as $$
declare
  r jsonb;
  msg text;
begin
  perform pg_temp.como(conta, sql);
  return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics msg = message_text;
  return (msg::jsonb ->> 'code');
end $$;

-- ── 1. Massa sintética ────────────────────────────────────────────────────────
insert into auth.users (id, aud, role, email) values
 ('c8070000-0000-4000-8000-000000000001','authenticated','authenticated','prof807_rico@t.test'),
 ('c8070000-0000-4000-8000-000000000002','authenticated','authenticated','prof807_min@t.test'),
 ('c8070000-0000-4000-8000-000000000003','authenticated','authenticated','casa807_vinculada@t.test'),
 ('c8070000-0000-4000-8000-000000000004','authenticated','authenticated','casa807_estranha@t.test'),
 ('c8070000-0000-4000-8000-000000000005','authenticated','authenticated','semperfil807@t.test');

select pg_temp.como('c8070000-0000-4000-8000-000000000001',
 $$select public.criar_conta('profissional','Prof Rico','+5561955558071','1992-05-10','2026-09-22')$$);
select pg_temp.como('c8070000-0000-4000-8000-000000000002',
 $$select public.criar_conta('profissional','Prof Minimo','+5561955558072','1995-08-15','2026-09-22')$$);
select pg_temp.como('c8070000-0000-4000-8000-000000000003',
 $$select public.criar_conta('contratante','Dono Casa Vinculada','+5561955558073','1985-03-20','2026-09-22')$$);
select pg_temp.como('c8070000-0000-4000-8000-000000000004',
 $$select public.criar_conta('contratante','Dono Casa Estranha','+5561955558074','1988-11-25','2026-09-22')$$);
select pg_temp.como('c8070000-0000-4000-8000-000000000005',
 $$select public.criar_conta('profissional','Sem Perfil','+5561955558075','1990-01-01','2026-09-22')$$);

-- Estabelecimentos
select pg_temp.como('c8070000-0000-4000-8000-000000000003',
  $$select public.cadastrar_estabelecimento('Bar do Vinculo','04252011000110','food_service','CLS 405 Bloco A','{"latitude":-15.79,"longitude":-47.88}'::jsonb,'Plano Piloto')$$);
select pg_temp.como('c8070000-0000-4000-8000-000000000004',
  $$select public.cadastrar_estabelecimento('Restaurante Estranho','68558622000173','food_service','CLN 102 Bloco B','{"latitude":-15.79,"longitude":-47.88}'::jsonb,'Plano Piloto')$$);

-- Perfis profissionais
insert into public.profissional (id, usuario_id, ponto_base) values
 ('c8070000-0000-4000-8000-000000000011', 'c8070000-0000-4000-8000-000000000001', 'POINT(-47.88 -15.79)'),
 ('c8070000-0000-4000-8000-000000000012', 'c8070000-0000-4000-8000-000000000002', 'POINT(-47.88 -15.79)');

insert into public.profissional_funcao (profissional_id, funcao_id)
select 'c8070000-0000-4000-8000-000000000011'::uuid, id from public.funcao where nome = 'garçom'
union all
select 'c8070000-0000-4000-8000-000000000012'::uuid, id from public.funcao where nome = 'garçom';

-- Profissional 1 preenche serviços e apresentação
select pg_temp.como('c8070000-0000-4000-8000-000000000001',
 $$select public.atualizar_apresentacao_profissional(jsonb_build_object(
   'apresentacao', 'Garçom profissional com 6 anos de experiência em eventos',
   'onde_trabalhei', 'Restaurante Lago 2020-2024',
   'experiencia_faixa', 'de_5_a_10_anos',
   'cursos', array['Atendimento de Excelência'],
   'idiomas', array['ingles']
 ))$$);

select pg_temp.como('c8070000-0000-4000-8000-000000000001',
 $$select public.definir_servicos(jsonb_build_array(
   jsonb_build_object(
     'funcao_id', (select id from public.funcao where nome = 'garçom'),
     'unidade', 'diaria',
     'valor_centavos', 20000,
     'horas_incluidas', 8,
     'leva_material', 'nao',
     'especialidade_ids', jsonb_build_array()
   )
 ))$$);

select pg_temp.como('c8070000-0000-4000-8000-000000000001',
 $$select public.definir_regioes_atendidas(array[(select id from public.regiao_administrativa where nome = 'Plano Piloto')], false)$$);

-- Casa 1 publica vaga no modo seleção e Profissional 1 se candidata
select pg_temp.como('c8070000-0000-4000-8000-000000000003',
  format($$select public.publicar_vaga(
    (select id from public.estabelecimento where nome = 'Bar do Vinculo'),
    (select id from public.funcao where nome = 'garçom'),
    '2027-01-15 18:00:00+00'::timestamptz,
    '2027-01-16 02:00:00+00'::timestamptz,
    'CLS 405 Bloco A',
    '{"latitude": -15.79, "longitude": -47.88}'::jsonb,
    20000,
    1,
    true, false, false,
    'Gerente Marcos',
    'selecao',
    %L::uuid,
    'preto completo',
    false,
    null,
    180,
    'Plano Piloto'
  )$$, gen_random_uuid()));

-- Prof 1 se candidata à vaga da Casa 1 (criando o vínculo legítimo de leitura)
select pg_temp.como('c8070000-0000-4000-8000-000000000001',
 format($$select public.candidatar((select id from public.vaga where local = 'CLS 405 Bloco A'))$$));

-- ── 2. Testes de meu_perfil_detalhado (Critério 4 e autorização) ──────────────

-- Anon sem sessão é barrado
select throws_ok(
  $$select pg_temp.como_anon('select public.meu_perfil_detalhado()')$$ ,
  '42501',
  null,
  'meu_perfil_detalhado: anon sem sessão não possui execute'
);

-- Chamador não autenticado (via auxiliar erro)
select is(
  pg_temp.erro_codigo(null, $$select public.meu_perfil_detalhado()$$),
  'nao_autenticado',
  'meu_perfil_detalhado: chamador nulo responde 401 nao_autenticado'
);

-- Contratante é perfil incompatível (RN25)
select is(
  pg_temp.erro_codigo('c8070000-0000-4000-8000-000000000003', $$select public.meu_perfil_detalhado()$$),
  'perfil_incompativel',
  'meu_perfil_detalhado: conta contratante responde 422 perfil_incompativel'
);

-- Profissional sem perfil cadastrado é 404
select is(
  pg_temp.erro_codigo('c8070000-0000-4000-8000-000000000005', $$select public.meu_perfil_detalhado()$$),
  'nao_encontrado',
  'meu_perfil_detalhado: profissional sem cadastro responde 404 nao_encontrado'
);

-- Profissional 1 obtém seu PerfilProfissionalDetalhado completo
select is(
  (pg_temp.como('c8070000-0000-4000-8000-000000000001', $$select public.meu_perfil_detalhado()$$) ->> 'apresentacao'),
  'Garçom profissional com 6 anos de experiência em eventos',
  'meu_perfil_detalhado: dono lê apresentacao'
);
select is(
  (pg_temp.como('c8070000-0000-4000-8000-000000000001', $$select public.meu_perfil_detalhado()$$) ->> 'experiencia_faixa'),
  'de_5_a_10_anos',
  'meu_perfil_detalhado: dono lê experiencia_faixa'
);
select is(
  (pg_temp.como('c8070000-0000-4000-8000-000000000001', $$select public.meu_perfil_detalhado()$$) -> 'servicos' -> 0 ->> 'unidade'),
  'diaria',
  'meu_perfil_detalhado: dono lê servicos com unidade diaria'
);
select is(
  ((pg_temp.como('c8070000-0000-4000-8000-000000000001', $$select public.meu_perfil_detalhado()$$) -> 'servicos' -> 0 ->> 'valor_centavos')::bigint),
  20000::bigint,
  'meu_perfil_detalhado: dono lê valor_centavos do servico'
);

-- Profissional 2 (mínimo) obtém PerfilProfissionalDetalhado sem quebrar (Critério 2)
select is(
  (pg_temp.como('c8070000-0000-4000-8000-000000000002', $$select public.meu_perfil_detalhado()$$) ->> 'apresentacao'),
  null,
  'meu_perfil_detalhado minimo: apresentacao e nula'
);
select is(
  (jsonb_array_length(pg_temp.como('c8070000-0000-4000-8000-000000000002', $$select public.meu_perfil_detalhado()$$) -> 'servicos')),
  0,
  'meu_perfil_detalhado minimo: servicos e array vazio []'
);
select is(
  (jsonb_array_length(pg_temp.como('c8070000-0000-4000-8000-000000000002', $$select public.meu_perfil_detalhado()$$) -> 'regioes')),
  0,
  'meu_perfil_detalhado minimo: regioes e array vazio []'
);

-- ── 3. Testes de candidatos_da_vaga (Critérios 1, 2 e privacidade) ────────────

-- Contratante da vaga (Casa 1) lê candidatos_da_vaga
create temp table cands as
  select pg_temp.como('c8070000-0000-4000-8000-000000000003',
    format($$select public.candidatos_da_vaga((select id from public.vaga where local = 'CLS 405 Bloco A'))$$)) as res;

select is(
  (select jsonb_array_length(res) from cands),
  1,
  'candidatos_da_vaga: retorna 1 candidato pendente'
);

-- Critério 1: Contratante autorizado recebe preço, unidade e duração
select is(
  (select res -> 0 -> 'profissional' -> 'servicos' -> 0 ->> 'unidade' from cands),
  'diaria',
  'Critério 1: candidato no cartao traz unidade diaria'
);
select is(
  (select (res -> 0 -> 'profissional' -> 'servicos' -> 0 ->> 'valor_centavos')::bigint from cands),
  20000::bigint,
  'Critério 1: candidato no cartao traz valor_centavos de 20000'
);
select is(
  (select (res -> 0 -> 'profissional' -> 'servicos' -> 0 ->> 'horas_incluidas')::int from cands),
  8,
  'Critério 1: candidato no cartao traz horas_incluidas de 8h'
);

-- Critério 1 (Privacidade): Proibição estrita de telefone, nascimento ou ponto base
select is(
  (select res -> 0 -> 'profissional' ? 'telefone' from cands),
  false,
  'Critério 1: perfil do candidato NUNCA expoe telefone (RN10)'
);
select is(
  (select res -> 0 -> 'profissional' ? 'nascimento' from cands),
  false,
  'Critério 1: perfil do candidato NUNCA expoe data de nascimento'
);
select is(
  (select res -> 0 -> 'profissional' ? 'ponto_base' from cands),
  false,
  'Critério 1: perfil do candidato NUNCA expoe ponto base geografico'
);

-- ── 4. Testes de perfil_publico com e sem vínculo (Critérios 3 e 4) ───────────

-- Casa 1 (COM vínculo por candidatura): recebe campos de perfil rico
create temp table perf_vinculado as
  select pg_temp.como('c8070000-0000-4000-8000-000000000003',
    $$select public.perfil_publico('c8070000-0000-4000-8000-000000000011'::uuid)$$) as res;

select is(
  (select res ->> 'apresentacao' from perf_vinculado),
  'Garçom profissional com 6 anos de experiência em eventos',
  'Critério 4: leitor com vinculo recebe apresentacao em perfil_publico'
);
select is(
  (select res ->> 'no_frila_desde' from perf_vinculado),
  to_char(now(), 'YYYY-MM'),
  'Critério 4: leitor com vinculo recebe no_frila_desde (AAAA-MM)'
);
select is(
  (select jsonb_array_length(res -> 'servicos') from perf_vinculado),
  1,
  'Critério 4: leitor com vinculo recebe servicos'
);

-- Casa 2 (SEM vínculo): campos do perfil rico são ESTRITAMENTE OMITIDOS (Critério 3)
create temp table perf_estranho as
  select pg_temp.como('c8070000-0000-4000-8000-000000000004',
    $$select public.perfil_publico('c8070000-0000-4000-8000-000000000011'::uuid)$$) as res;

select is(
  (select res ->> 'nome' from perf_estranho),
  'Prof Rico',
  'Critério 3: leitor sem vinculo recebe o nome publico'
);
select is(
  (select res ? 'apresentacao' from perf_estranho),
  false,
  'Critério 3: leitor sem vinculo NAO recebe chave apresentacao'
);
select is(
  (select res ? 'onde_trabalhei' from perf_estranho),
  false,
  'Critério 3: leitor sem vinculo NAO recebe chave onde_trabalhei'
);
select is(
  (select res ? 'experiencia_faixa' from perf_estranho),
  false,
  'Critério 3: leitor sem vinculo NAO recebe chave experiencia_faixa'
);
select is(
  (select res ? 'servicos' from perf_estranho),
  false,
  'Critério 3: leitor sem vinculo NAO recebe chave servicos'
);
select is(
  (select res ? 'regioes' from perf_estranho),
  false,
  'Critério 3: leitor sem vinculo NAO recebe chave regioes'
);
select is(
  (select res ? 'cursos' from perf_estranho),
  false,
  'Critério 3: leitor sem vinculo NAO recebe chave cursos'
);
select is(
  (select res ? 'idiomas' from perf_estranho),
  false,
  'Critério 3: leitor sem vinculo NAO recebe chave idiomas'
);
select is(
  (select res ? 'no_frila_desde' from perf_estranho),
  false,
  'Critério 3: leitor sem vinculo NAO recebe chave no_frila_desde'
);

-- Outro profissional lendo perfil_publico: também não recebe campos de vínculo
select is(
  (pg_temp.como('c8070000-0000-4000-8000-000000000002',
    $$select public.perfil_publico('c8070000-0000-4000-8000-000000000011'::uuid)$$) ? 'apresentacao'),
  false,
  'Critério 3: profissional lendo outro profissional nao recebe apresentacao'
);

-- Estabelecimento estranho tentando ler candidatos de vaga alheia é 403
select is(
  pg_temp.erro_codigo('c8070000-0000-4000-8000-000000000004',
    format($$select public.candidatos_da_vaga(%L::uuid)$$, (select id from public.vaga where local = 'CLS 405 Bloco A'))),
  'sem_permissao',
  'Critério 3: contratante de outro estabelecimento recebe 403 sem_permissao em candidatos_da_vaga'
);

-- Dinâmica de vínculo: adicionar Prof 1 à equipe de confiança da Casa 2 concede vínculo
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
values (
  (select id from public.estabelecimento where nome = 'Restaurante Estranho'),
  'c8070000-0000-4000-8000-000000000011'
);

-- Agora Casa 2 tem vínculo com Prof 1 via equipe de confiança
select is(
  (pg_temp.como('c8070000-0000-4000-8000-000000000004',
    $$select public.perfil_publico('c8070000-0000-4000-8000-000000000011'::uuid)$$) ? 'servicos'),
  true,
  'Dinamica de vinculo: inclusao em equipe_confianca concede projecao de servicos'
);

-- ── 5. Regressões contra vazamento de dados pessoais (Bloqueio Mútuo e Conta Excluída) ──

-- Casa 1 escolhe o candidato Prof 1 para confirmar turno
select pg_temp.como('c8070000-0000-4000-8000-000000000003',
  format($$select public.escolher_candidato(%L)$$, (select id from public.candidatura where profissional_id = 'c8070000-0000-4000-8000-000000000011')));

-- Antes de qualquer bloqueio: contratante da casa lê turno e painel com dados F2
create temp table turnos_antes as
  select pg_temp.como('c8070000-0000-4000-8000-000000000003',
    format($$select public.meus_turnos(null, null, %L)$$, (select id from public.estabelecimento where nome = 'Bar do Vinculo'))) as r;
select is(
  ((select r from turnos_antes) -> 0 -> 'contraparte' ? 'apresentacao'),
  true,
  'Baseline com vinculo: contraparte no turno possui apresentacao F2'
);

-- Cenário A: Profissional bloqueia o estabelecimento
select pg_temp.como('c8070000-0000-4000-8000-000000000001',
  format($$select public.bloquear('estabelecimento', %L)$$, (select id from public.estabelecimento where nome = 'Bar do Vinculo')));

-- 1. Perfil público direto responde 404
select is(
  pg_temp.erro_codigo('c8070000-0000-4000-8000-000000000003',
    $$select public.perfil_publico('c8070000-0000-4000-8000-000000000011'::uuid)$$),
  'nao_encontrado',
  'Bloqueio Prof->Casa: perfil_publico responde 404'
);

-- 2. meus_turnos da casa OMITA apresentação e dados F2 da contraparte
create temp table turnos_bloq_prof as
  select pg_temp.como('c8070000-0000-4000-8000-000000000003',
    format($$select public.meus_turnos(null, null, %L)$$, (select id from public.estabelecimento where nome = 'Bar do Vinculo'))) as r;
select is(
  ((select r from turnos_bloq_prof) -> 0 -> 'contraparte' ? 'apresentacao'),
  false,
  'Bloqueio Prof->Casa: meus_turnos omite apresentacao F2'
);

-- 3. painel_estabelecimento da casa OMITA histórico de emprego / texto livre F2
create temp table painel_bloq_prof as
  select pg_temp.como('c8070000-0000-4000-8000-000000000003',
    format($$select public.painel_estabelecimento(%L, '2027-01-01'::timestamptz, '2027-02-01'::timestamptz)$$,
      (select id from public.estabelecimento where nome = 'Bar do Vinculo'))) as r;
select is(
  ((select r from painel_bloq_prof)::text like '%Restaurante Lago 2020-2024%'),
  false,
  'Bloqueio Prof->Casa: painel_estabelecimento omite historico profissional F2'
);

-- Remove bloqueio do profissional
delete from public.bloqueio where autor_id = 'c8070000-0000-4000-8000-000000000001';

-- Cenário B: Casa bloqueia o profissional
select pg_temp.como('c8070000-0000-4000-8000-000000000003',
  $$select public.bloquear('profissional', 'c8070000-0000-4000-8000-000000000011')$$);

-- 1. Perfil público direto responde 404
select is(
  pg_temp.erro_codigo('c8070000-0000-4000-8000-000000000003',
    $$select public.perfil_publico('c8070000-0000-4000-8000-000000000011'::uuid)$$),
  'nao_encontrado',
  'Bloqueio Casa->Prof: perfil_publico responde 404'
);

-- 2. meus_turnos da casa OMITA apresentação F2 da contraparte
create temp table turnos_bloq_casa as
  select pg_temp.como('c8070000-0000-4000-8000-000000000003',
    format($$select public.meus_turnos(null, null, %L)$$, (select id from public.estabelecimento where nome = 'Bar do Vinculo'))) as r;
select is(
  ((select r from turnos_bloq_casa) -> 0 -> 'contraparte' ? 'apresentacao'),
  false,
  'Bloqueio Casa->Prof: meus_turnos omite apresentacao F2'
);

-- 3. painel_estabelecimento da casa OMITA histórico de emprego F2
create temp table painel_bloq_casa as
  select pg_temp.como('c8070000-0000-4000-8000-000000000003',
    format($$select public.painel_estabelecimento(%L, '2027-01-01'::timestamptz, '2027-02-01'::timestamptz)$$,
      (select id from public.estabelecimento where nome = 'Bar do Vinculo'))) as r;
select is(
  ((select r from painel_bloq_casa)::text like '%Restaurante Lago 2020-2024%'),
  false,
  'Bloqueio Casa->Prof: painel_estabelecimento omite historico profissional F2'
);

-- Remove bloqueio da casa
delete from public.bloqueio where autor_id = 'c8070000-0000-4000-8000-000000000003';

-- Cenário C: Exclusão real da conta do profissional (privado.excluir_conta)
select privado.excluir_conta('c8070000-0000-4000-8000-000000000001');

-- 1. perfil_publico responde 200 'Conta encerrada' e OMITA apresentação e campos F2
create temp table perfil_excluido as
  select pg_temp.como('c8070000-0000-4000-8000-000000000003',
    $$select public.perfil_publico('c8070000-0000-4000-8000-000000000011'::uuid)$$) as r;
select is(
  ((select r from perfil_excluido) ->> 'nome'),
  'Conta encerrada',
  'Conta excluida: nome exibido e Conta encerrada'
);
select is(
  ((select r from perfil_excluido) ? 'apresentacao'),
  false,
  'Conta excluida: perfil_publico omite apresentacao'
);
select is(
  ((select r from perfil_excluido) ? 'onde_trabalhei'),
  false,
  'Conta excluida: perfil_publico omite onde_trabalhei'
);
select is(
  ((select r from perfil_excluido) ? 'cursos'),
  false,
  'Conta excluida: perfil_publico omite cursos'
);
select is(
  ((select r from perfil_excluido) ? 'idiomas'),
  false,
  'Conta excluida: perfil_publico omite idiomas'
);
select is(
  ((select r from perfil_excluido) ? 'servicos'),
  false,
  'Conta excluida: perfil_publico omite servicos'
);
select is(
  ((select r from perfil_excluido) ? 'regioes'),
  false,
  'Conta excluida: perfil_publico omite regioes'
);

-- 2. meus_turnos da contraparte tem 'Conta encerrada' e OMITA apresentacao
create temp table turnos_excluido as
  select pg_temp.como('c8070000-0000-4000-8000-000000000003',
    format($$select public.meus_turnos(null, null, %L)$$, (select id from public.estabelecimento where nome = 'Bar do Vinculo'))) as r;
select is(
  ((select r from turnos_excluido) -> 0 -> 'contraparte' ->> 'nome'),
  'Conta encerrada',
  'Conta excluida: contraparte em meus_turnos tem nome Conta encerrada'
);
select is(
  ((select r from turnos_excluido) -> 0 -> 'contraparte' ? 'apresentacao'),
  false,
  'Conta excluida: contraparte em meus_turnos omite apresentacao'
);

-- 3. painel_estabelecimento da contraparte OMITA histórico de emprego F2
create temp table painel_excluido as
  select pg_temp.como('c8070000-0000-4000-8000-000000000003',
    format($$select public.painel_estabelecimento(%L, '2027-01-01'::timestamptz, '2027-02-01'::timestamptz)$$,
      (select id from public.estabelecimento where nome = 'Bar do Vinculo'))) as r;
select is(
  ((select r from painel_excluido)::text like '%Restaurante Lago 2020-2024%'),
  false,
  'Conta excluida: painel_estabelecimento omite historico profissional F2'
);

select * from finish();
rollback;
