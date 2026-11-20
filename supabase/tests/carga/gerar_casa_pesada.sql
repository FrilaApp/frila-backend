-- supabase/tests/carga/gerar_casa_pesada.sql
-- Carga sintética de UMA casa com histórico, para medir public.painel_estabelecimento
-- (cartão 1zojatYG).
--
-- Por que existe. supabase/tests/carga/gerar_df.sql espalha 20 mil vagas por 30 mil casas
-- (menos de uma vaga por casa, uma posição aberta cada, sem turno, candidatura nem
-- ocorrência). O painel de uma casa com histórico não é exercitado por ele.
--
-- Os volumes e as proporções de estado abaixo são HIPÓTESE de volume, não dado de produto.
-- Quem confirma o que é plausível para uma casa do DF é o Cauê ou o Jota.
--
-- ATENÇÃO:
--   * Roda EXCLUSIVAMENTE em banco local. Recusa host que não seja 127/8, 172.16/12 ou
--     10/8. NUNCA em frila-dev nem em Prod.
--   * Só roda DENTRO de uma transação, e quem chama TEM de terminar com `rollback`. O
--     arquivo não faz commit. Sem transação aberta ele falha de propósito (savepoint).
--     O chamador de referência é scripts/medir-painel.sh.
--   * Não depende de `supabase db reset` nem de gerar_df.sql: cria os seus próprios
--     usuários, profissionais e estabelecimentos, com ids em faixas que o gerar_df.sql não
--     usa (aqui o primeiro grupo do uuid termina em número de casa >= 1; lá é 0).
--
-- Variáveis (psql -v). Todas opcionais; o padrão é o cenário S1.
--   vagas                  vagas da casa principal                          (padrão 200)
--   posicoes               posições por vaga                                (padrão 2)
--   candidatos             candidaturas por posição                         (padrão 6)
--   dias                   tamanho do histórico, em dias, terminando hoje   (padrão 365)
--   casas_extras           outras casas SEM o dono como membro              (padrão 0)
--   vagas_extras           vagas de cada casa extra (2 posições, 3 cand.)   (padrão 20)
--   permitir_base_povoada  'sim' aceita banco com mais de 200 usuários      (padrão 'nao')
--
-- Uso de referência (dentro de `begin; ... rollback;`):
--   psql ... -v casa_pesada=1 -v vagas=1000 -v posicoes=3 -v candidatos=10 -f <este arquivo>
--
-- Em `supabase test db` (sem -v casa_pesada=1) o arquivo cai no ramo \else e roda só um
-- pass() de pgTAP, como o gerar_df.sql, para a suíte não carregar volume.

\if :{?casa_pesada}
\echo 'gerar_casa_pesada: verificando segurança e gerando a casa sintética...'

-- Falha sem transação aberta ("SAVEPOINT can only be used in transaction blocks").
savepoint casa_pesada_exige_transacao;
release savepoint casa_pesada_exige_transacao;

\if :{?vagas}
\else
  \set vagas 200
\endif
\if :{?posicoes}
\else
  \set posicoes 2
\endif
\if :{?candidatos}
\else
  \set candidatos 6
\endif
\if :{?dias}
\else
  \set dias 365
\endif
\if :{?casas_extras}
\else
  \set casas_extras 0
\endif
\if :{?vagas_extras}
\else
  \set vagas_extras 20
\endif
\if :{?permitir_base_povoada}
\else
  \set permitir_base_povoada nao
\endif

select set_config('frila.casa_pesada.vagas',        :'vagas',                true) as c_vagas,
       set_config('frila.casa_pesada.posicoes',     :'posicoes',             true) as c_posicoes,
       set_config('frila.casa_pesada.candidatos',   :'candidatos',           true) as c_candidatos,
       set_config('frila.casa_pesada.dias',         :'dias',                 true) as c_dias,
       set_config('frila.casa_pesada.casas_extras', :'casas_extras',         true) as c_extras,
       set_config('frila.casa_pesada.vagas_extras', :'vagas_extras',         true) as c_vagas_extras,
       set_config('frila.casa_pesada.base_povoada', :'permitir_base_povoada', true) as c_base
