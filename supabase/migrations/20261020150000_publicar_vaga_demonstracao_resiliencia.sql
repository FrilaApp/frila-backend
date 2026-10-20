-- Resiliência de publicar_vaga para conta de demonstração e semeadura pós-06/11 (Cartão 5boVdM0t).
--
-- 1. `public.publicar_vaga`:
--    - Contas de demonstração não enfileiram mensagens em pgmq.q_despacho (mantém isolamento estrito
--      e elimina dependência de transporte/agendador_secret/pg_net para a revisão da App Store).
--    - Fallback de regiao_administrativa para 'Plano Piloto' se omitida pela conta de demonstração.
--    - Fallback e tolerância de associação com o estabelecimento de demonstração ('Bar da Revisão').
--
-- 2. `privado.renovar_dados_demonstracao`:
--    - Resolve os UIDs das contas de demonstração em auth.users se já existirem previamente com outros IDs,
--      garantindo que o JWT emitido pelo Supabase Auth case com membro_estabelecimento e public.usuario.
--
-- 3. `privado.semear_vagas_demonstracao`:
--    - Semeadura idempotente de N vagas futuras abertas pós-06/11 (>= 2026-11-20) com M posições
--      para destravar os testes de desempenho do app iOS ("Lista cheia" e "Detalhe 20x").

-- ── 1. Resiliência em publicar_vaga ──────────────────────────────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.publicar_vaga 0.2.45

