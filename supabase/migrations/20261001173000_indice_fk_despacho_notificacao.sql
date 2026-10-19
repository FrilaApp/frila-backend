-- 20261001173000_indice_fk_despacho_notificacao.sql
--
-- Índice cobrindo a foreign key despacho_notificacao_id_fkey (cartão kT7NhMGV).
--
-- A tabela public.despacho é a mais volumosa no fluxo operacional do motor de despacho.
-- A coluna notificacao_id referencia public.notificacao(id) e participa diretamente
-- de consultas críticas no caminho quente:
--   - privado.contexto_do_push(notificacao_id): contagem de despachos em push agrupado
--   - privado.notificacao_expirada(notificacao_id): verificação pré-envio FCM
--   - metrica.funil_do_piloto: join entre despacho e notificacao
--   - integridade referencial: evita sequential scan em despacho ao manipular notificacao
--
-- O índice existente despacho_esperando_teto cobre apenas notificacao_id IS NULL.
-- Este índice cobre a chave estrangeira e todas as buscas com notificacao_id definido.

create index if not exists despacho_notificacao
  on public.despacho (notificacao_id);

comment on index public.despacho_notificacao is
  'Cobre a chave estrangeira despacho_notificacao_id_fkey e acelera consultas do caminho quente de push/teto (RNF11).';
