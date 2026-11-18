-- scripts/medir-painel.sql
-- Mede UM cenário de public.painel_estabelecimento. Não roda sozinho: o scripts/medir-painel.sh
-- o injeta, uma vez por cenário, DEPOIS de supabase/tests/carga/gerar_casa_pesada.sql e
-- dentro da mesma transação (que termina em rollback).
--
-- Entradas (psql \set, definidas pelo .sh):
--   rotulo        nome do cenário (S1, S2, ...)
--   janela_dias   tamanho da janela de/ate, em dias, a partir do início do histórico
--   amostras      número de chamadas medidas (padrão do .sh: 10)
--   aquecimento   chamadas descartadas antes das amostras (padrão do .sh: 3)
--   ae_min_ms     auto_explain.log_min_duration, em ms, na chamada instrumentada
--   ligar_extras  1 liga o dono como membro das casas extras antes de medir (controle)
--
-- Saída que o .sh lê (linhas começam por estes marcadores):
--   stdout:
--     VOLUME_JANELA ...    linhas dentro da janela, contadas como superusuário
--     ### EXPLAIN_...      explain (analyze, buffers) da chamada
--   stderr (NOTICE e LOG):
--     MEDIDA ...           tempo de parede: mediana/mín/máx de `amostras` chamadas
--     ### AUTO_EXPLAIN_..  consultas internas, via auto_explain, de UMA chamada extra
--     AUTO_EXPLAIN_INDISPONIVEL ...  quando o auto_explain não pôde ser ligado

\echo ### CENARIO :rotulo

select estab as ctx_estab, dono as ctx_dono, inicio as ctx_inicio from cp_ctx
\gset

\if :ligar_extras
  -- Controle da #518: o leitor passa a ser membro de todas as casas extras. Só toca as casas
  -- que o gerador criou nesta transação (nome 'Casa pesada N', id no formato do gerador).
  insert into public.membro_estabelecimento (usuario_id, perfil, estabelecimento_id, papel)
  select :'ctx_dono'::uuid, 'contratante', e.id, 'administrador'
    from public.estabelecimento e
   where e.id <> :'ctx_estab'::uuid
     and e.nome like 'Casa pesada %'
     and e.id::text ~ '^e[0-9]{7}-0000-0000-0000-000000000001$';
\endif

select :'ctx_inicio'::timestamptz                                       as de,
       :'ctx_inicio'::timestamptz + make_interval(days => :janela_dias) as ate
\gset

-- Linhas dentro da janela (como superusuário: não passa pelo painel).
select (select count(*) from public.vaga v
         where v.estabelecimento_id = :'ctx_estab'::uuid
           and v.inicio_em < :'ate'::timestamptz and v.fim_em > :'de'::timestamptz)   as vagas,
       (select count(*) from public.posicao p join public.vaga v on v.id = p.vaga_id
         where v.estabelecimento_id = :'ctx_estab'::uuid
           and v.inicio_em < :'ate'::timestamptz and v.fim_em > :'de'::timestamptz)   as posicoes,
       (select count(*) from public.candidatura c
          join public.posicao p on p.id = c.posicao_id join public.vaga v on v.id = p.vaga_id
         where v.estabelecimento_id = :'ctx_estab'::uuid
           and v.inicio_em < :'ate'::timestamptz and v.fim_em > :'de'::timestamptz)   as candidaturas,
       (select count(*) from public.turno t
          join public.posicao p on p.id = t.posicao_id join public.vaga v on v.id = p.vaga_id
         where v.estabelecimento_id = :'ctx_estab'::uuid
           and v.inicio_em < :'ate'::timestamptz and v.fim_em > :'de'::timestamptz)   as turnos,
       (select count(*) from public.membro_estabelecimento m
         where m.usuario_id = :'ctx_dono'::uuid)                                      as casas_do_leitor
\gset n_

\echo VOLUME_JANELA rotulo=:rotulo janela_dias=:janela_dias vagas=:n_vagas posicoes=:n_posicoes candidaturas=:n_candidaturas turnos=:n_turnos casas_do_leitor=:n_casas_do_leitor

