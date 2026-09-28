-- S2 · Backend · Alerta de vaga vazia na janela crítica (RF20, UC07, D4/B18)
-- Cartão: https://trello.com/c/vUR0Ltkb
--
-- `privado.alertar_vagas_vazias()` roda a cada cinco minutos. Para cada posição ainda
-- aberta cuja vaga já entrou na janela crítica (`inicio_em - alerta_antecedencia`),
-- enfileira `vaga_vazia` para cada membro do estabelecimento, uma vez por posição.
--
-- O relógio é o do produto (`frila.agora`), e todas as vagas começam às 18:00 de
-- 03/10 (horário de Brasília).
begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(24);

insert into privado.ambiente (eh_teste) values (true);

create temp table ids as
select
  'c3400000-0000-4000-8000-000000000001'::uuid as admin,
  'c3400000-0000-4000-8000-000000000002'::uuid as operador,
  'c3400000-0000-4000-8000-000000000003'::uuid as prof_usuario,
  'c3400000-0000-4000-8000-000000000004'::uuid as de_fora,
  'c3400000-0000-4000-8000-000000000005'::uuid as prof_usuario_2,
  'c3400000-0000-4000-8000-000000000011'::uuid as profissional,
  'c3400000-0000-4000-8000-000000000012'::uuid as profissional_2,
  'c3400000-0000-4000-8000-000000000021'::uuid as estabelecimento,
  'c3400000-0000-4000-8000-000000000031'::uuid as vaga_3h,
  'c3400000-0000-4000-8000-000000000032'::uuid as vaga_preenchida,
  'c3400000-0000-4000-8000-000000000033'::uuid as vaga_2h,
  'c3400000-0000-4000-8000-000000000034'::uuid as vaga_duas,
  'c3400000-0000-4000-8000-000000000035'::uuid as vaga_sem_elegiveis,
  'c3400000-0000-4000-8000-000000000036'::uuid as vaga_cancelada,
  'c3400000-0000-4000-8000-000000000037'::uuid as vaga_tardia,
  'c3400000-0000-4000-8000-000000000041'::uuid as pos_3h,
  'c3400000-0000-4000-8000-000000000042'::uuid as pos_preenchida,
  'c3400000-0000-4000-8000-000000000043'::uuid as pos_2h,
  'c3400000-0000-4000-8000-000000000044'::uuid as pos_duas_1,
  'c3400000-0000-4000-8000-000000000045'::uuid as pos_duas_2,
  'c3400000-0000-4000-8000-000000000046'::uuid as pos_sem_elegiveis,
  'c3400000-0000-4000-8000-000000000047'::uuid as pos_cancelada,
  'c3400000-0000-4000-8000-000000000048'::uuid as pos_tardia;

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}', '{}', now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

create function pg_temp.como(conta uuid, consulta text) returns jsonb
language plpgsql as $$
declare resultado jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute consulta into resultado;
  reset role;
  execute 'reset request.jwt.claims';
  return resultado;
end $$;

-- Quantos alertas de vaga vazia saíram para a posição.
create function pg_temp.alertas(p uuid) returns int
language sql as $$
  select count(*)::int from public.notificacao n
   where n.tipo = 'vaga_vazia' and n.referencia_id = p
$$;

create function pg_temp.vaga(
  id uuid, estab uuid, funcao uuid, posicoes int, antecedencia interval, autor uuid)
returns void language sql as $$
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em,
    chave_cliente, publicado_por, alerta_antecedencia)
  values (id, estab, funcao,
          '2026-10-03 18:00:00-03', '2026-10-03 23:00:00-03',
          'Local', 'POINT(-47.8800 -15.7700)'::extensions.geography,
          15000, posicoes, false, false, false, 'Responsavel', 'urgencia', 'publicada',
          '2026-09-30 12:00:00-03', gen_random_uuid(), autor, antecedencia)
$$;

create function pg_temp.posicao(id uuid, vaga uuid) returns void
language sql as $$
  insert into public.posicao (id, vaga_id, inicio_em, fim_em)
  values (id, vaga, '2026-10-03 18:00:00-03', '2026-10-03 23:00:00-03')
$$;

select pg_temp.autenticar(admin,        'admin-vazia@test.invalid')    from ids;
select pg_temp.autenticar(operador,     'operador-vazia@test.invalid') from ids;
select pg_temp.autenticar(prof_usuario, 'prof-vazia@test.invalid')     from ids;
select pg_temp.autenticar(de_fora,      'fora-vazia@test.invalid')     from ids;
select pg_temp.autenticar(prof_usuario_2, 'prof2-vazia@test.invalid')  from ids;

insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select admin, 'contratante'::public.perfil_conta, 'Admin Vazia', '+5561999934001',
       'admin-vazia@test.invalid', '1985-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids
union all
select operador, 'contratante'::public.perfil_conta, 'Operador Vazia', '+5561999934002',
       'operador-vazia@test.invalid', '1986-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids
union all
select prof_usuario, 'profissional'::public.perfil_conta, 'Prof Vazia', '+5561999934003',
       'prof-vazia@test.invalid', '1990-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids
