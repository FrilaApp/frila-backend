-- 20 recusas criticas do contrato lote 2 (04/10/2026).
--
-- Cobre os 20 pares adicionais de recusa por risco do inventario /private/tmp/claude-502/recusas-nao-vigiadas-04-10.md:
-- 1.  cancelarPosicao (404 nao_encontrado)
-- 2.  cancelarPosicao (403 sem_permissao)
-- 3.  cancelarVaga (404 nao_encontrado)
-- 4.  cancelarVaga (403 sem_permissao)
-- 5.  publicarVaga (403 sem_permissao)
-- 6.  candidatar (404 nao_encontrado)
-- 7.  candidatar (409 vaga_encerrada)
-- 8.  retirarCandidatura (404 nao_encontrado)
-- 9.  retirarCandidatura (409 candidatura_indisponivel)
-- 10. escolherCandidato (403 sem_permissao)
-- 11. escolherCandidato (409 posicao_ja_preenchida)
-- 12. avaliar (403 sem_permissao)
-- 13. avaliar (409 avaliacao_ja_registrada)
-- 14. cadastrarEstabelecimento (409 documento_ja_cadastrado)
-- 15. cadastrarEstabelecimento (403 sem_permissao)
-- 16. bloquear (404 nao_encontrado)
-- 17. denunciar (404 nao_encontrado)
-- 18. denunciar (422 campo_invalido)
-- 19. avisarACaminho (403 sem_permissao)
-- 20. configuracaoDoApp (404 nao_encontrado)
--
-- Ids proprios comecando em `c4860000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(20);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2027-04-01 12:00:00+00', true);

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

create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create temp table ids as select
  'c4860000-0000-4000-8000-000000000001'::uuid as contratante_dono,
  'c4860000-0000-4000-8000-000000000002'::uuid as contratante_outro,
  'c4860000-0000-4000-8000-000000000003'::uuid as profissional_1,
  'c4860000-0000-4000-8000-000000000004'::uuid as profissional_2,
  'c4860000-0000-4000-8000-000000000005'::uuid as profissional_suspenso;

select pg_temp.autenticar((select contratante_dono from ids), 'dono486@test.local');
select pg_temp.autenticar((select contratante_outro from ids), 'outro486@test.local');
select pg_temp.autenticar((select profissional_1 from ids), 'pro1_486@test.local');
select pg_temp.autenticar((select profissional_2 from ids), 'pro2_486@test.local');
select pg_temp.autenticar((select profissional_suspenso from ids), 'suspenso486@test.local');

-- Criacao de contas
select pg_temp.como((select contratante_dono from ids),
  $$ select public.criar_conta('contratante','Dono Casa 486','+5561948600001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select contratante_outro from ids),
  $$ select public.criar_conta('contratante','Outro Contratante 486','+5561948600002','1980-01-01','2026-09-22') $$);
select pg_temp.como((select profissional_1 from ids),
  $$ select public.criar_conta('profissional','Profissional 1 486','+5561948600003','1995-01-01','2026-09-22') $$);
select pg_temp.como((select profissional_2 from ids),
  $$ select public.criar_conta('profissional','Profissional 2 486','+5561948600004','1994-01-01','2026-09-22') $$);
select pg_temp.como((select profissional_suspenso from ids),
  $$ select public.criar_conta('profissional','Suspenso 486','+5561948600005','1993-05-05','2026-09-22') $$);

update public.usuario set estado = 'suspensa' where id = (select profissional_suspenso from ids);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select profissional_1 from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));
select pg_temp.como((select profissional_2 from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));

create temp table casa as
  select (pg_temp.como((select contratante_dono from ids),
    $$ select public.cadastrar_estabelecimento('Casa Teste 486','77598687000133','food_service',
         'CLN 408','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

-- Vaga 1 (urgencia)
create temp table v1 as
  select (pg_temp.como((select contratante_dono from ids), format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-04-05 18:00:00+00'::timestamptz, '2027-04-05 23:00:00+00'::timestamptz,
         'CLN 408','{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         15000::bigint, 1, true, false, false, 'Garçom',
         'urgencia'::public.modo_preenchimento, gen_random_uuid()) $$,
    (select id from casa), (select garcom from fn)))->>'vaga_id')::uuid as vaga_id;

create temp table cand1 as
  select pg_temp.como((select profissional_1 from ids), format(
    $$ select public.candidatar(%L::uuid) $$, (select vaga_id from v1))) as r;

-- Checkin, checkout e avaliacao no turno 1
select set_config('frila.agora', '2027-04-05 18:05:00+00', true);
select pg_temp.como((select profissional_1 from ids), format(
  $$ select public.fazer_checkin(%L::uuid, 40, '2027-04-05 18:05:00+00'::timestamptz) $$,
  ((select r from cand1)->>'turno_id')::uuid));

select set_config('frila.agora', '2027-04-05 22:55:00+00', true);
select pg_temp.como((select profissional_1 from ids), format(
  $$ select public.fazer_checkout(%L::uuid, 45, '2027-04-05 22:55:00+00'::timestamptz) $$,
  ((select r from cand1)->>'turno_id')::uuid));

select set_config('frila.agora', '2027-04-06 00:00:00+00', true);
select pg_temp.como((select contratante_dono from ids), format(
  $$ select public.avaliar(%L::uuid, true) $$, ((select r from cand1)->>'turno_id')::uuid));

-- Vaga 2 (para cancelamento)
create temp table v2 as
  select (pg_temp.como((select contratante_dono from ids), format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-04-10 18:00:00+00'::timestamptz, '2027-04-10 23:00:00+00'::timestamptz,
         'CLN 408','{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         15000::bigint, 1, true, false, false, 'Garçom',
         'urgencia'::public.modo_preenchimento, gen_random_uuid()) $$,
    (select id from casa), (select garcom from fn)))->>'vaga_id')::uuid as vaga_id;

select pg_temp.como((select contratante_dono from ids), format(
  $$ select public.cancelar_vaga(%L::uuid, 'evento adiado') $$, (select vaga_id from v2)));

-- Vaga Selecao
create temp table v_sel as
  select (pg_temp.como((select contratante_dono from ids), format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-04-15 18:00:00+00'::timestamptz, '2027-04-15 23:00:00+00'::timestamptz,
         'CLN 408','{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         15000::bigint, 1, true, false, false, 'Garçom',
         'selecao'::public.modo_preenchimento, gen_random_uuid()) $$,
    (select id from casa), (select garcom from fn)))->>'vaga_id')::uuid as vaga_id;

create temp table cand_sel1 as
  select pg_temp.como((select profissional_1 from ids), format(
    $$ select public.candidatar(%L::uuid) $$, (select vaga_id from v_sel))) as r;
create temp table cand_sel2 as
  select pg_temp.como((select profissional_2 from ids), format(
    $$ select public.candidatar(%L::uuid) $$, (select vaga_id from v_sel))) as r;

select pg_temp.como((select contratante_dono from ids), format(
  $$ select public.escolher_candidato(%L::uuid) $$, ((select r from cand_sel1)->>'candidatura_id')::uuid));

-- ── 1. cancelarPosicao: 404 nao_encontrado ─────────────────────────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids),
    $$ select public.cancelar_posicao('c4860000-0000-4000-8000-000000000099'::uuid, 'imprevisto') $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '1. cancelarPosicao: posicao inexistente devolve 404 nao_encontrado'
);

-- ── 2. cancelarPosicao: 403 sem_permissao ──────────────────────────────────────
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids),
    $$ select public.cancelar_posicao('c4860000-0000-4000-8000-000000000099'::uuid, 'imprevisto') $$),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '2. cancelarPosicao: conta suspensa devolve 403 sem_permissao'
);

-- ── 3. cancelarVaga: 404 nao_encontrado ────────────────────────────────────────
select throws_ok(
  pg_temp.por((select contratante_dono from ids),
    $$ select public.cancelar_vaga('c4860000-0000-4000-8000-000000000099'::uuid, 'evento adiado') $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '3. cancelarVaga: vaga inexistente devolve 404 nao_encontrado'
);

-- ── 4. cancelarVaga: 403 sem_permissao ─────────────────────────────────────────
update public.usuario set estado = 'suspensa' where id = (select contratante_outro from ids);
select throws_ok(
  pg_temp.por((select contratante_outro from ids), format(
    $$ select public.cancelar_vaga(%L::uuid, 'evento adiado') $$, (select vaga_id from v1))),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '4. cancelarVaga: contratante suspenso devolve 403 sem_permissao'
);

-- ── 5. publicarVaga: 403 sem_permissao ─────────────────────────────────────────
update public.usuario set estado = 'ativa' where id = (select contratante_outro from ids);
select throws_ok(
  pg_temp.por((select contratante_outro from ids), format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-04-20 18:00:00+00'::timestamptz, '2027-04-20 23:00:00+00'::timestamptz,
         'CLN 408','{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         15000::bigint, 1, true, false, false, 'Garçom',
         'urgencia'::public.modo_preenchimento, gen_random_uuid()) $$,
    (select id from casa), (select garcom from fn))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '5. publicarVaga: nao membro do estabelecimento devolve 403 sem_permissao'
);

-- ── 6. candidatar: 404 nao_encontrado ──────────────────────────────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids),
    $$ select public.candidatar('c4860000-0000-4000-8000-000000000099'::uuid) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '6. candidatar: vaga inexistente devolve 404 nao_encontrado'
);

-- ── 7. candidatar: 409 vaga_encerrada ──────────────────────────────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids), format(
    $$ select public.candidatar(%L::uuid) $$, (select vaga_id from v2))),
  'PGRST',
  pg_temp.erro('vaga_encerrada'),
  '7. candidatar: vaga cancelada devolve 409 vaga_encerrada'
);

-- ── 8. retirarCandidatura: 404 nao_encontrado ──────────────────────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids),
    $$ select public.retirar_candidatura('c4860000-0000-4000-8000-000000000099'::uuid) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '8. retirarCandidatura: candidatura inexistente devolve 404 nao_encontrado'
);

-- ── 9. retirarCandidatura: 409 candidatura_indisponivel ────────────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids), format(
    $$ select public.retirar_candidatura(%L::uuid) $$, ((select r from cand1)->>'candidatura_id')::uuid)),
  'PGRST',
  pg_temp.erro('candidatura_indisponivel'),
  '9. retirarCandidatura: candidatura confirmada devolve 409 candidatura_indisponivel'
);

-- ── 10. escolherCandidato: 403 sem_permissao ───────────────────────────────────
select throws_ok(
  pg_temp.por((select contratante_dono from ids),
    $$ select public.escolher_candidato('c4860000-0000-4000-8000-000000000099'::uuid) $$),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '10. escolherCandidato: candidatura inexistente ou de outra casa devolve 403 sem_permissao'
);

-- ── 11. escolherCandidato: 409 posicao_ja_preenchida ───────────────────────────
select throws_ok(
  pg_temp.por((select contratante_dono from ids), format(
    $$ select public.escolher_candidato(%L::uuid) $$, ((select r from cand_sel2)->>'candidatura_id')::uuid)),
  'PGRST',
  pg_temp.erro('posicao_ja_preenchida'),
  '11. escolherCandidato: vaga ja preenchida devolve 409 posicao_ja_preenchida'
);

-- ── 12. avaliar: 403 sem_permissao ─────────────────────────────────────────────
select throws_ok(
  pg_temp.por((select profissional_2 from ids), format(
    $$ select public.avaliar(%L::uuid, true) $$, ((select r from cand1)->>'turno_id')::uuid)),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '12. avaliar: usuario alheio ao turno devolve 403 sem_permissao'
);

-- ── 13. avaliar: 409 avaliacao_ja_registrada ───────────────────────────────────
select throws_ok(
  pg_temp.por((select contratante_dono from ids), format(
    $$ select public.avaliar(%L::uuid, false) $$, ((select r from cand1)->>'turno_id')::uuid)),
  'PGRST',
  pg_temp.erro('avaliacao_ja_registrada'),
  '13. avaliar: reavaliacao divergente devolve 409 avaliacao_ja_registrada'
);

-- ── 14. cadastrarEstabelecimento: 409 documento_ja_cadastrado ──────────────────
select throws_ok(
  pg_temp.por((select contratante_outro from ids),
    $$ select public.cadastrar_estabelecimento('Outra Casa 486','77598687000133','food_service',
         'CLN 409','{"latitude":-15.7910,"longitude":-47.8860}') $$),
  'PGRST',
  pg_temp.erro('documento_ja_cadastrado'),
  '14. cadastrarEstabelecimento: documento duplicado devolve 409 documento_ja_cadastrado'
);

-- ── 15. cadastrarEstabelecimento: 403 sem_permissao ────────────────────────────
update public.usuario set estado = 'suspensa' where id = (select contratante_outro from ids);
select throws_ok(
  pg_temp.por((select contratante_outro from ids),
    $$ select public.cadastrar_estabelecimento('Casa Suspenso 486','32168583000150','food_service',
         'CLN 409','{"latitude":-15.7910,"longitude":-47.8860}') $$),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '15. cadastrarEstabelecimento: conta suspensa devolve 403 sem_permissao'
);

-- ── 16. bloquear: 404 nao_encontrado ───────────────────────────────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids),
    $$ select public.bloquear('estabelecimento', 'c4860000-0000-4000-8000-000000000099'::uuid) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '16. bloquear: alvo inexistente devolve 404 nao_encontrado'
);

-- ── 17. denunciar: 404 nao_encontrado ──────────────────────────────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids),
    $$ select public.denunciar('estabelecimento', 'c4860000-0000-4000-8000-000000000099'::uuid,
         'outro', 'relato de teste para denuncia 404', gen_random_uuid()) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '17. denunciar: alvo inexistente devolve 404 nao_encontrado'
);

-- ── 18. denunciar: 422 campo_invalido ──────────────────────────────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids), format(
    $$ select public.denunciar('estabelecimento', %L::uuid,
         'motivo_invalido', 'relato de teste com tamanho suficiente', gen_random_uuid()) $$,
    (select id from casa))),
  'PGRST',
  pg_temp.erro('campo_invalido', 'motivo'),
  '18. denunciar: motivo invalido devolve 422 campo_invalido'
);

-- ── 19. avisarACaminho: 403 sem_permissao ──────────────────────────────────────
select throws_ok(
  pg_temp.por((select profissional_2 from ids), format(
    $$ select public.avisar_a_caminho(%L::uuid) $$, ((select r from cand1)->>'turno_id')::uuid)),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '19. avisarACaminho: profissional alheio ao turno devolve 403 sem_permissao'
);

-- ── 20. configuracaoDoApp: 404 nao_encontrado ──────────────────────────────────
select throws_ok(
  $$ select public.configuracao_do_app('android') $$,
  'PGRST',
  pg_temp.erro('nao_encontrado', 'plataforma'),
  '20. configuracaoDoApp: plataforma sem linha devolve 404 nao_encontrado'
);

select * from finish();
rollback;
