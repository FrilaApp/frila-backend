-- 912_detalhe_chamada_turno_id.sql
--
-- lWuOxMAQ: `public.detalhe_chamada` devolve `turno_id` na chamada aceita (`ChamadaDetalhe.turno_id`, contrato 0.2.56). Antes o ramo `aceita`
-- só acrescentava `local`, `ponto` e `responsavel_local`, e o "Ver turno" do app ficava sem o turno que o aceite criou.
--   A  aberta: sem turno_id (antes do aceite)
--   B  aceita: turno_id = o que `responder_chamada` devolveu, para o profissional e para o membro da casa, e é o turno da posição da vaga
--   C  recusada e os demais estados não ganham a chave; nada além do turno_id muda no ramo aceita
--   D  recusas e privilégios são os de antes
-- Cenário (`cenarios.sql`): vaga d…01 (Bar do Cerrado, 2 posições abertas); Carla (a…03) aceita e Diego (a…04) recusa; Zélia (b…01) é da casa.
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-27 15:00:00+00', true);
update privado.recurso set ligado = true where chave = 'chamada_direta';
select plan(31);

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

create function pg_temp.erro(sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  execute sql; return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  return msg::jsonb || det::jsonb;
end $$;

create temp table ids as select
  'a0000000-0000-4000-8000-000000000003'::uuid as carla,
  'e0000000-0000-4000-8000-000000000003'::uuid as carla_prof,
  'a0000000-0000-4000-8000-000000000004'::uuid as diego,
  'e0000000-0000-4000-8000-000000000004'::uuid as diego_prof,
  'b0000000-0000-4000-8000-000000000001'::uuid as zelia,
  'b0000000-0000-4000-8000-000000000002'::uuid as outra_casa,
  'c0000000-0000-4000-8000-000000000001'::uuid as casa,
  'd0000000-0000-4000-8000-000000000001'::uuid as vaga,
  'f9120000-0000-4000-8000-000000000001'::uuid as ch_carla,
  'f9120000-0000-4000-8000-000000000002'::uuid as ch_diego;

-- Um turno da Carla numa OUTRA vaga, com id MENOR que o da vaga da chamada. Quem não filtra a vaga e ordena pelo id da vaga (crescente) escolheria
-- este turno no lugar do certo: sem ele o teste não distingue "o turno desta vaga" de "o primeiro turno dela".
insert into public.vaga
  select (jsonb_populate_record(null::public.vaga, to_jsonb(v) || jsonb_build_object(
    'id', '00000000-0000-4000-8000-000000009120', 'inicio_em', '2026-10-01 18:00:00+00', 'fim_em', '2026-10-01 23:00:00+00',
    'chave_cliente', gen_random_uuid()))).*
    from public.vaga v where v.id = 'd0000000-0000-4000-8000-000000000007';
insert into public.posicao
  select (jsonb_populate_record(null::public.posicao, to_jsonb(p) || jsonb_build_object(
    'id', 'f1000000-0000-4000-8000-000000009120', 'vaga_id', '00000000-0000-4000-8000-000000009120',
    'profissional_id', 'e0000000-0000-4000-8000-000000000003',
    'inicio_em', '2026-10-01 18:00:00+00', 'fim_em', '2026-10-01 23:00:00+00', 'confirmado_em', '2026-09-30 12:00:00+00'))).*
    from public.posicao p where p.id = 'f1000000-0000-4000-8000-000000000701';
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, checkout_em, verificacao, valor_acordado_centavos)
values ('f2000000-0000-4000-8000-000000009120', 'f1000000-0000-4000-8000-000000009120', '2026-10-01 18:00:00+00', 'geolocalizado', 50,
        '2026-10-01 23:00:00+00', 'verificado', 15000);

-- Uma OUTRA pessoa (Elisa) já ocupa uma posição desta mesma vaga, com turno criado ANTES do aceite da Carla: quem acha o turno só pela vaga, sem filtrar
-- o profissional, devolveria o da Elisa. A Carla fica com a outra posição (o aceite escolhe a primeira aberta).
update public.posicao set estado = 'confirmada', profissional_id = 'e0000000-0000-4000-8000-000000000005', confirmado_em = '2026-11-26 12:00:00+00'
 where id = 'f1000000-0000-4000-8000-000000000101';
insert into public.turno (id, posicao_id, valor_acordado_centavos)
values ('f2000000-0000-4000-8000-000000009121', 'f1000000-0000-4000-8000-000000000101', 15000);

