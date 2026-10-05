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
    ('cc000000-0000-4000-8000-000000000004'::uuid,'contrato-suspenso@t.test')
  ) as c(id, email);

select pg_temp.guarda('criarConta', pg_temp.como('cc000000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante','Casa do Contrato','+5561944440001','1980-05-05','2026-09-22') $$));
select pg_temp.como('cc000000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('profissional','Pê do Contrato','+5561944440002','1995-05-05','2026-09-22') $$);
select pg_temp.como('cc000000-0000-4000-8000-000000000003',
  $$ select public.criar_conta('profissional','Pê Dois','+5561944440003','1994-05-05','2026-09-22') $$);
select pg_temp.como('cc000000-0000-4000-8000-000000000004',
  $$ select public.criar_conta('profissional','Pê Suspenso','+5561944440004','1993-05-05','2026-09-22') $$);

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
  select pg_temp.como('cc000000-0000-4000-8000-000000000003', format(
    $$ select public.candidatar(%L::uuid) $$, ((select r from vaga_sel)->>'vaga_id')::uuid)) as r;

select pg_temp.guarda('candidatosDaVaga', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.candidatos_da_vaga(%L::uuid) $$, ((select r from vaga_sel)->>'vaga_id')::uuid)));
select pg_temp.guarda('minhasCandidaturas', pg_temp.como('cc000000-0000-4000-8000-000000000003',
  $$ select public.minhas_candidaturas() $$));
select pg_temp.guarda('retirarCandidatura', pg_temp.como('cc000000-0000-4000-8000-000000000003', format(
  $$ select public.retirar_candidatura(%L::uuid) $$, ((select r from cand_sel2)->>'candidatura_id')::uuid)));
select pg_temp.guarda('escolherCandidato', pg_temp.como('cc000000-0000-4000-8000-000000000001', format(
  $$ select public.escolher_candidato(%L::uuid) $$, ((select r from cand_sel)->>'candidatura_id')::uuid)));

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

-- 3. cancelarPosicao: 409 posicao_nao_cancelavel (tentativa de cancelar posição já cancelada)
select pg_temp.guarda('promete:cancelarPosicao:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000003', format(
    $$ select public.cancelar_posicao(%L::uuid, 'duplicado') $$,
    ((select r from cand2)->>'posicao_id')::uuid)));

-- 4. cancelarVaga: 409 vaga_encerrada (tentativa de cancelar vaga já cancelada)
select pg_temp.guarda('promete:cancelarVaga:409',
  pg_temp.observado('cc000000-0000-4000-8000-000000000001', format(
    $$ select public.cancelar_vaga(%L::uuid, 'duplicado') $$,
    ((select r from vaga2)->>'vaga_id')::uuid)));

-- 5. excluirConta: 409 administrador_unico (único admin de estabelecimento com outros membros)
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values ('ee000000-0000-4000-8000-000000000099', 'contratante', 'Aux Contratante', '+5561999999999', 'aux@frila.test', '1990-01-01', '1.0', now(), 'ativa')
on conflict do nothing;

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ((select casa_id from ids), 'ee000000-0000-4000-8000-000000000099', 'operador')
on conflict do nothing;

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

select pg_temp.guarda('exportarMeusDados',
  privado.meus_dados('cc000000-0000-4000-8000-000000000002'));

-- Amostra também para a conta contratante (Casa), exercitando estabelecimentos vinculados
select pg_temp.guarda('exportarMeusDados',
  privado.meus_dados('cc000000-0000-4000-8000-000000000001'));

-- Por último, e depois de tudo: ela anonimiza a conta e cancela os turnos futuros dela.
-- Qualquer colheita posterior veria um cenário diferente do que as outras viram. A conta
-- anonimizada é a `…0003`, a mesma que os dois guardas de `promete:perfilPublico:404`
-- acima usam — por isso a ordem destes dois blocos é obrigatória, e inverter não daria
-- erro de sintaxe nem conflito: daria colheita sobre conta anonimizada, com portão verde.
select pg_temp.guarda('excluirConta',
  privado.excluir_conta('cc000000-0000-4000-8000-000000000003'));

-- ── A colheita ────────────────────────────────────────────────────────────────
\o
\pset format unaligned
\pset tuples_only on
select jsonb_build_object('op', op, 'corpo', corpo)::text from colhido order by ordem;

rollback;
