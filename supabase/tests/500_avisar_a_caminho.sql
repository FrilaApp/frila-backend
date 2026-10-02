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
select plan(28);

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

-- ── A coluna e as permissões ──────────────────────────────────────────────────
select has_column('public', 'turno', 'a_caminho_em',
  'US14: turno guarda o instante do aviso "estou a caminho"');
select col_type_is('public', 'turno', 'a_caminho_em', 'timestamp with time zone',
  'RN18: o aviso é timestamptz, como todo tempo do esquema');
select ok(not has_function_privilege('anon', 'public.avisar_a_caminho(uuid)', 'execute'),
  'anon não chama avisar_a_caminho');
select ok(has_function_privilege('authenticated', 'public.avisar_a_caminho(uuid)', 'execute'),
  'authenticated chama avisar_a_caminho');

-- ── Quem pode ─────────────────────────────────────────────────────────────────
select throws_ok(
  format($$ select public.avisar_a_caminho(%L) $$, (select a from t)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não há aviso');

select throws_ok(
  format($$ select pg_temp.avisar('ca000000-0000-4000-8000-0000000000d1', %L) $$, (select a from t)),
  'PGRST',
  '{"code" : "perfil_incompativel", "message" : "perfil_incompativel", "details" : null, "hint" : null}',
  'quem contrata não avisa que está a caminho');

select throws_ok(
  format($$ select pg_temp.avisar('ca000000-0000-4000-8000-0000000000e2', %L) $$, (select a from t)),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'turno de outro profissional é 403 sem_permissao');

select throws_ok(
  $$ select pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1',
                           'ca000000-0000-4000-8000-00000000ffff') $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'turno inexistente responde igual ao de outro, e não diz que não existe');

select throws_ok(
  $$ select pg_temp.como('ca000000-0000-4000-8000-0000000000e1',
                         'select public.avisar_a_caminho(null)') $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "turno_id", "hint" : null}',
  'sem turno_id é campo_obrigatorio');

-- ── A janela: de 3 h antes até 15 min depois do início ────────────────────────
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- O que a presença e a taxa diziam antes de qualquer aviso.
create temp table antes as
  select (select to_jsonb(p) from public.profissional p
           where p.usuario_id = 'ca000000-0000-4000-8000-0000000000e1') as profissional,
         (select to_jsonb(x) - 'a_caminho_em' from public.turno x where x.id = (select a from t)) as turno;

