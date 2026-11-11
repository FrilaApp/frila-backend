-- 843_multiplos_membros_papeis.sql
--
-- Múltiplos membros por estabelecimento com papéis (RF21, Cartão Trello JpKoxqWo).
--
-- 1. Convite aceito por conta de contratante vira membro; por conta de profissional é recusado com 422 perfil_incompativel.
-- 2. Remover membro revoga o acesso na hora e mantém histórico.
-- 3. Único administrador não sai sem transferir (422 ultimo_administrador).

begin;
select plan(33);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local "frila.agora" = '2026-11-09 15:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste-843';

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

create function pg_temp.erro(conta uuid, sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  perform pg_temp.como(conta, sql);
  return null;
exception when others then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return msg::jsonb || det::jsonb;
end $$;

-- ── 1. Fixtures ───────────────────────────────────────────────────────────────

insert into auth.users (id, email) values
  ('84300000-0000-4000-8000-000000000001', 'admin1@843.test'),
  ('84300000-0000-4000-8000-000000000002', 'contratante2@843.test'),
  ('84300000-0000-4000-8000-000000000003', 'prof@843.test'),
  ('84300000-0000-4000-8000-000000000004', 'alheio@843.test');

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em, estado) values
  ('84300000-0000-4000-8000-000000000001', 'contratante', 'Admin Um', 'admin1@843.test', '+5561955508431', '1985-01-01', '1.0', now(), 'ativa'),
  ('84300000-0000-4000-8000-000000000002', 'contratante', 'Contratante Dois', 'contratante2@843.test', '+5561955508432', '1990-02-02', '1.0', now(), 'ativa'),
  ('84300000-0000-4000-8000-000000000003', 'profissional', 'Profissional Teste', 'prof@843.test', '+5561955508433', '1995-03-03', '1.0', now(), 'ativa'),
  ('84300000-0000-4000-8000-000000000004', 'contratante', 'Contratante Alheio', 'alheio@843.test', '+5561955508434', '1992-04-04', '1.0', now(), 'ativa');

insert into public.profissional (id, usuario_id, ponto_base) values
  ('84300000-0000-4000-8000-000000000030', '84300000-0000-4000-8000-000000000003', 'POINT(-47.8822 -15.7942)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('84300000-0000-4000-8000-0000000000e1', 'Bar Central 843', '84311222000199', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('84300000-0000-4000-8000-0000000000e1', '84300000-0000-4000-8000-000000000001', 'administrador');

-- Criação de vaga para comprovar histórico preservado após saída de membro
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos, posicoes,
                         inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_por, publicado_em)
values
  ('84300000-0000-4000-8000-0000000000b1', '84300000-0000-4000-8000-0000000000e1', (select id from public.funcao where nome = 'garçom'),
   '2026-11-15 18:00+00', '2026-11-15 23:00+00', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 16000, 1,
   true, false, false, 'Gerente Histórico', 'urgencia', gen_random_uuid(), '84300000-0000-4000-8000-000000000001', now());

-- ── 2. Assinaturas e permissões ───────────────────────────────────────────────

select has_function('public', 'convidar_membro', array['uuid', 'text', 'public.papel_membro'], 'convidar_membro existe');
select has_function('public', 'aceitar_convite_membro', array['text'], 'aceitar_convite_membro existe');
select has_function('public', 'remover_membro', array['uuid', 'uuid'], 'remover_membro existe');
select has_function('public', 'transferir_administracao', array['uuid', 'uuid'], 'transferir_administracao existe');

select is(has_function_privilege('anon', 'public.convidar_membro(uuid, text, public.papel_membro)', 'execute'), false, 'anon sem execute em convidar_membro');
select is(has_function_privilege('anon', 'public.aceitar_convite_membro(text)', 'execute'), false, 'anon sem execute em aceitar_convite_membro');
select is(has_function_privilege('anon', 'public.remover_membro(uuid, uuid)', 'execute'), false, 'anon sem execute em remover_membro');
select is(has_function_privilege('anon', 'public.transferir_administracao(uuid, uuid)', 'execute'), false, 'anon sem execute em transferir_administracao');

select is(has_function_privilege('authenticated', 'public.convidar_membro(uuid, text, public.papel_membro)', 'execute'), true, 'authenticated com execute em convidar_membro');
select is(has_function_privilege('authenticated', 'public.aceitar_convite_membro(text)', 'execute'), true, 'authenticated com execute em aceitar_convite_membro');
select is(has_function_privilege('authenticated', 'public.remover_membro(uuid, uuid)', 'execute'), true, 'authenticated com execute em remover_membro');
select is(has_function_privilege('authenticated', 'public.transferir_administracao(uuid, uuid)', 'execute'), true, 'authenticated com execute em transferir_administracao');

-- ── 3. Teste de convidar_membro ───────────────────────────────────────────────

