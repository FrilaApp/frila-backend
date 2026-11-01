-- Teste pgTAP: Coordenadas exatas do estabelecimento em meus_turnos (Cartão 72 · RN06, RN22, v1.1 · Contrato 0.2.47)
--
-- Valida:
-- 1. Coordenadas aparecem para o profissional do turno CONFIRMADO (LGPD art. 7º, V - execução de contrato).
-- 2. Coordenadas aparecem para o profissional do turno CUMPRIDO e VERIFICADO (LGPD art. 7º, VI - exercício regular de direitos).
-- 3. Coordenadas retornam NULO para o profissional do turno CUMPRIDO NÃO VERIFICADO (LGPD art. 6º, III - minimização).
-- 4. Coordenadas retornam NULO para o profissional do turno CANCELADO (LGPD art. 6º, III).
-- 5. Membro do estabelecimento lê coordenadas de sua própria vaga normalmente.
-- 6. Terceiros nunca veem turnos ou coordenadas alheias (RF13).
-- 7. Contratante sem estabelecimento_id recebe lista vazia ([]).
-- 8. Recusa com 403 sem_permissao quando terceiro tenta passar estabelecimento_id alheio.
-- 9. Recusa com 401 nao_autenticado quando chamador é anônimo.
-- 10. Recusa com 401 nao_autenticado quando chamador é conta anonimizada.
-- 11. privado.candidatura_em_json não expõe coordenadas para mera candidatura.
-- 12. privado.turno_em_json com autor terceiro devolve ponto = null.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(15);

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

-- 1. Criação das contas de teste
select pg_temp.autenticar('78400000-0000-4000-8000-0000000000d1', 'dona784@turnos.test');
select pg_temp.autenticar('78400000-0000-4000-8000-0000000000d2', 'outra784@turnos.test');
select pg_temp.autenticar('78400000-0000-4000-8000-0000000000e1', 'prof1_784@turnos.test');
select pg_temp.autenticar('78400000-0000-4000-8000-0000000000e2', 'prof2_784@turnos.test');
select pg_temp.autenticar('78400000-0000-4000-8000-000000000031', 'terceiro784@turnos.test');
select pg_temp.autenticar('78400000-0000-4000-8000-0000000000a1', 'anon784@turnos.test');

select pg_temp.como('78400000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona 784','+5561978400001','1985-01-01','2026-09-22') $$);
select pg_temp.como('78400000-0000-4000-8000-0000000000d2',
  $$ select public.criar_conta('contratante','Dona Fora 784','+5561978400002','1985-01-01','2026-09-22') $$);
select pg_temp.como('78400000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Profissional Um 784','+5561978400011','1995-01-01','2026-09-22') $$);
select pg_temp.como('78400000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Profissional Dois 784','+5561978400012','1995-01-01','2026-09-22') $$);
select pg_temp.como('78400000-0000-4000-8000-000000000031',
  $$ select public.criar_conta('contratante','Terceiro 784','+5561978400021','1990-01-01','2026-09-22') $$);
select pg_temp.como('78400000-0000-4000-8000-0000000000a1',
  $$ select public.criar_conta('profissional','Anon 784','+5561978400031','1992-01-01','2026-09-22') $$);
update public.usuario set estado = 'anonimizada', anonimizado_em = now() where id = '78400000-0000-4000-8000-0000000000a1';

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como('78400000-0000-4000-8000-0000000000e1', format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.790000,"longitude":-47.885000}'::jsonb) $$, (select garcom from fn)));
select pg_temp.como('78400000-0000-4000-8000-0000000000e2', format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.790000,"longitude":-47.885000}'::jsonb) $$, (select garcom from fn)));

-- 2. Cadastro de estabelecimento com coordenadas exatas
create temp table casa as
  select (pg_temp.como('78400000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Bar do Lago 784','04252011000110','food_service',
         'SHIS QI 5 Bloco B','{"latitude":-15.791234,"longitude":-47.886543}') $$)->>'id')::uuid as id;

create temp table quando as
  select (privado.agora() + interval '1 day')          as v1_ini,
         (privado.agora() + interval '1 day 6 hours')  as v1_fim,
         (privado.agora() + interval '2 days')         as v2_ini,
         (privado.agora() + interval '2 days 6 hours') as v2_fim,
         (privado.agora() + interval '3 days')         as v3_ini,
         (privado.agora() + interval '3 days 6 hours') as v3_fim,
         (privado.agora() + interval '4 days')         as v4_ini,
         (privado.agora() + interval '4 days 6 hours') as v4_fim;

