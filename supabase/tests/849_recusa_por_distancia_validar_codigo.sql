-- Prova: recusa própria por distância sem contar erro no check-in por código (0.2.76, achado A2).
-- Regras cobertas:
--   1. Validação sem posição (distancia_m nulo) recusa 422 sem_localizacao (sem details).
--   2. Validação acima do raio (> 50 m) recusa 422 fora_do_raio (sem details).
--   3. A distância é conferida ANTES de comparar o código: código certo e código errado
--      devolvem a mesma recusa (sem vazar se o código estava certo).
--   4. A recusa por distância/posição NÃO conta como erro no contador 3/6 e NÃO bloqueia
--      (10 recusas seguidas e o código certo de perto ainda valida na hora).
--   5. Bloqueio vigente (409 codigo_bloqueado) continua vencendo antes de tudo.
--   6. Registro em privado.checkin_codigo_tentativa com resultado 'recusada_sem_conferir'.
--   7. Teto contra inundação: no máximo uma gravação 'recusada_sem_conferir' a cada 60 s por turno.
--   8. Cobertura mutacional das restrições tentativa_resultado e aceita_com_codigo_e_perto.
--   9. Integração com MeusDados.checkins_por_codigo (LGPD).

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-01-11 21:30:00+00', true);
select plan(26);

-- A casa 849 (dono)
create temp table ids as
select 'c8490000-0000-4000-8000-000000000001'::uuid as dono,
       'c8490000-0000-4000-8000-000000000021'::uuid as casa;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select dono, 'contratante'::public.perfil_conta, 'Casa 849 Dono', '+5561999998491', 'casa849@test.invalid',
       '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select casa, 'Bar 849', '80000000000849', 'food_service'::public.tipo_estabelecimento, 'Endereço 849',
       'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select dono, casa, 'administrador'::public.papel_membro from ids;

-- Habilitar checkin_por_codigo
update privado.recurso set ligado = true where chave = 'checkin_por_codigo';
insert into privado.recurso_estabelecimento (chave, estabelecimento_id)
values ('checkin_por_codigo', 'c8490000-0000-4000-8000-000000000021') on conflict do nothing;

create temp table turnos (nome text primary key, turno uuid, usuario uuid);
create function pg_temp.novo(nome text, inicio timestamptz default '2027-01-11 21:00:00+00') returns uuid
language plpgsql as $$
declare
  v_user uuid := gen_random_uuid(); v_prof uuid := gen_random_uuid();
  v_vaga uuid := gen_random_uuid(); v_pos  uuid := gen_random_uuid(); v_t uuid := gen_random_uuid();
begin
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_user, 'profissional', 'Prof 849 ' || nome, '+5561999998490', nome || '@t849.invalid',
          '1992-01-01', '1.0', '2026-09-20 12:00:00-03');
  insert into public.profissional (id, usuario_id, ponto_base) values (v_prof, v_user, 'POINT(-47.8800 -15.7700)');
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por)
  values (v_vaga, 'c8490000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
          inicio, inicio + interval '5 hours', 'Local 849', 'POINT(-47.8800 -15.7700)',
          15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada', inicio - interval '33 hours',
          gen_random_uuid(), 'c8490000-0000-4000-8000-000000000001');
  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_pos, v_vaga, 'confirmada', v_prof, inicio - interval '32 hours', inicio, inicio + interval '5 hours');
  insert into public.turno (id, posicao_id, valor_acordado_centavos) values (v_t, v_pos, 15000);
  insert into turnos values (nome, v_t, v_user);
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
create function pg_temp.u(nome text) returns uuid language sql as $$ select usuario from turnos where turnos.nome = u.nome $$;

create function pg_temp.checkin(nome text, distancia integer) returns jsonb language sql as $$
  select pg_temp.como(pg_temp.u(nome), format('select public.fazer_checkin(%L::uuid, %s, %L::timestamptz)',
                                              pg_temp.t(nome), distancia, privado.agora()))
$$;

create function pg_temp.gerar(nome text) returns text language sql as $$
  select r->>'codigo' from (
    select pg_temp.como('c8490000-0000-4000-8000-000000000001', format(
      'select public.gerar_codigo_checkin(%L::uuid)', pg_temp.t(nome))) as r) x
$$;

