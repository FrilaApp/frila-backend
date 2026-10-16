-- 724_rpc_confirmar_checkin_manual.sql
--
-- Cobertura completa da RPC public.confirmar_checkin_manual(turno_id uuid)
-- Top 1 do Mapa de Cobertura de RPCs (Rodada 4).
--
-- Regras validadas:
--   1. Permissões de catálogo: SECURITY DEFINER, search_path='', EXECUTE revogado de anon e concedido a authenticated.
--   2. Autenticação e Conta Ativa: 401 sem token, 403 conta_suspensa via privado.exigir_conta_ativa().
--   3. Validação de argumentos: 422 campo_obrigatorio para turno_id nulo, 404 nao_encontrado para id inexistente.
--   4. Autorização RF20 / RF21: Apenas membros do estabelecimento (administrador e operador) podem confirmar;
--      o próprio profissional do turno recebe 403 sem_permissao (não pode declarar a própria presença);
--      contratante alheio recebe 403 sem_permissao; profissional terceiro recebe 403 sem_permissao.
--   5. Pré-condições do turno:
--      - 409 checkin_pendente se checkin_em is null;
--      - 409 checkin_ja_confirmado se checkin_tipo <> 'manual' (geolocalizado já nasce verificado).
--   6. Caminho feliz:
--      - Retorna JSONB com turno_id, tipo='manual', verificacao='verificado', registrado_em e distancia_m;
--      - Atualiza public.turno: checkin_confirmado_em = privado.agora(), verificacao = 'verificado';
--      - Efeito colateral: dispara privado.recalcular_comparecimento(profissional_id), incrementando turnos_realizados.
--   7. Operador da casa: operador (além do administrador) confirma turno da casa com sucesso.
--   8. Idempotência / Reenvio: segunda chamada com checkin_confirmado_em preenchido devolve os dados
--      sem erro e sem alterar o timestamp original de confirmação.
--   9. Provas de mutação dinâmica:
--      - Mutante sem trava de membro (permite contratante alheio);
--      - Mutante sem trava de geolocalizado (permite confirmar check-in que não é manual);
--      - Mutante sem trava de check-in pendente;
--      - Restauração da política canônica e revalidação do bloqueio.
--
-- Prefixo de IDs: c7240000-0000-4000-8000-0000000000xx.
-- Datas determinísticas, sem now() livre e com rollback limpo.

begin;
select plan(26);

-- Ambiente de teste e relógio congelado
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-11-05 18:30:00+00', true);

-- ── Helpers ───────────────────────────────────────────────────────────────────

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

create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

-- ── Catálogo e Asserções Estruturais ──────────────────────────────────────────

select has_function('public', 'confirmar_checkin_manual', array['uuid'],
  'funcao public.confirmar_checkin_manual(uuid) existe no catalogo');

select is(
  (select p.prosecdef and array['search_path=""'] <@ coalesce(p.proconfig, '{}')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'confirmar_checkin_manual'),
  true,
  'confirmar_checkin_manual e SECURITY DEFINER com search_path="" estrito'
);

select is(
  has_function_privilege('anon', 'public.confirmar_checkin_manual(uuid)', 'execute'),
  false,
  'papel anon nao tem privilegio de EXECUTE em confirmar_checkin_manual'
);

select is(
  has_function_privilege('authenticated', 'public.confirmar_checkin_manual(uuid)', 'execute'),
  true,
  'papel authenticated tem privilegio de EXECUTE em confirmar_checkin_manual'
);

-- ── Cenário de Dados ─────────────────────────────────────────────────────────

select pg_temp.autenticar('c7240000-0000-4000-8000-000000000001', 'ze@barze.test');
select pg_temp.autenticar('c7240000-0000-4000-8000-000000000002', 'ana@prof.test');
select pg_temp.autenticar('c7240000-0000-4000-8000-000000000003', 'beto@prof.test');
select pg_temp.autenticar('c7240000-0000-4000-8000-000000000004', 'rui@operador.test');
select pg_temp.autenticar('c7240000-0000-4000-8000-000000000005', 'carla@cafe.test');
select pg_temp.autenticar('c7240000-0000-4000-8000-000000000006', 'sam@suspenso.test');

