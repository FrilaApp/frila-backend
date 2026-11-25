-- scripts/medir-painel-volume.sql
-- Mede public.painel_estabelecimento em várias casas ao mesmo tempo (cartão 1zojatYG).
-- Não roda sozinho: o scripts/medir-painel-volume.sh o injeta DEPOIS de
-- supabase/tests/carga/gerar_casa_pesada.sql e dentro da mesma transação (que termina em
-- rollback).
--
-- Entradas (psql \set, definidas pelo .sh):
--   casas         quantas casas o gerador criou (a principal e as extras)
--   vagas         vagas de cada casa
--   posicoes      posições de cada vaga
--   candidatos    candidaturas de cada posição
--   janelas       janelas de/ate, em dias, separadas por vírgula (ex.: 7,31); começam no
--                 primeiro dia do histórico
--   amostras      chamadas medidas por casa e por janela
--   aquecimento   rodadas descartadas antes das medidas
--
-- Cada casa é lida pelo seu próprio dono (membro só dela), como `authenticated`, então a RLS
-- e privado.eh_membro valem como no produto. As rodadas intercalam janelas e casas, para que
-- uma deriva do ambiente (autovacuum, cache) não caia toda sobre uma janela.
--
-- Saída que o .sh lê (marcadores no começo da linha; tudo sai por NOTICE, no mesmo fluxo):
--   PARAMETROS ...        o que foi pedido; o .sh confere o resto contra isto
--   CONFIG ...            configuração do planejador em uso (enable_seqscan etc.)
--   VOLUME_CASA ...       totais de cada casa, contados como superusuário
--   VOLUME_JANELA ...     linhas dentro de cada janela, por casa, contadas como superusuário
--   BLOCO ...             o que a resposta do painel continha na primeira rodada medida
--   AMOSTRA ...           uma chamada medida: tempo de parede em ms
--   PG_PERCENTIL ...      p50 e p95 de todas as amostras da janela, por percentile_cont
--   ### EXPLAIN_*         explain (analyze, buffers) da chamada da casa 1, por janela
--   ### AUTO_EXPLAIN_*    consultas internas da casa 1, por janela, via auto_explain

select estab as ctx_estab, dono as ctx_dono, inicio as ctx_inicio from cp_ctx
\gset

-- psql não interpola :variável dentro de $$...$$; os parâmetros entram nos blocos por GUC.
select set_config('frila.mv.casas',      :'casas',      true) as p_casas,
       set_config('frila.mv.vagas',      :'vagas',      true) as p_vagas,
       set_config('frila.mv.posicoes',   :'posicoes',   true) as p_posicoes,
       set_config('frila.mv.candidatos', :'candidatos', true) as p_candidatos,
       set_config('frila.mv.dias',       :'dias',       true) as p_dias
\gset

-- O gerador cria só um dono (membro da casa 1). Cada casa extra ganha o seu, membro só dela.
do $d$
declare
  v_casas int := current_setting('frila.mv.casas')::int;
  h       int;
begin
  for h in 2 .. v_casas loop
    insert into public.usuario (
      id, perfil, nome, telefone, email, nascimento, estado, demonstracao, termos_versao, termos_aceite_em
    ) values (
      pg_temp.cp_uuid('a', h, 1), 'contratante', 'Dono da casa pesada ' || h,
      '+556195' || lpad(h::text, 7, '0'), 'dono' || h || '@casa-pesada.carga.test',
      '1980-01-01'::date, 'ativa', false, 'v1.0', now()
    );
    insert into public.membro_estabelecimento (usuario_id, perfil, estabelecimento_id, papel)
    values (pg_temp.cp_uuid('a', h, 1), 'contratante', pg_temp.cp_uuid('e', h, 1), 'administrador');
  end loop;
end $d$;

select set_config('frila.mv.estabs',
         (select string_agg(pg_temp.cp_uuid('e', h, 1)::text, ',' order by h)
            from generate_series(1, :casas) h), true) as g_estabs,
       set_config('frila.mv.donos',
         (select string_agg(pg_temp.cp_uuid('a', h, 1)::text, ',' order by h)
            from generate_series(1, :casas) h), true) as g_donos,
       set_config('frila.mv.janelas',     :'janelas',     true) as g_janelas,
       set_config('frila.mv.de',          :'ctx_inicio',  true) as g_de,
       set_config('frila.mv.amostras',    :'amostras',    true) as g_amostras,
       set_config('frila.mv.aquecimento', :'aquecimento', true) as g_aquecimento
\gset

