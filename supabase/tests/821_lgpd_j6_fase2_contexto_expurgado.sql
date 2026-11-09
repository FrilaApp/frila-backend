-- Teste pgTAP: supabase/tests/821_lgpd_j6_fase2_contexto_expurgado.sql
-- Escopo: LGPD-J6, fase 2 (cartão BewEzEOJ). Depois de 5 anos do fim do turno, nada no banco
-- liga o profissional ao endereço ou à casa daquele turno.
-- Decisões do Cauê de 08/11/2026 (brief B-T5): R6 ocorrência de denúncia e cancelamento fica
-- 5 anos e depois perde relato e motivo; R7 a trilha sai junto com a entidade; R9 os
-- contadores de reputação ficam, sem recálculo. Q3: a posição sem turno da vaga expirada sai.
--
-- Provas:
--   R1-R3  vaga cujas posições terminaram todas há 5 anos (com ou sem turno, conta ativa ou
--          anonimizada): local e responsavel_local viram 'Expurgado (LGPD)', observacoes e traje
--          viram NULL, ponto vira o ponto neutro fixo; ocultações e trilha da vaga saem.
--   R4/R5  nenhuma chamada nem despacho dessa vaga sobra.
--   R6     ocorrência com 5 anos e 1 dia: relato NULL, motivo marcador, trilha fora; com 4 anos e
--          364 dias, ligada a posição ainda nos 5 anos, ou de outro tipo: intacta.
--   R7     a trilha de candidatura e avaliação do turno expurgado sai.
--   R8     marca_notificacao órfã ou com mais de 5 anos sai; as outras ficam. A marca de vaga
--          (que nunca é apagada) só sai pelo prazo.
--   R9     contadores do profissional iguais antes e depois do expurgo. O resíduo da
--          reconciliação diária fica num todo() (cartão 8KFuT8UP).
--   Q3     posição sem turno da vaga expirada sai, com candidaturas e trilha. A com falta fica
--          (entra na leitura de reputação).
--   FK     posição reaberta por atraso apontando para a original expurgada não derruba a rotina.
--   Exclusão de conta: com a conta anonimizada há mais de 15 dias, esta rotina e
--          limpar_contas_anonimizadas agem na mesma vaga e ocorrência sem desfazer uma à outra
--          (a terceira rodada não reescreve a linha: ctid igual).
--   Trava interna: anonimizar_contexto_das_vagas chamada direto recusa vaga com posição recente.
--   Rodada 2 da revisão (Lince Codex e Lince AG 2): M9, MD/M12, MV e MP.
--   Vaga com uma posição recente: nada muda. Piso de 5 anos não encurtável. Lote limitado e
--   idempotente (a concorrência com SKIP LOCKED não cabe numa sessão pgTAP; ver o PR).

begin;

insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
-- Relógio congelado antes de qualquer leitura de privado.agora().
select set_config('frila.agora', '2026-11-08 12:00:00+00', true);
set local timezone = 'UTC';

select plan(76);

-- ── 1. Catálogo ───────────────────────────────────────────────────────────────

select has_function('privado', 'expurgar_vagas_antigas', array['integer', 'integer'],
  'privado.expurgar_vagas_antigas(integer, integer) existe');
select has_function('privado', 'anonimizar_ocorrencias_antigas', array['integer', 'integer'],
  'privado.anonimizar_ocorrencias_antigas(integer, integer) existe');
select has_function('privado', 'limpar_marcas_notificacao', array['integer', 'integer'],
  'privado.limpar_marcas_notificacao(integer, integer) existe');

select is(
  (select count(*)::int from pg_proc p
    where p.pronamespace = 'privado'::regnamespace
      and p.proname in ('expurgar_vagas_antigas', 'anonimizar_ocorrencias_antigas',
                        'limpar_marcas_notificacao', 'anonimizar_contexto_das_vagas')
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  4,
  'as quatro funções novas são SECURITY DEFINER com search_path vazio');

select is(
  (select count(*)::int from pg_proc p
    where p.pronamespace = 'privado'::regnamespace
      and p.proname in ('expurgar_vagas_antigas', 'anonimizar_ocorrencias_antigas',
                        'limpar_marcas_notificacao', 'anonimizar_contexto_das_vagas')
      and (has_function_privilege('anon', p.oid, 'execute')
           or has_function_privilege('authenticated', p.oid, 'execute'))),
  0,
  'anon e authenticated não executam nenhuma das funções novas');

select ok(
  obj_description('privado.expurgar_turnos_antigos(integer, integer)'::regprocedure, 'pg_proc')
    ~ 'não recalcula',
  'R9: o comment do expurgo diz que os contadores de reputação não são recalculados');

-- ── 2. Cenário ────────────────────────────────────────────────────────────────

create temp table ids (chave text primary key, id uuid not null);

do $$
declare
  a        timestamptz := privado.agora();
  v_c1     uuid := gen_random_uuid();   -- contratante ativo
  v_c2     uuid := gen_random_uuid();   -- contratante anonimizado ontem
  v_c3     uuid := gen_random_uuid();   -- contratante anonimizado há 20 dias (limpar_contas age)
  v_p1u    uuid := gen_random_uuid();
  v_p2u    uuid := gen_random_uuid();
  v_p1     uuid;
  v_p2     uuid;
  v_e1     uuid;
  v_funcao uuid := (select id from public.funcao order by id limit 1);
  v_id     uuid;
  v_fim    timestamptz;

  -- Vaga com os campos de contexto preenchidos, terminando em p_fim.
  v_vaga_sql constant text :=
    'insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
       valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
       responsavel_local, traje, observacoes, modo, estado, chave_cliente, publicado_por)
     values ($1, $2, $3 - interval ''6 hours'', $3, $4,
       ''POINT(-47.9100 -15.8300)''::extensions.geography, 15000, 4, false, false, false,
       $5, $6, $7, ''urgencia'', ''encerrada'', gen_random_uuid(), $8)
     returning id';
