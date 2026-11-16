-- 869_busca_elegibilidade_e_ordem.sql
--
-- Busca de profissionais (migração 20261116210000, contrato 0.2.88): quem entra e em que ordem.
-- O cartão, o sigilo, o limite, o cursor e os erros estão no 870.
--   CD-P10 "Aceito chamadas diretas" é opt-in (false para todos) e liga pela RPC
--   CD-B03 / CD-P09 / CD-P14 serviço na função exata (sem expandir pelo grupo_busca), região ou todo o DF
--   CD-B06 bloqueio nos dois sentidos; CD-B10 cinco abertas tiram e voltam sozinhas
--   RN13 / RF25 / demonstração; só-CNPJ; aparelho na versão; pausa do par; prazo e agenda com horário
--   Ordem: a grade cobre o horário, depois a faixa de distância, depois o embaralho estável por
--   contratante e por dia; e a PROVA de que mudar a reputação não muda a ordem (RN06, D2).
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
-- 16/11/2026, 12:00 em Brasília (segunda-feira).
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-869';
select plan(60);

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;
create function pg_temp.u(n int) returns uuid language sql immutable as $$
  select ('c8690000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.p(n int) returns uuid language sql immutable as $$
  select ('c8690000-0000-4000-8000-0000000001' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.garcom() returns uuid language sql stable as $$ select id from public.funcao where nome = 'garçom' $$;
-- A busca inteira (sem cursor, até 20) de uma conta, como a lista dos números dos profissionais, em ordem.
create function pg_temp.lista(conta uuid, extra text default '', casa uuid default 'c8690000-0000-4000-8000-0000000000e1')
returns text language plpgsql as $$
declare r jsonb;
begin
  delete from privado.contador_busca;  -- o limite por hora é do 870; aqui não deve atrapalhar
  r := pg_temp.como(conta, format(
    'select public.buscar_profissionais(estabelecimento_id => %L, funcao_id => %L %s)',
    casa, pg_temp.garcom(), extra));
  return coalesce((select string_agg(right(e->>'id', 2), ',' order by o)
                     from jsonb_array_elements(r->'itens') with ordinality x(e, o)), '');
end $$;
create function pg_temp.tem(lista text, n int) returns boolean language sql immutable as $$
  select lpad(n::text, 2, '0') = any(string_to_array(lista, ',')) $$;
create function pg_temp.posicao_de(lista text, n int) returns int language sql immutable as $$
  select array_position(string_to_array(lista, ','), lpad(n::text, 2, '0')) $$;

-- ── Contas: 01 e 03 são membros da casa E1 (CNPJ); 02 é da casa E2 (CPF); 11 a 42 são profissionais ──
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', pg_temp.u(n), 'authenticated', 'authenticated',
       'p' || n || '@t869.test', privado.agora(), privado.agora(), false, false
  from (select generate_series(1, 3) union all select generate_series(11, 42)) s(n);
select pg_temp.como(pg_temp.u(n), format(
  $$ select public.criar_conta(%L, %L, %L, '1990-01-01', '2026-09-22') $$,
  case when n <= 3 then 'contratante' else 'profissional' end,
  'Pessoa ' || n || ' Sobrenome', '+55619555869' || lpad(n::text, 2, '0')))
  from (select generate_series(1, 3) union all select generate_series(11, 42)) s(n);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c8690000-0000-4000-8000-0000000000e1', 'Casa 869 CNPJ', '86912345000169', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
       ('c8690000-0000-4000-8000-0000000000e2', 'Casa 869 CPF', '86912345669', 'food_service', 'CLN 202',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
-- Casas sem membro, só para as cinco chamadas abertas do CD-B10.
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
select ('c8690000-0000-4000-8000-0000000000f' || k)::uuid, 'Casa 869 extra ' || k, '869555000000' || lpad(k::text, 2, '0'),
       'food_service', 'CLN 2' || k, 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'
  from generate_series(1, 5) k;
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  (pg_temp.u(1), 'c8690000-0000-4000-8000-0000000000e1', 'administrador'),
  (pg_temp.u(3), 'c8690000-0000-4000-8000-0000000000e1', 'administrador'),
  (pg_temp.u(2), 'c8690000-0000-4000-8000-0000000000e2', 'administrador');

-- Ponto base: 19 a ~10 km, 20 a ~30 km; os outros a ~1 km da casa.
insert into public.profissional (id, usuario_id, ponto_base)
select pg_temp.p(n), pg_temp.u(n),
       case n when 19 then 'POINT(-47.8822 -15.7042)' when 20 then 'POINT(-47.8822 -15.5242)'
              else 'POINT(-47.8822 -15.7852)' end::extensions.geography
  from generate_series(11, 42) n;
insert into public.profissional_funcao (profissional_id, funcao_id)
select pg_temp.p(n), case n when 24 then (select id from public.funcao where nome = 'garçonete')
                            when 25 then (select id from public.funcao where nome = 'auxiliar de bar')
                            else pg_temp.garcom() end
  from generate_series(11, 42) n;
insert into public.profissional_servico (profissional_id, funcao_id, unidade, valor_centavos)
select pf.profissional_id, pf.funcao_id, case when pf.profissional_id = pg_temp.p(29) then 'a_combinar' else 'hora' end,
       case when pf.profissional_id = pg_temp.p(29) then null else 5000 end
  from public.profissional_funcao pf
 where pf.profissional_id between pg_temp.p(11) and pg_temp.p(42);
-- 26 sem serviço; 26 também sem região. 27 só em Taguatinga; 28 todo o DF sem região marcada.
delete from public.profissional_servico where profissional_id = pg_temp.p(26);
insert into public.profissional_regiao (profissional_id, regiao_id)
select pg_temp.p(n), case n when 27 then 3 else 1 end from generate_series(11, 42) n where n not in (26, 28);
update public.profissional set atende_todo_df = true where id = pg_temp.p(28);
-- Aparelho na versão mínima da chamada direta para todos, menos 37 (nenhum) e 38 (1.1.0).
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select pg_temp.u(n), 'tok-869-' || n || '-000000000000000000', 'ios', case n when 38 then '1.1.0' else '1.2.0' end
  from generate_series(11, 42) n where n <> 37;

update privado.recurso set ligado = true where chave in ('chamada_direta', 'busca_profissionais');
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;

-- ── privado.nome_curto: o único lugar do "Maria L." (CD-B07, CD-S03) ──────────
select is(privado.nome_curto('Maria'), 'Maria', 'nome de uma palavra: sai inteiro, sem inicial');
select is(privado.nome_curto('Maria Souza'), 'Maria S.', 'nome simples: primeiro nome e a inicial do sobrenome');
select is(privado.nome_curto('Maria Souza Lima'), 'Maria L.', 'dois sobrenomes: a inicial do último (o de família)');
select is(privado.nome_curto('Ana Maria Souza'), 'Ana S.', 'prenome composto: não expõe o segundo prenome');
select is(privado.nome_curto('João dos Santos'), 'João S.', 'partícula (dos) não conta');
select is(privado.nome_curto('Maria da Silva e Souza'), 'Maria S.', 'partículas no meio (da, e) não contam');
select is(privado.nome_curto('  maria   souza-lima  '), 'maria S.', 'espaços sobrando e sobrenome com hífen; o primeiro nome fica como foi escrito');
select is(privado.nome_curto('Maria de'), 'Maria', 'só partícula depois do nome: sem inicial');
select is(privado.nome_curto('João Silva Filho'), 'João S.', 'sufixo de geração (Filho) não conta como sobrenome');
select is(privado.nome_curto('Pedro Souza Júnior'), 'Pedro S.', 'Júnior (com acento) também não conta');
select ok(privado.nome_curto('') is null and privado.nome_curto(null) is null, 'vazio ou nulo: nulo');

-- ── CD-P10: opt-in ────────────────────────────────────────────────────────────
select col_not_null('public', 'profissional_preferencia_chamada', 'aceita_chamadas', 'aceita_chamadas é not null');
select col_default_is('public', 'profissional_preferencia_chamada', 'aceita_chamadas', 'false',
  'aceita_chamadas nasce false (opt-in, CD-P10)');
select is((select count(*)::int from public.profissional_preferencia_chamada where aceita_chamadas), 0,
  'depois da migração, ninguém está na busca: aceita_chamadas false em toda linha');

-- 21 mexe só na antecedência: a linha nasce com aceita_chamadas false.
select is(pg_temp.como(pg_temp.u(21), $$ select public.definir_preferencia_chamadas(antecedencia_minima_h => 6) $$)
            ->> 'aceita_chamadas', 'false', 'preferência criada sem o campo: aceita_chamadas false');
select is(pg_temp.como(pg_temp.u(11), $$ select public.definir_preferencia_chamadas(
            aceita_chamadas => true, versao_texto_busca => 'busca-v1') $$) -> 'pendencias_para_busca',
          '[]'::jsonb, '11 liga pela RPC, com o perfil completo: nenhuma pendência');
select is((select aceita_chamadas_em from public.profissional_preferencia_chamada where profissional_id = pg_temp.p(11)),
          privado.agora(), 'ligar guarda o instante (registro do pedido do titular)');
select is((select versao_texto_busca from public.profissional_preferencia_chamada where profissional_id = pg_temp.p(11)),
          'busca-v1', 'ligar guarda a versão do texto');
-- Cada vez que liga, uma linha no histórico; desligar não apaga e não cria linha.
select pg_temp.como(pg_temp.u(11), $$ select public.definir_preferencia_chamadas(aceita_chamadas => false) $$);
select pg_temp.como(pg_temp.u(11), $$ select public.definir_preferencia_chamadas(
         aceita_chamadas => true, versao_texto_busca => 'busca-v2') $$);
select is((select string_agg(versao_texto_busca, ',' order by em, versao_texto_busca)
             from privado.registro_aceita_chamadas where profissional_id = pg_temp.p(11)),
          'busca-v1,busca-v2', 'o histórico guarda cada vez que liga (v1 e v2), e desligar não apaga');
select ok(not has_table_privilege('authenticated', 'privado.registro_aceita_chamadas', 'select')
          and not has_table_privilege('anon', 'privado.registro_aceita_chamadas', 'select'),
  'nem authenticated nem anon leem o histórico de ligar');
select is(pg_temp.como(pg_temp.u(26), $$ select public.definir_preferencia_chamadas(
            aceita_chamadas => true, versao_texto_busca => 'busca-v1') $$) -> 'pendencias_para_busca',
          '["sem_servico_com_preco", "sem_regiao"]'::jsonb, '26 liga sem serviço e sem região: as duas pendências');
select is(pg_temp.como(pg_temp.u(37), $$ select public.definir_preferencia_chamadas(
            aceita_chamadas => true, versao_texto_busca => 'busca-v1') $$) -> 'pendencias_para_busca',
          '["sem_aparelho_atualizado"]'::jsonb, '37 liga sem aparelho: sem_aparelho_atualizado');

-- Os demais ligam direto na tabela (a RPC já foi provada acima); 21 fica desligado, 22 sem linha.
-- 13 a 18 ficam fora (desligados) só para a página de 20 caber a lista inteira.
insert into public.profissional_preferencia_chamada (profissional_id, aceita_chamadas, aceita_chamadas_em, versao_texto_busca)
select pg_temp.p(n), true, privado.agora(), 'busca-v1'
  from generate_series(12, 42) n where n not in (13, 14, 15, 16, 17, 18, 21, 22, 26, 37)
on conflict (profissional_id) do update set aceita_chamadas = true;
update public.profissional_preferencia_chamada set pausado_ate = current_date + 1 where profissional_id = pg_temp.p(23);
update public.profissional_preferencia_chamada set aceita_de = 'so_cnpj' where profissional_id = pg_temp.p(36);
update public.profissional_preferencia_chamada set antecedencia_minima_h = 48 where profissional_id = pg_temp.p(41);

-- ── Quem entra (sem horário) ──────────────────────────────────────────────────
create temp table l0 as select pg_temp.lista(pg_temp.u(1)) as v;
select ok(pg_temp.tem((select v from l0), 11) and pg_temp.tem((select v from l0), 12),
  'quem ligou, com serviço, região e aparelho, aparece');
select ok(not pg_temp.tem((select v from l0), 21), 'aceita_chamadas desligado: fora (CD-P10)');
select ok(not pg_temp.tem((select v from l0), 22), 'sem preferência gravada: fora');
select ok(not pg_temp.tem((select v from l0), 23), 'pausado até hoje: fora (CD-P12)');
select ok(not pg_temp.tem((select v from l0), 24),
  'só a função exata: quem tem só garçonete não aparece na busca de garçom (o chamar confere a função exata)');
select ok(not pg_temp.tem((select v from l0), 25), 'serviço só de outra função: fora (CD-P09)');
select ok(not pg_temp.tem((select v from l0), 26), 'sem serviço e sem região: fora (CD-P09, CD-P14)');
select ok(not pg_temp.tem((select v from l0), 27), 'só outra região marcada: fora (CD-P14)');
select ok(pg_temp.tem((select v from l0), 28), 'todo o DF, sem região marcada: entra (CD-P14)');
select ok(pg_temp.tem((select v from l0), 29), 'serviço a_combinar conta como unidade de preço: entra');
select ok(pg_temp.tem((select v from l0), 36), 'só-CNPJ aparece para a casa com CNPJ');
select ok(not pg_temp.tem((select v from l0), 37) and not pg_temp.tem((select v from l0), 38),
  'sem aparelho, ou com app abaixo do mínimo da chamada direta: fora');
select ok(pg_temp.tem((select v from l0), 40) and pg_temp.tem((select v from l0), 41),
  'sem horário, agenda e antecedência não tiram ninguém');

-- Só-CNPJ, vista pela casa de pessoa física (membro 02 da E2).
create temp table lpf as select pg_temp.lista(pg_temp.u(2), '', 'c8690000-0000-4000-8000-0000000000e2') as v;
select ok(not pg_temp.tem((select v from lpf), 36) and pg_temp.tem((select v from lpf), 11),
  'só-CNPJ não aparece para a casa de pessoa física, e os outros aparecem (CD-P13)');

-- ── CD-B06: bloqueio nos dois sentidos, com qualquer membro ───────────────────
insert into public.bloqueio (autor_id, bloqueado_id) values (pg_temp.u(1), pg_temp.u(30)), (pg_temp.u(31), pg_temp.u(3));
create temp table l1 as select pg_temp.lista(pg_temp.u(1)) as v;
select ok(not pg_temp.tem((select v from l1), 30), 'membro bloqueou o profissional: fora');
select ok(not pg_temp.tem((select v from l1), 31), 'o profissional bloqueou OUTRO membro da casa: fora também');

-- ── Conta fora do ar e demonstração ───────────────────────────────────────────
update public.usuario set demonstracao = true where id = pg_temp.u(33);
update public.usuario set estado = 'suspensa' where id = pg_temp.u(34);
update public.usuario set estado = 'anonimizada', anonimizado_em = privado.agora() where id = pg_temp.u(35);
create temp table l2 as select pg_temp.lista(pg_temp.u(1)) as v;
select ok(not pg_temp.tem((select v from l2), 33), 'conta de demonstração não aparece para conta real');
select ok(not pg_temp.tem((select v from l2), 34), 'conta suspensa: fora (RN13)');
select ok(not pg_temp.tem((select v from l2), 35), 'conta anonimizada: fora (RF25)');

-- ── CD-B10: cinco chamadas abertas tiram; volta sozinho quando uma fecha ──────
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos, posicoes,
                         inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo,
                         chave_cliente, publicado_por, origem, estado)
select ('c8690000-0000-4000-8000-00000000a0' || lpad(k::text, 2, '0'))::uuid,
       case when k <= 5 then ('c8690000-0000-4000-8000-0000000000f' || k)::uuid else 'c8690000-0000-4000-8000-0000000000e1'::uuid end,
       pg_temp.garcom(), '2026-11-20 21:00+00', '2026-11-21 02:00+00', 'CLN', 'POINT(-47.8822 -15.7942)'::extensions.geography,
       15000, 1, true, false, false, 'Maitre', 'urgencia', gen_random_uuid(), pg_temp.u(1), 'chamada_direta', 'publicada'
  from generate_series(1, 6) k;
insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, estado, expira_em, chave)
select ('c8690000-0000-4000-8000-00000000a0' || lpad(k::text, 2, '0'))::uuid, pg_temp.p(32),
       ('c8690000-0000-4000-8000-0000000000f' || k)::uuid, pg_temp.u(1), 'aberta', '2026-11-17 03:00+00', gen_random_uuid()
  from generate_series(1, 5) k;
select ok(not pg_temp.tem(pg_temp.lista(pg_temp.u(1)), 32), 'com 5 chamadas abertas: fora (CD-B10)');
update public.chamada set estado = 'cancelada' where vaga_id = 'c8690000-0000-4000-8000-00000000a001';
select ok(pg_temp.tem(pg_temp.lista(pg_temp.u(1)), 32), 'uma aberta foi cancelada: volta sozinho, sem registro contra ele');

-- ── CD-C13: recusou uma chamada desta casa há menos de 24 h ────────────────────
insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, estado, expira_em, chave, respondida_em)
values ('c8690000-0000-4000-8000-00000000a006', pg_temp.p(39), 'c8690000-0000-4000-8000-0000000000e1', pg_temp.u(1),
        'recusada', '2026-11-17 03:00+00', gen_random_uuid(), '2026-11-16 14:00+00');
