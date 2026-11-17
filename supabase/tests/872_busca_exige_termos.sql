-- 872_busca_exige_termos.sql
--
-- A busca só para contratante que aceitou os Termos 1.1 (migração 20261116230000; I6 do pedido
-- 2026-11-16-12 do Cauê). O aceite é public.usuario.termos_versao, a data da publicação em AAAA-MM-DD:
-- vale quem tem 2026-11-13 (Termos 1.1 + Política 1.2) ou mais; a demonstração conta como aceito.
--   A  o fato: privado.termos_minimos_da_busca(), privado.aceitou_termos (limites, formato, demonstração,
--      conta inexistente) e o privilégio (só service_role)
--   B  buscar_profissionais: recusa 403 sem_permissao termos_pendentes (versão anterior, formato fora do padrão),
--      passa com a 1.1 ou mais nova e com a demonstração; a ordem dos erros (conta e perfil antes, filtros
--      depois) e a recusa que não gasta busca
--   C  chamar_profissional pelo caminho da busca (sem vínculo): recusa sem aceite, passa com aceite, a recusa
--      não revela quem está na busca, a 2ª chamada pelo vaga_id também
--   D  o caminho do vínculo (turno cumprido, equipe de confiança) NÃO muda, mesmo sem aceite
--   E  aceitar depois destrava a busca e a chamada
--   F  censo e privilégios
--   G  aceitar_termos (grava versão e instante, idempotente, só a versão vigente) e Usuario.termos_versao
--   H  o perfil rico pela busca só para quem aceitou a 1.1
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
-- 16/11/2026, 12:00 em Brasília (segunda-feira).
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-872';
select plan(103);

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
  select ('c8720000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.p(n int) returns uuid language sql immutable as $$
  select ('c8720000-0000-4000-8000-0000000001' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.casa(n int) returns uuid language sql immutable as $$
  select ('c8720000-0000-4000-8000-00000000e0' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.garcom() returns uuid language sql stable as $$ select id from public.funcao where nome = 'garçom' $$;

-- chamar_profissional como a conta, para o profissional n, em casa. Corpo válido.
-- 0.2.95: sem inicio, cada profissional vai a um minuto próprio a partir de 17/11 18:00, um trabalho próprio
-- (no mesmo minuto, a chamada a outra pessoa receberia trabalho_ja_aberto, que vem antes das outras recusas).
create function pg_temp.inicio_padrao(prof int) returns timestamptz language sql stable as $$
  select '2026-11-17 18:00+00'::timestamptz + prof * interval '1 minute' $$;
create function pg_temp.chamar(conta uuid, casa uuid, prof int, regiao text default 'Plano Piloto',
                               inicio text default null) returns text
language sql as $$
  select pg_temp.tenta(conta, format($a$ select public.chamar_profissional(chave => gen_random_uuid(),
    profissional_id => %L, estabelecimento_id => %L, funcao_id => %L, inicio_em => %L, fim_em => %L,
    local => 'CLN 201', regiao_administrativa => %L, ponto => '{"latitude":-15.7942,"longitude":-47.8822}',
    valor_centavos => 15000, inclui_refeicao => true, inclui_transporte => false,
    exige_material_proprio => false, responsavel_local => 'Maitre') $a$,
    pg_temp.p(prof), casa, pg_temp.garcom(), coalesce(inicio::timestamptz, pg_temp.inicio_padrao(prof)),
    coalesce(inicio::timestamptz, pg_temp.inicio_padrao(prof)) + interval '5 hours', regiao)) $$;
-- A 2ª ou 3ª chamada pela vaga direta.
create function pg_temp.chamar_vaga(conta uuid, casa uuid, prof int, vaga uuid) returns text language sql as $$
  select pg_temp.tenta(conta, format($a$ select public.chamar_profissional(chave => gen_random_uuid(),
    profissional_id => %L, estabelecimento_id => %L, vaga_id => %L) $a$, pg_temp.p(prof), casa, vaga)) $$;
-- A busca da casa, com o corpo válido (serviço obrigatório e região padrão).
create function pg_temp.busca(conta uuid, casa uuid) returns text language sql as $$
  select pg_temp.tenta(conta, format(
    'select public.buscar_profissionais(estabelecimento_id => %L, funcao_id => %L, regiao_id => 1)', casa, pg_temp.garcom())) $$;
-- Um turno cumprido e verificado da casa com o profissional (o vínculo "turno").
create function pg_temp.turno(p_estab uuid, p_prof uuid, p_inicio timestamptz) returns void language plpgsql as $$
declare v_vaga uuid := gen_random_uuid(); v_pos uuid := gen_random_uuid();
begin
  insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto, valor_centavos,
                           posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo,
                           chave_cliente, publicado_em, estado)
  values (v_vaga, p_estab, pg_temp.garcom(), (select usuario_id from public.membro_estabelecimento where estabelecimento_id = p_estab limit 1),
          p_inicio, p_inicio + interval '6 hours', 'Local 872', 'POINT(-47.88 -15.78)'::extensions.geography, 15000, 1,
          true, false, false, 'Responsável 872', 'urgencia', gen_random_uuid(), p_inicio - interval '2 days', 'encerrada');
  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, falta, inicio_em, fim_em)
  values (v_pos, v_vaga, p_prof, 'cumprida', p_inicio - interval '1 day', false, p_inicio, p_inicio + interval '6 hours');
  insert into public.turno (id, posicao_id, checkin_em, checkout_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
  values (gen_random_uuid(), v_pos, p_inicio, p_inicio + interval '6 hours', 'geolocalizado', 50, 'verificado', 15000);
end $$;

-- ── Massa ─────────────────────────────────────────────────────────────────────
-- Contratantes (cada um com a sua casa, a de mesmo número):
--   1  aceitou a 1.1 (2026-11-13)        2  versão anterior (2026-11-12, Termos 1.0.1)
--   3  versão mais nova (2026-11-20)     4  formato fora do padrão ("1.0")
--   5  demonstração, 2026-09-22 (é o que a conta de demonstração tem de verdade)
--   6  versão anterior, mas suspensa     7  criada direto com 2026-11-16 (Termos 1.2), sem aceitar de novo
-- Profissionais 11 a 15 (o 17 é um profissional com versão antiga, para a ordem dos erros).
--   11 na busca, sem vínculo com nenhuma casa      12 equipe de confiança da casa 2 (sem "Aceito chamadas")
--   13 turno cumprido com a casa 2 (sem "Aceito chamadas")
--   14 demonstração, na busca                      15 sem "Aceito chamadas" e sem vínculo (fora da busca)
--   16 na busca e nunca chamado por ninguém (o perfil rico, seção H)
--   18 turno cumprido com a casa 2 (sem "Aceito chamadas"; a 2ª chamada pela vaga, D4)
-- Contas 17 (profissional sem perfil de profissional, versão antiga) e 20 (login sem conta, só para o 404).
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', pg_temp.u(n), 'authenticated', 'authenticated',
       'p' || n || '@t872.test', privado.agora(), privado.agora(), false, false
  from (select generate_series(1, 7) union all select generate_series(11, 18) union all select 20) s(n);
select pg_temp.como(pg_temp.u(n), format(
  $$ select public.criar_conta(%L, %L, %L, '1990-01-01', %L) $$,
  case when n <= 7 then 'contratante' else 'profissional' end,
  case n when 11 then 'Maria Souza Lima' else 'Conta ' || n || ' Sobrenome' end,
  '+55619555872' || lpad(n::text, 2, '0'),
  case n when 1 then '2026-11-13' when 7 then '2026-11-16' when 2 then '2026-11-12' when 3 then '2026-11-20' when 4 then '1.0'
         when 5 then '2026-09-22' when 6 then '2026-11-12' else '2026-09-22' end))
  from (select generate_series(1, 7) union all select generate_series(11, 18) union all select 20) s(n)
 where n <> 20;
update public.usuario set demonstracao = true where id in (pg_temp.u(5), pg_temp.u(14));
update public.usuario set estado = 'suspensa' where id = pg_temp.u(6);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
select pg_temp.casa(n), 'Casa 872 ' || n, '8721234500' || lpad(n::text, 2, '0') || '69', 'food_service', 'CLN 20' || n,
       'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'
  from generate_series(1, 7) n;
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select pg_temp.u(n), pg_temp.casa(n), 'administrador' from generate_series(1, 7) n;

insert into public.profissional (id, usuario_id, ponto_base, apresentacao)
select pg_temp.p(n), pg_temp.u(n), 'POINT(-47.8822 -15.7852)'::extensions.geography, 'Apresentação ' || n
  from generate_series(11, 18) n where n <> 17;
insert into public.profissional_funcao (profissional_id, funcao_id)
select pg_temp.p(n), pg_temp.garcom() from generate_series(11, 18) n where n <> 17;
insert into public.profissional_servico (profissional_id, funcao_id, unidade, valor_centavos)
select pg_temp.p(n), pg_temp.garcom(), 'hora', 5000 from generate_series(11, 18) n where n <> 17;
insert into public.profissional_regiao (profissional_id, regiao_id)
select pg_temp.p(n), 1 from generate_series(11, 18) n where n <> 17;
-- Aparelho na versão mínima da chamada direta para todos.
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select pg_temp.u(n), 'tok-872-' || n || '-000000000000000000', 'ios', '1.2.0' from generate_series(11, 18) n where n <> 17;
-- "Aceito chamadas diretas": 11 e 14 (na busca). 12, 13 e 15 só têm a linha padrão (desligado); 12 e 13 têm vínculo.
insert into public.profissional_preferencia_chamada (profissional_id, aceita_chamadas, aceita_chamadas_em, versao_texto_busca)
select pg_temp.p(n), true, privado.agora(), 'busca-v1' from generate_series(11, 18) n where n in (11, 14, 16);
insert into public.profissional_preferencia_chamada (profissional_id) values (pg_temp.p(12)), (pg_temp.p(13)), (pg_temp.p(15)), (pg_temp.p(18));
-- Vínculos com a casa 2: 12 equipe de confiança; 13 turno cumprido e verificado.
insert into public.equipe_confianca (estabelecimento_id, profissional_id) values (pg_temp.casa(2), pg_temp.p(12));
select pg_temp.turno(pg_temp.casa(2), pg_temp.p(13), '2026-11-01 10:00-03');
select pg_temp.turno(pg_temp.casa(2), pg_temp.p(18), '2026-11-02 10:00-03');

update privado.recurso set ligado = true where chave in ('chamada_direta', 'busca_profissionais', 'perfil_rico');
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;

-- ══ A. O fato ═════════════════════════════════════════════════════════════════
select is(privado.termos_minimos_da_busca(), '2026-11-13',
  'A1 a versão mínima da busca é a de 13/11/2026 (Termos 1.1 + Política 1.2)');
select ok(privado.aceitou_termos(pg_temp.u(1), '2026-11-13'), 'A2 termos_versao igual à mínima: aceitou');
select ok(privado.aceitou_termos(pg_temp.u(3), '2026-11-13'), 'A3 termos_versao mais nova que a mínima: aceitou');
select ok(not privado.aceitou_termos(pg_temp.u(2), '2026-11-13'), 'A4 um dia antes da mínima (2026-11-12): não aceitou');
select ok(not privado.aceitou_termos(pg_temp.u(4), '2026-11-13'), 'A5 "1.0", fora do formato de data: não aceitou');
select ok(privado.aceitou_termos(pg_temp.u(7), '2026-11-13'), 'A5b conta criada com 2026-11-16 (Termos 1.2): conta como aceite da mínima 2026-11-13, sem aceitar de novo');
select ok(not privado.aceitou_termos(pg_temp.u(17), '2026-11-13'), 'A5c conta antiga (2026-09-22, de antes da 1.1): não aceitou');
select ok(privado.aceitou_termos(pg_temp.u(5), '2026-11-13'), 'A6 a conta de demonstração conta como aceito (login da revisão da Apple)');
select ok(not privado.aceitou_termos(gen_random_uuid(), '2026-11-13'), 'A7 conta inexistente: não aceitou');
select ok(not has_function_privilege('authenticated', 'privado.aceitou_termos(uuid, text)', 'execute')
          and not has_function_privilege('anon', 'privado.aceitou_termos(uuid, text)', 'execute'),
  'A8 o helper não é executável por anon nem por authenticated');
select is(privado.termos_publicadas(), array['2026-11-13', '2026-11-16'], 'A10 as versões publicadas que aceitar_termos aceita: 2026-11-13 e 2026-11-16 (a mínima da busca segue 2026-11-13, A1)');
select ok(not has_function_privilege('authenticated', 'privado.termos_publicadas()', 'execute'),
  'A11 a lista de publicadas não é executável por authenticated');
select ok(not has_function_privilege('authenticated', 'privado.termos_minimos_da_busca()', 'execute'),
  'A9 a versão mínima não é executável por authenticated');

-- ══ B. buscar_profissionais ═══════════════════════════════════════════════════
select is(pg_temp.busca(pg_temp.u(1), pg_temp.casa(1)), 'ok', 'B1 aceitou a 1.1 (2026-11-13): a busca responde');
select is(pg_temp.busca(pg_temp.u(3), pg_temp.casa(3)), 'ok', 'B2 aceitou uma versão mais nova: a busca responde');
select is(pg_temp.busca(pg_temp.u(2), pg_temp.casa(2)), '403 sem_permissao termos_pendentes',
  'B3 aceitou só uma versão anterior (2026-11-12): 403 sem_permissao, termos_pendentes');
select is(pg_temp.busca(pg_temp.u(4), pg_temp.casa(4)), '403 sem_permissao termos_pendentes',
  'B4 termos_versao fora do formato de data: a mesma recusa');
select is(pg_temp.busca(pg_temp.u(7), pg_temp.casa(7)), 'ok', 'B4b conta criada com 2026-11-16 busca sem aceitar de novo');
select is(pg_temp.busca(pg_temp.u(5), pg_temp.casa(5)), 'ok', 'B5 a demonstração (2026-09-22) segue buscando');
-- A ordem dos erros: conta e perfil antes da trava; a trava antes de qualquer filtro.
select is(pg_temp.busca(pg_temp.u(17), pg_temp.casa(1)), '403 sem_permissao',
  'B6 profissional com versão antiga: a recusa de perfil (sem termos_pendentes) vem antes da trava');
select is(pg_temp.busca(pg_temp.u(6), pg_temp.casa(6)), '403 sem_permissao conta_suspensa',
  'B7 conta suspensa com versão antiga: conta_suspensa vem antes da trava');
select is(pg_temp.tenta(pg_temp.u(2), 'select public.buscar_profissionais()'), '403 sem_permissao termos_pendentes',
  'B8 sem aceite e sem nenhum filtro: termos_pendentes, e não o 422 de campo obrigatório');
select is(pg_temp.tenta(pg_temp.u(1), 'select public.buscar_profissionais()'), '422 campo_obrigatorio estabelecimento_id',
  'B9 com aceite e sem filtro: o 422 de sempre (a trava não mudou a ordem dos filtros)');
select is(pg_temp.tenta(pg_temp.u(2), format('select public.buscar_profissionais(estabelecimento_id => %L, funcao_id => %L, regiao_id => 99999)',
                         pg_temp.casa(2), pg_temp.garcom())), '403 sem_permissao termos_pendentes',
  'B10 sem aceite e com região inválida: termos_pendentes antes do 422 do filtro');
select is(pg_temp.tenta(pg_temp.u(2), format('select public.buscar_profissionais(estabelecimento_id => %L, funcao_id => %L, regiao_id => 1)',
                         pg_temp.casa(1), pg_temp.garcom())), '403 sem_permissao termos_pendentes',
  'B11 sem aceite e com a casa de outra pessoa: termos_pendentes (a trava é sobre quem busca)');
select is((select coalesce(sum(total), 0)::int from privado.contador_busca where usuario_id in (pg_temp.u(2), pg_temp.u(4))), 0,
  'B12 a recusa por termos não gasta busca do limite por hora');
select is((select coalesce(sum(total), 0)::int from privado.contador_busca where usuario_id = pg_temp.u(1)), 1,
  'B13 e a busca de quem aceitou conta (só a B1: a B9 recusou o filtro antes do contador)');

select is((select count(*)::int from generate_series(1, 61) g
            where pg_temp.busca(pg_temp.u(2), pg_temp.casa(2)) = '403 sem_permissao termos_pendentes'), 61,
  'B14 61 recusas por termos seguidas: todas termos_pendentes, nenhuma vira 429 (a recusa não gasta o limite de 60 por hora)');
select is((select coalesce(sum(total), 0)::int from privado.contador_busca where usuario_id = pg_temp.u(2)), 0,
  'B15 e o contador de quem não aceitou segue zerado');

-- ══ C. chamar_profissional pela busca (sem vínculo) ═══════════════════════════
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 11), 'ok',
  'C1 aceitou a 1.1, profissional na busca, sem vínculo: a chamada nasce');
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 11), '403 sem_permissao termos_pendentes',
  'C2 versão anterior, profissional na busca, sem vínculo: 403 sem_permissao, termos_pendentes');
