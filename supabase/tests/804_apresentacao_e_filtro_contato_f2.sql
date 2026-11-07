-- F2 · RN26/RN38/RN39: apresentação do profissional, filtro de contato e Pix, e cada CHECK novo.
begin;
insert into privado.ambiente values (true, true) on conflict (id) do update set eh_teste = true;
set local frila.agora = '2027-01-11 09:00:00+00';
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
insert into auth.users (id, aud, role, email) values
 ('c8040000-0000-4000-8000-000000000001','authenticated','authenticated','prof804@t.test'),
 ('c8040000-0000-4000-8000-000000000002','authenticated','authenticated','casa804@t.test'),
 ('c8040000-0000-4000-8000-000000000003','authenticated','authenticated','susp804@t.test'),
 ('c8040000-0000-4000-8000-000000000004','authenticated','authenticated','semperfil804@t.test');
select pg_temp.como(('c8040000-0000-4000-8000-00000000000' || n)::uuid,
 format($$select public.criar_conta(%L,%L,%L,'1990-01-01','2026-09-22')$$, p, 'Conta ' || n, '+556195555804' || n))
 from (values (1,'profissional'),(2,'contratante'),(3,'profissional'),(4,'profissional')) t(n,p);
insert into public.profissional (id,usuario_id,ponto_base) values
 ('c8040000-0000-4000-8000-000000000011','c8040000-0000-4000-8000-000000000001','POINT(-47.88 -15.79)'),
 ('c8040000-0000-4000-8000-000000000013','c8040000-0000-4000-8000-000000000003','POINT(-47.88 -15.79)');
update public.usuario set estado = 'suspensa' where id = 'c8040000-0000-4000-8000-000000000003';

-- Violação direta de cada CHECK (mata mutante: limite frouxo, lista aberta, subconsulta removida).
create function pg_temp.viola(coluna text, valor text) returns text language plpgsql as $$
begin
 execute format('update public.profissional set %I = %s where id = %L', coluna, valor, 'c8040000-0000-4000-8000-000000000011');
 return 'aceitou';
exception when check_violation then return 'recusou';
end $$;
select throws_ok($$update public.profissional set apresentacao = repeat('x',601) where usuario_id = 'c8040000-0000-4000-8000-000000000001'$$,
 '23514', null, 'CHECK apresentacao: 601 caracteres recusado');
select throws_ok($$update public.profissional set onde_trabalhei = repeat('x',401) where usuario_id = 'c8040000-0000-4000-8000-000000000001'$$,
 '23514', null, 'CHECK onde_trabalhei: 401 caracteres recusado');
select throws_ok($$update public.profissional set experiencia_faixa = 'muito_tempo' where usuario_id = 'c8040000-0000-4000-8000-000000000001'$$,
 '23514', null, 'CHECK experiencia_faixa: valor fora do catálogo recusado');
select throws_ok($$update public.profissional set cursos = array['a','b','c','d','e','f'] where usuario_id = 'c8040000-0000-4000-8000-000000000001'$$,
 '23514', null, 'CHECK cursos: seis itens recusado');
select throws_ok($$update public.profissional set cursos = array[repeat('x',81)] where usuario_id = 'c8040000-0000-4000-8000-000000000001'$$,
 '23514', null, 'CHECK cursos: item de 81 caracteres recusado');
select throws_ok($$update public.profissional set cursos = array['a',null] where usuario_id = 'c8040000-0000-4000-8000-000000000001'$$,
 '23514', null, 'CHECK cursos: item nulo recusado');
select throws_ok($$update public.profissional set idiomas = array['portugues','klingon'] where usuario_id = 'c8040000-0000-4000-8000-000000000001'$$,
 '23514', null, 'CHECK idiomas: idioma fora da lista recusado');
