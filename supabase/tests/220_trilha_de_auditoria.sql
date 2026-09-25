-- A trilha de auditoria do ciclo (RNF13), e a imutabilidade do que é registro.
--
-- Cartão `6mdX80SC`. Quatro perguntas, e as duas últimas são as que importam:
--
--   1. percorrer o ciclo deixa uma linha por transição, com estado anterior e autor?
--   2. a trilha guarda dado pessoal? (RN15 — e a resposta tem de ser não, por coluna e
--      por conteúdo)
--   3. `ocorrencia.motivo` pode ser reescrito? (não, nem pelo dono do banco)
--   4. a exceção controlada da retenção funciona, e só ela?

begin;
select plan(23);

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

insert into privado.ambiente (id, eh_teste) values (true, true);
set local frila.agora = '2027-03-01 09:00:00+00';

-- Prefixo `ad`, que não existe em `cenarios.sql` nem nos outros arquivos.
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', c.id, 'authenticated','authenticated', c.email,
       privado.agora(), privado.agora(), false, false
  from (values
    ('ad000000-0000-4000-8000-000000000001'::uuid,'trilha-casa@t.test'),
    ('ad000000-0000-4000-8000-000000000002'::uuid,'trilha-prof@t.test')
  ) as c(id, email);

select pg_temp.como('ad000000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante','Dona da Trilha','+5561933330001','1981-07-07','2026-09-22') $$);
select pg_temp.como('ad000000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('profissional','Pê da Trilha','+5561933330002','1993-08-08','2026-09-22') $$);

create temp table f as select id from public.funcao where nome = 'garçom';

select pg_temp.como('ad000000-0000-4000-8000-000000000002', format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select id from f)));

create temp table casa as
  select (pg_temp.como('ad000000-0000-4000-8000-000000000001',
    $$ select public.cadastrar_estabelecimento('Casa da Trilha','07526557000100','food_service',
         'CLN 212','{"latitude":-15.7905,"longitude":-47.8855}') $$)->>'id')::uuid as id;

-- A contagem de linhas da trilha é sempre **por entidade deste arquivo**, nunca sobre a
-- tabela inteira: `cenarios.sql` já escreveu vagas e turnos antes deste teste começar.
create temp table vaga as
  select (pg_temp.como('ad000000-0000-4000-8000-000000000001', format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-03-08 21:00:00+00'::timestamptz, '2027-03-09 03:00:00+00'::timestamptz,
         'CLN 212','{"latitude":-15.7905,"longitude":-47.8855}'::jsonb,
         15000::bigint, 1, true, false, false, 'Gerente', 'urgencia'::public.modo_preenchimento,
         gen_random_uuid()) $$,
    (select id from casa), (select id from f)))->>'vaga_id')::uuid as id;

-- ── 1. O nascimento deixa rastro ──────────────────────────────────────────────

select is(
  (select count(*)::int from privado.auditoria_ciclo a
    where a.entidade = 'vaga' and a.entidade_id = (select id from vaga) and a.acao = 'criou'),
  1,
  'RNF13: publicar a vaga deixa uma linha de nascimento na trilha');

select is(
  (select a.autor_id from privado.auditoria_ciclo a
    where a.entidade = 'vaga' and a.entidade_id = (select id from vaga)),
  'ad000000-0000-4000-8000-000000000001'::uuid,
  'e a linha diz quem publicou');

select is(
  (select a.estado_novo from privado.auditoria_ciclo a
    where a.entidade = 'vaga' and a.entidade_id = (select id from vaga)),
  'publicada',
  'com o estado em que a vaga nasceu');

-- ── 2. A transição, que é o ponto do cartão ───────────────────────────────────

create temp table turno as
  select pg_temp.como('ad000000-0000-4000-8000-000000000002', format(
    $$ select public.candidatar(%L::uuid) $$, (select id from vaga))) as r;

select is(
  (select a.estado_anterior || ' → ' || a.estado_novo from privado.auditoria_ciclo a
    where a.entidade = 'posicao' and a.acao = 'mudou_estado'
      and a.entidade_id = ((select r from turno)->>'posicao_id')::uuid),
  'aberta → confirmada',
  'RNF13: a confirmação registra a transição, com o estado anterior e o novo');

select is(
  (select a.autor_id from privado.auditoria_ciclo a
    where a.entidade = 'posicao' and a.acao = 'mudou_estado'
      and a.entidade_id = ((select r from turno)->>'posicao_id')::uuid),
  'ad000000-0000-4000-8000-000000000002'::uuid,
  'e o autor é quem se candidatou, e não quem publicou');

