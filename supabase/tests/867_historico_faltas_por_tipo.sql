-- Histórico privado do titular: tipos, anulação, expurgo e ausência na casa.
begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2026-11-16 12:00:00+00', true);
set local timezone = 'UTC';
select plan(22);
create temp table ids (chave text primary key, id uuid not null);
grant select on ids to authenticated;

do $$
declare
  a         timestamptz := privado.agora();
  v_c_user  uuid := gen_random_uuid();
  v_p_user  uuid := gen_random_uuid();
  v_p_id    uuid;
  v_e_id    uuid;
  v_funcao  uuid := (select id from public.funcao order by id limit 1);
  v_vaga_antiga uuid;
  v_vaga_recente uuid;
  v_pos_id  uuid;
  v_turno_id uuid;
  i         int;
  v_fim_antigo timestamptz := a - interval '5 years' - interval '10 days';
  v_fim_recente timestamptz := a - interval '10 days';
begin
  -- Contratante e profissional
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_c_user, 'contratante', 'Contratante 840', '+5561999984001', 'c_840@teste.com', '1985-01-01', '0.2.68', a),
         (v_p_user, 'profissional', 'Profissional 840', '+5561999984002', 'p_840@teste.com', '1990-01-01', '0.2.68', a);

  insert into public.profissional (usuario_id, perfil, ponto_base)
  values (v_p_user, 'profissional', 'POINT(-47.88 -15.77)'::extensions.geography)
  returning id into v_p_id;

  insert into public.estabelecimento (nome, documento, tipo, endereco, regiao_administrativa, ponto)
  values ('Casa 840', '84084084000184', 'food_service', 'Endereço 840', 'Plano Piloto',
          'POINT(-47.88 -15.77)'::extensions.geography)
  returning id into v_e_id;

  insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
  values (v_e_id, v_c_user, 'administrador');

  insert into ids values ('c_user', v_c_user), ('p_user', v_p_user), ('prof', v_p_id), ('est', v_e_id);

  -- Vaga antiga (> 5 anos)
  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
    responsavel_local, traje, observacoes, modo, estado, chave_cliente, publicado_por)
  values (v_e_id, v_funcao, v_fim_antigo - interval '6 hours', v_fim_antigo, 'Casa Antiga 840',
    'POINT(-47.9100 -15.8300)'::extensions.geography, 15000, 4, false, false, false,
    'Gerente Antigo', 'Preto', 'Observacao Antiga', 'urgencia', 'encerrada', gen_random_uuid(), v_c_user)
  returning id into v_vaga_antiga;
  insert into ids values ('vaga_antiga', v_vaga_antiga);

  -- 3 turnos antigos verificados + 2 avaliações positivas
  for i in 1..3 loop
    insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em)
    values (v_vaga_antiga, v_p_id,
            v_fim_antigo - (i || ' days')::interval - interval '6 hours',
            v_fim_antigo - (i || ' days')::interval,
            'cumprida', v_fim_antigo - (i || ' days')::interval - interval '2 days')
    returning id into v_pos_id;

    insert into public.turno (posicao_id, valor_acordado_centavos, checkin_em, checkin_tipo, checkin_distancia_m, verificacao)
    values (v_pos_id, 15000, v_fim_antigo - (i || ' days')::interval - interval '6 hours', 'geolocalizado', 30, 'verificado')
    returning id into v_turno_id;

    -- Avaliações nos primeiros 2 turnos antigos (ambas positivas)
    if i <= 2 then
      insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
      values (v_turno_id, v_c_user, 'profissional', v_p_id, true);
    end if;
  end loop;

  -- 1 falta antiga (posição com falta e turno sem check-in)
  insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em, falta)
  values (v_vaga_antiga, v_p_id,
          v_fim_antigo - interval '4 days' - interval '6 hours',
          v_fim_antigo - interval '4 days',
          'cancelada', v_fim_antigo - interval '5 days', true)
  returning id into v_pos_id;

  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_pos_id, 15000);

  insert into public.ocorrencia (tipo, posicao_id, usuario_id, autor_id, motivo)
  values ('cancelamento', v_pos_id, v_p_user, v_c_user, 'reabertura_por_atraso');

  -- Vaga recente (< 5 anos, ex: 10 dias)
  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
    responsavel_local, traje, observacoes, modo, estado, chave_cliente, publicado_por)
  values (v_e_id, v_funcao, v_fim_recente - interval '15 days', v_fim_recente, 'Casa Recente 840',
    'POINT(-47.9100 -15.8300)'::extensions.geography, 15000, 8, false, false, false,
    'Gerente Recente', 'Preto', 'Observacao Recente', 'urgencia', 'encerrada', gen_random_uuid(), v_c_user)
  returning id into v_vaga_recente;
  insert into ids values ('vaga_recente', v_vaga_recente);

  -- 7 turnos recentes verificados + 6 avaliações (5 positivas e 1 negativa)
  for i in 1..7 loop
    insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em)
    values (v_vaga_recente, v_p_id,
            v_fim_recente - (i || ' days')::interval - interval '6 hours',
            v_fim_recente - (i || ' days')::interval,
            'cumprida', v_fim_recente - (i || ' days')::interval - interval '2 days')
    returning id into v_pos_id;

    insert into public.turno (posicao_id, valor_acordado_centavos, checkin_em, checkin_tipo, checkin_distancia_m, verificacao)
    values (v_pos_id, 15000, v_fim_recente - (i || ' days')::interval - interval '6 hours', 'geolocalizado', 30, 'verificado')
    returning id into v_turno_id;

    -- Avaliações em 6 dos 7 turnos: turnos 1..5 positivos, turno 6 negativo
    if i <= 5 then
      insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
      values (v_turno_id, v_c_user, 'profissional', v_p_id, true);
    elsif i = 6 then
      insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
      values (v_turno_id, v_c_user, 'profissional', v_p_id, false);
    end if;
  end loop;

  -- 1 falta recente
  insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em, falta)
  values (v_vaga_recente, v_p_id,
          v_fim_recente - interval '8 days' - interval '6 hours',
          v_fim_recente - interval '8 days',
          'cancelada', v_fim_recente - interval '9 days', true)
  returning id into v_pos_id;

  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_pos_id, 15000);
  insert into public.ocorrencia (tipo, posicao_id, usuario_id, autor_id, motivo)
  values ('cancelamento', v_pos_id, v_p_user, v_c_user, 'no_show_sem_checkin');
