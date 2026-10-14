-- 640_contato_e_link_texto_vaga.sql
--
-- Cartão J5 (pBXTS4vv): Recusar telefone, e-mail e link no texto livre da vaga (RN10, decisão J5).
-- A regra de negócio RN10 estabelece que dados de contato entre contratante e
-- profissional só devem ser liberados após a confirmação do turno (via contato_do_turno).
-- Textos livres em publicar_vaga/republicar_vaga (e cadastrar_estabelecimento) são validados
-- contra padrões de contato/link para evitar burlar essa proteção.
--
-- Cobertura:
-- 1. Unidade: privado.contem_contato_ou_link (positivos, negativos, falsos positivos legítimos).
-- 2. Integração publicar_vaga: recusas por campo (local, responsavel_local, traje, observacoes).
-- 3. Caso legítimo com falsos positivos (horário, valor monetário, CEP, data, endereço de Brasília).
-- 4. Idempotência de publicar_vaga com texto válido.
-- 5. Integração republicar_vaga (sucesso com vaga limpa, idempotência e recusa se origem tiver contato).
-- 6. Integração cadastrar_estabelecimento (recusa de contato/link em nome e endereço).
-- 7. RN15 / LGPD: nenhuma ocorrência grava dados de contato ou links rejeitados.
--
-- Ids de teste prefixados com c5000000.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(65);

-- ── 1. Testes unitários de privado.contem_contato_ou_link ───────────────────

-- Nulos e vazios
select ok(not privado.contem_contato_ou_link(null), 'nulo não contém contato');
select ok(not privado.contem_contato_ou_link(''), 'vazio não contém contato');

-- Telefones e WhatsApp (devem ser detectados)
select ok(privado.contem_contato_ou_link('99991234'), 'telefone fixo 8 dígitos puro');
select ok(privado.contem_contato_ou_link('3321-1234'), 'telefone fixo 8 dígitos com hífen');
select ok(privado.contem_contato_ou_link('987654321'), 'celular 9 dígitos puro');
select ok(privado.contem_contato_ou_link('98765-4321'), 'celular 9 dígitos com hífen');
select ok(privado.contem_contato_ou_link('6133211234'), 'fixo com DDD 10 dígitos');
select ok(privado.contem_contato_ou_link('(61) 3321-1234'), 'fixo com DDD formatado');
select ok(privado.contem_contato_ou_link('61987654321'), 'celular com DDD 11 dígitos');
select ok(privado.contem_contato_ou_link('(61) 98765-4321'), 'celular com DDD formatado');
select ok(privado.contem_contato_ou_link('61 9 8765-4321'), 'celular com espaços');
select ok(privado.contem_contato_ou_link('+5561987654321'), 'com DDI +55');
select ok(privado.contem_contato_ou_link('+55 (61) 98765-4321'), 'com DDI e máscara');
select ok(privado.contem_contato_ou_link('chama no zap: 61-99999-8888'), 'texto com zap e hífen');
select ok(privado.contem_contato_ou_link('meu cel 6 1 9 8 7 6 5 4 3 2 1'), 'burlar com dígitos espaçados');
select ok(privado.contem_contato_ou_link('61.98765.4321'), 'separado por pontos');

-- E-mails (devem ser detectados)
select ok(privado.contem_contato_ou_link('contato@empresa.com'), 'e-mail padrão');
select ok(privado.contem_contato_ou_link('meu.email+frila@gmail.com'), 'e-mail com plus e subdomínio');
select ok(privado.contem_contato_ou_link('financeiro@bar.com.br'), 'e-mail com .com.br');
select ok(privado.contem_contato_ou_link('envie para vaga @ restaurante.com.br'), 'e-mail com espaço ao redor do @');

