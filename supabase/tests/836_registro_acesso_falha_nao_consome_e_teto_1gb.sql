-- Teste pgTAP: supabase/tests/836_registro_acesso_falha_nao_consome_e_teto_1gb.sql
-- Migrações: 20261108110000 (#449) e 20261108233000 (B-449-NIT).
-- (1) Se a gravação falhar, nada é consumido (O-1 do Lince Codex no #449). Com um gatilho que derruba o insert em
--     privado.registro_acesso, a rodada devolve P0001 e consome 0; as mensagens ficam INTACTAS no slot, e nem o balde
--     de deduplicação nem o consumido_em andam. O mutante MX1 (consumir com pg_logical_slot_get_changes antes de gravar,
--     sem peek e sem avanço) esvazia o slot e morre aqui.
--     A rodada seguinte, que grava as mesmas mensagens, não cabe neste arquivo: o consumidor só pode ser chamado UMA vez
--     por sessão (ver o 822; o pg_cron abre uma conexão por rodada). Que uma rodada boa grava estas mensagens, o 822 prova.
-- (2) Os comentários da chave e de definir_coleta_registro_acesso dizem o teto real do servidor no Prod (1 GB, o mínimo
--     que o Supabase aceita) e o porquê certo: acima dele, o servidor invalida o slot antes de a autoproteção agir.
begin;
-- O slot de teste nasce antes de qualquer escrita (o Postgres exige), TEMPORÁRIO e com o nome real.
select 1 from pg_create_logical_replication_slot('frila_registro_acesso', 'test_decoding', true);
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-08 12:10:00+00', true);
select plan(11);

delete from privado.registro_acesso;
delete from privado.registro_acesso_recente;
delete from privado.falha_execucao where origem = 'consumir_registro_acesso';

-- Uma requisição do PostgREST, como o pre-request a vê (o mesmo auxiliar do 822).
create function pg_temp.requisicao(p_conta text, p_cabecalhos jsonb) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_conta, 'role', 'authenticated')::text, true);
  perform set_config('request.headers', p_cabecalhos::text, true);
  perform set_config('request.method', 'GET', true);
  perform requisicao.conferir_limite();
end $$;
-- Espia sem consumir. O flush faz a mensagem sem fsync aparecer.
create function pg_temp.espiar() returns setof text language plpgsql as $$
begin
  perform pg_logical_emit_message(false, 'zz_836_flush', 'x', true);
  return query
    select substr(d.data, strpos(d.data, ' content:') + 9)
      from pg_logical_slot_peek_changes('frila_registro_acesso', null, null) d
     where starts_with(d.data, 'message: transactional: 0 prefix: frila_registro_acesso, sz: ');
end $$;

-- ── (1) Gravação que falha não consome ──────────────────────────────────────
select is((privado.definir_coleta_registro_acesso(true) ->> 'slot')::boolean, true, 'coleta ligada, com o slot');
select pg_temp.requisicao('c8360000-0000-4000-8000-00000000000a', '{"cf-connecting-ip":"198.51.100.40"}');
select pg_temp.requisicao('c8360000-0000-4000-8000-00000000000b', '{"cf-connecting-ip":"198.51.100.41"}');
select is((select count(*)::int from pg_temp.espiar()), 2, 'duas mensagens no slot antes da rodada');
create temp table zz_836_antes as select consumido_em from privado.registro_acesso_coleta where unica;

-- O gatilho derruba toda gravação no registro (desfeito no rollback deste arquivo).
create function privado.zz_836_derruba() returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'zz_836_gravacao_derrubada';
end $$;
create trigger zz_836_derruba before insert on privado.registro_acesso
  for each row execute function privado.zz_836_derruba();

create temp table zz_836_rodada as select privado.consumir_registro_acesso() as r;
select is((select (r ->> 'consumidas')::int from zz_836_rodada), 0, 'com a gravação derrubada, a rodada não consome nada');
select is((select r ->> 'sqlstate' from zz_836_rodada), 'P0001', 'e devolve o SQLSTATE da falha (P0001)');
select is((select count(*)::int from privado.registro_acesso), 0, 'nenhuma linha gravada no registro');
select is((select count(*)::int from privado.registro_acesso_recente), 0,
  'nenhum balde marcado: a marcação de deduplicação volta junto com a gravação');
select results_eq($$ select * from pg_temp.espiar() order by 1 $$,
  $$ values ('c8360000-0000-4000-8000-00000000000a 198.51.100.40 2026-11-08T12:10:00.000000Z'::text),
            ('c8360000-0000-4000-8000-00000000000b 198.51.100.41 2026-11-08T12:10:00.000000Z'::text) $$,
  'as 2 mensagens seguem no slot, intactas, para a rodada seguinte');
select is((select consumido_em from privado.registro_acesso_coleta where unica), (select consumido_em from zz_836_antes),
  'o consumido_em não anda: não houve consumo');
select results_eq($$ select codigo, detalhes ->> 'sqlstate' from privado.falha_execucao
                      where origem = 'consumir_registro_acesso' $$,
  $$ values ('registro_acesso_consumo_falhou'::text, 'P0001'::text) $$,
  'a falha vira registro_acesso_consumo_falhou em falha_execucao, só com o SQLSTATE');

-- ── (2) O teto real do servidor nos comentários ─────────────────────────────
select ok(obj_description('privado.registro_acesso_coleta'::regclass, 'pg_class') like '%max_slot_wal_keep_size%1 GB%'
      and obj_description('privado.registro_acesso_coleta'::regclass, 'pg_class')
            like '%o servidor invalida o slot (lost) antes de a autoproteção agir, e o intervalo se perde%'
      and obj_description('privado.registro_acesso_coleta'::regclass, 'pg_class') not like '%256 MB%'
      and obj_description('privado.registro_acesso_coleta'::regclass, 'pg_class') not like '%confirmed_flush_lsn%',
  'a chave diz o teto do servidor de 1 GB e o porquê certo (invalidação antes da autoproteção)');
select ok(obj_description('privado.definir_coleta_registro_acesso(boolean)'::regprocedure, 'pg_proc')
            like '%max_slot_wal_keep_size de 1 GB%'
      and obj_description('privado.definir_coleta_registro_acesso(boolean)'::regprocedure, 'pg_proc') not like '%256 MB%',
  'definir_coleta_registro_acesso diz o teto do servidor de 1 GB');

select * from finish();
rollback;
