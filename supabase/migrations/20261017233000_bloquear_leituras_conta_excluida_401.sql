-- Bloqueio de leituras autenticadas para conta excluída / anonimizada (Item 23 / contrato OpenAPI).
--
-- Quando uma conta é excluída, seu registro passa para estado = 'anonimizada'.
-- O token JWT emitido pelo Auth pode permanecer válido até sua expiração natural.
-- Esta migração assegura que todas as RPCs autenticadas de leitura recusem conta anonimizada com 401 nao_autenticado,
-- disparando o encerramento imediato de sessão no app cliente (SaidaDaConta / RF25).
--
-- CUIDADO DE CONTRATO (RN13 / RF24):
-- A conta SUSPENSA mantém a capacidade de ler minha_conta() (HTTP 200) para exibir
-- a tela de suspensão e permitir a contestação. As demais leituras operacionais exigem conta ativa (403 conta_suspensa).

-- ── 1. minha_conta ────────────────────────────────────────────────────────────
create or replace function public.minha_conta()
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_linha public.usuario%rowtype;
begin
  if (select auth.uid()) is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  select * into v_linha from public.usuario u where u.id = (select auth.uid());
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Conta anonimizada é tratada como não autenticada (401), forçando saída no cliente
  if v_linha.estado = 'anonimizada' then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- Conta suspensa retorna 200 para permitir que a tela de contestação seja exibida
  return public.conta_em_json(v_linha);
end $$;

revoke execute on function public.minha_conta() from public, anon;
grant  execute on function public.minha_conta() to authenticated;

