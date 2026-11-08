-- Pedir nova análise de foto recusada (contrato 0.2.54, já declarado em 0.2.62; RN37, RN46).
--
-- É o caminho de revisão da decisão automatizada (LGPD, art. 20): o titular cuja foto foi
-- recusada, ou não publicada por falha da análise, pede que a análise automática seja
-- refeita. O contrato fixa o comportamento:
--   · uma vez por foto, só para `recusada` ou `nao_publicada`: volta a `em_analise` e a
--     análise é refeita uma vez;
--   · repetir o pedido da mesma foto não gera outra análise e devolve o estado atual;
--   · outro estado é `409 midia_indisponivel` (`estado_invalido`);
--   · depois do expurgo da recusada (até 24 h) é `409 midia_indisponivel` (`expurgada`);
--   · o pedido **não estende** a retenção do arquivo.
--
-- Por que duas colunas: `atualizado_em` é o relógio do expurgo das recusadas, mas a Edge
-- Function `moderar-midia` regrava esse campo a cada decisão. Sem guardar o prazo original,
-- uma segunda recusa reiniciaria as 24 h. `expurgo_ate` congela o prazo da primeira decisão
-- no momento do pedido; `nova_analise_pedida_em` é o limite de um pedido por foto.
--
-- Primeira implementação de RPC já declarada no contrato (isenção 1 do portão de contrato):
-- nenhuma assinatura muda.

-- ── 1. As duas colunas ────────────────────────────────────────────────────────

alter table privado.midia
  add column nova_analise_pedida_em timestamptz,
  add column expurgo_ate            timestamptz;

comment on column privado.midia.nova_analise_pedida_em is
  'Quando o titular pediu a nova análise da foto recusada ou não publicada (RN37, LGPD art. 20). Preenchida, o pedido não se repete: é o limite de um pedido por foto.';
comment on column privado.midia.expurgo_ate is
  'Prazo de expurgo congelado no pedido de nova análise: decisão original + 24 h. A nova análise não estende a retenção do arquivo (contrato 0.2.54).';

-- ── 2. A projeção: pode_pedir_nova_analise deixa de ser sempre false ──────────
--
-- `true` só quando: a mídia está `recusada` ou `nao_publicada`; o pedido ainda não foi feito;
-- o arquivo ainda não venceu o prazo de 24 h; e o titular não tem outra foto de perfil
-- `aprovada` ou `em_analise` (o índice de foto única recusaria a volta a `em_analise`).

create or replace function privado.midia_em_json(m privado.midia) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', m.id,
    'tipo', m.tipo,
    'estado', case when m.estado = 'expurgada' then 'removida' else m.estado end,
    'motivo_recusa', m.motivo_recusa,
    'pode_pedir_nova_analise', privado.midia_pode_pedir_nova_analise(m),
    'estabelecimento_id', m.estabelecimento_id)
$$;

create or replace function privado.midia_pode_pedir_nova_analise(m privado.midia) returns boolean
language sql stable security definer set search_path = '' as $$
  select m.estado in ('recusada', 'nao_publicada')
     and m.nova_analise_pedida_em is null
     and m.atualizado_em + interval '24 hours' > privado.agora()
     and not exists (
       select 1 from privado.midia o
        where o.id <> m.id
          and o.tipo = 'foto_perfil'
          and o.dono_tipo = m.dono_tipo
          and coalesce(o.estabelecimento_id, o.dono_usuario_id) = coalesce(m.estabelecimento_id, m.dono_usuario_id)
          and o.estado in ('aprovada', 'em_analise'))
$$;

comment on function privado.midia_pode_pedir_nova_analise(privado.midia) is
  'Se o titular ainda pode pedir a nova análise desta foto (contrato 0.2.54): recusada ou não publicada, sem pedido anterior, dentro das 24 h e sem outra foto ativa.';

revoke all on function privado.midia_pode_pedir_nova_analise(privado.midia) from public, anon, authenticated;
grant execute on function privado.midia_pode_pedir_nova_analise(privado.midia) to service_role;

-- ── 3. A RPC ──────────────────────────────────────────────────────────────────