-- 3. Publicação de vagas e geração de turnos
create function pg_temp.publicar(ini timestamptz, fim timestamptz, chave uuid) returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como('78400000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'Lago Sul QI 5',
         '{"latitude":-15.791234,"longitude":-47.886543}'::jsonb,
         18000, 1, true, true, false, 'Gerente Carlos', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn), ini, fim, chave))->>'vaga_id')::uuid;
end $corpo$;

create temp table ids_vagas as
  select pg_temp.publicar((select v1_ini from quando), (select v1_fim from quando),
           '78400000-0000-4000-8000-000000000001') as v_futura,
         pg_temp.publicar((select v2_ini from quando), (select v2_fim from quando),
           '78400000-0000-4000-8000-000000000002') as v_verificado,
         pg_temp.publicar((select v3_ini from quando), (select v3_fim from quando),
           '78400000-0000-4000-8000-000000000003') as v_nao_verificado,
         pg_temp.publicar((select v4_ini from quando), (select v4_fim from quando),
           '78400000-0000-4000-8000-000000000004') as v_cancelada;

-- Criação dos turnos de prof1
create temp table turnos as
  select (pg_temp.como('78400000-0000-4000-8000-0000000000e1',
           format($$ select public.candidatar(%L) $$, (select v_futura from ids_vagas)))->>'turno_id')::uuid as t_futura,
         (pg_temp.como('78400000-0000-4000-8000-0000000000e1',
           format($$ select public.candidatar(%L) $$, (select v_verificado from ids_vagas)))->>'turno_id')::uuid as t_verificado,
         (pg_temp.como('78400000-0000-4000-8000-0000000000e1',
           format($$ select public.candidatar(%L) $$, (select v_nao_verificado from ids_vagas)))->>'turno_id')::uuid as t_nao_verificado,
         (pg_temp.como('78400000-0000-4000-8000-0000000000e1',
           format($$ select public.candidatar(%L) $$, (select v_cancelada from ids_vagas)))->>'turno_id')::uuid as t_cancelada;

-- Ajusta estados reais para simular o ciclo de vida
-- Turno 2: cumprida + verificado
update public.posicao set estado = 'cumprida'
 where id = (select posicao_id from public.turno where id = (select t_verificado from turnos));
update public.turno set checkin_em = (select v2_ini from quando),
                        checkin_tipo = 'geolocalizado',
                        checkin_distancia_m = 50,
                        verificacao = 'verificado'
 where id = (select t_verificado from turnos);

-- Turno 3: cumprida + nao_verificado
update public.posicao set estado = 'cumprida'
 where id = (select posicao_id from public.turno where id = (select t_nao_verificado from turnos));
update public.turno set checkin_em = (select v3_ini from quando),
                        checkin_tipo = 'manual',
                        checkin_distancia_m = 350,
                        verificacao = 'nao_verificado'
 where id = (select t_nao_verificado from turnos);

-- Turno 4: cancelada
update public.posicao set estado = 'cancelada'
 where id = (select posicao_id from public.turno where id = (select t_cancelada from turnos));

-- ── 1. Profissional vê coordenadas no turno CONFIRMADO (futuro/em andamento) ──
create temp table turnos_prof1 as
  select pg_temp.como('78400000-0000-4000-8000-0000000000e1', $$ select public.meus_turnos() $$) as lista;

select is(
  (select (e->'vaga'->'ponto'->>'latitude')::numeric
     from jsonb_array_elements((select lista from turnos_prof1)) e
    where e->>'id' = (select t_futura from turnos)::text),
  -15.791234::numeric,
  'Turno CONFIRMADA: profissional vê latitude exata do estabelecimento (LGPD 7º, V)');

select is(
  (select (e->'vaga'->'ponto'->>'longitude')::numeric
     from jsonb_array_elements((select lista from turnos_prof1)) e
    where e->>'id' = (select t_futura from turnos)::text),
  -47.886543::numeric,
  'Turno CONFIRMADA: profissional vê longitude exata do estabelecimento (LGPD 7º, V)');

-- ── 2. Profissional vê coordenadas no turno CUMPRIDO e VERIFICADO ─────────────
select is(
  (select (e->'vaga'->'ponto'->>'latitude')::numeric
     from jsonb_array_elements((select lista from turnos_prof1)) e
    where e->>'id' = (select t_verificado from turnos)::text),
  -15.791234::numeric,
  'Turno CUMPRIDA + VERIFICADO: coordenadas preservadas para exercício regular de direitos (LGPD 7º, VI)');

select is(
  (select (e->'vaga'->'ponto'->>'longitude')::numeric
     from jsonb_array_elements((select lista from turnos_prof1)) e
    where e->>'id' = (select t_verificado from turnos)::text),
  -47.886543::numeric,
  'Turno CUMPRIDA + VERIFICADO: longitude preservada para histórico probatório (LGPD 7º, VI)');

