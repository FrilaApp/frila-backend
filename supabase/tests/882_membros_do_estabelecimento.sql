-- 882_membros_do_estabelecimento.sql
--
-- membros_do_estabelecimento (migração 20261117110000, contrato 0.2.103):
--   * o administrador da casa vê a lista com exatamente as chaves do contrato
--     (membro_id, nome, papel, desde, e_voce), administradores primeiro e, em cada papel, a entrada mais
--     antiga primeiro; e_voce só na linha de quem chama; membro_id é o id do vínculo, não o da conta;
--   * operador da casa, administrador de outra casa, profissional e casa inexistente recebem o MESMO 403
--     (o envelope inteiro, sem details); conta suspensa de quem chama: 403 conta_suspensa;
--     sem sessão: 401 nao_autenticado; anon: sem EXECUTE;
--   * nada de e-mail, telefone, documento nem usuario_id no corpo; a conta suspensa continua na lista.
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-17 12:00:00+00', true);
select plan(21);

create function pg_temp.id(n int) returns uuid language sql immutable as $$
  select ('c8820000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;

-- Chama como a conta (null = authenticated sem sub). Devolve o corpo em texto ou o envelope do erro.
create function pg_temp.como(conta uuid, sql text) returns text language plpgsql as $$
declare r text; v_det text;
begin
  execute 'set local role authenticated';
  if conta is null then
    execute 'set local request.jwt.claims = ''{"role":"authenticated"}''';
  else
    execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  end if;
  begin
    execute sql into r;
  exception when others then
    get stacked diagnostics v_det = pg_exception_detail;
    r := 'ERRO ' || sqlstate || ' ' || sqlerrm || ' ' || coalesce(v_det, '');
  end;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;
create function pg_temp.lista(conta uuid, estab uuid) returns jsonb language sql as $$
  select pg_temp.como(conta, format('select public.membros_do_estabelecimento(%L)', estab))::jsonb $$;
create function pg_temp.envelope(conta uuid, estab uuid) returns text language sql as $$
  select pg_temp.como(conta, format('select public.membros_do_estabelecimento(%L)', estab)) $$;

-- 1 Ana (admin A) · 2 Bia (admin A) · 3 Caio (operador A, o mais antigo) · 4 Dora (admin B)
-- 5 Edu (profissional) · 6 Fabi (admin A, depois suspensa)
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data,
                        raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', pg_temp.id(n), 'authenticated', 'authenticated',
       'conta' || n || '.882@teste.invalid', '2026-11-01 12:00:00+00', '{"provider":"email"}', '{}',
       '2026-11-01 12:00:00+00', '2026-11-01 12:00:00+00', false, false
  from generate_series(1, 6) n;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
select pg_temp.id(n), case n when 5 then 'profissional' else 'contratante' end::public.perfil_conta,
       (array['Ana 882','Bia 882','Caio 882','Dora 882','Edu 882','Fabi 882'])[n],
       '+556198820000' || n, 'conta' || n || '.882@teste.invalid', '1985-01-01', '2026-09-22',
       '2026-11-01 12:00:00+00', false
  from generate_series(1, 6) n;
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values (pg_temp.id(21), 'Casa A 882', '94827988200199', 'food_service', 'Endereco882a',
        'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto'),
       (pg_temp.id(22), 'Casa B 882', '94827988200288', 'food_service', 'Endereco882b',
        'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (id, usuario_id, estabelecimento_id, papel, criado_em)
values (pg_temp.id(53), pg_temp.id(3), pg_temp.id(21), 'operador',      '2026-10-01 10:00:00+00'),
       (pg_temp.id(51), pg_temp.id(1), pg_temp.id(21), 'administrador', '2026-10-02 10:00:00+00'),
       (pg_temp.id(52), pg_temp.id(2), pg_temp.id(21), 'administrador', '2026-10-03 10:00:00+00'),
       (pg_temp.id(56), pg_temp.id(6), pg_temp.id(21), 'administrador', '2026-10-04 10:00:00+00'),
       (pg_temp.id(54), pg_temp.id(4), pg_temp.id(22), 'administrador', '2026-10-05 10:00:00+00');
update public.usuario set estado = 'suspensa' where id = pg_temp.id(6);

-- 1 a 3: a lista do administrador
select is((select array_agg(distinct k order by k)
             from jsonb_array_elements(pg_temp.lista(pg_temp.id(1), pg_temp.id(21))) e, jsonb_object_keys(e) k),
          array['desde','e_voce','membro_id','nome','papel'],
          'administrador: cada membro traz exatamente membro_id, nome, papel, desde e e_voce');
select is(jsonb_array_length(pg_temp.lista(pg_temp.id(1), pg_temp.id(21))), 4,
          'administrador: os 4 membros da casa A, a conta suspensa incluída e ninguém da casa B');
select is((select array_agg(e->>'nome' order by ord)
             from jsonb_array_elements(pg_temp.lista(pg_temp.id(1), pg_temp.id(21))) with ordinality t(e, ord)),
          array['Ana 882','Bia 882','Fabi 882','Caio 882'],
          'ordem: administradores primeiro, pela entrada mais antiga, e depois o operador (mesmo sendo o mais antigo)');

-- 4 a 7: e_voce, membro_id, papel e desde
select is((select array_agg(e->>'nome' order by ord)
             from jsonb_array_elements(pg_temp.lista(pg_temp.id(1), pg_temp.id(21))) with ordinality t(e, ord)
            where (e->>'e_voce')::boolean),
          array['Ana 882'], 'e_voce é verdadeiro só na linha de quem chama');
select is((select array_agg(e->>'nome' order by ord)
             from jsonb_array_elements(pg_temp.lista(pg_temp.id(2), pg_temp.id(21))) with ordinality t(e, ord)
            where (e->>'e_voce')::boolean),
          array['Bia 882'], 'e_voce acompanha quem chama: para a outra administradora, só a linha dela');
select is((select array_agg(e->>'membro_id' order by ord)
             from jsonb_array_elements(pg_temp.lista(pg_temp.id(1), pg_temp.id(21))) with ordinality t(e, ord)),
          array[pg_temp.id(51), pg_temp.id(52), pg_temp.id(56), pg_temp.id(53)]::text[],
          'membro_id é o id do vínculo (membro_estabelecimento.id), não o da conta');
select is((select e from jsonb_array_elements(pg_temp.lista(pg_temp.id(1), pg_temp.id(21))) e
            where e->>'nome' = 'Caio 882'),
          jsonb_build_object('membro_id', pg_temp.id(53), 'nome', 'Caio 882', 'papel', 'operador',
                             'desde', '2026-10-01T10:00:00+00:00'::timestamptz, 'e_voce', false),
          'o operador sai com o papel, a data de entrada e e_voce falso');

-- 8: minimização
select ok(pg_temp.como(pg_temp.id(1), format('select public.membros_do_estabelecimento(%L)', pg_temp.id(21)))
            !~* '(@teste\.invalid|\+55619882|94827988200|usuario_id|email|telefone|documento|nascimento)',
          'nada de e-mail, telefone, documento, nascimento nem usuario_id no corpo');

-- 9 a 14: o mesmo 403 para todo o resto, comparado pelo envelope inteiro
select is(pg_temp.envelope(pg_temp.id(3), pg_temp.id(21)),
          'ERRO PGRST {"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null} {"status" : 403, "headers" : {}}',
          'operador da casa: 403 sem_permissao, sem details');
select is(pg_temp.envelope(pg_temp.id(4), pg_temp.id(21)), pg_temp.envelope(pg_temp.id(3), pg_temp.id(21)),
          'administrador de outra casa: o mesmo envelope do operador');
select is(pg_temp.envelope(pg_temp.id(5), pg_temp.id(21)), pg_temp.envelope(pg_temp.id(3), pg_temp.id(21)),
          'conta de profissional, que não é membro de nada: o mesmo envelope');
select is(pg_temp.envelope(pg_temp.id(1), pg_temp.id(99)), pg_temp.envelope(pg_temp.id(3), pg_temp.id(21)),
          'casa inexistente: o mesmo envelope, sem dizer que a casa não existe');
select is(pg_temp.envelope(pg_temp.id(1), pg_temp.id(22)), pg_temp.envelope(pg_temp.id(3), pg_temp.id(21)),
          'administrador da casa A pedindo a casa B: o mesmo envelope');
select is(pg_temp.envelope(pg_temp.id(1), null), pg_temp.envelope(pg_temp.id(3), pg_temp.id(21)),
          'estabelecimento_id nulo: o mesmo envelope');

-- 15 a 17: sessão e conta
select is(pg_temp.envelope(null, pg_temp.id(21)),
          'ERRO PGRST {"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null} {"status" : 401, "headers" : {}}',
          'authenticated sem sub: 401 nao_autenticado');
select is(pg_temp.envelope(pg_temp.id(6), pg_temp.id(21)),
          'ERRO PGRST {"code" : "sem_permissao", "message" : "sem_permissao", "details" : "conta_suspensa", "hint" : null} {"status" : 403, "headers" : {}}',
          'administradora com a conta suspensa: 403 sem_permissao com details conta_suspensa');
create function pg_temp.anon() returns text language plpgsql as $$
declare r text;
begin
  execute 'set local role anon';
  execute 'set local request.jwt.claims = ''{"role":"anon"}''';
  begin
    execute format('select public.membros_do_estabelecimento(%L)', pg_temp.id(21));
    r := 'EXECUTOU';
  exception when insufficient_privilege then r := '42501';
            when others then r := sqlstate;
  end;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;
select is(pg_temp.anon(), '42501', 'anon: sem EXECUTE (o PostgREST responde 401 ao anon)');

-- 18 a 21: a função
select ok(has_function_privilege('authenticated', 'public.membros_do_estabelecimento(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.membros_do_estabelecimento(uuid)', 'execute')
          and not has_function_privilege('public', 'public.membros_do_estabelecimento(uuid)', 'execute'),
          'grant só a authenticated');
select ok((select p.prosecdef from pg_proc p where p.oid = 'public.membros_do_estabelecimento(uuid)'::regprocedure),
          'security definer');
select ok((select p.proconfig @> array['search_path=""'] from pg_proc p
            where p.oid = 'public.membros_do_estabelecimento(uuid)'::regprocedure),
          'search_path vazio');
select is(pg_temp.lista(pg_temp.id(4), pg_temp.id(22)) -> 0 ->> 'e_voce', 'true',
          'a casa B: a administradora dela vê só a si mesma, com e_voce verdadeiro');

select * from finish();
rollback;
