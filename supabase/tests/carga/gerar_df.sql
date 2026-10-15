-- supabase/tests/carga/gerar_df.sql
-- Carga sintética do Distrito Federal (RNF11)
--
-- Volume simulado da praça-piloto:
--   - 30.000 estabelecimentos com membros (contratantes)
--   - 100.000 profissionais com grade semanal e funções
--   - 20.000 vagas publicadas com posições abertas
--   - Coordenadas geográficas dentro do polígono do Distrito Federal
--
-- ATENÇÃO:
--   Este script roda EXCLUSIVAMENTE no banco local de desenvolvimento.
--   NUNCA executar em homologação (frila-dev) nem em produção.
--   Para executar a carga completa via psql:
--     docker exec -i supabase_db_frila-backend psql -U postgres -d postgres -v carga=1 -f - < supabase/tests/carga/gerar_df.sql
--   Ou:
--     psql -U postgres -d postgres -v carga=1 -f supabase/tests/carga/gerar_df.sql

\if :{?carga}
\echo 'Iniciando verificação de segurança e geração de massa sintética do DF (RNF11)...'

do $$
declare
  t0 timestamptz := clock_timestamp();
  t1 timestamptz;
  v_funcoes uuid[];
  v_usuarios_existentes bigint;
  v_server_ip inet;
  v_base_data timestamptz := date_trunc('day', privado.agora()) + interval '1 day';
  v_escala int := coalesce(nullif(current_setting('frila.carga_escala', true), ''), '1')::int;
  v_n_contratantes int := 30000 * v_escala;
  v_n_estabelecimentos int := 30000 * v_escala;
  v_n_profissionais int := 100000 * v_escala;
  v_n_vagas int := 20000 * v_escala;