begin
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_c1, 'contratante', 'Contratante 821', '+5561999982101', 'c1_821@teste.com', '1985-01-01', '0.2.62', a),
         (v_p1u, 'profissional', 'Profissional Um 821', '+5561999982102', 'p1_821@teste.com', '1990-01-01', '0.2.62', a),
         (v_p2u, 'profissional', 'Profissional Dois 821', '+5561999982103', 'p2_821@teste.com', '1991-01-01', '0.2.62', a);
  insert into public.usuario (id, perfil, nome, nascimento, termos_versao, termos_aceite_em, estado, anonimizado_em)
  values (v_c2, 'contratante', 'Conta encerrada', '1980-01-01', '0.2.62', a, 'anonimizada', a - interval '1 day'),
         (v_c3, 'contratante', 'Conta encerrada', '1980-01-01', '0.2.62', a, 'anonimizada', a - interval '20 days');

  insert into public.profissional (usuario_id, perfil, ponto_base)
  values (v_p1u, 'profissional', 'POINT(-47.88 -15.77)'::extensions.geography) returning id into v_p1;
  insert into public.profissional (usuario_id, perfil, ponto_base)
  values (v_p2u, 'profissional', 'POINT(-47.88 -15.77)'::extensions.geography) returning id into v_p2;

  insert into public.estabelecimento (nome, documento, tipo, endereco, regiao_administrativa, ponto)
  values ('Casa 821', '82182182100121', 'food_service', 'Endereço 821', 'Plano Piloto',
          'POINT(-47.88 -15.77)'::extensions.geography)
  returning id into v_e1;
  insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
  values (v_e1, v_c1, 'administrador');

  insert into ids values ('c1', v_c1), ('c2', v_c2), ('c3', v_c3), ('p1', v_p1), ('p2', v_p2),
                         ('p1u', v_p1u), ('p2u', v_p2u), ('e1', v_e1);

  -- VA: conta ativa, todas as posições terminaram há 5 anos e 1 dia.
  v_fim := a - interval '5 years' - interval '1 day';
  execute v_vaga_sql into v_id
    using v_e1, v_funcao, v_fim, 'Rua da Casa Antiga, 12', 'Ana', 'Preto', 'Portão azul, falar com a Ana', v_c1;
  insert into ids values ('va', v_id);

  -- PA1: turno verificado de P1, com avaliação, candidatura aceita de P1 e recusada de P2.
  insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em)
  values (v_id, v_p1, v_fim - interval '6 hours', v_fim, 'cumprida', v_fim - interval '2 days')
  returning id into v_id;
  insert into ids values ('pa1', v_id);
  insert into public.candidatura (posicao_id, profissional_id, estado, criada_em)
  values (v_id, v_p1, 'aceita', v_fim - interval '3 days') returning id into v_id;
  insert into ids values ('cand_pa1_p1', v_id);
  insert into public.candidatura (posicao_id, profissional_id, estado, criada_em)
  values ((select id from ids where chave = 'pa1'), v_p2, 'recusada', v_fim - interval '3 days') returning id into v_id;
  insert into ids values ('cand_pa1_p2', v_id);
  insert into public.turno (posicao_id, valor_acordado_centavos, checkin_em, checkin_tipo, checkin_distancia_m, verificacao)
  values ((select id from ids where chave = 'pa1'), 15000, v_fim - interval '6 hours', 'geolocalizado', 40, 'verificado')
  returning id into v_id;
  insert into ids values ('ta1', v_id);
  insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
  values (v_id, v_c1, 'profissional', v_p1, true) returning id into v_id;
  insert into ids values ('aval_ta1', v_id);

  -- PA2: posição que nunca virou turno, com candidatura de P2 (Q3).
  insert into public.posicao (vaga_id, inicio_em, fim_em, estado)
  values ((select id from ids where chave = 'va'), v_fim - interval '6 hours', v_fim, 'aberta')
  returning id into v_id;
  insert into ids values ('pa2', v_id);
  insert into public.candidatura (posicao_id, profissional_id, estado, criada_em)
  values (v_id, v_p2, 'expirada', v_fim - interval '3 days') returning id into v_id;
  insert into ids values ('cand_pa2_p2', v_id);

  -- PA3: falta de P2 (turno sem check-in) e PA4, a posição reaberta que aponta para ela.
  insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em, falta)
  values ((select id from ids where chave = 'va'), v_p2, v_fim - interval '6 hours', v_fim,
          'cancelada', v_fim - interval '2 days', true)
  returning id into v_id;
  insert into ids values ('pa3', v_id);
  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_id, 15000) returning id into v_id;
  insert into ids values ('ta3', v_id);
  insert into public.posicao (vaga_id, inicio_em, fim_em, estado, reaberta_por_atraso_de)
  values ((select id from ids where chave = 'va'), v_fim - interval '6 hours', v_fim, 'aberta',
          (select id from ids where chave = 'pa3'))
  returning id into v_id;
  insert into ids values ('pa4', v_id);

  -- PA5: falta sem turno (o fluxo não produz; a regra a preserva porque a reputação a lê).
  insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em, falta)
  values ((select id from ids where chave = 'va'), v_p2, v_fim - interval '6 hours', v_fim,
          'cancelada', v_fim - interval '2 days', true)
  returning id into v_id;
  insert into ids values ('pa5_falta', v_id);

  -- Chamada aceita, despachos, ocultações e a denúncia que as motivou.
  insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, estado, recado,
                              expira_em, respondida_em, criada_em, chave)
  values ((select id from ids where chave = 'va'), v_p1, v_e1, v_c1, 'aceita', 'Traga o avental',
          v_fim - interval '5 days', v_fim - interval '9 days', v_fim - interval '10 days', gen_random_uuid());
  insert into public.despacho (vaga_id, profissional_id, criado_em)
  values ((select id from ids where chave = 'va'), v_p1, v_fim - interval '4 days'),
         ((select id from ids where chave = 'va'), v_p2, v_fim - interval '4 days');

  insert into public.ocorrencia (tipo, autor_id, estabelecimento_id, motivo, relato, criada_em)
  values ('denuncia', v_p2u, v_e1, 'outro', 'O portão é o azul, da Ana', a - interval '5 years' - interval '2 days')
  returning id into v_id;
  insert into ids values ('oc_moderacao', v_id);
  insert into privado.vaga_ocultada (vaga_id, ocorrencia_id, oculta_em)
  values ((select id from ids where chave = 'va'), v_id, a - interval '5 years' - interval '2 days');
  insert into privado.texto_da_vaga_ocultado (vaga_id, ocorrencia_id, oculto_em, responsavel_local, traje, observacoes)
  values ((select id from ids where chave = 'va'), v_id, a - interval '5 years' - interval '2 days',
          'Ana Original', 'Preto', 'Casa 12, portão azul');

  -- Cancelamento ligado ao turno antigo de PA3 (a #429 desliga; R6 anonimiza na mesma rodada).
  insert into public.ocorrencia (tipo, turno_id, posicao_id, autor_id, motivo, criada_em)
  values ('cancelamento', (select id from ids where chave = 'ta3'), (select id from ids where chave = 'pa3'),
          v_p2u, 'no_show_sem_checkin', v_fim)
  returning id into v_id;
  insert into ids values ('oc_canc_va', v_id);

  -- VA2: conta anonimizada, vaga antiga sem turno nenhum.
  v_fim := a - interval '5 years' - interval '5 days';
  execute v_vaga_sql into v_id
    using v_e1, v_funcao, v_fim, 'Chácara do Zé', 'Zé', 'Branco', 'Entrar pela porteira', v_c2;
  insert into ids values ('va2', v_id);
  insert into public.posicao (vaga_id, inicio_em, fim_em, estado)
  values (v_id, v_fim - interval '6 hours', v_fim, 'aberta');
  insert into public.despacho (vaga_id, profissional_id, criado_em)
  values (v_id, v_p2, v_fim - interval '4 days');

  -- VB: conta ativa, uma posição antiga com turno e outra recente. Nada da vaga muda.
  v_fim := a - interval '5 years' - interval '3 days';
  execute v_vaga_sql into v_id
    using v_e1, v_funcao, v_fim, 'Rua Mista, 2', 'Bruno', 'Azul', 'Bloco B', v_c1;
  insert into ids values ('vb', v_id);
  insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em)
  values (v_id, v_p1, v_fim - interval '6 hours', v_fim, 'cumprida', v_fim - interval '2 days')
  returning id into v_id;
  insert into ids values ('pb1', v_id);
  insert into public.turno (posicao_id, valor_acordado_centavos, checkin_em, checkin_tipo, checkin_distancia_m, verificacao)
  values (v_id, 15000, v_fim - interval '6 hours', 'geolocalizado', 40, 'verificado') returning id into v_id;
  insert into ids values ('tb1', v_id);
  insert into public.posicao (vaga_id, inicio_em, fim_em, estado)
  values ((select id from ids where chave = 'vb'), a - interval '10 days' - interval '6 hours', a - interval '10 days', 'aberta')
  returning id into v_id;
  insert into ids values ('pb2', v_id);
  insert into public.despacho (vaga_id, profissional_id, criado_em)
  values ((select id from ids where chave = 'vb'), v_p2, v_fim - interval '4 days');
  insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, estado,
                              expira_em, respondida_em, criada_em, chave)
  values ((select id from ids where chave = 'vb'), v_p2, v_e1, v_c1, 'aceita',
          v_fim - interval '5 days', v_fim - interval '9 days', v_fim - interval '10 days', gen_random_uuid());

  -- VB2: conta anonimizada, uma posição antiga e outra recente. Nada da vaga muda.
  v_fim := a - interval '5 years' - interval '4 days';
  execute v_vaga_sql into v_id
    using v_e1, v_funcao, v_fim, 'Estrada do Sítio, 3', 'Carla', 'Verde', 'Sítio da Carla', v_c2;
  insert into ids values ('vb2', v_id);
  insert into public.posicao (vaga_id, inicio_em, fim_em, estado)
  values (v_id, v_fim - interval '6 hours', v_fim, 'aberta'),
         (v_id, a - interval '9 days' - interval '6 hours', a - interval '9 days', 'aberta');
  insert into public.despacho (vaga_id, profissional_id, criado_em)
  values (v_id, v_p1, v_fim - interval '4 days');

  -- VF: terminou há 2 anos. Serve ao piso de 5 anos.
  v_fim := a - interval '2 years';
  execute v_vaga_sql into v_id
    using v_e1, v_funcao, v_fim, 'Rua Recente, 5', 'Duda', 'Cinza', 'Recente de 2 anos', v_c1;
  insert into ids values ('vf', v_id);
  insert into public.posicao (vaga_id, inicio_em, fim_em, estado)
  values (v_id, v_fim - interval '6 hours', v_fim, 'aberta');

  -- VC3: conta anonimizada há 20 dias, vaga antiga com turno verificado de P1. As duas rotinas
  -- agem nela: limpar_contas_anonimizadas no texto livre e esta no resto.
  v_fim := a - interval '5 years' - interval '6 days';
  execute v_vaga_sql into v_id
    using v_e1, v_funcao, v_fim, 'Rua da Conta Encerrada, 7', 'Elisa', 'Bege', 'Casa da Elisa', v_c3;
  insert into ids values ('vc3', v_id);
  insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em)
  values (v_id, v_p1, v_fim - interval '6 hours', v_fim, 'cumprida', v_fim - interval '2 days')
  returning id into v_id;
  insert into public.turno (posicao_id, valor_acordado_centavos, checkin_em, checkin_tipo, checkin_distancia_m, verificacao)
  values (v_id, 15000, v_fim - interval '6 hours', 'geolocalizado', 40, 'verificado');
  insert into public.despacho (vaga_id, profissional_id, criado_em)
  values ((select id from ids where chave = 'vc3'), v_p2, v_fim - interval '4 days');
  insert into public.ocorrencia (tipo, autor_id, estabelecimento_id, motivo, relato, criada_em)
  values ('denuncia', v_c3, v_e1, 'outro', 'Relato da conta encerrada', a - interval '5 years' - interval '1 day')
  returning id into v_id;
  insert into ids values ('oc_c3', v_id);

  -- Ocorrências de R6.
  insert into public.ocorrencia (tipo, autor_id, usuario_id, motivo, relato, criada_em)
  values ('denuncia', v_p2u, v_c1, 'assedio', 'Relato com nome e telefone', a - interval '5 years' - interval '1 day')
  returning id into v_id;
  insert into ids values ('od_5a1d', v_id);
  insert into public.ocorrencia (tipo, autor_id, usuario_id, motivo, relato, criada_em)
  values ('denuncia', v_p2u, v_c1, 'assedio', 'Relato ainda no prazo', a - interval '5 years' + interval '1 day')
  returning id into v_id;
  insert into ids values ('od_4a364d', v_id);
  insert into public.ocorrencia (tipo, posicao_id, autor_id, motivo, criada_em)
  values ('cancelamento', (select id from ids where chave = 'pb2'), v_c1, 'Mudança de planos da casa',
          a - interval '5 years' - interval '1 day')
  returning id into v_id;
  insert into ids values ('od_ligada_recente', v_id);
  insert into public.ocorrencia (tipo, autor_id, usuario_id, motivo, relato, criada_em)
  values ('suspensao', v_c1, v_p2u, 'Suspensão de teste', 'Relato da suspensão', a - interval '5 years' - interval '1 day')
  returning id into v_id;
  insert into ids values ('od_suspensao', v_id);
  insert into public.ocorrencia (tipo, autor_id, usuario_id, motivo, relato, criada_em)
  values ('denuncia', v_p2u, v_c1, '[removido por exclusão de conta]', null, a - interval '5 years' - interval '1 day')
  returning id into v_id;
  insert into ids values ('od_ja_excluida', v_id);
  insert into public.ocorrencia (tipo, autor_id, usuario_id, motivo, relato, criada_em)
  values ('denuncia', v_p2u, v_c1, 'outro', 'Relato de 2 anos', a - interval '2 years')
  returning id into v_id;
  insert into ids values ('od_2a', v_id);

  -- Marcas de R8.
  insert into privado.marca_notificacao (tipo, referencia_id, usuario_id, rodada, criada_em)
  values ('lembrete_24h', (select id from ids where chave = 'ta1'), v_p1u, 1, a - interval '5 years' - interval '2 days'),
         ('vaga', (select id from ids where chave = 'vf'), v_p1u, 1, a - interval '2 years' - interval '3 days'),
         ('lembrete_3h', '82100000-0000-4000-8000-000000000003', v_p1u, 1, a - interval '1 day'),
         ('vaga_vazia', (select id from ids where chave = 'pb2'), v_c1, 1, a - interval '10 days'),
         -- A vaga não é apagada, então a marca dela nunca fica órfã: só o prazo a tira.
         ('vaga', (select id from ids where chave = 'va'), v_p1u, 1, a - interval '5 years' - interval '1 day'),
         ('vaga', (select id from ids where chave = 'vb'), v_p1u, 1, a - interval '5 years' + interval '1 day');
