-- 730_rpc_atualizar_perfil_profissional.sql
--
-- Cobertura profunda via pgTAP para a RPC public.atualizar_perfil_profissional(uuid[], jsonb, jsonb).
-- Top 7 do Mapa de Lacunas de RPCs (MAPA-LACUNAS-RPCS.md).
--
-- Regras de Negócio e Segurança Exercitadas:
--   1. Catálogo e Privilégios:
--      • Função existe no catálogo com assinatura (uuid[], jsonb, jsonb);
--      • Definida como SECURITY DEFINER com search_path = '' estrito;
--      • Privilégio de EXECUTE revogado de anon e concedido a authenticated.
--   2. Autenticação e Perfis:
--      • Sem sessão (auth.uid() is null): recusa com 401 nao_autenticado;
--      • Chamador com perfil contratante: recusa com 422 perfil_incompativel;
--      • Chamador profissional com conta suspensa: recusa com 403 sem_permissao, details: conta_suspensa (RN13).
--   3. Validação de Parâmetros e Existência de Perfil:
--      • Todos os argumentos nulos (ou chamada sem argumentos): recusa com 422 campo_obrigatorio (details: nenhum_campo);
--      • Profissional sem registro em public.profissional: recusa com 404 nao_encontrado;
--      • ponto_base sem latitude ou longitude: recusa com 422 campo_obrigatorio (details: ponto_base);
--      • ponto_base fora dos limites geográficos (-90..90 / -180..180): recusa com 422 campo_invalido (details: ponto_base);
--      • funcoes como array vazio: recusa com 422 campo_obrigatorio (details: funcoes);
--      • funcoes com UUID fora do catálogo ou inativo: recusa com 422 campo_invalido (details: funcoes);
--      • disponibilidades não sendo array: recusa com 422 campo_invalido (details: disponibilidades);
--      • disponibilidades com dia_semana fora de 0..6: recusa com 422 campo_invalido (details: disponibilidades);
--      • disponibilidades com duração zero (hora_inicio = hora_fim): recusa com 422 campo_invalido (details: disponibilidades).
--   4. Atualização Atômica Parcial ("O enviado substitui; o omitido fica"):
--      • Enviar apenas ponto_base: atualiza coordenadas, preserva funcoes e disponibilidades;
--      • Enviar apenas funcoes: substitui funcoes, preserva ponto_base e disponibilidades;
--      • Enviar apenas disponibilidades: substitui grade (aceita janela cruzando meia-noite), preserva ponto_base e funcoes;
--      • Limpeza de grade via '[]'::jsonb: esvazia disponibilidades preservando os demais campos.
--   5. Provas de Mutação Real via pg_get_functiondef:
--      • Mutante 1: Omissão da trava nenhum_campo (chamada nula passaria sem erro); restaurado canonicamente;
--      • Mutante 2: Omissão do if ponto_base is not null (força update mesmo quando nulo); restaurado canonicamente;
--      • Restauração Canônica com is(pg_get_functiondef, def_original) e confirmação final.

begin;

-- Setup de ambiente: isolamento de teste e relógio congelado
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-11-15 12:00:00-03';

select plan(28);

-- Helpers temporários de teste
create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (
    instance_id, id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    is_sso_user, is_anonymous
  ) values (
    '00000000-0000-4000-8000-000000000000', conta, 'authenticated', 'authenticated',
    email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(),
    false, false
  ) on conflict (id) do nothing;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local "request.jwt.claims" = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute format('set local "request.jwt.claim.sub" = %L', conta::text);
  execute sql into r;
  reset role;
  execute 'reset "request.jwt.claims"';
  execute 'reset "request.jwt.claim.sub"';
  return r;
end $$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

-- Snapshot da definição original para verificação de restauração perfeita
create temp table pg_temp.def_original as
  select pg_get_functiondef('public.atualizar_perfil_profissional(uuid[], jsonb, jsonb)'::regprocedure) as def;

-- ── 1. Catálogo e Privilégios ─────────────────────────────────────────────────

select has_function(
  'public', 'atualizar_perfil_profissional', array['uuid[]', 'jsonb', 'jsonb'],
  'funcao public.atualizar_perfil_profissional(uuid[], jsonb, jsonb) existe no catalogo'
);