select is(pg_temp.chamar(pg_temp.u(4), pg_temp.casa(4), 11), '403 sem_permissao termos_pendentes',
  'C3 termos_versao fora do formato: a mesma recusa');
select is((select count(*)::int from public.chamada where profissional_id = pg_temp.p(11) and estabelecimento_id in (pg_temp.casa(2), pg_temp.casa(4))), 0,
  'C4 nenhuma das recusas criou chamada');
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 15), '403 sem_permissao termos_pendentes',
  'C5 profissional FORA da busca e sem vínculo, sem aceite: a mesma recusa (não revela quem está na busca)');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 15), '422 profissional_indisponivel nao_aceita_chamadas',
  'C6 com aceite, o profissional fora da busca segue com a recusa genérica de sempre');
select is(pg_temp.chamar(pg_temp.u(3), pg_temp.casa(3), 11), 'ok',
  'C7 aceitou uma versão mais nova: a chamada nasce');
select is(pg_temp.chamar(pg_temp.u(7), pg_temp.casa(7), 11), 'ok',
  'C7b conta criada com 2026-11-16: a chamada pela busca nasce sem aceitar de novo');
select is(pg_temp.chamar(pg_temp.u(5), pg_temp.casa(5), 14), 'ok',
  'C8 demonstração (2026-09-22) com profissional de demonstração: segue chamando');
