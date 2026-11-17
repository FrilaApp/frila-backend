-- expirar_chamadas pega a vaga antes da chamada, como o resto (B-065, issue #562).
--
-- A regra única de travas da chamada direta é vaga -> chamada -> usuario (20261117010000,
-- 20261117140000). O job (pg_cron, a cada minuto) era a exceção que a 20261117130000 deixou como
-- resíduo: pegava as chamadas vencidas (FOR UPDATE of c) e só depois a vaga, para encerrar a vaga
-- direta que ficou sem chamada aberta. Quem já tinha a vaga e queria a mesma chamada fechava o
-- ciclo. Medido com a ordem forçada por uma terceira conexão (scripts/corrida-chamada.sh, cenários
-- 14 a 18; números no PR): o aceite que fez a conferência do prazo antes de a chamada vencer, o
-- cancelamento da vaga direta (o gatilho vaga_cancelada_fecha_chamadas quer a chamada ainda no
-- prazo), a exclusão e a suspensão da conta.
--
-- Conserto: o job trava primeiro, num comando só e em ordem de id, as vagas das chamadas vencidas
-- (FOR NO KEY UPDATE, o modo que o update de estado da vaga já pegava: não há troca de modo no
-- meio), e só depois as chamadas vencidas dessas vagas, também em ordem de id. A chamada é relida
-- sob a trava (o FOR UPDATE reconfere "aberta e expira_em <= agora" na versão mais nova):
--   - Quem chegou antes na vaga termina primeiro e vence; o job pula a chamada que não está mais
--     aberta (aceita, cancelada, encerrada) e expira só a que continua aberta e vencida.
--   - A chamada que venceu entre os dois comandos e cuja vaga não foi travada fica para o minuto
--     seguinte (a lista das chamadas é limitada às vagas travadas): nenhuma expiração se perde.
--   - A vaga direta só é encerrada pela conferência da 20261117130000 (B-053), igual: sem chamada
--     aberta nem turno, e de novo sem chamada aberta depois da trava. A trava dela agora já é do
--     job desde o começo (o mesmo modo), então o bloco só reconfirma.
-- skip locked foi descartado: pularia a vaga ocupada e adiaria a expiração sem garantia de que o
-- próximo minuto a encontre livre; a espera em ordem não perde nada e não fecha ciclo.
--
-- Com isto a regra vaga -> chamada -> usuario vale para o job sem resíduo: vagas, depois chamadas,
-- depois o usuario (FOR KEY SHARE, a chave estrangeira do aviso). Ninguém mais pega a chamada e
-- depois a vaga (git grep nas migrações: a recusa, cancelar_chamada e o lembrete pegam só a
-- chamada e não pedem a vaga depois).
--
-- Custo: o job passa a esperar trava de vaga que antes não pegava. Antes ele só pedia a vaga da
-- direta que ia encerrar, e só no fim; agora pede, logo no começo, a vaga de toda chamada aberta e
-- vencida (só essas vagas: nenhuma outra). Espera quem segura uma delas (um aceite, um
-- cancelamento, uma chamada nova, uma exclusão), e quem chega depois espera o job, como já
-- esperava no update de estado. São transações curtas; o job roda a cada minuto.
--
-- Corpo copiado de 20261117130000 (a vigente: develop e PRs abertos, conferido com git grep e
-- gh pr diff), com as duas travas em ordem no começo e o FOR UPDATE das chamadas em ordem de id
-- (era por expira_em). Assinatura e grants iguais. A função é do esquema privado e não está no
-- contrato.

select set_config('lock_timeout', '2s', true);

create or replace function privado.expirar_chamadas()
returns int
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_count   int := 0;
  v_vagas   uuid[];
  r         record;
  v_membro  uuid;
begin
  -- B-065 (#562): a vaga antes da chamada, como o aceite, o cancelamento, a exclusão e a
  -- suspensão. Por id, num comando só, para dois jobs (ou o job e a exclusão de uma conta com
  -- várias vagas) não se cruzarem entre vagas.
  select array_agg(x.id) into v_vagas
    from (select g.id
            from public.vaga g
           where g.id in (select c.vaga_id from public.chamada c
                           where c.estado = 'aberta'
                             and c.expira_em <= v_agora)
           order by g.id
             for no key update) x;

  if v_vagas is null then
    return 0;
  end if;

  for r in
    select c.id, c.vaga_id, c.estabelecimento_id, p.usuario_id as prof_usuario_id
      from public.chamada c
      join public.profissional p on p.id = c.profissional_id
     where c.estado = 'aberta'
       and c.expira_em <= v_agora
       and c.vaga_id = any (v_vagas)
     order by c.id
     for update of c
  loop
    update public.chamada
       set estado = 'expirada',
           respondida_em = v_agora
     where id = r.id;

    -- Notifica o profissional
    insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
    values (r.prof_usuario_id, 'chamada_expirada', r.id, jsonb_build_object('chamada_id', r.id, 'vaga_id', r.vaga_id))
    on conflict do nothing;

    -- Notifica os membros do estabelecimento
    for v_membro in
      select me.usuario_id from public.membro_estabelecimento me where me.estabelecimento_id = r.estabelecimento_id
    loop
      insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
      values (v_membro, 'chamada_expirada', r.id, jsonb_build_object('chamada_id', r.id, 'vaga_id', r.vaga_id))
      on conflict do nothing;
    end loop;

    -- Encerra vaga direta se não houver mais chamadas abertas nem turnos
    if not exists (select 1 from public.chamada x where x.vaga_id = r.vaga_id and x.estado = 'aberta')
       and not exists (select 1 from public.turno t join public.posicao pos on pos.id = t.posicao_id where pos.vaga_id = r.vaga_id) then
      -- B-053 (#550): a vaga é travada e as chamadas abertas são conferidas de novo, já depois da
      -- trava. Um chamar_profissional (com vaga_id) que a segurava terminou antes: a chamada dele
      -- aparece aqui, e a vaga fica publicada. O modo é o do update abaixo. Desde a B-065 a vaga já
      -- é do job (a trava do começo, no mesmo modo): este comando só reconfirma.
      perform 1 from public.vaga g
        where g.id = r.vaga_id and g.estado = 'publicada' and g.origem = 'chamada_direta'
          for no key update;
      if found and not exists (select 1 from public.chamada x where x.vaga_id = r.vaga_id and x.estado = 'aberta') then
        update public.vaga set estado = 'encerrada' where id = r.vaga_id and estado = 'publicada' and origem = 'chamada_direta';
      end if;
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end $$;

comment on function privado.expirar_chamadas() is
  'Expira chamadas cujo prazo venceu (expira_em <= now()), emitindo notificações chamada_expirada (RN31, RN33, B5c). A vaga direta sem chamada aberta nem turno é encerrada. Trava as vagas das chamadas vencidas antes delas, em ordem de id (vaga -> chamada -> usuario, como o aceite, o cancelamento, a exclusão e a suspensão), e a conferência das chamadas abertas roda com a vaga travada, para não encerrar a vaga que acabou de receber mais uma chamada (B-053, B-065).';
revoke all on function privado.expirar_chamadas() from public, anon, authenticated;
grant execute on function privado.expirar_chamadas() to service_role;
