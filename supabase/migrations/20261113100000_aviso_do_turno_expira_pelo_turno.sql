-- D-20 (F-031 7.4): o aviso de check-out pendente (fim_sem_checkout) nunca saía, e o aviso de check-in à casa
-- (checkin e checkin_manual_pendente) não saía quando o check-in era depois do início da vaga.
--
-- Causa: privado.notificacao_expirada_pelo_relogio (corpo em 20260928220000:275, renomeada em 20260929100000:412)
-- punha os três no mesmo ramo do lembrete_24h e do lembrete_3h, que expira no INÍCIO da vaga. O fim_sem_checkout
-- nasce depois do fim, sempre depois do início, e o despacho o marcava falhou/vaga_ou_turno_ja_iniciado.
--
-- Agora cada um expira pelo próprio turno:
--   - fim_sem_checkout: o critério de quem o cria (alertar_fim_sem_checkout): check-in, sem check-out, posição não
--     cancelada, até o fim + fim_sem_checkout_janela (6 h);
--   - checkin_manual_pendente: enquanto a casa pode confirmar: sem confirmação, verificação pendente, posição não
--     cancelada, até o fim + prazo_da_confirmacao_tardia() (24 h);
--   - checkin: até o fim do turno, com a posição não cancelada.
-- O lembrete_24h e o lembrete_3h seguem expirando no início. Os outros ramos são a cópia literal do corpo vivo.
-- Só o corpo muda: mesma assinatura, e as permissões são reafirmadas abaixo.
--
-- Volta: migração corretiva que recria o corpo de 20260928220000:275 com o nome notificacao_expirada_pelo_relogio.

select set_config('lock_timeout', '2s', true);

create or replace function privado.notificacao_expirada_pelo_relogio(p_notificacao_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_notif  public.notificacao%rowtype;
  v_inicio timestamptz;
  v_limite timestamptz;
  v_agora  timestamptz := privado.agora();
begin
  select * into v_notif from public.notificacao where id = p_notificacao_id;
  if not found then
    return true;
  end if;

  if v_notif.tipo in ('inicio_sem_checkin', 'atraso_15min') then
    select p.fim_em into v_limite
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
     where t.id = v_notif.referencia_id
       and p.estado = 'confirmada'
       and t.checkin_em is null;
    return v_limite is null or v_limite <= v_agora;
  end if;

  if v_notif.tipo = 'cancelamento' then
    select p.inicio_em, p.fim_em into v_inicio, v_limite
      from public.posicao p
     where p.id = v_notif.referencia_id
       and exists (select 1 from public.ocorrencia o
                    where o.posicao_id = p.id and o.tipo = 'cancelamento'
                      and o.motivo = 'reabertura_por_atraso');
    if v_limite is not null then
      return v_limite <= v_agora;
    end if;
  end if;

  if v_notif.tipo = 'vaga_vazia' then
    select g.inicio_em into v_inicio
      from public.posicao p
      join public.vaga g on g.id = p.vaga_id
     where p.id = v_notif.referencia_id;

    if exists (select 1 from public.posicao p
                where p.id = v_notif.referencia_id and p.estado <> 'aberta') then
      return true;
    end if;

    if v_inicio is null then
      select g.inicio_em into v_inicio from public.vaga g where g.id = v_notif.referencia_id;
    end if;

    return v_inicio is null or v_inicio <= v_agora;
  end if;

  -- D-20 (F-031 7.4): estes três avisos são do turno em curso; NÃO expiram no início da vaga.
  -- fim_sem_checkout: o critério de quem cria o aviso (privado.alertar_fim_sem_checkout): check-in feito, sem
  -- check-out, posição não cancelada e até o fim previsto + fim_sem_checkout_janela.
  if v_notif.tipo = 'fim_sem_checkout' then
    select p.fim_em + privado.parametro_de_notificacao('fim_sem_checkout_janela') into v_limite
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
     where t.id = v_notif.referencia_id
       and t.checkin_em is not null
       and t.checkout_em is null
       and p.estado <> 'cancelada';
    return v_limite is null or v_limite <= v_agora;
  end if;

  -- checkin_manual_pendente: vale enquanto a casa ainda pode confirmar (confirmar_checkin_manual): check-in sem
  -- confirmação, verificação pendente, posição não cancelada e até o fim + o prazo da confirmação tardia (24 h).
  if v_notif.tipo = 'checkin_manual_pendente' then
    select p.fim_em + privado.prazo_da_confirmacao_tardia() into v_limite
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
     where t.id = v_notif.referencia_id
       and t.checkin_em is not null
       and t.checkin_confirmado_em is null
       and t.verificacao = 'pendente'
       and p.estado <> 'cancelada';
    return v_limite is null or v_limite <= v_agora;
  end if;

  -- checkin: o aviso à casa de que o profissional chegou; vale até o fim do turno, com a posição não cancelada.
  if v_notif.tipo = 'checkin' then
    select p.fim_em into v_limite
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
     where t.id = v_notif.referencia_id
       and p.estado <> 'cancelada';
    return v_limite is null or v_limite <= v_agora;
  end if;

  if v_notif.tipo in ('vaga', 'vagas_agrupadas', 'vaga_sem_elegiveis') then
    select max(p.fim_em) - interval '1 hour' into v_limite
      from public.posicao p
     where p.vaga_id = v_notif.referencia_id
       and p.estado = 'aberta'
       and p.reaberta_por_atraso_de is not null;
    if v_limite is not null then
      return v_limite <= v_agora;
    end if;
    select g.inicio_em into v_inicio from public.vaga g where g.id = v_notif.referencia_id;
  elsif v_notif.tipo in ('confirmacao', 'cancelamento') then
    select g.inicio_em into v_inicio
      from public.posicao p
      join public.vaga g on g.id = p.vaga_id
     where p.id = v_notif.referencia_id;

    if v_inicio is null then
      select g.inicio_em into v_inicio
        from public.turno t
        join public.posicao p on p.id = t.posicao_id
        join public.vaga g on g.id = p.vaga_id
       where t.id = v_notif.referencia_id;
    end if;

    if v_inicio is null then
      select g.inicio_em into v_inicio
        from public.vaga g
       where g.id = v_notif.referencia_id;
    end if;
  elsif v_notif.tipo in ('lembrete_24h', 'lembrete_3h') then
    select g.inicio_em into v_inicio
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga g on g.id = p.vaga_id
     where t.id = v_notif.referencia_id;

    if v_inicio is null then
      select g.inicio_em into v_inicio
        from public.posicao p
        join public.vaga g on g.id = p.vaga_id
       where p.id = v_notif.referencia_id;
    end if;
  end if;

  if v_inicio is not null and v_inicio <= v_agora then
    return true;
  end if;

  return false;
end $$;

comment on function privado.notificacao_expirada_pelo_relogio(uuid) is
  'A regra de tempo de privado.notificacao_expirada: expira no início do turno ou da vaga; inicio_sem_checkin e atraso_15min valem até o fim; reabertura por atraso até fim − 1 h (8zLfn0mt item 5). D-20: fim_sem_checkout vale até o fim + fim_sem_checkout_janela enquanto o turno está sem check-out; checkin_manual_pendente, até o fim + a confirmação tardia enquanto pendente; checkin, até o fim.';

revoke execute on function privado.notificacao_expirada_pelo_relogio(uuid) from public, anon, authenticated;
grant  execute on function privado.notificacao_expirada_pelo_relogio(uuid) to service_role;