-- A 2ª chamada pela vaga direta (a vaga nasceu da chamada C1) também é pelo caminho da busca.
select is(pg_temp.chamar_vaga(pg_temp.u(1), pg_temp.casa(1), 14, (select c.vaga_id from public.chamada c where c.profissional_id = pg_temp.p(11)
                                                                    and c.estabelecimento_id = pg_temp.casa(1))), '422 profissional_indisponivel nao_aceita_chamadas',
  'C9 com aceite, a 2ª chamada pela vaga: o profissional de demonstração não serve a conta real (M5, como antes)');
select is(pg_temp.tenta(pg_temp.u(2), format($a$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
    estabelecimento_id => %L, vaga_id => %L) $a$, pg_temp.p(11), pg_temp.casa(2),
    (select c.vaga_id from public.chamada c where c.profissional_id = pg_temp.p(11) and c.estabelecimento_id = pg_temp.casa(1)))),
  '403 sem_permissao termos_pendentes',
  'C10 versão anterior, 2ª chamada pelo vaga_id para quem está só na busca: termos_pendentes (antes de olhar a vaga)');
select is(pg_temp.chamar(pg_temp.u(6), pg_temp.casa(6), 11), '403 sem_permissao conta_suspensa',
  'C11 conta suspensa com versão antiga: conta_suspensa vem antes da trava');

