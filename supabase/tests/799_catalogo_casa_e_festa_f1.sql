-- 799_catalogo_casa_e_festa_f1.sql
--
-- Catálogo de Casa e Festa, regiões administrativas, especialidades e resolver_servico.
-- Contratação direta, fatia F1 · contrato 0.2.52 · RN44. Ids próprios, começando em `c7990000`.
--
-- O que este arquivo prova, e por que cada grupo existe:
--   1. As quatro tabelas novas existem, têm RLS ligado, o app logado lê e ninguém escreve:
--      `anon` não lê nada e `authenticated` não grava (o catálogo muda por migração).
--   2. As 37 regiões: ids de 1 a 37 sem buraco, número romano certo em cada uma, todas ativas.
--   3. As categorias Casa e Festa e eventos sociais, com dica e exemplo.
--   4. As seis funções novas no formato `servico`; garçom e garçonete no mesmo `grupo_busca`;
--      as funções antigas continuam `turno`.
--   5. Cada especialidade aponta para a sua função canônica e não vira função (RN44).
--   6. `resolver_servico`: 401, 422, sinônimo, nome sem acento e sem maiúscula, par de
--      garçom, lista vazia sem criar função, teto de 5 e função inativa fora da lista.
--   7. O despacho não mudou (RN05, CA1): um estabelecimento `servico_domestico` publica uma
--      vaga normal de faxina residencial e só quem tem essa função recebe o despacho.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-11-05 12:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-799';

select plan(79);

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, privado.agora(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
          privado.agora(), privado.agora(), false, false)
  on conflict (id) do nothing;
end $$;

-- Executa `sql` (que devolve um valor) como a conta logada e devolve o resultado em jsonb.
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

-- Executa `sql` com a identidade de `papel`, sem conta. Se levantar, a subtransação do
-- throws_ok desfaz o SET LOCAL junto com o resto.
create function pg_temp.como_papel(papel text, sql text) returns void
language plpgsql as $$
begin
  execute format('set local role %I', papel);
  execute sql;
  reset role;
end $$;

-- Número romano de 1 a 39: a conferência das 37 regiões não depende de copiar a lista.
create function pg_temp.romano(n int) returns text
language plpgsql immutable as $$
declare
  r text := '';
  v int := n;
begin
  while v >= 10 loop r := r || 'X'; v := v - 10; end loop;
  if v = 9 then r := r || 'IX'; v := 0; end if;
  if v >= 5 then r := r || 'V'; v := v - 5; end if;
  if v = 4 then r := r || 'IV'; v := 0; end if;
  while v >= 1 loop r := r || 'I'; v := v - 1; end loop;
  return r;
end $$;

-- Os nomes de uma resposta de resolver_servico, na ordem em que vieram.
create function pg_temp.nomes(j jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(e->>'nome' order by ord), '[]'::jsonb)
    from jsonb_array_elements(j) with ordinality t(e, ord)
$$;

-- ── O cenário ─────────────────────────────────────────────────────────────────

select pg_temp.autenticar('c7990000-0000-4000-8000-000000000001', 'casa799@t.test');
select pg_temp.autenticar('c7990000-0000-4000-8000-000000000002', 'faxina799@t.test');
select pg_temp.autenticar('c7990000-0000-4000-8000-000000000003', 'garcom799@t.test');

