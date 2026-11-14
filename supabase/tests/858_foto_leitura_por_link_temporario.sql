-- 858_foto_leitura_por_link_temporario.sql
--
-- A foto de perfil se lê por um link temporário da Edge Function `ler-midia` (B-020, contrato
-- 0.2.82), sem o segredo legado do Storage no Vault. O banco cunha um token opaco de 1 h DEPOIS
-- de conferir o vínculo, guarda só o SHA-256 e, quando a função pede, RECONFERE tudo, conta o uso e
-- devolve o caminho da miniatura (ou nulo). A função serve os bytes; nenhum link do Storage sai.
--
-- Casos do aceite: o dono vê a própria; a casa com vínculo vê; sem vínculo não vê (nem com id
-- adivinhado, nem com token de outra foto); recusada/removida não resolve; o link expira. E, do
-- parecer do Lince Codex: repasse × token incompatível, revogação (leitor, casa, bloqueio, recurso)
-- e o teto de 120 usos por token (replay).

begin;
insert into privado.ambiente values (true, true) on conflict (id) do update set eh_teste = true;
set local frila.agora = '2027-01-11 09:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste-858';
set local frila.ler_midia_function_url = 'http://funcoes.invalid/functions/v1/ler-midia';
select no_plan();

-- Nenhum segredo legado do Storage: a leitura não pode depender dele.
delete from vault.secrets where name in ('storage_jwt_secret', 'ler_midia_function_url');

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
-- 1 = profissional A (foto aprovada), 2 = profissional B (foto em análise),
-- 3 = contratante da casa X (vínculo com A pela candidatura), 4 = contratante da casa Y (sem vínculo).
insert into auth.users (id, aud, role, email) values
 ('c8580000-0000-4000-8000-000000000001','authenticated','authenticated','profa858@t.test'),
 ('c8580000-0000-4000-8000-000000000002','authenticated','authenticated','profb858@t.test'),
 ('c8580000-0000-4000-8000-000000000003','authenticated','authenticated','casax858@t.test'),
 ('c8580000-0000-4000-8000-000000000004','authenticated','authenticated','casay858@t.test');

select pg_temp.como(('c8580000-0000-4000-8000-00000000000' || n)::uuid,
  format($$select public.criar_conta(%L,%L,%L,'1992-05-10','2026-09-22')$$, p, 'Conta ' || n, '+556195558580' || n))
  from (values (1,'profissional'),(2,'profissional'),(3,'contratante'),(4,'contratante')) t(n,p);

select pg_temp.como('c8580000-0000-4000-8000-000000000003',
  $$select public.cadastrar_estabelecimento('Bar Link X','04252011000110','food_service','CLS 8580 Link','{"latitude":-15.79,"longitude":-47.88}'::jsonb,'Plano Piloto')$$);
select pg_temp.como('c8580000-0000-4000-8000-000000000004',
  $$select public.cadastrar_estabelecimento('Bar Link Y','68558622000173','food_service','CLN 8580 Link','{"latitude":-15.79,"longitude":-47.88}'::jsonb,'Plano Piloto')$$);

insert into public.profissional (id, usuario_id, ponto_base) values
 ('c8580000-0000-4000-8000-000000000011','c8580000-0000-4000-8000-000000000001','POINT(-47.88 -15.79)'),
 ('c8580000-0000-4000-8000-000000000012','c8580000-0000-4000-8000-000000000002','POINT(-47.88 -15.79)');
insert into public.profissional_funcao (profissional_id, funcao_id)
select p, (select id from public.funcao where nome = 'garçom')
  from unnest(array['c8580000-0000-4000-8000-000000000011','c8580000-0000-4000-8000-000000000012']::uuid[]) p;

select pg_temp.como('c8580000-0000-4000-8000-000000000003',
  format($$select public.publicar_vaga(
    (select id from public.estabelecimento where nome = 'Bar Link X'),
    (select id from public.funcao where nome = 'garçom'),
    '2027-01-15 18:00:00+00'::timestamptz, '2027-01-16 02:00:00+00'::timestamptz,
    'CLS 8580 Link', '{"latitude": -15.79, "longitude": -47.88}'::jsonb, 20000, 3,
    true, false, false, 'Gerente Marcos', 'selecao', %L::uuid, 'preto completo', false, null, 180,
    'Plano Piloto')$$, gen_random_uuid()));
