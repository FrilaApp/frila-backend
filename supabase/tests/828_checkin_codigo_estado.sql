-- 828_checkin_codigo_estado.sql
--
-- O estado do check-in por código e a chave por estabelecimento (contrato 0.2.68; migração
-- 20261109101000). Cobre:
--   · critério 11: as tabelas novas não têm coluna de posição, de metros, de motivo, de sinal
--     nem de autor, e a API não as alcança;
--   · critério 7 (a chave): global E por estabelecimento, fechada por padrão, 403 recurso_desligado;
--   · critério 4 (o contador): a 3ª errada bloqueia, o bloqueio não conta, a 6ª encerra, e
--     código novo não zera;
--   · um teste por CHECK, com o nome da regra, para a mutação ficar vermelha sem ele.
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-01-11 21:30:00+00', true);
select plan(60);

create temp table ids as
select
  'c8280000-0000-4000-8000-000000000001'::uuid as prof_user,
  'c8280000-0000-4000-8000-000000000002'::uuid as casa_user,
  'c8280000-0000-4000-8000-000000000011'::uuid as profissional,
  'c8280000-0000-4000-8000-000000000021'::uuid as casa,
  'c8280000-0000-4000-8000-000000000022'::uuid as outra_casa,
  'c8280000-0000-4000-8000-000000000031'::uuid as vaga,
  'c8280000-0000-4000-8000-000000000041'::uuid as posicao,
  'c8280000-0000-4000-8000-000000000051'::uuid as turno;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select prof_user, 'profissional'::public.perfil_conta, 'Prof 828', '+5561999998281',
       'prof828@test.invalid', '1992-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz from ids
union all
select casa_user, 'contratante'::public.perfil_conta, 'Casa 828', '+5561999998282',
       'casa828@test.invalid', '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz from ids;
insert into public.profissional (id, usuario_id, ponto_base)
select profissional, prof_user, 'POINT(-47.8800 -15.7700)'::extensions.geography from ids;
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select casa, 'Bar 828', '80000000000828', 'food_service'::public.tipo_estabelecimento, 'Endereço de teste',
       'POINT(-47.8800 -15.7700)'::extensions.geography from ids
union all
select outra_casa, 'Bar 828 B', '80000000008282', 'food_service'::public.tipo_estabelecimento, 'Endereço de teste',
       'POINT(-47.8800 -15.7700)'::extensions.geography from ids;
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select casa_user, casa, 'administrador' from ids;
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por)
select vaga, casa, (select id from public.funcao limit 1),
       '2027-01-11 21:00:00+00', '2027-01-12 02:00:00+00', 'Local 828',
       'POINT(-47.8800 -15.7700)'::extensions.geography, 15000, 1, false, false, false,
       'Gerente', 'urgencia', 'publicada', '2027-01-10 12:00:00+00', gen_random_uuid(), casa_user
  from ids;
insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select posicao, vaga, 'confirmada', profissional, '2027-01-10 13:00:00+00',
       '2027-01-11 21:00:00+00', '2027-01-12 02:00:00+00' from ids;
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, verificacao, valor_acordado_centavos)
select turno, posicao, '2027-01-11 21:05:00+00', 'manual'::public.tipo_registro,
       'pendente'::public.verificacao_turno, 15000 from ids;

-- A recusa de public.erro como "status code motivo", ou null quando passa.
create function pg_temp.recusa(sql text) returns text language plpgsql as $$
declare msg text; det text;
begin
  execute sql;
  return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  return concat_ws(' ', det::jsonb ->> 'status', msg::jsonb ->> 'code', msg::jsonb ->> 'details');
end $$;

create function pg_temp.violacao(tabela text, restricao text) returns text language sql as $$
  select format('new row for relation "%s" violates check constraint "%s"', tabela, restricao) $$;

create function pg_temp.erro() returns text language sql as $$
  select privado.registrar_erro_codigo('c8280000-0000-4000-8000-000000000051') $$;

create function pg_temp.relogio(instante text) returns void language sql as $$
  select set_config('frila.agora', instante, true) $$;

-- ── 1. O que as tabelas guardam, e quem as alcança (critério 11) ──────────────
select is(
  (select array_agg(column_name::text order by column_name) from information_schema.columns
    where table_schema = 'privado' and table_name = 'checkin_codigo_tentativa'),
  array['codigo_gerado_em', 'em', 'faixa', 'id', 'resultado', 'turno_id'],
  'critério 11: a tentativa guarda só a hora, o resultado, a faixa e a hora do código; sem metros, coordenada, motivo, sinal ou autor');