end $$;

-- Contadores de reputação antes do expurgo (R9).
create temp table reputacao_antes as
select id, turnos_realizados, taxa_comparecimento, aval_positivas, aval_total
  from public.profissional
 where id in (select id from ids where chave in ('p1', 'p2'));

-- Retrato das vagas que não podem mudar.
create temp table vagas_intactas as
select id, local, responsavel_local, observacoes, traje, ponto::text as ponto
  from public.vaga
 where id in (select id from ids where chave in ('vb', 'vb2', 'vf'));

select ok(
  (select count(*) from privado.auditoria_ciclo
    where entidade_id in (select id from ids where chave in ('va', 'cand_pa1_p1', 'cand_pa1_p2', 'cand_pa2_p2',
                                                             'aval_ta1', 'pa2', 'od_5a1d'))) >= 7,
  'cenário: os gatilhos de auditoria gravaram a trilha que o expurgo precisa apagar');

-- ── 3. A rotina diária ────────────────────────────────────────────────────────

select lives_ok(
  $$ create temp table r_exec as select privado.executar_retencao_diaria() as res $$,
  'executar_retencao_diaria roda inteira, mesmo com posição reaberta apontando para a original expurgada');

-- VA, conta ativa
select is((select local from public.vaga where id = (select id from ids where chave = 'va')),
  'Expurgado (LGPD)', 'R1: local da vaga expirada vira o marcador');
