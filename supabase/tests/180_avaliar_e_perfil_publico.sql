-- `avaliar` e `perfil_publico`: a reputação com denominador.
--
-- Uma pergunta só, sim ou não, nos dois sentidos (RN07). O perfil público mostra
-- "X de Y" e a taxa de comparecimento com o total de turnos considerados (RN08, RF16).
--
--   RN07  só depois do fim previsto, e só com presença verificada — pelo relógio do
--         produto, na RPC e no gatilho de `avaliacao`, para nenhum caminho escapar
--   RN08  positivas e total da parte avaliada; perfil novo com total 0 e taxa nula
--   RN10  o perfil público não traz telefone, e-mail, nascimento nem ponto base
--
-- Cada recusa é conferida nos dois eixos, como em 080 e 090: o `sqlstate` `PGRST` e o
-- envelope inteiro, que fixa `code` e `details`.

begin;
select plan(43);

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

create function pg_temp.avaliar(conta uuid, turno uuid, resposta boolean) returns jsonb
language sql as $$
  select pg_temp.como(conta, format('select public.avaliar(%L::uuid, %L::boolean)', turno, resposta))
$$;

create function pg_temp.perfil(conta uuid, alvo uuid) returns jsonb
language sql as $$
  select pg_temp.como(conta, format('select public.perfil_publico(%L::uuid)', alvo))
$$;

-- ── O cenário ──────────────────────────────────────────────────────────────────
--
--   Ana   profissional, garçom · T1 verificado (sáb 19h–23h), T2 sem check-in
--         (sex 19h–23h), T3 verificado (qua 19h–23h), uma falta (ter)
--   Beto  profissional novo, sem histórico
--   Caio  profissional de fora, depois com a conta encerrada
--   Zé    administrador do Bar do Zé · Olga, operadora do mesmo bar
--   Rita  administradora do Buffet da Rita, de fora

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('f1000000-0000-4000-8000-000000000001','profissional','Ana',  '+5561988880001','ana@aval.test', '1995-03-07','2026-09-22', now()),
  ('f1000000-0000-4000-8000-000000000002','profissional','Beto', '+5561988880002','beto@aval.test','1996-04-08','2026-09-22', now()),
  ('f1000000-0000-4000-8000-000000000003','profissional','Caio', '+5561988880003','caio@aval.test','1997-05-09','2026-09-22', now()),
  ('f2000000-0000-4000-8000-000000000001','contratante', 'Zé',   '+5561988880011','ze@aval.test',  '1980-01-01','2026-09-22', now()),
  ('f2000000-0000-4000-8000-000000000002','contratante', 'Olga', '+5561988880012','olga@aval.test','1981-01-01','2026-09-22', now()),
  ('f2000000-0000-4000-8000-000000000003','contratante', 'Rita', '+5561988880013','rita@aval.test','1982-01-01','2026-09-22', now());

insert into public.profissional (id, usuario_id, ponto_base) values
  ('f3000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','POINT(-47.8811 -15.7911)'::extensions.geography),
  ('f3000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000002','POINT(-47.8812 -15.7912)'::extensions.geography),
  ('f3000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000003','POINT(-47.8813 -15.7913)'::extensions.geography);

