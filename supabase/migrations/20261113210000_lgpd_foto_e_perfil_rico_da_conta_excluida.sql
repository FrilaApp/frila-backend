-- A conta excluída perde também a foto (e as outras mídias dela) e o perfil rico na limpeza dos 15
-- dias (Bússola, condição para ligar a foto; LGPD art. 16 e 18, VI; B-019, pacote 10).
--
-- Até aqui, privado.limpar_contas_anonimizadas (20261107350000) não tocava em privado.midia, em
-- public.profissional_regiao, em public.profissional_servico nem em profissional.atende_todo_df, e
-- privado.expurgar_midias_recusadas só expurga foto recusada. A foto some da tela quando a conta é
-- anonimizada (foto_de_perfil_projecao exige a conta ativa), mas os arquivos e a linha ficavam.
--
-- Passo novo na rotina diária, privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(15), para
-- toda conta anonimizada há 15 dias ou mais:
--   1. cada mídia da própria pessoa (estabelecimento_id nulo; a foto e o logo da casa são da casa)
--      ainda não removida vira 'removida' e entra na fila expurgo_midia com o original e a
--      miniatura, a mesma mensagem de public.remover_midia. A Edge Function expurgar-midias apaga
--      os dois arquivos do bucket midia-perfil e confirma ('expurgada');
--   2. a linha de privado.midia sai depois de expurgada, quando nenhum pedido dela espera na fila
--      (sem isso, a validação do expurgo não acharia a linha e os arquivos ficariam). Com ela saem,
--      por on delete cascade, as linhas de privado.moderacao_chamada da mídia; a ocorrencia.midia_id
--      vira nula (on delete set null);
--   3. perfil rico: as regiões (profissional_regiao), os serviços com preço (profissional_servico, e
--      por cascata as especialidades) e atende_todo_df = false.
-- Idempotente: a 2ª rodada não acha nada. Um passo próprio, como os outros, com o bloco de exceção
-- da rotina (uma falha não para os demais).
--
-- Sem mudança de superfície: nenhuma função de public mudou.

select set_config('lock_timeout', '2s', true);

create or replace function privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(p_dias integer default 15)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_corte      timestamptz;
  r            record;
  v_enfileiradas integer := 0;
  v_linhas     integer := 0;
  v_regioes    integer := 0;
  v_servicos   integer := 0;
  v_todo_df    integer := 0;
begin
  if p_dias is null or p_dias < 1 then
    raise exception 'p_dias inválido: %', p_dias;
  end if;
  v_corte := privado.agora() - make_interval(days => p_dias);
  perform set_config('privado.retencao', 'on', true);

  -- 1. As mídias da pessoa: removida + expurgo físico (original e miniatura)
  for r in
    select m.id, m.storage_path
      from privado.midia m
      join public.usuario u on u.id = m.dono_usuario_id
     where u.estado = 'anonimizada'
       and u.anonimizado_em <= v_corte
       and m.estabelecimento_id is null
       and m.estado not in ('removida', 'expurgada')
     for update of m skip locked
  loop
    update privado.midia set estado = 'removida', atualizado_em = privado.agora() where id = r.id;
    perform pgmq.send(
      'expurgo_midia',
      jsonb_build_object(
        'verificacao_id', r.id::text,
        'bucket', 'midia-perfil',
        'caminhos', jsonb_build_array(r.storage_path, replace(r.storage_path, '.jpg', '_thumb.jpg')),
        'origem', 'foto_perfil'
      )
    );
    v_enfileiradas := v_enfileiradas + 1;
  end loop;

  -- 2. A linha sai depois de expurgada, sem pedido dela na fila
  delete from privado.midia m
   using public.usuario u
   where u.id = m.dono_usuario_id
     and u.estado = 'anonimizada'
     and u.anonimizado_em <= v_corte
     and m.estabelecimento_id is null
     and m.estado = 'expurgada'
     and not exists (select 1 from pgmq.q_expurgo_midia q where q.message ->> 'verificacao_id' = m.id::text);
  get diagnostics v_linhas = row_count;

  -- 3. O perfil rico
  delete from public.profissional_regiao pr
   using public.profissional p, public.usuario u
   where pr.profissional_id = p.id and p.usuario_id = u.id
     and u.estado = 'anonimizada' and u.anonimizado_em <= v_corte;
  get diagnostics v_regioes = row_count;

  delete from public.profissional_servico ps
   using public.profissional p, public.usuario u
   where ps.profissional_id = p.id and p.usuario_id = u.id
     and u.estado = 'anonimizada' and u.anonimizado_em <= v_corte;
  get diagnostics v_servicos = row_count;

  update public.profissional p
     set atende_todo_df = false
    from public.usuario u
   where p.usuario_id = u.id and p.atende_todo_df
     and u.estado = 'anonimizada' and u.anonimizado_em <= v_corte;
  get diagnostics v_todo_df = row_count;

  return jsonb_build_object(
    'midias_enfileiradas', v_enfileiradas,
    'midias_apagadas',     v_linhas,
    'regioes_apagadas',    v_regioes,
    'servicos_apagados',   v_servicos,
    'atende_todo_df_desligado', v_todo_df);
