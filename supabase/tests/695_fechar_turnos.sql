-- 695_fechar_turnos.sql
--
-- Cobertura pgTAP de privado.fechar_turnos() (Lacuna #6, RNF03, RF11, RF18, RN08).
--
-- 1. Privilégios mínimos e search_path restritivo.
-- 2. Recusa de execução por papéis não autorizados (authenticated, anon, public).
-- 3. Delegação estrita para privado.fechar_turnos_e_vagas().
-- 4. Execução de fechamento em posições confirmadas expiradas (estado -> cumprida).
-- 5. Cancelamento de posições abertas expiradas (estado -> cancelada).
-- 6. Encerramento de vagas expiradas sem posições pendentes (estado -> encerrada).
-- 7. Enfileiramento de notificação avaliacao_disponivel para profissional e estabelecimento.
-- 8. Idempotência da execução subsequente imediata (retorno 0).

begin;
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-16 12:00:00-03';

select plan(15);

-- ── 1. Privilégios e segurança ────────────────────────────────────────────────

select ok(
  has_function_privilege('service_role', 'privado.fechar_turnos()', 'execute'),
  'service_role executa privado.fechar_turnos()'
);

select ok(
  not has_function_privilege('authenticated', 'privado.fechar_turnos()', 'execute'),
  'authenticated não executa privado.fechar_turnos()'
);

select ok(
  not has_function_privilege('anon', 'privado.fechar_turnos()', 'execute'),
  'anon não executa privado.fechar_turnos()'
);

select ok(
  not has_function_privilege('public', 'privado.fechar_turnos()', 'execute'),
  'public não executa privado.fechar_turnos()'
);

select ok(
  position('select privado.fechar_turnos_e_vagas();' in (select prosrc from pg_proc where proname = 'fechar_turnos' and pronamespace = 'privado'::regnamespace)) > 0,
  'privado.fechar_turnos() delega estritamente para privado.fechar_turnos_e_vagas()'
);

select is(
  (select prosecdef from pg_proc where proname = 'fechar_turnos' and pronamespace = 'privado'::regnamespace),
  true,
  'privado.fechar_turnos() é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'fechar_turnos' and pronamespace = 'privado'::regnamespace),
  array['search_path=""'],
  'privado.fechar_turnos() possui search_path vazio fixado'
);

-- ── 2. Cenário de teste determinístico (prefixo fa) ───────────────────────────

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado) values
  ('fa000000-0000-4000-8000-000000000001', 'contratante',  'Contratante FA', '+5561999960001', 'c_fa@test.com', '1985-01-01', '2026-09-22', now(), 'ativa'),
  ('fa000000-0000-4000-8000-000000000002', 'profissional', 'Profissional FA', '+5561999960002', 'p_fa@test.com', '1992-02-02', '2026-09-22', now(), 'ativa');

insert into public.profissional (id, usuario_id, ponto_base) values
  ('fa000000-0000-4000-8000-000000000020', 'fa000000-0000-4000-8000-000000000002', 'POINT(-47.8825 -15.7942)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('fa000000-0000-4000-8000-000000000010', 'Restaurante FA', '77666555000199', 'food_service', 'SCLN 102 Bloco C',
   'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('fa000000-0000-4000-8000-000000000010', 'fa000000-0000-4000-8000-000000000001', 'administrador');

-- Vaga 1: com posição confirmada expirada (concluída)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, ponto, local, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  inicio_em, fim_em, modo, estado, regiao_administrativa, chave_cliente, publicado_por
) values (
  'fa000000-0000-4000-8000-000000000030',
  'fa000000-0000-4000-8000-000000000010',
  (select id from public.funcao where nome = 'garçom' limit 1),
  'POINT(-47.8825 -15.7942)'::extensions.geography,
  'Restaurante FA', 15000, 1, true, false, false, 'Gerente',
  privado.agora() - interval '4 hours', privado.agora() - interval '1 hour',
  'urgencia', 'publicada', 'Plano Piloto', gen_random_uuid(),
  'fa000000-0000-4000-8000-000000000001'
);

