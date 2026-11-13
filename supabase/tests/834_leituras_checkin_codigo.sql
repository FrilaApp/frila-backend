-- 834_leituras_checkin_codigo.sql
--
-- As leituras do check-in por código (contrato 0.2.68, revisto na 0.2.70; migração 20261111203000;
-- PR8 do B-CHECKIN-BACK). Cobre:
--   · RecursosDoApp: o mínimo por versão aceita checkin_por_codigo; sem linha de mínimo vem false em
--     toda versão e plataforma, mesmo com a chave ligada (FORA: o calendário da 1.2 é do JP); com a
--     chave e o mínimo, só a versão decide, até quatro partes (0.2.67); a lista de casas do piloto
--     não entra na abertura;
--   · MeusDados.checkins_por_codigo, montado pelas RPCs de verdade (fazer_checkin com sinais,
--     gerar, validar e a confirmação manual): só o turno do profissional com algum registro, as
--     tentativas em ordem, codigo_gerado_em nulo sem código em vigor, nenhuma chave fora do contrato
--     e nunca o valor do código; a casa e o profissional sem registro recebem [] (regra (d) da
--     Bússola, critério 11);
--   · o catálogo (regra (b) e critério 13): só a validação e a exportação citam confianca_baixa; quem
--     lê as duas tabelas é uma lista fechada; nenhuma view, política nem gatilho sobre elas.
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-01-11 21:30:00+00', true);
select plan(32);

-- ── 1. RecursosDoApp ──────────────────────────────────────────────────────────

insert into privado.configuracao_app (plataforma, versao_minima, versao_recomendada, url_da_loja)
values ('ios', '0.1.0', '0.1.0', 'https://apps.apple.com/app/id0000000000'),
       ('android', '0.1.0', '0.1.0', 'https://play.google.com/store/apps/details?id=br.com.frila')
on conflict (plataforma) do nothing;

create function pg_temp.r(plataforma text, versao text) returns text language sql as $$
  select public.configuracao_do_app(plataforma, versao)->'recursos'->>'checkin_por_codigo' $$;

select is((select string_agg(k, ',' order by k) from jsonb_object_keys(public.configuracao_do_app('ios')->'recursos') k),
  'chamada_direta,checkin_por_codigo,foto_de_perfil,perfil_rico',
  'RecursosDoApp tem exatamente os quatro recursos do contrato, com checkin_por_codigo (0.2.68)');
-- Desde 20261112230000 o recurso nasce como o "vale para todos": chave ligada e mínimo de 1.2.0 só no iOS.
select is(pg_temp.r('ios', '9.9'), 'true', 'como nasce (chave ligada, mínimo 1.2.0 no iOS, 20261112230000): "9.9" é true');
select is((select string_agg(plataforma::text || ':' || versao_minima, ',' order by plataforma::text)
             from privado.recurso_versao_minima where recurso = 'checkin_por_codigo'), 'ios:1.2.0',
  'a migração põe o mínimo só no iOS (1.2.0); o Android fica fora até ordem nova');

-- A mecânica da versão mínima abaixo parte do zero: sem mínimo, com a chave ligada.
delete from privado.recurso_versao_minima where recurso = 'checkin_por_codigo';
update privado.recurso set ligado = true where chave = 'checkin_por_codigo';
select ok((select bool_and(pg_temp.r(p, v) is not distinct from 'false')
             from unnest(array['ios', 'android']) p, unnest(array['1', '1.2', '99.0.0.1', null]) v),
  'chave ligada e sem mínimo: false em toda versão e plataforma (fechado por padrão, 0.2.65)');

select lives_ok($$ insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
                   values ('checkin_por_codigo', 'ios', '1.2.0') $$,
  'recurso_versao_minima_recurso aceita checkin_por_codigo');
select is((select count(*)::int from privado.recurso_estabelecimento where chave = 'checkin_por_codigo'), 0,
  'premissa: nenhuma casa na lista por casa (que não é mais lida, 20261112230000)');
select is(pg_temp.r('ios', '1.2'), 'true',
  'com a chave e o mínimo "1.2.0", "1.2" alcança: true, sem depender da lista de casas (que vale por turno)');
select is(pg_temp.r('ios', '1.1.9'), 'false', 'abaixo do mínimo: false');
select is(pg_temp.r('ios', '1.2.0.1'), 'true', 'até quatro partes (0.2.67): "1.2.0.1" alcança "1.2.0"');
select is(pg_temp.r('ios', null), 'false', 'sem versao_app (o app 1.0 e o 1.1): false');
select is(pg_temp.r('android', '1.2'), 'false', 'mínimo só no iOS: no Android, false');

