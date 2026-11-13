-- 833_validar_codigo_checkin.sql
--
-- validar_codigo_checkin (contrato 0.2.68, `validarCodigoCheckin`; migração 20261111201000). Cobre:
--   · as recusas que não gravam nem contam: 401 (sem sessão e conta que não existe mais), 403
--     conta_suspensa, 422 perfil_incompativel, 422 de formato (turno_id, codigo e distancia_m), 404
--     (turno inexistente, de outro profissional e bloqueio) e 403 recurso_desligado;
--   · o estado: 409 checkin_pendente, 409 checkin_ja_confirmado (o código já usado inclusive, leitura
--     7), 422 fora_da_janela, que a conta de demonstração atravessa (D9), 409 codigo_bloqueado durante o
--     bloqueio e depois de encerrado, sem contar;
--   · o acerto: o turno vira codigo e verificado, a hora da validação, o valor apagado, a tentativa
--     aceita, o aviso checkin aos membros, a resposta do contrato, e o turno sai dos pendentes do painel
--     (critérios 1, 2 e 3); sem posição, confiança baixa, que não sai no painel nem em meus_turnos
--     (critérios 4b e 11);
--   · o erro: conta, grava a tentativa e responde por response.status, sem desfazer a gravação (D2):
--     422 codigo_invalido, 409 temporario na 3ª, 409 encerrado na 6ª (critérios 4 e 6); o raio de
--     100 m, com a borda; o vencido pela validade e não pela presença do valor (D4), com a borda dos
--     300 s; o raio da regra e o coalesce de 100 sem ela (R1);
--   · a posição cancelada não ganha presença; o código nunca sai num erro de restrição (R2);
--   · a confirmação manual depois do código recusa 409 checkin_ja_confirmado (0.2.69, PR7).
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-01-11 21:30:00+00', true);
select plan(78);

-- A casa 833 (dono e operador) e um contratante de outra casa.
create temp table ids as
select 'c8330000-0000-4000-8000-000000000001'::uuid as dono,
       'c8330000-0000-4000-8000-000000000002'::uuid as operador,
       'c8330000-0000-4000-8000-000000000021'::uuid as casa;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select u, 'contratante'::public.perfil_conta, 'Casa 833 ' || n, '+556199999833' || n, 'casa833-' || n || '@test.invalid',
       '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids, lateral (values (dono, 1), (operador, 2)) v (u, n);
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select casa, 'Bar 833', '80000000000833', 'food_service'::public.tipo_estabelecimento, 'Endereço de teste',
       'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select u, casa, p::public.papel_membro from ids, lateral (values (dono, 'administrador'), (operador, 'operador')) v (u, p);

-- Cada turno é de um profissional próprio, confirmado, de hoje, das 21h às 2h.
create temp table turnos (nome text primary key, turno uuid, usuario uuid);
create function pg_temp.novo(nome text, inicio timestamptz default '2027-01-11 21:00:00+00') returns uuid
language plpgsql as $$
declare
  v_user uuid := gen_random_uuid(); v_prof uuid := gen_random_uuid();
  v_vaga uuid := gen_random_uuid(); v_pos  uuid := gen_random_uuid(); v_t uuid := gen_random_uuid();
begin
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_user, 'profissional', 'Prof 833 ' || nome, '+5561999998330', nome || '@t833.invalid',
          '1992-01-01', '1.0', '2026-09-20 12:00:00-03');
  insert into public.profissional (id, usuario_id, ponto_base) values (v_prof, v_user, 'POINT(-47.8800 -15.7700)');
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por)
  values (v_vaga, 'c8330000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
          inicio, inicio + interval '5 hours', 'Local 833', 'POINT(-47.8800 -15.7700)',
          15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada', inicio - interval '33 hours',
          gen_random_uuid(), 'c8330000-0000-4000-8000-000000000001');
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
  select pg_temp.como('c8330000-0000-4000-8000-000000000001',
                      format('select public.gerar_codigo_checkin(%L::uuid)', pg_temp.t(nome)))->>'codigo'
