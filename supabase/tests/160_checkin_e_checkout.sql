-- `fazer_checkin`, `fazer_checkout` e `confirmar_checkin_manual`: a prova de presença.
--
-- RN22 tem três desfechos, e o de baixo é o que o produto mais teme: o turno que
-- aconteceu e não tem prova. Os três estão aqui, e o arquivo inteiro depende do relógio
-- do produto — sem ele, testar a janela do registro exigiria esperar o turno começar.
--
--   até 200 m          geolocalizado, presença verificada na hora
--   acima, ou sem GPS  manual, pendente até a casa confirmar
--   ninguém confirma   nao_verificado, e não conta a favor nem contra na taxa
--
-- Ids próprios, começando em `af000000`.

begin;
select plan(26);

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

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

select pg_temp.autenticar('af000000-0000-4000-8000-0000000000d1','dona@presenca.test');
select pg_temp.autenticar('af000000-0000-4000-8000-0000000000e1','e1@presenca.test');
select pg_temp.autenticar('af000000-0000-4000-8000-0000000000e2','e2@presenca.test');

select pg_temp.como('af000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona da Presença','+5561944440001','1980-01-01','2026-09-22') $$);
select pg_temp.como('af000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Presença Um','+5561944440011','1995-01-01','2026-09-22') $$);
select pg_temp.como('af000000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Presença Dois','+5561944440012','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create function pg_temp.perfil(conta uuid) returns void
language plpgsql as $corpo$
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, (select garcom from fn)));
end $corpo$;

select pg_temp.perfil('af000000-0000-4000-8000-0000000000e1');
select pg_temp.perfil('af000000-0000-4000-8000-0000000000e2');

create temp table casa as
  select (pg_temp.como('af000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa da Presença','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create temp table quando as
  select (privado.agora() + interval '2 days')         as ini,
         (privado.agora() + interval '2 days 6 hours') as fim;

create function pg_temp.publicar(chave uuid, dias int default 0) returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como('af000000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 406',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, 'Seu Zé', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn),
    (select ini + (dias || ' days')::interval from quando),
    (select fim + (dias || ' days')::interval from quando), chave))->>'vaga_id')::uuid;
end $corpo$;

create temp table t as
  select (pg_temp.como('af000000-0000-4000-8000-0000000000e1',
            format($$ select public.candidatar(%L) $$,
                   pg_temp.publicar('af000000-0000-4000-8000-000000000001')))->>'turno_id')::uuid as perto,
         (pg_temp.como('af000000-0000-4000-8000-0000000000e2',
            format($$ select public.candidatar(%L) $$,
                   pg_temp.publicar('af000000-0000-4000-8000-000000000002')))->>'turno_id')::uuid as longe;

-- O turno que nunca terá check-in, para o caso do check-out sem começo. Nasce aqui,
-- junto dos outros: publicar e candidatar exigem início no futuro, e mais abaixo o
-- relógio do produto já estará depois dele.
create temp table t3 as
  select (pg_temp.como('af000000-0000-4000-8000-0000000000e1',
            format($$ select public.candidatar(%L) $$,
                   pg_temp.publicar('af000000-0000-4000-8000-000000000003', 1)))->>'turno_id')::uuid as id;

-- ── O que não existe, e não deve existir ──────────────────────────────────────
--
-- A decisão de RN22 é que o banco guarda a **distância** medida no toque, nunca a
-- coordenada. Uma coluna de coordenada em `turno` seria o rastreamento contínuo
-- entrando pela porta dos fundos, e ninguém notaria até o primeiro pedido de dados.
select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public' and table_name = 'turno'
      and (column_name like '%ponto%' or column_name like '%latitude%'
           or column_name like '%longitude%' or column_name like '%coordenada%')),
  0,
  'RN22: não existe coluna de coordenada do profissional no turno');

