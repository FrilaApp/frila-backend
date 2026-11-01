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
select set_config('privado.retencao', 'on', true);

-- Limpeza preventiva completa do estado residual de execuções anteriores (demonstracao.sh, ciclo-completo.sh, etc.)
delete from public.entrada_demonstracao;
delete from privado.alerta_emitido;
delete from pgmq.q_despacho;
delete from pgmq.q_email;
delete from cron.job_run_details;
delete from public.notificacao where usuario_id in ('74600000-0000-4000-8000-000000000001', '74600000-0000-4000-8000-000000000002');
delete from privado.falha_execucao;
delete from net._http_response;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
update public.ocorrencia set resolvido_em = now() where resolvido_em is null;

-- ── 1. Bloco 1: job_despacho_parado ───────────────────────────────────────────
do $$ begin
  perform cron.unschedule('reprocessar_despacho');
end $$;
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from privado.alerta_emitido;
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'job_despacho_parado'),
  1,
  'Bloco 1 presente: job_despacho_parado emite alerta quando cron está inativo'
);
do $$ begin
  perform cron.schedule('reprocessar_despacho', '* * * * *', 'select privado.processar_fila_despacho()');
end $$;
delete from privado.alerta_emitido;

-- ── 2. Bloco 2: fila_despacho_antiga ───────────────────────────────────────────
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from pgmq.q_despacho;
delete from privado.alerta_emitido;
insert into pgmq.q_despacho (enqueued_at, vt, message)
values (privado.agora() - interval '20 minutes', privado.agora(), '{"vaga_id":"00000000-0000-0000-0000-000000000001"}'::jsonb);
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'fila_despacho_antiga'),
  1,
  'Bloco 2 presente: fila_despacho_antiga emite alerta para mensagem com mais de 15 min'
);
delete from pgmq.q_despacho;
delete from privado.alerta_emitido;

-- ── 3. Bloco 3: fila_email_antiga ──────────────────────────────────────────────
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from pgmq.q_email;
delete from privado.alerta_emitido;
insert into pgmq.q_email (enqueued_at, vt, message)
values (privado.agora() - interval '20 minutes', privado.agora(), '{"tipo":"alerta"}'::jsonb);
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'fila_email_antiga'),
  1,
  'Bloco 3 presente: fila_email_antiga emite alerta para mensagem com mais de 15 min'
);
delete from pgmq.q_email;
delete from privado.alerta_emitido;

-- ── 4. Bloco 4: job_cron_falhou ────────────────────────────────────────────────
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from cron.job_run_details;
delete from privado.alerta_emitido;
insert into cron.job_run_details (jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time)
values (1, 990003, 1234, 'postgres', 'postgres', 'select 1;', 'failed', 'erro simulado', privado.agora() - interval '5 minutes', privado.agora() - interval '4 minutes');
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'job_cron_falhou'),
  1,
  'Bloco 4 presente: job_cron_falhou emite alerta quando job falha nos últimos 15 min'
);
delete from cron.job_run_details;
delete from privado.alerta_emitido;

-- ── 5. Bloco 5: notificacao_push_falhou ─────────────────────────────────────────
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from public.notificacao where usuario_id = '74600000-0000-4000-8000-000000000001';
delete from privado.alerta_emitido;
insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em)
values ('74600000-0000-4000-8000-000000000001', 'Usuário Push Falha', 'pushfalha@test.local', '+5561911117462', 'profissional', 'ativa', '1995-01-01', '1.0', now())
on conflict (id) do nothing;

insert into public.notificacao (usuario_id, tipo, referencia_id, estado_entrega, motivo_falha, enviada_em)
values ('74600000-0000-4000-8000-000000000001', 'confirmacao', gen_random_uuid(), 'falhou', 'FAILED_PRECONDITION', privado.agora() - interval '30 minutes');
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'notificacao_push_falhou'),
  1,
  'Bloco 5 presente: notificacao_push_falhou emite alerta para push com falha na última hora'
);
delete from public.notificacao where usuario_id = '74600000-0000-4000-8000-000000000001';
delete from privado.alerta_emitido;

-- ── 6. Bloco 6: fcm_configuracao_suspeita ──────────────────────────────────────
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from public.notificacao where usuario_id = '74600000-0000-4000-8000-000000000002';
delete from privado.alerta_emitido;
insert into public.usuario (id, nome, email, telefone, perfil, estado, nascimento, termos_versao, termos_aceite_em)
values ('74600000-0000-4000-8000-000000000002', 'Usuário FCM NOT_FOUND', 'fcmfalha@test.local', '+5561911117463', 'profissional', 'ativa', '1995-01-01', '1.0', now())
on conflict (id) do nothing;

