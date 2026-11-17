-- Liga a foto de perfil, a chamada direta e o perfil rico para TODOS no iOS 1.2.0 (ordem do Cauê,
-- 13/11/2026 20:19, pedido 2026-11-13-13: "as duas funções no ar para TODOS, sem piloto"; o AGORA.md
-- põe o perfil rico junto da contratação direta, na 1.2). B-019, pacote 10.
--
--   1. Versão mínima do iOS em 1.2.0 para os três (o app que tem as telas: frila-frontend main,
--      MARKETING_VERSION 1.2.0). Sem linha, o recurso fica desligado na plataforma (20261108150000).
--      Android: nenhuma linha (fora até ordem nova). Quem tem o 1.0/1.1 recebe false e não vê nada.
--   2. foto_de_perfil = true no iOS (a chave da foto mora em privado.configuracao_app).
--   3. chamada_direta e perfil_rico ligados em privado.recurso (falha alto se a linha faltar).
--
-- Pré-condições (roteiro do pacote 10, fora deste arquivo): Política publicada, App Privacy no ASC,
-- os segredos da moderação (Azure, France Central) no frila-prod e a análise de imagem respondendo.
--
-- Como voltar (mudança de dado, sem destrutivo), numa migração corretiva:
--   update privado.recurso set ligado = false where chave in ('chamada_direta', 'perfil_rico');
--   update privado.configuracao_app set foto_de_perfil = false where plataforma = 'ios';
--   delete from privado.recurso_versao_minima
--    where plataforma = 'ios' and recurso in ('foto_de_perfil', 'chamada_direta', 'perfil_rico');
--
-- Sem mudança de superfície: nenhuma função de public mudou; configuracao_do_app já lê as chaves
-- por privado.recurso_na_versao (20261111203000).

select set_config('lock_timeout', '2s', true);

-- ── 1. Versão mínima do iOS ───────────────────────────────────────────────────

insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
values ('foto_de_perfil', 'ios', '1.2.0'),
       ('chamada_direta', 'ios', '1.2.0'),
       ('perfil_rico',    'ios', '1.2.0')
on conflict (recurso, plataforma)
  do update set versao_minima = excluded.versao_minima, atualizado_em = privado.agora();

-- ── 2. e 3. As chaves ─────────────────────────────────────────────────────────

do $$
declare n int;
begin
  update privado.configuracao_app set foto_de_perfil = true where plataforma = 'ios';
  if not found then
    raise exception 'privado.configuracao_app sem a linha ios';
  end if;

  update privado.recurso set ligado = true where chave in ('chamada_direta', 'perfil_rico');
  get diagnostics n = row_count;
  if n <> 2 then
    raise exception 'privado.recurso: esperava as linhas chamada_direta e perfil_rico, achei %', n;
  end if;
end $$;
