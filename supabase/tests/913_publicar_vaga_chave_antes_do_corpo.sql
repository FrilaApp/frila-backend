-- 913_publicar_vaga_chave_antes_do_corpo.sql
--
-- ZFwcL4of: `public.publicar_vaga` confere a chave de idempotência (`chave_cliente`, RF04) ANTES do corpo (`privado.validar_nova_vaga`), como a
-- `publicar_escala`. Antes, o corpo era conferido primeiro: no reenvio de uma publicação que já gravou, uma recusa de conteúdo que depende do relógio
-- (início no passado, antecedência da seleção) ou do catálogo (função inexistente) escondia a vaga gravada, o app soltava a chave e a pessoa publicava OUTRA vaga.
--   A  reenvio com a mesma chave e um corpo que agora seria inválido devolve a vaga gravada: sem 422, sem segunda vaga, sem novo despacho
--   B  a chave nova continua conferindo o corpo (as recusas de conteúdo seguem), e a chave nula recusa como antes
--   C  a chave só vale para quem é da casa e dentro da casa; as recusas anteriores ao corpo (perfil, suspensão, vínculo) vêm antes
--   D  forma da resposta e privilégios iguais
-- Cenário (`cenarios.sql`): Zélia (b…01) administra o Bar do Cerrado (c…01); b…02 administra a casa c…02; a…01 é profissional. Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-27 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste';
select plan(28);

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
  'b0000000-0000-4000-8000-000000000001'::uuid as zelia,
  'b0000000-0000-4000-8000-000000000004'::uuid as operador,
  'b0000000-0000-4000-8000-000000000002'::uuid as outra_dona,
  'a0000000-0000-4000-8000-000000000001'::uuid as prof,
  'c0000000-0000-4000-8000-000000000001'::uuid as casa,
  'c0000000-0000-4000-8000-000000000002'::uuid as outra_casa,
  (select id from public.funcao where nome = 'garçom') as garcom,
  '91300000-0000-4000-8000-000000000001'::uuid as k1,
  '91300000-0000-4000-8000-000000000002'::uuid as k2,
  '91300000-0000-4000-8000-000000000003'::uuid as k3,
  '91300000-0000-4000-8000-000000000004'::uuid as k4;

-- Uma publicação com os argumentos que variam; o resto é o de uma vaga boa.
create function pg_temp.publicar(
  conta uuid, estab uuid, funcao uuid, inicio timestamptz, fim timestamptz, posicoes int, modo text, chave uuid, valor bigint default 18000
) returns jsonb language sql as $$
  select pg_temp.como(conta, format(
    $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte', '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
         %s, %s, true, true, false, 'Seu Zé', %L, %L) $x$,
    estab, funcao, inicio, fim, valor, posicoes, modo, chave)) $$;

create function pg_temp.erro_de(conta uuid, estab uuid, funcao uuid, inicio timestamptz, fim timestamptz, posicoes int, modo text, chave uuid, valor bigint default 18000)
returns jsonb language sql as $$
  select pg_temp.erro(format($y$ select pg_temp.publicar(%L, %L, %L, %L, %L, %s, %L, %L, %s) $y$, conta, estab, funcao, inicio, fim, posicoes, modo, chave, valor)) $$;

-- Reenvio que devolve a recusa como valor (e não como queda do arquivo): na base o reenvio recusa, e o teste precisa reprovar a asserção.
create function pg_temp.reenviar(
  conta uuid, estab uuid, funcao uuid, inicio timestamptz, fim timestamptz, posicoes int, modo text, chave uuid, valor bigint default 18000
) returns jsonb language plpgsql as $$
begin
  return pg_temp.publicar(conta, estab, funcao, inicio, fim, posicoes, modo, chave, valor);
exception when sqlstate 'PGRST' then
  return jsonb_build_object('recusou', true);
end $$;

-- ── 1ª publicação: a vaga que o reenvio tem de achar ───────────────────────────────────────────────────────────────

create temp table primeira as
  select pg_temp.publicar((select zelia from ids), (select casa from ids), (select garcom from ids),
    privado.agora() + interval '3 days', privado.agora() + interval '3 days 6 hours', 3, 'urgencia', (select k1 from ids)) as j;