insert into public.profissional_funcao (profissional_id, funcao_id)
select 'f3000000-0000-4000-8000-000000000001', id from public.funcao where nome = 'garçom';

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('f4000000-0000-4000-8000-000000000001','Bar do Zé','19131905000129','food_service','CLN 201',
   'POINT(-47.8822 -15.7942)'::extensions.geography),
  ('f4000000-0000-4000-8000-000000000002','Buffet da Rita','45223011000179','evento','SIA',
   'POINT(-47.9 -15.8)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('f2000000-0000-4000-8000-000000000001','f4000000-0000-4000-8000-000000000001','administrador'),
  ('f2000000-0000-4000-8000-000000000002','f4000000-0000-4000-8000-000000000001','operador'),
  ('f2000000-0000-4000-8000-000000000003','f4000000-0000-4000-8000-000000000002','administrador');

-- Uma vaga de uma posição, já confirmada para a Ana (ou cancelada com falta).
create function pg_temp.turno_da_ana(pos uuid, inicio timestamptz, fim timestamptz, falta boolean)
returns void language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em,
                           publicado_por)
  values (v, 'f4000000-0000-4000-8000-000000000001',
          (select f.id from public.funcao f where f.nome = 'garçom'),
          inicio, fim, 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1, true, false, false, 'Maître Zé', 'urgencia', gen_random_uuid(),
          inicio - interval '2 days', 'f2000000-0000-4000-8000-000000000001');
  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em)
  values (pos, v, case when falta then 'cancelada' else 'confirmada' end::public.estado_posicao,
          'f3000000-0000-4000-8000-000000000001', inicio - interval '1 day', falta, inicio, fim);
end $$;

select pg_temp.turno_da_ana('f6000000-0000-4000-8000-000000000001','2026-10-10 19:00+00','2026-10-10 23:00+00', false);
select pg_temp.turno_da_ana('f6000000-0000-4000-8000-000000000002','2026-10-09 19:00+00','2026-10-09 23:00+00', false);
select pg_temp.turno_da_ana('f6000000-0000-4000-8000-000000000003','2026-10-07 19:00+00','2026-10-07 23:00+00', false);
select pg_temp.turno_da_ana('f6000000-0000-4000-8000-000000000004','2026-10-06 19:00+00','2026-10-06 23:00+00', true);

-- O check-in (#79) ainda não existe: a presença verificada é escrita direto.
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
                          verificacao, valor_acordado_centavos) values
  ('f7000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001',
   '2026-10-10 19:02+00','geolocalizado', 40, 'verificado', 12000),
  ('f7000000-0000-4000-8000-000000000002','f6000000-0000-4000-8000-000000000002',
   null, null, null, 'pendente', 12000),
  ('f7000000-0000-4000-8000-000000000003','f6000000-0000-4000-8000-000000000003',
   '2026-10-07 19:05+00','geolocalizado', 80, 'verificado', 12000);

-- `fazer_checkin`, `confirmar_checkin_manual` e o cancelamento com falta chamam esta
-- função depois de escrever; como o cenário escreve direto, chama-a aqui.
select privado.recalcular_comparecimento('f3000000-0000-4000-8000-000000000001');

-- O relógio: marcador de teste escrito aqui dentro, e levado pelo rollback. Todas as
-- datas do cenário estão no futuro do `now()` real: se alguma regra olhar `now()` em
-- vez de `privado.agora()`, o caminho feliz deste arquivo fica vermelho.
insert into privado.ambiente (id, eh_teste) values (true, true);

-- ── Os contadores batem com as avaliações ─────────────────────────────────────
-- Antes de qualquer escrita deste arquivo: o banco já traz as avaliações de
-- `cenarios.sql`, e um contador escrito à mão por cima do gatilho contaria cada uma
-- duas vezes.
select is(
  (select count(*)::int from (
     select p.aval_positivas, p.aval_total,
            (select count(*) filter (where a.resposta) from public.avaliacao a
              where a.alvo_tipo = 'profissional' and a.alvo_id = p.id) as pos,
            (select count(*) from public.avaliacao a
              where a.alvo_tipo = 'profissional' and a.alvo_id = p.id) as tot
       from public.profissional p
     union all
     select e.aval_positivas, e.aval_total,
            (select count(*) filter (where a.resposta) from public.avaliacao a
              where a.alvo_tipo = 'estabelecimento' and a.alvo_id = e.id),
            (select count(*) from public.avaliacao a
              where a.alvo_tipo = 'estabelecimento' and a.alvo_id = e.id)
       from public.estabelecimento e) x
    where aval_positivas <> pos or aval_total <> tot),
  0,
  'RN08: positivas e total de cada parte batem com as avaliações gravadas');

