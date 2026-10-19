-- 694_reconciliar_reputacao.sql
--
-- Cobertura pgTAP de privado.reconciliar_reputacao() (Lacuna #5, RNF13, RF22, RN15).
--
-- 1. Privilégios mínimos e search_path restritivo.
-- 2. Recusa de execução por papéis não autorizados (authenticated, anon, public).
-- 3. Execução idempotente em banco sincronizado (retorna 0).
-- 4. Detecção e correção de divergência de reputação (taxa, turnos, aval_positivas, aval_total).
-- 5. Gravação da trilha de auditoria em privado.divergencia_reputacao.
-- 6. Re-execução imediata idempotente (retorna 0 e sem novas divergências).

begin;
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-16 12:00:00-03';

select plan(14);

-- ── 1. Privilégios e segurança ────────────────────────────────────────────────

select ok(
  has_function_privilege('service_role', 'privado.reconciliar_reputacao()', 'execute'),
  'service_role executa privado.reconciliar_reputacao()'
);

select ok(
  not has_function_privilege('authenticated', 'privado.reconciliar_reputacao()', 'execute'),
  'authenticated não executa privado.reconciliar_reputacao()'
);

select ok(
  not has_function_privilege('anon', 'privado.reconciliar_reputacao()', 'execute'),
  'anon não executa privado.reconciliar_reputacao()'
);

select ok(
  not has_function_privilege('public', 'privado.reconciliar_reputacao()', 'execute'),
  'public não executa privado.reconciliar_reputacao()'
);

select ok(
  position('select privado.reconciliar_comparecimento();' in (select prosrc from pg_proc where proname = 'reconciliar_reputacao' and pronamespace = 'privado'::regnamespace)) > 0,
  'privado.reconciliar_reputacao() delega estritamente para privado.reconciliar_comparecimento()'
);

select is(
  (select prosecdef from pg_proc where proname = 'reconciliar_reputacao' and pronamespace = 'privado'::regnamespace),
  true,
  'privado.reconciliar_reputacao() é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'reconciliar_reputacao' and pronamespace = 'privado'::regnamespace),
  array['search_path=""'],
  'privado.reconciliar_reputacao() possui search_path vazio fixado'
);

-- ── 2. Cenário de teste (prefixo f9) ──────────────────────────────────────────

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado) values
  ('f9000000-0000-4000-8000-000000000001', 'contratante',  'Contratante F9', '+5561999970001', 'c_f9@test.com', '1985-01-01', '2026-09-22', now(), 'ativa'),
  ('f9000000-0000-4000-8000-000000000002', 'profissional', 'Profissional F9', '+5561999970002', 'p_f9@test.com', '1992-02-02', '2026-09-22', now(), 'ativa');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('f9000000-0000-4000-8000-000000000010', 'Restaurante F9', '99888777000199', 'food_service', 'SCLN 205 Bloco A',
   'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('f9000000-0000-4000-8000-000000000010', 'f9000000-0000-4000-8000-000000000001', 'administrador');

-- Cria profissional inicialmente com cache corrompido propositalmente:
-- Canônico: 1 turno com presença verificada e 1 falta -> total 2, taxa 1/2 = 0.500
-- Cache adulterado: taxa_comparecimento = 1.000, turnos_realizados = 5, aval_positivas = 10, aval_total = 10
insert into public.profissional (
  id, usuario_id, ponto_base,
  taxa_comparecimento, turnos_realizados, aval_positivas, aval_total
) values (
  'f9000000-0000-4000-8000-000000000020',
  'f9000000-0000-4000-8000-000000000002',
  'POINT(-47.8825 -15.7942)'::extensions.geography,
  1.000, 5, 10, 10
);

-- Vaga 1 (presença verificada)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, ponto, local, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  inicio_em, fim_em, modo, estado, regiao_administrativa, chave_cliente, publicado_por
) values (
  'f9000000-0000-4000-8000-000000000030',
  'f9000000-0000-4000-8000-000000000010',
  (select id from public.funcao where nome = 'garçom' limit 1),
  'POINT(-47.8825 -15.7942)'::extensions.geography,
  'Restaurante F9', 15000, 1, true, false, false, 'Gerente',
  privado.agora() - interval '2 days', privado.agora() - interval '2 days' + interval '6 hours',
  'urgencia', 'encerrada', 'Plano Piloto', gen_random_uuid(),
  'f9000000-0000-4000-8000-000000000001'
);