select ok((select j ? 'vaga_id' from primeira), '0 a 1ª publicação grava (não passa vazio)');
select is((select jsonb_array_length(j->'posicoes') from primeira), 3, '0b com três posições');

-- ── A. Reenvio com a mesma chave e corpo que agora seria inválido ──────────────────────────────────────────────────

select is(
  pg_temp.reenviar((select zelia from ids), (select casa from ids), (select garcom from ids),
    privado.agora() - interval '1 day', privado.agora() - interval '18 hours', 3, 'urgencia', (select k1 from ids)),
  (select j from primeira),
  'A1 reenvio com o início no passado devolve a vaga gravada, sem 422');
select is(
  pg_temp.reenviar((select zelia from ids), (select casa from ids), (select garcom from ids),
    privado.agora() + interval '2 hours', privado.agora() + interval '8 hours', 3, 'selecao', (select k1 from ids)),
  (select j from primeira),
  'A2 reenvio em modo seleção sem a antecedência de 24 h devolve a vaga gravada');
select is(
  pg_temp.reenviar((select zelia from ids), (select casa from ids), 'f0000000-0000-4000-8000-00000000dead',
    privado.agora() + interval '3 days', privado.agora() + interval '3 days 6 hours', 3, 'urgencia', (select k1 from ids)),
  (select j from primeira),
  'A3 reenvio com uma função que não existe devolve a vaga gravada');
select is(
  pg_temp.reenviar((select zelia from ids), (select casa from ids), (select garcom from ids),
    privado.agora() + interval '3 days 6 hours', privado.agora() + interval '3 days', 3, 'urgencia', (select k1 from ids)),
  (select j from primeira),
  'A4 reenvio com o fim antes do início devolve a vaga gravada');
select is(
  pg_temp.reenviar((select zelia from ids), (select casa from ids), (select garcom from ids),
    privado.agora() + interval '3 days', privado.agora() + interval '3 days 6 hours', 0, 'urgencia', (select k1 from ids), 0),
  (select j from primeira),
  'A5 reenvio com zero posições e valor zero devolve a vaga gravada');
select is(
  pg_temp.reenviar((select zelia from ids), (select casa from ids), (select garcom from ids),
    privado.agora() + interval '3 days', privado.agora() + interval '3 days 6 hours', 3, 'urgencia', (select k1 from ids)),
  (select j from primeira),
  'A6 e o reenvio idêntico continua devolvendo a mesma vaga (o que a base já fazia)');

select is((select count(*)::int from public.vaga where chave_cliente = (select k1 from ids)), 1, 'A7 continua havendo uma vaga só com a chave');
select is((select count(*)::int from public.posicao where vaga_id = ((select j->>'vaga_id' from primeira))::uuid), 3, 'A8 e três posições, não mais');
select is((select count(*)::int from pgmq.q_despacho where (message->>'vaga_id')::uuid = ((select j->>'vaga_id' from primeira))::uuid), 1,
  'A9 e uma mensagem na fila: o reenvio não redespacha');
select is((select array_agg(k order by k) from primeira, jsonb_object_keys(j) k), array['posicoes', 'vaga_id'],
  'A10 a resposta do reenvio tem a mesma forma: vaga_id e posicoes');

-- ── B. Chave nova: o corpo continua conferido ──────────────────────────────────────────────────────────────────────

select is(pg_temp.erro_de((select zelia from ids), (select casa from ids), (select garcom from ids),
    privado.agora() - interval '1 day', privado.agora() - interval '18 hours', 3, 'urgencia', (select k2 from ids))->>'code', 'horario_invalido',
  'B1 chave nova com o início no passado: 422 horario_invalido');
select is((select count(*)::int from public.vaga where chave_cliente = (select k2 from ids)), 0, 'B2 e nada é gravado');
select is(pg_temp.erro_de((select zelia from ids), (select casa from ids), (select garcom from ids),
    privado.agora() + interval '2 hours', privado.agora() + interval '8 hours', 3, 'selecao', (select k2 from ids))->>'status', '422',
  'B3 chave nova em modo seleção sem antecedência: 422');
