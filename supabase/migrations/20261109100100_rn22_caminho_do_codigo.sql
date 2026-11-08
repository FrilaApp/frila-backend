-- A RN22 ganha o terceiro caminho: o código da casa validado (contrato 0.2.68).
-- Desenho: frila-docs, arquitetura/desenho-checkin-por-codigo-v1.2.md, seção 8; a Modelagem
-- muda antes, no frila-docs #198, e o texto da RN22 no Documento de Requisitos é da Bússola.
--
-- Até aqui, `verificado` só valia com o geolocalizado a até 200 m ou com o manual confirmado
-- pela casa, e `checkin_confirmado_em` só existia no manual. Com o código, o check-in nasce
-- `manual` e `pendente`, e a validação o leva a `codigo`, com `checkin_confirmado_em` igual à
-- hora da validação. Os dois caminhos de antes não mudam.
--
-- Três restrições:
--   confirmacao_no_manual_ou_codigo  substitui confirmacao_so_no_manual (o nome antigo mentiria);
--   codigo_sempre_confirmado         nova: tipo codigo sem a hora da validação não existe;
--   verificacao_coerente             aceita codigo com checkin_confirmado_em preenchido.
--
-- Cada troca é um `alter table` só, com o drop e o add juntos: a tabela nunca fica sem a regra,
-- e o bloqueio da linha é tomado uma vez. As restrições valem para as linhas que já existem,
-- que não têm `codigo` e continuam válidas.

select set_config('lock_timeout', '2s', true);

alter table public.turno
  drop constraint confirmacao_so_no_manual,
  add constraint confirmacao_no_manual_ou_codigo check (
    checkin_confirmado_em is null or checkin_tipo in ('manual', 'codigo')),
  add constraint codigo_sempre_confirmado check (
    checkin_tipo is distinct from 'codigo' or checkin_confirmado_em is not null),
  drop constraint verificacao_coerente,
  -- 'verificado' só com prova, e nunca sem marcar quando a prova existe.
  add constraint verificacao_coerente check (
    (verificacao = 'verificado') = coalesce(
      checkin_tipo = 'geolocalizado'
        or (checkin_tipo in ('manual', 'codigo') and checkin_confirmado_em is not null), false));

comment on constraint confirmacao_no_manual_ou_codigo on public.turno is
  'RN22: a hora de confirmação só existe no manual (a casa confirmou) e no código (a hora da validação, 0.2.68). O geolocalizado nasce verificado e não tem o que confirmar.';
comment on constraint codigo_sempre_confirmado on public.turno is
  'RN22 (0.2.68): o check-in nasce manual e só vira codigo na validação, que grava checkin_confirmado_em. Tipo codigo sem essa hora não existe.';
comment on constraint verificacao_coerente on public.turno is
  'RN22: verificado só com prova (geolocalizado a até 200 m, manual confirmado pela casa ou código validado, 0.2.68) e nunca sem marcar quando a prova existe.';
comment on column public.turno.checkin_confirmado_em is
  'No manual, quando um membro da casa confirmou a chegada (RF20). No codigo (0.2.68), a hora da validação do código, pelo relógio do servidor. Nulo no geolocalizado e no manual ainda sem confirmação.';
