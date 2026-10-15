-- 672_mutantes_sobreviventes_ciclo_e_texto.sql
--
-- Cobertura de testes pgTAP para os mutantes comportamentais sobreviventes
-- identificados no relatório de mutação (MUTACAO-15-10.md):
--
-- 1. Mutante 4 (RN23 / RNF13): Despachos represados pelo teto em vagas canceladas.
--    - liberar_teto_do_profissional não emite notificação para vaga inativa.
--    - verificar_saude não dispara falso alerta despacho_esperando_alem_do_teto.
--    - Despacho mantém notificacao_id nulo de forma imutável e segura.
--
-- 2. Mutante 5 (RN07 / #181): Janela retroativa de 7 dias em fechar_turnos_e_vagas.
--    - Turno concluído dentro da janela (5 dias atrás) gera notificacao avaliacao_disponivel.
--    - Turno concluído além da janela (8 dias atrás) transita posição para cumprida
--      sem emitir avaliacao_disponivel obsoleta (RN07).
--
-- 3. Mutante 6 (RN10 / #179 / J5): Moderação de contato em texto livre com separadores combinados.
--    - Detecção com barras, pontos, traços, parênteses e espaços misturados.
--    - Preservação estrita de falsos positivos legítimos (horário, data, valor, CEP).
--    - Recusa com 422 campo_invalido em publicar_vaga.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(12);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-10-15 12:00:00-03', true);

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create temp table ids as
select
  'c6720000-0000-4000-8000-000000000001'::uuid as prof_user,
  'c6720000-0000-4000-8000-000000000002'::uuid as contratante_user,
  'c6720000-0000-4000-8000-000000000011'::uuid as profissional,
  'c6720000-0000-4000-8000-000000000021'::uuid as estabelecimento,
  -- Mutante 4
  'c6720000-0000-4000-8000-000000000031'::uuid as vaga_mut4,
  'c6720000-0000-4000-8000-000000000041'::uuid as pos_mut4,
  'c6720000-0000-4000-8000-000000000061'::uuid as despacho_mut4,
  -- Mutante 5
  'c6720000-0000-4000-8000-000000000032'::uuid as vaga_mut5_dentro,
  'c6720000-0000-4000-8000-000000000042'::uuid as pos_mut5_dentro,
  'c6720000-0000-4000-8000-000000000052'::uuid as turno_mut5_dentro,
  'c6720000-0000-4000-8000-000000000033'::uuid as vaga_mut5_fora,
  'c6720000-0000-4000-8000-000000000043'::uuid as pos_mut5_fora,
  'c6720000-0000-4000-8000-000000000053'::uuid as turno_mut5_fora;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select prof_user, 'profissional'::public.perfil_conta, 'Profissional Mutantes',
       '+5561999990071', 'prof-mut@test.invalid', '1992-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids
union all
select contratante_user, 'contratante'::public.perfil_conta, 'Casa Mutantes',
       '+5561999990072', 'casa-mut@test.invalid', '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids;

insert into public.profissional (id, usuario_id, ponto_base)
select profissional, prof_user, 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.profissional_funcao (profissional_id, funcao_id)
select profissional, (select id from public.funcao limit 1)
  from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select estabelecimento, 'Casa Mutantes', '80000000000672', 'food_service',
       'Endereco Mutantes', 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select contratante_user, estabelecimento, 'administrador'
  from ids;

select pg_temp.autenticar((select contratante_user from ids), 'casa-mut@test.invalid');

-- ── 1. Mutante 4: Despacho sob teto de vaga cancelada ─────────────────────────

insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
)
select vaga_mut4, estabelecimento, (select id from public.funcao limit 1),
       '2026-10-15 18:00:00-03', '2026-10-15 23:00:00-03',
       'Local Mut4', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada',
       '2026-10-15 10:00:00-03', gen_random_uuid(), contratante_user
  from ids;

insert into public.despacho (id, vaga_id, profissional_id, notificacao_id, criado_em, rodada)
select despacho_mut4, vaga_mut4, profissional, null,
       '2026-10-15 11:10:00-03', 1
  from ids;

-- Vaga é cancelada antes de vencer a janela do teto
update public.vaga set estado = 'cancelada' where id = (select vaga_mut4 from ids);

-- Liberação de teto não deve emitir notificação para vaga inativa
select is(
  privado.liberar_teto_do_profissional((select profissional from ids)),
  null,
  'Mutante 4: liberar_teto_do_profissional não despacha notificação para vaga cancelada'
);

-- Limpa filas de alerta para checagem estrita de saúde
truncate table pgmq.q_email;
truncate table privado.alerta_emitido;

select privado.verificar_saude();

select is(
  (select count(*)::int from pgmq.q_email where message->>'codigo' = 'despacho_esperando_alem_do_teto'),
  0,
  'Mutante 4: Despacho sob teto de vaga cancelada não gera falso alarme em verificar_saude'
);

select is(
  (select notificacao_id from public.despacho where id = (select despacho_mut4 from ids)),
  null,
  'Mutante 4: Despacho preserva estado original com notificacao_id nulo de forma imutável'
);

-- ── 2. Mutante 5: Janela retroativa de 7 dias em fechar_turnos_e_vagas ──────────

-- Cenário 5A: Turno cumprido e verificado há 5 dias (dentro dos 7 dias)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
)
select vaga_mut5_dentro, estabelecimento, (select id from public.funcao limit 1),
       '2026-10-10 12:00:00-03', '2026-10-10 18:00:00-03',
       'Local Mut5 A', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       16000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada',
       '2026-10-09 10:00:00-03', gen_random_uuid(), contratante_user
  from ids;

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select pos_mut5_dentro, vaga_mut5_dentro, 'confirmada', profissional, '2026-10-09 11:00:00-03',
       '2026-10-10 12:00:00-03', '2026-10-10 18:00:00-03'
  from ids;

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, checkout_em, verificacao, valor_acordado_centavos)
select turno_mut5_dentro, pos_mut5_dentro,
       '2026-10-10 11:55:00-03', 'geolocalizado'::public.tipo_registro, 50,
       '2026-10-10 18:05:00-03', 'verificado'::public.verificacao_turno, 16000
  from ids;

