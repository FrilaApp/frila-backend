-- Teste pgTAP guarda-chuva: Prova que verificar_saude() contém INTEGRALMENTE todos os 13 blocos de monitoramento operacional
-- Se qualquer refatoração futura sobrescrever verificar_saude() e omitir qualquer um dos blocos, este teste reprova na CI.
--
-- Blocos vigiados:
-- 1.  job_despacho_parado
-- 2.  fila_despacho_antiga
-- 3.  fila_email_antiga
-- 4.  job_cron_falhou
-- 5.  notificacao_push_falhou
-- 6.  fcm_configuracao_suspeita
-- 7.  despacho_esperando_alem_do_teto
-- 8.  falha_execucao_edge_function
-- 9.  moderacao_vencida
-- 10. contestacao_vencida
-- 11. pgnet_falha_transporte
-- 12. pgnet_resposta_recusada
-- 13. demonstracao_sob_ataque

begin;
select plan(13);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- Relógio congelado e segredo para triggers de despacho
select set_config('frila.agora', '2026-10-18 14:00:00-03', true);
select set_config('frila.agendador_secret', 'segredo-de-teste-746', true);

-- Limpa estado de alertas emitidos
delete from privado.alerta_emitido;

-- ── 1. Bloco 1: job_despacho_parado ───────────────────────────────────────────
do $$ begin
  perform cron.unschedule('reprocessar_despacho');
end $$;
delete from privado.alerta_emitido where codigo = 'job_despacho_parado';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'job_despacho_parado'),
  1,
  'Bloco 1 presente: job_despacho_parado emite alerta quando cron está inativo'
);
do $$ begin
  perform cron.schedule('reprocessar_despacho', '* * * * *', 'select privado.processar_fila_despacho()');
end $$;

-- ── 2. Bloco 2: fila_despacho_antiga ───────────────────────────────────────────
delete from pgmq.q_despacho;
insert into pgmq.q_despacho (enqueued_at, vt, message)
values (privado.agora() - interval '20 minutes', privado.agora(), '{"vaga_id":"00000000-0000-0000-0000-000000000001"}'::jsonb);
delete from privado.alerta_emitido where codigo = 'fila_despacho_antiga';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'fila_despacho_antiga'),
  1,
  'Bloco 2 presente: fila_despacho_antiga emite alerta para mensagem com mais de 15 min'
);
delete from pgmq.q_despacho;

-- ── 3. Bloco 3: fila_email_antiga ──────────────────────────────────────────────
delete from pgmq.q_email;
insert into pgmq.q_email (enqueued_at, vt, message)
values (privado.agora() - interval '20 minutes', privado.agora(), '{"tipo":"alerta"}'::jsonb);
delete from privado.alerta_emitido where codigo = 'fila_email_antiga';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'fila_email_antiga'),
  1,
  'Bloco 3 presente: fila_email_antiga emite alerta para mensagem com mais de 15 min'
);
delete from pgmq.q_email;

-- ── 4. Bloco 4: job_cron_falhou ────────────────────────────────────────────────
delete from cron.job_run_details;
insert into cron.job_run_details (jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time)
values (1, 990003, 1234, 'postgres', 'postgres', 'select 1;', 'failed', 'erro simulado', privado.agora() - interval '5 minutes', privado.agora() - interval '4 minutes');
delete from privado.alerta_emitido where codigo = 'job_cron_falhou';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'job_cron_falhou'),
  1,
  'Bloco 4 presente: job_cron_falhou emite alerta quando job falha nos últimos 15 min'
);
delete from cron.job_run_details;

-- ── 5. Bloco 5: notificacao_push_falhou ─────────────────────────────────────────
-- Escopado ao usuário de fixture deste bloco, e não a tabela inteira: um
-- `delete from public.notificacao` sem filtro quebra com FK
-- (despacho_notificacao_id_fkey) quando já existe notificação real ligada a um
-- despacho — exatamente o que os scripts de corrida e `ciclo-completo.sh` deixam no
-- banco antes deste arquivo rodar na CI. Medido no PR #310 (cartão `5boVdM0t`):
-- `supabase test db` sozinho (banco limpo) passa; rodado de novo depois de
-- corrida-ciclo.sh/corrida-push.sh/ciclo-completo.sh, este bloco falha com
-- "update or delete on table notificacao violates foreign key constraint
-- despacho_notificacao_id_fkey". O alerta não perde cobertura por restringir ao
-- próprio usuário de fixture: `privado.alerta_emitido` é único por `codigo` (teto de
-- 1/hora em `privado.emitir_alerta`), então uma notificação real e falha por acaso
-- dentro da mesma hora ainda deixaria a asserção abaixo em 1, não mais.
delete from public.notificacao where usuario_id = '74600000-0000-4000-8000-000000000001';
insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em)
values ('74600000-0000-4000-8000-000000000001', 'Usuário Push Falha', 'pushfalha@test.local', '+5561911117462', 'profissional', 'ativa', '1995-01-01', '1.0', now())
on conflict (id) do nothing;

