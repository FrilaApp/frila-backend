-- 20261107360000_leitura_perfil_e_candidato.sql
--
-- Fatia F2 / B3c: Leitura do perfil e cartão de candidato (DOC3, OpenAPI 0.2.53, RN26, RN27).
--   * public.meu_perfil_detalhado: leitura completa do próprio perfil pelo profissional.
--   * privado.contratante_com_vinculo_leitura: identifica contratante com vínculo legítimo de leitura
--     (equipe de confiança, candidatura em vaga da casa, histórico de turno ou chamada direta).
--   * privado.perfil_publico_profissional: projeção aditiva dos campos F2 (serviços, apresentação,
--     regiões, etc.) quando preenchidos e autorizados por vínculo de leitura.
--   * public.candidatos_da_vaga: entrega projeção completa aos contratantes da casa,
--     com preços/serviços para o cartão de candidato, sem vazar dados privados (telefone, ponto base, nascimento).
--   * public.perfil_publico: entrega projeção enriquecida apenas para contratantes com vínculo legítimo.

-- ── 1. Helper de vínculo de leitura ───────────────────────────────────────────
create or replace function privado.contratante_com_vinculo_leitura(
  p_prof uuid,
  p_uid  uuid
) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from public.membro_estabelecimento me
     where me.usuario_id = p_uid
       and (
         -- 1. Equipe de confiança da casa
         exists (
           select 1 from public.equipe_confianca ec
            where ec.estabelecimento_id = me.estabelecimento_id
              and ec.profissional_id = p_prof
         )
         -- 2. Candidatura em vaga da casa
         or exists (
           select 1 from public.candidatura c
             join public.posicao pos on pos.id = c.posicao_id
             join public.vaga v on v.id = pos.vaga_id
            where v.estabelecimento_id = me.estabelecimento_id
              and c.profissional_id = p_prof
         )
         -- 3. Turno confirmado/realizado com a casa
         or exists (
           select 1 from public.posicao pos
             join public.vaga v on v.id = pos.vaga_id
            where v.estabelecimento_id = me.estabelecimento_id
              and pos.profissional_id = p_prof
         )
         -- 4. Chamada direta entre a casa e o profissional
         or exists (
           select 1 from public.chamada ch
            where ch.estabelecimento_id = me.estabelecimento_id
              and ch.profissional_id = p_prof
         )
       )
  );
$$;

comment on function privado.contratante_com_vinculo_leitura(uuid, uuid) is
  'Verifica se o usuário é contratante com vínculo legítimo de leitura com o profissional: equipe de confiança, candidatura em vaga da casa, turno ou chamada direta (DOC3, OpenAPI 0.2.53).';

revoke all on function privado.contratante_com_vinculo_leitura(uuid, uuid) from public, anon, authenticated;
grant execute on function privado.contratante_com_vinculo_leitura(uuid, uuid) to service_role;

-- ── 2. Perfil público do profissional com projeção F2 sob demanda ─────────────
create or replace function privado.perfil_publico_profissional(prof uuid)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid         uuid := (select auth.uid());
  v_res         jsonb;
  p             public.profissional%rowtype;
  u             public.usuario%rowtype;
  v_tem_f2      boolean;
  v_bloqueado   boolean;