end $$;


-- Fixture antiga: reabertura por atraso; recente: no-show.
-- Terceira falta: desistência em cima da hora, com trilha canônica.
with p as (
 insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em, falta)
 values ((select id from ids where chave='vaga_recente'), (select id from ids where chave='prof'),
 privado.agora()-interval '2 days', privado.agora()-interval '1 day 18 hours', 'cancelada', privado.agora()-interval '3 days', true)
 returning id
) insert into ids select 'cancelamento_tardio', id from p;
insert into public.turno(posicao_id, valor_acordado_centavos) values ((select id from ids where chave='cancelamento_tardio'),15000);
insert into public.ocorrencia(tipo,posicao_id,usuario_id,autor_id,motivo,criada_em)
 values ('cancelamento',(select id from ids where chave='cancelamento_tardio'),(select id from ids where chave='p_user'),
 (select id from ids where chave='p_user'),'Imprevisto sintético',privado.agora()-interval '2 days 1 hour');

select is(privado.historico_faltas((select id from ids where chave='prof')),
 '{"nao_compareceu":2,"cancelou_menos_24h":1}'::jsonb,'reabertura e no-show somam não compareceu; desistência fica separada');
select set_config('request.jwt.claims',json_build_object('sub',(select id from ids where chave='p_user'))::text,true);
set local role authenticated;
select is(public.meu_perfil_profissional()->'historico_faltas',
 '{"nao_compareceu":2,"cancelou_menos_24h":1}'::jsonb,'titular recebe contagem por tipo');
select ok(not (public.meu_perfil_profissional()->'reputacao' ? 'historico_faltas'),'não polui schema compartilhado Reputacao');
select throws_ok($$ select privado.historico_faltas((select id from ids where chave='prof')) $$,'42501',null,'cliente não chama helper privado por id');
reset role;
select set_config('request.jwt.claims',json_build_object('sub',(select id from ids where chave='c_user'))::text,true);
set local role authenticated;
select ok(not (public.perfil_publico((select id from ids where chave='prof')) ? 'historico_faltas'),'casa não recebe contadores na raiz pública');
select ok(not (public.perfil_publico((select id from ids where chave='prof'))->'reputacao' ? 'historico_faltas'),'casa não recebe contadores na reputação');
select throws_ok($$ select public.meu_perfil_profissional() $$,'PGRST',null,'casa não acessa perfil próprio do profissional');
reset role;
insert into privado.conta_equipe(usuario_id) values ((select id from ids where chave='c_user')) on conflict do nothing;
select privado.anular_falta((select id from ids where chave='cancelamento_tardio'),'Contestação sintética deferida',(select id from ids where chave='c_user'));
select is(privado.historico_faltas((select id from ids where chave='prof')),
 '{"nao_compareceu":2,"cancelou_menos_24h":0}'::jsonb,'falta anulada sai da contagem');