create or replace function public.publicar_vaga(
  estabelecimento_id      uuid,
  funcao_id               uuid,
  inicio_em               timestamptz,
  fim_em                  timestamptz,
  local                   text,
  ponto                   jsonb,
  valor_centavos          bigint,
  posicoes                integer,
  inclui_refeicao         boolean,
  inclui_transporte       boolean,
  exige_material_proprio  boolean,
  responsavel_local       text,
  modo                    public.modo_preenchimento,
  chave                   uuid,
  traje                   text    default null,
  participa_rateio        boolean default null,
  observacoes             text    default null,
  alerta_antecedencia_min int     default 180,
  regiao_administrativa   text    default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_estab_id  uuid;
  v_local     text := btrim(publicar_vaga.local);
  v_resp      text := btrim(publicar_vaga.responsavel_local);
  v_traje     text := btrim(publicar_vaga.traje);
  v_obs       text := btrim(publicar_vaga.observacoes);
  v_regiao    text;
  v_agora     timestamptz;
  v_ponto     extensions.geography;
  v_vaga      public.vaga%rowtype;
  v_posicoes  uuid[];
  v_eh_demo   boolean;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('contratante');

  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  v_eh_demo := privado.conta_de_demonstracao();

  -- Resolução resiliente do estabelecimento para demonstração
  if publicar_vaga.estabelecimento_id is null and v_eh_demo then
    select m.estabelecimento_id into v_estab_id
      from public.membro_estabelecimento m
     where m.usuario_id = v_uid
     limit 1;
    if v_estab_id is null then
      v_estab_id := 'de000000-0000-4000-8000-000000000010'::uuid;
    end if;
  else
    v_estab_id := publicar_vaga.estabelecimento_id;
  end if;

  if v_eh_demo and not privado.eh_membro(v_estab_id) then
    insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
    values (v_uid, v_estab_id, 'administrador')
    on conflict do nothing;
  end if;

  if not privado.eh_membro(v_estab_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- RN02: vaga incompleta não existe
  if publicar_vaga.funcao_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'funcao_id');
  end if;
  if publicar_vaga.inicio_em is null then
    perform public.erro(422, 'campo_obrigatorio', 'inicio_em');
  end if;
  if publicar_vaga.fim_em is null then
    perform public.erro(422, 'campo_obrigatorio', 'fim_em');
  end if;
  if v_local is null or v_local = '' then
    perform public.erro(422, 'campo_obrigatorio', 'local');
  end if;
  if v_resp is null or v_resp = '' then
    perform public.erro(422, 'campo_obrigatorio', 'responsavel_local');
  end if;
  if publicar_vaga.valor_centavos is null then
    perform public.erro(422, 'campo_obrigatorio', 'valor_centavos');
  end if;
  if publicar_vaga.posicoes is null then
    perform public.erro(422, 'campo_obrigatorio', 'posicoes');
  end if;
  if publicar_vaga.inclui_refeicao is null then
    perform public.erro(422, 'campo_obrigatorio', 'inclui_refeicao');
  end if;
  if publicar_vaga.inclui_transporte is null then
    perform public.erro(422, 'campo_obrigatorio', 'inclui_transporte');
  end if;
  if publicar_vaga.exige_material_proprio is null then
    perform public.erro(422, 'campo_obrigatorio', 'exige_material_proprio');
  end if;
  if publicar_vaga.modo is null then
    perform public.erro(422, 'campo_obrigatorio', 'modo');
  end if;
  if publicar_vaga.chave is null then
    perform public.erro(422, 'campo_obrigatorio', 'chave');
  end if;

  -- Região administrativa: informada na publicação ou herdada do estabelecimento
  if publicar_vaga.regiao_administrativa is not null then
    v_regiao := btrim(publicar_vaga.regiao_administrativa);
    if v_regiao = '' then
      if v_eh_demo then
        v_regiao := 'Plano Piloto';
      else
        perform public.erro(422, 'campo_obrigatorio', 'regiao_administrativa');
      end if;
    end if;
  else
    select e.regiao_administrativa into v_regiao
      from public.estabelecimento e
     where e.id = v_estab_id;
    if v_regiao is null or btrim(v_regiao) = '' then
      if v_eh_demo then
        v_regiao := 'Plano Piloto';
      else
        perform public.erro(422, 'campo_obrigatorio', 'regiao_administrativa');
      end if;
    end if;
  end if;

  if publicar_vaga.valor_centavos <= 0 then
    perform public.erro(422, 'campo_invalido', 'valor_centavos');
  end if;
  if publicar_vaga.posicoes < 1 or publicar_vaga.posicoes > 200 then
    perform public.erro(422, 'campo_invalido', 'posicoes');
  end if;
  if publicar_vaga.alerta_antecedencia_min is null
     or publicar_vaga.alerta_antecedencia_min < 1 then
    perform public.erro(422, 'campo_invalido', 'alerta_antecedencia_min');
  end if;

  if not exists (select 1 from public.funcao f where f.id = publicar_vaga.funcao_id) then
    perform public.erro(422, 'campo_invalido', 'funcao_id');
  end if;

  v_agora := privado.agora();

  if publicar_vaga.fim_em <= publicar_vaga.inicio_em then
    perform public.erro(422, 'horario_invalido');
  end if;
  if publicar_vaga.inicio_em <= v_agora then
    perform public.erro(422, 'horario_invalido');
  end if;

  -- RN24: o modo seleção fecha sozinho 24 horas antes do início
  if publicar_vaga.modo = 'selecao'
     and publicar_vaga.inicio_em <= v_agora + interval '24 hours' then
    perform public.erro(422, 'selecao_sem_antecedencia');
  end if;

  -- Diretriz 1.2 da App Store nos campos livres da vaga
  perform privado.exigir_texto_aceitavel(jsonb_build_object(
    'local',                 v_local,
    'regiao_administrativa', v_regiao,
    'responsavel_local',     v_resp,
    'traje',                 v_traje,
    'observacoes',           v_obs));

  v_ponto := privado.ponto_do_json(publicar_vaga.ponto, 'ponto');

  -- RF04: chave de idempotência do cliente
  select * into v_vaga
    from public.vaga g
   where g.estabelecimento_id = v_estab_id
     and g.chave_cliente = publicar_vaga.chave;

  if found then
    select array_agg(p.id order by p.id) into v_posicoes
      from public.posicao p where p.vaga_id = v_vaga.id;
    return jsonb_build_object('vaga_id', v_vaga.id,
                              'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[])));
  end if;

  begin
    insert into public.vaga (
      estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa, ponto,
      valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
      exige_material_proprio, responsavel_local, traje, participa_rateio,
      observacoes, modo, alerta_antecedencia, publicado_por, chave_cliente)
    values (
      v_estab_id, publicar_vaga.funcao_id,
      publicar_vaga.inicio_em, publicar_vaga.fim_em, v_local, v_regiao, v_ponto,
      publicar_vaga.valor_centavos, publicar_vaga.posicoes,
      publicar_vaga.inclui_refeicao, publicar_vaga.inclui_transporte,
      publicar_vaga.exige_material_proprio, v_resp,
      nullif(v_traje, ''), publicar_vaga.participa_rateio, nullif(v_obs, ''),
      publicar_vaga.modo,
      make_interval(mins => publicar_vaga.alerta_antecedencia_min),
      v_uid, publicar_vaga.chave)
    returning * into v_vaga;
  exception
    when unique_violation then
      select * into v_vaga
        from public.vaga g
       where g.estabelecimento_id = v_estab_id
         and g.chave_cliente = publicar_vaga.chave;
      select array_agg(p.id order by p.id) into v_posicoes
        from public.posicao p where p.vaga_id = v_vaga.id;
      return jsonb_build_object('vaga_id', v_vaga.id,
                                'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[])));
  end;

  insert into public.posicao (vaga_id, inicio_em, fim_em)
  select v_vaga.id, v_vaga.inicio_em, v_vaga.fim_em
    from generate_series(1, publicar_vaga.posicoes);

  select array_agg(p.id order by p.id) into v_posicoes
    from public.posicao p where p.vaga_id = v_vaga.id;

  -- Isolamento de demonstração: contas de demonstração não entram na fila de despacho,
  -- protegendo a revisão contra falhas externas de transporte/segredo e sem notificar terceiros.
  if not v_eh_demo then
    perform pgmq.send('despacho', jsonb_build_object(
      'vaga_id',      v_vaga.id,
      'publicada_em', v_vaga.publicado_em));
  end if;

  return jsonb_build_object('vaga_id', v_vaga.id, 'posicoes', to_jsonb(v_posicoes));
end $$;

comment on function public.publicar_vaga(
  uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int, text
) is
  'Publica vaga e cria as posições pedidas (RN02, RN03). Enfileira o despacho em pgmq para contas reais (B15). Isolamento para conta de demonstração (5boVdM0t). Reenvio seguro por chave_cliente (RF04).';

revoke execute on function public.publicar_vaga(
  uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int, text
) from public, anon;

grant execute on function public.publicar_vaga(
  uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int, text
) to authenticated;

-- ── 2. Renovação de dados de demonstração com resolução dinâmica de UID ───────

create or replace function privado.renovar_dados_demonstracao(
  agora timestamptz default privado.agora()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora              timestamptz := coalesce(agora, privado.agora());
  v_aberta_inicio      timestamptz := v_agora + interval '5 days';
  v_aberta_fim         timestamptz := v_agora + interval '5 days 6 hours';
  v_preenchida_inicio  timestamptz := v_agora + interval '2 days';
  v_preenchida_fim     timestamptz := v_agora + interval '2 days 6 hours';
  v_contratante_uid    uuid;
  v_profissional_uid   uuid;
  v_estabelecimento_id uuid := 'de000000-0000-4000-8000-000000000010'::uuid;
  v_vaga_aberta_id     uuid := 'de000000-0000-4000-8000-000000000020'::uuid;
  v_vaga_preenchida_id uuid := 'de000000-0000-4000-8000-000000000021'::uuid;
  v_pos_aberta_id      uuid := 'de000000-0000-4000-8000-000000000030'::uuid;
  v_pos_confirmada_id  uuid := 'de000000-0000-4000-8000-000000000031'::uuid;
  v_prof_id            uuid;
  v_funcao_garcom      uuid;
  v_funcao_bartender   uuid;
begin
  -- 1. Resolve UIDs existentes em auth.users ou adota os canônicos de000000-...
  select id into v_contratante_uid
    from auth.users
   where lower(email) = 'revisao-contratante@frila.app'
   order by created_at asc
   limit 1;

  if v_contratante_uid is null then
    v_contratante_uid := 'de000000-0000-4000-8000-000000000001'::uuid;
  end if;

  select id into v_profissional_uid
    from auth.users
   where lower(email) = 'revisao-profissional@frila.app'
   order by created_at asc
   limit 1;

  if v_profissional_uid is null then
    v_profissional_uid := 'de000000-0000-4000-8000-000000000002'::uuid;
  end if;

  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous,
                          confirmation_token, recovery_token, email_change,
                          email_change_token_new, email_change_token_current,
                          phone_change, phone_change_token, reauthentication_token)
  select '00000000-0000-0000-0000-000000000000', c.id, 'authenticated', 'authenticated',
         c.email, v_agora, '{"provider":"email","providers":["email"]}'::jsonb,
         '{}'::jsonb, v_agora, v_agora, false, false,
         '', '', '', '', '', '', '', ''
    from (values
      (v_contratante_uid, 'revisao-contratante@frila.app'),
      (v_profissional_uid, 'revisao-profissional@frila.app')
    ) as c(id, email)
  on conflict (id) do nothing;

  -- 2. Garante os usuários em public.usuario com marcação demonstracao = true
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                              termos_versao, termos_aceite_em, demonstracao)
  values
    (v_contratante_uid, 'contratante', 'Casa de Demonstração',
     '+5561999990901', 'revisao-contratante@frila.app', '1985-01-01', '2026-09-22', v_agora, true),
    (v_profissional_uid, 'profissional', 'Perfil de Demonstração',
     '+5561999990902', 'revisao-profissional@frila.app', '1995-01-01', '2026-09-22', v_agora, true)
  on conflict (id) do update set
    demonstracao = true,
    estado = 'ativa';

  -- Se existirem linhas nos IDs canônicos padrão, assegura estado ativo e demonstração
  update public.usuario
     set demonstracao = true, estado = 'ativa'
   where id in ('de000000-0000-4000-8000-000000000001'::uuid, 'de000000-0000-4000-8000-000000000002'::uuid);

  -- 3. Perfil do profissional e funções
  insert into public.profissional (usuario_id, ponto_base)
  values (v_profissional_uid, 'POINT(-47.8825 -15.7940)'::extensions.geography)
  on conflict (usuario_id) do nothing;

  select id into v_prof_id from public.profissional where usuario_id = v_profissional_uid;

  select id into v_funcao_garcom from public.funcao where nome = 'garçom';
  select id into v_funcao_bartender from public.funcao where nome = 'bartender';

  if v_prof_id is not null and v_funcao_garcom is not null then
    insert into public.profissional_funcao (profissional_id, funcao_id)
    values (v_prof_id, v_funcao_garcom)
    on conflict do nothing;
  end if;

  if v_prof_id is not null and v_funcao_bartender is not null then
    insert into public.profissional_funcao (profissional_id, funcao_id)
    values (v_prof_id, v_funcao_bartender)
    on conflict do nothing;
  end if;

  -- 4. Estabelecimento e associação do contratante
  insert into public.estabelecimento (id, nome, documento, tipo, endereco, regiao_administrativa, ponto)
  values (v_estabelecimento_id, 'Bar da Revisão', '19131243000197',
          'food_service', 'CLS 405, Asa Sul, Brasília', 'Plano Piloto',
          'POINT(-47.8880 -15.8020)'::extensions.geography)
  on conflict (id) do update set
    ponto = excluded.ponto,
    regiao_administrativa = coalesce(excluded.regiao_administrativa, 'Plano Piloto');

  insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
  values (v_contratante_uid, v_estabelecimento_id, 'administrador')
  on conflict (usuario_id, estabelecimento_id) do update set papel = 'administrador';

  if v_contratante_uid <> 'de000000-0000-4000-8000-000000000001'::uuid then
    insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
    values ('de000000-0000-4000-8000-000000000001'::uuid, v_estabelecimento_id, 'administrador')
    on conflict (usuario_id, estabelecimento_id) do update set papel = 'administrador';
  end if;

  -- 5. Limpeza de artefatos de testes / histórico anterior nas posições de demonstração
  perform set_config('privado.retencao', 'on', true);
  delete from public.ocorrencia
   where posicao_id in (v_pos_aberta_id, v_pos_confirmada_id)
      or turno_id in (select id from public.turno where posicao_id in (v_pos_aberta_id, v_pos_confirmada_id));
  delete from public.avaliacao
   where turno_id in (select id from public.turno where posicao_id in (v_pos_aberta_id, v_pos_confirmada_id));
  delete from public.candidatura where posicao_id in (v_pos_aberta_id, v_pos_confirmada_id);
  delete from public.turno where posicao_id = v_pos_aberta_id;
  perform set_config('privado.retencao', 'off', true);

  -- 6. Atualização/Criação das Vagas com datas à frente do relógio
  -- Vaga Aberta
  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local,
                           regiao_administrativa, ponto, valor_centavos, posicoes,
                           inclui_refeicao, inclui_transporte, exige_material_proprio,
                           responsavel_local, modo, estado, chave_cliente, publicado_por)
  values (v_vaga_aberta_id, v_estabelecimento_id, v_funcao_garcom,
          v_aberta_inicio, v_aberta_fim,
          'CLS 405, Asa Sul', 'Plano Piloto',
          'POINT(-47.8880 -15.8020)'::extensions.geography,
          18000, 1, true, true, false, 'Gerente da Revisão', 'urgencia',
          'publicada'::public.estado_vaga,
          v_vaga_aberta_id, v_contratante_uid)
  on conflict (id) do update set
    inicio_em = excluded.inicio_em,
    fim_em = excluded.fim_em,
    estado = 'publicada',
    posicoes = 1,
    modo = 'urgencia',
    valor_centavos = 18000,
    publicado_por = excluded.publicado_por;

  -- Vaga Preenchida
  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local,
                           regiao_administrativa, ponto, valor_centavos, posicoes,
                           inclui_refeicao, inclui_transporte, exige_material_proprio,
                           responsavel_local, modo, estado, chave_cliente, publicado_por)
  values (v_vaga_preenchida_id, v_estabelecimento_id, v_funcao_garcom,
          v_preenchida_inicio, v_preenchida_fim,
          'CLS 405, Asa Sul', 'Plano Piloto',
          'POINT(-47.8880 -15.8020)'::extensions.geography,
          18000, 1, true, true, false, 'Gerente da Revisão', 'urgencia',
          'preenchida'::public.estado_vaga,
          v_vaga_preenchida_id, v_contratante_uid)
  on conflict (id) do update set
    inicio_em = excluded.inicio_em,
    fim_em = excluded.fim_em,
    estado = 'preenchida',
    posicoes = 1,
    modo = 'urgencia',
    valor_centavos = 18000,
    publicado_por = excluded.publicado_por;

  -- 7. Posições
  -- Posição da vaga aberta
  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em)
  values (v_pos_aberta_id, v_vaga_aberta_id, 'aberta', null, null, false, v_aberta_inicio, v_aberta_fim)
  on conflict (id) do update set
    estado = 'aberta',
    profissional_id = null,
    confirmado_em = null,
    falta = false,
    inicio_em = excluded.inicio_em,
    fim_em = excluded.fim_em;

  -- Posição da vaga preenchida
  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em)
  values (v_pos_confirmada_id, v_vaga_preenchida_id, 'confirmada', v_prof_id, v_agora, false, v_preenchida_inicio, v_preenchida_fim)
  on conflict (id) do update set
    estado = 'confirmada',
    profissional_id = excluded.profissional_id,
    confirmado_em = excluded.confirmado_em,
    falta = false,
    inicio_em = excluded.inicio_em,
    fim_em = excluded.fim_em;

  -- 8. Turno confirmado (restaura para o estado inicial virgem, pendente de check-in)
  insert into public.turno (posicao_id, valor_acordado_centavos, verificacao)
  values (v_pos_confirmada_id, 18000, 'pendente')
  on conflict (posicao_id) do update set
    valor_acordado_centavos = 18000,
    a_caminho_em = null,
    checkin_em = null,
    checkin_recebido_em = null,
    checkin_tipo = null,
    checkin_distancia_m = null,
    checkin_confirmado_em = null,
    checkout_em = null,
    checkout_recebido_em = null,
    checkout_distancia_m = null,
    verificacao = 'pendente';

  -- 9. Recalcula histórico de comparecimento do profissional de revisão
  if v_prof_id is not null then
    perform privado.recalcular_comparecimento(v_prof_id);
  end if;

  -- 10. Zera registro de tentativas das contas de demonstração
  delete from public.entrada_demonstracao
   where lower(email) in ('revisao-contratante@frila.app', 'revisao-profissional@frila.app');

  return jsonb_build_object(
    'sucesso', true,
    'referencia_em', v_agora,
    'vaga_aberta_id', v_vaga_aberta_id,
    'vaga_aberta_inicio', v_aberta_inicio,
    'vaga_preenchida_id', v_vaga_preenchida_id,
    'vaga_preenchida_inicio', v_preenchida_inicio,
    'posicao_aberta_id', v_pos_aberta_id,
    'posicao_confirmada_id', v_pos_confirmada_id
  );