select pg_temp.como('c7990000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante','Dona da Casa','+5561955557991','1980-01-01','2026-09-22') $$);
select pg_temp.como('c7990000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('profissional','Diarista Teste','+5561955557992','1990-01-01','2026-09-22') $$);
select pg_temp.como('c7990000-0000-4000-8000-000000000003',
  $$ select public.criar_conta('profissional','Garçom Teste','+5561955557993','1995-01-01','2026-09-22') $$);

-- Uma casa de família: CPF, tipo servico_domestico.
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c7990000-0000-4000-8000-0000000000e1', 'Casa da Família 799', '12345678909', 'servico_domestico',
        'SQN 305', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c7990000-0000-4000-8000-000000000001', 'c7990000-0000-4000-8000-0000000000e1', 'administrador');

insert into public.profissional (usuario_id, ponto_base) values
  ('c7990000-0000-4000-8000-000000000002', 'POINT(-47.8822 -15.7800)'::extensions.geography),
  ('c7990000-0000-4000-8000-000000000003', 'POINT(-47.8822 -15.7801)'::extensions.geography);

create temp table ids as
select (select p.id from public.profissional p where p.usuario_id = 'c7990000-0000-4000-8000-000000000002') as prof_faxina,
       (select p.id from public.profissional p where p.usuario_id = 'c7990000-0000-4000-8000-000000000003') as prof_garcom,
       'c7990000-0000-4000-8000-000000000001'::uuid as conta_casa,
       'c7990000-0000-4000-8000-0000000000e1'::uuid as casa,
       (select id from public.funcao where nome = 'faxina residencial') as faxina,
       (select id from public.funcao where nome = 'garçom') as garcom;

-- Os dois moram a 1,4 km da casa e têm a semana inteira livre: a única coisa que os
-- separa é a função.
insert into public.profissional_funcao (profissional_id, funcao_id)
select prof_faxina, faxina from ids union all select prof_garcom, garcom from ids;

insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
select prof_faxina, d::smallint, '00:00'::time, '23:59:59'::time from ids, generate_series(0, 6) d
union all
select prof_garcom, d::smallint, '00:00'::time, '23:59:59'::time from ids, generate_series(0, 6) d;

-- ── 1. As quatro tabelas, RLS e quem lê e escreve ─────────────────────────────

select has_table('public', 'regiao_administrativa', 'regiao_administrativa existe');
select has_table('public', 'categoria',             'categoria existe');
select has_table('public', 'especialidade',         'especialidade existe');
select has_table('public', 'funcao_sinonimo',       'funcao_sinonimo existe');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
      and c.relname in ('regiao_administrativa', 'categoria', 'especialidade', 'funcao_sinonimo')),
  4,
  'as 4 tabelas do catálogo têm Row Level Security ligado');

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public'
      and tablename in ('regiao_administrativa', 'categoria', 'especialidade', 'funcao_sinonimo')
      and cmd = 'SELECT' and 'authenticated' = any (roles)),
  4,
  'cada uma tem a sua política de leitura para authenticated');

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public'
      and tablename in ('regiao_administrativa', 'categoria', 'especialidade', 'funcao_sinonimo')
      and cmd <> 'SELECT'),
  0,
  'nenhuma tem política de escrita: o catálogo muda por migração');

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'
      and table_name in ('regiao_administrativa', 'categoria', 'especialidade', 'funcao_sinonimo')),
  0,
  'anon não tem concessão nenhuma nas 4 tabelas');

select throws_ok(
  $$ select pg_temp.como_papel('anon', $x$ select count(*) from public.regiao_administrativa $x$) $$,
  '42501', null,
  'a chave publicável do app não lê as regiões sem estar logada');

select throws_ok(
  $$ select pg_temp.como_papel('authenticated', $x$
       insert into public.regiao_administrativa (id, numero, nome) values (99, 'XCIX', 'Região Inventada') $x$) $$,
  '42501', null,
  'quem está logado não grava região direto na tabela');

select throws_ok(
  $$ select pg_temp.como_papel('authenticated', $x$
       insert into public.funcao_sinonimo (termo, funcao_id)
       values ('faxina de luxo', (select id from public.funcao where nome = 'passadeira')) $x$) $$,
  '42501', null,
  'quem está logado não grava sinônimo direto na tabela');

select throws_ok(
  $$ select pg_temp.como_papel('authenticated', $x$
       insert into public.especialidade (funcao_id, nome)
       values ((select id from public.funcao where nome = 'passadeira'), 'inventada') $x$) $$,
  '42501', null,
  'quem está logado não grava especialidade direto na tabela');