select ok(not (select falta from public.posicao where id=(select id from ids where chave='cancelamento_tardio')),'anulação mantém flag canônica falsa');
-- Outra desistência, já antiga: o expurgo deve guardar os DOIS tipos.
with p as (
 insert into public.posicao(vaga_id,profissional_id,inicio_em,fim_em,estado,confirmado_em,falta)
 values ((select id from ids where chave='vaga_antiga'),(select id from ids where chave='prof'),
 privado.agora()-interval '6 years 6 hours',privado.agora()-interval '6 years','cancelada',privado.agora()-interval '6 years 1 day',true)
 returning id
) insert into ids select 'cancelamento_antigo',id from p;
insert into public.turno(posicao_id,valor_acordado_centavos) values ((select id from ids where chave='cancelamento_antigo'),15000);
insert into public.ocorrencia(tipo,posicao_id,usuario_id,autor_id,motivo,criada_em)
 values ('cancelamento',(select id from ids where chave='cancelamento_antigo'),(select id from ids where chave='p_user'),
 (select id from ids where chave='p_user'),'Imprevisto sintético antigo',privado.agora()-interval '6 years 7 hours');
select is(privado.historico_faltas((select id from ids where chave='prof')),
 '{"nao_compareceu":2,"cancelou_menos_24h":1}'::jsonb,'desistência antiga tem tipo próprio antes do expurgo');
select is(privado.historico_faltas(gen_random_uuid()),'{"nao_compareceu":0,"cancelou_menos_24h":0}'::jsonb,'sem histórico produz zeros');
select privado.reconciliar_comparecimento();
create temp table taxa_antes as select taxa_comparecimento from public.profissional where id=(select id from ids where chave='prof');
select privado.expurgar_turnos_antigos();
select is(privado.historico_faltas((select id from ids where chave='prof')),
 '{"nao_compareceu":2,"cancelou_menos_24h":1}'::jsonb,'expurgo preserva exatamente o histórico tipado');
select is((select nao_compareceu from privado.profissional_reputacao_expurgada where profissional_id=(select id from ids where chave='prof')),1,'R9 guarda tipo da falta antiga antes de apagar trilha');
select is((select cancelou_menos_24h from privado.profissional_reputacao_expurgada where profissional_id=(select id from ids where chave='prof')),1,'R9 preserva desistência sem confundir com não comparecimento');
select is(privado.expurgar_turnos_antigos(),0,'segundo expurgo não duplica');
select privado.recalcular_comparecimento((select id from ids where chave='prof'));
select is((select taxa_comparecimento from public.profissional where id=(select id from ids where chave='prof')),(select taxa_comparecimento from taxa_antes),'taxa preservada após expurgo e recálculo');
select throws_ok($$ update privado.profissional_reputacao_expurgada set nao_compareceu=-1, cancelou_menos_24h=3 where profissional_id=(select id from ids where chave='prof') $$,'23514',null,'contador negativo recusado');
select throws_ok($$ update privado.profissional_reputacao_expurgada set cancelou_menos_24h=2 where profissional_id=(select id from ids where chave='prof') $$,'23514',null,'soma dos tipos deve ser total de faltas');
-- A soma tipada e os dois tipos >=0 já implicam faltas>=0. Para exercitar
-- a guarda antiga isoladamente, suspendemos SOMENTE a coerência nesta transação
-- de teste; o CHECK volta imediatamente e o rollback final restaura tudo.
alter table privado.profissional_reputacao_expurgada drop constraint faltas_tipos_coerentes;
select throws_ok($$ update privado.profissional_reputacao_expurgada set faltas=-1 where profissional_id=(select id from ids where chave='prof') $$,'23514',null,'total negativo recusado pela guarda própria, sem mascaramento pela soma');
alter table privado.profissional_reputacao_expurgada add constraint faltas_tipos_coerentes check (faltas = nao_compareceu + cancelou_menos_24h);
select throws_ok($$ update privado.profissional_reputacao_expurgada set nao_compareceu=3, cancelou_menos_24h=-1 where profissional_id=(select id from ids where chave='prof') $$,'23514',null,'segundo tipo negativo recusado mesmo com soma válida');
select ok(not has_table_privilege('authenticated','privado.profissional_reputacao_expurgada','select'),'R9 segue privado');
select ok(not has_function_privilege('anon','public.perfil_profissional_em_json(public.profissional)','execute'),'moldador de perfil segue sem acesso anônimo');
select * from finish();
rollback;
