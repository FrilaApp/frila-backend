select set_config('lock_timeout', '2s', true);

-- ── Bloqueio tira o profissional da equipe de confiança (D-14, RF26) ────────────
--
-- A recusa em `incluir_na_equipe` (20261114040000) impede a entrada de quem está
-- bloqueado. Faltava o outro lado: quem JÁ está na equipe e passa a ser bloqueado
-- continuava lá, e a casa seguia vendo e chamando alguém que bloqueou (ou que ela
-- bloqueou). Aqui a saída acontece na mesma transação do bloqueio, por gatilho, sem
-- mexer em `bloquear` nem `desbloquear`. O `incluir_na_equipe` só ganha as travas da
-- seção 0, que fecham a corrida com o gatilho.
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
--
-- Corrida (Lince Codex no #506): o DELETE do gatilho não enxerga uma inclusão que ainda
-- não tem commit, e a inclusão conferiu o bloqueio antes de ele existir. Três travas por
-- linha fecham isso:
--   incluir_na_equipe          casa (FOR UPDATE) e depois profissional (FOR UPDATE), na
--                              mesma ordem da chamar_profissional;
--   bloqueio (gatilho)         só o profissional (FOR UPDATE), nunca a casa;
--   membro novo (gatilho)      só a casa (FOR NO KEY UPDATE), nunca o profissional.
-- Quem chega depois espera e, em READ COMMITTED, o comando seguinte já vê o que o outro
-- confirmou: a inclusão recusa com 404 ou o gatilho apaga a linha. Não há ciclo.

-- ── 0. incluir_na_equipe trava casa e profissional antes de conferir o bloqueio ──
-- contrato: corpo-sem-mudanca-de-superficie public.incluir_na_equipe 0.2.83
-- Corpo da 20261114040000 sem mudança de guarda, erro ou resposta; só entram as travas.

create or replace function public.incluir_na_equipe(
  estabelecimento_id uuid,
  profissional_id    uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_prof      public.profissional%rowtype;
  v_user      public.usuario%rowtype;
  v_cumpriu   boolean;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- RN25: apenas contratante
  perform privado.exigir_perfil('contratante');

  -- RN13: conta suspensa não altera equipe
  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  -- RF21: apenas administrador do estabelecimento pode alterar a equipe (operador não mexe na equipe)
  if not privado.eh_administrador(incluir_na_equipe.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- Profissional precisa existir e não estar anonimizado (404)
  select * into v_prof
    from public.profissional p
   where p.id = incluir_na_equipe.profissional_id;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Serializa com o bloqueio (trava o profissional) e com o membro novo (trava a casa), na
  -- ordem da chamar_profissional: casa e depois profissional. As checagens abaixo vêm
  -- depois das travas para enxergar o que o outro lado já confirmou.
  perform 1 from public.estabelecimento e where e.id = incluir_na_equipe.estabelecimento_id for update;
  perform 1 from public.profissional p where p.id = incluir_na_equipe.profissional_id for update;

  select * into v_user
    from public.usuario u
   where u.id = v_prof.usuario_id;

  if v_user.estado = 'anonimizada' then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- RF26 / D-14: bloqueio mútuo nos dois sentidos com o estabelecimento ou separação de demonstração
  if privado.bloqueado_com_estabelecimento(v_user.id, incluir_na_equipe.estabelecimento_id)
     or v_user.demonstracao <> privado.conta_de_demonstracao() then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Critério de aceite: Só quem já cumpriu turno no estabelecimento pode ser incluído (UC11).
  -- Presença verificada (RN22: check-in geolocalizado ou manual confirmado -> t.verificacao = 'verificado')
  select exists (
    select 1
      from public.turno t
      join public.posicao pos on pos.id = t.posicao_id
      join public.vaga v on v.id = pos.vaga_id
     where pos.profissional_id = incluir_na_equipe.profissional_id
       and v.estabelecimento_id = incluir_na_equipe.estabelecimento_id
       and t.verificacao = 'verificado'
  ) into v_cumpriu;

  if not v_cumpriu then
    perform public.erro(403, 'sem_permissao', 'sem_turno_cumprido');
  end if;

  -- Idempotente: insere se não existir
  insert into public.equipe_confianca (estabelecimento_id, profissional_id, adicionado_em)
  values (incluir_na_equipe.estabelecimento_id, incluir_na_equipe.profissional_id, privado.agora())
  on conflict (estabelecimento_id, profissional_id) do nothing;

  return jsonb_build_object(
    'estabelecimento_id', incluir_na_equipe.estabelecimento_id,
    'profissional_id',    incluir_na_equipe.profissional_id
  );
end $$;

comment on function public.incluir_na_equipe(uuid, uuid) is
  'Inclui profissional na equipe de confiança do estabelecimento (RF18, RF26, UC11). Exige turno verificado prévio na casa e ausência de bloqueio mútuo. Idempotente.';

revoke execute on function public.incluir_na_equipe(uuid, uuid) from public, anon;
grant  execute on function public.incluir_na_equipe(uuid, uuid) to authenticated;

-- ── 1. Alguém bloqueia: sai a linha de cada casa em que o par se cruza ──────────

create or replace function privado.tirar_da_equipe_no_bloqueio()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Trava o profissional do par (a mesma linha que o incluir_na_equipe trava): uma inclusão
  -- em curso termina antes e o delete abaixo a vê. Nunca a casa: o bloqueio de um membro
  -- atinge várias casas, e travá-las aqui abriria ordem de deadlock com a inclusão.
  perform 1 from public.profissional p where p.usuario_id in (new.autor_id, new.bloqueado_id) for update;

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
  -- Trava a casa (a mesma linha que o incluir_na_equipe trava com FOR UPDATE, e conflita com
  -- ele). FOR NO KEY UPDATE é o modo que o aceitar_convite_membro já tem nesta linha, e não é
  -- troca de trava sobre o KEY SHARE que o insert pegou pela chave estrangeira: dois membros
  -- entrando juntos na mesma casa só se enfileiram, sem deadlock.
  perform 1 from public.estabelecimento e where e.id = new.estabelecimento_id for no key update;

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