insert into public.notificacao (usuario_id, tipo, referencia_id, estado_entrega, motivo_falha, enviada_em)
values ('74600000-0000-4000-8000-000000000002', 'confirmacao', gen_random_uuid(), 'falhou', 'NOT_FOUND', privado.agora() - interval '5 minutes');
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'fcm_configuracao_suspeita'),
  1,
  'Bloco 6 presente: fcm_configuracao_suspeita emite alerta para motivo NOT_FOUND nos últimos 15 min'
);
delete from public.notificacao where usuario_id = '74600000-0000-4000-8000-000000000002';
delete from privado.alerta_emitido;

-- ── 7. Bloco 7: despacho_esperando_alem_do_teto ────────────────────────────────
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from privado.alerta_emitido;
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

select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'despacho_esperando_alem_do_teto'),
  1,
  'Bloco 7 presente: despacho_esperando_alem_do_teto emite alerta para despachos além da janela'
);
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from privado.alerta_emitido;

-- ── 8. Bloco 8: falha_execucao_edge_function ───────────────────────────────────
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from privado.falha_execucao;
delete from privado.alerta_emitido;
insert into privado.falha_execucao (origem, codigo, detalhes, criada_em)
values ('enviar-email', 'falha_smtp', '{"erro":"timeout"}'::jsonb, privado.agora() - interval '5 minutes');
select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'falha_execucao_edge_function'),
  1,
  'Bloco 8 presente: falha_execucao_edge_function emite alerta para falhas nos últimos 15 min'
);
delete from privado.falha_execucao;
delete from privado.alerta_emitido;

-- ── 9. Bloco 9: moderacao_vencida ──────────────────────────────────────────────
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from privado.alerta_emitido;
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

select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'moderacao_vencida'),
  1,
  'Bloco 9 presente: moderacao_vencida emite alerta para denúncias abertas há mais de 24h'
);
update public.ocorrencia set resolvido_em = now() where tipo = 'denuncia' and resolvido_em is null;
delete from privado.alerta_emitido;

-- ── 10. Bloco 10: contestacao_vencida ──────────────────────────────────────────
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from privado.alerta_emitido;
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

select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'contestacao_vencida'),
  1,
  'Bloco 10 presente: contestacao_vencida emite alerta para contestações abertas além de 5 dias úteis'
);
update public.ocorrencia set resolvido_em = now() where tipo = 'contestacao' and resolvido_em is null;
delete from privado.alerta_emitido;

-- ── 11. Bloco 11: pgnet_falha_transporte ───────────────────────────────────────
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from net._http_response;
delete from privado.alerta_emitido;
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values 
  (990011, null, null, null, null, true, null, privado.agora() - interval '5 minutes'),
  (990012, null, null, null, null, true, null, privado.agora() - interval '4 minutes'),
  (990013, 502, 'text/html', '{}'::jsonb, 'Bad Gateway', false, null, privado.agora() - interval '3 minutes');

select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_falha_transporte'),
  1,
  'Bloco 11 presente: pgnet_falha_transporte emite alerta para >= 3 falhas assíncronas na janela'
);
delete from net._http_response;
delete from privado.alerta_emitido;

-- ── 12. Bloco 12: pgnet_resposta_recusada ──────────────────────────────────────
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from net._http_response;
delete from privado.alerta_emitido;
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values (990014, 401, 'application/json', '{}'::jsonb, '{"code":401}', false, null, privado.agora() - interval '2 minutes');

select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_resposta_recusada'),
  1,
  'Bloco 12 presente: pgnet_resposta_recusada emite alerta para resposta 401/403/404 na janela'
);
delete from net._http_response;
delete from privado.alerta_emitido;

-- ── 13. Bloco 13: demonstracao_sob_ataque ──────────────────────────────────────
delete from public.entrada_demonstracao;
delete from public.despacho;
update public.vaga set estado = 'cancelada' where estado = 'publicada';
delete from privado.alerta_emitido;
insert into public.entrada_demonstracao (email, aceita, em)
select 'demo@test.local', false, privado.agora() - (g || ' minutes')::interval
  from generate_series(1, 10) as g;

select privado.verificar_saude();
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'demonstracao_sob_ataque'),
  1,
  'Bloco 13 presente: demonstracao_sob_ataque emite alerta para >= 10 tentativas recusadas na janela'
);
delete from public.entrada_demonstracao;
delete from privado.alerta_emitido;

select * from finish();
rollback;