end $$;

comment on function privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(integer) is
  'LGPD art. 16 e 18, VI (B-019): para conta anonimizada há p_dias (15) ou mais, põe cada mídia da pessoa (estabelecimento_id nulo) em removida e na fila expurgo_midia (original e miniatura, bucket midia-perfil), apaga a linha já expurgada sem pedido na fila, e apaga o perfil rico (profissional_regiao, profissional_servico) e desliga atende_todo_df. Idempotente. Passo da rotina diária.';

revoke execute on function privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(integer) from public, anon, authenticated;
grant  execute on function privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(integer) to service_role;

-- A rotina diária ganha o passo, logo depois da limpeza das contas. O corpo é o da 20261109200000
-- com só a linha nova.

create or replace function privado.executar_retencao_diaria()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- (chave do resultado, chamada). As chamadas são fixas e qualificadas; nada vem de fora.
  c_passos constant text[][] := array[
    ['contas_anonimizadas_limpas',       'privado.limpar_contas_anonimizadas(15)'],
    ['foto_e_perfil_rico_de_contas_excluidas', 'privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(15)'],
    ['higiene',                          'privado.higienizar_tabelas()'],
    ['eventos_app_limpos',               'privado.limpar_eventos_app(90)'],
    ['expurgo_midia_identidade',         'privado.expurgar_midias_verificacao_identidade()'],
    ['expurgo_midia_perfil',             'privado.expurgar_midias_recusadas()'],
    ['expurgo_chamadas_nao_aceitas',     'privado.limpar_chamadas_expurgadas(90)'],
    ['expurgo_checkin_por_codigo',       'privado.limpar_checkin_por_codigo(90, 500)'],
    ['expurgo_equipe_confianca',         'privado.expurgar_equipe_confianca_inativa(5, 500)'],
    ['expurgo_turnos_antigos',           'privado.expurgar_turnos_antigos(5, 500)'],
    ['expurgo_vagas_antigas',            'privado.expurgar_vagas_antigas(5, 500)'],
    ['anonimizacao_ocorrencias_antigas', 'privado.anonimizar_ocorrencias_antigas(5, 500)'],
    ['expurgo_marcas_notificacao',       'privado.limpar_marcas_notificacao(5, 1000)'],
    ['expurgo_registros_acesso',         'privado.limpar_registros_acesso(6, 1000)'],
    ['expurgo_inventario_leituras',      'privado.limpar_inventario_leituras_registro_acesso(5, 1000)']
  ];
  v_resultado jsonb := jsonb_build_object('executado_em', privado.agora());
  v_falhas    jsonb := '[]'::jsonb;
  v_valor     jsonb;
begin
  for i in 1 .. array_length(c_passos, 1) loop
    begin
      execute format('select to_jsonb(%s)', c_passos[i][2]) into v_valor;
    exception when others then
      v_valor := null;
      v_falhas := v_falhas || jsonb_build_object('passo', c_passos[i][1], 'sqlstate', sqlstate);
      begin
        perform privado.registrar_falha_execucao('executar_retencao_diaria', 'retencao_passo_falhou',
          jsonb_build_object('passo', c_passos[i][1], 'sqlstate', sqlstate));
      exception when others then
        null;  -- a falha segue no retorno ('falhas'); o registro não pode parar a rotina
      end;
    end;
    v_resultado := v_resultado || jsonb_build_object(c_passos[i][1], v_valor);
  end loop;

  return v_resultado || jsonb_build_object('falhas', v_falhas);
end $$;


comment on function privado.executar_retencao_diaria() is
  'Rotina diária consolidada de retenção e limpeza: contas anonimizadas (15 dias) e, das mesmas contas, a foto, as outras mídias da pessoa e o perfil rico (regiões, serviços, atende_todo_df; B-019), higiene de tabelas, eventos do app (90 dias), expurgo de mídias de identidade e fotos recusadas (24 h), chamadas não aceitas (90 dias), o estado do check-in por código (90 dias depois do mais tarde entre o fim do turno e o fim da contestação, 0.2.68), equipe de confiança inativa (5 anos sem turnos juntos), turnos com mais de 5 anos e o contexto deles (vaga, chamada, despacho, posição sem turno, ocorrência de denúncia e cancelamento, marcas de notificação e trilha; LGPD-J6 fases 1 e 2), registros de acesso à aplicação com mais de 6 meses (Marco Civil art. 15) e o inventário das leituras deles com mais de 5 anos (Decreto 8.771, art. 13, III). Cada passo roda num bloco de exceção próprio: um passo que falha é desfeito, vai para privado.falha_execucao (executar_retencao_diaria / retencao_passo_falhou, com o passo e o SQLSTATE) e para a chave falhas do retorno, e os outros passos rodam mesmo assim.';

revoke execute on function privado.executar_retencao_diaria() from public, anon, authenticated;
grant  execute on function privado.executar_retencao_diaria() to service_role;
