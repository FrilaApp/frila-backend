-- 723_rls_anon_sem_select.sql
--
-- Cobertura de Row Level Security (RLS) e Privilegios para o papel anon (Top 10 do Mapa RLS):
--   Diretriz de Seguranca:
--     "revoke all on all tables in schema public from anon;"
--
-- Casos cobertos:
--   1. Rejeicao estrita de SELECT em todas as 22 tabelas do schema public sob papel anon:
--      - usuario, profissional, estabelecimento, membro_estabelecimento, equipe_confianca;
--      - funcao, profissional_funcao, disponibilidade, evento, vaga, posicao, candidatura;
--      - turno, avaliacao, bloqueio, despacho, notificacao, dispositivo, ocorrencia;
--      - pedido_de_exclusao, evento_app, entrada_demonstracao.
--      - Cada tentativa levanta SQLSTATE 42501 com mensagem "permission denied for table <t>".
--   2. Verificacao de Catalogo:
--      - role_table_grants para grantee = 'anon' no schema public e exatamente ZERO;
--      - Nenhuma tabela do schema public possui relrowsecurity desativado.
--   3. Prova de Mutacao Real:
--      - Mutante com concessao indevida (grant select on public.funcao to anon):
--        comprova que anon passaria e que o throws_ok nao e falso-positivo de sintaxe;
--      - Restauracao com revoke e revalidacao completa de bloqueio.

begin;
select plan(28);

insert into privado.ambiente (id, eh_teste) values (true, true)
  on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-25 12:00:00+00';
set local frila.agendador_secret = 'teste-segredo-723';

-- ── 1. Auxiliares ──────────────────────────────────────────────────────────────

create function pg_temp.como(papel text, sql text) returns void
language plpgsql as $$
begin
  execute format('set local role %I', papel);
  execute sql;
  reset role;
end $$;

-- ── 2. Catalogo e Concessoes ───────────────────────────────────────────────────

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'),
  0,
  'papel anon possui exatamente 0 concessoes de privilegio em tabelas de public'
);

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0,
  'todas as tabelas do schema public possuem Row Level Security ativo'
);

-- ── 3. Tentativas de SELECT direto pelo papel anon nas 22 tabelas ───────────────

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.usuario') $$,
  '42501',
  'permission denied for table usuario',
  'anon recebe 42501 em SELECT direto em public.usuario'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.profissional') $$,
  '42501',
  'permission denied for table profissional',
  'anon recebe 42501 em SELECT direto em public.profissional'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.estabelecimento') $$,
  '42501',
  'permission denied for table estabelecimento',
  'anon recebe 42501 em SELECT direto em public.estabelecimento'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.membro_estabelecimento') $$,
  '42501',
  'permission denied for table membro_estabelecimento',
  'anon recebe 42501 em SELECT direto em public.membro_estabelecimento'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.equipe_confianca') $$,
  '42501',
  'permission denied for table equipe_confianca',
  'anon recebe 42501 em SELECT direto em public.equipe_confianca'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.funcao') $$,
  '42501',
  'permission denied for table funcao',
  'anon recebe 42501 em SELECT direto em public.funcao'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.profissional_funcao') $$,
  '42501',
  'permission denied for table profissional_funcao',
  'anon recebe 42501 em SELECT direto em public.profissional_funcao'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.disponibilidade') $$,
  '42501',
  'permission denied for table disponibilidade',
  'anon recebe 42501 em SELECT direto em public.disponibilidade'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.evento') $$,
  '42501',
  'permission denied for table evento',
  'anon recebe 42501 em SELECT direto em public.evento'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.vaga') $$,
  '42501',
  'permission denied for table vaga',
  'anon recebe 42501 em SELECT direto em public.vaga'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.posicao') $$,
  '42501',
  'permission denied for table posicao',
  'anon recebe 42501 em SELECT direto em public.posicao'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.candidatura') $$,
  '42501',
  'permission denied for table candidatura',
  'anon recebe 42501 em SELECT direto em public.candidatura'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.turno') $$,
  '42501',
  'permission denied for table turno',
  'anon recebe 42501 em SELECT direto em public.turno'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.avaliacao') $$,
  '42501',
  'permission denied for table avaliacao',
  'anon recebe 42501 em SELECT direto em public.avaliacao'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.bloqueio') $$,
  '42501',
  'permission denied for table bloqueio',
  'anon recebe 42501 em SELECT direto em public.bloqueio'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.despacho') $$,
  '42501',
  'permission denied for table despacho',
  'anon recebe 42501 em SELECT direto em public.despacho'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.notificacao') $$,
  '42501',
  'permission denied for table notificacao',
  'anon recebe 42501 em SELECT direto em public.notificacao'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.dispositivo') $$,
  '42501',
  'permission denied for table dispositivo',
  'anon recebe 42501 em SELECT direto em public.dispositivo'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.ocorrencia') $$,
  '42501',
  'permission denied for table ocorrencia',
  'anon recebe 42501 em SELECT direto em public.ocorrencia'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.pedido_de_exclusao') $$,
  '42501',
  'permission denied for table pedido_de_exclusao',
  'anon recebe 42501 em SELECT direto em public.pedido_de_exclusao'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.evento_app') $$,
  '42501',
  'permission denied for table evento_app',
  'anon recebe 42501 em SELECT direto em public.evento_app'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.entrada_demonstracao') $$,
  '42501',
  'permission denied for table entrada_demonstracao',
  'anon recebe 42501 em SELECT direto em public.entrada_demonstracao'
);

-- ── 4. Prova de Mutacao Real ──────────────────────────────────────────────────

-- Mutacao: conceder SELECT indevidamente para anon
grant select on public.funcao to anon;

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'),
  1,
  'mutante com grant select reflete exatamente 1 concessao no catalogo'
);

select lives_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.funcao') $$,
  'mutante com grant select: comprova que anon passaria e que throws_ok discrimina'
);

-- Restauracao: revogar e revalidar bloqueio
revoke select on public.funcao from anon;

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'),
  0,
  'restauracao: apos REVOKE, role_table_grants volta a ser exatamente zero'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.funcao') $$,
  '42501',
  'permission denied for table funcao',
  'restauracao: apos REVOKE, anon volta a ser sumariamente bloqueado com 42501'
);

select * from finish();
rollback;