select is(
  (select count(*)::int from privado.auditoria_ciclo a
    where a.entidade = 'turno' and a.entidade_id = ((select r from turno)->>'turno_id')::uuid),
  1,
  'o turno nasce com uma linha só — INSERT não vira INSERT mais UPDATE');

-- UPDATE que não mexe na coluna de estado não polui a trilha. Sem esta regra, a trilha
-- deixaria de ser legível justamente no dia em que alguém precisasse lê-la.
set local frila.agora = '2027-03-08 21:05:00+00';
select pg_temp.como('ad000000-0000-4000-8000-000000000002', format(
  $$ select public.fazer_checkin(%L::uuid, 30, '2027-03-08 21:05:00+00'::timestamptz) $$,
  ((select r from turno)->>'turno_id')::uuid));

select is(
  (select count(*)::int from privado.auditoria_ciclo a
    where a.entidade = 'turno' and a.entidade_id = ((select r from turno)->>'turno_id')::uuid),
  2,
  'o check-in muda a verificação e acrescenta exatamente uma linha');

select is(
  (select a.estado_anterior || ' → ' || a.estado_novo from privado.auditoria_ciclo a
    where a.entidade = 'turno' and a.acao = 'mudou_estado'
      and a.entidade_id = ((select r from turno)->>'turno_id')::uuid),
  'pendente → verificado',
  'e ela conta a transição da presença');

select is(
  (select count(*)::int from privado.auditoria_ciclo a
    join public.candidatura c on c.id = a.entidade_id
   where a.entidade = 'candidatura'
     and c.posicao_id = ((select r from turno)->>'posicao_id')::uuid),
  1,
  'a candidatura também deixa rastro — é dela que sai a prova de quem pediu o turno');

-- ── O ciclo fecha, e a avaliação entra na trilha ──────────────────────────────
set local frila.agora = '2027-03-09 02:55:00+00';
select pg_temp.como('ad000000-0000-4000-8000-000000000002', format(
  $$ select public.fazer_checkout(%L::uuid, 50, '2027-03-09 02:55:00+00'::timestamptz) $$,
  ((select r from turno)->>'turno_id')::uuid));

set local frila.agora = '2027-03-09 04:00:00+00';
select pg_temp.como('ad000000-0000-4000-8000-000000000001', format(
  $$ select public.avaliar(%L::uuid, true) $$, ((select r from turno)->>'turno_id')::uuid));

select is(
  (select count(*)::int from privado.auditoria_ciclo a
    join public.avaliacao av on av.id = a.entidade_id
   where a.entidade = 'avaliacao'
     and av.turno_id = ((select r from turno)->>'turno_id')::uuid),
  1,
  'RNF13: a avaliação entra na trilha pelo nascimento — ela não tem estado para transitar');

-- ── 3. RN15: a trilha não guarda dado pessoal ─────────────────────────────────

select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'privado' and table_name = 'auditoria_ciclo'
      and column_name ~* '(nome|telefone|email|nascimento|documento|ponto|latitude|longitude|endereco)'),
  0,
  'RN15: nenhuma coluna da trilha tem nome, telefone, e-mail, documento ou coordenada');

-- A negativa por coluna não basta: `estado_anterior` e `estado_novo` são `text`, e um
-- gatilho futuro poderia escrever qualquer coisa neles. Esta pergunta é sobre o conteúdo.
select is(
  (select count(*)::int from privado.auditoria_ciclo a
    where a.estado_anterior || ' ' || coalesce(a.estado_novo, '') ~*
          '(\+55|@|Dona da Trilha|Pê da Trilha|-15\.79|-47\.88|07526557000100)'),
  0,
  'e nenhuma linha carrega conteúdo pessoal no estado — a trilha guarda transição, não cópia');

-- ── 4. Registro é registro: `ocorrencia` e `despacho` não se reescrevem ───────

-- Uma vaga própria para o cancelamento: a primeira já foi cumprida e avaliada, e
-- cancelar uma posição cumprida é outra recusa, não este teste.
set local frila.agora = '2027-03-09 05:00:00+00';
create temp table vaga2 as
  select (pg_temp.como('ad000000-0000-4000-8000-000000000001', format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-03-22 21:00:00+00'::timestamptz, '2027-03-23 03:00:00+00'::timestamptz,
         'CLN 212','{"latitude":-15.7905,"longitude":-47.8855}'::jsonb,
         15000::bigint, 1, true, false, false, 'Gerente', 'urgencia'::public.modo_preenchimento,
         gen_random_uuid()) $$,
    (select id from casa), (select id from f)))->>'vaga_id')::uuid as id;

create temp table turno2 as
  select pg_temp.como('ad000000-0000-4000-8000-000000000002', format(
    $$ select public.candidatar(%L::uuid) $$, (select id from vaga2))) as r;