-- Busca desligada: termos_pendentes nunca sai; a recusa é a genérica de sempre.
update privado.recurso set ligado = false where chave = 'busca_profissionais';
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 11), '422 profissional_indisponivel nao_aceita_chamadas',
  'C12 com a busca desligada, quem não aceitou e não tem vínculo recebe a genérica (termos_pendentes não sai)');
update privado.recurso set ligado = true where chave = 'busca_profissionais';
-- O bloqueio (404) vem antes da trava dos Termos; profissional que não existe também.
select is(pg_temp.tenta(pg_temp.u(2), format($a$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
    estabelecimento_id => %L) $a$, gen_random_uuid(), pg_temp.casa(2))), '404 nao_encontrado',
  'C13 profissional inexistente, sem aceite: o 404 vem antes de termos_pendentes');

-- ══ D. O caminho do vínculo NÃO muda ══════════════════════════════════════════
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 12), 'ok',
  'D1 sem aceite, profissional da equipe de confiança da casa (sem "Aceito chamadas"): a chamada nasce, como antes');
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 13, 'Plano Piloto', '2026-11-18 18:00+00'), 'ok',
  'D2 sem aceite, profissional com turno cumprido na casa: a chamada nasce, como antes');
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 12), '409 chamada_ja_aberta',
  'D3 e as regras de sempre seguem pelo vínculo (a chamada aberta repetida dá o 409)');
