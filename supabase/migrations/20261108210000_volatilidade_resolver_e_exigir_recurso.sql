-- Volatilidade de privado.resolver_conta_demonstracao e privado.exigir_recurso (B-VOLATIL).
--
-- As duas nasceram STABLE (20261108085500, #443; 20261108086000, #444) e só levantam exceção
-- pelo public.erro, que é VOLATILE. Na imagem da CI (postgres 17.11.0.004), o plpgsql_check
-- acusa "routine is marked as STABLE, but expression is VOLATILE" nas duas. Decisão da Central
-- em 08/11/2026 (opção B): as migrações dos dois PRs ficaram intactas (os shas do manifesto da
-- janela de 09/11), os achados entraram em scripts/lint-conhecido.sh, e a correção vem aqui,
-- depois da janela, tirando as duas linhas da lista no mesmo PR.
--
-- Só a volatilidade muda: nenhum corpo, assinatura, grant ou comentário. Quem chama as duas
-- (as quatro RPCs do perfil rico, renovar_dados_demonstracao e semear_vagas_demonstracao) já é
-- VOLATILE, então nenhuma chamadora passa a chamar função mais volátil que ela.

select set_config('lock_timeout', '2s', true);

alter function privado.resolver_conta_demonstracao(uuid, text) volatile;
alter function privado.exigir_recurso(text) volatile;
