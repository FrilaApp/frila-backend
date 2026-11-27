-- 908_solicitar_upload_midia_v2.sql
--
-- B-102 (Fase 2, fatia a), contrato 0.2.119: `public.solicitar_upload_midia_v2` pede a URL de envio da foto com o token FORA da
-- URL. Mesma entrada e mesmas recusas da v1; só o 200 muda (`upload_url` com o `midia_id` e o token em `upload_token`).
--   A  v2 = v1 nas recusas: cada entrada recusada devolve exatamente o mesmo erro nas duas (status, code, details), e a recusa existe
--   B  o 200 da v2: URL só com `midia_id`, `upload_token` de 64 hex, sem miniatura, validade de 15 min, só o SHA-256 no banco
--   C  o token da v2 é o do `enviar-midia`: `privado.consumir_token_upload` o aceita uma vez e recusa a segunda
--   D  a v1 não mudou: segue com `&token=` na URL
--   E  quem pode: o membro da casa pede pela casa; privilégios (authenticated executa, anon não)
-- Só dados sintéticos.
begin;
-- 20261113220000 liga foto, chamada direta e perfil rico para todos; este teste parte das chaves desligadas, como nasceram.
update privado.recurso set ligado = false where chave in ('chamada_direta', 'perfil_rico');
update privado.configuracao_app set foto_de_perfil = false;
delete from privado.recurso_versao_minima where recurso in ('foto_de_perfil', 'chamada_direta', 'perfil_rico');
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-27 15:00:00+00', true);
select plan(65);

