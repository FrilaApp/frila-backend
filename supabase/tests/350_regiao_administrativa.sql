-- `350_regiao_administrativa.sql`: Região administrativa em estabelecimento, vaga e RPCs.
--
-- Requisito: x0jkygj0 (S2 · Backend · Região administrativa do local da vaga e interpolação nos pushes).
-- Contrato: 0.2.20 (NovoEstabelecimento, Estabelecimento, NovaVaga, VagaResumo, Vaga, VagaNaLista).

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(20);

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

-- ── 1. Estrutura do banco: colunas NOT NULL com CHECK não vazio ─────────────────
select has_column('public', 'estabelecimento', 'regiao_administrativa',
  'estabelecimento tem coluna regiao_administrativa');
select col_not_null('public', 'estabelecimento', 'regiao_administrativa',
  'estabelecimento.regiao_administrativa é NOT NULL');

select has_column('public', 'vaga', 'regiao_administrativa',
  'vaga tem coluna regiao_administrativa');
select col_not_null('public', 'vaga', 'regiao_administrativa',
  'vaga.regiao_administrativa é NOT NULL');

-- ── Contas de teste ────────────────────────────────────────────────────────────
select pg_temp.autenticar('d1000000-0000-4000-8000-000000000001', 'dona.ra@frila.test');
select pg_temp.autenticar('d1000000-0000-4000-8000-000000000002', 'garcom.ra@frila.test');

select pg_temp.como('d1000000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante', 'Dona RA', '+5561999990301', '1985-05-10', '2026-09-22') $$);
select pg_temp.como('d1000000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('profissional', 'Garçom RA', '+5561999990302', '1990-06-15', '2026-09-22') $$);

select pg_temp.como('d1000000-0000-4000-8000-000000000002',
  format($$ select public.criar_perfil_profissional(
              array[%L]::uuid[],
              '{"latitude":-15.7942,"longitude":-47.8822}'::jsonb) $$,
         (select id from public.funcao where nome = 'garçom')));

-- ── 2. cadastrar_estabelecimento ───────────────────────────────────────────────
-- Recusa regiao_administrativa vazia
select throws_ok(
  $$ select pg_temp.como('d1000000-0000-4000-8000-000000000001',
       $x$ select public.cadastrar_estabelecimento(
             'Bar Vazio', '04252011000110', 'food_service',
             'CLN 201', '{"latitude":-15.7942,"longitude":-47.8822}',
             '') $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "regiao_administrativa", "hint" : null}',
  'regiao_administrativa vazia em cadastrar_estabelecimento é recusada com 422 campo_obrigatorio');

-- Recusa termo ofensivo em regiao_administrativa
select throws_ok(
  $$ select pg_temp.como('d1000000-0000-4000-8000-000000000001',
       $x$ select public.cadastrar_estabelecimento(
             'Bar Ofensivo', '04252011000110', 'food_service',
             'CLN 201', '{"latitude":-15.7942,"longitude":-47.8822}',
             'caralho') $x$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "regiao_administrativa", "hint" : null}',
  'termo ofensivo em regiao_administrativa no cadastrar_estabelecimento é recusado com 422 campo_invalido');

-- Sucesso no cadastro com regiao_administrativa
create temp table t_estab as
  select (pg_temp.como('d1000000-0000-4000-8000-000000000001',
    $$ select public.cadastrar_estabelecimento(
         'Bar Raiz', '04252011000110', 'food_service',
         'CLN 201 Bloco B', '{"latitude":-15.7942,"longitude":-47.8822}',
         'Plano Piloto') $$)) as r;

select is((select r->>'regiao_administrativa' from t_estab), 'Plano Piloto',
  'cadastrar_estabelecimento devolve regiao_administrativa no schema Estabelecimento');

select is(
  (select regiao_administrativa from public.estabelecimento where documento = '04252011000110'),
  'Plano Piloto',
  'estabelecimento gravado tem regiao_administrativa = Plano Piloto');

select throws_ok(
  $$ update public.estabelecimento set regiao_administrativa = '   ' where documento = '04252011000110' $$,
  '23514',
  null,
  'estabelecimento_regiao_administrativa_check: regiao_administrativa não pode ser vazia ou só espaços');

-- ── 3. publicar_vaga ──────────────────────────────────────────────────────────
create temp table vars as
  select (r->>'id')::uuid as estab_id,
         (select id from public.funcao where nome = 'garçom') as func_id
    from t_estab;

-- Recusa regiao_administrativa vazia se informada explicitamente
select throws_ok(
  format($x$ select pg_temp.como('d1000000-0000-4000-8000-000000000001',
               $$ select public.publicar_vaga(
                    estabelecimento_id     => '%s'::uuid,
                    funcao_id              => '%s'::uuid,
                    inicio_em              => privado.agora() + interval '4 hours',
                    fim_em                 => privado.agora() + interval '8 hours',
                    local                  => 'CLN 201',
                    ponto                  => '{"latitude":-15.7942,"longitude":-47.8822}'::jsonb,
                    valor_centavos         => 18000,
                    posicoes               => 1,
                    inclui_refeicao        => true,
                    inclui_transporte      => true,
                    exige_material_proprio => false,
                    responsavel_local      => 'Seu Zé',
                    modo                   => 'urgencia',
                    chave                  => gen_random_uuid(),
                    regiao_administrativa  => '') $$) $x$,
         (select estab_id from vars), (select func_id from vars)),
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "regiao_administrativa", "hint" : null}',
  'regiao_administrativa vazia em publicar_vaga é recusada com 422 campo_obrigatorio');

