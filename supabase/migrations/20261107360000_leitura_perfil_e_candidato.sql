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
  v_uid     uuid := (select auth.uid());
  v_res     jsonb;
  v_p       public.profissional%rowtype;
  v_u       public.usuario%rowtype;
  v_tem_f2  boolean;
begin
  select p.* into v_p from public.profissional p where p.id = prof;
  if not found then return null; end if;
  select u.* into v_u from public.usuario u where u.id = v_p.usuario_id;

  v_res := jsonb_build_object(
    'id',   v_p.id,
    'tipo', 'profissional',
    'nome', case when v_u.estado = 'anonimizada' then 'Conta encerrada' else v_u.nome end,
    'funcoes', coalesce((select jsonb_agg(f.nome order by f.nome)
                           from public.profissional_funcao pf
                           join public.funcao f on f.id = pf.funcao_id
                          where pf.profissional_id = v_p.id), '[]'::jsonb),
    'reputacao', jsonb_build_object(
      'positivas',           v_p.aval_positivas,
      'total',               v_p.aval_total,
      'taxa_comparecimento', v_p.taxa_comparecimento,
      'turnos_realizados',   v_p.turnos_realizados,
      'turnos_considerados', v_p.turnos_realizados
                             + (select count(*) from public.posicao x
                                 where x.profissional_id = v_p.id and x.falta))
  );

  -- Se o leitor é contratante com vínculo E o profissional possui dados de F2 cadastrados:
  if v_uid is not null and privado.contratante_com_vinculo_leitura(v_p.id, v_uid) then
    v_tem_f2 := (
      v_p.apresentacao is not null
      or v_p.onde_trabalhei is not null
      or v_p.experiencia_faixa is not null
      or (v_p.cursos is not null and cardinality(v_p.cursos) > 0)
      or (v_p.idiomas is not null and cardinality(v_p.idiomas) > 0)
      or v_p.atende_todo_df
      or exists (select 1 from public.profissional_servico where profissional_id = v_p.id)
      or exists (select 1 from public.profissional_regiao where profissional_id = v_p.id)
    );

    if v_tem_f2 then
      v_res := v_res || jsonb_build_object(
        'apresentacao', v_p.apresentacao,
        'onde_trabalhei', v_p.onde_trabalhei,
        'experiencia_faixa', v_p.experiencia_faixa,
        'cursos', to_jsonb(coalesce(v_p.cursos, '{}'::text[])),
        'idiomas', to_jsonb(coalesce(v_p.idiomas, '{}'::text[])),
        'atende_todo_df', v_p.atende_todo_df,
        'no_frila_desde', to_char(v_u.criado_em, 'YYYY-MM'),
        'regioes', coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
                               from public.profissional_regiao pr
                               join public.regiao_administrativa r on r.id = pr.regiao_id
                              where pr.profissional_id = v_p.id), '[]'::jsonb),
        'servicos', coalesce((select jsonb_agg(jsonb_strip_nulls(to_jsonb(s) - array['profissional_id','funcao_id','extras','atualizado_em']) ||
                             jsonb_build_object('funcao', to_jsonb(f) - 'ativo', 'especialidades', coalesce((select jsonb_agg(to_jsonb(e) order by e.nome)
                               from public.profissional_servico_especialidade se join public.especialidade e on e.id = se.especialidade_id
                               where se.profissional_id = s.profissional_id and se.funcao_id = s.funcao_id), '[]'::jsonb)) order by f.nome)
                             from public.profissional_servico s join public.funcao f on f.id = s.funcao_id
                            where s.profissional_id = v_p.id), '[]'::jsonb)
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
