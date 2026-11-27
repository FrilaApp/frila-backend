-- 922_ultimo_administrador_olha_so_a_propria_casa.sql
--
-- HbSJRenz (itens 90 e 91): a trava de "último administrador" conta só os administradores DA CASA, em `aceitar_convite_membro` (rebaixar-se a
-- operador por um convite) e em `remover_membro`. Sem o filtro `m.estabelecimento_id = <casa>`, o administrador de OUTRA casa serviria de "outro
-- administrador" e a casa ficaria sem nenhum. Os testes de antes (843, 883, 902) só têm administradores na casa testada.
--   A  o único administrador de A aceita convite de operador de A, com a casa B tendo um administrador: 422 ultimo_administrador; ele segue
--      administrador, o convite não é gasto e a casa B não muda
--   B  o único administrador de A é removido (pelo `id` do vínculo e pelo `usuario_id`): 422 ultimo_administrador; o vínculo continua
--   C  controles: com um segundo administrador DENTRO de A, o mesmo aceite rebaixa (200) e a mesma remoção funciona (200)
-- Nota: a definição viva de `aceitar_convite_membro` é a de 20261125140000 (que confere o e-mail); a trava é a mesma de 20261117120000.
-- Ids próprios (`92200000`). Só dados sintéticos.
begin;
select plan(17);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local "frila.agora" = '2026-11-27 15:00:00+00';

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