select is(
  (select array_agg(column_name::text order by column_name) from information_schema.columns
    where table_schema = 'privado' and table_name = 'checkin_codigo'),
  array['bloqueado_ate', 'codigo', 'codigo_exigido', 'confianca_baixa', 'encerrado_em',
        'erros', 'expira_em', 'gerado_em', 'turno_id'],
  'critério 11: o estado do turno não tem posição, metros, sinal nem quem gerou o código');

select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'privado'
      and table_name in ('recurso_estabelecimento', 'regra_checkin_codigo', 'checkin_codigo', 'checkin_codigo_tentativa')
      and udt_name in ('geography', 'geometry', 'point')),
  0, 'critério 11: nenhuma coluna geográfica nas quatro tabelas novas');

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relrowsecurity
      and c.relname in ('recurso_estabelecimento', 'regra_checkin_codigo', 'checkin_codigo', 'checkin_codigo_tentativa')),
  4, 'as quatro tabelas novas estão em privado, com RLS ligada');

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'privado'
      and tablename in ('recurso_estabelecimento', 'regra_checkin_codigo', 'checkin_codigo', 'checkin_codigo_tentativa')),
  0, 'nenhuma política: os apps só chegam às tabelas pelas RPCs');

select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'privado'
      and table_name in ('recurso_estabelecimento', 'regra_checkin_codigo', 'checkin_codigo', 'checkin_codigo_tentativa')
      and grantee in ('anon', 'authenticated', 'PUBLIC')),
  0, 'anon e authenticated não têm privilégio nenhum nas tabelas novas');

