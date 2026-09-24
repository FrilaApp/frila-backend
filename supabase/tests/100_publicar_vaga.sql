-- `publicar_vaga`: a vaga entra no ar e o despacho fica para depois.
--
-- É a primeira escrita que cria mais de uma linha e a primeira que deixa trabalho
-- para outro processo. Quatro coisas são cobradas aqui pela primeira vez:
--
--   RN02  vaga incompleta não existe — cada campo obrigatório recusa com o seu nome
--   RN03  uma posição por unidade pedida, todas abertas
--   B15   publicar não espera o despacho: a RPC só deixa a mensagem na fila
--   RF04  a chave do cliente torna o reenvio seguro
--
-- Cada recusa é conferida nos dois eixos, como em 080_criar_conta.sql: o `sqlstate`
-- `PGRST` e o envelope inteiro, que fixa `code` e `details`. O **status** HTTP só o
-- `ciclo-completo.sh` alcança, e cada recusa daqui tem uma linha lá.
--
-- Os documentos e os ids do cenário não são tocados: este arquivo cria as próprias
-- contas, com ids que começam em `f0000000`, e conta apenas o que ele mesmo criou.

begin;
select plan(37);

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

-- d1: dona do bar, que publica · d2: outra contratante, sem vínculo com o bar
-- d3: contratante suspensa, também administradora · p1: profissional
select pg_temp.autenticar('f0000000-0000-4000-8000-0000000000d1','dona@vaga.test');
select pg_temp.autenticar('f0000000-0000-4000-8000-0000000000d2','outra@vaga.test');
select pg_temp.autenticar('f0000000-0000-4000-8000-0000000000d3','suspensa@vaga.test');
select pg_temp.autenticar('f0000000-0000-4000-8000-0000000000e1','garcom@vaga.test');

select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona do Bar','+5561999990201','1980-01-01','2026-09-22') $$);
select pg_temp.como('f0000000-0000-4000-8000-0000000000d2',
  $$ select public.criar_conta('contratante','Outra Dona','+5561999990202','1981-01-01','2026-09-22') $$);
select pg_temp.como('f0000000-0000-4000-8000-0000000000d3',
  $$ select public.criar_conta('contratante','Dona Suspensa','+5561999990203','1982-01-01','2026-09-22') $$);
select pg_temp.como('f0000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Garçom da Vaga','+5561999990204','1995-01-01','2026-09-22') $$);

-- O bar de onde as vagas saem. CNPJ com dígito verificador calculado à parte, e
-- diferente dos do cenário e do 090.
create temp table bar as select (pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
  $$ select public.cadastrar_estabelecimento('Bar da Vaga','04252011000110','food_service',
       'SCLN 406, Asa Norte','{"latitude":-15.7890,"longitude":-47.8850}') $$)->>'id')::uuid as id;

-- A conta suspensa também administra o bar: sem isso, a recusa por suspensão sairia
-- como `sem_permissao` por falta de vínculo e o teste passaria pelo motivo errado.
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select 'f0000000-0000-4000-8000-0000000000d3', id, 'administrador' from bar;
update public.usuario set estado = 'suspensa'
 where id = 'f0000000-0000-4000-8000-0000000000d3';

create temp table cat as select id from public.funcao where nome = 'garçom';

-- Um horário no futuro, longe o bastante para o modo seleção também caber.
create temp table quando as
  select (privado.agora() + interval '3 days') as inicio,
         (privado.agora() + interval '3 days 6 hours') as fim;

-- ── Sem sessão não há publicação ───────────────────────────────────────────────
select throws_ok(
  format($$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
              '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
              18000, 3, true, true, false, 'Seu Zé', 'urgencia',
              '11111111-1111-4111-8111-111111111111'::uuid) $$,
         (select id from bar), (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não se publica vaga');

-- ── RN25: a publicação é do contratante ────────────────────────────────────────
select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000e1',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
             '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 1, true, true, false, 'Seu Zé', 'urgencia',
             '11111111-1111-4111-8111-111111111112'::uuid) $x$) $$,
         (select id from bar), (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "perfil_incompativel", "message" : "perfil_incompativel", "details" : null, "hint" : null}',
  'RN25: conta de profissional não publica vaga (422 perfil_incompativel)');

-- ── RF21: só quem é do estabelecimento publica por ele ─────────────────────────
select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d2',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
             '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 1, true, true, false, 'Seu Zé', 'urgencia',
             '11111111-1111-4111-8111-111111111113'::uuid) $x$) $$,
         (select id from bar), (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'RF21: quem não é membro do estabelecimento recebe 403 sem_permissao');

