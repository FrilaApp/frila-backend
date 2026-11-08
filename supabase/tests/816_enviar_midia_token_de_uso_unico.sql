-- 816_enviar_midia_token_de_uso_unico.sql
--
-- Upload da foto pela Edge Function enviar-midia (contrato 0.2.63). Ids próprios, começando
-- em `81600000`. Só dados sintéticos.
--
-- O que este arquivo prova:
--   1. solicitar_upload_midia devolve a URL da enviar-midia com token opaco de 64 hex; o banco
--      guarda só o SHA-256, nunca o token, e o prazo de 2 h.
--   2. privado.consumir_token_upload entrega o caminho uma vez só; depois, NULL.
--   3. Não entrega com token errado, token de outra mídia, vencido, mídia fora de `enviando`,
--      conta suspensa, quem pediu fora da casa ou recurso desligado; formato inválido é NULL.
--   4. Só service_role executa o consumo; o hash é único.
--   5. As duas unicidades da mídia que só a escrita direta alcança: um storage_path por
--      mídia, e uma foto de perfil por dono em `em_analise` e em `aprovada`.
-- A disputa de duas conexões pelo mesmo token está em scripts/corrida-token-upload.sh.

begin;
select plan(25);

insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
set local "frila.agora" = '2026-11-20 12:00:00+00';
select vault.create_secret('https://projeto.supabase.test/functions/v1/enviar-midia', 'enviar_midia_function_url');

create function pg_temp.sessao(conta uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    case when conta is null then '' else json_build_object('sub', conta, 'role', 'authenticated')::text end, true);
end $$;
create function pg_temp.token(url text) returns text language sql as $$ select substring(url from 'token=([0-9a-f]{64})$') $$;

