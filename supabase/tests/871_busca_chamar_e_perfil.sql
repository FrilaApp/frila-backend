-- 871_busca_chamar_e_perfil.sql
--
-- Busca de profissionais, PR 2 (migração 20261116220000, contrato 0.2.88): chamar quem está na busca,
-- a região da vaga direta, o perfil rico pela busca e o nome curto em toda leitura de PerfilPublico.
--   A  chamar_profissional pela busca, sem vínculo: quem entra, quem não entra (a mesma recusa genérica),
--      a demonstração isolada por população (M5), regiao_id (guardado, inválido = 422), a 2ª e a 3ª
--      chamada pelo vaga_id, a chave desligada e o caminho do vínculo igual ao de antes
--   B  PARIDADE: quem a busca mostra, a chamada aceita; quem ela não mostra, a chamada recusa
--   C  perfil_publico: o profissional na busca é vínculo de leitura do perfil rico (com ou sem pausa),
--      a foto TAMBÉM (0.2.90, com o aceite dos Termos 1.1; o 873 cobre o caso sem aceite), e o nome vem curto sem candidatura, turno nem equipe
--   D  o nome curto em CADA leitora de PerfilPublico (minhas_chamadas, detalhe_chamada, candidatos_da_vaga)
--      e em ItemBloqueio.nome; o nome inteiro com candidatura, turno e equipe
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
-- 16/11/2026, 12:00 em Brasília (segunda-feira).
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-871';
set local frila.ler_midia_function_url = 'http://funcoes.invalid/functions/v1/ler-midia';
select plan(87);

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;
-- O envelope inteiro da recusa ("status code details"), ou 'ok'.
create function pg_temp.tenta(conta uuid, sql text) returns text language plpgsql as $$
declare m text; d text;
begin
  perform pg_temp.como(conta, sql);
  return 'ok';
exception when others then
  get stacked diagnostics m = message_text, d = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return case when m ~ '^\s*\{' then concat_ws(' ', d::jsonb->>'status', m::jsonb->>'code', m::jsonb->>'details') else m end;
