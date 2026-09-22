-- Semente que **só** roda em ambiente de teste.
--
-- `supabase db reset` a executa no local e na CI, porque ela está em
-- `config.toml → [db.seed].sql_paths`. Nenhum caminho remoto passa por aqui:
-- `supabase db push` não roda semente, e `scripts/aplicar-remoto.sh` executa
-- explicitamente só o `seed.sql`, e depois confere que este marcador ficou ausente.
--
-- É o que torna `privado.agora()` sobreponível aqui e nunca no frila-dev ou no
-- frila-prod. Sem um arquivo separado, o marcador seria uma variável de ambiente que
-- alguém esquece ligada — e um relógio sobreponível em produção é um jeito de burlar
-- todo prazo do produto: os 7 dias do contato (RN10), as 24 horas do modo seleção
-- (RN24), o fim previsto que libera a avaliação (RN07).

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