create function public.pedir_nova_analise_midia(midia_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := privado.usuario_midia(true);   -- 401, 403 recurso_desligado, 403 conta_suspensa
  v_m   privado.midia;
begin
  select m.* into v_m from privado.midia m
   where m.id = pedir_nova_analise_midia.midia_id
     and (m.estabelecimento_id is null and m.dono_usuario_id = v_uid
          or privado.eh_membro(m.estabelecimento_id))
   for update;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;

  -- Repetir o pedido devolve o estado atual, sem outra análise.
  if v_m.nova_analise_pedida_em is not null then
    return privado.midia_em_json(v_m);
  end if;

  -- Arquivo expurgado, ou já vencido o prazo de 24 h da decisão: o pedido não estende a retenção.
  if v_m.estado = 'expurgada'
     or (v_m.estado in ('recusada', 'nao_publicada')
         and v_m.atualizado_em + interval '24 hours' <= privado.agora()) then
    perform public.erro(409, 'midia_indisponivel', 'expurgada');
  end if;

  if v_m.estado not in ('recusada', 'nao_publicada') then
    perform public.erro(409, 'midia_indisponivel', 'estado_invalido');
  end if;

  begin
    update privado.midia
       set estado = 'em_analise',
           motivo_recusa = null,
           motivo_codigo = null,
           nova_analise_pedida_em = privado.agora(),
           expurgo_ate = v_m.atualizado_em + interval '24 hours',
           atualizado_em = privado.agora()
     where id = v_m.id
    returning * into v_m;
  exception when unique_violation then
    -- O titular já tem outra foto aprovada ou em análise: esta não pode voltar.
    perform public.erro(409, 'midia_indisponivel', 'estado_invalido');
  end;

  perform pgmq.send('moderacao_midia', jsonb_build_object('midia_id', v_m.id));
  return privado.midia_em_json(v_m);
end $$;

comment on function public.pedir_nova_analise_midia(uuid) is
  'Pede uma única nova análise automática de foto recusada ou não publicada (contrato 0.2.54, RN37, RN46; LGPD art. 20). Repetir devolve o estado atual. Outro estado ou outra foto ativa: 409 midia_indisponivel estado_invalido; vencida ou expurgada: 409 expurgada. Não estende a retenção (expurgo_ate).';

revoke execute on function public.pedir_nova_analise_midia(uuid) from public, anon;
grant  execute on function public.pedir_nova_analise_midia(uuid) to authenticated;

-- ── 4. O expurgo respeita o prazo congelado ───────────────────────────────────
--
-- Recusada ou não publicada: vence no prazo congelado, se houver, ou 24 h depois da decisão.
-- Em nova análise ainda sem veredito quando o prazo original vence: expurga também. Assim a
-- fila de moderação parada (falha fechada) não segura o arquivo além das 24 h. A Edge
-- Function `moderar-midia` só grava veredito em linha `em_analise`, então a decisão que
-- chegar depois não ressuscita a mídia expurgada.

create or replace function privado.expurgar_midias_recusadas()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_qtd integer := 0;
  v_caminhos jsonb;
begin
  for r in
    select id, storage_path
      from privado.midia
     where (estado in ('recusada', 'nao_publicada')
            and coalesce(expurgo_ate, atualizado_em + interval '24 hours') <= privado.agora())
        or (estado = 'em_analise'
            and expurgo_ate is not null
            and expurgo_ate <= privado.agora())
     for update skip locked
  loop
    v_caminhos := jsonb_build_array(r.storage_path, replace(r.storage_path, '.jpg', '_thumb.jpg'));

    perform pgmq.send(
      'expurgo_midia',
      jsonb_build_object(
        'verificacao_id', r.id::text,
        'bucket', 'midia-perfil',
        'caminhos', v_caminhos,
        'origem', 'foto_perfil'
      )
    );

    update privado.midia
       set estado = 'expurgada',
           atualizado_em = privado.agora()
     where id = r.id;

    v_qtd := v_qtd + 1;
  end loop;

  return v_qtd;
end $$;

comment on function privado.expurgar_midias_recusadas() is
  'Enfileira para expurgo físico no Storage as fotos recusadas ou não publicadas há mais de 24 horas da decisão original (expurgo_ate, quando houve pedido de nova análise), inclusive a que ainda espera a nova análise, e marca estado=expurgada. Idempotente.';

revoke execute on function privado.expurgar_midias_recusadas() from public, anon, authenticated;
grant  execute on function privado.expurgar_midias_recusadas() to service_role;