end $$;
create function pg_temp.u(n int) returns uuid language sql immutable as $$
  select ('c8710000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.p(n int) returns uuid language sql immutable as $$
  select ('c8710000-0000-4000-8000-0000000001' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.casa(n int) returns uuid language sql immutable as $$
  select ('c8710000-0000-4000-8000-00000000e0' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.garcom() returns uuid language sql stable as $$ select id from public.funcao where nome = 'garçom' $$;

-- chamar_profissional como a conta, para o profissional n, em casa. Corpo válido; extra acrescenta ou troca argumentos.
-- 0.2.95: sem inicio, cada profissional vai a um minuto próprio a partir de 17/11 18:00, um trabalho próprio
-- (no mesmo minuto, a chamada a outra pessoa receberia trabalho_ja_aberto, que vem antes das outras recusas).
create function pg_temp.inicio_padrao(prof int) returns timestamptz language sql stable as $$
  select '2026-11-17 18:00+00'::timestamptz + prof * interval '1 minute' $$;
create function pg_temp.chamar(conta uuid, casa uuid, prof int, regiao text default 'Plano Piloto',
                               extra text default '', inicio text default null) returns text
language sql as $$
  select pg_temp.tenta(conta, format($a$ select public.chamar_profissional(chave => gen_random_uuid(),
    profissional_id => %L, estabelecimento_id => %L, funcao_id => %L, inicio_em => %L, fim_em => %L,
    local => 'CLN 201', regiao_administrativa => %L, ponto => '{"latitude":-15.7942,"longitude":-47.8822}',
    valor_centavos => 15000, inclui_refeicao => true, inclui_transporte => false,
    exige_material_proprio => false, responsavel_local => 'Maitre' %s) $a$,
    pg_temp.p(prof), casa, pg_temp.garcom(), coalesce(inicio::timestamptz, pg_temp.inicio_padrao(prof)),
    coalesce(inicio::timestamptz, pg_temp.inicio_padrao(prof)) + interval '5 hours', regiao, extra)) $$;
-- A 2ª ou 3ª chamada pela vaga direta.
create function pg_temp.chamar_vaga(conta uuid, casa uuid, prof int, vaga uuid) returns text language sql as $$
  select pg_temp.tenta(conta, format($a$ select public.chamar_profissional(chave => gen_random_uuid(),
    profissional_id => %L, estabelecimento_id => %L, vaga_id => %L) $a$, pg_temp.p(prof), casa, vaga)) $$;
create function pg_temp.perfil(leitor uuid, alvo uuid) returns jsonb language sql as
  $$ select pg_temp.como(leitor, format('select public.perfil_publico(%L::uuid)', alvo)) $$;
create function pg_temp.nome(leitor uuid, alvo uuid) returns text language sql as
  $$ select pg_temp.perfil(leitor, alvo) ->> 'nome' $$;
-- Quem a busca da casa mostra (os dois últimos dígitos do id de cada um, em ordem).
create function pg_temp.lista(conta uuid, casa uuid, regiao int default 1) returns text language plpgsql as $$
declare r jsonb;
begin
  delete from privado.contador_busca;
  r := pg_temp.como(conta, format(
    'select public.buscar_profissionais(estabelecimento_id => %L, funcao_id => %L, regiao_id => %s)',
    casa, pg_temp.garcom(), regiao));
  return coalesce((select string_agg(right(e->>'id', 2), ',' order by o)
                     from jsonb_array_elements(r->'itens') with ordinality x(e, o)), '');
end $$;
create function pg_temp.tem(lista text, n int) returns boolean language sql immutable as $$
  select lpad(n::text, 2, '0') = any(string_to_array(lista, ',')) $$;
-- Um turno cumprido e verificado da casa com o profissional (o vínculo "turno").
create function pg_temp.turno(p_estab uuid, p_prof uuid, p_inicio timestamptz) returns void language plpgsql as $$
declare v_vaga uuid := gen_random_uuid(); v_pos uuid := gen_random_uuid();
begin
  insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto, valor_centavos,
                           posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo,
                           chave_cliente, publicado_em, estado)
  values (v_vaga, p_estab, pg_temp.garcom(), (select usuario_id from public.membro_estabelecimento where estabelecimento_id = p_estab limit 1),
          p_inicio, p_inicio + interval '6 hours', 'Local 871', 'POINT(-47.88 -15.78)'::extensions.geography, 15000, 1,
          true, false, false, 'Responsável 871', 'urgencia', gen_random_uuid(), p_inicio - interval '2 days', 'encerrada');
  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, falta, inicio_em, fim_em)
  values (v_pos, v_vaga, p_prof, 'cumprida', p_inicio - interval '1 day', false, p_inicio, p_inicio + interval '6 hours');
  insert into public.turno (id, posicao_id, checkin_em, checkout_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
  values (gen_random_uuid(), v_pos, p_inicio, p_inicio + interval '6 hours', 'geolocalizado', 50, 'verificado', 15000);
end $$;

-- ── Massa ─────────────────────────────────────────────────────────────────────
-- Contratantes: 1 (casa CNPJ), 2 (casa CPF), 3 (casa de demonstração), 4 (sem casa), 5 (casa 4, a do teste das 3 chamadas por vaga).
-- Profissionais 11 a 44.
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', pg_temp.u(n), 'authenticated', 'authenticated',
       'p' || n || '@t871.test', privado.agora(), privado.agora(), false, false
  from (select generate_series(1, 5) union all select generate_series(11, 44)) s(n);
select pg_temp.como(pg_temp.u(n), format(
  $$ select public.criar_conta(%L, %L, %L, '1990-01-01', '2026-11-13') $$,
  case when n <= 5 then 'contratante' else 'profissional' end,
  case n when 11 then 'Maria Souza Lima' when 19 then 'Pedro Alves Pinto' when 25 then 'Carla Mendes Rocha'
         when 26 then 'Rui Barbosa Neto' when 36 then 'Joana Pereira Dias' else 'Prof ' || n || ' Sobrenome' end,
  '+55619555871' || lpad(n::text, 2, '0')))
  from (select generate_series(1, 5) union all select generate_series(11, 44)) s(n);
update public.usuario set demonstracao = true where id in (pg_temp.u(3), pg_temp.u(14));

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  (pg_temp.casa(1), 'Casa 871 CNPJ', '87112345000169', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  (pg_temp.casa(2), 'Casa 871 CPF',  '87112345669',    'food_service', 'CLN 202', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  (pg_temp.casa(3), 'Casa 871 Demo', '87112345000270', 'food_service', 'CLN 203', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  (pg_temp.casa(4), 'Casa 871 Vaga', '87112345000371', 'food_service', 'CLN 204', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
-- Casas sem membro, só para o que depende de outra casa (cinco abertas, recusa de outra casa).
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
select pg_temp.casa(10 + k), 'Casa 871 extra ' || k, '8719999900' || lpad(k::text, 2, '0') || '69', 'food_service', 'CLN 2' || k,
       'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'
  from generate_series(1, 5) k;
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  (pg_temp.u(1), pg_temp.casa(1), 'administrador'),
  (pg_temp.u(2), pg_temp.casa(2), 'administrador'),
  (pg_temp.u(3), pg_temp.casa(3), 'administrador'),
  (pg_temp.u(5), pg_temp.casa(4), 'administrador');

insert into public.profissional (id, usuario_id, ponto_base, apresentacao)
select pg_temp.p(n), pg_temp.u(n), 'POINT(-47.8822 -15.7852)'::extensions.geography, 'Apresentação ' || n
  from generate_series(11, 44) n;
insert into public.profissional_funcao (profissional_id, funcao_id)
select pg_temp.p(n), pg_temp.garcom() from generate_series(11, 44) n;
insert into public.profissional_servico (profissional_id, funcao_id, unidade, valor_centavos)
select pg_temp.p(n), pg_temp.garcom(), 'hora', 5000 from generate_series(11, 44) n;
delete from public.profissional_servico where profissional_id = pg_temp.p(16);          -- 16: sem serviço
-- Regiões: 17, 32, 33 e 34 só em Taguatinga (3); 18 e 27 atendem o DF todo; os outros, o Plano Piloto (1).
insert into public.profissional_regiao (profissional_id, regiao_id)
select pg_temp.p(n), case when n in (17, 32, 33, 34) then 3 else 1 end
  from generate_series(11, 44) n where n not in (18, 27);
update public.profissional set atende_todo_df = true where id in (pg_temp.p(18), pg_temp.p(27));
-- Aparelho na versão mínima da chamada direta para todos, menos 23 (1.1.0).
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select pg_temp.u(n), 'tok-871-' || n || '-000000000000000000', 'ios', case n when 23 then '1.1.0' else '1.2.0' end
  from generate_series(11, 44) n;

-- Preferências. "Aceito chamadas diretas" ligado para quase todos; 12 desligado, 13 sem linha, 19 e 31 (vínculo) desligado.
insert into public.profissional_preferencia_chamada (profissional_id, aceita_chamadas, aceita_chamadas_em, versao_texto_busca)
select pg_temp.p(n), true, privado.agora(), 'busca-v1' from generate_series(11, 44) n where n not in (12, 13, 19, 31, 39);
insert into public.profissional_preferencia_chamada (profissional_id) values (pg_temp.p(12)), (pg_temp.p(19)), (pg_temp.p(31)), (pg_temp.p(39));
update public.profissional_preferencia_chamada set pausado_ate = current_date + 1 where profissional_id in (pg_temp.p(15), pg_temp.p(31));
update public.profissional_preferencia_chamada set aceita_de = 'so_cnpj' where profissional_id = pg_temp.p(22);
update public.profissional_preferencia_chamada set aceita_de_quem_ja_trabalhou = false where profissional_id in (pg_temp.p(38), pg_temp.p(39));
update public.profissional_preferencia_chamada set antecedencia_minima_h = 48 where profissional_id = pg_temp.p(24);

-- Vínculos de trabalho com a casa 1: 19 e 31 equipe; 25 candidatura; 26 turno.
insert into public.equipe_confianca (estabelecimento_id, profissional_id) values
  (pg_temp.casa(1), pg_temp.p(19)), (pg_temp.casa(1), pg_temp.p(31)), (pg_temp.casa(1), pg_temp.p(39));
select pg_temp.turno(pg_temp.casa(1), pg_temp.p(26), '2026-11-01 10:00-03');
select pg_temp.como(pg_temp.u(1),
  -- Início relativo ao relógio real (3 dias; 8 h de turno): a vaga de seleção exige início > publicação + 24 h
  -- (selecao_com_antecedencia) e a publicação usa now(); a data fixa de 25/11/2026 venceu em 24/11 18:00 UTC (B-111).
  format($$select public.publicar_vaga(%L, %L, %L::timestamptz, %L::timestamptz,
    'CLN 871 vaga', '{"latitude": -15.79, "longitude": -47.88}'::jsonb, 20000, 1,
    true, false, false, 'Gerente 871', 'selecao', %L::uuid, 'preto', false, null, 180, 'Plano Piloto')$$,
    pg_temp.casa(1), pg_temp.garcom(), now() + interval '3 days', now() + interval '3 days 8 hours', gen_random_uuid()));
select pg_temp.como(pg_temp.u(25), $$select public.candidatar((select id from public.vaga where local = 'CLN 871 vaga'))$$);

-- 20: cinco chamadas abertas de outras casas. 21: recusou chamada da casa 1 há menos de 24 h.
insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto, valor_centavos, posicoes,
                         inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo, chave_cliente,
                         publicado_em, estado, origem)
select ('c8710000-0000-4000-8000-0000000002' || lpad(k::text, 2, '0'))::uuid, case when k = 6 then pg_temp.casa(1) else pg_temp.casa(10 + ((k - 1) % 5) + 1) end, pg_temp.garcom(),
       pg_temp.u(1), '2026-11-30 18:00+00', '2026-11-30 23:00+00', 'Local 871', 'POINT(-47.88 -15.78)'::extensions.geography,
       15000, 1, true, false, false, 'Resp', 'urgencia', gen_random_uuid(), '2026-11-16 12:00+00', 'publicada', 'chamada_direta'
  from generate_series(1, 6) k;
insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, expira_em, chave, estado, respondida_em, criada_em)
select ('c8710000-0000-4000-8000-0000000002' || lpad(k::text, 2, '0'))::uuid, pg_temp.p(20), pg_temp.casa(10 + ((k - 1) % 5) + 1),
       pg_temp.u(1), '2026-11-17 00:00+00', gen_random_uuid(), 'aberta', null, '2026-11-16 12:00+00'
  from generate_series(1, 5) k;
insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, expira_em, chave, estado, respondida_em, criada_em)
values ('c8710000-0000-4000-8000-000000000206', pg_temp.p(21), pg_temp.casa(1), pg_temp.u(1), '2026-11-17 00:00+00', gen_random_uuid(),
        'recusada', '2026-11-16 10:00+00', '2026-11-16 09:00+00');
-- 20 de verdade é a 20; a chamada recusada de 21 é da casa 1.

update privado.recurso set ligado = true where chave in ('chamada_direta', 'busca_profissionais', 'perfil_rico');
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;

-- ══ A. chamar_profissional pela busca ═════════════════════════════════════════
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 11, extra => ', regiao_id => 1'), 'ok',
  'A1 quem está na busca recebe a chamada SEM vínculo de trabalho com a casa');
select is((select v.regiao_id::int from public.chamada c join public.vaga v on v.id = c.vaga_id
            where c.profissional_id = pg_temp.p(11)), 1, 'A2 a vaga direta guarda o regiao_id com que nasceu');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 11), '409 chamada_ja_aberta',
  'A3 segunda chamada ao mesmo profissional: o 409 chamada_ja_aberta de sempre');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 12), '422 profissional_indisponivel nao_aceita_chamadas',
  'A4 sem "Aceito chamadas diretas" e sem vínculo: a recusa genérica de sempre');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 13), '422 profissional_indisponivel nao_aceita_chamadas',
  'A5 sem linha de preferência e sem vínculo: a mesma recusa genérica');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 15), '422 profissional_indisponivel nao_aceita_chamadas',
  'A6 na busca mas em pausa: genérica, sem dizer "pausado" (a casa sem vínculo não descobre a pausa)');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 31), '422 profissional_indisponivel pausado',
  'A7 vínculo (equipe) com pausa: "pausado", como antes da busca');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 16), '422 profissional_indisponivel nao_aceita_chamadas',
  'A8 na busca mas sem serviço com preço para a função: genérica');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 17), '422 profissional_indisponivel nao_aceita_chamadas',
  'A9 atende só Taguatinga e o trabalho é no Plano Piloto: genérica');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 17, 'Taguatinga', ', regiao_id => 3'), 'ok',
  'A10 o mesmo profissional, com o trabalho em Taguatinga (regiao_id 3): a chamada nasce, apesar de a casa ser do Plano Piloto');
