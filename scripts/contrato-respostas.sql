-- Colhe uma resposta real de cada RPC da v1.0, para o validador conferir contra o schema.
--
-- Cartão `0uROtsRX`. Este arquivo **não** afirma nada: ele executa o ciclo inteiro e
-- imprime, uma por linha, `{"op": "<operationId>", "corpo": <o que a RPC devolveu>}`.
-- Quem julga é `scripts/contrato_responde.py`, contra o `contrato/openapi.yaml`.
--
-- Por que pelo banco, e não por HTTP: o JSON que o PostgREST entrega é, byte por byte, o
-- que a função do Postgres montou — ele não remodela corpo de RPC. E só aqui o relógio do
-- produto pode ser deslocado, que é o que torna alcançável o caminho feliz de check-in,
-- check-out e avaliação. O eixo HTTP — rota existe, status certo, envelope de erro com a
-- chave `headers` — já é do `ciclo-completo.sh`, e os dois se completam em vez de se
-- repetirem.
--
-- Tudo roda dentro de `begin … rollback`: o banco sai como entrou.

begin;

-- Os passos intermediários não interessam a ninguém: o que sai deste arquivo é só a
-- colheita do fim. Sem isto, a saída vem com uma tabela por chamada e o validador teria
-- de adivinhar onde começa o que importa.
\o /dev/null

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

-- Colhe a recusa em vez da resposta: o envelope de `public.erro` sai em `MESSAGE`, que é
-- exatamente o corpo que o PostgREST devolve ao cliente.
create function pg_temp.recusa(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare msg text;
begin
  begin
    perform pg_temp.como(conta, sql);
    return null;
  exception when others then
    get stacked diagnostics msg = message_text;
    reset role;
    begin execute 'reset request.jwt.claims'; exception when others then null; end;
    return msg::jsonb;
  end;
end $$;

create temp table colhido (ordem serial, op text, corpo jsonb);
create function pg_temp.guarda(op text, corpo jsonb) returns void
language sql as $$ insert into colhido (op, corpo) values (op, corpo) $$;

-- ── O cenário ──────────────────────────────────────────────────────────────────
insert into privado.ambiente (id, eh_teste) values (true, true);
set local frila.agora = '2027-01-11 09:00:00+00';

insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', c.id, 'authenticated','authenticated', c.email,
       privado.agora(), privado.agora(), false, false
  from (values
    ('cc000000-0000-4000-8000-000000000001'::uuid,'contrato-casa@t.test'),
    ('cc000000-0000-4000-8000-000000000002'::uuid,'contrato-prof@t.test'),
    ('cc000000-0000-4000-8000-000000000003'::uuid,'contrato-prof2@t.test')
  ) as c(id, email);

select pg_temp.guarda('criarConta', pg_temp.como('cc000000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante','Casa do Contrato','+5561944440001','1980-05-05','2026-09-22') $$));
select pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('profissional','Pê do Contrato','+5561944440002','1995-05-05','2026-09-22') $$);
select pg_temp.como('cc000000-0000-4000-8000-000000000003',
  $$ select public.criar_conta('profissional','Pê Dois','+5561944440003','1994-05-05','2026-09-22') $$);

select pg_temp.guarda('minhaConta', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.minha_conta() $$));

create temp table f as select id from public.funcao where nome = 'garçom';

select pg_temp.guarda('criarPerfilProfissional', pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb,
       '[{"dia_semana":1,"hora_inicio":"08:00","hora_fim":"23:59"}]'::jsonb) $$, (select id from f))));
select pg_temp.como('cc000000-0000-4000-8000-000000000003', format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select id from f)));

select pg_temp.guarda('meuPerfilProfissional', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.meu_perfil_profissional() $$));

select pg_temp.guarda('atualizarPerfilProfissional', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.atualizar_perfil_profissional(ponto_base => '{"latitude":-15.7901,"longitude":-47.8851}'::jsonb) $$));

create temp table casa as
  select (pg_temp.como('cc000000-0000-4000-8000-000000000001',
    $$ select public.cadastrar_estabelecimento('Casa do Contrato','29979036000140','food_service',
         'CLN 108','{"latitude":-15.7905,"longitude":-47.8855}') $$)) as r;
