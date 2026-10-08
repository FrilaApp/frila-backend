-- 15 recusas criticas do contrato lote 8 (07/10/2026).
--
-- Cobertura de regras de negócio (422 validações de negócio e 401 de autenticação):
-- 1.  criarConta (422 campo_obrigatorio)
-- 2.  registrarEvento (422 campo_obrigatorio)
-- 3.  escolherCandidato (401 nao_autenticado)
-- 4.  minhasCandidaturas (401 nao_autenticado)
-- 5.  vagasAbertas (401 nao_autenticado)
-- 6.  detalheVaga (401 nao_autenticado)
-- 7.  republicarVaga (401 nao_autenticado)
-- 8.  meusTurnos (401 nao_autenticado)
-- 9.  contatoDoTurno (401 nao_autenticado)
-- 10. avisarACaminho (401 nao_autenticado)
-- 11. painelEstabelecimento (401 nao_autenticado)
-- 12. meusEstabelecimentos (401 nao_autenticado)
-- 13. meuEstabelecimento (401 nao_autenticado)
-- 14. equipeDeConfianca (401 nao_autenticado)
-- 15. situacaoDaConta (401 nao_autenticado)
--
-- Ids próprios começando em `c4930000`.

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
  'c4930000-0000-4000-8000-000000000001'::uuid as usuario_novo_id,
  'c4930000-0000-4000-8000-000000000002'::uuid as usuario_ativo_id;

select pg_temp.autenticar((select usuario_novo_id from ids), 'novo493@test.local');
select pg_temp.autenticar((select usuario_ativo_id from ids), 'ativo493@test.local');

select pg_temp.como((select usuario_ativo_id from ids),
  $$ select public.criar_conta('contratante','Contratante 493','+5561911114932','1985-01-01','2026-09-22') $$);

-- 1. criarConta: 422 campo_obrigatorio (nome nulo)
select throws_ok(
  pg_temp.por((select usuario_novo_id from ids),
    $$ select public.criar_conta('profissional', null, '+5561999990001', '1990-01-01', '1.0') $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'nome'),
  '1. criarConta com nome nulo recusa 422 campo_obrigatorio'
);

-- 2. registrarEvento: 422 campo_obrigatorio (evento nulo)
select throws_ok(
  pg_temp.por((select usuario_ativo_id from ids),
    $$ select public.registrar_evento(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'evento'),
  '2. registrarEvento com evento nulo recusa 422 campo_obrigatorio'
);

-- 3. escolherCandidato: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.escolher_candidato('c4930000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '3. escolherCandidato sem token recusa 401 nao_autenticado'
);

-- 4. minhasCandidaturas: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.minhas_candidaturas() $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '4. minhasCandidaturas sem token recusa 401 nao_autenticado'
);

-- 5. vagasAbertas: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.vagas_abertas() $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '5. vagasAbertas sem token recusa 401 nao_autenticado'
);

-- 6. detalheVaga: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.detalhe_vaga('c4930000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '6. detalheVaga sem token recusa 401 nao_autenticado'
);

-- 7. republicarVaga: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.republicar_vaga('c4930000-0000-4000-8000-000000000001'::uuid, now(), now(), gen_random_uuid()) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '7. republicarVaga sem token recusa 401 nao_autenticado'
);

-- 8. meusTurnos: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.meus_turnos() $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '8. meusTurnos sem token recusa 401 nao_autenticado'
);

-- 9. contatoDoTurno: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.contato_do_turno('c4930000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '9. contatoDoTurno sem token recusa 401 nao_autenticado'
);

-- 10. avisarACaminho: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.avisar_a_caminho('c4930000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '10. avisarACaminho sem token recusa 401 nao_autenticado'
);

-- 11. painelEstabelecimento: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.painel_estabelecimento('c4930000-0000-4000-8000-000000000001'::uuid, now(), now()) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '11. painelEstabelecimento sem token recusa 401 nao_autenticado'
);

-- 12. meusEstabelecimentos: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.meus_estabelecimentos() $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '12. meusEstabelecimentos sem token recusa 401 nao_autenticado'
);

-- 13. meuEstabelecimento: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.meu_estabelecimento('c4930000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '13. meuEstabelecimento sem token recusa 401 nao_autenticado'
);

-- 14. equipeDeConfianca: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.equipe_de_confianca('c4930000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '14. equipeDeConfianca sem token recusa 401 nao_autenticado'
);

-- 15. situacaoDaConta: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.situacao_da_conta() $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '15. situacaoDaConta sem token recusa 401 nao_autenticado'
);

rollback;
