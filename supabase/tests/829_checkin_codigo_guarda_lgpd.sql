-- 829_checkin_codigo_guarda_lgpd.sql
--
-- A guarda de LGPD do check-in por código (contrato 0.2.68; migração 20261109102000; regras da
-- Bússola, 08/11, na Modelagem do frila-docs #198):
--   · 90 dias depois do mais tarde entre o fim do turno e o fim da contestação, o estado sai, com
--     as tentativas em cascata; contestação aberta segura, fechada há 89 dias segura, fechada há
--     91 apaga; conta a do turno e, até ela existir, a de suspensão do profissional;
--   · o valor do código sai até 1 minuto depois de vencer (job a cada minuto);
--   · a anonimização da conta do profissional leva o estado dos turnos dele;
--   · a rotina diária chama a limpeza.
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-06-01 12:00:00+00', true);
select plan(19);

create temp table ids as
select
  'c8290000-0000-4000-8000-000000000001'::uuid as prof_a_user,
  'c8290000-0000-4000-8000-000000000002'::uuid as prof_b_user,
  'c8290000-0000-4000-8000-000000000003'::uuid as casa_user,
  'c8290000-0000-4000-8000-000000000011'::uuid as prof_a,
  'c8290000-0000-4000-8000-000000000012'::uuid as prof_b,
  'c8290000-0000-4000-8000-000000000021'::uuid as casa;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select prof_a_user, 'profissional'::public.perfil_conta, 'Prof 829 A', '+5561999998291',
       'prof829a@test.invalid', '1992-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz from ids
union all
select prof_b_user, 'profissional'::public.perfil_conta, 'Prof 829 B', '+5561999998292',
       'prof829b@test.invalid', '1993-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz from ids
union all
select casa_user, 'contratante'::public.perfil_conta, 'Casa 829', '+5561999998293',
       'casa829@test.invalid', '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz from ids;
insert into public.profissional (id, usuario_id, ponto_base)
select prof_a, prof_a_user, 'POINT(-47.8800 -15.7700)'::extensions.geography from ids
union all
select prof_b, prof_b_user, 'POINT(-47.8800 -15.7700)'::extensions.geography from ids;
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select casa, 'Bar 829', '80000000000829', 'food_service'::public.tipo_estabelecimento, 'Endereço de teste',
       'POINT(-47.8800 -15.7700)'::extensions.geography from ids;
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select casa_user, casa, 'administrador' from ids;

-- Um turno encerrado do profissional, que terminou `dias` antes de agora, com o estado do código
-- (as duas marcas) e uma tentativa.
create temp table turnos (nome text primary key, id uuid);
create function pg_temp.turno(nome text, prof uuid, dias integer) returns void language plpgsql as $$
declare
  v_fim  timestamptz := '2027-06-01 12:00:00+00'::timestamptz - make_interval(days => dias);
  v_vaga uuid := gen_random_uuid();
  v_pos  uuid := gen_random_uuid();
  v_t    uuid := gen_random_uuid();
begin
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por)
  values (v_vaga, 'c8290000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
          v_fim - interval '5 hours', v_fim, 'Local 829', 'POINT(-47.8800 -15.7700)'::extensions.geography,
          15000, 1, false, false, false, 'Gerente', 'urgencia', 'encerrada', v_fim - interval '2 days',
          gen_random_uuid(), 'c8290000-0000-4000-8000-000000000003');
  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_pos, v_vaga, 'cumprida', prof, v_fim - interval '1 day', v_fim - interval '5 hours', v_fim);
  insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, verificacao, valor_acordado_centavos)
  values (v_t, v_pos, v_fim - interval '5 hours', 'manual', 'nao_verificado', 15000);
  insert into privado.checkin_codigo (turno_id, codigo_exigido, confianca_baixa) values (v_t, true, true);
  insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa)
  values (v_t, v_fim - interval '4 hours', 'recusada', 'acima_de_100_m');
  insert into turnos values (nome, v_t);
end $$;