-- ── 3. Profissional recebe ponto NULO no turno cumprido NÃO VERIFICADO ────────
select is(
  (select e->'vaga'->'ponto'
     from jsonb_array_elements((select lista from turnos_prof1)) e
    where e->>'id' = (select t_nao_verificado from turnos)::text),
  'null'::jsonb,
  'Turno CUMPRIDA + NÃO VERIFICADO: ponto é NULO (LGPD 6º, III - minimização)');

-- ── 4. Profissional recebe ponto NULO no turno CANCELADO ──────────────────────
select is(
  (select e->'vaga'->'ponto'
     from jsonb_array_elements((select lista from turnos_prof1)) e
    where e->>'id' = (select t_cancelada from turnos)::text),
  'null'::jsonb,
  'Turno CANCELADA: ponto é NULO (LGPD 6º, III - cessação da necessidade)');

-- ── 5. Membro do estabelecimento vê coordenadas normalmente ──────────────────
create temp table turnos_casa as
  select pg_temp.como('78400000-0000-4000-8000-0000000000d1',
    format($$ select public.meus_turnos(estabelecimento_id => %L) $$, (select id from casa))) as lista;

select is(
  (select (e->'vaga'->'ponto'->>'latitude')::numeric
     from jsonb_array_elements((select lista from turnos_casa)) e
    where e->>'id' = (select t_futura from turnos)::text),
  -15.791234::numeric,
  'Membro da casa lê coordenadas de sua vaga no turno confirmado');

select is(
  (select (e->'vaga'->'ponto'->>'latitude')::numeric
     from jsonb_array_elements((select lista from turnos_casa)) e
    where e->>'id' = (select t_cancelada from turnos)::text),
  -15.791234::numeric,
  'Membro da casa lê coordenadas de sua vaga mesmo em turno cancelado');

-- ── 6. Terceiro (prof2) nunca vê turnos ou coordenadas alheias ────────────────
select is(
  (select count(*)::int
     from jsonb_array_elements(pg_temp.como('78400000-0000-4000-8000-0000000000e2',
            $$ select public.meus_turnos() $$)) e
    where e->>'id' in ((select t_futura from turnos)::text, (select t_verificado from turnos)::text)),
  0,
  'RF13: terceiro profissional nunca vê turnos de outra pessoa');

-- ── 7. Contratante sem estabelecimento_id recebe lista vazia ──────────────────
select is(
  pg_temp.como('78400000-0000-4000-8000-000000000031', $$ select public.meus_turnos() $$),
  '[]'::jsonb,
  'Contratante sem estabelecimento_id recebe [] válido');

-- ── 8. Recusa 403 sem_permissao para terceiro com estabelecimento_id alheio ───
select throws_ok(
  format($$ select pg_temp.como('78400000-0000-4000-8000-0000000000d2',
       $x$ select public.meus_turnos(estabelecimento_id => %L) $x$) $$, (select id from casa)),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  '403 sem_permissao quando não é membro da casa');

-- ── 9. Recusa 401 nao_autenticado para usuário anônimo ────────────────────────
select throws_ok(
  $$ select public.meus_turnos() $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  '401 nao_autenticado para chamada sem token');

-- ── 10. Recusa 401 nao_autenticado para conta anonimizada ─────────────────────
select throws_ok(
  $$ select pg_temp.como('78400000-0000-4000-8000-0000000000a1', $x$ select public.meus_turnos() $x$) $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  '401 nao_autenticado para conta com estado anonimizada');

-- ── 11. Candidatura em seleção não expõe coordenadas antes da confirmação ─────
-- Cria vaga em seleção e candidatura pendente
insert into public.posicao (vaga_id, estado, inicio_em, fim_em)
values ((select v_futura from ids_vagas), 'aberta', (select v1_ini from quando), (select v1_fim from quando));

insert into public.candidatura (posicao_id, profissional_id, estado)
values ((select id from public.posicao where vaga_id = (select v_futura from ids_vagas) and estado = 'aberta' limit 1),
        (select id from public.profissional where usuario_id = '78400000-0000-4000-8000-0000000000e2'),
        'pendente');

select is(
  (select privado.candidatura_em_json(c.id)->'vaga'->'ponto'
     from public.candidatura c
    where c.profissional_id = (select id from public.profissional where usuario_id = '78400000-0000-4000-8000-0000000000e2')),
  null,
  'candidatura_em_json não expõe coordenadas para candidato pendente');

-- ── 12. privado.turno_em_json com autor terceiro devolve ponto = null ─────────
select is(
  (select privado.turno_em_json((select t_futura from turnos), '78400000-0000-4000-8000-000000000031')->'vaga'->'ponto'),
  'null'::jsonb,
  'privado.turno_em_json invocado com autor terceiro devolve ponto = null');

rollback;