create function pg_temp.chamar(conta uuid, turno uuid, codigo text, distancia integer) returns jsonb
language plpgsql as $$
declare r jsonb; v_det text;
begin
  perform set_config('response.status', '', true);
  r := pg_temp.como(conta, format('select public.validar_codigo_checkin(%L::uuid, %L::text, %s)',
                                  turno, codigo, coalesce(distancia::text, 'null')));
  return jsonb_build_object('status', coalesce(nullif(current_setting('response.status', true), '')::int, 200),
                            'corpo', r);
exception when sqlstate 'PGRST' then
  get stacked diagnostics v_det = pg_exception_detail;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return jsonb_build_object('status', (v_det::jsonb->>'status')::int, 'corpo', sqlerrm::jsonb);
end $$;

create function pg_temp.v(nome text, codigo text, distancia integer) returns text language sql as $$
  select (r->>'status') || ':' ||
         case when (r->>'status')::int = 200 then r->'corpo'->>'verificacao'
              else (r->'corpo'->>'code') || coalesce(':' || (r->'corpo'->>'details'), '') end
    from (select pg_temp.chamar(pg_temp.u(nome), pg_temp.t(nome), codigo, distancia) as r) x
$$;

select pg_temp.novo('t1');
select pg_temp.checkin('t1', 40);
select ok(pg_temp.gerar('t1') ~ '^[0-9]{6}$', 'código de 6 dígitos gerado pela casa');

create temp table cod_valido as
select codigo as cod from privado.checkin_codigo where turno_id = pg_temp.t('t1');

-- ── 2. Checagem prévia: sem localização (null) e fora do raio (> 50 m) ───────
-- 2.1 Código CERTO sem localização recusa 422 sem_localizacao
create temp table r_sem_pos as
select pg_temp.chamar(pg_temp.u('t1'), pg_temp.t('t1'), (select cod from cod_valido), null) as r;

select is((select (r->>'status')::int from r_sem_pos), 422, 'sem localização: HTTP 422');
select is((select r->'corpo'->>'code' from r_sem_pos), 'sem_localizacao', 'sem localização: code sem_localizacao');
select is((select r->'corpo'->>'details' from r_sem_pos), null, 'sem localização: details é nulo');

-- 2.2 Código CERTO a 60 m (> 50 m) recusa 422 fora_do_raio
select set_config('frila.agora', '2027-01-11 21:31:10+00', true);

create temp table r_longe as
select pg_temp.chamar(pg_temp.u('t1'), pg_temp.t('t1'), (select cod from cod_valido), 60) as r;

select is((select (r->>'status')::int from r_longe), 422, 'fora do raio: HTTP 422');
select is((select r->'corpo'->>'code' from r_longe), 'fora_do_raio', 'fora do raio: code fora_do_raio');
select is((select r->'corpo'->>'details' from r_longe), null, 'fora do raio: details é nulo');

-- ── 3. Antes de comparar: código errado dá a MESMA resposta ──────────────────
select set_config('frila.agora', '2027-01-11 21:32:20+00', true);
create temp table r_errado_longe as
select pg_temp.chamar(pg_temp.u('t1'), pg_temp.t('t1'), '000000', 80) as r;
select is((select r->'corpo'->>'code' from r_errado_longe), 'fora_do_raio',
  'código errado a 80 m: dá fora_do_raio sem comparar o código');

create temp table r_errado_sem_pos as
select pg_temp.chamar(pg_temp.u('t1'), pg_temp.t('t1'), '000000', null) as r;
select is((select r->'corpo'->>'code' from r_errado_sem_pos), 'sem_localizacao',
  'código errado sem posição: dá sem_localizacao sem comparar o código');

-- ── 4. Não avança contador de erros nem bloqueia ─────────────────────────────
select is((select erros from privado.checkin_codigo where turno_id = pg_temp.t('t1')), 0,
  'recusas por distância/posição não incrementam erros (erros continua 0)');

-- Simula 10 tentativas a 90 m
do $$
declare
  v_user uuid := (select pg_temp.u('t1'));
  v_t uuid := (select pg_temp.t('t1'));
  i int;
begin
  for i in 1..10 loop
    perform pg_temp.chamar(v_user, v_t, '999999', 90);
  end loop;
end $$;

select is((select erros from privado.checkin_codigo where turno_id = pg_temp.t('t1')), 0,
  '10 tentativas fora do raio: erros continua 0');
select is((select privado.estado_do_codigo(pg_temp.t('t1'))), 'aberto',
  'caminho do código continua aberto (não acionou bloqueio)');