$$;
create function pg_temp.cod(nome text) returns text language sql as $$
  select c.codigo from privado.checkin_codigo c where c.turno_id = pg_temp.t(nome)
$$;
-- Um código de 6 dígitos que não é o gravado.
create function pg_temp.errado(nome text) returns text language sql as $$
  select lpad(((coalesce(pg_temp.cod(nome), '000000')::int + 1) % 1000000)::text, 6, '0')
$$;
-- A chamada como a PostgREST a responde: o status (response.status, ou o do raise) e o corpo.
create function pg_temp.chamar(conta uuid, turno uuid, codigo text, distancia integer) returns jsonb
language plpgsql as $$
declare r jsonb; v_det text;
begin
  perform set_config('response.status', '', true);
  r := pg_temp.como(conta, format('select public.validar_codigo_checkin(%L::uuid, %L::text, %L::integer)',
                                  turno, codigo, distancia));
  return jsonb_build_object('status', coalesce(nullif(current_setting('response.status', true), '')::int, 200),
                            'corpo', r);
exception when sqlstate 'PGRST' then
  get stacked diagnostics v_det = pg_exception_detail;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return jsonb_build_object('status', (v_det::jsonb->>'status')::int, 'corpo', sqlerrm::jsonb);
end $$;
-- Resumida: status:code[:details] na recusa, status:verificacao no 200.
create function pg_temp.validar(conta uuid, turno uuid, codigo text, distancia integer) returns text
language sql as $$
  select (r->>'status') || ':' ||
         case when (r->>'status')::int = 200 then r->'corpo'->>'verificacao'
              else (r->'corpo'->>'code') || coalesce(':' || (r->'corpo'->>'details'), '') end
    from (select pg_temp.chamar(conta, turno, codigo, distancia) as r) x
$$;
-- O profissional do turno valida.
create function pg_temp.v(nome text, codigo text, distancia integer) returns text language sql as $$
  select pg_temp.validar(pg_temp.u(nome), pg_temp.t(nome), codigo, distancia)
$$;
create function pg_temp.erros(nome text) returns integer language sql as $$
  select coalesce((select c.erros from privado.checkin_codigo c where c.turno_id = pg_temp.t(nome)), 0)
$$;
create function pg_temp.tentativas(nome text) returns integer language sql as $$
  select count(*)::int from privado.checkin_codigo_tentativa k where k.turno_id = pg_temp.t(nome)
$$;
create function pg_temp.ligar() returns void language sql as $$
  update privado.recurso set ligado = true where chave = 'checkin_por_codigo';
$$;
create function pg_temp.painel() returns jsonb language sql as $$
  select pg_temp.como('c8330000-0000-4000-8000-000000000001', format(
    'select public.painel_estabelecimento(%L::uuid, %L::timestamptz, %L::timestamptz)',
    'c8330000-0000-4000-8000-000000000021', '2027-01-11 00:00:00+00', '2027-01-13 00:00:00+00'))
$$;

-- Desde 20261112210000 a chave nasce ligada para todas as casas. A massa abaixo nasce no fluxo legado (a
-- chave desligada: 'verificado' fecha geolocalizado e verificado na hora) e a chave liga adiante, como antes.
update privado.recurso set ligado = false where chave = 'checkin_por_codigo';

select pg_temp.novo(n) from unnest(array['a', 'sem_posicao', 'raio', 'erros', 'vencido', 'regra', 'cancelada',
                                         'r2', 'sem_codigo', 'sem_checkin', 'verificado', 'bloqueado', 'suspenso']) n;
select pg_temp.novo('fora', '2027-01-12 08:00:00+00');   -- começa amanhã de manhã: fora da janela
select pg_temp.checkin(n, 500) from unnest(array['a', 'sem_posicao', 'raio', 'erros', 'vencido', 'regra',
                                                 'cancelada', 'r2', 'sem_codigo', 'bloqueado', 'suspenso']) n;
