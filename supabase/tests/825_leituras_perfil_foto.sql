-- 825_leituras_perfil_foto.sql
--
-- As leituras de perfil projetam foto_url e foto_id (contrato 0.2.54, cartão ZgK6KacD):
-- perfil_publico, candidatos_da_vaga e detalhe_chamada.
--
-- As duas chaves saem juntas ou nenhuma sai. Cada condição de ausência tem um caso próprio, que
-- liga e desliga UMA coisa por vez a partir do caso positivo: chave desligada, sem vínculo, foto
-- que não está aprovada, titular suspenso, titular com conta encerrada, segredo do Storage ausente
-- e leitor do papel errado. Sem o caso positivo verde antes, um negativo verde não provaria nada.

begin;
insert into privado.ambiente values (true, true) on conflict (id) do update set eh_teste = true;
set local frila.agora = '2027-01-11 09:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste-825';
set local frila.storage_url = 'http://storage.invalid/storage/v1';
select no_plan();

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', conta, 'role', 'authenticated')::text, true);
  execute sql into r;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return r;
end $$;

-- ── 1. Massa sintética ────────────────────────────────────────────────────────
insert into auth.users (id, aud, role, email) values
 ('c8250000-0000-4000-8000-000000000001','authenticated','authenticated','profa825@t.test'),
 ('c8250000-0000-4000-8000-000000000002','authenticated','authenticated','profb825@t.test'),
 ('c8250000-0000-4000-8000-000000000003','authenticated','authenticated','casax825@t.test'),
 ('c8250000-0000-4000-8000-000000000004','authenticated','authenticated','casay825@t.test'),
 ('c8250000-0000-4000-8000-000000000005','authenticated','authenticated','profe825@t.test'),
 ('c8250000-0000-4000-8000-000000000006','authenticated','authenticated','proff825@t.test'),
 ('c8250000-0000-4000-8000-000000000007','authenticated','authenticated','profc825@t.test');

select pg_temp.como(('c8250000-0000-4000-8000-00000000000' || n)::uuid,
  format($$select public.criar_conta(%L,%L,%L,'1992-05-10','2026-09-22')$$, p, 'Conta ' || n, '+556195555825' || n))
  from (values (1,'profissional'),(2,'profissional'),(3,'contratante'),(4,'contratante'),
               (5,'profissional'),(6,'profissional'),(7,'profissional')) t(n,p);

select pg_temp.como('c8250000-0000-4000-8000-000000000003',
  $$select public.cadastrar_estabelecimento('Bar Foto X','04252011000110','food_service','CLS 4250 Foto','{"latitude":-15.79,"longitude":-47.88}'::jsonb,'Plano Piloto')$$);
select pg_temp.como('c8250000-0000-4000-8000-000000000004',
  $$select public.cadastrar_estabelecimento('Bar Foto Y','68558622000173','food_service','CLN 1020 Foto','{"latitude":-15.79,"longitude":-47.88}'::jsonb,'Plano Piloto')$$);

insert into public.profissional (id, usuario_id, ponto_base) values
 ('c8250000-0000-4000-8000-000000000011','c8250000-0000-4000-8000-000000000001','POINT(-47.88 -15.79)'),
 ('c8250000-0000-4000-8000-000000000012','c8250000-0000-4000-8000-000000000002','POINT(-47.88 -15.79)'),
 ('c8250000-0000-4000-8000-000000000015','c8250000-0000-4000-8000-000000000005','POINT(-47.88 -15.79)'),
 ('c8250000-0000-4000-8000-000000000016','c8250000-0000-4000-8000-000000000006','POINT(-47.88 -15.79)'),
 ('c8250000-0000-4000-8000-000000000017','c8250000-0000-4000-8000-000000000007','POINT(-47.88 -15.79)');
insert into public.profissional_funcao (profissional_id, funcao_id)
select p, (select id from public.funcao where nome = 'garçom')
  from unnest(array['c8250000-0000-4000-8000-000000000011','c8250000-0000-4000-8000-000000000012',
                    'c8250000-0000-4000-8000-000000000015','c8250000-0000-4000-8000-000000000016',
                    'c8250000-0000-4000-8000-000000000017']::uuid[]) p;