begin
  select * into p from public.profissional where id = prof;
  if not found then return null; end if;
  select * into u from public.usuario where id = p.usuario_id;

  v_res := jsonb_build_object(
    'id',   p.id,
    'tipo', 'profissional',
    'nome', case when u.estado = 'anonimizada' then 'Conta encerrada' else u.nome end,
    'funcoes', coalesce((select jsonb_agg(f.nome order by f.nome)
                           from public.profissional_funcao pf
                           join public.funcao f on f.id = pf.funcao_id
                          where pf.profissional_id = p.id), '[]'::jsonb),
    'reputacao', jsonb_build_object(
      'positivas',           p.aval_positivas,
      'total',               p.aval_total,
      'taxa_comparecimento', p.taxa_comparecimento,
      'turnos_realizados',   p.turnos_realizados,
      'turnos_considerados', p.turnos_realizados
                             + (select count(*) from public.posicao x
                                 where x.profissional_id = p.id and x.falta))
  );

  -- Bloqueio mútuo em qualquer direção com o leitor ou estabelecimentos do leitor:
  if v_uid is not null then
    v_bloqueado := exists (
      select 1 from public.bloqueio b
       where (b.autor_id = v_uid and b.bloqueado_id = p.usuario_id)
          or (b.autor_id = p.usuario_id and b.bloqueado_id = v_uid)
    ) or exists (
      select 1 from public.membro_estabelecimento me
       where me.usuario_id = v_uid
         and privado.bloqueado_com_estabelecimento(p.usuario_id, me.estabelecimento_id)
    );
  else
    v_bloqueado := false;
  end if;

  -- Se o alvo NÃO está anonimizado/encerrado, o leitor está autenticado,
  -- NÃO há bloqueio mútuo, o leitor possui vínculo legítimo e o profissional preencheu dados F2:
  if u.estado <> 'anonimizada'
     and v_uid is not null
     and not v_bloqueado
     and privado.contratante_com_vinculo_leitura(p.id, v_uid) then

    v_tem_f2 := (
      p.apresentacao is not null
      or p.onde_trabalhei is not null
      or p.experiencia_faixa is not null
      or (p.cursos is not null and cardinality(p.cursos) > 0)
      or (p.idiomas is not null and cardinality(p.idiomas) > 0)
      or p.atende_todo_df
      or exists (select 1 from public.profissional_servico where profissional_id = p.id)
      or exists (select 1 from public.profissional_regiao where profissional_id = p.id)
    );

    if v_tem_f2 then
      v_res := v_res || jsonb_build_object(
        'apresentacao', p.apresentacao,
        'onde_trabalhei', p.onde_trabalhei,
        'experiencia_faixa', p.experiencia_faixa,
        'cursos', to_jsonb(coalesce(p.cursos, '{}'::text[])),
        'idiomas', to_jsonb(coalesce(p.idiomas, '{}'::text[])),
        'atende_todo_df', p.atende_todo_df,
        'no_frila_desde', to_char(u.criado_em, 'YYYY-MM'),
        'regioes', coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
                               from public.profissional_regiao pr
                               join public.regiao_administrativa r on r.id = pr.regiao_id
                              where pr.profissional_id = p.id), '[]'::jsonb),
        'servicos', coalesce((select jsonb_agg(jsonb_strip_nulls(to_jsonb(s) - array['profissional_id','funcao_id','extras','atualizado_em']) ||
                             jsonb_build_object('funcao', to_jsonb(f) - 'ativo', 'especialidades', coalesce((select jsonb_agg(to_jsonb(e) order by e.nome)
                               from public.profissional_servico_especialidade se join public.especialidade e on e.id = se.especialidade_id
                               where se.profissional_id = s.profissional_id and se.funcao_id = s.funcao_id), '[]'::jsonb)) order by f.nome)
                             from public.profissional_servico s join public.funcao f on f.id = s.funcao_id
                            where s.profissional_id = p.id), '[]'::jsonb)
      );
    end if;
  end if;

  return v_res;
end $$;

comment on function privado.perfil_publico_profissional(uuid) is
  'Monta o PerfilPublico de profissional: base estrita de reputação (RN08) e, quando há vínculo com o contratante leitor e dados de F2 cadastrados, projeção rica (0.2.53).';

revoke all on function privado.perfil_publico_profissional(uuid) from public, anon, authenticated;
grant execute on function privado.perfil_publico_profissional(uuid) to service_role;