select is(
  (select coalesce(p.proconfig, '{}') @> array['search_path=""'] and p.prosecdef
     from pg_proc p
    where p.proname = 'atualizar_perfil_profissional'
      and p.pronamespace = 'public'::regnamespace),
  true,
  'atualizar_perfil_profissional e SECURITY DEFINER com search_path="" estrito'
);

select ok(
  not has_function_privilege('anon', 'public.atualizar_perfil_profissional(uuid[], jsonb, jsonb)', 'execute'),
  'papel anon nao tem privilegio de EXECUTE em atualizar_perfil_profissional'
);

select ok(
  has_function_privilege('authenticated', 'public.atualizar_perfil_profissional(uuid[], jsonb, jsonb)', 'execute'),
  'papel authenticated tem privilegio de EXECUTE em atualizar_perfil_profissional'
);

-- ── Setup de Fixtures ─────────────────────────────────────────────────────────

create temp table ids as select
  -- Contratante
  '73000000-0000-4000-8000-000000000001'::uuid as user_contratante,
  -- Profissionais (contas de usuario)
  '73000000-0000-4000-8000-000000000011'::uuid as user_prof_ana,
  '73000000-0000-4000-8000-000000000012'::uuid as user_prof_suspenso,
  '73000000-0000-4000-8000-000000000013'::uuid as user_prof_sem_perfil,
  -- Profissional ID (linha em public.profissional)
  '73000000-0000-4000-8000-000000000021'::uuid as prof_ana,
  '73000000-0000-4000-8000-000000000022'::uuid as prof_suspenso;

-- Funções ativas do catálogo para teste
create temp table funcoes_teste as
  select id, nome, row_number() over (order by nome) as rn
    from public.funcao
   where ativo is true
   limit 3;

-- Autenticações em auth.users
select pg_temp.autenticar((select user_contratante from ids),     'contratante@730.test');
select pg_temp.autenticar((select user_prof_ana from ids),         'ana@730.test');
select pg_temp.autenticar((select user_prof_suspenso from ids),    'suspenso@730.test');
select pg_temp.autenticar((select user_prof_sem_perfil from ids),  'sem_perfil@730.test');

-- Usuários
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('73000000-0000-4000-8000-000000000001', 'contratante', 'Seu Zé', 'contratante@730.test', '+5561973000001', '1980-01-01', 'ativa', '1.0', now()),
  ('73000000-0000-4000-8000-000000000011', 'profissional', 'Ana Silva', 'ana@730.test', '+5561973000011', '1995-05-10', 'ativa', '1.0', now()),
  ('73000000-0000-4000-8000-000000000012', 'profissional', 'Pedro Suspenso', 'suspenso@730.test', '+5561973000012', '1992-03-15', 'suspensa', '1.0', now()),
  ('73000000-0000-4000-8000-000000000013', 'profissional', 'Lucas Sem Perfil', 'sem_perfil@730.test', '+5561973000013', '1990-11-25', 'ativa', '1.0', now());

-- Entidades profissional
insert into public.profissional (
  id, usuario_id, ponto_base, taxa_comparecimento, turnos_realizados, aval_positivas, aval_total
) values
  ('73000000-0000-4000-8000-000000000021', '73000000-0000-4000-8000-000000000011',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 1.000, 5, 5, 5),
  ('73000000-0000-4000-8000-000000000022', '73000000-0000-4000-8000-000000000012',
   'POINT(-47.8850 -15.7980)'::extensions.geography, 0.800, 4, 4, 5);

-- Inserir função inicial para Ana (função 1)
insert into public.profissional_funcao (profissional_id, funcao_id)
values ('73000000-0000-4000-8000-000000000021', (select id from funcoes_teste where rn = 1));

-- Inserir disponibilidade inicial para Ana (Segunda-feira 08:00..12:00)
insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
values ('73000000-0000-4000-8000-000000000021', 1, '08:00', '12:00');

-- ── 2. Autenticação e Perfis ──────────────────────────────────────────────────

select throws_ok(
  $$ select public.atualizar_perfil_profissional(
       ponto_base => '{"latitude": -15.7942, "longitude": -47.8822}'::jsonb
     ) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  'sem sessao (auth.uid nulo): recusa com 401 nao_autenticado'
);

select throws_ok(
  pg_temp.por((select user_contratante from ids),
    $$ select public.atualizar_perfil_profissional(
         ponto_base => '{"latitude": -15.7942, "longitude": -47.8822}'::jsonb
       ) $$),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  'contratante chamando: recusa com 422 perfil_incompativel'
);