select pg_temp.checkin('verificado', 50);       -- geolocalizado e verificado
-- O check-in do turno de amanhã, gravado à mão: a janela do check-in também o recusaria.
update public.turno set checkin_em = '2027-01-11 21:30:00+00', checkin_tipo = 'manual'
 where id = pg_temp.t('fora');
insert into public.bloqueio (autor_id, bloqueado_id) select dono, pg_temp.u('bloqueado') from ids;
update public.usuario set estado = 'suspensa' where id = pg_temp.u('suspenso');

-- ── As recusas que não gravam nem contam ─────────────────────────────────────
select is(pg_temp.validar(null, pg_temp.t('a'), '123456', 40), '401:nao_autenticado', 'sem sessão: 401');
select is(pg_temp.validar('c8330000-0000-4000-8000-0000000000ff', pg_temp.t('a'), '123456', 40), '401:nao_autenticado',
  'conta que não existe mais (anonimizada e apagada): 401');
select is(pg_temp.v('suspenso', '123456', 40), '403:sem_permissao:conta_suspensa', 'conta suspensa: 403 conta_suspensa');
select is(pg_temp.validar((select dono from ids), pg_temp.t('a'), '123456', 40), '422:perfil_incompativel',
  'conta de contratante: 422 perfil_incompativel (RN25)');
select is(pg_temp.validar(pg_temp.u('a'), null, '123456', 40), '422:campo_obrigatorio:turno_id', 'sem turno_id: 422');
select is(pg_temp.v('a', null, 40), '422:campo_obrigatorio:codigo', 'sem codigo: 422 campo_obrigatorio');
select is(pg_temp.v('a', '12345', 40), '422:campo_invalido:codigo', 'código de 5 dígitos: 422 campo_invalido');
select is(pg_temp.v('a', '12a456', 40), '422:campo_invalido:codigo', 'código com letra: 422 campo_invalido');
select is(pg_temp.v('a', '1234567', 40), '422:campo_invalido:codigo', 'código de 7 dígitos: 422 campo_invalido (o formato é exato)');
select is(pg_temp.v('a', '123456', -1), '422:campo_invalido:distancia_m', 'distância negativa: 422 campo_invalido');
select is(pg_temp.validar(pg_temp.u('a'), 'c8330000-0000-4000-8000-0000000000ee', '123456', 40), '404:nao_encontrado',
  'turno que não existe: 404');
select is(pg_temp.validar(pg_temp.u('sem_posicao'), pg_temp.t('a'), '123456', 40), '404:nao_encontrado',
  'turno de outro profissional: 404, como o que não existe');
select is(pg_temp.v('bloqueado', '123456', 40), '404:nao_encontrado', 'bloqueio entre o profissional e a casa: 404');
select is(pg_temp.v('a', '123456', 40), '403:sem_permissao:recurso_desligado', 'chave desligada no global: 403 recurso_desligado');
update privado.recurso set ligado = true where chave = 'checkin_por_codigo';
-- Ligada, a casa fora da lista passa pela chave (vale para todas, 20261112210000). Não se chama validar aqui:
-- com a chave ligada o código errado grava tentativa, e esta seção prova só o que NÃO grava nada.
select lives_ok($$select privado.exigir_recurso_para('checkin_por_codigo', 'c8330000-0000-4000-8000-000000000021')$$,
  'chave ligada e casa fora da lista: exigir_recurso_para não recusa (vale para todas, sem 403 recurso_desligado)');
select is((select count(*)::int from privado.checkin_codigo) + (select count(*)::int from privado.checkin_codigo_tentativa), 0,
  'as recusas antes do estado não gravam nada: nem contador, nem tentativa');
select pg_temp.ligar();

-- Etapa 1: com a chave ligada, renova aproximação a 40 m (<= raio_proximidade_m 50 m provisório) para permitir gerar
select pg_temp.checkin(n, 40) from unnest(array['a', 'sem_posicao', 'raio', 'erros', 'vencido', 'regra', 'cancelada', 'r2']) n;

