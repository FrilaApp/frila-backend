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

-- Observa o STATUS de uma tentativa, e não o corpo dela: devolve `{"status": n}` com o
-- código que o envelope de `public.erro` carrega em DETAIL, ou `{"status": 200}` quando a
-- chamada passou. É o que sustenta a direção contrato-à-frente — a pergunta ali não é "o
-- corpo casa", é "a recusa que o contrato promete acontece".
create function pg_temp.observado(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare
  det text;
  msg text;
begin
  begin
    if conta is null then
      execute sql;
    else
      perform pg_temp.como(conta, sql);
    end if;
    return jsonb_build_object('status', 200, 'code', null);
  exception when others then
    get stacked diagnostics det = pg_exception_detail, msg = message_text;
    reset role;
    begin execute 'reset request.jwt.claims'; exception when others then null; end;
    -- Sem DETAIL não é recusa do contrato: é erro de banco, e dizer 500 aqui seria
    -- inventar um status que ninguém devolveu.
    return case when det is null or det = '' then jsonb_build_object('status', null, 'code', null)
                else jsonb_build_object(
                  'status', (det::jsonb->>'status')::int,
                  'code', case when msg ~ '^\s*\{' then (msg::jsonb->>'code') else null end
                ) end;
  end;
end $$;

create temp table colhido (ordem serial, op text, corpo jsonb);
create function pg_temp.guarda(op text, corpo jsonb) returns void
language sql as $$ insert into colhido (op, corpo) values (op, corpo) $$;

-- ── O cenário ──────────────────────────────────────────────────────────────────
insert into privado.ambiente (id, eh_teste) values (true, true);
set local frila.agora = '2027-01-11 09:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste';

insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', c.id, 'authenticated','authenticated', c.email,
       privado.agora(), privado.agora(), false, false
  from (values
    ('cc000000-0000-4000-8000-000000000001'::uuid,'contrato-casa@t.test'),
    ('cc000000-0000-4000-8000-000000000002'::uuid,'contrato-prof@t.test'),
    ('cc000000-0000-4000-8000-000000000003'::uuid,'contrato-prof2@t.test'),
    ('cc000000-0000-4000-8000-000000000004'::uuid,'contrato-suspenso@t.test'),
    ('cc000000-0000-4000-8000-000000000005'::uuid,'contrato-prof3@t.test')
  ) as c(id, email);

select pg_temp.guarda('criarConta', pg_temp.como('cc000000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante','Casa do Contrato','+5561944440001','1980-05-05','2026-09-22') $$));
select pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('profissional','Pê do Contrato','+5561944440002','1995-05-05','2026-09-22') $$);
select pg_temp.como('cc000000-0000-4000-8000-000000000003',
  $$ select public.criar_conta('profissional','Pê Dois','+5561944440003','1994-05-05','2026-09-22') $$);
select pg_temp.como('cc000000-0000-4000-8000-000000000004',
  $$ select public.criar_conta('profissional','Pê Suspenso','+5561944440004','1993-05-05','2026-09-22') $$);
select pg_temp.como('cc000000-0000-4000-8000-000000000005',
  $$ select public.criar_conta('profissional','Pê Três','+5561944440005','1992-05-05','2026-09-22') $$);

select pg_temp.guarda('minhaConta', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.minha_conta() $$));
select pg_temp.guarda('situacaoDaConta', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.situacao_da_conta() $$));

select pg_temp.guarda('registrarDispositivo', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.registrar_dispositivo('fcm_token_teste_harness_contrato_1234567890', 'ios') $$));

select pg_temp.como('cc000000-0000-4000-8000-000000000003',
  $$ select public.registrar_dispositivo('fcm_token_teste_harness_contrato_remover_01', 'ios') $$);
select pg_temp.guarda('removerDispositivo', pg_temp.como('cc000000-0000-4000-8000-000000000003',
  $$ select public.remover_dispositivo('fcm_token_teste_harness_contrato_remover_01') $$));

select pg_temp.guarda('registrarEvento', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.registrar_evento('app_aberto') $$));

create temp table f as select id from public.funcao where nome = 'garçom';

select pg_temp.guarda('criarPerfilProfissional', pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb,
       '[{"dia_semana":1,"hora_inicio":"08:00","hora_fim":"23:59"}]'::jsonb) $$, (select id from f))));
select pg_temp.como('cc000000-0000-4000-8000-000000000003', format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select id from f)));
select pg_temp.como('cc000000-0000-4000-8000-000000000005', format(
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

-- O cadastro da casa, para quem é membro dela (contrato 0.2.29): é de onde o app tira o
-- endereço, a região e o ponto para preencher a publicação da vaga.
select pg_temp.guarda('meuEstabelecimento', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.meu_estabelecimento(%L::uuid) $$, (select casa_id from ids))));



insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select (select casa_id from ids), p.id
  from public.profissional p
 where p.usuario_id = 'cc000000-0000-4000-8000-000000000002';

select pg_temp.guarda('criteriosDeNotificacao', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.criterios_de_notificacao() $$));

delete from public.equipe_confianca
 where profissional_id in (select id from public.profissional where usuario_id = 'cc000000-0000-4000-8000-000000000002');

select pg_temp.guarda('pedirRevisaoDespacho', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.pedir_revisao_despacho('Relato de teste para revisao do despacho no contrato.') $$));

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

-- ── Suporte a partir do turno (contrato 0.2.40) ────────────────────────────────
select pg_temp.guarda('abrirSuporte', pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
  $$ select public.abrir_suporte(%L::uuid, 'endereco', 'cc000000-0000-4000-8000-000000000777'::uuid) $$,
  ((select r from cand)->>'turno_id')::uuid)));

-- ── O modo seleção (contrato 0.2.24) ──────────────────────────────────────────
--
-- Uma vaga de seleção a onze dias, entre os turnos das outras duas: os dois profissionais
-- se candidatam, o Pê Dois retira e a casa escolhe o Pê.
create temp table vaga_sel as
  select pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-01-22 21:00:00+00'::timestamptz, '2027-01-23 03:00:00+00'::timestamptz,
         'CLN 108','{"latitude":-15.7905,"longitude":-47.8855}'::jsonb,
         16000::bigint, 1, true, false, false, 'Gerente', 'selecao'::public.modo_preenchimento,
         %L::uuid) $$,
    (select casa_id from ids), (select id from f), gen_random_uuid())) as r;
create temp table cand_sel as
  select pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.candidatar(%L::uuid) $$, ((select r from vaga_sel)->>'vaga_id')::uuid)) as r;
create temp table cand_sel2 as
  select pg_temp.como('cc000000-0000-4000-8000-000000000005', format(
    $$ select public.candidatar(%L::uuid) $$, ((select r from vaga_sel)->>'vaga_id')::uuid)) as r;

select pg_temp.guarda('candidatosDaVaga', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.candidatos_da_vaga(%L::uuid) $$, ((select r from vaga_sel)->>'vaga_id')::uuid)));
select pg_temp.guarda('minhasCandidaturas', pg_temp.como('cc000000-0000-4000-8000-000000000003',
  $$ select public.minhas_candidaturas() $$));
select pg_temp.guarda('retirarCandidatura', pg_temp.como('cc000000-0000-4000-8000-000000000005', format(
  $$ select public.retirar_candidatura(%L::uuid) $$, ((select r from cand_sel2)->>'candidatura_id')::uuid)));
select pg_temp.guarda('escolherCandidato', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.escolher_candidato(%L::uuid) $$, ((select r from cand_sel)->>'candidatura_id')::uuid)));

-- ── Republicar posições restantes em urgência (contrato 0.2.41) ────────────────
-- Vaga de seleção fechada com sobras: 2 posições, nenhuma escolhida -> sobram 2 posições.
create temp table vaga_sel_rep as
  select pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-01-23 21:00:00+00'::timestamptz, '2027-01-24 03:00:00+00'::timestamptz,
         'CLN 108','{"latitude":-15.7905,"longitude":-47.8855}'::jsonb,
         16000::bigint, 2, true, false, false, 'Gerente', 'selecao'::public.modo_preenchimento,
         %L::uuid) $$,
    (select casa_id from ids), (select id from f), gen_random_uuid())) as r;

-- Simula o fechamento automático da seleção levando as posições abertas a canceladas e a vaga a encerrada
update public.posicao set estado = 'cancelada' where vaga_id = ((select r from vaga_sel_rep)->>'vaga_id')::uuid;
update public.vaga set estado = 'encerrada' where id = ((select r from vaga_sel_rep)->>'vaga_id')::uuid;

select pg_temp.guarda('republicarPosicoesRestantes', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.republicar_posicoes_restantes(%L::uuid, %L::uuid) $$,
  ((select r from vaga_sel_rep)->>'vaga_id')::uuid, 'cc000000-0000-4000-8000-000000000888'::uuid)));

-- ── Estou a caminho, de 3 h antes até 15 min depois do início (0.2.25) ────────
set local frila.agora = '2027-01-18 17:59:59+00';
select pg_temp.guarda('erro:a_caminho_fora_da_janela',
  pg_temp.recusa('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.avisar_a_caminho(%L::uuid) $$, ((select r from cand)->>'turno_id')::uuid)));

set local frila.agora = '2027-01-18 20:30:00+00';
select pg_temp.guarda('avisarACaminho', pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
  $$ select public.avisar_a_caminho(%L::uuid) $$, ((select r from cand)->>'turno_id')::uuid)));

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
select pg_temp.guarda('painelEstabelecimento', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.painel_estabelecimento(%L::uuid, '2027-01-01T00:00:00Z'::timestamptz, '2027-12-31T00:00:00Z'::timestamptz) $$,
  (select casa_id from ids))));
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

-- ── Equipe de confiança ───────────────────────────────────────────────────────
select pg_temp.guarda('incluirNaEquipe', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.incluir_na_equipe(%L::uuid, %L::uuid) $$,
  (select casa_id from ids),
  (select p.id from public.profissional p where p.usuario_id = 'cc000000-0000-4000-8000-000000000002'))));

select pg_temp.guarda('equipeDeConfianca', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.equipe_de_confianca(%L::uuid) $$, (select casa_id from ids))));

select pg_temp.guarda('removerDaEquipe', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.remover_da_equipe(%L::uuid, %L::uuid) $$,
  (select casa_id from ids),
  (select p.id from public.profissional p where p.usuario_id = 'cc000000-0000-4000-8000-000000000002'))));

-- ── A configuração do app, sem sessão ─────────────────────────────────────────
--
-- É a única RPC que o app chama antes de entrar, então colhe como `anon`, e não pelo
-- `pg_temp.como`, que monta sessão. O `anon` não escreve em `colhido`: a resposta passa
-- por uma variável do psql e é guardada depois de voltar ao papel de antes.
set local role anon;
select public.configuracao_do_app('ios')::text as configuracao \gset
reset role;
select pg_temp.guarda('configuracaoDoApp', :'configuracao'::jsonb);

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

-- ── Reabrir por atraso ────────────────────────────────────────────────────────
--
-- Por último, porque anda o relógio para fevereiro: as recusas acima dependem do relógio
-- de janeiro. Um turno confirmado sem check-in, a recusa antes dos 15 minutos e a
-- reabertura depois deles.
create temp table vaga3 as
  select pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.republicar_vaga(%L::uuid, '2027-02-01 21:00:00+00'::timestamptz,
         '2027-02-02 03:00:00+00'::timestamptz, %L::uuid) $$,
    ((select r from vaga1)->>'vaga_id')::uuid, gen_random_uuid())) as r;
create temp table cand3 as
  select pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.candidatar(%L::uuid) $$, ((select r from vaga3)->>'vaga_id')::uuid)) as r;