update privado.recurso set ligado = false where chave = 'checkin_por_codigo';
select is(pg_temp.r('ios', '1.2'), 'false', 'chave desligada, com o mínimo: false');

-- ── 2. A massa da exportação ──────────────────────────────────────────────────
-- A casa 834 (dono) e três profissionais: Ana tem cinco turnos, um por noite (RN21); Bia, um; Caio,
-- nenhum registro do código. Tudo pelas RPCs, com a chave ligada para a casa.

create temp table ids as
select 'c8340000-0000-4000-8000-000000000001'::uuid as dono,
       'c8340000-0000-4000-8000-000000000021'::uuid as casa,
       'c8340000-0000-4000-8000-000000000011'::uuid as ana,
       'c8340000-0000-4000-8000-000000000012'::uuid as bia,
       'c8340000-0000-4000-8000-000000000013'::uuid as caio;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select u, pf::public.perfil_conta, 'Conta 834 ' || n, '+55619999983' || n, 'conta834-' || n || '@test.invalid',
       '1990-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids, lateral (values (dono, 'contratante', '01'), (ana, 'profissional', '11'),
                            (bia, 'profissional', '12'), (caio, 'profissional', '13')) v (u, pf, n);
insert into public.profissional (id, usuario_id, ponto_base)
select gen_random_uuid(), u, 'POINT(-47.8800 -15.7700)' from ids, lateral (values (ana), (bia), (caio)) v (u);
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select casa, 'Bar 834', '80000000000834', 'food_service'::public.tipo_estabelecimento, 'Endereço de teste',
       'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select dono, casa, 'administrador'::public.papel_membro from ids;

update privado.recurso set ligado = true where chave = 'checkin_por_codigo';

-- Um turno confirmado, das 21h às 2h, para o profissional da conta dada.
create temp table turnos (nome text primary key, turno uuid, inicio timestamptz);
create function pg_temp.novo(nome text, conta uuid, inicio timestamptz) returns uuid
language plpgsql as $$
declare
  v_prof uuid := (select p.id from public.profissional p where p.usuario_id = conta);
  v_vaga uuid := gen_random_uuid(); v_pos uuid := gen_random_uuid(); v_t uuid := gen_random_uuid();
begin
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por)
  values (v_vaga, 'c8340000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
          inicio, inicio + interval '5 hours', 'Local 834', 'POINT(-47.8800 -15.7700)',
          15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada', inicio - interval '33 hours',
          gen_random_uuid(), 'c8340000-0000-4000-8000-000000000001');
  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_pos, v_vaga, 'confirmada', v_prof, inicio - interval '32 hours', inicio, inicio + interval '5 hours');
  insert into public.turno (id, posicao_id, valor_acordado_centavos) values (v_t, v_pos, 15000);
  insert into turnos values (nome, v_t, inicio);
  return v_t;
end $$;

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
create function pg_temp.t(nome text) returns uuid language sql as $$ select turno from turnos where turnos.nome = t.nome $$;
-- Põe o relógio no instante dado da noite do turno (21:30 + segundos).
create function pg_temp.na_noite(nome text, segundos integer default 0) returns void language sql as $$
  select set_config('frila.agora', ((select inicio from turnos where turnos.nome = na_noite.nome)
                                    + interval '30 minutes' + make_interval(secs => segundos))::text, true)
$$;
create function pg_temp.checkin(conta uuid, nome text, distancia integer, sinais text default null) returns jsonb
language sql as $$
  select pg_temp.como(conta, format('select public.fazer_checkin(%L::uuid, %s, %L::timestamptz, %s)',
                                    pg_temp.t(nome), distancia, privado.agora(),
                                    coalesce(quote_literal(sinais) || '::jsonb', 'null')))
$$;
create function pg_temp.gerar(nome text) returns text language sql as $$
  select pg_temp.como('c8340000-0000-4000-8000-000000000001',
                      format('select public.gerar_codigo_checkin(%L::uuid)', pg_temp.t(nome)))->>'codigo'
$$;
create function pg_temp.cod(nome text) returns text language sql as $$
  select c.codigo from privado.checkin_codigo c where c.turno_id = pg_temp.t(nome)
$$;
create function pg_temp.errado(nome text) returns text language sql as $$
  select lpad(((pg_temp.cod(nome)::int + 1) % 1000000)::text, 6, '0')