-- ── Quem pode avaliar ──────────────────────────────────────────────────────────
set local frila.agora = '2026-10-11 01:00:00+00';

select throws_ok(
  $$ select public.avaliar('f7000000-0000-4000-8000-000000000001', true) $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não se avalia');

select throws_ok(
  $$ select pg_temp.avaliar('f2000000-0000-4000-8000-000000000003','f7000000-0000-4000-8000-000000000001', true) $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'RN07: só as partes do turno avaliam — contratante de outro estabelecimento não');

select throws_ok(
  $$ select pg_temp.avaliar('f1000000-0000-4000-8000-000000000002','f7000000-0000-4000-8000-000000000001', true) $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'RN07: profissional que não trabalhou o turno também não');

select throws_ok(
  $$ select pg_temp.avaliar('f2000000-0000-4000-8000-000000000001','f7000000-0000-4000-8000-0000000000ff', true) $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'turno inexistente recebe a mesma recusa de turno alheio — a diferença diria que ele existe');

-- ── RN07: antes do fim, e sem presença ─────────────────────────────────────────
set local frila.agora = '2026-10-10 22:59:59+00';

select throws_ok(
  $$ select pg_temp.avaliar('f2000000-0000-4000-8000-000000000001','f7000000-0000-4000-8000-000000000001', true) $$,
  'PGRST',
  '{"code" : "avaliacao_indisponivel", "message" : "avaliacao_indisponivel", "details" : "antes_do_fim", "hint" : null}',
  'RN07: um segundo antes do fim previsto a avaliação é recusada com details = antes_do_fim');

select throws_ok(
  $$ select pg_temp.avaliar('f1000000-0000-4000-8000-000000000001','f7000000-0000-4000-8000-000000000001', true) $$,
  'PGRST',
  '{"code" : "avaliacao_indisponivel", "message" : "avaliacao_indisponivel", "details" : "antes_do_fim", "hint" : null}',
  'RN07: vale igual para o lado do profissional');

set local frila.agora = '2026-10-11 01:00:00+00';

select throws_ok(
  $$ select pg_temp.avaliar('f2000000-0000-4000-8000-000000000001','f7000000-0000-4000-8000-000000000002', true) $$,
  'PGRST',
  '{"code" : "avaliacao_indisponivel", "message" : "avaliacao_indisponivel", "details" : "sem_presenca_verificada", "hint" : null}',
  'RN07: turno não verificado não aceita avaliação (details = sem_presenca_verificada)');

select throws_ok(
  $$ select pg_temp.avaliar('f1000000-0000-4000-8000-000000000001','f7000000-0000-4000-8000-000000000002', false) $$,
  'PGRST',
  '{"code" : "avaliacao_indisponivel", "message" : "avaliacao_indisponivel", "details" : "sem_presenca_verificada", "hint" : null}',
  'RN07: nem do lado do profissional');

select is(
  (select count(*)::int from public.avaliacao
    where turno_id::text like 'f7000000-%'),
  0,
  'RN07: nenhuma recusa deixou avaliação gravada');

-- ── O caminho feliz ────────────────────────────────────────────────────────────
-- A leitura antes, para medir a soma depois.
select is(
  pg_temp.perfil('f2000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001')->'reputacao'->'total',
  '0'::jsonb,
  'RN08: antes da avaliação, a Ana tem total 0');

select is(
  pg_temp.avaliar('f2000000-0000-4000-8000-000000000001','f7000000-0000-4000-8000-000000000001', true)
    - 'criada_em',
  '{"turno_id":"f7000000-0000-4000-8000-000000000001","resposta":true}'::jsonb,
  'RN07: o contratante responde sim, e recebe a Avaliacao do contrato');

select is(
  (select jsonb_build_array(r->'positivas', r->'total')
     from (select pg_temp.perfil('f1000000-0000-4000-8000-000000000002',
                                 'f3000000-0000-4000-8000-000000000001')->'reputacao' r) x),
  '[1, 1]'::jsonb,
  'RN08: depois de um sim, o perfil_publico da Ana soma 1 em positivas e 1 em total');

select is(
  (select jsonb_build_array(aval_positivas, aval_total) from public.estabelecimento
    where id = 'f4000000-0000-4000-8000-000000000001'),
  '[0, 0]'::jsonb,
  'RN08: e só a parte avaliada soma — o estabelecimento que avaliou não muda');

-- Idempotência pela chave natural (turno, autor).
select is(
  pg_temp.avaliar('f2000000-0000-4000-8000-000000000001','f7000000-0000-4000-8000-000000000001', true),
  (select jsonb_build_object('turno_id', turno_id, 'resposta', resposta, 'criada_em', criada_em)
     from public.avaliacao where turno_id = 'f7000000-0000-4000-8000-000000000001'),
  'reenviar a mesma resposta devolve a avaliação gravada, com o mesmo criada_em');

select is(
  (select aval_total from public.profissional where id = 'f3000000-0000-4000-8000-000000000001'),
  1,
  'RN08: e o reenvio não conta duas vezes');

select throws_ok(
  $$ select pg_temp.avaliar('f2000000-0000-4000-8000-000000000001','f7000000-0000-4000-8000-000000000001', false) $$,
  'PGRST',
  '{"code" : "avaliacao_ja_registrada", "message" : "avaliacao_ja_registrada", "details" : null, "hint" : null}',
  'RN07: mudar a resposta devolve 409 avaliacao_ja_registrada');

-- Um lado avalia uma vez: a operadora do mesmo bar não soma um segundo voto.
select throws_ok(
  $$ select pg_temp.avaliar('f2000000-0000-4000-8000-000000000002','f7000000-0000-4000-8000-000000000001', false) $$,
  'PGRST',
  '{"code" : "avaliacao_ja_registrada", "message" : "avaliacao_ja_registrada", "details" : null, "hint" : null}',
  'RN08: outro membro do mesmo estabelecimento, com outra resposta, recebe o 409');

select is(
  pg_temp.avaliar('f2000000-0000-4000-8000-000000000002','f7000000-0000-4000-8000-000000000001', true)->>'resposta',
  'true',
  'e, com a mesma resposta, recebe a avaliação do seu lado já gravada');

select is(
  (select jsonb_build_array(aval_positivas, aval_total, (select count(*) from public.avaliacao
                                                 where turno_id = 'f7000000-0000-4000-8000-000000000001'
                                                   and alvo_tipo = 'profissional'))
     from public.profissional where id = 'f3000000-0000-4000-8000-000000000001'),
  '[1, 1, 1]'::jsonb,
  'RN08: um turno, um voto de cada lado — o total da Ana continua 1');

select is(
  (select jsonb_build_array(
            privado.pode_avaliar('f7000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000002'),
            privado.pode_avaliar('f7000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001'))),
  '[false, true]'::jsonb,
  'pode_avaliar é por lado, como no contrato: a operadora já não vê o botão, a Ana ainda vê');

-- O outro lado: a Ana responde não sobre o bar.
select is(
  pg_temp.avaliar('f1000000-0000-4000-8000-000000000001','f7000000-0000-4000-8000-000000000001', false)->>'resposta',
  'false',
  'RN07: o profissional avalia o estabelecimento, no mesmo turno');

select is(
  pg_temp.perfil('f1000000-0000-4000-8000-000000000001','f4000000-0000-4000-8000-000000000001')
    - 'id',
  '{"tipo":"estabelecimento","nome":"Bar do Zé",
    "reputacao":{"positivas":0,"total":1,"taxa_comparecimento":null,
                 "turnos_considerados":0,"turnos_realizados":0}}'::jsonb,
  'RN08: o estabelecimento fica com 0 de 1, sem funções e sem taxa, que é só de profissional');

