-- O aviso de check-out pendente (fim_sem_checkout) vale até 60 min depois do fim previsto, e não
-- mais 6 h: a mesma janela que o servidor aceita para o check-out (B-019, F-032; pedido 2026-11-13-12).
--
-- O aviso diz "Registre o check-out". privado.exigir_janela_checkout (20261111180000) recusa com
-- 422 fora_da_janela qualquer check-out depois de fim_em + 60 min. Com a janela do aviso em 6 h
-- (20260929234718; o vencimento do D-20, 20261113100000, lê o mesmo parâmetro), um reenvio por
-- backoff ou um agendador que volta de uma parada entregava, entre fim + 60 min e fim + 6 h, um
-- pedido de check-out que o servidor recusa. Agora o aviso nem é criado
-- (privado.alertar_fim_sem_checkout) nem sai (privado.notificacao_expirada_pelo_relogio) depois de
-- fim + 60 min. Nenhuma função muda: as duas leem privado.parametro_de_notificacao.
--
-- Como voltar (mudança de dado): update privado.parametro_notificacao set valor = interval '6 hours'
--   where chave = 'fim_sem_checkout_janela';
--
-- Sem mudança de superfície.

select set_config('lock_timeout', '2s', true);

do $$
begin
  update privado.parametro_notificacao
     set valor = interval '60 minutes',
         finalidade = 'RN11: até quando depois do fim previsto o aviso de check-out pendente ainda vale (é criado e sai). '
                   || 'Igual à janela do check-out em privado.exigir_janela_checkout (fim + 60 min), para o aviso não pedir '
                   || 'um check-out que o servidor recusa (B-019, 13/11/2026). Impede também avisos sobre turnos antigos.'
   where chave = 'fim_sem_checkout_janela';
  if not found then
    raise exception 'privado.parametro_notificacao sem a linha fim_sem_checkout_janela (20260929234718 não aplicada?)';
  end if;
end $$;