select is((select responsavel_local from public.vaga where id = (select id from ids where chave = 'va')),
  'Expurgado (LGPD)', 'R1: responsavel_local da vaga expirada vira o marcador');
select is((select extensions.st_astext(ponto) from public.vaga where id = (select id from ids where chave = 'va')),
  'POINT(-47.8825 -15.7942)', 'R1: ponto da vaga expirada vira o ponto neutro fixo (NOT NULL mantido, RN02)');
select ok((select observacoes is null and traje is null from public.vaga where id = (select id from ids where chave = 'va')),
  'R2: observacoes e traje da vaga expirada viram NULL');
select is((select count(*)::int from public.chamada where vaga_id = (select id from ids where chave = 'va')),
  0, 'R4: a chamada aceita da vaga expirada sai');
select is((select count(*)::int from public.despacho where vaga_id = (select id from ids where chave = 'va')),
  0, 'R5: os despachos da vaga expirada saem (exceção privado.retencao)');
select is((select count(*)::int from privado.vaga_ocultada where vaga_id = (select id from ids where chave = 'va')),
  0, 'R3: a ocultação da vaga expirada sai');
select is((select count(*)::int from privado.texto_da_vaga_ocultado where vaga_id = (select id from ids where chave = 'va')),
  0, 'R3: o texto original guardado pela moderação sai');
