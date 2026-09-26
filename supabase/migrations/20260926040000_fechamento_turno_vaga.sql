-- S2 · Backend · Fechamento do turno e da vaga
--
-- O agendador chama `privado.fechar_turnos_e_vagas()` a cada cinco minutos.
-- A chamada abaixo é a configuração de produção, documentada aqui sem ser aplicada
-- pela migração:
--
-- select cron.schedule('fechar-turnos-e-vagas', '*/5 * * * *',
--                      $$select privado.fechar_turnos_e_vagas();$$);

create or replace function privado.fechar_turnos_e_vagas()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora    timestamptz := privado.agora();
  v_fechados integer := 0;
  v_posicoes integer := 0;
  v_turno    record;
begin
  -- Reutiliza o fechamento de turnos manuais e a atualização dos contadores.
  v_fechados := privado.fechar_turnos_passados();

  -- A posição cumprida é o registro do turno encerrado; a verificação é atributo
  -- do turno e não impede o fechamento da posição.
  update public.posicao p
     set estado = 'cumprida'
   where p.estado = 'confirmada'
     and p.fim_em <= v_agora;
  get diagnostics v_posicoes = row_count;
  v_fechados := v_fechados + v_posicoes;

  -- Só a presença verificada abre avaliação. A chave (tipo, referência, conta)
  -- dentro de privado.notificar torna a execução idempotente.
  for v_turno in
    select t.id as turno_id,
           p.profissional_id,
           v.estabelecimento_id
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga v on v.id = p.vaga_id
     where p.estado = 'cumprida'
       and p.fim_em <= v_agora
       and t.verificacao = 'verificado'
  loop
    perform privado.notificar(
      privado.usuario_do_profissional(v_turno.profissional_id),
      'avaliacao_disponivel',
      v_turno.turno_id,
      jsonb_build_object('turno_id', v_turno.turno_id));

    perform privado.notificar_membros(
      v_turno.estabelecimento_id,
      'avaliacao_disponivel',
      v_turno.turno_id,
      jsonb_build_object('turno_id', v_turno.turno_id));
  end loop;

  -- Uma vaga só deixa de aparecer como publicada/preenchida quando não há
  -- posição aberta ou confirmada para ela.
  update public.vaga v
     set estado = 'encerrada'
   where v.estado in ('publicada', 'preenchida')
     and v.fim_em <= v_agora
     and not exists (
       select 1
         from public.posicao p
        where p.vaga_id = v.id
          and p.estado in ('aberta', 'confirmada'));

  return v_fechados;
end $$;

comment on function privado.fechar_turnos_e_vagas() is
  'Job a cada cinco minutos: reutiliza o fechamento de turnos passados, conclui posições, enfileira avaliacao_disponivel para os dois lados e encerra vagas sem posição aberta ou confirmada.';

revoke execute on function privado.fechar_turnos_e_vagas() from public, anon, authenticated;
grant execute on function privado.fechar_turnos_e_vagas() to service_role;

create or replace function privado.fechar_turnos()
returns integer
language sql
security definer
set search_path = ''
as $$
  select privado.fechar_turnos_e_vagas();
$$;

revoke execute on function privado.fechar_turnos() from public, anon, authenticated;
grant execute on function privado.fechar_turnos() to service_role;