insert into public.posicao (id, vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em) values (
  'fa000000-0000-4000-8000-000000000040',
  'fa000000-0000-4000-8000-000000000030',
  'fa000000-0000-4000-8000-000000000020',
  privado.agora() - interval '4 hours', privado.agora() - interval '1 hour',
  'confirmada', privado.agora() - interval '5 hours'
);

insert into public.turno (id, posicao_id, checkin_em, checkout_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos) values (
  'fa000000-0000-4000-8000-000000000050',
  'fa000000-0000-4000-8000-000000000040',
  privado.agora() - interval '4 hours', privado.agora() - interval '1 hour',
  'geolocalizado', 50, 'verificado', 15000
);

-- Vaga 2: expirada com posição aberta não preenchida
insert into public.vaga (
  id, estabelecimento_id, funcao_id, ponto, local, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  inicio_em, fim_em, modo, estado, regiao_administrativa, chave_cliente, publicado_por
) values (
  'fa000000-0000-4000-8000-000000000031',
  'fa000000-0000-4000-8000-000000000010',
  (select id from public.funcao where nome = 'garçom' limit 1),
  'POINT(-47.8825 -15.7942)'::extensions.geography,
  'Restaurante FA', 15000, 1, true, false, false, 'Gerente',
  privado.agora() - interval '5 hours', privado.agora() - interval '2 hours',
  'urgencia', 'publicada', 'Plano Piloto', gen_random_uuid(),
  'fa000000-0000-4000-8000-000000000001'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado) values (
  'fa000000-0000-4000-8000-000000000041',
  'fa000000-0000-4000-8000-000000000031',
  privado.agora() - interval '5 hours', privado.agora() - interval '2 hours',
  'aberta'
);

-- ── 3. Execução de fechamento via privado.fechar_turnos() ─────────────────────

select is(
  (select privado.fechar_turnos() >= 1),
  true,
  'privado.fechar_turnos() executa e fecha posicoes/turnos passados (retorno >= 1)'
);

-- ── 4. Verificação da transição de estados ─────────────────────────────────────

select is(
  (select p.estado from public.posicao p where p.id = 'fa000000-0000-4000-8000-000000000040'),
  'cumprida'::public.estado_posicao,
  'posicao confirmada expirada transitou para cumprida'
);

select is(
  (select p.estado from public.posicao p where p.id = 'fa000000-0000-4000-8000-000000000041'),
  'cancelada'::public.estado_posicao,
  'posicao aberta expirada transitou para cancelada'
);

select is(
  (select v.estado from public.vaga v where v.id = 'fa000000-0000-4000-8000-000000000030'),
  'encerrada'::public.estado_vaga,
  'vaga 1 transitou para encerrada apos cumprimento da posicao'
);

select is(
  (select v.estado from public.vaga v where v.id = 'fa000000-0000-4000-8000-000000000031'),
  'encerrada'::public.estado_vaga,
  'vaga 2 transitou para encerrada apos cancelamento da posicao aberta'
);

-- ── 5. Verificação de notificações de avaliação disponível ────────────────────

select is(
  (select count(*)::int from public.notificacao n
    where n.tipo = 'avaliacao_disponivel'
      and n.referencia_id = 'fa000000-0000-4000-8000-000000000050'
      and n.usuario_id = 'fa000000-0000-4000-8000-000000000002'),
  1,
  'notificacao avaliacao_disponivel enfileirada para o profissional'
);

select is(
  (select count(*)::int from public.notificacao n
    where n.tipo = 'avaliacao_disponivel'
      and n.referencia_id = 'fa000000-0000-4000-8000-000000000050'
      and n.usuario_id = 'fa000000-0000-4000-8000-000000000001'),
  1,
  'notificacao avaliacao_disponivel enfileirada para o contratante membro'
);

-- ── 6. Idempotência da execução subsequente ───────────────────────────────────

select is(
  privado.fechar_turnos(),
  0,
  'segunda execucao imediata de privado.fechar_turnos() devolve 0 (idempotencia)'
);

select * from finish();
rollback;
