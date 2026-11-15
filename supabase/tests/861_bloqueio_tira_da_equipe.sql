-- 861_bloqueio_tira_da_equipe.sql
--
-- D-14 / RF26: quem bloqueia (ou é bloqueado) sai da equipe de confiança na mesma
-- transação do bloqueio, por gatilho (migração 20261114050000). Sem notificação.
--
-- Casos cobertos:
--   1. Estrutura: as duas funções de gatilho existem, são SECURITY DEFINER com
--      search_path="" e nem authenticated nem anon executam; os dois gatilhos existem.
--   2. O administrador da casa bloqueia o profissional: a linha sai da casa, e também da
--      2ª casa de que ele é membro; a mesma pessoa numa casa sem relação fica.
--   3. O profissional bloqueia o estabelecimento: a linha sai.
--   4. OUTRO membro (operador) bloqueia o profissional: a linha da casa sai.
--   5. Linhas sem relação ficam (outro profissional na mesma casa).
--   6. Repetir o bloquear é idempotente e não dá erro.
--   7. Desbloquear não devolve o profissional; o administrador consegue incluí-lo de novo
--      por incluir_na_equipe (a volta só não é automática).
--   8. Membro novo com bloqueio prévio (nos dois sentidos) entra na casa: a linha sai.
--   9. O bloqueio e a saída da equipe são o mesmo comando: a linha já não existe no fim
--      de um único bloco que só chama bloquear.
--  10. Estrutura do incluir_na_equipe reescrito nesta migração (mesmos grants do 860) e as
--      travas que fecham a corrida com os gatilhos. A corrida em si, com duas conexões, fica
--      em scripts/corrida-equipe-bloqueio.sh: o pgTAP roda numa sessão só.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_temp;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-11-14 12:00:00-03';

select plan(47);

-- ── 1. Estrutura ───────────────────────────────────────────────────────────────

select is(
  (select prosecdef from pg_proc
    where proname = 'tirar_da_equipe_no_bloqueio' and pronamespace = 'privado'::regnamespace),
  true, 'privado.tirar_da_equipe_no_bloqueio é SECURITY DEFINER'
);

select ok(
  (select proconfig from pg_proc
    where proname = 'tirar_da_equipe_no_bloqueio' and pronamespace = 'privado'::regnamespace)
    @> array['search_path=""'],
  'privado.tirar_da_equipe_no_bloqueio tem search_path="" fixado'
);

select is(
  (select prosecdef from pg_proc
    where proname = 'tirar_da_equipe_no_membro_novo' and pronamespace = 'privado'::regnamespace),
  true, 'privado.tirar_da_equipe_no_membro_novo é SECURITY DEFINER'
);

select ok(
  (select proconfig from pg_proc
    where proname = 'tirar_da_equipe_no_membro_novo' and pronamespace = 'privado'::regnamespace)
    @> array['search_path=""'],
  'privado.tirar_da_equipe_no_membro_novo tem search_path="" fixado'
);

select ok(
  case when to_regprocedure('privado.tirar_da_equipe_no_bloqueio()') is null then false
       else not has_function_privilege('authenticated', 'privado.tirar_da_equipe_no_bloqueio()', 'execute') end,
  'authenticated NÃO executa privado.tirar_da_equipe_no_bloqueio'
);

select ok(
  case when to_regprocedure('privado.tirar_da_equipe_no_bloqueio()') is null then false
       else not has_function_privilege('anon', 'privado.tirar_da_equipe_no_bloqueio()', 'execute') end,
  'anon NÃO executa privado.tirar_da_equipe_no_bloqueio'
);

select ok(
  case when to_regprocedure('privado.tirar_da_equipe_no_membro_novo()') is null then false
       else not has_function_privilege('authenticated', 'privado.tirar_da_equipe_no_membro_novo()', 'execute') end,
  'authenticated NÃO executa privado.tirar_da_equipe_no_membro_novo'
);

select ok(
  case when to_regprocedure('privado.tirar_da_equipe_no_membro_novo()') is null then false
       else not has_function_privilege('anon', 'privado.tirar_da_equipe_no_membro_novo()', 'execute') end,
  'anon NÃO executa privado.tirar_da_equipe_no_membro_novo'
);

select has_trigger('public', 'bloqueio', 'trg_bloqueio_tirar_da_equipe',
  'public.bloqueio tem o gatilho trg_bloqueio_tirar_da_equipe');

select has_trigger('public', 'membro_estabelecimento', 'trg_membro_tirar_da_equipe',
  'public.membro_estabelecimento tem o gatilho trg_membro_tirar_da_equipe');