select is((select v.regiao_id::int from public.chamada c join public.vaga v on v.id = c.vaga_id
            where c.profissional_id = pg_temp.p(17)), 3, 'A11 a vaga guarda o regiao_id 3');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 32, 'Taguatinga'), 'ok',
  'A12 sem regiao_id, a região do trabalho é a que tem o mesmo nome de regiao_administrativa');
select is((select v.regiao_id from public.chamada c join public.vaga v on v.id = c.vaga_id where c.profissional_id = pg_temp.p(32)),
  null, 'A13 sem regiao_id no corpo, a vaga não guarda nenhum');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 18, 'Ceilândia'), 'ok',
  'A14 atende o DF todo (sem região marcada): qualquer região do trabalho serve');

-- regiao_id inválido: 422 campo_invalido (regiao_id), e nenhuma chamada nasce.
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 27, extra => ', regiao_id => 9999'), '422 campo_invalido regiao_id',
  'A15 regiao_id fora do catálogo: 422 campo_invalido (regiao_id)');
update public.regiao_administrativa set ativo = false where id = 5;
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 27, (select nome from public.regiao_administrativa where id = 5), ', regiao_id => 5'),
  '422 campo_invalido regiao_id', 'A16 regiao_id de região inativa: 422 campo_invalido (regiao_id)');