-- ── O gatilho: o mesmo portão para quem escreve direto na tabela ───────────────
set local frila.agora = '2026-10-07 22:59:59+00';

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     values ('f7000000-0000-4000-8000-000000000003','f2000000-0000-4000-8000-000000000001',
             'profissional','f3000000-0000-4000-8000-000000000001', true) $$,
  'PGRST',
  '{"code" : "avaliacao_indisponivel", "message" : "avaliacao_indisponivel", "details" : "antes_do_fim", "hint" : null}',
  'RN07: o gatilho de avaliacao recusa antes do fim, pelo relógio do produto');

set local frila.agora = '2026-10-11 01:00:00+00';

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     values ('f7000000-0000-4000-8000-000000000002','f2000000-0000-4000-8000-000000000001',
             'profissional','f3000000-0000-4000-8000-000000000001', true) $$,
  'PGRST',
  '{"code" : "avaliacao_indisponivel", "message" : "avaliacao_indisponivel", "details" : "sem_presenca_verificada", "hint" : null}',
  'RN07: o gatilho de avaliacao recusa turno não verificado');

set local frila.agora = '2026-10-07 23:00:00+00';

-- No `now()` real, em setembro, este turno ainda não aconteceu. Só passa se o gatilho usar
-- o relógio do produto.
select lives_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     values ('f7000000-0000-4000-8000-000000000003','f2000000-0000-4000-8000-000000000001',
             'profissional','f3000000-0000-4000-8000-000000000001', false) $$,
  'RN07: no instante do fim previsto o gatilho libera, pelo relógio do produto e não pelo now()');

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     values ('f7000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000001',
             'estabelecimento','f4000000-0000-4000-8000-000000000002', true) $$,
  '23514',
  null,
  'o alvo tem que ser a outra parte do turno — o Buffet da Rita não estava lá');

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     values ('f7000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000003',
             'estabelecimento','f4000000-0000-4000-8000-000000000001', true) $$,
  '23514',
  null,
  'e o autor tem que ser uma das partes — o Caio não trabalhou esse turno');

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     values ('f7000000-0000-4000-8000-000000000003','f2000000-0000-4000-8000-000000000002',
             'profissional','f3000000-0000-4000-8000-000000000001', false) $$,
  '23505',
  null,
  'RN08: um voto por lado também na tabela — a operadora não avalia de novo o que o Zé avaliou');