select pg_temp.como(('c8580000-0000-4000-8000-00000000000' || n)::uuid,
  $$select public.candidatar((select id from public.vaga where local = 'CLS 8580 Link'))$$)
  from (values (1),(2)) t(n);

insert into privado.midia (id, dono_usuario_id, estabelecimento_id, dono_tipo, tipo, storage_path, mime, bytes, estado) values
 ('c8580000-0000-4000-8000-0000000000a1','c8580000-0000-4000-8000-000000000001',null,'profissional','foto_perfil','perfil/c8580000-0000-4000-8000-0000000000a1.jpg','image/jpeg',1000,'aprovada'),
 ('c8580000-0000-4000-8000-0000000000a2','c8580000-0000-4000-8000-000000000002',null,'profissional','foto_perfil','perfil/c8580000-0000-4000-8000-0000000000a2.jpg','image/jpeg',1000,'em_analise'),
 ('c8580000-0000-4000-8000-0000000000b1','c8580000-0000-4000-8000-000000000003',
   (select id from public.estabelecimento where nome = 'Bar Link X'),'estabelecimento','foto_perfil','perfil/c8580000-0000-4000-8000-0000000000b1.jpg','image/jpeg',1000,'aprovada');

update privado.configuracao_app set foto_de_perfil = true;

-- Atalhos.
create function pg_temp.perfil_de(leitor uuid, alvo uuid) returns jsonb language sql as
  $$ select pg_temp.como(leitor, format('select public.perfil_publico(%L::uuid)', alvo)) $$;
create function pg_temp.token_de(url text) returns text language sql as
  $$ select substring(url from '[?&]token=([0-9a-f]{64})$') $$;
create function pg_temp.resolver(midia uuid, token text) returns text language sql as
  $$ select privado.resolver_link_leitura_midia(midia, token) $$;
create function pg_temp.minha(leitor uuid, midia uuid) returns jsonb language sql as
  $$ select e from jsonb_array_elements(pg_temp.como(leitor, 'select public.minhas_midias()')) e
      where e ->> 'id' = midia::text $$;

-- ── 2. A casa com vínculo recebe o link e o link resolve para a miniatura ─────
create temp table lx as
  select pg_temp.perfil_de('c8580000-0000-4000-8000-000000000003', 'c8580000-0000-4000-8000-000000000011') ->> 'foto_url' as url;

select matches((select url from lx),
  '^http://funcoes\.invalid/functions/v1/ler-midia\?midia_id=c8580000-0000-4000-8000-0000000000a1&token=[0-9a-f]{64}$',
  'casa com vínculo: foto_url é o link da ler-midia, com midia_id e token opaco, sem o segredo legado no Vault');
select is(pg_temp.perfil_de('c8580000-0000-4000-8000-000000000003', 'c8580000-0000-4000-8000-000000000011') ->> 'foto_id',
  'c8580000-0000-4000-8000-0000000000a1', 'casa com vínculo: foto_id segue vindo junto');
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))),
  'perfil/c8580000-0000-4000-8000-0000000000a1_thumb.jpg', 'casa com vínculo: o link resolve para a miniatura');
select ok(position('c8580000-0000-4000-8000-0000000000a1.jpg' in (select url from lx)) = 0,
  'o caminho do arquivo original nunca sai no link');

-- O banco guarda só o hash do token, preso à mídia e ao leitor, com validade de 1 h.
select ok(not exists (select 1 from privado.midia_link_leitura where token_hash = pg_temp.token_de((select url from lx))),
  'o token em claro não fica no banco');
select is((select (l.midia_id, l.leitor_id, l.expira_em)::text from privado.midia_link_leitura l
            where l.token_hash = encode(sha256(convert_to(pg_temp.token_de((select url from lx)), 'UTF8')), 'hex')),
  ('c8580000-0000-4000-8000-0000000000a1'::uuid, 'c8580000-0000-4000-8000-000000000003'::uuid,
   '2027-01-11 10:00:00+00'::timestamptz)::text,
  'o banco guarda o SHA-256, a mídia, o leitor e expira_em = agora + 1 h');