create temp table conv1 as
  select pg_temp.como('84300000-0000-4000-8000-000000000001',
    $$ select public.convidar_membro('84300000-0000-4000-8000-0000000000e1'::uuid, 'novo@843.test', 'operador') $$
  ) as r;

select is(
  ((select r from conv1)->>'token') is not null and length((select r from conv1)->>'token') = 64,
  true,
  'admin gera convite válido com sucesso (200/jsonb com token 64 hex)'
);

select is(
  (select count(*) from privado.convite_membro
    where id = ((select r from conv1)->>'convite_id')::uuid
      and estabelecimento_id = '84300000-0000-4000-8000-0000000000e1'
      and email = 'novo@843.test'
      and papel = 'operador'
      and usado_em is null),
  1::bigint,
  'convite gravado em privado.convite_membro com status não usado'
);

select is(
  (pg_temp.erro('84300000-0000-4000-8000-000000000004',
    $$ select public.convidar_membro('84300000-0000-4000-8000-0000000000e1'::uuid, 'outro@843.test', 'operador') $$
  ))->>'code',
  'sem_permissao',
  'não-admin recusa 403 ao tentar convidar'
);

select is(
  (pg_temp.erro('84300000-0000-4000-8000-000000000001',
    $$ select public.convidar_membro('84300000-0000-4000-8000-0000000000e1'::uuid, 'email-invalido', 'operador') $$
  ))->>'code',
  'campo_invalido',
  'email inválido recusa 422 campo_invalido'
);

-- ── 4. Teste de aceitar_convite_membro (Critério 1) ───────────────────────────

-- Critério 1: conta de profissional tenta aceitar -> 422 perfil_incompativel (RN25)
select is(
  (pg_temp.erro('84300000-0000-4000-8000-000000000003', format(
    $$ select public.aceitar_convite_membro(%L) $$, (select r->>'token' from conv1)
  )))->>'code',
  'perfil_incompativel',
  'critério 1: profissional tentando aceitar recusa 422 perfil_incompativel'
);

-- Critério 1: conta de contratante aceita convite válido e vira membro
create temp table membro_novo as
  select pg_temp.como('84300000-0000-4000-8000-000000000002', format(
    $$ select public.aceitar_convite_membro(%L) $$, (select r->>'token' from conv1)
  )) as r;

select is(
  ((select r from membro_novo)->>'papel'),
  'operador',
  'critério 1: contratante aceita convite válido e vira membro operador'
);

select is(
  (pg_temp.como('84300000-0000-4000-8000-000000000002',
    $$ select to_jsonb(privado.eh_membro('84300000-0000-4000-8000-0000000000e1'::uuid)) $$
  )),
  'true'::jsonb,
  'privado.eh_membro agora é true para novo membro'
);

select is(
  (select papel from public.membro_estabelecimento where estabelecimento_id = '84300000-0000-4000-8000-0000000000e1' and usuario_id = '84300000-0000-4000-8000-000000000002'),
  'operador'::public.papel_membro,
  'novo membro é operador (papel operador no banco)'
);

-- Token já usado recusa com convite_invalido
select is(
  (pg_temp.erro('84300000-0000-4000-8000-000000000004', format(
    $$ select public.aceitar_convite_membro(%L) $$, (select r->>'token' from conv1)
  )))->>'code',
  'convite_invalido',
  'token já usado recusa 422 convite_invalido'
);

select is(
  (pg_temp.erro('84300000-0000-4000-8000-000000000002',
    $$ select public.aceitar_convite_membro('token_que_nao_existe_1234567890') $$
  ))->>'code',
  'convite_invalido',
  'token inexistente recusa 422 convite_invalido'
);

-- Convite expirado
insert into privado.convite_membro (estabelecimento_id, email, papel, convidado_por, token_hash, expira_em, criado_em)
values ('84300000-0000-4000-8000-0000000000e1', 'vencido@843.test', 'operador',
        '84300000-0000-4000-8000-000000000001', encode(sha256('token_vencido_843'::bytea), 'hex'),
        '2026-11-08 12:00:00+00', '2026-11-01 12:00:00+00');

select is(
  (pg_temp.erro('84300000-0000-4000-8000-000000000002',
    $$ select public.aceitar_convite_membro('token_vencido_843') $$
  ))->>'code',
  'convite_invalido',
  'token expirado recusa 422 convite_invalido'
);

-- Restrições da tabela, violadas direto (portão de mutação estrutural: scripts/mutacao.sh)
select throws_ok(
  $$ insert into privado.convite_membro (estabelecimento_id, email, papel, convidado_por, token_hash, expira_em)
     values ('84300000-0000-4000-8000-0000000000e1', 'sem-arroba', 'operador',
             '84300000-0000-4000-8000-000000000001', encode(sha256('token_email_843'::bytea), 'hex'),
             '2026-11-16 12:00:00+00') $$,
  '23514',
  'new row for relation "convite_membro" violates check constraint "convite_membro_email_check"',
  'convite_membro_email_check: e-mail sem formato válido é recusado na tabela'
);