select set_config('frila.med.estab',       :'ctx_estab', true) as m_estab,
       set_config('frila.med.de',          :'de',        true) as m_de,
       set_config('frila.med.ate',         :'ate',       true) as m_ate,
       set_config('frila.med.rotulo',      :'rotulo',    true) as m_rotulo,
       set_config('frila.med.amostras',    :'amostras',  true) as m_amostras,
       set_config('frila.med.aquecimento', :'aquecimento', true) as m_aquecimento,
       set_config('frila.med.ae_min_ms',   :'ae_min_ms', true) as m_ae,
       set_config('request.jwt.claims',
                  json_build_object('sub', :'ctx_dono', 'role', 'authenticated')::text, true) as m_claims
\gset

-- ── 1. Tempo de parede, como o dono da casa (authenticated), auto_explain desligado ────
set local role authenticated;

do $m$
declare
  v_estab uuid        := current_setting('frila.med.estab')::uuid;
  v_de    timestamptz := current_setting('frila.med.de')::timestamptz;
  v_ate   timestamptz := current_setting('frila.med.ate')::timestamptz;
  v_n     int         := current_setting('frila.med.amostras')::int;
  v_aq    int         := current_setting('frila.med.aquecimento')::int;
  v_ms    numeric[]   := '{}';
  v_t0    timestamptz;
  v_r     jsonb;
  v_i     int;
  v_med   numeric;
  v_min   numeric;
  v_max   numeric;
begin
  for v_i in 1 .. v_aq loop
    v_r := public.painel_estabelecimento(v_estab, v_de, v_ate);
  end loop;
  for v_i in 1 .. v_n loop
    v_t0 := clock_timestamp();
    v_r  := public.painel_estabelecimento(v_estab, v_de, v_ate);
    v_ms := v_ms || (extract(epoch from clock_timestamp() - v_t0) * 1000)::numeric;
  end loop;
  select percentile_cont(0.5) within group (order by x), min(x), max(x)
    into v_med, v_min, v_max
    from unnest(v_ms) x;
  raise notice 'MEDIDA rotulo=% aquecimento=% amostras=% mediana_ms=% min_ms=% max_ms=% bytes=%',
    current_setting('frila.med.rotulo'), v_aq, v_n,
    round(v_med, 2), round(v_min, 2), round(v_max, 2), octet_length(v_r::text);
end $m$;

-- ── 2. Plano e buffers da chamada inteira ─────────────────────────────────────────────
\echo ### EXPLAIN_INICIO :rotulo
explain (analyze, buffers, costs off)
select public.painel_estabelecimento(:'ctx_estab'::uuid, :'de'::timestamptz, :'ate'::timestamptz);
\echo ### EXPLAIN_FIM :rotulo

reset role;

-- ── 3. Consultas internas via auto_explain, numa chamada extra ────────────────────────
-- Os parâmetros do auto_explain são de superusuário, por isso reset role antes. Se não
-- puderem ser ligados, o cenário segue sem plano interno e o .sh registra "NAO MEDIDO".
do $ae$
begin
  begin
    execute 'load ''auto_explain''';
  exception when others then
    raise notice 'AUTO_EXPLAIN_LOAD_FALHOU rotulo=% (%): seguindo, pode estar pré-carregado',
      current_setting('frila.med.rotulo'), sqlerrm;
  end;
  perform set_config('auto_explain.log_nested_statements', 'on', true);
  perform set_config('auto_explain.log_analyze', 'on', true);
  perform set_config('auto_explain.log_buffers', 'on', true);
  perform set_config('auto_explain.log_min_duration', current_setting('frila.med.ae_min_ms'), true);
exception when others then
  raise notice 'AUTO_EXPLAIN_INDISPONIVEL rotulo=% (%)', current_setting('frila.med.rotulo'), sqlerrm;
end $ae$;

-- Os marcadores saem por NOTICE (stderr), o mesmo fluxo em que o auto_explain escreve o LOG,
-- porque o docker exec não garante a ordem entre stdout e stderr.
set local client_min_messages = log;
set local role authenticated;
do $i$
begin
  raise notice '### AUTO_EXPLAIN_INICIO %', current_setting('frila.med.rotulo');
end $i$;
select octet_length(public.painel_estabelecimento(:'ctx_estab'::uuid, :'de'::timestamptz, :'ate'::timestamptz)::text) as bytes_chamada_instrumentada;
do $f$
begin
  raise notice '### AUTO_EXPLAIN_FIM %', current_setting('frila.med.rotulo');
end $f$;
reset role;
set local client_min_messages = notice;

do $off$
begin
  perform set_config('auto_explain.log_min_duration', '-1', true);
exception when others then
  null;
end $off$;

\echo ### FIM_CENARIO :rotulo