update public.regiao_administrativa set ativo = true where id = 5;
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 27, 'Taguatinga', ', regiao_id => 1'), '422 campo_invalido regiao_id',
  'A17 regiao_id de nome diferente do regiao_administrativa do corpo: 422 campo_invalido (regiao_id)');
select is((select count(*)::int from public.chamada where profissional_id = pg_temp.p(27)), 0, 'A18 nenhuma dessas recusas criou chamada');
-- Sem a busca, o regiao_id também vale para quem tem vínculo (a vaga o guarda).
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 19, extra => ', regiao_id => 1'), 'ok',
  'A19 o caminho do vínculo (equipe, sem "Aceito chamadas diretas") segue igual, agora com regiao_id');

-- 2ª e 3ª chamada pela vaga direta: a função e a região são as da vaga.
select is(pg_temp.chamar_vaga(pg_temp.u(1), pg_temp.casa(1), 27,
            (select c.vaga_id from public.chamada c where c.profissional_id = pg_temp.p(11))), 'ok',
  'A20 2ª chamada pela vaga (região 1): quem atende o DF todo e está na busca recebe');
select is(pg_temp.chamar_vaga(pg_temp.u(1), pg_temp.casa(1), 33,
            (select c.vaga_id from public.chamada c where c.profissional_id = pg_temp.p(11))), '422 profissional_indisponivel nao_aceita_chamadas',
  'A21 pela vaga do Plano Piloto, quem atende só Taguatinga não serve: a região é a da vaga');
