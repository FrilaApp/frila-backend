-- 734_rpc_leitura_sigilo_mutantes.sql
--
-- Cobertura profunda e camada de mutação executada para as RPCs de LEITURA
-- que operam com RLS-bypass (SECURITY DEFINER):
--   * public.contato_do_turno(turno_id uuid)
--   * public.perfil_publico(id uuid)
--   * cruzamento com public.candidatos_da_vaga(vaga_id uuid)
--
-- Regras de Negócio e Segurança Exercitadas:
--   1. Catálogo e Privilégios:
--      - Ambas são SECURITY DEFINER com search_path="" estrito.
--      - EXECUTE revogado de anon e concedido a authenticated.
--   2. Sigilo Absoluto entre Concorrentes (RN10, RNF08, RF11):
--      - contato_do_turno: exclusivo entre o profissional escalado e os membros da casa.
--        Concorrentes ou terceiros recebem estritamente 404 nao_encontrado (sem vazar a existência).
--      - candidatos_da_vaga: perfil profissional chamando recebe 422 perfil_incompativel.
--   3. Borda Temporal Estrita de 7 Dias Pós-Fim do Turno (RN10, LGPD):
--      - A fim_em + 7 dias exatos (22:00:00 > 22:00:00 é falso): contato AUTORIZADO.
--      - A fim_em + 7 dias e 1 segundo (22:00:01 > 22:00:00 é true): recusa com 403 contato_expirado.
--   4. Bloqueio Mútuo Bidirecional (RF26, RN10):
--      - contato_do_turno: bloqueio entre o profissional e o estabelecimento responde 404 para ambos.
--      - perfil_publico: bloqueio entre quem chama e o perfil em ambos os sentidos responde 404.
--      - perfil_publico: bloqueio entre o profissional e qualquer membro do estabelecimento responde 404.
--      - perfil_publico: bloqueio com o estabelecimento responde 404.
--   5. Sigilo de Dados Confidenciais em Perfil Público (RN10, LGPD):
--      - perfil_publico nunca vaza telefone, email, documento, nascimento ou ponto_base.
--   6. Estado da Posição em contato_do_turno:
--      - Apenas posições confirmadas ou cumpridas têm base contratual para contato;
--        posição cancelada responde 404 nao_encontrado.
--   7. 5 Provas Reais de Mutação Dinâmica com Restauração Canônica Formal:
--      - Mutante C1: Omissão da trava de sigilo de concorrentes em contato_do_turno.
--      - Mutante C2: Relaxamento da borda temporal de 7 para 8 dias em contato_do_turno.
--      - Mutante C3: Omissão do bloqueio mútuo em contato_do_turno.
--      - Mutante P1: Omissão do sentido inverso de bloqueio em perfil_publico.
--      - Mutante P2: Omissão do bloqueio de estabelecimento em perfil_publico.
--      - Restauração canônica formal de cada função com is(pg_get_functiondef, def_orig).
--
-- Prefixo de IDs: c7320000-0000-4000-8000-0000000000xx.
-- Datas determinísticas com frila.agora congelado e rollback limpo.

begin;
select plan(31);

-- Snapshot inicial das definições canônicas originais antes de qualquer mutação
create temp table _def_orig_contato as
select pg_get_functiondef('public.contato_do_turno(uuid)'::regprocedure) as def;

create temp table _def_orig_perfil as
select pg_get_functiondef('public.perfil_publico(uuid)'::regprocedure) as def;

-- Ambiente de teste e relógio congelado
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agendador_secret = 'teste-segredo-732';
select set_config('frila.agora', '2026-11-20 18:00:00+00', true);

-- ── 1. Auxiliares ──────────────────────────────────────────────────────────────

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, '2026-10-01 10:00:00+00', '{"provider":"email"}'::jsonb, '{}'::jsonb,
          '2026-10-01 10:00:00+00', '2026-10-01 10:00:00+00', false, false)
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

