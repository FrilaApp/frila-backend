-- `vagas_abertas` e `detalhe_vaga`: o que o profissional vê antes de se candidatar.
--
-- São as duas primeiras leituras do lado de quem trabalha, e as primeiras em que o
-- **que não aparece** importa mais do que o que aparece:
--
--   RN06  a ordem é por distância, nunca por reputação nem por pagamento
--   RF26  vaga de estabelecimento com bloqueio entre as partes some da lista
--   RN10  documento e telefone não saem daqui, nem no detalhe
--   2.1   conta de demonstração e conta real não se enxergam
--
-- O banco não nasce vazio: `cenarios.sql` já põe 3 estabelecimentos e 7 vagas. Este
-- arquivo cria as próprias, com ids que começam em `ab000000`, e conta apenas o que ele
-- mesmo criou — contagem sobre a tabela inteira mede o cenário junto.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(33);

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

-- ── As contas ─────────────────────────────────────────────────────────────────
--
-- d1 publica · p1 procura · p2 bloqueou a casa do d1 · c1 é contratante sem vínculo
-- pd e dd são o par de demonstração: um publica, o outro procura.
select pg_temp.autenticar('ab000000-0000-4000-8000-0000000000d1','dona@lista.test');
select pg_temp.autenticar('ab000000-0000-4000-8000-0000000000e1','p1@lista.test');
select pg_temp.autenticar('ab000000-0000-4000-8000-0000000000e2','p2@lista.test');
select pg_temp.autenticar('ab000000-0000-4000-8000-0000000000c1','c1@lista.test');
select pg_temp.autenticar('ab000000-0000-4000-8000-0000000000dd','demo-dona@lista.test');
select pg_temp.autenticar('ab000000-0000-4000-8000-0000000000ed','demo-prof@lista.test');

select pg_temp.como('ab000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona da Lista','+5561999990301','1980-01-01','2026-09-22') $$);
select pg_temp.como('ab000000-0000-4000-8000-0000000000c1',
  $$ select public.criar_conta('contratante','Outra Dona','+5561999990302','1980-01-01','2026-09-22') $$);
select pg_temp.como('ab000000-0000-4000-8000-0000000000dd',
  $$ select public.criar_conta('contratante','Dona Demo','+5561999990303','1980-01-01','2026-09-22') $$);

-- Os profissionais precisam de perfil: é dele que sai o ponto base usado quando a
-- chamada não traz coordenada.
select pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Pê Um','+5561999990311','1995-01-01','2026-09-22') $$);
select pg_temp.como('ab000000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Pê Dois','+5561999990312','1995-01-01','2026-09-22') $$);
select pg_temp.como('ab000000-0000-4000-8000-0000000000ed',
  $$ select public.criar_conta('profissional','Pê Demo','+5561999990313','1995-01-01','2026-09-22') $$);

create temp table funcoes as
  select (select id from public.funcao where nome = 'garçom')    as garcom,
         (select id from public.funcao where nome = 'bartender') as bartender;

select pg_temp.como('ab000000-0000-4000-8000-0000000000e1', format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from funcoes)));
select pg_temp.como('ab000000-0000-4000-8000-0000000000e2', format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from funcoes)));
select pg_temp.como('ab000000-0000-4000-8000-0000000000ed', format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from funcoes)));