-- ── Volume e configuração, como superusuário ───────────────────────────────────────────
do $v$
declare
  v_estabs  text[] := string_to_array(current_setting('frila.mv.estabs'), ',');
  v_janelas int[]  := string_to_array(current_setting('frila.mv.janelas'), ',')::int[];
  v_de      timestamptz := current_setting('frila.mv.de')::timestamptz;
  c int;
  j int;
  r record;
begin
  raise notice 'PARAMETROS casas=% vagas=% posicoes=% candidatos=% janelas=% amostras=% aquecimento=% dias_historico=%',
    cardinality(v_estabs), current_setting('frila.mv.vagas'), current_setting('frila.mv.posicoes'),
    current_setting('frila.mv.candidatos'), current_setting('frila.mv.janelas'),
    current_setting('frila.mv.amostras'), current_setting('frila.mv.aquecimento'),
    current_setting('frila.mv.dias');

  raise notice 'CONFIG enable_seqscan=% enable_indexscan=% enable_bitmapscan=% enable_nestloop=% random_page_cost=% work_mem=% shared_buffers=% jit=%',
    current_setting('enable_seqscan'), current_setting('enable_indexscan'),
    current_setting('enable_bitmapscan'), current_setting('enable_nestloop'),
    current_setting('random_page_cost'), current_setting('work_mem'),
    current_setting('shared_buffers'), current_setting('jit');

  for c in 1 .. cardinality(v_estabs) loop
    select (select count(*) from public.vaga v where v.estabelecimento_id = v_estabs[c]::uuid) as vagas,
           (select count(*) from public.posicao p join public.vaga v on v.id = p.vaga_id
             where v.estabelecimento_id = v_estabs[c]::uuid) as posicoes,
           (select count(*) from public.candidatura k
              join public.posicao p on p.id = k.posicao_id join public.vaga v on v.id = p.vaga_id
             where v.estabelecimento_id = v_estabs[c]::uuid) as candidaturas
      into r;
    raise notice 'VOLUME_CASA casa=% vagas=% posicoes=% candidaturas=%', c, r.vagas, r.posicoes, r.candidaturas;

    foreach j in array v_janelas loop
      select (select count(*) from public.vaga v
               where v.estabelecimento_id = v_estabs[c]::uuid
                 and v.inicio_em < v_de + make_interval(days => j) and v.fim_em > v_de) as vagas,
             (select count(*) from public.posicao p join public.vaga v on v.id = p.vaga_id
               where v.estabelecimento_id = v_estabs[c]::uuid
                 and v.inicio_em < v_de + make_interval(days => j) and v.fim_em > v_de) as posicoes,
             (select count(*) from public.candidatura k
                join public.posicao p on p.id = k.posicao_id join public.vaga v on v.id = p.vaga_id
               where v.estabelecimento_id = v_estabs[c]::uuid
                 and v.inicio_em < v_de + make_interval(days => j) and v.fim_em > v_de) as candidaturas,
             (select count(*) from public.turno t
                join public.posicao p on p.id = t.posicao_id join public.vaga v on v.id = p.vaga_id
               where v.estabelecimento_id = v_estabs[c]::uuid
                 and v.inicio_em < v_de + make_interval(days => j) and v.fim_em > v_de) as turnos
        into r;
      raise notice 'VOLUME_JANELA janela_dias=% casa=% vagas=% posicoes=% candidaturas=% turnos=%',
        j, c, r.vagas, r.posicoes, r.candidaturas, r.turnos;
    end loop;
  end loop;
end $v$;

-- ── Tempo de parede, como o dono de cada casa (authenticated) ──────────────────────────
set local role authenticated;

do $m$
declare
  v_estabs  text[] := string_to_array(current_setting('frila.mv.estabs'), ',');
  v_donos   text[] := string_to_array(current_setting('frila.mv.donos'), ',');
  v_janelas int[]  := string_to_array(current_setting('frila.mv.janelas'), ',')::int[];
  v_de      timestamptz := current_setting('frila.mv.de')::timestamptz;
  v_n       int := current_setting('frila.mv.amostras')::int;
  v_aq      int := current_setting('frila.mv.aquecimento')::int;
  v_acc     jsonb := '{}';
  v_rodada  int;
  v_j       int;
  v_c       int;
  v_t0      timestamptz;
  v_r       jsonb;
  v_ms      numeric;
