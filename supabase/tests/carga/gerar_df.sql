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

  raise notice '1. Gerando 30.000 contas de contratantes em public.usuario...';
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
    from generate_series(1, 30000) i
  on conflict (id) do nothing;
  t1 := clock_timestamp();
  raise notice '   30.000 contratantes gerados em %', (t1 - t0);
  t0 := t1;

  raise notice '2. Gerando 30.000 estabelecimentos no DF em public.estabelecimento...';
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
    from generate_series(1, 30000) i
  on conflict (id) do nothing;
  t1 := clock_timestamp();
  raise notice '   30.000 estabelecimentos gerados em %', (t1 - t0);
  t0 := t1;

  raise notice '3. Vinculando proprietários em public.membro_estabelecimento...';
  insert into public.membro_estabelecimento (
    usuario_id, perfil, estabelecimento_id, papel
  )
  select ('a0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         'contratante',
         ('e0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         'administrador'
    from generate_series(1, 30000) i
  on conflict (usuario_id, estabelecimento_id) do nothing;
  t1 := clock_timestamp();
  raise notice '   30.000 membros vinculados em %', (t1 - t0);
  t0 := t1;

  raise notice '4. Gerando 100.000 contas de profissionais em public.usuario...';
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
    from generate_series(1, 100000) i
  on conflict (id) do nothing;
  t1 := clock_timestamp();
  raise notice '   100.000 usuarios profissionais gerados em %', (t1 - t0);
  t0 := t1;

  raise notice '5. Gerando 100.000 profissionais com ponto base no DF em public.profissional...';
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
    from generate_series(1, 100000) i
  on conflict (id) do nothing;
  t1 := clock_timestamp();
  raise notice '   100.000 profissionais gerados em %', (t1 - t0);
  t0 := t1;

  raise notice '6. Atribuindo funções do catálogo aos profissionais (~200.000 vínculos)...';
  insert into public.profissional_funcao (profissional_id, funcao_id)
  select ('b0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         v_funcoes[(i % cardinality(v_funcoes)) + 1]
    from generate_series(1, 100000) i
  union all
  select ('b0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         v_funcoes[((i + 7) % cardinality(v_funcoes)) + 1]
    from generate_series(1, 100000) i
   where (i % cardinality(v_funcoes)) <> ((i + 7) % cardinality(v_funcoes))
  on conflict do nothing;
  t1 := clock_timestamp();
  raise notice '   profissional_funcao gerado em %', (t1 - t0);
  t0 := t1;

  raise notice '7. Gerando grade semanal de disponibilidade (~200.000 janelas)...';
  insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
  select ('b0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         (i % 7)::smallint,
         '18:00'::time,
         '02:00'::time
    from generate_series(1, 100000) i
  union all
  select ('b0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         ((i + 2) % 7)::smallint,
         '08:00'::time,
         '16:00'::time
    from generate_series(1, 100000) i
  on conflict do nothing;
  t1 := clock_timestamp();
  raise notice '   disponibilidade gerada em %', (t1 - t0);
  t0 := t1;

  raise notice '8. Gerando 20.000 vagas publicadas no DF em public.vaga...';
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
    responsavel_local, modo, estado, publicado_por, chave_cliente
  )
  select ('c0000000-0000-0000-0000-' || lpad(to_hex(i::bigint), 12, '0'))::uuid,
         ('e0000000-0000-0000-0000-' || lpad(to_hex((((i - 1) % 30000) + 1)::bigint), 12, '0'))::uuid,
         v_funcoes[(i % cardinality(v_funcoes)) + 1],
         '2026-10-01 18:00:00+00'::timestamptz + ((i % 14) || ' days')::interval + ((i % 5) || ' hours')::interval,
         '2026-10-01 18:00:00+00'::timestamptz + ((i % 14) || ' days')::interval + ((i % 5) || ' hours')::interval + interval '6 hours',
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
         ('a0000000-0000-0000-0000-' || lpad(to_hex((((i - 1) % 30000) + 1)::bigint), 12, '0'))::uuid,
         gen_random_uuid()
    from generate_series(1, 20000) i
  on conflict (id) do nothing;
  t1 := clock_timestamp();
  raise notice '   20.000 vagas geradas em %', (t1 - t0);
  t0 := t1;

  raise notice '9. Gerando 20.000 posições abertas em public.posicao...';
  insert into public.posicao (vaga_id, estado, inicio_em, fim_em)
  select v.id,
         'aberta',
         v.inicio_em,
         v.fim_em
    from public.vaga v
   where v.id >= 'c0000000-0000-0000-0000-000000000001'::uuid
     and v.id <= 'c0000000-0000-0000-0000-000000004e20'::uuid
  on conflict do nothing;
  t1 := clock_timestamp();
  raise notice '   20.000 posições abertas geradas em %', (t1 - t0);
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