-- Recusa termo ofensivo em regiao_administrativa
select throws_ok(
  format($x$ select pg_temp.como('d1000000-0000-4000-8000-000000000001',
               $$ select public.publicar_vaga(
                    estabelecimento_id     => '%s'::uuid,
                    funcao_id              => '%s'::uuid,
                    inicio_em              => privado.agora() + interval '4 hours',
                    fim_em                 => privado.agora() + interval '8 hours',
                    local                  => 'CLN 201',
                    ponto                  => '{"latitude":-15.7942,"longitude":-47.8822}'::jsonb,
                    valor_centavos         => 18000,
                    posicoes               => 1,
                    inclui_refeicao        => true,
                    inclui_transporte      => true,
                    exige_material_proprio => false,
                    responsavel_local      => 'Seu Zé',
                    modo                   => 'urgencia',
                    chave                  => gen_random_uuid(),
                    regiao_administrativa  => 'porra') $$) $x$,
         (select estab_id from vars), (select func_id from vars)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "regiao_administrativa", "hint" : null}',
  'termo ofensivo em regiao_administrativa em publicar_vaga é recusado com 422 campo_invalido');

-- Publicação com regiao_administrativa explícita (Taguatinga)
create temp table t_vaga1 as
  select (pg_temp.como('d1000000-0000-4000-8000-000000000001',
    format($x$ select public.publicar_vaga(
                 estabelecimento_id     => '%s'::uuid,
                 funcao_id              => '%s'::uuid,
                 inicio_em              => privado.agora() + interval '4 hours',
                 fim_em                 => privado.agora() + interval '8 hours',
                 local                  => 'QND 25, Comercial Norte',
                 ponto                  => '{"latitude":-15.8300,"longitude":-48.0500}'::jsonb,
                 valor_centavos         => 20000,
                 posicoes               => 1,
                 inclui_refeicao        => true,
                 inclui_transporte      => true,
                 exige_material_proprio => false,
                 responsavel_local      => 'Gerente Taguatinga',
                 modo                   => 'urgencia',
                 chave                  => gen_random_uuid(),
                 regiao_administrativa  => 'Taguatinga') $x$,
           estab_id, func_id))) as r
    from vars;

select is(
  (select regiao_administrativa from public.vaga where id = (select (r->>'vaga_id')::uuid from t_vaga1)),
  'Taguatinga',
  'vaga com regiao_administrativa explícita grava Taguatinga');

select throws_ok(
  format($$ update public.vaga set regiao_administrativa = '   ' where id = %L $$,
         (select (r->>'vaga_id')::uuid from t_vaga1)),
  '23514',
  null,
  'vaga_regiao_administrativa_check: regiao_administrativa não pode ser vazia ou só espaços');

-- Publicação sem regiao_administrativa informada herda a do estabelecimento (Plano Piloto)
create temp table t_vaga2 as
  select (pg_temp.como('d1000000-0000-4000-8000-000000000001',
    format($x$ select public.publicar_vaga(
                 estabelecimento_id     => '%s'::uuid,
                 funcao_id              => '%s'::uuid,
                 inicio_em              => privado.agora() + interval '5 hours',
                 fim_em                 => privado.agora() + interval '9 hours',
                 local                  => 'CLN 201 Bloco B',
                 ponto                  => '{"latitude":-15.7942,"longitude":-47.8822}'::jsonb,
                 valor_centavos         => 18000,
                 posicoes               => 1,
                 inclui_refeicao        => true,
                 inclui_transporte      => true,
                 exige_material_proprio => false,
                 responsavel_local      => 'Seu Zé',
                 modo                   => 'urgencia',
                 chave                  => gen_random_uuid()) $x$,
           estab_id, func_id))) as r
    from vars;