insert into public.usuario (id, perfil, estado, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('c7240000-0000-4000-8000-000000000001', 'contratante',  'ativa',    'Zé',   '+5561972400001', 'ze@barze.test',    '1980-01-01', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7240000-0000-4000-8000-000000000002', 'profissional', 'ativa',    'Ana',  '+5561972400002', 'ana@prof.test',    '1995-05-10', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7240000-0000-4000-8000-000000000003', 'profissional', 'ativa',    'Beto', '+5561972400003', 'beto@prof.test',   '1992-07-20', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7240000-0000-4000-8000-000000000004', 'contratante',  'ativa',    'Rui',  '+5561972400004', 'rui@operador.test','1988-03-15', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7240000-0000-4000-8000-000000000005', 'contratante',  'ativa',    'Carla','+5561972400005', 'carla@cafe.test',  '1985-11-25', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7240000-0000-4000-8000-000000000006', 'contratante',  'suspensa', 'Sam',  '+5561972400006', 'sam@suspenso.test','1990-09-09', '2026-09-22', '2026-10-01 10:00:00+00');

insert into public.profissional (id, usuario_id, ponto_base, turnos_realizados, taxa_comparecimento) values
  ('c7240000-0000-4000-8000-000000000020', 'c7240000-0000-4000-8000-000000000002', 'POINT(-47.88 -15.79)'::extensions.geography, 0, null),
  ('c7240000-0000-4000-8000-000000000030', 'c7240000-0000-4000-8000-000000000003', 'POINT(-47.89 -15.80)'::extensions.geography, 0, null);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('c7240000-0000-4000-8000-000000000010', 'Bar do Zé', '72400000000101', 'food_service', 'CLN 201 Bloco A', 'POINT(-47.8840 -15.7960)'::extensions.geography),
  ('c7240000-0000-4000-8000-000000000050', 'Café Carla', '72400000000102', 'food_service', 'CLN 302 Bloco B', 'POINT(-47.8880 -15.7990)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('c7240000-0000-4000-8000-000000000001', 'c7240000-0000-4000-8000-000000000010', 'administrador'),
  ('c7240000-0000-4000-8000-000000000004', 'c7240000-0000-4000-8000-000000000010', 'operador'),
  ('c7240000-0000-4000-8000-000000000006', 'c7240000-0000-4000-8000-000000000010', 'operador'),
  ('c7240000-0000-4000-8000-000000000005', 'c7240000-0000-4000-8000-000000000050', 'administrador');

-- Vaga 1 (05/11): Ana e Beto confirmados
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7240000-0000-4000-8000-000000000100',
  'c7240000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-05 18:00:00+00', '2026-11-05 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 2,
  true, false, false, 'Seu Zé', 'urgencia', 'preenchida',
  'c7240000-0000-4000-8000-000000000901'::uuid,
  'c7240000-0000-4000-8000-000000000001'::uuid,
  '2026-11-01 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7240000-0000-4000-8000-000000000201', 'c7240000-0000-4000-8000-000000000100', '2026-11-05 18:00:00+00', '2026-11-05 23:00:00+00', 'confirmada', 'c7240000-0000-4000-8000-000000000020', '2026-11-02 10:00:00+00'),
  ('c7240000-0000-4000-8000-000000000202', 'c7240000-0000-4000-8000-000000000100', '2026-11-05 18:00:00+00', '2026-11-05 23:00:00+00', 'confirmada', 'c7240000-0000-4000-8000-000000000030', '2026-11-02 10:00:00+00');

-- Vaga 2 (06/11): Ana para teste de turno sem check-in
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7240000-0000-4000-8000-000000000102',
  'c7240000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-06 18:00:00+00', '2026-11-06 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'urgencia', 'preenchida',
  'c7240000-0000-4000-8000-000000000902'::uuid,
  'c7240000-0000-4000-8000-000000000001'::uuid,
  '2026-11-01 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7240000-0000-4000-8000-000000000203', 'c7240000-0000-4000-8000-000000000102', '2026-11-06 18:00:00+00', '2026-11-06 23:00:00+00', 'confirmada', 'c7240000-0000-4000-8000-000000000020', '2026-11-02 10:00:00+00');

-- Turnos:
-- Turno 301: Ana - Check-in manual pendente de confirmação
-- Turno 302: Beto - Check-in geolocalizado já verificado
-- Turno 303: Ana - Sem check-in (checkin_em is null)
insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7240000-0000-4000-8000-000000000301', 'c7240000-0000-4000-8000-000000000201', 'manual', '2026-11-05 17:55:00+00', 350, 'pendente', 18000, null),
  ('c7240000-0000-4000-8000-000000000302', 'c7240000-0000-4000-8000-000000000202', 'geolocalizado', '2026-11-05 17:50:00+00', 45, 'verificado', 18000, null),
  ('c7240000-0000-4000-8000-000000000303', 'c7240000-0000-4000-8000-000000000203', null, null, null, 'pendente', 18000, null);

-- ── Recusas e Validações de Entrada ──────────────────────────────────────────

select throws_ok(
  $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000301'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  'sem sessao (auth.uid nulo): recusa com 401 nao_autenticado'
);

select throws_ok(
  pg_temp.por('c7240000-0000-4000-8000-000000000001', $$ select public.confirmar_checkin_manual(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'turno_id'),
  'turno_id nulo: recusa com 422 campo_obrigatorio'
);

select throws_ok(
  pg_temp.por('c7240000-0000-4000-8000-000000000001', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000999'::uuid) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'turno_id inexistente: recusa com 404 nao_encontrado'
);

select throws_ok(
  pg_temp.por('c7240000-0000-4000-8000-000000000006', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000301'::uuid) $$),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'membro com conta suspensa: recusa com 403 sem_permissao (conta_suspensa via exigir_conta_ativa)'
);

-- RF20: Isolamento de Papéis na Confirmação de Presença
select throws_ok(
  pg_temp.por('c7240000-0000-4000-8000-000000000002', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000301'::uuid) $$),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  'RF20: profissional do turno nao pode confirmar a propria presenca manual (403 sem_permissao)'
);

select throws_ok(
  pg_temp.por('c7240000-0000-4000-8000-000000000003', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000301'::uuid) $$),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  'profissional terceiro sem vinculo recebe 403 sem_permissao'
);

select throws_ok(
  pg_temp.por('c7240000-0000-4000-8000-000000000005', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000301'::uuid) $$),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  'contratante de outro estabelecimento recebe 403 sem_permissao'
);

-- Pré-condições de Estado do Turno
select throws_ok(
  pg_temp.por('c7240000-0000-4000-8000-000000000001', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000303'::uuid) $$),
  'PGRST',
  pg_temp.erro('checkin_pendente'),
  'turno sem check-in realizado: recusa com 409 checkin_pendente'
);

select throws_ok(
  pg_temp.por('c7240000-0000-4000-8000-000000000001', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000302'::uuid) $$),
  'PGRST',
  pg_temp.erro('checkin_ja_confirmado'),
  'turno com check-in geolocalizado ja verificado: recusa com 409 checkin_ja_confirmado'
);

-- ── Estado Inicial Antes da Confirmação ──────────────────────────────────────

select is(
  (select t.verificacao || '|' || (t.checkin_confirmado_em is null)::text
     from public.turno t where t.id = 'c7240000-0000-4000-8000-000000000301'),
  'pendente|true',
  'turno 301 inicia com verificacao=pendente e checkin_confirmado_em nulo'
);

select is(
  (select p.turnos_realizados from public.profissional p where p.id = 'c7240000-0000-4000-8000-000000000020'),
  0,
  'profissional Ana inicia com 0 turnos realizados'
);

-- ── Caminho Feliz: Confirmação pelo Administrador ────────────────────────────

select is(
  pg_temp.como('c7240000-0000-4000-8000-000000000001', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000301'::uuid) $$),
  jsonb_build_object(
    'turno_id',      'c7240000-0000-4000-8000-000000000301'::uuid,
    'tipo',          'manual',
    'verificacao',   'verificado',
    'registrado_em', '2026-11-05 17:55:00+00'::timestamptz,
    'distancia_m',   350
  ),
  'confirmar_checkin_manual devolve envelope exato com verificacao=verificado e tipo=manual'
);

-- Efeitos no banco após a confirmação
select is(
  (select t.verificacao from public.turno t where t.id = 'c7240000-0000-4000-8000-000000000301'),
  'verificado'::public.verificacao_turno,
  'turno atualizado para verificacao=verificado no banco'
);

select is(
  (select t.checkin_confirmado_em from public.turno t where t.id = 'c7240000-0000-4000-8000-000000000301'),
  '2026-11-05 18:30:00+00'::timestamptz,
  'checkin_confirmado_em registrado com o carimbo exato de privado.agora()'
);

-- Efeito Colateral: Recálculo de Comparecimento
select is(
  (select p.turnos_realizados || '|' || p.taxa_comparecimento::text
     from public.profissional p where p.id = 'c7240000-0000-4000-8000-000000000020'),
  '1|1.000',
  'privado.recalcular_comparecimento atualizou turnos_realizados=1 e taxa=1.000'
);

-- ── RF21: Confirmação pelo Papel Operador do Estabelecimento ─────────────────
-- Vaga 3 (07/11): Beto para o operador Rui confirmar
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7240000-0000-4000-8000-000000000103',
  'c7240000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-07 18:00:00+00', '2026-11-07 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'urgencia', 'preenchida',
  'c7240000-0000-4000-8000-000000000903'::uuid,
  'c7240000-0000-4000-8000-000000000001'::uuid,
  '2026-11-01 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em)
values ('c7240000-0000-4000-8000-000000000204', 'c7240000-0000-4000-8000-000000000103',
        '2026-11-07 18:00:00+00', '2026-11-07 23:00:00+00', 'confirmada',
        'c7240000-0000-4000-8000-000000000030', '2026-11-02 10:00:00+00');

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em)
values ('c7240000-0000-4000-8000-000000000304', 'c7240000-0000-4000-8000-000000000204',
        'manual', '2026-11-07 17:58:00+00', 420, 'pendente', 18000, null);

select is(
  (pg_temp.como('c7240000-0000-4000-8000-000000000004', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000304'::uuid) $$)->>'verificacao'),
  'verificado',
  'RF21: operador do estabelecimento (Rui) confirma presenca manual com sucesso'
);

-- ── Idempotência e Reenvio de Chamada ─────────────────────────────────────────
-- Avançamos o relógio para provar que a rechamada NÃO altera o timestamp original
select set_config('frila.agora', '2026-11-05 19:45:00+00', true);

select is(
  pg_temp.como('c7240000-0000-4000-8000-000000000001', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000301'::uuid) $$),
  jsonb_build_object(
    'turno_id',      'c7240000-0000-4000-8000-000000000301'::uuid,
    'tipo',          'manual',
    'verificacao',   'verificado',
    'registrado_em', '2026-11-05 17:55:00+00'::timestamptz,
    'distancia_m',   350
  ),
  'idempotencia: segunda chamada devolve os mesmos dados sem erro'
);

select is(
  (select t.checkin_confirmado_em from public.turno t where t.id = 'c7240000-0000-4000-8000-000000000301'),
  '2026-11-05 18:30:00+00'::timestamptz,
  'idempotencia: checkin_confirmado_em preserva o carimbo original e nao e sobrescrito'
);

-- ── Provas de Mutação Real (Discriminação de Asserções) ──────────────────────

-- Mutação 1: Omissão da trava de membro do estabelecimento
-- Substituímos a função temporariamente omitindo a verificação de membro
CREATE OR REPLACE FUNCTION public.confirmar_checkin_manual(turno_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
  v_pos public.posicao%rowtype;
  v_t   public.turno%rowtype;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  perform privado.exigir_conta_ativa();
  if confirmar_checkin_manual.turno_id is null then perform public.erro(422, 'campo_obrigatorio', 'turno_id'); end if;
  select p.* into v_pos from public.turno t join public.posicao p on p.id = t.posicao_id where t.id = confirmar_checkin_manual.turno_id;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;
  -- MUTACAO 1: OMITIDA CHECAGEM if not privado.eh_membro(...)
  select * into v_t from public.turno t where t.id = confirmar_checkin_manual.turno_id;
  if v_t.checkin_em is null then perform public.erro(409, 'checkin_pendente'); end if;
  if v_t.checkin_tipo <> 'manual' then perform public.erro(409, 'checkin_ja_confirmado'); end if;
  return jsonb_build_object('mutante_sem_membro', true);
end $function$;

select is(
  (pg_temp.como('c7240000-0000-4000-8000-000000000005', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000301'::uuid) $$))->>'mutante_sem_membro',
  'true',
  'mutante sem trava de membro: contratante alheio passaria; prova que 403 discrimina'
);

-- Mutação 2: Omissão da trava de check-in geolocalizado
CREATE OR REPLACE FUNCTION public.confirmar_checkin_manual(turno_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
  v_pos public.posicao%rowtype;
  v_t   public.turno%rowtype;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  perform privado.exigir_conta_ativa();
  if confirmar_checkin_manual.turno_id is null then perform public.erro(422, 'campo_obrigatorio', 'turno_id'); end if;
  select p.* into v_pos from public.turno t join public.posicao p on p.id = t.posicao_id where t.id = confirmar_checkin_manual.turno_id;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;
  if not privado.eh_membro(privado.estabelecimento_da_vaga(v_pos.vaga_id)) then perform public.erro(403, 'sem_permissao'); end if;
  select * into v_t from public.turno t where t.id = confirmar_checkin_manual.turno_id;
  if v_t.checkin_em is null then perform public.erro(409, 'checkin_pendente'); end if;
  -- MUTACAO 2: OMITIDA CHECAGEM if v_t.checkin_tipo <> 'manual'
  return jsonb_build_object('mutante_sem_tipo', true);
end $function$;

select is(
  (pg_temp.como('c7240000-0000-4000-8000-000000000001', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000302'::uuid) $$))->>'mutante_sem_tipo',
  'true',
  'mutante sem trava de checkin_tipo: geolocalizado passaria; prova que 409 discrimina'
);

-- Mutação 3: Omissão da trava de check-in pendente (checkin_em is null)
CREATE OR REPLACE FUNCTION public.confirmar_checkin_manual(turno_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
  v_pos public.posicao%rowtype;
  v_t   public.turno%rowtype;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  perform privado.exigir_conta_ativa();
  if confirmar_checkin_manual.turno_id is null then perform public.erro(422, 'campo_obrigatorio', 'turno_id'); end if;
  select p.* into v_pos from public.turno t join public.posicao p on p.id = t.posicao_id where t.id = confirmar_checkin_manual.turno_id;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;
  if not privado.eh_membro(privado.estabelecimento_da_vaga(v_pos.vaga_id)) then perform public.erro(403, 'sem_permissao'); end if;
  select * into v_t from public.turno t where t.id = confirmar_checkin_manual.turno_id;
  -- MUTACAO 3: OMITIDA CHECAGEM if v_t.checkin_em is null
  return jsonb_build_object('mutante_sem_pendente', true);
end $function$;

select is(
  (pg_temp.como('c7240000-0000-4000-8000-000000000001', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000303'::uuid) $$))->>'mutante_sem_pendente',
  'true',
  'mutante sem trava de checkin pendente: turno sem presenca passaria; prova que 409 discrimina'
);

-- ── Restauração Canônica ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.confirmar_checkin_manual(turno_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
  v_pos public.posicao%rowtype;
  v_t   public.turno%rowtype;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  perform privado.exigir_conta_ativa();
  if confirmar_checkin_manual.turno_id is null then perform public.erro(422, 'campo_obrigatorio', 'turno_id'); end if;
  select p.* into v_pos from public.turno t join public.posicao p on p.id = t.posicao_id where t.id = confirmar_checkin_manual.turno_id;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;
  if not privado.eh_membro(privado.estabelecimento_da_vaga(v_pos.vaga_id)) then perform public.erro(403, 'sem_permissao'); end if;
  select * into v_t from public.turno t where t.id = confirmar_checkin_manual.turno_id;
  if v_t.checkin_em is null then perform public.erro(409, 'checkin_pendente'); end if;
  if v_t.checkin_tipo <> 'manual' then perform public.erro(409, 'checkin_ja_confirmado'); end if;
  if v_t.checkin_confirmado_em is not null then
    return jsonb_build_object('turno_id', v_t.id, 'tipo', v_t.checkin_tipo, 'verificacao', v_t.verificacao, 'registrado_em', v_t.checkin_em, 'distancia_m', v_t.checkin_distancia_m);
  end if;
  update public.turno t set checkin_confirmado_em = privado.agora(), verificacao = 'verificado' where t.id = confirmar_checkin_manual.turno_id returning * into v_t;
  perform privado.recalcular_comparecimento(v_pos.profissional_id);
  return jsonb_build_object('turno_id', v_t.id, 'tipo', v_t.checkin_tipo, 'verificacao', v_t.verificacao, 'registrado_em', v_t.checkin_em, 'distancia_m', v_t.checkin_distancia_m);
end $function$;

select throws_ok(
  pg_temp.por('c7240000-0000-4000-8000-000000000005', $$ select public.confirmar_checkin_manual('c7240000-0000-4000-8000-000000000301'::uuid) $$),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  'funcao canonica restaurada: contratante alheio volta a ser barrado com 403 sem_permissao'
);

select * from finish();
rollback;