select is(pg_temp.erro_de((select zelia from ids), (select casa from ids), 'f0000000-0000-4000-8000-00000000dead',
    privado.agora() + interval '3 days', privado.agora() + interval '3 days 6 hours', 3, 'urgencia', (select k2 from ids))->>'status', '422',
  'B4 chave nova com função inexistente: 422');
select is(pg_temp.erro_de((select zelia from ids), (select casa from ids), (select garcom from ids),
    privado.agora() + interval '3 days', privado.agora() + interval '3 days 6 hours', 3, 'urgencia', null)->>'details', 'chave',
  'B5 chave nula: recusa campo_obrigatorio chave, como antes');

create temp table nova as
  select pg_temp.publicar((select zelia from ids), (select casa from ids), (select garcom from ids),
    privado.agora() + interval '4 days', privado.agora() + interval '4 days 6 hours', 2, 'urgencia', (select k3 from ids)) as j;
select isnt((select j->>'vaga_id' from nova), (select j->>'vaga_id' from primeira), 'B6 chave nova e corpo válido: outra vaga');
select is((select jsonb_array_length(j->'posicoes') from nova), 2, 'B7 com as próprias posições');

-- ── C. Quem pode consultar a chave ────────────────────────────────────────────────────────────────────────────────

select is(pg_temp.erro_de((select outra_dona from ids), (select casa from ids), (select garcom from ids),
    privado.agora() - interval '1 day', privado.agora() - interval '18 hours', 3, 'urgencia', (select k1 from ids))->>'code', 'sem_permissao',
  'C1 quem não é da casa não acha a vaga pela chave: 403 sem_permissao');
select is(pg_temp.erro_de((select prof from ids), (select casa from ids), (select garcom from ids),
    privado.agora() - interval '1 day', privado.agora() - interval '18 hours', 3, 'urgencia', (select k1 from ids))->>'code', 'perfil_incompativel',
  'C2 profissional com a chave da casa: perfil_incompativel');
update public.usuario set estado = 'suspensa' where id = (select operador from ids);
select is(pg_temp.erro_de((select operador from ids), (select casa from ids), (select garcom from ids),
    privado.agora() - interval '1 day', privado.agora() - interval '18 hours', 3, 'urgencia', (select k1 from ids))->>'details', 'conta_suspensa',
  'C3 conta suspensa da casa com a chave: 403 conta_suspensa');
select is(pg_temp.erro(format($$ select public.publicar_vaga(%L, %L, %L, %L, 'x', '{"latitude":-15.789,"longitude":-47.885}'::jsonb, 18000, 3, true, true, false, 'Seu Zé', 'urgencia', %L) $$,
    (select casa from ids), (select garcom from ids), privado.agora() + interval '3 days', privado.agora() + interval '3 days 6 hours', (select k1 from ids)))->>'status', '401',
  'C4 sem sessão: 401');

-- A mesma chave em OUTRA casa é outra publicação (a chave é por estabelecimento).
create temp table da_outra_casa as
  select pg_temp.publicar((select outra_dona from ids), (select outra_casa from ids), (select garcom from ids),
    privado.agora() + interval '3 days', privado.agora() + interval '3 days 6 hours', 1, 'urgencia', (select k1 from ids)) as j;
select isnt((select j->>'vaga_id' from da_outra_casa), (select j->>'vaga_id' from primeira), 'C5 a mesma chave em outra casa cria a vaga dela');
select is((select estabelecimento_id from public.vaga where id = (select (j->>'vaga_id')::uuid from da_outra_casa)), (select outra_casa from ids),
  'C6 e ela é da outra casa');
select is((select count(*)::int from public.vaga where chave_cliente = (select k1 from ids)), 2, 'C7 duas vagas com a mesma chave, uma por casa');

-- ── D. Privilégios ────────────────────────────────────────────────────────────────────────────────────────────────

select ok(has_function_privilege('authenticated',
  'public.publicar_vaga(uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer, boolean, boolean, boolean, text, public.modo_preenchimento, uuid, text, boolean, text, int, text)', 'execute'),
  'D1 authenticated executa');
select ok(not has_function_privilege('anon',
  'public.publicar_vaga(uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer, boolean, boolean, boolean, text, public.modo_preenchimento, uuid, text, boolean, text, int, text)', 'execute'),
  'D2 anon não executa');

select * from finish();
rollback;
