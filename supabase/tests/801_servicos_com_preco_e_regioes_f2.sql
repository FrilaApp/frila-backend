-- F2: RN26/RN27/RN38 e violações diretas de cada CHECK (mutantes).
begin;
insert into privado.ambiente values (true, true) on conflict (id) do update set eh_teste = true;
set local frila.agora = '2027-01-11 09:00:00+00';
select no_plan();
select has_table('public', 'profissional_servico', 'F2: serviços persistidos');
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
 ('c8010000-0000-4000-8000-000000000001','authenticated','authenticated','prof801@t.test'),
 ('c8010000-0000-4000-8000-000000000002','authenticated','authenticated','outro801@t.test');
select pg_temp.como('c8010000-0000-4000-8000-000000000001',
 $$select public.criar_conta('profissional','Profissional Teste','+5561955558011','1990-01-01','2026-09-22')$$);
select pg_temp.como('c8010000-0000-4000-8000-000000000002',
 $$select public.criar_conta('profissional','Outro Teste','+5561955558012','1990-01-01','2026-09-22')$$);
insert into public.profissional (id,usuario_id,ponto_base) values
 ('c8010000-0000-4000-8000-000000000011','c8010000-0000-4000-8000-000000000001','POINT(-47.88 -15.79)'),
 ('c8010000-0000-4000-8000-000000000012','c8010000-0000-4000-8000-000000000002','POINT(-47.88 -15.79)');
create temp table ids as select id as funcao from public.funcao where nome = 'faxina residencial';
insert into public.profissional_funcao select 'c8010000-0000-4000-8000-000000000011',funcao from ids;
insert into public.profissional_servico (profissional_id,funcao_id,unidade)
 select 'c8010000-0000-4000-8000-000000000011',funcao,'a_combinar' from ids;
select throws_ok($$update public.profissional_servico set unidade = 'invalida' where profissional_id = 'c8010000-0000-4000-8000-000000000011'$$, '23514', null, 'CHECK unidade: mutante recusado');
select throws_ok($$update public.profissional_servico set valor_centavos = 999 where profissional_id = 'c8010000-0000-4000-8000-000000000011'$$, '23514', null, 'CHECK valor_centavos: mutante recusado');
select throws_ok($$update public.profissional_servico set valor_max_centavos = 999 where profissional_id = 'c8010000-0000-4000-8000-000000000011'$$, '23514', null, 'CHECK valor_max_centavos: mutante recusado');
select throws_ok($$update public.profissional_servico set horas_incluidas = 3 where profissional_id = 'c8010000-0000-4000-8000-000000000011'$$, '23514', null, 'CHECK horas_incluidas: mutante recusado');
select throws_ok($$update public.profissional_servico set minimo_horas = 0 where profissional_id = 'c8010000-0000-4000-8000-000000000011'$$, '23514', null, 'CHECK minimo_horas: mutante recusado');
select throws_ok($$update public.profissional_servico set minimo_pessoas = 0 where profissional_id = 'c8010000-0000-4000-8000-000000000011'$$, '23514', null, 'CHECK minimo_pessoas: mutante recusado');
select throws_ok($$update public.profissional_servico set ate_pessoas = 0 where profissional_id = 'c8010000-0000-4000-8000-000000000011'$$, '23514', null, 'CHECK ate_pessoas: mutante recusado');
select throws_ok($$update public.profissional_servico set duracao_tipica_h = 25 where profissional_id = 'c8010000-0000-4000-8000-000000000011'$$, '23514', null, 'CHECK duracao_tipica_h: mutante recusado');
select throws_ok($$update public.profissional_servico set descricao_pacote = repeat('x',121) where profissional_id = 'c8010000-0000-4000-8000-000000000011'$$, '23514', null, 'CHECK descricao_pacote: mutante recusado');
select throws_ok($$update public.profissional_servico set inclui = repeat('x',301) where profissional_id = 'c8010000-0000-4000-8000-000000000011'$$, '23514', null, 'CHECK inclui: mutante recusado');
select throws_ok($$update public.profissional_servico set leva_material = 'talvez' where profissional_id = 'c8010000-0000-4000-8000-000000000011'$$, '23514', null, 'CHECK leva_material: mutante recusado');
delete from public.profissional_servico where profissional_id = 'c8010000-0000-4000-8000-000000000011';
create function pg_temp.servicos(j jsonb) returns jsonb language sql as $$
 select pg_temp.como('c8010000-0000-4000-8000-000000000001',format('select public.definir_servicos(%L::jsonb)',j)) $$;