select is((select count(*)::int from privado.auditoria_ciclo
            where entidade = 'vaga' and entidade_id = (select id from ids where chave = 'va')),
  0, 'R3/R7: a trilha da vaga expirada sai');
select is((select count(*)::int from privado.auditoria_ciclo
            where (entidade = 'candidatura' and entidade_id in (select id from ids where chave in ('cand_pa1_p1', 'cand_pa1_p2')))
               or (entidade = 'avaliacao' and entidade_id = (select id from ids where chave = 'aval_ta1'))),
  0, 'R7: a trilha da candidatura e da avaliação do turno expurgado sai junto');
select is((select count(*)::int from public.posicao
            where id in (select id from ids where chave in ('pa1', 'pa2', 'pa3', 'pa4'))),
  0, 'Q3: a posição sem turno e a posição reaberta da vaga expirada saem');
select results_eq(
  $$ select vaga_id, profissional_id, falta from public.posicao where id = (select id from ids where chave = 'pa5_falta') $$,
  $$ select (select id from ids where chave = 'va'), (select id from ids where chave = 'p2'), true $$,
  'Q3: a posição com falta e sem turno fica (a reputação lê a falta em posicao)');
select is((select count(*)::int from public.candidatura where id = (select id from ids where chave = 'cand_pa2_p2')),
  0, 'Q3: a candidatura da posição sem turno sai em cascata');
select is((select count(*)::int from privado.auditoria_ciclo
            where (entidade = 'posicao' and entidade_id in (select id from ids where chave in ('pa2', 'pa4')))
               or (entidade = 'candidatura' and entidade_id = (select id from ids where chave = 'cand_pa2_p2'))),
  0, 'Q3: a trilha da posição sem turno e da candidatura dela sai');
select is(
  (select (select count(*) from public.chamada c
            where c.vaga_id = (select id from ids where chave = 'va') and c.profissional_id = (select id from ids where chave = 'p1'))
        + (select count(*) from public.despacho d
            where d.vaga_id = (select id from ids where chave = 'va') and d.profissional_id = (select id from ids where chave = 'p1'))
        + (select count(*) from privado.auditoria_ciclo a
            where a.entidade_id in (select id from ids where chave in ('va', 'pa1', 'ta1', 'cand_pa1_p1', 'aval_ta1'))))::int,
  0,
  'Aceite: nenhuma chamada, despacho ou auditoria_ciclo liga o profissional à vaga do turno expurgado');

-- VA2, conta anonimizada, vaga sem turno nenhum
select results_eq(
  $$ select local, responsavel_local, observacoes, traje, extensions.st_astext(ponto)
       from public.vaga where id = (select id from ids where chave = 'va2') $$,
  $$ values ('Expurgado (LGPD)'::text, 'Expurgado (LGPD)'::text, null::text, null::text, 'POINT(-47.8825 -15.7942)'::text) $$,
  'R1-R3: vaga antiga sem turno de conta anonimizada também é anonimizada');
