-- Aviso de hora excedida quando o fim previsto passa sem check-out (cartão qcVimM84 ·
-- US15, RN11, UC05).
--
-- O eixo do arquivo é o relógio do produto cruzando o fim de quatro turnos da mesma casa:
--
--   fim − 1 min             nada sai para ninguém
--   fim + 1 min             quem entrou e não saiu avisa os dois lados, uma vez
--   segunda execução        nenhum aviso novo — a chave (tipo, referência, conta)
--   turno com check-out     nada, nunca
--   turno sem check-in      nada: esse é o no-show, e é outro cartão
--   fim + 7 h               fora da janela: o agendador que volta de uma parada não
--                           avisa sobre o turno de ontem
--
-- E o critério 3, que é sobre o que o aviso **não** diz: hora extra. Do lado do banco
-- isso não é disciplina de quem escreve, é estrutura — `privado.notificar` recusa
-- qualquer chave de payload fora do vocabulário, então não existe onde guardar minutos
-- excedidos.
--
-- Ids próprios, começando em `fc000000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(25);

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

-- d1 é a casa; os quatro profissionais são os quatro desfechos do fim do turno.
select pg_temp.autenticar('fc000000-0000-4000-8000-0000000000d1','d1@checkout.test');
select pg_temp.autenticar('fc000000-0000-4000-8000-0000000000e1','e1@checkout.test');
select pg_temp.autenticar('fc000000-0000-4000-8000-0000000000e2','e2@checkout.test');
select pg_temp.autenticar('fc000000-0000-4000-8000-0000000000e3','e3@checkout.test');
select pg_temp.autenticar('fc000000-0000-4000-8000-0000000000e4','e4@checkout.test');

select pg_temp.como('fc000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Casa do Check-out','+5561955550001','1980-01-01','2026-09-22') $$);
select pg_temp.como('fc000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Entrou e Ficou','+5561955550011','1995-01-01','2026-09-22') $$);
select pg_temp.como('fc000000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Entrou e Saiu','+5561955550012','1995-01-01','2026-09-22') $$);
select pg_temp.como('fc000000-0000-4000-8000-0000000000e3',
  $$ select public.criar_conta('profissional','Nao Apareceu','+5561955550013','1995-01-01','2026-09-22') $$);
select pg_temp.como('fc000000-0000-4000-8000-0000000000e4',
  $$ select public.criar_conta('profissional','Turno Antigo','+5561955550014','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create function pg_temp.perfil(conta uuid) returns void
language plpgsql as $corpo$
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, (select garcom from fn)));
end $corpo$;

select pg_temp.perfil('fc000000-0000-4000-8000-0000000000e1');
select pg_temp.perfil('fc000000-0000-4000-8000-0000000000e2');
select pg_temp.perfil('fc000000-0000-4000-8000-0000000000e3');
select pg_temp.perfil('fc000000-0000-4000-8000-0000000000e4');

create temp table casa as
  select (pg_temp.como('fc000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa do Check-out','04252011000110','food_service',
         'SCLN 409','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create function pg_temp.publicar(chave uuid, dias int) returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como('fc000000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 409',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, 'Dona Rita', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn),
    privado.agora() + (dias || ' days')::interval,
    privado.agora() + (dias || ' days 6 hours')::interval, chave))->>'vaga_id')::uuid;
end $corpo$;

create temp table v as
  select pg_temp.publicar('fc000000-0000-4000-8000-000000000001', 2) as ficou,
         pg_temp.publicar('fc000000-0000-4000-8000-000000000002', 3) as saiu,
         pg_temp.publicar('fc000000-0000-4000-8000-000000000003', 4) as sumiu,
         pg_temp.publicar('fc000000-0000-4000-8000-000000000004', 5) as antigo;

create temp table c as
  select pg_temp.como('fc000000-0000-4000-8000-0000000000e1',
           format($$ select public.candidatar(%L) $$, (select ficou  from v))) as ficou,
         pg_temp.como('fc000000-0000-4000-8000-0000000000e2',
           format($$ select public.candidatar(%L) $$, (select saiu   from v))) as saiu,
         pg_temp.como('fc000000-0000-4000-8000-0000000000e3',
           format($$ select public.candidatar(%L) $$, (select sumiu  from v))) as sumiu,
         pg_temp.como('fc000000-0000-4000-8000-0000000000e4',
           format($$ select public.candidatar(%L) $$, (select antigo from v))) as antigo;

create temp table p as
  select (ficou->>'posicao_id')::uuid  as pos_ficou,  (ficou->>'turno_id')::uuid  as t_ficou,
         (saiu->>'posicao_id')::uuid   as pos_saiu,   (saiu->>'turno_id')::uuid   as t_saiu,
         (sumiu->>'posicao_id')::uuid  as pos_sumiu,  (sumiu->>'turno_id')::uuid  as t_sumiu,
         (antigo->>'posicao_id')::uuid as pos_antigo, (antigo->>'turno_id')::uuid as t_antigo
    from c;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

create function pg_temp.relogio(posicao uuid, desloc interval, pelo_fim boolean default true)
returns void language plpgsql as $$
begin
  perform set_config('frila.agora',
    (select ((case when pelo_fim then x.fim_em else x.inicio_em end) + desloc)::text
       from public.posicao x where x.id = posicao), true);
end $$;

create function pg_temp.avisos(p_conta uuid, p_turno uuid) returns int
language sql as $$
  select count(*)::int from public.notificacao n
   where n.tipo::text = 'fim_sem_checkout'
     and n.usuario_id = p_conta and n.referencia_id = p_turno
$$;

-- ── 1. A estrutura ────────────────────────────────────────────────────────────

select has_function('privado', 'alertar_fim_sem_checkout', array[]::text[],
  'privado.alertar_fim_sem_checkout() existe');

select is(
  has_function_privilege('authenticated', 'privado.alertar_fim_sem_checkout()', 'execute'),
  false,
  'o app não chama o agendador');

select is(
  has_function_privilege('service_role', 'privado.alertar_fim_sem_checkout()', 'execute'),
  true,
  'o service_role chama');

select is(
  (select schedule from cron.job where jobname = 'alertar_fim_sem_checkout'),
  '*/5 * * * *',
  'o job roda a cada cinco minutos');

select is(
  (select valor from privado.parametro_notificacao where chave = 'fim_sem_checkout_janela'),
  interval '6 hours',
  'a janela do aviso é parâmetro, e não número solto no meio da função');

-- ── 2. Antes do fim, nada ─────────────────────────────────────────────────────

select pg_temp.relogio((select pos_ficou from p), interval '-1 minute');
select pg_temp.como('fc000000-0000-4000-8000-0000000000e1',
  format($$ select public.fazer_checkin(%L, 30, %L) $$, (select t_ficou from p), privado.agora()));

select is(privado.alertar_fim_sem_checkout(), 0,
  'um minuto antes do fim, o turno em andamento não gera aviso');

select is(pg_temp.avisos('fc000000-0000-4000-8000-0000000000e1', (select t_ficou from p)), 0,
  'e o profissional não recebeu nada');

-- ── 3. Critério 1: passou o fim sem check-out, os dois lados, uma vez ─────────

select pg_temp.relogio((select pos_ficou from p), interval '1 minute');

select is(privado.alertar_fim_sem_checkout(), 1,
  'um minuto depois do fim, o turno com check-in e sem check-out entra no aviso');

select is(pg_temp.avisos('fc000000-0000-4000-8000-0000000000e1', (select t_ficou from p)), 1,
  'quem trabalhou recebe o aviso');

select is(pg_temp.avisos('fc000000-0000-4000-8000-0000000000d1', (select t_ficou from p)), 1,
  'e a casa também: são os dois lados (RN11)');

-- A segunda execução é o teste do "uma vez". O agendador roda a cada cinco minutos, e
-- sem a chave de unicidade o profissional levaria um push por rodada até fazer check-out.
select is(privado.alertar_fim_sem_checkout(), 1,
  'a segunda execução ainda encontra o turno');

select is(pg_temp.avisos('fc000000-0000-4000-8000-0000000000e1', (select t_ficou from p)), 1,
  'mas não cria um segundo aviso para o profissional (critério 1: uma vez)');

select is(pg_temp.avisos('fc000000-0000-4000-8000-0000000000d1', (select t_ficou from p)), 1,
  'nem para a casa');

-- ── 4. Critério 2: turno com check-out não recebe aviso ──────────────────────

select pg_temp.relogio((select pos_saiu from p), interval '-10 minutes');
select pg_temp.como('fc000000-0000-4000-8000-0000000000e2',
  format($$ select public.fazer_checkin(%L, 30, %L) $$, (select t_saiu from p), privado.agora()));
select pg_temp.relogio((select pos_saiu from p), interval '-1 minute');
select pg_temp.como('fc000000-0000-4000-8000-0000000000e2',
  format($$ select public.fazer_checkout(%L, 30, %L) $$, (select t_saiu from p), privado.agora()));

select isnt(
  (select checkout_em from public.turno where id = (select t_saiu from p)),
  null,
  'o segundo turno tem check-out — a asserção abaixo tem o que medir');

select pg_temp.relogio((select pos_saiu from p), interval '1 minute');

select is(pg_temp.avisos('fc000000-0000-4000-8000-0000000000e2', (select t_saiu from p)), 0,
  'antes de rodar, ninguém tinha avisado esse turno');

select is(privado.alertar_fim_sem_checkout(), 0,
  'depois do fim, o turno com check-out não entra no aviso (critério 2)');

select is(pg_temp.avisos('fc000000-0000-4000-8000-0000000000e2', (select t_saiu from p)), 0,
  'e quem fez check-out não recebe nada');

select is(pg_temp.avisos('fc000000-0000-4000-8000-0000000000d1', (select t_saiu from p)), 0,
  'nem a casa, por esse turno');

-- ── 5. Sem check-in não é caso deste aviso ───────────────────────────────────
--
-- Turno confirmado que terminou sem ninguém aparecer é no-show, e vira falta pelo
-- `fechar_turnos_passados` (cartão NDx7TJ4d). Pedir check-out a quem não entrou seria
-- avisar a pessoa errada sobre a coisa errada.

select pg_temp.relogio((select pos_sumiu from p), interval '1 minute');

select is(privado.alertar_fim_sem_checkout(), 0,
  'turno que terminou sem check-in nenhum não é deste aviso: é no-show');

select is(pg_temp.avisos('fc000000-0000-4000-8000-0000000000e3', (select t_sumiu from p)), 0,
  'e quem nunca chegou não recebe pedido de check-out');

-- ── 6. A janela ──────────────────────────────────────────────────────────────

select pg_temp.relogio((select pos_antigo from p), interval '-10 minutes');
select pg_temp.como('fc000000-0000-4000-8000-0000000000e4',
  format($$ select public.fazer_checkin(%L, 30, %L) $$, (select t_antigo from p), privado.agora()));

select pg_temp.relogio((select pos_antigo from p), interval '7 hours');

select is(privado.alertar_fim_sem_checkout(), 0,
  'passada a janela de 6 h, o turno antigo não gera aviso');

select is(pg_temp.avisos('fc000000-0000-4000-8000-0000000000e4', (select t_antigo from p)), 0,
  'o agendador que volta de uma parada não avisa sobre o turno de ontem');

-- ── 7. Critério 3: não há onde guardar hora extra ────────────────────────────
--
-- O critério fala de tela, e a tela é iOS. O que o backend pode garantir é que ele nunca
-- terá o número para mostrar: o payload da notificação é vocabulário fechado.

select is(
  (select n.payload - 'tipo' from public.notificacao n
    where n.tipo::text = 'fim_sem_checkout'
      and n.usuario_id = 'fc000000-0000-4000-8000-0000000000e1'
      and n.referencia_id = (select t_ficou from p)),
  jsonb_build_object('turno_id', (select t_ficou from p)),
  'o aviso leva só o turno: nenhum minuto, nenhuma duração, nenhuma hora extra');

select throws_ok(
  $$ select privado.notificar('fc000000-0000-4000-8000-0000000000e1', 'fim_sem_checkout',
       'fc000000-0000-4000-8000-000000000001',
       '{"minutos_excedidos": 45}'::jsonb) $$,
  '22023',
  null,
  'e o banco recusa um payload com minutos excedidos: não há onde guardar hora extra');

-- Nenhuma função do produto fala em hora extra. O texto do push vive no `enviar-push`,
-- mas uma função do banco que montasse essa frase entraria por aqui sem ninguém ver.
select is(
  (select string_agg(p.proname, ', ' order by p.proname)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','privado')
      and p.prosrc ~* '(hora|horas)[[:space:]]+extra'),
  null,
  'nenhuma função de public ou privado fala em hora extra');

select * from finish();
rollback;