select is(pg_temp.chamar_vaga(pg_temp.u(2), pg_temp.casa(2), 18, (select c.vaga_id from public.chamada c where c.profissional_id = pg_temp.p(12))), 'ok',
  'D4 sem aceite, a 2ª chamada pela vaga para quem tem vínculo: nasce');
select is(pg_temp.chamar(pg_temp.u(4), pg_temp.casa(4), 12), '403 sem_permissao termos_pendentes',
  'D5 o vínculo é com A CASA: sem aceite, quem não tem vínculo com a casa 4 (só com a 2) é recusado');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 12), '422 profissional_indisponivel nao_aceita_chamadas',
  'D6 com aceite e sem vínculo com a casa 1, quem não está na busca segue com a genérica de sempre');

-- ══ G. aceitar_termos e Usuario.termos_versao ════════════════════════════════
-- Conta 4: "1.0" no cadastro. O instante do aceite antigo é recuado para provar que o servidor carimba de novo.
update public.usuario set termos_aceite_em = '2026-10-01 10:00+00' where id = pg_temp.u(4);
update privado.termos_aceite set aceito_em = '2026-10-01 10:00+00' where usuario_id = pg_temp.u(4) and versao = '1.0';
select is(pg_temp.como(pg_temp.u(4), 'select public.minha_conta()') ->> 'termos_versao', '1.0',
  'G1 minha_conta devolve termos_versao (a última aceita, no cadastro)');
