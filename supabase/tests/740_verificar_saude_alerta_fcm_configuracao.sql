begin;
select plan(7);

-- Garante que a fila email e ambiente de teste estão preparados
do $$
begin
  if not exists (select 1 from pg_tables where schemaname = 'pgmq' and tablename = 'q_email') then
    perform pgmq.create('email');
  end if;
  truncate table pgmq.q_email;
  truncate table privado.alerta_emitido;
end $$;

insert into privado.ambiente (eh_teste) values (true)
on conflict do nothing;

-- 1. Cria usuário e notificação que falhou com motivo_falha = 'NOT_FOUND' recente (5 min atrás)
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'f0000000-0000-4000-8000-000000000740',
        'authenticated', 'authenticated', 'fcm_alerta@teste.com', now(),
        '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
on conflict do nothing;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('f0000000-0000-4000-8000-000000000740', 'profissional', 'Alerta FCM', '+5561999990740',
        'fcm_alerta@teste.com', '1990-01-01'::date, '2026-09-22', privado.agora())
on conflict do nothing;

insert into public.notificacao (
  id, usuario_id, tipo, referencia_id, payload,
  tentativas, estado_entrega, motivo_falha, enviada_em
) values (
  'a4000000-0000-4000-8000-000000000001',
  'f0000000-0000-4000-8000-000000000740',
  'avaliacao_disponivel',
  gen_random_uuid(),
  '{}'::jsonb,
  1,
  'falhou',
  'NOT_FOUND',
  privado.agora() - interval '5 minutes'
);

-- Executa verificar_saude: deve detectar e emitir o alerta fcm_configuracao_suspeita
select ok(
  privado.verificar_saude() > 0,
  'privado.verificar_saude() detecta falhas NOT_FOUND de configuracao FCM e emite alertas'
);

select is(
  (select count(*)::int from pgmq.q_email where message->>'codigo' = 'fcm_configuracao_suspeita'),
  1,
  'Alerta com codigo fcm_configuracao_suspeita foi colocado na fila email'
);

select is(
  (select message->>'tipo' from pgmq.q_email where message->>'codigo' = 'fcm_configuracao_suspeita'),
  'alerta',
  'Mensagem tem tipo = alerta'
);

-- 2. Segundo alerta dentro de 1 hora deve ser suprimido pelo rate limit de emitir_alerta
select is(
  privado.emitir_alerta('fcm_configuracao_suspeita', 1),
  false,
  'Alerta subsequente de fcm_configuracao_suspeita em menos de 1h é suprimido pelo rate limit'
);

-- 3. Limpa alertas e testa que motivo UNREGISTERED (token desregistrado legítimo) NÃO emite fcm_configuracao_suspeita
truncate table pgmq.q_email;
truncate table privado.alerta_emitido;
update public.notificacao
   set motivo_falha = 'UNREGISTERED'
 where id = 'a4000000-0000-4000-8000-000000000001';

select privado.verificar_saude();

select is(
  (select count(*)::int from pgmq.q_email where message->>'codigo' = 'fcm_configuracao_suspeita'),
  0,
  'Motivo UNREGISTERED não é falha de configuração e NÃO gera fcm_configuracao_suspeita'
);

-- 4. Notificação NOT_FOUND fora da janela (mais antiga que 15 minutos) NÃO gera fcm_configuracao_suspeita
truncate table pgmq.q_email;
truncate table privado.alerta_emitido;
update public.notificacao
   set motivo_falha = 'NOT_FOUND',
       enviada_em = privado.agora() - interval '20 minutes'
 where id = 'a4000000-0000-4000-8000-000000000001';

select privado.verificar_saude();

select is(
  (select count(*)::int from pgmq.q_email where message->>'codigo' = 'fcm_configuracao_suspeita'),
  0,
  'Falha NOT_FOUND fora da janela de 15 minutos NÃO gera fcm_configuracao_suspeita'
);

-- 5. Notificação pendente ou enviada com NOT_FOUND não conta (apenas estado falhou)
truncate table pgmq.q_email;
truncate table privado.alerta_emitido;
update public.notificacao
   set motivo_falha = 'NOT_FOUND',
       estado_entrega = 'enviada',
       enviada_em = privado.agora() - interval '2 minutes'
 where id = 'a4000000-0000-4000-8000-000000000001';

select privado.verificar_saude();

select is(
  (select count(*)::int from pgmq.q_email where message->>'codigo' = 'fcm_configuracao_suspeita'),
  0,
  'Notificação sem estado_entrega = falhou NÃO gera alerta de configuração'
);

select * from finish();
rollback;