-- A casa X publica uma vaga em modo seleção; A, B e C se candidatam (vínculo de candidatura).
select pg_temp.como('c8250000-0000-4000-8000-000000000003',
  format($$select public.publicar_vaga(
    (select id from public.estabelecimento where nome = 'Bar Foto X'),
    (select id from public.funcao where nome = 'garçom'),
    '2027-01-15 18:00:00+00'::timestamptz, '2027-01-16 02:00:00+00'::timestamptz,
    'CLS 4250 Foto', '{"latitude": -15.79, "longitude": -47.88}'::jsonb, 20000, 3,
    true, false, false, 'Gerente Marcos', 'selecao', %L::uuid, 'preto completo', false, null, 180,
    'Plano Piloto')$$, gen_random_uuid()));
select pg_temp.como(('c8250000-0000-4000-8000-00000000000' || n)::uuid,
  $$select public.candidatar((select id from public.vaga where local = 'CLS 4250 Foto'))$$)
  from (values (1),(2),(7)) t(n);

-- Fotos. A e C têm foto aprovada; B tem foto em análise; a casa X tem logo aprovada.
insert into privado.midia (id, dono_usuario_id, estabelecimento_id, dono_tipo, tipo, storage_path, mime, bytes, estado) values
 ('c8250000-0000-4000-8000-0000000000a1','c8250000-0000-4000-8000-000000000001',null,'profissional','foto_perfil','perfil/c8250000-0000-4000-8000-0000000000a1.jpg','image/jpeg',1000,'aprovada'),
 ('c8250000-0000-4000-8000-0000000000a2','c8250000-0000-4000-8000-000000000002',null,'profissional','foto_perfil','perfil/c8250000-0000-4000-8000-0000000000a2.jpg','image/jpeg',1000,'em_analise'),
 ('c8250000-0000-4000-8000-0000000000a7','c8250000-0000-4000-8000-000000000007',null,'profissional','foto_perfil','perfil/c8250000-0000-4000-8000-0000000000a7.jpg','image/jpeg',1000,'aprovada'),
 ('c8250000-0000-4000-8000-0000000000b1','c8250000-0000-4000-8000-000000000003',
   (select id from public.estabelecimento where nome = 'Bar Foto X'),'estabelecimento','foto_perfil','perfil/c8250000-0000-4000-8000-0000000000b1.jpg','image/jpeg',1000,'aprovada');

-- O recurso ligado e o segredo do Storage no Vault.
update privado.configuracao_app set foto_de_perfil = true;
select vault.create_secret('segredo-de-teste-storage-825-0123456789', 'storage_jwt_secret');

create function pg_temp.casa_x() returns uuid language sql as
  $$ select id from public.estabelecimento where nome = 'Bar Foto X' $$;
create function pg_temp.vaga_x() returns uuid language sql as
  $$ select id from public.vaga where local = 'CLS 4250 Foto' $$;

-- Chamada da casa X para o profissional F (só chamada, nenhum outro vínculo) e para A.
insert into public.chamada (id, vaga_id, profissional_id, estabelecimento_id, criada_por, expira_em, chave) values
 ('c8250000-0000-4000-8000-0000000000c6', pg_temp.vaga_x(), 'c8250000-0000-4000-8000-000000000016', pg_temp.casa_x(),
   'c8250000-0000-4000-8000-000000000003', '2027-01-14 00:00:00+00', gen_random_uuid()),
 ('c8250000-0000-4000-8000-0000000000c1', pg_temp.vaga_x(), 'c8250000-0000-4000-8000-000000000011', pg_temp.casa_x(),
   'c8250000-0000-4000-8000-000000000003', '2027-01-14 00:00:00+00', gen_random_uuid());

-- Atalhos de leitura.
create function pg_temp.perfil_de(leitor uuid, alvo uuid) returns jsonb language sql as
  $$ select pg_temp.como(leitor, format('select public.perfil_publico(%L::uuid)', alvo)) $$;
create function pg_temp.erro_ou_nulo(leitor uuid, alvo uuid) returns text language plpgsql as $$
begin
  perform pg_temp.perfil_de(leitor, alvo);
  return 'ok';
exception when others then return sqlstate;
end $$;

-- ── 2. perfil_publico: o caso positivo (profissional lido por contratante com candidatura) ────
select is(pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011') ->> 'foto_id',
  'c8250000-0000-4000-8000-0000000000a1', 'profissional, leitor com candidatura: foto_id é o id da mídia aprovada');

select matches(pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011') ->> 'foto_url',
  '^http://storage\.invalid/storage/v1/object/sign/midia-perfil/perfil/c8250000-0000-4000-8000-0000000000a1_thumb\.jpg\?token=[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$',
  'foto_url aponta para a miniatura, no formato de URL assinada do Storage');