insert into public.notificacao (usuario_id, tipo, referencia_id, estado_entrega, motivo_falha, enviada_em)
values ('74600000-0000-4000-8000-000000000001', 'confirmacao', gen_random_uuid(), 'falhou', 'FAILED_PRECONDITION', privado.agora() - interval '30 minutes');
delete from privado.alerta_emitido where codigo = 'notificacao_push_falhou';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'notificacao_push_falhou'),
  1,
  'Bloco 5 presente: notificacao_push_falhou emite alerta para push com falha na última hora'
);
delete from public.notificacao where usuario_id = '74600000-0000-4000-8000-000000000001';

-- ── 6. Bloco 6: fcm_configuracao_suspeita ──────────────────────────────────────
-- Mesmo escopo do bloco 5, pelo mesmo motivo (FK despacho_notificacao_id_fkey).
delete from public.notificacao where usuario_id = '74600000-0000-4000-8000-000000000002';
insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em)
values ('74600000-0000-4000-8000-000000000002', 'Usuário FCM NOT_FOUND', 'fcmfalha@test.local', '+5561911117463', 'profissional', 'ativa', '1995-01-01', '1.0', now())
on conflict (id) do nothing;

insert into public.notificacao (usuario_id, tipo, referencia_id, estado_entrega, motivo_falha, enviada_em)
values ('74600000-0000-4000-8000-000000000002', 'confirmacao', gen_random_uuid(), 'falhou', 'NOT_FOUND', privado.agora() - interval '5 minutes');
delete from privado.alerta_emitido where codigo = 'fcm_configuracao_suspeita';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'fcm_configuracao_suspeita'),
  1,
  'Bloco 6 presente: fcm_configuracao_suspeita emite alerta para motivo NOT_FOUND nos últimos 15 min'
);
delete from public.notificacao where usuario_id = '74600000-0000-4000-8000-000000000002';

-- ── 7. Bloco 7: despacho_esperando_alem_do_teto ────────────────────────────────
do $$
declare
  v_dono      uuid := gen_random_uuid();
  v_estab     uuid := gen_random_uuid();
  v_prof_user uuid := gen_random_uuid();
  v_prof_id   uuid := gen_random_uuid();
  v_func      uuid;
  v_vaga      uuid := gen_random_uuid();
begin
  select id into v_func from public.funcao limit 1;
  insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em)
  values 
    (v_dono, 'Dono Despacho', 'dono_despacho@test.local', '+5561911117461', 'contratante', 'ativa', '1985-01-01', '1.0', now()),
    (v_prof_user, 'Prof Despacho', 'prof_despacho@test.local', '+5561911117467', 'profissional', 'ativa', '1995-01-01', '1.0', now());

  insert into public.profissional (id, usuario_id, ponto_base)
  values (v_prof_id, v_prof_user, 'POINT(-47.88 -15.79)'::extensions.geography);

  insert into public.estabelecimento (id, nome, documento, endereco, ponto, tipo)
  values (v_estab, 'Bar Despacho', '11222333000199', 'Rua D', 'POINT(-47.88 -15.79)'::extensions.geography, 'food_service');
  insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
  values (v_estab, v_dono, 'administrador');

  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_por, estado)
  values (v_vaga, v_estab, v_func, privado.agora() + interval '5 hours', privado.agora() + interval '10 hours', 'Local', 'POINT(-47.88 -15.79)'::extensions.geography, 15000, 1, false, false, false, 'Gerente', 'urgencia', gen_random_uuid(), v_dono, 'publicada');

  insert into public.despacho (vaga_id, profissional_id, rodada, notificacao_id, criado_em)
  values (v_vaga, v_prof_id, 1, null, privado.agora() - interval '50 minutes');
end $$;

delete from privado.alerta_emitido where codigo = 'despacho_esperando_alem_do_teto';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'despacho_esperando_alem_do_teto'),
  1,
  'Bloco 7 presente: despacho_esperando_alem_do_teto emite alerta para despachos além da janela'
);
update public.vaga set estado = 'cancelada' where publicado_por in (select id from public.usuario where email = 'dono_despacho@test.local');

