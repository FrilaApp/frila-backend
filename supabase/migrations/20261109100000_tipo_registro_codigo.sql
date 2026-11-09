-- O check-in por código ganha o seu tipo de registro (contrato 0.2.68, TipoRegistro).
-- Desenho: frila-docs, arquitetura/desenho-checkin-por-codigo-v1.2.md; Modelagem no frila-docs #198.
--
-- Esta migração tem só o valor novo, e é de propósito. Valor acrescentado com
-- `alter type ... add value` não pode ser usado na mesma transação em que nasce, e os CHECKs da
-- RN22 que o citam vêm na 20261109100100. Nenhuma função grava `codigo` ainda: o check-in
-- continua nascendo `geolocalizado` ou `manual`, e só a validação do código (PR6 do plano) o usa.

alter type public.tipo_registro add value if not exists 'codigo';

comment on type public.tipo_registro is
  'Como a presença foi provada no check-in (RN22). geolocalizado: a até 200 m, verificado na hora. manual: a casa confirma. codigo (0.2.68): o check-in nasce manual e vira codigo quando o profissional valida o código que a casa mostrou.';
