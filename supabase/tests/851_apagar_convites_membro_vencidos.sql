-- 851_apagar_convites_membro_vencidos.sql
--
-- Retenção do convite de membro (migração 20261112200000; achado da Bússola, 12/11/2026; ROPA linha 31):
-- privado.apagar_convites_membro_vencidos() apaga o convite com
--   coalesce(usado_em, expira_em) <= agora - 29 days
-- A rotina é diária; o corte em 29 dias faz a 1ª execução depois dos 29 dias apagar, e o convite sai sempre em até
-- 30 dias depois de aceito (usado_em) ou, se não aceito, depois de vencer (expira_em).
--   · aceito e vencido há 31 dias saem; há 28 dias ficam;
--   · BORDA: aceito e vencido EXATAMENTE no corte (agora - 29 dias) saem; 1 segundo antes do corte
--     (agora - 29 dias + 1 s) ficam;
--   · o aceito antes de vencer sai pelo usado_em; o válido (ainda não venceu) fica;
--   · a função devolve a contagem certa e é idempotente;
--   · o job existe no cron.job, diário (se houver pg_cron no ambiente; senão, skip com motivo);
--   · anon e authenticated não executam a função; service_role executa.
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-06-01 12:00:00+00', true);
select plan(19);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('c8510000-0000-4000-8000-000000000001', 'contratante', 'Casa 851', '+5561999998511', 'casa851@test.invalid',
        '1988-01-01', '1.0', '2026-09-20 12:00:00-03');
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ('c8510000-0000-4000-8000-000000000021', 'Bar 851', '80000000000851', 'food_service', 'Endereço 851',
        'POINT(-47.8800 -15.7700)'::extensions.geography);
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c8510000-0000-4000-8000-000000000001', 'c8510000-0000-4000-8000-000000000021', 'administrador');

-- Convite de teste: expira_em e usado_em dados como intervalo a partir de agora (negativo = no passado).
create function pg_temp.convite(n integer, expira_em_em interval, usado_em_em interval default null) returns void
language sql as $$
  insert into privado.convite_membro (id, estabelecimento_id, email, papel, convidado_por, token_hash, expira_em, usado_em)
  values (('c8510000-0000-4000-8000-0000000001' || lpad(n::text, 2, '0'))::uuid,
          'c8510000-0000-4000-8000-000000000021',
          'convidado851-' || n || '@test.invalid',
          'operador',
          'c8510000-0000-4000-8000-000000000001',
          'hash851-' || n,
          privado.agora() + expira_em_em,
          case when usado_em_em is null then null else privado.agora() + usado_em_em end);
$$;

create function pg_temp.existe(n integer) returns boolean language sql as $$
  select exists (select 1 from privado.convite_membro
                  where id = ('c8510000-0000-4000-8000-0000000001' || lpad(n::text, 2, '0'))::uuid)
$$;

-- Corte = agora - 29 dias.
--  1 aceito há 31 dias (venceu há 24)                        → sai
--  2 aceito há 28 dias                                       → fica
--  3 vencido há 31 dias, nunca aceito                        → sai
--  4 vencido há 28 dias, nunca aceito                        → fica
--  5 válido (vence daqui a 5 dias)                           → fica
--  6 aceito há 31 dias, com expira_em ainda no futuro        → sai pelo usado_em
--  7 aceito EXATAMENTE no corte (agora - 29 dias)            → sai
--  8 vencido EXATAMENTE no corte (agora - 29 dias)           → sai
--  9 aceito 1 s antes do corte (agora - 29 dias + 1 s)       → fica
-- 10 vencido 1 s antes do corte (agora - 29 dias + 1 s)      → fica
select pg_temp.convite(1, interval '-24 days', interval '-31 days');
select pg_temp.convite(2, interval '-22 days', interval '-28 days');
select pg_temp.convite(3, interval '-31 days');
select pg_temp.convite(4, interval '-28 days');
select pg_temp.convite(5, interval '5 days');
select pg_temp.convite(6, interval '5 days', interval '-31 days');
select pg_temp.convite(7, interval '-22 days', interval '-29 days');
select pg_temp.convite(8, interval '-29 days');
select pg_temp.convite(9, interval '-22 days', interval '-29 days' + interval '1 second');
select pg_temp.convite(10, interval '-29 days' + interval '1 second');

