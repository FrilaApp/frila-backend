-- 831_fazer_checkin_sinais.sql
--
-- fazer_checkin com os sinais do aparelho (contrato 0.2.68; migração 20261109103000). Cobre:
--   · critério 7: com a chave desligada para a casa (global, ou casa fora da lista), os sinais
--     são ignorados, até no formato, e a resposta é a de hoje;
--   · critério 9 e leitura 4: sem sinais, o caminho A não muda, faixa de 150 a 200 m inclusive;
--   · a proteção por risco (seção 6; leitura 5): localização simulada, salto, precisão a partir de
--     100 m e a faixa de 150 a 200 m deixam o check-in manual e pendente, com codigo_exigido, e a
--     resposta não diz qual sinal pesou;
--   · critério 10 e leitura 8: a casa ainda confirma à mão, e o manual sem confirmação fecha
--     nao_verificado, com o aviso aos dois lados;
--   · uma assinatura só, com sinais opcional (sem PGRST203).
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-01-11 21:30:00+00', true);
select plan(36);

create temp table ids as
select 'c8310000-0000-4000-8000-000000000002'::uuid as casa_user,
       'c8310000-0000-4000-8000-000000000021'::uuid as casa;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select casa_user, 'contratante'::public.perfil_conta, 'Casa 831', '+5561999998312',
       'casa831@test.invalid', '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz from ids;
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select casa, 'Bar 831', '80000000000831', 'food_service'::public.tipo_estabelecimento, 'Endereço de teste',
       'POINT(-47.8800 -15.7700)'::extensions.geography from ids;
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select casa_user, casa, 'administrador' from ids;

-- Um profissional com um turno confirmado de hoje, das 21h às 2h, ainda sem check-in.
create temp table turnos (nome text primary key, turno uuid, usuario uuid);
create function pg_temp.novo(nome text) returns void language plpgsql as $$
declare
  v_user uuid := gen_random_uuid(); v_prof uuid := gen_random_uuid();
  v_vaga uuid := gen_random_uuid(); v_pos  uuid := gen_random_uuid(); v_t uuid := gen_random_uuid();
begin
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_user, 'profissional', 'Prof 831 ' || nome, '+5561999998310', nome || '@t831.invalid',
          '1992-01-01', '1.0', '2026-09-20 12:00:00-03');
  insert into public.profissional (id, usuario_id, ponto_base)
  values (v_prof, v_user, 'POINT(-47.8800 -15.7700)');
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por)
  values (v_vaga, 'c8310000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
          '2027-01-11 21:00:00+00', '2027-01-12 02:00:00+00', 'Local 831', 'POINT(-47.8800 -15.7700)',
          15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada', '2027-01-10 12:00:00+00',
          gen_random_uuid(), 'c8310000-0000-4000-8000-000000000002');
  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_pos, v_vaga, 'confirmada', v_prof, '2027-01-10 13:00:00+00',
          '2027-01-11 21:00:00+00', '2027-01-12 02:00:00+00');
  insert into public.turno (id, posicao_id, valor_acordado_centavos) values (v_t, v_pos, 15000);
  insert into turnos values (nome, v_t, v_user);
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

-- O SQL do check-in do profissional do turno. Sem sinais, a chamada tem três argumentos, como a
-- do app 1.0 e do 1.1.
create function pg_temp.sql_checkin(nome text, distancia integer, sinais jsonb) returns text language sql as $$
  select format('select public.fazer_checkin(%L::uuid, %s, %L::timestamptz%s)',
                (select turno from turnos t where t.nome = sql_checkin.nome), coalesce(distancia::text, 'null'),
                '2027-01-11 21:30:00+00', case when sinais is null then '' else format(', %L::jsonb', sinais) end) $$;

create function pg_temp.checkin(nome text, distancia integer, sinais jsonb default null) returns jsonb language sql as $$
  select pg_temp.como((select usuario from turnos t where t.nome = checkin.nome), pg_temp.sql_checkin(nome, distancia, sinais)) $$;

-- A recusa de public.erro como "status code motivo".
create function pg_temp.recusa(nome text, distancia integer, sinais jsonb) returns text language plpgsql as $$
declare msg text; det text;
begin
  perform pg_temp.checkin(nome, distancia, sinais);
  return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return concat_ws(' ', det::jsonb ->> 'status', msg::jsonb ->> 'code', msg::jsonb ->> 'details');
