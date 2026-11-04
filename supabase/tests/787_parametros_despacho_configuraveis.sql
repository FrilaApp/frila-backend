-- 787_parametros_despacho_configuraveis.sql
--
-- Cobertura pgTAP dos parâmetros de despacho configuráveis em runtime.
-- Cartão 2RsO30sX · D02 · RN05, RN23.
--
-- O que prova:
--   1. privado.parametro_despacho guarda metro em `integer`, com o teto e o piso que
--      impedem raio zero e raio de país.
--   2. privado.parametro_de_despacho_metros lê a chave e devolve NULL quando ela não
--      existe (ao contrário do teto, em que ausência é erro).
--   3. privado.elegiveis **obedece ao parâmetro**: o mesmo cenário muda de conjunto de
--      elegíveis só com `update`, sem migração e sem redeploy. É este o grupo que mataria
--      um mutante que voltasse a cravar 15000 no `ST_DWithin`.
--   4. A equipe de confiança (RF18) continua dispensando o raio, qualquer que seja ele.
--   5. O fallback de 15000 segura o padrão da RN05 quando a chave é apagada.
--   6. Os parâmetros de tempo da RN23 (teto_janela, urgente_antecedencia) seguem legíveis
--      e ajustáveis pela mesma via, e chave ausente lá é exceção, não NULL.
--   7. Nem anon nem authenticated leem a tabela ou executam a função: parâmetro de
--      operação não é dado de API.
--
-- O cenário é sintético e nasce dentro da transação: um estabelecimento no Plano Piloto,
-- um profissional a ~1,6 km da vaga e outro a ~40 km (fora do raio padrão). Nenhum dado
-- real, nenhuma dependência do que já está no banco.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(29);

-- ── O cenário ─────────────────────────────────────────────────────────────────

create function pg_temp.cenario()
returns table (vaga uuid, perto uuid, longe uuid, estab uuid)
language plpgsql as $$
declare
  v_estab  uuid;
  v_funcao uuid;
  v_perto  uuid;
  v_longe  uuid;
  v_vaga   uuid;
  v_inicio timestamptz;
  v_fim    timestamptz;
  v_dow    int;
begin
  insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
  values ('Bar do Parâmetro', '11222333000181', 'food_service', 'CLN 201',
          'POINT(-47.8822 -15.7942)'::extensions.geography)
  returning id into v_estab;

  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values ('cccccccc-0787-0000-0000-000000000001','contratante','Dono do Bar',
          '+5561999990787','dono787@t.test','1980-01-01','2026-09-22', now());

  insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
  values ('cccccccc-0787-0000-0000-000000000001', v_estab, 'administrador');

  select id into v_funcao from public.funcao where nome = 'garçom';

  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
    ('aaaaaaaa-0787-0000-0000-000000000001','profissional','Perto','+5561999990781','perto787@t.test','1995-01-01','2026-09-22', now()),
    ('aaaaaaaa-0787-0000-0000-000000000002','profissional','Longe','+5561999990782','longe787@t.test','1995-01-01','2026-09-22', now());

  -- ~1,6 km da vaga (Asa Norte) e ~40 km (sentido Brazlândia): um dentro e um fora do
  -- raio padrão de 15 km, para o parâmetro ter o que mover.
  insert into public.profissional (usuario_id, ponto_base) values
    ('aaaaaaaa-0787-0000-0000-000000000001','POINT(-47.8822 -15.7800)'::extensions.geography),
    ('aaaaaaaa-0787-0000-0000-000000000002','POINT(-48.2500 -15.7942)'::extensions.geography);

  select p.id into v_perto from public.profissional p where p.usuario_id = 'aaaaaaaa-0787-0000-0000-000000000001';
  select p.id into v_longe from public.profissional p where p.usuario_id = 'aaaaaaaa-0787-0000-0000-000000000002';

  insert into public.profissional_funcao (profissional_id, funcao_id) values
    (v_perto, v_funcao), (v_longe, v_funcao);

  -- A vaga começa amanhã às 10h e termina às 14h, no fuso do DF, e a grade dos dois
  -- cobre o dia inteiro: a grade não é o que este teste mede.
  v_inicio := (date_trunc('day', privado.agora() at time zone 'America/Sao_Paulo')
               + interval '1 day' + interval '10 hours') at time zone 'America/Sao_Paulo';
  v_fim    := v_inicio + interval '4 hours';
  v_dow    := extract(dow from (v_inicio at time zone 'America/Sao_Paulo'))::int;

  insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim) values
    (v_perto, v_dow, '00:00', '23:59:59'),
    (v_longe, v_dow, '00:00', '23:59:59');

  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente,
                           publicado_por)
  values (v_estab, v_funcao, v_inicio, v_fim, 'CLN 201',
          'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1::smallint, true, false, false, 'Maître', 'urgencia', gen_random_uuid(),
          'cccccccc-0787-0000-0000-000000000001')
  returning id into v_vaga;

  return query select v_vaga, v_perto, v_longe, v_estab;