-- Cenário 5B: Turno cumprido e verificado há 8 dias (fora da janela de 7 dias)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
)
select vaga_mut5_fora, estabelecimento, (select id from public.funcao limit 1),
       '2026-10-07 12:00:00-03', '2026-10-07 18:00:00-03',
       'Local Mut5 B', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       16000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada',
       '2026-10-06 10:00:00-03', gen_random_uuid(), contratante_user
  from ids;

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select pos_mut5_fora, vaga_mut5_fora, 'confirmada', profissional, '2026-10-06 11:00:00-03',
       '2026-10-07 12:00:00-03', '2026-10-07 18:00:00-03'
  from ids;

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, checkout_em, verificacao, valor_acordado_centavos)
select turno_mut5_fora, pos_mut5_fora,
       '2026-10-07 11:55:00-03', 'geolocalizado'::public.tipo_registro, 50,
       '2026-10-07 18:05:00-03', 'verificado'::public.verificacao_turno, 16000
  from ids;

-- Executa o fechamento de turnos e vagas
select privado.fechar_turnos_e_vagas();

-- 5A: Notificação avaliacao_disponivel emitida para turno recente (5 dias)
select is(
  (select count(*)::int from public.notificacao
    where tipo = 'avaliacao_disponivel' and referencia_id = (select turno_mut5_dentro from ids)),
  2,
  'Mutante 5: Turno cumprido dentro da janela de 7 dias gera avaliacao_disponivel para ambos os lados'
);

select is(
  (select estado from public.posicao where id = (select pos_mut5_dentro from ids)),
  'cumprida',
  'Mutante 5: Posição recente é concluída como cumprida'
);