-- ── 2. As 37 regiões administrativas (CA4) ────────────────────────────────────

select is(
  (select count(*)::int from public.regiao_administrativa),
  37,
  'são 37 regiões administrativas');

select is(
  (select array_agg(id::int order by id) from public.regiao_administrativa),
  (select array_agg(g) from generate_series(1, 37) g),
  'os ids vão de 1 a 37, sem buraco');

select is(
  (select count(*)::int from public.regiao_administrativa where numero <> pg_temp.romano(id::int)),
  0,
  'o número romano de cada região confere com o id (RA I = 1 ... RA XXXVII = 37)');

select is(
  (select count(*)::int from public.regiao_administrativa where not ativo),
  0,
  'todas as 37 estão ativas');

select is(
  (select nome from public.regiao_administrativa where id = 1),
  'Plano Piloto',
  'a RA I é o Plano Piloto');

select is(
  (select nome from public.regiao_administrativa where id = 9),
  'Ceilândia',
  'a RA IX é Ceilândia');

select is(
  (select nome from public.regiao_administrativa where id = 20),
  'Águas Claras',
  'a RA XX é Águas Claras');

select is(
  (select nome from public.regiao_administrativa where id = 35),
  'Água Quente',
  'a RA XXXV é Água Quente');

select is(
  (select numero || ' ' || nome from public.regiao_administrativa where id = 37),
  'XXXVII Ponte Alta',
  'a RA XXXVII é Ponte Alta');

select is(
  pg_temp.como('c7990000-0000-4000-8000-000000000001',
    $$ select to_jsonb(count(*)) from public.regiao_administrativa $$),
  '37'::jsonb,
  'quem está logado lê as 37 regiões');

select throws_ok(
  $$ insert into public.regiao_administrativa (id, numero, nome) values (0, 'Z', 'Zero') $$,
  '23514', null,
  'o id da região é maior que zero');

select throws_ok(
  $$ insert into public.regiao_administrativa (id, numero, nome) values (38, 'XXXVIII', 'Plano Piloto') $$,
  '23505', null,
  'o nome da região é único');

-- ── 3. As categorias ──────────────────────────────────────────────────────────

select is(
  (select count(*)::int from public.categoria),
  9,
  'são 9 categorias: as 7 de antes, Casa e Festa e eventos sociais');

select is(
  (select count(*)::int from public.categoria
    where nome in ('Salão', 'Bar', 'Cozinha', 'Evento', 'Apoio', 'Varejo', 'Logística')),
  7,
  'as 7 categorias de antes continuam');

select is(
  (select count(*)::int from public.categoria
    where nome in ('Casa', 'Festa e eventos sociais')
      and btrim(dica_perfil) <> '' and btrim(exemplo_perfil) <> ''),
  2,
  'Casa e Festa e eventos sociais trazem dica e exemplo de perfil');

select is(
  (select count(distinct f.categoria)::int from public.funcao f
     left join public.categoria c on c.nome = f.categoria
    where c.nome is null),
  0,
  'toda categoria usada por uma função existe na tabela de categorias');

-- ── 4. As funções novas e o grupo de busca ────────────────────────────────────

select is(
  (select count(*)::int from public.funcao),
  38,
  'o catálogo tem 38 funções: as 32 de antes e as 6 novas');

select is(
  (select array_agg(nome order by nome) from public.funcao
    where categoria = 'Casa' and formato_padrao = 'servico'),
  array['faxina comercial', 'faxina residencial', 'passadeira'],
  'Casa tem faxina residencial, passadeira e faxina comercial, no formato servico');

select is(
  (select array_agg(nome order by nome) from public.funcao
    where categoria = 'Festa e eventos sociais' and formato_padrao = 'servico'),
  array['auxiliar de festa', 'churrasqueiro', 'cozinheiro de festa'],
  'Festa e eventos sociais tem churrasqueiro, cozinheiro de festa e auxiliar de festa, no formato servico');