set local frila.agora = '2027-02-01 21:05:00+00';
select pg_temp.guarda('erro:reabertura_antes_da_tolerancia',
  pg_temp.recusa('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.reabrir_por_atraso(%L::uuid) $$, ((select r from cand3)->>'posicao_id')::uuid)));

set local frila.agora = '2027-02-01 21:20:00+00';
select pg_temp.guarda('reabrirPorAtraso', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.reabrir_por_atraso(%L::uuid) $$, ((select r from cand3)->>'posicao_id')::uuid)));

-- ── Denunciar e bloquear ──────────────────────────────────────────────────────
--
-- Por último, porque o bloqueio esconderia a casa de quem bloqueou em tudo o que vem
-- depois. O Pê Dois bloqueia a casa; a casa denuncia o Pê.
select pg_temp.guarda('bloquear', pg_temp.como('cc000000-0000-4000-8000-000000000003', format(
  $$ select public.bloquear('estabelecimento', %L::uuid) $$, (select casa_id from ids))));
select pg_temp.guarda('denunciar', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.denunciar('profissional', %L::uuid, 'outro',
       'Relato do teste de contrato.', gen_random_uuid()) $$,
  (select p.id from public.profissional p
    where p.usuario_id = 'cc000000-0000-4000-8000-000000000002'))));

-- ── Suspensão e contestação (0.2.27) ─────────────────────────────────────────
--
-- Pê Suspenso é suspenso preventivamente pela casa/equipe, contesta a suspensão
-- com relato detalhado (recebe Protocolo) e confere o erro ao tentar contestar de novo.
select pg_temp.guarda('erro:sem_suspensao_ativa',
  pg_temp.recusa('cc000000-0000-4000-8000-000000000002',
    $$ select public.contestar_suspensao('Tentativa de contestacao por conta que nao esta suspensa.') $$));

select privado.suspender(
  'cc000000-0000-4000-8000-000000000004'::uuid,
  'Suspensão para validação contratual',
  'cc000000-0000-4000-8000-000000000001'::uuid
);

select pg_temp.guarda('contestarSuspensao', pg_temp.como('cc000000-0000-4000-8000-000000000004',
  $$ select public.contestar_suspensao('Apresento relato detalhado com mais de dez caracteres para contestar a suspensao.') $$));

select pg_temp.guarda('erro:contestacao_ja_aberta',
  pg_temp.recusa('cc000000-0000-4000-8000-000000000004',
    $$ select public.contestar_suspensao('Segunda tentativa de contestacao enquanto a primeira esta aberta.') $$));

-- ── Chamada direta, F4 parte A (0.2.55) ───────────────────────────────────────
-- O Pê Três está na equipe de confiança (vínculo na v1.1, RN28). O Pê do Contrato, com início
-- em 1 h, cai em 422 profissional_indisponivel. O interruptor nasce desligado: mede o 403.
create function pg_temp.chamar(prof text, daqui interval default '1 day') returns text
language sql as $$ select format($c$ select public.chamar_profissional(chave => gen_random_uuid(),
  profissional_id => %L,
  estabelecimento_id => %L, funcao_id => %L, inicio_em => %L, fim_em => %L, local => 'CLN 108',
  regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7905,"longitude":-47.8855}',
  valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false,
  exige_material_proprio => false, responsavel_local => 'Gerente', recado => 'Precisamos de você no sábado') $c$,
  coalesce((select p.id from public.profissional p where p.usuario_id = prof::uuid), prof::uuid), (select casa_id from ids), (select id from f), privado.agora() + daqui, privado.agora() + daqui + interval '5 hours') $$;
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select (select casa_id from ids), p.id from public.profissional p where p.usuario_id = 'cc000000-0000-4000-8000-000000000005';
select pg_temp.guarda('promete:chamarProfissional:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', pg_temp.chamar('cc000000-0000-4000-8000-000000000005')));
update privado.recurso set ligado = true where chave = 'chamada_direta';
-- 0.2.66: só se chama quem tem aparelho na versão mínima de chamada_direta (20261108160000).
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do nothing;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select p.usuario_id, 'tok-colheita-' || p.usuario_id, 'ios', '1.2.0'
  from public.profissional p where p.usuario_id::text like 'cc000000-%'
on conflict (token_fcm) do nothing;
select pg_temp.guarda('chamarProfissional', pg_temp.como('cc000000-0000-4000-8000-000000000001',
  pg_temp.chamar('cc000000-0000-4000-8000-000000000005')));
select pg_temp.guarda('promete:chamarProfissional:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', pg_temp.chamar('cc000000-0000-4000-8000-000000000005')));
select pg_temp.guarda('promete:chamarProfissional:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', pg_temp.chamar('cc000000-0000-4000-8000-000000000002', interval '1 hour')));
select pg_temp.guarda('promete:chamarProfissional:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', pg_temp.chamar('cc000000-0000-4000-8000-0000000000fe')));
select pg_temp.guarda('promete:chamarProfissional:401',
  pg_temp.observado(null, pg_temp.chamar('cc000000-0000-4000-8000-000000000005')));

-- ── Chamada direta, F4 partes B e C (0.2.55, 0.2.56): as seis RPCs vigiadas ───
-- A chamada 1 (casa → Pê Três) fica aberta acima. Leitura e preferência pelo Pê Três; as
-- recusas de resposta antes do aceite e depois o aceite (200). A chamada 2 (casa → Pê do
-- Contrato, posto na equipe; o Pê Dois bloqueou a casa acima) é cancelada (200) e a vaga dela
-- vira pública (200). Repetir resposta ou cancelamento é idempotente (200); os 409 vêm do
-- outro estado: cancelar a chamada 1, já aceita, e responder a chamada 2, já cancelada. A 409
-- da conversão usa a vaga da chamada 1, encerrada à mão no cenário. O Pê Suspenso (…0004)
-- mede os 403; o Pê Sem Perfil (…0006), o 404 da preferência; a conta nula, os 401.
create temp table ch1 as
  select c.id, c.vaga_id from public.chamada c
    join public.profissional p on p.id = c.profissional_id
   where p.usuario_id = 'cc000000-0000-4000-8000-000000000005' and c.estado = 'aberta'
   order by c.criada_em limit 1;

select pg_temp.guarda('detalheChamada', pg_temp.como('cc000000-0000-4000-8000-000000000005',
  format('select public.detalhe_chamada(%L)', (select id from ch1))));
select pg_temp.guarda('promete:detalheChamada:404', pg_temp.observado('cc000000-0000-4000-8000-000000000002',
  format('select public.detalhe_chamada(%L)', (select id from ch1))));
select pg_temp.guarda('minhasChamadas', pg_temp.como('cc000000-0000-4000-8000-000000000005',
  $$select public.minhas_chamadas()$$));
select pg_temp.guarda('promete:minhasChamadas:422', pg_temp.observado('cc000000-0000-4000-8000-000000000005',
  $$select public.minhas_chamadas(estado => 'qualquer')$$));
select pg_temp.guarda('definirPreferenciaChamadas', pg_temp.como('cc000000-0000-4000-8000-000000000005',
  $$select public.definir_preferencia_chamadas(aceita_de_quem_ja_trabalhou => true)$$));
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'cc000000-0000-4000-8000-000000000006', 'authenticated', 'authenticated',
        'contrato-sem-perfil@t.test', privado.agora(), privado.agora(), false, false);
select pg_temp.como('cc000000-0000-4000-8000-000000000006',
  $$ select public.criar_conta('profissional','Pê Sem Perfil','+5561944440006','1991-05-05','2026-09-22') $$);
select pg_temp.guarda('promete:definirPreferenciaChamadas:404', pg_temp.observado('cc000000-0000-4000-8000-000000000006',
  $$select public.definir_preferencia_chamadas(aceita_de_quem_ja_trabalhou => true)$$));
select pg_temp.guarda('promete:definirPreferenciaChamadas:422', pg_temp.observado('cc000000-0000-4000-8000-000000000005',
  $$select public.definir_preferencia_chamadas()$$));

select pg_temp.guarda('promete:responderChamada:422', pg_temp.observado('cc000000-0000-4000-8000-000000000005',
  format('select public.responder_chamada(%L, %L)', (select id from ch1), 'talvez')));
select pg_temp.guarda('promete:responderChamada:404', pg_temp.observado('cc000000-0000-4000-8000-000000000002',
  format('select public.responder_chamada(%L, %L)', (select id from ch1), 'aceitar')));
select pg_temp.guarda('responderChamada', pg_temp.como('cc000000-0000-4000-8000-000000000005',
  format('select public.responder_chamada(%L, %L)', (select id from ch1), 'aceitar')));

insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select (select casa_id from ids), p.id from public.profissional p where p.usuario_id = 'cc000000-0000-4000-8000-000000000002';
select pg_temp.como('cc000000-0000-4000-8000-000000000001', pg_temp.chamar('cc000000-0000-4000-8000-000000000002'));
create temp table ch2 as
  select c.id, c.vaga_id from public.chamada c
    join public.profissional p on p.id = c.profissional_id
   where p.usuario_id = 'cc000000-0000-4000-8000-000000000002' and c.estado = 'aberta'
   order by c.criada_em limit 1;
select pg_temp.guarda('cancelarChamada', pg_temp.como('cc000000-0000-4000-8000-000000000001',
  format('select public.cancelar_chamada(%L)', (select id from ch2))));
select pg_temp.guarda('promete:cancelarChamada:409', pg_temp.observado('cc000000-0000-4000-8000-000000000001',
  format('select public.cancelar_chamada(%L)', (select id from ch1))));
select pg_temp.guarda('promete:responderChamada:409', pg_temp.observado('cc000000-0000-4000-8000-000000000002',
  format('select public.responder_chamada(%L, %L)', (select id from ch2), 'aceitar')));

select pg_temp.guarda('promete:publicarAPartirDaChamada:422', pg_temp.observado('cc000000-0000-4000-8000-000000000001',
  format('select public.publicar_a_partir_da_chamada(%L)', (select vaga_id from ch2))));
select pg_temp.guarda('publicarAPartirDaChamada', pg_temp.como('cc000000-0000-4000-8000-000000000001',
  format('select public.publicar_a_partir_da_chamada(%L, gen_random_uuid())', (select vaga_id from ch2))));
update public.vaga set estado = 'cancelada' where id = (select vaga_id from ch1);
select pg_temp.guarda('promete:publicarAPartirDaChamada:409', pg_temp.observado('cc000000-0000-4000-8000-000000000001',
  format('select public.publicar_a_partir_da_chamada(%L, gen_random_uuid())', (select vaga_id from ch1))));

select pg_temp.guarda('promete:' || op || ':401', pg_temp.observado(null, sql)) from (values
  ('detalheChamada', $$select public.detalhe_chamada(gen_random_uuid())$$),
  ('minhasChamadas', $$select public.minhas_chamadas()$$),
  ('definirPreferenciaChamadas', $$select public.definir_preferencia_chamadas(aceita_de_quem_ja_trabalhou => true)$$),
  ('responderChamada', $$select public.responder_chamada(gen_random_uuid(), 'aceitar')$$),
  ('cancelarChamada', $$select public.cancelar_chamada(gen_random_uuid())$$),
  ('publicarAPartirDaChamada', $$select public.publicar_a_partir_da_chamada(gen_random_uuid(), gen_random_uuid())$$)) t(op, sql);
select pg_temp.guarda('promete:' || op || ':403', pg_temp.observado('cc000000-0000-4000-8000-000000000004', sql)) from (values
  ('detalheChamada', $$select public.detalhe_chamada(gen_random_uuid())$$),
  ('minhasChamadas', $$select public.minhas_chamadas()$$),
  ('definirPreferenciaChamadas', $$select public.definir_preferencia_chamadas(aceita_de_quem_ja_trabalhou => true)$$),
  ('responderChamada', $$select public.responder_chamada(gen_random_uuid(), 'aceitar')$$),
  ('cancelarChamada', $$select public.cancelar_chamada(gen_random_uuid())$$),
  ('publicarAPartirDaChamada', $$select public.publicar_a_partir_da_chamada(gen_random_uuid(), gen_random_uuid())$$)) t(op, sql);
