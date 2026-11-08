-- 822_lgpd_registro_acessos_borda.sql · LGPD-J6 R11 (migração 20261108110000).
-- Registro de acessos pelo IP da borda: o db_pre_request emite uma mensagem lógica na 1ª requisição de cada
-- (conta, cf-connecting-ip, hora), inclusive no GET; o consumidor grava a 1ª de cada balde; a limpeza de 6 meses
-- respeita a guarda legal (MCI art. 15, § 2º); a autoproteção derruba o slot acima do teto e registra o buraco.
begin;
-- Os slots de teste nascem antes de qualquer escrita (o Postgres exige) e são TEMPORÁRIOS: somem no fim da sessão,
-- mesmo se o arquivo cair no meio. O primeiro usa o nome real, para o pre-request e o consumidor o acharem.
select 1 from pg_create_logical_replication_slot('frila_registro_acesso', 'test_decoding', true);
select 1 from pg_create_logical_replication_slot('zz_822_extra', 'test_decoding', true);
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-08 12:10:00+00', true);
select plan(38);

delete from privado.registro_acesso;
delete from privado.falha_execucao where origem in ('consumir_registro_acesso', 'verificar_saude');

-- Uma requisição do PostgREST, como o pre-request a vê.
create function pg_temp.requisicao(p_conta text, p_cabecalhos jsonb, p_metodo text default 'GET', p_papel text default 'authenticated')
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_conta, 'role', p_papel)::text, true);
  perform set_config('request.headers', p_cabecalhos::text, true);
  perform set_config('request.method', p_metodo, true);
  perform requisicao.conferir_limite();
end $$;
-- Consome (e devolve) as mensagens do registro que estão no slot. O flush faz a mensagem sem fsync aparecer.
create function pg_temp.mensagens(p_prefixo text default 'frila_registro_acesso') returns setof text language plpgsql as $$
begin
  perform pg_logical_emit_message(false, 'zz_822_flush', 'x', true);
  return query
    select substr(d.data, strpos(d.data, ' content:') + 9)
      from pg_logical_slot_get_changes('frila_registro_acesso', null, null) d
     where starts_with(d.data, 'message: transactional: 0 prefix: ' || p_prefixo || ', sz: ');
end $$;
-- Espia sem consumir: o que ficar no slot é do consumidor.
create function pg_temp.espiar(p_prefixo text) returns setof text language plpgsql as $$
begin
  perform pg_logical_emit_message(false, 'zz_822_flush', 'x', true);
  return query
    select substr(d.data, strpos(d.data, ' content:') + 9)
      from pg_logical_slot_peek_changes('frila_registro_acesso', null, null) d
     where starts_with(d.data, 'message: transactional: 0 prefix: ' || p_prefixo || ', sz: ');
end $$;
create function pg_temp.flush() returns void language sql as $$
  select null::void from pg_logical_emit_message(false, 'zz_822_flush', 'x', true)
$$;
create function pg_temp.agora(p text) returns void language sql as $$
  select null::void from set_config('frila.agora', p, true)
$$;

-- ── Estrutura e privilégios ─────────────────────────────────────────────────
select columns_are('privado', 'registro_acesso', array['usuario_id', 'ip', 'acessado_em'],
  'registro: só conta, IP e data e hora (sem id, recurso, user_agent nem porta)');
select ok(not has_table_privilege('anon', 'privado.registro_acesso', 'select,insert,update,delete')
      and not has_table_privilege('authenticated', 'privado.registro_acesso', 'select,insert,update,delete')
      and not has_table_privilege('anon', 'privado.registro_acesso_recente', 'select,insert,update,delete')
      and not has_table_privilege('authenticated', 'privado.registro_acesso_recente', 'select,insert,update,delete')
      and not has_table_privilege('anon', 'privado.registro_acesso_coleta', 'select,insert,update,delete')
      and not has_table_privilege('authenticated', 'privado.registro_acesso_coleta', 'select,insert,update,delete'),
  'anon e authenticated não alcançam o registro, a deduplicação nem a chave');
select ok(has_table_privilege('service_role', 'privado.registro_acesso_guarda', 'insert')
      and not has_table_privilege('authenticated', 'privado.registro_acesso_guarda', 'select,insert,update,delete')
      and not has_table_privilege('anon', 'privado.registro_acesso_guarda', 'select,insert,update,delete'),
  'guarda legal: só o service_role escreve');
select ok((select bool_and(c.relrowsecurity) from pg_class c
            where c.oid in ('privado.registro_acesso'::regclass, 'privado.registro_acesso_recente'::regclass,
                            'privado.registro_acesso_coleta'::regclass, 'privado.registro_acesso_guarda'::regclass)),
  'RLS ligado nas quatro tabelas');
