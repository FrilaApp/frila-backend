-- 15 recusas de maior risco vigiadas no portão do contrato (04/10/2026).
--
-- Cobre as 15 recusas de maior criticidade catalogadas em /private/tmp/claude-502/recusas-nao-vigiadas-04-10.md:
-- 1.  contatoDoTurno (403 sem_permissao)
-- 2.  contatoDoTurno (404 nao_encontrado)
-- 3.  cancelarPosicao (409 posicao_nao_cancelavel)
-- 4.  cancelarVaga (409 vaga_encerrada)
-- 5.  excluirConta (409 administrador_unico)
-- 6.  bloquear (403 sem_permissao)
-- 7.  bloquear (422 campo_invalido)
-- 8.  denunciar (403 sem_permissao)
-- 9.  contestarSuspensao (409 contestacao_ja_aberta)
-- 10. contestarSuspensao (422 sem_suspensao_ativa)
-- 11. reabrirPorAtraso (409 posicao_nao_cancelavel)
-- 12. reabrirPorAtraso (403 sem_permissao)
-- 13. confirmarCheckinManual (409 checkin_ja_confirmado)
-- 14. fazerCheckin (409 vaga_encerrada)
-- 15. fazerCheckout (409 checkin_pendente)
--
-- Ids próprios começando em `c4850000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(15);

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
  'c4850000-0000-4000-8000-000000000001'::uuid as contratante_dono,
  'c4850000-0000-4000-8000-000000000002'::uuid as contratante_outro,
  'c4850000-0000-4000-8000-000000000003'::uuid as profissional_1,
  'c4850000-0000-4000-8000-000000000004'::uuid as profissional_suspenso;

select pg_temp.autenticar((select contratante_dono from ids), 'dono485@test.local');
select pg_temp.autenticar((select contratante_outro from ids), 'outro485@test.local');
select pg_temp.autenticar((select profissional_1 from ids), 'pro485@test.local');
select pg_temp.autenticar((select profissional_suspenso from ids), 'suspenso485@test.local');

-- Criação de contas
select pg_temp.como((select contratante_dono from ids),
  $$ select public.criar_conta('contratante','Dono Casa 485','+5561948500001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select contratante_outro from ids),
  $$ select public.criar_conta('contratante','Outro Contratante 485','+5561948500002','1980-01-01','2026-09-22') $$);
select pg_temp.como((select profissional_1 from ids),
  $$ select public.criar_conta('profissional','Profissional 485','+5561948500003','1995-01-01','2026-09-22') $$);
select pg_temp.como((select profissional_suspenso from ids),
  $$ select public.criar_conta('profissional','Suspenso 485','+5561948500004','1993-05-05','2026-09-22') $$);

update public.usuario set estado = 'suspensa' where id = (select profissional_suspenso from ids);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select profissional_1 from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));

create temp table casa as
  select (pg_temp.como((select contratante_dono from ids),
    $$ select public.cadastrar_estabelecimento('Casa Teste 485','04252011000110','food_service',
         'CLN 408','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

-- Vaga 1: turno geolocalizado já concluído com check-in
create temp table v1 as
  select (pg_temp.como((select contratante_dono from ids), format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-04-01 18:00:00+00'::timestamptz, '2027-04-01 23:00:00+00'::timestamptz,
         'CLN 408','{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         15000::bigint, 1, true, false, false, 'Garçom',
         'urgencia'::public.modo_preenchimento, gen_random_uuid()) $$,
    (select id from casa), (select garcom from fn)))->>'vaga_id')::uuid as vaga_id;

create temp table cand1 as
  select pg_temp.como((select profissional_1 from ids), format(
    $$ select public.candidatar(%L::uuid) $$, (select vaga_id from v1))) as r;

-- Checkin geolocalizado no turno 1
select set_config('frila.agora', '2027-04-01 18:05:00+00', true);
select pg_temp.como((select profissional_1 from ids), format(
  $$ select public.fazer_checkin(%L::uuid, 50, '2027-04-01 18:05:00+00'::timestamptz) $$,
  ((select r from cand1)->>'turno_id')::uuid));

-- Vaga 2: vaga que será cancelada
create temp table v2 as
  select (pg_temp.como((select contratante_dono from ids), format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-04-05 18:00:00+00'::timestamptz, '2027-04-05 23:00:00+00'::timestamptz,
         'CLN 408','{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         15000::bigint, 1, true, false, false, 'Garçom',
         'urgencia'::public.modo_preenchimento, gen_random_uuid()) $$,
    (select id from casa), (select garcom from fn)))->>'vaga_id')::uuid as vaga_id;

-- Vaga 3: vaga com posição cancelada por reabertura por atraso
create temp table v3 as
  select (pg_temp.como((select contratante_dono from ids), format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-04-10 18:00:00+00'::timestamptz, '2027-04-10 23:00:00+00'::timestamptz,
         'CLN 408','{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         15000::bigint, 1, true, false, false, 'Garçom',
         'urgencia'::public.modo_preenchimento, gen_random_uuid()) $$,
    (select id from casa), (select garcom from fn)))->>'vaga_id')::uuid as vaga_id;

create temp table cand3 as
  select pg_temp.como((select profissional_1 from ids), format(
    $$ select public.candidatar(%L::uuid) $$, (select vaga_id from v3))) as r;

-- Reabre por atraso vaga 3 (posição de cand3 fica cancelada)
select set_config('frila.agora', '2027-04-10 18:20:00+00', true);
select pg_temp.como((select contratante_dono from ids), format(
  $$ select public.reabrir_por_atraso(%L::uuid) $$, ((select r from cand3)->>'posicao_id')::uuid));

-- ── 1. contatoDoTurno: 403 sem_permissao (conta suspensa) ──────────────────────
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids), format(
    $$ select public.contato_do_turno(%L::uuid) $$, ((select r from cand1)->>'turno_id')::uuid)),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '1. contatoDoTurno: conta suspensa recebe 403 sem_permissao'
);

-- ── 2. contatoDoTurno: 404 nao_encontrado (turno inexistente) ──────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids),
    $$ select public.contato_do_turno('c4850000-0000-4000-8000-000000000099'::uuid) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '2. contatoDoTurno: turno inexistente recebe 404 nao_encontrado'
);

-- ── 3. cancelarPosicao: 409 posicao_nao_cancelavel ─────────────────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids), format(
    $$ select public.cancelar_posicao(%L::uuid, 'duplicado') $$, ((select r from cand3)->>'posicao_id')::uuid)),
  'PGRST',
  pg_temp.erro('posicao_nao_cancelavel'),
  '3. cancelarPosicao: posicao ja cancelada recebe 409 posicao_nao_cancelavel'
);

-- ── 4. cancelarVaga: 409 vaga_encerrada ────────────────────────────────────────
select pg_temp.como((select contratante_dono from ids), format(
  $$ select public.cancelar_vaga(%L::uuid, 'evento adiado') $$, (select vaga_id from v2)));

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ((select id from casa), (select contratante_outro from ids), 'operador')
on conflict do nothing;

select throws_ok(
  pg_temp.por((select contratante_outro from ids), format(
    $$ select public.cancelar_vaga(%L::uuid, 'evento adiado') $$, (select vaga_id from v2))),
  'PGRST',
  pg_temp.erro('vaga_encerrada'),
  '4. cancelarVaga: vaga ja cancelada recebe 409 vaga_encerrada'
);

-- ── 5. excluirConta: 409 administrador_unico ───────────────────────────────────
select throws_ok(
  format('select privado.excluir_conta(%L::uuid)', (select contratante_dono from ids)),
  'PGRST',
  pg_temp.erro('administrador_unico'),
  '5. excluirConta: administrador unico com outros membros recebe 409 administrador_unico'
);

delete from public.membro_estabelecimento
 where estabelecimento_id = (select id from casa)
   and usuario_id = (select contratante_outro from ids);

-- ── 6. bloquear: 403 sem_permissao (conta suspensa) ───────────────────────────
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids), format(
    $$ select public.bloquear('estabelecimento', %L::uuid) $$, (select id from casa))),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '6. bloquear: conta suspensa recebe 403 sem_permissao'
);

-- ── 7. bloquear: 422 campo_invalido (auto-bloqueio) ───────────────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids), format(
    $$ select public.bloquear('profissional', (select p.id from public.profissional p where p.usuario_id = %L::uuid)) $$,
    (select profissional_1 from ids))),
  'PGRST',
  pg_temp.erro('campo_invalido', 'alvo_tipo'),
  '7. bloquear: auto-bloqueio recebe 422 campo_invalido'
);

-- ── 8. denunciar: 403 sem_permissao (conta suspensa) ──────────────────────────
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids), format(
    $$ select public.denunciar('estabelecimento', %L::uuid, 'outro', 'relato teste', gen_random_uuid()) $$,
    (select id from casa))),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '8. denunciar: conta suspensa recebe 403 sem_permissao'
);

-- ── 9. contestarSuspensao: 409 contestacao_ja_aberta ──────────────────────────
select privado.suspender(
  (select profissional_suspenso from ids),
  'Suspensao de teste',
  (select contratante_dono from ids)
);

select pg_temp.como((select profissional_suspenso from ids),
  $$ select public.contestar_suspensao('Primeira contestacao com mais de dez caracteres.') $$);

select throws_ok(
  pg_temp.por((select profissional_suspenso from ids),
    $$ select public.contestar_suspensao('Segunda tentativa enquanto a primeira esta aberta.') $$),
  'PGRST',
  pg_temp.erro('contestacao_ja_aberta'),
  '9. contestarSuspensao: contestacao repetida recebe 409 contestacao_ja_aberta'
);

-- ── 10. contestarSuspensao: 422 sem_suspensao_ativa ───────────────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids),
    $$ select public.contestar_suspensao('Conta ativa tentando contestar.') $$),
  'PGRST',
  pg_temp.erro('sem_suspensao_ativa'),
  '10. contestarSuspensao: conta ativa recebe 422 sem_suspensao_ativa'
);

-- ── 11. reabrirPorAtraso: 409 posicao_nao_cancelavel (com check-in) ────────────
select throws_ok(
  pg_temp.por((select contratante_dono from ids), format(
    $$ select public.reabrir_por_atraso(%L::uuid) $$, ((select r from cand1)->>'posicao_id')::uuid)),
  'PGRST',
  pg_temp.erro('posicao_nao_cancelavel', 'checkin_registrado'),
  '11. reabrirPorAtraso: posicao com check-in realizado recebe 409 posicao_nao_cancelavel'
);

-- ── 12. reabrirPorAtraso: 403 sem_permissao (não membro) ───────────────────────
select throws_ok(
  pg_temp.por((select contratante_outro from ids), format(
    $$ select public.reabrir_por_atraso(%L::uuid) $$, ((select r from cand1)->>'posicao_id')::uuid)),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '12. reabrirPorAtraso: contratante de outro estabelecimento recebe 403 sem_permissao'
);

-- ── 13. confirmarCheckinManual: 409 checkin_ja_confirmado ─────────────────────
select throws_ok(
  pg_temp.por((select contratante_dono from ids), format(
    $$ select public.confirmar_checkin_manual(%L::uuid) $$, ((select r from cand1)->>'turno_id')::uuid)),
  'PGRST',
  pg_temp.erro('checkin_ja_confirmado'),
  '13. confirmarCheckinManual: check-in geolocalizado recebe 409 checkin_ja_confirmado'
);

-- ── 14. fazerCheckin: 409 vaga_encerrada (em posição cancelada) ────────────────
select throws_ok(
  pg_temp.por((select profissional_1 from ids), format(
    $$ select public.fazer_checkin(%L::uuid, 50, '2027-04-10 18:20:00+00'::timestamptz) $$,
    ((select r from cand3)->>'turno_id')::uuid)),
  'PGRST',
  pg_temp.erro('vaga_encerrada', 'posicao_cancelada'),
  '14. fazerCheckin: check-in em posicao cancelada recebe 409 vaga_encerrada'
);

-- ── 15. fazerCheckout: 409 checkin_pendente (sem check-in) ─────────────────────
create temp table v4 as
  select (pg_temp.como((select contratante_dono from ids), format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-04-15 18:00:00+00'::timestamptz, '2027-04-15 23:00:00+00'::timestamptz,
         'CLN 408','{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         15000::bigint, 1, true, false, false, 'Garçom',
         'urgencia'::public.modo_preenchimento, gen_random_uuid()) $$,
    (select id from casa), (select garcom from fn)))->>'vaga_id')::uuid as vaga_id;

create temp table cand4 as
  select pg_temp.como((select profissional_1 from ids), format(
    $$ select public.candidatar(%L::uuid) $$, (select vaga_id from v4))) as r;

select set_config('frila.agora', '2027-04-15 23:10:00+00', true);

select throws_ok(
  pg_temp.por((select profissional_1 from ids), format(
    $$ select public.fazer_checkout(%L::uuid, 50, '2027-04-15 23:10:00+00'::timestamptz) $$,
    ((select r from cand4)->>'turno_id')::uuid)),
  'PGRST',
  pg_temp.erro('checkin_pendente'),
  '15. fazerCheckout: checkout sem check-in previo recebe 409 checkin_pendente'
);

rollback;