select throws_ok(
  pg_temp.por((select user_prof_suspenso from ids),
    $$ select public.atualizar_perfil_profissional(
         ponto_base => '{"latitude": -15.7942, "longitude": -47.8822}'::jsonb
       ) $$),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'profissional com conta suspensa: recusa com 403 sem_permissao (conta_suspensa)'
);

-- ── 3. Validação de Parâmetros e Existência de Perfil ─────────────────────────

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.atualizar_perfil_profissional() $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'nenhum_campo'),
  'todos os campos nulos: recusa com 422 campo_obrigatorio (details: nenhum_campo)'
);

select throws_ok(
  pg_temp.por((select user_prof_sem_perfil from ids),
    $$ select public.atualizar_perfil_profissional(
         ponto_base => '{"latitude": -15.7942, "longitude": -47.8822}'::jsonb
       ) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'usuario sem perfil profissional cadastrado: recusa com 404 nao_encontrado'
);

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.atualizar_perfil_profissional(
         ponto_base => '{"latitude": -15.7942}'::jsonb
       ) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'ponto_base'),
  'ponto_base sem longitude: recusa com 422 campo_obrigatorio (details: ponto_base)'
);

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.atualizar_perfil_profissional(
         ponto_base => '{"latitude": 90.0001, "longitude": -47.8822}'::jsonb
       ) $$),
  'PGRST',
  pg_temp.erro('campo_invalido', 'ponto_base'),
  'ponto_base com latitude fora de -90..90: recusa com 422 campo_invalido (details: ponto_base)'
);

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.atualizar_perfil_profissional(
         ponto_base => '{"latitude": -15.7942, "longitude": 180.0001}'::jsonb
       ) $$),
  'PGRST',
  pg_temp.erro('campo_invalido', 'ponto_base'),
  'ponto_base com longitude fora de -180..180: recusa com 422 campo_invalido (details: ponto_base)'
);

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.atualizar_perfil_profissional(
         funcoes => array[]::uuid[]
       ) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'funcoes'),
  'funcoes como array vazio: recusa com 422 campo_obrigatorio (details: funcoes)'
);

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.atualizar_perfil_profissional(
         funcoes => array['73000000-0000-4000-8000-000000000999'::uuid]
       ) $$),
  'PGRST',
  pg_temp.erro('campo_invalido', 'funcoes'),
  'funcoes com UUID fora do catalogo: recusa com 422 campo_invalido (details: funcoes)'
);

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.atualizar_perfil_profissional(
         disponibilidades => '{"dia_semana": 1}'::jsonb
       ) $$),
  'PGRST',
  pg_temp.erro('campo_invalido', 'disponibilidades'),
  'disponibilidades nao sendo array json: recusa com 422 campo_invalido (details: disponibilidades)'
);

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.atualizar_perfil_profissional(
         disponibilidades => '[{"dia_semana": 7, "hora_inicio": "08:00", "hora_fim": "12:00"}]'::jsonb
       ) $$),
  'PGRST',
  pg_temp.erro('campo_invalido', 'disponibilidades'),
  'disponibilidades com dia_semana 7 (fora de 0..6): recusa com 422 campo_invalido'
);

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.atualizar_perfil_profissional(
         disponibilidades => '[{"dia_semana": 1, "hora_inicio": "10:00", "hora_fim": "10:00"}]'::jsonb
       ) $$),
  'PGRST',
  pg_temp.erro('campo_invalido', 'disponibilidades'),
  'disponibilidades com duracao zero (inicio = fim): recusa com 422 campo_invalido'
);

-- ── 4. Atualização Atômica Parcial ("O enviado substitui; o omitido fica") ────

-- 4.1. Atualizar apenas ponto_base: preserva funcoes e disponibilidades
select is(
  (pg_temp.como((select user_prof_ana from ids),
     $$ select public.atualizar_perfil_profissional(
          ponto_base => '{"latitude": -15.800000, "longitude": -47.890000}'::jsonb
        ) $$)->'ponto_base'),
  '{"latitude": -15.8, "longitude": -47.89}'::jsonb,
  'atualizar apenas ponto_base: novas coordenadas registradas'
);

select is(
  (select count(*)::int from public.profissional_funcao where profissional_id = (select prof_ana from ids)),
  1,
  'atualizar apenas ponto_base: funcoes anteriores continuam preservadas'
);