select is(pg_temp.chamar_vaga(pg_temp.u(1), pg_temp.casa(1), 33,
            (select c.vaga_id from public.chamada c where c.profissional_id = pg_temp.p(17))), 'ok',
  'A22 pela vaga de Taguatinga (regiao_id guardado), o mesmo profissional serve');
-- Vaga direta anterior à 0.2.88 (regiao_id nulo): vale o nome da região da vaga.
update public.vaga set regiao_id = null where id = (select c.vaga_id from public.chamada c where c.profissional_id = pg_temp.p(17));
select is(pg_temp.chamar_vaga(pg_temp.u(1), pg_temp.casa(1), 34,
            (select c.vaga_id from public.chamada c where c.profissional_id = pg_temp.p(17))), 'ok',
  'A23 vaga direta sem regiao_id guardado: a região vem do nome em regiao_administrativa');

-- As demais regras valem igual para os dois caminhos.
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 20), '422 profissional_indisponivel agenda_cheia',
  'A24 cinco abertas: agenda_cheia, também pela busca');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 21), '422 profissional_indisponivel par_em_pausa',
  'A25 recusou esta casa há menos de 24 h: par_em_pausa (o código específico, pelos dois caminhos)');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 24), '422 profissional_indisponivel antecedencia_insuficiente',
  'A26 o prazo do profissional (48 h) vale pela busca');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 23), '422 profissional_indisponivel nao_aceita_chamadas',
  'A27 sem aparelho na versão mínima: genérica, pela busca também');
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 22), '422 profissional_indisponivel nao_aceita_chamadas',
  'A28 só-CNPJ tira a casa de pessoa física, pela busca também');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 22), 'ok', 'A29 e a casa com CNPJ chama o mesmo profissional');
-- Demonstração: a conta real não chama a de demonstração, nem o contrário (M5).
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 14), '422 profissional_indisponivel nao_aceita_chamadas',
  'A30 contratante real, profissional de demonstração na busca: genérica');
select is(pg_temp.chamar(pg_temp.u(3), pg_temp.casa(3), 35), '422 profissional_indisponivel nao_aceita_chamadas',
  'A31 contratante de demonstração, profissional real na busca: genérica');
select is(pg_temp.chamar(pg_temp.u(3), pg_temp.casa(3), 14), 'ok',
  'A32 demonstração com demonstração funciona (a população é a mesma)');
-- A chave desligada: só quem tem vínculo.
update privado.recurso set ligado = false where chave = 'busca_profissionais';
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 35), '422 profissional_indisponivel nao_aceita_chamadas',
  'A33 com busca_profissionais desligado, quem está só na busca não recebe');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 31, extra => ''), '422 profissional_indisponivel pausado',
  'A34 e o vínculo segue valendo (aqui, a pausa dele)');
update privado.recurso set ligado = true where chave = 'busca_profissionais';
-- Bloqueio tem precedência (RF26).
select pg_temp.como(pg_temp.u(1), format($$select public.bloquear('profissional', %L::uuid)$$, pg_temp.p(36)));
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 36), '404 nao_encontrado', 'A35 bloqueado: 404, antes de qualquer outra recusa');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 36, extra => ', regiao_id => 9999'), '404 nao_encontrado',
  'A36 bloqueado com regiao_id inválido: o 404 do bloqueio vem ANTES do 422 de regiao_id (CD-C03)');

-- "Aceitar chamadas de quem já trabalhou comigo" desligado só vale no caminho do VÍNCULO (contrato 0.2.88).
create temp table lista_p38 as select pg_temp.lista(pg_temp.u(2), pg_temp.casa(2)) as v;
select ok(pg_temp.tem((select v from lista_p38), 38),
  'A37 "Aceito chamadas diretas" ligado com aceita_de_quem_ja_trabalhou desligado: aparece na busca');
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 38), 'ok',
  'A38 e a chamada pela busca, sem vínculo, FUNCIONA: a preferência do vínculo não o barra');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 39), '422 profissional_indisponivel nao_aceita_chamadas',
  'A39 controle: com vínculo (equipe) e a preferência desligada, sem "Aceito chamadas diretas": a recusa genérica de sempre (857)');

-- A 1ª chamada pela busca cria a vaga direta; a 2ª e a 3ª, com o vaga_id dela, ficam na mesma vaga; a 4ª recusa
-- pelo limite de 3 por vaga (422 limite_de_chamadas, por_vaga). Casa 4, sem vínculo com nenhum dos quatro.
create temp table vagas_antes as select count(*)::int as n from public.vaga where estabelecimento_id = pg_temp.casa(4);
select is(pg_temp.chamar(pg_temp.u(5), pg_temp.casa(4), 41), 'ok', 'A40 a 1ª chamada pela busca (sem vínculo) nasce');
create temp table vaga_primeira as select c.vaga_id as id from public.chamada c where c.profissional_id = pg_temp.p(41);
select is((select count(*)::int from public.vaga where estabelecimento_id = pg_temp.casa(4)) - (select n from vagas_antes), 1,
  'A41 a 1ª chamada criou UMA vaga direta nova na casa');