\gset

-- Ids determinísticos: <letra><casa em 7 dígitos>-0000-0000-0000-<n em 12 dígitos hex>.
-- Casa 1 é a principal; 2 em diante são as extras. Os profissionais e o dono são da casa 1.
create function pg_temp.cp_uuid(letra text, casa int, n bigint) returns uuid
language sql immutable as $$
  select (letra || lpad(casa::text, 7, '0') || '-0000-0000-0000-' || lpad(to_hex(n), 12, '0'))::uuid
$$;

-- Estado da posição de índice n dentro da casa (hipótese do cartão, P3.1):
--   n % 10 em 0..6 cumprida (70%) · 7 cancelada (10%) · 8 confirmada (10%) · 9 aberta (10%)
create function pg_temp.cp_estado(n bigint) returns public.estado_posicao
language sql immutable as $$
  select case n % 10
           when 7 then 'cancelada'::public.estado_posicao
           when 8 then 'confirmada'::public.estado_posicao
           when 9 then 'aberta'::public.estado_posicao
           else 'cumprida'::public.estado_posicao
         end
$$;

-- Gera vagas, posições, turnos, candidaturas e ocorrências de UMA casa.
--
-- Horário: no máximo 3 vagas por dia, em faixas de 6 h que não se cruzam (06h, 12h, 18h).
-- É isso que mantém a exclusão sem_turno_sobreposto satisfeita com um pool pequeno de
-- profissionais: o mesmo profissional reaparece em outras vagas, mas duas vagas nunca
-- dividem dia e faixa, e dentro de uma vaga as posições usam profissionais distintos
-- (índices consecutivos módulo p_pool, com p_pool >= p_posicoes).
--
-- Cada casa usa um grupo próprio de profissionais, a partir de p_offset. As casas extras têm
-- as mesmas datas da principal; se dividissem profissionais, o mesmo profissional seria
-- confirmado em duas casas no mesmo horário e violaria sem_turno_sobreposto.
--
-- O gerador não busca coerência entre o estado e a data: todas as vagas ficam no passado
-- (o histórico termina ontem) e há posições abertas e confirmadas nelas. Serve ao volume e
-- à forma dos dados, não à semântica de "hoje".
--
-- Das posições cumpridas, 5% têm check-in manual ainda pendente (alimenta
-- checkins_pendentes) e 5% manual já confirmado; o resto é geolocalizado. A confirmada tem
-- turno sem check-in.
create function pg_temp.cp_gerar_casa(
  p_casa int, p_estab uuid, p_dono uuid,
  p_vagas int, p_posicoes int, p_candidatos int, p_dias int, p_pool int, p_offset int
) returns void
language plpgsql as $$
declare
  v_funcoes uuid[];
  v_agora   timestamptz := privado.agora();
  v_inicio  timestamptz := date_trunc('day', privado.agora()) - make_interval(days => p_dias);
