-- 20260929180000_equipe_de_confianca.sql
--
-- Equipe de confiança do estabelecimento:
--   - public.equipe_de_confianca(estabelecimento_id uuid) -> jsonb (PerfilPublico[])
--   - public.incluir_na_equipe(estabelecimento_id uuid, profissional_id uuid) -> jsonb (MembroDaEquipe)
--   - public.remover_da_equipe(estabelecimento_id uuid, profissional_id uuid) -> jsonb (MembroDaEquipe)
--
-- Requisitos: RF18, RN05, RN16, RN23, UC11, UC02. Cartão: jl6nbekI.
--
-- Decisões de desenho:
--   1. Membros do estabelecimento podem consultar a equipe; incluir ou remover exige
--      ser administrador do estabelecimento (RF21, UC11, contrato meus_estabelecimentos).
--   2. Inclusão exige que o profissional tenha cumprido ao menos um turno com presença
--      verificada (t.verificacao = 'verificado') no estabelecimento. Caso contrário,
--      recusa com 403 sem_permissao (detalhe: 'sem_turno_cumprido').
--   3. Inclusão e remoção são idempotentes e devolvem MembroDaEquipe {estabelecimento_id, profissional_id}.
--   4. Profissional inexistente ou com conta anonimizada resulta em 404 nao_encontrado.
--   5. A tabela public.equipe_confianca já existe com RLS ligado desde a criação do esquema
--      e já é consultada por privado.elegiveis para dispensar o raio de 15 km da RN05.

-- ── 1. equipe_de_confianca ───────────────────────────────────────────────────────

create or replace function public.equipe_de_confianca(estabelecimento_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_res jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- Apenas membro do estabelecimento pode consultar a equipe (RF21, UC11)
  if not privado.eh_membro(equipe_de_confianca.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- Retorna array de PerfilPublico dos profissionais da equipe
  select coalesce(
    jsonb_agg(privado.perfil_publico_profissional(ec.profissional_id) order by ec.adicionado_em desc),
    '[]'::jsonb
  )
    into v_res
    from public.equipe_confianca ec
    join public.profissional p on p.id = ec.profissional_id
    join public.usuario u on u.id = p.usuario_id and u.estado <> 'anonimizada'
   where ec.estabelecimento_id = equipe_de_confianca.estabelecimento_id;

  return v_res;
end $$;

comment on function public.equipe_de_confianca(uuid) is
  'Lista os profissionais da equipe de confiança do estabelecimento (RF18, UC11). Retorna lista de PerfilPublico.';

revoke execute on function public.equipe_de_confianca(uuid) from public, anon;
grant  execute on function public.equipe_de_confianca(uuid) to authenticated;

-- ── 2. incluir_na_equipe ─────────────────────────────────────────────────────────

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
  v_uid      uuid := (select auth.uid());
  v_prof     public.profissional%rowtype;
  v_user     public.usuario%rowtype;
  v_cumpriu  boolean;
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
  'Inclui profissional na equipe de confiança do estabelecimento (RF18, UC11). Exige turno verificado prévio na casa. Idempotente.';

revoke execute on function public.incluir_na_equipe(uuid, uuid) from public, anon;
grant  execute on function public.incluir_na_equipe(uuid, uuid) to authenticated;

-- ── 3. remover_da_equipe ─────────────────────────────────────────────────────────

create or replace function public.remover_da_equipe(
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
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('contratante');

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  -- RF21: apenas administrador do estabelecimento pode alterar a equipe (operador não mexe na equipe)
  if not privado.eh_administrador(remover_da_equipe.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- Idempotente: remove da equipe_confianca sem penalidade (RN16)
  delete from public.equipe_confianca
   where estabelecimento_id = remover_da_equipe.estabelecimento_id
     and profissional_id = remover_da_equipe.profissional_id;

  return jsonb_build_object(
    'estabelecimento_id', remover_da_equipe.estabelecimento_id,
    'profissional_id',    remover_da_equipe.profissional_id
  );
end $$;

comment on function public.remover_da_equipe(uuid, uuid) is
  'Remove profissional da equipe de confiança do estabelecimento (RF18, RN16, UC11). Idempotente e sem penalidade.';

revoke execute on function public.remover_da_equipe(uuid, uuid) from public, anon;
grant  execute on function public.remover_da_equipe(uuid, uuid) to authenticated;