-- ── As recusas do estado ─────────────────────────────────────────────────────
select is(pg_temp.v('sem_checkin', '123456', 40), '409:checkin_pendente', 'sem check-in: 409 checkin_pendente');
select is(pg_temp.v('verificado', '123456', 40), '409:checkin_ja_confirmado', 'presença já verificada: 409 checkin_ja_confirmado');
insert into privado.checkin_codigo (turno_id, codigo, gerado_em, expira_em)
values (pg_temp.t('fora'), '482913', privado.agora(), privado.agora() + interval '300 seconds');
select is(pg_temp.v('fora', '482913', 40), '422:fora_da_janela', 'fora da janela do check-in: 422 fora_da_janela');
select is(pg_temp.erros('fora') + pg_temp.tentativas('fora'), 0, 'fora da janela: não conta nem grava a tentativa');
update public.usuario set demonstracao = true where id = pg_temp.u('fora');
select is(pg_temp.v('fora', '482913', 40), '200:verificado', 'a conta de demonstração valida fora da janela (D9)');

-- ── O acerto, com posição ────────────────────────────────────────────────────
select pg_temp.gerar(n) from unnest(array['a', 'sem_posicao', 'raio', 'erros', 'vencido', 'regra', 'cancelada', 'r2']) n;
select ok(pg_temp.painel()->'checkins_pendentes' ? pg_temp.t('a')::text, 'antes da validação, o turno espera no painel');
-- Com a chave ligada e o código em vigor, o formato recusa do mesmo jeito e não conta (contrato :731, "Parâmetro nulo").
select is(pg_temp.v('a', null, 40) || ' ' || pg_temp.v('a', '1234567', 40) || ' ' || pg_temp.v('a', pg_temp.cod('a'), -1),
  '422:campo_obrigatorio:codigo 422:campo_invalido:codigo 422:campo_invalido:distancia_m',
  'com a chave ligada e o código em vigor: codigo nulo, fora do formato e distância negativa recusam com 422');
select is(pg_temp.erros('a') * 10 + pg_temp.tentativas('a'), 0, 'o formato e o nulo não contam como tentativa: nem contador, nem tentativa');
create temp table cod_a as select pg_temp.cod('a') as c,
  (select gerado_em from privado.checkin_codigo where turno_id = pg_temp.t('a')) as gerado_em,
  (select expira_em from privado.checkin_codigo where turno_id = pg_temp.t('a')) as expira_em;
create temp table r_a as select pg_temp.chamar(pg_temp.u('a'), pg_temp.t('a'), (select c from cod_a), 40) as r;
select is((select (r->>'status')::int from r_a), 200, 'código certo, em vigor, a 40 m: 200, sem response.status');
select is((select array_agg(k order by k) from r_a, jsonb_object_keys(r->'corpo') k),
  array['distancia_m', 'registrado_em', 'tipo', 'turno_id', 'verificacao'],
  'a resposta é o ResultadoRegistro, sem codigo_exigido e codigo_disponivel, que só saem no fazer_checkin');
-- Etapa 1: checkin_distancia_m é preservada no turno e devolvida na resposta
select results_eq(
  $$ select r->'corpo'->>'tipo', r->'corpo'->>'verificacao', (r->'corpo'->>'registrado_em')::timestamptz,
            jsonb_typeof(r->'corpo'->'distancia_m'), (r->'corpo'->>'turno_id')::uuid from r_a $$,
  $$ values ('codigo', 'verificado', '2027-01-11 21:30:00+00'::timestamptz, 'number', pg_temp.t('a')) $$,
  'Etapa 1: a resposta: tipo codigo, verificado, hora do check-in e distância preservada (number)');
select results_eq(
  $$ select checkin_tipo::text, verificacao::text, checkin_confirmado_em, checkin_distancia_m from public.turno where id = pg_temp.t('a') $$,
  $$ values ('codigo', 'verificado', '2027-01-11 21:30:00+00'::timestamptz, 40::integer) $$,
  'Etapa 1: o turno vira codigo e verificado, com checkin_confirmado_em e checkin_distancia_m preservado (40 m)');