select ok(
  not has_function_privilege('authenticated', 'privado.recurso_ligado_para(text, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'privado.exigir_recurso_para(text, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'privado.faixa_da_leitura(integer)', 'execute')
  and not has_function_privilege('authenticated', 'privado.estado_do_codigo(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'privado.registrar_erro_codigo(uuid)', 'execute')
  and not has_function_privilege('anon', 'privado.registrar_erro_codigo(uuid)', 'execute'),
  'as funções novas de privado não são executáveis pelo app');

select is((select provolatile::text from pg_proc where oid = 'privado.exigir_recurso_para(text, uuid)'::regprocedure),
  'v', 'exigir_recurso_para é VOLATILE, porque chama public.erro (#455)');

-- ── 2. A chave, global e por estabelecimento (critério 7; leitura 6) ──────────
select is((select ligado from privado.recurso where chave = 'checkin_por_codigo'), false,
  'checkin_por_codigo nasce desligada');

insert into privado.recurso_estabelecimento (chave, estabelecimento_id)
select 'checkin_por_codigo', casa from ids;

select is(privado.recurso_ligado_para('checkin_por_codigo', (select casa from ids)), false,
  'chave global desligada: a casa da lista fica desligada');
select is(pg_temp.recusa(format('select privado.exigir_recurso_para(%L, %L)', 'checkin_por_codigo', (select casa from ids))),
  '403 sem_permissao recurso_desligado', 'chave desligada: exigir_recurso_para responde 403 recurso_desligado');

update privado.recurso set ligado = true where chave = 'checkin_por_codigo';

select is(privado.recurso_ligado_para('checkin_por_codigo', (select casa from ids)), true,
  'chave ligada e casa na lista: o recurso vale para a casa');
select is(privado.recurso_ligado_para('checkin_por_codigo', (select outra_casa from ids)), false,
  'chave ligada e casa fora da lista: fechado por padrão');
select is(pg_temp.recusa(format('select privado.exigir_recurso_para(%L, %L)', 'checkin_por_codigo', (select outra_casa from ids))),
  '403 sem_permissao recurso_desligado', 'casa fora do piloto recebe 403 recurso_desligado mesmo com a chave ligada');
select is(pg_temp.recusa(format('select privado.exigir_recurso_para(%L, %L)', 'checkin_por_codigo', (select casa from ids))),
  null, 'casa do piloto com a chave ligada passa');
update privado.recurso set ligado = true where chave = 'chamada_direta';
select is(privado.recurso_ligado_para('chamada_direta', (select casa from ids)), false,
  'a lista é por chave: a casa do piloto do código não ganha outra chave, mesmo ligada');

-- ── 3. Os números ajustáveis ──────────────────────────────────────────────────
select is((select row(validade_s, bloqueio_s, raio_validacao_m, precisao_ruim_m)::text from privado.regra_checkin_codigo),
  '(300,300,100,100)', 'regra nasce com 5 min de validade e de bloqueio, raio de 100 m e precisão ruim a partir de 100 m');

select throws_ok($$insert into privado.regra_checkin_codigo (unica) values (false)$$,
  '23514', pg_temp.violacao('regra_checkin_codigo', 'regra_uma_linha'), 'regra_uma_linha: a regra tem uma linha só');
select throws_ok($$update privado.regra_checkin_codigo set validade_s = 119$$,
  '23514', pg_temp.violacao('regra_checkin_codigo', 'validade_de_2_a_5_min'), 'validade_de_2_a_5_min: menos de 2 min é recusado');
select throws_ok($$update privado.regra_checkin_codigo set validade_s = 301$$,
  '23514', pg_temp.violacao('regra_checkin_codigo', 'validade_de_2_a_5_min'), 'validade_de_2_a_5_min: mais de 5 min é recusado');
select throws_ok($$update privado.regra_checkin_codigo set bloqueio_s = 119$$,
  '23514', pg_temp.violacao('regra_checkin_codigo', 'bloqueio_de_2_a_5_min'), 'bloqueio_de_2_a_5_min: menos de 2 min é recusado');
select throws_ok($$update privado.regra_checkin_codigo set bloqueio_s = 301$$,
  '23514', pg_temp.violacao('regra_checkin_codigo', 'bloqueio_de_2_a_5_min'), 'bloqueio_de_2_a_5_min: mais de 5 min é recusado');
select throws_ok($$update privado.regra_checkin_codigo set raio_validacao_m = 101$$,
  '23514', pg_temp.violacao('regra_checkin_codigo', 'raio_ate_100_m'), 'raio_ate_100_m: o raio não passa de 100 m');
select throws_ok($$update privado.regra_checkin_codigo set raio_validacao_m = 0$$,
  '23514', pg_temp.violacao('regra_checkin_codigo', 'raio_ate_100_m'), 'raio_ate_100_m: raio zero é recusado');
select throws_ok($$update privado.regra_checkin_codigo set precisao_ruim_m = 0$$,
  '23514', pg_temp.violacao('regra_checkin_codigo', 'precisao_ruim_positiva'), 'precisao_ruim_positiva: limiar zero é recusado');
select lives_ok($$update privado.regra_checkin_codigo set validade_s = 120, bloqueio_s = 120, raio_validacao_m = 1, precisao_ruim_m = 1$$,
  'as bordas aprovadas (2 min e 1 m) valem');
update privado.regra_checkin_codigo set validade_s = 300, bloqueio_s = 300, raio_validacao_m = 100, precisao_ruim_m = 100;

-- ── 4. O estado do turno ──────────────────────────────────────────────────────
insert into privado.checkin_codigo (turno_id) select turno from ids;

select throws_ok($$update privado.checkin_codigo set codigo = '12345', gerado_em = '2027-01-11 21:30:00+00', expira_em = '2027-01-11 21:35:00+00'$$,
  '23514', pg_temp.violacao('checkin_codigo', 'codigo_seis_digitos'), 'codigo_seis_digitos: cinco dígitos é recusado');
select throws_ok($$update privado.checkin_codigo set codigo = '12a456', gerado_em = '2027-01-11 21:30:00+00', expira_em = '2027-01-11 21:35:00+00'$$,
  '23514', pg_temp.violacao('checkin_codigo', 'codigo_seis_digitos'), 'codigo_seis_digitos: letra é recusada');
select throws_ok($$update privado.checkin_codigo set codigo = '482913', gerado_em = null, expira_em = '2027-01-11 21:35:00+00'$$,
  '23514', pg_temp.violacao('checkin_codigo', 'codigo_com_validade'), 'codigo_com_validade: código sem hora de geração é recusado');
select throws_ok($$update privado.checkin_codigo set codigo = '482913', gerado_em = '2027-01-11 21:30:00+00', expira_em = '2027-01-11 21:30:00+00'$$,
  '23514', pg_temp.violacao('checkin_codigo', 'codigo_com_validade'), 'codigo_com_validade: código que vence ao nascer é recusado');
select throws_ok($$update privado.checkin_codigo set codigo = '482913', gerado_em = '2027-01-11 21:30:00+00', expira_em = null$$,
  '23514', pg_temp.violacao('checkin_codigo', 'codigo_com_validade'), 'codigo_com_validade: código sem validade é recusado (B1: o nulo não passa)');
select throws_ok($$update privado.checkin_codigo set codigo = '482913', gerado_em = '2027-01-11 21:30:00+00', expira_em = '2027-02-10 21:30:00+00'$$,
  '23514', pg_temp.violacao('checkin_codigo', 'codigo_com_validade'), 'codigo_com_validade: validade de 30 dias é recusada');
select throws_ok($$update privado.checkin_codigo set codigo = '482913', gerado_em = '2027-01-11 21:30:00+00', expira_em = '2027-01-11 21:35:01+00'$$,
  '23514', pg_temp.violacao('checkin_codigo', 'codigo_com_validade'), 'codigo_com_validade: um segundo além dos 5 min da regra é recusado');
select lives_ok($$update privado.checkin_codigo set codigo = '048291', gerado_em = '2027-01-11 21:30:00+00', expira_em = '2027-01-11 21:35:00+00'$$,
  'código de 6 dígitos com validade vale, inclusive começando por zero');
select throws_ok($$update privado.checkin_codigo set erros = 7$$,
  '23514', pg_temp.violacao('checkin_codigo', 'erros_no_teto'), 'erros_no_teto: mais de 6 erros não existe');
select throws_ok($$update privado.checkin_codigo set erros = -1$$,
  '23514', pg_temp.violacao('checkin_codigo', 'erros_no_teto'), 'erros_no_teto: erro negativo não existe');
select throws_ok($$update privado.checkin_codigo set erros = 5, encerrado_em = '2027-01-11 21:31:00+00'$$,
  '23514', pg_temp.violacao('checkin_codigo', 'encerrado_no_teto'), 'encerrado_no_teto: encerrar com menos de 6 erros é recusado');
select throws_ok($$update privado.checkin_codigo set erros = 6, encerrado_em = null$$,
  '23514', pg_temp.violacao('checkin_codigo', 'encerrado_no_teto'), 'encerrado_no_teto: 6 erros sem encerrar é recusado (mão dupla)');

-- ── 5. As tentativas ──────────────────────────────────────────────────────────
select throws_ok(format($$insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa, codigo_gerado_em) values (%L, '2027-01-11 21:31:00+00', 'talvez', 'ate_100_m', '2027-01-11 21:30:00+00')$$, (select turno from ids)),
  '23514', pg_temp.violacao('checkin_codigo_tentativa', 'tentativa_resultado'), 'tentativa_resultado: só aceita ou recusada');
select throws_ok(format($$insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa) values (%L, '2027-01-11 21:31:00+00', 'recusada', 'perto')$$, (select turno from ids)),
  '23514', pg_temp.violacao('checkin_codigo_tentativa', 'tentativa_faixa'), 'tentativa_faixa: só as três faixas, nunca os metros');