select pg_temp.guarda('promete:' || op || ':404', pg_temp.observado('cc000000-0000-4000-8000-000000000001', sql)) from (values
  ('cancelarChamada', $$select public.cancelar_chamada(gen_random_uuid())$$),
  ('publicarAPartirDaChamada', $$select public.publicar_a_partir_da_chamada(gen_random_uuid(), gen_random_uuid())$$)) t(op, sql);

-- ── A direção contrato-à-frente: a recusa que o contrato promete ─────────────
--
-- Cartão `EFveOeIb`. Os outros portões medem o contrato ATRÁS do código — espelho
-- divergente, PR que mexe em `public` sem mexer no contrato, corpo de sucesso que não
-- casa. A direção em que o **contrato promete e o código não entrega** não tinha portão:
-- a 0.2.28 passou a prometer `404` em `perfil_publico` entre partes bloqueadas, a função
-- não filtra bloqueio, e nada reprovou.
--
-- Vem depois do `bloquear` de propósito, e é a única colheita que depende dele. O
-- comentário acima diz que o bloqueio ficou por último "porque esconderia a casa de quem
-- bloqueou em tudo o que vem depois" — e era justamente por isso que nenhuma colheita
-- acontecia com um par bloqueado.
--
-- Os dois sentidos, porque é o que o contrato promete: o Pê Dois bloqueou a casa, então
-- nem ele vê a casa nem a casa vê ele.
select pg_temp.guarda('promete:perfilPublico:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000003', format(
    $$ select public.perfil_publico(%L::uuid) $$, (select casa_id from ids))));

select pg_temp.guarda('promete:perfilPublico:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.perfil_publico(%L::uuid) $$,
    (select p.id from public.profissional p
      where p.usuario_id = 'cc000000-0000-4000-8000-000000000003'))));

-- ── 15 pares de maior risco (privacidade, dinheiro, exclusão, bloqueio, autorização) ──
-- 1. contatoDoTurno: 403 sem_permissao (conta suspensa tentando ler contato do turno)
select pg_temp.guarda('promete:contatoDoTurno:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004', format(
    $$ select public.contato_do_turno(%L::uuid) $$, ((select r from cand)->>'turno_id')::uuid)));

-- 2. contatoDoTurno: 404 nao_encontrado (turno inexistente)
select pg_temp.guarda('promete:contatoDoTurno:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.contato_do_turno('c0000000-0000-4000-8000-000000000099'::uuid) $$));

-- 3. cancelarPosicao: 409 posicao_nao_cancelavel (contraparte tentando cancelar posição já cancelada)
select pg_temp.guarda('promete:cancelarPosicao:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.cancelar_posicao(%L::uuid, 'duplicado') $$,
    ((select r from cand2)->>'posicao_id')::uuid)));

-- Outro membro da casa para exercitar recusas de autorização/encerramento
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values ('ee000000-0000-4000-8000-000000000099', 'contratante', 'Aux Contratante', '+5561999999999', 'aux@frila.test', '1990-01-01', '1.0', now(), 'ativa')
on conflict do nothing;

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ((select casa_id from ids), 'ee000000-0000-4000-8000-000000000099', 'operador')
on conflict do nothing;

-- 4. cancelarVaga: 409 vaga_encerrada (outro membro tentando cancelar vaga já cancelada)
select pg_temp.guarda('promete:cancelarVaga:409',
  pg_temp.observado('ee000000-0000-4000-8000-000000000099', format(
    $$ select public.cancelar_vaga(%L::uuid, 'duplicado') $$,
    ((select r from vaga2)->>'vaga_id')::uuid)));

-- 5. excluirConta: 409 administrador_unico (único admin de estabelecimento com outros membros)
select pg_temp.guarda('promete:excluirConta:409',
  pg_temp.observado(null, format(
    $$ select privado.excluir_conta(%L::uuid) $$, 'cc000000-0000-4000-8000-000000000001'::uuid)));

delete from public.membro_estabelecimento
 where estabelecimento_id = (select casa_id from ids)
   and usuario_id = 'ee000000-0000-4000-8000-000000000099';

-- 6. bloquear: 403 sem_permissao (conta suspensa tenta registrar bloqueio)
select pg_temp.guarda('promete:bloquear:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004', format(
    $$ select public.bloquear('estabelecimento', %L::uuid) $$, (select casa_id from ids))));

-- 7. bloquear: 422 campo_invalido (tentativa de auto-bloqueio)
select pg_temp.guarda('promete:bloquear:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.bloquear('profissional', (select p.id from public.profissional p where p.usuario_id = 'cc000000-0000-4000-8000-000000000002')) $$)));

-- 8. denunciar: 403 sem_permissao (conta suspensa tenta abrir denúncia)
select pg_temp.guarda('promete:denunciar:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004', format(
    $$ select public.denunciar('estabelecimento', %L::uuid, 'outro', 'relato de teste', gen_random_uuid()) $$,
    (select casa_id from ids))));

-- 9. contestarSuspensao: 409 contestacao_ja_aberta (segunda contestação enquanto a primeira está aberta)
select pg_temp.guarda('promete:contestarSuspensao:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004',
    $$ select public.contestar_suspensao('Segunda tentativa de contestacao enquanto a primeira esta aberta.') $$));

-- 10. contestarSuspensao: 422 sem_suspensao_ativa (conta não suspensa tenta contestar)
select pg_temp.guarda('promete:contestarSuspensao:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.contestar_suspensao('Conta ativa tentando contestar suspensao inexistente.') $$));

-- 11. reabrirPorAtraso: 409 posicao_nao_cancelavel (posição já possui check-in realizado)
select pg_temp.guarda('promete:reabrirPorAtraso:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.reabrir_por_atraso(%L::uuid) $$, ((select r from cand)->>'posicao_id')::uuid)));

-- 12. reabrirPorAtraso: 403 sem_permissao (não membro da contratante dona da vaga tenta reabrir)
select pg_temp.guarda('promete:reabrirPorAtraso:403',
  pg_temp.observado('ee000000-0000-4000-8000-000000000099', format(
    $$ select public.reabrir_por_atraso(%L::uuid) $$, ((select r from cand3)->>'posicao_id')::uuid)));

-- 13. confirmarCheckinManual: 409 checkin_ja_confirmado (checkin geolocalizado já nasce verificado)
select pg_temp.guarda('promete:confirmarCheckinManual:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.confirmar_checkin_manual(%L::uuid) $$, ((select r from cand)->>'turno_id')::uuid)));

-- 14. fazerCheckin: 409 vaga_encerrada (trigger turno_checkin_nunca_em_posicao_cancelada impede checkin em posição cancelada)
select pg_temp.guarda('promete:fazerCheckin:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.fazer_checkin(%L::uuid, 40, '2027-02-01 21:20:00+00'::timestamptz) $$,
    ((select r from cand3)->>'turno_id')::uuid)));

-- 15. fazerCheckout: 409 checkin_pendente (checkout tentado antes de registrar check-in)
select pg_temp.guarda('promete:fazerCheckout:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.fazer_checkout(%L::uuid, 40, '2027-02-01 22:00:00+00'::timestamptz) $$,
    ((select r from cand3)->>'turno_id')::uuid)));

-- ── Lote 2: 20 pares críticos por risco (cancelamento, seleção, cadastro, bloqueio) ──
-- 16. cancelarPosicao: 404 nao_encontrado (posição inexistente)
select pg_temp.guarda('promete:cancelarPosicao:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000003',
    $$ select public.cancelar_posicao('c0000000-0000-4000-8000-000000000099'::uuid, 'imprevisto') $$));

-- 17. cancelarPosicao: 403 sem_permissao (conta suspensa tentando cancelar posição)
select pg_temp.guarda('promete:cancelarPosicao:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004',
    $$ select public.cancelar_posicao('c0000000-0000-4000-8000-000000000099'::uuid, 'imprevisto') $$));

-- 18. cancelarVaga: 404 nao_encontrado (vaga inexistente)
select pg_temp.guarda('promete:cancelarVaga:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.cancelar_vaga('c0000000-0000-4000-8000-000000000099'::uuid, 'evento adiado') $$));

-- 19. cancelarVaga: 403 sem_permissao (contratante suspenso tentando cancelar vaga)
update public.usuario set estado = 'suspensa' where id = 'ee000000-0000-4000-8000-000000000099';
select pg_temp.guarda('promete:cancelarVaga:403',
  pg_temp.observado('ee000000-0000-4000-8000-000000000099', format(
    $$ select public.cancelar_vaga(%L::uuid, 'evento adiado') $$, ((select r from vaga1)->>'vaga_id')::uuid)));

-- 20. publicarVaga: 403 sem_permissao (não membro tentando publicar vaga no estabelecimento)
update public.usuario set estado = 'ativa' where id = 'ee000000-0000-4000-8000-000000000099';
select pg_temp.guarda('promete:publicarVaga:403',
  pg_temp.observado('ee000000-0000-4000-8000-000000000099', format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-02-10 21:00:00+00'::timestamptz, '2027-02-11 03:00:00+00'::timestamptz,
         'CLN 108','{"latitude":-15.7905,"longitude":-47.8855}'::jsonb,
         16000::bigint, 1, true, false, false, 'Gerente', 'urgencia'::public.modo_preenchimento,
         gen_random_uuid()) $$,
    (select casa_id from ids), (select id from f))));