begin
  select array_agg(id order by id) into v_funcoes from public.funcao;

  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
    responsavel_local, modo, estado, publicado_por, chave_cliente
  )
  select pg_temp.cp_uuid('c', p_casa, i),
         p_estab,
         v_funcoes[(i % cardinality(v_funcoes)) + 1],
         h.inicio,
         h.inicio + interval '6 hours',
         'Local casa pesada ' || i,
         extensions.ST_SetSRID(extensions.ST_MakePoint(-47.93, -15.78), 4326)::extensions.geography,
         15000 + (i % 10) * 1000,
         p_posicoes,
         false, false, false,
         'Responsável ' || i,
         'urgencia',
         case when h.inicio + interval '6 hours' < v_agora
              then 'encerrada'::public.estado_vaga
              else 'publicada'::public.estado_vaga end,
         p_dono,
         gen_random_uuid()
    from generate_series(1, p_vagas) i
   cross join lateral (
     select v_inicio
            + make_interval(days => d.dia)
            + make_interval(hours => 6 + 6 * ((i - 1) - ceil(d.dia::numeric * p_vagas / p_dias)::int)) as inicio
       from (select floor((i - 1)::numeric * p_dias / p_vagas)::int as dia) d
   ) h;

  insert into public.posicao (
    id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em
  )
  select pg_temp.cp_uuid('d', p_casa, n.n),
         v.id,
         pg_temp.cp_estado(n.n),
         case when pg_temp.cp_estado(n.n) = 'aberta' then null
              else pg_temp.cp_uuid('b', 1, p_offset + (n.n % p_pool) + 1) end,
         case when pg_temp.cp_estado(n.n) = 'aberta' then null
              else v.inicio_em - interval '2 days' end,
         pg_temp.cp_estado(n.n) = 'cancelada' and n.n % 3 = 0,
         v.inicio_em,
         v.fim_em
    from generate_series(1, p_vagas) i
    join public.vaga v on v.id = pg_temp.cp_uuid('c', p_casa, i)
   cross join lateral generate_series(1, p_posicoes) k
   cross join lateral (select (i - 1)::bigint * p_posicoes + k as n) n;

  insert into public.turno (
    posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, checkin_confirmado_em,
    checkout_em, checkout_distancia_m, verificacao, valor_acordado_centavos
  )
  select p.id,
         case when m.modo = 'sem_checkin' then null else p.inicio_em + interval '5 minutes' end,
         case m.modo when 'sem_checkin' then null
                     when 'geo'         then 'geolocalizado'::public.tipo_registro
                     else 'manual'::public.tipo_registro end,
         case when m.modo = 'sem_checkin' then null else 50 end,
         case when m.modo = 'manual_confirmado' then p.inicio_em + interval '1 hour' else null end,
         case when p.estado = 'cumprida' then p.fim_em else null end,
         case when p.estado = 'cumprida' then 40 else null end,
         case when m.modo in ('geo', 'manual_confirmado')
              then 'verificado'::public.verificacao_turno
              else 'pendente'::public.verificacao_turno end,
         v.valor_centavos
    from generate_series(1, p_vagas::bigint * p_posicoes) n
    join public.posicao p on p.id = pg_temp.cp_uuid('d', p_casa, n)
    join public.vaga v    on v.id = p.vaga_id
   cross join lateral (
     select case when p.estado = 'confirmada' then 'sem_checkin'
                 when n % 20 = 0              then 'manual_pendente'
                 when n % 20 = 1              then 'manual_confirmado'
                 else 'geo' end as modo
   ) m
   where p.estado in ('cumprida', 'confirmada');

  insert into public.candidatura (posicao_id, profissional_id, estado)
  select pg_temp.cp_uuid('d', p_casa, n),
         pg_temp.cp_uuid('b', 1, p_offset + ((n + c) % p_pool) + 1),
         case when pg_temp.cp_estado(n) = 'aberta' then 'pendente'::public.estado_candidatura
              when c = 0                           then 'aceita'::public.estado_candidatura
              else 'recusada'::public.estado_candidatura end
    from generate_series(1, p_vagas::bigint * p_posicoes) n
   cross join generate_series(0, p_candidatos - 1) c;

  insert into public.ocorrencia (tipo, posicao_id, autor_id, motivo, criada_em)
  select 'cancelamento'::public.tipo_ocorrencia,
         p.id,
         case when n % 3 = 0 then pg_temp.cp_uuid('b', 1, p_offset + (n % p_pool) + 1) else p_dono end,
         case n % 3 when 0 then 'imprevisto pessoal'
                    when 1 then 'no_show_sem_checkin'
                    else 'mudança de escala' end,
         p.inicio_em - interval '1 day'
    from generate_series(1, p_vagas::bigint * p_posicoes) n
    join public.posicao p on p.id = pg_temp.cp_uuid('d', p_casa, n)
   where p.estado = 'cancelada';
end $$;