-- ── 2. meus_turnos ────────────────────────────────────────────────────────────
create or replace function public.meus_turnos(
  de                 timestamptz default null,
  ate                timestamptz default null,
  estabelecimento_id uuid        default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_prof  uuid;
  v_agora timestamptz;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- Anonimizada: 401; Suspensa: 403 sem_permissao, conta_suspensa
  perform privado.exigir_conta_ativa();

  if meus_turnos.estabelecimento_id is not null then
    if not privado.eh_membro(meus_turnos.estabelecimento_id) then
      perform public.erro(403, 'sem_permissao');
    end if;
  else
    select p.id into v_prof from public.profissional p where p.usuario_id = v_uid;
    if v_prof is null then
      return '[]'::jsonb;
    end if;
  end if;

  v_agora := privado.agora();

  return coalesce((
    select jsonb_agg(item order by ordem)
      from (
        select privado.turno_em_json(t.id, v_uid) as item,
               case
                 when v_agora between p.inicio_em and coalesce(p.fim_em, v_agora) then 0
                 when p.inicio_em > v_agora then 1
                 else 2
               end as grupo,
               case
                 when p.inicio_em >= v_agora then extract(epoch from p.inicio_em)
                 else - extract(epoch from p.inicio_em)
               end as ordem
          from public.turno t
          join public.posicao p on p.id = t.posicao_id
          join public.vaga v on v.id = p.vaga_id
         where (
                 (meus_turnos.estabelecimento_id is not null and v.estabelecimento_id = meus_turnos.estabelecimento_id)
                 or
                 (meus_turnos.estabelecimento_id is null and p.profissional_id = v_prof)
               )
           and (meus_turnos.de is null or p.inicio_em >= meus_turnos.de)
           and (meus_turnos.ate is null or p.inicio_em <= meus_turnos.ate)
      ) sub
  ), '[]'::jsonb);
end $$;

revoke execute on function public.meus_turnos(timestamptz, timestamptz, uuid) from public, anon;
grant  execute on function public.meus_turnos(timestamptz, timestamptz, uuid) to authenticated;

-- ── 3. meu_perfil_profissional ────────────────────────────────────────────────
create or replace function public.meu_perfil_profissional()
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_linha public.profissional%rowtype;
begin
  if (select auth.uid()) is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  select * into v_linha from public.profissional p where p.usuario_id = (select auth.uid());
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  return public.perfil_profissional_em_json(v_linha);
end $$;

revoke execute on function public.meu_perfil_profissional() from public, anon;
grant  execute on function public.meu_perfil_profissional() to authenticated;

-- ── 4. meu_estabelecimento ───────────────────────────────────────────────────
create or replace function public.meu_estabelecimento(estabelecimento_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_linha public.estabelecimento%rowtype;
  v_papel public.papel_membro;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  select m.papel into v_papel
    from public.membro_estabelecimento m
   where m.estabelecimento_id = meu_estabelecimento.estabelecimento_id
     and m.usuario_id = v_uid;
  if not found then
    perform public.erro(403, 'sem_permissao');
  end if;

  select e.* into v_linha
    from public.estabelecimento e
   where e.id = meu_estabelecimento.estabelecimento_id;

  return privado.estabelecimento_em_json(v_linha, v_papel) - 'documento';
end $$;

revoke execute on function public.meu_estabelecimento(uuid) from public, anon;
grant  execute on function public.meu_estabelecimento(uuid) to authenticated;

-- ── 5. painel_estabelecimento ────────────────────────────────────────────────
create or replace function public.painel_estabelecimento(
  estabelecimento_id uuid,
  de                 timestamptz,
  ate                timestamptz
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_estab     uuid := painel_estabelecimento.estabelecimento_id;
  v_de        timestamptz := painel_estabelecimento.de;
  v_ate       timestamptz := painel_estabelecimento.ate;
  v_agora     timestamptz;
  v_vagas     jsonb;
  v_pendentes jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  if v_estab is null or not privado.eh_membro(v_estab) then
    perform public.erro(403, 'sem_permissao');
  end if;

  if v_de is null then
    perform public.erro(422, 'campo_obrigatorio', 'de');
  end if;
  if v_ate is null then
    perform public.erro(422, 'campo_obrigatorio', 'ate');
  end if;

  v_agora := privado.agora();

  select coalesce(jsonb_agg(jsonb_build_object(
           'vaga', jsonb_build_object(
              'id',                    v.id,
              'funcao',                f.nome,
              'local',                 v.local,
              'regiao_administrativa', v.regiao_administrativa,
              'inicio_em',             v.inicio_em,
              'fim_em',                v.fim_em,
              'valor_centavos',        v.valor_centavos),
           'modo',   v.modo,
           'estado', v.estado,
           -- 0.2.41: Quantas posições republicar_posicoes_restantes republicaria agora (ou nulo)
           'republicavel_em_urgencia',
              (select case when r.restantes > 0 and r.motivo is null then r.restantes else null end
                 from privado.republicacao_da_selecao(v.id) r),
           -- A casa vê "oculta pela Equipe"; o estado segue o do ciclo de vida (0.2.23).
           'oculta', privado.vaga_oculta(v.id),
           'alerta_vaga_vazia',
              v.estado = 'publicada'
              and v_agora >= v.inicio_em - v.alerta_antecedencia
              and v_agora <  v.inicio_em
              and exists (select 1 from public.posicao pa
                           where pa.vaga_id = v.id and pa.estado = 'aberta'),
           'candidatos_pendentes',
              (select count(distinct c.profissional_id)
                 from public.candidatura c
                 join public.posicao pc on pc.id = c.posicao_id
                where pc.vaga_id = v.id
                  and c.estado = 'pendente'
                  and not privado.bloqueado_com_estabelecimento(
                            privado.usuario_do_profissional(c.profissional_id), v_estab)),
           'posicoes',
              (select coalesce(jsonb_agg(jsonb_build_object(
                        'id',                    p.id,
                        'estado',                p.estado,
                        'profissional',          case when p.profissional_id is null then null
                                                      else privado.perfil_publico_profissional(p.profissional_id) end,
                        'turno_id',              t.id,
                        'verificacao',           t.verificacao,
                        'em_atraso',             p.estado = 'confirmada'
                                                 and t.checkin_em is null
                                                 and v_agora >= p.inicio_em + interval '15 minutes'
                                                 and v_agora <  p.fim_em,
                        'a_caminho_em',          t.a_caminho_em,
                        'checkin_em',            t.checkin_em,
                        'checkin_tipo',          t.checkin_tipo,
                        'checkin_confirmado_em', t.checkin_confirmado_em,
                        'cancelamento',          case
                          when p.estado = 'cancelada' and p.profissional_id is not null then
                            (select jsonb_build_object(
                               'causa', case
                                 when o.motivo = 'reabertura_por_atraso' then 'reabertura_por_atraso'
                                 when o.motivo = 'no_show_sem_checkin' then 'no_show_sem_checkin'
                                 when o.motivo in ('exclusão de conta', 'suspensão de conta') then 'outro'
                                 when o.motivo = 'vaga_cancelada' then 'estabelecimento'
                                 when o.autor_id = privado.usuario_do_profissional(p.profissional_id) then 'profissional'
                                 else 'estabelecimento'
                               end,
                               'falta', p.falta,
                               'motivo', case
                                 when o.motivo in ('reabertura_por_atraso', 'no_show_sem_checkin', 'exclusão de conta', 'suspensão de conta', 'vaga_cancelada')
                                   then null
                                 else o.motivo
                               end,
                               'cancelada_em', o.criada_em)
                               from public.ocorrencia o
                              where o.posicao_id = p.id
                                and o.tipo = 'cancelamento'
                              order by o.criada_em desc
                              limit 1)
                          else null end)
                      order by p.id), '[]'::jsonb)
                 from public.posicao p
                 left join public.turno t on t.posicao_id = p.id
                where p.vaga_id = v.id))
         order by v.inicio_em, v.id), '[]'::jsonb)
    into v_vagas
    from public.vaga v
    join public.funcao f on f.id = v.funcao_id
   where v.estabelecimento_id = v_estab
     and v.inicio_em < v_ate
     and v.fim_em    > v_de;

  select coalesce(jsonb_agg(t.id order by t.checkin_em, t.id), '[]'::jsonb)
    into v_pendentes
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v    on v.id = p.vaga_id
   where v.estabelecimento_id = v_estab
     and v.inicio_em < v_ate
     and v.fim_em    > v_de
     and p.estado in ('confirmada', 'cumprida')
     and t.checkin_tipo = 'manual'
     and t.checkin_confirmado_em is null;

  return jsonb_build_object(
    'estabelecimento_id', v_estab,
    'vagas',              v_vagas,
    'checkins_pendentes', v_pendentes);
end $$;

comment on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) is
  'Vagas, candidatos, contratados, check-ins, cancelamentos e republicável em urgência do estabelecimento (RF20, RF13, RF14, RN12, UC07, D1-C). Contrato 0.2.41.';

revoke execute on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) from public, anon;
grant  execute on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) to authenticated;

