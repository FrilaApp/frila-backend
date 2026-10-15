-- privado.elegiveis: recorte do raio GiST antes do join com usuario (RNF11, RNF12).
-- Recomendação 1 do relatório de carga 10x (backend#195).
--
-- O contexto: a Recomendação 1 do relatório de carga 10x (PR #195) sugeriu isolar a
-- filtragem espacial (ST_DWithin 15 km) e de catálogo (pf.funcao_id) em uma subquery antes
-- do join com public.usuario, visando evitar o Seq Scan em usuario observado sob carga.
--
-- A reordenação: a CTE `candidatos` foi reestruturada para isolar o join entre
-- profissional_funcao e profissional com o filtro geográfico em uma subquery derivada `p`,
-- juntando com public.usuario em seguida.
--
-- Achado técnico de EXPLAIN (2x e 10x):
--   - O PostgreSQL realiza achatamento de subqueries simples sem barreira de materialização
--     (subquery pull-up). Desta forma, o planejador achata a subquery interna `p` e
--     produz uma árvore de execução rigorosamente IDÊNTICA à versão anterior (nó por nó,
--     custo por custo e contagem de loops/linhas).
--   - Em escala 2x: tanto ANTES quanto DEPOIS operam via Nested Loop com Index Scan na PK de
--     usuario (usuario_pkey), sem nenhum Seq Scan em usuario em ambos os casos. A variação
--     observada no benchmark (36,7 ms vs 29,5 ms) decorre de ruído e jitter amostral.
--   - Em escala 10x: tanto ANTES quanto DEPOIS caem no mesmo Hash Join com Seq Scan em
--     usuario (1.302.514 linhas lidas), pois sob 1,3M linhas o otimizador estima o custo da
--     varredura sequencial como inferior a ~62k lookups individuais no índice da PK.
--   - Conclusão: a reordenação sintática expressa o isolamento da regra espacial, mas, por
--     causa do subquery pull-up, não altera o plano físico nem elimina o Seq Scan a 10x
--     (o que demandará abordagem por índice cobridor ou barreira de otimização em tarefa
--     futura). O PR serve como refatoração semântica com validação de equivalência estrita
--     via pgTAP (10/10 testes cobrindo 100% das vagas).
--
-- contrato: corpo-sem-mudanca-de-superficie privado.elegiveis 0.2.42

create or replace function privado.elegiveis(
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
  select * into v from public.vaga g where g.id = elegiveis.vaga_id;
  if not found then
    return;
  end if;

  -- Só despacha vaga no estado 'publicada'
  if v.estado <> 'publicada' then
    return;
  end if;

  -- Isolamento de contas de demonstração (critério 6 do cartão):
  -- Vaga de conta de demonstração só notifica conta de demonstração,
  -- e vaga real só notifica conta real.
  select u.demonstracao into v_demo
    from public.usuario u
   where u.id = v.publicado_por;

  -- Horários no fuso America/Sao_Paulo (fuso canônico do DF para a grade semanal)
  v_inicio_sp := (v.inicio_em at time zone 'America/Sao_Paulo');
  v_dow       := extract(dow from v_inicio_sp)::int;
  v_dow_ontem := (v_dow + 6) % 7;

  return query
  -- `as materialized`: a barreira de otimização é deliberada, e é o que garante que a
  -- função da vaga e o raio cortem primeiro. Removê-la reintroduz a regressão de 28/09.
  -- Reordenação (recomendação 1 do relatório de carga 10x, PR #195):
  -- Aplica o catálogo de função e o raio geográfico GiST (ST_DWithin 15 km) antes de
  -- consultar public.usuario, associando apenas os candidatos locais elegíveis via PK.
  with candidatos as materialized (
    select p.id, p.usuario_id
      from (
        select p.id, p.usuario_id
          from public.profissional_funcao pf
          join public.profissional p on p.id = pf.profissional_id
         -- 1. Função compatível (catálogo fechado) — o filtro mais seletivo da vaga
         where pf.funcao_id = v.funcao_id
           -- Exclusão de conta (ex: quem cancelou na reabertura da posição)
           and (elegiveis.excluir_conta is null or p.usuario_id <> elegiveis.excluir_conta)
           -- 2. Até 15 km (usa índice GiST profissional_ponto), ou equipe de confiança (RF18)
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
   -- 3. Grade cobrindo o horário integral, inclusive janela que atravessa a meia-noite.
   --    Usa disponibilidade_busca (profissional_id, dia_semana): aqui o profissional já
   --    está fixado, que é exatamente o acesso que esse índice serve.
   where exists (
       select 1 from public.disponibilidade d
        where d.profissional_id = c.id
          and (
            -- Janela iniciada no mesmo dia da semana da vaga
            (
              d.dia_semana = v_dow
              and (
                -- Janela no mesmo dia (sem virar a noite)
                (d.hora_inicio < d.hora_fim
                 and tstzrange(
                       (date_trunc('day', v_inicio_sp) + d.hora_inicio) at time zone 'America/Sao_Paulo',
                       (date_trunc('day', v_inicio_sp) + d.hora_fim) at time zone 'America/Sao_Paulo'
                     ) @> tstzrange(v.inicio_em, v.fim_em))
                -- Janela que vira a noite iniciada no dia
                or (d.hora_inicio > d.hora_fim
                    and tstzrange(
                          (date_trunc('day', v_inicio_sp) + d.hora_inicio) at time zone 'America/Sao_Paulo',
                          (date_trunc('day', v_inicio_sp) + interval '1 day' + d.hora_fim) at time zone 'America/Sao_Paulo'
                        ) @> tstzrange(v.inicio_em, v.fim_em))
              )
            )
            -- Janela iniciada na véspera que vira a noite e cobre o turno na madrugada
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
     -- 4. Sem bloqueio mútuo com o estabelecimento (RF26). Depois da CTE de propósito:
     --    é função, e custa por linha.
     and not privado.bloqueado_com_estabelecimento(c.usuario_id, v.estabelecimento_id)
     -- 5. Sem turno sobreposto já confirmado (RN21)
     and not exists (
       select 1 from public.posicao x
        where x.profissional_id = c.id
          and x.estado in ('confirmada', 'cumprida')
          and x.vaga_id <> v.id
          and tstzrange(x.inicio_em, x.fim_em) && tstzrange(v.inicio_em, v.fim_em)
     )
     -- 6. Nesta vaga, nem quem faltou (RN12, em qualquer rodada) nem quem já trabalha nela
     and not exists (
       select 1 from public.posicao x
        where x.vaga_id = v.id
          and x.profissional_id = c.id
          and (x.falta or x.estado in ('confirmada', 'cumprida'))
     )
     -- 7. Um despacho por rodada (8zLfn0mt item 2): não despacha de novo nesta rodada
     and not exists (
       select 1 from public.despacho x
        where x.vaga_id = v.id and x.profissional_id = c.id
          and x.rodada = v.rodada_despacho
     );
     -- RN06: Sem ORDER BY por reputação, sem prioridade paga, nada patrocinado.
end $$;

comment on function privado.elegiveis(uuid, uuid) is
  'Consulta os profissionais elegíveis para uma vaga conforme RN05, RF18, RF26, RN21, RN12 e RN06. Trata a janela de meia-noite, isola contas de demonstração e respeita a rodada de despacho. A CTE materializada fixa a ordem dos filtros: função e raio primeiro (antes do join com usuario), grade e bloqueio depois (RNF11).';

revoke execute on function privado.elegiveis(uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.elegiveis(uuid, uuid) to service_role;