-- ── 2. Catálogo e Privilégios ──────────────────────────────────────────────────

select has_function('public', 'contato_do_turno', array['uuid'],
  'funcao public.contato_do_turno(uuid) existe no catalogo');

select is(
  (select prosecdef and proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'contato_do_turno'
      and p.proargtypes = 'uuid'::regtype::oid::text::oidvector),
  true,
  'contato_do_turno e SECURITY DEFINER com search_path="" estrito'
);

select ok(
  not has_function_privilege('anon', 'public.contato_do_turno(uuid)', 'EXECUTE'),
  'papel anon nao tem privilegio de EXECUTE em contato_do_turno'
);

select ok(
  has_function_privilege('authenticated', 'public.contato_do_turno(uuid)', 'EXECUTE'),
  'papel authenticated tem privilegio de EXECUTE em contato_do_turno'
);

select has_function('public', 'perfil_publico', array['uuid'],
  'funcao public.perfil_publico(uuid) existe no catalogo');

select is(
  (select prosecdef and proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'perfil_publico'
      and p.proargtypes = 'uuid'::regtype::oid::text::oidvector),
  true,
  'perfil_publico e SECURITY DEFINER com search_path="" estrito'
);

select ok(
  not has_function_privilege('anon', 'public.perfil_publico(uuid)', 'EXECUTE'),
  'papel anon nao tem privilegio de EXECUTE em perfil_publico'
);

select ok(
  has_function_privilege('authenticated', 'public.perfil_publico(uuid)', 'EXECUTE'),
  'papel authenticated tem privilegio de EXECUTE em perfil_publico'
);

-- ── 3. Fixtures e Cenário ──────────────────────────────────────────────────────