-- Posição 1 confirmada com turno verificado
insert into public.posicao (id, vaga_id, profissional_id, inicio_em, fim_em, estado, falta, confirmado_em) values (
  'f9000000-0000-4000-8000-000000000040',
  'f9000000-0000-4000-8000-000000000030',
  'f9000000-0000-4000-8000-000000000020',
  privado.agora() - interval '2 days', privado.agora() - interval '2 days' + interval '6 hours',
  'cumprida', false, privado.agora() - interval '3 days'
);

insert into public.turno (id, posicao_id, checkin_em, checkout_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos) values (
  'f9000000-0000-4000-8000-000000000050',
  'f9000000-0000-4000-8000-000000000040',
  privado.agora() - interval '2 days', privado.agora() - interval '2 days' + interval '6 hours',
  'geolocalizado', 50, 'verificado', 15000
);

-- Avaliação positiva recebida pelo profissional
insert into public.avaliacao (id, turno_id, autor_id, alvo_tipo, alvo_id, resposta) values (
  'f9000000-0000-4000-8000-000000000060',
  'f9000000-0000-4000-8000-000000000050',
  'f9000000-0000-4000-8000-000000000001',
  'profissional',
  'f9000000-0000-4000-8000-000000000020',
  true
);

-- Posição 2 com falta do profissional (sem turno de presença)
insert into public.posicao (id, vaga_id, profissional_id, inicio_em, fim_em, estado, falta, confirmado_em) values (
  'f9000000-0000-4000-8000-000000000041',
  'f9000000-0000-4000-8000-000000000030',
  'f9000000-0000-4000-8000-000000000020',
  privado.agora() - interval '1 day', privado.agora() - interval '1 day' + interval '6 hours',
  'cancelada', true, privado.agora() - interval '2 days'
);

-- Força a corrupção do cache desnormalizado do profissional após os gatilhos:
update public.profissional
   set taxa_comparecimento = 1.000,
       turnos_realizados = 5,
       aval_positivas = 10,
       aval_total = 10
 where id = 'f9000000-0000-4000-8000-000000000020';

-- ── 3. Execução de reconciliação via reconciliar_reputacao() ──────────────────

-- Deve encontrar e reconciliar a divergência intencional do profissional F9
select is(
  (select privado.reconciliar_reputacao() >= 1),
  true,
  'privado.reconciliar_reputacao() executa e retorna contagem de divergencias >= 1'
);

-- ── 4. Verificação da correção do cache em public.profissional ─────────────────

select is(
  (select p.taxa_comparecimento from public.profissional p where p.id = 'f9000000-0000-4000-8000-000000000020'),
  0.500::numeric(4,3),
  'taxa_comparecimento corrigida para 0.500 (1 presenca / 2 turnos com presenca+falta)'
);

select is(
  (select p.turnos_realizados from public.profissional p where p.id = 'f9000000-0000-4000-8000-000000000020'),
  1,
  'turnos_realizados corrigido para 1 (apenas turnos com verificacao = verificado)'
);

select is(
  (select p.aval_positivas from public.profissional p where p.id = 'f9000000-0000-4000-8000-000000000020'),
  1,
  'aval_positivas corrigido para 1 (1 avaliacao positiva historica)'
);

select is(
  (select p.aval_total from public.profissional p where p.id = 'f9000000-0000-4000-8000-000000000020'),
  1,
  'aval_total corrigido para 1'
);

-- ── 5. Verificação da trilha de auditoria em divergencia_reputacao ────────────

select is(
  (select count(*)::int from privado.divergencia_reputacao d
    where d.profissional_id = 'f9000000-0000-4000-8000-000000000020'
      and d.taxa_anterior = 1.000
      and d.taxa_corrigida = 0.500
      and d.turnos_anterior = 5
      and d.turnos_corrigido = 1
      and d.aval_pos_anterior = 10
      and d.aval_pos_corrigido = 1
      and d.aval_tot_anterior = 10
      and d.aval_tot_corrigido = 1),
  1,
  'trilha gravada em privado.divergencia_reputacao com valores anteriores e corrigidos exatos'
);

-- ── 6. Idempotência da execução subsequente ───────────────────────────────────

select is(
  privado.reconciliar_reputacao(),
  0,
  'segunda execucao imediata devolve 0 divergencias (idempotencia garantida)'
);

select * from finish();
rollback;