-- ── Sem sessão, e do lado errado ──────────────────────────────────────────────
select throws_ok(
  format($$ select public.fazer_checkin(%L, 100, now()) $$, (select perto from t)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não há check-in');

select throws_ok(
  format($$ select pg_temp.como('af000000-0000-4000-8000-0000000000e2',
       $x$ select public.fazer_checkin(%L, 100, now()) $x$) $$, (select perto from t)),
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'turno de outra pessoa é 404 — um 403 diria que ele existe');

-- ── A janela ──────────────────────────────────────────────────────────────────
--
-- O relógio do produto anda para 30 minutos antes do início: é a hora em que o
-- profissional chega, e é dentro da janela.
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
select set_config('frila.agora',
  (select (ini - interval '30 minutes')::text from quando), true);

select throws_ok(
  format($$ select pg_temp.como('af000000-0000-4000-8000-0000000000e1',
       $x$ select public.fazer_checkin(%L, 100, %L) $x$) $$,
         (select perto from t), (select ini - interval '61 minutes' from quando)),
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  '61 minutos antes do início está fora da janela de 60');

select throws_ok(
  format($$ select pg_temp.como('af000000-0000-4000-8000-0000000000e1',
       $x$ select public.fazer_checkin(%L, 100, %L) $x$) $$,
         (select perto from t), (select ini - interval '27 minutes' from quando)),
  'PGRST',
  '{"code" : "registro_no_futuro", "message" : "registro_no_futuro", "details" : null, "hint" : null}',
  '3 minutos no futuro é registro_no_futuro — 2 minutos de folga é o que o relógio do aparelho ganha');

select lives_ok(
  format($$ select pg_temp.como('af000000-0000-4000-8000-0000000000e1',
       $x$ select public.fazer_checkin(%L, 150, %L) $x$) $$,
         (select perto from t), (select ini - interval '32 minutes' from quando)),
  'e 32 minutos antes do início, com 150 m, entra');

-- ── 150 m: verificado na hora ─────────────────────────────────────────────────
create temp table r as
  select privado.turno_em_json((select perto from t), 'af000000-0000-4000-8000-0000000000e1') as j;

select is(
  (select t2.verificacao::text from public.turno t2 where t2.id = (select perto from t)),
  'verificado',
  'RN22: check-in a 150 m fica verificado na hora');

select is(
  (select t2.checkin_tipo::text from public.turno t2 where t2.id = (select perto from t)),
  'geolocalizado',
  'e o tipo é geolocalizado — quem decide é o servidor, a partir da distância');

select is(
  (select t2.checkin_distancia_m from public.turno t2 where t2.id = (select perto from t)),
  150,
  'a distância medida no toque é gravada');

-- A hora do toque e a hora da chegada são colunas diferentes: o registro feito sem rede
-- sai da fila do app depois, e sem as duas um turno das 18:00 sincronizado às 23:00
-- ficaria indistinguível de um das 23:00.
select isnt(
  (select t2.checkin_em from public.turno t2 where t2.id = (select perto from t)),
  (select t2.checkin_recebido_em from public.turno t2 where t2.id = (select perto from t)),
  'a hora do toque e a hora em que o servidor recebeu são guardadas separadas');

-- Presença verificada atualiza a taxa de comparecimento.
select is(
  (select p.taxa_comparecimento from public.profissional p
    where p.usuario_id = 'af000000-0000-4000-8000-0000000000e1'),
  1.000::numeric,
  'presença verificada atualiza a taxa de comparecimento');

select is(
  (select p.turnos_realizados from public.profissional p
    where p.usuario_id = 'af000000-0000-4000-8000-0000000000e1'),
  1,
  'e conta o turno realizado');

-- ── Reenviar ──────────────────────────────────────────────────────────────────
select is(
  pg_temp.como('af000000-0000-4000-8000-0000000000e1',
    format($$ select public.fazer_checkin(%L, 999, %L) $$,
           (select perto from t), (select ini from quando)))->>'distancia_m',
  '150',
  'reenviar o check-in devolve o registro já gravado, e não o novo');

-- ── 350 m: manual, pendente ───────────────────────────────────────────────────
select is(
  pg_temp.como('af000000-0000-4000-8000-0000000000e2',
    format($$ select public.fazer_checkin(%L, 350, %L) $$,
           (select longe from t), (select ini - interval '31 minutes' from quando)))->>'tipo',
  'manual',
  'RN22: check-in a 350 m vira manual');

select is(
  (select t2.verificacao::text from public.turno t2 where t2.id = (select longe from t)),
  'pendente',
  'e a presença fica pendente até a casa confirmar');

-- A distância do manual não é gravada: ela não prova nada, e guardá-la sugeriria que
-- prova. O que vale é a confirmação de quem estava lá.
select is(
  (select t2.checkin_distancia_m from public.turno t2 where t2.id = (select longe from t)),
  null,
  'a distância do check-in manual não é gravada: ela não prova presença');

select is(
  (select p.taxa_comparecimento from public.profissional p
    where p.usuario_id = 'af000000-0000-4000-8000-0000000000e2'),
  null,
  'e a taxa de quem está pendente não muda — sem prova não há comparecimento contado');

-- ── Quem confirma é a casa ────────────────────────────────────────────────────
select throws_ok(
  format($$ select pg_temp.como('af000000-0000-4000-8000-0000000000e2',
       $x$ select public.confirmar_checkin_manual(%L) $x$) $$, (select longe from t)),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'RF20: o profissional confirmando o próprio check-in manual recebe 403');

select is(
  pg_temp.como('af000000-0000-4000-8000-0000000000d1',
    format($$ select public.confirmar_checkin_manual(%L) $$, (select longe from t)))->>'verificacao',
  'verificado',
  'a casa confirma, e só então o manual conta como presença');

select is(
  (select p.taxa_comparecimento from public.profissional p
    where p.usuario_id = 'af000000-0000-4000-8000-0000000000e2'),
  1.000::numeric,
  'e a taxa de comparecimento passa a contar o turno');

select throws_ok(
  format($$ select pg_temp.como('af000000-0000-4000-8000-0000000000d1',
       $x$ select public.confirmar_checkin_manual(%L) $x$) $$, (select perto from t)),
  'PGRST',
  '{"code" : "checkin_ja_confirmado", "message" : "checkin_ja_confirmado", "details" : null, "hint" : null}',
  'confirmar um check-in geolocalizado é 409: ele já nasceu verificado');

-- ── O check-out ───────────────────────────────────────────────────────────────
--
-- A 350 m, e sem erro de restrição: um teto aqui deixaria o turno sem check-out em vez
-- de com um check-out distante.
select set_config('frila.agora', (select (fim - interval '5 minutes')::text from quando), true);

select is(
  pg_temp.como('af000000-0000-4000-8000-0000000000e1',
    format($$ select public.fazer_checkout(%L, 350, %L) $$,
           (select perto from t), (select fim - interval '5 minutes' from quando)))->>'distancia_m',
  '350',
  'check-out a 350 m é aceito, e a distância é gravada como medida');

select is(
  (select t2.checkout_distancia_m from public.turno t2 where t2.id = (select perto from t)),
  350,
  'e a restrição de distância não recusa a escrita');

select is(
  (select t2.verificacao::text from public.turno t2 where t2.id = (select perto from t)),
  'verificado',
  'o check-out não muda a verificação: quem prova presença é o check-in');

-- ── Check-out sem check-in ────────────────────────────────────────────────────
select throws_ok(
  format($$ select pg_temp.como('af000000-0000-4000-8000-0000000000e1',
       $x$ select public.fazer_checkout(%L, 10, %L) $x$) $$,
         (select id from t3), (select fim - interval '5 minutes' from quando)),
  'PGRST',
  '{"code" : "checkin_pendente", "message" : "checkin_pendente", "details" : null, "hint" : null}',
  'encerrar um turno que nunca começou é 409 checkin_pendente');

-- ── O terceiro desfecho: o turno sem prova ────────────────────────────────────
--
-- Ninguém confirmou o manual, e o turno acabou. Ele não conta a favor nem contra: punir
-- quem ficou sem sinal seria punir o aparelho, e não o comportamento.
update public.turno set verificacao = 'nao_verificado', checkin_confirmado_em = null,
                        checkin_tipo = 'manual'
 where id = (select longe from t);
select privado.recalcular_comparecimento(
  (select p.id from public.profissional p where p.usuario_id = 'af000000-0000-4000-8000-0000000000e2'));

select is(
  (select p.taxa_comparecimento from public.profissional p
    where p.usuario_id = 'af000000-0000-4000-8000-0000000000e2'),
  null,
  'RN22: turno não verificado fica fora do numerador e do denominador');

select set_config('frila.agora', '', true);

select * from finish();
rollback;