select isnt(pg_temp.token_de(pg_temp.perfil_de('c8580000-0000-4000-8000-000000000003', 'c8580000-0000-4000-8000-000000000011') ->> 'foto_url'),
  pg_temp.token_de((select url from lx)), 'cada leitura cunha um token novo');

-- Cunhar e resolver vão em comandos separados, como na vida real (a leitura e o GET da função são
-- duas requisições).

-- A logo da casa, lida pelo profissional com candidatura.
create temp table logo as
  select pg_temp.perfil_de('c8580000-0000-4000-8000-000000000001',
           (select id from public.estabelecimento where nome = 'Bar Link X')) ->> 'foto_url' as url;
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000b1', pg_temp.token_de((select url from logo))),
  'perfil/c8580000-0000-4000-8000-0000000000b1_thumb.jpg', 'profissional com vínculo: o link da logo resolve');

-- candidatos_da_vaga também entrega um link que resolve.
create temp table cand as
  select e -> 'profissional' ->> 'foto_url' as url
    from jsonb_array_elements(pg_temp.como('c8580000-0000-4000-8000-000000000003',
           format('select public.candidatos_da_vaga(%L::uuid)', (select id from public.vaga where local = 'CLS 8580 Link')))) e
   where e -> 'profissional' ->> 'id' = 'c8580000-0000-4000-8000-000000000011';
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from cand))),
  'perfil/c8580000-0000-4000-8000-0000000000a1_thumb.jpg', 'candidatos_da_vaga: o link do candidato resolve');

-- ── 3. O dono vê a própria (minhas_midias.url) ────────────────────────────────
select matches(pg_temp.minha('c8580000-0000-4000-8000-000000000001', 'c8580000-0000-4000-8000-0000000000a1') ->> 'url',
  '^http://funcoes\.invalid/functions/v1/ler-midia\?midia_id=c8580000-0000-4000-8000-0000000000a1&token=[0-9a-f]{64}$',
  'dono: minhas_midias traz url para a foto aprovada');
create temp table propria as
  select pg_temp.minha('c8580000-0000-4000-8000-000000000001', 'c8580000-0000-4000-8000-0000000000a1') ->> 'url' as url;
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from propria))),
  'perfil/c8580000-0000-4000-8000-0000000000a1_thumb.jpg', 'dono: o link da própria foto resolve');
select ok(not (pg_temp.minha('c8580000-0000-4000-8000-000000000002', 'c8580000-0000-4000-8000-0000000000a2') ? 'url'),
  'dono: foto em análise não traz url');
create temp table logo_propria as
  select pg_temp.minha('c8580000-0000-4000-8000-000000000003', 'c8580000-0000-4000-8000-0000000000b1') ->> 'url' as url;
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000b1', pg_temp.token_de((select url from logo_propria))),
  'perfil/c8580000-0000-4000-8000-0000000000b1_thumb.jpg', 'membro da casa: o link da logo da própria casa resolve');

-- O link do dono não serve a outro leitor nem a outra foto: o hash está preso à mídia.
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000b1', pg_temp.token_de((select url from propria))), null,
  'link da foto do dono usado com o id da logo: nulo');

-- ── 4. Sem vínculo não vê: nem link, nem id adivinhado, nem token de outra foto ──
select ok(not (pg_temp.perfil_de('c8580000-0000-4000-8000-000000000004', 'c8580000-0000-4000-8000-000000000011') ? 'foto_url'),
  'casa sem vínculo: nenhum link');
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', repeat('a', 64)), null,
  'id certo com token adivinhado: nulo');
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000b1', pg_temp.token_de((select url from lx))), null,
  'token válido usado com o id de outra foto: nulo');
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', 'nao-e-token'), null, 'token malformado: nulo');
select is(pg_temp.resolver(null, pg_temp.token_de((select url from lx))), null, 'sem id: nulo');

