-- 20260929190000_contestar_despacho.sql
--
-- Contestar o despacho ("Por que recebo vagas"):
--   - public.criterios_de_notificacao() -> jsonb (CriteriosDeNotificacao)
--   - public.pedir_revisao_despacho(relato text) -> jsonb (Protocolo)
--
-- Requisitos: RF27, RN05, RN06, RN23, LGPD art. 20. Cartão: eaWhDeym.
--
-- Decisões de desenho:
--   1. criterios_de_notificacao expõe os critérios reais do profissional autenticado:
--      funções ativas, grade de disponibilidade semanal, raio padrão de 15 km (RN05),
--      equipes de confiança em que está incluído (que dispensam o raio de 15 km)
--      e o intervalo mínimo entre notificações de 30 minutos (RN23).
--   2. pedir_revisao_despacho registra uma ocorrência do tipo 'revisao_despacho'
--      com o relato fornecido (mínimo de 10 caracteres e filtro ofensivo da Diretriz 1.2),
--      enfileira notificação na fila 'email' (sem dados pessoais nem relato, RN15)
--      e devolve o Protocolo oficial com prazo de 5 dias úteis (privado.prazo_de_resposta).

-- ── 1. criterios_de_notificacao ──────────────────────────────────────────────────

create or replace function public.criterios_de_notificacao()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_prof public.profissional%rowtype;
  v_res  jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('profissional');

  select * into v_prof
    from public.profissional p
   where p.usuario_id = v_uid;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  select jsonb_build_object(
    'funcoes', coalesce(
      (select jsonb_agg(jsonb_build_object('id', f.id, 'nome', f.nome, 'categoria', f.categoria)
                        order by f.nome)
         from public.profissional_funcao pf
         join public.funcao f on f.id = pf.funcao_id
        where pf.profissional_id = v_prof.id),
      '[]'::jsonb),
    'disponibilidades', coalesce(
      (select jsonb_agg(jsonb_build_object(
                'dia_semana',  d.dia_semana,
                'hora_inicio', to_char(d.hora_inicio, 'HH24:MI'),
                'hora_fim',    to_char(d.hora_fim,    'HH24:MI'))
                order by d.dia_semana, d.hora_inicio)
         from public.disponibilidade d
        where d.profissional_id = v_prof.id),
      '[]'::jsonb),
    'distancia_maxima_km', 15,
    'equipes_de_confianca', coalesce(
      (select jsonb_agg(jsonb_build_object(
                'estabelecimento_id', ec.estabelecimento_id,
                'nome',               e.nome)
                order by e.nome)
         from public.equipe_confianca ec
         join public.estabelecimento e on e.id = ec.estabelecimento_id
        where ec.profissional_id = v_prof.id),
      '[]'::jsonb),
    'notificacoes_no_maximo_a_cada_min', 30
  ) into v_res;

  return v_res;
end $$;

comment on function public.criterios_de_notificacao() is
  'Critérios em vigor que decidem se o profissional recebe notificações de vagas (RF27, RN05, RN06, RN23, LGPD art. 20).';

revoke execute on function public.criterios_de_notificacao() from public, anon;
grant  execute on function public.criterios_de_notificacao() to authenticated;

-- ── 2. pedir_revisao_despacho ────────────────────────────────────────────────────

create or replace function public.pedir_revisao_despacho(relato text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_relato text := pg_catalog.btrim(pedir_revisao_despacho.relato);
  v_oc     public.ocorrencia%rowtype;
  v_agora  timestamptz;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('profissional');
  perform privado.exigir_conta_ativa();

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  if v_relato is null or v_relato = '' then
    perform public.erro(422, 'campo_obrigatorio', 'relato');
  end if;

  if pg_catalog.length(v_relato) < 10 then
    perform public.erro(422, 'campo_invalido', 'relato');
  end if;

  -- Diretriz 1.2 da App Store nos campos livres
  perform privado.exigir_texto_aceitavel(jsonb_build_object('relato', v_relato));

  v_agora := privado.agora();

  insert into public.ocorrencia (
    autor_id,
    tipo,
    motivo,
    relato,
    criada_em
  ) values (
    v_uid,
    'revisao_despacho',
    'revisao_despacho',
    v_relato,
    v_agora
  ) returning * into v_oc;

  -- Garante que a fila email existe
  if not exists (select 1 from pgmq.meta where queue_name = 'email') then
    perform pgmq.create('email');
  end if;

  -- Enfileira o aviso de e-mail à Equipe Frila, só com o ID (RN15: sem relato nem dado pessoal na fila)
  perform pgmq.send('email', jsonb_build_object(
    'tipo',          'revisao_despacho',
    'ocorrencia_id', v_oc.id
  ));

  return jsonb_build_object(
    'ocorrencia_id',      v_oc.id,
    'tipo',               'revisao_despacho',
    'criada_em',          v_oc.criada_em,
    'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em)
  );
end $$;

comment on function public.pedir_revisao_despacho(text) is
  'Contestar o despacho com pedido de revisão à Equipe Frila (RF27, LGPD art. 20). Devolve Protocolo com prazo de resposta em até 5 dias úteis.';

revoke execute on function public.pedir_revisao_despacho(text) from public, anon;
grant  execute on function public.pedir_revisao_despacho(text) to authenticated;
