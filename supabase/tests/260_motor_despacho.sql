-- Testes do Motor de Despacho: elegibilidade, fila, reprocessamento e agendador.
--
-- Cobre os critérios de aceite do cartão 7XS6MQGg:
--   1. Com o seed, publicar uma vaga gera despacho só para os elegíveis.
--   2. Profissional a 16 km não recebe; bloqueado não recebe; com turno sobreposto não recebe.
--   3. Reprocessar a mesma mensagem não duplica `despacho`.
--   6. Vaga de conta de demonstração não notifica conta real, e vaga real não notifica conta de demonstração.
--   + Notificação `vaga_sem_elegiveis` quando não há ninguém.
--   + Reprocessamento pela fila pgmq com tentativas limitadas.

begin;
select plan(40);

-- ── 1. Existência e permissões das funções ─────────────────────────────────────
select has_function('privado', 'elegiveis', array['uuid', 'uuid'],
  'privado.elegiveis(uuid, uuid) existe');

select has_function('privado', 'despachar_vaga', array['uuid', 'text', 'uuid'],
  'privado.despachar_vaga(uuid, text, uuid) existe');

select has_function('privado', 'processar_fila_despacho', array['integer', 'integer'],
  'privado.processar_fila_despacho(int, int) existe');

select is(
  has_function_privilege('anon', 'privado.elegiveis(uuid, uuid)', 'execute'),
  false,
  'privado.elegiveis não é chamável por anon');

select is(
  has_function_privilege('authenticated', 'privado.elegiveis(uuid, uuid)', 'execute'),
  false,
  'privado.elegiveis não é chamável por authenticated (RN06, RN05)');

select is(
  has_function_privilege('anon', 'privado.despachar_vaga(uuid, text, uuid)', 'execute'),
  false,
  'privado.despachar_vaga não é chamável por anon');

select is(
  has_function_privilege('authenticated', 'privado.despachar_vaga(uuid, text, uuid)', 'execute'),
  false,
  'privado.despachar_vaga não é chamável por authenticated');

-- ── 2. Critério 1: Com o seed, conferir elegíveis da vaga de referência ───────
-- Vaga de referência do Bar do Cerrado (garçom, sexta 18:00–02:00)
create temp table ids as select
  'd0000000-0000-4000-8000-000000000001'::uuid as vaga_ref,
  'e0000000-0000-4000-8000-000000000001'::uuid as ana,      -- elegível
  'e0000000-0000-4000-8000-000000000002'::uuid as bruno,    -- sem a função
  'e0000000-0000-4000-8000-000000000003'::uuid as carla,    -- fora do horário
  'e0000000-0000-4000-8000-000000000004'::uuid as diego,    -- 16.9 km (além dos 15 km)
  'e0000000-0000-4000-8000-000000000005'::uuid as elisa,    -- conta suspensa
  'e0000000-0000-4000-8000-000000000006'::uuid as felipe,   -- bloqueado pelo bar
  'e0000000-0000-4000-8000-000000000007'::uuid as gabi,     -- turno sobreposto
  'e0000000-0000-4000-8000-000000000008'::uuid as heitor,   -- elegível (Lago Sul)
  'e0000000-0000-4000-8000-000000000009'::uuid as iara,     -- elegível por equipe de confiança
  'e0000000-0000-4000-8000-000000000010'::uuid as joao,     -- sem a função
  'e0000000-0000-4000-8000-000000000011'::uuid as katia,    -- elegível (sem histórico)
  'e0000000-0000-4000-8000-000000000012'::uuid as lucas,    -- elegível (taxa 0.000)
  (select id from public.profissional where usuario_id = 'de000000-0000-4000-8000-000000000002') as prof_demo;

-- Isola a execução contra dados residuais criados por testes HTTP (ex: ciclo-completo.sh na CI)
update public.usuario
   set estado = 'suspensa'
 where id not in (
   select usuario_id from public.profissional where id::text like 'e0000000-0000-4000-8000-%'
 )
 and id <> 'de000000-0000-4000-8000-000000000002';

-- Garante disponibilidade da conta de demonstração para os testes
insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
select (select prof_demo from ids), d, '00:00'::time, '23:59'::time
  from generate_series(0, 6) as d;

