-- 480_modo_selecao.sql
--
-- Cartão d3A1WjG3 (US12, RF09, RN19, RN21, RN24, UC04; contrato 0.2.24): o modo seleção.
--
-- Para vaga que começa em mais de 24 h, o contratante escolhe entre os candidatos. Sem
-- escolha até 24 h antes, a vaga fecha sozinha e os candidatos são avisados e liberados.
-- A candidatura vale até a vaga fechar e pode ser retirada sem penalidade.
--
--   1. publicar_vaga aceita `selecao` e recusa com menos de 24 h (selecao_sem_antecedencia)
--   2. candidatar numa vaga de seleção fica pendente, sem posição, turno nem contato
--   3. candidatos_da_vaga, retirar_candidatura e minhas_candidaturas
--   4. escolher_candidato: confirma só o escolhido e libera os outros com aviso (RN19)
--   5. RN21 na escolha, conta suspensa e vaga cancelada com candidaturas pendentes
--   6. o fechamento automático 24 h antes, agendado no pg_cron
--
-- A corrida (duas escolhas simultâneas para a última posição) mora em
-- `scripts/corrida-ciclo.sh`: o pgTAP roda numa sessão só e não a enxergaria.
--
-- Prefixo `c9`. O relógio do produto é fixo: 02/11/2026 12:00 UTC.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(68);

insert into privado.ambiente (id, eh_teste) values (true, true);
select set_config('frila.agora', '2026-11-02 12:00:00+00', true);

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

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

-- d1: a dona da casa · d2: dona de outra casa · p1 a p6: garçons
select pg_temp.autenticar('c9000000-0000-4000-8000-0000000000d1', 'd1@selecao.test');
select pg_temp.autenticar('c9000000-0000-4000-8000-0000000000d2', 'd2@selecao.test');
select pg_temp.autenticar(('c9000000-0000-4000-8000-00000000000' || n)::uuid, 'p' || n || '@selecao.test')
  from generate_series(1, 6) n;

select pg_temp.como('c9000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona da Seleção','+5561977770001','1980-01-01','2026-09-22') $$);
select pg_temp.como('c9000000-0000-4000-8000-0000000000d2',
  $$ select public.criar_conta('contratante','Dona de Outra Casa','+5561977770002','1980-01-01','2026-09-22') $$);
select pg_temp.como(('c9000000-0000-4000-8000-00000000000' || n)::uuid,
  format($$ select public.criar_conta('profissional','Garçom %s','+556197777001%s','1995-01-01','2026-09-22') $$, n, n))
  from generate_series(1, 6) n;

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como(('c9000000-0000-4000-8000-00000000000' || n)::uuid,
  format($$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)))
  from generate_series(1, 6) n;