select pg_temp.autenticar('c7320000-0000-4000-8000-000000000001', 'dono@c732.test');
select pg_temp.autenticar('c7320000-0000-4000-8000-000000000002', 'operador@c732.test');
select pg_temp.autenticar('c7320000-0000-4000-8000-000000000003', 'alheio@c732.test');
select pg_temp.autenticar('c7320000-0000-4000-8000-000000000011', 'pedro@c732.test');
select pg_temp.autenticar('c7320000-0000-4000-8000-000000000012', 'carlos@c732.test');
select pg_temp.autenticar('c7320000-0000-4000-8000-000000000013', 'bruno@c732.test');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('c7320000-0000-4000-8000-000000000001', 'contratante',  'Dono Bar A',    '+5561973200001', 'dono@c732.test',     '1980-01-01', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7320000-0000-4000-8000-000000000002', 'contratante',  'Operador Bar A','+5561973200002', 'operador@c732.test', '1985-05-15', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7320000-0000-4000-8000-000000000003', 'contratante',  'Dono Bar B',    '+5561973200003', 'alheio@c732.test',   '1975-08-20', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7320000-0000-4000-8000-000000000011', 'profissional', 'Pedro Garçom',  '+5561973200011', 'pedro@c732.test',    '1995-03-10', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7320000-0000-4000-8000-000000000012', 'profissional', 'Carlos Garçom', '+5561973200012', 'carlos@c732.test',   '1996-07-12', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7320000-0000-4000-8000-000000000013', 'profissional', 'Bruno Garçom',  '+5561973200013', 'bruno@c732.test',    '1994-11-25', '2026-09-22', '2026-10-01 10:00:00+00');

-- Perfis Profissionais:
insert into public.profissional (id, usuario_id, ponto_base) values
  ('c7320000-0000-4000-8000-000000000021', 'c7320000-0000-4000-8000-000000000011', 'POINT(-47.88 -15.79)'::extensions.geography),
  ('c7320000-0000-4000-8000-000000000022', 'c7320000-0000-4000-8000-000000000012', 'POINT(-47.89 -15.80)'::extensions.geography),
  ('c7320000-0000-4000-8000-000000000023', 'c7320000-0000-4000-8000-000000000013', 'POINT(-47.87 -15.78)'::extensions.geography);

-- Estabelecimentos:
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('c7320000-0000-4000-8000-000000000031', 'Bar A Central', '73200000000180', 'food_service', 'CLN 402 Bloco A', 'POINT(-47.8840 -15.7960)'::extensions.geography),
  ('c7320000-0000-4000-8000-000000000032', 'Bar B Outro',   '73200000000109', 'food_service', 'CLS 204 Bloco B', 'POINT(-47.8880 -15.7990)'::extensions.geography);

-- Membros dos Estabelecimentos:
insert into public.membro_estabelecimento (id, estabelecimento_id, usuario_id, papel) values
  ('c7320000-0000-4000-8000-000000000040', 'c7320000-0000-4000-8000-000000000031', 'c7320000-0000-4000-8000-000000000001', 'administrador'),
  ('c7320000-0000-4000-8000-000000000041', 'c7320000-0000-4000-8000-000000000031', 'c7320000-0000-4000-8000-000000000002', 'operador'),
  ('c7320000-0000-4000-8000-000000000042', 'c7320000-0000-4000-8000-000000000032', 'c7320000-0000-4000-8000-000000000003', 'administrador');

-- Funções profissionais:
insert into public.profissional_funcao (profissional_id, funcao_id) values
  ('c7320000-0000-4000-8000-000000000021', (select id from public.funcao where ativo is true limit 1)),
  ('c7320000-0000-4000-8000-000000000022', (select id from public.funcao where ativo is true limit 1)),
  ('c7320000-0000-4000-8000-000000000023', (select id from public.funcao where ativo is true limit 1));

-- Vagas:
-- Vaga 1 do Bar A: Turno de Pedro (18h..22h em 2026-11-20)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7320000-0000-4000-8000-000000000061',
  'c7320000-0000-4000-8000-000000000031',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-20 18:00:00+00', '2026-11-20 22:00:00+00', 'CLN 402 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Dono Bar A', 'urgencia', 'preenchida',
  'c7320000-0000-4000-8000-000000000961'::uuid,
  'c7320000-0000-4000-8000-000000000001'::uuid,
  '2026-11-19 10:00:00+00'
);

-- Posição 1 confirmada para Pedro:
insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7320000-0000-4000-8000-000000000071', 'c7320000-0000-4000-8000-000000000061',
   '2026-11-20 18:00:00+00', '2026-11-20 22:00:00+00', 'confirmada',
   'c7320000-0000-4000-8000-000000000021', '2026-11-19 12:00:00+00');

-- Turno 1 vinculado:
insert into public.turno (id, posicao_id, valor_acordado_centavos) values
  ('c7320000-0000-4000-8000-000000000081', 'c7320000-0000-4000-8000-000000000071', 18000);

-- Vaga 2 do Bar A: Turno com Bruno (para testes de Bloqueio Mútuo)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7320000-0000-4000-8000-000000000062',
  'c7320000-0000-4000-8000-000000000031',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-20 18:00:00+00', '2026-11-20 22:00:00+00', 'CLN 402 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Dono Bar A', 'urgencia', 'preenchida',
  'c7320000-0000-4000-8000-000000000962'::uuid,
  'c7320000-0000-4000-8000-000000000001'::uuid,
  '2026-11-19 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7320000-0000-4000-8000-000000000072', 'c7320000-0000-4000-8000-000000000062',
   '2026-11-20 18:00:00+00', '2026-11-20 22:00:00+00', 'confirmada',
   'c7320000-0000-4000-8000-000000000023', '2026-11-19 12:00:00+00');

insert into public.turno (id, posicao_id, valor_acordado_centavos) values
  ('c7320000-0000-4000-8000-000000000082', 'c7320000-0000-4000-8000-000000000072', 18000);