select ok(not has_function_privilege('authenticated', 'privado.consumir_registro_acesso(integer)', 'execute')
      and not has_function_privilege('authenticated', 'privado.definir_coleta_registro_acesso(boolean)', 'execute')
      and not has_function_privilege('anon', 'privado.proteger_slot_registro_acesso(text)', 'execute')
      and has_function_privilege('anon', 'requisicao.conferir_limite()', 'execute'),
  'só o service_role e o agendador mexem na coleta; o pre-request segue chamável pelo PostgREST');
select is((select ligada from privado.registro_acesso_coleta), false, 'a coleta nasce desligada');
select is((select teto_wal_mb from privado.registro_acesso_coleta), 128, 'teto de WAL padrão: 128 MB');
-- A chave tem uma linha só: a PK aceitaria unica = false; só o CHECK barra.
select throws_ok($$ insert into privado.registro_acesso_coleta (unica) values (false) $$, '23514', null,
  'a chave da coleta tem uma linha só (CHECK unica)');
-- A referência da guarda: de 1 a 80 caracteres depois do btrim. Período válido, para só esse CHECK barrar.
select throws_ok($$ insert into privado.registro_acesso_guarda (usuario_id, desde, ate, referencia)
                    values ('c8220000-0000-4000-8000-0000000000d1', '2026-11-01', '2026-12-01', '   ') $$, '23514', null,
  'guarda: referência vazia depois do btrim é recusada');
select throws_ok($$ insert into privado.registro_acesso_guarda (usuario_id, desde, ate, referencia)
                    values ('c8220000-0000-4000-8000-0000000000d1', '2026-11-01', '2026-12-01', repeat('x', 81)) $$, '23514', null,
  'guarda: referência com 81 caracteres é recusada');
select lives_ok($$ insert into privado.registro_acesso_guarda (usuario_id, desde, ate, referencia)
                   values ('c8220000-0000-4000-8000-0000000000d1', '2026-11-01', '2026-12-01', repeat('x', 80)) $$,
  'guarda: referência com 80 caracteres é aceita');

-- ── Pre-request com a coleta desligada: nada sai ────────────────────────────
select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000a', '{"cf-connecting-ip":"198.51.100.10"}');
select is((select count(*)::int from pg_temp.mensagens()), 0, 'coleta desligada: o GET não emite nada');

select is((privado.definir_coleta_registro_acesso(true) ->> 'slot')::boolean, true, 'ligar a coleta exige o slot');

-- ── Pre-request com a coleta ligada ─────────────────────────────────────────
select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000a', '{"cf-connecting-ip":"198.51.100.10"}');
select results_eq($$ select * from pg_temp.mensagens() $$,
  $$ values ('c8220000-0000-4000-8000-00000000000a 198.51.100.10 2026-11-08T12:10:00.000000Z'::text) $$,
  'GET autenticado emite conta, IP do cf-connecting-ip e data e hora em UTC');
select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000a', '{"cf-connecting-ip":"198.51.100.11"}', 'POST');
select is((select count(*)::int from pg_temp.mensagens()), 1, 'POST (escrita) também emite');
select pg_temp.requisicao(null, '{"cf-connecting-ip":"198.51.100.12"}', 'GET', 'anon');
select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000b', '{"cf-connecting-ip":"198.51.100.12"}', 'GET', 'service_role');
select is((select count(*)::int from pg_temp.mensagens()), 0, 'anon e service_role não entram no registro');
select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000a',
  '{"x-forwarded-for":"203.0.113.77, 198.51.100.13","true-client-ip":"203.0.113.78","x-real-ip":"203.0.113.79"}');
select is((select count(*)::int from pg_temp.mensagens()), 0,
  'sem cf-connecting-ip não emite: X-Forwarded-For, true-client-ip e x-real-ip nunca valem');
select lives_ok($$ select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000a', '{"cf-connecting-ip":"nao-e-ip"}') $$,
  'cf-connecting-ip inválido: a requisição segue');
select is((select count(*)::int from pg_temp.mensagens()), 0, 'e nada é emitido');

-- Registro quebrado: a requisição segue, o limite de escrita segue contando, e a falha vira mensagem sem dado pessoal.
alter table privado.registro_acesso_recente rename to registro_acesso_recente_fora;
delete from privado.escrita_por_conta where usuario_id = 'c8220000-0000-4000-8000-00000000000a';
select lives_ok($$ select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000a', '{"cf-connecting-ip":"198.51.100.14"}', 'POST') $$,
  'registro quebrado não derruba a requisição');