begin
  for v_rodada in 1 - v_aq .. v_n loop
    for v_j in 1 .. cardinality(v_janelas) loop
      for v_c in 1 .. cardinality(v_estabs) loop
        perform set_config('request.jwt.claims',
                           json_build_object('sub', v_donos[v_c], 'role', 'authenticated')::text, true);
        v_t0 := clock_timestamp();
        v_r  := public.painel_estabelecimento(v_estabs[v_c]::uuid, v_de,
                                              v_de + make_interval(days => v_janelas[v_j]));
        v_ms := round((extract(epoch from clock_timestamp() - v_t0) * 1000)::numeric, 3);
        if v_rodada >= 1 then
          raise notice 'AMOSTRA janela_dias=% casa=% i=% ms=%', v_janelas[v_j], v_c, v_rodada, v_ms;
          v_acc := jsonb_set(v_acc, array[v_janelas[v_j]::text],
                             coalesce(v_acc -> v_janelas[v_j]::text, '[]'::jsonb) || to_jsonb(v_ms));
        end if;
        if v_rodada = 1 then
          raise notice 'BLOCO janela_dias=% casa=% vagas_resposta=% posicoes_resposta=% bytes=%',
            v_janelas[v_j], v_c, jsonb_array_length(v_r -> 'vagas'),
            (select coalesce(sum(jsonb_array_length(x -> 'posicoes')), 0)
               from jsonb_array_elements(v_r -> 'vagas') x),
            octet_length(v_r::text);
        end if;
      end loop;
    end loop;
  end loop;

  for v_j in 1 .. cardinality(v_janelas) loop
    raise notice 'PG_PERCENTIL janela_dias=% amostras=% p50_ms=% p95_ms=%',
      v_janelas[v_j],
      jsonb_array_length(v_acc -> v_janelas[v_j]::text),
      (select round((percentile_cont(0.5) within group (order by x::float8))::numeric, 2)
         from jsonb_array_elements_text(v_acc -> v_janelas[v_j]::text) x),
      (select round((percentile_cont(0.95) within group (order by x::float8))::numeric, 2)
         from jsonb_array_elements_text(v_acc -> v_janelas[v_j]::text) x);
  end loop;
end $m$;

-- ── Plano da chamada inteira e das consultas internas, casa 1, uma vez por janela ──────
-- O explain de uma função plpgsql mostra só o nó externo; as consultas de dentro saem pelo
-- auto_explain. Os parâmetros dele são de superusuário, por isso reset role antes.
reset role;

do $ae$
begin
  begin
    execute 'load ''auto_explain''';
  exception when others then
    raise notice 'AUTO_EXPLAIN_LOAD_FALHOU (%): seguindo, pode estar pré-carregado', sqlerrm;
  end;
  perform set_config('auto_explain.log_nested_statements', 'on', true);
  perform set_config('auto_explain.log_analyze', 'on', true);
  perform set_config('auto_explain.log_buffers', 'on', true);
  perform set_config('auto_explain.log_min_duration', '0', true);
exception when others then
  raise notice 'AUTO_EXPLAIN_INDISPONIVEL (%)', sqlerrm;
end $ae$;

select set_config('request.jwt.claims',
                  json_build_object('sub', :'ctx_dono', 'role', 'authenticated')::text, true) as g_claims
\gset

-- Cada janela vira uma sequência de comandos, executada por \gexec.
select x.s
  from unnest(string_to_array(:'janelas', ',')::int[]) with ordinality as jj(j, n)
 cross join lateral (values
   (1, format('do $i$ begin raise notice ''### EXPLAIN_INICIO janela_dias=%s''; end $i$', jj.j)),
   (2, 'set local role authenticated'),
   (3, format('explain (analyze, buffers, costs off) select public.painel_estabelecimento(%L::uuid, %L::timestamptz, %L::timestamptz)',
              :'ctx_estab', :'ctx_inicio', :'ctx_inicio'::timestamptz + make_interval(days => jj.j))),
   (4, 'reset role'),
   (5, format('do $i$ begin raise notice ''### EXPLAIN_FIM janela_dias=%s''; end $i$', jj.j))
 ) x(o, s)
 order by jj.n, x.o
\gexec

set local client_min_messages = log;
select x.s
  from unnest(string_to_array(:'janelas', ',')::int[]) with ordinality as jj(j, n)
 cross join lateral (values
   (1, format('do $i$ begin raise notice ''### AUTO_EXPLAIN_INICIO janela_dias=%s''; end $i$', jj.j)),
   (2, 'set local role authenticated'),
   (3, format('select octet_length(public.painel_estabelecimento(%L::uuid, %L::timestamptz, %L::timestamptz)::text) as bytes_chamada_instrumentada',
              :'ctx_estab', :'ctx_inicio', :'ctx_inicio'::timestamptz + make_interval(days => jj.j))),
   (4, 'reset role'),
   (5, format('do $i$ begin raise notice ''### AUTO_EXPLAIN_FIM janela_dias=%s''; end $i$', jj.j))
 ) x(o, s)
 order by jj.n, x.o
\gexec
set local client_min_messages = notice;