do $$
declare
  v_vagas      int := current_setting('frila.casa_pesada.vagas')::int;
  v_posicoes   int := current_setting('frila.casa_pesada.posicoes')::int;
  v_candidatos int := current_setting('frila.casa_pesada.candidatos')::int;
  v_dias       int := current_setting('frila.casa_pesada.dias')::int;
  v_extras     int := current_setting('frila.casa_pesada.casas_extras')::int;
  v_vagas_ext  int := current_setting('frila.casa_pesada.vagas_extras')::int;
  v_povoada    text := current_setting('frila.casa_pesada.base_povoada');
  v_pool       int;
  v_pool_ext   constant int := 20;
  v_total      int;
  v_dono       uuid := pg_temp.cp_uuid('a', 1, 1);
  v_funcoes    uuid[];
  v_server_ip  inet;
  v_usuarios   bigint;
  t0           timestamptz := clock_timestamp();
  v_h          int;
begin
  -- ── Salvaguardas ────────────────────────────────────────────────────────────
  v_server_ip := inet_server_addr();
  if v_server_ip is not null and not (v_server_ip <<= '127.0.0.0/8'::cidr
                                      or v_server_ip <<= '172.16.0.0/12'::cidr
                                      or v_server_ip <<= '10.0.0.0/8'::cidr) then
    raise exception 'Segurança: execução bloqueada em host remoto/não-local (IP: %)', v_server_ip;
  end if;

  select count(*) into v_usuarios from public.usuario;
  if v_usuarios > 200 and v_povoada <> 'sim' then
    raise exception 'O banco já contém % usuários. Os números medidos incluiriam essa massa. Rode com -v permitir_base_povoada=sim se isso for aceitável (a carga some no rollback), ou use outro banco.', v_usuarios;
  end if;

  select array_agg(id order by id) into v_funcoes from public.funcao;
  if v_funcoes is null or cardinality(v_funcoes) = 0 then
    raise exception 'Tabela public.funcao está vazia. Aplique o seed antes.';
  end if;

  if exists (select 1 from public.estabelecimento e where e.id = pg_temp.cp_uuid('e', 1, 1)) then
    raise exception 'A massa da casa pesada já existe neste banco (sobra de uma carga que não terminou em rollback?). Nada foi gerado.';
  end if;

  if v_vagas < 1 or v_posicoes < 1 or v_posicoes > 200 or v_candidatos < 1 or v_dias < 30
     or v_extras < 0 or v_vagas_ext < 1 then
    raise exception 'Parâmetros fora do intervalo: vagas>=1, 1<=posicoes<=200, candidatos>=1, dias>=30, casas_extras>=0, vagas_extras>=1.';
  end if;
  if ceil(v_vagas::numeric / v_dias) > 3 or ceil(v_vagas_ext::numeric / v_dias) > 3 then
    raise exception 'No máximo 3 vagas por dia (faixas de 6 h sem cruzar). Aumente -v dias ou reduza -v vagas.';
  end if;

  v_pool  := greatest(300, v_candidatos, v_posicoes);
  v_total := v_pool + v_extras * v_pool_ext;

  -- A recomputação de comparecimento por gatilho não faz parte do que se mede; o idioma de
  -- lote é o mesmo de 20260926000000 e 20261112100000. Desfeito no fim.
  perform set_config('frila.em_lote', 'true', true);

  raise notice 'casa pesada: % vagas x % posicoes x % candidatos, % dias, % profissionais (% na principal), % casas extras',
    v_vagas, v_posicoes, v_candidatos, v_dias, v_total, v_pool, v_extras;

  -- ── Identidade ──────────────────────────────────────────────────────────────
  insert into public.usuario (
    id, perfil, nome, telefone, email, nascimento, estado, demonstracao, termos_versao, termos_aceite_em
  ) values (
    v_dono, 'contratante', 'Dono da casa pesada', '+5561950000001',
    'dono@casa-pesada.carga.test', '1980-01-01'::date, 'ativa', false, 'v1.0', now()
  );

  insert into public.usuario (
    id, perfil, nome, telefone, email, nascimento, estado, demonstracao, termos_versao, termos_aceite_em
  )
  select pg_temp.cp_uuid('b', 1, i),
         'profissional',
         'Profissional casa pesada ' || i,
         '+556193' || lpad(i::text, 7, '0'),
         'profissional_' || i || '@casa-pesada.carga.test',
         '1995-01-01'::date, 'ativa', false, 'v1.0', now()
    from generate_series(1, v_total) i;

  insert into public.profissional (id, usuario_id, perfil, ponto_base)
  select pg_temp.cp_uuid('b', 1, i),
         pg_temp.cp_uuid('b', 1, i),
         'profissional',
         extensions.ST_SetSRID(extensions.ST_MakePoint(-47.93, -15.78), 4326)::extensions.geography
    from generate_series(1, v_total) i;

  insert into public.profissional_funcao (profissional_id, funcao_id)
  select pg_temp.cp_uuid('b', 1, i), v_funcoes[(i % cardinality(v_funcoes)) + 1]
    from generate_series(1, v_total) i
  union all
  select pg_temp.cp_uuid('b', 1, i), v_funcoes[((i + 7) % cardinality(v_funcoes)) + 1]
    from generate_series(1, v_total) i
   where (i % cardinality(v_funcoes)) <> ((i + 7) % cardinality(v_funcoes))
  on conflict do nothing;

  insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
  select pg_temp.cp_uuid('e', h, 1),
         'Casa pesada ' || h,
         '98' || lpad(h::text, 12, '0'),
         'food_service'::public.tipo_estabelecimento,
         'Endereço casa pesada ' || h,
         extensions.ST_SetSRID(extensions.ST_MakePoint(-47.93, -15.78), 4326)::extensions.geography
    from generate_series(1, 1 + v_extras) h;

  -- O dono é membro só da casa principal. As extras ficam sem vínculo; quem mede o
  -- controle "leitor membro de 1 e de 5 casas" cria os vínculos depois.
  insert into public.membro_estabelecimento (usuario_id, perfil, estabelecimento_id, papel)
  values (v_dono, 'contratante', pg_temp.cp_uuid('e', 1, 1), 'administrador');

  raise notice '   identidade pronta em %', clock_timestamp() - t0;
  t0 := clock_timestamp();

  -- ── Casa principal e extras ─────────────────────────────────────────────────
  perform pg_temp.cp_gerar_casa(1, pg_temp.cp_uuid('e', 1, 1), v_dono,
                                v_vagas, v_posicoes, v_candidatos, v_dias, v_pool, 0);
  raise notice '   casa principal pronta em %', clock_timestamp() - t0;
  t0 := clock_timestamp();

  for v_h in 2 .. 1 + v_extras loop
    perform pg_temp.cp_gerar_casa(v_h, pg_temp.cp_uuid('e', v_h, 1), v_dono,
                                  v_vagas_ext, 2, 3, v_dias, v_pool_ext,
                                  v_pool + (v_h - 2) * v_pool_ext);
  end loop;
  if v_extras > 0 then
    raise notice '   % casas extras prontas em %', v_extras, clock_timestamp() - t0;
  end if;

  perform set_config('frila.em_lote', '', true);
end $$;

-- O que o chamador precisa saber depois da carga. Tabela temporária: some no rollback.
create temp table cp_ctx as
select pg_temp.cp_uuid('e', 1, 1) as estab,
       pg_temp.cp_uuid('a', 1, 1) as dono,
       date_trunc('day', privado.agora()) - make_interval(days => :dias) as inicio;

-- Estatística do planejador, como o planos-com-carga.sh ensina. Dentro da transação, então
-- desfeita no rollback.
analyze public.usuario;
analyze public.profissional;
analyze public.profissional_funcao;
analyze public.estabelecimento;
analyze public.membro_estabelecimento;
analyze public.vaga;
analyze public.posicao;
analyze public.turno;
analyze public.candidatura;
analyze public.ocorrencia;

\echo 'gerar_casa_pesada: casa gerada (dentro da transação do chamador).'
\else
-- Execução padrão em pgTAP (quando rodado por 'supabase test db').
begin;
select plan(1);
select pass('supabase/tests/carga/gerar_casa_pesada.sql: gerador da casa pesada presente (executar com -v casa_pesada=1)');
select * from finish();
rollback;
\endif