create function pg_temp.t(nome text) returns uuid language sql as $$ select id from turnos where turnos.nome = t.nome $$;

create function pg_temp.contestacao(turno uuid, usuario uuid, resolvida_ha_dias integer) returns void language sql as $$
  insert into public.ocorrencia (tipo, turno_id, usuario_id, autor_id, motivo, resolvido_em)
  values ('contestacao', turno, usuario, coalesce(usuario, 'c8290000-0000-4000-8000-000000000001'),
          'Contestação 829',
          case when resolvida_ha_dias is not null
               then '2027-06-01 12:00:00+00'::timestamptz - make_interval(days => resolvida_ha_dias) end) $$;

create function pg_temp.restantes() returns text[] language sql as $$
  select coalesce(array_agg(t.nome order by t.nome), '{}')
    from turnos t join privado.checkin_codigo c on c.turno_id = t.id $$;

select pg_temp.turno('t1_fim_89d', (select prof_a from ids), 89);
select pg_temp.turno('t2_fim_91d', (select prof_a from ids), 91);
select pg_temp.turno('t3_contestacao_aberta', (select prof_a from ids), 200);
select pg_temp.turno('t4_contestacao_fechada_89d', (select prof_a from ids), 201);
select pg_temp.turno('t5_contestacao_fechada_91d', (select prof_a from ids), 202);
select pg_temp.turno('t6_suspensao_de_b', (select prof_b from ids), 203);
select pg_temp.contestacao(pg_temp.t('t3_contestacao_aberta'), null, null);
select pg_temp.contestacao(pg_temp.t('t4_contestacao_fechada_89d'), null, 89);
select pg_temp.contestacao(pg_temp.t('t5_contestacao_fechada_91d'), null, 91);
-- A contestação de suspensão grava só usuario_id (20261001100000:555-569).
select pg_temp.contestacao(null, (select prof_b_user from ids), null);

-- ── 1. Os 90 dias ─────────────────────────────────────────────────────────────
select is(privado.limpar_checkin_por_codigo(), 2, 'a limpeza apaga os dois turnos vencidos e devolve quantos saíram');
select is(pg_temp.restantes(),
  array['t1_fim_89d', 't3_contestacao_aberta', 't4_contestacao_fechada_89d', 't6_suspensao_de_b'],
  'fica: fim há 89 dias, contestação aberta, contestação fechada há 89 dias, e a suspensão aberta do profissional; saem: fim há 91 dias e contestação fechada há 91');
select is((select count(*)::int from privado.checkin_codigo_tentativa
            where turno_id in (pg_temp.t('t2_fim_91d'), pg_temp.t('t5_contestacao_fechada_91d'))), 0,
  'as tentativas dos turnos apagados saem em cascata');
select is((select count(*)::int from privado.checkin_codigo_tentativa where turno_id = pg_temp.t('t1_fim_89d')), 1,
  'as tentativas do turno que fica continuam');
select ok((select checkin_tipo = 'manual' and checkin_em is not null and verificacao = 'nao_verificado'
             from public.turno where id = pg_temp.t('t2_fim_91d')),
  'o turno continua, com o tipo e a hora do check-in: só o caminho do código sai');
select ok(not exists (select 1 from privado.checkin_codigo c join turnos t on t.id = c.turno_id
                       join public.posicao p on p.id = (select posicao_id from public.turno where id = t.id)
                      where p.profissional_id = (select prof_a from ids) and t.nome = 't2_fim_91d'),
  'a suspensão aberta de outro profissional não segura os turnos deste');

update public.ocorrencia set resolvido_em = '2027-06-01 12:00:00+00'::timestamptz - interval '89 days'
 where tipo = 'contestacao' and turno_id is null and usuario_id = (select prof_b_user from ids);
select is(privado.limpar_checkin_por_codigo(), 0, 'suspensão do profissional fechada há 89 dias ainda segura');
update public.ocorrencia set resolvido_em = '2027-06-01 12:00:00+00'::timestamptz - interval '91 days'
 where tipo = 'contestacao' and turno_id is null and usuario_id = (select prof_b_user from ids);