-- O token: carga {url, scope=download, iat, exp = iat + 3600} e assinatura HS256 refeita à parte.
create temp table tok as
  select split_part(pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011') ->> 'foto_url', 'token=', 2) as t;
create function pg_temp.b64u_json(p text) returns jsonb language sql as
  $$ select convert_from(decode(translate(p, '-_', '+/') || repeat('=', (4 - length(p) % 4) % 4), 'base64'), 'utf8')::jsonb $$;

select is(pg_temp.b64u_json(split_part((select t from tok), '.', 2)) ->> 'url',
  'midia-perfil/perfil/c8250000-0000-4000-8000-0000000000a1_thumb.jpg', 'token: url = bucket/miniatura');
select is(pg_temp.b64u_json(split_part((select t from tok), '.', 2)) ->> 'scope', 'download', 'token: scope download');
select is((pg_temp.b64u_json(split_part((select t from tok), '.', 2)) ->> 'exp')::bigint
        - (pg_temp.b64u_json(split_part((select t from tok), '.', 2)) ->> 'iat')::bigint,
  3600::bigint, 'token: vale por 1 hora');
select is(split_part((select t from tok), '.', 3),
  translate(rtrim(encode(extensions.hmac(split_part((select t from tok), '.', 1) || '.' || split_part((select t from tok), '.', 2),
    'segredo-de-teste-storage-825-0123456789', 'sha256'), 'base64'), '='), '+/', '-_'),
  'token: assinatura HS256 com o segredo do Vault, refeita de forma independente');

select ok(position('c8250000-0000-4000-8000-0000000000a1.jpg' in
    pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011')::text) = 0,
  'o caminho do arquivo original (storage_path) nunca sai');
select ok(pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011') ?& array['id','tipo','nome','reputacao'],
  'o resto do perfil segue no corpo');

-- ── 3. perfil_publico: cada condição de ausência, uma por vez ─────────────────
-- 3.1 recurso desligado
update privado.configuracao_app set foto_de_perfil = false;
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011') ?| array['foto_url','foto_id']),
  'recurso foto_de_perfil desligado: as duas chaves ausentes');
select is(pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011') ->> 'nome', 'Conta 1',
  'recurso desligado: o resto do perfil responde como antes');
update privado.configuracao_app set foto_de_perfil = true;

-- 3.2 sem vínculo de leitura (contratante da casa Y)
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000004', 'c8250000-0000-4000-8000-000000000011') ?| array['foto_url','foto_id']),
  'sem vínculo (casa Y): as duas chaves ausentes');
select is(pg_temp.perfil_de('c8250000-0000-4000-8000-000000000004', 'c8250000-0000-4000-8000-000000000011') ->> 'nome', 'Conta 1',
  'sem vínculo: o perfil base continua respondendo');

-- 3.3 foto que não está aprovada
update privado.midia set estado = 'em_analise' where id = 'c8250000-0000-4000-8000-0000000000a1';
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011') ?| array['foto_url','foto_id']),
  'foto em análise: as duas chaves ausentes');
update privado.midia set estado = 'recusada' where id = 'c8250000-0000-4000-8000-0000000000a1';
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011') ?| array['foto_url','foto_id']),
  'foto recusada: as duas chaves ausentes');
update privado.midia set estado = 'nao_publicada' where id = 'c8250000-0000-4000-8000-0000000000a1';
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011') ?| array['foto_url','foto_id']),
  'foto não publicada: as duas chaves ausentes');
update privado.midia set estado = 'aprovada' where id = 'c8250000-0000-4000-8000-0000000000a1';

-- 3.4 titular suspenso (RN13) e titular com conta encerrada (RF25)
update public.usuario set estado = 'suspensa' where id = 'c8250000-0000-4000-8000-000000000001';
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011') ?| array['foto_url','foto_id']),
  'titular suspenso: as duas chaves ausentes');
update public.usuario set estado = 'anonimizada', anonimizado_em = now() where id = 'c8250000-0000-4000-8000-000000000001';
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011') ?| array['foto_url','foto_id']),
  'titular com conta encerrada: as duas chaves ausentes');
update public.usuario set estado = 'ativa', anonimizado_em = null where id = 'c8250000-0000-4000-8000-000000000001';

-- 3.5 segredo do Storage ausente: a foto some, e a leitura do perfil continua de pé
delete from vault.secrets where name = 'storage_jwt_secret';
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011') ?| array['foto_url','foto_id']),
  'sem segredo do Storage: as duas chaves ausentes');