insert into privado.convite_membro (estabelecimento_id, email, papel, convidado_por, token_hash, expira_em)
values ('84300000-0000-4000-8000-0000000000e1', 'primeiro@843.test', 'operador',
        '84300000-0000-4000-8000-000000000001', encode(sha256('token_repetido_843'::bytea), 'hex'),
        '2026-11-16 12:00:00+00');

select throws_ok(
  $$ insert into privado.convite_membro (estabelecimento_id, email, papel, convidado_por, token_hash, expira_em)
     values ('84300000-0000-4000-8000-0000000000e1', 'segundo@843.test', 'operador',
             '84300000-0000-4000-8000-000000000001', encode(sha256('token_repetido_843'::bytea), 'hex'),
             '2026-11-16 12:00:00+00') $$,
  '23505',
  'duplicate key value violates unique constraint "convite_membro_token_hash_key"',
  'convite_membro_token_hash_key: dois convites com o mesmo token_hash são recusados na tabela'
);

-- ── 5. Proteção do Último Administrador (Critério 3) ─────────────────────────

-- Neste ponto, admin1 é o ÚNICO administrador (contratante2 é operador)
select is(
  (pg_temp.erro('84300000-0000-4000-8000-000000000001',
    $$ select public.remover_membro('84300000-0000-4000-8000-0000000000e1'::uuid, '84300000-0000-4000-8000-000000000001'::uuid) $$
  ))->>'code',
  'ultimo_administrador',
  'critério 3: único administrador recusa 422 ultimo_administrador ao tentar ser removido'
);

-- ── 6. Transferência de Administração e Remoção (Critério 2) ──────────────────

-- Operador tenta transferir admin -> 403 sem_permissao
select is(
  (pg_temp.erro('84300000-0000-4000-8000-000000000002',
    $$ select public.transferir_administracao('84300000-0000-4000-8000-0000000000e1'::uuid, '84300000-0000-4000-8000-000000000002'::uuid) $$
  ))->>'code',
  'sem_permissao',
  'operador tenta transferir admin e recusa 403'
);

-- Admin1 transfere administração para contratante2 (promove contratante2 a administrador)
select is(
  (pg_temp.como('84300000-0000-4000-8000-000000000001',
    $$ select public.transferir_administracao('84300000-0000-4000-8000-0000000000e1'::uuid, '84300000-0000-4000-8000-000000000002'::uuid) $$
  )->>'papel'),
  'administrador',
  'admin transfere admin para operador com sucesso'
);

-- Agora contratante2 é administrador
select is(
  (select papel from public.membro_estabelecimento where estabelecimento_id = '84300000-0000-4000-8000-0000000000e1' and usuario_id = '84300000-0000-4000-8000-000000000002'),
  'administrador'::public.papel_membro,
  'novo admin tem papel administrador no banco'
);

-- Agora que há 2 administradores, admin1 pode ser removido (por si ou por contratante2)
select is(
  (pg_temp.como('84300000-0000-4000-8000-000000000002',
    $$ select public.remover_membro('84300000-0000-4000-8000-0000000000e1'::uuid, '84300000-0000-4000-8000-000000000001'::uuid) $$
  )->>'removido')::boolean,
  true,
  'critério 2: admin pode ser removido quando há outro admin'
);

-- Critério 2: Acesso revogado na hora para o membro removido
select is(
  (pg_temp.como('84300000-0000-4000-8000-000000000001',
    $$ select to_jsonb(privado.eh_membro('84300000-0000-4000-8000-0000000000e1'::uuid)) $$
  )),
  'false'::jsonb,
  'critério 2: acesso revogado na hora (eh_membro é false)'
);

-- Critério 2: Histórico do estabelecimento e vagas criado por admin1 continua intacto
select is(
  (select count(*) from public.vaga
    where estabelecimento_id = '84300000-0000-4000-8000-0000000000e1'
      and publicado_por = '84300000-0000-4000-8000-000000000001'),
  1::bigint,
  'critério 2: histórico do estabelecimento e vagas preservados'
);

-- Critério 3 de novo: Agora que sobrou apenas contratante2 como administrador, ele não pode ser removido
select is(
  (pg_temp.erro('84300000-0000-4000-8000-000000000002',
    $$ select public.remover_membro('84300000-0000-4000-8000-0000000000e1'::uuid, '84300000-0000-4000-8000-000000000002'::uuid) $$
  ))->>'code',
  'ultimo_administrador',
  'agora único admin restante recusa 422 ao tentar sair'
);

rollback;
