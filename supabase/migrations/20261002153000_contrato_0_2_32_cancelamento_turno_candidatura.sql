-- Contrato 0.2.32 (frila-docs #68, cartão Uc69VI57):
-- 1. Turno.cancelamento (CancelamentoDoTurno ou null) em meus_turnos e MeusDados.turnos:
--    causa, falta, cancelada_em. Sem motivo (nem para profissional nem para contratante).
-- 2. Candidatura.turno_id (Uuid ou null) em minhas_candidaturas e retirar_candidatura:
--    preenchido estritamente no estado 'aceita'.

-- ── 1. privado.cancelamento_da_posicao ─────────────────────────────────────────
--
-- Dedução canônica da causa, falta, cancelada_em e motivo do cancelamento de uma
-- posição. O painel da casa expõe motivo; o turno expõe sem motivo.

create or replace function privado.cancelamento_da_posicao(posicao uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pos      record;
  v_oco      record;
  v_causa    text;
  v_motivo   text := null;
  v_falta    boolean;
  v_canc_em  timestamptz;
  v_prof_usr uuid;
begin
  select p.id, p.vaga_id, p.estado, p.profissional_id, p.falta, p.confirmado_em,
         v.estabelecimento_id
    into v_pos
    from public.posicao p
    join public.vaga v on v.id = p.vaga_id
   where p.id = posicao;

  if not found or v_pos.estado <> 'cancelada' or v_pos.profissional_id is null then
    return null;
  end if;

  v_falta := v_pos.falta;
  v_prof_usr := privado.usuario_do_profissional(v_pos.profissional_id);

  -- Ocorrência mais recente de cancelamento da posição
  select o.id, o.motivo, o.autor_id, o.criada_em
    into v_oco
    from public.ocorrencia o
   where o.posicao_id = v_pos.id
     and o.tipo = 'cancelamento'
   order by o.criada_em desc, o.id desc
   limit 1;

  if not found then
    return jsonb_build_object(
      'causa',        'outro',
      'falta',        v_falta,
      'motivo',       null,
      'cancelada_em', coalesce(v_pos.confirmado_em, now())
    );
  end if;

  v_canc_em := v_oco.criada_em;

  if v_oco.motivo = 'reabertura_por_atraso' then
    v_causa := 'reabertura_por_atraso';
    v_motivo := null;
  elsif v_oco.motivo = 'no_show_sem_checkin' then
    v_causa := 'no_show_sem_checkin';
    v_motivo := null;
  elsif v_oco.motivo in ('exclusão de conta', 'suspensão de conta', '[removido por exclusão de conta]') then
    v_causa := 'outro';
    v_motivo := null;
  elsif v_oco.motivo = 'vaga_cancelada' then
    v_causa := 'estabelecimento';
    v_motivo := null;
  elsif v_oco.autor_id = v_prof_usr then
    v_causa := 'profissional';
    v_motivo := v_oco.motivo;
  elsif exists (
    select 1
      from public.membro_estabelecimento m
     where m.estabelecimento_id = v_pos.estabelecimento_id
       and m.usuario_id = v_oco.autor_id
  ) then
    v_causa := 'estabelecimento';
    v_motivo := v_oco.motivo;
  else
    v_causa := 'outro';
    v_motivo := null;
  end if;

  return jsonb_build_object(
    'causa',        v_causa,
    'falta',        v_falta,
    'motivo',       v_motivo,
    'cancelada_em', v_canc_em
  );
end $$;

comment on function privado.cancelamento_da_posicao(uuid) is
  'Dedução canônica do cancelamento de uma posição (RN12). Usada pelo painel (com motivo) e pelo turno (sem motivo).';

revoke execute on function privado.cancelamento_da_posicao(uuid) from public, anon, authenticated;
grant  execute on function privado.cancelamento_da_posicao(uuid) to service_role;

-- ── 2. privado.cancelamento_do_turno ───────────────────────────────────────────
--
-- O cancelamento no schema CancelamentoDoTurno (contrato 0.2.32): causa, falta e
-- cancelada_em. Sem o motivo da ocorrência para nenhum dos lados (decisão de 02/10).

create or replace function privado.cancelamento_do_turno(posicao uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when c is null then null
    else jsonb_build_object(
      'causa',        c->'causa',
      'falta',        (c->>'falta')::boolean,
      'cancelada_em', c->'cancelada_em'
    )
  end
  from (select privado.cancelamento_da_posicao(posicao) as c) s
$$;

comment on function privado.cancelamento_do_turno(uuid) is
  'Cancelamento do turno no schema CancelamentoDoTurno (contrato 0.2.32): causa, falta e cancelada_em, sem motivo.';

revoke execute on function privado.cancelamento_do_turno(uuid) from public, anon, authenticated;
grant  execute on function privado.cancelamento_do_turno(uuid) to service_role;

-- ── 3. privado.turno_em_json: adiciona chave cancelamento ───────────────────────

create or replace function privado.turno_em_json(turno uuid, autor uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id',         t.id,
    'posicao_id', t.posicao_id,
    'vaga', jsonb_build_object(
      'id',                    v.id,
      'funcao',                f.nome,
      'local',                 v.local,
      'regiao_administrativa', v.regiao_administrativa,
      'inicio_em',             v.inicio_em,
      'fim_em',                v.fim_em,
      'valor_centavos',        v.valor_centavos),
    'contraparte', case
      when privado.usuario_do_profissional(p.profissional_id) = autor
        then privado.estabelecimento_publico(v.estabelecimento_id)
        else privado.perfil_publico_profissional(p.profissional_id) end,
    'contato_visivel_ate',     p.fim_em + interval '7 days',
    'a_caminho_em',            t.a_caminho_em,
    'checkin_em',              t.checkin_em,
    'checkin_tipo',            t.checkin_tipo,
    'checkin_distancia_m',     t.checkin_distancia_m,
    'checkin_confirmado_em',   t.checkin_confirmado_em,
    'checkout_em',             t.checkout_em,
    'checkout_distancia_m',    t.checkout_distancia_m,
    'verificacao',             t.verificacao,
    'valor_acordado_centavos', t.valor_acordado_centavos,
    'pode_avaliar',            privado.pode_avaliar(t.id, autor),
    'estado',                  p.estado,
    'avaliacao',               (
      select jsonb_build_object(
        'turno_id',  a.turno_id,
        'resposta',  a.resposta,
        'criada_em', a.criada_em
      )
      from public.avaliacao a
      where a.turno_id = t.id
        and a.alvo_tipo = case
          when privado.usuario_do_profissional(p.profissional_id) = autor then 'estabelecimento'
          else 'profissional'
        end
    ),
    'cancelamento',            case
                                 when p.estado = 'cancelada'
                                   then privado.cancelamento_do_turno(p.id)
                                 else null
                               end)
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v    on v.id = p.vaga_id
    join public.funcao f  on f.id = v.funcao_id
   where t.id = turno
$$;

comment on function privado.turno_em_json(uuid, uuid) is
  'Turno no schema do contrato (RF09, RF10). Expõe regiao_administrativa no VagaResumo, a_caminho_em (US14), estado, avaliacao (0.2.31) e cancelamento (contrato 0.2.32, RN12).';

revoke execute on function privado.turno_em_json(uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.turno_em_json(uuid, uuid) to service_role;

-- ── 4. privado.candidatura_em_json: adiciona chave turno_id ────────────────────

create or replace function privado.candidatura_em_json(candidatura uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id',        c.id,
    'vaga',      jsonb_build_object(
                   'id',                    v.id,
                   'funcao',                f.nome,
                   'local',                 v.local,
                   'regiao_administrativa', v.regiao_administrativa,
                   'inicio_em',             v.inicio_em,
                   'fim_em',                v.fim_em,
                   'valor_centavos',        v.valor_centavos),
    'estado',    c.estado,
    'criada_em', c.criada_em,
    'turno_id',  case
                   when c.estado = 'aceita' then (
                     select t.id
                       from public.turno t
                      where t.posicao_id = c.posicao_id
                   )
                   else null
                 end)
    from public.candidatura c
    join public.posicao x on x.id = c.posicao_id
    join public.vaga v    on v.id = x.vaga_id
    join public.funcao f  on f.id = v.funcao_id
   where c.id = candidatura
$$;

comment on function privado.candidatura_em_json(uuid) is
  'Candidatura no formato do contrato: id, vaga (VagaResumo), estado, criada_em e turno_id (contrato 0.2.32).';

revoke execute on function privado.candidatura_em_json(uuid) from public, anon, authenticated;
grant  execute on function privado.candidatura_em_json(uuid) to service_role;