union all
select de_fora, 'contratante'::public.perfil_conta, 'Fora Vazia', '+5561999934004',
       'fora-vazia@test.invalid', '1987-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids
union all
select prof_usuario_2, 'profissional'::public.perfil_conta, 'Prof2 Vazia', '+5561999934005',
       'prof2-vazia@test.invalid', '1991-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids;

insert into public.profissional (id, usuario_id, ponto_base)
select profissional, prof_usuario, 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids
union all
select profissional_2, prof_usuario_2, 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

-- O profissional só faz a primeira função do catálogo; a vaga sem elegíveis pede outra.
insert into public.profissional_funcao (profissional_id, funcao_id)
select profissional, (select id from public.funcao order by nome limit 1) from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select estabelecimento, 'Casa Vazia', '83400000000191', 'food_service',
       'Endereco de teste', 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

-- Dois membros: o alerta vai para a casa inteira, sem filtro de papel. `de_fora` não é
-- membro e não pode receber nada.
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select admin, estabelecimento, 'administrador'::public.papel_membro from ids
union all
select operador, estabelecimento, 'operador'::public.papel_membro from ids;

-- As vagas. Todas começam às 18:00; muda a antecedência e o que acontece com a posição.
select pg_temp.vaga(vaga_3h, estabelecimento, (select id from public.funcao order by nome limit 1),
                    1, '3 hours', admin) from ids;
select pg_temp.vaga(vaga_preenchida, estabelecimento, (select id from public.funcao order by nome limit 1),
                    1, '3 hours', admin) from ids;
select pg_temp.vaga(vaga_2h, estabelecimento, (select id from public.funcao order by nome limit 1),
                    1, '2 hours', admin) from ids;
select pg_temp.vaga(vaga_duas, estabelecimento, (select id from public.funcao order by nome limit 1),
                    2, '3 hours', admin) from ids;
select pg_temp.vaga(vaga_sem_elegiveis, estabelecimento,
                    (select id from public.funcao order by nome desc limit 1),
                    1, '3 hours', admin) from ids;
select pg_temp.vaga(vaga_cancelada, estabelecimento, (select id from public.funcao order by nome limit 1),
                    1, '3 hours', admin) from ids;

select pg_temp.posicao(pos_3h, vaga_3h) from ids;
select pg_temp.posicao(pos_preenchida, vaga_preenchida) from ids;
select pg_temp.posicao(pos_2h, vaga_2h) from ids;
select pg_temp.posicao(pos_duas_1, vaga_duas) from ids;
select pg_temp.posicao(pos_duas_2, vaga_duas) from ids;
select pg_temp.posicao(pos_sem_elegiveis, vaga_sem_elegiveis) from ids;
select pg_temp.posicao(pos_cancelada, vaga_cancelada) from ids;

update public.vaga set estado = 'cancelada' where id = (select vaga_cancelada from ids);

-- O motor de despacho já avisou que ninguém é elegível: o alerta de vaga vazia é outro
-- aviso e sai do mesmo jeito (US07, cenário 4).
select privado.notificar(admin, 'vaga_sem_elegiveis', vaga_sem_elegiveis,
                         jsonb_build_object('vaga_id', vaga_sem_elegiveis))
  from ids;

-- ── 14:00, quatro horas antes: a posição é preenchida ────────────────────────
select set_config('frila.agora', '2026-10-03 14:00:00-03', true);

select pg_temp.como(
  (select prof_usuario from ids),
  format($$ select public.candidatar(%L) $$, (select vaga_preenchida from ids)));

select is(
  (select estado::text from public.posicao where id = (select pos_preenchida from ids)),
  'confirmada',
  'preparação: a posição foi preenchida a 4 h do início');

select is(privado.alertar_vagas_vazias(), 0,
  'a 4 h do início nenhuma vaga está na janela crítica');

-- ── 14:59: ainda fora da janela de 3 h ───────────────────────────────────────
select set_config('frila.agora', '2026-10-03 14:59:00-03', true);
select privado.alertar_vagas_vazias();

select is(pg_temp.alertas((select pos_3h from ids)), 0,
  'um minuto antes das 3 h a posição aberta ainda não gera alerta');

-- ── 15:00: três horas antes ──────────────────────────────────────────────────
select set_config('frila.agora', '2026-10-03 15:00:00-03', true);

select is(privado.alertar_vagas_vazias(), 4,
  'às 3 h entram na janela quatro posições abertas (3 h, duas posições e sem elegíveis)');

select is(pg_temp.alertas((select pos_3h from ids)), 2,
  'posição aberta a 3 h do início gera o alerta, um para cada membro da casa');

select is(
  (select array_agg(n.usuario_id order by n.usuario_id) from public.notificacao n
    where n.tipo = 'vaga_vazia' and n.referencia_id = (select pos_3h from ids)),
  (select array[admin, operador] from ids),
  'o alerta vai ao administrador e ao operador, e a ninguém mais');

select is(pg_temp.alertas((select pos_preenchida from ids)), 0,
  'posição preenchida a 4 h do início não gera alerta');

select is(pg_temp.alertas((select pos_2h from ids)), 0,
  'antecedência de 2 h escolhida na publicação: às 3 h ainda não há alerta');

