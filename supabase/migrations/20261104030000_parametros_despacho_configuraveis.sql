-- Parâmetros do despacho configuráveis em runtime: o raio da RN05 sai do código.
-- Cartão 2RsO30sX · D02 · RN05, RN23.
--
-- O teto e a urgência da RN23 já moram em `privado.parametro_notificacao` desde o cartão
-- `ee3MT3fH`, e mudam com um `update`. O raio da RN05 era o literal `15000` dentro de
-- `privado.elegiveis`: trocar 15 km por 12 km exigia migração, revisão, merge e deploy,
-- o que é lento demais para um ajuste que a operação do piloto pode pedir numa segunda.
--
-- Esta migração **não muda comportamento nenhum**: o valor inicial é o mesmo 15000 de
-- antes. O que muda é de onde o número vem. A decisão e os gatilhos de ajuste estão em
-- `docs/decisoes/D02-parametros-do-despacho.md`.
--
-- Duas tabelas, e não uma. `parametro_notificacao` guarda `interval`;
-- `parametro_despacho` guarda metro, em `integer`. Uma tabela só obrigaria coluna
-- genérica com unidade declarada ao lado, e aí `30` em metros e `30` em minutos caberiam
-- na mesma linha. O tipo da coluna é a documentação que não envelhece.
--
-- O fallback é assimétrico de propósito, e a assimetria é o ponto desta migração:
--   · Teto ausente faria o despacho notificar **sem limite** — violação silenciosa da
--     RN23. Por isso `privado.parametro_de_notificacao` levanta `parametro_ausente`.
--   · Raio ausente faria `ST_DWithin` comparar com `NULL`, que não seleciona ninguém:
--     vaga sem candidato, em silêncio, que é o modo de falha mais caro do produto. Por
--     isso aqui a leitura devolve `NULL` e quem chama aplica `coalesce(..., 15000)`, o
--     padrão documentado da RN05.

-- ── 1. A configuração ─────────────────────────────────────────────────────────

create table if not exists privado.parametro_despacho (
  chave        text primary key,
  valor_metros integer not null,
  descricao    text not null,
  constraint parametro_despacho_positivo  check (valor_metros > 0),
  -- Teto de 200 km: o produto é do DF, e um raio maior que isso é erro de digitação
  -- (um zero a mais em 15000 vira 150 km) que notificaria o país inteiro.
  constraint parametro_despacho_teto      check (valor_metros <= 200000),
  constraint parametro_despacho_descrito  check (length(btrim(descricao)) > 0)
);

comment on table privado.parametro_despacho is
  'Parâmetros métricos do despacho (RN05). Mudam sem migração: privado.elegiveis lê daqui a cada chamada. A irmã privado.parametro_notificacao guarda os parâmetros de tempo (RN23).';

comment on column privado.parametro_despacho.valor_metros is
  'O valor em metros, inteiro. ST_DWithin sobre geography recebe metro: converter na borda é onde erro de unidade nasce.';

insert into privado.parametro_despacho (chave, valor_metros, descricao) values
  ('raio_maximo_metros', 15000,
   'RN05: distância máxima entre o ponto base do profissional e a vaga para ele entrar no despacho. Equipe de confiança (RF18) dispensa o raio.')
on conflict (chave) do nothing;

revoke all on table privado.parametro_despacho from public, anon, authenticated;

create or replace function privado.parametro_de_despacho_metros(p_chave text)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v integer;
begin
  select p.valor_metros into v
    from privado.parametro_despacho p
   where p.chave = p_chave;
  -- `NULL` quando a chave não existe, e não exceção: quem chama decide o padrão. Para o
  -- raio, `privado.elegiveis` aplica `coalesce(..., 15000)` — ver o cabeçalho.
  return v;
end $$;

comment on function privado.parametro_de_despacho_metros(text) is
  'Lê um parâmetro métrico do despacho (RN05) em metros. Devolve NULL quando a chave não existe: quem chama aplica o padrão da regra, ao contrário de privado.parametro_de_notificacao, em que o parâmetro ausente é erro.';

revoke execute on function privado.parametro_de_despacho_metros(text) from public, anon, authenticated;
grant  execute on function privado.parametro_de_despacho_metros(text) to service_role;

-- ── 2. privado.elegiveis lê o parâmetro ───────────────────────────────────────
--
-- A função é reproduzida inteira a partir de `20260929160100_elegiveis_ordem_de_filtro.sql`
-- (é `create or replace`, não há como alterar só uma linha). Mudam três coisas, e nada
-- mais: a variável `v_raio_m`, a leitura do parâmetro antes do `return query`, e o
-- literal `15000` do `ST_DWithin`, que vira `v_raio_m`. A CTE `as materialized` e a ordem
-- dos filtros 1 a 7 ficam como estão: removê-las reintroduz a regressão de 28/09.

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
  v_raio_m    integer;
begin
  -- RN05 configurável (cartão 2RsO30sX): uma leitura por chamada, antes do
  -- `return query`. Dentro do predicado da CTE isto seria uma chamada de função por
  -- linha, que é exatamente o custo que esta função foi reescrita para tirar
  -- (`privado.bloqueado_com_estabelecimento`, 28/09). O `coalesce` devolve o padrão
  -- documentado da RN05: parâmetro ausente não pode virar despacho sem ninguém.
  v_raio_m := coalesce(privado.parametro_de_despacho_metros('raio_maximo_metros'), 15000);

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
       -- 2. Até o raio da RN05, hoje 15 km (usa índice GiST profissional_ponto), ou
       --    equipe de confiança (RF18), que dispensa o raio
       and (
         extensions.ST_DWithin(p.ponto_base, v.ponto, v_raio_m)
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
  'Consulta os profissionais elegíveis para uma vaga conforme RN05, RF18, RF26, RN21, RN12 e RN06. O raio da RN05 vem de privado.parametro_despacho (chave raio_maximo_metros), lido uma vez por chamada, com 15000 de fallback. Trata a janela de meia-noite, isola contas de demonstração e respeita a rodada de despacho. A CTE materializada fixa a ordem dos filtros: função e raio primeiro, grade e bloqueio depois (RNF11).';

revoke execute on function privado.elegiveis(uuid, uuid) from public, anon, authenticated;