-- 21. candidatar: 404 nao_encontrado (vaga inexistente)
select pg_temp.guarda('promete:candidatar:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.candidatar('c0000000-0000-4000-8000-000000000099'::uuid) $$));

-- 22. candidatar: 409 vaga_encerrada (candidatura em vaga cancelada)
select pg_temp.guarda('promete:candidatar:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.candidatar(%L::uuid) $$, ((select r from vaga2)->>'vaga_id')::uuid)));

-- 23. retirarCandidatura: 404 nao_encontrado (candidatura inexistente)
select pg_temp.guarda('promete:retirarCandidatura:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.retirar_candidatura('c0000000-0000-4000-8000-000000000099'::uuid) $$));

-- 24. retirarCandidatura: 409 candidatura_indisponivel (candidatura já aceita/confirmada)
select pg_temp.guarda('promete:retirarCandidatura:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.retirar_candidatura(%L::uuid) $$, ((select r from cand)->>'candidatura_id')::uuid)));

-- 25. escolherCandidato: 403 sem_permissao (candidatura inexistente ou de outra casa)
select pg_temp.guarda('promete:escolherCandidato:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.escolher_candidato('c0000000-0000-4000-8000-000000000099'::uuid) $$));

-- 26. escolherCandidato: 409 posicao_ja_preenchida (vaga de seleção já preenchida)
select pg_temp.guarda('promete:escolherCandidato:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.escolher_candidato(%L::uuid) $$, ((select r from cand_sel2)->>'candidatura_id')::uuid)));

-- 27. avaliar: 403 sem_permissao (profissional que não participou do turno)
select pg_temp.guarda('promete:avaliar:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000003', format(
    $$ select public.avaliar(%L::uuid, true) $$, ((select r from cand)->>'turno_id')::uuid)));

-- 28. avaliar: 409 avaliacao_ja_registrada (avaliação conflitante para o mesmo turno)
select pg_temp.guarda('promete:avaliar:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.avaliar(%L::uuid, false) $$, ((select r from cand)->>'turno_id')::uuid)));

-- 29. cadastrarEstabelecimento: 409 documento_ja_cadastrado (CNPJ duplicado)
select pg_temp.guarda('promete:cadastrarEstabelecimento:409',
  pg_temp.observado('ee000000-0000-4000-8000-000000000099',
    $$ select public.cadastrar_estabelecimento('Outra Casa','29979036000140','food_service',
         'CLN 109','{"latitude":-15.7905,"longitude":-47.8855}') $$));

-- 30. cadastrarEstabelecimento: 403 sem_permissao (conta suspensa)
update public.usuario set estado = 'suspensa' where id = 'ee000000-0000-4000-8000-000000000099';
select pg_temp.guarda('promete:cadastrarEstabelecimento:403',
  pg_temp.observado('ee000000-0000-4000-8000-000000000099',
    $$ select public.cadastrar_estabelecimento('Outra Casa','44211993000160','food_service',
         'CLN 109','{"latitude":-15.7905,"longitude":-47.8855}') $$));

-- 31. bloquear: 404 nao_encontrado (alvo inexistente)
select pg_temp.guarda('promete:bloquear:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.bloquear('estabelecimento', 'c0000000-0000-4000-8000-000000000099'::uuid) $$));

-- 32. denunciar: 404 nao_encontrado (alvo inexistente)
select pg_temp.guarda('promete:denunciar:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.denunciar('estabelecimento', 'c0000000-0000-4000-8000-000000000099'::uuid, 'outro', 'relato de teste para denuncia 404', gen_random_uuid()) $$));

-- 33. denunciar: 422 campo_invalido (motivo inválido)
select pg_temp.guarda('promete:denunciar:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.denunciar('estabelecimento', %L::uuid, 'motivo_invalido', 'relato de teste para denuncia 422', gen_random_uuid()) $$,
    (select casa_id from ids))));

-- 34. avisarACaminho: 403 sem_permissao (não é o profissional confirmado do turno)
select pg_temp.guarda('promete:avisarACaminho:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000003', format(
    $$ select public.avisar_a_caminho(%L::uuid) $$, ((select r from cand)->>'turno_id')::uuid)));

-- 35. configuracaoDoApp: 404 nao_encontrado (plataforma sem linha de configuração)
select pg_temp.guarda('promete:configuracaoDoApp:404',
  pg_temp.observado(null,
    $$ select public.configuracao_do_app('android') $$));

delete from public.usuario where id = 'ee000000-0000-4000-8000-000000000099';

-- ── Lote 3: 15 pares críticos por risco (presença, turnos, vagas, equipe) ──────
-- 36. confirmarCheckinManual: 403 sem_permissao (não membro do estabelecimento tentando confirmar)
select pg_temp.guarda('promete:confirmarCheckinManual:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.confirmar_checkin_manual(%L::uuid) $$, ((select r from cand)->>'turno_id')::uuid)));

-- 37. confirmarCheckinManual: 404 nao_encontrado (turno inexistente)
select pg_temp.guarda('promete:confirmarCheckinManual:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.confirmar_checkin_manual('c0000000-0000-4000-8000-000000000099'::uuid) $$));

-- 38. fazerCheckin: 403 sem_permissao (profissional suspenso tentando fazer check-in)
select pg_temp.guarda('promete:fazerCheckin:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004', format(
    $$ select public.fazer_checkin(%L::uuid, 40, '2027-01-18 21:05:00+00'::timestamptz) $$,
    ((select r from cand)->>'turno_id')::uuid)));

-- 39. fazerCheckin: 404 nao_encontrado (turno inexistente)
select pg_temp.guarda('promete:fazerCheckin:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.fazer_checkin('c0000000-0000-4000-8000-000000000099'::uuid, 40, '2027-01-18 21:05:00+00'::timestamptz) $$));

-- 40. fazerCheckout: 403 sem_permissao (profissional suspenso tentando fazer checkout)
select pg_temp.guarda('promete:fazerCheckout:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004', format(
    $$ select public.fazer_checkout(%L::uuid, 40, '2027-01-19 02:55:00+00'::timestamptz) $$,
    ((select r from cand)->>'turno_id')::uuid)));

-- 41. fazerCheckout: 404 nao_encontrado (turno inexistente)
select pg_temp.guarda('promete:fazerCheckout:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.fazer_checkout('c0000000-0000-4000-8000-000000000099'::uuid, 40, '2027-01-19 02:55:00+00'::timestamptz) $$));

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values ('ee000000-0000-4000-8000-000000000098', 'contratante', 'Outro Contratante', '+5561999999998', 'outro_contratante@frila.test', '1990-01-01', '1.0', now(), 'ativa')
on conflict do nothing;

-- 42. republicarVaga: 403 sem_permissao (contratante de outro estabelecimento tentando republicar vaga)
select pg_temp.guarda('promete:republicarVaga:403',
  pg_temp.observado('ee000000-0000-4000-8000-000000000098', format(
    $$ select public.republicar_vaga(%L::uuid, '2027-02-15 21:00:00+00'::timestamptz, '2027-02-16 03:00:00+00'::timestamptz, gen_random_uuid()) $$,
    ((select r from vaga1)->>'vaga_id')::uuid)));

-- 43. republicarVaga: 404 nao_encontrado (vaga de origem inexistente)
select pg_temp.guarda('promete:republicarVaga:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.republicar_vaga('c0000000-0000-4000-8000-000000000099'::uuid, '2027-02-15 21:00:00+00'::timestamptz, '2027-02-16 03:00:00+00'::timestamptz, gen_random_uuid()) $$));

-- 44. detalheVaga: 403 sem_permissao (profissional suspenso tentando ver detalhe da vaga)
select pg_temp.guarda('promete:detalheVaga:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004', format(
    $$ select public.detalhe_vaga(%L::uuid) $$, ((select r from vaga1)->>'vaga_id')::uuid)));

-- 45. detalheVaga: 404 nao_encontrado (vaga inexistente)
select pg_temp.guarda('promete:detalheVaga:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.detalhe_vaga('c0000000-0000-4000-8000-000000000099'::uuid) $$));

-- 46. candidatosDaVaga: 403 sem_permissao (contratante de outro estabelecimento tentando listar candidatos)
select pg_temp.guarda('promete:candidatosDaVaga:403',
  pg_temp.observado('ee000000-0000-4000-8000-000000000098', format(
    $$ select public.candidatos_da_vaga(%L::uuid) $$, ((select r from vaga1)->>'vaga_id')::uuid)));

-- 47. candidatosDaVaga: 404 nao_encontrado (vaga inexistente)
select pg_temp.guarda('promete:candidatosDaVaga:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.candidatos_da_vaga('c0000000-0000-4000-8000-000000000099'::uuid) $$));

-- 48. incluirNaEquipe: 403 sem_permissao (profissional sem turno verificado cumprido no estabelecimento)
select pg_temp.guarda('promete:incluirNaEquipe:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.incluir_na_equipe(%L::uuid, 'e0000000-0000-4000-8000-000000000004'::uuid) $$,
    (select casa_id from ids))));

-- 49. incluirNaEquipe: 404 nao_encontrado (profissional inexistente)
select pg_temp.guarda('promete:incluirNaEquipe:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.incluir_na_equipe(%L::uuid, 'c0000000-0000-4000-8000-000000000099'::uuid) $$,
    (select casa_id from ids))));

-- 50. removerDaEquipe: 403 sem_permissao (contratante de outro estabelecimento tentando remover da equipe)
select pg_temp.guarda('promete:removerDaEquipe:403',
  pg_temp.observado('ee000000-0000-4000-8000-000000000098', format(
    $$ select public.remover_da_equipe(%L::uuid, 'e0000000-0000-4000-8000-000000000004'::uuid) $$,
    (select casa_id from ids))));

delete from public.usuario where id = 'ee000000-0000-4000-8000-000000000098';

-- ── Lote 4: 15 pares críticos por risco (autorização, existência e unicidade) ──

-- 51. criarPerfilProfissional: 403 sem_permissao (profissional suspenso tentando cadastrar perfil)
select pg_temp.guarda('promete:criarPerfilProfissional:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004', format(
    $$ select public.criar_perfil_profissional(array[%L::uuid], null, null) $$, (select id from f))));

-- 52. atualizarPerfilProfissional: 403 sem_permissao (profissional suspenso tentando atualizar perfil)
select pg_temp.guarda('promete:atualizarPerfilProfissional:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004', format(
    $$ select public.atualizar_perfil_profissional(array[%L::uuid], null, null) $$, (select id from f))));

-- 53. pedirRevisaoDespacho: 403 sem_permissao (profissional suspenso tentando pedir revisao)
select pg_temp.guarda('promete:pedirRevisaoDespacho:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004',
    $$ select public.pedir_revisao_despacho('Relato detalhado para pedir revisao de despacho com tamanho suficiente.') $$));

-- 54. meuEstabelecimento: 403 sem_permissao (chamador nao e membro do estabelecimento)
select pg_temp.guarda('promete:meuEstabelecimento:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.meu_estabelecimento(%L::uuid) $$, (select casa_id from ids))));

-- 55. equipeDeConfianca: 403 sem_permissao (chamador nao e membro do estabelecimento)
select pg_temp.guarda('promete:equipeDeConfianca:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.equipe_de_confianca(%L::uuid) $$, (select casa_id from ids))));

-- 56. vagasAbertas: 403 sem_permissao (profissional suspenso tentando listar vagas)
select pg_temp.guarda('promete:vagasAbertas:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004',
    $$ select public.vagas_abertas() $$));

-- 57. retirarCandidatura: 403 sem_permissao (profissional suspenso tentando retirar candidatura)
select pg_temp.guarda('promete:retirarCandidatura:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004',
    $$ select public.retirar_candidatura('c0000000-0000-4000-8000-000000000099'::uuid) $$));

-- 58. minhasCandidaturas: 403 sem_permissao (profissional suspenso tentando listar candidaturas)
select pg_temp.guarda('promete:minhasCandidaturas:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004',
    $$ select public.minhas_candidaturas() $$));

-- 59. meusTurnos: 403 sem_permissao (chamador nao e membro do estabelecimento informado)
select pg_temp.guarda('promete:meusTurnos:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.meus_turnos(null, null, %L::uuid) $$, (select casa_id from ids))));

-- 60. painelEstabelecimento: 403 sem_permissao (chamador nao e membro do estabelecimento)
select pg_temp.guarda('promete:painelEstabelecimento:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.painel_estabelecimento(%L::uuid, '2027-01-11 00:00:00+00'::timestamptz, '2027-01-11 23:59:59+00'::timestamptz) $$,
    (select casa_id from ids))));

-- Auxiliar para 61: usuario autenticado sem linha em public.usuario
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'ee000000-0000-4000-8000-000000000097'::uuid,
        'authenticated', 'authenticated', 'sem-usuario@t.test', now(), now(), false, false)
on conflict do nothing;

-- 61. minhaConta: 404 nao_encontrado (usuario autenticado sem cadastro)
select pg_temp.guarda('promete:minhaConta:404',
  pg_temp.observado('ee000000-0000-4000-8000-000000000097',
    $$ select public.minha_conta() $$));

delete from auth.users where id = 'ee000000-0000-4000-8000-000000000097';

-- 62. meuPerfilProfissional: 404 nao_encontrado (contratante sem linha em public.profissional)
select pg_temp.guarda('promete:meuPerfilProfissional:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.meu_perfil_profissional() $$));

-- Auxiliar para 63: conta profissional criada, mas ainda sem perfil preenchido
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'ee000000-0000-4000-8000-000000000096'::uuid,
        'authenticated', 'authenticated', 'sem-perfil-prof@t.test', now(), now(), false, false)
on conflict do nothing;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values ('ee000000-0000-4000-8000-000000000096', 'profissional', 'Sem Perfil', '+5561944440096', 'sem-perfil-prof@t.test', '1995-01-01', '1.0', now(), 'ativa')
on conflict do nothing;

-- 63. atualizarPerfilProfissional: 404 nao_encontrado (conta profissional sem linha em public.profissional)
select pg_temp.guarda('promete:atualizarPerfilProfissional:404',
  pg_temp.observado('ee000000-0000-4000-8000-000000000096', format(
    $$ select public.atualizar_perfil_profissional(array[%L::uuid], null, null) $$, (select id from f))));

