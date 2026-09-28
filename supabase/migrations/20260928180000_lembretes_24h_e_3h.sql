-- S2 · Backend · Lembretes 24 h e 3 h antes do turno (k5R4tzjC)
--
-- Job a cada 5 minutos que envia os lembretes de 24 h e 3 h antes do turno.
-- Configuração do cron de produção (documentada sem aplicação na migração):
-- select cron.schedule('enviar-lembretes-turno', '*/5 * * * *',
--                      $$select privado.enviar_lembretes_turno();$$);

-- ── 1. privado.obter_conteudo_push_lembrete ───────────────────────────────────
-- Monta o conteúdo do push interpolado com Opção A homologada (proposta-textos.md).
create or replace function privado.obter_conteudo_push_lembrete(
  p_turno_id   uuid,
  p_usuario_id uuid,
  p_tipo       text
)
returns jsonb
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  v_turno     record;
  v_eh_prof   boolean;
  v_funcao    text;
  v_estab     text;
  v_horario   text;
  v_title     text;
  v_body      text;
begin
  select t.id,
         p.inicio_em,
         p.profissional_id,
         v.estabelecimento_id,
         f.nome as funcao_nome,
         e.nome as estab_nome
    into v_turno
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v on v.id = p.vaga_id
    join public.funcao f on f.id = v.funcao_id
    join public.estabelecimento e on e.id = v.estabelecimento_id
   where t.id = p_turno_id;

  if not found then
    return null;
  end if;

  v_eh_prof := (privado.usuario_do_profissional(v_turno.profissional_id) = p_usuario_id);
  v_funcao  := v_turno.funcao_nome;
  v_estab   := v_turno.estab_nome;
  v_horario := to_char(v_turno.inicio_em at time zone 'America/Sao_Paulo', 'HH24:MI');

  -- O banco não tem região/bairro estruturado (vaga.local e estabelecimento.endereco são texto livre).
  -- Conforme instrução do orquestrador e RN10, usamos somente o nome do estabelecimento ({estabelecimento}).
  -- Nunca endereço livre. A introdução de região estruturada no banco virá em cartão próprio.
  if v_eh_prof then
    if p_tipo = 'lembrete_24h' then
      v_title := 'Lembrete de turno amanhã';
      v_body  := format('%s em %s amanhã às %s.', v_funcao, v_estab, v_horario);
    elsif p_tipo = 'lembrete_3h' then
      v_title := 'Seu turno começa em 3 horas';
      v_body  := format('%s em %s às %s. Planeje seu trajeto.', v_funcao, v_estab, v_horario);
    end if;
  else
    if p_tipo = 'lembrete_24h' then
      v_title := 'Turno agendado para amanhã';
      v_body  := format('Turno de %s confirmado para amanhã às %s.', v_funcao, v_horario);
    elsif p_tipo = 'lembrete_3h' then
      v_title := 'Turno em 3 horas';
      v_body  := format('Turno de %s começa às %s. O profissional foi lembrado.', v_funcao, v_horario);
    end if;
  end if;

  return jsonb_build_object('title', v_title, 'body', v_body);
end $$;

comment on function privado.obter_conteudo_push_lembrete(uuid, uuid, text) is
  'Monta título e corpo dos lembretes de 24h e 3h segundo a Opção A homologada (proposta-textos.md). Local utiliza apenas nome do estabelecimento (sem endereço/número per RN10 e aviso do orquestrador).';

revoke execute on function privado.obter_conteudo_push_lembrete(uuid, uuid, text) from public, anon, authenticated;
grant execute on function privado.obter_conteudo_push_lembrete(uuid, uuid, text) to service_role;

-- ── 2. privado.enviar_lembretes_turno ──────────────────────────────────────────
-- Job a cada 5 minutos que envia o lembrete devido e ainda não enviado.
-- A marca em notificacao (única por tipo, referência e usuário) garante idempotência.
create or replace function privado.enviar_lembretes_turno()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora     timestamptz := privado.agora();
  v_enviados  integer := 0;
  v_turno     record;
  v_user_prof uuid;
begin
  -- 1. Lembretes de 24 horas:
  -- Janela: entre 24 h e 3 h antes do início do turno.
  -- Turnos confirmados depois da marca de 24 h não recebem lembrete vencido.
  -- Posições canceladas ou não confirmadas não entram.
  for v_turno in
    select t.id as turno_id,
           p.profissional_id,
           v.estabelecimento_id
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga v on v.id = p.vaga_id
     where p.estado = 'confirmada'
       and p.confirmado_em <= p.inicio_em - interval '24 hours'
       and v_agora >= p.inicio_em - interval '24 hours'
       and v_agora < p.inicio_em - interval '3 hours'
  loop
    if v_turno.profissional_id is not null then
      v_user_prof := privado.usuario_do_profissional(v_turno.profissional_id);
      if v_user_prof is not null then
        perform privado.notificar(
          v_user_prof,
          'lembrete_24h'::public.tipo_notificacao,
          v_turno.turno_id,
          jsonb_build_object('turno_id', v_turno.turno_id)
        );
        v_enviados := v_enviados + 1;
      end if;
    end if;

    perform privado.notificar_membros(
      v_turno.estabelecimento_id,
      'lembrete_24h'::public.tipo_notificacao,
      v_turno.turno_id,
      jsonb_build_object('turno_id', v_turno.turno_id)
    );
    v_enviados := v_enviados + 1;
  end loop;

  -- 2. Lembretes de 3 horas:
  -- Janela: entre 3 h antes e o início do turno.
  -- Turnos confirmados com menos de 3 h de antecedência não recebem lembrete atrasado.
  for v_turno in
    select t.id as turno_id,
           p.profissional_id,
           v.estabelecimento_id
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga v on v.id = p.vaga_id
     where p.estado = 'confirmada'
       and p.confirmado_em <= p.inicio_em - interval '3 hours'
       and v_agora >= p.inicio_em - interval '3 hours'
       and v_agora < p.inicio_em
  loop
    if v_turno.profissional_id is not null then
      v_user_prof := privado.usuario_do_profissional(v_turno.profissional_id);
      if v_user_prof is not null then
        perform privado.notificar(
          v_user_prof,
          'lembrete_3h'::public.tipo_notificacao,
          v_turno.turno_id,
          jsonb_build_object('turno_id', v_turno.turno_id)
        );
        v_enviados := v_enviados + 1;
      end if;
    end if;

    perform privado.notificar_membros(
      v_turno.estabelecimento_id,
      'lembrete_3h'::public.tipo_notificacao,
      v_turno.turno_id,
      jsonb_build_object('turno_id', v_turno.turno_id)
    );
    v_enviados := v_enviados + 1;
  end loop;

  return v_enviados;
end $$;

comment on function privado.enviar_lembretes_turno() is
  'Job a cada 5 minutos que envia lembrete_24h e lembrete_3h para profissional e membros do contratante. Idempotente pela marca de envio em notificacao. Não envia vencidos nem turnos cancelados.';

revoke execute on function privado.enviar_lembretes_turno() from public, anon, authenticated;
grant execute on function privado.enviar_lembretes_turno() to service_role;

create or replace function privado.enviar_lembretes()
returns integer
language sql
security definer
set search_path = ''
as $$
  select privado.enviar_lembretes_turno();
$$;

revoke execute on function privado.enviar_lembretes() from public, anon, authenticated;
grant execute on function privado.enviar_lembretes() to service_role;