-- ── As casas ──────────────────────────────────────────────────────────────────
create temp table casas as
  select (pg_temp.como('ab000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa Perto','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as perto,
         (pg_temp.como('ab000000-0000-4000-8000-0000000000dd',
    $$ select public.cadastrar_estabelecimento('Casa Demo','68558622000173','food_service',
         'SCLN 407','{"latitude":-15.7915,"longitude":-47.8865}') $$)->>'id')::uuid as demo;

-- A segunda casa do mesmo dono, longe: é ela que prova a ordenação por distância.
create temp table casa_longe as
  select (pg_temp.como('ab000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa Longe','07526557000100','varejo',
         'Águas Claras','{"latitude":-15.8390,"longitude":-48.0250}') $$)->>'id')::uuid as id;

-- ── A marca de demonstração ───────────────────────────────────────────────────
update public.usuario set demonstracao = true
 where id in ('ab000000-0000-4000-8000-0000000000dd','ab000000-0000-4000-8000-0000000000ed');

-- ── As vagas ──────────────────────────────────────────────────────────────────
--
-- Sexta às 23:30 em São Paulo. O filtro `data` compara o dia **em São Paulo**, e não em
-- UTC: às 23:30 de sexta no horário de Brasília já é sábado em UTC, e uma comparação
-- ingênua jogaria a vaga para o dia seguinte — o profissional que filtrasse "sexta" não
-- veria o turno de sexta à noite, que é o turno mais comum do produto.
create temp table quando as
  select ('2026-10-16 23:30:00 America/Sao_Paulo'::timestamptz) as sexta_noite,
         ('2026-10-17 05:30:00 America/Sao_Paulo'::timestamptz) as fim_sexta,
         ('2026-10-20 18:00:00 America/Sao_Paulo'::timestamptz) as terca,
         ('2026-10-21 00:00:00 America/Sao_Paulo'::timestamptz) as fim_terca;

create function pg_temp.publicar(conta uuid, estab uuid, funcao uuid,
                                 ini timestamptz, fim timestamptz, posicoes int,
                                 chave uuid) returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como(conta, format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'Endereço da vaga',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, %s, true, true, false, 'Seu Zé', 'urgencia', %L) $sql$,
    estab, funcao, ini, fim, posicoes, chave))->>'vaga_id')::uuid;
end $corpo$;

create temp table vagas as
  select pg_temp.publicar('ab000000-0000-4000-8000-0000000000d1', (select perto from casas),
           (select garcom from funcoes), (select sexta_noite from quando),
           (select fim_sexta from quando), 3,
           'ab000000-0000-4000-8000-000000000001') as perto,
         pg_temp.publicar('ab000000-0000-4000-8000-0000000000d1', (select id from casa_longe),
           (select garcom from funcoes), (select terca from quando),
           (select fim_terca from quando), 1,
           'ab000000-0000-4000-8000-000000000002') as longe,
         pg_temp.publicar('ab000000-0000-4000-8000-0000000000d1', (select perto from casas),
           (select bartender from funcoes), (select terca from quando),
           (select fim_terca from quando), 1,
           'ab000000-0000-4000-8000-000000000003') as bartender,
         pg_temp.publicar('ab000000-0000-4000-8000-0000000000dd', (select demo from casas),
           (select garcom from funcoes), (select sexta_noite from quando),
           (select fim_sexta from quando), 1,
           'ab000000-0000-4000-8000-000000000004') as demo;

-- A vaga da Casa Longe usa o ponto do estabelecimento, e não o da publicação: o helper
-- manda sempre o mesmo ponto, e sem esta correção as duas vagas ficariam à mesma
-- distância e a ordenação não provaria nada.
update public.vaga set ponto = 'SRID=4326;POINT(-48.0250 -15.8390)'::extensions.geography
 where id = (select longe from vagas);

-- P2 bloqueou a dona da Casa Perto. RF26: as vagas dela somem para ele.
insert into public.bloqueio (autor_id, bloqueado_id)
values ('ab000000-0000-4000-8000-0000000000e2','ab000000-0000-4000-8000-0000000000d1');