-- A lista exata esperada de elegíveis: Ana, Heitor, Iara, Katia, Lucas (5 profissionais)
select set_eq(
  $$ select profissional_id from privado.elegiveis('d0000000-0000-4000-8000-000000000001') $$,
  $$ select unnest(array[
       'e0000000-0000-4000-8000-000000000001'::uuid,
       'e0000000-0000-4000-8000-000000000008'::uuid,
       'e0000000-0000-4000-8000-000000000009'::uuid,
       'e0000000-0000-4000-8000-000000000011'::uuid,
       'e0000000-0000-4000-8000-000000000012'::uuid
     ]) $$,
  'Critério 1: Com o seed, privado.elegiveis devolve exatamente os 5 profissionais elegíveis'
);

-- ── 3. Critério 2: Inelegíveis pontuais da RN05 ────────────────────────────────
select ok(
  not exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select diego from ids)),
  'Critério 2: Profissional a 16 km (Diego, 16.9 km) não recebe');

select ok(
  not exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select felipe from ids)),
  'Critério 2: Profissional bloqueado (Felipe) não recebe');

select ok(
  not exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select gabi from ids)),
  'Critério 2: Profissional com turno sobreposto (Gabi) não recebe');

select ok(
  not exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select bruno from ids)),
  'Bruno não recebe: função incompatível');

select ok(
  not exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select carla from ids)),
  'Carla não recebe: fora da grade de horário');

select ok(
  not exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select elisa from ids)),
  'Elisa não recebe: conta suspensa');

-- ── 4. Regras adicionais de elegibilidade (RN06 e RF18) ────────────────────────
select ok(
  exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select iara from ids)),
  'RF18: Iara mora a 17.4 km e recebe por ser da equipe de confiança do bar');

select ok(
  exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select katia from ids)),
  'RN06: Katia (sem histórico, taxa nula) recebe junto com os outros');

select ok(
  exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select lucas from ids)),
  'RN06: Lucas (taxa 0.000) recebe junto: reputação não altera elegibilidade nem ordem');

-- ── 5. Janela que atravessa a meia-noite ───────────────────────────────────────
-- Teste de vaga iniciando na madrugada (sábado 00:30–02:00) coberta por grade de sexta 18:00–02:00
create temp table vaga_madrugada as
select g.id as vaga_id
  from public.vaga g
 where g.id = (select vaga_ref from ids);

-- Atualiza temporariamente para testar a madrugada coberta pela janela da véspera
do $$
declare
  v_vg uuid := (select vaga_ref from ids);
  v_ini timestamptz;
  v_fim timestamptz;
begin
  select inicio_em into v_ini from public.vaga where id = v_vg;
  -- Madrugada de sábado: início às 00:30 (+6h30 da sexta 18h) até 02:00
  v_ini := v_ini + interval '6 hours 30 minutes';
  v_fim := v_ini + interval '1 hour 30 minutes';

  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, publicado_por, modo, estado, chave_cliente)
  values ('d0000000-0000-4000-8000-000000000099',
          'c0000000-0000-4000-8000-000000000001',
          (select id from public.funcao where nome = 'garçom'),
          v_ini, v_fim, 'CLN 208', 'POINT(-47.8869 -15.7620)'::extensions.geography,
          10000, 1, false, false, false, 'Gerente',
          (select publicado_por from public.vaga where id = v_vg), 'urgencia', 'publicada', gen_random_uuid());
end $$;

select ok(
  exists (
    select 1 from privado.elegiveis('d0000000-0000-4000-8000-000000000099')
     where profissional_id = (select ana from ids)
  ),
  'A janela de sexta 18:00–02:00 cobre a vaga que começa no sábado à 00:30 (atravessa a meia-noite)'
);

-- ── 6. Despacho e notificações criadas por despachar_vaga ──────────────────────
select is(
  privado.despachar_vaga('d0000000-0000-4000-8000-000000000001'),
  5,
  'privado.despachar_vaga cria 5 despachos para os 5 elegíveis');

select is(
  (select count(*)::int from public.despacho where vaga_id = 'd0000000-0000-4000-8000-000000000001'),
  5,
  '5 linhas gravadas em public.despacho');

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'vaga' and referencia_id = 'd0000000-0000-4000-8000-000000000001'),
  5,
  '5 notificações com tipo vaga criadas');

-- Cada despacho aponta para a respectiva notificacao
select is(
  (select count(*)::int from public.despacho d
    where d.vaga_id = 'd0000000-0000-4000-8000-000000000001' and d.notificacao_id is not null),
  5,
  'Cada linha de despacho aponta para uma notificacao_id válida');

