select set_config('lock_timeout', '2s', true);

-- ── incluir_na_equipe com recusa de profissional bloqueado ou demonstração ──────
-- contrato: corpo-sem-mudanca-de-superficie public.incluir_na_equipe 0.2.83
-- D-14 / RF26: quem está bloqueado (em qualquer sentido) ou do outro lado da demonstração
-- não pode ser incluído na equipe de confiança. Responde 404 nao_encontrado (RF26),
-- sem revelar a existência ou motivo do bloqueio para quem pede.

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