end $$;

-- tipo, verificacao e codigo_exigido da resposta, numa linha.
create function pg_temp.resumo(r jsonb) returns text language sql as $$
  select concat_ws(' ', r ->> 'tipo', r ->> 'verificacao', 'exigido=' || coalesce(r ->> 'codigo_exigido', '-'),
                   'disponivel=' || coalesce(r ->> 'codigo_disponivel', '-')) $$;

create function pg_temp.t(nome text) returns uuid language sql as $$ select turno from turnos x where x.nome = t.nome $$;

select pg_temp.novo(n) from unnest(array[
  'off', 'off_mal', 'fora', 'sem_sinais', 'sem_sinais_180', 'normal', 'simulada', 'salto', 'precisao_100',
  'precisao_99', 'precisao_20_0', 'precisao_100_0', 'precisao_nula', 'faixa_150', 'faixa_149', 'faixa_200', 'acima_201', 'mal', 'sem_distancia']) n;

-- ── 1. Chave desligada: nada muda (critério 7) ────────────────────────────────
select is(pg_temp.resumo(pg_temp.checkin('off', 50, '{"localizacao_simulada": true, "precisao_m": 5, "salto_de_posicao": false}')),
  'geolocalizado verificado exigido=- disponivel=-', 'chave desligada: o sinal suspeito é ignorado e os 50 m verificam na hora');
select is((select array_agg(k order by k) from jsonb_object_keys(
            privado.resposta_do_checkin((select t from public.turno t where t.id = pg_temp.t('off')), false)) k),
  array['distancia_m', 'registrado_em', 'tipo', 'turno_id', 'verificacao'], 'chave desligada: a resposta é a de hoje, sem os campos novos');
select is(pg_temp.resumo(pg_temp.checkin('off_mal', 50, '{"qualquer": 1}')),
  'geolocalizado verificado exigido=- disponivel=-', 'chave desligada: nem o formato dos sinais é conferido');
select is((select count(*)::int from privado.checkin_codigo where turno_id in (pg_temp.t('off'), pg_temp.t('off_mal'))), 0,
  'chave desligada: nenhum estado do código é criado');

update privado.recurso set ligado = true where chave = 'checkin_por_codigo';
select is(pg_temp.resumo(pg_temp.checkin('fora', 50, '{"localizacao_simulada": true, "precisao_m": 5, "salto_de_posicao": false}')),
  'geolocalizado verificado exigido=- disponivel=-', 'chave global ligada e casa fora do piloto: igual à chave desligada');

insert into privado.recurso_estabelecimento (chave, estabelecimento_id) select 'checkin_por_codigo', casa from ids;

-- ── 2. Chave ligada, sem sinal suspeito: o caminho A não muda (critério 9; leitura 4) ──
select is(pg_temp.resumo(pg_temp.checkin('sem_sinais', 50)),
  'geolocalizado verificado exigido=false disponivel=false', 'sem sinais (app 1.0 e 1.1, três argumentos): os 50 m verificam na hora');
select is(pg_temp.resumo(pg_temp.checkin('sem_sinais_180', 180)),
  'geolocalizado verificado exigido=false disponivel=false', 'leitura 4: sem sinais, a faixa de 150 a 200 m não pesa');
select is(pg_temp.resumo(pg_temp.checkin('normal', 50, '{"localizacao_simulada": false, "precisao_m": 20, "salto_de_posicao": false}')),
  'geolocalizado verificado exigido=false disponivel=false', 'sinais normais: quem está normal não sente atrito');

-- ── 3. Sinal suspeito: a casa atesta (seção 6; leitura 5) ─────────────────────
select is(pg_temp.resumo(pg_temp.checkin('simulada', 50, '{"localizacao_simulada": true, "precisao_m": 5, "salto_de_posicao": false}')),
  'manual pendente exigido=true disponivel=true', 'localização simulada: a 50 m, o check-in fica manual e pendente, com o código exigido');
select ok((select checkin_distancia_m is null from public.turno where id = pg_temp.t('simulada'))
          and (select codigo_exigido from privado.checkin_codigo where turno_id = pg_temp.t('simulada')),
  'o servidor grava só codigo_exigido; a distância do manual não é gravada, e os sinais nunca');