select is(
  (select count(*)::int from public.funcao where formato_padrao = 'servico'),
  6,
  'só as 6 funções novas são servico: as 32 de antes continuam turno');

select is(
  (select array_agg(nome order by nome) from public.funcao where grupo_busca = 'garcom_garconete'),
  array['garçom', 'garçonete'],
  'garçom e garçonete dividem o grupo de busca');

select is(
  (select count(*)::int from public.funcao where grupo_busca is not null),
  2,
  'nenhuma outra função tem grupo de busca');

select throws_ok(
  $$ update public.funcao set formato_padrao = 'pacote' where nome = 'passadeira' $$,
  '23514', null,
  'formato_padrao só aceita turno ou servico');

-- ── 5. As especialidades (CA3) ────────────────────────────────────────────────

select is(
  (select count(*)::int from public.especialidade e join public.funcao f on f.id = e.funcao_id
    where f.nome = 'faxina residencial'),
  5,
  'faxina residencial tem 5 especialidades');

select is(
  (select array_agg(e.nome order by e.nome) from public.especialidade e join public.funcao f on f.id = e.funcao_id
    where f.nome = 'passadeira'),
  array['cama e banho', 'roupa social', 'tecido delicado'],
  'passadeira tem roupa social, cama e banho e tecido delicado');

select is(
  (select count(*)::int from public.especialidade e join public.funcao f on f.id = e.funcao_id
    where f.nome = 'churrasqueiro'),
  4,
  'churrasqueiro tem 4 especialidades');

select is(
  (select array_agg(e.nome order by e.nome) from public.especialidade e join public.funcao f on f.id = e.funcao_id
    where f.nome = 'bartender'),
  array['bar móvel', 'coquetelaria clássica', 'drinks autorais', 'flair'],
  'bartender tem as 4 especialidades curadas');

select is(
  (select count(*)::int from public.especialidade),
  16,
  'são 16 especialidades no total, todas curadas');

select is(
  (select count(*)::int from public.especialidade e
     join public.funcao f on f.nome = e.nome),
  0,
  'nenhuma especialidade é também uma função: especialidade não vira função (RN44)');

select is(
  (select count(*)::int from public.funcao),
  38,
  'consultar as especialidades não criou função nenhuma');

select throws_ok(
  $$ insert into public.especialidade (funcao_id, nome)
     values ((select id from public.funcao where nome = 'passadeira'), 'roupa social') $$,
  '23505', null,
  'a mesma especialidade não se repete na mesma função');

select throws_ok(
  $$ insert into public.especialidade (funcao_id, nome)
     values ((select id from public.funcao where nome = 'passadeira'), '   ') $$,
  '23514', null,
  'especialidade em branco não existe');

select throws_ok(
  $$ insert into public.especialidade (funcao_id, nome)
     values (gen_random_uuid(), 'sem função') $$,
  '23503', null,
  'especialidade sem função canônica não existe');

-- ── 6. Os sinônimos ───────────────────────────────────────────────────────────

select is(
  (select count(*)::int from public.funcao_sinonimo),
  6,
  'são 6 sinônimos');

select is(
  (select count(*)::int from public.funcao_sinonimo where termo <> privado.normalizar(termo)),
  0,
  'todo sinônimo está guardado normalizado, sem acento nem maiúscula');

select throws_ok(
  $$ insert into public.funcao_sinonimo (termo, funcao_id)
     values ('Faxina Pesada', (select id from public.funcao where nome = 'faxina residencial')) $$,
  '23514', null,
  'sinônimo com maiúscula é recusado: não casaria com nada');

select is(
  (select f.nome from public.funcao_sinonimo s join public.funcao f on f.id = s.funcao_id
    where s.termo = 'copeira de festa'),
  'auxiliar de festa',
  'copeira de festa aponta para auxiliar de festa');