-- ── 1b. incluir_na_equipe reescrito e as travas da corrida ────────────────────

select is(
  (select prosecdef from pg_proc
    where proname = 'incluir_na_equipe' and pronamespace = 'public'::regnamespace),
  true, 'public.incluir_na_equipe continua SECURITY DEFINER'
);

select ok(
  (select proconfig from pg_proc
    where proname = 'incluir_na_equipe' and pronamespace = 'public'::regnamespace)
    @> array['search_path=""'],
  'public.incluir_na_equipe continua com search_path="" fixado'
);

select ok(
  has_function_privilege('authenticated', 'public.incluir_na_equipe(uuid, uuid)', 'execute'),
  'authenticated continua executando public.incluir_na_equipe'
);

select ok(
  not has_function_privilege('anon', 'public.incluir_na_equipe(uuid, uuid)', 'execute'),
  'anon continua sem executar public.incluir_na_equipe'
);

-- As travas são o conserto da corrida; um create or replace futuro que as perca reabre o
-- furo sem que nenhum caso de uma sessão só perceba.
select ok(
  (select prosrc from pg_proc
    where proname = 'incluir_na_equipe' and pronamespace = 'public'::regnamespace)
    ~* 'from public\.estabelecimento e where e\.id = incluir_na_equipe\.estabelecimento_id for update',
  'incluir_na_equipe trava a casa com FOR UPDATE'
);

select ok(
  (select prosrc from pg_proc
    where proname = 'incluir_na_equipe' and pronamespace = 'public'::regnamespace)
    ~* 'from public\.estabelecimento e where e\.id = incluir_na_equipe\.estabelecimento_id for update;\s*perform 1 from public\.profissional p where p\.id = incluir_na_equipe\.profissional_id for update;\s*select \* into v_user',
  'incluir_na_equipe trava casa e depois profissional, antes de ler a conta e conferir o bloqueio'
);

select ok(
  (select prosrc from pg_proc
    where proname = 'tirar_da_equipe_no_bloqueio' and pronamespace = 'privado'::regnamespace)
    ~* 'from public\.profissional p where p\.usuario_id in \(new\.autor_id, new\.bloqueado_id\) for update;\s*delete from public\.equipe_confianca'
  and (select prosrc from pg_proc
        where proname = 'tirar_da_equipe_no_bloqueio' and pronamespace = 'privado'::regnamespace)
      !~* 'public\.estabelecimento',
  'o gatilho do bloqueio trava só o profissional, antes do delete, e nunca a casa'
);

select ok(
  (select prosrc from pg_proc
    where proname = 'tirar_da_equipe_no_membro_novo' and pronamespace = 'privado'::regnamespace)
    ~* 'from public\.estabelecimento e where e\.id = new\.estabelecimento_id for no key update;\s*delete from public\.equipe_confianca',
  'o gatilho do membro novo trava a casa com FOR NO KEY UPDATE, antes do delete'
);