select is((select contagem from privado.escrita_por_conta where usuario_id = 'c8220000-0000-4000-8000-00000000000a'), 1,
  'e o limite de escrita conta normalmente');
select results_eq($$ select * from pg_temp.espiar('frila_registro_acesso_falha') $$, $$ values ('42P01'::text) $$,
  'a falha sai como mensagem só com o SQLSTATE');
alter table privado.registro_acesso_recente_fora rename to registro_acesso_recente;

-- ── O consumidor ────────────────────────────────────────────────────────────
-- 12:10 A/.20 · 12:30 A/.20 de novo · 12:20 A/.21 (troca de IP) · 12:15 B/.20 · 13:05 A/.20 (hora seguinte)
select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000a', '{"cf-connecting-ip":"198.51.100.20"}');
select pg_temp.agora('2026-11-08 12:30:00+00');
select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000a', '{"cf-connecting-ip":"198.51.100.20"}');
select pg_temp.agora('2026-11-08 12:20:00+00');
select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000a', '{"cf-connecting-ip":"198.51.100.21"}');
select pg_temp.agora('2026-11-08 12:15:00+00');
select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000b', '{"cf-connecting-ip":"198.51.100.20"}');
select pg_temp.agora('2026-11-08 13:05:00+00');
select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000a', '{"cf-connecting-ip":"198.51.100.20"}');
select pg_temp.flush();
-- UMA chamada do consumidor por sessão, como no pg_cron (uma conexão por rodada). Com o plpgsql_check pré-carregado
-- (padrão da imagem do Supabase), a 2ª chamada na mesma sessão cai com "cannot find parent statement on pldbgapi2
-- call stack" (medido em 08/11/2026). Por isso o teto do slot, que chama o consumidor de novo, está no 824.
select is((privado.consumir_registro_acesso() ->> 'consumidas')::int, 5, 'o consumidor leu as 5 mensagens');
select results_eq($$ select usuario_id::text, host(ip), acessado_em from privado.registro_acesso order by 1, 3 $$,
  $$ values ('c8220000-0000-4000-8000-00000000000a', '198.51.100.20', '2026-11-08 12:10:00+00'::timestamptz),
            ('c8220000-0000-4000-8000-00000000000a', '198.51.100.21', '2026-11-08 12:20:00+00'::timestamptz),
            ('c8220000-0000-4000-8000-00000000000a', '198.51.100.20', '2026-11-08 13:05:00+00'::timestamptz),
            ('c8220000-0000-4000-8000-00000000000b', '198.51.100.20', '2026-11-08 12:15:00+00'::timestamptz) $$,
  'uma linha por (conta, IP, hora), com o PRIMEIRO uso do balde; troca de IP na mesma hora gera linha nova');
select is((select consumido_em from privado.registro_acesso_coleta), '2026-11-08 13:05:00+00'::timestamptz,
  'e carimbou o último consumo');

-- Depois de gravado, o pre-request deduplica: a mesma conta e IP na mesma hora não emite de novo.
select pg_temp.agora('2026-11-08 13:40:00+00');
select pg_temp.requisicao('c8220000-0000-4000-8000-00000000000a', '{"cf-connecting-ip":"198.51.100.20"}');
select is((select count(*)::int from pg_temp.espiar('frila_registro_acesso')), 0,
  'mesma conta, IP e hora já gravados: o pre-request não emite de novo');
select ok(exists (select 1 from privado.registro_acesso_recente
                   where usuario_id = 'c8220000-0000-4000-8000-00000000000a' and host(ip) = '198.51.100.20'
                     and balde = '2026-11-08 13:00:00+00'),
  'porque o consumidor marcou (conta, IP, hora) em registro_acesso_recente');

-- A falha do pre-request (acima) virou registro em falha_execucao, sem dado pessoal.
select results_eq($$ select codigo, detalhes ->> 'ultimo_sqlstate', detalhes::text !~ '198\.51|c8220000'
                       from privado.falha_execucao where origem = 'consumir_registro_acesso' and codigo = 'registro_acesso_falhou' $$,
  $$ values ('registro_acesso_falhou'::text, '42P01'::text, true) $$,
  'a falha engolida pelo pre-request vira falha_execucao, só com o SQLSTATE');