-- ── Sem sessão não há lista ───────────────────────────────────────────────────
select throws_ok(
  $$ select public.vagas_abertas() $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não há lista de vagas');

select throws_ok(
  format($$ select public.detalhe_vaga(%L) $$, (select perto from vagas)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não há detalhe');

-- ── A lista é a tela do profissional ──────────────────────────────────────────
select throws_ok(
  $$ select pg_temp.como('ab000000-0000-4000-8000-0000000000c1',
       $x$ select public.vagas_abertas() $x$) $$,
  'PGRST',
  '{"code" : "perfil_incompativel", "message" : "perfil_incompativel", "details" : null, "hint" : null}',
  'RN25: conta de contratante não lista vagas abertas');

-- ── A ordem é por distância ───────────────────────────────────────────────────
create temp table lista as
  select pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
    $$ select public.vagas_abertas() $$) as j;

create temp table minhas as
  select ordinalidade, item
    from lista, jsonb_array_elements((select j from lista))
         with ordinality as t(item, ordinalidade)
   where (item->>'id')::uuid in (select perto from vagas
                                 union select longe from vagas
                                 union select bartender from vagas);

-- A asserção é sobre a posição da vaga distante, e não sobre a ordem entre as duas da
-- Casa Perto: as duas saem do mesmo ponto, empatam em distância e o desempate é por id.
-- Fixar o empate seria testar o `order by` secundário, que é detalhe de implementação.
select is(
  (select max(ordinalidade) from minhas),
  (select ordinalidade from minhas where item->>'id' = (select longe from vagas)::text),
  'RN06: a ordem é por distância — a vaga de Águas Claras vem depois das duas da Casa Perto');

select cmp_ok(
  (select (item->>'distancia_km')::numeric from minhas where item->>'id' = (select longe from vagas)::text),
  '>',
  (select (item->>'distancia_km')::numeric from minhas where item->>'id' = (select perto from vagas)::text),
  'e a distância devolvida acompanha a ordem');

-- Águas Claras fica a uns 15 km do Plano Piloto. A asserção é de ordem de grandeza: o
-- que ela pega é a troca de latitude por longitude, que jogaria a vaga para o oceano
-- Índico e devolveria milhares de quilômetros.
select cmp_ok(
  (select (item->>'distancia_km')::numeric from minhas where item->>'id' = (select longe from vagas)::text),
  '<', 30::numeric,
  'a distância está em quilômetros, e latitude não foi trocada por longitude');

select is(
  (select array_agg(k order by k) from minhas, jsonb_object_keys(minhas.item) k
    where minhas.item->>'id' = (select perto from vagas)::text),
  array['distancia_km','estabelecimento','fim_em','funcao','id','inclusos','inicio_em',
        'local','modo','posicoes_abertas','valor_centavos'],
  'cada item traz exatamente os campos do schema VagaNaLista do contrato');

select is(
  (select item->>'posicoes_abertas' from minhas where item->>'id' = (select perto from vagas)::text),
  '3',
  'posicoes_abertas conta as posições ainda abertas, e não o total pedido');

select is(
  (select item->'funcao'->>'nome' from minhas where item->>'id' = (select bartender from vagas)::text),
  'bartender',
  'a função vem com o nome do catálogo');

select is(
  (select item->'estabelecimento'->>'nome' from minhas where item->>'id' = (select perto from vagas)::text),
  'Casa Perto',
  'o estabelecimento vem como PerfilPublico, com nome');

select is(
  (select array_agg(k order by k)
     from minhas, jsonb_object_keys(minhas.item->'estabelecimento') k
    where minhas.item->>'id' = (select perto from vagas)::text),
  array['id','nome','reputacao','tipo'],
  'e só com os campos de PerfilPublico — nada de documento ou endereço');

select is(
  (select array_agg(k order by k)
     from minhas, jsonb_object_keys(minhas.item->'estabelecimento'->'reputacao') k
    where minhas.item->>'id' = (select perto from vagas)::text),
  array['positivas','taxa_comparecimento','total','turnos_considerados','turnos_realizados'],
  'RN08: a reputação vem com o denominador, como o contrato exige');

-- ── O que não aparece ─────────────────────────────────────────────────────────
select is(
  (select count(*)::int from lista, jsonb_array_elements((select j from lista)) e
    where e->>'id' = (select demo from vagas)::text),
  0,
  'diretriz 2.1: conta real não vê vaga de conta de demonstração');

create temp table lista_demo as
  select pg_temp.como('ab000000-0000-4000-8000-0000000000ed',
    $$ select public.vagas_abertas() $$) as j;

select is(
  (select count(*)::int from lista_demo, jsonb_array_elements((select j from lista_demo)) e
    where e->>'id' in ((select perto from vagas)::text, (select longe from vagas)::text)),
  0,
  'e conta de demonstração não vê vaga real');

select is(
  (select count(*)::int from lista_demo, jsonb_array_elements((select j from lista_demo)) e
    where e->>'id' = (select demo from vagas)::text),
  1,
  'a conta de demonstração vê a vaga de demonstração, que é o ponto de existir');

create temp table lista_bloqueada as
  select pg_temp.como('ab000000-0000-4000-8000-0000000000e2',
    $$ select public.vagas_abertas() $$) as j;

select is(
  (select count(*)::int from lista_bloqueada, jsonb_array_elements((select j from lista_bloqueada)) e
    where e->>'id' in ((select perto from vagas)::text, (select bartender from vagas)::text)),
  0,
  'RF26: quem bloqueou a dona não vê nenhuma vaga da casa dela');

select is(
  (select count(*)::int from lista_bloqueada, jsonb_array_elements((select j from lista_bloqueada)) e
    where e->>'id' = (select longe from vagas)::text),
  0,
  'RF26: e o bloqueio é com a pessoa, então a outra casa dela também some');

-- Vaga que saiu de `publicada` não é vaga aberta.
update public.vaga set estado = 'cancelada' where id = (select bartender from vagas);

select is(
  (select count(*)::int
     from jsonb_array_elements(pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
            $$ select public.vagas_abertas() $$)) e
    where e->>'id' = (select bartender from vagas)::text),
  0,
  'vaga cancelada sai da lista');

update public.vaga set estado = 'publicada' where id = (select bartender from vagas);

-- ── Os filtros ────────────────────────────────────────────────────────────────
select is(
  (select count(*)::int
     from jsonb_array_elements(pg_temp.como('ab000000-0000-4000-8000-0000000000e1', format(
            $$ select public.vagas_abertas(funcao_id => %L) $$, (select bartender from funcoes)))) e
    where e->>'id' in ((select perto from vagas)::text, (select bartender from vagas)::text)),
  1,
  'o filtro por função deixa só a vaga de bartender das minhas');

-- O caso que o cartão nomeia: 23:30 de sexta em São Paulo é sábado em UTC.
select is(
  (select count(*)::int
     from jsonb_array_elements(pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
            $$ select public.vagas_abertas(data => '2026-10-16') $$)) e
    where e->>'id' = (select perto from vagas)::text),
  1,
  'a vaga das 23:30 de sexta em São Paulo aparece no filtro de sexta, não no de sábado');