-- Links, URLs e encurtadores (devem ser detectados)
select ok(privado.contem_contato_ou_link('http://restaurante.com'), 'URL http');
select ok(privado.contem_contato_ou_link('https://instagram.com/meubar'), 'URL https');
select ok(privado.contem_contato_ou_link('www.restaurante.com.br'), 'link www');
select ok(privado.contem_contato_ou_link('wa.me/5561999999999'), 'encurtador wa.me');
select ok(privado.contem_contato_ou_link('bit.ly/vaga-urgente'), 'encurtador bit.ly');
select ok(privado.contem_contato_ou_link('t.me/grupo_vagas'), 'encurtador t.me');
select ok(privado.contem_contato_ou_link('linktr.ee/bardozeca'), 'encurtador linktr.ee');
select ok(privado.contem_contato_ou_link('meusite.com.br'), 'domínio com .com.br');
select ok(privado.contem_contato_ou_link('cardapio.io'), 'domínio com .io');
select ok(privado.contem_contato_ou_link('link.dev'), 'domínio com .dev');
select ok(privado.contem_contato_ou_link('clube.app/vagas'), 'domínio com .app e path');

-- Falsos positivos que DEVEM PASSAR (devem retornar false)
select ok(not privado.contem_contato_ou_link('14:00'), 'horário simples');
select ok(not privado.contem_contato_ou_link('18h30'), 'horário com h');
select ok(not privado.contem_contato_ou_link('das 14:00 às 22:00'), 'intervalo de horários às');
select ok(not privado.contem_contato_ou_link('18:00 - 02:00'), 'intervalo de horários com hífen');
select ok(not privado.contem_contato_ou_link('R$ 1.200,00'), 'valor em reais com milhar');
select ok(not privado.contem_contato_ou_link('R$ 150,00'), 'valor em reais padrão');
select ok(not privado.contem_contato_ou_link('150 reais'), 'valor em reais por extenso');
select ok(not privado.contem_contato_ou_link('R$ 80,00'), 'valor curto');
select ok(not privado.contem_contato_ou_link('CEP 70000-000'), 'CEP com prefixo e hífen');
select ok(not privado.contem_contato_ou_link('70000-000'), 'CEP com hífen');
select ok(not privado.contem_contato_ou_link('CEP: 70000-000'), 'CEP com dois pontos');
select ok(not privado.contem_contato_ou_link('CEP 70000000'), 'CEP sem hífen com prefixo CEP');
select ok(not privado.contem_contato_ou_link('Quadra 102 Bloco B Lote 4'), 'endereço de Brasília quadra e bloco');
select ok(not privado.contem_contato_ou_link('SCS Quadra 4 Bloco A Sala 204'), 'endereço comercial de Brasília');
select ok(not privado.contem_contato_ou_link('Rua 3 Chácara 12 Casa 5'), 'endereço com vários números curtos');
select ok(not privado.contem_contato_ou_link('15/10/2026'), 'data DD/MM/AAAA');
select ok(not privado.contem_contato_ou_link('15-10-2026'), 'data com hífen');
select ok(not privado.contem_contato_ou_link('15.10.2026'), 'data com ponto');
select ok(not privado.contem_contato_ou_link('2026-10-15'), 'data no formato ISO');
select ok(not privado.contem_contato_ou_link('Camisa preta e avental limpo'), 'traje legítimo');
select ok(not privado.contem_contato_ou_link('Entrar pelos fundos e procurar o gerente'), 'observações legítimas');

-- ── 2. Setup para testes de integração de RPCs ──────────────────────────────

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
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

select pg_temp.autenticar('c5000000-0000-4000-8000-0000000000d1', 'dona.j5@vaga.test');

select pg_temp.como('c5000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona J5','+5561999990501','1985-01-01','2026-09-22') $$);

create temp table fn_j5 as select (select id from public.funcao where nome = 'garçom') as garcom;

create temp table est_j5 as
  select (pg_temp.como('c5000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Bar do J5','33014556000196','food_service',
         'SCLN 410 Bloco B Sala 101','{"latitude":-15.7910,"longitude":-47.8860}', 'Plano Piloto') $$)->>'id')::uuid as id;

-- Função auxiliar para publicar vaga na sessão autenticada da contratante
create function pg_temp.publicar_custom(
  chave uuid,
  loc text,
  resp text,
  traje text,
  obs text
) returns jsonb
language plpgsql as $corpo$
begin
  return pg_temp.como('c5000000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, %L,
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, %L, 'urgencia', %L, %L, true, %L, 240, 'Plano Piloto') $sql$,
    (select id from est_j5), (select garcom from fn_j5),
    privado.agora() + interval '2 days',
    privado.agora() + interval '2 days 6 hours',
    loc, resp, chave, traje, obs));
