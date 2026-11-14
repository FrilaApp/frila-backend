-- A foto de perfil segue DESLIGADA até existir a leitura assinada sem o segredo legado do Storage
-- (decisão do O2, 13/11/2026 22h3x, opção (c) do P6 do B-019; ordem do Cauê 13-13).
--
-- A 20261113220000 ligou foto, chamada direta e perfil rico. O ponta a ponta no frila-dev mostrou que a
-- foto aprovada nunca aparece para outra pessoa: privado.foto_de_perfil_projecao só a devolve se
-- privado.token_de_leitura_storage assinar a URL com 'storage_jwt_secret' do Vault (20261109150000:13-17),
-- e esse segredo não existe no dev nem no Prod. Copiar o segredo legado para o Vault foi vetado pelo
-- Lince Codex (08/11, retornos/gates-ativacao-B-C-lince-fb89.md, item B). A leitura assinada por Edge
-- Function vem num brief próprio, contrato primeiro.
--
-- Esta migração só desfaz a foto: foto_de_perfil = false no ios e sai o mínimo da foto. A chamada
-- direta e o perfil rico continuam ligados no iOS 1.2.0. No Prod, ela vai NA MESMA TRANSAÇÃO que a
-- 220000 (pacote 10b'), então a foto não fica ligada nem por um instante.
--
-- Como voltar (ligar a foto, quando a leitura assinada existir): uma migração nova com
--   update privado.configuracao_app set foto_de_perfil = true where plataforma = 'ios';
--   insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('foto_de_perfil', 'ios', '<build>');
--
-- Sem mudança de superfície.

select set_config('lock_timeout', '2s', true);

do $$
begin
  update privado.configuracao_app set foto_de_perfil = false where plataforma = 'ios';
  if not found then
    raise exception 'privado.configuracao_app sem a linha ios';
  end if;
end $$;

delete from privado.recurso_versao_minima where recurso = 'foto_de_perfil' and plataforma = 'ios';