$$;
-- O resultado resumido da validação: o status (response.status ou o do raise) e o code.
create function pg_temp.validar(conta uuid, nome text, codigo text, distancia integer) returns text
language plpgsql as $$
declare r jsonb; v_det text;
begin
  perform set_config('response.status', '', true);
  r := pg_temp.como(conta, format('select public.validar_codigo_checkin(%L::uuid, %L::text, %L::integer)',
                                  pg_temp.t(nome), codigo, distancia));
  return coalesce(nullif(current_setting('response.status', true), ''), '200') || ':' || coalesce(r->>'code', r->>'verificacao');
exception when sqlstate 'PGRST' then
  get stacked diagnostics v_det = pg_exception_detail;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return (v_det::jsonb->>'status') || ':' || (sqlerrm::jsonb->>'code');
end $$;
create function pg_temp.gerado_em(nome text) returns timestamptz language sql as $$
  select c.gerado_em from privado.checkin_codigo c where c.turno_id = pg_temp.t(nome)
$$;

select pg_temp.novo('exigido',     (select ana from ids), '2027-01-11 21:00:00+00');
select pg_temp.novo('leitura',     (select ana from ids), '2027-01-12 21:00:00+00');
select pg_temp.novo('sem_posicao', (select ana from ids), '2027-01-13 21:00:00+00');
select pg_temp.novo('so_gerado',   (select ana from ids), '2027-01-14 21:00:00+00');
select pg_temp.novo('vencido',     (select ana from ids), '2027-01-15 21:00:00+00');
select pg_temp.novo('da_bia',      (select bia from ids), '2027-01-11 21:00:00+00');

-- exigido: sinal suspeito a 40 m (codigo_exigido), e a casa confirma à mão (leitura 8).
select pg_temp.na_noite('exigido');
select pg_temp.checkin((select ana from ids), 'exigido', 40,
                       '{"localizacao_simulada": true, "precisao_m": 12, "salto_de_posicao": false}');
select pg_temp.como((select dono from ids), format('select public.confirmar_checkin_manual(%L::uuid)', pg_temp.t('exigido')));
-- leitura: errada a 150 m aos 5 s, certa a 30 m aos 10 s.
select pg_temp.na_noite('leitura');
-- Etapa 1: chegada elegível a 40 m (<= raio_proximidade_m 50 m provisório)
select pg_temp.checkin((select ana from ids), 'leitura', 40);
select pg_temp.gerar('leitura');
create temp table gerado_leitura as select pg_temp.gerado_em('leitura') as em, pg_temp.cod('leitura') as cod;
select pg_temp.na_noite('leitura', 5);
select pg_temp.validar((select ana from ids), 'leitura', pg_temp.errado('leitura'), 150);
select pg_temp.na_noite('leitura', 10);
select pg_temp.validar((select ana from ids), 'leitura', (select cod from gerado_leitura), 30);
-- sem_posicao: certa sem posição (confiança baixa).
select pg_temp.na_noite('sem_posicao');
-- Etapa 1: chegada elegível a 40 m (<= raio_proximidade_m 50 m provisório)
select pg_temp.checkin((select ana from ids), 'sem_posicao', 40);
select pg_temp.gerar('sem_posicao');
select pg_temp.validar((select ana from ids), 'sem_posicao', pg_temp.cod('sem_posicao'), null);
-- so_gerado: a casa gera e ninguém lê. O valor fica em vigor, e é fixado para a busca no texto.
select pg_temp.na_noite('so_gerado');
-- Etapa 1: chegada elegível a 40 m (<= raio_proximidade_m 50 m provisório)
select pg_temp.checkin((select ana from ids), 'so_gerado', 40);
select pg_temp.gerar('so_gerado');
-- Etapa 1: preserva o cenário de teste de turno sem codigo_exigido nem tentativas
update privado.checkin_codigo set codigo = '864209', codigo_exigido = false where turno_id = pg_temp.t('so_gerado');
-- vencido: lê o código depois da validade (301 s): conta, sem código em vigor.
select pg_temp.na_noite('vencido');
-- Etapa 1: chegada elegível a 40 m (<= raio_proximidade_m 50 m provisório)
select pg_temp.checkin((select ana from ids), 'vencido', 40);
select pg_temp.gerar('vencido');
create temp table cod_vencido as select pg_temp.cod('vencido') as cod;
select pg_temp.na_noite('vencido', 301);
select pg_temp.validar((select ana from ids), 'vencido', (select cod from cod_vencido), 40);
-- da_bia: uma errada.
select pg_temp.na_noite('da_bia');
-- Etapa 1: chegada elegível a 40 m (<= raio_proximidade_m 50 m provisório)
select pg_temp.checkin((select bia from ids), 'da_bia', 40);
select pg_temp.gerar('da_bia');
select pg_temp.validar((select bia from ids), 'da_bia', pg_temp.errado('da_bia'), 40);

