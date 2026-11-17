-- Proposta 0.2.85: aguarda decisão do JP (painel: aceite tardio).
-- Não altera faltas, cancelamento, aceite ou reabertura. Preserva autorização,
-- travamento de linha e idempotência; só a borda superior usa a confirmação.
create or replace function public.avisar_a_caminho(turno_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid     uuid := (select auth.uid());
  v_inicio  timestamptz;
  v_confirmado timestamptz;
  v_aviso   timestamptz;
  v_agora   timestamptz;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if avisar_a_caminho.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  -- Só o profissional **confirmado**. A posição cancelada guarda o profissional (RN12),
  -- e um aviso ali diria à casa que vem alguém que não vem. Turno inexistente, de outro
  -- ou de posição que não está confirmada respondem igual, como o contrato pede.
  select p.inicio_em, p.confirmado_em, t.a_caminho_em
    into v_inicio, v_confirmado, v_aviso
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = avisar_a_caminho.turno_id
     and p.estado = 'confirmada'
     and privado.usuario_do_profissional(p.profissional_id) = v_uid
     for update of t;

  if not found then
    perform public.erro(403, 'sem_permissao');
  end if;

  if v_aviso is null then
    v_agora := privado.agora();

    if v_agora < v_inicio - interval '3 hours'
       or v_agora > greatest(v_inicio, v_confirmado) + interval '15 minutes' then
      perform public.erro(422, 'a_caminho_fora_da_janela');
    end if;

    update public.turno t
       set a_caminho_em = coalesce(t.a_caminho_em, v_agora)
     where t.id = avisar_a_caminho.turno_id
    returning t.a_caminho_em into v_aviso;
  end if;

  return jsonb_build_object(
    'turno_id',     avisar_a_caminho.turno_id,
    'a_caminho_em', v_aviso);
end $$;

comment on function public.avisar_a_caminho(uuid) is
  'Aviso operacional de 3h antes do início até greatest(inicio, confirmado_em) + 15min. Não é presença. Contrato 0.2.85.';
revoke execute on function public.avisar_a_caminho(uuid) from public, anon;
grant execute on function public.avisar_a_caminho(uuid) to authenticated;

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
    'confirmado_em', p.confirmado_em,
    'vaga', jsonb_build_object(
      'id',                    v.id,
      'funcao',                f.nome,
      'local',                 v.local,
      'regiao_administrativa', v.regiao_administrativa,
      'ponto',                 case
                                 -- 1. Membro do estabelecimento da vaga: lê coordenadas da própria casa
                                 when exists (
                                   select 1 from public.membro_estabelecimento m
                                    where m.estabelecimento_id = v.estabelecimento_id
                                      and m.usuario_id = autor
                                 )
                                   and v.ponto is not null
                                   then privado.ponto_em_json(v.ponto)
                                 -- 2. Profissional alocado no turno:
                                 --    - Visível enquanto confirmado (futuro / em andamento, LGPD art. 7º, V)
                                 --    - Visível se cumprido e presença verificada (LGPD art. 7º, VI)
                                 when privado.usuario_do_profissional(p.profissional_id) = autor
                                   and (
                                     p.estado = 'confirmada'
                                     or (p.estado = 'cumprida' and t.verificacao = 'verificado')
                                   )
                                   and v.ponto is not null
                                   then privado.ponto_em_json(v.ponto)
                                 -- 3. Nos demais casos (cancelado, não verificado, ou terceiros): nulo (LGPD art. 6º, III)
                                 else null
                               end,
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
  'Turno com confirmado_em para janela simétrica do aviso a caminho (0.2.85); mantém coordenadas, cancelamento e avaliação.';
revoke execute on function privado.turno_em_json(uuid, uuid) from public, anon, authenticated;
grant execute on function privado.turno_em_json(uuid, uuid) to service_role;