select throws_ok(format($$insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa, codigo_gerado_em) values (%L, '2027-01-11 21:31:00+00', 'aceita', 'acima_de_100_m', '2027-01-11 21:30:00+00')$$, (select turno from ids)),
  '23514', pg_temp.violacao('checkin_codigo_tentativa', 'aceita_com_codigo_e_perto'), 'aceita_com_codigo_e_perto: leitura aceita nunca veio de mais de 100 m');
select throws_ok(format($$insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa) values (%L, '2027-01-11 21:31:00+00', 'aceita', 'sem_posicao')$$, (select turno from ids)),
  '23514', pg_temp.violacao('checkin_codigo_tentativa', 'aceita_com_codigo_e_perto'), 'aceita_com_codigo_e_perto: leitura aceita teve código em vigor');
select lives_ok(format($$insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa) values (%L, '2027-01-11 21:31:00+00', 'recusada', 'acima_de_100_m')$$, (select turno from ids)),
  'recusa acima de 100 m sem código em vigor é registrada');

delete from privado.checkin_codigo where turno_id = (select turno from ids);
select is((select count(*)::int from privado.checkin_codigo_tentativa where turno_id = (select turno from ids)), 0,
  'apagar o estado do turno leva as tentativas em cascata');

-- ── 6. A faixa e o estado ─────────────────────────────────────────────────────
select is(array[privado.faixa_da_leitura(null), privado.faixa_da_leitura(0), privado.faixa_da_leitura(100), privado.faixa_da_leitura(101)],
  array['sem_posicao', 'ate_100_m', 'ate_100_m', 'acima_de_100_m'], 'faixa_da_leitura: sem posição, até 100 m (inclusive) e acima');