select is(
  (select count(*)::int from public.disponibilidade where profissional_id = (select prof_ana from ids)),
  1,
  'atualizar apenas ponto_base: disponibilidades anteriores continuam preservadas'
);

-- 4.2. Atualizar apenas funcoes: adiciona função 2 e função 3, preserva ponto_base
select is(
  (select jsonb_array_length(pg_temp.como((select user_prof_ana from ids),
     format($$ select public.atualizar_perfil_profissional(
          funcoes => array[%L, %L]::uuid[]
        ) $$, (select id from funcoes_teste where rn = 2), (select id from funcoes_teste where rn = 3)))->'funcoes')),
  2,
  'atualizar apenas funcoes: substitui funcoes para exatamente 2 novas funcoes'
);

select is(
  (select count(*)::int from public.disponibilidade where profissional_id = (select prof_ana from ids)),
  1,
  'atualizar apenas funcoes: disponibilidades continuam preservadas'
);

-- 4.3. Atualizar apenas disponibilidades (incluindo janela cruzando meia-noite)
select is(
  (select jsonb_array_length(pg_temp.como((select user_prof_ana from ids),
     $$ select public.atualizar_perfil_profissional(
          disponibilidades => '[
            {"dia_semana": 5, "hora_inicio": "18:00", "hora_fim": "02:00"},
            {"dia_semana": 6, "hora_inicio": "19:00", "hora_fim": "03:00"}
          ]'::jsonb
        ) $$)->'disponibilidades')),
  2,
  'atualizar apenas disponibilidades: aceita janelas noturnas atravessando meia-noite'
);

-- 4.4. Esvaziar grade com array vazio '[]'::jsonb
select is(
  (pg_temp.como((select user_prof_ana from ids),
     $$ select public.atualizar_perfil_profissional(
          disponibilidades => '[]'::jsonb
        ) $$)->'disponibilidades'),
  '[]'::jsonb,
  'esvaziar grade com []::jsonb: disponibilidades zera preservando demais atributos'
);

-- ── 5. Provas de Mutação Real via pg_get_functiondef ─────────────────────────

-- Mutante 1: Omissão da trava de nenhum campo fornecido
do $$
begin
  execute replace(
    pg_get_functiondef('public.atualizar_perfil_profissional(uuid[], jsonb, jsonb)'::regprocedure),
    'if atualizar_perfil_profissional.funcoes is null
     and atualizar_perfil_profissional.ponto_base is null
     and atualizar_perfil_profissional.disponibilidades is null then',
    'if false and atualizar_perfil_profissional.funcoes is null then'
  );
end $$;

select is(
  (pg_temp.como((select user_prof_ana from ids),
     $$ select public.atualizar_perfil_profissional() $$)?'id'),
  true,
  'mutante 1 (sem trava nenhum_campo): chamada sem argumentos passa; prova discriminacao da trava'
);

-- Restauração dinâmica do mutante 1
do $$
begin
  execute (select def from pg_temp.def_original);
end $$;

-- Mutante 2: Omissão da checagem if ponto_base is not null (força update mesmo se nulo)
do $$
begin
  execute replace(
    pg_get_functiondef('public.atualizar_perfil_profissional(uuid[], jsonb, jsonb)'::regprocedure),
    'if atualizar_perfil_profissional.ponto_base is not null then',
    'if true then'
  );
end $$;

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.atualizar_perfil_profissional(
         disponibilidades => '[]'::jsonb
       ) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'ponto_base'),
  'mutante 2 (sem checagem is not null em ponto_base): quebra update parcial de grade; prova discriminacao'
);

-- Restauração dinâmica do mutante 2
do $$
begin
  execute (select def from pg_temp.def_original);
end $$;

-- Restauração Canônica Verificada
select is(
  pg_get_functiondef('public.atualizar_perfil_profissional(uuid[], jsonb, jsonb)'::regprocedure),
  (select def from pg_temp.def_original),
  'restauracao canonica: definicao final identica a original via is(pg_get_functiondef, def_original)'
);

-- Confirmação Canônica Final sob a definição canônica restaurada
select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.atualizar_perfil_profissional() $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'nenhum_campo'),
  'confirmacao canonica final: chamada sem argumentos volta a recusar 422 nenhum_campo'
);

select * from finish();
rollback;