select is(privado.limpar_checkin_por_codigo(), 1, 'suspensão do profissional fechada há 91 dias libera a limpeza');
select is(privado.limpar_checkin_por_codigo(30), 0, 'piso de 90 dias: o parâmetro não encurta a guarda');
select is(pg_temp.restantes(), array['t1_fim_89d', 't3_contestacao_aberta', 't4_contestacao_fechada_89d'],
  'depois das três rodadas, ficam só os turnos dentro da guarda');

-- ── 2. O valor vencido ────────────────────────────────────────────────────────
update privado.checkin_codigo set codigo = '482913', gerado_em = '2027-06-01 11:55:00+00', expira_em = '2027-06-01 12:00:00+00'
 where turno_id = pg_temp.t('t1_fim_89d');
update privado.checkin_codigo set codigo = '731904', gerado_em = '2027-06-01 11:55:01+00', expira_em = '2027-06-01 12:00:01+00'
 where turno_id = pg_temp.t('t3_contestacao_aberta');
select is(privado.apagar_codigos_checkin_vencidos(), 1, 'o job apaga um código vencido e devolve quantos');
select is((select array_agg(coalesce(c.codigo, 'apagado') order by t.nome) from privado.checkin_codigo c join turnos t on t.id = c.turno_id
            where t.nome in ('t1_fim_89d', 't3_contestacao_aberta')),
  array['apagado', '731904'], 'sai o código que venceu na hora; fica o que ainda vale 1 segundo');
select ok((select gerado_em is not null and expira_em is not null from privado.checkin_codigo where turno_id = pg_temp.t('t1_fim_89d')),
  'a hora da geração e a validade ficam: só o valor sai');
select is(
  (select row(schedule, command, active)::text from cron.job where jobname = 'apagar_codigos_checkin_vencidos'),
  '("* * * * *","select privado.apagar_codigos_checkin_vencidos()",t)',
  'o job roda a cada minuto, chamando privado.apagar_codigos_checkin_vencidos()');

-- ── 3. A anonimização da conta ────────────────────────────────────────────────
select pg_temp.turno('t7_recente_de_b', (select prof_b from ids), 10);
update public.usuario set nome = 'Conta encerrada', telefone = null, email = null,
       estado = 'anonimizada', anonimizado_em = privado.agora()
 where id = (select prof_a_user from ids);
select is(pg_temp.restantes(), array['t7_recente_de_b'],
  'a anonimização do profissional apaga o estado dos turnos dele, dentro da guarda ou não; o de outro fica');
select is((select count(*)::int from privado.checkin_codigo_tentativa t join turnos x on x.id = t.turno_id
            where x.nome in ('t1_fim_89d', 't3_contestacao_aberta', 't4_contestacao_fechada_89d')), 0,
  'as tentativas do profissional anonimizado saem junto');
select is((select count(*)::int from public.turno where id in (pg_temp.t('t1_fim_89d'), pg_temp.t('t3_contestacao_aberta'))), 2,
  'os turnos do profissional anonimizado continuam, porque são também da casa');

-- ── 4. Na rotina diária e fora do alcance do app ──────────────────────────────
select pg_temp.turno('t8_vencido_de_b', (select prof_b from ids), 100);
select is((privado.executar_retencao_diaria() ->> 'expurgo_checkin_por_codigo')::int, 1,
  'a rotina diária chama a limpeza e devolve expurgo_checkin_por_codigo');

select ok(
  not has_function_privilege('authenticated', 'privado.limpar_checkin_por_codigo(integer, integer)', 'execute')
  and not has_function_privilege('authenticated', 'privado.apagar_codigos_checkin_vencidos()', 'execute')
  and not has_function_privilege('authenticated', 'privado.apagar_checkin_codigo_da_conta()', 'execute')
  and not has_function_privilege('anon', 'privado.limpar_checkin_por_codigo(integer, integer)', 'execute'),
  'as funções da guarda não são executáveis pelo app');

select * from finish();
rollback;