-- Fronteiras: o limite exato é aceito (mata mutante que aperta o CHECK).
select is(pg_temp.viola('apresentacao', 'repeat(''x'',600)'), 'aceitou', 'CHECK apresentacao: 600 caracteres aceito');
select is(pg_temp.viola('onde_trabalhei', 'repeat(''x'',400)'), 'aceitou', 'CHECK onde_trabalhei: 400 caracteres aceito');
select is(pg_temp.viola('cursos', 'array_fill(repeat(''x'',80),array[5])'), 'aceitou', 'CHECK cursos: cinco itens de 80 aceitos');
select is(pg_temp.viola('idiomas', 'array[''portugues'',''ingles'',''espanhol'',''libras'',''outro'']'), 'aceitou', 'CHECK idiomas: lista inteira aceita');
select is(pg_temp.viola('experiencia_faixa', '''mais_de_10_anos'''), 'aceitou', 'CHECK experiencia_faixa: faixa do catálogo aceita');
update public.profissional set apresentacao = null, onde_trabalhei = null, experiencia_faixa = null, cursos = null, idiomas = null
 where id = 'c8040000-0000-4000-8000-000000000011';

-- Filtro RN38 direto: (texto, deve ser limpo).
select is(privado.texto_sem_contato_ou_pix(t), limpo, 'filtro RN38: ' || coalesce(t, 'null'))
 from (values
  ('Trabalho com eventos há dez anos', true), ('Bar do Zé de 2019 a 2023', true), ('Bar do Zé 2019-2023', true),
  ('Das 14h às 22h, R$ 150,00 a diária', true), (null, true), ('', true),
  ('Garçom com 5 anos de experiência em eventos corporativos e casamentos.', true),
  ('Atendo no Plano Piloto, Águas Claras e Taguatinga.', true),
  ('Sr. Silva foi meu supervisor no hotel.', true),
  ('Sr.Silva foi meu supervisor no hotel.', true),
  ('(61) 98888-7777', false), ('61988887777', false), ('61 9 8888 7777', false), ('+55 61 98888-7777', false),
  ('meu zap é seis um nove oito oito oito oito sete sete sete sete', false), ('liga 61 nove 8888 7777', false),
  ('(61) 2019-2023', false), ('joao@exemplo.com', false), ('segue @joaodobar', false),
  ('https://exemplo.com/joao', false), ('www.joao.net', false), ('joaodobar.com.br', false), ('wa.me/5561988887777', false),
  ('pix cpf 123.456.789-09', false), ('chave pix 12345678909', false), ('pix 12.345.678/0001-95', false),
  ('chave 123e4567-e89b-12d3-a456-426614174000', false), ('chave 123e4567e89b12d3a456426614174000', false),
  -- Regressões das 11 variantes de ataque do Lince Codex
  ('segue ＠perfilteste', false),
  ('segue ﹫perfilteste', false),
  ('pessoa＠exemplo．com', false),
  ('perfil．example．com', false),
  ('nove ' || chr(8203) || 'oito sete seis cinco quatro três dois', false),
  ('nove oito sete seis cinco quatro tre' || chr(770) || 's dois', false),
  ('d94bfb19' || chr(8203) || '-0a5d-4fc0-a8e8-3b8f6a5c2d11', false),
  ('perfil.exemplo.br', false),
  ('perfil.example.xyz', false),
  ('example.c' || U&'\043E' || 'm', false),
  ('pessoa arroba exemplo ponto com', false)
 ) v(t, limpo);

-- A RPC: feliz, omitido preserva, null limpa.
create function pg_temp.atualiza(corpo jsonb, conta uuid default 'c8040000-0000-4000-8000-000000000001') returns jsonb language sql as $$
 select pg_temp.como(conta, format('select public.atualizar_apresentacao_profissional(%L::jsonb)', corpo)) $$;
create function pg_temp.erro(corpo jsonb, conta uuid default 'c8040000-0000-4000-8000-000000000001') returns jsonb language plpgsql as $$
declare msg text; det text;
begin
 perform pg_temp.atualiza(corpo, conta); return null;
