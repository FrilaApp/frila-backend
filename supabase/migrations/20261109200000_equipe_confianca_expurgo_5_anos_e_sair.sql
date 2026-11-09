-- 20261109200000_equipe_confianca_expurgo_5_anos_e_sair.sql
--
-- Equipe de confiança:
--   1. RPC public.sair_da_equipe(estabelecimento_id uuid) -> jsonb
--      Autoexclusão voluntária do profissional da equipe de confiança de um estabelecimento (LGPD art. 18).
--   2. Expurgo na rotina diária de retenção (privado.executar_retencao_diaria):
--      Remove ligações onde o último turno verificado/cumprido ocorreu há mais de 5 anos,
--      ou onde a inclusão ocorreu há mais de 5 anos sem turnos nos últimos 5 anos.
--
-- Requisitos: RF18, RN16, UC11, LGPD art. 18. Contrato 0.2.72.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. RPC public.sair_da_equipe
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.sair_da_equipe(
  estabelecimento_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid             uuid := (select auth.uid());
  v_profissional_id uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  -- RN25: apenas o próprio profissional pode pedir sua autoexclusão da equipe
  v_profissional_id := privado.meu_profissional_id();
  if v_profissional_id is null then
    perform public.erro(403, 'sem_permissao');
  end if;

  if sair_da_equipe.estabelecimento_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'estabelecimento_id');
  end if;

  if not exists (
    select 1
      from public.equipe_confianca ec
     where ec.estabelecimento_id = sair_da_equipe.estabelecimento_id
       and ec.profissional_id = v_profissional_id
  ) then
    perform public.erro(422, 'campo_invalido', 'estabelecimento_id');
  end if;

  -- Remove a ligação sem penalidade nem aviso à casa (RN16, LGPD art. 18)
  delete from public.equipe_confianca ec
   where ec.estabelecimento_id = sair_da_equipe.estabelecimento_id
     and ec.profissional_id = v_profissional_id;

  return jsonb_build_object();
end $$;

comment on function public.sair_da_equipe(uuid) is
  'Profissional sai voluntariamente da equipe de confiança de um estabelecimento (LGPD art. 18, direito de autoexclusão). Sem penalidade nem aviso à casa.';

revoke execute on function public.sair_da_equipe(uuid) from public, anon;
grant  execute on function public.sair_da_equipe(uuid) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Expurgo de equipe de confiança inativa (5 anos sem turnos juntos)
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function privado.expurgar_equipe_confianca_inativa(
  p_anos   integer default 5,
  p_limite integer default 500
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limite_data timestamptz;
  v_total       integer := 0;
  v_lote        integer;
  v_lotes       integer := 0;
  c_teto_lotes  constant integer := 100;
begin
  -- Salvaguarda: piso de 5 anos que nenhum parâmetro encurta
  if p_anos is null or p_anos < 5 then
    p_anos := 5;
  end if;
  if p_limite is null or p_limite < 1 then
    p_limite := 500;
  end if;

  v_limite_data := privado.agora() - make_interval(years => p_anos);

  loop
    with alvos as (
      select ec.estabelecimento_id, ec.profissional_id
        from public.equipe_confianca ec
       where not exists (
         -- nenhum turno verificado nos últimos 5 anos
         select 1
           from public.turno t
           join public.posicao pos on pos.id = t.posicao_id
           join public.vaga v on v.id = pos.vaga_id
          where pos.profissional_id = ec.profissional_id
            and v.estabelecimento_id = ec.estabelecimento_id
            and t.verificacao = 'verificado'
            and pos.fim_em >= v_limite_data
       )
       and (
         -- o último turno verificado ocorreu há mais de 5 anos
         exists (
           select 1
             from public.turno t
             join public.posicao pos on pos.id = t.posicao_id
             join public.vaga v on v.id = pos.vaga_id
            where pos.profissional_id = ec.profissional_id
              and v.estabelecimento_id = ec.estabelecimento_id
              and t.verificacao = 'verificado'
              and pos.fim_em < v_limite_data
         )
         -- ou a data de inclusão/criação tem mais de 5 anos e não houve turno nos últimos 5 anos
         or ec.adicionado_em < v_limite_data
       )
       limit p_limite
       for update of ec skip locked
    )
    delete from public.equipe_confianca ec
     using alvos a
     where ec.estabelecimento_id = a.estabelecimento_id
       and ec.profissional_id = a.profissional_id;

    get diagnostics v_lote = row_count;
    v_total := v_total + v_lote;
    v_lotes := v_lotes + 1;
    exit when v_lote < p_limite or v_lotes >= c_teto_lotes;
  end loop;

  return v_total;
end $$;

comment on function privado.expurgar_equipe_confianca_inativa(integer, integer) is
  'Expurga da equipe de confiança (public.equipe_confianca) vínculos sem turnos verificados nos últimos 5 anos cujo último turno ou adição ocorreu há mais de 5 anos. Chamada por privado.executar_retencao_diaria.';

revoke all on function privado.expurgar_equipe_confianca_inativa(integer, integer) from public, anon, authenticated;
grant execute on function privado.expurgar_equipe_confianca_inativa(integer, integer) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Consolidação na rotina diária de retenção e limpeza
-- ─────────────────────────────────────────────────────────────────────────────

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
  'Rotina diária consolidada de retenção e limpeza: contas anonimizadas (15 dias), higiene de tabelas, eventos do app (90 dias), expurgo de mídias de identidade e fotos recusadas (24 h), chamadas não aceitas (90 dias), o estado do check-in por código (90 dias depois do mais tarde entre o fim do turno e o fim da contestação, 0.2.68), equipe de confiança inativa (5 anos sem turnos juntos), turnos com mais de 5 anos e o contexto deles (vaga, chamada, despacho, posição sem turno, ocorrência de denúncia e cancelamento, marcas de notificação e trilha; LGPD-J6 fases 1 e 2), registros de acesso à aplicação com mais de 6 meses (Marco Civil art. 15) e o inventário das leituras deles com mais de 5 anos (Decreto 8.771, art. 13, III). Cada passo roda num bloco de exceção próprio: um passo que falha é desfeito, vai para privado.falha_execucao (executar_retencao_diaria / retencao_passo_falhou, com o passo e o SQLSTATE) e para a chave falhas do retorno, e os outros passos rodam mesmo assim.';

revoke execute on function privado.executar_retencao_diaria() from public, anon, authenticated;
grant  execute on function privado.executar_retencao_diaria() to service_role;
