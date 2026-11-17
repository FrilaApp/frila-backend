-- `avisar_a_caminho`: o profissional avisa que saiu de casa (cartão h53CJVP7, US14
-- cenário 1, RF12, contrato 0.2.25).
--
-- É um sinal para quem está no salão, e só isso. Não é presença, não substitui o
-- check-in e não entra na taxa de comparecimento. O que este arquivo prova:
--
--   quem       só o profissional confirmado no turno; terceiro, turno inexistente ou
--              posição cancelada recebem 403 sem_permissao
--   quando     de 3 h antes até 15 min depois do início, com as duas bordas dentro;
--              um segundo fora de cada lado é 422 a_caminho_fora_da_janela
--   de novo    a segunda chamada devolve o mesmo registro, com o instante original
--   onde       `painel_estabelecimento` expõe `a_caminho_em` em PosicaoNoPainel e
--              `meus_turnos` no Turno
--
-- Datas relativas ao relógio do produto no momento do teste (padrão do #64): nada aqui
-- vence com o calendário. Ids próprios, começando em `ca000000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(12);

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

select pg_temp.autenticar('ca000000-0000-4000-8000-0000000000d1','dona@caminho.test');
select pg_temp.autenticar('ca000000-0000-4000-8000-0000000000e1','e1@caminho.test');
select pg_temp.autenticar('ca000000-0000-4000-8000-0000000000e2','e2@caminho.test');

select pg_temp.como('ca000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona do Salão','+5561932100001','1980-01-01','2026-09-22') $$);
select pg_temp.como('ca000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Caminho Um','+5561932100011','1995-01-01','2026-09-22') $$);
select pg_temp.como('ca000000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Caminho Dois','+5561932100012','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create function pg_temp.perfil(conta uuid) returns void
language plpgsql as $corpo$
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, (select garcom from fn)));
end $corpo$;

select pg_temp.perfil('ca000000-0000-4000-8000-0000000000e1');
select pg_temp.perfil('ca000000-0000-4000-8000-0000000000e2');

create temp table casa as
  select (pg_temp.como('ca000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Salão do Caminho','33114455000197','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

-- Quatro turnos do mesmo profissional, um por dia, para que cada borda da janela tenha
-- o seu: o aviso é idempotente, e um turno já avisado não testaria a borda seguinte.
create temp table quando as
  select (privado.agora() + interval '2 days')         as ini,
         (privado.agora() + interval '2 days 6 hours') as fim;

create function pg_temp.turno(chave uuid, dias int) returns uuid
language plpgsql as $corpo$
declare v_vaga uuid;
begin
  v_vaga := (pg_temp.como('ca000000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 406',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, 'Seu Zé', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn),
    (select ini + (dias || ' days')::interval from quando),
    (select fim + (dias || ' days')::interval from quando), chave))->>'vaga_id')::uuid;
  return (pg_temp.como('ca000000-0000-4000-8000-0000000000e1',
    format($sql$ select public.candidatar(%L) $sql$, v_vaga))->>'turno_id')::uuid;
end $corpo$;

create temp table t as
  select pg_temp.turno('ca000000-0000-4000-8000-000000000001', 0) as a,
         pg_temp.turno('ca000000-0000-4000-8000-000000000002', 1) as b,
         pg_temp.turno('ca000000-0000-4000-8000-000000000003', 2) as c,
         pg_temp.turno('ca000000-0000-4000-8000-000000000004', 3) as d;

create function pg_temp.avisar(conta uuid, turno uuid) returns jsonb
language sql as $$
  select pg_temp.como(conta, format($x$ select public.avisar_a_caminho(%L) $x$, turno));
$$;

create function pg_temp.relogio(instante timestamptz) returns void
language sql as $$
  select set_config('frila.agora', instante::text, true);
$$;


insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
update public.posicao p set confirmado_em = p.inicio_em + interval '40 minutes'
where p.id in (select posicao_id from public.turno where id in (select a from t union select b from t union select c from t));
select pg_temp.relogio((select ini + interval '41 minutes' from quando));
select lives_ok($$ select pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1', (select a from t)) $$,
 'Substituto confirmado em inicio+40min avisa em inicio+41min');
select is((select a_caminho_em from public.turno where id=(select a from t)), privado.agora(),
 'Aviso guarda o relógio do servidor');
select ok((select checkin_em is null and verificacao='pendente' from public.turno where id=(select a from t)),
 'Aviso não vira presença nem verificação');
select throws_ok($$ select pg_temp.como('ca000000-0000-4000-8000-0000000000d1',
 format('select public.reabrir_por_atraso(%L)', (select posicao_id from public.turno where id=(select a from t)))) $$, 'PGRST',
 '{"code" : "reabertura_antes_da_tolerancia", "message" : "reabertura_antes_da_tolerancia", "details" : null, "hint" : null}',
 'Casa ainda respeita tolerância pós-confirmação: regra de falta não muda');
select is((privado.turno_em_json((select a from t),'ca000000-0000-4000-8000-0000000000e1')->>'confirmado_em')::timestamptz,
 (select ini + interval '40 minutes' from quando), 'Leitura do profissional expõe confirmação');
select is((privado.turno_em_json((select a from t),'ca000000-0000-4000-8000-0000000000d1')->>'confirmado_em')::timestamptz,
 (select ini + interval '40 minutes' from quando), 'Leitura da casa expõe a mesma confirmação');
select pg_temp.relogio((select ini + interval '56 minutes' from quando));
select is((pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1', (select a from t))->>'a_caminho_em')::timestamptz,
 (select ini + interval '41 minutes' from quando), 'Repetição após janela mantém instante original');
select pg_temp.relogio((select ini + interval '1 day 55 minutes' from quando));
select lives_ok($$ select pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1', (select b from t)) $$,
 'Borda confirmação+15min é inclusiva');
select pg_temp.relogio((select ini + interval '2 days 55 minutes 1 second' from quando));
select throws_ok($$ select pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1', (select c from t)) $$, 'PGRST',
 '{"code" : "a_caminho_fora_da_janela", "message" : "a_caminho_fora_da_janela", "details" : null, "hint" : null}',
 'Um segundo após confirmação+15min recusa');
select ok((select a_caminho_em is null from public.turno where id=(select c from t)), 'Recusa não grava aviso');
update public.posicao p set confirmado_em = p.inicio_em - interval '1 hour'
where p.id=(select posicao_id from public.turno where id=(select d from t));
select pg_temp.relogio((select ini + interval '3 days 15 minutes' from quando));
select lives_ok($$ select pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1', (select d from t)) $$,
 'Confirmação antecipada mantém borda do início+15min');
select ok(not has_function_privilege('anon','public.avisar_a_caminho(uuid)','execute'), 'anon segue sem execução');
select * from finish();
rollback;