-- ── 1. Estrutura e acesso ─────────────────────────────────────────────────────

select has_function('privado', 'apagar_convites_membro_vencidos', array[]::text[],
                    '1.1 a função privado.apagar_convites_membro_vencidos() existe');
select is_definer('privado', 'apagar_convites_membro_vencidos', array[]::text[],
                  '1.2 é SECURITY DEFINER');
select ok((select proconfig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'privado' and p.proname = 'apagar_convites_membro_vencidos') @> array['search_path=""'],
          '1.3 opera com search_path vazio');
select is(has_function_privilege('service_role', 'privado.apagar_convites_membro_vencidos()', 'execute'), true,
          '1.4 service_role executa');
select is(has_function_privilege('anon', 'privado.apagar_convites_membro_vencidos()', 'execute'), false,
          '1.5 anon não executa');
select is(has_function_privilege('authenticated', 'privado.apagar_convites_membro_vencidos()', 'execute'), false,
          '1.6 authenticated não executa');

-- ── 2. O job no pg_cron ───────────────────────────────────────────────────────

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform set_config('frila.t851_cron', 'sim', true);
  else
    perform set_config('frila.t851_cron', 'nao', true);
  end if;
end $$;

select case when current_setting('frila.t851_cron', true) = 'sim'
            then is((select count(*)::int from cron.job where jobname = 'apagar_convites_membro_vencidos'), 1,
                    '2.1 o job apagar_convites_membro_vencidos existe no cron.job')
            else skip('2.1 sem pg_cron neste ambiente: o job só é agendado quando a extensão existe', 1) end;
select case when current_setting('frila.t851_cron', true) = 'sim'
            then is((select schedule from cron.job where jobname = 'apagar_convites_membro_vencidos'), '41 5 * * *',
                    '2.2 o job é diário, às 05:41 UTC')
            else skip('2.2 sem pg_cron neste ambiente', 1) end;
select case when current_setting('frila.t851_cron', true) = 'sim'
            then is((select command from cron.job where jobname = 'apagar_convites_membro_vencidos'),
                    'select privado.apagar_convites_membro_vencidos()',
                    '2.3 o job chama a função')
            else skip('2.3 sem pg_cron neste ambiente', 1) end;

-- ── 3. O corte de 29 dias ─────────────────────────────────────────────────────

select is(privado.apagar_convites_membro_vencidos(), 5,
          '3.1 devolve 5: aceito há 31, vencido há 31, aceito há 31 antes de vencer, e aceito e vencido exatamente no corte');
select is(pg_temp.existe(1), false, '3.2 aceito há 31 dias sai');
select is(pg_temp.existe(3), false, '3.3 vencido há 31 dias sai');
select is(pg_temp.existe(6), false, '3.4 aceito há 31 dias antes de vencer sai pelo usado_em');
select is(pg_temp.existe(7), false, '3.5 borda: aceito exatamente 29 dias atrás sai (<=)');
select is(pg_temp.existe(8), false, '3.6 borda: vencido exatamente 29 dias atrás sai (<=)');
select is(pg_temp.existe(9), true, '3.7 borda: aceito 1 segundo antes do corte fica');
select is(pg_temp.existe(10), true, '3.8 borda: vencido 1 segundo antes do corte fica');
select is(pg_temp.existe(2) and pg_temp.existe(4) and pg_temp.existe(5), true,
          '3.9 aceito há 28, vencido há 28 e o válido ficam');
select is(privado.apagar_convites_membro_vencidos(), 0,
          '3.10 segunda chamada no mesmo instante devolve 0 (idempotente)');

select * from finish();
rollback;