-- A vaga direta e as duas chamadas abertas, como `chamar_profissional` as deixa (20261107300000).
update public.vaga set origem = 'chamada_direta' where id = (select vaga from ids);
insert into public.chamada (id, vaga_id, profissional_id, estabelecimento_id, criada_por, estado, expira_em, chave) values
  ((select ch_carla from ids), (select vaga from ids), (select carla_prof from ids), (select casa from ids), (select zelia from ids), 'aberta', '2026-11-28 15:00:00+00', gen_random_uuid()),
  ((select ch_diego from ids), (select vaga from ids), (select diego_prof from ids), (select casa from ids), (select zelia from ids), 'aberta', '2026-11-28 15:00:00+00', gen_random_uuid());

create function pg_temp.detalhe(conta uuid, p_chamada uuid) returns jsonb language sql as
  $$ select pg_temp.como(conta, format('select public.detalhe_chamada(%L)', p_chamada)) $$;

-- ── A. Aberta: sem turno_id ───────────────────────────────────────────────────────────────────────────────────

create temp table det_aberta as select pg_temp.detalhe((select carla from ids), (select ch_carla from ids)) as j;
select is((select j->>'estado' from det_aberta), 'aberta', '0 a chamada da Carla está aberta (não passa vazio)');
select ok((select not (j ? 'turno_id') from det_aberta), 'A1 aberta: o profissional não recebe turno_id');
select ok((select not (j ? 'turno_id') from (select pg_temp.detalhe((select zelia from ids), (select ch_carla from ids)) as j) x), 'A2 aberta: o membro da casa também não');
select ok((select not (j ? 'local') from det_aberta), 'A3 aberta: segue sem local (RN36)');

-- O aceite da Carla encerra as outras chamadas abertas da vaga: o Diego recusa antes.
select pg_temp.como((select diego from ids), format($$ select public.responder_chamada(%L, 'recusar', 'agenda') $$, (select ch_diego from ids)));

-- ── B. Aceita ─────────────────────────────────────────────────────────────────────────────────────────────────

create temp table aceite as select pg_temp.como((select carla from ids),
  format($$ select public.responder_chamada(%L, 'aceitar') $$, (select ch_carla from ids))) as j;
select ok((select (j->>'turno_id') is not null from aceite), '0b o responder_chamada devolveu o turno_id (a base já fazia)');
select ok((select count(*) >= 2 from public.turno t join public.posicao p on p.id = t.posicao_id where p.profissional_id = (select carla_prof from ids)),
  '0b2 a Carla tem turnos em mais de uma vaga (o turno_id precisa ser o desta vaga, não o primeiro dela)');
select ok((select p.vaga_id < (select vaga from ids) from public.turno t join public.posicao p on p.id = t.posicao_id where t.id = 'f2000000-0000-4000-8000-000000009120'),
  '0b3 e o turno dela em outra vaga vem ANTES na ordem crescente do id da vaga (ordenar por vaga sem filtrar escolheria o errado)');
select isnt((select j->>'turno_id' from aceite), 'f2000000-0000-4000-8000-000000009120', '0b4 o turno desta chamada não é o da outra vaga');

create temp table det_aceita as select pg_temp.detalhe((select carla from ids), (select ch_carla from ids)) as j;
create temp table det_aceita_casa as select pg_temp.detalhe((select zelia from ids), (select ch_carla from ids)) as j;

select is((select j->>'estado' from det_aceita), 'aceita', '0c a chamada da Carla está aceita');
select is((select j->>'turno_id' from det_aceita), (select j->>'turno_id' from aceite), 'B1 aceita: turno_id = o que o responder_chamada devolveu (profissional)');
select is((select j->>'turno_id' from det_aceita_casa), (select j->>'turno_id' from aceite), 'B2 e o mesmo para o membro da casa');
select is(jsonb_typeof((select j->'turno_id' from det_aceita)), 'string', 'B3 turno_id é um uuid em texto');
select ok((select exists (
    select 1 from public.turno t join public.posicao p on p.id = t.posicao_id
     where t.id = (j->>'turno_id')::uuid and p.vaga_id = (select vaga from ids) and p.profissional_id = (select carla_prof from ids))
  from det_aceita), 'B4 é o turno da posição da vaga ocupada pela Carla');
select is((select count(*) from public.turno t join public.posicao p on p.id = t.posicao_id where p.vaga_id = (select vaga from ids)), 2::bigint,
  'B5 a vaga tem dois turnos (o da Elisa e o da Carla) e o turno_id é o da Carla');