end $corpo$;

-- ── 3. Caso legítimo com falsos positivos aceitos em publicar_vaga ──────────

create temp table chave_limpa as select gen_random_uuid() as k;

create temp table vaga_legitima as
  select pg_temp.publicar_custom(
    (select k from chave_limpa),
    'SCS Quadra 4 Bloco A Sala 204, CEP 70304-000',
    'Gerente Marcos',
    'Camisa preta e calça jeans',
    'Turno das 18:00 às 02:00 em 15/10/2026. Diária de R$ 180,00. Entrar pelos fundos.'
  ) as j;

select isnt(
  (select (j->>'vaga_id')::uuid from vaga_legitima), null,
  'vaga com falsos positivos legítimos (horário, moeda, CEP, data, endereço de Brasília) é aceita');

-- ── 4. Idempotência de publicar_vaga com texto válido ───────────────────────

select is(
  (select (pg_temp.publicar_custom(
    (select k from chave_limpa),
    'SCS Quadra 4 Bloco A Sala 204, CEP 70304-000',
    'Gerente Marcos',
    'Camisa preta e calça jeans',
    'Turno das 18:00 às 02:00 em 15/10/2026. Diária de R$ 180,00. Entrar pelos fundos.'
  )->>'vaga_id')::uuid),
  (select (j->>'vaga_id')::uuid from vaga_legitima),
  'idempotência: reenviar com a mesma chave do cliente retorna o mesmo vaga_id');

-- ── 5. Recusas de publicar_vaga por campo contaminado ───────────────────────

select throws_ok(
  $$ select pg_temp.publicar_custom(
       gen_random_uuid(),
       'Bar Central - Fone (61) 99999-8888',
       'Gerente Marcos',
       'Camisa preta',
       'Observações limpas'
     ) $$,
  'PGRST',
  pg_temp.erro('campo_invalido', 'local'),
  'publicar_vaga recusa telefone no campo local');

select throws_ok(
  $$ select pg_temp.publicar_custom(
       gen_random_uuid(),
       'SCS Quadra 4 Bloco A',
       'Marcos zap 61999998888',
       'Camisa preta',
       'Observações limpas'
     ) $$,
  'PGRST',
  pg_temp.erro('campo_invalido', 'responsavel_local'),
  'publicar_vaga recusa telefone no campo responsavel_local');

select throws_ok(
  $$ select pg_temp.publicar_custom(
       gen_random_uuid(),
       'SCS Quadra 4 Bloco A',
       'Gerente Marcos',
       'Veja o traje em https://instagram.com/traje_bar',
       'Observações limpas'
     ) $$,
  'PGRST',
  pg_temp.erro('campo_invalido', 'traje'),
  'publicar_vaga recusa URL no campo traje');

select throws_ok(
  $$ select pg_temp.publicar_custom(
       gen_random_uuid(),
       'SCS Quadra 4 Bloco A',
       'Gerente Marcos',
       'Camisa preta',
       'Dúvidas chamar no e-mail vagas@bardoj5.com'
     ) $$,
  'PGRST',
  pg_temp.erro('campo_invalido', 'observacoes'),
  'publicar_vaga recusa e-mail no campo observacoes');

select throws_ok(
  $$ select pg_temp.publicar_custom(
       gen_random_uuid(),
       'SCS Quadra 4 Bloco A',
       'Gerente Marcos',
       'Camisa preta',
       'Chame no wa.me/5561999998888 para acertar antes'
     ) $$,
  'PGRST',
  pg_temp.erro('campo_invalido', 'observacoes'),
  'publicar_vaga recusa encurtador wa.me no campo observacoes');

-- ── 6. republicar_vaga: sucesso, idempotência e recusa se origem tiver contato

create temp table chave_rep as select gen_random_uuid() as k;

create temp table vaga_republicada as
  select (pg_temp.como('c5000000-0000-4000-8000-0000000000d1', format(
    $$ select public.republicar_vaga(%L::uuid, %L::timestamptz, %L::timestamptz, %L::uuid) $$,
    (select (j->>'vaga_id')::uuid from vaga_legitima),
    privado.agora() + interval '5 days',
    privado.agora() + interval '5 days 6 hours',
    (select k from chave_rep)
  ))->>'vaga_id')::uuid as id;

