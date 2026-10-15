-- 680_elegiveis_recorte_antes_do_join.sql
-- Prova a paridade exaustiva entre privado.elegiveis (versão canônica em produção)
-- e a proposta de reordenação da CTE da Recomendação 1 do relatório de carga 10x (#195).
--
-- Contexto: A Recomendação 1 do relatório de carga #195 propôs isolar o join de
-- profissional_funcao e profissional com o filtro geográfico GiST em uma subquery antes
-- do join com public.usuario. Conforme verificado por EXPLAIN, o PostgreSQL achata a
-- subquery (subquery pull-up), produzindo plano físico idêntico ao canônico.
-- Este teste garante que qualquer tentativa de reordenação sintática da CTE preserva
-- com 100% de paridade exata o conjunto de elegíveis retornado em todas as vagas.

begin;
select plan(10);

-- ── 1. Implementação com a reordenação proposta (Rec. 1 do #195) em schema temporário ──
create or replace function pg_temp.elegiveis_reordenada(
  vaga_id       uuid,
  excluir_conta uuid default null
)
returns table (profissional_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v           public.vaga%rowtype;
  v_demo      boolean;
  v_inicio_sp timestamp;
  v_dow       int;
  v_dow_ontem int;
begin
  select * into v from public.vaga g where g.id = elegiveis_reordenada.vaga_id;
  if not found then
    return;
  end if;

  if v.estado <> 'publicada' then
    return;
  end if;

  select u.demonstracao into v_demo
    from public.usuario u
   where u.id = v.publicado_por;

  v_inicio_sp := (v.inicio_em at time zone 'America/Sao_Paulo');
  v_dow       := extract(dow from v_inicio_sp)::int;
  v_dow_ontem := (v_dow + 6) % 7;

  return query
  with candidatos as materialized (
    select p.id, p.usuario_id
      from (
        select p.id, p.usuario_id
          from public.profissional_funcao pf
          join public.profissional p on p.id = pf.profissional_id
         where pf.funcao_id = v.funcao_id
           and (elegiveis_reordenada.excluir_conta is null or p.usuario_id <> elegiveis_reordenada.excluir_conta)
           and (
             extensions.ST_DWithin(p.ponto_base, v.ponto, 15000)
             or exists (
               select 1 from public.equipe_confianca e
                where e.estabelecimento_id = v.estabelecimento_id
                  and e.profissional_id = p.id
             )
           )
      ) p
      join public.usuario u on u.id = p.usuario_id and u.estado = 'ativa'
     where (v_demo is null or u.demonstracao = v_demo)
  )
  select c.id
    from candidatos c
   where exists (
       select 1 from public.disponibilidade d
        where d.profissional_id = c.id
          and (
            (
              d.dia_semana = v_dow
              and (
                (d.hora_inicio < d.hora_fim
                 and tstzrange(
                       (date_trunc('day', v_inicio_sp) + d.hora_inicio) at time zone 'America/Sao_Paulo',
                       (date_trunc('day', v_inicio_sp) + d.hora_fim) at time zone 'America/Sao_Paulo'
                     ) @> tstzrange(v.inicio_em, v.fim_em))
                or (d.hora_inicio > d.hora_fim
                    and tstzrange(
                          (date_trunc('day', v_inicio_sp) + d.hora_inicio) at time zone 'America/Sao_Paulo',
                          (date_trunc('day', v_inicio_sp) + interval '1 day' + d.hora_fim) at time zone 'America/Sao_Paulo'
                        ) @> tstzrange(v.inicio_em, v.fim_em))
              )
            )
            or (
              d.dia_semana = v_dow_ontem
              and d.hora_inicio > d.hora_fim
              and tstzrange(
                    (date_trunc('day', v_inicio_sp) - interval '1 day' + d.hora_inicio) at time zone 'America/Sao_Paulo',
                    (date_trunc('day', v_inicio_sp) + d.hora_fim) at time zone 'America/Sao_Paulo'
                  ) @> tstzrange(v.inicio_em, v.fim_em)
            )
          )
     )
     and not privado.bloqueado_com_estabelecimento(c.usuario_id, v.estabelecimento_id)
     and not exists (
       select 1 from public.posicao x
        where x.profissional_id = c.id
          and x.estado in ('confirmada', 'cumprida')
          and x.vaga_id <> v.id
          and tstzrange(x.inicio_em, x.fim_em) && tstzrange(v.inicio_em, v.fim_em)
     )
     and not exists (
       select 1 from public.posicao x
        where x.vaga_id = v.id
          and x.profissional_id = c.id
          and (x.falta or x.estado in ('confirmada', 'cumprida'))
     )
     and not exists (
       select 1 from public.despacho x
        where x.vaga_id = v.id and x.profissional_id = c.id
          and x.rodada = v.rodada_despacho
     );
end $$;

-- ── 2. Massa de teste e cenários ───────────────────────────────────────────────────
create temp table ids as select
  'd0000000-0000-4000-8000-000000000001'::uuid as vaga_ref,
  'd0000000-0000-4000-8000-000000000002'::uuid as vaga_demo,
  'e0000000-0000-4000-8000-000000000001'::uuid as ana,
  'e0000000-0000-4000-8000-000000000004'::uuid as diego,
  'e0000000-0000-4000-8000-000000000009'::uuid as iara;

-- Teste 1: mesmo conjunto de elegíveis na vaga de referência padrão
select set_eq(
  'select profissional_id from privado.elegiveis((select vaga_ref from ids))',
  'select profissional_id from pg_temp.elegiveis_reordenada((select vaga_ref from ids))',
  'Fixture vaga_ref: mesmo conjunto exato de elegíveis entre canônica e reordenada'
);

-- Teste 2: conjunto contém Ana (elegível padrão) e Iara (equipe confiança), e exclui Diego (>15km)
select ok(
  (select array_agg(profissional_id order by profissional_id) from privado.elegiveis((select vaga_ref from ids)))
    @> array[(select ana from ids), (select iara from ids)]
  and not (
    (select array_agg(profissional_id order by profissional_id) from privado.elegiveis((select vaga_ref from ids)))
    @> array[(select diego from ids)]
  ),
  'Fixture vaga_ref: critérios positivos e negativos de elegibilidade preservados'
);

-- Teste 3: vaga de demonstração produz o mesmo conjunto
select is(
  (select array_agg(profissional_id order by profissional_id) from privado.elegiveis((select vaga_demo from ids))),
  (select array_agg(profissional_id order by profissional_id) from pg_temp.elegiveis_reordenada((select vaga_demo from ids))),
  'Fixture vaga_demo: mesmo conjunto de demonstração entre canônica e reordenada'
);

-- Teste 4: exclusão explícita de conta (excluir_conta) preservada
select is(
  (select array_agg(profissional_id order by profissional_id)
     from privado.elegiveis((select vaga_ref from ids), (select usuario_id from public.profissional where id = (select ana from ids)))),
  (select array_agg(profissional_id order by profissional_id)
     from pg_temp.elegiveis_reordenada((select vaga_ref from ids), (select usuario_id from public.profissional where id = (select ana from ids)))),
  'Fixture com excluir_conta: mesmo conjunto com exclusão de profissional específico'
);

-- Teste 5: exclusão de Ana de fato remove apenas ela da lista
select is(
  (select count(*)::int
     from privado.elegiveis((select vaga_ref from ids), (select usuario_id from public.profissional where id = (select ana from ids)))),
  (select count(*)::int from privado.elegiveis((select vaga_ref from ids))) - 1,
  'Excluir conta remove exatamente um elegível'
);

-- Teste 6: conferência exaustiva em todas as vagas do banco
select ok(
  not exists (
    select 1
      from public.vaga v
     where (select array_agg(e.profissional_id order by e.profissional_id) from privado.elegiveis(v.id) e)
           is distinct from
           (select array_agg(a.profissional_id order by a.profissional_id) from pg_temp.elegiveis_reordenada(v.id) a)
  ),
  'Conferência exaustiva: 100% das vagas cadastradas devolvem exatamente o mesmo conjunto entre canônica e reordenada'
);

-- Teste 7: vaga inexistente
select is(
  (select count(*)::int from privado.elegiveis('00000000-0000-0000-0000-000000000000'::uuid)),
  0,
  'Vaga inexistente devolve 0 linhas'
);

-- Teste 8: vaga não publicada
select is(
  (select count(*)::int
     from (
       select privado.elegiveis(id)
         from public.vaga
        where estado <> 'publicada'
        limit 1
     ) s),
  0,
  'Vaga não publicada devolve 0 linhas'
);

-- Teste 9: Volatilidade da função preservada (STABLE)
select is(
  (select p.provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'elegiveis'),
  's'::"char",
  'privado.elegiveis permanece STABLE'
);

-- Teste 10: Privilégios restritos a service_role (RN06)
select ok(
  not has_function_privilege('authenticated', 'privado.elegiveis(uuid,uuid)', 'execute')
  and not has_function_privilege('anon', 'privado.elegiveis(uuid,uuid)', 'execute')
  and has_function_privilege('service_role', 'privado.elegiveis(uuid,uuid)', 'execute'),
  'privado.elegiveis mantém privilégios concedidos apenas a service_role'
);

select * from finish();
rollback;
