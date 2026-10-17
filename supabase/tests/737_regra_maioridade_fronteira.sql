begin;
select plan(10);

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

-- Habilita o relógio controlável do produto
insert into privado.ambiente (eh_teste) values (true)
on conflict do nothing;

-- ── 1. Cenário de produção: 17 anos e 364 dias às 22h BRT (janela 21h-24h) ───────
-- Horário: 17/10/2026 22:00:00 BRT (UTC-3), que equivale a 18/10/2026 01:00:00 UTC.
-- Alguém nascido em 18/10/2008 completa 18 anos apenas no dia 18/10 em Brasília.
-- Às 22h do dia 17/10 ela AINDA é menor de idade (17 anos e 364 dias).
set local frila.agora = '2026-10-17 22:00:00-03';

select pg_temp.autenticar('f0000000-0000-4000-8000-000000000091', 'quase18@teste.com');

-- Deve recusar na RPC criar_conta com 422 'menor_de_idade'
select throws_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000091',
       $x$ select public.criar_conta('profissional','Quase Maior','+5561999990091','2008-10-18','2026-09-22') $x$) $$,
  'PGRST',
  '{"code" : "menor_de_idade", "message" : "menor_de_idade", "details" : null, "hint" : null}',
  'RN20: 17 anos e 364 dias às 22h BRT (21h-24h) deve ser recusado em criar_conta'
);

-- Deve recusar no check constraint da tabela public.usuario se tentar insert direto
select throws_ok(
  $$ insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
     values ('f0000000-0000-4000-8000-000000000091', 'profissional', 'Quase Maior', '+5561999990091',
             'quase18@teste.com', '2008-10-18'::date, '2026-09-22', privado.agora()) $$,
  '23514',
  null,
  'RN20: constraint maior_de_idade de public.usuario recusa 17a364d às 22h BRT'
);

-- ── 2. Exatamente 18 anos completos aceita ────────────────────────────────────
-- Às 22h do dia 17/10/2026 em Brasília, quem nasceu em 17/10/2008 já fez 18 anos hoje.
select pg_temp.autenticar('f0000000-0000-4000-8000-000000000092', 'exatos18@teste.com');

select lives_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000092',
       $x$ select public.criar_conta('profissional','Exatos 18','+5561999990092','2008-10-17','2026-09-22') $x$) $$,
  'RN20: exatamente 18 anos completos é aceito em criar_conta'
);

-- ── 3. Virada da meia-noite em Brasília: às 00:00:01 do dia 18/10 aceita ────────
set local frila.agora = '2026-10-18 00:00:01-03';

select pg_temp.autenticar('f0000000-0000-4000-8000-000000000093', 'virou18@teste.com');

select lives_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000093',
       $x$ select public.criar_conta('profissional','Virou 18','+5561999990093','2008-10-18','2026-09-22') $x$) $$,
  'RN20: na virada do dia 18/10 em Brasília, quem nasceu em 18/10/2008 é aceito'
);

-- ── 4. Fronteira bissexta: 29/02 em ano não bissexto (2026) completa em 01/03 ─
-- Nascido em 29/02/2008 (ano bissexto).
-- Em 28/02/2026 às 12:00 BRT: AINDA NÃO tem 18 anos (completa em 01/03).
set local frila.agora = '2026-02-28 12:00:00-03';

select pg_temp.autenticar('f0000000-0000-4000-8000-000000000094', 'bissexto28_rpc@teste.com');
select pg_temp.autenticar('f0000000-0000-4000-8000-000000000095', 'bissexto28_tab@teste.com');

select throws_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000094',
       $x$ select public.criar_conta('profissional','Bissexto 28','+5561999990094','2008-02-29','2026-09-22') $x$) $$,
  'PGRST',
  '{"code" : "menor_de_idade", "message" : "menor_de_idade", "details" : null, "hint" : null}',
  'RN20: nascido em 29/02 é menor em 28/02 de ano não bissexto'
);

select throws_ok(
  $$ insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
     values ('f0000000-0000-4000-8000-000000000095', 'profissional', 'Bissexto 28', '+5561999990095',
             'bissexto28_tab@teste.com', '2008-02-29'::date, '2026-09-22', privado.agora()) $$,
  '23514',
  null,
  'RN20: constraint maior_de_idade recusa 29/02 em 28/02 de ano não bissexto'
);

-- Em 01/03/2026 às 00:00:01 BRT: completa 18 anos (29/02 -> 01/03 no app e no servidor)
set local frila.agora = '2026-03-01 00:00:01-03';

select pg_temp.autenticar('f0000000-0000-4000-8000-000000000096', 'bissexto01@teste.com');

select lives_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000096',
       $x$ select public.criar_conta('profissional','Bissexto 01','+5561999990096','2008-02-29','2026-09-22') $x$) $$,
  'RN20: nascido em 29/02 completa 18 anos em 01/03 de ano não bissexto'
);

-- ── 5. Fronteira da virada do ano: 31/12 às 22h BRT (01/01 01h UTC) ───────────
-- Nascido em 01/01/2009 só completa 18 anos em 01/01/2027.
-- Às 22h BRT de 31/12/2026 (já 01/01/2027 em UTC), ele AINDA tem 17 anos em Brasília.
set local frila.agora = '2026-12-31 22:00:00-03';

select pg_temp.autenticar('f0000000-0000-4000-8000-000000000099', 'anonovo31_rpc@teste.com');
select pg_temp.autenticar('f0000000-0000-4000-8000-000000000100', 'anonovo31_tab@teste.com');

select throws_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000099',
       $x$ select public.criar_conta('profissional','Ano Novo 31','+5561999990099','2009-01-01','2026-09-22') $x$) $$,
  'PGRST',
  '{"code" : "menor_de_idade", "message" : "menor_de_idade", "details" : null, "hint" : null}',
  'RN20: nascido em 01/01 é menor em 31/12 às 22h BRT apesar de UTC já ter virado o ano'
);

select throws_ok(
  $$ insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
     values ('f0000000-0000-4000-8000-000000000100', 'profissional', 'Ano Novo 31', '+5561999990099',
             'anonovo31_tab@teste.com', '2009-01-01'::date, '2026-09-22', privado.agora()) $$,
  '23514',
  null,
  'RN20: constraint maior_de_idade recusa nascido em 01/01 em 31/12 às 22h BRT'
);

-- Virada do ano: 01/01/2027 00:00:01 BRT
set local frila.agora = '2027-01-01 00:00:01-03';

select pg_temp.autenticar('f0000000-0000-4000-8000-000000000101', 'anonovo01@teste.com');

select lives_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000101',
       $x$ select public.criar_conta('profissional','Ano Novo 01','+5561999990099','2009-01-01','2026-09-22') $x$) $$,
  'RN20: na virada do ano 01/01 em Brasília, completa 18 anos e entra'
);

select * from finish();
rollback;
