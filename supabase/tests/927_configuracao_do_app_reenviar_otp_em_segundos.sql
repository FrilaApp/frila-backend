-- 905_configuracao_do_app_reenviar_otp_em_segundos.sql
-- Prova em Postgres real que `public.configuracao_do_app` devolve `reenviar_otp_em_segundos`
-- (default 60, configurado 30, fallback 60 se ausente) para roles `anon` e `authenticated`,
-- preservando grants e sem expor campos privados de `privado.config_auth`.
begin;
select plan(7);

-- 1. Default 60s como role anon
update privado.config_auth set cooldown_reenvio_otp_segundos = 60 where unica = true;
set local role anon;

select is(
  (public.configuracao_do_app('web', '0.1.0') ->> 'reenviar_otp_em_segundos'),
  '60',
  'anon recebe reenviar_otp_em_segundos = 60 no default'
);

select ok(
  not (public.configuracao_do_app('web', '0.1.0') ? 'exigir_dispositivo_verificado')
  and not (public.configuracao_do_app('web', '0.1.0') ? 'corte_sessoes_anteriores_em'),
  'configuracao_do_app não expõe colunas privadas de privado.config_auth'
);

reset role;

-- 2. Configurado 30s como role authenticated e anon
update privado.config_auth set cooldown_reenvio_otp_segundos = 30 where unica = true;
set local role authenticated;

select is(
  (public.configuracao_do_app('ios', '1.2.0') ->> 'reenviar_otp_em_segundos'),
  '30',
  'authenticated recebe reenviar_otp_em_segundos = 30 quando config_auth = 30'
);

set local role anon;
select is(
  (public.configuracao_do_app('android', '1.2.0') ->> 'reenviar_otp_em_segundos'),
  '30',
  'anon recebe reenviar_otp_em_segundos = 30 quando config_auth = 30'
);

reset role;

-- 3. Ausência da linha em privado.config_auth -> fallback seguro 60
delete from privado.config_auth;
set local role anon;

select is(
  (public.configuracao_do_app('web', '0.1.0') ->> 'reenviar_otp_em_segundos'),
  '60',
  'ausência de linha em config_auth devolve fallback seguro 60'
);

reset role;

-- 4. Grants preservados
select ok(
  has_function_privilege('anon', 'public.configuracao_do_app(text, text)', 'execute')
  and has_function_privilege('authenticated', 'public.configuracao_do_app(text, text)', 'execute'),
  'grants de execução para anon e authenticated preservados'
);

select ok(
  not has_table_privilege('anon', 'privado.config_auth', 'select')
  and not has_table_privilege('authenticated', 'privado.config_auth', 'select'),
  'privado.config_auth permanece inacessível a anon e authenticated'
);

select * from finish();
rollback;