-- Etapa 1: codigo_exigido é gravado true nas chegadas sob chave ligada;
-- sem_posicao falha na validação (recusada), portanto confianca_baixa permanece false.
select is((select string_agg(c.codigo_exigido::text || '/' || c.confianca_baixa::text || '/' ||
                             (select count(*) from privado.checkin_codigo_tentativa k where k.turno_id = c.turno_id),
                             ',' order by x.inicio, x.nome)
             from privado.checkin_codigo c join turnos x on x.turno = c.turno_id),
  'true/false/1,true/false/0,true/false/2,true/false/1,false/false/0,true/false/1',
  'premissa: as RPCs gravaram o caminho do código dos seis turnos (da_bia, exigido, leitura, sem_posicao, so_gerado, vencido)');

-- ── 3. MeusDados.checkins_por_codigo ──────────────────────────────────────────

create temp table exp_ana  as select privado.meus_dados((select ana from ids))->'checkins_por_codigo' as j;
create temp table exp_bia  as select privado.meus_dados((select bia from ids))->'checkins_por_codigo' as j;
create temp table exp_caio as select privado.meus_dados((select caio from ids))->'checkins_por_codigo' as j;
create temp table exp_casa as select privado.meus_dados((select dono from ids)) as j;

select is((select array_agg(x.nome order by e.ord)
             from exp_ana cross join lateral jsonb_array_elements(j) with ordinality e (v, ord)
             join turnos x on x.turno = (e.v->>'turno_id')::uuid),
  array['vencido', 'sem_posicao', 'leitura', 'exigido'],
  'Ana: só os turnos com algum registro, do mais novo ao mais velho; o só gerado não entra');
select is((select v from exp_ana, jsonb_array_elements(j) v where (v->>'turno_id')::uuid = pg_temp.t('exigido')),
  jsonb_build_object('turno_id', pg_temp.t('exigido'), 'codigo_exigido', true, 'confianca_baixa', false,
                     'tentativas', '[]'::jsonb),
  'código exigido e confirmado à mão: a marca de exigido, sem tentativas');
select is((select v->'tentativas' from exp_ana, jsonb_array_elements(j) v where (v->>'turno_id')::uuid = pg_temp.t('leitura')),
  jsonb_build_array(
    jsonb_build_object('em', '2027-01-12 21:30:05+00'::timestamptz, 'resultado', 'recusada_sem_conferir', 'faixa', 'acima_de_100_m',
                       'codigo_gerado_em', (select em from gerado_leitura)),
    jsonb_build_object('em', '2027-01-12 21:30:10+00'::timestamptz, 'resultado', 'aceita', 'faixa', 'ate_100_m',
                       'codigo_gerado_em', (select em from gerado_leitura))),
  'as tentativas em ordem, com a hora, o resultado, a faixa e a hora do código em vigor');
-- 0.2.76: tentativa sem posição é recusada_sem_conferir (422) e codigo_exigido=true; confianca_baixa permanece false
select is((select v - 'turno_id' from exp_ana, jsonb_array_elements(j) v where (v->>'turno_id')::uuid = pg_temp.t('sem_posicao')),
  jsonb_build_object('codigo_exigido', true, 'confianca_baixa', false, 'tentativas', jsonb_build_array(
    jsonb_build_object('em', '2027-01-13 21:30:00+00'::timestamptz, 'resultado', 'recusada_sem_conferir', 'faixa', 'sem_posicao',
                       'codigo_gerado_em', '2027-01-13 21:30:00+00'::timestamptz))),
  'validado sem posição: na 0.2.76 tentativa é recusada_sem_conferir, histórico preservado em MeusDados');
select is((select v->'tentativas'->0 from exp_ana, jsonb_array_elements(j) v where (v->>'turno_id')::uuid = pg_temp.t('vencido')),
  jsonb_build_object('em', '2027-01-15 21:35:01+00'::timestamptz, 'resultado', 'recusada', 'faixa', 'ate_100_m',
                     'codigo_gerado_em', null),
  'lido depois da validade: conta, com codigo_gerado_em nulo (sem código em vigor)');