select ok(not pg_temp.tem(pg_temp.lista(pg_temp.u(1)), 39), 'recusou chamada da casa há 1 h: fora para esta casa (par_em_pausa)');

-- RN34: já tem chamada aberta desta casa: fora para ela, presente para a outra.
insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, estado, expira_em, chave)
values ('c8690000-0000-4000-8000-00000000a006', pg_temp.p(29), 'c8690000-0000-4000-8000-0000000000e1', pg_temp.u(1),
        'aberta', '2026-11-17 03:00+00', gen_random_uuid());
select ok(not pg_temp.tem(pg_temp.lista(pg_temp.u(1)), 29)
          and pg_temp.tem(pg_temp.lista(pg_temp.u(2), '', 'c8690000-0000-4000-8000-0000000000e2'), 29),
  'chamada aberta desta casa: fora para ela (chamada_ja_aberta), presente para outra casa');
update public.chamada set estado = 'cancelada' where profissional_id = pg_temp.p(29);

-- ── Com horário: prazo e grade ────────────────────────────────────────────────
-- Terça 17/11, 18:00 a 23:00 em Brasília (30 h à frente).
-- 40 tem turno confirmado no mesmo horário (não tira); 42 e 19 têm grade que cobre (terça 17:00 a 23:30).
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos, posicoes,
                         inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo,
                         chave_cliente, publicado_por, estado)