select is(
  (select regiao_administrativa from public.vaga where id = (select (r->>'vaga_id')::uuid from t_vaga2)),
  'Plano Piloto',
  'publicar_vaga sem regiao_administrativa herda do estabelecimento (Plano Piloto)');

-- ── 4. republicar_vaga ────────────────────────────────────────────────────────
create temp table t_repub as
  select (pg_temp.como('d1000000-0000-4000-8000-000000000001',
    format($x$ select public.republicar_vaga(
                 vaga_id   => '%s'::uuid,
                 inicio_em => privado.agora() + interval '24 hours',
                 fim_em    => privado.agora() + interval '28 hours',
                 chave     => gen_random_uuid()) $x$,
           (select (r->>'vaga_id')::uuid from t_vaga1)))) as r;

select is(
  (select regiao_administrativa from public.vaga where id = (select (r->>'vaga_id')::uuid from t_repub)),
  'Taguatinga',
  'republicar_vaga preserva regiao_administrativa da vaga de origem');

-- ── 5. vagas_abertas ──────────────────────────────────────────────────────────
create temp table t_lista as
  select pg_temp.como('d1000000-0000-4000-8000-000000000002',
    $$ select public.vagas_abertas(latitude => -15.7942, longitude => -47.8822) $$) as r;

select is(
  (select (jsonb_path_query_first(r, '$[*] ? (@.id == $vaga).regiao_administrativa',
                                  jsonb_build_object('vaga', (select r->>'vaga_id' from t_vaga1))
                                 )) #>> '{}'
     from t_lista),
  'Taguatinga',
  'vagas_abertas expõe regiao_administrativa no schema VagaNaLista');

-- ── 6. detalhe_vaga ───────────────────────────────────────────────────────────
create temp table t_detalhe as
  select pg_temp.como('d1000000-0000-4000-8000-000000000002',
    format($$ select public.detalhe_vaga('%s'::uuid) $$,
           (select (r->>'vaga_id')::uuid from t_vaga1))) as r;

select is((select r->>'regiao_administrativa' from t_detalhe), 'Taguatinga',
  'detalhe_vaga expõe regiao_administrativa no schema Vaga');

-- ── 7. painel_estabelecimento ─────────────────────────────────────────────────
create temp table t_painel as
  select pg_temp.como('d1000000-0000-4000-8000-000000000001',
    format($x$ select public.painel_estabelecimento(
                 estabelecimento_id => '%s'::uuid,
                 de                 => privado.agora() - interval '1 hour',
                 ate                => privado.agora() + interval '48 hours') $x$,
           (select estab_id from vars))) as r;

select is(
  (select (jsonb_path_query_first(r, '$.vagas[*] ? (@.vaga.id == $vaga).vaga.regiao_administrativa',
                                  jsonb_build_object('vaga', (select r->>'vaga_id' from t_vaga1))
                                 )) #>> '{}'
     from t_painel),
  'Taguatinga',
  'painel_estabelecimento expõe regiao_administrativa no VagaResumo da vaga');

-- ── 8. privado.turno_em_json / meus_turnos ────────────────────────────────────
-- Candidata na vaga 1
create temp table t_cand as
  select (pg_temp.como('d1000000-0000-4000-8000-000000000002',
    format($$ select public.candidatar('%s'::uuid) $$,
           (select (r->>'vaga_id')::uuid from t_vaga1)))) as r;

create temp table t_turno_json as
  select privado.turno_em_json(
           (select (r->>'turno_id')::uuid from t_cand),
           'd1000000-0000-4000-8000-000000000002'::uuid) as r;

select is(
  (select r->'vaga'->>'regiao_administrativa' from t_turno_json),
  'Taguatinga',
  'privado.turno_em_json expõe regiao_administrativa no VagaResumo do turno');

-- meus_turnos
create temp table t_meus_turnos as
  select pg_temp.como('d1000000-0000-4000-8000-000000000002',
    $$ select public.meus_turnos() $$) as r;

select is(
  (select (jsonb_path_query_first(r, '$[*] ? (@.id == $tid).vaga.regiao_administrativa',
                                  jsonb_build_object('tid', (select r->>'turno_id' from t_cand))
                                 )) #>> '{}'
     from t_meus_turnos),
  'Taguatinga',
  'meus_turnos expõe regiao_administrativa no VagaResumo do turno');

select * from finish();
rollback;