select is((select count(*)::int from public.notificacao
            where tipo = 'checkin_manual_pendente' and referencia_id = pg_temp.t('simulada')
              and usuario_id = (select casa_user from ids)), 1,
  'a casa recebe o checkin_manual_pendente de sempre, que no app 1.2 abre a tela do código');
select is(pg_temp.resumo(pg_temp.checkin('salto', 50, '{"localizacao_simulada": false, "precisao_m": 5, "salto_de_posicao": true}')),
  'manual pendente exigido=true disponivel=true', 'salto de posição: o código é exigido');
select is(pg_temp.resumo(pg_temp.checkin('precisao_100', 50, '{"localizacao_simulada": false, "precisao_m": 100, "salto_de_posicao": false}')),
  'manual pendente exigido=true disponivel=true', 'leitura 5: precisão ruim a partir de 100 m');
select is(pg_temp.resumo(pg_temp.checkin('precisao_99', 50, '{"localizacao_simulada": false, "precisao_m": 99, "salto_de_posicao": false}')),
  'geolocalizado verificado exigido=false disponivel=false', 'leitura 5: 99 m de imprecisão ainda não é precisão ruim');
-- A precisão é inteira pelo valor (contrato: type integer, metros inteiros): 20.0, como o Kotlin
-- serializa um Double, passa e é avaliada, sem erro cru (bloqueio do Lince AG 2 no #464).
select is(pg_temp.resumo(pg_temp.checkin('precisao_20_0', 50, '{"localizacao_simulada": false, "precisao_m": 20.0, "salto_de_posicao": false}')),
  'geolocalizado verificado exigido=false disponivel=false', 'precisao_m 20.0: passa e é avaliada como 20, sem erro cru (#464)');
select is(pg_temp.resumo(pg_temp.checkin('precisao_100_0', 50, '{"localizacao_simulada": false, "precisao_m": 100.0, "salto_de_posicao": false}')),
  'manual pendente exigido=true disponivel=true', 'precisao_m 100.0: avaliada como 100, precisão ruim (#464)');
select lives_ok($$ select privado.sinal_suspeito(v.s, 50)
                     from (values ('{"localizacao_simulada": false, "precisao_m": 0, "salto_de_posicao": false}'::jsonb),
                                  ('{"localizacao_simulada": false, "precisao_m": 20.0, "salto_de_posicao": false}'),
                                  ('{"localizacao_simulada": false, "precisao_m": 1e2, "salto_de_posicao": false}'),
                                  ('{"localizacao_simulada": false, "precisao_m": 2147483647.0, "salto_de_posicao": false}'),
                                  ('{"localizacao_simulada": false, "precisao_m": null, "salto_de_posicao": false}')) v (s)
                    where privado.sinais_validos(v.s) $$,
  'todo sinal que passa no sinais_validos é avaliado sem erro cru: 0, 20.0, 1e2, 2147483647.0 e nulo (#464)');
select is(pg_temp.resumo(pg_temp.checkin('precisao_nula', 50, '{"localizacao_simulada": false, "precisao_m": null, "salto_de_posicao": false}')),
  'geolocalizado verificado exigido=false disponivel=false', 'D5 PENDENTE do JP: provisoriamente, precisão nula não conta como ruim (muda só em privado.precisao_ruim)');
select is(pg_temp.resumo(pg_temp.checkin('faixa_150', 150, '{"localizacao_simulada": false, "precisao_m": 5, "salto_de_posicao": false}')),
  'manual pendente exigido=true disponivel=true', 'com sinais, a faixa começa em 150 m');
select is(pg_temp.resumo(pg_temp.checkin('faixa_149', 149, '{"localizacao_simulada": false, "precisao_m": 5, "salto_de_posicao": false}')),
  'geolocalizado verificado exigido=false disponivel=false', 'com sinais, 149 m está fora da faixa');
select is(pg_temp.resumo(pg_temp.checkin('faixa_200', 200, '{"localizacao_simulada": false, "precisao_m": 5, "salto_de_posicao": false}')),
  'manual pendente exigido=true disponivel=true', 'com sinais, a faixa vai até 200 m');
select is(pg_temp.resumo(pg_temp.checkin('acima_201', 201, '{"localizacao_simulada": false, "precisao_m": 5, "salto_de_posicao": false}')),
  'manual pendente exigido=false disponivel=true', 'acima de 200 m é o manual de sempre: o código fica disponível, mas não exigido');
select is((select array_agg(k order by k) from jsonb_object_keys(
            privado.resposta_do_checkin((select t from public.turno t where t.id = pg_temp.t('simulada')), true)) k),
  array['codigo_disponivel', 'codigo_exigido', 'distancia_m', 'registrado_em', 'tipo', 'turno_id', 'verificacao'],
  'a resposta não diz qual sinal pesou: só os dois campos do contrato a mais');

-- ── 4. Sinais fora do formato, com a chave ligada ─────────────────────────────
select is(pg_temp.recusa('mal', 50, '{"localizacao_simulada": false, "salto_de_posicao": false}'),
  '422 campo_invalido sinais', 'sinais sem precisao_m: 422 campo_invalido (sinais)');
select is(pg_temp.recusa('mal', 50, '{"localizacao_simulada": false, "precisao_m": -1, "salto_de_posicao": false}'),
  '422 campo_invalido sinais', 'precisao_m negativa: 422 campo_invalido (sinais)');
select is(pg_temp.recusa('mal', 50, '{"localizacao_simulada": false, "precisao_m": 4.7, "salto_de_posicao": false}'),
  '422 campo_invalido sinais', 'precisao_m com fração (4.7): 422 campo_invalido (sinais), como os outros sinais fora do contrato (#464)');
select is(pg_temp.recusa('mal', 50, '{"localizacao_simulada": "sim", "precisao_m": 5, "salto_de_posicao": false}'),
  '422 campo_invalido sinais', 'localizacao_simulada que não é booleano: 422 campo_invalido (sinais)');
select ok((select checkin_em is null from public.turno where id = pg_temp.t('mal')),
  'a recusa pelos sinais não grava check-in');

-- ── 5. O reenvio ──────────────────────────────────────────────────────────────
select is(pg_temp.resumo(pg_temp.checkin('simulada', 50)),
  'manual pendente exigido=true disponivel=true', 'o reenvio devolve o mesmo codigo_exigido');
update privado.checkin_codigo set erros = 6, encerrado_em = '2027-01-11 21:40:00+00' where turno_id = pg_temp.t('salto');
select is(pg_temp.resumo(pg_temp.checkin('salto', 50)),
  'manual pendente exigido=true disponivel=false', 'no reenvio, codigo_disponivel é o do momento: com o caminho encerrado, false');

-- ── 6. O manual continua (critério 10; leitura 8) ─────────────────────────────
select is(pg_temp.resumo(pg_temp.como((select casa_user from ids),
            format('select public.confirmar_checkin_manual(%L::uuid)', pg_temp.t('simulada')))),
  'manual verificado exigido=- disponivel=-', 'leitura 8: com o código exigido, a casa ainda confirma à mão');
select is(pg_temp.resumo(pg_temp.checkin('sem_distancia', null, '{"localizacao_simulada": false, "precisao_m": 5, "salto_de_posicao": false}')),
  'manual pendente exigido=false disponivel=true', 'sem localização, o check-in é o manual de sempre');

select set_config('frila.agora', '2027-01-12 02:10:00+00', true);
select privado.fechar_turnos_passados();
select is((select verificacao::text from public.turno where id = pg_temp.t('sem_distancia')), 'nao_verificado',
  'critério 10: o manual sem confirmação fecha nao_verificado no fim do turno');
select is((select count(*)::int from public.notificacao where tipo = 'turno_nao_verificado' and referencia_id = pg_temp.t('sem_distancia')), 2,
  'critério 10: os dois lados recebem o aviso turno_nao_verificado');

-- ── 7. Uma assinatura só ──────────────────────────────────────────────────────
select is((select count(*)::int from pg_proc where proname = 'fazer_checkin' and pronamespace = 'public'::regnamespace), 1,
  'fazer_checkin tem uma assinatura só, sem sobrecarga (PGRST203)');
select ok((select pg_get_function_arguments(p.oid) like '%sinais jsonb DEFAULT NULL%'
             from pg_proc p where p.proname = 'fazer_checkin' and p.pronamespace = 'public'::regnamespace),
  'sinais é opcional: quem chama com três argumentos segue funcionando');

select * from finish();
rollback;