-- F2 atrás da chave perfil_rico (RN46, contrato 0.2.60): desligada, a F2 recusa com 403
-- recurso_desligado. Colhe a recusa e liga a chave antes de qualquer outra colheita da F2.
select pg_temp.guarda('promete:meuPerfilDetalhado:403', pg_temp.observado('cc000000-0000-4000-8000-000000000002', $$select public.meu_perfil_detalhado()$$));
update privado.recurso set ligado = true where chave = 'perfil_rico';

-- F2: perfil ainda não cadastrado.
select pg_temp.guarda('promete:definirServicos:404', pg_temp.observado('ee000000-0000-4000-8000-000000000096', $$select public.definir_servicos('[]')$$));
select pg_temp.guarda('promete:definirRegioesAtendidas:404', pg_temp.observado('ee000000-0000-4000-8000-000000000096', $$select public.definir_regioes_atendidas('{}',false)$$));
select pg_temp.guarda('promete:atualizarApresentacaoProfissional:404', pg_temp.observado('ee000000-0000-4000-8000-000000000096', $$select public.atualizar_apresentacao_profissional('{"apresentacao":"x"}')$$));
select pg_temp.guarda('promete:meuPerfilDetalhado:404', pg_temp.observado('ee000000-0000-4000-8000-000000000096', $$select public.meu_perfil_detalhado()$$));
delete from public.usuario where id = 'ee000000-0000-4000-8000-000000000096';
delete from auth.users where id = 'ee000000-0000-4000-8000-000000000096';

-- 64. criarConta: 409 conta_existente (tentativa de criar com perfil divergente de conta ja cadastrada)
select pg_temp.guarda('promete:criarConta:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.criar_conta('profissional', 'Outro Nome', '+5561944440009', '1980-05-05', '2026-09-22') $$));

-- 65. criarPerfilProfissional: 409 perfil_ja_existe (profissional que ja possui perfil cadastrado)
select pg_temp.guarda('promete:criarPerfilProfissional:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.criar_perfil_profissional(array[%L::uuid], null, null) $$, (select id from f))));

-- ── Lote 5: mais 15 pares críticos por risco (despacho, catálogo e validações de campos) ──

-- 66. pedirRevisaoDespacho: 409 contestacao_ja_aberta (segunda contestacao pelo mesmo autor cc...0002, que ja contestou na linha 174)
select pg_temp.guarda('promete:pedirRevisaoDespacho:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.pedir_revisao_despacho('Segunda tentativa de contestacao de despacho pelo mesmo autor.') $$));

-- 67. avaliar: 422 campo_obrigatorio (turno_id nulo)
select pg_temp.guarda('promete:avaliar:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.avaliar(null, true) $$));

-- 68. criteriosDeNotificacao: 403 sem_permissao (profissional suspenso tentando ler criterios)
select pg_temp.guarda('promete:criteriosDeNotificacao:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004',
    $$ select public.criterios_de_notificacao() $$));

-- Auxiliar para 69: conta profissional ativa sem linha em public.profissional
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'ee000000-0000-4000-8000-000000000095'::uuid,
        'authenticated', 'authenticated', 'sem-perfil-criterios@t.test', now(), now(), false, false)
on conflict do nothing;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values ('ee000000-0000-4000-8000-000000000095', 'profissional', 'Prof Sem Perfil Criterios', '+5561944440095', 'sem-perfil-criterios@t.test', '1995-01-01', '1.0', now(), 'ativa')
on conflict do nothing;

-- 69. criteriosDeNotificacao: 404 nao_encontrado (profissional sem linha em public.profissional)
select pg_temp.guarda('promete:criteriosDeNotificacao:404',
  pg_temp.observado('ee000000-0000-4000-8000-000000000095',
    $$ select public.criterios_de_notificacao() $$));

delete from public.usuario where id = 'ee000000-0000-4000-8000-000000000095';
delete from auth.users where id = 'ee000000-0000-4000-8000-000000000095';

-- 70. meusEstabelecimentos: 403 sem_permissao (conta suspensa tentando ler estabelecimentos)
select pg_temp.guarda('promete:meusEstabelecimentos:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004',
    $$ select public.meus_estabelecimentos() $$));

-- 71. registrarDispositivo: 422 campo_obrigatorio (token_fcm nulo)
select pg_temp.guarda('promete:registrarDispositivo:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.registrar_dispositivo(null, 'ios') $$));

-- 72. pedirRevisaoDespacho: 422 campo_obrigatorio (relato nulo)
select pg_temp.guarda('promete:pedirRevisaoDespacho:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.pedir_revisao_despacho(null) $$));

-- 73. cadastrarEstabelecimento: 422 perfil_incompativel (profissional tentando cadastrar casa)
select pg_temp.guarda('promete:cadastrarEstabelecimento:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.cadastrar_estabelecimento('Casa Incompativel', '29979036000140', 'food_service',
         'CLN 108', '{"latitude":-15.7905,"longitude":-47.8855}'::jsonb) $$));

-- 74. atualizarPerfilProfissional: 422 campo_obrigatorio (funcoes vazias)
select pg_temp.guarda('promete:atualizarPerfilProfissional:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.atualizar_perfil_profissional(array[]::uuid[], null, null) $$));

-- 75. publicarVaga: 422 campo_obrigatorio (funcao_id nula)
select pg_temp.guarda('promete:publicarVaga:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.publicar_vaga(%L::uuid, null, '2027-01-22 21:00:00+00'::timestamptz, '2027-01-23 03:00:00+00'::timestamptz,
         'CLN 108', '{"latitude":-15.7905,"longitude":-47.8855}'::jsonb, 16000::bigint, 1, true, false, false,
         'Gerente', 'urgencia'::public.modo_preenchimento, gen_random_uuid()) $$,
    (select casa_id from ids))));

-- 76. escolherCandidato: 422 campo_obrigatorio (candidatura_id nula)
select pg_temp.guarda('promete:escolherCandidato:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.escolher_candidato(null) $$));

-- 77. cancelarVaga: 422 campo_obrigatorio (vaga_id nula)
select pg_temp.guarda('promete:cancelarVaga:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.cancelar_vaga(null, 'motivo de teste') $$));

-- 78. cancelarPosicao: 422 campo_obrigatorio (posicao_id nula)
select pg_temp.guarda('promete:cancelarPosicao:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.cancelar_posicao(null, 'motivo de teste') $$));

-- 79. fazerCheckin: 422 campo_obrigatorio (turno_id nulo)
select pg_temp.guarda('promete:fazerCheckin:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.fazer_checkin(null, 40, '2027-01-18 20:05:00+00'::timestamptz) $$));

-- 80. fazerCheckout: 422 campo_obrigatorio (turno_id nulo)
select pg_temp.guarda('promete:fazerCheckout:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.fazer_checkout(null, 40, '2027-01-19 02:00:00+00'::timestamptz) $$));

-- ── Lote 6: mais 15 pares críticos por risco (blindagem do perímetro de autenticação: 401 nao_autenticado) ──

-- 81. publicarVaga: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:publicarVaga:401',
  pg_temp.observado(null,
    $$ select public.publicar_vaga('00000000-0000-0000-0000-000000000001'::uuid, '00000000-0000-0000-0000-000000000002'::uuid,
         '2027-01-18 21:00:00+00'::timestamptz, '2027-01-19 03:00:00+00'::timestamptz,
         'CLN 108', '{"latitude":-15.7905,"longitude":-47.8855}'::jsonb, 16000::bigint, 1, true, false, false,
         'Gerente', 'urgencia'::public.modo_preenchimento, gen_random_uuid(), 'camisa preta', true, 'porta dos fundos', 180) $$));

-- 82. cancelarVaga: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:cancelarVaga:401',
  pg_temp.observado(null,
    $$ select public.cancelar_vaga(null, 'motivo de teste') $$));

-- 83. cancelarPosicao: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:cancelarPosicao:401',
  pg_temp.observado(null,
    $$ select public.cancelar_posicao(null, 'motivo de teste') $$));

-- 84. candidatar: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:candidatar:401',
  pg_temp.observado(null,
    $$ select public.candidatar(null) $$));

-- 85. retirarCandidatura: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:retirarCandidatura:401',
  pg_temp.observado(null,
    $$ select public.retirar_candidatura(null) $$));

-- 86. fazerCheckin: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:fazerCheckin:401',
  pg_temp.observado(null,
    $$ select public.fazer_checkin(null, 40, now()) $$));

-- 87. fazerCheckout: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:fazerCheckout:401',
  pg_temp.observado(null,
    $$ select public.fazer_checkout(null, 40, now()) $$));

-- 88. confirmarCheckinManual: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:confirmarCheckinManual:401',
  pg_temp.observado(null,
    $$ select public.confirmar_checkin_manual(null) $$));

-- 89. reabrirPorAtraso: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:reabrirPorAtraso:401',
  pg_temp.observado(null,
    $$ select public.reabrir_por_atraso(null) $$));

-- 90. avaliar: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:avaliar:401',
  pg_temp.observado(null,
    $$ select public.avaliar(null, true) $$));

-- 91. bloquear: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:bloquear:401',
  pg_temp.observado(null,
    $$ select public.bloquear('profissional', null) $$));

-- 92. denunciar: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:denunciar:401',
  pg_temp.observado(null,
    $$ select public.denunciar('profissional', null, 'outro', 'relato de teste com tamanho suficiente', gen_random_uuid()) $$));

-- 93. contestarSuspensao: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:contestarSuspensao:401',
  pg_temp.observado(null,
    $$ select public.contestar_suspensao('relato de teste com tamanho suficiente') $$));

-- 94. pedirRevisaoDespacho: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:pedirRevisaoDespacho:401',
  pg_temp.observado(null,
    $$ select public.pedir_revisao_despacho('relato de teste com tamanho suficiente') $$));

-- 95. candidatosDaVaga: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:candidatosDaVaga:401',
  pg_temp.observado(null,
    $$ select public.candidatos_da_vaga(null) $$));

-- ── Lote 7: mais 15 pares críticos por risco (regras de negócio: 422 validações e perfis) ──

-- 96. painelEstabelecimento: 422 campo_obrigatorio (de nulo)
select pg_temp.guarda('promete:painelEstabelecimento:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.painel_estabelecimento(%L::uuid, null, '2027-01-11 23:59:59+00'::timestamptz) $$,
    (select casa_id from ids))));