-- ── 8. Bloco 8: falha_execucao_edge_function ───────────────────────────────────
delete from privado.falha_execucao;
insert into privado.falha_execucao (origem, codigo, detalhes, criada_em)
values ('enviar-email', 'falha_smtp', '{"erro":"timeout"}'::jsonb, privado.agora() - interval '5 minutes');
delete from privado.alerta_emitido where codigo = 'falha_execucao_edge_function';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'falha_execucao_edge_function'),
  1,
  'Bloco 8 presente: falha_execucao_edge_function emite alerta para falhas nos últimos 15 min'
);
delete from privado.falha_execucao;

-- ── 9. Bloco 9: moderacao_vencida ──────────────────────────────────────────────
update public.ocorrencia set resolvido_em = now() where tipo = 'denuncia' and resolvido_em is null;
do $$
declare
  v_autor uuid := gen_random_uuid();
  v_alvo  uuid := gen_random_uuid();
begin
  insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em)
  values 
    (v_autor, 'Autor Denuncia', 'autor_denuncia@test.local', '+5561911117464', 'profissional', 'ativa', '1995-01-01', '1.0', now()),
    (v_alvo,  'Alvo Denuncia',  'alvo_denuncia@test.local',  '+5561911117465', 'profissional', 'ativa', '1995-01-01', '1.0', now());

  insert into public.ocorrencia (tipo, autor_id, usuario_id, motivo, origem, criada_em, resolvido_em)
  values ('denuncia', v_autor, v_alvo, 'assedio', 'app', privado.agora() - interval '25 hours', null);
end $$;

delete from privado.alerta_emitido where codigo = 'moderacao_vencida';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'moderacao_vencida'),
  1,
  'Bloco 9 presente: moderacao_vencida emite alerta para denúncias abertas há mais de 24h'
);
update public.ocorrencia set resolvido_em = now() where tipo = 'denuncia' and resolvido_em is null;

-- ── 10. Bloco 10: contestacao_vencida ──────────────────────────────────────────
update public.ocorrencia set resolvido_em = now() where tipo = 'contestacao' and resolvido_em is null;
do $$
declare
  v_suspenso uuid := gen_random_uuid();
begin
  insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em)
  values (v_suspenso, 'Autor Contestacao', 'autor_contestacao@test.local', '+5561911117466', 'profissional', 'suspensa', '1995-01-01', '1.0', now());

  insert into public.ocorrencia (tipo, autor_id, motivo, relato, origem, criada_em, resolvido_em)
  values ('contestacao', v_suspenso, 'contestacao_suspensao', 'Relato', 'app', privado.agora() - interval '14 days', null);
end $$;

delete from privado.alerta_emitido where codigo = 'contestacao_vencida';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'contestacao_vencida'),
  1,
  'Bloco 10 presente: contestacao_vencida emite alerta para contestações abertas além de 5 dias úteis'
);
update public.ocorrencia set resolvido_em = now() where tipo = 'contestacao' and resolvido_em is null;

-- ── 11. Bloco 11: pgnet_falha_transporte ───────────────────────────────────────
delete from net._http_response;
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values 
  (990011, null, null, null, null, true, null, privado.agora() - interval '5 minutes'),
  (990012, null, null, null, null, true, null, privado.agora() - interval '4 minutes'),
  (990013, 502, 'text/html', '{}'::jsonb, 'Bad Gateway', false, null, privado.agora() - interval '3 minutes');

delete from privado.alerta_emitido where codigo = 'pgnet_falha_transporte';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_falha_transporte'),
  1,
  'Bloco 11 presente: pgnet_falha_transporte emite alerta para >= 3 falhas assíncronas na janela'
);
delete from net._http_response;

-- ── 12. Bloco 12: pgnet_resposta_recusada ──────────────────────────────────────
delete from net._http_response;
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values (990014, 401, 'application/json', '{}'::jsonb, '{"code":401}', false, null, privado.agora() - interval '2 minutes');

delete from privado.alerta_emitido where codigo = 'pgnet_resposta_recusada';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_resposta_recusada'),
  1,
  'Bloco 12 presente: pgnet_resposta_recusada emite alerta para resposta 401/403/404 na janela'
);
delete from net._http_response;

-- ── 13. Bloco 13: demonstracao_sob_ataque ──────────────────────────────────────
delete from public.entrada_demonstracao;
insert into public.entrada_demonstracao (email, aceita, em)
select 'demo@test.local', false, privado.agora() - (g || ' minutes')::interval
  from generate_series(1, 10) as g;

delete from privado.alerta_emitido where codigo = 'demonstracao_sob_ataque';
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'demonstracao_sob_ataque'),
  1,
  'Bloco 13 presente: demonstracao_sob_ataque emite alerta para >= 10 tentativas recusadas na janela'
);
delete from public.entrada_demonstracao;

select * from finish();
rollback;