select results_eq(
  $$ select c.codigo, c.gerado_em, c.expira_em, c.confianca_baixa, c.erros from privado.checkin_codigo c where c.turno_id = pg_temp.t('a') $$,
  $$ select null::text, gerado_em, expira_em, false, 0 from cod_a $$,
  'o valor sai do banco; a hora da geração e da validade ficam; com posição, sem confiança baixa');
select results_eq(
  $$ select em, resultado, faixa, codigo_gerado_em from privado.checkin_codigo_tentativa where turno_id = pg_temp.t('a') $$,
  $$ select '2027-01-11 21:30:00+00'::timestamptz, 'aceita', 'ate_100_m', gerado_em from cod_a $$,
  'uma tentativa aceita, na faixa até 100 m, com a hora em que o código foi gerado');
select is((select count(*)::int from public.notificacao n where n.referencia_id = pg_temp.t('a') and n.tipo = 'checkin'
            and n.usuario_id in ((select dono from ids), (select operador from ids))), 2,
  'os dois membros da casa recebem o aviso checkin');
select is((select array_agg(distinct k order by k) from public.notificacao n, jsonb_object_keys(n.payload) k
            where n.referencia_id = pg_temp.t('a') and n.tipo = 'checkin'), array['tipo', 'turno_id', 'vaga_id'],
  'o aviso leva só o tipo, o turno e a vaga, nunca o código');
select ok(not (pg_temp.painel()->'checkins_pendentes' ? pg_temp.t('a')::text), 'validado, o turno sai dos pendentes do painel');
select is(pg_temp.v('a', (select c from cod_a), 40), '409:checkin_ja_confirmado',
  'o código já usado: 409 checkin_ja_confirmado (leitura 7)');
select is(pg_temp.erros('a') * 10 + pg_temp.tentativas('a'), 1, 'o código já usado não conta nem grava outra tentativa');
-- 0.2.69: a confirmação manual de turno já verificado pelo código recusa 409 (a corrida é do PR7, em
-- scripts/corrida-checkin-codigo.sh; aqui, a ordem simples).
create function pg_temp.confirmar(turno uuid) returns text language plpgsql as $$
declare v_det text;
begin
  perform pg_temp.como('c8330000-0000-4000-8000-000000000001', format('select public.confirmar_checkin_manual(%L::uuid)', turno));
  return '200';
exception when sqlstate 'PGRST' then
  get stacked diagnostics v_det = pg_exception_detail;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return ((v_det::jsonb)->>'status') || ':' || (sqlerrm::jsonb->>'code');
end $$;
select is(pg_temp.confirmar(pg_temp.t('a')), '409:checkin_ja_confirmado',
  'a casa confirma à mão um turno já verificado pelo código: 409 checkin_ja_confirmado (0.2.69)');

-- ── O acerto sem posição: confiança baixa, que só sai na exportação ──────────
-- Etapa 1: sem localização (distancia_m nula) JAMAIS confirma presença no novo fluxo (recusa 422)
select is(pg_temp.v('sem_posicao', pg_temp.cod('sem_posicao'), null), '422:codigo_invalido',
  'Etapa 1: código certo sem posição: recusado com 422 codigo_invalido');
select results_eq(
  $$ select c.confianca_baixa, k.faixa, k.resultado from privado.checkin_codigo c
       join privado.checkin_codigo_tentativa k on k.turno_id = c.turno_id where c.turno_id = pg_temp.t('sem_posicao') $$,
  $$ values (false, 'sem_posicao', 'recusada') $$, 'Etapa 1: sem posição: tentativa recusada na faixa sem_posicao e confianca_baixa permanece false');
select ok(pg_temp.painel()::text !~ 'confianca', 'a confiança baixa não sai no painel da casa (critério 11)');
select ok(pg_temp.como(pg_temp.u('sem_posicao'), $$ select public.meus_turnos('2027-01-11 00:00:00+00', '2027-01-13 00:00:00+00', null) $$)::text
          !~ 'confianca', 'nem em meus_turnos do profissional');