select is((select string_agg(distinct k, ',' order by k) from exp_ana, jsonb_array_elements(j) v, jsonb_object_keys(v) k),
  'codigo_exigido,confianca_baixa,tentativas,turno_id',
  'cada turno traz só as quatro chaves do contrato: nem o contador, nem o bloqueio, nem o valor');
select is((select string_agg(distinct k, ',' order by k)
             from exp_ana, jsonb_array_elements(j) v, jsonb_array_elements(v->'tentativas') t, jsonb_object_keys(t) k),
  'codigo_gerado_em,em,faixa,resultado',
  'cada tentativa traz só as quatro chaves do contrato: nem os metros, nem o motivo');
select is((select c.codigo from privado.checkin_codigo c where c.turno_id = pg_temp.t('so_gerado')), '864209',
  'premissa: o turno só gerado tem o código 864209 em vigor');
select is(position('864209' in privado.meus_dados((select ana from ids))::text), 0,
  'o valor do código nunca sai na exportação (critério 11)');
select is((select array_agg(x.nome) from exp_bia cross join lateral jsonb_array_elements(j) v
             join turnos x on x.turno = (v->>'turno_id')::uuid),
  array['da_bia'], 'Bia vê só o próprio turno, e a Ana não vê o dela');
select is((select j from exp_caio), '[]'::jsonb, 'profissional sem registro do código: []');
select is((select j->'checkins_por_codigo' from exp_casa), '[]'::jsonb,
  'a exportação de quem opera a casa vem [], mesmo com os seis turnos da casa com registro (regra (d))');
select is((select jsonb_array_length(j->'turnos') from exp_casa), 6,
  'premissa: a exportação da casa enxerga os seis turnos; só o caminho do código fica de fora');

-- ── 4. O catálogo: quem lê o caminho do código (regra (b), critério 13) ───────
-- prosrc de toda função fora dos esquemas do sistema. \m e \M são as bordas de palavra do
-- Postgres: privado.checkin_codigo casa, apagar_checkin_codigo_da_conta e checkin_codigo_tentativa não.

create temp table funcoes as
select n.nspname || '.' || p.proname as f, p.prosrc
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname !~ '^pg_';

select is((select array_agg(distinct f order by f) from funcoes where prosrc ~ '\mconfianca_baixa\M'),
  array['privado.meus_dados', 'public.validar_codigo_checkin'],
  'regra (b): só a validação (que grava) e a exportação citam confianca_baixa; o expurgo apaga a linha inteira, e nada de taxa, avaliação, ordenação, despacho ou suspensão a lê');
select is((select array_agg(distinct f order by f) from funcoes where prosrc ~ '\mcheckin_codigo_tentativa\M'),
  array['privado.meus_dados', 'public.validar_codigo_checkin'],
  'as tentativas: só a validação grava e só a exportação lê');
select is((select array_agg(distinct f order by f) from funcoes where prosrc ~ '\mcheckin_codigo\M'),
  array['privado.apagar_checkin_codigo_da_conta', 'privado.apagar_codigos_checkin_vencidos', 'privado.estado_do_codigo',
        'privado.limpar_checkin_por_codigo', 'privado.meus_dados', 'privado.registrar_erro_codigo',
        'privado.resposta_do_checkin', 'public.fazer_checkin', 'public.gerar_codigo_checkin',
        'public.validar_codigo_checkin'],
  'o estado do código: a lista fechada de quem o lê (o caminho do código, a guarda e a exportação); leitor novo entra aqui com o motivo');
select is((select count(*)::int from pg_views where definition ~ '\m(checkin_codigo|checkin_codigo_tentativa|confianca_baixa)\M')
        + (select count(*)::int from pg_matviews where definition ~ '\m(checkin_codigo|checkin_codigo_tentativa|confianca_baixa)\M'),
  0, 'nenhuma view nem view materializada lê o caminho do código');
select is((select count(*)::int from pg_policies where schemaname = 'privado' and tablename in ('checkin_codigo', 'checkin_codigo_tentativa')),
  0, 'nenhuma política nas duas tabelas: nenhum cliente as lê direto');
select is((select count(*)::int from pg_trigger
            where tgrelid in ('privado.checkin_codigo'::regclass, 'privado.checkin_codigo_tentativa'::regclass)
              and not tgisinternal),
  0, 'nenhum gatilho nas duas tabelas: nada copia a linha para outro lugar (RN15)');

select * from finish();
rollback;