values ('c8690000-0000-4000-8000-00000000b001', 'c8690000-0000-4000-8000-0000000000e2', pg_temp.garcom(),
        '2026-11-17 20:00+00', '2026-11-18 01:00+00', 'CLN', 'POINT(-47.8822 -15.7942)'::extensions.geography,
        15000, 1, true, false, false, 'Maitre', 'urgencia', gen_random_uuid(), pg_temp.u(2), 'preenchida');
insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values ('c8690000-0000-4000-8000-00000000b001', 'confirmada', pg_temp.p(40), privado.agora(),
        '2026-11-17 20:00+00', '2026-11-18 01:00+00');
insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
values (pg_temp.p(42), 2, '17:00', '23:30'), (pg_temp.p(19), 2, '17:00', '23:30'),
       (pg_temp.p(12), 2, '19:00', '23:30');  -- 12 cobre só parte: não ganha o selo

create temp table lh as select pg_temp.lista(pg_temp.u(1),
  $$, inicio_em => '2026-11-17 21:00+00', fim_em => '2026-11-18 02:00+00'$$) as v;
select ok(pg_temp.tem((select v from lh), 40),
  'com horário: turno confirmado no mesmo horário NÃO tira (a busca não revela a agenda; 0.2.88)');
select ok(not pg_temp.tem((select v from lh), 41), 'com horário: antecedência mínima de 48 h maior que o prazo tira (RN31)');
select is((string_to_array((select v from lh), ','))[1:2], array['42', '19'],
  'quem tem a grade cobrindo o horário vem primeiro (42 até 5 km, depois 19 de 5 a 15 km), antes dos de até 5 km sem grade');