select isnt((select id from vaga_republicada), null,
  'republicar_vaga replica a vaga limpa com sucesso');

select is(
  (pg_temp.como('c5000000-0000-4000-8000-0000000000d1', format(
    $$ select public.republicar_vaga(%L::uuid, %L::timestamptz, %L::timestamptz, %L::uuid) $$,
    (select (j->>'vaga_id')::uuid from vaga_legitima),
    privado.agora() + interval '5 days',
    privado.agora() + interval '5 days 6 hours',
    (select k from chave_rep)
  ))->>'vaga_id')::uuid,
  (select id from vaga_republicada),
  'republicar_vaga é idempotente com a mesma chave do cliente');

-- Se uma vaga de origem tivesse dados de contato (ex: legada no banco), republicar_vaga recusa
create temp table vaga_legada as
  with ins as (
    insert into public.vaga (
      estabelecimento_id, funcao_id, publicado_por,
      inicio_em, fim_em, local, ponto, valor_centavos, posicoes,
      inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
      modo, chave_cliente, traje, participa_rateio,
      observacoes, alerta_antecedencia, regiao_administrativa, estado
    ) values (
      (select id from est_j5), (select garcom from fn_j5), 'c5000000-0000-4000-8000-0000000000d1',
      privado.agora() + interval '1 day', privado.agora() + interval '1 day 6 hours',
      'SCLN 410', 'POINT(-47.8860 -15.7910)'::extensions.geography,
      18000, 1, true, true, false, 'Gerente',
      'urgencia', gen_random_uuid(), 'camisa preta', true,
      'Contato direto zap 61999990000', '04:00:00'::interval, 'Plano Piloto', 'publicada'
    ) returning id
  )
  select id from ins;

select throws_ok(
  format(
    $$ select pg_temp.como('c5000000-0000-4000-8000-0000000000d1', format(
         'select public.republicar_vaga(%%L::uuid, %%L::timestamptz, %%L::timestamptz, %%L::uuid)',
         %L, privado.agora() + interval '6 days', privado.agora() + interval '6 days 6 hours', gen_random_uuid())) $$,
    (select id from vaga_legada)),
  'PGRST',
  pg_temp.erro('campo_invalido', 'observacoes'),
  'republicar_vaga recusa republicação se a origem continha contato nas observações');

-- ── 7. cadastrar_estabelecimento: recusa de contato/link ─────────────────────

select throws_ok(
  $$ select pg_temp.como('c5000000-0000-4000-8000-0000000000d1',
       $sql$ select public.cadastrar_estabelecimento('Bar www.bar.com','61695227000193','evento',
            'SIA Trecho 3','{"latitude":-15.8,"longitude":-47.9}'::jsonb, 'SIA') $sql$) $$,
  'PGRST',
  pg_temp.erro('campo_invalido', 'nome'),
  'cadastrar_estabelecimento recusa URL no nome');

select throws_ok(
  $$ select pg_temp.como('c5000000-0000-4000-8000-0000000000d1',
       $sql$ select public.cadastrar_estabelecimento('Bar do SIA','61695227000193','evento',
            'SIA Trecho 3 ligar 61988887777','{"latitude":-15.8,"longitude":-47.9}'::jsonb, 'SIA') $sql$) $$,
  'PGRST',
  pg_temp.erro('campo_invalido', 'endereco'),
  'cadastrar_estabelecimento recusa telefone no endereço');

-- ── 8. RN15 / LGPD: nenhuma ocorrência grava dados de contato ou links ───────

select is(
  (select count(*)::int from public.ocorrencia
    where motivo ~* '99999' or motivo ~* 'instagram' or motivo ~* 'bardoj5\.com'
       or coalesce(relato, '') ~* '99999' or coalesce(relato, '') ~* 'instagram' or coalesce(relato, '') ~* 'bardoj5\.com'),
  0,
  'RN15 / LGPD: nenhuma ocorrência foi gravada contendo os dados de contato rejeitados');

rollback;