-- ── 2. Auxiliares de JWT e de contagem ─────────────────────────────────────────

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
  execute format('set local "request.jwt.claims" = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute format('set local "request.jwt.claim.sub" = %L', conta::text);
  execute sql into r;
  reset role;
  execute 'reset "request.jwt.claims"';
  execute 'reset "request.jwt.claim.sub"';
  return r;
end $$;

create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

-- ── 3. Massa de dados (sintética) ──────────────────────────────────────────────

create temp table ids as
select
  '86100000-0000-4000-8000-000000000001'::uuid as user_dono,      -- administrador das casas A e B
  '86100000-0000-4000-8000-000000000002'::uuid as user_operador,  -- operador da casa A
  '86100000-0000-4000-8000-000000000003'::uuid as user_dono_c,    -- administrador da casa C
  '86100000-0000-4000-8000-000000000004'::uuid as user_novo1,     -- entra na casa A depois (bloqueou P6)
  '86100000-0000-4000-8000-000000000005'::uuid as user_novo2,     -- entra na casa A depois (P7 o bloqueou)
  '86100000-0000-4000-8000-000000000011'::uuid as estab_a,
  '86100000-0000-4000-8000-000000000012'::uuid as estab_b,
  '86100000-0000-4000-8000-000000000013'::uuid as estab_c;

-- Profissionais P1..P8: usuario_id e id derivados do número.
create temp table prof as
select n,
       format('86100000-0000-4000-8000-%s', lpad((100 + n * 10 + 1)::text, 12, '0'))::uuid as usuario_id,
       format('86100000-0000-4000-8000-%s', lpad((100 + n * 10 + 2)::text, 12, '0'))::uuid as id
  from generate_series(1, 8) n;

create function pg_temp.pu(n int) returns uuid language sql as $$ select usuario_id from pg_temp.prof where n = $1 $$;
create function pg_temp.pp(n int) returns uuid language sql as $$ select id from pg_temp.prof where n = $1 $$;

create function pg_temp.na_equipe(estab uuid, p int) returns int language sql as $$
  select count(*)::int from public.equipe_confianca e
   where e.estabelecimento_id = estab and e.profissional_id = pg_temp.pp(p)
$$;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
values
  ((select user_dono from ids),     'contratante', 'Dono 861',     '+5561999998611', 'dono861@test.invalid',     '1985-01-01', '1.0', now(), false),
  ((select user_operador from ids), 'contratante', 'Operador 861', '+5561999998612', 'operador861@test.invalid', '1990-03-03', '1.0', now(), false),
  ((select user_dono_c from ids),   'contratante', 'Dono C 861',   '+5561999998613', 'donoc861@test.invalid',   '1982-04-04', '1.0', now(), false),
  ((select user_novo1 from ids),    'contratante', 'Novo Um 861',  '+5561999998614', 'novo1861@test.invalid',   '1991-05-05', '1.0', now(), false),
  ((select user_novo2 from ids),    'contratante', 'Novo Dois 861','+5561999998615', 'novo2861@test.invalid',   '1992-06-06', '1.0', now(), false);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
select p.usuario_id, 'profissional', 'Prof ' || p.n || ' 861', '+556198888' || lpad((7610 + p.n)::text, 4, '0'),
       'prof' || p.n || '861@test.invalid', '1995-01-01', '1.0', now(), false
  from prof p;

insert into public.profissional (id, usuario_id, ponto_base)
select p.id, p.usuario_id, 'POINT(-47.88 -15.78)'::extensions.geography from prof p;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values
  ((select estab_a from ids), 'Casa A 861', '86100000000101', 'food_service', 'Quadra 861', 'POINT(-47.88 -15.78)'::extensions.geography),
  ((select estab_b from ids), 'Casa B 861', '86100000000102', 'food_service', 'Quadra 862', 'POINT(-47.89 -15.79)'::extensions.geography),
  ((select estab_c from ids), 'Casa C 861', '86100000000103', 'food_service', 'Quadra 863', 'POINT(-47.90 -15.80)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values
  ((select user_dono from ids),     (select estab_a from ids), 'administrador'),
  ((select user_operador from ids), (select estab_a from ids), 'operador'),
  ((select user_dono from ids),     (select estab_b from ids), 'administrador'),
  ((select user_dono_c from ids),   (select estab_c from ids), 'administrador');

select pg_temp.autenticar((select user_dono from ids),     'dono861@test.invalid');
select pg_temp.autenticar((select user_operador from ids), 'operador861@test.invalid');
select pg_temp.autenticar(pg_temp.pu(2), 'prof2861@test.invalid');

-- Equipes de confiança (a escrita direta é só da massa do teste, como superusuário):
--   casa A: P1 P2 P3 P4 P6 P7 P8   casa B: P1 P4   casa C: P1 P2 P4
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select (select estab_a from ids), pg_temp.pp(n) from unnest(array[1,2,3,4,6,7,8]) n
union all
select (select estab_b from ids), pg_temp.pp(n) from unnest(array[1,4]) n
union all
select (select estab_c from ids), pg_temp.pp(n) from unnest(array[1,2,4]) n;

-- Turno verificado de P1 na casa A, só para o administrador poder incluí-lo de novo.
do $$
declare
  v_vaga uuid := gen_random_uuid();
  v_pos  uuid := gen_random_uuid();
begin
  insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em,
                           local, ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em, estado)
  values (v_vaga, '86100000-0000-4000-8000-000000000011',
          (select id from public.funcao where nome = 'garçom'),
          '86100000-0000-4000-8000-000000000001',
          '2026-11-10 10:00:00-03', '2026-11-10 16:00:00-03', 'Local 861',
          'POINT(-47.88 -15.78)'::extensions.geography, 15000, 1, true, false, false,
          'Responsável 861', 'urgencia', gen_random_uuid(), '2026-11-08 10:00:00-03', 'encerrada');

  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, falta, inicio_em, fim_em)
  values (v_pos, v_vaga, '86100000-0000-4000-8000-000000000112', 'cumprida',
          '2026-11-09 10:00:00-03', false, '2026-11-10 10:00:00-03', '2026-11-10 16:00:00-03');

  insert into public.turno (id, posicao_id, checkin_em, checkout_em, checkin_tipo, checkin_distancia_m,
                            verificacao, valor_acordado_centavos)
  values (gen_random_uuid(), v_pos, '2026-11-10 10:00:00-03', '2026-11-10 16:00:00-03',
          'geolocalizado', 50, 'verificado', 15000);