-- 97. candidatar: 422 campo_obrigatorio (vaga_id nula)
select pg_temp.guarda('promete:candidatar:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.candidatar(null) $$));

-- 98. retirarCandidatura: 422 campo_obrigatorio (candidatura_id nula)
select pg_temp.guarda('promete:retirarCandidatura:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.retirar_candidatura(null) $$));

-- 99. reabrirPorAtraso: 422 campo_obrigatorio (posicao_id nula)
select pg_temp.guarda('promete:reabrirPorAtraso:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.reabrir_por_atraso(null) $$));

-- 100. confirmarCheckinManual: 422 campo_obrigatorio (turno_id nulo)
select pg_temp.guarda('promete:confirmarCheckinManual:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.confirmar_checkin_manual(null) $$));

-- 101. contatoDoTurno: 422 campo_obrigatorio (turno_id nulo)
select pg_temp.guarda('promete:contatoDoTurno:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.contato_do_turno(null) $$));

-- 102. detalheVaga: 422 campo_obrigatorio (vaga_id nula)
select pg_temp.guarda('promete:detalheVaga:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.detalhe_vaga(null) $$));

-- 103. candidatosDaVaga: 422 campo_obrigatorio (vaga_id nula)
select pg_temp.guarda('promete:candidatosDaVaga:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.candidatos_da_vaga(null) $$));

-- 104. republicarVaga: 422 campo_obrigatorio (vaga_origem_id nula)
select pg_temp.guarda('promete:republicarVaga:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.republicar_vaga(null, '2027-02-15 21:00:00+00'::timestamptz, '2027-02-16 03:00:00+00'::timestamptz, gen_random_uuid()) $$));

-- 105. avisarACaminho: 422 campo_obrigatorio (turno_id nulo)
select pg_temp.guarda('promete:avisarACaminho:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.avisar_a_caminho(null) $$));

-- 106. configuracaoDoApp: 422 campo_obrigatorio (plataforma nula)
select pg_temp.guarda('promete:configuracaoDoApp:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.configuracao_do_app(null) $$));

-- 107. criarPerfilProfissional: 422 perfil_incompativel (contratante tentando criar perfil profissional)
select pg_temp.guarda('promete:criarPerfilProfissional:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.criar_perfil_profissional(array[%L::uuid], null, null) $$, (select id from f))));

-- 108. vagasAbertas: 422 perfil_incompativel (contratante tentando consultar vagas abertas)
select pg_temp.guarda('promete:vagasAbertas:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.vagas_abertas() $$));

-- 109. minhasCandidaturas: 422 perfil_incompativel (contratante tentando consultar candidaturas)
select pg_temp.guarda('promete:minhasCandidaturas:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.minhas_candidaturas() $$));

-- 110. meusEstabelecimentos: 422 perfil_incompativel (profissional tentando consultar estabelecimentos)
select pg_temp.guarda('promete:meusEstabelecimentos:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.meus_estabelecimentos() $$));

-- ── Lote 8: mais 15 pares críticos por risco (422 de negócio, 403 e perímetro 401) ──

-- Auxiliar para 111: usuario autenticado sem linha em public.usuario
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'ee000000-0000-4000-8000-000000000094'::uuid,
        'authenticated', 'authenticated', 'sem-usuario-criar@t.test', now(), now(), false, false)
on conflict do nothing;

-- 111. criarConta: 422 campo_obrigatorio (nome nulo)
select pg_temp.guarda('promete:criarConta:422',
  pg_temp.observado('ee000000-0000-4000-8000-000000000094',
    $$ select public.criar_conta('profissional', null, '+5561999990001', '1990-01-01', '1.0') $$));

delete from auth.users where id = 'ee000000-0000-4000-8000-000000000094';

-- 112. registrarEvento: 422 campo_obrigatorio (evento nulo)
select pg_temp.guarda('promete:registrarEvento:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.registrar_evento(null) $$));

-- 113. escolherCandidato: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:escolherCandidato:401',
  pg_temp.observado(null,
    $$ select public.escolher_candidato('c0000000-0000-4000-8000-000000000001'::uuid) $$));

-- 114. minhasCandidaturas: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:minhasCandidaturas:401',
  pg_temp.observado(null,
    $$ select public.minhas_candidaturas() $$));

-- 115. vagasAbertas: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:vagasAbertas:401',
  pg_temp.observado(null,
    $$ select public.vagas_abertas() $$));

-- 116. detalheVaga: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:detalheVaga:401',
  pg_temp.observado(null,
    $$ select public.detalhe_vaga('c0000000-0000-4000-8000-000000000001'::uuid) $$));

-- 117. republicarVaga: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:republicarVaga:401',
  pg_temp.observado(null,
    $$ select public.republicar_vaga('c0000000-0000-4000-8000-000000000001'::uuid, now(), now(), gen_random_uuid()) $$));

-- 118. meusTurnos: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:meusTurnos:401',
  pg_temp.observado(null,
    $$ select public.meus_turnos() $$));

-- 119. contatoDoTurno: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:contatoDoTurno:401',
  pg_temp.observado(null,
    $$ select public.contato_do_turno('c0000000-0000-4000-8000-000000000001'::uuid) $$));

-- 120. avisarACaminho: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:avisarACaminho:401',
  pg_temp.observado(null,
    $$ select public.avisar_a_caminho('c0000000-0000-4000-8000-000000000001'::uuid) $$));

-- 121. painelEstabelecimento: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:painelEstabelecimento:401',
  pg_temp.observado(null,
    $$ select public.painel_estabelecimento('c0000000-0000-4000-8000-000000000001'::uuid, now(), now()) $$));

-- 122. meusEstabelecimentos: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:meusEstabelecimentos:401',
  pg_temp.observado(null,
    $$ select public.meus_estabelecimentos() $$));

-- 123. meuEstabelecimento: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:meuEstabelecimento:401',
  pg_temp.observado(null,
    $$ select public.meu_estabelecimento('c0000000-0000-4000-8000-000000000001'::uuid) $$));

-- 124. equipeDeConfianca: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:equipeDeConfianca:401',
  pg_temp.observado(null,
    $$ select public.equipe_de_confianca('c0000000-0000-4000-8000-000000000001'::uuid) $$));

-- 125. situacaoDaConta: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:situacaoDaConta:401',
  pg_temp.observado(null,
    $$ select public.situacao_da_conta() $$));

-- ── Lote 9: 15 novos pares críticos vigiados do contrato (regras 422 e perímetro 401) ──

-- 126. criteriosDeNotificacao: 422 perfil_incompativel (chamador contratante)
select pg_temp.guarda('promete:criteriosDeNotificacao:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.criterios_de_notificacao() $$));

-- 127. incluirNaEquipe: 422 perfil_incompativel (chamador profissional)
select pg_temp.guarda('promete:incluirNaEquipe:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    format($$ select public.incluir_na_equipe(%L::uuid, 'cc000000-0000-4000-8000-000000000002'::uuid) $$, (select casa_id from ids))));

-- 128. removerDaEquipe: 422 perfil_incompativel (chamador profissional)
select pg_temp.guarda('promete:removerDaEquipe:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    format($$ select public.remover_da_equipe(%L::uuid, 'cc000000-0000-4000-8000-000000000002'::uuid) $$, (select casa_id from ids))));

-- 129. minhaConta: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:minhaConta:401',
  pg_temp.observado(null,
    $$ select public.minha_conta() $$));

-- 130. meuPerfilProfissional: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:meuPerfilProfissional:401',
  pg_temp.observado(null,
    $$ select public.meu_perfil_profissional() $$));

-- 131. atualizarPerfilProfissional: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:atualizarPerfilProfissional:401',
  pg_temp.observado(null,
    $$ select public.atualizar_perfil_profissional(ponto_base => '{"latitude":-15.7901,"longitude":-47.8851}'::jsonb) $$));

-- 132. criarPerfilProfissional: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:criarPerfilProfissional:401',
  pg_temp.observado(null,
    format($$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select id from f))));

-- 133. cadastrarEstabelecimento: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:cadastrarEstabelecimento:401',
  pg_temp.observado(null,
    $$ select public.cadastrar_estabelecimento('Casa Sem Token','29979036000140','food_service','CLN 108','{"latitude":-15.7905,"longitude":-47.8855}') $$));

-- 134. criteriosDeNotificacao: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:criteriosDeNotificacao:401',
  pg_temp.observado(null,
    $$ select public.criterios_de_notificacao() $$));

-- 135. incluirNaEquipe: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:incluirNaEquipe:401',
  pg_temp.observado(null,
    format($$ select public.incluir_na_equipe(%L::uuid, 'cc000000-0000-4000-8000-000000000002'::uuid) $$, (select casa_id from ids))));

-- 136. removerDaEquipe: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:removerDaEquipe:401',
  pg_temp.observado(null,
    format($$ select public.remover_da_equipe(%L::uuid, 'cc000000-0000-4000-8000-000000000002'::uuid) $$, (select casa_id from ids))));

-- 137. perfilPublico: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:perfilPublico:401',
  pg_temp.observado(null,
    $$ select public.perfil_publico('cc000000-0000-4000-8000-000000000002'::uuid) $$));

-- 138. registrarDispositivo: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:registrarDispositivo:401',
  pg_temp.observado(null,
    $$ select public.registrar_dispositivo('fcm_token_teste_harness_contrato_anon_1234', 'ios') $$));

-- 139. removerDispositivo: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:removerDispositivo:401',
  pg_temp.observado(null,
    $$ select public.remover_dispositivo('fcm_token_teste_harness_contrato_anon_1234') $$));

-- 140. registrarEvento: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:registrarEvento:401',
  pg_temp.observado(null,
    $$ select public.registrar_evento('app_aberto') $$));

-- ── Lote 10: última recusa crítica vigiada de RPC no banco (encerramento do perímetro 401) ──

-- 141. criarConta: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:criarConta:401',
  pg_temp.observado(null,
    $$ select public.criar_conta('profissional','Teste Sem Token','+5561999990001','1990-01-01','1.0') $$));

-- ── Suporte por e-mail a partir do turno (contrato 0.2.40): 5 recusas vigiadas ──

-- 142. abrirSuporte: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:abrirSuporte:401',
  pg_temp.observado(null, format(
    $$ select public.abrir_suporte(%L::uuid, 'endereco', gen_random_uuid()) $$,
    ((select r from cand)->>'turno_id')::uuid)));

-- 143. abrirSuporte: 403 sem_permissao (conta suspensa)
insert into auth.users (id, email) values ('ee000000-0000-4000-8000-000000000093', 'suspenso_suporte@frila.test') on conflict do nothing;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values ('ee000000-0000-4000-8000-000000000093', 'profissional', 'Suspenso Suporte', '+5561999990093', 'suspenso_suporte@frila.test', '1990-01-01', '1.0', now(), 'suspensa')
on conflict (id) do update set estado = 'suspensa';
select pg_temp.guarda('promete:abrirSuporte:403',
  pg_temp.observado('ee000000-0000-4000-8000-000000000093', format(
    $$ select public.abrir_suporte(%L::uuid, 'endereco', gen_random_uuid()) $$,
    ((select r from cand)->>'turno_id')::uuid)));

-- 144. abrirSuporte: 404 nao_encontrado (turno inexistente)
select pg_temp.guarda('promete:abrirSuporte:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.abrir_suporte('c0000000-0000-4000-8000-000000000099'::uuid, 'endereco', gen_random_uuid()) $$));

-- 145. abrirSuporte: 422 campo_obrigatorio (chave nula)
select pg_temp.guarda('promete:abrirSuporte:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.abrir_suporte(%L::uuid, 'endereco', null::uuid) $$,
    ((select r from cand)->>'turno_id')::uuid)));

-- 146. abrirSuporte: 429 limite_excedido (teto de 5 chamados por dia atingido)
-- Semeia 5 chamados anteriores para a conta Pê (...0002) no dia corrente
set local frila.agora = '2027-02-01 21:25:00+00';
insert into public.ocorrencia (tipo, origem, turno_id, autor_id, motivo, chave_cliente, criada_em)
select 'suporte', 'app', ((select r from cand)->>'turno_id')::uuid, 'cc000000-0000-4000-8000-000000000002'::uuid, 'outro', gen_random_uuid(), privado.agora()
  from generate_series(1, 5);

select pg_temp.guarda('promete:abrirSuporte:429',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002', format(
    $$ select public.abrir_suporte(%L::uuid, 'endereco', gen_random_uuid()) $$,
    ((select r from cand)->>'turno_id')::uuid)));


-- ── Republicar posições restantes do modo seleção (contrato 0.2.41): 4 recusas vigiadas ──

-- 147. republicarPosicoesRestantes: 401 nao_autenticado (chamador sem sessão / anonimo)
select pg_temp.guarda('promete:republicarPosicoesRestantes:401',
  pg_temp.observado(null, format(
    $$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$,
    ((select r from vaga_sel_rep)->>'vaga_id')::uuid)));

-- 148. republicarPosicoesRestantes: 403 sem_permissao (chamador é contratante mas não é membro do estabelecimento da vaga)
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'ee000000-0000-4000-8000-000000000088'::uuid,
        'authenticated', 'authenticated', 'aux-rep-403@t.test', now(), now(), false, false)
on conflict do nothing;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values ('ee000000-0000-4000-8000-000000000088', 'contratante', 'Aux Rep 403', '+5561999990088', 'aux-rep-403@t.test', '1990-01-01', '1.0', now(), 'ativa')
on conflict (id) do update set estado = 'ativa';