select is(pg_temp.chamar_vaga(pg_temp.u(5), pg_temp.casa(4), 42, (select id from vaga_primeira)), 'ok', 'A42 a 2ª chamada, a outro profissional, pelo vaga_id da 1ª');
select is(pg_temp.chamar_vaga(pg_temp.u(5), pg_temp.casa(4), 43, (select id from vaga_primeira)), 'ok', 'A43 a 3ª chamada, a outro profissional, pelo vaga_id da 1ª');
select is((select count(*)::int from public.vaga where estabelecimento_id = pg_temp.casa(4)) - (select n from vagas_antes), 1,
  'A44 a 2ª e a 3ª NÃO criaram vaga: a casa tem só a vaga a mais da 1ª');
select is((select count(*)::int || '/' || count(distinct profissional_id)::int from public.chamada where vaga_id = (select id from vaga_primeira)),
  '3/3', 'A45 as três chamadas ficam na mesma vaga, para três profissionais diferentes');
select is(pg_temp.chamar_vaga(pg_temp.u(5), pg_temp.casa(4), 44, (select id from vaga_primeira)), '422 limite_de_chamadas por_vaga',
  'A46 a 4ª chamada no mesmo vaga_id recusa pelo limite de 3 por vaga (422 limite_de_chamadas, por_vaga)');
select is((select count(*) from public.chamada where vaga_id = (select id from vaga_primeira))::text || '/'
          || ((select count(*) from public.vaga where estabelecimento_id = pg_temp.casa(4)) - (select n from vagas_antes))::text,
  '3/1', 'A47 a recusa não criou chamada nem vaga');

-- ══ B. Paridade: quem a busca mostra, a chamada aceita ════════════════════════
create temp table lista_busca as select pg_temp.lista(pg_temp.u(1), pg_temp.casa(1)) as v;
select ok(pg_temp.tem((select v from lista_busca), 35), 'B1 o profissional 35 aparece na busca');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 35), 'ok', 'B2 e a chamada a ele nasce');
select ok(not pg_temp.tem((select v from lista_busca), 12) and not pg_temp.tem((select v from lista_busca), 15)
          and not pg_temp.tem((select v from lista_busca), 16) and not pg_temp.tem((select v from lista_busca), 23)
          and not pg_temp.tem((select v from lista_busca), 36),
  'B3 quem a chamada recusa pela genérica ou pelo bloqueio (12, 15, 16, 23, 36) não aparece na busca');
select ok(not pg_temp.tem((select v from lista_busca), 20) and not pg_temp.tem((select v from lista_busca), 21)
          and not pg_temp.tem((select v from lista_busca), 11),
  'B4 quem a chamada recusa por agenda cheia, par em pausa ou chamada já aberta (20, 21, 11) também não aparece');

