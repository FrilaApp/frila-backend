-- Ordem de travas: operacao_suspender_conta e bloquear × aceite e exclusão (issue #526, B-061).
--
-- O resíduo que a 20261117010000 (#522) deixou anotado, agora medido. A regra é a do aceite,
-- vaga -> chamada -> usuario, e duas funções pegavam o usuario antes:
--
--   privado.operacao_suspender_conta: usuario FOR UPDATE -> (contratante) vagas da casa FOR UPDATE
--                      -> update estado = 'suspensa' -> gatilho trg_usuario_suspensao_chamada
--                      -> update das chamadas abertas da conta
--   public.bloquear:   insert em public.bloqueio -> chave estrangeira: as duas contas FOR KEY SHARE
--                      -> gatilho trg_bloqueio_encerrar_chamada -> update das chamadas abertas
--                         entre as partes
--
-- Contra o aceite (vaga -> chamada -> conta FOR KEY SHARE na chave estrangeira do aviso) e a
-- exclusão (vaga -> chamada -> usuario FOR UPDATE), cada uma fecha um ciclo. Medido com a ordem
-- forçada por uma terceira conexão (cenários 9 a 12 de scripts/corrida-chamada.sh, 4 rodadas por
-- ordem), na develop antes desta migração:
--   9a. suspensão do profissional com o aceite dele em voo ............ 40P01 em 4 de 4
--   9b. aceite com a suspensão do profissional em voo ................. 40P01 em 4 de 4
--   9c. suspensão da casa (único membro) com o aceite em voo .......... 40P01 em 4 de 4
--   10. exclusão com a suspensão da mesma conta em voo ................ 40P01 em 4 de 4
--   11a. a casa bloqueia o profissional que se exclui ................. 40P01 em 4 de 4
--   11b. o profissional bloqueia a casa que se exclui ................. 40P01 em 4 de 4
--   12a/12b. bloqueio × aceite, nas duas ordens ....................... 0 de 4 (não há ciclo: o
--        aceite não pede nada que o bloqueio segure; fica como guarda)
--
-- O conserto é o da 20261117010000: antes do usuario, cada função trava por id o que o gatilho
-- dela vai mexer, no predicado do próprio gatilho, copiado. A suspensão trava as vagas (as que o
-- caminho do contratante recolhe e as das chamadas abertas) e depois as chamadas; o bloqueio
-- trava as chamadas abertas entre as partes (ele não mexe em vaga). Quem chega com o outro em
-- voo espera na vaga ou na chamada, sem segurar a conta, e o desfecho é o de quem chegou
-- primeiro: a suspensão que chega depois do aceite reabre o turno que ele confirmou; o aceite
-- que chega depois da suspensão recebe chamada_indisponivel; a exclusão anonimiza a conta já
-- suspensa; o bloqueio fica gravado contra a conta já anonimizada.
--
-- O que não muda, de propósito:
--   * O modo da trava do usuario na suspensão, FOR UPDATE (a mesma barreira da exclusão: turno
--     confirmado por outro caminho espera a suspensão ou cai em 40P01, nunca fica de pé).
--   * responder_chamada, excluir_conta e os gatilhos.
--   * privado.expirar_chamadas (chamada antes da vaga) segue fora: não é desta issue.
--
-- Corpos copiados da versão vigente (bloquear: 20260929100000; operacao_suspender_conta:
-- 20261001100000, conferidos com pg_get_functiondef no banco local), com só o bloco de travas
-- acrescentado. Nenhuma assinatura muda: bloquear segue o contrato, e a suspensão é do esquema
-- privado e não está nele. create or replace mantém o comentário e as permissões.

select set_config('lock_timeout', '2s', true);

-- contrato: corpo-sem-mudanca-de-superficie public.bloquear 0.2.105
create or replace function public.bloquear(alvo_tipo text, alvo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_tipo   text := bloquear.alvo_tipo;
  v_alvo   uuid := bloquear.alvo_id;
  v_perfil public.perfil_conta;
  v_contas uuid[];
  v_criado timestamptz;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  if v_tipo is null then
    perform public.erro(422, 'campo_obrigatorio', 'alvo_tipo');
  end if;
  if v_alvo is null then
    perform public.erro(422, 'campo_obrigatorio', 'alvo_id');
  end if;
  if v_tipo not in ('profissional', 'estabelecimento') then
    perform public.erro(422, 'campo_invalido', 'alvo_tipo');
  end if;

  v_perfil := privado.perfil_da_conta();
  if (v_perfil = 'profissional') is distinct from (v_tipo = 'estabelecimento') then
    perform public.erro(422, 'campo_invalido', 'alvo_tipo');
  end if;

  if v_tipo = 'estabelecimento' then
    select array_agg(m.usuario_id) into v_contas
      from public.membro_estabelecimento m
     where m.estabelecimento_id = v_alvo;
  else
    select array_agg(p.usuario_id) into v_contas
      from public.profissional p
     where p.id = v_alvo;
  end if;

  if v_contas is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- ── Ordem de aquisição: chamada -> usuario, a do aceite (#526) ─────────────────
  --
  -- Antes do insert, por id, as chamadas abertas entre as partes: o predicado do gatilho
  -- trg_bloqueio_encerrar_chamada, copiado, com as contas bloqueadas todas de uma vez. A chave
  -- estrangeira do bloqueio trava as duas contas em FOR KEY SHARE, e o gatilho só chega nas
  -- chamadas depois; quem as segura (a exclusão da conta bloqueada, que trava a chamada antes do
  -- usuario) esperava o bloqueio, e o bloqueio esperava a chamada.
  perform 1 from public.chamada c
   where c.estado = 'aberta'
     and (
       (c.estabelecimento_id in (select m.estabelecimento_id from public.membro_estabelecimento m where m.usuario_id = v_uid)
        and c.profissional_id in (select p.id from public.profissional p where p.usuario_id = any (v_contas)))
       or
       (c.estabelecimento_id in (select m.estabelecimento_id from public.membro_estabelecimento m where m.usuario_id = any (v_contas))
        and c.profissional_id in (select p.id from public.profissional p where p.usuario_id = v_uid))
     )
   order by c.id
     for update;

  -- Idempotente pelo par: o reenvio não cria linha, e o `criado_em` devolvido é o do
  -- primeiro bloqueio.
  insert into public.bloqueio (autor_id, bloqueado_id, criado_em)
  select v_uid, c, privado.agora() from unnest(v_contas) c
  on conflict (autor_id, bloqueado_id) do nothing;

  select min(b.criado_em) into v_criado
    from public.bloqueio b
   where b.autor_id = v_uid and b.bloqueado_id = any (v_contas);

  return jsonb_build_object('alvo_tipo', v_tipo, 'alvo_id', v_alvo, 'criado_em', v_criado);
end $$;

create or replace function privado.operacao_suspender_conta(
  usuario_id  uuid,
  motivo      text,
  operador_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid         uuid := operacao_suspender_conta.usuario_id;
  v_motivo      text := pg_catalog.btrim(operacao_suspender_conta.motivo);
  v_operador    uuid := operacao_suspender_conta.operador_id;
  v_usuario     public.usuario%rowtype;
  v_agora       timestamptz := privado.agora();
  v_pos         public.posicao%rowtype;
  v_cand        record;
  v_vagas       uuid[];
  v_cancelados  integer := 0;
  v_oc_id       uuid;
begin
  if v_uid is null then
    perform public.erro(422, 'campo_obrigatorio', 'usuario_id');
  end if;

  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_uid);

  -- ── Ordem de aquisição: vaga -> chamada -> usuario, a do aceite (#526) ────────
  --
  -- Antes do usuario, cada uma por id: as vagas que o caminho do contratante recolhe (as futuras
  -- da casa em que a conta é o único membro, o predicado do passo 2, copiado) e as das chamadas
  -- abertas, e depois as chamadas abertas que o gatilho trg_usuario_suspensao_chamada vai fechar
  -- (o predicado dele, copiado: a profissional chamada ou quem chamou). O aceite trava a vaga e a
  -- chamada e só depois a conta (a chave estrangeira do aviso), então a suspensão que chega com
  -- ele em voo espera a vaga e lê os turnos confirmados depois dele, e os reabre logo abaixo.
  perform 1 from public.vaga g
   where (g.inicio_em > v_agora
          and g.estado in ('publicada', 'preenchida')
          and g.estabelecimento_id in (
            select m.estabelecimento_id from public.membro_estabelecimento m
             where m.usuario_id = v_uid
               and not exists (
                 select 1 from public.membro_estabelecimento x
                  where x.estabelecimento_id = m.estabelecimento_id
                    and x.usuario_id <> v_uid)))
      or g.id in (
           select c.vaga_id from public.chamada c
            where (c.criada_por = v_uid
                   or c.profissional_id = (select p.id from public.profissional p where p.usuario_id = v_uid))
              and c.estado = 'aberta')
   order by g.id
     for update;

  perform 1 from public.chamada c
   where (c.criada_por = v_uid
          or c.profissional_id = (select p.id from public.profissional p where p.usuario_id = v_uid))
     and c.estado = 'aberta'
   order by c.id
     for update;

  select * into v_usuario
    from public.usuario u
   where u.id = v_uid
     for update;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_usuario.estado = 'anonimizada' then
    perform public.erro(409, 'conta_ja_anonimizada');
  end if;

  if v_usuario.estado = 'suspensa' then
    return jsonb_build_object(
      'usuario_id',         v_uid,
      'estado_anterior',    'suspensa',
      'estado_atual',       'suspensa',
      'ja_estava_suspensa', true,
      'turnos_cancelados',  0
    );
  end if;

  -- 1. Se for profissional: reabre cada turno futuro através de privado.cancelar_uma_posicao
  -- (RN13), sem falta (decisão de 29/09).
  if v_usuario.perfil = 'profissional' then
    perform set_config('frila.exclusao_de_conta', 'on', true);
    for v_pos in
      select p.*
        from public.posicao p
       where p.estado = 'confirmada'
         and p.inicio_em > v_agora
         and p.profissional_id = (select x.id from public.profissional x where x.usuario_id = v_uid)
    loop
      perform privado.cancelar_uma_posicao(v_pos.id, v_uid, 'suspensão de conta', true);
      v_cancelados := v_cancelados + 1;
    end loop;
    perform set_config('frila.exclusao_de_conta', 'off', true);
  end if;

  -- 2. Se for contratante: nas casas onde for o único membro, recolhe as vagas futuras.
  if v_usuario.perfil = 'contratante' then
    perform set_config('frila.autor_da_exclusao', v_operador::text, true);

    select coalesce(array_agg(x.id order by x.id), '{}') into v_vagas
      from (select g.id
              from public.vaga g
             where g.inicio_em > v_agora
               and g.estado in ('publicada', 'preenchida')
               and g.estabelecimento_id in (
                 select m.estabelecimento_id from public.membro_estabelecimento m
                  where m.usuario_id = v_uid
                    and not exists (
                      select 1 from public.membro_estabelecimento x
                       where x.estabelecimento_id = m.estabelecimento_id
                         and x.usuario_id <> v_uid))
             order by g.id
               for update) x;

    for v_pos in
      select p.*
        from public.posicao p
       where p.vaga_id = any (v_vagas)
         and p.estado = 'confirmada'
         and p.inicio_em > v_agora
       order by p.id
    loop
      perform privado.cancelar_uma_posicao(v_pos.id, v_operador, 'suspensão de conta', false);
      v_cancelados := v_cancelados + 1;
    end loop;

    for v_cand in
      select c.id, c.profissional_id, p.vaga_id
        from public.candidatura c
        join public.posicao p on p.id = c.posicao_id
       where p.vaga_id = any (v_vagas)
         and c.estado = 'pendente'
    loop
      update public.candidatura set estado = 'retirada' where id = v_cand.id;
      perform privado.notificar(
        privado.usuario_do_profissional(v_cand.profissional_id),
        'cancelamento',
        v_cand.vaga_id,
        jsonb_build_object('vaga_id', v_cand.vaga_id, 'reaberta', false)
      );
    end loop;

    update public.posicao p
       set estado = 'cancelada'
     where p.vaga_id = any (v_vagas)
       and p.estado = 'aberta';

    update public.vaga g
       set estado = 'cancelada'
     where g.id = any (v_vagas);

    perform set_config('frila.autor_da_exclusao', '', true);
  end if;

  -- Atualiza o estado da conta para suspensa
  update public.usuario
     set estado = 'suspensa'
   where id = v_uid;

  -- Registra ocorrência de suspensão
  insert into public.ocorrencia (
    tipo,
    usuario_id,
    autor_id,
    motivo,
    criada_em,
    resolvido_em,
    resultado
  ) values (
    'suspensao',
    v_uid,
    v_operador,
    v_motivo,
    v_agora,
    v_agora,
    'Conta suspensa pela Equipe Frila via procedimento operacional.'
  ) returning id into v_oc_id;

  -- RN15 / Card BsXIZHOw: notificação sem motivo no push
  perform privado.notificar(
    v_uid,
    'suspensao'::public.tipo_notificacao,
    v_oc_id,
    '{}'::jsonb
  );

  return jsonb_build_object(
    'usuario_id',        v_uid,
    'estado_anterior',   'ativa',
    'estado_atual',      'suspensa',
    'ocorrencia_id',     v_oc_id,
    'turnos_cancelados', v_cancelados,
    'suspenso_em',       v_agora
  );
end $$;
