-- Religa a foto de perfil para TODOS no iOS 1.2.0, agora que ela tem leitura (B-020, pacote 11).
--
-- A 20261113220000 ligou foto, chamada direta e perfil rico; a 20261113230000 desfez só a foto, porque a
-- foto aprovada nunca aparecia (a leitura dependia do segredo legado do Storage, vetado pelo Lince Codex).
-- A 20261114003000 (#501) trouxe a leitura pela Edge Function ler-midia, e a prova no frila-dev passou
-- (retornos/B-020-dev.md): o dono e a casa com vínculo veem; token alterado e foto removida dão 404.
-- Esta migração é a volta escrita no cabeçalho da 20261113230000:
--   1. foto_de_perfil = true no iOS (privado.configuracao_app; falha alto se a linha faltar);
--   2. versão mínima do iOS em 1.2.0 para a foto (sem linha, o recurso fica desligado na plataforma,
--      20261108150000). Android: nenhuma linha (fora até ordem nova).
--
-- Pré-condições do Prod (roteiro do pacote 11, fora deste arquivo): a 20261114003000 e a ler-midia no ar,
-- "Fotos ou vídeos" declarado no App Privacy (ASC) e a moderação real respondendo.
--
-- Como voltar (mudança de dado, sem destrutivo), numa migração corretiva:
--   update privado.configuracao_app set foto_de_perfil = false where plataforma = 'ios';
--   delete from privado.recurso_versao_minima where recurso = 'foto_de_perfil' and plataforma = 'ios';
--
-- Sem mudança de superfície: nenhuma função de public mudou; configuracao_do_app já lê a chave por
-- privado.recurso_na_versao (20261111203000).

select set_config('lock_timeout', '2s', true);

insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
values ('foto_de_perfil', 'ios', '1.2.0')
on conflict (recurso, plataforma)
  do update set versao_minima = excluded.versao_minima, atualizado_em = privado.agora();

do $$
begin
  update privado.configuracao_app set foto_de_perfil = true where plataforma = 'ios';
  if not found then
    raise exception 'privado.configuracao_app sem a linha ios';
  end if;
end $$;