-- ══ C. perfil_publico ═════════════════════════════════════════════════════════
update privado.configuracao_app set foto_de_perfil = true;
delete from vault.secrets where name in ('storage_jwt_secret', 'ler_midia_function_url');
insert into privado.midia (id, dono_usuario_id, estabelecimento_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
values ('c8710000-0000-4000-8000-0000000000a1', pg_temp.u(37), null, 'profissional', 'foto_perfil',
        'perfil/c8710000-0000-4000-8000-0000000000a1.jpg', 'image/jpeg', 1000, 'aprovada');

select is(pg_temp.nome(pg_temp.u(1), pg_temp.p(37)), 'Prof S.',
  'C1 contratante sem candidatura, turno nem equipe: o nome vem curto');
select is(pg_temp.perfil(pg_temp.u(1), pg_temp.p(37)) -> 'reputacao', privado.reputacao_profissional(pg_temp.p(37)),
  'C1b a reputação do perfil é a do helper único (a mesma do cartão da busca, com o denominador)');
select is(pg_temp.perfil(pg_temp.u(1), pg_temp.p(37)) ->> 'apresentacao', 'Apresentação 37',
  'C2 o profissional na busca é vínculo de leitura: o perfil rico vem (apresentação)');
select ok((pg_temp.perfil(pg_temp.u(1), pg_temp.p(37)) ->> 'foto_id') = 'c8710000-0000-4000-8000-0000000000a1'
          and (pg_temp.perfil(pg_temp.u(1), pg_temp.p(37)) ->> 'foto_url') like 'http://funcoes.invalid/functions/v1/ler-midia?midia_id=%',
  'C3 a foto aprovada vem pelo vínculo da busca (0.2.90, contratante com os Termos 1.1 aceitos)');
select is(pg_temp.perfil(pg_temp.u(1), pg_temp.p(15)) ->> 'apresentacao', 'Apresentação 15',
  'C4 em pausa, o perfil rico vem do mesmo jeito (o perfil não revela a pausa)');
select is(pg_temp.nome(pg_temp.u(1), pg_temp.p(15)), 'Prof S.', 'C5 e o nome também vem curto');
select ok(not (pg_temp.perfil(pg_temp.u(1), pg_temp.p(12)) ? 'apresentacao'),
  'C6 sem "Aceito chamadas diretas" e sem vínculo, o perfil rico NÃO vem');
select is(pg_temp.nome(pg_temp.u(1), pg_temp.p(12)), 'Prof S.', 'C7 e o nome vem curto também (vale esteja ou não na busca)');
update privado.recurso set ligado = false where chave = 'busca_profissionais';
select ok(not (pg_temp.perfil(pg_temp.u(1), pg_temp.p(37)) ? 'apresentacao'),
  'C8 com busca_profissionais desligado, a busca não conta como vínculo de leitura');
update privado.recurso set ligado = true where chave = 'busca_profissionais';
select ok(not (pg_temp.perfil(pg_temp.u(1), pg_temp.p(14)) ? 'apresentacao'),
  'C9 profissional de demonstração na busca não dá perfil rico a contratante real');
-- A casa que só chamou (11 e 35 têm chamada da casa 1, sem candidatura, turno nem equipe): nome curto.
select is(pg_temp.nome(pg_temp.u(1), pg_temp.p(11)), 'Maria L.',
  'C10 a casa que só chamou o profissional lê o nome curto (hoje lê o nome inteiro)');
-- Com vínculo de trabalho, o nome inteiro, como sempre veio.
select is(pg_temp.nome(pg_temp.u(1), pg_temp.p(19)), 'Pedro Alves Pinto', 'C11 equipe de confiança: nome inteiro');
select is(pg_temp.nome(pg_temp.u(1), pg_temp.p(25)), 'Carla Mendes Rocha', 'C12 candidatura em vaga da casa: nome inteiro');
select is(pg_temp.nome(pg_temp.u(1), pg_temp.p(26)), 'Rui Barbosa Neto', 'C13 turno com a casa: nome inteiro');
select is(pg_temp.nome(pg_temp.u(2), pg_temp.p(26)), 'Rui B.', 'C14 outra casa, sem vínculo com ele: nome curto, sem o sufixo Neto (o vínculo é da casa)');
-- Quem não é contratante lê como sempre leu.
select is(pg_temp.nome(pg_temp.u(12), pg_temp.p(11)), 'Maria L.', 'C15 outro PROFISSIONAL lê o nome curto (nome inteiro só para o próprio e para contratante com vínculo)');
select is(pg_temp.nome(pg_temp.u(4), pg_temp.p(11)), 'Maria L.', 'C15b contratante sem estabelecimento lê o nome curto');
select is(pg_temp.nome(pg_temp.u(11), pg_temp.p(11)), 'Maria Souza Lima', 'C16 o próprio profissional lê o nome inteiro');
-- Controle da foto: com equipe de confiança, a foto vem também (o vínculo da 0.2.54, que segue valendo).
insert into public.equipe_confianca (estabelecimento_id, profissional_id) values (pg_temp.casa(1), pg_temp.p(37));
select is(pg_temp.perfil(pg_temp.u(1), pg_temp.p(37)) ->> 'foto_id', 'c8710000-0000-4000-8000-0000000000a1',
  'C17 controle: com equipe de confiança a foto vem igual (o vínculo antigo segue valendo)');
select is(pg_temp.nome(pg_temp.u(1), pg_temp.p(37)), 'Prof 37 Sobrenome', 'C18 e o nome passa a vir inteiro');
delete from public.equipe_confianca where profissional_id = pg_temp.p(37);
-- m2: a busca não dá perfil rico a profissional que não está ativo (suspenso).
select is(pg_temp.perfil(pg_temp.u(1), pg_temp.p(40)) ->> 'apresentacao', 'Apresentação 40',
  'C19 controle: profissional ativo na busca: o perfil rico vem');
update public.usuario set estado = 'suspensa' where id = pg_temp.u(40);
select ok(not (pg_temp.perfil(pg_temp.u(1), pg_temp.p(40)) ? 'apresentacao'),
  'C20 profissional suspenso na busca: o perfil rico NÃO vem');

-- ══ D. O nome curto em cada leitora de PerfilPublico ═════════════════════════
-- D1 minhas_chamadas (ChamadaResumo.outra_parte)
create temp table minhas as select pg_temp.como(pg_temp.u(1), $$select public.minhas_chamadas()$$) as j;
select is((select i -> 'outra_parte' ->> 'nome' from minhas, jsonb_array_elements(j -> 'itens') i
            where i ->> 'profissional_id' = pg_temp.p(11)::text), 'Maria L.',
  'D1 minhas_chamadas: outra_parte.nome curto para a casa que só chamou');
select is((select i -> 'outra_parte' ->> 'nome' from minhas, jsonb_array_elements(j -> 'itens') i
            where i ->> 'profissional_id' = pg_temp.p(19)::text), 'Pedro Alves Pinto',
  'D2 minhas_chamadas: outra_parte.nome inteiro quando há equipe de confiança');
-- D3 detalhe_chamada
select is(pg_temp.como(pg_temp.u(1), format($$select public.detalhe_chamada(%L::uuid)$$,
            (select c.id from public.chamada c where c.profissional_id = pg_temp.p(11)))) -> 'outra_parte' ->> 'nome', 'Maria L.',
  'D3 detalhe_chamada: outra_parte.nome curto para a casa que só chamou');
select is(pg_temp.como(pg_temp.u(1), format($$select public.detalhe_chamada(%L::uuid)$$,
            (select c.id from public.chamada c where c.profissional_id = pg_temp.p(19)))) -> 'outra_parte' ->> 'nome', 'Pedro Alves Pinto',
  'D4 detalhe_chamada: nome inteiro com equipe de confiança');
select ok(not (pg_temp.como(pg_temp.u(1), format($$select public.detalhe_chamada(%L::uuid)$$,
            (select c.id from public.chamada c where c.profissional_id = pg_temp.p(11)))) -> 'outra_parte' ? 'foto_id'),
  'D5 detalhe_chamada: a outra parte da busca sem foto');
-- D6 candidatos_da_vaga: candidatura é vínculo, o nome vem inteiro
select is(pg_temp.como(pg_temp.u(1), format($$select public.candidatos_da_vaga(%L::uuid)$$,
            (select id from public.vaga where local = 'CLN 871 vaga'))) -> 0 -> 'profissional' ->> 'nome', 'Carla Mendes Rocha',
  'D6 candidatos_da_vaga: o candidato vem com o nome inteiro');
-- D7 a leitura da casa que NÃO chamou nem tem vínculo (casa 2) traz o nome curto no perfil
select is(pg_temp.nome(pg_temp.u(2), pg_temp.p(11)), 'Maria L.', 'D7 a casa que nunca chamou também lê o nome curto');
-- Só o vínculo VIGENTE na hora da leitura conta (Juiz): candidatura retirada e equipe desfeita voltam ao nome curto.
update public.candidatura set estado = 'retirada' where profissional_id = pg_temp.p(25);
select is(pg_temp.nome(pg_temp.u(1), pg_temp.p(25)), 'Carla R.', 'D10 candidatura RETIRADA não é vínculo: o nome volta a vir curto');
update public.candidatura set estado = 'pendente' where profissional_id = pg_temp.p(25);
select is(pg_temp.nome(pg_temp.u(1), pg_temp.p(25)), 'Carla Mendes Rocha', 'D11 com a candidatura vigente de novo, o nome vem inteiro');
delete from public.equipe_confianca where profissional_id = pg_temp.p(19) and estabelecimento_id = pg_temp.casa(1);
select is(pg_temp.nome(pg_temp.u(1), pg_temp.p(19)), 'Pedro P.', 'D12 equipe DESFEITA não é vínculo: o nome volta a vir curto');
insert into public.equipe_confianca (estabelecimento_id, profissional_id) values (pg_temp.casa(1), pg_temp.p(19));
select is(pg_temp.nome(pg_temp.u(1), pg_temp.p(19)), 'Pedro Alves Pinto', 'D13 com a equipe de volta, o nome vem inteiro');
-- m4 (limite conhecido): a exportação (privado.meus_dados, pela Edge Function sem JWT: auth.uid() nulo) traz a contraparte
-- dos turnos do contratante com o nome CURTO, enquanto privado.turno_em_json não passa o leitor ao nome. O ajuste vem
-- depois que o JP mesclar os PRs #513 e #516, que reescrevem turno_em_json (esta migração não a recria, para não apagar a dele).
-- Este teste trava o comportamento de hoje: quando o ajuste entrar, ele muda para o nome inteiro.
select is((select jsonb_path_query_first(privado.meus_dados(pg_temp.u(1)), '$.turnos[*] ? (@.contraparte.nome == "Rui B.")') -> 'contraparte' ->> 'nome'),
  'Rui B.', 'D14 exportação do contratante, sem sessão: a contraparte do turno sai com o nome curto (limite conhecido, m4)');
-- D8 ItemBloqueio.nome
select pg_temp.como(pg_temp.u(1), format($$select public.bloquear('profissional', %L::uuid)$$, pg_temp.p(26)));
create temp table bloqueios as select pg_temp.como(pg_temp.u(1), $$select public.listar_bloqueios()$$) as j;
select is((select i ->> 'nome' from bloqueios, jsonb_array_elements(j) i where i ->> 'alvo_id' = pg_temp.p(36)::text), 'Joana D.',
  'D8 listar_bloqueios: ItemBloqueio.nome curto para quem a casa não conhece por candidatura, turno ou equipe');
select is((select i ->> 'nome' from bloqueios, jsonb_array_elements(j) i where i ->> 'alvo_id' = pg_temp.p(26)::text), 'Rui Barbosa Neto',
  'D9 listar_bloqueios: nome inteiro de quem já trabalhou na casa (turno)');

select * from finish();
rollback;