end $$;

create temp table cen as select * from pg_temp.cenario();

create function pg_temp.elegiveis_do_cenario() returns bigint
language sql as $$
  select count(*) from privado.elegiveis((select vaga from cen));
$$;

create function pg_temp.eh_elegivel(p_prof uuid) returns boolean
language sql as $$
  select exists (
    select 1 from privado.elegiveis((select vaga from cen)) e
     where e.profissional_id = p_prof
  );
$$;

-- ── 1. A tabela guarda metro em integer, e só valor de gente ──────────────────

select has_table('privado', 'parametro_despacho',
  'privado.parametro_despacho existe');

select is(
  (select data_type from information_schema.columns
    where table_schema = 'privado' and table_name = 'parametro_despacho'
      and column_name = 'valor_metros'),
  'integer',
  'valor_metros é integer: ST_DWithin sobre geography recebe metro, e o tipo é a documentação que não envelhece');

select is(
  privado.parametro_de_despacho_metros('raio_maximo_metros'),
  15000,
  'RN05: o raio nasce em 15000 metros, o mesmo número que era literal antes do cartão');

select throws_ok(
  $$ update privado.parametro_despacho set valor_metros = 0 where chave = 'raio_maximo_metros' $$,
  '23514', null,
  'raio zero é recusado: despacho sem ninguém não é configuração, é incidente');

select throws_ok(
  $$ update privado.parametro_despacho set valor_metros = -1 where chave = 'raio_maximo_metros' $$,
  '23514', null,
  'raio negativo é recusado');

select throws_ok(
  $$ update privado.parametro_despacho set valor_metros = 250000 where chave = 'raio_maximo_metros' $$,
  '23514', null,
  'raio acima de 200 km é recusado: um zero a mais em 15000 notificaria o país');

select throws_ok(
  $$ insert into privado.parametro_despacho (chave, valor_metros, descricao)
     values ('sem_descricao', 1000, '   ') $$,
  '23514', null,
  'parâmetro sem descrição é recusado: quem lê a tabela precisa saber o que o número decide');

-- ── 2. A leitura devolve NULL na chave ausente ────────────────────────────────

select is(
  privado.parametro_de_despacho_metros('chave_que_nao_existe'),
  null,
  'chave ausente devolve NULL, e não exceção: quem chama aplica o padrão da regra');

-- ── 3. privado.elegiveis obedece ao parâmetro ────────────────────────────────
-- Este é o grupo que mata o mutante óbvio: se o ST_DWithin voltasse a cravar 15000, as
-- três provas abaixo (50 km, 500 m e a volta ao padrão) ficariam vermelhas.

select ok(
  pg_temp.eh_elegivel((select perto from cen)),
  'raio padrão: o profissional a ~1,6 km entra no despacho');

select ok(
  not pg_temp.eh_elegivel((select longe from cen)),
  'raio padrão: o profissional a ~40 km fica fora');

update privado.parametro_despacho set valor_metros = 50000 where chave = 'raio_maximo_metros';

select is(
  privado.parametro_de_despacho_metros('raio_maximo_metros'),
  50000,
  'o raio mudou para 50 km com um update, sem migração de esquema');

select ok(
  pg_temp.eh_elegivel((select longe from cen)),
  'com 50 km, o profissional a ~40 km passa a ser elegível: a função lê o parâmetro, não um literal');

select is(
  pg_temp.elegiveis_do_cenario(),
  2::bigint,
  'com 50 km, os dois profissionais do cenário entram');

update privado.parametro_despacho set valor_metros = 500 where chave = 'raio_maximo_metros';

select is(
  pg_temp.elegiveis_do_cenario(),
  0::bigint,
  'com 500 m, ninguém do cenário entra: o aperto também vale');

-- ── 4. Equipe de confiança dispensa o raio (RF18) ────────────────────────────

insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select estab, longe from cen;

select ok(
  pg_temp.eh_elegivel((select longe from cen)),
  'RF18: a equipe de confiança entra mesmo com o raio em 500 m');

select ok(
  not pg_temp.eh_elegivel((select perto from cen)),
  'quem não está na equipe continua preso ao raio de 500 m');

delete from public.equipe_confianca
 where profissional_id = (select longe from cen);

-- ── 5. O fallback segura o padrão da RN05 ────────────────────────────────────

delete from privado.parametro_despacho where chave = 'raio_maximo_metros';

select is(
  privado.parametro_de_despacho_metros('raio_maximo_metros'),
  null,
  'a chave apagada não é lida');

select ok(
  pg_temp.eh_elegivel((select perto from cen)),
  'sem a chave, o coalesce de privado.elegiveis devolve os 15 km da RN05: o de ~1,6 km continua elegível');

select ok(
  not pg_temp.eh_elegivel((select longe from cen)),
  'sem a chave, o de ~40 km segue fora: o fallback é o padrão da regra, não "sem raio"');

insert into privado.parametro_despacho (chave, valor_metros, descricao)
values ('raio_maximo_metros', 15000, 'RN05: restaurado pelo teste 787.');

-- ── 6. Os parâmetros de tempo da RN23 ────────────────────────────────────────

select is(
  privado.parametro_de_notificacao('teto_janela'),
  interval '30 minutes',
  'RN23: o teto entre notificações é de 30 minutos');

select is(
  privado.parametro_de_notificacao('urgente_antecedencia'),
  interval '2 hours',
  'RN23: a vaga que começa em menos de 2 horas fura o agrupamento');

update privado.parametro_notificacao set valor = interval '45 minutes' where chave = 'teto_janela';

select is(
  privado.parametro_de_notificacao('teto_janela'),
  interval '45 minutes',
  'RN23: o teto também se ajusta por update, sem migração');

update privado.parametro_notificacao set valor = interval '30 minutes' where chave = 'teto_janela';

select throws_ok(
  $$ select privado.parametro_de_notificacao('chave_que_nao_existe') $$,
  'P0002', null,
  'RN23: parâmetro de tempo ausente é exceção, porque teto ausente viraria "sem teto" em silêncio');

-- ── 7. Parâmetro de operação não é dado de API ───────────────────────────────

select ok(
  not has_table_privilege('anon', 'privado.parametro_despacho', 'select')
  and not has_table_privilege('authenticated', 'privado.parametro_despacho', 'select'),
  'nem anon nem authenticated leem privado.parametro_despacho');

select ok(
  not has_function_privilege('anon', 'privado.parametro_de_despacho_metros(text)', 'execute')
  and not has_function_privilege('authenticated', 'privado.parametro_de_despacho_metros(text)', 'execute'),
  'nem anon nem authenticated executam privado.parametro_de_despacho_metros');

select ok(
  has_function_privilege('service_role', 'privado.parametro_de_despacho_metros(text)', 'execute'),
  'service_role executa a leitura, como na irmã da RN23');

-- O invariante do schema `privado`: 100% das tabelas com RLS, nenhuma com FORCE. Os testes
-- 738 e 785 conferem isso sobre o schema inteiro, e foi essa conta que a primeira versão
-- desta migração quebrou — a tabela nasceu sem RLS. A asserção aqui nomeia a tabela, para
-- a falha apontar o arquivo que a criou em vez de um total de schema.
select is(
  (select c.relrowsecurity from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'parametro_despacho'),
  true,
  'privado.parametro_despacho tem RLS habilitado, como toda tabela de privado (achado 1 da AUDITORIA-RLS)');

select is(
  (select c.relforcerowsecurity from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'parametro_despacho'),
  false,
  'privado.parametro_despacho não tem FORCE RLS: forçar tiraria o bypass do dono e quebraria a função SECURITY DEFINER que a lê');

-- Com RLS ligado e nenhuma política, um GRANT concedido por engano não vaza linha. A irmã
-- da RN23 tem a mesma prova no teste 738.
grant select on privado.parametro_despacho to authenticated;

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'privado' and tablename = 'parametro_despacho'),
  0,
  'sem política nenhuma: com RLS ligado, GRANT acidental para authenticated não devolve linha');

revoke select on privado.parametro_despacho from authenticated;

select * from finish();

rollback;