end $$;

comment on function privado.renovar_dados_demonstracao(timestamptz) is
  'Renovação idempotente dos dados de demonstração (cartão RzllRo3o, 5boVdM0t): resolução de UID por e-mail, vagas e turno preservados à frente do relógio.';

revoke all on function privado.renovar_dados_demonstracao(timestamptz) from public, anon, authenticated;
grant execute on function privado.renovar_dados_demonstracao(timestamptz) to service_role;

-- ── 3. Semeadura de vagas de demonstração pós-06/11 ────────────────────────────

create or replace function privado.semear_vagas_demonstracao(
  p_quantidade         int         default 5,
  p_inicio_base        timestamptz default null,
  p_posicoes_por_vaga  int         default 20
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora              timestamptz := privado.agora();
  v_inicio             timestamptz;
  v_contratante_uid    uuid;
  v_estabelecimento_id uuid := 'de000000-0000-4000-8000-000000000010'::uuid;
  v_funcao_garcom      uuid;
  v_vaga_id            uuid;
  v_pos_id             uuid;
  v_vaga_inicio        timestamptz;
  v_vaga_fim           timestamptz;
  v_vagas_ids          uuid[] := '{}'::uuid[];
begin
  if p_quantidade < 1 or p_quantidade > 50 then
    perform public.erro(422, 'campo_invalido', 'quantidade');
  end if;
  if p_posicoes_por_vaga < 1 or p_posicoes_por_vaga > 200 then
    perform public.erro(422, 'campo_invalido', 'posicoes');
  end if;

  -- Início padrão no futuro: pós-06/11 (>= 2026-11-20 ou agora + 30 dias se for além)
  v_inicio := coalesce(p_inicio_base, greatest(v_agora + interval '30 days', '2026-11-20 18:00:00+00'::timestamptz));

  -- 1. Descobre usuário contratante de demonstração
  select id into v_contratante_uid
    from auth.users
   where lower(email) = 'revisao-contratante@frila.app'
   order by created_at asc
   limit 1;

  if v_contratante_uid is null then
    v_contratante_uid := 'de000000-0000-4000-8000-000000000001'::uuid;
  end if;

  -- Garante perfil contratante e membro
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                              termos_versao, termos_aceite_em, demonstracao)
  values (v_contratante_uid, 'contratante', 'Casa de Demonstração',
          '+5561999990901', 'revisao-contratante@frila.app', '1985-01-01',
          '2026-09-22', v_agora, true)
  on conflict (id) do update set demonstracao = true, estado = 'ativa';

  insert into public.estabelecimento (id, nome, documento, tipo, endereco, regiao_administrativa, ponto)
  values (v_estabelecimento_id, 'Bar da Revisão', '19131243000197',
          'food_service', 'CLS 405, Asa Sul, Brasília', 'Plano Piloto',
          'POINT(-47.8880 -15.8020)'::extensions.geography)
  on conflict (id) do update set
    regiao_administrativa = coalesce(excluded.regiao_administrativa, 'Plano Piloto'),
    ponto = excluded.ponto;

  insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
  values (v_contratante_uid, v_estabelecimento_id, 'administrador')
  on conflict (usuario_id, estabelecimento_id) do update set papel = 'administrador';

  select id into v_funcao_garcom from public.funcao where nome = 'garçom';
  if v_funcao_garcom is null then
    select id into v_funcao_garcom from public.funcao limit 1;
  end if;

  -- 2. Cria ou atualiza as vagas de demonstração com posições
  for i in 1..p_quantidade loop
    -- Deterministic UUID: de000000-0000-4000-8000-000000000101, ...
    v_vaga_id := ('de000000-0000-4000-8000-' || lpad(to_hex(256 + i), 12, '0'))::uuid;
    v_vaga_inicio := v_inicio + ((i - 1) * interval '1 day');
    v_vaga_fim := v_vaga_inicio + interval '6 hours';
    v_vagas_ids := array_append(v_vagas_ids, v_vaga_id);

    insert into public.vaga (
      id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa,
      ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
      exige_material_proprio, responsavel_local, modo, estado, chave_cliente, publicado_por
    ) values (
      v_vaga_id, v_estabelecimento_id, v_funcao_garcom, v_vaga_inicio, v_vaga_fim,
      'Bar da Revisão - CLS 405', 'Plano Piloto',
      'POINT(-47.8880 -15.8020)'::extensions.geography,
      18000, p_posicoes_por_vaga, true, true, false,
      'Gerente da Revisão', 'urgencia'::public.modo_preenchimento,
      'publicada'::public.estado_vaga,
      v_vaga_id, v_contratante_uid
    )
    on conflict (id) do update set
      inicio_em      = excluded.inicio_em,
      fim_em         = excluded.fim_em,
      estado         = 'publicada',
      posicoes       = excluded.posicoes,
      modo           = 'urgencia',
      valor_centavos = 18000,
      publicado_por  = excluded.publicado_por;

    -- Posições
    for j in 1..p_posicoes_por_vaga loop
      -- Deterministic UUID: de000000-0000-4000-8001-...
      v_pos_id := ('de000000-0000-4000-8001-' || lpad(to_hex(i * 1000 + j), 12, '0'))::uuid;
      insert into public.posicao (
        id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em
      ) values (
        v_pos_id, v_vaga_id, 'aberta', null, null, false, v_vaga_inicio, v_vaga_fim
      )
      on conflict (id) do update set
        estado          = 'aberta',
        profissional_id = null,
        confirmado_em   = null,
        falta           = false,
        inicio_em       = excluded.inicio_em,
        fim_em          = excluded.fim_em;
    end loop;

    -- Limpa artefatos residuais e posições excedentes dessas vagas/posições
    perform set_config('privado.retencao', 'on', true);
    delete from public.ocorrencia
     where posicao_id in (select id from public.posicao where vaga_id = v_vaga_id)
        or turno_id in (select id from public.turno where posicao_id in (select id from public.posicao where vaga_id = v_vaga_id));
    delete from public.avaliacao
     where turno_id in (select id from public.turno where posicao_id in (select id from public.posicao where vaga_id = v_vaga_id));
    delete from public.candidatura
     where posicao_id in (select id from public.posicao where vaga_id = v_vaga_id);
    delete from public.turno
     where posicao_id in (select id from public.posicao where vaga_id = v_vaga_id);
    delete from public.posicao
     where vaga_id = v_vaga_id
       and id not in (
         select ('de000000-0000-4000-8001-' || lpad(to_hex(i * 1000 + k), 12, '0'))::uuid
           from generate_series(1, p_posicoes_por_vaga) k
       );
    perform set_config('privado.retencao', 'off', true);
  end loop;

  -- Remove vagas excedentes de semeaduras anteriores se a quantidade foi reduzida
  perform set_config('privado.retencao', 'on', true);
  delete from public.ocorrencia
   where posicao_id in (
     select p.id from public.posicao p
      where p.vaga_id in (
        select v.id from public.vaga v
         where v.id::text like 'de000000-0000-4000-8000-0000000001%'
           and not (v.id = any(v_vagas_ids))
      )
   );
  delete from public.candidatura
   where posicao_id in (
     select p.id from public.posicao p
      where p.vaga_id in (
        select v.id from public.vaga v
         where v.id::text like 'de000000-0000-4000-8000-0000000001%'
           and not (v.id = any(v_vagas_ids))
      )
   );
  delete from public.turno
   where posicao_id in (
     select p.id from public.posicao p
      where p.vaga_id in (
        select v.id from public.vaga v
         where v.id::text like 'de000000-0000-4000-8000-0000000001%'
           and not (v.id = any(v_vagas_ids))
      )
   );
  delete from public.posicao
   where vaga_id in (
     select v.id from public.vaga v
      where v.id::text like 'de000000-0000-4000-8000-0000000001%'
        and not (v.id = any(v_vagas_ids))
   );
  delete from public.vaga
   where id::text like 'de000000-0000-4000-8000-0000000001%'
     and not (id = any(v_vagas_ids));
  perform set_config('privado.retencao', 'off', true);

  return jsonb_build_object(
    'sucesso',            true,
    'vagas_semeadas',     p_quantidade,
    'posicoes_por_vaga',  p_posicoes_por_vaga,
    'inicio_base',        v_inicio,
    'vagas_ids',          to_jsonb(v_vagas_ids)
  );
end $$;

comment on function privado.semear_vagas_demonstracao(int, timestamptz, int) is
  'Semeadura idempotente de vagas futuras abertas de demonstração pós-06/11 com N posições, destravando medições de desempenho do app iOS (Lista cheia e Detalhe 20x).';

revoke all on function privado.semear_vagas_demonstracao(int, timestamptz, int) from public, anon, authenticated;
grant execute on function privado.semear_vagas_demonstracao(int, timestamptz, int) to service_role;
