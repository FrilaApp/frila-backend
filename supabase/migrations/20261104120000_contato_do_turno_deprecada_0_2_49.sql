-- Contrato 0.2.49 (issue #396, Fase 2): `contato_do_turno` fica deprecada.
--
-- Decisão de produto de 04/11/2026: a troca de contatos entre contratante e contratado
-- não deve ser praticada nem explicitada no app. O contrato 0.2.49 marca a operação como
-- `deprecated` e declara que ela segue respondendo como hoje até o fim do suporte aos apps
-- já publicados (mudança incompatível vira função nova; a antiga fica no ar).
--
-- Esta migração não muda comportamento: nenhuma regra, nenhum retorno, nenhum grant. Só
-- o comentário do catálogo, para que quem lê o banco saiba que a função é legada.
-- `candidatar`, `escolher_candidato` e `meus_turnos` seguem devolvendo `contato` e
-- `contato_visivel_ate`: o contrato os tornou opcionais e nuláveis, e o servidor atual os
-- preencher é um caso válido dele. Parar de entregá-los fica para uma versão própria do
-- contrato, junto com o telefone opcional no cadastro e a migração dos números gravados.

comment on function public.contato_do_turno(uuid) is
  'DEPRECADA na 0.2.49 (decisão de produto de 04/11/2026, issue #396): o app novo não a chama e o contato não é trocado pelo app. Segue respondendo para os apps já publicados. Contato da outra parte do turno (RF11, RN10). Só depois da confirmação e só até 7 dias depois do fim; depois disso, 403 contato_expirado. Antes da confirmação, fora do turno ou com bloqueio entre as partes, 404. Conta inativa ou anonimizada é recusada no início (B10).';