exception when sqlstate 'PGRST' then
 get stacked diagnostics msg = message_text, det = pg_exception_detail;
 return msg::jsonb || jsonb_build_object('status', (det::jsonb->>'status')::int);
end $$;
select is(pg_temp.atualiza('{"apresentacao":"Garçom há 8 anos","onde_trabalhei":"Bar do Zé 2019-2023","experiencia_faixa":"de_5_a_10_anos",
 "cursos":["Coquetelaria"],"idiomas":["ingles","libras"]}') #- '{id}' @> '{"apresentacao":"Garçom há 8 anos","experiencia_faixa":"de_5_a_10_anos",
 "cursos":["Coquetelaria"],"idiomas":["ingles","libras"],"atende_todo_df":false}', true, 'RN26: atualiza e devolve o perfil detalhado');
select is(pg_temp.atualiza('{"apresentacao":"Novo texto"}') #>> '{onde_trabalhei}', 'Bar do Zé 2019-2023', 'campo omitido continua como estava');
select is(pg_temp.atualiza('{"apresentacao":"Novo texto"}') #>> '{cursos,0}', 'Coquetelaria', 'lista omitida continua como estava');
select is((select atende_todo_df from public.profissional where id = 'c8040000-0000-4000-8000-000000000011'), false, 'a RPC não mexe em atende_todo_df');
select is(pg_temp.atualiza('{"apresentacao":null}') -> 'apresentacao', 'null'::jsonb, 'null limpa apresentacao');
select is((select onde_trabalhei from public.profissional where id = 'c8040000-0000-4000-8000-000000000011'), 'Bar do Zé 2019-2023', 'limpar um campo preserva os outros');
select is(pg_temp.atualiza('{"cursos":null,"idiomas":null,"experiencia_faixa":null,"onde_trabalhei":null}') #>> '{cursos}', '[]', 'null limpa cursos e devolve lista vazia');
select is((select count(*)::int from public.profissional where id = 'c8040000-0000-4000-8000-000000000011'
 and apresentacao is null and onde_trabalhei is null and experiencia_faixa is null and cursos is null and idiomas is null), 1, 'todos os campos limpos no banco');
select is(jsonb_array_length(pg_temp.atualiza('{"idiomas":[]}') -> 'idiomas'), 0, 'lista vazia é aceita');

-- Recusas com código e campo.
select is(pg_temp.erro('{}') ->> 'details', 'nenhum_campo', 'corpo vazio: nenhum_campo');
select is(pg_temp.erro('{}') ->> 'code', 'campo_obrigatorio', 'corpo vazio: campo_obrigatorio');
select is(pg_temp.erro('[]') ->> 'details', 'nenhum_campo', 'corpo que não é objeto: nenhum_campo');
select is(pg_temp.erro('{"pessoa@exemplo.test":"x"}') ->> 'details', 'campo_desconhecido', 'P2: chave desconhecida não ecoa entrada arbitrária');
select is(pg_temp.erro('{"campo_novo":"x"}') ->> 'details', 'campo_desconhecido', 'P2: campo desconhecido devolve identificador fixo');
select is((pg_temp.erro(c) ->> 'code') || ':' || (pg_temp.erro(c) ->> 'details'), 'campo_invalido:' || campo, 'recusa ' || campo || ': ' || c::text)
 from (values
  ('{"apresentacao":1}'::jsonb,'apresentacao'), (jsonb_build_object('apresentacao', repeat('x',601)),'apresentacao'),
  (jsonb_build_object('onde_trabalhei', repeat('x',401)),'onde_trabalhei'), ('{"experiencia_faixa":"muito_tempo"}','experiencia_faixa'),
  ('{"experiencia_faixa":3}','experiencia_faixa'), ('{"cursos":"Coquetelaria"}','cursos'), ('{"cursos":[1]}','cursos'),
  ('{"cursos":["a","b","c","d","e","f"]}','cursos'), (jsonb_build_object('cursos', jsonb_build_array(repeat('x',81))),'cursos'),
  ('{"idiomas":["klingon"]}','idiomas'), ('{"idiomas":["ingles","ingles"]}','idiomas'), ('{"idiomas":"ingles"}','idiomas'),
  ('{"atende_todo_df":true}','campo_desconhecido'),
  ('{"apresentacao":"ligue 61 98888-7777"}','apresentacao'), ('{"onde_trabalhei":"veja joao@exemplo.com"}','onde_trabalhei'),
  ('{"apresentacao":"meu pix 123e4567-e89b-12d3-a456-426614174000"}','apresentacao'),
  ('{"onde_trabalhei":"https://exemplo.com"}','onde_trabalhei'), ('{"cursos":["me chame no @joao"]}','cursos'),
  ('{"cursos":["zap 61988887777"]}','cursos')
 ) t(c, campo);
select is(pg_temp.erro(jsonb_build_object('apresentacao', 'Turno com ' || (select termo from privado.termo_bloqueado order by termo limit 1))) ->> 'details',
 'apresentacao', 'termo bloqueado continua recusado em apresentacao');
select is((select apresentacao from public.profissional where id = 'c8040000-0000-4000-8000-000000000011'), null, 'recusa não grava nada');
select is(pg_temp.erro('{"apresentacao":"ok"}', 'c8040000-0000-4000-8000-000000000002') ->> 'code', 'perfil_incompativel', 'RN25: contratante é perfil_incompativel');
select is(pg_temp.erro('{"apresentacao":"ok"}', 'c8040000-0000-4000-8000-000000000003') ->> 'status', '403', 'conta suspensa: 403');
select is(pg_temp.erro('{"apresentacao":"ok"}', 'c8040000-0000-4000-8000-000000000004') ->> 'status', '404', 'profissional sem perfil: 404');
select throws_ok($$select public.atualizar_apresentacao_profissional('{"apresentacao":"ok"}')$$, 'PGRST', null, 'sem sessão: recusado');
select ok(not has_function_privilege('anon', 'public.atualizar_apresentacao_profissional(jsonb)', 'EXECUTE')
 and has_function_privilege('authenticated', 'public.atualizar_apresentacao_profissional(jsonb)', 'EXECUTE'), 'só authenticated executa a RPC');
select ok(not has_function_privilege('authenticated', 'privado.texto_sem_contato_ou_pix(text)', 'EXECUTE'), 'o filtro não é chamável pelo app');

-- P1-2: Ciclo de exclusão e retenção dos novos campos
do $$
declare
  v_uid uuid := 'c8040000-0000-4000-8000-000000000001';
  v_prof_id uuid := 'c8040000-0000-4000-8000-000000000011';
begin
  -- Popula apresentação e novos dados
  update public.profissional set
    apresentacao = 'Texto para expurgo',
    onde_trabalhei = 'Local antigo',
    experiencia_faixa = 'de_1_a_3_anos',
    cursos = array['Curso Retencao'],
    idiomas = array['portugues']
  where id = v_prof_id;

  -- 1. Exclui a conta
  perform privado.excluir_conta(v_uid);

  -- 2. Imediatamente após exclusão, dados ainda existem sob retenção
  assert (select apresentacao from public.profissional where id = v_prof_id) is not null, 'dados devem existir sob retencao';

  -- 3. Avança o relógio além de 21 dias e executa a limpeza
  perform set_config('frila.agora', '2027-02-05 10:00:00+00', true);
  perform privado.limpar_contas_anonimizadas(15);

  -- 4. Todos os 5 campos devem estar NULL
  assert (select count(*) from public.profissional where id = v_prof_id
          and apresentacao is null
          and onde_trabalhei is null
          and experiencia_faixa is null
          and cursos is null
          and idiomas is null) = 1, 'todos os campos novos devem ser limpos por limpar_contas_anonimizadas';
end $$;
select pass('P1-2: Retenção LGPD: apresentacao, onde_trabalhei, cursos, idiomas e faixa zerados por limpar_contas_anonimizadas');

select * from finish();
rollback;