-- Vaga 3: Turno com Posição Cancelada
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7320000-0000-4000-8000-000000000063',
  'c7320000-0000-4000-8000-000000000031',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-20 18:00:00+00', '2026-11-20 22:00:00+00', 'CLN 402 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Dono Bar A', 'urgencia', 'publicada',
  'c7320000-0000-4000-8000-000000000963'::uuid,
  'c7320000-0000-4000-8000-000000000001'::uuid,
  '2026-11-19 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, falta) values
  ('c7320000-0000-4000-8000-000000000073', 'c7320000-0000-4000-8000-000000000063',
   '2026-11-20 18:00:00+00', '2026-11-20 22:00:00+00', 'cancelada',
   'c7320000-0000-4000-8000-000000000021', false);

insert into public.turno (id, posicao_id, valor_acordado_centavos) values
  ('c7320000-0000-4000-8000-000000000083', 'c7320000-0000-4000-8000-000000000073', 18000);

-- Bloqueio mútuo entre Dono Bar A (0001) e Bruno Garçom (0013):
insert into public.bloqueio (id, autor_id, bloqueado_id) values
  ('c7320000-0000-4000-8000-000000000091', 'c7320000-0000-4000-8000-000000000001', 'c7320000-0000-4000-8000-000000000013');

-- ── 4. Leitura Canônica e Sigilo entre Concorrentes em contato_do_turno ─────────