-- ── 6. perfil_publico ────────────────────────────────────────────────────────
create or replace function public.perfil_publico(id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_prof_user uuid;
  v_perfil    jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  v_prof_user := privado.usuario_do_profissional(perfil_publico.id);
  if v_prof_user is not null then
    if exists (
      select 1 from public.bloqueio b
       where (b.autor_id = v_uid and b.bloqueado_id = v_prof_user)
          or (b.autor_id = v_prof_user and b.bloqueado_id = v_uid)
    ) or exists (
      select 1 from public.membro_estabelecimento m
       where m.usuario_id = v_uid
         and privado.bloqueado_com_estabelecimento(v_prof_user, m.estabelecimento_id)
    ) then
      perform public.erro(404, 'nao_encontrado');
    end if;

    v_perfil := privado.perfil_publico_profissional(perfil_publico.id);

  elsif exists (select 1 from public.estabelecimento e where e.id = perfil_publico.id) then
    if privado.bloqueado_com_estabelecimento(v_uid, perfil_publico.id) then
      perform public.erro(404, 'nao_encontrado');
    end if;

    v_perfil := privado.estabelecimento_publico(perfil_publico.id);
  end if;

  if v_perfil is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  return v_perfil;
end $$;

revoke execute on function public.perfil_publico(uuid) from public, anon;
grant  execute on function public.perfil_publico(uuid) to authenticated;

-- ── 7. registrar_evento ──────────────────────────────────────────────────────
create or replace function public.registrar_evento(
  evento      text,
  vaga_id     uuid default null,
  turno_id    uuid default null,
  ocorrido_em timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_usuario_id  uuid := auth.uid();
  v_agora       timestamptz := privado.agora();
  v_ocorrido    timestamptz;
  v_evento_enum public.evento_de_telemetria;
begin
  if v_usuario_id is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  if evento is null or pg_catalog.btrim(evento) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'evento');
  end if;

  begin
    v_evento_enum := evento::public.evento_de_telemetria;
  exception when invalid_text_representation then
    perform public.erro(422, 'campo_invalido', 'evento');
  end;

  if ocorrido_em is not null then
    if ocorrido_em > v_agora then
      perform public.erro(422, 'registro_no_futuro');
    end if;
    v_ocorrido := ocorrido_em;
  else
    v_ocorrido := v_agora;
  end if;

  insert into public.evento_app (
    usuario_id,
    evento,
    vaga_id,
    turno_id,
    ocorrido_em
  ) values (
    v_usuario_id,
    v_evento_enum,
    vaga_id,
    turno_id,
    v_ocorrido
  );

  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public.registrar_evento(text, uuid, uuid, timestamptz) from public, anon;
grant  execute on function public.registrar_evento(text, uuid, uuid, timestamptz) to authenticated;