-- ── RN13: conta suspensa não publica, e o motivo vai no details ────────────────
select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d3',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
             '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 1, true, true, false, 'Seu Zé', 'urgencia',
             '11111111-1111-4111-8111-111111111114'::uuid) $x$) $$,
         (select id from bar), (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : "conta_suspensa", "hint" : null}',
  'RN13: conta suspensa recebe sem_permissao com details conta_suspensa');

-- ── O caminho feliz ────────────────────────────────────────────────────────────
create temp table v as select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
  format($$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
       '{"latitude":-15.7890,"longitude":-47.8850}'::jsonb,
       18000, 3, true, true, false, 'Seu Zé', 'urgencia',
       '22222222-2222-4222-8222-222222222222'::uuid,
       'Camisa preta', true, 'Levar avental', 240) $$,
    (select id from bar), (select id from cat),
    (select inicio from quando), (select fim from quando))) as j;

select is(
  (select array_agg(k order by k) from v, jsonb_object_keys(v.j) k),
  array['posicoes','vaga_id'],
  'a resposta traz exatamente os campos do schema VagaPublicada do contrato');

select is((select jsonb_array_length(j->'posicoes') from v), 3,
  'RN03: três posições pedidas, três ids devolvidos');

select is(
  (select count(*)::int from public.posicao
    where vaga_id = (select (j->>'vaga_id')::uuid from v)),
  3,
  'RN03: e três linhas em posicao, de fato');

select is(
  (select count(distinct estado)::int || ':' || min(estado)::text from public.posicao
    where vaga_id = (select (j->>'vaga_id')::uuid from v)),
  '1:aberta',
  'RN03: todas nascem abertas, e nenhuma com profissional');

select is(
  (select count(*)::int from public.posicao
    where vaga_id = (select (j->>'vaga_id')::uuid from v) and profissional_id is not null),
  0,
  'e nenhuma nasce com profissional');

-- A posição carrega início e fim desnormalizados da vaga: é deles que o EXCLUDE de
-- RN21 vive, e um índice GIST não atravessa junção. Copiar errado aqui desliga a
-- regra de sobreposição para toda vaga publicada por esta RPC.
select is(
  (select count(*)::int from public.posicao p join public.vaga g on g.id = p.vaga_id
    where p.vaga_id = (select (j->>'vaga_id')::uuid from v)
      and (p.inicio_em <> g.inicio_em or p.fim_em <> g.fim_em)),
  0,
  'RN21: a posição copia início e fim da vaga, que é de onde o EXCLUDE lê');

select is(
  (select estado::text from public.vaga where id = (select (j->>'vaga_id')::uuid from v)),
  'publicada',
  'a vaga nasce publicada');

select is(
  (select publicado_por from public.vaga where id = (select (j->>'vaga_id')::uuid from v)),
  'f0000000-0000-4000-8000-0000000000d1'::uuid,
  'RF04: fica registrado quem publicou');

select is(
  (select alerta_antecedencia from public.vaga where id = (select (j->>'vaga_id')::uuid from v)),
  interval '240 minutes',
  'B18: a antecedência do alerta chega em minutos e vira intervalo');

-- O ponto vai e volta sem trocar latitude por longitude. Trocar as duas põe a vaga no
-- oceano Índico e desliga a elegibilidade por distância (RN05).
select is(
  (select round(extensions.ST_Y(ponto::extensions.geometry)::numeric, 4)
     from public.vaga where id = (select (j->>'vaga_id')::uuid from v)),
  -15.7890::numeric,
  'a vaga guarda a latitude que foi enviada');

select is(
  (select round(extensions.ST_X(ponto::extensions.geometry)::numeric, 4)
     from public.vaga where id = (select (j->>'vaga_id')::uuid from v)),
  -47.8850::numeric,
  'e a longitude');

select is(
  (select traje || '|' || participa_rateio::text || '|' || observacoes
     from public.vaga where id = (select (j->>'vaga_id')::uuid from v)),
  'Camisa preta|true|Levar avental',
  'os três campos opcionais são gravados quando vêm');