-- 4.1 Dono do bar lê contato do profissional titular Pedro
select is(
  (pg_temp.como('c7320000-0000-4000-8000-000000000001',
    $$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000081'::uuid) $$))->>'nome',
  'Pedro Garçom',
  'dono da casa le contato do profissional titular com sucesso (nome e telefone)'
);

-- 4.2 Operador membro do bar lê o mesmo contato com sucesso
select is(
  (pg_temp.como('c7320000-0000-4000-8000-000000000002',
    $$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000081'::uuid) $$))->>'telefone',
  '+5561973200011',
  'operador membro da casa le o mesmo contato do profissional com sucesso'
);

-- 4.3 Profissional titular Pedro lê contato do estabelecimento
select is(
  (pg_temp.como('c7320000-0000-4000-8000-000000000011',
    $$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000081'::uuid) $$))->>'nome',
  'Bar A Central',
  'profissional titular le contato do estabelecimento com sucesso'
);

-- 4.4 Concorrente Carlos (outro garçom) tenta ler contato do turno de Pedro
select throws_ok(
  $$ select pg_temp.como('c7320000-0000-4000-8000-000000000012',
       $x$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000081'::uuid) $x$) $$,
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'sigilo entre concorrentes: garcom concorrente recebe 404 ao tentar ler turno alheio'
);

-- 4.5 Terceiro alheio (Dono do Bar B) tenta ler contato do turno do Bar A
select throws_ok(
  $$ select pg_temp.como('c7320000-0000-4000-8000-000000000003',
       $x$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000081'::uuid) $x$) $$,
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'sigilo societario: contratante de outro estabelecimento recebe 404'
);

-- ── 5. Borda Temporal Estrita de 7 Dias Pós-Fim (RN10) ─────────────────────────
-- Fim do turno é 2026-11-20 22:00:00+00.
-- Fim + 7 dias = 2026-11-27 22:00:00+00.

-- 5.1 No instante exato de 7 dias pós-fim (v_agora > fim_em + 7d é falso): autorizado!
select set_config('frila.agora', '2026-11-27 22:00:00+00', true);

select is(
  (pg_temp.como('c7320000-0000-4000-8000-000000000001',
    $$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000081'::uuid) $$))->>'telefone',
  '+5561973200011',
  'RN10 borda exata: a 7 dias exatos (22:00:00 > 22:00:00 e false), contato e autorizado'
);

-- 5.2 A 7 dias e 1 segundo pós-fim (v_agora > fim_em + 7d é true): 403 contato_expirado!
select set_config('frila.agora', '2026-11-27 22:00:01+00', true);

select throws_ok(
  $$ select pg_temp.como('c7320000-0000-4000-8000-000000000001',
       $x$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000081'::uuid) $x$) $$,
  'PGRST',
  pg_temp.erro('contato_expirado'),
  'RN10 borda exata +1s: a 7 dias e 1 segundo pós-fim (> e true), recusa com 403 contato_expirado'
);

-- Retornar relógio para dentro do prazo
select set_config('frila.agora', '2026-11-20 20:00:00+00', true);

-- ── 6. Bloqueio Mútuo e Posição Não Confirmada em contato_do_turno ──────────────

-- 6.1 Bruno tem bloqueio mútuo com Dono Bar A: Dono chamando recebe 404
select throws_ok(
  $$ select pg_temp.como('c7320000-0000-4000-8000-000000000001',
       $x$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000082'::uuid) $x$) $$,
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'RF26 bloqueio mutuo: contratante com profissional bloqueado recebe 404'
);

-- 6.2 Bruno chamando turno do Bar A recebe 404
select throws_ok(
  $$ select pg_temp.como('c7320000-0000-4000-8000-000000000013',
       $x$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000082'::uuid) $x$) $$,
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'RF26 bloqueio mutuo: profissional bloqueado recebe 404 ao consultar turno'
);

-- 6.3 Posição cancelada não concede contato (sem base contratual)
select throws_ok(
  $$ select pg_temp.como('c7320000-0000-4000-8000-000000000001',
       $x$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000083'::uuid) $x$) $$,
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'base contratual: turno em posicao cancelada recusa contato com 404'
);

-- ── 7. Provas de Mutação Dinâmica em contato_do_turno ──────────────────────────

-- Mutante C1: Omissão da trava de sigilo contra concorrentes
-- Sob o mutante, concorrente Carlos passaria a ler o contato telefônico do estabelecimento!
do $$
begin
  execute replace(
    pg_get_functiondef('public.contato_do_turno(uuid)'::regprocedure),
    'if not v_sou_prof and not privado.eh_membro(v_estab) then',
    'if false and not v_sou_prof and not privado.eh_membro(v_estab) then'
  );
end $$;

select is(
  (pg_temp.como('c7320000-0000-4000-8000-000000000012',
    $$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000081'::uuid) $$))->>'telefone',
  '+5561973200011',
  'mutante C1 (sem trava concorrente): concorrente leria telefone do titular; prova discriminacao da trava'
);

-- Restauração dinâmica canônica C1
do $$
begin
  execute replace(
    pg_get_functiondef('public.contato_do_turno(uuid)'::regprocedure),
    'if false and not v_sou_prof and not privado.eh_membro(v_estab) then',
    'if not v_sou_prof and not privado.eh_membro(v_estab) then'
  );
end $$;

-- Mutante C2: Relaxamento da borda de 7 dias para 8 dias
-- Sob o mutante, a chamada no instante 7d + 1s passaria sem 403!
do $$
begin
  execute replace(
    pg_get_functiondef('public.contato_do_turno(uuid)'::regprocedure),
    '+ interval ''7 days''',
    '+ interval ''8 days'''
  );
end $$;

select set_config('frila.agora', '2026-11-27 22:00:01+00', true);

select is(
  (pg_temp.como('c7320000-0000-4000-8000-000000000001',
    $$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000081'::uuid) $$))->>'telefone',
  '+5561973200011',
  'mutante C2 (borda 8 dias): chamada a 7d 1s passaria sem 403; prova discriminacao estrita de 7 dias'
);

-- Restauração dinâmica canônica C2
do $$
begin
  execute replace(
    pg_get_functiondef('public.contato_do_turno(uuid)'::regprocedure),
    '+ interval ''8 days''',
    '+ interval ''7 days'''
  );
end $$;

select set_config('frila.agora', '2026-11-20 20:00:00+00', true);

-- Mutante C3: Omissão da verificação de bloqueio mútuo
-- Sob o mutante, Bruno bloqueado passaria a ver o contato do Bar A!
do $$
begin
  execute replace(
    pg_get_functiondef('public.contato_do_turno(uuid)'::regprocedure),
    'if privado.bloqueado_com_estabelecimento(case when v_sou_prof then v_uid else v_dono end,',
    'if false and privado.bloqueado_com_estabelecimento(case when v_sou_prof then v_uid else v_dono end,'
  );
end $$;

select is(
  (pg_temp.como('c7320000-0000-4000-8000-000000000013',
    $$ select public.contato_do_turno('c7320000-0000-4000-8000-000000000082'::uuid) $$))->>'telefone',
  '+5561973200001',
  'mutante C3 (sem bloqueio): profissional bloqueado leria contato; prova discriminacao de RF26'
);

-- Restauração dinâmica canônica C3
do $$
begin
  execute replace(
    pg_get_functiondef('public.contato_do_turno(uuid)'::regprocedure),
    'if false and privado.bloqueado_com_estabelecimento(case when v_sou_prof then v_uid else v_dono end,',
    'if privado.bloqueado_com_estabelecimento(case when v_sou_prof then v_uid else v_dono end,'
  );
end $$;

-- Validação formal de restauração canônica de contato_do_turno
select is(
  pg_get_functiondef('public.contato_do_turno(uuid)'::regprocedure),
  (select def from _def_orig_contato),
  'função contato_do_turno restaurada idêntica à definição original'
);

-- ── 8. Sigilo e Bloqueio Mútuo em perfil_publico ────────────────────────────────

-- 8.1 Leitura canônica do perfil profissional de Pedro
select is(
  (pg_temp.como('c7320000-0000-4000-8000-000000000001',
    $$ select public.perfil_publico('c7320000-0000-4000-8000-000000000021'::uuid) $$))->>'nome',
  'Pedro Garçom',
  'perfil_publico: leitura canonica do profissional devolve nome esperado'
);

-- 8.2 Prova de ausência de dados privados confidenciais (RN10)
select is(
  (select count(*)::int
     from jsonb_object_keys(
       pg_temp.como('c7320000-0000-4000-8000-000000000001',
         $$ select public.perfil_publico('c7320000-0000-4000-8000-000000000021'::uuid) $$)
     ) as k
    where k in ('telefone', 'email', 'documento', 'nascimento', 'ponto_base')),
  0,
  'RN10 sigilo: perfil_publico nao vaza telefone, email, documento, nascimento ou ponto_base'
);

-- 8.3 Bloqueio mútuo: Dono Bar A consultando perfil de Bruno Garçom recebe 404
select throws_ok(
  $$ select pg_temp.como('c7320000-0000-4000-8000-000000000001',
       $x$ select public.perfil_publico('c7320000-0000-4000-8000-000000000023'::uuid) $x$) $$,
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'RF26 perfil_publico: contratante que bloqueou profissional recebe 404'
);

-- 8.4 Bloqueio mútuo sentido inverso: Bruno Garçom (bloqueado) consultando perfil do Bar A Central
select throws_ok(
  $$ select pg_temp.como('c7320000-0000-4000-8000-000000000013',
       $x$ select public.perfil_publico('c7320000-0000-4000-8000-000000000031'::uuid) $x$) $$,
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'RF26 perfil_publico: profissional bloqueado recebe 404 ao consultar estabelecimento'
);

-- 8.5 Bloqueio com membro: Operador do Bar A consultando perfil de Bruno Garçom
select throws_ok(
  $$ select pg_temp.como('c7320000-0000-4000-8000-000000000002',
       $x$ select public.perfil_publico('c7320000-0000-4000-8000-000000000023'::uuid) $x$) $$,
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'RF26 perfil_publico: membro do estabelecimento recebe 404 ao consultar profissional bloqueado com a casa'
);

-- ── 9. Provas de Mutação Dinâmica em perfil_publico ────────────────────────────

-- Pedro bloqueia Carlos:
insert into public.bloqueio (id, autor_id, bloqueado_id) values
  ('c7320000-0000-4000-8000-000000000092', 'c7320000-0000-4000-8000-000000000011', 'c7320000-0000-4000-8000-000000000012');

-- Mutante P1: Omissão do sentido inverso de bloqueio
-- Sob o mutante, Carlos (bloqueado) conseguiria ver o perfil de Pedro (autor)!
do $$
begin
  execute replace(
    pg_get_functiondef('public.perfil_publico(uuid)'::regprocedure),
    'or (b.autor_id = v_prof_user and b.bloqueado_id = v_uid)',
    'or (false and b.autor_id = v_prof_user and b.bloqueado_id = v_uid)'
  );
end $$;

-- Sob o mutante P1, Carlos (bloqueado) chamando o perfil de Pedro (autor) passaria sem 404!
select is(
  (pg_temp.como('c7320000-0000-4000-8000-000000000012',
    $$ select public.perfil_publico('c7320000-0000-4000-8000-000000000021'::uuid) $$))->>'nome',
  'Pedro Garçom',
  'mutante P1 (sem sentido inverso): bloqueado passaria a ver perfil de quem o bloqueou; discriminado'
);

-- Restauração dinâmica canônica P1
do $$
begin
  execute replace(
    pg_get_functiondef('public.perfil_publico(uuid)'::regprocedure),
    'or (false and b.autor_id = v_prof_user and b.bloqueado_id = v_uid)',
    'or (b.autor_id = v_prof_user and b.bloqueado_id = v_uid)'
  );
end $$;

-- Mutante P2: Omissão do bloqueio com estabelecimento
-- Sob o mutante, Bruno bloqueado passaria a ver o perfil do Bar A Central!
do $$
begin
  execute replace(
    pg_get_functiondef('public.perfil_publico(uuid)'::regprocedure),
    'if privado.bloqueado_com_estabelecimento(v_uid, perfil_publico.id) then',
    'if false and privado.bloqueado_com_estabelecimento(v_uid, perfil_publico.id) then'
  );
end $$;

select is(
  (pg_temp.como('c7320000-0000-4000-8000-000000000013',
    $$ select public.perfil_publico('c7320000-0000-4000-8000-000000000031'::uuid) $$))->>'nome',
  'Bar A Central',
  'mutante P2 (sem bloqueio estab): bloqueado passaria a ver perfil do bar; discriminado'
);

-- Restauração dinâmica canônica P2
do $$
begin
  execute replace(
    pg_get_functiondef('public.perfil_publico(uuid)'::regprocedure),
    'if false and privado.bloqueado_com_estabelecimento(v_uid, perfil_publico.id) then',
    'if privado.bloqueado_com_estabelecimento(v_uid, perfil_publico.id) then'
  );
end $$;

-- Validação formal de restauração canônica de perfil_publico
select is(
  pg_get_functiondef('public.perfil_publico(uuid)'::regprocedure),
  (select def from _def_orig_perfil),
  'função perfil_publico restaurada idêntica à definição original'
);

-- ── 10. Cruzamento de Sigilo em candidatos_da_vaga ─────────────────────────────

-- Concorrente Carlos (perfil profissional) tenta bisbilhotar os candidatos da vaga 1
select throws_ok(
  $$ select pg_temp.como('c7320000-0000-4000-8000-000000000012',
       $x$ select public.candidatos_da_vaga('c7320000-0000-4000-8000-000000000061'::uuid) $x$) $$,
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  'sigilo concorrencial em candidatos_da_vaga: profissional chamando recebe 422 perfil_incompativel'
);

select * from finish();
rollback;