select is((select count(*)::int from public.despacho where vaga_id = (select id from ids where chave = 'va2'))
        + (select count(*)::int from public.posicao where vaga_id = (select id from ids where chave = 'va2')),
  0, 'R5/Q3: despacho e posição sem turno da vaga antiga de conta anonimizada saem');

-- VB e VB2: uma posição recente, nada da vaga muda
-- E2 do Lince AG 2 (mutante MP): a trava de dentro recusa a vaga com posição recente mesmo
-- quando alguém chama a função direto, sem passar pela seleção de quem a chama.
select is(privado.anonimizar_contexto_das_vagas(array[(select id from ids where chave = 'vb'),
                                                       (select id from ids where chave = 'vb2')]),
  0, 'anonimizar_contexto_das_vagas chamada direto com vaga de posição recente devolve 0');
select results_eq(
  $$ select id, local, responsavel_local, observacoes, traje, ponto::text
       from public.vaga where id in (select id from ids where chave in ('vb', 'vb2', 'vf')) order by id $$,
  $$ select id, local, responsavel_local, observacoes, traje, ponto from vagas_intactas order by id $$,
  'vaga com uma posição recente (conta ativa e anonimizada) e vaga de 2 anos: nenhum campo muda');
select is((select count(*)::int from public.despacho where vaga_id in (select id from ids where chave in ('vb', 'vb2'))),
  2, 'vaga com uma posição recente: os despachos ficam');
select is((select count(*)::int from public.chamada where vaga_id = (select id from ids where chave = 'vb')),
  1, 'vaga com uma posição recente: a chamada aceita fica');
select ok((select count(*) from privado.auditoria_ciclo
            where entidade = 'vaga' and entidade_id in (select id from ids where chave in ('vb', 'vb2'))) >= 2,
  'vaga com uma posição recente: a trilha da vaga fica');
select is((select count(*)::int from public.posicao where vaga_id in (select id from ids where chave in ('vb', 'vb2'))),
  3, 'vaga com uma posição recente: só a posição do turno expurgado sai (a sem turno antiga de VB2 fica com a vaga)');
select is((select count(*)::int from public.turno where id = (select id from ids where chave = 'tb1')),
  0, 'o turno antigo da vaga mista continua expurgado pela #429');

-- R6: ocorrências
select results_eq(
  $$ select motivo, relato, turno_id, posicao_id from public.ocorrencia where id = (select id from ids where chave = 'oc_canc_va') $$,
  $$ values ('Expurgado (LGPD)'::text, null::text, null::uuid, null::uuid) $$,
  'R6: cancelamento do turno expurgado, desligado pela #429, perde o motivo na mesma rodada');
select results_eq(
  $$ select motivo, relato from public.ocorrencia where id = (select id from ids where chave = 'oc_moderacao') $$,
  $$ values ('Expurgado (LGPD)'::text, null::text) $$,
  'R6: denúncia que ocultou a vaga perde motivo e relato');
select results_eq(
  $$ select motivo, relato from public.ocorrencia where id = (select id from ids where chave = 'od_5a1d') $$,
  $$ values ('Expurgado (LGPD)'::text, null::text) $$,
  'R6: denúncia com 5 anos e 1 dia: relato NULL e motivo marcador');
select is((select count(*)::int from privado.auditoria_ciclo
            where entidade = 'ocorrencia' and entidade_id in (select id from ids where chave in ('od_5a1d', 'oc_canc_va', 'oc_moderacao'))),
  0, 'R6/R7: a trilha das ocorrências anonimizadas sai');
select results_eq(
  $$ select motivo, relato from public.ocorrencia where id = (select id from ids where chave = 'od_4a364d') $$,
  $$ values ('assedio'::text, 'Relato ainda no prazo'::text) $$,
  'R6: denúncia com 4 anos e 364 dias fica igual');
select is((select count(*)::int from privado.auditoria_ciclo
            where entidade = 'ocorrencia' and entidade_id = (select id from ids where chave = 'od_4a364d')),
  1, 'R6: a trilha da denúncia com 4 anos e 364 dias fica');
select results_eq(
  $$ select motivo, posicao_id from public.ocorrencia where id = (select id from ids where chave = 'od_ligada_recente') $$,
  $$ select 'Mudança de planos da casa'::text, (select id from ids where chave = 'pb2') $$,
  'R6: ocorrência antiga ligada a posição ainda nos 5 anos espera essa posição');
select results_eq(
  $$ select motivo, relato from public.ocorrencia where id = (select id from ids where chave = 'od_suspensao') $$,
  $$ values ('Suspensão de teste'::text, 'Relato da suspensão'::text) $$,
  'R6 vale só para denúncia e cancelamento: a suspensão antiga fica igual');
select results_eq(
  $$ select motivo, relato from public.ocorrencia where id = (select id from ids where chave = 'od_ja_excluida') $$,
  $$ values ('[removido por exclusão de conta]'::text, null::text) $$,
  'R6: ocorrência já limpa pela exclusão de conta mantém o marcador dela (sem disputa com limpar_contas_anonimizadas)');
select is((select count(*)::int from privado.auditoria_ciclo
            where entidade = 'ocorrencia' and entidade_id = (select id from ids where chave = 'od_ja_excluida')),
  0, 'R6: a trilha da ocorrência já limpa pela exclusão também sai aos 5 anos');