-- ── B15: o despacho fica na fila, e a publicação não espera por ele ────────────
--
-- A asserção é sobre a fila, e não sobre o efeito do despacho: a RPC não pode criar
-- linha em `despacho` nenhuma. Se um dia alguém "otimizar" chamando o motor aqui
-- dentro, a publicação passa a depender da rede e esta asserção morre.
select is(
  (select count(*)::int from pgmq.q_despacho
    where (message->>'vaga_id')::uuid = (select (j->>'vaga_id')::uuid from v)),
  1,
  'B15: uma mensagem na fila despacho, para o motor do Sprint 2');

select is(
  (select count(*)::int from public.despacho
    where vaga_id = (select (j->>'vaga_id')::uuid from v)),
  0,
  'B15: e nenhum despacho calculado dentro da transação da publicação');

-- ── RF04: a chave do cliente ───────────────────────────────────────────────────
--
-- A rede cai depois do commit e o app reenvia. A mesma chave devolve a mesma vaga —
-- e, sobretudo, não cria outras três posições.
select is(
  pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
    format($$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
         '{"latitude":-15.7890,"longitude":-47.8850}'::jsonb,
         18000, 3, true, true, false, 'Seu Zé', 'urgencia',
         '22222222-2222-4222-8222-222222222222'::uuid) $$,
      (select id from bar), (select id from cat),
      (select inicio from quando), (select fim from quando)))->>'vaga_id',
  (select j->>'vaga_id' from v),
  'RF04: reenviar com a mesma chave devolve a mesma vaga');

select is(
  (select count(*)::int from public.vaga
    where chave_cliente = '22222222-2222-4222-8222-222222222222'),
  1,
  'e continua havendo uma vaga só');

select is(
  (select count(*)::int from public.posicao
    where vaga_id = (select (j->>'vaga_id')::uuid from v)),
  3,
  'e três posições, não seis');

select is(
  (select count(*)::int from pgmq.q_despacho
    where (message->>'vaga_id')::uuid = (select (j->>'vaga_id')::uuid from v)),
  1,
  'e uma mensagem na fila, não duas: o reenvio não redespacha');

-- ── RN02: cada campo obrigatório recusa com o próprio nome ─────────────────────
select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, '   ',
             '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 1, true, true, false, 'Seu Zé', 'urgencia',
             '33333333-3333-4333-8333-333333333331'::uuid) $x$) $$,
         (select id from bar), (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "local", "hint" : null}',
  'RN02: local em branco é campo_obrigatorio com details = local');

select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
             '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 1, true, true, false, '  ', 'urgencia',
             '33333333-3333-4333-8333-333333333332'::uuid) $x$) $$,
         (select id from bar), (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "responsavel_local", "hint" : null}',
  'RN02: responsável em branco é campo_obrigatorio com details = responsavel_local');

select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
             null::jsonb,
             18000, 1, true, true, false, 'Seu Zé', 'urgencia',
             '33333333-3333-4333-8333-333333333333'::uuid) $x$) $$,
         (select id from bar), (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "ponto", "hint" : null}',
  'RN02: ponto ausente é campo_obrigatorio com details = ponto');

-- RN18: o valor é centavo inteiro e positivo. Zero não é "de graça", é engano de
-- digitação — e uma vaga de zero real percorre o despacho inteiro antes de alguém
-- notar.
select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
             '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             0, 1, true, true, false, 'Seu Zé', 'urgencia',
             '33333333-3333-4333-8333-333333333334'::uuid) $x$) $$,
         (select id from bar), (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "valor_centavos", "hint" : null}',
  'RN18: valor zero é campo_invalido com details = valor_centavos');

select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
             '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 201, true, true, false, 'Seu Zé', 'urgencia',
             '33333333-3333-4333-8333-333333333335'::uuid) $x$) $$,
         (select id from bar), (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "posicoes", "hint" : null}',
  'o teto de 200 posições do contrato é recusado com o código do contrato, não com 23514');

-- ── Horário ────────────────────────────────────────────────────────────────────
select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
             '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 1, true, true, false, 'Seu Zé', 'urgencia',
             '33333333-3333-4333-8333-333333333336'::uuid) $x$) $$,
         (select id from bar), (select id from cat),
         (select fim from quando), (select inicio from quando)),
  'PGRST',
  '{"code" : "horario_invalido", "message" : "horario_invalido", "details" : null, "hint" : null}',
  'fim antes do início é horario_invalido, e não violação de constraint');

select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
             '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 1, true, true, false, 'Seu Zé', 'urgencia',
             '33333333-3333-4333-8333-333333333337'::uuid) $x$) $$,
         (select id from bar), (select id from cat),
         (select privado.agora() - interval '2 hours'), (select privado.agora() - interval '1 hour')),
  'PGRST',
  '{"code" : "horario_invalido", "message" : "horario_invalido", "details" : null, "hint" : null}',
  'turno no passado é horario_invalido');