create function pg_temp.erro(sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  execute sql; return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  return msg::jsonb || det::jsonb;
end $$;

insert into auth.users(id, email) values
 ('90800000-0000-4000-8000-000000000001', 'prof@908.test'),
 ('90800000-0000-4000-8000-000000000002', 'outra@908.test'),
 ('90800000-0000-4000-8000-000000000003', 'admin@908.test'),
 ('90800000-0000-4000-8000-000000000004', 'estranho@908.test'),
 ('90800000-0000-4000-8000-000000000005', 'suspensa@908.test');
insert into public.usuario(id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em)
select id,
       (case when email in ('admin@908.test', 'estranho@908.test') then 'contratante' else 'profissional' end)::public.perfil_conta,
       'Pessoa sintética', email, '+556195550908' || row_number() over (), '1995-01-01', '1.0', now()
  from auth.users where email like '%@908.test';
insert into public.estabelecimento(id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('90800000-0000-4000-8000-000000000010', 'Casa sintética', '90800000000010', 'outro', 'Endereço sintético',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento(usuario_id, estabelecimento_id, papel)
values ('90800000-0000-4000-8000-000000000003', '90800000-0000-4000-8000-000000000010', 'administrador');
select vault.create_secret('jwt-sintetico-908-sem-valor-real-32-caracteres', 'storage_jwt_secret');

-- ── A. As recusas da v2 são as da v1 ──────────────────────────────────────────

-- Sem sessão.
reset request.jwt.claims;
select is(pg_temp.erro($$select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',1)$$)->>'status', '401',
  'A1 sem sessão: 401');
select is(
  pg_temp.erro($$select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',1)$$),
  pg_temp.erro($$select public.solicitar_upload_midia('foto_perfil','image/jpeg',1)$$),
  'A2 sem sessão: o mesmo erro da v1');

-- Recurso desligado (a chave nasce desligada).
set local request.jwt.claims = '{"sub":"90800000-0000-4000-8000-000000000001","role":"authenticated"}';
select is(pg_temp.erro($$select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',1)$$)->>'details', 'recurso_desligado',
  'A3 recurso desligado: 403 recurso_desligado');
select is(
  pg_temp.erro($$select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',1)$$),
  pg_temp.erro($$select public.solicitar_upload_midia('foto_perfil','image/jpeg',1)$$),
  'A4 recurso desligado: o mesmo erro da v1');

update privado.configuracao_app set foto_de_perfil = true;
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('foto_de_perfil', 'ios', '1.2.0');

-- Cada entrada inválida: a v2 recusa, e com o mesmo erro da v1.
create temp table entradas (rotulo text, args text);
insert into entradas values
  ('tipo', '''foto_local'',''image/jpeg'',1'),
  ('tipo nulo', 'null,''image/jpeg'',1'),
  ('formato png', '''foto_perfil'',''image/png'',1'),
  ('formato webp', '''foto_perfil'',''image/webp'',1'),
  ('formato gif', '''foto_perfil'',''image/gif'',1'),
  ('formato nulo', '''foto_perfil'',null,1'),
  ('tamanho negativo', '''foto_perfil'',''image/jpeg'',-1'),
  ('tamanho zero', '''foto_perfil'',''image/jpeg'',0'),
  ('tamanho acima de 5 MB', '''foto_perfil'',''image/jpeg'',5242881'),
  ('tamanho nulo', '''foto_perfil'',''image/jpeg'',null'),
  ('profissional pela casa (não é membro)', '''foto_perfil'',''image/jpeg'',1,''90800000-0000-4000-8000-000000000010''');

select isnt(pg_temp.erro(format('select public.solicitar_upload_midia_v2(%s)', args)), null::jsonb, 'A5 a v2 recusa: ' || rotulo)
  from entradas order by rotulo;
select is(
  pg_temp.erro(format('select public.solicitar_upload_midia_v2(%s)', args)),
  pg_temp.erro(format('select public.solicitar_upload_midia(%s)', args)),
  'A6 o mesmo erro da v1: ' || rotulo)
  from entradas order by rotulo;

-- Papel e vínculo errados.
set local request.jwt.claims = '{"sub":"90800000-0000-4000-8000-000000000004","role":"authenticated"}';
select isnt(pg_temp.erro($$select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',1)$$), null::jsonb,
  'A7 contratante sem casa pede como profissional: recusa');
select is(
  pg_temp.erro($$select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',1)$$),
  pg_temp.erro($$select public.solicitar_upload_midia('foto_perfil','image/jpeg',1)$$),
  'A8 contratante sem casa: o mesmo erro da v1');
select is(
  pg_temp.erro($$select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',1,'90800000-0000-4000-8000-000000000010')$$)->>'status',
  '403', 'A9 quem não é membro da casa: 403');
select is(
  pg_temp.erro($$select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',1,'90800000-0000-4000-8000-000000000010')$$),
  pg_temp.erro($$select public.solicitar_upload_midia('foto_perfil','image/jpeg',1,'90800000-0000-4000-8000-000000000010')$$),
  'A10 não-membro: o mesmo erro da v1');

-- Conta suspensa.
update public.usuario set estado = 'suspensa' where id = '90800000-0000-4000-8000-000000000005';
set local request.jwt.claims = '{"sub":"90800000-0000-4000-8000-000000000005","role":"authenticated"}';
select is(pg_temp.erro($$select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',1)$$)->>'details', 'conta_suspensa',
  'A11 conta suspensa: 403 conta_suspensa');
select is(
  pg_temp.erro($$select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',1)$$),
  pg_temp.erro($$select public.solicitar_upload_midia('foto_perfil','image/jpeg',1)$$),
  'A12 conta suspensa: o mesmo erro da v1');

-- ── B. O 200 da v2 ────────────────────────────────────────────────────────────

set local request.jwt.claims = '{"sub":"90800000-0000-4000-8000-000000000001","role":"authenticated"}';
create temp table v2 as select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',5242880) as r;
create temp table v2b as select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',1) as r;

select is((select array_agg(k order by k) from v2, jsonb_object_keys(r) k),
  array['expira_em', 'midia_id', 'upload_token', 'upload_url'],
  'B1 o 200 traz exatamente midia_id, upload_url, upload_token e expira_em');
select ok((select r->>'upload_url' ~ '/functions/v1/enviar-midia\?midia_id=[0-9a-f-]{36}$' from v2),
  'B2 a upload_url é a da enviar-midia só com o midia_id na query');
select ok((select position('token' in r->>'upload_url') = 0 from v2),
  'B3 a upload_url não tem a palavra token');
select ok((select position(r->>'upload_token' in r->>'upload_url') = 0 from v2),
  'B4 a upload_url não carrega o valor do token');
select ok((select r->>'upload_url' not like '%&%' and r->>'upload_url' not like '%#%' from v2),
  'B5 a upload_url não tem segundo parâmetro nem fragmento');
select ok((select r->>'upload_token' ~ '^[0-9a-f]{64}$' from v2), 'B6 o upload_token são 64 hexadecimais minúsculos');
select isnt((select r->>'upload_token' from v2), (select r->>'upload_token' from v2b), 'B7 cada pedido tem o seu token');
select isnt((select r->>'midia_id' from v2), (select r->>'midia_id' from v2b), 'B8 e a sua mídia');
select ok((select position('90800000-0000-4000-8000-000000000001' in r->>'upload_url') = 0 from v2),
  'B9 a URL não traz o id do dono');
select ok(not (select r ? 'upload_url_miniatura' from v2), 'B10 sem miniatura (descontinuada na 0.2.57)');
select is((select (r->>'expira_em')::timestamptz from v2), privado.agora() + interval '15 minutes',
  'B11 a validade é de 15 minutos, como a da v1');
select is((select (r->>'midia_id') ~ '^[0-9a-f-]{36}$' from v2), true, 'B12 midia_id é um uuid');

-- O banco guarda só o SHA-256 do token.
select is(
  (select upload_token_hash from privado.midia where id = (select (r->>'midia_id')::uuid from v2)),
  (select encode(sha256(convert_to(r->>'upload_token', 'UTF8')), 'hex') from v2),
  'B13 o banco guarda o SHA-256 do upload_token');
select ok(
  (select position((select r->>'upload_token' from v2) in row_to_json(m)::text) = 0
     from privado.midia m where m.id = (select (r->>'midia_id')::uuid from v2)),
  'B14 o token em claro não aparece em nenhuma coluna da mídia');
select is(
  (select upload_expira_em from privado.midia where id = (select (r->>'midia_id')::uuid from v2)),
  privado.agora() + interval '15 minutes',
  'B15 o upload_expira_em gravado é o mesmo prazo');
select is(
  (select row(dono_tipo, tipo, mime, bytes, estado)::text from privado.midia where id = (select (r->>'midia_id')::uuid from v2)),
  '(profissional,foto_perfil,image/jpeg,5242880,enviando)',
  'B16 a mídia nasce em enviando, do profissional, igual à da v1');
select is(
  (select storage_path from privado.midia where id = (select (r->>'midia_id')::uuid from v2)),
  'perfil/' || (select r->>'midia_id' from v2) || '.jpg',
  'B17 o caminho no Storage é o da v1');

-- ── C. O token da v2 é o que a enviar-midia consome ───────────────────────────

reset request.jwt.claims;
select is(
  privado.consumir_token_upload((select (r->>'midia_id')::uuid from v2), (select r->>'upload_token' from v2)),
  'perfil/' || (select r->>'midia_id' from v2) || '.jpg',
  'C1 consumir_token_upload aceita o token da v2 e devolve o caminho');
select is(
  privado.consumir_token_upload((select (r->>'midia_id')::uuid from v2), (select r->>'upload_token' from v2)),
  null::text,
  'C2 e é de uso único: a segunda vez devolve nulo');
select is(
  privado.consumir_token_upload((select (r->>'midia_id')::uuid from v2b), repeat('0', 64)),
  null::text,
  'C3 outro token não consome a mídia');
select is(
  privado.consumir_token_upload((select (r->>'midia_id')::uuid from v2b), (select r->>'upload_token' from v2)),
  null::text,
  'C4 o token de uma mídia não consome a de outro pedido');

-- Vencido: depois dos 15 minutos o token deixa de valer.
select set_config('frila.agora', '2026-11-27 15:16:00+00', true);
select is(
  privado.consumir_token_upload((select (r->>'midia_id')::uuid from v2b), (select r->>'upload_token' from v2b)),
  null::text,
  'C5 depois dos 15 minutos o token da v2 não vale');
select set_config('frila.agora', '2026-11-27 15:00:00+00', true);

-- ── D. A v1 não mudou ─────────────────────────────────────────────────────────

set local request.jwt.claims = '{"sub":"90800000-0000-4000-8000-000000000001","role":"authenticated"}';
create temp table v1 as select public.solicitar_upload_midia('foto_perfil','image/jpeg',5242880) as r;
select ok((select r->>'upload_url' ~ '/functions/v1/enviar-midia\?midia_id=[0-9a-f-]{36}&token=[0-9a-f]{64}$' from v1),
  'D1 a v1 segue com o token na query (sem descontinuação)');
select ok(not (select r ? 'upload_token' from v1), 'D2 e sem upload_token');
select is((select array_agg(k order by k) from v1, jsonb_object_keys(r) k), array['expira_em', 'midia_id', 'upload_url'],
  'D3 a v1 devolve os mesmos três campos de antes');

-- ── E. Quem pode ──────────────────────────────────────────────────────────────

set local request.jwt.claims = '{"sub":"90800000-0000-4000-8000-000000000003","role":"authenticated"}';
create temp table v2casa as select public.solicitar_upload_midia_v2('foto_perfil','image/jpeg',1,'90800000-0000-4000-8000-000000000010') as r;
select is(
  (select estabelecimento_id::text from privado.midia where id = (select (r->>'midia_id')::uuid from v2casa)),
  '90800000-0000-4000-8000-000000000010', 'E1 o membro da casa pede pela casa');
select is(
  (select dono_tipo from privado.midia where id = (select (r->>'midia_id')::uuid from v2casa)), 'estabelecimento',
  'E2 e a mídia é da casa');
select ok((select r->>'upload_url' !~ 'token' from v2casa), 'E3 também pela casa a URL vai sem token');
reset request.jwt.claims;
select ok(has_function_privilege('authenticated', 'public.solicitar_upload_midia_v2(text, text, bigint, uuid)', 'execute'),
  'E4 authenticated executa a v2');
select ok(not has_function_privilege('anon', 'public.solicitar_upload_midia_v2(text, text, bigint, uuid)', 'execute'),
  'E5 anon não executa a v2');
select is(has_function_privilege('anon', 'public.solicitar_upload_midia(text, text, bigint, uuid)', 'execute'), false,
  'E6 nem a v1 (mesma regra)');
select ok((select prosecdef from pg_proc where oid = 'public.solicitar_upload_midia_v2(text, text, bigint, uuid)'::regprocedure),
  'E7 a v2 é security definer');
select ok((select 'search_path=""' = any(proconfig) from pg_proc where oid = 'public.solicitar_upload_midia_v2(text, text, bigint, uuid)'::regprocedure),
  'E8 com search_path vazio, como a v1');

select * from finish();
rollback;