select is(
  (select jsonb_build_array(aval_positivas, aval_total)
     from public.profissional where id = 'f3000000-0000-4000-8000-000000000001'),
  '[1, 2]'::jsonb,
  'RN08: a escrita direta também soma na parte avaliada — 1 de 2, sem caminho que escape');

-- ── perfil_publico ─────────────────────────────────────────────────────────────
set local frila.agora = '2026-10-11 01:00:00+00';

select throws_ok(
  $$ select public.perfil_publico('f3000000-0000-4000-8000-000000000001') $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não há perfil público');

select throws_ok(
  $$ select pg_temp.perfil('f2000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-0000000000ff') $$,
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'id que não é profissional nem estabelecimento dá 404');

-- Ana: T1 e T3 verificados, uma falta; T2, sem verificação, fica fora das duas contas.
select is(
  pg_temp.perfil('f2000000-0000-4000-8000-000000000003','f3000000-0000-4000-8000-000000000001'),
  '{"id":"f3000000-0000-4000-8000-000000000001","tipo":"profissional","nome":"Ana",
    "funcoes":["garçom"],
    "reputacao":{"positivas":1,"total":2,"taxa_comparecimento":0.667,
                 "turnos_considerados":3,"turnos_realizados":2}}'::jsonb,
  'RN08: 1 de 2, 2 turnos realizados e taxa 2 ÷ 3 — verificados sobre verificados mais faltas');