select pg_temp.como('ad000000-0000-4000-8000-000000000002', format(
  $$ select public.cancelar_posicao(%L::uuid, 'imprevisto de verdade') $$,
  ((select r from turno2)->>'posicao_id')::uuid));

create temp table oc as
  select id from public.ocorrencia
   where motivo = 'imprevisto de verdade' limit 1;

select isnt((select id from oc), null,
  'o cancelamento gravou a ocorrência que os dois testes abaixo protegem');

select is(
  (select count(*)::int from privado.auditoria_ciclo a
    where a.entidade = 'ocorrencia' and a.entidade_id = (select id from oc)),
  1,
  'e a ocorrência entra na trilha, pelo nascimento');

-- ── `despacho` não se reescreve, e nem se apaga ───────────────────────────────
--
-- Ele é o registro de que alguém foi notificado sobre uma vaga. Reescrevê-lo depois seria
-- reescrever a prova de quem teve a chance de aceitar o turno, que é a própria pergunta
-- que a RN06 existe para poder responder.
insert into public.despacho (id, vaga_id, profissional_id)
select 'ad000000-0000-4000-8000-0000000000d1', (select id from vaga2),
       (select p.id from public.profissional p where p.usuario_id = 'ad000000-0000-4000-8000-000000000002');

select throws_ok(
  $$ update public.despacho set notificacao_id = gen_random_uuid()
      where id = 'ad000000-0000-4000-8000-0000000000d1' $$,
  '23001',
  null,
  'RNF13: despacho não se reescreve — ele é a prova de quem teve a chance do turno');

select throws_ok(
  $$ delete from public.despacho where id = 'ad000000-0000-4000-8000-0000000000d1' $$,
  '23001',
  null,
  'e despacho não se apaga');

-- A trilha é escrita por gatilho, e `acao` só aceita os dois verbos que os gatilhos usam.
-- Sem a restrição, uma escrita futura poderia inventar um terceiro e ninguém saberia ler.
select throws_ok(
  $$ insert into privado.auditoria_ciclo (entidade, entidade_id, acao)
     values ('vaga', gen_random_uuid(), 'apagou') $$,
  '23514',
  null,
  'a trilha só aceita os verbos que os gatilhos escrevem: criou e mudou_estado');

select throws_ok(
  format($$ update public.ocorrencia set motivo = 'outra historia' where id = %L $$, (select id from oc)),
  '23001',
  null,
  'RNF13: o motivo da ocorrência não se reescreve, nem com a conexão do dono do banco');

select throws_ok(
  format($$ delete from public.ocorrencia where id = %L $$, (select id from oc)),
  '23001',
  null,
  'e ocorrência não se apaga');

-- O desfecho pode mudar: é para isso que `resultado` e `resolvido_em` existem.
select lives_ok(
  format($$ update public.ocorrencia set resultado = 'sem penalidade', resolvido_em = privado.agora()
             where id = %L $$, (select id from oc)),
  'mas o desfecho muda — resultado e resolvido_em são as duas colunas que a decisão preenche');

-- A exceção controlada da retenção (RF25, cartão `yClUqOpU`). Ela é sinal de sessão e
-- some com a transação: quem esquecer de desligar não deixa a porta aberta para a próxima
-- conexão. O job ainda não existe; o que existe, e está provado aqui, é a porta que ele
-- vai usar.
set local privado.retencao = 'on';

-- Medido ao escrever este teste, e é achado para o cartão da retenção: o relato **não
-- pode ser esvaziado**. `ocorrencia_motivo_check` exige `length(btrim(motivo)) > 0`, então
-- a retenção tem de **substituir** o relato por um marcador, e não apagá-lo. Um job que
-- tentasse `motivo = ''` morreria com 23514 depois de passar pela exceção controlada.
select throws_ok(
  format($$ update public.ocorrencia set motivo = '' where id = %L $$, (select id from oc)),
  '23514',
  null,
  'a retenção não pode esvaziar o relato: ocorrencia_motivo_check exige texto');

select lives_ok(
  format($$ update public.ocorrencia set motivo = '[removido por exclusão de conta]'
             where id = %L $$, (select id from oc)),
  'RF25: com privado.retencao ligado, a retenção substitui o relato da ocorrência');

-- E a porta fecha sozinha: basta o sinal sair para o registro voltar a ser imutável.
reset privado.retencao;

select throws_ok(
  format($$ update public.ocorrencia set motivo = 'terceira versao' where id = %L $$, (select id from oc)),
  '23001',
  null,
  'e sem o sinal de retenção o registro volta a ser imutável na mesma transação');

select * from finish();
rollback;
