-- expirar_chamadas trava a vaga direta e confere as chamadas abertas de novo antes de encerrá-la
-- (B-053, issue #550).
--
-- O job (pg_cron, a cada minuto) expira a chamada vencida e, se a vaga direta ficou sem chamada
-- aberta e sem turno, encerra a vaga. Numa sessão só isso sempre esteve certo: com a 2ª chamada no
-- prazo, a vaga segue publicada (supabase/tests/884, partes 1 a 3). O defeito é de disputa: a
-- conferência "sem chamada aberta" era feita sem trava. Um chamar_profissional com vaga_id que
-- ainda não tinha feito commit segura a vaga FOR UPDATE (20261117080000) e já inseriu a chamada
-- nova; o job não a enxergava, esperava a vaga no update e, solta a trava, reavaliava só o
-- "estado = publicada" e encerrava a vaga: chamada ABERTA numa vaga ENCERRADA. O gatilho
-- vaga_cancelada_fecha_chamadas (20261117050000) só vale para a ida a cancelada, então a chamada
-- ficava aberta numa vaga encerrada até vencer. Medido: scripts/corrida-chamada.sh, cenário 8,
-- 4 de 4 rodadas da ordem forçada antes desta migração.
--
-- Conserto: antes do update, a vaga é travada (FOR NO KEY UPDATE) e as chamadas abertas dela são
-- conferidas de novo, em outro comando, que já enxerga o que entrou enquanto o job esperava.
--   - A chamada nova chegou antes: o job espera a vaga, enxerga a chamada e deixa a vaga publicada.
--   - O job chegou antes: o chamar espera a vaga, relê a versão encerrada e recebe 409
--     vaga_encerrada (a conferência depois da trava, da 20261117080000).
--   - Um aceite que terminou enquanto o job esperava deixa a vaga preenchida: a trava relê a
--     linha, o "estado = publicada" não vale mais, e nada é encerrado.
--
-- Travas: nenhuma nova. O job continua pegando a chamada e depois a vaga, e a vaga só quando ia
-- encerrá-la (a conferência sem trava continua na frente). FOR NO KEY UPDATE é o modo que o update
-- de estado já pegava, no mesmo ponto; só passa a ser pego um comando antes. Por isso os ciclos
-- possíveis são os de antes (o resíduo descrito na 20261117010000: o job pega a chamada antes da
-- vaga), nem mais nem menos. Basta esse modo: quem insere chamada numa vaga que existe é só
-- chamar_profissional, que a segura FOR UPDATE do insert ao commit.
--
-- Corpo copiado de 20261107370000 (a vigente: develop e PRs abertos, conferido com git grep e
-- gh pr diff), com só o bloco "B-053" a mais e o comment on function. Assinatura e grants iguais.
-- A função é do esquema privado e não está no contrato.

select set_config('lock_timeout', '2s', true);

create or replace function privado.expirar_chamadas()
returns int
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_count   int := 0;
  r         record;
  v_membro  uuid;
begin
  for r in
    select c.id, c.vaga_id, c.estabelecimento_id, p.usuario_id as prof_usuario_id
      from public.chamada c
      join public.profissional p on p.id = c.profissional_id
     where c.estado = 'aberta'
       and c.expira_em <= v_agora
     order by c.expira_em
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
      -- aparece aqui, e a vaga fica publicada. O modo é o do update abaixo.
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
  'Expira chamadas cujo prazo venceu (expira_em <= now()), emitindo notificações chamada_expirada (RN31, RN33, B5c). A vaga direta sem chamada aberta nem turno é encerrada; antes disso é travada e as chamadas abertas são conferidas de novo, para não encerrar a vaga que acabou de receber mais uma chamada (B-053).';
revoke all on function privado.expirar_chamadas() from public, anon, authenticated;
grant execute on function privado.expirar_chamadas() to service_role;