select ok(not (pg_temp.como(pg_temp.u(4), 'select public.minha_conta()') ? 'termos_aceite_em'),
  'G2 o instante do aceite não sai em Usuario (só a versão)');
create temp table aceite_u4 as
  select pg_temp.como(pg_temp.u(4), $$ select public.aceitar_termos('2026-11-13') $$) as r;
select is((select r ->> 'termos_versao' from aceite_u4), '2026-11-13', 'G3 aceitar_termos devolve a versão aceita');
select is((select (r ->> 'aceito_em')::timestamptz from aceite_u4), '2026-11-16 15:00:00+00'::timestamptz,
  'G4 e o instante do servidor (frila.agora), não o de antes nem um do cliente');
select is((select termos_versao || ' ' || termos_aceite_em::text from public.usuario where id = pg_temp.u(4)),
  '2026-11-13 2026-11-16 15:00:00+00', 'G5 grava no mesmo lugar do cadastro: usuario.termos_versao e termos_aceite_em');
select is(pg_temp.como(pg_temp.u(4), 'select public.minha_conta()') ->> 'termos_versao', '2026-11-13',
  'G6 minha_conta passa a devolver a versão nova');
-- Reenvio: mesma versão, relógio andou; nada é regravado e a resposta é o aceite que já existe.
select set_config('frila.agora', '2026-11-16 16:30:00+00', true);
select is(pg_temp.como(pg_temp.u(4), $$ select public.aceitar_termos('2026-11-13') $$), (select r from aceite_u4),
  'G7 reenvio da mesma versão devolve o MESMO aceite (versão e instante)');
select is((select termos_aceite_em from public.usuario where id = pg_temp.u(4)), '2026-11-16 15:00:00+00'::timestamptz,
  'G8 e não carimba de novo: o instante do primeiro aceite fica');
select is(pg_temp.como(pg_temp.u(4), $$ select public.aceitar_termos('  2026-11-13  ') $$), (select r from aceite_u4),
  'G9 a versão com espaços nas pontas é a mesma (btrim, como no cadastro)');
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);
-- Só a versão vigente.
select is(pg_temp.tenta(pg_temp.u(2), $$ select public.aceitar_termos('2026-11-12') $$), '422 campo_invalido termos_versao',
  'G10 versão anterior à vigente: 422 campo_invalido (termos_versao)');
select is(pg_temp.tenta(pg_temp.u(2), $$ select public.aceitar_termos('2026-11-20') $$), '422 campo_invalido termos_versao',
  'G11 versão que o servidor não conhece (mais nova que a vigente): a mesma recusa');
select is(pg_temp.tenta(pg_temp.u(2), $$ select public.aceitar_termos('1.1') $$), '422 campo_invalido termos_versao',
  'G12 texto que não é a versão vigente: a mesma recusa');
select is((select termos_versao from public.usuario where id = pg_temp.u(2)), '2026-11-12',
  'G13 nenhuma recusa gravou nada');
select is(pg_temp.tenta(pg_temp.u(2), $$ select public.aceitar_termos('') $$), '422 campo_obrigatorio termos_versao',
  'G14 versão vazia: 422 campo_obrigatorio (termos_versao)');
select is(pg_temp.tenta(pg_temp.u(2), $$ select public.aceitar_termos() $$), '422 campo_obrigatorio termos_versao',
  'G15 sem a versão: a mesma recusa');
select is(pg_temp.tenta(pg_temp.u(3), $$ select public.aceitar_termos('2026-11-13') $$), '422 campo_invalido termos_versao',
  'G16 o aceite não volta atrás: quem já aceitou 2026-11-20 não troca por 2026-11-13');
select is(pg_temp.tenta(pg_temp.u(3), $$ select public.aceitar_termos('2026-11-16') $$), '422 campo_invalido termos_versao',
  'G16b nem por 2026-11-16 (mais antiga que a já aceita)');
select is((select termos_versao from public.usuario where id = pg_temp.u(3)), '2026-11-20', 'G17 e a versão mais nova fica');
-- A versão 2026-11-16 (Termos 1.2) também está publicada: grava, e quem a aceitou busca (a mínima segue 2026-11-13).
select is(pg_temp.como(pg_temp.u(1), $$ select public.aceitar_termos('2026-11-16') $$) ->> 'termos_versao', '2026-11-16',
  'G16c a conta 1 aceita a versão publicada 2026-11-16: grava e devolve a versão');