create function pg_temp.erro(j jsonb) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
 perform pg_temp.servicos(j); return null;
exception when sqlstate 'PGRST' then
 get stacked diagnostics msg = message_text, det = pg_exception_detail;
 return msg::jsonb || jsonb_build_object('status',(det::jsonb->>'status')::int);
end $$;
select is((pg_temp.servicos(jsonb_build_array(jsonb_build_object('funcao_id',funcao,'unidade','diaria','valor_centavos',12345,'horas_incluidas',8)))
 ->'servicos'->0) @> '{"valor_centavos":12345,"horas_incluidas":8}',true,'RN27: diária preserva centavos e duração') from ids;
select is((pg_temp.erro(jsonb_build_array(jsonb_build_object('funcao_id',funcao) || j))->>'details'),campo,'unidade e campos inválidos: '||campo)
 from ids cross join (values
 ('{"unidade":"hora"}'::jsonb,'valor_centavos'), ('{"unidade":"diaria","valor_centavos":1000}','horas_incluidas'),
 ('{"unidade":"pacote","valor_centavos":1000}','descricao_pacote'), ('{"unidade":"por_pessoa","valor_centavos":1000}','minimo_pessoas'),
 ('{"unidade":"hora","valor_centavos":999}','valor_centavos'), ('{"unidade":"hora","valor_centavos":1000001}','valor_centavos'),
 ('{"unidade":"hora","valor_centavos":2000,"valor_max_centavos":1000}','valor_max_centavos'),
 ('{"unidade":"hora","valor_centavos":1000,"horas_incluidas":8}','horas_incluidas'),
 ('{"unidade":"a_combinar","valor_centavos":1000}','valor_centavos'),
 ('{"unidade":"invalida"}','unidade'), ('{"unidade":"hora","valor_centavos":"1000"}','valor_centavos'),
 ('{"unidade":"a_combinar","especialidade_ids":{}}','especialidade_ids'),
 ('{"unidade":"a_combinar","especialidade_ids":["invalido"]}','especialidade_ids'),
 ('{"unidade":"pacote","valor_centavos":1000,"descricao_pacote":"acesse https://teste.invalid"}','descricao_pacote')
 ) t(j,campo);
select is((pg_temp.erro(jsonb_build_array(jsonb_build_object('funcao_id',id,'unidade','a_combinar')))->>'code'),
 'funcao_nao_marcada','RN27: recusa função não marcada') from public.funcao where nome = 'passadeira';
select is((pg_temp.erro(jsonb_build_array(jsonb_build_object('funcao_id',funcao,'unidade','a_combinar','especialidade_ids',
 jsonb_build_array((select id from public.especialidade where nome='cortes nobres')))))->>'details'),
 'especialidade_ids','RN44: especialidade de outra função') from ids;
select is((pg_temp.erro(jsonb_build_array(jsonb_build_object('funcao_id',funcao,'unidade','a_combinar','especialidade_ids',
 (select jsonb_agg(gen_random_uuid()) from generate_series(1,9)))))->>'details'),'especialidade_ids','RN44: máximo 8') from ids;
select is((pg_temp.erro((select jsonb_agg(jsonb_build_object('funcao_id',funcao,'unidade','a_combinar') order by n) from generate_series(1,11) n))->>'details'),
 'servicos','RN27: máximo 10') from ids;
select is((pg_temp.erro(jsonb_build_array(jsonb_build_object('funcao_id',funcao,'unidade','a_combinar'),
 jsonb_build_object('funcao_id',funcao,'unidade','a_combinar')))->>'details'),'servicos','RN27: sem função repetida') from ids;
select is((select valor_centavos from public.profissional_servico where profissional_id='c8010000-0000-4000-8000-000000000011'),12345,'falhas preservam conjunto anterior');
select ok((pg_temp.servicos(jsonb_build_array(jsonb_build_object('funcao_id',funcao)||j))->'servicos'->0) @> j,'unidade válida: '||(j->>'unidade'))
 from ids cross join (values ('{"unidade":"hora","valor_centavos":1000,"minimo_horas":1}'::jsonb),
 ('{"unidade":"evento","valor_centavos":1000,"ate_pessoas":2000,"duracao_tipica_h":24}'),
 ('{"unidade":"pacote","valor_centavos":1000,"descricao_pacote":"Limpeza completa"}'),
 ('{"unidade":"por_pessoa","valor_centavos":1000,"minimo_pessoas":10}'), ('{"unidade":"a_combinar"}')) t(j);