select pg_temp.guarda('cadastrarEstabelecimento', (select r from casa));

select pg_temp.guarda('meusEstabelecimentos', pg_temp.como('cc000000-0000-4000-8000-000000000001',
  $$ select public.meus_estabelecimentos() $$));

create temp table ids as select ((select r from casa)->>'id')::uuid as casa_id;

select pg_temp.guarda('painelEstabelecimento', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.painel_estabelecimento(%L::uuid, '2027-01-01T00:00:00Z'::timestamptz, '2027-12-31T00:00:00Z'::timestamptz) $$,
  (select casa_id from ids))));

-- ── A vaga, e o ciclo ─────────────────────────────────────────────────────────
create temp table vaga1 as
  select pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-01-18 21:00:00+00'::timestamptz, '2027-01-19 03:00:00+00'::timestamptz,
         'CLN 108','{"latitude":-15.7905,"longitude":-47.8855}'::jsonb,
         16000::bigint, 1, true, false, false, 'Gerente', 'urgencia'::public.modo_preenchimento,
         %L::uuid, 'camisa preta', true, 'porta dos fundos', 180) $$,
    (select casa_id from ids), (select id from f), gen_random_uuid())) as r;
select pg_temp.guarda('publicarVaga', (select r from vaga1));

create temp table vaga2 as
  select pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.republicar_vaga(%L::uuid, '2027-01-25 21:00:00+00'::timestamptz,
         '2027-01-26 03:00:00+00'::timestamptz, %L::uuid) $$,
    ((select r from vaga1)->>'vaga_id')::uuid, gen_random_uuid())) as r;
select pg_temp.guarda('republicarVaga', (select r from vaga2));

select pg_temp.guarda('vagasAbertas', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.vagas_abertas(-15.7900, -47.8850) $$));

select pg_temp.guarda('detalheVaga', pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
  $$ select public.detalhe_vaga(%L::uuid) $$, ((select r from vaga1)->>'vaga_id')::uuid)));

create temp table cand as
  select pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.candidatar(%L::uuid) $$, ((select r from vaga1)->>'vaga_id')::uuid)) as r;
select pg_temp.guarda('candidatar', (select r from cand));

-- A segunda vaga recebe o outro profissional: é o turno do check-in manual.
create temp table cand2 as
  select pg_temp.como('cc000000-0000-4000-8000-000000000003', format(
    $$ select public.candidatar(%L::uuid) $$, ((select r from vaga2)->>'vaga_id')::uuid)) as r;

select pg_temp.guarda('meusTurnos', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.meus_turnos() $$));

select pg_temp.guarda('contatoDoTurno', pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
  $$ select public.contato_do_turno(%L::uuid) $$, ((select r from cand)->>'turno_id')::uuid)));

-- ── A presença, com o relógio no turno ────────────────────────────────────────
set local frila.agora = '2027-01-18 21:05:00+00';

select pg_temp.guarda('fazerCheckin', pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
  $$ select public.fazer_checkin(%L::uuid, 40, '2027-01-18 21:05:00+00'::timestamptz) $$,
  ((select r from cand)->>'turno_id')::uuid)));

set local frila.agora = '2027-01-19 02:55:00+00';

select pg_temp.guarda('fazerCheckout', pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
  $$ select public.fazer_checkout(%L::uuid, 55, '2027-01-19 02:55:00+00'::timestamptz) $$,
  ((select r from cand)->>'turno_id')::uuid)));

-- Check-in manual na segunda vaga, e a confirmação pelo contratante.
set local frila.agora = '2027-01-25 21:05:00+00';
select pg_temp.como('cc000000-0000-4000-8000-000000000003', format(
  $$ select public.fazer_checkin(%L::uuid, null, '2027-01-25 21:05:00+00'::timestamptz) $$,
  ((select r from cand2)->>'turno_id')::uuid));
select pg_temp.guarda('confirmarCheckinManual', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.confirmar_checkin_manual(%L::uuid) $$, ((select r from cand2)->>'turno_id')::uuid)));