select is(pg_temp.erro_ou_nulo('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000011'), 'ok',
  'sem segredo do Storage: perfil_publico NÃO falha');
select vault.create_secret('segredo-de-teste-storage-825-0123456789', 'storage_jwt_secret');

-- 3.6 leitor do papel errado (profissional lendo foto de profissional)
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000005', 'c8250000-0000-4000-8000-000000000011') ?| array['foto_url','foto_id']),
  'profissional lendo foto de profissional: as duas chaves ausentes');

-- 3.7 só chamada, sem candidatura, turno nem equipe: o contrato 0.2.54 não a conta para foto de
-- profissional. O alvo é C (foto aprovada); a casa X o vê pela candidatura, a casa Y só tem a chamada.
select is(pg_temp.perfil_de('c8250000-0000-4000-8000-000000000003', 'c8250000-0000-4000-8000-000000000017') ->> 'foto_id',
  'c8250000-0000-4000-8000-0000000000a7', 'controle: a casa X, com candidatura, vê a foto de C');
insert into public.chamada (id, vaga_id, profissional_id, estabelecimento_id, criada_por, expira_em, chave)
select 'c8250000-0000-4000-8000-0000000000c9', v.id, 'c8250000-0000-4000-8000-000000000017', e.id,
       'c8250000-0000-4000-8000-000000000004', '2027-01-14 00:00:00+00', gen_random_uuid()
  from public.vaga v, public.estabelecimento e where v.local = 'CLS 4250 Foto' and e.nome = 'Bar Foto Y';
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000004', 'c8250000-0000-4000-8000-000000000017') ?| array['foto_url','foto_id']),
  'casa só com chamada ao profissional: foto de profissional ausente (vínculo do contrato)');
delete from public.chamada where id = 'c8250000-0000-4000-8000-0000000000c9';

-- ── 4. perfil_publico de estabelecimento: leitor profissional ─────────────────
select is(pg_temp.perfil_de('c8250000-0000-4000-8000-000000000001', pg_temp.casa_x()) ->> 'foto_id',
  'c8250000-0000-4000-8000-0000000000b1', 'estabelecimento, profissional com candidatura: foto_id da logo');
select is(pg_temp.perfil_de('c8250000-0000-4000-8000-000000000006', pg_temp.casa_x()) ->> 'foto_id',
  'c8250000-0000-4000-8000-0000000000b1', 'estabelecimento, profissional só com chamada: foto_id da logo');
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000005', pg_temp.casa_x()) ?| array['foto_url','foto_id']),
  'estabelecimento, profissional sem vínculo: as duas chaves ausentes');
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000004', pg_temp.casa_x()) ?| array['foto_url','foto_id']),
  'estabelecimento lido por contratante: as duas chaves ausentes (leitor do papel errado)');
update public.usuario set estado = 'suspensa' where id = 'c8250000-0000-4000-8000-000000000003';
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000001', pg_temp.casa_x()) ?| array['foto_url','foto_id']),
  'estabelecimento, titular da logo suspenso: as duas chaves ausentes');
update public.usuario set estado = 'ativa' where id = 'c8250000-0000-4000-8000-000000000003';
update privado.configuracao_app set foto_de_perfil = false;
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000001', pg_temp.casa_x()) ?| array['foto_url','foto_id']),
  'estabelecimento, recurso desligado: as duas chaves ausentes');
update privado.configuracao_app set foto_de_perfil = true;
update privado.midia set estado = 'em_analise' where id = 'c8250000-0000-4000-8000-0000000000b1';
select ok(not (pg_temp.perfil_de('c8250000-0000-4000-8000-000000000001', pg_temp.casa_x()) ?| array['foto_url','foto_id']),
  'estabelecimento, logo não aprovada: as duas chaves ausentes');
update privado.midia set estado = 'aprovada' where id = 'c8250000-0000-4000-8000-0000000000b1';

-- ── 5. candidatos_da_vaga ─────────────────────────────────────────────────────
create temp table cand as
  select pg_temp.como('c8250000-0000-4000-8000-000000000003',
    format('select public.candidatos_da_vaga(%L::uuid)', pg_temp.vaga_x())) as j;
select is((select count(*)::int from jsonb_array_elements((select j from cand))), 3, 'candidatos_da_vaga: os três candidatos listados');
select is((select e -> 'profissional' ->> 'foto_id' from jsonb_array_elements((select j from cand)) e
            where e -> 'profissional' ->> 'id' = 'c8250000-0000-4000-8000-000000000011'),
  'c8250000-0000-4000-8000-0000000000a1', 'candidatos_da_vaga: candidato com foto aprovada traz foto_id');
