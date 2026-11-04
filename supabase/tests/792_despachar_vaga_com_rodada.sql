-- 792_despachar_vaga_com_rodada.sql
--
-- Guarda contra o que aconteceu no frila-prod em 04/11/2026: a função `privado.despachar_vaga`
-- ficou na versão ANTIGA (`on conflict (vaga_id, profissional_id)`), incompatível com a
-- restrição `unique (vaga_id, profissional_id, rodada)` da tabela `despacho`, e nenhum despacho
-- era criado. Aqui se prova, no banco reconstruído do zero, que a função vigente:
--   1. conflita pela chave com `rodada`, a mesma restrição que a tabela tem;
--   2. não usa mais o `on conflict` sem `rodada`;
--   3. continua com `security definer`, `search_path` vazio e só o `service_role` executa.

begin;
select plan(6);

select ok(
  exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.despacho'::regclass
       and c.contype = 'u'
       and pg_get_constraintdef(c.oid) = 'UNIQUE (vaga_id, profissional_id, rodada)'
  ),
  'despacho tem a restrição única (vaga_id, profissional_id, rodada)'
);

select ok(
  (select p.prosrc ilike '%on conflict (vaga_id, profissional_id, rodada) do nothing%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'despachar_vaga'),
  'despachar_vaga conflita pela chave com rodada'
);

select ok(
  (select p.prosrc !~* 'on conflict \(vaga_id, profissional_id\) do nothing'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'despachar_vaga'),
  'despachar_vaga não usa mais o on conflict sem rodada'
);

select ok(
  (select p.prosecdef and p.proconfig = array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'despachar_vaga'),
  'despachar_vaga é security definer com search_path vazio'
);

select ok(
  has_function_privilege('service_role', 'privado.despachar_vaga(uuid, text, uuid)', 'execute'),
  'service_role executa despachar_vaga'
);

select ok(
  not has_function_privilege('authenticated', 'privado.despachar_vaga(uuid, text, uuid)', 'execute')
  and not has_function_privilege('anon', 'privado.despachar_vaga(uuid, text, uuid)', 'execute'),
  'authenticated e anon não executam despachar_vaga'
);

select * from finish();
rollback;