-- ── Avaliar e o perfil público ────────────────────────────────────────────────
set local frila.agora = '2027-01-19 04:00:00+00';

select pg_temp.guarda('avaliar', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.avaliar(%L::uuid, true) $$, ((select r from cand)->>'turno_id')::uuid)));

select pg_temp.guarda('perfilPublico', pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
  $$ select public.perfil_publico(%L::uuid) $$,
  (select p.id from public.profissional p where p.usuario_id = 'cc000000-0000-4000-8000-000000000002'))));

-- ── Cancelar ──────────────────────────────────────────────────────────────────
set local frila.agora = '2027-01-24 09:00:00+00';

select pg_temp.guarda('cancelarPosicao', pg_temp.como('cc000000-0000-4000-8000-000000000003', format(
  $$ select public.cancelar_posicao(%L::uuid, 'imprevisto') $$,
  ((select r from cand2)->>'posicao_id')::uuid)));

select pg_temp.guarda('cancelarVaga', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.cancelar_vaga(%L::uuid, 'evento adiado') $$,
  ((select r from vaga2)->>'vaga_id')::uuid)));

-- ── As recusas, no envelope do contrato ───────────────────────────────────────
--
-- Uma por código de erro que as RPCs da v1.0 levantam. O validador confere cada uma
-- contra o schema `Erro`, e não contra o que eu lembro que o envelope tem.
-- Sem `sub` no JWT: `auth.uid()` devolve NULL, que é o caso de sessão ausente. Passar um
-- uuid desconhecido **não** serve — isso é sessão válida de conta que não existe, e a
-- resposta certa ali é `nao_encontrado`. Medido ao escrever este arquivo.
do $$
declare msg text;
begin
  begin
    perform public.minha_conta();
  exception when others then
    get stacked diagnostics msg = message_text;
    insert into colhido (op, corpo) values ('erro:nao_autenticado', msg::jsonb);
  end;
end $$;
select pg_temp.guarda('erro:perfil_incompativel',
  pg_temp.recusa('cc000000-0000-4000-8000-000000000002', $$ select public.meus_estabelecimentos() $$));
select pg_temp.guarda('erro:campo_obrigatorio',
  pg_temp.recusa('cc000000-0000-4000-8000-000000000001',
    $$ select public.republicar_vaga(null::uuid, now(), now() + interval '1 h', gen_random_uuid()) $$));
select pg_temp.guarda('erro:nao_encontrado',
  pg_temp.recusa('cc000000-0000-4000-8000-000000000002',
    $$ select public.detalhe_vaga('cc000000-0000-4000-8000-0000000000ff'::uuid) $$));
-- `sem_permissao` é "existe e não é seu". O painel de uma casa de que a conta não é
-- membro devolve isso — e devolve 403, e não 404, de propósito: quem pergunta pelo painel
-- já veio da própria lista de casas.
select pg_temp.guarda('erro:sem_permissao',
  pg_temp.recusa('cc000000-0000-4000-8000-000000000001',
    $$ select public.painel_estabelecimento('cc000000-0000-4000-8000-0000000000ee'::uuid,
         '2027-01-01T00:00:00Z'::timestamptz, '2027-12-31T00:00:00Z'::timestamptz) $$));
select pg_temp.guarda('erro:horario_invalido',
  pg_temp.recusa('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.republicar_vaga(%L::uuid, '2027-01-30 03:00:00+00'::timestamptz, '2027-01-30 01:00:00+00'::timestamptz, gen_random_uuid()) $$,
    ((select r from vaga1)->>'vaga_id')::uuid)));
select pg_temp.guarda('erro:avaliacao_indisponivel',
  pg_temp.recusa('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.avaliar(%L::uuid, true) $$, ((select r from cand2)->>'turno_id')::uuid)));

-- ── A colheita ────────────────────────────────────────────────────────────────
\o
\pset format unaligned
\pset tuples_only on
select jsonb_build_object('op', op, 'corpo', corpo)::text from colhido order by ordem;

rollback;