select is(pg_temp.alertas((select pos_duas_1 from ids)) + pg_temp.alertas((select pos_duas_2 from ids)),
  4,
  'vaga de duas posições abertas: um alerta por posição, para cada membro');

select is(pg_temp.alertas((select pos_sem_elegiveis from ids)), 2,
  'vaga sem elegíveis também recebe o alerta de vaga vazia (US07, cenário 4)');

select is(pg_temp.alertas((select pos_cancelada from ids)), 0,
  'vaga cancelada não gera alerta, mesmo com posição ainda marcada como aberta');

select is(
  (select n.payload from public.notificacao n
    where n.tipo = 'vaga_vazia' and n.referencia_id = (select pos_3h from ids)
      and n.usuario_id = (select admin from ids)),
  (select jsonb_build_object('vaga_id', vaga_3h, 'posicao_id', pos_3h, 'tipo', 'vaga_vazia')
     from ids),
  'o destino do toque é Minhas vagas com a vaga em alerta: tipo, vaga_id e posicao_id, nada mais (RN15)');

select is(
  (select count(*)::int from public.notificacao n
    where n.tipo = 'vaga_vazia' and n.profissional_id is not null),
  0,
  'o alerta é da casa e não conta no teto de notificação do profissional (RN23)');

-- ── 15:05: o agendador roda de novo ──────────────────────────────────────────
select set_config('frila.agora', '2026-10-03 15:05:00-03', true);

select is(privado.alertar_vagas_vazias(), 0,
  'a segunda rodada não encontra posição nova para alertar');

select is(pg_temp.alertas((select pos_3h from ids)), 2,
  'um alerta por posição: a segunda rodada não duplica o push');

-- ── 16:00: duas horas antes ──────────────────────────────────────────────────
select set_config('frila.agora', '2026-10-03 16:00:00-03', true);

select is(privado.alertar_vagas_vazias(), 1,
  'às 2 h entra a posição da vaga publicada com antecedência de 2 h');

select is(pg_temp.alertas((select pos_2h from ids)), 2,
  'antecedência de 2 h escolhida na publicação é respeitada');

-- ── Depois do início não há o que pedir ──────────────────────────────────────
-- Uma vaga que o agendador nunca viu na janela (publicada tarde, ou o agendador parado)
-- e que já começou não recebe alerta: ninguém mais se candidata.
select pg_temp.vaga(vaga_tardia, estabelecimento, (select id from public.funcao order by nome limit 1),
                    1, '3 hours', admin) from ids;
select pg_temp.posicao(pos_tardia, vaga_tardia) from ids;

select set_config('frila.agora', '2026-10-03 18:00:00-03', true);
select privado.alertar_vagas_vazias();

select is(pg_temp.alertas((select pos_tardia from ids)), 0,
  'no início do turno a posição ainda aberta não gera mais alerta');

-- ── O alerta enfileirado deixa de valer ──────────────────────────────────────
-- `notificacao_expirada` é a pergunta que a enviar-push faz antes de mandar. Para o
-- alerta, a referência é a posição.
select set_config('frila.agora', '2026-10-03 15:10:00-03', true);

select is(
  privado.notificacao_expirada((select n.id from public.notificacao n
    where n.tipo = 'vaga_vazia' and n.referencia_id = (select pos_3h from ids)
      and n.usuario_id = (select admin from ids))),
  false,
  'alerta de posição ainda aberta, antes do início, continua valendo');

update public.posicao set estado = 'confirmada', profissional_id = (select profissional_2 from ids),
                          confirmado_em = '2026-10-03 15:08:00-03'
 where id = (select pos_duas_1 from ids);

select is(
  privado.notificacao_expirada((select n.id from public.notificacao n
    where n.tipo = 'vaga_vazia' and n.referencia_id = (select pos_duas_1 from ids)
      and n.usuario_id = (select admin from ids))),
  true,
  'posição preenchida depois de enfileirado: o alerta não sai (diria que ainda está vaga)');

select set_config('frila.agora', '2026-10-03 18:00:00-03', true);

select is(
  privado.notificacao_expirada((select n.id from public.notificacao n
    where n.tipo = 'vaga_vazia' and n.referencia_id = (select pos_3h from ids)
      and n.usuario_id = (select admin from ids))),
  true,
  'no início do turno o alerta ainda não enviado expira');

-- ── Quem pode chamar ─────────────────────────────────────────────────────────
select ok(
  not has_function_privilege('authenticated', 'privado.alertar_vagas_vazias()', 'execute')
  and not has_function_privilege('anon', 'privado.alertar_vagas_vazias()', 'execute'),
  'o app não chama o agendador: authenticated e anon sem execute');

select ok(
  has_function_privilege('service_role', 'privado.alertar_vagas_vazias()', 'execute'),
  'service_role executa o agendador');

-- ── O agendador ──────────────────────────────────────────────────────────────
select is(
  (select j.schedule from cron.job j where j.jobname = 'alertar_vagas_vazias'),
  '*/5 * * * *',
  'o pg_cron roda o alerta a cada cinco minutos');

select * from finish();
rollback;