end $$;

-- Prova de que a massa começou como se descreveu: 7 + 2 + 3 linhas.
select is(
  (select count(*)::int from public.equipe_confianca
    where estabelecimento_id in (select estab_a from ids union select estab_b from ids union select estab_c from ids)),
  12, 'Massa: 7 profissionais na casa A, 2 na B e 3 na C'
);

-- ── 4. O administrador bloqueia o profissional (P1) ────────────────────────────

select is(
  pg_temp.como((select user_dono from ids),
               format('select public.bloquear(%L, %L)', 'profissional', pg_temp.pp(1)))->>'alvo_tipo',
  'profissional', 'O administrador bloqueia P1 (200)'
);

select is(pg_temp.na_equipe((select estab_a from ids), 1), 0,
  'Bloqueio do administrador: P1 sai da equipe da casa A');

select is(pg_temp.na_equipe((select estab_b from ids), 1), 0,
  'Bloqueio do administrador: P1 sai também da equipe da 2ª casa (B) de que ele é membro');

select is(pg_temp.na_equipe((select estab_c from ids), 1), 1,
  'P1 continua na equipe da casa C, onde ninguém tem bloqueio com ele');

select is(
  (select count(*)::int from public.equipe_confianca
    where profissional_id = pg_temp.pp(4)
      and estabelecimento_id in (select estab_a from ids union select estab_b from ids union select estab_c from ids)),
  3, 'Linhas sem relação ficam: P4 continua nas casas A, B e C');

-- ── 5. O profissional bloqueia o estabelecimento (P2 → casa A) ─────────────────

select is(
  pg_temp.como(pg_temp.pu(2),
               format('select public.bloquear(%L, %L)', 'estabelecimento', (select estab_a from ids)))->>'alvo_tipo',
  'estabelecimento', 'P2 bloqueia a casa A (200)'
);

select is(pg_temp.na_equipe((select estab_a from ids), 2), 0,
  'Bloqueio do profissional: P2 sai da equipe da casa A');

select is(pg_temp.na_equipe((select estab_c from ids), 2), 1,
  'P2 continua na equipe da casa C (a casa C não foi bloqueada)');

-- ── 6. OUTRO membro (operador) bloqueia o profissional (P3) ────────────────────

select is(pg_temp.na_equipe((select estab_a from ids), 3), 1, 'Antes: P3 está na equipe da casa A');

select is(
  pg_temp.como((select user_operador from ids),
               format('select public.bloquear(%L, %L)', 'profissional', pg_temp.pp(3)))->>'alvo_tipo',
  'profissional', 'O operador bloqueia P3 (200)'
);

select is(pg_temp.na_equipe((select estab_a from ids), 3), 0,
  'Bloqueio de outro membro (operador): P3 sai da equipe da casa A');

select is(
  (select count(*)::int from public.equipe_confianca
    where estabelecimento_id = (select estab_a from ids)
      and profissional_id in (pg_temp.pp(4), pg_temp.pp(6), pg_temp.pp(7), pg_temp.pp(8))),
  4, 'Linhas sem relação ficam: P4, P6, P7 e P8 continuam na casa A');

-- ── 7. Repetir o bloquear é idempotente ────────────────────────────────────────

select lives_ok(
  pg_temp.por((select user_dono from ids),
              format('select public.bloquear(%L, %L)', 'profissional', pg_temp.pp(1))),
  'Repetir o bloquear de P1 não dá erro'
);

select is(
  pg_temp.na_equipe((select estab_a from ids), 1) + pg_temp.na_equipe((select estab_b from ids), 1), 0,
  'Depois do bloquear repetido, P1 segue fora das casas A e B');

-- ── 8. Desbloquear não devolve; o administrador inclui de novo ─────────────────

select lives_ok(
  pg_temp.por((select user_dono from ids),
              format('select public.desbloquear(%L, %L)', 'profissional', pg_temp.pp(1))),
  'O administrador desbloqueia P1'
);

select is(
  pg_temp.na_equipe((select estab_a from ids), 1) + pg_temp.na_equipe((select estab_b from ids), 1), 0,
  'Depois do desbloquear, P1 NÃO volta sozinho às casas A e B (count = 0)');

