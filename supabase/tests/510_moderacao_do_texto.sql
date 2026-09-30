-- Moderação da diretriz 1.2: o filtro nos campos livres e o texto denunciado ocultado
-- em até 24 h (cartão FrpxqCxp · RF26, RN13 · App Store 1.2).
--
-- O que já estava medido, e por isso não se repete aqui: ocultar e reexibir a **vaga
-- inteira** é do cartão `Oxh0AWE7`, e o `460_operacao_equipe_frila.sql` cobre cada
-- caminho — vitrine, detalhe, candidatura, republicação, despacho e a ocorrência.
--
-- Aqui ficam as três coisas que faltavam:
--
--   · o critério 1 do cartão: vaga com termo ofensivo nas observações é recusada pelo
--     servidor. O filtro do Sprint 0 já cobria o campo; o que não existia era a asserção,
--     e filtro sem teste é filtro que a próxima refatoração remove de graça;
--   · o texto ocultado deixando de aparecer **sem** tirar a vaga do ar, e voltando
--     inteiro na reexibição;
--   · o prazo de 24 h, que até aqui era uma frase no cartão e agora é uma fila que a
--     Equipe consegue perguntar ao banco.
--
-- Ids próprios, começando em `12a00000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(36);

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

-- d1 publica; op1 é o membro da Equipe Frila que assina a moderação; e1 é profissional.
select pg_temp.autenticar('12a00000-0000-4000-8000-0000000000d1','d1@moderacao.test');
select pg_temp.autenticar('12a00000-0000-4000-8000-00000000000f','op@moderacao.test');
select pg_temp.autenticar('12a00000-0000-4000-8000-0000000000e1','e1@moderacao.test');

select pg_temp.como('12a00000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Casa da Moderação','+5561966660001','1980-01-01','2026-09-22') $$);
select pg_temp.como('12a00000-0000-4000-8000-00000000000f',
  $$ select public.criar_conta('contratante','Operador Frila','+5561966660002','1980-01-01','2026-09-22') $$);
select pg_temp.como('12a00000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Quem Trabalha','+5561966660011','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create temp table casa as
  select (pg_temp.como('12a00000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa da Moderação','04252011000110','food_service',
         'SCLN 410','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

-- Publica uma vaga com os campos livres à escolha de quem chama.
create function pg_temp.publicar(chave uuid, resp text, traje text, obs text) returns jsonb
language plpgsql as $corpo$
begin
  return pg_temp.como('12a00000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 410',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, %L, 'urgencia', %L, %L, true, %L) $sql$,
    (select id from casa), (select garcom from fn),
    privado.agora() + interval '3 days',
    privado.agora() + interval '3 days 6 hours',
    resp, chave, traje, obs));
end $corpo$;

-- ── 1. Critério 1: o filtro recusa o termo ofensivo nos campos livres ────────
--
-- A asserção do caminho limpo vem primeiro de propósito: sem ela, as três recusas abaixo
-- passariam igual se `publicar_vaga` estivesse recusando tudo.

create temp table limpa as
  select pg_temp.publicar('12a00000-0000-4000-8000-000000000001',
           'Seu Zé', 'camisa preta', 'Levar sapato fechado.') as j;

select isnt(
  (select (j->>'vaga_id')::uuid from limpa), null,
  'a vaga sem termo da lista é publicada: as recusas abaixo medem o filtro, e não a porta');

select throws_ok(
  $$ select pg_temp.publicar('12a00000-0000-4000-8000-000000000002',
       'Seu Zé', 'camisa preta', 'Não aceitamos babaca no salão.') $$,
  'PGRST',
  pg_temp.erro('campo_invalido', 'observacoes'),
  'critério 1: vaga com termo ofensivo nas observações é recusada, com o campo no details');

select throws_ok(
  $$ select pg_temp.publicar('12a00000-0000-4000-8000-000000000003',
       'Seu Zé', 'camisa de bosta', 'Nada demais.') $$,
  'PGRST',
  pg_temp.erro('campo_invalido', 'traje'),
  'e o mesmo vale para o traje');

select throws_ok(
  $$ select pg_temp.publicar('12a00000-0000-4000-8000-000000000004',
       'Seu Babaca', 'camisa preta', 'Nada demais.') $$,
  'PGRST',
  pg_temp.erro('campo_invalido', 'responsavel_local'),
  'e para o nome do responsável no local');

-- ── 2. O texto ocultado ──────────────────────────────────────────────────────

create temp table v as select (j->>'vaga_id')::uuid as id from limpa;

select has_function('privado', 'operacao_moderar_texto', array['uuid','text','text','uuid'],
  'privado.operacao_moderar_texto existe');

select is(
  (select bool_or(has_function_privilege(r, 'privado.operacao_moderar_texto(uuid,text,text,uuid)', 'execute'))
     from unnest(array['anon','authenticated']) r),
  false,
  'nem anon nem authenticated moderam texto: a Equipe age pela chave de serviço');

select is(
  has_function_privilege('service_role', 'privado.operacao_moderar_texto(uuid,text,text,uuid)', 'execute'),
  true,
  'o service_role modera');

select throws_ok(
  format($$ select privado.operacao_moderar_texto(%L, 'ocultar', 'teste',
              '12a00000-0000-4000-8000-0000000000d1') $$, (select id from v)),
  'PGRST', pg_temp.erro('campo_invalido', 'operador_id'),
  'quem publicou a vaga não assina a moderação dela');

-- Antes: o texto está lá.
select is(
  (select responsavel_local || '|' || traje || '|' || observacoes from public.vaga where id = (select id from v)),
  'Seu Zé|camisa preta|Levar sapato fechado.',
  'antes da moderação o texto livre está na vaga');

create temp table m as
  select privado.operacao_moderar_texto((select id from v), 'ocultar',
           'Observações com ofensa, denunciadas', '12a00000-0000-4000-8000-00000000000f') as j;

select is((select (j->>'texto_oculto')::boolean from m), true,
  'a moderação responde que o texto está oculto');

select is(
  (select observacoes from public.vaga where id = (select id from v)), null,
  'as observações somem da linha da vaga');

select is(
  (select traje from public.vaga where id = (select id from v)), null,
  'o traje some da linha da vaga');

select is(
  (select responsavel_local from public.vaga where id = (select id from v)),
  '[removido pela moderação]',
  'o responsável, que é not null, recebe o marcador neutro');

select is(privado.texto_da_vaga_oculto((select id from v)), true,
  'a vaga fica marcada como texto sob moderação');

-- O ponto do cartão: ocultar o texto NÃO tira a vaga do ar.
select is(privado.vaga_oculta((select id from v)), false,
  'ocultar o texto não oculta a vaga: quem tem turno confirmado não perde nada');

select isnt(
  (select pg_temp.como('12a00000-0000-4000-8000-0000000000e1',
     format($$ select public.detalhe_vaga(%L) $$, (select id from v)))),
  null,
  'o detalhe da vaga continua respondendo a quem não está nela');

select is(
  (select pg_temp.como('12a00000-0000-4000-8000-0000000000e1',
     format($$ select public.detalhe_vaga(%L) $$, (select id from v)))->>'observacoes'),
  null,
  'e o texto ocultado não aparece no detalhe');

select is(
  (select pg_temp.como('12a00000-0000-4000-8000-0000000000e1',
     format($$ select public.detalhe_vaga(%L) $$, (select id from v)))->>'traje'),
  null,
  'nem o traje');

-- O original não se perde: muda de lugar.
select is(
  (select observacoes from privado.texto_da_vaga_ocultado where vaga_id = (select id from v)),
  'Levar sapato fechado.',
  'o original fica guardado em privado, fora do PostgREST');

-- ── 3. A ocorrência ──────────────────────────────────────────────────────────

select is(
  (select tipo::text from public.ocorrencia where id = (select (j->>'ocorrencia_id')::uuid from m)),
  'suporte',
  'a moderação grava ocorrência de suporte, e não denúncia');

select is(
  (select autor_id from public.ocorrencia where id = (select (j->>'ocorrencia_id')::uuid from m)),
  '12a00000-0000-4000-8000-00000000000f'::uuid,
  'assinada pelo operador da Equipe Frila, e não por quem publicou');

select is(
  (select usuario_id from public.ocorrencia where id = (select (j->>'ocorrencia_id')::uuid from m)),
  '12a00000-0000-4000-8000-0000000000d1'::uuid,
  'com quem publicou como alvo');

select isnt(
  (select resolvido_em from public.ocorrencia where id = (select (j->>'ocorrencia_id')::uuid from m)),
  null,
  'e já nasce resolvida: a ação aconteceu no momento do registro');

-- ── 4. Reenvio e reexibição ──────────────────────────────────────────────────

select is(
  (privado.operacao_moderar_texto((select id from v), 'ocultar', 'de novo',
     '12a00000-0000-4000-8000-00000000000f')->>'ja_estava_oculto')::boolean,
  true,
  'reenviar ocultar devolve o que já foi feito');

select is(
  (select count(*)::int from public.ocorrencia
    where motivo like 'Moderação Diretriz 1.2 (texto):%'),
  1,
  'e não grava uma segunda ocorrência');

select lives_ok(
  format($$ select privado.operacao_moderar_texto(%L, 'reexibir', 'Analisado, texto liberado',
              '12a00000-0000-4000-8000-00000000000f') $$, (select id from v)),
  'a Equipe reexibe o texto');

select is(
  (select responsavel_local || '|' || traje || '|' || observacoes from public.vaga where id = (select id from v)),
  'Seu Zé|camisa preta|Levar sapato fechado.',
  'e ele volta inteiro, exatamente como estava');

select is(privado.texto_da_vaga_oculto((select id from v)), false,
  'a marca sai');

select is(
  (select count(*)::int from privado.texto_da_vaga_ocultado where vaga_id = (select id from v)),
  0,
  'e a cópia guardada some junto: o texto vive num lugar só');

select throws_ok(
  format($$ select privado.operacao_moderar_texto(%L, 'reexibir', 'de novo',
              '12a00000-0000-4000-8000-00000000000f') $$, (select id from v)),
  'PGRST', pg_temp.erro('campo_invalido', 'texto_nao_ocultado'),
  'reexibir texto que não foi ocultado é recusado');

select throws_ok(
  format($$ select privado.operacao_moderar_texto(%L, 'apagar', 'motivo',
              '12a00000-0000-4000-8000-00000000000f') $$, (select id from v)),
  'PGRST', pg_temp.erro('campo_invalido', 'acao'),
  'a ação é fechada em duas palavras: não há "apagar"');

-- ── 5. O prazo de 24 h da diretriz 1.2 ───────────────────────────────────────

select is(
  privado.prazo_de_moderacao('2026-09-30 10:00:00-03'::timestamptz),
  '2026-10-01 10:00:00-03'::timestamptz,
  '24 h corridas, e não dias úteis: a diretriz não pula o fim de semana');

-- A RN13 continua inteira e é outra coisa: 5 dias úteis para RESPONDER.
select isnt(
  privado.prazo_de_moderacao('2026-09-30 10:00:00-03'::timestamptz)::date,
  privado.prazo_de_resposta('2026-09-30 10:00:00-03'::timestamptz),
  'o prazo de agir no conteúdo não é o prazo de responder ao denunciante (RN13)');

insert into public.ocorrencia (id, tipo, autor_id, usuario_id, motivo, relato, chave_cliente, criada_em)
values ('12a00000-0000-4000-8000-00000000fa01', 'denuncia',
        '12a00000-0000-4000-8000-0000000000e1',
        '12a00000-0000-4000-8000-0000000000d1',
        'assedio', 'Relato qualquer com mais de dez caracteres.',
        '12a00000-0000-4000-8000-00000000cc01',
        privado.agora() - interval '30 hours');

select is(
  (select vencida from privado.moderacao_pendente()
    where ocorrencia_id = '12a00000-0000-4000-8000-00000000fa01'),
  true,
  'denúncia aberta há 30 h aparece na fila de plantão como vencida');

select is(
  (select tratar_ate from privado.moderacao_pendente()
    where ocorrencia_id = '12a00000-0000-4000-8000-00000000fa01'),
  privado.prazo_de_moderacao(privado.agora() - interval '30 hours'),
  'com o prazo calculado por uma definição só');

select is(
  (select count(*)::int from privado.moderacao_pendente() f
    join public.ocorrencia o on o.id = f.ocorrencia_id
   where o.resolvido_em is not null),
  0,
  'a fila não mostra o que já foi tratado');

select * from finish();
rollback;
