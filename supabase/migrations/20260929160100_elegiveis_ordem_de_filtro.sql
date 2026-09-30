-- privado.elegiveis: fixa a ordem de avaliação dos filtros (RNF11, RNF03).
-- Cartão zptkprHt. Nenhuma mudança de comportamento: mesmo conjunto de elegíveis.
--
-- O problema. A função escrevia os filtros como `exists` irmãos sobre
-- `public.profissional` e deixava o planejador escolher por onde começar. Com os cenários
-- (12 profissionais) qualquer ordem serve. Com o volume da praça-piloto ele escolhia
-- começar pela grade semanal, que é o filtro menos seletivo.
--
-- Medido em 28/09 sobre a carga de `supabase/tests/carga/gerar_df.sql` (100 mil
-- profissionais, 200 mil janelas de disponibilidade, 20 mil vagas):
--
--   ->  HashAggregate  (actual time=19.799..24.098 rows=14286)
--         ->  Seq Scan on disponibilidade d  (actual time=0.010..24.965 rows=14286)
--               Rows Removed by Filter: 185732
--   ->  Index Scan using profissional_pkey on profissional p  (loops=894)
--         Filter: (NOT privado.bloqueado_com_estabelecimento(...))
--
-- Duas contas ruins de uma vez: 200 mil janelas varridas para chegar a 14.286 candidatos
-- que a função da vaga cortava para 894, e `privado.bloqueado_com_estabelecimento` — que é
-- função, e custa por linha — executada 894 vezes.
--
-- A correção. Uma CTE `as materialized` que parte de `public.profissional_funcao` com o
-- raio de 15 km e a conta ativa, e só então aplica grade, bloqueio, turno sobreposto,
-- presença nesta vaga e rodada de despacho sobre o conjunto pequeno.
--
-- Medido, 36 chamadas sobre 12 vagas do DF:
--
--   antes:   p95 48,0 a 85,8 ms · soma 1.003 a 1.320 ms · Seq Scan em disponibilidade
--   depois:  p95 17,8 ms        · soma 553 ms           · sem Seq Scan
--
-- Por que não um índice. A alternativa medida foi repor
-- `disponibilidade_dia_horario (dia_semana, hora_inicio, hora_fim, profissional_id)`, que
-- o PR #46 criou e depois removeu. Ela tira o Seq Scan mas deixa o custo do bloqueio por
-- linha: p95 57,3 ms — pior que a reescrita, e cobrando escrita a mais em toda gravação de
-- grade. Com a reescrita o índice atrapalha: p95 23,7 ms com ele contra 17,8 ms sem,
-- porque `disponibilidade_busca (profissional_id, dia_semana)` é o acesso certo quando se
-- parte do profissional. Nenhum índice novo entra nesta migração.
--
-- Esta migração parte da versão de `20260929110000_rodada_de_despacho.sql` e preserva os
-- filtros 6 (RN12: quem faltou ou já trabalha nesta vaga) e 7 (um despacho por rodada)
-- exatamente como estão lá. Só a ordem de avaliação muda.

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
  with candidatos as materialized (
    select p.id, p.usuario_id
      from public.profissional_funcao pf
      join public.profissional p on p.id = pf.profissional_id
      join public.usuario u on u.id = p.usuario_id and u.estado = 'ativa'
     -- 1. Função compatível (catálogo fechado) — o filtro mais seletivo da vaga
     where pf.funcao_id = v.funcao_id
       and (v_demo is null or u.demonstracao = v_demo)
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
  'Consulta os profissionais elegíveis para uma vaga conforme RN05, RF18, RF26, RN21, RN12 e RN06. Trata a janela de meia-noite, isola contas de demonstração e respeita a rodada de despacho. A CTE materializada fixa a ordem dos filtros: função e raio primeiro, grade e bloqueio depois (RNF11).';

revoke execute on function privado.elegiveis(uuid, uuid) from public, anon, authenticated;