select ok((select (e -> 'profissional') ? 'foto_url' from jsonb_array_elements((select j from cand)) e
            where e -> 'profissional' ->> 'id' = 'c8250000-0000-4000-8000-000000000011'),
  'candidatos_da_vaga: candidato com foto aprovada traz foto_url');
select ok((select not ((e -> 'profissional') ?| array['foto_url','foto_id']) from jsonb_array_elements((select j from cand)) e
            where e -> 'profissional' ->> 'id' = 'c8250000-0000-4000-8000-000000000012'),
  'candidatos_da_vaga: candidato com foto em análise não traz as chaves');
update public.usuario set estado = 'suspensa' where id = 'c8250000-0000-4000-8000-000000000007';
select ok((select not ((e -> 'profissional') ?| array['foto_url','foto_id'])
             from jsonb_array_elements(pg_temp.como('c8250000-0000-4000-8000-000000000003',
               format('select public.candidatos_da_vaga(%L::uuid)', pg_temp.vaga_x()))) e
            where e -> 'profissional' ->> 'id' = 'c8250000-0000-4000-8000-000000000017'),
  'candidatos_da_vaga: candidato suspenso com foto aprovada não traz as chaves');
update public.usuario set estado = 'ativa' where id = 'c8250000-0000-4000-8000-000000000007';

-- ── 6. detalhe_chamada ────────────────────────────────────────────────────────
update privado.recurso set ligado = true where chave = 'chamada_direta';
select is(pg_temp.como('c8250000-0000-4000-8000-000000000001',
    $$select public.detalhe_chamada('c8250000-0000-4000-8000-0000000000c1')$$) -> 'outra_parte' ->> 'foto_id',
  'c8250000-0000-4000-8000-0000000000b1', 'detalhe_chamada, lado do profissional: a outra parte (casa) traz foto_id');
select is(pg_temp.como('c8250000-0000-4000-8000-000000000003',
    $$select public.detalhe_chamada('c8250000-0000-4000-8000-0000000000c1')$$) -> 'outra_parte' ->> 'foto_id',
  'c8250000-0000-4000-8000-0000000000a1', 'detalhe_chamada, lado da casa: a outra parte (profissional com candidatura) traz foto_id');
select ok((pg_temp.como('c8250000-0000-4000-8000-000000000006',
    $$select public.detalhe_chamada('c8250000-0000-4000-8000-0000000000c6')$$) -> 'outra_parte') ?& array['foto_url','foto_id'],
  'detalhe_chamada, profissional só com chamada: a logo da casa vem (vínculo de chamada)');
select ok(not ((pg_temp.como('c8250000-0000-4000-8000-000000000003',
    $$select public.detalhe_chamada('c8250000-0000-4000-8000-0000000000c6')$$) -> 'outra_parte') ?| array['foto_url','foto_id']),
  'detalhe_chamada, lado da casa, profissional só com chamada: sem foto (vínculo do contrato)');
update privado.configuracao_app set foto_de_perfil = false;
select ok(not ((pg_temp.como('c8250000-0000-4000-8000-000000000001',
    $$select public.detalhe_chamada('c8250000-0000-4000-8000-0000000000c1')$$) -> 'outra_parte') ?| array['foto_url','foto_id']),
  'detalhe_chamada com o recurso desligado: sem as chaves');
update privado.configuracao_app set foto_de_perfil = true;

-- ── 7. A superfície não mudou ─────────────────────────────────────────────────
select has_function('public', 'perfil_publico', array['uuid'], 'perfil_publico mantém a assinatura');
select has_function('public', 'candidatos_da_vaga', array['uuid'], 'candidatos_da_vaga mantém a assinatura');
select has_function('public', 'detalhe_chamada', array['uuid'], 'detalhe_chamada mantém a assinatura');
select ok(not has_function_privilege('authenticated', 'privado.foto_de_perfil_projecao(uuid,uuid,uuid)', 'execute'),
  'o app não chama a projeção direto');
select ok(not has_function_privilege('anon', 'privado.token_de_leitura_storage(text,text,integer)', 'execute'),
  'o app não emite token de leitura direto');
select ok(has_function_privilege('authenticated', 'public.perfil_publico(uuid)', 'execute'),
  'perfil_publico segue executável por authenticated');

select * from finish();
rollback;