-- ── 3. Atualização de public.perfil_publico ───────────────────────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.perfil_publico 0.2.61
create or replace function public.perfil_publico(id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid       uuid := (select auth.uid());
  v_prof_user uuid;
  v_perfil    jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'anonimizada') then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- 1. Perfil profissional
  v_prof_user := privado.usuario_do_profissional(perfil_publico.id);
  if v_prof_user is not null then
    -- RF26: bloqueio nos dois sentidos entre quem chama e o profissional,
    -- ou entre o profissional e qualquer estabelecimento do qual quem chama é membro.
    if exists (
      select 1 from public.bloqueio b
       where (b.autor_id = v_uid and b.bloqueado_id = v_prof_user)
          or (b.autor_id = v_prof_user and b.bloqueado_id = v_uid)
    ) or exists (
      select 1 from public.membro_estabelecimento m
       where m.usuario_id = v_uid
         and privado.bloqueado_com_estabelecimento(v_prof_user, m.estabelecimento_id)
    ) then
      perform public.erro(404, 'nao_encontrado');
    end if;

    v_perfil := privado.perfil_publico_profissional(perfil_publico.id);

  -- 2. Perfil de estabelecimento
  elsif exists (select 1 from public.estabelecimento e where e.id = perfil_publico.id) then
    -- RF26: bloqueio com qualquer membro do estabelecimento nos dois sentidos.
    if privado.bloqueado_com_estabelecimento(v_uid, perfil_publico.id) then
      perform public.erro(404, 'nao_encontrado');
    end if;

    v_perfil := privado.estabelecimento_publico(perfil_publico.id);
  end if;

  -- 3. Id que não é profissional nem estabelecimento (ou não encontrado)
  if v_perfil is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  return v_perfil;
end $$;

comment on function public.perfil_publico(uuid) is
  'Perfil público de profissional ou estabelecimento por id. Profissional ganha campos ricos da F2 se quem lê tem vínculo legítimo. Devolve 404 para id inexistente e para bloqueio mútuo.';

revoke execute on function public.perfil_publico(uuid) from public, anon;
grant  execute on function public.perfil_publico(uuid) to authenticated;

-- ── 4. candidatos_da_vaga com projeção completa F2 ───────────────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.candidatos_da_vaga 0.2.61
create or replace function public.candidatos_da_vaga(vaga_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid   uuid := (select auth.uid());
  v_estab uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('contratante');

  if candidatos_da_vaga.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  select estabelecimento_id into v_estab
    from public.vaga
   where id = candidatos_da_vaga.vaga_id;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if not privado.eh_membro(v_estab) then
    perform public.erro(403, 'sem_permissao');
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'candidatura_id', c.id,
             'profissional',   privado.perfil_publico_profissional(c.profissional_id),
             'da_equipe',      exists(
                                 select 1
                                   from public.equipe_confianca ec
                                  where ec.estabelecimento_id = v_estab
                                    and ec.profissional_id = c.profissional_id
                               ),
             'criada_em',      c.criada_em)
           order by c.criada_em, c.id)
      from public.candidatura c
      join public.posicao x on x.id = c.posicao_id
     where x.vaga_id = candidatos_da_vaga.vaga_id
       and c.estado = 'pendente'
       and not privado.bloqueado_com_estabelecimento(
             privado.usuario_do_profissional(c.profissional_id),
             v_estab)), '[]'::jsonb);
end $$;

comment on function public.candidatos_da_vaga(uuid) is
  'Modo seleção: lista os candidatos pendentes na ordem de chegada (RN06) com flag da_equipe (0.2.38) e projeção de perfil rico (0.2.53), ocultando profissionais com bloqueio mútuo com o estabelecimento.';

revoke execute on function public.candidatos_da_vaga(uuid) from public, anon;
grant  execute on function public.candidatos_da_vaga(uuid) to authenticated;

-- ── 5. meu_perfil_detalhado ───────────────────────────────────────────────────
create or replace function public.meu_perfil_detalhado()
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_prof public.profissional%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'anonimizada') then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('profissional');

  select * into v_prof from public.profissional p where p.usuario_id = v_uid;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  return privado.perfil_com_servicos(v_prof);
end $$;

comment on function public.meu_perfil_detalhado() is
  '0.2.53. O perfil de meu_perfil_profissional mais apresentação, serviços e regiões. Conta de contratante é 422 perfil_incompativel; profissional sem perfil, 404.';

revoke execute on function public.meu_perfil_detalhado() from public, anon;
grant  execute on function public.meu_perfil_detalhado() to authenticated;