-- R8: marcas
select is((select count(*)::int from privado.marca_notificacao
            where referencia_id = (select id from ids where chave = 'ta1')),
  0, 'R8: marca com mais de 5 anos (do turno expurgado) sai');
select is((select count(*)::int from privado.marca_notificacao
            where referencia_id = '82100000-0000-4000-8000-000000000003'),
  0, 'R8: marca órfã sai, mesmo recente');
select is((select count(*)::int from privado.marca_notificacao
            where referencia_id in (select id from ids where chave in ('vf', 'pb2'))),
  2, 'R8: marca recente de vaga e de posição que existem fica');
select is((select count(*)::int from privado.marca_notificacao
            where tipo = 'vaga' and referencia_id = (select id from ids where chave = 'va')),
  0, 'R8: marca com 5 anos e 1 dia sai pelo prazo, mesmo com a vaga existindo (não é órfã)');
select is((select count(*)::int from privado.marca_notificacao
            where tipo = 'vaga' and referencia_id = (select id from ids where chave = 'vb')),
  1, 'R8: marca com 4 anos e 364 dias de vaga que existe fica');

-- Conta anonimizada há 20 dias: limpar_contas_anonimizadas (que roda antes, na mesma rotina)
-- apaga o texto livre com o marcador dela e deixa o local, que o turno verificado ainda
-- segurava; o expurgo do turno tira o turno e anonimiza o resto com o marcador do expurgo.
select results_eq(
  $$ select local, responsavel_local, observacoes, traje, extensions.st_astext(ponto)
       from public.vaga where id = (select id from ids where chave = 'vc3') $$,
  $$ values ('Expurgado (LGPD)'::text, '[removido por exclusão de conta]'::text, null::text, null::text,
             'POINT(-47.8825 -15.7942)'::text) $$,
  'conta anonimizada há 20 dias: cada rotina deixa o seu marcador na vaga expirada, na mesma rodada');
select is((select count(*)::int from public.despacho where vaga_id = (select id from ids where chave = 'vc3'))
        + (select count(*)::int from public.posicao where vaga_id = (select id from ids where chave = 'vc3')),
  0, 'conta anonimizada há 20 dias: despacho e posição da vaga expirada saem');

-- R9: contadores de reputação
select results_eq(
  $$ select id, turnos_realizados, taxa_comparecimento, aval_positivas, aval_total
       from public.profissional where id in (select id from ids where chave in ('p1', 'p2')) order by id $$,
  $$ select id, turnos_realizados, taxa_comparecimento, aval_positivas, aval_total from reputacao_antes order by id $$,
  'R9: os contadores de reputação dos dois profissionais são os mesmos antes e depois do expurgo');

-- ── 4. Idempotência, piso e lote ──────────────────────────────────────────────

select is(privado.expurgar_vagas_antigas(), 0, 'segunda execução: nenhuma vaga para refazer');
select is(privado.anonimizar_ocorrencias_antigas(), 0, 'segunda execução: nenhuma ocorrência para refazer');
select is(privado.limpar_marcas_notificacao(), 0, 'segunda execução: nenhuma marca para refazer');
-- VA sai pelo expurgo de turnos (a vaga do lote); expurgar_vagas_antigas conta a VA2, sem turno.
select ok(
  (select (res->>'expurgo_vagas_antigas')::int >= 1
      and (res->>'anonimizacao_ocorrencias_antigas')::int >= 4
      and (res->>'expurgo_marcas_notificacao')::int >= 2
     from r_exec),
  'executar_retencao_diaria devolve as três contagens novas no jsonb');

select is(privado.expurgar_vagas_antigas(1, 500), 0, 'piso: p_anos = 1 não alcança a vaga de 2 anos');
select is(privado.expurgar_vagas_antigas(0, 500), 0, 'piso: p_anos = 0 não alcança a vaga de 2 anos');
select is(privado.expurgar_vagas_antigas(null, null), 0, 'piso: p_anos nulo vale 5 anos');
select is(privado.anonimizar_ocorrencias_antigas(1, 500), 0, 'piso: p_anos = 1 não alcança a denúncia de 2 anos');
select is(privado.anonimizar_ocorrencias_antigas(-3, 500), 0, 'piso: p_anos negativo vale 5 anos');
select is(privado.limpar_marcas_notificacao(1, 1000), 0, 'piso: p_anos = 1 não alcança a marca de 2 anos');
select results_eq(
  $$ select observacoes from public.vaga where id = (select id from ids where chave = 'vf') $$,
  $$ values ('Recente de 2 anos'::text) $$,
  'piso: a vaga de 2 anos continua com o texto dela');
select results_eq(
  $$ select motivo, relato from public.ocorrencia where id = (select id from ids where chave = 'od_2a') $$,
  $$ values ('outro'::text, 'Relato de 2 anos'::text) $$,
  'piso: a denúncia de 2 anos continua com motivo e relato');
select is((select count(*)::int from privado.marca_notificacao
            where referencia_id = (select id from ids where chave = 'vf')),
  1, 'piso: a marca de 2 anos continua');

-- Lote limitado: duas vagas antigas, lote de 1, uma por vez e na ordem do fim.
do $$
declare
  a timestamptz := privado.agora();
  v_id uuid;
  i int;
