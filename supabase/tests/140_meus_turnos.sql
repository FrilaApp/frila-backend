-- `meus_turnos`: o acompanhamento depois da confirmação, dos dois lados.
--
-- A mesma operação serve o profissional e a casa, e o que muda é quem aparece como
-- `contraparte`. Três coisas são cobradas aqui:
--
--   RN10  nenhum telefone sai por esta lista; o contato tem porta própria e prazo
--   RN07  `pode_avaliar` só depois do fim previsto e com presença verificada
--   RF13  turno de outra pessoa nunca aparece
--
-- Ids próprios, começando em `ad000000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(20);

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

select pg_temp.autenticar('ad000000-0000-4000-8000-0000000000d1','dona@turnos.test');
select pg_temp.autenticar('ad000000-0000-4000-8000-0000000000d2','outra@turnos.test');
select pg_temp.autenticar('ad000000-0000-4000-8000-0000000000e1','e1@turnos.test');
select pg_temp.autenticar('ad000000-0000-4000-8000-0000000000e2','e2@turnos.test');

select pg_temp.como('ad000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona dos Turnos','+5561966660001','1980-01-01','2026-09-22') $$);
select pg_temp.como('ad000000-0000-4000-8000-0000000000d2',
  $$ select public.criar_conta('contratante','Dona de Fora','+5561966660002','1980-01-01','2026-09-22') $$);
select pg_temp.como('ad000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Turno Um','+5561966660011','1995-01-01','2026-09-22') $$);
select pg_temp.como('ad000000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Turno Dois','+5561966660012','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create function pg_temp.perfil(conta uuid) returns void
language plpgsql as $corpo$
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, (select garcom from fn)));
end $corpo$;

select pg_temp.perfil('ad000000-0000-4000-8000-0000000000e1');
select pg_temp.perfil('ad000000-0000-4000-8000-0000000000e2');

create temp table casa as
  select (pg_temp.como('ad000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa dos Turnos','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create temp table quando as
  select (privado.agora() + interval '2 days')         as proximo_ini,
         (privado.agora() + interval '2 days 6 hours') as proximo_fim,
         (privado.agora() + interval '9 days')         as distante_ini,
         (privado.agora() + interval '9 days 6 hours') as distante_fim;

create function pg_temp.publicar(ini timestamptz, fim timestamptz, chave uuid) returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como('ad000000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 406',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 2, true, true, false, 'Seu Zé', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn), ini, fim, chave))->>'vaga_id')::uuid;
end $corpo$;

create temp table vagas as
  select pg_temp.publicar((select proximo_ini from quando), (select proximo_fim from quando),
           'ad000000-0000-4000-8000-000000000001') as proximo,
         pg_temp.publicar((select distante_ini from quando), (select distante_fim from quando),
           'ad000000-0000-4000-8000-000000000002') as distante;

-- e1 pega os dois turnos; e2 pega só o distante. É o que prova que a lista de cada um
-- traz só o que é seu.
create temp table t1 as
  select (pg_temp.como('ad000000-0000-4000-8000-0000000000e1',
    format($$ select public.candidatar(%L) $$, (select distante from vagas)))->>'turno_id')::uuid as distante,
         (pg_temp.como('ad000000-0000-4000-8000-0000000000e1',
    format($$ select public.candidatar(%L) $$, (select proximo from vagas)))->>'turno_id')::uuid as proximo;

create temp table t2 as
  select (pg_temp.como('ad000000-0000-4000-8000-0000000000e2',
    format($$ select public.candidatar(%L) $$, (select distante from vagas)))->>'turno_id')::uuid as distante;

-- ── Sem sessão ────────────────────────────────────────────────────────────────
select throws_ok(
  $$ select public.meus_turnos() $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não há lista de turnos');

-- ── A lista do profissional ───────────────────────────────────────────────────
create temp table lista as
  select pg_temp.como('ad000000-0000-4000-8000-0000000000e1',
    $$ select public.meus_turnos() $$) as j;

select is((select jsonb_array_length(j) from lista), 2,
  'o profissional vê os dois turnos que são dele');

select is(
  (select array_agg(e->>'id')
     from lista, jsonb_array_elements((select j from lista)) e),
  array[(select proximo from t1)::text, (select distante from t1)::text],
  'RF13: hoje e os próximos primeiro, do mais próximo para o mais distante');

select is(
  (select array_agg(k order by k) from lista, jsonb_object_keys((select j->0 from lista)) k),
  array['checkin_confirmado_em','checkin_distancia_m','checkin_em','checkin_tipo',
        'checkout_distancia_m','checkout_em','contato_visivel_ate','contraparte','id',
        'pode_avaliar','posicao_id','vaga','valor_acordado_centavos','verificacao'],
  'cada turno traz exatamente os campos do schema Turno do contrato');

select is(
  (select array_agg(k order by k) from lista, jsonb_object_keys((select j->0->'vaga' from lista)) k),
  array['fim_em','funcao','id','inicio_em','local','valor_centavos'],
  'e a vaga vem como VagaResumo, com a função pelo nome');

-- RN10: o telefone tem porta própria, e uma lista que já o trouxesse tornaria o prazo
-- decorativo.
select is(
  (select count(*)::int from lista
    where (select j from lista)::text like '%+55619666600%'),
  0,
  'RN10: nenhum telefone sai por meus_turnos');

select is(
  (select (j->0->>'contato_visivel_ate')::timestamptz from lista),
  (select proximo_fim + interval '7 days' from quando),
  'RN10: contato_visivel_ate é o fim previsto mais 7 dias');

select is((select j->0->>'verificacao' from lista), 'pendente',
  'o turno recém-confirmado ainda não tem presença verificada');

select is((select (j->0->>'pode_avaliar')::boolean from lista), false,
  'RN07: não se avalia antes do fim do turno');

select is(
  (select j->0->>'valor_acordado_centavos' from lista),
  '18000',
  'RN11: o valor acordado é o que foi copiado na confirmação');

-- A contraparte do profissional é a casa.
select is((select j->0->'contraparte'->>'tipo' from lista), 'estabelecimento',
  'para o profissional, a contraparte é o estabelecimento');

select is((select j->0->'contraparte'->>'nome' from lista), 'Casa dos Turnos',
  'e vem com o nome da casa');

-- ── Turno de outra pessoa ─────────────────────────────────────────────────────
select is(
  (select count(*)::int
     from jsonb_array_elements(pg_temp.como('ad000000-0000-4000-8000-0000000000e2',
            $$ select public.meus_turnos() $$)) e
    where e->>'id' in ((select proximo from t1)::text, (select distante from t1)::text)),
  0,
  'RF13: o turno de outra pessoa nunca aparece');

select is(
  (select jsonb_array_length(pg_temp.como('ad000000-0000-4000-8000-0000000000e2',
     $$ select public.meus_turnos() $$))),
  1,
  'e quem tem um turno vê um turno');

-- ── A lista da casa ───────────────────────────────────────────────────────────
create temp table da_casa as
  select pg_temp.como('ad000000-0000-4000-8000-0000000000d1',
    format($$ select public.meus_turnos(estabelecimento_id => %L) $$, (select id from casa))) as j;

select is((select jsonb_array_length(j) from da_casa), 3,
  'a casa vê os três turnos das suas vagas');

select is((select j->0->'contraparte'->>'tipo' from da_casa), 'profissional',
  'para a casa, a contraparte é o profissional');

select throws_ok(
  format($$ select pg_temp.como('ad000000-0000-4000-8000-0000000000d2',
       $x$ select public.meus_turnos(estabelecimento_id => %L) $x$) $$, (select id from casa)),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'RF21: quem não é membro não lê os turnos da casa');

select is(
  pg_temp.como('ad000000-0000-4000-8000-0000000000d1', $$ select public.meus_turnos() $$),
  '[]'::jsonb,
  'contratante sem estabelecimento_id recebe lista vazia, e não erro: a pergunta é válida');

-- ── O filtro de janela ────────────────────────────────────────────────────────
select is(
  (select jsonb_array_length(pg_temp.como('ad000000-0000-4000-8000-0000000000e1',
     format($$ select public.meus_turnos(ate => %L) $$,
            (select proximo_fim from quando))))),
  1,
  'o filtro por janela corta o turno distante');

-- ── RN07 depois do fim, com presença verificada ───────────────────────────────
--
-- O relógio do produto anda para depois do fim, e o turno ganha presença verificada:
-- é a única combinação em que `pode_avaliar` fica verdadeiro.
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
select set_config('frila.agora',
  (select (proximo_fim + interval '1 hour')::text from quando), true);

update public.turno set checkin_em = (select proximo_ini from quando),
                        checkin_tipo = 'geolocalizado',
                        checkin_distancia_m = 30,
                        verificacao = 'verificado'
 where id = (select proximo from t1);

select is(
  (select (e->>'pode_avaliar')::boolean
     from jsonb_array_elements(pg_temp.como('ad000000-0000-4000-8000-0000000000e1',
            $$ select public.meus_turnos() $$)) e
    where e->>'id' = (select proximo from t1)::text),
  true,
  'RN07: depois do fim e com presença verificada, pode avaliar');

select set_config('frila.agora', '', true);

select * from finish();
rollback;