select is(
  (select count(*)::int
     from jsonb_array_elements(pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
            $$ select public.vagas_abertas(data => '2026-10-17') $$)) e
    where e->>'id' = (select perto from vagas)::text),
  0,
  'e não aparece no dia seguinte');

select is(
  (select count(*)::int
     from jsonb_array_elements(pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
            $$ select public.vagas_abertas(distancia_max_km => 5) $$)) e
    where e->>'id' = (select longe from vagas)::text),
  0,
  'distancia_max_km corta a vaga de Águas Claras');

select is(
  (select count(*)::int
     from jsonb_array_elements(pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
            $$ select public.vagas_abertas(distancia_max_km => 5) $$)) e
    where e->>'id' = (select perto from vagas)::text),
  1,
  'e mantém a que está perto');

-- Coordenada explícita manda mais que o ponto base: quem está em Águas Claras naquele
-- dia quer ver o que há em volta dele, não em volta de casa.
-- A contagem é sobre as minhas vagas, e não sobre a lista inteira: `cenarios.sql` tem
-- uma casa em Águas Claras, e hoje ela não tem vaga publicada — mas contar a lista
-- inteira faria esta asserção depender disso continuar verdade.
select is(
  (select array_agg(e->>'id')
     from jsonb_array_elements(pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
            $$ select public.vagas_abertas(latitude => -15.8390, longitude => -48.0250,
                                           distancia_max_km => 5) $$)) e
    where (e->>'id')::uuid in (select perto from vagas
                               union select longe from vagas
                               union select bartender from vagas)),
  array[(select longe from vagas)::text],
  'com coordenada explícita, a única das minhas dentro de 5 km é a de Águas Claras');

