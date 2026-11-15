select set_config('lock_timeout', '2s', true);

-- ── Bloqueio tira o profissional da equipe de confiança (D-14, RF26) ────────────
--
-- A recusa em `incluir_na_equipe` (20261114040000) impede a entrada de quem está
-- bloqueado. Faltava o outro lado: quem JÁ está na equipe e passa a ser bloqueado
-- continuava lá, e a casa seguia vendo e chamando alguém que bloqueou (ou que ela
-- bloqueou). Aqui a saída acontece na mesma transação do bloqueio, por gatilho, sem
-- mexer em `bloquear`, `desbloquear` nem `incluir_na_equipe`.
--
-- Sem notificação a ninguém: RF26 manda não revelar o bloqueio.
--
-- O par é o mesmo de `privado.bloqueado_com_estabelecimento`: a conta do profissional
-- de um lado e a conta de QUALQUER membro da casa do outro, em qualquer sentido. Um
-- membro que bloqueia um profissional bloqueia pela casa inteira, e por todas as casas
-- de que ele é membro; por isso a linha sai de cada uma delas.
--
-- Desbloquear NÃO devolve o profissional à equipe: a volta é um ato do administrador,
-- por `incluir_na_equipe`.

-- ── 1. Alguém bloqueia: sai a linha de cada casa em que o par se cruza ──────────

create or replace function privado.tirar_da_equipe_no_bloqueio()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.equipe_confianca e
   using public.profissional p
   where p.id = e.profissional_id
     and (
       (p.usuario_id = new.autor_id
        and exists (select 1
                      from public.membro_estabelecimento m
                     where m.estabelecimento_id = e.estabelecimento_id
                       and m.usuario_id = new.bloqueado_id))
       or
       (p.usuario_id = new.bloqueado_id
        and exists (select 1
                      from public.membro_estabelecimento m
                     where m.estabelecimento_id = e.estabelecimento_id
                       and m.usuario_id = new.autor_id))
     );
  return new;
end;
$$;

drop trigger if exists trg_bloqueio_tirar_da_equipe on public.bloqueio;
create trigger trg_bloqueio_tirar_da_equipe
after insert on public.bloqueio
for each row execute function privado.tirar_da_equipe_no_bloqueio();

revoke execute on function privado.tirar_da_equipe_no_bloqueio() from public, anon, authenticated;

comment on function privado.tirar_da_equipe_no_bloqueio() is
  'Gatilho AFTER INSERT em public.bloqueio (D-14, RF26): apaga de public.equipe_confianca toda linha em que a conta do profissional é uma ponta do bloqueio e um membro da casa é a outra, em qualquer sentido, na mesma transação. Não notifica ninguém (RF26) e o desbloqueio não devolve a linha.';

-- ── 2. Membro novo na casa: quem tem bloqueio com ele sai da equipe ─────────────
--
-- "Bloqueado não fica na equipe" vale também para quem entra na casa depois: o membro
-- novo pode ter bloqueado (ou ter sido bloqueado por) um profissional que já estava na
-- equipe dessa casa.

create or replace function privado.tirar_da_equipe_no_membro_novo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.equipe_confianca e
   using public.profissional p
   where e.estabelecimento_id = new.estabelecimento_id
     and p.id = e.profissional_id
     and p.usuario_id <> new.usuario_id
     and exists (select 1
                   from public.bloqueio b
                  where (b.autor_id = new.usuario_id and b.bloqueado_id = p.usuario_id)
                     or (b.autor_id = p.usuario_id and b.bloqueado_id = new.usuario_id));
  return new;
end;
$$;

drop trigger if exists trg_membro_tirar_da_equipe on public.membro_estabelecimento;
create trigger trg_membro_tirar_da_equipe
after insert on public.membro_estabelecimento
for each row execute function privado.tirar_da_equipe_no_membro_novo();

revoke execute on function privado.tirar_da_equipe_no_membro_novo() from public, anon, authenticated;

comment on function privado.tirar_da_equipe_no_membro_novo() is
  'Gatilho AFTER INSERT em public.membro_estabelecimento (D-14, RF26): se a conta do membro novo tem bloqueio, em qualquer sentido, com a conta de um profissional da equipe da casa, a linha sai de public.equipe_confianca. Não notifica ninguém (RF26).';
