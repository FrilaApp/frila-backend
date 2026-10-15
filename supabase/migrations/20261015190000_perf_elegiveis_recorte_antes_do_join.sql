-- privado.elegiveis: recorte do raio GiST antes do join com usuario (RNF11, RNF12).
-- Recomendação 1 do relatório de carga 10x (backend#195).
--
-- O problema: sob volume massivo de profissionais (escala 10x do DF, 1.000.000 de
-- profissionais e 1.300.000 de usuários), a CTE `candidatos` juntava pf, p e u na mesma
-- cláusula FROM. O planejador PostgreSQL considerava que ~62.500 buscas individuais no
-- índice PK (usuario_pkey) seriam mais custosas do que ler a tabela usuario inteira
-- sequencialmente (Seq Scan), degradando a mediana de 13,8 ms para mais de 400 ms.
--
-- A correção: reordena a CTE de candidatos para aplicar o filtro de função e o raio
-- geográfico GiST (ST_DWithin 15 km ou equipe de confiança) antes de consultar
-- public.usuario. Desta forma, a junção com usuario opera sobre o conjunto já reduzido
-- localmente, garantindo o uso de Index Scan na PK de usuario sem varredura sequencial.
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
