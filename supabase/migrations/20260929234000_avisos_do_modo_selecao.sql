-- Os dois avisos do modo seleção (cartão d3A1WjG3, contrato 0.2.24).
--
--   candidatura_recusada  o profissional não foi escolhido e a vaga encheu
--   selecao_encerrada     a vaga de seleção fechou 24 h antes do início (RN24); vai para
--                         cada candidato pendente e para cada membro da casa
--
-- O escolhido recebe o `confirmacao` de sempre, o mesmo do modo urgência (RF10).
--
-- Em arquivo próprio porque o valor novo de um enum só pode ser usado depois do commit
-- da transação que o criou. As funções que o usam vêm na migração seguinte.
--
-- Os textos do push não estão na planilha aprovada do design: até chegarem, o
-- `enviar-push` manda o texto genérico que já usa para tipo sem texto próprio.

alter type public.tipo_notificacao add value if not exists 'candidatura_recusada';
alter type public.tipo_notificacao add value if not exists 'selecao_encerrada';

comment on type public.tipo_notificacao is
  'Os dezoito avisos do produto. `vaga` e `vagas_agrupadas` vão ao profissional e contam no teto da RN23; os demais vão à conta que precisa agir ou saber. `candidatura_recusada` e `selecao_encerrada` são do modo seleção (contrato 0.2.24).';