-- ── 7. resolver_servico ───────────────────────────────────────────────────────

select is(
  has_function_privilege('anon', 'public.resolver_servico(text)', 'execute'),
  false,
  'resolver_servico não é chamável pela chave publicável sem login');

select is(
  has_function_privilege('authenticated', 'public.resolver_servico(text)', 'execute'),
  true,
  'resolver_servico é chamável por quem está logado');

select throws_ok(
  $$ select public.resolver_servico('diarista') $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem conta logada, 401 nao_autenticado');

select throws_ok(
  $$ select pg_temp.como('c7990000-0000-4000-8000-000000000001', $x$ select public.resolver_servico('a') $x$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "termo", "hint" : null}',
  'termo de 1 caractere: 422 campo_invalido, details termo');

select throws_ok(
  $$ select pg_temp.como('c7990000-0000-4000-8000-000000000001', $x$ select public.resolver_servico('   a   ') $x$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "termo", "hint" : null}',
  'os espaços não contam: " a " também é 422');

select throws_ok(
  $$ select pg_temp.como('c7990000-0000-4000-8000-000000000001', $x$ select public.resolver_servico(null) $x$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "termo", "hint" : null}',
  'termo nulo: 422 campo_invalido');

select throws_ok(
  $$ select pg_temp.como('c7990000-0000-4000-8000-000000000001', $x$ select public.resolver_servico('') $x$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "termo", "hint" : null}',
  'termo vazio: 422 campo_invalido');

select throws_ok(
  $$ select pg_temp.como('c7990000-0000-4000-8000-000000000001', format($x$ select public.resolver_servico(%L) $x$, repeat('a', 61))) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "termo", "hint" : null}',
  'termo acima de 60 caracteres: 422 campo_invalido');

create temp table r_diarista as
select pg_temp.como('c7990000-0000-4000-8000-000000000001',
  $$ select public.resolver_servico('diarista') $$) as j;

select is(
  pg_temp.nomes((select j from r_diarista)),
  '["faxina residencial"]'::jsonb,
  '"diarista" devolve a função canônica faxina residencial (CA2)');

select is(
  (select ((j->0)->>'id')::uuid from r_diarista),
  (select faxina from ids),
  'e é o id da função do catálogo, o mesmo que o despacho usa');

select is(
  (select j->0->>'formato_padrao' from r_diarista),
  'servico',
  'a resposta traz o formato_padrao da função');

select is(
  (select array_agg(k order by k) from r_diarista, jsonb_object_keys(j->0) k),
  array['categoria', 'dica_perfil', 'exemplo_perfil', 'formato_padrao', 'grupo_busca', 'id', 'nome'],
  'cada item é uma Funcao do contrato 0.2.52, com os 4 campos novos');

select is(
  pg_temp.nomes(pg_temp.como('c7990000-0000-4000-8000-000000000001',
    $$ select public.resolver_servico('  FAXINEIRA ') $$)),
  '["faxina residencial"]'::jsonb,
  'maiúscula e espaço nas pontas não atrapalham o sinônimo');

select is(
  pg_temp.nomes(pg_temp.como('c7990000-0000-4000-8000-000000000001',
    $$ select public.resolver_servico('limpeza residencial') $$)),
  '["faxina residencial"]'::jsonb,
  'sinônimo de mais de uma palavra também casa');

select is(
  pg_temp.nomes(pg_temp.como('c7990000-0000-4000-8000-000000000001',
    $$ select public.resolver_servico('churrasqueira') $$)),
  '["churrasqueiro"]'::jsonb,
  '"churrasqueira" devolve churrasqueiro');

select is(
  pg_temp.nomes(pg_temp.como('c7990000-0000-4000-8000-000000000001',
    $$ select public.resolver_servico('garcom') $$)),
  '["garçom", "garçonete"]'::jsonb,
  '"garcom", sem acento, devolve garçom e também garçonete, que dividem o grupo de busca');