-- ── 7. Critério 3: Reprocessar a mesma vaga não duplica despacho ───────────────
select is(
  privado.despachar_vaga('d0000000-0000-4000-8000-000000000001'),
  0,
  'Critério 3: Reprocessar a mesma vaga gera 0 novos despachos');

select is(
  (select count(*)::int from public.despacho where vaga_id = 'd0000000-0000-4000-8000-000000000001'),
  5,
  'Critério 3: public.despacho mantém exatamente os 5 despachos originais (sem duplicidade)');

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'vaga' and referencia_id = 'd0000000-0000-4000-8000-000000000001'),
  5,
  'Critério 3: Nenhuma notificação duplicada na reexecução');

-- ── 8. Critério 6: Isolamento das contas de demonstração ───────────────────────
-- 8a: Vaga real não notifica conta de demonstração
select ok(
  not exists (
    select 1 from public.despacho
     where vaga_id = 'd0000000-0000-4000-8000-000000000001'
       and profissional_id = (select prof_demo from ids)
  ),
  'Critério 6: Vaga real não despacha nem notifica conta de demonstração'
);

-- 8b: Criar vaga publicada por conta de demonstração
do $$
declare
  v_demo_pub uuid := 'de000000-0000-4000-8000-000000000001'; -- contratante de demonstracao
  v_demo_estab uuid;
  v_agora timestamptz := privado.agora();
begin
  select id into v_demo_estab from public.estabelecimento
   where id = 'c0000000-0000-4000-8000-000000000001'; -- usa bar do cerrado como local

  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, publicado_por, modo, estado, chave_cliente)
  values ('de000000-0000-4000-8000-000000000099',
          v_demo_estab,
          (select id from public.funcao where nome = 'garçom'),
          v_agora + interval '4 days',
          v_agora + interval '4 days 6 hours',
          'Local Demo', 'POINT(-47.8825 -15.7940)'::extensions.geography,
          15000, 1, false, false, false, 'Revisor',
          v_demo_pub, 'urgencia', 'publicada', gen_random_uuid());
end $$;

-- Apenas o profissional de demonstração deve ser elegível para a vaga de demonstração
select is(
  (select count(*)::int from privado.elegiveis('de000000-0000-4000-8000-000000000099')),
  1,
  'Critério 6: Vaga de demonstração tem exatamente 1 elegível'
);

select is(
  (select profissional_id from privado.elegiveis('de000000-0000-4000-8000-000000000099')),
  (select prof_demo from ids),
  'Critério 6: O único elegível da vaga de demonstração é o profissional de demonstração'
);

-- Nenhuma conta real foi elegível para a vaga de demonstração
select ok(
  not exists (
    select 1 from privado.elegiveis('de000000-0000-4000-8000-000000000099') e
    where e.profissional_id in (select ana from ids union select heitor from ids)
  ),
  'Critério 6: Vaga de demonstração NÃO notifica contas reais'
);

-- ── 9. Sem nenhum elegível: notificar vaga_sem_elegiveis uma vez ───────────────
do $$
declare
  v_agora timestamptz := privado.agora();
  v_vaga_sem uuid := 'd0000000-0000-4000-8000-000000000088';
begin
  -- Vaga em Brazlândia (fora de 15km de todos) e para função sem profissionais cadastrados
  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, publicado_por, modo, estado, chave_cliente)
  values (v_vaga_sem,
          'c0000000-0000-4000-8000-000000000001',
          (select id from public.funcao where nome = 'chapa (carga e descarga)'),
          v_agora + interval '5 days',
          v_agora + interval '5 days 4 hours',
          'Brazlândia', 'POINT(-48.2000 -15.6700)'::extensions.geography,
          25000, 1, false, false, false, 'Gerente',
          (select publicado_por from public.vaga where id = (select vaga_ref from ids)),
          'urgencia', 'publicada', gen_random_uuid());
end $$;

select is(
  (select count(*)::int from privado.elegiveis('d0000000-0000-4000-8000-000000000088')),
  0,
  'A vaga isolada não tem nenhum profissional elegível'
);

-- Despacha a vaga sem elegíveis
select is(
  privado.despachar_vaga('d0000000-0000-4000-8000-000000000088'),
  0,
  '0 despachos gerados para vaga sem elegíveis'
);

select ok(
  exists (
    select 1 from public.notificacao
     where tipo = 'vaga_sem_elegiveis'
       and referencia_id = 'd0000000-0000-4000-8000-000000000088'
  ),
  'UC02 1a: Contratante é notificado com vaga_sem_elegiveis'
);