select is(
  pg_temp.perfil('f2000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000002'),
  '{"id":"f3000000-0000-4000-8000-000000000002","tipo":"profissional","nome":"Beto","funcoes":[],
    "reputacao":{"positivas":0,"total":0,"taxa_comparecimento":null,
                 "turnos_considerados":0,"turnos_realizados":0}}'::jsonb,
  'RF16: perfil novo devolve total 0 e taxa nula — a tela mostra "Sem histórico", nunca nota zero');

-- RN10: nenhum dado de contato, nem o que chega perto do endereço.
create temp table perfis as
  select pg_temp.perfil('f2000000-0000-4000-8000-000000000003', x) as j
    from unnest(array['f3000000-0000-4000-8000-000000000001',
                      'f3000000-0000-4000-8000-000000000002',
                      'f4000000-0000-4000-8000-000000000001']::uuid[]) x;

select is(
  (select count(*)::int from perfis
    where j::text ~* '(\+55619888800|@aval\.test|1995-03-07|1996-04-08|ponto|telefone|email|e-mail|nascimento|latitude|longitude|documento|19131905000129|-47\.88|-15\.79)'),
  0,
  'RN10: o perfil público nunca traz telefone, e-mail, nascimento, ponto base ou documento');

select is(
  (select array_agg(distinct k order by k) from perfis, jsonb_object_keys(j) k),
  array['funcoes','id','nome','reputacao','tipo'],
  'RN10: as chaves são só as do PerfilPublico do contrato');

select is(
  (select array_agg(distinct k order by k) from perfis, jsonb_object_keys(j->'reputacao') k),
  array['positivas','taxa_comparecimento','total','turnos_considerados','turnos_realizados'],
  'RN07: a reputação é o par e a taxa — não existe média, nem campo para ela');

-- RF25: a conta encerrada mantém o histórico e perde o nome.
update public.usuario
   set estado = 'anonimizada', anonimizado_em = now(), nome = 'Caio', email = null, telefone = null
 where id = 'f1000000-0000-4000-8000-000000000003';

select is(
  pg_temp.perfil('f2000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000003')->>'nome',
  'Conta encerrada',
  'RF25: a conta anonimizada aparece como "Conta encerrada"');

-- ── Uma auxiliar só para a reputação ───────────────────────────────────────────
-- O painel e o perfil público contam a mesma coisa pelo mesmo caminho.
select is(
  (select x->'profissional'
     from jsonb_array_elements(pg_temp.como('f2000000-0000-4000-8000-000000000001',
            $x$ select public.painel_estabelecimento('f4000000-0000-4000-8000-000000000001'::uuid,
                 '2026-10-10 00:00+00'::timestamptz, '2026-10-11 00:00+00'::timestamptz) $x$)->'vagas') v,
          jsonb_array_elements(v->'posicoes') x
    where x->>'id' = 'f6000000-0000-4000-8000-000000000001'),
  pg_temp.perfil('f2000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001'),
  'o painel mostra a Ana exatamente como o perfil_publico — a mesma auxiliar, a mesma conta');

-- ── Sem política de escrita ────────────────────────────────────────────────────
select throws_ok(
  $$ select pg_temp.como('f2000000-0000-4000-8000-000000000001',
       $x$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
           values ('f7000000-0000-4000-8000-000000000003','f2000000-0000-4000-8000-000000000001',
                   'profissional','f3000000-0000-4000-8000-000000000001', true)
           returning null::jsonb $x$) $$,
  '42501',
  null,
  'o app não escreve em avaliacao: avalia pela RPC');

select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('avaliar','perfil_publico')
      and has_function_privilege('anon', p.oid, 'execute')),
  null,
  'anon não executa avaliar nem perfil_publico');

select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('avaliar','perfil_publico')
      and has_function_privilege('authenticated', p.oid, 'execute')),
  array['avaliar','perfil_publico'],
  'authenticated executa as duas');

select is(
  (select p.provolatile::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'perfil_publico'),
  'v',
  'perfil_publico chama public.erro, que é volátil — e não escreve, para responder por GET');

select * from finish();
rollback;