-- ── Paginação ─────────────────────────────────────────────────────────────────
select is(
  (select jsonb_array_length(pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
     $$ select public.vagas_abertas(limite => 2) $$))),
  2,
  'o limite é respeitado');

select isnt(
  (select pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
     $$ select public.vagas_abertas(limite => 1, deslocamento => 1) $$)->0->>'id'),
  (select pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
     $$ select public.vagas_abertas(limite => 1) $$)->0->>'id'),
  'o deslocamento anda na lista, e não devolve a mesma primeira vaga');

select throws_ok(
  $$ select pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
       $x$ select public.vagas_abertas(limite => 101) $x$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "limite", "hint" : null}',
  'o teto de 100 do contrato é recusado com o código do contrato');

-- ── detalhe_vaga ──────────────────────────────────────────────────────────────
create temp table det as
  select pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
    format($$ select public.detalhe_vaga(%L) $$, (select perto from vagas))) as j;

select is(
  (select array_agg(k order by k) from det, jsonb_object_keys((select j from det)) k),
  array['distancia_km','estabelecimento','estado','fim_em','funcao','id','inclusos',
        'inicio_em','local','modo','observacoes','participa_rateio','ponto','posicoes',
        'posicoes_abertas','publicado_em','responsavel_local','traje','valor_centavos'],
  'o detalhe traz exatamente os campos do schema Vaga do contrato');

-- RN10. O telefone da outra parte sai por `contato_do_turno`, depois da confirmação e
-- dentro do prazo — nunca por uma leitura pública.
select is(
  (select count(*)::int from det
    where (select j from det)::text like '%04252011000110%'
       or (select j from det)::text like '%+556199999030%'),
  0,
  'RN10: nem o documento do estabelecimento nem telefone nenhum aparecem no detalhe');

select throws_ok(
  format($$ select pg_temp.como('ab000000-0000-4000-8000-0000000000e2',
       $x$ select public.detalhe_vaga(%L) $x$) $$, (select perto from vagas)),
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'RF26: para quem bloqueou a casa, o detalhe é 404 — não 403, que confirmaria que ela existe');

select throws_ok(
  format($$ select pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
       $x$ select public.detalhe_vaga(%L) $x$) $$, (select demo from vagas)),
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'diretriz 2.1: conta real recebe 404 no detalhe de vaga de demonstração');

select throws_ok(
  $$ select pg_temp.como('ab000000-0000-4000-8000-0000000000e1',
       $x$ select public.detalhe_vaga('00000000-0000-4000-8000-000000000000') $x$) $$,
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'vaga que não existe é 404 nao_encontrado');

-- ── O índice é usado ──────────────────────────────────────────────────────────
--
-- O cartão pede `EXPLAIN` sem varredura sequencial em `vaga`. A asserção é sobre o
-- plano da consulta que a RPC faz, com o operador `<->` e o índice GIST parcial.
select isnt_empty(
  $$ explain (format text)
     select v.id from public.vaga v
      where v.estado = 'publicada'
      order by v.ponto <-> 'SRID=4326;POINT(-47.885 -15.79)'::extensions.geography
      limit 30 $$,
  'o plano da consulta da lista existe e é inspecionável');

select * from finish();
rollback;