-- Repasse válido × token incompatível. O token é portador: o resolvedor não sabe quem abriu, e o
-- link da casa X, repassado a qualquer pessoa, resolve por 1 h com os direitos da casa X (risco
-- aceito no desenho, o mesmo da URL assinada de antes, limitado pelo teto de usos). Já um token
-- que não é DAQUELA mídia não resolve nunca.
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))),
  'perfil/c8580000-0000-4000-8000-0000000000a1_thumb.jpg', 'repasse válido: o token da casa X resolve a mídia dele');
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a2', pg_temp.token_de((select url from lx))), null,
  'token incompatível: o mesmo token com o id de outra mídia do mesmo tipo não resolve');

-- Um hash válido gravado para quem NÃO tem vínculo (casa Y) não resolve: o vínculo é reconferido.
insert into privado.midia_link_leitura (token_hash, midia_id, leitor_id, expira_em) values
 (encode(sha256(convert_to(repeat('b', 64), 'UTF8')), 'hex'), 'c8580000-0000-4000-8000-0000000000a1',
  'c8580000-0000-4000-8000-000000000004', '2027-01-11 10:00:00+00');
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', repeat('b', 64)), null,
  'token no banco para leitor sem vínculo: nulo (o vínculo se reconfere na leitura)');

-- ── 5. Recusada, removida, suspensa, recurso desligado ou bloqueio: o link já emitido morre ──
update privado.midia set estado = 'removida' where id = 'c8580000-0000-4000-8000-0000000000a1';
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))), null,
  'foto removida depois do link: nulo');
update privado.midia set estado = 'recusada' where id = 'c8580000-0000-4000-8000-0000000000a1';
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))), null,
  'foto recusada depois do link: nulo');
select ok(not (pg_temp.minha('c8580000-0000-4000-8000-000000000001', 'c8580000-0000-4000-8000-0000000000a1') ? 'url'),
  'dono: foto recusada não traz url');
update privado.midia set estado = 'aprovada' where id = 'c8580000-0000-4000-8000-0000000000a1';
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))),
  'perfil/c8580000-0000-4000-8000-0000000000a1_thumb.jpg', 'controle: aprovada de novo, o mesmo link volta a resolver');

update public.usuario set estado = 'suspensa' where id = 'c8580000-0000-4000-8000-000000000001';
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))), null,
  'titular suspenso: nulo');
update public.usuario set estado = 'ativa' where id = 'c8580000-0000-4000-8000-000000000001';

update privado.configuracao_app set foto_de_perfil = false;
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))), null,
  'recurso desligado: nulo');
update privado.configuracao_app set foto_de_perfil = true;

insert into public.bloqueio (autor_id, bloqueado_id) values
 ('c8580000-0000-4000-8000-000000000001', 'c8580000-0000-4000-8000-000000000003');
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))), null,
  'bloqueio entre o titular e o leitor depois do link: nulo (RF26)');
delete from public.bloqueio where autor_id = 'c8580000-0000-4000-8000-000000000001';

-- O leitor que recebeu o link: anonimizado ou suspenso, o link morre.
update public.usuario set estado = 'anonimizada', anonimizado_em = now() where id = 'c8580000-0000-4000-8000-000000000003';
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))), null,
  'leitor anonimizado depois do link: nulo');
update public.usuario set estado = 'suspensa', anonimizado_em = null where id = 'c8580000-0000-4000-8000-000000000003';
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))), null,
  'leitor suspenso depois do link: nulo');
update public.usuario set estado = 'ativa' where id = 'c8580000-0000-4000-8000-000000000003';

-- O leitor sai da casa: o vínculo vinha pela casa, e o link morre.
create temp table membro_x as
  select * from public.membro_estabelecimento where usuario_id = 'c8580000-0000-4000-8000-000000000003';
delete from public.membro_estabelecimento where usuario_id = 'c8580000-0000-4000-8000-000000000003';
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))), null,
  'leitor fora da casa depois do link: nulo');
insert into public.membro_estabelecimento select * from membro_x;
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))),
  'perfil/c8580000-0000-4000-8000-0000000000a1_thumb.jpg', 'controle: de volta à casa, resolve');