-- ── Diretriz 1.2: o filtro alcança os campos livres da vaga ────────────────────
--
-- `observacoes`, `local`, `responsavel_local` e `traje` são digitados à mão e vão
-- para a tela de quem procura turno. A recusa é `campo_invalido`, e não
-- `campo_obrigatorio`: o campo veio, o valor é que não serve.
select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
             '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 1, true, true, false, 'Seu Zé', 'urgencia',
             '33333333-3333-4333-8333-333333333338'::uuid,
             null, null, 'Nada de caralho aqui') $x$) $$,
         (select id from bar), (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "observacoes", "hint" : null}',
  'diretriz 1.2: termo bloqueado em observações é campo_invalido com o campo indicado');

select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
             '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 1, true, true, false, 'Seu Caralho', 'urgencia',
             '33333333-3333-4333-8333-333333333339'::uuid) $x$) $$,
         (select id from bar), (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "responsavel_local", "hint" : null}',
  'diretriz 1.2: e alcança o responsável pelo local');

-- ── RN24 na v1.0: o modo seleção não existe ainda ──────────────────────────────
--
-- A v1.0 tem só o modo urgência (escopo do MVP). O código é `campo_invalido` com
-- `details = modo`, e não `selecao_sem_antecedencia`: este último é a regra das 24 h,
-- que só faz sentido quando o modo passar a existir, na v1.1.
select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
       $x$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 406, Asa Norte',
             '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 1, true, true, false, 'Seu Zé', 'selecao',
             '44444444-4444-4444-8444-444444444444'::uuid) $x$) $$,
         (select id from bar), (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "modo", "hint" : null}',
  'v1.0: modo seleção é campo_invalido com details = modo');

-- ── Nada sobrou de recusa nenhuma ──────────────────────────────────────────────
--
-- Toda recusa acima aconteceu antes de qualquer escrita. Sem esta asserção, uma RPC
-- que gravasse a vaga e só então validasse passaria em todas as outras.
select is(
  (select count(*)::int from public.vaga
    where estabelecimento_id = (select id from bar)),
  1,
  'depois de doze recusas, a única vaga do bar é a do caminho feliz');

select is(
  (select count(*)::int from public.posicao p
    join public.vaga g on g.id = p.vaga_id
   where g.estabelecimento_id = (select id from bar)),
  3,
  'e as três posições dela');

-- ── Estabelecimento inexistente ────────────────────────────────────────────────
select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
       $x$ select public.publicar_vaga('00000000-0000-4000-8000-000000000000'::uuid, %L, %L, %L,
             'SCLN 406, Asa Norte', '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 1, true, true, false, 'Seu Zé', 'urgencia',
             '55555555-5555-4555-8555-555555555555'::uuid) $x$) $$,
         (select id from cat),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'estabelecimento que não existe é sem_permissao, e não 404: quem não é membro não fica sabendo se existe');

-- ── Função fora do catálogo ────────────────────────────────────────────────────
select throws_ok(
  format($$ select pg_temp.como('f0000000-0000-4000-8000-0000000000d1',
       $x$ select public.publicar_vaga(%L, '00000000-0000-4000-8000-000000000000'::uuid, %L, %L,
             'SCLN 406, Asa Norte', '{"latitude":-15.789,"longitude":-47.885}'::jsonb,
             18000, 1, true, true, false, 'Seu Zé', 'urgencia',
             '66666666-6666-4666-8666-666666666666'::uuid) $x$) $$,
         (select id from bar),
         (select inicio from quando), (select fim from quando)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "funcao_id", "hint" : null}',
  'função fora do catálogo é campo_invalido com details = funcao_id');

-- ── A fila não é legível por quem tem sessão ───────────────────────────────────
--
-- A mensagem carrega o id da vaga e, no Sprint 2, carregará critério de despacho.
-- `pgmq` cria as tabelas em schema próprio; o PostgREST só expõe `public`, mas RLS
-- desligada numa tabela alcançável seria o tipo de descuido que só aparece depois.
select is(
  (select count(*)::int from pg_tables
    where schemaname = 'pgmq' and tablename = 'q_despacho' and rowsecurity),
  1,
  'a tabela da fila tem RLS ligada, como toda tabela alcançável');

select * from finish();
rollback;
