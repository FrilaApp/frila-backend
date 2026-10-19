-- Renovação idempotente dos dados de demonstração da App Store (cartão RzllRo3o, item 6).
--
-- As contas `revisao-contratante` e `revisao-profissional` precisam de dados válidos e com
-- datas à frente do relógio sempre que um envio 1.0.x for submetido à revisão da Apple.
-- O `seed.sql` semeava datas relativas no primeiro provisionamento, mas sob `on conflict (id) do nothing`
-- essas datas envelheciam e caíam no passado. Além disso, o teste de conferência remota
-- (`demonstracao.sh`) consome o turno ao realizar check-in e check-out, deixando o estado
-- indisponível para o revisor humano da Apple.
--
-- Esta função `privado.renovar_dados_demonstracao(agora timestamptz default privado.agora())`:
--   1. É estritamente idempotente (pode rodar quantas vezes forem necessárias).
--   2. É parametrizada no tempo (nunca usa datas literais fixas).
--   3. Garante que as contas de demonstração e suas entidades base existam.
--   4. Reposiciona as vagas e posições sempre no futuro a partir de `agora`:
--      - Vaga aberta (de000000-0000-4000-8000-000000000020): início em `agora + 5 days`, duração de 6h.
--      - Vaga preenchida (de000000-0000-4000-8000-000000000021): início em `agora + 2 days`, duração de 6h.
--   5. Restaura a posição aberta (30) para o estado `aberta` (sem profissional associado e sem faltas),
--      removendo eventuais candidaturas ou turnos órfãos gerados por testes.
--   6. Restaura a posição do turno (31) para o estado `confirmada` com o profissional de demonstração,
--      removendo eventuais avaliações ou ocorrências geradas em testes.
--   7. Restaura o turno (31) para o estado `pendente` (checkin_em, checkout_em e recebidos limpos),
--      pronto para que o revisor da Apple possa executar o fluxo de presença.
--   8. Recalcula o histórico do profissional de demonstração e limpa tentativas registradas
--      em `public.entrada_demonstracao`.

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
  v_contratante_uid    uuid := 'de000000-0000-4000-8000-000000000001'::uuid;
  v_profissional_uid   uuid := 'de000000-0000-4000-8000-000000000002'::uuid;
  v_estabelecimento_id uuid := 'de000000-0000-4000-8000-000000000010'::uuid;
  v_vaga_aberta_id     uuid := 'de000000-0000-4000-8000-000000000020'::uuid;
  v_vaga_preenchida_id uuid := 'de000000-0000-4000-8000-000000000021'::uuid;
  v_pos_aberta_id      uuid := 'de000000-0000-4000-8000-000000000030'::uuid;
  v_pos_confirmada_id  uuid := 'de000000-0000-4000-8000-000000000031'::uuid;
  v_prof_id            uuid;
  v_funcao_garcom      uuid;
  v_funcao_bartender   uuid;
begin
  -- 1. Garante que os usuários de revisão existam no GoTrue (auth.users)
  -- As colunas de token vazias evitam erro 500 no admin generate_link (GoTrue)
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
    regiao_administrativa = excluded.regiao_administrativa;

  insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
  values (v_contratante_uid, v_estabelecimento_id, 'administrador')
  on conflict do nothing;

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
    valor_centavos = 18000;

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
    valor_centavos = 18000;

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
  'Renovação idempotente dos dados de demonstração (cartão RzllRo3o, item 6): vagas aberta e confirmada sempre com datas à frente de agora, turno restaurado para pendente de check-in e tentativas zeradas.';

revoke all on function privado.renovar_dados_demonstracao(timestamptz) from public, anon, authenticated;
grant execute on function privado.renovar_dados_demonstracao(timestamptz) to service_role;