-- Re-executar não duplica a notificação vaga_sem_elegiveis
select privado.despachar_vaga('d0000000-0000-4000-8000-000000000088');
select is(
  (select count(*)::int from public.notificacao
    where tipo = 'vaga_sem_elegiveis'
      and referencia_id = 'd0000000-0000-4000-8000-000000000088'),
  (select count(*)::int from public.membro_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000001'),
  'Re-executar o despacho não duplica a notificação vaga_sem_elegiveis'
);

-- ── 10. Fila pgmq e limite de tentativas ──────────────────────────────────────
-- Testa o consumo pela fila pgmq
set local frila.agendador_secret = 'segredo-de-teste';
select pgmq.send('despacho', jsonb_build_object(
  'vaga_id', 'd0000000-0000-4000-8000-000000000099'
));

select cmp_ok(
  (select count(*)::int from privado.processar_fila_despacho(10, 30) where sucesso = true),
  '>=', 1,
  'processar_fila_despacho consome mensagem da fila com sucesso'
);

-- Mensagem com tentativas esgotadas (read_ct > 5) é arquivada e não processada
do $$
declare
  v_mid bigint;
begin
  select pgmq.send('despacho', jsonb_build_object(
    'vaga_id', '00000000-0000-4000-8000-000000000000'
  )) into v_mid;
  -- Simula 6 leituras anteriores
  update pgmq.q_despacho set read_ct = 6 where msg_id = v_mid;
end $$;

select is(
  (select erro from privado.processar_fila_despacho(10, 30) where vaga_id = '00000000-0000-4000-8000-000000000000'),
  'teto_tentativas_excedido',
  'Mensagem com read_ct > 5 é arquivada por exceder o teto de tentativas'
);

-- ── 11. Trigger de disparo assíncrono via pgmq pós-commit ──────────────────────
select ok(
  exists (
    select 1 from pg_trigger
     where tgrelid = 'pgmq.q_despacho'::regclass
       and tgname like '%despacho%'
  ),
  'Trigger pós-commit instalado em pgmq.q_despacho para disparar net.http_post'
);

-- ── 12. Validação do segredo obrigatório em privado.disparar_despacho ──────────
set local frila.agendador_secret = '';
select throws_ok(
  $$ select privado.disparar_despacho('d0000000-0000-4000-8000-000000000001') $$,
  'Configuração frila.agendador_secret ausente no banco de dados',
  'privado.disparar_despacho falha explicitamente quando frila.agendador_secret não está configurado'
);

select throws_ok(
  $$ select pgmq.send('despacho', jsonb_build_object(
       'vaga_id', 'd0000000-0000-4000-8000-000000000001')) $$,
  'Configuração frila.agendador_secret ausente no banco de dados',
  'trigger do despacho não engole falha de configuração do segredo'
);

do $$
begin
  set local frila.agendador_secret = 'segredo-de-teste';
  set local frila.edge_function_url = 'not-a-url';
  perform pgmq.send('despacho', jsonb_build_object(
    'vaga_id', 'd0000000-0000-4000-8000-000000000001'));
end $$;

select ok(
  exists (
    select 1
      from pgmq.q_despacho
     where message->>'vaga_id' = 'd0000000-0000-4000-8000-000000000001'
  ),
  'falha de transporte mantém a mensagem na fila para reprocessamento'
);

-- ── 13. Marca de envio para tipo vaga impede notificação duplicada ─────────────
do $$
declare
  v_n1 uuid;
  v_n2 uuid;
  v_ana_usr uuid := 'a0000000-0000-4000-8000-000000000001';
  v_vg uuid := 'd0000000-0000-4000-8000-000000000001';
begin
  v_n1 := privado.notificar(v_ana_usr, 'vaga', v_vg, jsonb_build_object('vaga_id', v_vg));
  v_n2 := privado.notificar(v_ana_usr, 'vaga', v_vg, jsonb_build_object('vaga_id', v_vg));
  if v_n1 <> v_n2 then
    raise exception 'notificacoes diferentes criadas: % vs %', v_n1, v_n2;
  end if;
end $$;

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'vaga'
      and referencia_id = 'd0000000-0000-4000-8000-000000000001'
      and usuario_id = 'a0000000-0000-4000-8000-000000000001'),
  1,
  'privado.notificar não duplica notificação do tipo vaga para o mesmo usuário e referência'
);

select * from finish();
rollback;
