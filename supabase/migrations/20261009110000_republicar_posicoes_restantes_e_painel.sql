-- 20261009110000_republicar_posicoes_restantes_e_painel.sql
--
-- Republicar as posições restantes em urgência (modo seleção, D1-C, contrato 0.2.41).
-- Passo P3 e P4 do plano (requisitos/republicar-posicoes-restantes-plano.md):
--   1. RPC public.republicar_posicoes_restantes(vaga_id uuid, chave uuid) returns jsonb
--   2. Atualização de public.painel_estabelecimento incluindo o campo republicavel_em_urgencia

-- ── 1. RPC public.republicar_posicoes_restantes ───────────────────────────────
--
-- Publica uma vaga nova de urgência com as posições restantes de uma vaga de
-- seleção que fechou no prazo das 24 h (D1-C, RR-RN01 a RR-RN10).
--
-- Ordem estrita das conferências (seção 6 de republicar-posicoes-restantes-v1.1.md):
--   1. Sem sessão: 401 nao_autenticado
--   2. Perfil de contratante e conta ativa: privado.exigir_perfil('contratante') e privado.exigir_conta_ativa()
--   3. Campos obrigatórios: vaga_id e chave (422 campo_obrigatorio)
--   4. Origem inexistente: 404 nao_encontrado; de outra casa: 403 sem_permissao
--   5. Reenvio idempotente pela chave: se já existe vaga criada por esta RPC para este estabelecimento e chave, devolve-a
--   6. Origem oculta pela moderação: 422 vaga_oculta
--   7. Elegibilidade e sobras (RR-RN01, RR-RN03, RR-RN05): 422 republicacao_indisponivel com details
--   8. Cria a vaga chamando public.publicar_vaga em urgência e grava vaga.republicada_de

create or replace function public.republicar_posicoes_restantes(
  vaga_id uuid,
  chave   uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_origem_id uuid := republicar_posicoes_restantes.vaga_id;
  v_chave     uuid := republicar_posicoes_restantes.chave;
  v_origem    public.vaga%rowtype;
  v_ja_criada public.vaga%rowtype;
  v_posicoes  uuid[];
  v_sobras    int;
  v_motivo    text;
  v_nova      jsonb;
  v_nova_id   uuid;
begin
  -- 1. Sem sessão: 401 nao_autenticado
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- 2. Perfil contratante e conta ativa (RR-RN06)
  perform privado.exigir_perfil('contratante');
  perform privado.exigir_conta_ativa();

  -- 3. vaga_id e chave nulos: 422 campo_obrigatorio
  if v_origem_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;
  if v_chave is null then
    perform public.erro(422, 'campo_obrigatorio', 'chave');
  end if;

  -- 4. Origem inexistente (404) ou de outra casa (403)
  select * into v_origem from public.vaga g where g.id = v_origem_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if not privado.eh_membro(v_origem.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- 5. Reenvio pela chave antes do resto (H4, RR-RN04)
  -- Se a casa já publicou uma vaga com esta chave_cliente, devolve a mesma
  select * into v_ja_criada
    from public.vaga g
   where g.estabelecimento_id = v_origem.estabelecimento_id
     and g.chave_cliente = v_chave;
  if found then
    select array_agg(p.id order by p.id) into v_posicoes
      from public.posicao p
     where p.vaga_id = v_ja_criada.id;
    return jsonb_build_object(
      'vaga_id', v_ja_criada.id,
      'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[]))
    );
  end if;

  -- 6. Origem oculta pela moderação (RR-RN07)
  if privado.vaga_oculta(v_origem.id) then
    perform public.erro(422, 'vaga_oculta');
  end if;

  -- 7. Elegibilidade e sobras (RR-RN01, RR-RN03, RR-RN05)
  select r.restantes, r.motivo into v_sobras, v_motivo
    from privado.republicacao_da_selecao(v_origem.id) r;

  if v_motivo is not null then
    perform public.erro(422, 'republicacao_indisponivel', v_motivo);
  end if;

  -- 8. Chama publicar_vaga com modo urgencia, sobras calculadas e horário/valor da origem.
  -- Depois vincula republicada_de na vaga nova gerada.
  v_nova := public.publicar_vaga(
    estabelecimento_id     => v_origem.estabelecimento_id,
    funcao_id              => v_origem.funcao_id,
    inicio_em              => v_origem.inicio_em,
    fim_em                 => v_origem.fim_em,
    local                  => v_origem.local,
    ponto                  => jsonb_build_object(
                                'latitude',  extensions.ST_Y(v_origem.ponto::extensions.geometry),
                                'longitude', extensions.ST_X(v_origem.ponto::extensions.geometry)),
    valor_centavos         => v_origem.valor_centavos,
    posicoes               => v_sobras,
    inclui_refeicao        => v_origem.inclui_refeicao,
    inclui_transporte      => v_origem.inclui_transporte,
    exige_material_proprio => v_origem.exige_material_proprio,
    responsavel_local      => v_origem.responsavel_local,
    modo                   => 'urgencia'::public.modo_preenchimento,
    chave                  => v_chave,
    traje                  => v_origem.traje,
    participa_rateio       => v_origem.participa_rateio,
    observacoes            => v_origem.observacoes,
    alerta_antecedencia_min => (extract(epoch from v_origem.alerta_antecedencia) / 60)::int,
    regiao_administrativa  => v_origem.regiao_administrativa
  );

  v_nova_id := (v_nova->>'vaga_id')::uuid;

  -- Vincula a origem na vaga nova. Se bater no índice único parcial (corrida de dois toques
  -- simultâneos com chaves diferentes), trata a violação e recusa com ja_republicada.
  begin
    update public.vaga
       set republicada_de = v_origem.id
     where id = v_nova_id;
  exception
    when unique_violation then
      perform public.erro(422, 'republicacao_indisponivel', 'ja_republicada');
  end;

  return v_nova;
end $$;

comment on function public.republicar_posicoes_restantes(uuid, uuid) is
  'Republica em urgência as posições restantes de uma vaga de seleção fechada (D1-C, RF05, RF09, RN24, UC01). Contrato 0.2.41.';

revoke execute on function public.republicar_posicoes_restantes(uuid, uuid) from public, anon;
grant  execute on function public.republicar_posicoes_restantes(uuid, uuid) to authenticated;

-- ── 2. Atualização de public.painel_estabelecimento ───────────────────────────
--
-- Passa a expor o campo republicavel_em_urgencia (int ou nulo) por vaga (contrato 0.2.41).

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