select is(
  pg_temp.como((select user_dono from ids),
               format('select public.incluir_na_equipe(%L, %L)', (select estab_a from ids), pg_temp.pp(1))),
  jsonb_build_object('estabelecimento_id', (select estab_a from ids), 'profissional_id', pg_temp.pp(1)),
  'O administrador inclui P1 de novo por incluir_na_equipe (a volta só não é automática)');

select is(pg_temp.na_equipe((select estab_a from ids), 1), 1,
  'P1 está de volta na casa A depois da inclusão deliberada');

-- ── 9. Membro novo com bloqueio prévio entra na casa ───────────────────────────

-- O novo1 bloqueou P6; o P7 bloqueou o novo2. Nenhum dos dois é membro ainda.
insert into public.bloqueio (autor_id, bloqueado_id, criado_em)
values (pg_temp.pu(7), (select user_novo2 from ids), '2026-11-13 10:00:00-03'),
       ((select user_novo1 from ids), pg_temp.pu(6), '2026-11-13 10:05:00-03');

select is(
  pg_temp.na_equipe((select estab_a from ids), 6) + pg_temp.na_equipe((select estab_a from ids), 7), 2,
  'Antes de entrar na casa, o bloqueio de quem ainda não é membro não tira ninguém da equipe');

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ((select user_novo1 from ids), (select estab_a from ids), 'operador');

select is(pg_temp.na_equipe((select estab_a from ids), 6), 0,
  'Membro novo (novo1, que bloqueou P6) entra na casa A: P6 sai da equipe');

select is(pg_temp.na_equipe((select estab_a from ids), 7), 1,
  'A entrada do novo1 não tira P7, que não tem bloqueio com ele');

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ((select user_novo2 from ids), (select estab_a from ids), 'operador');

select is(pg_temp.na_equipe((select estab_a from ids), 7), 0,
  'Membro novo (novo2, bloqueado por P7) entra na casa A: P7 sai da equipe');

select is(
  (select count(*)::int from public.equipe_confianca
    where estabelecimento_id = (select estab_a from ids)
      and profissional_id in (pg_temp.pp(1), pg_temp.pp(4), pg_temp.pp(8))),
  3, 'Linhas sem relação ficam: P1, P4 e P8 continuam na casa A');

select is(
  (select count(*)::int from public.equipe_confianca
    where estabelecimento_id = (select estab_b from ids)
      and profissional_id = pg_temp.pp(4)),
  1, 'O membro novo da casa A não mexe na equipe da casa B (P4 fica)');

-- ── 10. Bloqueio e saída da equipe são o mesmo comando ─────────────────────────
--
-- Um único bloco só chama bloquear e, na sequência, conta a linha: sem passo
-- intermediário (nada de rodar a limpeza à parte).

create function pg_temp.bloqueia_e_conta(conta uuid, alvo uuid, estab uuid, p int) returns int
language plpgsql as $$
begin
  perform pg_temp.como(conta, format('select public.bloquear(%L, %L)', 'profissional', alvo));
  return pg_temp.na_equipe(estab, p);
end $$;

select is(pg_temp.na_equipe((select estab_a from ids), 8), 1, 'Antes: P8 está na equipe da casa A');

select is(
  pg_temp.bloqueia_e_conta((select user_dono from ids), pg_temp.pp(8), (select estab_a from ids), 8),
  0, 'Logo depois de bloquear(...), sem passo intermediário, P8 já não está na equipe');

-- ── 11. Integridade geral ──────────────────────────────────────────────────────

select is(
  (select count(*)::int from public.equipe_confianca e
    join public.profissional p on p.id = e.profissional_id
    join public.membro_estabelecimento m on m.estabelecimento_id = e.estabelecimento_id
    join public.bloqueio b on (b.autor_id = m.usuario_id and b.bloqueado_id = p.usuario_id)
                           or (b.bloqueado_id = m.usuario_id and b.autor_id = p.usuario_id)
   where e.estabelecimento_id in (select estab_a from ids union select estab_b from ids union select estab_c from ids)),
  0, 'Integridade: nenhuma linha da equipe tem bloqueio ativo com um membro da casa');

select is(
  (select count(*)::int from public.equipe_confianca
    where estabelecimento_id in (select estab_a from ids union select estab_b from ids union select estab_c from ids)),
  6, 'Integridade: sobram 6 linhas (A: P1 P4; B: P4; C: P1 P2 P4)');

select * from finish();

rollback;