select is((select count(*)::int from information_schema.columns
            where table_schema = 'public' and table_name = 'turno' and column_name ~ 'confianca'), 0,
  'nem no turno, que não tem coluna para ela');

-- ── O raio: lido a mais de 100 m, conta; a 100 m, vale ───────────────────────
create temp table r_raio as select pg_temp.chamar(pg_temp.u('raio'), pg_temp.t('raio'), pg_temp.cod('raio'), 101) as r;
select is((select (r->>'status')::int || ':' || (r->'corpo'->>'code') from r_raio), '422:codigo_invalido',
  'código certo lido a 101 m: 422 codigo_invalido (leitura 3)');
select is((select r->'corpo' from r_raio),
  '{"code": "codigo_invalido", "message": "codigo_invalido", "details": null, "hint": null}'::jsonb,
  'o envelope é o de public.erro, sem details: a recusa não diz o motivo');
select results_eq(
  $$ select k.resultado, k.faixa, k.codigo_gerado_em = c.gerado_em, c.erros, c.codigo is not null
       from privado.checkin_codigo_tentativa k join privado.checkin_codigo c on c.turno_id = k.turno_id
      where k.turno_id = pg_temp.t('raio') $$,
  $$ values ('recusada', 'acima_de_100_m', true, 1, true) $$,
  'a recusa grava: a tentativa recusada acima de 100 m, o contador em 1, e o código segue em vigor (D2)');
select is((select verificacao::text from public.turno where id = pg_temp.t('raio')), 'pendente', 'a recusa não verifica o turno');
-- Etapa 1: raio_validacao_m provisório é 50 m; leitura a 50 m valida (a borda do raio)
select is(pg_temp.v('raio', pg_temp.cod('raio'), 50), '200:verificado', 'Etapa 1: o mesmo código lido a 50 m: vale (a borda do raio provisório)');

-- ── O raio da regra, e o padrão de 100 m sem ela (R1) ────────────────────────
update privado.regra_checkin_codigo set raio_validacao_m = 50;
select is(pg_temp.v('regra', pg_temp.cod('regra'), 60), '422:codigo_invalido', 'com o raio da regra em 50 m, a leitura a 60 m conta');
select is((select faixa || ':' || resultado from privado.checkin_codigo_tentativa where turno_id = pg_temp.t('regra')),
  'ate_100_m:recusada', 'a faixa é a do contrato (até 100 m), e a tentativa, recusada');
delete from privado.regra_checkin_codigo;
-- Etapa 1: sem a linha da regra, o raio fallback é 50 m provisório (coalesce)
select is(pg_temp.v('regra', pg_temp.cod('regra'), 50), '200:verificado', 'Etapa 1: sem a linha da regra, o raio é 50 m (coalesce provisório)');
insert into privado.regra_checkin_codigo default values;

-- ── O contador: 3 erradas bloqueiam; no bloqueio não conta ───────────────────
select is(pg_temp.v('sem_codigo', '123456', 40), '422:codigo_invalido', 'sem código gerado, qualquer leitura conta como errada');
select results_eq(
  $$ select c.erros, k.codigo_gerado_em from privado.checkin_codigo c join privado.checkin_codigo_tentativa k using (turno_id)
      where c.turno_id = pg_temp.t('sem_codigo') $$,
  $$ values (1, null::timestamptz) $$, 'sem código em vigor, a tentativa não tem a hora da geração');
create temp table cod_erros as select pg_temp.cod('erros') as c,
  (select gerado_em from privado.checkin_codigo where turno_id = pg_temp.t('erros')) as gerado_em;
select is(pg_temp.v('erros', pg_temp.errado('erros'), 40), '422:codigo_invalido', '1ª errada: 422 codigo_invalido');
select results_eq(
  $$ select resultado, faixa, codigo_gerado_em from privado.checkin_codigo_tentativa where turno_id = pg_temp.t('erros') $$,
  $$ select 'recusada', 'ate_100_m', gerado_em from cod_erros $$,
  'a errada com código em vigor grava a hora em que ele foi gerado');