select is((select termos_versao || ' ' || termos_aceite_em::text from public.usuario where id = pg_temp.u(1)), '2026-11-16 2026-11-16 15:00:00+00',
  'G16d usuario guarda o último aceite, com o instante do servidor');
select is((select string_agg(versao, ',' order by versao) from privado.termos_aceite where usuario_id = pg_temp.u(1)), '2026-11-13,2026-11-16',
  'G16e e o histórico guarda as duas: o aceite da 1.1 do cadastro continua lá');
select is(pg_temp.busca(pg_temp.u(1), pg_temp.casa(1)), 'ok', 'G16f quem aceitou 2026-11-16 (acima da mínima 2026-11-13) busca');
select is(pg_temp.tenta(pg_temp.u(1), $$ select public.aceitar_termos('2026-11-13') $$), '422 campo_invalido termos_versao',
  'G16g depois da 2026-11-16, voltar para a 2026-11-13 é recusado (o aceite não volta atrás)');
-- Quem pode.
select is(pg_temp.tenta(null, $$ select public.aceitar_termos('2026-11-13') $$), '401 nao_autenticado', 'G18 sem sessão: 401');
select is(pg_temp.tenta(pg_temp.u(20), $$ select public.aceitar_termos('2026-11-13') $$), '404 nao_encontrado',
  'G19 login sem conta criada: 404 nao_encontrado');
select is(pg_temp.tenta(pg_temp.u(6), $$ select public.aceitar_termos('2026-11-13') $$), 'ok',
  'G20 conta suspensa também aceita (o contrato não promete 403 aqui); a busca segue barrando a suspensa');
select is(pg_temp.busca(pg_temp.u(6), pg_temp.casa(6)), '403 sem_permissao conta_suspensa',
  'G20b e, já com a 1.1 aceita, a suspensa segue recusada pela busca (conta_suspensa)');
select is(pg_temp.tenta(pg_temp.u(17), $$ select public.aceitar_termos('2026-11-13') $$), 'ok',
  'G21 profissional também aceita (o aceite é da conta, não do perfil)');
select is(pg_temp.tenta(pg_temp.u(5), $$ select public.aceitar_termos('2026-11-13') $$), 'ok',
  'G22 a demonstração também aceita');
select ok(has_function_privilege('authenticated', 'public.aceitar_termos(text)', 'execute')
          and not has_function_privilege('anon', 'public.aceitar_termos(text)', 'execute'),
  'G23 aceitar_termos: authenticated executa, anon não');
-- Depois de aceitar a 1.1, a busca e a chamada passam (a conta 4 estava recusada em B4 e C3).
select is(pg_temp.busca(pg_temp.u(4), pg_temp.casa(4)), 'ok', 'G24 depois de aceitar a 1.1, a busca passa');
select is(pg_temp.chamar(pg_temp.u(4), pg_temp.casa(4), 11), 'ok', 'G25 e a chamada pela busca nasce');

-- ══ H. O perfil rico pela busca só para quem aceitou a 1.1 ════════════════════
select is(pg_temp.como(pg_temp.u(1), format('select public.perfil_publico(%L::uuid)', pg_temp.p(16))) ->> 'apresentacao', 'Apresentação 16',
  'H1 quem aceitou a 1.1 lê o perfil rico de quem está na busca');
select ok(not (pg_temp.como(pg_temp.u(2), format('select public.perfil_publico(%L::uuid)', pg_temp.p(16))) ? 'apresentacao'),
  'H2 quem não aceitou (versão anterior) NÃO lê: a busca não conta como vínculo de leitura');
select is(pg_temp.como(pg_temp.u(2), format('select public.perfil_publico(%L::uuid)', pg_temp.p(16))) ->> 'nome', 'Conta S.',
  'H3 e o nome vem curto, como para qualquer leitor sem vínculo');
select is(pg_temp.como(pg_temp.u(2), format('select public.perfil_publico(%L::uuid)', pg_temp.p(12))) ->> 'apresentacao', 'Apresentação 12',
  'H4 o vínculo de trabalho (equipe de confiança) segue dando o perfil rico, sem aceite');

-- ══ M. O histórico dos aceites (privado.termos_aceite) ═══════════════════════
-- (a) chave única (conta, versão).
select throws_ok(format($$ insert into privado.termos_aceite (usuario_id, versao, aceito_em) values (%L, '2026-11-13', now()) $$, pg_temp.u(4)),
  '23505', null, 'M1 a chave é única por conta e versão: o mesmo aceite não entra duas vezes');