-- ── 5. Teto contra inundação: no máximo 1 linha a cada 60 s ──────────────────
select is((select count(*)::int from privado.checkin_codigo_tentativa
            where turno_id = pg_temp.t('t1') and resultado = 'recusada_sem_conferir'
              and em = '2027-01-11 21:32:20+00'), 1,
  'teto contra inundação: 10 chamadas no mesmo minuto gravam apenas 1 linha recusada_sem_conferir');

-- ── 6. Bloqueio vigente vence antes da distância ─────────────────────────────
update privado.checkin_codigo
   set bloqueado_ate = '2027-01-11 21:45:00+00'
 where turno_id = pg_temp.t('t1');

create temp table r_bloqueado as
select pg_temp.chamar(pg_temp.u('t1'), pg_temp.t('t1'), (select cod from cod_valido), 150) as r;

select is((select (r->>'status')::int || ':' || (r->'corpo'->>'code') || ':' || (r->'corpo'->>'details') from r_bloqueado),
  '409:codigo_bloqueado:temporario',
  'bloqueio vigente vence antes da checagem de distância: responde 409 codigo_bloqueado');

update privado.checkin_codigo set bloqueado_ate = null where turno_id = pg_temp.t('t1');

-- ── 7. Validação com sucesso a 30 m (< 50 m) após todas as recusas ───────────
select set_config('frila.agora', '2027-01-11 21:34:00+00', true);
create temp table r_sucesso as
select pg_temp.chamar(pg_temp.u('t1'), pg_temp.t('t1'), (select cod from cod_valido), 30) as r;

select is((select (r->>'status')::int from r_sucesso), 200, 'validação a 30 m com código certo: HTTP 200');
select is((select r->'corpo'->>'verificacao' from r_sucesso), 'verificado', 'presença confirmada como verificado');
select is((select checkin_tipo from public.turno where id = pg_temp.t('t1')), 'codigo', 'checkin_tipo vira codigo');

-- ── 8. Cobertura mutacional das restrições de checkin_codigo_tentativa ───────
-- 8.1 tentativa_resultado
select throws_ok(
  format($$insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa, codigo_gerado_em)
            values (%L, '2027-01-11 21:35:00+00', 'invalido', 'ate_100_m', '2027-01-11 21:30:00+00')$$, pg_temp.t('t1')),
  '23514', null, 'tentativa_resultado: recusa resultado <> aceita, recusada, recusada_sem_conferir');

select lives_ok(
  format($$insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa, codigo_gerado_em)
            values (%L, '2027-01-11 21:36:00+00', 'recusada_sem_conferir', 'sem_posicao', null)$$, pg_temp.t('t1')),
  'tentativa_resultado: aceita recusada_sem_conferir sem posicao');

select lives_ok(
  format($$insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa, codigo_gerado_em)
            values (%L, '2027-01-11 21:37:00+00', 'recusada_sem_conferir', 'acima_de_100_m', null)$$, pg_temp.t('t1')),
  'tentativa_resultado: aceita recusada_sem_conferir acima de 100 m');

-- 8.2 aceita_com_codigo_e_perto
select throws_ok(
  format($$insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa, codigo_gerado_em)
            values (%L, '2027-01-11 21:38:00+00', 'aceita', 'acima_de_100_m', '2027-01-11 21:30:00+00')$$, pg_temp.t('t1')),
  '23514', null, 'aceita_com_codigo_e_perto: recusa aceita com faixa acima_de_100_m');

select throws_ok(
  format($$insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa, codigo_gerado_em)
            values (%L, '2027-01-11 21:39:00+00', 'aceita', 'ate_100_m', null)$$, pg_temp.t('t1')),
  '23514', null, 'aceita_com_codigo_e_perto: recusa aceita sem codigo_gerado_em');

-- ── 9. Exportação MeusDados.checkins_por_codigo (LGPD) ────────────────────────
create temp table exp as
select privado.meus_dados(pg_temp.u('t1'))->'checkins_por_codigo' as j;

select ok((select j from exp) is not null, 'checkins_por_codigo presente em MeusDados');
select is((select (v->>'codigo_exigido')::boolean from exp, jsonb_array_elements(j) v), true, 'codigo_exigido é true');
select ok(exists (
  select 1 from exp, jsonb_array_elements(j) v, jsonb_array_elements(v->'tentativas') t
   where t->>'resultado' = 'recusada_sem_conferir'
), 'tentativas em MeusDados traz o resultado recusada_sem_conferir');

select ok(exists (
  select 1 from exp, jsonb_array_elements(j) v, jsonb_array_elements(v->'tentativas') t
   where t->>'resultado' = 'aceita'
), 'tentativas em MeusDados traz o resultado aceita');

rollback;