begin
  -- ── Proteção estrita contra execução fora do ambiente local ──────────────────
  v_server_ip := inet_server_addr();
  if v_server_ip is not null and not (v_server_ip <<= '127.0.0.0/8'::cidr or v_server_ip <<= '172.16.0.0/12'::cidr or v_server_ip <<= '10.0.0.0/8'::cidr) then
    raise exception 'Segurança RNF11: execução bloqueada em host remoto/não-local (IP: %)', v_server_ip;
  end if;

  select count(*) into v_usuarios_existentes from public.usuario;
  if v_usuarios_existentes > 200 then
    raise exception 'Segurança RNF11: banco já contém % usuários. Carga cancelada para não poluir base povoada.', v_usuarios_existentes;
  end if;

  select array_agg(id order by id) into v_funcoes from public.funcao;
  if v_funcoes is null or cardinality(v_funcoes) = 0 then
    raise exception 'Tabela public.funcao está vazia. Aplique o seed antes de rodar a carga.';
  end if;

  raise notice 'Iniciando carga com escala %x (% contratantes, % profissionais, % vagas)...',
    v_escala, v_n_contratantes, v_n_profissionais, v_n_vagas;

  raise notice '1. Gerando % contas de contratantes em public.usuario...', v_n_contratantes;
  insert into public.usuario (
    id, perfil, nome, telefone, email, nascimento, estado, demonstracao, termos_versao, termos_aceite_em
  )
  select ('a0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         'contratante',
         'Contratante DF ' || i,
         '+556191' || lpad(i::text, 7, '0'),
         'contratante_' || i || '@df.carga.test',
         '1980-01-01'::date,
         'ativa',
         false,
         'v1.0',
         now()
    from generate_series(1, v_n_contratantes) i
  on conflict (id) do nothing;
  t1 := clock_timestamp();
  raise notice '   % contratantes gerados em %', v_n_contratantes, (t1 - t0);
  t0 := t1;

  raise notice '2. Gerando % estabelecimentos no DF em public.estabelecimento...', v_n_estabelecimentos;
  insert into public.estabelecimento (
    id, nome, documento, tipo, endereco, ponto
  )
  select ('e0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         'Estabelecimento DF ' || i,
         lpad(i::text, 14, '0'),
         case when i % 3 = 0 then 'food_service'::public.tipo_estabelecimento
              when i % 3 = 1 then 'varejo'::public.tipo_estabelecimento
              else 'evento'::public.tipo_estabelecimento end,
         'Endereço Comercial DF ' || i,
         extensions.ST_SetSRID(
           extensions.ST_MakePoint(
             -48.20 + (i % 800) * 0.0009,
             -16.00 + ((i * 7) % 450) * 0.001
           ), 4326
         )::extensions.geography
    from generate_series(1, v_n_estabelecimentos) i
  on conflict (id) do nothing;
  t1 := clock_timestamp();
  raise notice '   % estabelecimentos gerados em %', v_n_estabelecimentos, (t1 - t0);
  t0 := t1;

  raise notice '3. Vinculando proprietários em public.membro_estabelecimento...';
  insert into public.membro_estabelecimento (
    usuario_id, perfil, estabelecimento_id, papel
  )
  select ('a0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         'contratante',
         ('e0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         'administrador'
    from generate_series(1, v_n_estabelecimentos) i
  on conflict (usuario_id, estabelecimento_id) do nothing;
  t1 := clock_timestamp();
  raise notice '   % membros vinculados em %', v_n_estabelecimentos, (t1 - t0);
  t0 := t1;

  raise notice '4. Gerando % contas de profissionais em public.usuario...', v_n_profissionais;
  insert into public.usuario (
    id, perfil, nome, telefone, email, nascimento, estado, demonstracao, termos_versao, termos_aceite_em
  )
  select ('b0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         'profissional',
         'Profissional DF ' || i,
         '+556192' || lpad(i::text, 7, '0'),
         'profissional_' || i || '@df.carga.test',
         '1995-01-01'::date,
         'ativa',
         false,
         'v1.0',
         now()
    from generate_series(1, v_n_profissionais) i
  on conflict (id) do nothing;
  t1 := clock_timestamp();
  raise notice '   % usuarios profissionais gerados em %', v_n_profissionais, (t1 - t0);
  t0 := t1;

  raise notice '5. Gerando % profissionais com ponto base no DF em public.profissional...', v_n_profissionais;
  insert into public.profissional (
    id, usuario_id, perfil, ponto_base
  )
  select ('b0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         ('b0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         'profissional',
         extensions.ST_SetSRID(
           extensions.ST_MakePoint(
             -48.20 + ((i * 13) % 800) * 0.0009,
             -16.00 + ((i * 17) % 450) * 0.001
           ), 4326
         )::extensions.geography
    from generate_series(1, v_n_profissionais) i
  on conflict (id) do nothing;
  t1 := clock_timestamp();
  raise notice '   % profissionais gerados em %', v_n_profissionais, (t1 - t0);
  t0 := t1;

  raise notice '6. Atribuindo funções do catálogo aos profissionais...';
  insert into public.profissional_funcao (profissional_id, funcao_id)
  select ('b0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         v_funcoes[(i % cardinality(v_funcoes)) + 1]
    from generate_series(1, v_n_profissionais) i
  union all
  select ('b0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         v_funcoes[((i + 7) % cardinality(v_funcoes)) + 1]
    from generate_series(1, v_n_profissionais) i
   where (i % cardinality(v_funcoes)) <> ((i + 7) % cardinality(v_funcoes))
  on conflict do nothing;
  t1 := clock_timestamp();
  raise notice '   profissional_funcao gerado em %', (t1 - t0);
  t0 := t1;

  raise notice '7. Gerando grade semanal de disponibilidade...';
  insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
  select ('b0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         (i % 7)::smallint,
         '18:00'::time,
         '02:00'::time
    from generate_series(1, v_n_profissionais) i
  union all
  select ('b0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         ((i + 2) % 7)::smallint,
         '08:00'::time,
         '16:00'::time
    from generate_series(1, v_n_profissionais) i
  on conflict do nothing;
  t1 := clock_timestamp();
  raise notice '   disponibilidade gerada em %', (t1 - t0);
  t0 := t1;

  raise notice '8. Gerando % vagas publicadas no DF em public.vaga...', v_n_vagas;
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
    responsavel_local, modo, estado, publicado_por, chave_cliente
  )
  select ('c0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         ('e0000000-0000-0000-0000-' || lpad(to_hex((((i - 1) % v_n_estabelecimentos) + 1)::bigint), 12, '0'))::uuid,
         v_funcoes[(i % cardinality(v_funcoes)) + 1],
         v_base_data + ((i % 14) || ' days')::interval + ((18 + (i % 5)) || ' hours')::interval,
         v_base_data + ((i % 14) || ' days')::interval + ((18 + (i % 5)) || ' hours')::interval + interval '6 hours',
         'Local DF ' || i,
         extensions.ST_SetSRID(
           extensions.ST_MakePoint(
             -48.20 + (i % 800) * 0.0009,
             -16.00 + ((i * 7) % 450) * 0.001
           ), 4326
         )::extensions.geography,
         15000 + (i % 10) * 1000,
         1,
         false,
         false,
         false,
         'Responsável ' || i,
         'urgencia',
         'publicada',
         ('a0000000-0000-0000-0000-' || lpad(to_hex((((i - 1) % v_n_contratantes) + 1)::bigint), 12, '0'))::uuid,
         gen_random_uuid()
    from generate_series(1, v_n_vagas) i
  on conflict (id) do nothing;
  t1 := clock_timestamp();
  raise notice '   % vagas geradas em %', v_n_vagas, (t1 - t0);
  t0 := t1;

  raise notice '9. Gerando % posições abertas em public.posicao...', v_n_vagas;
  insert into public.posicao (vaga_id, estado, inicio_em, fim_em)
  select v.id,
         'aberta',
         v.inicio_em,
         v.fim_em
    from public.vaga v
   where v.id >= 'c0000000-0000-0000-0000-000000000001'::uuid
     and v.id <= ('c0000000-0000-0000-0000-' || lpad(to_hex(v_n_vagas::bigint), 12, '0'))::uuid
  on conflict do nothing;
  t1 := clock_timestamp();
  raise notice '   % posições abertas geradas em %', v_n_vagas, (t1 - t0);
  t0 := t1;

  raise notice '10. Atualizando estatísticas do planejador (ANALYZE)...';
  analyze public.usuario;
  analyze public.estabelecimento;
  analyze public.membro_estabelecimento;
  analyze public.profissional;
  analyze public.profissional_funcao;
  analyze public.disponibilidade;
  analyze public.vaga;
  analyze public.posicao;
  t1 := clock_timestamp();
  raise notice '    Estatísticas atualizadas em %', (t1 - t0);

  raise notice 'Massa sintética do DF carregada com sucesso!';
end $$;

\else
-- Execução padrão em pgTAP (quando rodado por 'supabase test db')
-- Não carrega os 150k registros para manter suíte e CI rápidas e determinísticas.
begin;
select plan(1);
select pass('supabase/tests/carga/gerar_df.sql: script de carga sintética do DF presente (executar com -v carga=1)');
select * from finish();
rollback;
\endif
