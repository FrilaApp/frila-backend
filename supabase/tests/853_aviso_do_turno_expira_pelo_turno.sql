-- D-20 (F-031 7.4): os avisos do turno em curso expiram pelo turno, e não no início da vaga.
--
-- Antes desta correção, privado.notificacao_expirada_pelo_relogio punha fim_sem_checkout, checkin e
-- checkin_manual_pendente no ramo do lembrete_24h e do lembrete_3h (expira no início). O enviar-push
-- pergunta privado.notificacao_expirada antes de cada envio e, com "expirada", grava
-- falhou/vaga_ou_turno_ja_iniciado. Era o que o F-031 viu em 7.4: o turno sem check-out e os dois
-- fim_sem_checkout criados no fim, ambos falhou/vaga_ou_turno_ja_iniciado, e nenhum chegou.
--
-- Eixo do arquivo: um turno de 6 h, com o check-in DEPOIS do início (a chave do check-in por código
-- está ligada para todos, então o check-in fica pendente e a casa recebe checkin_manual_pendente).
--
-- Ids próprios, começando em `fd200000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(17);

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

select pg_temp.autenticar('fd200000-0000-4000-8000-0000000000d1','d1@d20.test');
select pg_temp.autenticar('fd200000-0000-4000-8000-0000000000e1','e1@d20.test');

select pg_temp.como('fd200000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Casa do D20','+5561955552001','1980-01-01','2026-09-22') $$);
select pg_temp.como('fd200000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Chegou Depois','+5561955552011','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como('fd200000-0000-4000-8000-0000000000e1', format(
  $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
          '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, (select garcom from fn)));

create temp table casa as
  select (pg_temp.como('fd200000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa do D20','04252011000110','food_service',
         'SCLN 409','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create temp table v as
  select (pg_temp.como('fd200000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 409',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, 'Dona Rita', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn),
    privado.agora() + interval '2 days',
    privado.agora() + interval '2 days 6 hours',
    'fd200000-0000-4000-8000-000000000001'))->>'vaga_id')::uuid as vaga;

create temp table c as
  select pg_temp.como('fd200000-0000-4000-8000-0000000000e1',
           format($$ select public.candidatar(%L) $$, (select vaga from v))) as r;

create temp table p as
  select (r->>'posicao_id')::uuid as pos, (r->>'turno_id')::uuid as turno from c;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

create function pg_temp.relogio(desloc interval, pelo_fim boolean default true)
returns void language plpgsql as $$
begin
  perform set_config('frila.agora',
    (select ((case when pelo_fim then x.fim_em else x.inicio_em end) + desloc)::text
       from public.posicao x where x.id = (select pos from p)), true);
end $$;

-- o id do aviso <tipo> da conta <conta> para o turno do arquivo
create function pg_temp.aviso(p_tipo text, p_conta uuid) returns uuid
language sql as $$
  select n.id from public.notificacao n
   where n.tipo::text = p_tipo and n.usuario_id = p_conta and n.referencia_id = (select turno from p)
$$;

-- ── 1. Check-in DEPOIS do início: o aviso à casa não vence no início ──────────

select pg_temp.relogio(interval '10 minutes', false);
select pg_temp.como('fd200000-0000-4000-8000-0000000000e1',
  format($$ select public.fazer_checkin(%L, 30, %L) $$, (select turno from p), privado.agora()));

select is((select verificacao::text from public.turno where id = (select turno from p)), 'pendente',
  'com a chave ligada para todos, o check-in 10 min depois do início fica pendente');

select isnt(pg_temp.aviso('checkin_manual_pendente', 'fd200000-0000-4000-8000-0000000000d1'), null,
  'a casa recebeu o aviso checkin_manual_pendente');

select is(privado.notificacao_expirada(pg_temp.aviso('checkin_manual_pendente', 'fd200000-0000-4000-8000-0000000000d1')),
  false,
  'D-20: checkin_manual_pendente depois do início NÃO expira (antes: expirava no início da vaga)');

select pg_temp.relogio(interval '23 hours');
select is(privado.notificacao_expirada(pg_temp.aviso('checkin_manual_pendente', 'fd200000-0000-4000-8000-0000000000d1')),
  false,
  'checkin_manual_pendente ainda vale 23 h depois do fim (a casa pode confirmar até fim + 24 h)');

select pg_temp.relogio(interval '25 hours');
select is(privado.notificacao_expirada(pg_temp.aviso('checkin_manual_pendente', 'fd200000-0000-4000-8000-0000000000d1')),
  true,
  'checkin_manual_pendente expira depois do prazo da confirmação tardia (fim + 24 h)');

-- ── 2. checkin (o aviso de chegada à casa) vale até o fim ─────────────────────

select privado.notificar('fd200000-0000-4000-8000-0000000000d1', 'checkin', (select turno from p),
                         jsonb_build_object('turno_id', (select turno from p)));

select pg_temp.relogio(interval '-1 minute');
select is(privado.notificacao_expirada(pg_temp.aviso('checkin', 'fd200000-0000-4000-8000-0000000000d1')),
  false,
  'D-20: checkin um minuto antes do fim (bem depois do início) NÃO expira');

select pg_temp.relogio(interval '1 minute');
select is(privado.notificacao_expirada(pg_temp.aviso('checkin', 'fd200000-0000-4000-8000-0000000000d1')),
  true,
  'checkin expira no fim do turno');

-- ── 3. F-031 7.4: passou o fim sem check-out; os dois fim_sem_checkout saem ───

select pg_temp.relogio(interval '1 minute');
select is(privado.alertar_fim_sem_checkout(), 1,
  'um minuto depois do fim, o turno com check-in e sem check-out entra no aviso');

select isnt(pg_temp.aviso('fim_sem_checkout', 'fd200000-0000-4000-8000-0000000000e1'), null,
  'o profissional tem o aviso fim_sem_checkout');
select isnt(pg_temp.aviso('fim_sem_checkout', 'fd200000-0000-4000-8000-0000000000d1'), null,
  'e a casa também');

select is(privado.notificacao_expirada(pg_temp.aviso('fim_sem_checkout', 'fd200000-0000-4000-8000-0000000000e1')),
  false,
  'F-031 7.4: o fim_sem_checkout do profissional NÃO expira (antes: falhou/vaga_ou_turno_ja_iniciado)');
select is(privado.notificacao_expirada(pg_temp.aviso('fim_sem_checkout', 'fd200000-0000-4000-8000-0000000000d1')),
  false,
  'F-031 7.4: o fim_sem_checkout da casa NÃO expira');

select pg_temp.relogio(interval '59 minutes');
select is(privado.notificacao_expirada(pg_temp.aviso('fim_sem_checkout', 'fd200000-0000-4000-8000-0000000000e1')),
  false,
  'fim_sem_checkout ainda vale dentro da janela (fim + 59 min)');

select pg_temp.relogio(interval '61 minutes');
select is(privado.notificacao_expirada(pg_temp.aviso('fim_sem_checkout', 'fd200000-0000-4000-8000-0000000000e1')),
  true,
  'B-019: fim_sem_checkout expira depois de fim + 60 min, a janela do check-out (antes: 6 h)');

-- com o check-out feito, o aviso de check-out pendente não serve mais
select pg_temp.relogio(interval '2 minutes');
update public.turno set checkout_em = privado.agora() where id = (select turno from p);
select is(privado.notificacao_expirada(pg_temp.aviso('fim_sem_checkout', 'fd200000-0000-4000-8000-0000000000e1')),
  true,
  'fim_sem_checkout expira quando o turno tem check-out');

-- ── 4. O lembrete antes do turno segue expirando no início ────────────────────

select privado.notificar('fd200000-0000-4000-8000-0000000000e1', 'lembrete_3h', (select turno from p),
                         jsonb_build_object('turno_id', (select turno from p)));

select pg_temp.relogio(interval '-1 minute', false);
select is(privado.notificacao_expirada(pg_temp.aviso('lembrete_3h', 'fd200000-0000-4000-8000-0000000000e1')),
  false,
  'lembrete_3h um minuto antes do início ainda vale');

select pg_temp.relogio(interval '1 minute', false);
select is(privado.notificacao_expirada(pg_temp.aviso('lembrete_3h', 'fd200000-0000-4000-8000-0000000000e1')),
  true,
  'lembrete_3h expira no início, como antes');

select * from finish();
rollback;
