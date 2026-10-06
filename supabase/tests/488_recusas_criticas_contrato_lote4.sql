-- 15 recusas criticas do contrato lote 4 (06/10/2026).
--
-- Cobre os 15 pares adicionais de recusa por risco do levantamento frente-0.2.37.md:
-- 1.  criarPerfilProfissional (403 sem_permissao)
-- 2.  atualizarPerfilProfissional (403 sem_permissao)
-- 3.  pedirRevisaoDespacho (403 sem_permissao)
-- 4.  meuEstabelecimento (403 sem_permissao)
-- 5.  equipeDeConfianca (403 sem_permissao)
-- 6.  vagasAbertas (403 sem_permissao)
-- 7.  retirarCandidatura (403 sem_permissao)
-- 8.  minhasCandidaturas (403 sem_permissao)
-- 9.  meusTurnos (403 sem_permissao)
-- 10. painelEstabelecimento (403 sem_permissao)
-- 11. minhaConta (404 nao_encontrado)
-- 12. meuPerfilProfissional (404 nao_encontrado)
-- 13. atualizarPerfilProfissional (404 nao_encontrado)
-- 14. criarConta (409 conta_existente)
-- 15. criarPerfilProfissional (409 perfil_ja_existe)
--
-- Ids proprios comecando em `c4880000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(15);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2027-05-01 12:00:00+00', true);

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
  'c4880000-0000-4000-8000-000000000001'::uuid as contratante_dono,
  'c4880000-0000-4000-8000-000000000002'::uuid as contratante_outro,
  'c4880000-0000-4000-8000-000000000003'::uuid as profissional_ativo,
  'c4880000-0000-4000-8000-000000000004'::uuid as profissional_suspenso,
  'c4880000-0000-4000-8000-000000000005'::uuid as usuario_sem_perfil,
  'c4880000-0000-4000-8000-000000000006'::uuid as usuario_anonimo;

select pg_temp.autenticar((select contratante_dono from ids), 'dono@frila.test');
select pg_temp.autenticar((select contratante_outro from ids), 'outro@frila.test');
select pg_temp.autenticar((select profissional_ativo from ids), 'ativo@frila.test');
select pg_temp.autenticar((select profissional_suspenso from ids), 'suspenso@frila.test');
select pg_temp.autenticar((select usuario_sem_perfil from ids), 'semperfil@frila.test');
select pg_temp.autenticar((select usuario_anonimo from ids), 'semcadastro@frila.test');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values
  ((select contratante_dono from ids), 'contratante', 'Contratante Dono', '+5561999990001', 'dono@frila.test', '1985-01-01', '1.0', now(), 'ativa'),
  ((select contratante_outro from ids), 'contratante', 'Contratante Outro', '+5561999990002', 'outro@frila.test', '1988-02-02', '1.0', now(), 'ativa'),
  ((select profissional_ativo from ids), 'profissional', 'Profissional Ativo', '+5561999990003', 'ativo@frila.test', '1995-03-03', '1.0', now(), 'ativa'),
  ((select profissional_suspenso from ids), 'profissional', 'Profissional Suspenso', '+5561999990004', 'suspenso@frila.test', '1996-04-04', '1.0', now(), 'suspensa'),
  ((select usuario_sem_perfil from ids), 'profissional', 'Profissional Sem Perfil', '+5561999990005', 'semperfil@frila.test', '1997-05-05', '1.0', now(), 'ativa');

create temp table func as select id from public.funcao where nome = 'garçom' limit 1;

insert into public.profissional (usuario_id)
values ((select profissional_ativo from ids));

create temp table prof_ativo as select id from public.profissional where usuario_id = (select profissional_ativo from ids);
perform privado.gravar_funcoes((select id from prof_ativo), array[(select id from func)]);

-- Estabelecimento da casa 1 gerenciada por contratante_dono
create temp table casa1 as
select public.cadastrar_estabelecimento(
  'Restaurante Lote 4',
  'bar_restaurante'::public.tipo_estabelecimento,
  '12345678000195',
  '+5561999990001',
  'Asa Sul, Bloco A',
  -15.7942,
  -47.8822,
  'Plano Piloto'
) as id;

-- 1. criarPerfilProfissional: 403 sem_permissao (profissional suspenso tentando cadastrar perfil)
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids), format(
    $$ select public.criar_perfil_profissional(array[%L::uuid], null, null) $$,
    (select id from func))),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '1. criarPerfilProfissional: 403 sem_permissao quando conta esta suspensa'
);

-- 2. atualizarPerfilProfissional: 403 sem_permissao (profissional suspenso tentando atualizar perfil)
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids), format(
    $$ select public.atualizar_perfil_profissional(array[%L::uuid], null, null) $$,
    (select id from func))),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '2. atualizarPerfilProfissional: 403 sem_permissao quando conta esta suspensa'
);

-- 3. pedirRevisaoDespacho: 403 sem_permissao (profissional suspenso tentando pedir revisao)
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids),
    $$ select public.pedir_revisao_despacho('Relato valido com mais de dez caracteres.') $$),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '3. pedirRevisaoDespacho: 403 sem_permissao quando conta esta suspensa'
);

-- 4. meuEstabelecimento: 403 sem_permissao (chamador nao e membro do estabelecimento)
select throws_ok(
  pg_temp.por((select contratante_outro from ids), format(
    $$ select public.meu_estabelecimento(%L::uuid) $$,
    (select (id->>'id')::uuid from casa1))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '4. meuEstabelecimento: 403 sem_permissao quando chamador nao e membro'
);

-- 5. equipeDeConfianca: 403 sem_permissao (chamador nao e membro do estabelecimento)
select throws_ok(
  pg_temp.por((select contratante_outro from ids), format(
    $$ select public.equipe_de_confianca(%L::uuid) $$,
    (select (id->>'id')::uuid from casa1))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '5. equipeDeConfianca: 403 sem_permissao quando chamador nao e membro'
);

-- 6. vagasAbertas: 403 sem_permissao (profissional suspenso tentando consultar vagas)
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids),
    $$ select public.vagas_abertas() $$),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '6. vagasAbertas: 403 sem_permissao quando conta esta suspensa'
);

-- 7. retirarCandidatura: 403 sem_permissao (profissional suspenso tentando retirar candidatura)
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids),
    $$ select public.retirar_candidatura('c4880000-0000-4000-8000-000000000099'::uuid) $$),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '7. retirarCandidatura: 403 sem_permissao quando conta esta suspensa'
);

-- 8. minhasCandidaturas: 403 sem_permissao (profissional suspenso tentando listar candidaturas)
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids),
    $$ select public.minhas_candidaturas() $$),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '8. minhasCandidaturas: 403 sem_permissao quando conta esta suspensa'
);

-- 9. meusTurnos: 403 sem_permissao (chamador nao e membro do estabelecimento passado)
select throws_ok(
  pg_temp.por((select contratante_outro from ids), format(
    $$ select public.meus_turnos(null, null, %L::uuid) $$,
    (select (id->>'id')::uuid from casa1))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '9. meusTurnos: 403 sem_permissao quando chamador nao e membro do estabelecimento'
);

-- 10. painelEstabelecimento: 403 sem_permissao (chamador nao e membro do estabelecimento)
select throws_ok(
  pg_temp.por((select contratante_outro from ids), format(
    $$ select public.painel_estabelecimento(%L::uuid, '2027-05-01 00:00:00+00'::timestamptz, '2027-05-01 23:59:59+00'::timestamptz) $$,
    (select (id->>'id')::uuid from casa1))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '10. painelEstabelecimento: 403 sem_permissao quando chamador nao e membro'
);

-- 11. minhaConta: 404 nao_encontrado (usuario autenticado sem linha em usuario)
select throws_ok(
  pg_temp.por((select usuario_anonimo from ids),
    $$ select public.minha_conta() $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '11. minhaConta: 404 nao_encontrado quando usuario nao possui registro cadastrado'
);

-- 12. meuPerfilProfissional: 404 nao_encontrado (contratante sem linha em profissional)
select throws_ok(
  pg_temp.por((select contratante_dono from ids),
    $$ select public.meu_perfil_profissional() $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '12. meuPerfilProfissional: 404 nao_encontrado quando conta nao possui perfil profissional'
);

-- 13. atualizarPerfilProfissional: 404 nao_encontrado (conta profissional sem linha em profissional)
select throws_ok(
  pg_temp.por((select usuario_sem_perfil from ids), format(
    $$ select public.atualizar_perfil_profissional(array[%L::uuid], null, null) $$,
    (select id from func))),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '13. atualizarPerfilProfissional: 404 nao_encontrado quando profissional nao possui perfil criado'
);

-- 14. criarConta: 409 conta_existente (tentativa com perfil divergente de conta ja existente)
select throws_ok(
  pg_temp.por((select contratante_dono from ids),
    $$ select public.criar_conta('profissional', 'Tentativa Divergente', '+5561999990001', '1985-01-01', '1.0') $$),
  'PGRST',
  pg_temp.erro('conta_existente', 'perfil_divergente'),
  '14. criarConta: 409 conta_existente quando perfil diverge da conta ja cadastrada'
);

-- 15. criarPerfilProfissional: 409 perfil_ja_existe (profissional que ja possui perfil cadastrado)
select throws_ok(
  pg_temp.por((select profissional_ativo from ids), format(
    $$ select public.criar_perfil_profissional(array[%L::uuid], null, null) $$,
    (select id from func))),
  'PGRST',
  pg_temp.erro('perfil_ja_existe'),
  '15. criarPerfilProfissional: 409 perfil_ja_existe quando perfil ja foi cadastrado'
);

rollback;