select is((select e->>'disponivel_no_horario'
             from jsonb_array_elements(pg_temp.como(pg_temp.u(1), format(
               $$ select public.buscar_profissionais(estabelecimento_id => %L, funcao_id => %L,
                    inicio_em => '2026-11-17 21:00+00', fim_em => '2026-11-18 02:00+00') $$,
               'c8690000-0000-4000-8000-0000000000e1', pg_temp.garcom())) -> 'itens') e
            where e->>'id' = pg_temp.p(12)::text), 'false',
  'grade que cobre só parte do horário não dá o selo');

-- ── Ordem sem horário: faixa de distância, embaralho estável ──────────────────
create temp table la as select pg_temp.lista(pg_temp.u(1)) as v;
select ok(pg_temp.posicao_de((select v from la), 19) = array_length(string_to_array((select v from la), ','), 1) - 1
          and pg_temp.posicao_de((select v from la), 20) = array_length(string_to_array((select v from la), ','), 1),
  'sem horário: os de até 5 km primeiro, depois 5 a 15 km (19), depois mais de 15 km (20)');
select is(pg_temp.lista(pg_temp.u(1)), (select v from la), 'a mesma conta, no mesmo dia: a mesma ordem');
select isnt(pg_temp.lista(pg_temp.u(3)), (select v from la), 'outro contratante da mesma casa: outra ordem');
select is((select string_agg(x, ',' order by x) from unnest(string_to_array(pg_temp.lista(pg_temp.u(3)), ',')) x),
          (select string_agg(x, ',' order by x) from unnest(string_to_array((select v from la), ',')) x),
  'mesma lista de pessoas para os dois contratantes, só a ordem muda');
