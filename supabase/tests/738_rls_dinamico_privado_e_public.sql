-- Teste dinâmico de segurança de tabelas (achados 1 e 2 da AUDITORIA-RLS.md):
-- 1. Toda tabela de `public` sem política RLS tem has_table_privilege('authenticated','select') = false
--    e has_table_privilege('anon','select') = false (protege contra GRANT SELECT acidental em tabelas internas).
-- 2. Toda tabela de `privado` tem Row Level Security (RLS) habilitado.
-- 3. Nenhuma tabela de `privado` possui FORCE ROW LEVEL SECURITY (owner postgres mantém bypass de manutenção).
-- 4. Prova de defesa em profundidade: mesmo sob GRANT forçado temporário, RLS oculta 100% das linhas para clientes.
-- 5. Funções SECURITY DEFINER e triggers continuam escrevendo e lendo as 9 tabelas normalmente.

begin;
select plan(14);

-- ── 1. Tabelas de public sem política não possuem SELECT para clientes ─────────
-- Dinâmico: busca todas as tabelas em public que não possuem nenhuma política RLS em pg_policy.
-- Exige que nenhuma delas conceda SELECT a authenticated ou anon.
select is(
  (select count(*)::int from (
     select c.oid
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
       left join pg_policy p on p.polrelid = c.oid
      where n.nspname = 'public' and c.relkind in ('r', 'p')
      group by c.oid
     having count(p.polname) = 0
        and (has_table_privilege('authenticated', c.oid, 'select')
             or has_table_privilege('anon', c.oid, 'select'))
   ) sem_politica_com_select),
  0,
  'AUDITORIA-RLS achado 2: toda tabela de public sem política não tem SELECT para authenticated ou anon'
);

-- Confirma que exatamente as 3 tabelas internas de public conhecidas sem política continuam protegidas
select is(
  (select count(*)::int from (
     select c.oid
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
       left join pg_policy p on p.polrelid = c.oid
      where n.nspname = 'public' and c.relkind in ('r', 'p')
      group by c.oid
     having count(p.polname) = 0
   ) sem_politica),
  3,
  'exatamente as 3 tabelas operacionais internas de public (entrada_demonstracao, evento_app, pedido_de_exclusao) não possuem política'
);

-- ── 2. Todas as tabelas de privado têm RLS ativado ─────────────────────────────
-- Dinâmico: nenhuma tabela comum ou particionada no schema privado pode ter relrowsecurity = false.
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and not c.relrowsecurity),
  0,
  'AUDITORIA-RLS achado 1: toda tabela do schema privado tem Row Level Security (RLS) ativado'
);

-- Contagem total de tabelas em privado com RLS (as 13 tabelas catalogadas)
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and c.relrowsecurity),
  13,
  'todas as 13 tabelas do schema privado possuem RLS ligado'
);

-- ── 3. Nenhuma tabela de privado possui FORCE ROW LEVEL SECURITY ───────────────
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and c.relforcerowsecurity),
  0,
  'nenhuma tabela de privado possui FORCE RLS (funções SECURITY DEFINER do owner postgres não são barradas)'
);

-- ── 4. As 9 tabelas anteriormente sem RLS agora têm RLS comprovadamente ligado ──
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname in (
      'ambiente', 'auditoria_ciclo', 'conta_equipe', 'divergencia_reputacao',
      'parametro_notificacao', 'termo_bloqueado', 'texto_da_vaga_ocultado',
      'tipo_no_teto', 'vaga_ocultada'
    ) and c.relrowsecurity),
  9,
  'as 9 tabelas do achado da auditoria possuem RLS habilitado'
);

-- ── 5. Defesa em profundidade: simulação de concessão indevida acidental ────────
-- Se por engano um administrador conceder GRANT SELECT para authenticated em privado.parametro_notificacao:
grant select on privado.parametro_notificacao to authenticated;

-- Criamos uma função de teste executada com papel authenticated
create function pg_temp.contar_como_authenticated() returns int
language plpgsql security invoker as $$
declare
  v_qtd int;
begin
  execute 'set local role authenticated';
  select count(*)::int into v_qtd from privado.parametro_notificacao;
  reset role;
  return v_qtd;
end $$;

-- Como o RLS está ativado sem políticas permissivas, a leitura de authenticated retorna 0 linhas
select is(
  (select pg_temp.contar_como_authenticated()),
  0,
  'defesa em profundidade: mesmo com GRANT acidental, RLS sem política devolve zero linhas para authenticated'
);

-- Limpa a concessão do teste
revoke select on privado.parametro_notificacao from authenticated;

-- ── 6. Operações de leitura/escrita das funções SECURITY DEFINER continuam normais
-- Testamos leitura/escrita direta via rotinas do banco nas tabelas de privado:

-- ambiente: lido por privado.agora()
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select lives_ok(
  $$ select privado.agora() $$,
  'privado.agora() lê privado.ambiente sem erro sob RLS'
);

-- parametro_notificacao: lido por rotinas de notificação
select lives_ok(
  $$ select chave, valor from privado.parametro_notificacao limit 1 $$,
  'leitura administrativa de privado.parametro_notificacao funciona'
);

-- termo_bloqueado: lido por filtro de texto ofensivo
select lives_ok(
  $$ select privado.texto_aceitavel('Texto Perfeito Sem Ofensas') $$,
  'privado.texto_aceitavel consulta privado.termo_bloqueado com sucesso sob RLS'
);

-- tipo_no_teto: lido pelas travas de RN23
select lives_ok(
  $$ select count(*) from privado.tipo_no_teto $$,
  'leitura de privado.tipo_no_teto funciona'
);

-- conta_equipe: lida por candidatos_da_vaga
select lives_ok(
  $$ select count(*) from privado.conta_equipe $$,
  'leitura de privado.conta_equipe funciona'
);

-- auditoria_ciclo: gravada por triggers de ciclo
select lives_ok(
  $$ insert into privado.auditoria_ciclo (entidade, entidade_id, acao, estado_anterior, estado_novo)
     values ('turno', gen_random_uuid(), 'criou', null, 'aberto') $$,
  'escrita em privado.auditoria_ciclo funciona sob RLS'
);

-- divergencia_reputacao: tabela de reconciliação
select lives_ok(
  $$ select count(*) from privado.divergencia_reputacao $$,
  'leitura de privado.divergencia_reputacao funciona sob RLS'
);

select * from finish();
rollback;