select is(pg_temp.v('erros', pg_temp.errado('erros'), 40), '422:codigo_invalido', '2ª errada: 422 codigo_invalido');
select is(pg_temp.v('erros', pg_temp.errado('erros'), 40), '409:codigo_bloqueado:temporario',
  '3ª errada: 409 codigo_bloqueado (temporario), gravada');
select results_eq(
  $$ select c.erros, c.bloqueado_ate, (select count(*)::int from privado.checkin_codigo_tentativa k where k.turno_id = c.turno_id)
       from privado.checkin_codigo c where c.turno_id = pg_temp.t('erros') $$,
  $$ values (3, '2027-01-11 21:35:00+00'::timestamptz, 3) $$,
  'a 3ª grava o bloqueio de 300 s da regra e as 3 tentativas');
select is((select r->'corpo' from (select pg_temp.chamar(pg_temp.u('erros'), pg_temp.t('erros'), (select c from cod_erros), 40) as r) x),
  '{"code": "codigo_bloqueado", "message": "codigo_bloqueado", "details": "temporario", "hint": null}'::jsonb,
  'no bloqueio, até o código certo recebe 409 codigo_bloqueado (temporario)');
select is(pg_temp.erros('erros') * 10 + pg_temp.tentativas('erros'), 33, 'no bloqueio, a leitura não conta nem grava');
select is((select verificacao::text from public.turno where id = pg_temp.t('erros')), 'pendente', 'no bloqueio, o turno segue pendente');

-- ── A posição cancelada não ganha presença ───────────────────────────────────
update public.posicao set estado = 'cancelada'
 where id = (select posicao_id from public.turno where id = pg_temp.t('cancelada'));
update public.turno set verificacao = 'nao_verificado' where id = pg_temp.t('cancelada');
select is(pg_temp.v('cancelada', pg_temp.cod('cancelada'), 40), '409:vaga_encerrada:posicao_cancelada',
  'posição cancelada: o código certo não verifica (409 vaga_encerrada)');
select is(pg_temp.tentativas('cancelada') * 10 + (pg_temp.cod('cancelada') is not null)::int, 1,
  'a recusa desfaz tudo: nenhuma tentativa, e o código segue gravado');

-- ── O vencido: vale pelo expira_em, nunca pela presença do valor (D4) ───────
create temp table cod_vencido as select pg_temp.cod('vencido') as c;
select set_config('frila.agora', '2027-01-11 21:35:00+00', true);   -- 300 s depois de gerar
select is(pg_temp.v('vencido', (select c from cod_vencido), 40), '422:codigo_invalido',
  'aos 300 s, o código certo venceu: 422 codigo_invalido');
select results_eq(
  $$ select c.codigo, k.codigo_gerado_em from privado.checkin_codigo c join privado.checkin_codigo_tentativa k using (turno_id)
      where c.turno_id = pg_temp.t('vencido') $$,
  $$ select c, null::timestamptz from cod_vencido $$,
  'o valor vencido segue no banco até o job, e a tentativa não o conta como em vigor');
select pg_temp.gerar('vencido');
select set_config('frila.agora', '2027-01-11 21:39:59.999+00', true);   -- 299,999 s depois de gerar o novo
select is(pg_temp.v('vencido', pg_temp.cod('vencido'), 40), '200:verificado', 'aos 299,999 s, o código novo ainda vale (a borda)');

-- ── Depois do bloqueio: a 4ª e a 5ª contam; a 6ª encerra ─────────────────────
select pg_temp.gerar('erros');
select is(pg_temp.v('erros', pg_temp.errado('erros'), 40), '422:codigo_invalido', 'passado o bloqueio, a 4ª errada conta: 422');
select is(pg_temp.v('erros', pg_temp.errado('erros'), 40), '422:codigo_invalido', '5ª errada: 422');
select is(pg_temp.v('erros', pg_temp.errado('erros'), 40), '409:codigo_bloqueado:encerrado',
  '6ª errada: 409 codigo_bloqueado (encerrado), gravada');
