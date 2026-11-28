-- 904_criar_desafio_cooldown_efetivo.sql
-- Prova em Postgres real que `privado.criar_desafio_dispositivo` devolve o JSON esperado
-- (`desafio_id`, `expira_em`, `cooldown_segundos`) refletindo `privado.config_auth` (default 60s e 30s).
begin;
select plan(6);

insert into auth.users (id, email, aud, role, created_at, updated_at)
values (
  'e4444444-4444-4444-8444-444444444444'::uuid,
  'cooldown.desafio@frila.test',
  'authenticated',
  'authenticated',
  now(),
  now()
)
on conflict (id) do nothing;

-- 1. Default 60s em privado.config_auth (unica = true)
update privado.config_auth set cooldown_reenvio_otp_segundos = 60 where unica = true;

create temp table t_desafio_60 as
select privado.criar_desafio_dispositivo(
  'e4444444-4444-4444-8444-444444444444'::uuid,
  'Cooldown.Desafio@Frila.test',
  'hash-cooldown-desafio',
  'ios'
) as res;

select ok(
  ((select res ->> 'desafio_id' from t_desafio_60) ~* '^[0-9a-f-]{36}$'),
  'criar_desafio_dispositivo devolve desafio_id UUID válido (default 60s)'
);

select ok(
  ((select res ->> 'expira_em' from t_desafio_60) is not null),
  'criar_desafio_dispositivo devolve expira_em preenchido (default 60s)'
);

select is(
  ((select res ->> 'cooldown_segundos' from t_desafio_60)),
  '60',
  'criar_desafio_dispositivo devolve cooldown_segundos = 60 quando config_auth está no default 60'
);

-- 2. Configurado para 30s em privado.config_auth (unica = true)
update privado.config_auth set cooldown_reenvio_otp_segundos = 30 where unica = true;

create temp table t_desafio_30 as
select privado.criar_desafio_dispositivo(
  'e4444444-4444-4444-8444-444444444444'::uuid,
  'Cooldown.Desafio@Frila.test',
  'hash-cooldown-desafio',
  'web'
) as res;

select ok(
  ((select res ->> 'desafio_id' from t_desafio_30) ~* '^[0-9a-f-]{36}$'),
  'criar_desafio_dispositivo devolve desafio_id UUID válido (config 30s)'
);

select is(
  ((select res ->> 'cooldown_segundos' from t_desafio_30)),
  '30',
  'criar_desafio_dispositivo devolve cooldown_segundos = 30 quando config_auth está em 30'
);

select ok(
  not has_function_privilege('anon', 'privado.criar_desafio_dispositivo(uuid, text, text, text)', 'execute')
  and not has_function_privilege('authenticated', 'privado.criar_desafio_dispositivo(uuid, text, text, text)', 'execute'),
  'privado.criar_desafio_dispositivo segue inacessível a anon e authenticated'
);

select * from finish();
rollback;