select set_config('frila.agora', '2026-11-17 15:00:00+00', true);
select isnt(pg_temp.lista(pg_temp.u(1)), (select v from la), 'no dia seguinte, a ordem muda');
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);

-- ── RN06 / D2: a reputação não ordena ─────────────────────────────────────────
-- Dá reputação máxima a quem está no fim da faixa de até 5 km (antes de 19 e 20) e zera a de quem
-- está no começo.
update public.profissional set aval_positivas = 50, aval_total = 50, taxa_comparecimento = 1, turnos_realizados = 50
 where id = pg_temp.p(split_part((select v from la), ',',
                                 array_length(string_to_array((select v from la), ','), 1) - 2)::int);
update public.profissional set aval_positivas = 0, aval_total = 40, taxa_comparecimento = 0, turnos_realizados = 0
 where id = pg_temp.p(right(split_part((select v from la), ',', 1), 2)::int);
select is((select (e->'reputacao'->>'total')::int
             from jsonb_array_elements(pg_temp.como(pg_temp.u(1), format(
               'select public.buscar_profissionais(estabelecimento_id => %L, funcao_id => %L)',
               'c8690000-0000-4000-8000-0000000000e1', pg_temp.garcom())) -> 'itens') e
            where right(e->>'id', 2) = split_part((select v from la), ',', 1)), 40,
  'o cartão mostra a reputação nova (a mudança valeu)');
