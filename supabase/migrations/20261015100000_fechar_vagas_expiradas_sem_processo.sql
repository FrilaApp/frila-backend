-- 20261015100000_fechar_vagas_expiradas_sem_processo.sql
--
-- Encerramento de vagas publicadas e cancelamento de posições abertas após fim_em (D654gdGQ).
--
-- Problema: fechar_turnos_e_vagas só encerrava a vaga quando 'not exists' encontrava
-- zero posições abertas ou confirmadas. Contudo, posições não preenchidas permaneciam
-- com estado = 'aberta' para sempre após fim_em, impedindo o encerramento da vaga e
-- mantendo-a com estado = 'publicada' indefinidamente. Isso poluía o índice GiST
-- (vaga_ponto_publicada) e degradava consultas quentes como vagas_abertas.
--
-- Correção:
-- 1. Cancela posições abertas cujo turno já terminou (fim_em <= privado.agora()).
-- 2. Encerra vagas (estado = 'encerrada') cujo turno já terminou e que não possuam
--    posições abertas ou confirmadas ativas.

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

  -- Cancela posições abertas cujo turno terminou sem confirmação.
  -- Sem isto, posições não preenchidas ficavam como 'aberta' indefinidamente,
  -- impedindo o encerramento da vaga e acumulando registros no índice GiST.
  update public.posicao p
     set estado = 'cancelada'
   where p.estado = 'aberta'
     and p.fim_em <= v_agora;

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
  'Job a cada cinco minutos: reutiliza o fechamento de turnos passados, conclui posições confirmadas, cancela posições abertas cujo turno terminou, enfileira avaliacao_disponivel para os dois lados e encerra vagas sem posição aberta ou confirmada.';

revoke execute on function privado.fechar_turnos_e_vagas() from public, anon, authenticated;
grant execute on function privado.fechar_turnos_e_vagas() to service_role;