select pg_temp.relogio((select ini - interval '3 hours 1 second' from quando));
select throws_ok(
  format($$ select pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1', %L) $$, (select a from t)),
  'PGRST',
  '{"code" : "a_caminho_fora_da_janela", "message" : "a_caminho_fora_da_janela", "details" : null, "hint" : null}',
  'um segundo antes das 3 h é 422 a_caminho_fora_da_janela');

select pg_temp.relogio((select ini - interval '3 hours' from quando));
create temp table primeiro as
  select pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1', (select a from t)) as j;

select is((select j from primeiro),
  jsonb_build_object('turno_id', (select a from t),
                     'a_caminho_em', (select ini - interval '3 hours' from quando)),
  'exatamente 3 h antes entra, e a resposta é ResultadoACaminho');

select is((select x.a_caminho_em from public.turno x where x.id = (select a from t)),
  (select ini - interval '3 hours' from quando),
  'o instante gravado é o do relógio do servidor');

-- ── Idempotência ──────────────────────────────────────────────────────────────
select pg_temp.relogio((select ini - interval '1 hour' from quando));
select is(pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1', (select a from t)),
  (select j from primeiro),
  'a segunda chamada devolve o mesmo registro');

select is((select x.a_caminho_em from public.turno x where x.id = (select a from t)),
  (select ini - interval '3 hours' from quando),
  'e não move o instante já gravado');

-- O reenvio que chega depois de a janela fechar é a mesma chamada atrasada pela rede,
-- e não um aviso novo: devolve o registro em vez de recusar o que já foi aceito.
select pg_temp.relogio((select ini + interval '1 hour' from quando));
select is(pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1', (select a from t)),
  (select j from primeiro),
  'o reenvio depois da janela devolve o registro já gravado');

-- ── A borda de cima ───────────────────────────────────────────────────────────
select pg_temp.relogio((select ini + interval '1 day 15 minutes' from quando));
select is(
  (pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1', (select b from t))->>'a_caminho_em')::timestamptz,
  (select ini + interval '1 day 15 minutes' from quando),
  'exatamente 15 min depois do início entra');

select pg_temp.relogio((select ini + interval '2 days 15 minutes 1 second' from quando));
select throws_ok(
  format($$ select pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1', %L) $$, (select c from t)),
  'PGRST',
  '{"code" : "a_caminho_fora_da_janela", "message" : "a_caminho_fora_da_janela", "details" : null, "hint" : null}',
  'um segundo depois dos 15 min é 422 a_caminho_fora_da_janela');

select is((select x.a_caminho_em from public.turno x where x.id = (select c from t)), null,
  'e a recusa não grava nada');

-- ── Não é presença nem taxa ───────────────────────────────────────────────────
select is(
  (select to_jsonb(x) - 'a_caminho_em' from public.turno x where x.id = (select a from t)),
  (select turno from antes),
  'o aviso só escreve a_caminho_em: check-in, verificação e check-out ficam como estavam');

select is((select x.verificacao::text from public.turno x where x.id = (select a from t)), 'pendente',
  'a presença continua pendente depois do aviso');

select is(
  (select to_jsonb(p) from public.profissional p
    where p.usuario_id = 'ca000000-0000-4000-8000-0000000000e1'),
  (select profissional from antes),
  'a taxa de comparecimento e o resto do profissional não mudam');

-- ── Posição cancelada ─────────────────────────────────────────────────────────
-- A posição cancelada guarda o profissional (RN12), mas ele não está mais confirmado:
-- um aviso ali diria à casa que vem alguém que não vem.
update public.posicao p set estado = 'cancelada'
 where p.id = (select x.posicao_id from public.turno x where x.id = (select d from t));

select pg_temp.relogio((select ini + interval '3 days' - interval '1 hour' from quando));
select throws_ok(
  format($$ select pg_temp.avisar('ca000000-0000-4000-8000-0000000000e1', %L) $$, (select d from t)),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'posição cancelada é 403 sem_permissao, mesmo dentro da janela');

-- ── O painel do contratante ───────────────────────────────────────────────────
create function pg_temp.posicao_no_painel(turno uuid) returns jsonb
language sql as $$
  select po
    from jsonb_array_elements(pg_temp.como('ca000000-0000-4000-8000-0000000000d1', format(
           $x$ select public.painel_estabelecimento(%L, %L, %L) $x$,
           (select id from casa),
           (select ini - interval '1 day' from quando),
           (select fim + interval '5 days' from quando)))->'vagas') v,
         jsonb_array_elements(v->'posicoes') po
   where (po->>'turno_id')::uuid = turno;
$$;

select is((pg_temp.posicao_no_painel((select a from t))->>'a_caminho_em')::timestamptz,
  (select ini - interval '3 hours' from quando),
  'US14: o painel mostra a_caminho_em na posição de quem avisou');

select is(pg_temp.posicao_no_painel((select c from t))->'a_caminho_em', 'null'::jsonb,
  'e null, com a chave presente, na posição de quem não avisou');

select is(
  (select array_agg(k order by k) from jsonb_object_keys(pg_temp.posicao_no_painel((select a from t))) k),
  array['a_caminho_em','cancelamento','checkin_confirmado_em','checkin_em','checkin_tipo','em_atraso','estado','id','profissional','turno_id','verificacao'],
  'PosicaoNoPainel traz exatamente os campos do contrato (0.2.31)');

-- ── Meu turno ─────────────────────────────────────────────────────────────────
create temp table meus as
  select pg_temp.como('ca000000-0000-4000-8000-0000000000e1', $$ select public.meus_turnos() $$) as j;

select is(
  (select (e->>'a_caminho_em')::timestamptz
     from meus, jsonb_array_elements(meus.j) e where (e->>'id')::uuid = (select a from t)),
  (select ini - interval '3 hours' from quando),
  'Turno expõe a_caminho_em para a tela Meu turno');

select is(
  (select e->'a_caminho_em'
     from meus, jsonb_array_elements(meus.j) e where (e->>'id')::uuid = (select c from t)),
  'null'::jsonb,
  'e null no turno ainda sem aviso');

select is(
  (select e->'a_caminho_em'
     from jsonb_array_elements(pg_temp.como('ca000000-0000-4000-8000-0000000000d1', format(
            $x$ select public.meus_turnos(null, null, %L) $x$, (select id from casa)))) e
    where (e->>'id')::uuid = (select a from t)),
  to_jsonb((select ini - interval '3 hours' from quando)),
  'a casa vê o mesmo instante em meus_turnos por estabelecimento');

select * from finish();
rollback;