-- A recusa por inteiro: o envelope de public.erro (message) mais o status (detail).
create function pg_temp.erro(conta uuid, sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  perform pg_temp.como(conta, sql);
  return null;
exception when others then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return msg::jsonb || det::jsonb;
end $$;

-- U1: ÚNICO administrador de A. U2: administrador de B. U3: operador de A.
insert into auth.users (id, email, email_confirmed_at) values
  ('92200000-0000-4000-8000-000000000001', 'u1.922@teste.invalid', now()),
  ('92200000-0000-4000-8000-000000000002', 'u2.922@teste.invalid', now()),
  ('92200000-0000-4000-8000-000000000003', 'u3.922@teste.invalid', now());
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em, estado)
select id, 'contratante', 'Conta ' || right(email, 22), email, '+556195550922' || right(id::text, 1), '1985-01-01', '1.0', now(), 'ativa'
  from auth.users where email like '%.922@teste.invalid';

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('92200000-0000-4000-8000-0000000000a1', 'Casa A 922', '92211222000191', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('92200000-0000-4000-8000-0000000000b1', 'Casa B 922', '92211222000292', 'food_service', 'CLN 202', 'POINT(-47.8825 -15.7945)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('92200000-0000-4000-8000-0000000000a1', '92200000-0000-4000-8000-000000000001', 'administrador'),
  ('92200000-0000-4000-8000-0000000000a1', '92200000-0000-4000-8000-000000000003', 'operador'),
  ('92200000-0000-4000-8000-0000000000b1', '92200000-0000-4000-8000-000000000002', 'administrador');

-- Convites inseridos direto, com o e-mail de quem aceita.
create function pg_temp.convite(tok text, email text, papel public.papel_membro) returns void language sql as $$
  insert into privado.convite_membro (estabelecimento_id, email, papel, convidado_por, token_hash, expira_em)
  values ('92200000-0000-4000-8000-0000000000a1', email, papel, '92200000-0000-4000-8000-000000000001',
          encode(sha256(convert_to(tok, 'UTF8')), 'hex'), '2026-12-10 15:00:00+00');
$$;
select pg_temp.convite('tok-rebaixa-922', 'u1.922@teste.invalid', 'operador');
select pg_temp.convite('tok-controle-922', 'u1.922@teste.invalid', 'operador');

create temp table ids as select
  (select id from public.membro_estabelecimento where estabelecimento_id = '92200000-0000-4000-8000-0000000000a1' and usuario_id = '92200000-0000-4000-8000-000000000001') as u1_em_a;

select is((select count(*)::int from public.membro_estabelecimento where papel = 'administrador'
            and estabelecimento_id in ('92200000-0000-4000-8000-0000000000a1', '92200000-0000-4000-8000-0000000000b1')), 2,
  '0 há dois administradores nas duas casas do teste, um em cada');
select is((select count(*)::int from public.membro_estabelecimento where estabelecimento_id = '92200000-0000-4000-8000-0000000000a1' and papel = 'administrador'), 1,
  '0b e a casa A tem um só (o U1)');

-- ── A. O único administrador de A aceita convite de operador ──────────────────

select is((pg_temp.erro('92200000-0000-4000-8000-000000000001', $$ select public.aceitar_convite_membro('tok-rebaixa-922') $$))->>'code',
  'ultimo_administrador', 'A1 o único administrador de A aceita convite de operador de A: 422 ultimo_administrador (o admin da casa B não vale)');
select is((pg_temp.erro('92200000-0000-4000-8000-000000000001', $$ select public.aceitar_convite_membro('tok-rebaixa-922') $$))->>'status',
  '422', 'A2 e o status é 422');
select is((select papel::text from public.membro_estabelecimento where id = (select u1_em_a from ids)), 'administrador', 'A3 ele segue administrador de A');
select is((select usado_em is null from privado.convite_membro where token_hash = encode(sha256(convert_to('tok-rebaixa-922', 'UTF8')), 'hex')), true,
  'A4 o convite não foi gasto (a recusa desfaz o uso)');
select is((select count(*)::int from public.membro_estabelecimento where estabelecimento_id = '92200000-0000-4000-8000-0000000000b1' and papel = 'administrador'), 1,
  'A5 e a casa B segue com o seu administrador');

-- ── B. O único administrador de A é removido ──────────────────────────────────

select is((pg_temp.erro('92200000-0000-4000-8000-000000000001',
  format($$ select public.remover_membro(estabelecimento_id => '92200000-0000-4000-8000-0000000000a1'::uuid, membro_id => %L::uuid) $$, (select u1_em_a from ids))))->>'code',
  'ultimo_administrador', 'B1 remover o único administrador de A (pelo id do vínculo): 422 ultimo_administrador');
select is((pg_temp.erro('92200000-0000-4000-8000-000000000001',
  $$ select public.remover_membro(estabelecimento_id => '92200000-0000-4000-8000-0000000000a1'::uuid, membro_id => '92200000-0000-4000-8000-000000000001'::uuid) $$))->>'code',
  'ultimo_administrador', 'B2 e pelo usuario_id: 422 ultimo_administrador');
select is((select count(*)::int from public.membro_estabelecimento where estabelecimento_id = '92200000-0000-4000-8000-0000000000a1' and papel = 'administrador'), 1,
  'B3 a casa A segue com o seu administrador');
select is((select count(*)::int from public.membro_estabelecimento where id = (select u1_em_a from ids)), 1, 'B4 e o vínculo dele continua');

-- ── C. Controles: com um segundo administrador DENTRO de A, as mesmas ações funcionam ──

update public.membro_estabelecimento set papel = 'administrador'
 where estabelecimento_id = '92200000-0000-4000-8000-0000000000a1' and usuario_id = '92200000-0000-4000-8000-000000000003';

select is((pg_temp.como('92200000-0000-4000-8000-000000000001', $$ select public.aceitar_convite_membro('tok-controle-922') $$))->>'papel',
  'operador', 'C1 com outro administrador em A, o mesmo aceite rebaixa o U1 a operador');
select is((select papel::text from public.membro_estabelecimento where id = (select u1_em_a from ids)), 'operador', 'C2 e o vínculo dele virou operador');
select is((select count(*)::int from public.membro_estabelecimento where estabelecimento_id = '92200000-0000-4000-8000-0000000000a1' and papel = 'administrador'), 1,
  'C3 A tem agora um administrador só (o U3)');

-- O U3 passou a ser o único de A: a trava volta a valer para ele, ainda com o U2 administrando B.
select is((pg_temp.erro('92200000-0000-4000-8000-000000000003',
  $$ select public.remover_membro(estabelecimento_id => '92200000-0000-4000-8000-0000000000a1'::uuid, membro_id => '92200000-0000-4000-8000-000000000003'::uuid) $$))->>'code',
  'ultimo_administrador', 'C4 o U3, agora o único de A, também não sai');

-- Um segundo administrador em A: a remoção de um deles funciona.
update public.membro_estabelecimento set papel = 'administrador' where id = (select u1_em_a from ids);
select is((pg_temp.como('92200000-0000-4000-8000-000000000003',
  format($$ select public.remover_membro(estabelecimento_id => '92200000-0000-4000-8000-0000000000a1'::uuid, membro_id => %L::uuid) $$, (select u1_em_a from ids))))->>'removido',
  'true', 'C5 com dois administradores em A, remover um deles funciona');
select is((select count(*)::int from public.membro_estabelecimento where estabelecimento_id = '92200000-0000-4000-8000-0000000000a1' and papel = 'administrador'), 1,
  'C6 e A fica com o outro');

select * from finish();
rollback;