-- ── Limpeza de 6 meses com a guarda legal ───────────────────────────────────
delete from privado.registro_acesso;
select pg_temp.agora('2026-11-08 12:00:00+00');
insert into privado.registro_acesso (usuario_id, ip, acessado_em) values
  ('c8220000-0000-4000-8000-0000000000c1', '198.51.100.31', '2026-11-08 12:00:00+00'::timestamptz - interval '7 months'),
  ('c8220000-0000-4000-8000-0000000000c2', '198.51.100.32', '2026-11-08 12:00:00+00'::timestamptz - interval '7 months'),
  ('c8220000-0000-4000-8000-0000000000c3', '198.51.100.33', '2026-11-08 12:00:00+00'::timestamptz - interval '7 months'),
  ('c8220000-0000-4000-8000-0000000000c4', '198.51.100.34', '2026-11-08 12:00:00+00'::timestamptz - interval '7 months'),
  ('c8220000-0000-4000-8000-0000000000c2', '198.51.100.35', '2026-11-08 12:00:00+00'::timestamptz - interval '6 months' + interval '1 day'),
  ('c8220000-0000-4000-8000-0000000000c2', '198.51.100.36', '2026-11-08 12:00:00+00'::timestamptz - interval '6 months' - interval '1 day');
insert into privado.registro_acesso_guarda (usuario_id, desde, ate, referencia) values
  ('c8220000-0000-4000-8000-0000000000c1', '2026-10-01', '2027-01-01', 'OF-822-1'),   -- vigente
  ('c8220000-0000-4000-8000-0000000000c3', '2026-01-01', '2026-06-01', 'OF-822-3'),   -- vencida
  ('c8220000-0000-4000-8000-0000000000c4', '2026-12-01', '2027-03-01', 'OF-822-4');   -- ainda não começou
select is(privado.limpar_registros_acesso(1, 1000), 4, 'p_meses = 1 vale como 6: saem 4 linhas');
select ok(exists (select 1 from privado.registro_acesso where usuario_id = 'c8220000-0000-4000-8000-0000000000c1'),
  'conta em guarda vigente: a linha de 7 meses fica (MCI art. 15, § 2º)');
select ok(not exists (select 1 from privado.registro_acesso
                       where usuario_id in ('c8220000-0000-4000-8000-0000000000c3', 'c8220000-0000-4000-8000-0000000000c4')),
  'guarda vencida, ou que ainda não começou: a linha de 7 meses sai');
select results_eq($$ select host(ip) from privado.registro_acesso where usuario_id = 'c8220000-0000-4000-8000-0000000000c2' $$,
  $$ values ('198.51.100.35'::text) $$,
  'outra conta: sai a de 6 meses e 1 dia e a de 7, fica a de 6 meses menos 1 dia');
insert into privado.registro_acesso (usuario_id, ip, acessado_em)
select 'c8220000-0000-4000-8000-0000000000c5', '198.51.100.40', '2026-11-08 12:00:00+00'::timestamptz - interval '7 months' - n * interval '1 second'
  from generate_series(1, 150) n;
select is(privado.limpar_registros_acesso(6, 1), 100, 'teto de 100 lotes por execução');
select throws_ok($$ insert into privado.registro_acesso_guarda (usuario_id, desde, ate, referencia)
                    values ('c8220000-0000-4000-8000-0000000000c6', '2026-12-01', '2026-11-01', 'OF-822-6') $$,
  '23514', null, 'a guarda precisa de fim depois do início');

-- ── Coleta desligada derruba o slot (no slot extra, para os casos seguintes) ─
create or replace function privado.slot_registro_acesso() returns text language sql immutable set search_path = '' as $$
  select 'zz_822_extra'::text $$;
select is((privado.definir_coleta_registro_acesso(false) ->> 'slot')::boolean, false, 'desligar a coleta derruba o slot');
select ok(not exists (select 1 from pg_replication_slots where slot_name = 'zz_822_extra'), 'sem coleta, nenhum slot retém WAL');
create or replace function privado.slot_registro_acesso() returns text language sql immutable set search_path = '' as $$
  select 'frila_registro_acesso'::text $$;
select privado.definir_coleta_registro_acesso(true);

-- ── verificar_saude: consumidor parado e atraso do slot ─────────────────────
delete from privado.alerta_emitido where codigo like 'registro_acesso_%';
update privado.registro_acesso_coleta set consumido_em = privado.agora() - interval '20 minutes';
select privado.verificar_saude();
select ok(exists (select 1 from privado.alerta_emitido where codigo = 'registro_acesso_parado'),
  'consumidor parado há mais de 15 minutos: alerta registro_acesso_parado');

-- ── Agendamento ─────────────────────────────────────────────────────────────
select results_eq($$ select schedule, command from cron.job where jobname = 'consumir_registro_acesso' $$,
  $$ values ('* * * * *'::text, 'select privado.consumir_registro_acesso()'::text) $$,
  'o consumidor roda a cada minuto');

select * from finish();
rollback;
