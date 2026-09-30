-- O `privado` executável só por quem precisa (auditoria de segurança de 30/09).
--
-- A migração 20260922200000 deu `execute on all functions in schema privado` a
-- `authenticated`, e cada função criada depois sem `revoke` explícito nasceu com a
-- concessão padrão do Postgres: `execute` para PUBLIC, `anon` incluído. Medido no banco
-- local em 30/09: 37 funções do `privado` executáveis por `authenticated` e 12 por `anon`.
-- Entre elas:
--
--   privado.contato_do_profissional(posicao)   telefone e WhatsApp de qualquer profissional
--   privado.contato_do_estabelecimento(vaga)   telefone de quem publicou qualquer vaga
--   privado.gravar_funcoes(prof, funcoes)      reescreve as funções de qualquer profissional
--   privado.gravar_disponibilidade(prof, …)    reescreve a grade de qualquer profissional
--   privado.recalcular_comparecimento(prof)    escreve em `profissional`
--
-- Hoje nenhuma é alcançável: o PostgREST e o GraphQL expõem só `public` (conferido pela
-- introspecção do `graphql.resolve` como `authenticated` e `anon`). Mas o que separa isto
-- de um vazamento de telefone e de escrita em perfil alheio é uma caixa marcada no painel
-- ("Exposed schemas"), e a regra do repositório já é: função do `privado` leva `revoke`
-- de public, anon e authenticated.
--
-- Quem precisa de `execute` como `authenticated` são as doze funções que as políticas de
-- RLS chamam, porque a política roda com a identidade de quem lê. As RPCs de `public` são
-- `security definer`: o que elas chamam no `privado` roda como o dono, e dispensa a
-- concessão. Gatilho também dispensa — o `execute` da função de gatilho só é conferido no
-- `create trigger`, não no disparo.

-- 1. Fecha tudo, de todo mundo que não é dono nem serviço.
revoke execute on all functions in schema privado from public, anon, authenticated;

-- 2. Reabre para authenticated só as que as políticas de RLS chamam.
grant execute on function privado.bloqueado_com_estabelecimento(uuid, uuid) to authenticated;
grant execute on function privado.candidatou_na_vaga(uuid)                  to authenticated;
grant execute on function privado.eh_membro(uuid)                           to authenticated;
grant execute on function privado.estabelecimento_da_posicao(uuid)          to authenticated;
grant execute on function privado.estabelecimento_da_vaga(uuid)             to authenticated;
grant execute on function privado.lado_da_posicao(uuid)                     to authenticated;
grant execute on function privado.mesma_populacao(uuid)                     to authenticated;
grant execute on function privado.meu_profissional_id()                     to authenticated;
grant execute on function privado.ocupa_posicao_na_vaga(uuid)               to authenticated;
grant execute on function privado.perfil_da_conta()                         to authenticated;
grant execute on function privado.usuario_do_profissional(uuid)             to authenticated;
grant execute on function privado.vaga_oculta(uuid)                         to authenticated;

-- 3. O serviço continua executando tudo, como antes: as que tinham a concessão padrão
-- chegavam a `service_role` por PUBLIC, e o `revoke` acima tirou esse caminho.
grant execute on all functions in schema privado to service_role;

-- 4. A função que nascer amanhã sem `revoke` nasce fechada. O privilégio padrão vale
-- para o que `postgres` criar no schema, que é quem aplica as migrações.
alter default privileges for role postgres in schema privado
  revoke execute on functions from public;