select pg_temp.guarda('promete:republicarPosicoesRestantes:403',
  pg_temp.observado('ee000000-0000-4000-8000-000000000088', format(
    $$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$,
    ((select r from vaga_sel_rep)->>'vaga_id')::uuid)));

delete from public.usuario where id = 'ee000000-0000-4000-8000-000000000088';
delete from auth.users where id = 'ee000000-0000-4000-8000-000000000088';

-- 149. republicarPosicoesRestantes: 404 nao_encontrado (origem inexistente)
select pg_temp.guarda('promete:republicarPosicoesRestantes:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.republicar_posicoes_restantes('c0000000-0000-4000-8000-000000000099'::uuid, gen_random_uuid()) $$));

-- 150. republicarPosicoesRestantes: 422 republicacao_indisponivel (origem de modo urgência, recusa com nao_e_selecao)
select pg_temp.guarda('promete:republicarPosicoesRestantes:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$,
    ((select r from vaga1)->>'vaga_id')::uuid)));


-- ── As Edge Functions ─────────────────────────────────────────────────────────
--
-- Cartão `oCv0WPNY`. Até 01/10 este arquivo colhia só as RPCs, e as Edge Functions não
-- eram medidas por portão nenhum: o `contrato-acompanha-o-codigo.sh` só dispara em função
-- de `public`, e quem monta a exportação é `privado.meus_dados`.
--
-- O corpo que a Edge Function devolve é, sem remodelar, o jsonb que a função de `privado`
-- montou — as duas fazem `return resposta(200, dados)` com o que veio do banco. Então
-- colher aqui mede exatamente o que o cliente recebe, pelo mesmo raciocínio que vale para
-- as RPCs e sem precisar subir `functions serve`.
--
-- As que ficam de fora estão em `FORA_DO_ALCANCE`, no `contrato_responde.py`, cada uma com
-- o motivo. A lista vive **só lá**, e este comentário não a repete de propósito: duas
-- cópias de uma lista divergem na primeira mudança, e a primeira versão deste comentário
-- citava dois exemplos dela — o bastante para um leitor concluir que eram a lista inteira.
-- Aconteceu em 01/10, na revisão deste PR.

-- Semeia dados nas coleções do titular Pê (...0002) para que nenhuma coleção seja avaliada vazia:
-- 1. Despacho recebido para a vaga 1
insert into public.despacho (vaga_id, profissional_id, rodada, reaberta, criado_em)
select ((select r from vaga1)->>'vaga_id')::uuid,
       p.id,
       1,
       false,
       '2027-01-18 20:00:00+00'::timestamptz
  from public.profissional p
 where p.usuario_id = 'cc000000-0000-4000-8000-000000000002';

-- 2. Avaliação dada pelo profissional para a casa no turno 1
select pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
  $$ select public.avaliar(%L::uuid, true) $$, ((select r from cand)->>'turno_id')::uuid));

-- 3. Bloqueio registrado pelo profissional contra estabelecimento
select pg_temp.como('cc000000-0000-4000-8000-000000000002', format(
  $$ select public.bloquear('estabelecimento', %L::uuid) $$,
  (select casa_id from ids)));

-- 4. Associação ativa em equipe de confiança
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select (select casa_id from ids), p.id
  from public.profissional p
 where p.usuario_id = 'cc000000-0000-4000-8000-000000000002'
on conflict do nothing;

-- 5. Notificação entregue (com urgente=true no banco para provar que MeusDados o omite)
insert into public.notificacao (usuario_id, tipo, referencia_id, payload, urgente, enviada_em, entregue_em)
values (
  'cc000000-0000-4000-8000-000000000002',
  'lembrete_24h'::public.tipo_notificacao,
  'c0000000-0000-4000-8000-000000000001'::uuid,
  '{"turno_id": "c0000000-0000-4000-8000-000000000001"}'::jsonb,
  true,
  '2027-01-20 10:00:00+00'::timestamptz,
  '2027-01-20 10:05:00+00'::timestamptz
);

-- Semeia mídia para exercitar a coleção midias em MeusDados (0.2.59)
insert into privado.midia (dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
values ('cc000000-0000-4000-8000-000000000002', 'profissional', 'foto_perfil', 'perfil/cc02.jpg', 'image/jpeg', 1024, 'aprovada');

-- `eventos_app` (LGPD nUpPFCpM) já consta em MeusDados desde o contrato 0.2.45 (frila-docs#96).
select pg_temp.guarda('exportarMeusDados',
  privado.meus_dados('cc000000-0000-4000-8000-000000000002'));

-- Amostra também para a conta contratante (Casa), exercitando estabelecimentos vinculados
select pg_temp.guarda('exportarMeusDados',
  privado.meus_dados('cc000000-0000-4000-8000-000000000001'));

-- ── Verificação de identidade (RN14, contrato 0.2.50, cartão 86CC7PW3) ────────
--
-- As três operações e as dez recusas que o contrato promete. A ordem aqui é regra, e não
-- arrumação: o 422 de `confirmar` precisa de uma conta que pediu o upload e não enviou
-- nada, e o 409 de `solicitar` precisa de uma que já está `em_analise`. Medir os dois na
-- mesma conta exigiria desfazer estado no meio, que é como um harness passa a medir a
-- própria ordem em vez da regra.
--
-- A assinatura da URL de upload lê o segredo do Vault; sem ele a função recusa por
-- desenho (`segredo_ausente`), e a colheita mediria a falta do segredo, não a operação.
select vault.create_secret('jwt-sintetico-da-colheita-com-mais-de-32-caracteres', 'storage_jwt_secret');

-- Dois profissionais a mais: um para o 409 de `solicitar` (que termina em `em_analise`) e
-- outro para o 422 e o 409 de `confirmar`, que precisam de estados diferentes.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values ('ee000000-0000-4000-8000-000000000097', 'profissional', 'Prof Verificacao', '+5561999999997', 'verif97@frila.test', '1995-01-01', '1.0', now(), 'ativa'),
       ('ee000000-0000-4000-8000-000000000096', 'profissional', 'Prof Sem Envio', '+5561999999996', 'verif96@frila.test', '1995-01-01', '1.0', now(), 'ativa')
on conflict do nothing;

insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'ee000000-0000-4000-8000-000000000097', 'authenticated', 'authenticated', 'verif97@frila.test', privado.agora(), privado.agora(), false, false),
       ('00000000-0000-0000-0000-000000000000', 'ee000000-0000-4000-8000-000000000096', 'authenticated', 'authenticated', 'verif96@frila.test', privado.agora(), privado.agora(), false, false)
on conflict do nothing;

-- 1. minhaIdentidadeStatus: resposta feliz, no estado inicial de toda conta
select pg_temp.guarda('minhaIdentidadeStatus', pg_temp.como('ee000000-0000-4000-8000-000000000097',
  $$ select public.minha_identidade_status() $$));

-- 2. minhaIdentidadeStatus: 403 sem_permissao (contratante não tem verificação de identidade)
select pg_temp.guarda('promete:minhaIdentidadeStatus:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.minha_identidade_status() $$));

-- 3. solicitarUploadVerificacao: 422 campo_invalido (documento fora de rg e cnh)
select pg_temp.guarda('promete:solicitarUploadVerificacao:422',
  pg_temp.observado('ee000000-0000-4000-8000-000000000097',
    $$ select public.solicitar_upload_verificacao('passaporte') $$));

-- 4. solicitarUploadVerificacao: 403 sem_permissao (contratante)
select pg_temp.guarda('promete:solicitarUploadVerificacao:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.solicitar_upload_verificacao('rg') $$));

-- 5. solicitarUploadVerificacao: resposta feliz, três URLs assinadas de 2 h
select pg_temp.guarda('solicitarUploadVerificacao', pg_temp.como('ee000000-0000-4000-8000-000000000097',
  $$ select public.solicitar_upload_verificacao('rg') $$));

-- 6. confirmarEnvioVerificacao: 422 evidencia_incompleta (pediu e não enviou nada)
select pg_temp.guarda('promete:confirmarEnvioVerificacao:422',
  pg_temp.observado('ee000000-0000-4000-8000-000000000097',
    $$ select public.confirmar_envio_verificacao() $$));

-- 7. confirmarEnvioVerificacao: 409 verificacao_indisponivel (nunca pediu o upload)
select pg_temp.guarda('promete:confirmarEnvioVerificacao:409',
  pg_temp.observado('ee000000-0000-4000-8000-000000000096',
    $$ select public.confirmar_envio_verificacao() $$));

-- 8. confirmarEnvioVerificacao: 403 sem_permissao (contratante)
select pg_temp.guarda('promete:confirmarEnvioVerificacao:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.confirmar_envio_verificacao() $$));

-- As mídias chegam ao bucket. `storage.objects` é o índice do Storage, e é nele que a RPC
-- confere; o byte não existe aqui, e não precisa existir para medir a resposta.
insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select 'documentos-identidade', caminho, v.usuario_id, v.usuario_id::text, '{"size": 1024, "mimetype": "image/jpeg"}'::jsonb
  from privado.verificacao_identidade v
  cross join lateral (values (v.storage_path_frente), (v.storage_path_verso), (v.storage_path_selfie)) as partes(caminho)
 where v.usuario_id = 'ee000000-0000-4000-8000-000000000097'
on conflict do nothing;

-- 9. confirmarEnvioVerificacao: resposta feliz, a verificação vai para em_analise
select pg_temp.guarda('confirmarEnvioVerificacao', pg_temp.como('ee000000-0000-4000-8000-000000000097',
  $$ select public.confirmar_envio_verificacao() $$));

-- 10. solicitarUploadVerificacao: 409 verificacao_indisponivel (análise em curso)
select pg_temp.guarda('promete:solicitarUploadVerificacao:409',
  pg_temp.observado('ee000000-0000-4000-8000-000000000097',
    $$ select public.solicitar_upload_verificacao('rg') $$));

-- ── Listar e desfazer bloqueios (RF26, UC17, contrato 0.2.51, cartão Y18NMyPo) ──
--
-- A ordem aqui segue a do arquivo: o que precisa de conta ativa vem antes do
-- `excluir_conta` do fim, e os dois 401 ficam depois dele, porque é lá que existe conta
-- anonimizada para medir.

-- A listagem precisa de item real: coleção declarada e nunca exercitada reprova o portão,
-- e com razão — um array vazio não prova que o corpo de `ItemBloqueio` casa com o schema.
select pg_temp.guarda('bloquear', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.bloquear('profissional', %L::uuid) $$,
  (select p.id from public.profissional p where p.usuario_id = 'cc000000-0000-4000-8000-000000000003'))));

-- Resposta feliz da listagem, agora com um item
select pg_temp.guarda('listarBloqueios', pg_temp.como('cc000000-0000-4000-8000-000000000001',
  $$ select public.listar_bloqueios() $$));

-- Resposta feliz do desbloqueio: idempotente, devolve 200 mesmo sem bloqueio anterior
select pg_temp.guarda('desbloquear', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.desbloquear('profissional', %L::uuid) $$,
  (select p.id from public.profissional p where p.usuario_id = 'cc000000-0000-4000-8000-000000000003'))));

-- desbloquear: 404 nao_encontrado (perfil de profissional que não existe)
select pg_temp.guarda('promete:desbloquear:404',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001',
    $$ select public.desbloquear('profissional', 'c0000000-0000-4000-8000-0000000000fe'::uuid) $$));

-- desbloquear: 422 campo_invalido (o perfil decide o alvo; profissional não desbloqueia profissional)
select pg_temp.guarda('promete:desbloquear:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000003', format(
    $$ select public.desbloquear('profissional', %L::uuid) $$,
    (select p.id from public.profissional p where p.usuario_id = 'cc000000-0000-4000-8000-000000000003'))));