insert into auth.users (id, email) values
  ('81600000-0000-4000-8000-000000000001', 'prof@816.test'),
  ('81600000-0000-4000-8000-000000000002', 'casa@816.test');
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em) values
  ('81600000-0000-4000-8000-000000000001', 'profissional', 'Pessoa sintética', 'prof@816.test', '+5561955508161', '1995-01-01', '1.0', now()),
  ('81600000-0000-4000-8000-000000000002', 'contratante',  'Casa sintética',   'casa@816.test', '+5561955508162', '1985-01-01', '1.0', now());
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('81600000-0000-4000-8000-0000000000e1', 'Casa 816', '81612345666', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('81600000-0000-4000-8000-000000000002', '81600000-0000-4000-8000-0000000000e1', 'administrador');

update privado.configuracao_app set foto_de_perfil = true;
select pg_temp.sessao('81600000-0000-4000-8000-000000000001');
create temp table s1 as select public.solicitar_upload_midia('foto_perfil', 'image/jpeg', 1024) r;
create temp table s2 as select public.solicitar_upload_midia('foto_perfil', 'image/jpeg', 1024) r;
select pg_temp.sessao(null);

-- ── 1. URL, hash e prazo ──────────────────────────────────────────────────────

select ok((select r->>'upload_url' from s1) like 'https://projeto.supabase.test/functions/v1/enviar-midia?midia_id='
            || (select r->>'midia_id' from s1) || '&token=%',
  'a upload_url é da enviar-midia, com o midia_id reservado');
select ok(pg_temp.token((select r->>'upload_url' from s1)) is not null, 'token opaco de 64 hex na URL');
select is((select upload_token_hash from privado.midia where id = (select (r->>'midia_id')::uuid from s1)),
  encode(sha256(convert_to(pg_temp.token((select r->>'upload_url' from s1)), 'UTF8')), 'hex'),
  'o banco guarda o SHA-256 do token');
select is((select count(*)::int from privado.midia m
            where position(pg_temp.token((select r->>'upload_url' from s1)) in row_to_json(m)::text) > 0),
  0, 'o token em si não aparece em nenhuma coluna');
select is((select upload_expira_em from privado.midia where id = (select (r->>'midia_id')::uuid from s1)),
  '2026-11-20 14:00:00+00'::timestamptz, 'o token vale 2 h');
select ok(pg_temp.token((select r->>'upload_url' from s1)) <> pg_temp.token((select r->>'upload_url' from s2)),
  'cada pedido ganha um token novo');

-- ── 2. Uso único ──────────────────────────────────────────────────────────────

select is(privado.consumir_token_upload((select (r->>'midia_id')::uuid from s1), pg_temp.token((select r->>'upload_url' from s1))),
  'perfil/' || (select r->>'midia_id' from s1) || '.jpg', 'o token certo entrega o caminho reservado');
select is(privado.consumir_token_upload((select (r->>'midia_id')::uuid from s1), pg_temp.token((select r->>'upload_url' from s1))),
  null, 'o mesmo token não vale de novo');
select ok((select upload_usado_em is not null from privado.midia where id = (select (r->>'midia_id')::uuid from s1)),
  'o consumo fica registrado');

-- ── 3. Recusas ────────────────────────────────────────────────────────────────

select is(privado.consumir_token_upload((select (r->>'midia_id')::uuid from s2), repeat('0', 64)), null, 'token errado: NULL');
select is(privado.consumir_token_upload((select (r->>'midia_id')::uuid from s1), pg_temp.token((select r->>'upload_url' from s2))),
  null, 'token de outra mídia: NULL');
select is(privado.consumir_token_upload((select (r->>'midia_id')::uuid from s2), 'nao-e-hex'), null, 'formato inválido: NULL, sem erro');

set local "frila.agora" = '2026-11-20 14:00:01+00';
select is(privado.consumir_token_upload((select (r->>'midia_id')::uuid from s2), pg_temp.token((select r->>'upload_url' from s2))),
  null, 'vencido (2 h e 1 s): NULL');
set local "frila.agora" = '2026-11-20 12:00:00+00';

update privado.midia set estado = 'removida' where id = (select (r->>'midia_id')::uuid from s2);
select is(privado.consumir_token_upload((select (r->>'midia_id')::uuid from s2), pg_temp.token((select r->>'upload_url' from s2))),
  null, 'mídia fora de enviando: NULL');

select pg_temp.sessao('81600000-0000-4000-8000-000000000001');
create temp table s3 as select public.solicitar_upload_midia('foto_perfil', 'image/jpeg', 1024) r;
select pg_temp.sessao(null);
update public.usuario set estado = 'suspensa' where id = '81600000-0000-4000-8000-000000000001';
select is(privado.consumir_token_upload((select (r->>'midia_id')::uuid from s3), pg_temp.token((select r->>'upload_url' from s3))),
  null, 'conta do titular suspensa depois do pedido: NULL');
update public.usuario set estado = 'ativa' where id = '81600000-0000-4000-8000-000000000001';

update privado.configuracao_app set foto_de_perfil = false;
select is(privado.consumir_token_upload((select (r->>'midia_id')::uuid from s3), pg_temp.token((select r->>'upload_url' from s3))),
  null, 'recurso desligado depois do pedido: NULL');
update privado.configuracao_app set foto_de_perfil = true;

select pg_temp.sessao('81600000-0000-4000-8000-000000000002');
create temp table s4 as select public.solicitar_upload_midia('foto_perfil', 'image/jpeg', 1024, '81600000-0000-4000-8000-0000000000e1') r;
select pg_temp.sessao(null);
delete from public.membro_estabelecimento where usuario_id = '81600000-0000-4000-8000-000000000002';
select is(privado.consumir_token_upload((select (r->>'midia_id')::uuid from s4), pg_temp.token((select r->>'upload_url' from s4))),
  null, 'quem pediu a foto da casa saiu da casa: NULL');

-- ── 4. Privilégio e unicidade ─────────────────────────────────────────────────

select ok(not has_function_privilege('authenticated', 'privado.consumir_token_upload(uuid, text)', 'EXECUTE')
          and not has_function_privilege('anon', 'privado.consumir_token_upload(uuid, text)', 'EXECUTE'),
  'anon e authenticated não executam o consumo');
select ok(has_function_privilege('service_role', 'privado.consumir_token_upload(uuid, text)', 'EXECUTE'),
  'service_role executa o consumo');
select throws_ok(
  format($$update privado.midia set upload_token_hash = %L where id = %L$$,
         (select upload_token_hash from privado.midia where id = (select (r->>'midia_id')::uuid from s3)),
         (select r->>'midia_id' from s4)),
  '23505', null, 'índice único: dois envios nunca compartilham o mesmo hash');

-- ── 5. As duas unicidades da mídia (F3) ──────────────────────────────────────
--
-- As RPCs geram o caminho e trocam a foto anterior antes de gravar, então nenhum teste de
-- RPC encosta nestas duas regras: o mutante que derruba cada uma sobrevivia (CI do #435).
-- Pela escrita direta, cada asserção monta dados que só a regra em teste pode recusar.

create function pg_temp.midia(id uuid, dono uuid, casa uuid, estado text, caminho text) returns void
language sql as $$
  insert into privado.midia (id, dono_usuario_id, estabelecimento_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
  values (id, dono, casa, case when casa is null then 'profissional' else 'estabelecimento' end,
          'foto_perfil', caminho, 'image/jpeg', 1024, estado) $$;

-- `enviando` fica fora do índice parcial: aqui só a unique de storage_path pode recusar.
select pg_temp.midia('81600000-0000-4000-8000-0000000000a1', '81600000-0000-4000-8000-000000000001', null,
  'enviando', 'perfil/816/repetido.jpg');
select throws_ok(
  $$ select pg_temp.midia('81600000-0000-4000-8000-0000000000a2', '81600000-0000-4000-8000-000000000002',
       '81600000-0000-4000-8000-0000000000e1', 'enviando', 'perfil/816/repetido.jpg') $$,
  '23505', null, 'midia_storage_path_key: duas mídias nunca apontam para o mesmo original');

-- Caminhos distintos: aqui só o índice midia_foto_unica_por_estado pode recusar.
select pg_temp.midia('81600000-0000-4000-8000-0000000000b1', '81600000-0000-4000-8000-000000000001', null,
  'em_analise', 'perfil/816/analise-1.jpg');
select throws_ok(
  $$ select pg_temp.midia('81600000-0000-4000-8000-0000000000b2', '81600000-0000-4000-8000-000000000001', null,
       'em_analise', 'perfil/816/analise-2.jpg') $$,
  '23505', null, 'midia_foto_unica_por_estado: o profissional não tem duas fotos de perfil em análise');
select pg_temp.midia('81600000-0000-4000-8000-0000000000b3', '81600000-0000-4000-8000-000000000001', null,
  'aprovada', 'perfil/816/aprovada-1.jpg');
select throws_ok(
  $$ select pg_temp.midia('81600000-0000-4000-8000-0000000000b4', '81600000-0000-4000-8000-000000000001', null,
       'aprovada', 'perfil/816/aprovada-2.jpg') $$,
  '23505', null, 'midia_foto_unica_por_estado: o profissional não tem duas fotos de perfil aprovadas');
-- A casa é dona pela casa (coalesce no índice), e não por quem enviou: a 2ª foto vem de
-- OUTRO dono da mesma casa. Com o mesmo dono nas duas, um índice pelo dono também colidiria
-- (mutante sem o coalesce, apontado pelo Lince AG 2 no #435). A escrita direta não confere
-- a filiação, então o …0001 basta como segundo dono da …e1.
select pg_temp.midia('81600000-0000-4000-8000-0000000000c1', '81600000-0000-4000-8000-000000000002',
  '81600000-0000-4000-8000-0000000000e1', 'em_analise', 'perfil/816/casa-1.jpg');
select throws_ok(
  $$ select pg_temp.midia('81600000-0000-4000-8000-0000000000c2', '81600000-0000-4000-8000-000000000001',
       '81600000-0000-4000-8000-0000000000e1', 'em_analise', 'perfil/816/casa-2.jpg') $$,
  '23505', null, 'midia_foto_unica_por_estado: a casa não tem duas fotos de perfil em análise');
-- O índice é parcial: a aprovada convive com a que está em análise, e recusadas se acumulam.
select lives_ok(
  $$ select pg_temp.midia('81600000-0000-4000-8000-0000000000d1', '81600000-0000-4000-8000-000000000001', null,
       'recusada', 'perfil/816/recusada-1.jpg'),
            pg_temp.midia('81600000-0000-4000-8000-0000000000d2', '81600000-0000-4000-8000-000000000001', null,
       'recusada', 'perfil/816/recusada-2.jpg') $$,
  'midia_foto_unica_por_estado: com uma aprovada e uma em análise, recusadas não colidem');

select * from finish();
rollback;