-- 5B: Turno fora da janela (8 dias) NÃO emite notificação obsoleta (RN07)
select is(
  (select count(*)::int from public.notificacao
    where tipo = 'avaliacao_disponivel' and referencia_id = (select turno_mut5_fora from ids)),
  0,
  'Mutante 5: Turno fora da janela de 7 dias não recebe notificacao de avaliacao_disponivel'
);

select is(
  (select estado from public.posicao where id = (select pos_mut5_fora from ids)),
  'cumprida',
  'Mutante 5: Posição com mais de 7 dias transita para cumprida sem travar o fechamento'
);

-- ── 3. Mutante 6: Moderação de Texto Livre (#179 / RN10 / J5) ─────────────────

-- Detecção de telefone com múltiplos separadores combinados (barras, hífens, pontos, parênteses)
select ok(
  privado.contem_contato_ou_link('chame no 61/98765-4321'),
  'Mutante 6: Telefone com barra e hífen combinados é detectado'
);

select ok(
  privado.contem_contato_ou_link('(61) 9.8765/4321 falar com Carlos'),
  'Mutante 6: Telefone com parênteses, ponto e barra é detectado'
);

select ok(
  not privado.contem_contato_ou_link('Turno das 18h às 23h30 pagamento R$ 150,00 na data 20/10/2026'),
  'Mutante 6: Horários, valores monetários e datas legítimas continuam passando normalmente'
);

-- Teste de integração: publicar_vaga recusa texto camuflado com 422 campo_invalido
select throws_ok(
  format('select pg_temp.como(%L, %L)',
    (select contratante_user from ids),
    format($$
      select public.publicar_vaga(
        estabelecimento_id => %L::uuid,
        funcao_id => (select id from public.funcao limit 1),
        inicio_em => '2026-10-16 18:00:00-03'::timestamptz,
        fim_em => '2026-10-16 23:00:00-03'::timestamptz,
        local => 'CLN 105',
        ponto => '{"latitude":-15.7700,"longitude":-47.8800}'::jsonb,
        valor_centavos => 15000::bigint,
        posicoes => 1,
        inclui_refeicao => false,
        inclui_transporte => false,
        exige_material_proprio => false,
        responsavel_local => 'Gerente',
        modo => 'urgencia'::public.modo_preenchimento,
        chave => gen_random_uuid(),
        traje => 'Camisa preta',
        observacoes => 'Dúvidas no 61/98765-4321'
      )
    $$, (select estabelecimento from ids))),
  'PGRST',
  pg_temp.erro('campo_invalido', 'observacoes'),
  'Mutante 6: publicar_vaga recusa criação com telefone camuflado em observações'
);

-- Teste de integração positivo: publicar_vaga aceita horário, data e valor legítimos
select ok(
  (pg_temp.como(
    (select contratante_user from ids),
    format($$
      select public.publicar_vaga(
        estabelecimento_id => %L::uuid,
        funcao_id => (select id from public.funcao limit 1),
        inicio_em => '2026-10-16 18:00:00-03'::timestamptz,
        fim_em => '2026-10-16 23:00:00-03'::timestamptz,
        local => 'CLN 105',
        ponto => '{"latitude":-15.7700,"longitude":-47.8800}'::jsonb,
        valor_centavos => 15000::bigint,
        posicoes => 1,
        inclui_refeicao => false,
        inclui_transporte => false,
        exige_material_proprio => false,
        responsavel_local => 'Gerente',
        modo => 'urgencia'::public.modo_preenchimento,
        chave => gen_random_uuid(),
        traje => 'Camisa preta',
        observacoes => 'Disponível de 18h às 23h30 na data 20/10/2026 valor R$ 150,00'
      )
    $$, (select estabelecimento from ids)))->>'vaga_id') is not null,
  'Mutante 6: publicar_vaga aceita observações com horários, datas e valores legítimos'
);

select * from finish();
rollback;