select is((select valor_centavos from public.profissional_servico where profissional_id='c8010000-0000-4000-8000-000000000011'),null,'a combinar sem preço');
select is(jsonb_array_length(pg_temp.servicos(jsonb_build_array(jsonb_build_object('funcao_id',funcao,'unidade','a_combinar',
 'especialidade_ids',jsonb_build_array((select id from public.especialidade where funcao_id=funcao limit 1)))))->'servicos'->0->'especialidades'),1,'especialidade válida persistida') from ids;
select is((pg_temp.como('c8010000-0000-4000-8000-000000000001',$$select count(*) from public.profissional_servico where profissional_id='c8010000-0000-4000-8000-000000000011'$$))::int,1,'leitura autenticada de serviços');
select is((pg_temp.como('c8010000-0000-4000-8000-000000000001',$$select count(*) from public.profissional_servico_especialidade where profissional_id='c8010000-0000-4000-8000-000000000011'$$))::int,1,'leitura autenticada de especialidades');
create function pg_temp.regioes(r int[], todo boolean, conta uuid default 'c8010000-0000-4000-8000-000000000001') returns jsonb language sql as $$
 select pg_temp.como(conta,format('select public.definir_regioes_atendidas(%L::int[],%L::boolean)',r,todo)) $$;
select is(jsonb_array_length(pg_temp.regioes(array[1,2],false)->'regioes'),2,'RN26: regiões válidas');
select throws_ok($$select pg_temp.regioes(array[999],false)$$,'PGRST',null,'região inexistente recusada');
update public.regiao_administrativa set ativo=false where id=3;
select throws_ok($$select pg_temp.regioes(array[3],false)$$,'PGRST',null,'região inativa recusada');
select is((pg_temp.regioes(array[999],true)->>'atende_todo_df')::boolean,true,'RN26: todo DF ignora lista');
select is((select count(*)::int from public.profissional_regiao where profissional_id='c8010000-0000-4000-8000-000000000011'),0,'todo DF limpa regiões');
select is(jsonb_array_length(pg_temp.regioes('{}',null)->'regioes'),0,'seleção vazia permitida');
select pg_temp.regioes(array[1],false);
select pg_temp.regioes(array[2],false,'c8010000-0000-4000-8000-000000000002');
select is((select regiao_id::int from public.profissional_regiao where profissional_id='c8010000-0000-4000-8000-000000000011'),1,'outro dono não altera região anterior');
select is((pg_temp.como('c8010000-0000-4000-8000-000000000002',$$select count(*) from public.profissional_servico where profissional_id='c8010000-0000-4000-8000-000000000011'$$))::int,0,'perfil de terceiro protegido: profissional_servico');
select is((pg_temp.como('c8010000-0000-4000-8000-000000000002',$$select count(*) from public.profissional_servico_especialidade where profissional_id='c8010000-0000-4000-8000-000000000011'$$))::int,0,'perfil de terceiro protegido: profissional_servico_especialidade');
select is((pg_temp.como('c8010000-0000-4000-8000-000000000002',$$select count(*) from public.profissional_regiao where profissional_id='c8010000-0000-4000-8000-000000000011'$$))::int,0,'perfil de terceiro protegido: profissional_regiao');
select is(jsonb_array_length(pg_temp.servicos('[]')->'servicos'),0,'lista vazia limpa serviços e especialidades');
select is((select count(*)::int from public.profissional_servico_especialidade where profissional_id='c8010000-0000-4000-8000-000000000011'),0,'especialidades removidas em cascata');
select throws_ok($$select public.definir_servicos('[]')$$,'PGRST',null,'serviços exigem autenticação');
select throws_ok($$select public.definir_regioes_atendidas('{}',false)$$,'PGRST',null,'regiões exigem autenticação');
select ok(c.relrowsecurity and not has_table_privilege('authenticated',c.oid,'INSERT,UPDATE,DELETE') and not has_table_privilege('anon',c.oid,'SELECT'),
 'RLS ligado e sem escrita: '||c.relname) from pg_class c where c.oid in ('public.profissional_servico'::regclass,'public.profissional_servico_especialidade'::regclass,'public.profissional_regiao'::regclass);
select is((pg_temp.como('c8010000-0000-4000-8000-000000000001',$$select count(*) from public.profissional_regiao where profissional_id='c8010000-0000-4000-8000-000000000011'$$))::int,1,'leitura autenticada das regiões');
select * from finish();
rollback;
