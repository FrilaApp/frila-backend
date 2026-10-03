-- 521_contestacao_negada_permite_reenvio.sql
--
-- Cartão pVvubZJy (S2 · Backend · Defeito em contestar_suspensao):
-- Após resolução/negativa de uma contestação anterior pela Equipe Frila,
-- a conta suspensa pode enviar uma nova contestação (alinhado a situacao_da_conta).

begin;
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-03 10:00:00-03';
select plan(7);

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-4000-8000-000000000000', 'fd000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'suspenso@fd.test', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now())
on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-4000-8000-000000000000', 'fd000000-0000-4000-8000-000000000099', 'authenticated', 'authenticated', 'operador@fd.test', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now())
on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado) values
  ('fd000000-0000-4000-8000-000000000001', 'profissional', 'Eduardo Suspenso', '+5561999980001', 'suspenso@fd.test', '1995-05-10', '2026-09-22', now(), 'ativa'),
  ('fd000000-0000-4000-8000-000000000099', 'contratante',  'Operador Equipe',  '+5561999980099', 'operador@fd.test', '1990-01-01', '2026-09-22', now(), 'ativa');

insert into privado.conta_equipe (usuario_id) values ('fd000000-0000-4000-8000-000000000099');

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
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

-- Suspende a conta
select privado.suspender(
  'fd000000-0000-4000-8000-000000000001',
  'Suspensão para validação de reenvio de contestação',
  'fd000000-0000-4000-8000-000000000099'
);

-- 1. Primeira contestação: aceita normalmente
create temp table resp_c1 as
  select pg_temp.como('fd000000-0000-4000-8000-000000000001',
    $$ select public.contestar_suspensao('Primeira contestacao de suspensao enviada pelo usuario') $$) as r;

select is(
  ((select r from resp_c1)->>'tipo'),
  'contestacao',
  '1. Primeira contestação aceita e gera protocolo'
);

-- 2. situacao_da_conta exibe contestação aberta
select is(
  ((pg_temp.como('fd000000-0000-4000-8000-000000000001',
    $$ select public.situacao_da_conta() $$))->'suspensao'->'contestacao'->>'tipo'),
  'contestacao',
  '2. situacao_da_conta exibe contestação em aberto'
);

-- 3. Segunda contestação enquanto a primeira está aberta é recusada com 409
select throws_ok(
  $$ select pg_temp.como('fd000000-0000-4000-8000-000000000001',
       $q$ select public.contestar_suspensao('Tentativa concomitante de enviar outra contestacao') $q$) $$,
  'PGRST',
  pg_temp.erro('contestacao_ja_aberta'),
  '3. Segunda contestação com a anterior em aberto é recusada com 409 contestacao_ja_aberta'
);

-- Operador resolve / nega a contestação
update public.ocorrencia
   set resolvido_em = now()
 where id = ((select r from resp_c1)->>'ocorrencia_id')::uuid;

-- 4. situacao_da_conta oculta a contestação resolvida
select is(
  ((pg_temp.como('fd000000-0000-4000-8000-000000000001',
    $$ select public.situacao_da_conta() $$))->'suspensao'->>'contestacao'),
  null,
  '4. situacao_da_conta oculta contestação resolvida (app vê contestacao: null)'
);

-- 5. Segunda contestação agora é ACEITA após a anterior ter sido resolvida (correção do defeito pVvubZJy)
create temp table resp_c2 as
  select pg_temp.como('fd000000-0000-4000-8000-000000000001',
    $$ select public.contestar_suspensao('Segunda contestacao com informacoes adicionais apos negativa') $$) as r;

select is(
  ((select r from resp_c2)->>'tipo'),
  'contestacao',
  '5. Segunda contestação é aceita após resolução da anterior'
);

-- 6. O protocolo novo é diferente do primeiro
select isnt(
  ((select r from resp_c2)->>'ocorrencia_id'),
  ((select r from resp_c1)->>'ocorrencia_id'),
  '6. Novo protocolo de contestação gerado'
);

-- 7. Terceira contestação enquanto a segunda está aberta é recusada com 409
select throws_ok(
  $$ select pg_temp.como('fd000000-0000-4000-8000-000000000001',
       $q$ select public.contestar_suspensao('Terceira contestacao com a segunda ainda aberta') $q$) $$,
  'PGRST',
  pg_temp.erro('contestacao_ja_aberta'),
  '7. Terceira contestação recusada enquanto a segunda estiver aberta'
);

select * from finish();
rollback;