select results_eq(
  $$ select c.erros, c.encerrado_em from privado.checkin_codigo c where c.turno_id = pg_temp.t('erros') $$,
  $$ values (6, '2027-01-11 21:39:59.999+00'::timestamptz) $$, 'a 6ª grava os 6 erros e o encerramento');
select is(pg_temp.v('erros', pg_temp.cod('erros'), 40), '409:codigo_bloqueado:encerrado',
  'encerrado, até o código certo recebe 409 codigo_bloqueado (encerrado)');
select is(pg_temp.erros('erros') * 10 + pg_temp.tentativas('erros'), 66, 'encerrado, a leitura não conta nem grava');
select is((select count(*)::int from privado.checkin_codigo_tentativa where turno_id = pg_temp.t('erros') and resultado = 'recusada'), 6,
  'as 6 tentativas gravadas são recusadas');

-- ── O código nunca sai num erro de restrição (R2) ────────────────────────────
-- O erro como o Postgres o entrega: SQLSTATE, mensagem e DETAIL.
create function pg_temp.erro_cru(codigo text) returns text[] language plpgsql as $$
declare v_estado text; v_msg text; v_det text;
begin
  perform pg_temp.como(pg_temp.u('r2'), format('select public.validar_codigo_checkin(%L::uuid, %L, 40)', pg_temp.t('r2'), codigo));
  return array['ok'];
exception when others then
  get stacked diagnostics v_estado = returned_sqlstate, v_msg = message_text, v_det = pg_exception_detail;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return array[v_estado, v_msg, coalesce(v_det, '')];
end $$;
select pg_temp.gerar('r2');
-- check_violation ao contar a errada: o DETAIL do Postgres traria a linha com o código em vigor.
alter table privado.checkin_codigo add constraint zz_833_sem_erros check (erros = 0) not valid;
create temp table e1 as select pg_temp.erro_cru(pg_temp.errado('r2')) as e;
select is((select e[1] from e1), '23514', 'check_violation ao contar a errada: o mesmo SQLSTATE');
select is((select e[3] from e1), '', 'check_violation ao contar a errada: sai sem o DETAIL, que traria o código');
select ok((select e[2] !~ '[0-9]{6}' and e[2] ~ 'zz_833_sem_erros' from e1),
  'check_violation ao contar a errada: a mensagem nomeia a restrição e não traz o código');
alter table privado.checkin_codigo drop constraint zz_833_sem_erros;
-- not_null_violation, também da classe 23: um gatilho anula uma coluna obrigatória na escrita.
create function privado.zz_833_anula() returns trigger language plpgsql as $$ begin new.erros := null; return new; end $$;
create trigger zz_833_anula before update on privado.checkin_codigo for each row execute function privado.zz_833_anula();
create temp table e2 as select pg_temp.erro_cru(pg_temp.errado('r2')) as e;
select is((select e[1] || ':' || e[3] from e2), '23502:', 'not_null_violation ao contar a errada: o mesmo SQLSTATE, sem o DETAIL');
select ok((select e[2] !~ '[0-9]{6}' from e2), 'not_null_violation ao contar a errada: a mensagem não traz o código');
create temp table e3 as select pg_temp.erro_cru(pg_temp.cod('r2')) as e;
select is((select e[1] || ':' || e[3] from e3), '23502:', 'not_null_violation no acerto: o mesmo SQLSTATE, sem o DETAIL');
drop trigger zz_833_anula on privado.checkin_codigo;
select is(pg_temp.erros('r2') * 10 + pg_temp.tentativas('r2') + (select count(*)::int from public.turno
            where id = pg_temp.t('r2') and verificacao = 'verificado'), 0,
  'o erro de restrição desfaz a leitura: nem contador, nem tentativa, nem presença');

select * from finish();
rollback;