-- 403 sem_permissao com conta suspensa, nas duas operações (RN13 exige conta ativa)
select pg_temp.guarda('promete:listarBloqueios:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004',
    $$ select public.listar_bloqueios() $$));

select pg_temp.guarda('promete:desbloquear:403',
  pg_temp.observado('cc000000-0000-4000-8000-000000000004', format(
    $$ select public.desbloquear('profissional', %L::uuid) $$,
    (select p.id from public.profissional p where p.usuario_id = 'cc000000-0000-4000-8000-000000000003'))));

-- Resposta feliz de resolverServico (contrato 0.2.52, fatia F1)
select pg_temp.guarda('resolverServico', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.resolver_servico('diarista') $$));

-- resolverServico: 422 campo_invalido (termo com menos de 2 caracteres)
select pg_temp.guarda('promete:resolverServico:422',
  pg_temp.observado('cc000000-0000-4000-8000-000000000002',
    $$ select public.resolver_servico('a') $$));

-- F2: respostas com serviço, especialidade e região reais.
insert into public.profissional_funcao (profissional_id,funcao_id)
 select p.id,f.id from public.profissional p cross join public.funcao f
 where p.usuario_id='cc000000-0000-4000-8000-000000000002' and f.nome='faxina residencial' on conflict do nothing;
select pg_temp.guarda('definirServicos', pg_temp.como('cc000000-0000-4000-8000-000000000002',format(
 $$select public.definir_servicos(%L::jsonb)$$, (select jsonb_build_array(jsonb_build_object('funcao_id',f.id,
 'unidade','diaria','valor_centavos',15000,'horas_incluidas',8,'especialidade_ids',jsonb_build_array(e.id)))
 from public.funcao f join public.especialidade e on e.funcao_id=f.id where f.nome='faxina residencial' limit 1))));
select pg_temp.guarda('definirRegioesAtendidas', pg_temp.como('cc000000-0000-4000-8000-000000000002',
 $$select public.definir_regioes_atendidas(array[1,2],false)$$));
select pg_temp.guarda('promete:definirServicos:401',pg_temp.observado(null,$$select public.definir_servicos('[]')$$));
select pg_temp.guarda('promete:definirServicos:403',pg_temp.observado('cc000000-0000-4000-8000-000000000004',$$select public.definir_servicos('[]')$$));
select pg_temp.guarda('promete:definirServicos:422',pg_temp.observado('cc000000-0000-4000-8000-000000000002',$$select public.definir_servicos('{}')$$));
select pg_temp.guarda('promete:definirRegioesAtendidas:401',pg_temp.observado(null,$$select public.definir_regioes_atendidas('{}',false)$$));
select pg_temp.guarda('promete:definirRegioesAtendidas:403',pg_temp.observado('cc000000-0000-4000-8000-000000000004',$$select public.definir_regioes_atendidas('{}',false)$$));
select pg_temp.guarda('promete:definirRegioesAtendidas:422',pg_temp.observado('cc000000-0000-4000-8000-000000000002',$$select public.definir_regioes_atendidas(array[999],false)$$));
select pg_temp.guarda('atualizarApresentacaoProfissional', pg_temp.como('cc000000-0000-4000-8000-000000000002',
 $$select public.atualizar_apresentacao_profissional('{"apresentacao":"Faxineira há oito anos","onde_trabalhei":"Condomínio Sol 2019-2023","experiencia_faixa":"de_5_a_10_anos","cursos":["Limpeza pós-obra"],"idiomas":["ingles"]}')$$));
select pg_temp.guarda('promete:atualizarApresentacaoProfissional:401',pg_temp.observado(null,$$select public.atualizar_apresentacao_profissional('{"apresentacao":"x"}')$$));
select pg_temp.guarda('promete:atualizarApresentacaoProfissional:403',pg_temp.observado('cc000000-0000-4000-8000-000000000004',$$select public.atualizar_apresentacao_profissional('{"apresentacao":"x"}')$$));
select pg_temp.guarda('promete:atualizarApresentacaoProfissional:422',pg_temp.observado('cc000000-0000-4000-8000-000000000002',$$select public.atualizar_apresentacao_profissional('{"apresentacao":"ligue 61 98888-7777"}')$$));
select pg_temp.guarda('meuPerfilDetalhado', pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$select public.meu_perfil_detalhado()$$));
select pg_temp.guarda('promete:meuPerfilDetalhado:401',pg_temp.observado(null,$$select public.meu_perfil_detalhado()$$));
select pg_temp.guarda('promete:meuPerfilDetalhado:422',pg_temp.observado('cc000000-0000-4000-8000-000000000001',$$select public.meu_perfil_detalhado()$$));

-- B4a: URLs e projeções de mídia, incluindo cada recusa declarada no contrato.
create temp table midia_colheita as
select 'ee000000-0000-4000-8000-000000000097'::uuid conta;
update privado.configuracao_app set foto_de_perfil=false;
select pg_temp.guarda('promete:solicitarUploadMidia:403', pg_temp.observado(conta,
  $$select public.solicitar_upload_midia('foto_perfil','image/jpeg',1024)$$)) from midia_colheita;
select pg_temp.guarda('promete:confirmarUploadMidia:403', pg_temp.observado(conta,
  $$select public.confirmar_upload_midia('80200000-0000-4000-8000-000000000099')$$)) from midia_colheita;
update privado.configuracao_app set foto_de_perfil=true;
create temp table midia_upload as select pg_temp.como(conta,
  $$select public.solicitar_upload_midia('foto_perfil','image/jpeg',1024)$$) resposta from midia_colheita;
select pg_temp.guarda('solicitarUploadMidia', resposta) from midia_upload;
select pg_temp.guarda('promete:solicitarUploadMidia:422', pg_temp.observado(conta,
  $$select public.solicitar_upload_midia('foto_perfil','image/png',1024)$$)) from midia_colheita;
select pg_temp.guarda('promete:confirmarUploadMidia:422', pg_temp.observado(conta,
  format('select public.confirmar_upload_midia(%L)', resposta->>'midia_id'))) from midia_colheita cross join midia_upload;
insert into storage.objects(bucket_id,name) select 'midia-perfil', storage_path from privado.midia
  where id=(select (resposta->>'midia_id')::uuid from midia_upload);
select pg_temp.guarda('confirmarUploadMidia', pg_temp.como(conta,
  format('select public.confirmar_upload_midia(%L)', resposta->>'midia_id'))) from midia_colheita cross join midia_upload;
select pg_temp.guarda('minhasMidias', pg_temp.como(conta, $$select public.minhas_midias()$$)) from midia_colheita;
select pg_temp.guarda('removerMidia', pg_temp.como(conta,
  format('select public.remover_midia(%L)', resposta->>'midia_id'))) from midia_colheita cross join midia_upload;
-- Nova análise de foto recusada: 200 sobre recusada sintética; 409 sobre a removida acima.
insert into privado.midia(id,dono_usuario_id,dono_tipo,tipo,storage_path,mime,bytes,estado,motivo_recusa,atualizado_em)
select 'ee000000-0000-4000-8000-0000000000a9', conta, 'profissional', 'foto_perfil',
       'perfil/ee000000-0000-4000-8000-0000000000a9.jpg', 'image/jpeg', 1024, 'recusada',
       'texto_ou_dado_pessoal', privado.agora() from midia_colheita;
select pg_temp.guarda('pedirNovaAnaliseMidia', pg_temp.como(conta,
  $$select public.pedir_nova_analise_midia('ee000000-0000-4000-8000-0000000000a9')$$)) from midia_colheita;
select pg_temp.guarda('promete:pedirNovaAnaliseMidia:409', pg_temp.observado(conta,
  format('select public.pedir_nova_analise_midia(%L)', resposta->>'midia_id'))) from midia_colheita cross join midia_upload;
select pg_temp.guarda('promete:' || op || ':401', pg_temp.observado(null, sql)) from (values
  ('solicitarUploadMidia', $$select public.solicitar_upload_midia('foto_perfil','image/jpeg',1)$$),
  ('confirmarUploadMidia', $$select public.confirmar_upload_midia('80200000-0000-4000-8000-000000000099')$$),
  ('removerMidia', $$select public.remover_midia('80200000-0000-4000-8000-000000000099')$$),
  ('pedirNovaAnaliseMidia', $$select public.pedir_nova_analise_midia('80200000-0000-4000-8000-000000000099')$$),
  ('minhasMidias', $$select public.minhas_midias()$$)) t(op,sql);
select pg_temp.guarda('promete:' || op || ':404', pg_temp.observado(conta, sql)) from midia_colheita cross join (values
  ('confirmarUploadMidia', $$select public.confirmar_upload_midia('80200000-0000-4000-8000-000000000099')$$),
  ('removerMidia', $$select public.remover_midia('80200000-0000-4000-8000-000000000099')$$),
  ('pedirNovaAnaliseMidia', $$select public.pedir_nova_analise_midia('80200000-0000-4000-8000-000000000099')$$)) t(op,sql);
select pg_temp.guarda('promete:' || op || ':403', pg_temp.observado('cc000000-0000-4000-8000-000000000004',sql)) from (values
  ('removerMidia', $$select public.remover_midia('80200000-0000-4000-8000-000000000099')$$),
  ('pedirNovaAnaliseMidia', $$select public.pedir_nova_analise_midia('80200000-0000-4000-8000-000000000099')$$),
  ('minhasMidias', $$select public.minhas_midias()$$)) t(op,sql);

-- Por último, e depois de tudo: ela anonimiza a conta e cancela os turnos futuros dela.
-- Qualquer colheita posterior veria um cenário diferente do que as outras viram. A conta
-- anonimizada é a `…0003`, a mesma que os dois guardas de `promete:perfilPublico:404`
-- acima usam — por isso a ordem destes dois blocos é obrigatória, e inverter não daria
-- erro de sintaxe nem conflito: daria colheita sobre conta anonimizada, com portão verde.
select pg_temp.guarda('excluirConta',
  privado.excluir_conta('cc000000-0000-4000-8000-000000000003'));

-- Os dois 401 do ciclo de bloqueio: conta anonimizada não lista nem desbloqueia (RF25).
select pg_temp.guarda('promete:listarBloqueios:401',
  pg_temp.observado('cc000000-0000-4000-8000-000000000003',
    $$ select public.listar_bloqueios() $$));

select pg_temp.guarda('promete:desbloquear:401',
  pg_temp.observado('cc000000-0000-4000-8000-000000000003',
    $$ select public.desbloquear('estabelecimento', 'c0000000-0000-4000-8000-0000000000fd'::uuid) $$));

-- 401 de resolverServico: conta anonimizada não busca serviço (RF25)
select pg_temp.guarda('promete:resolverServico:401',
  pg_temp.observado('cc000000-0000-4000-8000-000000000003',
    $$ select public.resolver_servico('diarista') $$));

-- Os três 401 da verificação de identidade: conta anonimizada não lê nem escreve
-- verificação (RF25, RNF08), e a recusa vem antes de olhar perfil ou estado. Só aqui,
-- depois da exclusão acima, existe uma conta anonimizada para medir.
select pg_temp.guarda('promete:minhaIdentidadeStatus:401',
  pg_temp.observado('cc000000-0000-4000-8000-000000000003',
    $$ select public.minha_identidade_status() $$));

select pg_temp.guarda('promete:solicitarUploadVerificacao:401',
  pg_temp.observado('cc000000-0000-4000-8000-000000000003',
    $$ select public.solicitar_upload_verificacao('rg') $$));

select pg_temp.guarda('promete:confirmarEnvioVerificacao:401',
  pg_temp.observado('cc000000-0000-4000-8000-000000000003',
    $$ select public.confirmar_envio_verificacao() $$));

-- ── A colheita ────────────────────────────────────────────────────────────────
\o
\pset format unaligned
\pset tuples_only on
select jsonb_build_object('op', op, 'corpo', corpo)::text from colhido order by ordem;

rollback;
