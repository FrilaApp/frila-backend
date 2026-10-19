-- Agenda no pg_cron os jobs que só existiam em comentário (achado do ESTADO de 29/09).
--
-- `20260926000000_turnos_nao_verificados_e_reconciliacao.sql` e
-- `20260926040000_fechamento_turno_vaga.sql` deixaram o agendamento "documentado, sem
-- ativação", porque o pg_cron ainda não existia no banco. Ele entrou com o motor de
-- despacho (`20260926010000`), e os jobs posteriores já se agendam na própria migração
-- (lembretes, vaga vazia, teto, atraso). Estes três ficaram para trás: no ar, turno
-- passado não fechava, posição não virava cumprida, a avaliação não abria e a vaga não
-- encerrava.
--
-- Três jobs comentados viram dois agendados:
--
--   fechar_turnos_e_vagas         */5 * * * *   privado.fechar_turnos_e_vagas()
--     Chama `privado.fechar_turnos_passados()` antes de concluir as posições, e essa
--     ordem importa: o no-show sem check-in vira cancelamento com falta antes de a
--     posição confirmada vencida virar cumprida. Um job separado para
--     `fechar_turnos_passados` rodaria a mesma função duas vezes no mesmo minuto,
--     disputando as mesmas linhas, sem acrescentar nada. O comentário antigo sugeria o
--     nome `fechar-turnos-e-vagas`; os outros sete jobs usam sublinhado, e este segue.
--
--   reconciliar_reputacao_diaria  0 6 * * *     privado.reconciliar_comparecimento()
--     06:00 UTC é 03:00 em Brasília: fora da janela de RNF12 (quinta a domingo, 16h às
--     2h), como a retenção (06:30) e a limpeza de dispositivos (06:17). O comentário
--     antigo dizia 04:00 UTC, que é 01:00 em Brasília, dentro da janela.
--
-- Os nomes sugeridos pelos comentários são desagendados se alguém os tiver registrado à
-- mão num ambiente, para não haver dois executores do mesmo fechamento.

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobname)
       from cron.job
      where jobname in ('fechar_turnos_passados', 'fechar-turnos-e-vagas',
                        'fechar_turnos_e_vagas', 'reconciliar_reputacao_diaria');

    perform cron.schedule(
      'fechar_turnos_e_vagas',
      '*/5 * * * *',
      'select privado.fechar_turnos_e_vagas()'
    );

    perform cron.schedule(
      'reconciliar_reputacao_diaria',
      '0 6 * * *',
      'select privado.reconciliar_comparecimento()'
    );
  end if;
end $$;