select is(pg_temp.lista(pg_temp.u(1)), (select v from la), 'mudar a reputação não muda a ordem (RN06, D2)');

-- ── LGPD do registro de ligar (decisão da Bússola, 16/11/2026) ───────────────
select is((select jsonb_agg(r->>'versao_texto_busca' order by r->>'em', r->>'versao_texto_busca')
             from jsonb_array_elements(privado.meus_dados(pg_temp.u(11)) -> 'registros_aceita_chamadas') r),
          '["busca-v1", "busca-v2"]'::jsonb, 'meus_dados exporta cada vez que o titular ligou (versão e instante)');
select is(privado.meus_dados(pg_temp.u(1)) -> 'registros_aceita_chamadas', '[]'::jsonb,
  'na exportação de quem opera a casa, registros_aceita_chamadas vem vazio');
-- 11 exclui a conta há 16 dias: a limpeza de 15 dias apaga o registro e a preferência da busca.
update public.usuario set estado = 'anonimizada', anonimizado_em = privado.agora() - interval '16 days'
 where id = pg_temp.u(11);
select is((privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(15) ->> 'registros_aceita_chamadas_apagados')::int, 2,
  'a limpeza da conta excluída apaga as duas linhas do registro');
select ok(not exists (select 1 from privado.registro_aceita_chamadas where profissional_id = pg_temp.p(11))
          and (select not aceita_chamadas and aceita_chamadas_em is null and versao_texto_busca is null
                 from public.profissional_preferencia_chamada where profissional_id = pg_temp.p(11)),
  'depois da limpeza: nenhuma linha do registro e a preferência da busca limpa');

select * from finish();
rollback;
