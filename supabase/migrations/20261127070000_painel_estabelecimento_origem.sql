-- Z0HbaZ0P: `public.painel_estabelecimento` passa a devolver `vaga.origem` (`VagaResumo.origem`, contrato 0.2.55).
--
-- O contrato declara `origem` (`publicacao` | `chamada_direta`) em `VagaResumo`, e `VagaNoPainel.vaga` o referencia. A definição
-- vigente (20261112100000_confirmacao_tardia_24h.sql) montava `vaga` com 7 chaves e não o incluía: o app lia toda vaga da casa como
-- publicação, e o botão "Acompanhar chamadas" de Minhas vagas (iOS e Android) nunca aparecia para a vaga direta.
--
-- Corpo de 20261112100000 com uma única linha nova no objeto `vaga`: `'origem', v.origem`. Assinatura, `security definer set
-- search_path = ''`, grants, comentário e todo o resto ficam iguais. `vaga.origem` é `not null default 'publicacao'` com CHECK nos
-- dois valores (20261107300000), então o campo sai sempre preenchido.
--
-- Não muda a superfície: o contrato já declara `VagaResumo.origem` desde a 0.2.55 e a resposta passa a casar com ele.
-- contrato: corpo-sem-mudanca-de-superficie public.painel_estabelecimento 0.2.118

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

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'anonimizada') then
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
              'valor_centavos',        v.valor_centavos,
              -- 0.2.55 (VagaResumo.origem): sem ele a vaga direta é lida como publicação e o "Acompanhar chamadas" nunca aparece.
              'origem',                v.origem),
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
     and t.verificacao = 'pendente'
     and t.checkin_confirmado_em is null;

  return jsonb_build_object(
    'estabelecimento_id', v_estab,
    'vagas',              v_vagas,
    'checkins_pendentes', v_pendentes);
end $$;

comment on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) is
  'Vagas, candidatos, contratados, check-ins, cancelamentos e republicável em urgência do estabelecimento (RF20, RF13, RF14, RN12, UC07, D1-C). Contrato 0.2.41. checkins_pendentes lista apenas turnos com verificacao = pendente. Desde 0.2.55 vaga.origem (publicacao ou chamada_direta).';

revoke execute on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) from public, anon;
grant  execute on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) to authenticated;