select isnt((select j->>'turno_id' from aceite), 'f2000000-0000-4000-8000-000000009121', 'B5b não é o turno da Elisa, que está na mesma vaga');

-- Responder de novo ao aceite (idempotência) e reler: o mesmo turno.
select is(
  (pg_temp.como((select carla from ids), format($$ select public.responder_chamada(%L, 'aceitar') $$, (select ch_carla from ids))))->>'turno_id',
  (select j->>'turno_id' from aceite), 'B6 aceitar de novo devolve o mesmo turno');
select is((select j->>'turno_id' from (select pg_temp.detalhe((select carla from ids), (select ch_carla from ids)) as j) x), (select j->>'turno_id' from aceite),
  'B7 e o detalhe continua com o mesmo turno_id');

-- Só o turno_id é novo no ramo aceita.
select is(
  (select array_agg(k order by k) from (select jsonb_object_keys(j) k from det_aceita except select jsonb_object_keys(j) from det_aberta) x),
  array['local', 'ponto', 'responsavel_local', 'turno_id'],
  'C1 do aberto para o aceito entram local, ponto, responsavel_local e turno_id, e mais nada');
select is((select j - 'turno_id' - 'local' - 'ponto' - 'responsavel_local' - 'estado' - 'respondida_em' from det_aceita),
          (select j - 'estado' - 'respondida_em' from det_aberta),
  'C2 o resto da resposta é o mesmo de antes do aceite');
select ok((select (j->>'local') is not null and (j ? 'ponto') and (j->>'responsavel_local') is not null from det_aceita), 'C3 local, ponto e responsavel_local seguem vindo');

-- ── C. Recusada e os demais estados ───────────────────────────────────────────────────────────────────────────

select is((select j->>'estado' from (select pg_temp.detalhe((select diego from ids), (select ch_diego from ids)) as j) x), 'recusada', '0d a chamada do Diego está recusada');
select ok((select not (j ? 'turno_id') from (select pg_temp.detalhe((select diego from ids), (select ch_diego from ids)) as j) x), 'C4 recusada: sem turno_id (profissional)');
select ok((select not (j ? 'turno_id') from (select pg_temp.detalhe((select zelia from ids), (select ch_diego from ids)) as j) x), 'C5 recusada: sem turno_id (casa)');
select ok((select not (j ? 'local') and not (j ? 'ponto') and not (j ? 'responsavel_local') from (select pg_temp.detalhe((select diego from ids), (select ch_diego from ids)) as j) x),
  'C5b recusada: segue sem local, ponto e responsavel_local (RN36)');
create function pg_temp.estados_com_turno(p_chamada uuid, conta uuid) returns int language plpgsql as $$
declare e text; n int := 0;
begin
  foreach e in array array['expirada', 'cancelada', 'encerrada'] loop
    update public.chamada set estado = e where id = p_chamada;
    if pg_temp.detalhe(conta, p_chamada) ? 'turno_id' then n := n + 1; end if;
  end loop;
  return n;
end $$;
select is(pg_temp.estados_com_turno((select ch_diego from ids), (select diego from ids)), 0, 'C6 expirada, cancelada e encerrada: sem turno_id');

-- ── D. Recusas e privilégios ──────────────────────────────────────────────────────────────────────────────────

select is(pg_temp.erro(format('select public.detalhe_chamada(%L)', (select ch_carla from ids)))->>'status', '401', 'D1 sem sessão: 401');
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000004","role":"authenticated"}';
select is(pg_temp.erro(format('select public.detalhe_chamada(%L)', (select ch_carla from ids)))->>'status', '404', 'D2 outro profissional não lê a chamada da Carla: 404');
set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002","role":"authenticated"}';
select is(pg_temp.erro(format('select public.detalhe_chamada(%L)', (select ch_carla from ids)))->>'status', '404', 'D3 membro de outra casa: 404');
reset request.jwt.claims;
select ok(has_function_privilege('authenticated', 'public.detalhe_chamada(uuid)', 'execute'), 'D4 authenticated executa');
select ok(not has_function_privilege('anon', 'public.detalhe_chamada(uuid)', 'execute'), 'D5 anon não executa');
select ok((select prosecdef and 'search_path=""' = any(proconfig) from pg_proc where oid = 'public.detalhe_chamada(uuid)'::regprocedure),
  'D6 security definer com search_path vazio');

select * from finish();
rollback;