create temp table casa as
  select (pg_temp.como('c9000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa da Seleção','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as a,
         (pg_temp.como('c9000000-0000-4000-8000-0000000000d2',
    $$ select public.cadastrar_estabelecimento('Outra Casa','11222333000181','food_service',
         'SCLN 407','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as b;

-- Publica pela dona d1. Devolve a resposta inteira, para o teste ler a recusa também.
create function pg_temp.publicar(modo text, ini timestamptz, fim timestamptz,
                                 posicoes int, chave uuid) returns jsonb
language plpgsql as $corpo$
begin
  return pg_temp.como('c9000000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 406',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, %s, true, true, false, 'Seu Zé', %L, %L) $sql$,
    (select a from casa), (select garcom from fn), ini, fim, posicoes, modo, chave));
end $corpo$;

create function pg_temp.p(n int) returns uuid language sql as $$
  select ('c9000000-0000-4000-8000-00000000000' || n)::uuid
$$;

create function pg_temp.candidatar(n int, vaga uuid) returns jsonb language sql as $$
  select pg_temp.como(pg_temp.p(n), format($s$ select public.candidatar(%L) $s$, vaga))
$$;

create function pg_temp.escolher(conta uuid, candidatura uuid) returns jsonb language sql as $$
  select pg_temp.como(conta, format($s$ select public.escolher_candidato(%L) $s$, candidatura))
$$;

create function pg_temp.cand(n int, vaga uuid) returns uuid language sql as $$
  select c.id from public.candidatura c
    join public.posicao x on x.id = c.posicao_id
    join public.profissional pr on pr.id = c.profissional_id
   where x.vaga_id = vaga and pr.usuario_id = pg_temp.p(n)
$$;

create function pg_temp.estado_cand(n int, vaga uuid) returns text language sql as $$
  select c.estado::text from public.candidatura c where c.id = pg_temp.cand(n, vaga)
$$;

create function pg_temp.avisos(n int, p_tipo text, vaga uuid) returns int language sql as $$
  select count(*)::int from public.notificacao
   where usuario_id = pg_temp.p(n) and tipo::text = p_tipo and payload->>'vaga_id' = vaga::text
$$;

-- ── 0. Estrutura e privilégios ──────────────────────────────────────────────────

select ok(has_function_privilege('authenticated', 'public.escolher_candidato(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.escolher_candidato(uuid)', 'execute'),
  'escolher_candidato: authenticated executa, anon não');
select ok(has_function_privilege('authenticated', 'public.candidatos_da_vaga(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.candidatos_da_vaga(uuid)', 'execute'),
  'candidatos_da_vaga: authenticated executa, anon não');
select ok(has_function_privilege('authenticated', 'public.retirar_candidatura(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.retirar_candidatura(uuid)', 'execute'),
  'retirar_candidatura: authenticated executa, anon não');
select ok(has_function_privilege('authenticated', 'public.minhas_candidaturas(public.estado_candidatura)', 'execute')
          and not has_function_privilege('anon', 'public.minhas_candidaturas(public.estado_candidatura)', 'execute'),
  'minhas_candidaturas: authenticated executa, anon não');
select ok(not has_function_privilege('authenticated', 'privado.fechar_selecoes()', 'execute')
          and has_function_privilege('service_role', 'privado.fechar_selecoes()', 'execute'),
  'o fechamento automático é só do agendador');
select ok('candidatura_recusada' = any (enum_range(null::public.tipo_notificacao)::text[])
          and 'selecao_encerrada' = any (enum_range(null::public.tipo_notificacao)::text[]),
  'os dois avisos do contrato 0.2.24 existem: candidatura_recusada e selecao_encerrada');

-- ── 1. publicar_vaga ────────────────────────────────────────────────────────────

select throws_ok(
  $$ select pg_temp.publicar('selecao', '2026-11-03 11:00+00', '2026-11-03 17:00+00', 1,
                             'c9000000-0000-4000-8000-00000000a001') $$,
  'PGRST', pg_temp.erro('selecao_sem_antecedencia'),
  'RN24: seleção com 23 h de antecedência é recusada com selecao_sem_antecedencia');
select throws_ok(
  $$ select pg_temp.publicar('selecao', '2026-11-03 12:00+00', '2026-11-03 18:00+00', 1,
                             'c9000000-0000-4000-8000-00000000a002') $$,
  'PGRST', pg_temp.erro('selecao_sem_antecedencia'),
  'RN24: com exatamente 24 h também (a vaga nasceria fechada)');

-- A janela A: 05/11 20:00 às 06/11 02:00. S1, S2, S3 e S4 são de seleção; U1 é urgência.
create temp table vagas as select
  (pg_temp.publicar('selecao', '2026-11-05 20:00+00', '2026-11-06 02:00+00', 1,
                    'c9000000-0000-4000-8000-00000000b001')->>'vaga_id')::uuid as s1,
  (pg_temp.publicar('selecao', '2026-11-05 20:00+00', '2026-11-06 02:00+00', 2,
                    'c9000000-0000-4000-8000-00000000b002')->>'vaga_id')::uuid as s2,
  (pg_temp.publicar('selecao', '2026-11-05 20:00+00', '2026-11-06 02:00+00', 1,
                    'c9000000-0000-4000-8000-00000000b003')->>'vaga_id')::uuid as s3,
  (pg_temp.publicar('selecao', '2026-11-05 20:00+00', '2026-11-06 02:00+00', 1,
                    'c9000000-0000-4000-8000-00000000b004')->>'vaga_id')::uuid as s4,
  (pg_temp.publicar('urgencia', '2026-11-05 21:00+00', '2026-11-06 01:00+00', 1,
                    'c9000000-0000-4000-8000-00000000b005')->>'vaga_id')::uuid as u1;

select is((select modo::text from public.vaga where id = (select s1 from vagas)), 'selecao',
  'RN24: seleção com mais de 24 h é publicada no modo seleção');
select is((select count(*)::int from public.posicao where vaga_id = (select s2 from vagas)
            and estado = 'aberta'), 2,
  'a vaga de seleção nasce com as posições pedidas, abertas');

-- ── 2. candidatar numa vaga de seleção ──────────────────────────────────────────

select is(pg_temp.candidatar(1, (select s1 from vagas)) - 'candidatura_id',
  '{"estado": "pendente", "posicao_id": null, "turno_id": null, "contato": null}'::jsonb,
  'candidatura em seleção fica pendente, sem posição, turno nem contato (RN10)');
select is((pg_temp.candidatar(1, (select s1 from vagas))->>'candidatura_id')::uuid,
  pg_temp.cand(1, (select s1 from vagas)),
  'reenviar devolve a mesma candidatura');
select pg_temp.candidatar(n, (select s1 from vagas)) from generate_series(2, 4) n;
select is((select count(*)::int from public.candidatura c join public.posicao x on x.id = c.posicao_id
            where x.vaga_id = (select s1 from vagas) and c.estado = 'pendente'), 4,
  'quatro candidatos pendentes na vaga de uma posição');
select is((select estado::text from public.posicao where vaga_id = (select s1 from vagas)), 'aberta',
  'a posição continua aberta até a escolha');
select is(pg_temp.avisos(1, 'confirmacao', (select s1 from vagas)), 0,
  'ninguém é avisado de confirmação por se candidatar');

-- ── 3. candidatos_da_vaga, retirar_candidatura e minhas_candidaturas ────────────

select is(jsonb_array_length(pg_temp.como('c9000000-0000-4000-8000-0000000000d1',
  format($$ select public.candidatos_da_vaga(%L) $$, (select s1 from vagas)))), 4,
  'a dona vê os quatro candidatos');
select is((select array_agg(k order by k) from jsonb_object_keys(
    pg_temp.como('c9000000-0000-4000-8000-0000000000d1',
      format($$ select public.candidatos_da_vaga(%L) $$, (select s1 from vagas)))->0) k),
  array['candidatura_id', 'criada_em', 'profissional'],
  'cada candidato é um Candidato do contrato');
select is(pg_temp.como('c9000000-0000-4000-8000-0000000000d1',
    format($$ select public.candidatos_da_vaga(%L) $$, (select s1 from vagas)))->0->'profissional'->>'tipo',
  'profissional',
  'o candidato traz o PerfilPublico do profissional, com a reputação (RN08)');
select throws_ok(
  format($$ select pg_temp.como('c9000000-0000-4000-8000-0000000000d2',
            $x$ select public.candidatos_da_vaga(%L) $x$) $$, (select s1 from vagas)),
  'PGRST', pg_temp.erro('sem_permissao'),
  'quem não é da casa recebe 403 sem_permissao');
select throws_ok(
  $$ select pg_temp.como('c9000000-0000-4000-8000-0000000000d1',
       $x$ select public.candidatos_da_vaga('c9000000-0000-4000-8000-00000000ffff') $x$) $$,
  'PGRST', pg_temp.erro('nao_encontrado'),
  'vaga que não existe: 404');

select is(pg_temp.como(pg_temp.p(4), format($$ select public.retirar_candidatura(%L) $$,
            pg_temp.cand(4, (select s1 from vagas))))->>'estado', 'retirada',
  'RN24: o candidato retira sem penalidade');
select is(pg_temp.como(pg_temp.p(4), format($$ select public.retirar_candidatura(%L) $$,
            pg_temp.cand(4, (select s1 from vagas))))->'vaga'->>'id', (select s1 from vagas)::text,
  'retirar de novo devolve a mesma candidatura retirada, com a vaga');
select throws_ok(
  format($$ select pg_temp.como(pg_temp.p(3), $x$ select public.retirar_candidatura(%L) $x$) $$,
         pg_temp.cand(1, (select s1 from vagas))),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'a candidatura de outro profissional não existe para quem pede');
select is((select count(*)::int from public.posicao x join public.candidatura c on c.posicao_id = x.id
            join public.profissional pr on pr.id = c.profissional_id
            where x.vaga_id = (select s1 from vagas) and pr.usuario_id = pg_temp.p(4)
              and x.falta), 0,
  'retirar não marca falta');
select is(jsonb_array_length(pg_temp.como('c9000000-0000-4000-8000-0000000000d1',
  format($$ select public.candidatos_da_vaga(%L) $$, (select s1 from vagas)))), 3,
  'quem retirou sai da lista de candidatos');

select is(pg_temp.como(pg_temp.p(4), $$ select public.minhas_candidaturas() $$)->0->>'estado',
  'retirada', 'minhas_candidaturas mostra a retirada');
select is(jsonb_array_length(pg_temp.como(pg_temp.p(4),
    $$ select public.minhas_candidaturas('pendente') $$)), 0,
  'o filtro por estado deixa a retirada de fora');
select is((select array_agg(k order by k) from jsonb_object_keys(
    pg_temp.como(pg_temp.p(1), $$ select public.minhas_candidaturas('pendente') $$)->0->'vaga') k),
  array['fim_em', 'funcao', 'id', 'inicio_em', 'local', 'regiao_administrativa', 'valor_centavos'],
  'a vaga da candidatura é um VagaResumo do contrato');

-- ── 4. escolher_candidato ───────────────────────────────────────────────────────

select throws_ok(
  format($$ select pg_temp.escolher('c9000000-0000-4000-8000-0000000000d2', %L) $$,
         pg_temp.cand(1, (select s1 from vagas))),
  'PGRST', pg_temp.erro('sem_permissao'),
  'quem não é da casa não escolhe: 403 sem_permissao');
select throws_ok(
  format($$ select pg_temp.escolher('c9000000-0000-4000-8000-0000000000d1', %L) $$,
         pg_temp.cand(4, (select s1 from vagas))),
  'PGRST', pg_temp.erro('candidatura_indisponivel'),
  'candidatura retirada não se escolhe: 409 candidatura_indisponivel');

create temp table escolha as
  select pg_temp.escolher('c9000000-0000-4000-8000-0000000000d1',
                          pg_temp.cand(1, (select s1 from vagas))) as r;

select is((select r->>'estado' from escolha), 'confirmada',
  'escolher confirma o candidato');
select is((select r->'contato'->>'telefone' from escolha), '+5561977770011',
  'RN10: a resposta traz o contato do profissional escolhido');
select is((select count(*)::int from public.posicao where vaga_id = (select s1 from vagas)
            and estado = 'confirmada' and profissional_id =
              (select id from public.profissional where usuario_id = pg_temp.p(1))), 1,
  'RN19: a posição fica confirmada para o escolhido, e só para ele');
select is((select valor_acordado_centavos from public.turno where id = (select (r->>'turno_id')::uuid from escolha)),
  18000::bigint, 'RN11: o turno nasce com o valor da vaga');
select is((select estado::text from public.vaga where id = (select s1 from vagas)), 'preenchida',
  'a última posição escolhida fecha a vaga');
select is(array[pg_temp.estado_cand(1, (select s1 from vagas)), pg_temp.estado_cand(2, (select s1 from vagas)),
                pg_temp.estado_cand(3, (select s1 from vagas)), pg_temp.estado_cand(4, (select s1 from vagas))],
  array['aceita', 'recusada', 'recusada', 'retirada'],
  'os não escolhidos são liberados (recusada); quem retirou continua retirada');
select is(pg_temp.avisos(1, 'confirmacao', (select s1 from vagas)), 1,
  'o escolhido recebe confirmacao');
select is(pg_temp.avisos(2, 'candidatura_recusada', (select s1 from vagas))
          + pg_temp.avisos(3, 'candidatura_recusada', (select s1 from vagas))
          + pg_temp.avisos(4, 'candidatura_recusada', (select s1 from vagas)), 2,
  'os dois não escolhidos pendentes recebem candidatura_recusada; quem retirou, não');
select is((select array_agg(k order by k) from public.notificacao n, jsonb_object_keys(n.payload) k
            where n.usuario_id = pg_temp.p(2) and n.tipo = 'candidatura_recusada'),
  array['tipo', 'vaga_id'],
  'RN15: o aviso leva só o tipo e a vaga');
select throws_ok(
  format($$ select pg_temp.escolher('c9000000-0000-4000-8000-0000000000d1', %L) $$,
         pg_temp.cand(1, (select s1 from vagas))),
  'PGRST', pg_temp.erro('candidatura_indisponivel'),
  'escolher de novo a candidatura já escolhida: 409 candidatura_indisponivel');
select throws_ok(
  format($$ select pg_temp.escolher('c9000000-0000-4000-8000-0000000000d1', %L) $$,
         pg_temp.cand(2, (select s1 from vagas))),
  'PGRST', pg_temp.erro('posicao_ja_preenchida'),
  'RN19: com a vaga cheia, escolher outro candidato responde posicao_ja_preenchida');
select throws_ok(
  format($$ select pg_temp.como(pg_temp.p(1), $x$ select public.retirar_candidatura(%L) $x$) $$,
         pg_temp.cand(1, (select s1 from vagas))),
  'PGRST', pg_temp.erro('candidatura_indisponivel'),
  'candidatura escolhida não se retira: vira cancelamento');
select is(pg_temp.candidatar(1, (select s1 from vagas))->>'estado', 'confirmada',
  'o escolhido que reenvia a candidatura recebe o próprio turno');
select throws_ok(
  format($$ select pg_temp.candidatar(5, %L) $$, (select s1 from vagas)),
  'PGRST', pg_temp.erro('posicao_ja_preenchida'),
  'vaga preenchida não aceita candidatura nova');

-- ── 5. Duas posições, RN21, conta suspensa e cancelamento ───────────────────────

select throws_ok(
  format($$ select pg_temp.candidatar(1, %L) $$, (select s2 from vagas)),
  'PGRST', pg_temp.erro('inelegivel', 'turno_sobreposto'),
  'RN21: quem já tem turno no mesmo horário não se candidata');
select pg_temp.candidatar(n, (select s2 from vagas)) from unnest(array[2, 3, 5]) n;

-- p2 ganha a vaga de urgência que se cruza com S2 depois de se candidatar a ela.
select is(pg_temp.candidatar(2, (select u1 from vagas))->>'estado', 'confirmada',
  'p2 é confirmado em outra vaga que se cruza com S2');
select throws_ok(
  format($$ select pg_temp.escolher('c9000000-0000-4000-8000-0000000000d1', %L) $$,
         pg_temp.cand(2, (select s2 from vagas))),
  'PGRST', pg_temp.erro('inelegivel', 'turno_sobreposto'),
  'RN21: escolher quem ficou com turno sobreposto é recusado');
select is(pg_temp.estado_cand(2, (select s2 from vagas)), 'pendente',
  'a escolha recusada não mexe na candidatura');

select is(pg_temp.escolher('c9000000-0000-4000-8000-0000000000d1',
            pg_temp.cand(3, (select s2 from vagas)))->>'estado', 'confirmada',
  'na vaga de duas posições, a primeira escolha confirma');
select is(array[(select estado::text from public.vaga where id = (select s2 from vagas)),
                pg_temp.estado_cand(5, (select s2 from vagas))],
  array['publicada', 'pendente'],
  'com posição sobrando, a vaga segue publicada e os outros continuam pendentes');

select pg_temp.candidatar(6, (select s4 from vagas));
update public.usuario set estado = 'suspensa' where id = pg_temp.p(6);
select throws_ok(
  format($$ select pg_temp.escolher('c9000000-0000-4000-8000-0000000000d1', %L) $$,
         pg_temp.cand(6, (select s4 from vagas))),
  'PGRST', pg_temp.erro('inelegivel', 'perfil_suspenso'),
  'RN13: candidato suspenso depois de se candidatar não é escolhido');
select pg_temp.candidatar(4, (select s4 from vagas));
select pg_temp.como('c9000000-0000-4000-8000-0000000000d1',
  format($$ select public.cancelar_vaga(%L, 'mudou o evento') $$, (select s4 from vagas)));
select is(array[pg_temp.estado_cand(4, (select s4 from vagas)), pg_temp.estado_cand(6, (select s4 from vagas))],
  array['expirada', 'expirada'],
  'vaga cancelada expira as candidaturas pendentes');

-- ── 6. O fechamento automático, 24 h antes ──────────────────────────────────────

select pg_temp.candidatar(5, (select s3 from vagas));

select is((select count(*)::int from cron.job
            where jobname = 'fechar_selecoes' and command = 'select privado.fechar_selecoes()'),
  1, 'o fechamento do modo seleção está agendado no pg_cron');
select is((select schedule from cron.job where jobname = 'fechar_selecoes'), '* * * * *',
  'e roda a cada minuto');

-- O job é global, e o cenário do seed tem vaga de seleção própria: as asserções olham
-- para as vagas deste arquivo.
select privado.fechar_selecoes();
select is((select array_agg(estado::text order by id) from public.vaga
            where id in ((select s2 from vagas), (select s3 from vagas))),
  array['publicada', 'publicada'],
  'antes das 24 h, nada fecha');

-- 05/11 20:00 − 24 h = 04/11 20:00.
select set_config('frila.agora', '2026-11-04 20:00:00+00', true);

select throws_ok(
  format($$ select pg_temp.candidatar(4, %L) $$, (select s3 from vagas)),
  'PGRST', pg_temp.erro('vaga_encerrada'),
  'RN24: a partir de 24 h antes a vaga de seleção não aceita candidatura, antes mesmo do job');
select throws_ok(
  format($$ select pg_temp.escolher('c9000000-0000-4000-8000-0000000000d1', %L) $$,
         pg_temp.cand(5, (select s2 from vagas))),
  'PGRST', pg_temp.erro('vaga_encerrada'),
  'RN24: nem aceita escolha');

select cmp_ok(privado.fechar_selecoes(), '>=', 2, 'o job fecha as vagas de seleção vencidas (S2 e S3)');

select is((select estado::text from public.vaga where id = (select s3 from vagas)), 'encerrada',
  'sem escolha nenhuma, a vaga encerra');
select is((select estado::text from public.posicao where vaga_id = (select s3 from vagas)), 'cancelada',
  'e a posição aberta passa a cancelada');
select is(pg_temp.estado_cand(5, (select s3 from vagas)), 'expirada',
  'o candidato pendente é liberado (expirada)');
select is(pg_temp.avisos(5, 'selecao_encerrada', (select s3 from vagas)), 1,
  'e avisado com selecao_encerrada');
select is((select count(*)::int from public.notificacao
            where usuario_id = 'c9000000-0000-4000-8000-0000000000d1'
              and tipo = 'selecao_encerrada' and payload->>'vaga_id' = (select s3 from vagas)::text), 1,
  'a casa também é avisada');

select is((select estado::text from public.vaga where id = (select s2 from vagas)), 'preenchida',
  'com uma escolha feita, a vaga fecha como preenchida');
select is((select array_agg(estado::text order by estado::text) from public.posicao
            where vaga_id = (select s2 from vagas)),
  array['cancelada', 'confirmada'],
  'a posição escolhida continua confirmada; a outra é cancelada');
select is(array[pg_temp.estado_cand(2, (select s2 from vagas)), pg_temp.estado_cand(5, (select s2 from vagas))],
  array['expirada', 'expirada'],
  'os pendentes de S2 são liberados');

select is(privado.fechar_selecoes(), 0, 'rodar de novo não fecha nada');
select is(pg_temp.avisos(5, 'selecao_encerrada', (select s3 from vagas)), 1,
  'e não repete aviso');

select * from finish();
rollback;