begin
  for i in 1..2 loop
    insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
      valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
      responsavel_local, observacoes, modo, estado, chave_cliente, publicado_por)
    values ((select id from ids where chave = 'e1'), (select id from public.funcao order by id limit 1),
      a - interval '5 years' - make_interval(days => 30 - i) - interval '6 hours',
      a - interval '5 years' - make_interval(days => 30 - i),
      'Lote ' || i, 'POINT(-47.9100 -15.8300)'::extensions.geography, 15000, 1, false, false, false,
      'Lote ' || i, 'Lote ' || i, 'urgencia', 'encerrada', gen_random_uuid(), (select id from ids where chave = 'c1'))
    returning id into v_id;
    insert into ids values ('lote' || i, v_id);
  end loop;
end $$;

select is(privado.expurgar_vagas_antigas(5, 1), 1, 'lote: p_limite = 1 anonimiza exatamente uma vaga');
select results_eq(
  $$ select (select local from public.vaga where id = (select id from ids where chave = 'lote1')),
            (select local from public.vaga where id = (select id from ids where chave = 'lote2')) $$,
  $$ values ('Expurgado (LGPD)'::text, 'Lote 2'::text) $$,
  'lote: a vaga que terminou antes vai primeiro e a outra espera a próxima rodada');
select is(privado.expurgar_vagas_antigas(5, 1), 1, 'lote: a rodada seguinte pega a vaga que faltava');
select is(privado.expurgar_vagas_antigas(5, 1), 0, 'lote: depois disso não sobra nada');

-- ── 5. Rodadas seguintes: a exclusão de conta e o expurgo não se desfazem ─────
--
-- E1 do Lince AG 2 (mutante MV), com a conta VC3 anonimizada há 20 dias: a rodada 1 é a do
-- bloco 3; aqui vêm a 2 e a 3, no mesmo dia. O estado final de cada rodada seria o mesmo
-- mesmo se as duas rotinas brigassem (uma reescreve, a outra desfaz, na mesma rodada). Por
-- isso a prova são as contagens de cada rotina e o ctid: qualquer UPDATE gera uma versão nova
-- da linha, e nenhuma outra rotina da retenção diária escreve em vaga ou ocorrência.

create temp table rodada_2 as select privado.executar_retencao_diaria() as res;

select results_eq(
  $$ select local, responsavel_local, observacoes, traje, extensions.st_astext(ponto)
       from public.vaga where id = (select id from ids where chave = 'vc3') $$,
  $$ values ('[removido por exclusão de conta]'::text, '[removido por exclusão de conta]'::text, null::text, null::text,
             'POINT(-47.8825 -15.7942)'::text) $$,
  'rodada 2: limpar_contas_anonimizadas põe o marcador dela no local (o turno verificado saiu) e o expurgo não desfaz');
select is((select (res->>'expurgo_vagas_antigas')::int from rodada_2), 0,
  'rodada 2: expurgar_vagas_antigas não refaz a vaga que a exclusão de conta remarcou');
select is((select (res->>'anonimizacao_ocorrencias_antigas')::int from rodada_2), 0,
  'rodada 2: nenhuma ocorrência refeita');

create temp table linhas_rodada_2 as
select (select ctid::text from public.vaga where id = (select id from ids where chave = 'vc3')) as vaga_ctid,
       (select ctid::text from public.ocorrencia where id = (select id from ids where chave = 'oc_c3')) as ocorrencia_ctid;

create temp table rodada_3 as select privado.executar_retencao_diaria() as res;

select results_eq(
  $$ select (select ctid::text from public.vaga where id = (select id from ids where chave = 'vc3')),
            (select ctid::text from public.ocorrencia where id = (select id from ids where chave = 'oc_c3')) $$,
  $$ select vaga_ctid, ocorrencia_ctid from linhas_rodada_2 $$,
  'rodada 3: nenhuma das duas rotinas reescreve a vaga nem a ocorrência (ctid igual)');
select is((select (res->>'contas_anonimizadas_limpas')::int from rodada_3), 0,
  'rodada 3: limpar_contas_anonimizadas não refaz nada');
select is((select (res->>'expurgo_vagas_antigas')::int from rodada_3), 0,
  'rodada 3: expurgar_vagas_antigas não refaz nada');
select is((select (res->>'anonimizacao_ocorrencias_antigas')::int from rodada_3), 0,
  'rodada 3: nenhuma ocorrência refeita');
select results_eq(
  $$ select o.motivo, o.relato,
            (select count(*)::int from privado.auditoria_ciclo a where a.entidade = 'ocorrencia' and a.entidade_id = o.id)
       from public.ocorrencia o where o.id = (select id from ids where chave = 'oc_c3') $$,
  $$ values ('[removido por exclusão de conta]'::text, null::text, 0) $$,
  'conta anonimizada: a denúncia antiga fica com o marcador da exclusão, sem relato e sem trilha');

-- ── 6. R9 garantido: a reconciliação diária preserva a reputação expurgada ──

-- Em comando separado: no mesmo comando, a leitura usaria o retrato de antes da reconciliação.
do $$ begin perform privado.reconciliar_comparecimento(); end $$;

select results_eq(
  $$ select p.id, p.turnos_realizados, p.taxa_comparecimento, p.aval_positivas, p.aval_total
       from public.profissional p
      where p.id in (select id from ids where chave in ('p1', 'p2')) order by p.id $$,
  $$ select id, turnos_realizados, taxa_comparecimento, aval_positivas, aval_total from reputacao_antes order by id $$,
  'R9 depois da reconciliação diária: os contadores deveriam ser os mesmos de antes do expurgo');

select * from finish();
rollback;
