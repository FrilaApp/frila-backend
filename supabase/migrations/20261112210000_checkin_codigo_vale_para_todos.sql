-- O check-in por código vale para TODOS os estabelecimentos (decisão do Cauê, 12/11/2026: "sem
-- casa âncora e sem piloto"; pedido 2026-11-12-12).
--
-- Até aqui a chave valia por casa: privado.recurso_ligado_para exigia a chave global ligada E a
-- casa em privado.recurso_estabelecimento (20261109101000). Agora vale só a chave global.
--
--   1. privado.recurso_ligado_para devolve só privado.recurso_ligado(p_chave). A assinatura, o
--      security definer, o search_path e o grant ficam; p_estabelecimento fica no parâmetro, sem
--      uso, para não quebrar gerar_codigo_checkin, validar_codigo_checkin e fazer_checkin.
--   2. A chave checkin_por_codigo liga (falha alto se a linha não existir).
--   3. A versão mínima do iOS é 1.2.0 (o app que tem o fluxo do código): configuracao_do_app
--      devolve recursos.checkin_por_codigo = true só dali em diante. Android: nenhuma linha (fora
--      até ordem nova). Quem tem o app 1.0/1.1 recebe false e cai na confirmação manual (aceito).
--   4. privado.recurso_estabelecimento deixa de ser lida e fica, comentada. Apagar é mudança
--      destrutiva e vai em duas fases: uma 2ª fase decide se a tabela sai.
--
-- Como voltar (mudança de dado, sem destrutivo):
--   update privado.recurso set ligado = false where chave = 'checkin_por_codigo';
--   delete from privado.recurso_versao_minima where recurso = 'checkin_por_codigo' and plataforma = 'ios';
-- A volta do desenho por casa (lista em privado.recurso_estabelecimento) é uma migração corretiva
-- que recria o corpo de recurso_ligado_para da 20261109101000.
--
-- Sem mudança de superfície: nenhuma função de public mudou (o corpo de configuracao_do_app já lê a
-- chave por privado.recurso_na_versao, 20261111203000).

select set_config('lock_timeout', '2s', true);

-- ── 1. A chave vale para a casa quando a chave global está ligada ─────────────

create or replace function privado.recurso_ligado_para(p_chave text, p_estabelecimento uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select privado.recurso_ligado(p_chave)
$$;
comment on function privado.recurso_ligado_para(text, uuid) is
  'Se a chave vale para o estabelecimento: desde 20261112210000 vale a chave global ligada em privado.recurso, para todas as casas (decisão do Cauê, 12/11/2026). p_estabelecimento fica na assinatura, sem uso, para não quebrar quem chama; a lista por casa (privado.recurso_estabelecimento) deixou de ser lida (RN46).';

-- ── 2. Liga a chave ───────────────────────────────────────────────────────────

do $$
begin
  update privado.recurso set ligado = true where chave = 'checkin_por_codigo';
  if not found then
    raise exception 'privado.recurso sem a linha checkin_por_codigo (20261109101000 não aplicada?)';
  end if;
end $$;

-- ── 3. Versão mínima do iOS ───────────────────────────────────────────────────

insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
values ('checkin_por_codigo', 'ios', '1.2.0')
on conflict (recurso, plataforma)
  do update set versao_minima = excluded.versao_minima, atualizado_em = privado.agora();

-- ── 4. A lista por casa deixa de valer ────────────────────────────────────────

comment on table privado.recurso_estabelecimento is
  'Não é mais lida desde 20261112210000 (o check-in por código vale para todos, decisão do Cauê, 12/11/2026); fica até uma 2ª fase decidir se sai.';