select is(privado.estado_do_codigo((select turno from ids)), 'aberto', 'turno sem estado tem o caminho do código aberto');

-- ── 7. O contador (critério 4; leituras 3 e 9) ────────────────────────────────
select is(array[pg_temp.erro(), pg_temp.erro()], array['invalido', 'invalido'], 'as duas primeiras erradas respondem invalido');

-- A casa gera código novo entre a 2ª e a 3ª: o contador é do turno, não do código.
update privado.checkin_codigo set codigo = '731904', gerado_em = '2027-01-11 21:30:00+00', expira_em = '2027-01-11 21:35:00+00'
 where turno_id = (select turno from ids);

select is(pg_temp.erro(), 'temporario', 'critério 4: a 3ª errada bloqueia, mesmo com código novo (o contador não zera)');
select is((select bloqueado_ate from privado.checkin_codigo where turno_id = (select turno from ids)),
  '2027-01-11 21:35:00+00'::timestamptz, 'o bloqueio dura regra_checkin_codigo.bloqueio_s (5 min), pelo relógio do servidor');
select is(pg_temp.erro(), 'temporario', 'durante o bloqueio a leitura responde temporario');
select is((select erros from privado.checkin_codigo where turno_id = (select turno from ids)), 3,
  'durante o bloqueio a leitura não conta');
select is(privado.estado_do_codigo((select turno from ids)), 'temporario', 'estado_do_codigo: temporario no bloqueio');

select pg_temp.relogio('2027-01-11 21:35:01+00');
select is(privado.estado_do_codigo((select turno from ids)), 'aberto', 'passado o bloqueio, o caminho reabre');
select is(array[pg_temp.erro(), pg_temp.erro(), pg_temp.erro()], array['invalido', 'invalido', 'encerrado'],
  'leitura 9: a 4ª e a 5ª respondem invalido, e a 6ª já responde encerrado, sem nova espera');
select ok((select erros = 6 and encerrado_em = '2027-01-11 21:35:01+00'::timestamptz
             from privado.checkin_codigo where turno_id = (select turno from ids)),
  'a 6ª grava erros = 6 e encerrado_em no mesmo update');
select is(array[pg_temp.erro(), privado.estado_do_codigo((select turno from ids))], array['encerrado', 'encerrado'],
  'depois de encerrado, a leitura responde encerrado e o estado fica encerrado');
select is((select erros from privado.checkin_codigo where turno_id = (select turno from ids)), 6,
  'depois de encerrado, nada mais conta');

-- O bloqueio lê a regra: com 2 min configurados, a 3ª bloqueia por 2 min.
delete from privado.checkin_codigo where turno_id = (select turno from ids);
update privado.regra_checkin_codigo set bloqueio_s = 120;
select pg_temp.erro(); select pg_temp.erro(); select pg_temp.erro();
select is((select bloqueado_ate from privado.checkin_codigo where turno_id = (select turno from ids)),
  '2027-01-11 21:37:01+00'::timestamptz, 'o bloqueio segue a regra ajustada (2 min)');

-- Sem a linha da regra, a 3ª ainda bloqueia, pelo padrão de 5 min (R1 do Lince no #458).
delete from privado.checkin_codigo where turno_id = (select turno from ids);
delete from privado.regra_checkin_codigo;
select is(array[pg_temp.erro(), pg_temp.erro(), pg_temp.erro()], array['invalido', 'invalido', 'temporario'],
  'regra vazia: a 3ª errada ainda responde temporario');
select is((select bloqueado_ate from privado.checkin_codigo where turno_id = (select turno from ids)),
  '2027-01-11 21:40:01+00'::timestamptz, 'regra vazia: o bloqueio vale o padrão de 5 min, e não some');

select * from finish();
rollback;