-- Teto de 120 usos por token: replay e GETs concorrentes disputam o mesmo UPDATE atômico.
select ok((select usos from privado.midia_link_leitura
            where token_hash = encode(sha256(convert_to(pg_temp.token_de((select url from lx)), 'UTF8')), 'hex')) > 0,
  'cada GET resolvido conta um uso');
update privado.midia_link_leitura set usos = 119
 where token_hash = encode(sha256(convert_to(pg_temp.token_de((select url from lx)), 'UTF8')), 'hex');
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))),
  'perfil/c8580000-0000-4000-8000-0000000000a1_thumb.jpg', 'o 120º uso ainda resolve');
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))), null,
  'o 121º uso não resolve: teto por token');
update privado.midia_link_leitura set usos = 0
 where token_hash = encode(sha256(convert_to(pg_temp.token_de((select url from lx)), 'UTF8')), 'hex');

-- ── 6. O link expira em 1 h ───────────────────────────────────────────────────
select set_config('frila.agora', '2027-01-11 09:59:00+00', true);
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))),
  'perfil/c8580000-0000-4000-8000-0000000000a1_thumb.jpg', 'aos 59 min: resolve');
select set_config('frila.agora', '2027-01-11 10:00:01+00', true);
select is(pg_temp.resolver('c8580000-0000-4000-8000-0000000000a1', pg_temp.token_de((select url from lx))), null,
  'depois de 1 h: nulo');

-- Os hashes vencidos saem: a próxima leitura apaga os vencidos em lote.
select pg_temp.perfil_de('c8580000-0000-4000-8000-000000000003', 'c8580000-0000-4000-8000-000000000011');
select is((select count(*)::int from privado.midia_link_leitura where expira_em <= '2027-01-11 10:00:01+00'), 0,
  'uma leitura nova apaga os hashes vencidos');
select set_config('frila.agora', '2027-01-11 09:00:00+00', true);

-- ── 7. Superfície e privilégios ───────────────────────────────────────────────
select throws_ok(
  $$insert into privado.midia_link_leitura (token_hash, midia_id, leitor_id, expira_em)
    values ('token-em-claro-nao-e-hash', 'c8580000-0000-4000-8000-0000000000a1', 'c8580000-0000-4000-8000-000000000003', now())$$,
  '23514', null, 'a tabela só aceita SHA-256 em hex (64), nunca um token em claro de outro formato');
select ok(not has_function_privilege('authenticated', 'privado.resolver_link_leitura_midia(uuid,text)', 'execute'),
  'o app não resolve link direto');
select ok(not has_function_privilege('anon', 'privado.resolver_link_leitura_midia(uuid,text)', 'execute'),
  'anon não resolve link');
select ok(not has_function_privilege('authenticated', 'privado.cunhar_link_leitura_midia(uuid,uuid)', 'execute'),
  'o app não cunha link direto');
select ok(not has_table_privilege('authenticated', 'privado.midia_link_leitura', 'select'),
  'a tabela dos hashes não é legível pelo app');
select ok(has_function_privilege('service_role', 'privado.resolver_link_leitura_midia(uuid,text)', 'execute'),
  'service_role resolve (a Edge Function)');
select is((select provolatile from pg_proc where oid = 'privado.resolver_link_leitura_midia(uuid,text)'::regprocedure), 'v',
  'o resolvedor, que conta o uso, é VOLATILE');
select is((select provolatile from pg_proc where oid = 'privado.foto_de_perfil_projecao(uuid,uuid,uuid)'::regprocedure), 'v',
  'a projeção, que grava o hash, é VOLATILE');
select is((select provolatile from pg_proc where oid = 'privado.midia_em_json(privado.midia)'::regprocedure), 's',
  'midia_em_json segue STABLE: a url não entra nela');
select has_function('public', 'perfil_publico', array['uuid'], 'perfil_publico mantém a assinatura');
select has_function('public', 'minhas_midias', array[]::text[], 'minhas_midias mantém a assinatura');

select * from finish();
rollback;
