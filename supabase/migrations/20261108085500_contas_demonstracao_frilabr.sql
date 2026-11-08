-- Migração: 20261108085500_contas_demonstracao_frilabr.sql
-- Escopo: B-DEMO. As contas de demonstração (as da revisão da Apple) saem de frila.app, que
-- não é do Frila: o domínio não tem MX e aponta para IPs de terceiro, e quem o controlar
-- recebe os códigos de login dessas contas. Os endereços passam a ser
-- revisao-contratante@frilabr.com e revisao-profissional@frilabr.com.
--
-- privado.renovar_dados_demonstracao e privado.semear_vagas_demonstracao (20261020150000,
-- imutável) procuravam as contas por e-mail @frila.app e adotavam QUALQUER conta com esse
-- endereço: depois da troca no Prod, quem controla frila.app criaria conta nele e viraria
-- administradora do Bar da Revisão (Lince Codex, B1). Aqui as duas são recriadas e passam a
-- resolver a conta por privado.resolver_conta_demonstracao, que:
--   1. devolve o UUID canônico (de000000-0000-4000-8000-000000000001 e ...0002) sempre que ele
--      existe em auth.users, que é o caso das duas contas no Prod (medido em 08/11/2026);
--   2. sem o canônico, aceita a conta com o endereço novo só se ela já for de demonstração
--      (public.usuario.demonstracao = true);
--   3. sem conta nenhuma, devolve o canônico, que a função cria;
--   4. fora disso, falha fechado (409 conta_de_demonstracao_nao_canonica) e não adota nada.
-- Os endereços novos são públicos neste repositório, e antes da troca qualquer um pode criar
-- conta com eles (um /otp anônimo, um generate_link): por isso o e-mail sozinho nunca basta
-- (Lince Codex B2, Lince AG 2). O endereço antigo não é procurado em caminho nenhum.
--
-- Esta migração não troca o e-mail de conta nenhuma. No Prod ela entra ANTES da troca das duas
-- contas, e o segredo DEMONSTRACAO_EMAILS vem depois da troca (ordem e pré-teste no PR #443).

-- ── 0. Qual é a conta de demonstração ─────────────────────────────────────────

create or replace function privado.resolver_conta_demonstracao(p_canonico uuid, p_email text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  -- O canônico vence sempre: nenhuma outra conta com o mesmo endereço é adotada.
  if exists (select 1 from auth.users u where u.id = p_canonico) then
    return p_canonico;
  end if;

  select u.id into v_id
    from auth.users u
   where lower(u.email) = lower(p_email)
   order by u.created_at asc
   limit 1;

  if v_id is null then
    return p_canonico;
  end if;

  if exists (select 1 from public.usuario pu where pu.id = v_id and pu.demonstracao) then
    return v_id;
  end if;

  -- Uma conta que não é a canônica nem de demonstração tem o endereço: não adota.
  perform public.erro(409, 'conta_de_demonstracao_nao_canonica', p_email);
  return null;
end $$;

comment on function privado.resolver_conta_demonstracao(uuid, text) is
  'Conta de demonstração (B-DEMO): o UUID canônico quando existe; sem ele, a conta com o endereço só se já for de demonstração; sem conta nenhuma, o canônico. Uma conta avulsa com o endereço faz a função falhar fechado (409 conta_de_demonstracao_nao_canonica) em vez de adotá-la.';

revoke all on function privado.resolver_conta_demonstracao(uuid, text) from public, anon, authenticated;

-- ── 1. Renovação dos dados de demonstração ───────────────────────────────────

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
  v_contratante_uid := privado.resolver_conta_demonstracao(
    'de000000-0000-4000-8000-000000000001'::uuid, 'revisao-contratante@frilabr.com');

  v_profissional_uid := privado.resolver_conta_demonstracao(
    'de000000-0000-4000-8000-000000000002'::uuid, 'revisao-profissional@frilabr.com');

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
      (v_contratante_uid, 'revisao-contratante@frilabr.com'),
      (v_profissional_uid, 'revisao-profissional@frilabr.com')
    ) as c(id, email)
  on conflict (id) do nothing;

  -- 2. Garante os usuários em public.usuario com marcação demonstracao = true
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                              termos_versao, termos_aceite_em, demonstracao)
  values
    (v_contratante_uid, 'contratante', 'Casa de Demonstração',
     '+5561999990901', 'revisao-contratante@frilabr.com', '1985-01-01', '2026-09-22', v_agora, true),
    (v_profissional_uid, 'profissional', 'Perfil de Demonstração',
     '+5561999990902', 'revisao-profissional@frilabr.com', '1995-01-01', '2026-09-22', v_agora, true)
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
  delete from public.entrada_demonstracao;

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
  'Renovação idempotente dos dados de demonstração (cartão RzllRo3o, 5boVdM0t): conta resolvida por privado.resolver_conta_demonstracao (o UUID canônico primeiro; nunca adota conta avulsa com o endereço), vagas e turno preservados à frente do relógio. Nunca procura nem grava @frila.app, domínio que não é do Frila.';

revoke all on function privado.renovar_dados_demonstracao(timestamptz) from public, anon, authenticated;
grant execute on function privado.renovar_dados_demonstracao(timestamptz) to service_role;

-- ── 2. Semeadura de vagas de demonstração ────────────────────────────────────

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
  v_contratante_uid := privado.resolver_conta_demonstracao(
    'de000000-0000-4000-8000-000000000001'::uuid, 'revisao-contratante@frilabr.com');

  -- Garante perfil contratante e membro
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                              termos_versao, termos_aceite_em, demonstracao)
  values (v_contratante_uid, 'contratante', 'Casa de Demonstração',
          '+5561999990901', 'revisao-contratante@frilabr.com', '1985-01-01',
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
  'Semeadura idempotente de vagas futuras abertas de demonstração pós-06/11 com N posições, destravando medições de desempenho do app iOS (Lista cheia e Detalhe 20x). A conta contratante é resolvida por privado.resolver_conta_demonstracao (o UUID canônico primeiro).';

revoke all on function privado.semear_vagas_demonstracao(int, timestamptz, int) from public, anon, authenticated;
grant execute on function privado.semear_vagas_demonstracao(int, timestamptz, int) to service_role;

-- ── 3. O endereço do suporte no comment de abrir_suporte ──────────────────────
-- O comment citava suporte@frila.app; o endereço da Equipe Frila é suporte@frilabr.com
-- (EMAIL_EQUIPE em supabase/functions/enviar-email/index.ts).

comment on function public.abrir_suporte(uuid, text, uuid) is
  'Abre um chamado de suporte a partir de um turno (RF23, UC14, contrato 0.2.40). O Frila não guarda o texto no banco (RN15); o app monta o assunto com o protocolo curto para envio a suporte@frilabr.com. Idempotente pela chave. Limite de 5 chamados por dia por conta (SU-RN06).';