select is(
  pg_temp.nomes(pg_temp.como('c7990000-0000-4000-8000-000000000001',
    $$ select public.resolver_servico('Garçonete') $$)),
  '["garçonete", "garçom"]'::jsonb,
  '"Garçonete" devolve garçonete primeiro e garçom depois: do mais exato para o menos');

select is(
  pg_temp.nomes(pg_temp.como('c7990000-0000-4000-8000-000000000001',
    $$ select public.resolver_servico('faxina') $$)),
  '["faxina comercial", "faxina residencial"]'::jsonb,
  'o começo do nome casa, e no empate vale a ordem alfabética (nada é patrocinado, RN06)');

select is(
  pg_temp.nomes(pg_temp.como('c7990000-0000-4000-8000-000000000001',
    $$ select public.resolver_servico('residencial') $$)),
  '["faxina residencial"]'::jsonb,
  'uma palavra do meio do nome também casa');

select is(
  pg_temp.como('c7990000-0000-4000-8000-000000000001',
    $$ select public.resolver_servico('astronauta') $$),
  '[]'::jsonb,
  'termo sem correspondência devolve lista vazia, e não erro');

select is(
  pg_temp.como('c7990000-0000-4000-8000-000000000001',
    $$ select public.resolver_servico('!!') $$),
  '[]'::jsonb,
  'só pontuação não casa com tudo: devolve lista vazia');

select is(
  (select count(*)::int from public.funcao),
  38,
  'o termo desconhecido não criou função (RN44)');

select is(
  jsonb_array_length(pg_temp.como('c7990000-0000-4000-8000-000000000001',
    $$ select public.resolver_servico('de') $$)),
  5,
  'um termo que casa com muitas funções devolve no máximo 5');

update public.funcao set ativo = false where nome = 'faxina comercial';

select is(
  pg_temp.nomes(pg_temp.como('c7990000-0000-4000-8000-000000000001',
    $$ select public.resolver_servico('faxina') $$)),
  '["faxina residencial"]'::jsonb,
  'função inativa não aparece na busca');

-- ── 8. O despacho não mudou (CA1) ─────────────────────────────────────────────

create temp table vaga as
select (pg_temp.como('c7990000-0000-4000-8000-000000000001', format(
  $$ select public.publicar_vaga(%L::uuid, %L::uuid,
       '2026-11-07 18:00:00+00'::timestamptz, '2026-11-07 23:00:00+00'::timestamptz,
       'SQN 305','{"latitude":-15.7942,"longitude":-47.8822}'::jsonb,
       25000::bigint, 1, true, false, true, 'Dona da Casa',
       'urgencia'::public.modo_preenchimento, %L::uuid) $$,
  (select casa from ids), (select faxina from ids), gen_random_uuid()))->>'vaga_id')::uuid as id;

select ok(
  (select id is not null from vaga),
  'um estabelecimento servico_domestico publica uma vaga normal de faxina residencial (CA1)');

select is(
  (select v.funcao_id from public.vaga v where v.id = (select id from vaga)),
  (select faxina from ids),
  'a vaga guarda o funcao_id da faxina residencial, como qualquer vaga');

select is(
  (select array_agg(profissional_id) from privado.elegiveis((select id from vaga))),
  (select array[prof_faxina] from ids),
  'só o profissional com a função faxina residencial é elegível: o garçom, com a semana livre e a 1,4 km, não é');

select is(
  privado.despachar_vaga((select id from vaga)),
  1,
  'o despacho cria um único envio');

select is(
  (select array_agg(d.profissional_id) from public.despacho d where d.vaga_id = (select id from vaga)),
  (select array[prof_faxina] from ids),
  'o despacho é só do profissional da faxina residencial');

select is(
  (select count(*)::int from public.despacho d
    where d.vaga_id = (select id from vaga) and d.profissional_id = (select prof_garcom from ids)),
  0,
  'o garçom não recebe despacho de faxina');

select * from finish();
rollback;