-- (b) aceitar a 1.1 não sobrescreve o aceite do cadastro sem guardá-lo: os dois ficam consultáveis.
select is((select string_agg(versao, ',' order by versao) from privado.termos_aceite where usuario_id = pg_temp.u(4)), '1.0,2026-11-13',
  'M2 a conta 4 aceitou "1.0" no cadastro e a 1.1 depois: as duas versões estão no histórico');
select is((select aceito_em from privado.termos_aceite where usuario_id = pg_temp.u(4) and versao = '1.0'), '2026-10-01 10:00+00'::timestamptz,
  'M3 o aceite do cadastro segue com o instante que tinha (não foi regravado pela 1.1)');
select is((select aceito_em from privado.termos_aceite where usuario_id = pg_temp.u(4) and versao = '2026-11-13'), '2026-11-16 15:00+00'::timestamptz,
  'M4 e o da 1.1 tem o instante do servidor');
select is((select count(*)::int from privado.termos_aceite where usuario_id = pg_temp.u(3)), 1,
  'M5 o cadastro grava o primeiro aceite no histórico (a conta 3 só tem o do cadastro)');
select is((select count(*)::int from privado.termos_aceite where usuario_id = pg_temp.u(17)), 2,
  'M6 o reenvio não duplica: a conta 17 tem o cadastro e a 1.1, e só');
select ok(not has_table_privilege('authenticated', 'privado.termos_aceite', 'select') and not has_table_privilege('anon', 'privado.termos_aceite', 'select'),
  'M7 o histórico não é legível por authenticated nem por anon');
-- (c) fora da anonimização e da limpeza dos 15 dias.
select privado.excluir_conta(pg_temp.u(17));
select is((select estado::text from public.usuario where id = pg_temp.u(17)), 'anonimizada', 'M8 a conta 17 foi anonimizada');
update public.usuario set anonimizado_em = privado.agora() - interval '16 days' where id = pg_temp.u(17);
select privado.limpar_contas_anonimizadas(15);
select is((select count(*)::int from privado.termos_aceite where usuario_id = pg_temp.u(17)), 2,
  'M9 depois da anonimização e da limpeza de 15 dias, as linhas de aceite continuam');
select is((select termos_versao from public.usuario where id = pg_temp.u(17)), '2026-11-13',
  'M10 e o último aceite segue em usuario (a anonimização não o toca)');
-- (d) a versão do aceite não fica em branco (termos_aceite_versao_check): sem a restrição, este insert passaria.
select throws_ok(format($$ insert into privado.termos_aceite (usuario_id, versao, aceito_em) values (%L, '   ', now()) $$, pg_temp.u(4)),
  '23514', null, 'M11 a versão do aceite não pode ficar em branco (só espaços é recusado pela restrição da versão)');

-- ══ E. Aceitar depois destrava ════════════════════════════════════════════════
update public.usuario set termos_versao = '2026-11-13', termos_aceite_em = privado.agora() where id = pg_temp.u(2);
select is(pg_temp.busca(pg_temp.u(2), pg_temp.casa(2)), 'ok', 'E1 depois de aceitar a 1.1, a busca responde');
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 11), 'ok', 'E2 e a chamada pela busca nasce');
update public.usuario set termos_versao = '2026-11-12' where id = pg_temp.u(1);
select is(pg_temp.busca(pg_temp.u(1), pg_temp.casa(1)), '403 sem_permissao termos_pendentes',
  'E3 a regra lê o dado na hora: voltou para a versão anterior, recusa de novo');

-- Os censos não mudam: nenhuma RPC pública nova (as duas funções novas são do schema privado).
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('buscar_profissionais', 'chamar_profissional')), 2,
  'F1 as duas RPCs seguem com uma assinatura cada (create or replace, sem sobrecarga nova)');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'privado' and p.proname in ('aceitou_termos', 'termos_minimos_da_busca', 'termos_publicadas', 'registrar_aceite_termos')), 4,
  'F2 as funções novas moram no schema privado (o fato, a mínima, a lista de publicadas e o gatilho do histórico)');
select ok(has_function_privilege('authenticated', 'public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int)', 'execute')
          and not has_function_privilege('anon', 'public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int)', 'execute'),
  'F3 buscar_profissionais mantém os privilégios (authenticated sim, anon não)');
select ok(has_function_privilege('authenticated', 'public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int)', 'execute')
          and not has_function_privilege('anon', 'public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int)', 'execute'),
  'F4 chamar_profissional mantém os privilégios (authenticated sim, anon não)');

select * from finish();
rollback;
