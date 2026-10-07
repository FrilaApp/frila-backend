-- 15 recusas criticas do contrato lote 7 (07/10/2026).
--
-- Cobertura de regras de negócio (422 validações de campos e perfis incompatíveis):
-- 1.  painelEstabelecimento (422 campo_obrigatorio)
-- 2.  candidatar (422 campo_obrigatorio)
-- 3.  retirarCandidatura (422 campo_obrigatorio)
-- 4.  reabrirPorAtraso (422 campo_obrigatorio)
-- 5.  confirmarCheckinManual (422 campo_obrigatorio)
-- 6.  contatoDoTurno (422 campo_obrigatorio)
-- 7.  detalheVaga (422 campo_obrigatorio)
-- 8.  candidatosDaVaga (422 campo_obrigatorio)
-- 9.  republicarVaga (422 campo_obrigatorio)
-- 10. avisarACaminho (422 campo_obrigatorio)
-- 11. configuracaoDoApp (422 campo_obrigatorio)
-- 12. criarPerfilProfissional (422 perfil_incompativel)
-- 13. vagasAbertas (422 perfil_incompativel)
-- 14. minhasCandidaturas (422 perfil_incompativel)
-- 15. meusEstabelecimentos (422 perfil_incompativel)
--
-- Ids próprios começando em `c4920000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(15);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

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
  'c4920000-0000-4000-8000-000000000001'::uuid as contratante_id,
  'c4920000-0000-4000-8000-000000000002'::uuid as profissional_id;

select pg_temp.autenticar((select contratante_id from ids), 'contratante492@test.local');
select pg_temp.autenticar((select profissional_id from ids), 'profissional492@test.local');

select pg_temp.como((select contratante_id from ids),
  $$ select public.criar_conta('contratante','Contratante 492','+5561911114921','1985-01-01','2026-09-22') $$);
select pg_temp.como((select profissional_id from ids),
  $$ select public.criar_conta('profissional','Profissional 492','+5561922224922','1990-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select profissional_id from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));

create temp table casa as
  select (pg_temp.como((select contratante_id from ids),
    $$ select public.cadastrar_estabelecimento('Casa Teste 492','77598687000133','food_service',
         'CLN 408','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

-- 1. painelEstabelecimento: 422 campo_obrigatorio (de nulo)
select throws_ok(
  pg_temp.por((select contratante_id from ids), format(
    $$ select public.painel_estabelecimento(%L::uuid, null, '2027-01-11 23:59:59+00'::timestamptz) $$,
    (select id from casa))),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'de'),
  '1. painelEstabelecimento com de nulo recusa 422 campo_obrigatorio'
);

-- 2. candidatar: 422 campo_obrigatorio (vaga_id nula)
select throws_ok(
  pg_temp.por((select profissional_id from ids),
    $$ select public.candidatar(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'vaga_id'),
  '2. candidatar com vaga_id nula recusa 422 campo_obrigatorio'
);

-- 3. retirarCandidatura: 422 campo_obrigatorio (candidatura_id nula)
select throws_ok(
  pg_temp.por((select profissional_id from ids),
    $$ select public.retirar_candidatura(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'candidatura_id'),
  '3. retirarCandidatura com candidatura_id nula recusa 422 campo_obrigatorio'
);

-- 4. reabrirPorAtraso: 422 campo_obrigatorio (posicao_id nula)
select throws_ok(
  pg_temp.por((select contratante_id from ids),
    $$ select public.reabrir_por_atraso(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'posicao_id'),
  '4. reabrirPorAtraso com posicao_id nula recusa 422 campo_obrigatorio'
);

-- 5. confirmarCheckinManual: 422 campo_obrigatorio (turno_id nulo)
select throws_ok(
  pg_temp.por((select contratante_id from ids),
    $$ select public.confirmar_checkin_manual(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'turno_id'),
  '5. confirmarCheckinManual com turno_id nulo recusa 422 campo_obrigatorio'
);

-- 6. contatoDoTurno: 422 campo_obrigatorio (turno_id nulo)
select throws_ok(
  pg_temp.por((select profissional_id from ids),
    $$ select public.contato_do_turno(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'turno_id'),
  '6. contatoDoTurno com turno_id nulo recusa 422 campo_obrigatorio'
);

-- 7. detalheVaga: 422 campo_obrigatorio (vaga_id nula)
select throws_ok(
  pg_temp.por((select profissional_id from ids),
    $$ select public.detalhe_vaga(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'vaga_id'),
  '7. detalheVaga com vaga_id nula recusa 422 campo_obrigatorio'
);

-- 8. candidatosDaVaga: 422 campo_obrigatorio (vaga_id nula)
select throws_ok(
  pg_temp.por((select contratante_id from ids),
    $$ select public.candidatos_da_vaga(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'vaga_id'),
  '8. candidatosDaVaga com vaga_id nula recusa 422 campo_obrigatorio'
);

-- 9. republicarVaga: 422 campo_obrigatorio (vaga_origem_id nula)
select throws_ok(
  pg_temp.por((select contratante_id from ids),
    $$ select public.republicar_vaga(null, '2027-02-15 21:00:00+00'::timestamptz, '2027-02-16 03:00:00+00'::timestamptz, gen_random_uuid()) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'vaga_id'),
  '9. republicarVaga com vaga_origem_id nula recusa 422 campo_obrigatorio'
);

-- 10. avisarACaminho: 422 campo_obrigatorio (turno_id nulo)
select throws_ok(
  pg_temp.por((select profissional_id from ids),
    $$ select public.avisar_a_caminho(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'turno_id'),
  '10. avisarACaminho com turno_id nulo recusa 422 campo_obrigatorio'
);

-- 11. configuracaoDoApp: 422 campo_obrigatorio (plataforma nula)
select throws_ok(
  pg_temp.por((select profissional_id from ids),
    $$ select public.configuracao_do_app(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'plataforma'),
  '11. configuracaoDoApp com plataforma nula recusa 422 campo_obrigatorio'
);

-- 12. criarPerfilProfissional: 422 perfil_incompativel (contratante tentando criar perfil profissional)
select throws_ok(
  pg_temp.por((select contratante_id from ids), format(
    $$ select public.criar_perfil_profissional(array[%L]::uuid[], null, null) $$, (select garcom from fn))),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  '12. criarPerfilProfissional por contratante recusa 422 perfil_incompativel'
);

-- 13. vagasAbertas: 422 perfil_incompativel (contratante tentando consultar vagas abertas)
select throws_ok(
  pg_temp.por((select contratante_id from ids),
    $$ select public.vagas_abertas() $$),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  '13. vagasAbertas por contratante recusa 422 perfil_incompativel'
);

-- 14. minhasCandidaturas: 422 perfil_incompativel (contratante tentando consultar candidaturas)
select throws_ok(
  pg_temp.por((select contratante_id from ids),
    $$ select public.minhas_candidaturas() $$),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  '14. minhasCandidaturas por contratante recusa 422 perfil_incompativel'
);

-- 15. meusEstabelecimentos: 422 perfil_incompativel (profissional tentando consultar estabelecimentos)
select throws_ok(
  pg_temp.por((select profissional_id from ids),
    $$ select public.meus_estabelecimentos() $$),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  '15. meusEstabelecimentos por profissional recusa 422 perfil_incompativel'
);

rollback;
