-- Testes pgTAP para os alertas operacionais de moderação e contestação vencidas,
-- fechamento automático de denúncia/contestação nas ações da equipe e teto do relato (Itens 21 e 21b).

begin;

select plan(13);

set local frila.agendador_secret = 'segredo-de-teste';

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local "request.jwt.claims" = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute format('set local "request.jwt.claim.sub" = %L', conta::text);
  execute sql into r;
  reset role;
  execute 'reset "request.jwt.claims"';
  execute 'reset "request.jwt.claim.sub"';
  return r;
end $$;

-- Cenário base
create temp table ids as
select
  gen_random_uuid() as prof_usr,
  gen_random_uuid() as casa_usr,
  gen_random_uuid() as equipe_usr,
  gen_random_uuid() as prof_id,
  gen_random_uuid() as estab_id,
  gen_random_uuid() as vaga_id,
  gen_random_uuid() as pos_id,
  gen_random_uuid() as turno_id;

-- Usuários
insert into auth.users (instance_id, id, aud, role, email)
values
  ('00000000-0000-0000-0000-000000000000', (select prof_usr from ids), 'authenticated', 'authenticated', 'prof742@frila.test'),
  ('00000000-0000-0000-0000-000000000000', (select casa_usr from ids), 'authenticated', 'authenticated', 'casa742@frila.test'),
  ('00000000-0000-0000-0000-000000000000', (select equipe_usr from ids), 'authenticated', 'authenticated', 'equipe742@frila.test');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
values
  ((select prof_usr from ids), 'profissional', 'Prof 742', '+5561977770001', 'prof742@frila.test', '1995-01-01', 'ativa', '2026-09-22', now()),
  ((select casa_usr from ids), 'contratante', 'Casa 742', '+5561977770002', 'casa742@frila.test', '1990-01-01', 'ativa', '2026-09-22', now()),
  ((select equipe_usr from ids), 'contratante', 'Equipe 742', '+5561977770003', 'equipe742@frila.test', '1992-01-01', 'ativa', '2026-09-22', now());

insert into public.profissional (id, usuario_id, ponto_base)
values ((select prof_id from ids), (select prof_usr from ids), 'POINT(-47.88 -15.79)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, regiao_administrativa, endereco, ponto)
values ((select estab_id from ids), 'Estab 742', '12345678000199', 'food_service', 'Plano Piloto', 'SCS Quadra 1', 'POINT(-47.88 -15.79)'::extensions.geography);

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ((select estab_id from ids), (select casa_usr from ids), 'administrador');

-- Cria vaga, posição e turno
insert into public.vaga (id, estabelecimento_id, publicado_por, funcao_id, inicio_em, fim_em, local, regiao_administrativa, responsavel_local, valor_centavos, posicoes, modo, estado, ponto, chave_cliente, traje, observacoes, inclui_refeicao, inclui_transporte, exige_material_proprio)
values (
  (select vaga_id from ids),
  (select estab_id from ids),
  (select casa_usr from ids),
  (select id from public.funcao limit 1),
  now() + interval '3 days',
  now() + interval '3 days 6 hours',
  'Estab 742',
  'Plano Piloto',
  'Gerente 742',
  15000,
  1,
  'urgencia',
  'publicada',
  'POINT(-47.88 -15.79)'::extensions.geography,
  gen_random_uuid(),
  'Social',
  'Texto da vaga para teste de moderacao',
  false,
  false,
  false
);

insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em, profissional_id, confirmado_em)
values ((select pos_id from ids), (select vaga_id from ids), 'confirmada', now() + interval '3 days', now() + interval '3 days 6 hours', (select prof_id from ids), now());

insert into public.turno (id, posicao_id, valor_acordado_centavos)
values ((select turno_id from ids), (select pos_id from ids), 15000);

-- Limpa alertas antigos da tabela de controle
delete from privado.alerta_emitido where codigo in ('moderacao_vencida', 'contestacao_vencida');

-- ── Teste 1: Denúncia com menos de 24h NÃO dispara moderacao_vencida ─────────
insert into public.ocorrencia (id, tipo, turno_id, usuario_id, autor_id, motivo, relato, criada_em)
values (
  gen_random_uuid(),
  'denuncia',
  (select turno_id from ids),
  (select casa_usr from ids),
  (select prof_usr from ids),
  'outro',
  'Denuncia recente teste',
  privado.agora() - interval '2 hours'
);

select is(
  (select count(*)::int from public.ocorrencia where tipo = 'denuncia' and resolvido_em is null and criada_em < privado.agora() - interval '24 hours'),
  0,
  'nenhuma denúncia vencida com criada_em recente'
);

-- ── Teste 2: Denúncia criada há mais de 24h dispara moderacao_vencida ─────────
insert into public.ocorrencia (id, tipo, turno_id, usuario_id, autor_id, motivo, relato, criada_em)
values (
  gen_random_uuid(),
  'denuncia',
  (select turno_id from ids),
  (select casa_usr from ids),
  (select prof_usr from ids),
  'outro',
  'Denuncia antiga teste mais de 24h',
  privado.agora() - interval '26 hours'
);

select is(
  (select count(*)::int from public.ocorrencia where tipo = 'denuncia' and resolvido_em is null and criada_em < privado.agora() - interval '24 hours'),
  1,
  '1 denúncia vencida há mais de 24h identificada'
);

-- Executa verificar_saude e confere alerta enfileirado
select lives_ok(
  $$ select privado.verificar_saude() $$,
  'verificar_saude executa com sucesso sob denúncia vencida'
);

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'moderacao_vencida'),
  1,
  'alerta moderacao_vencida registrado em privado.alerta_emitido'
);

-- ── Teste 3: Contestação com mais de 5 dias úteis dispara contestacao_vencida ──
insert into public.ocorrencia (id, tipo, usuario_id, autor_id, motivo, relato, criada_em)
values (
  gen_random_uuid(),
  'contestacao',
  (select prof_usr from ids),
  (select prof_usr from ids),
  'Contestação antiga teste',
  'Relato de contestacao antiga com mais de dez caracteres',
  privado.agora() - interval '10 days'
);

delete from privado.alerta_emitido where codigo = 'contestacao_vencida';
select privado.verificar_saude();

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'contestacao_vencida'),
  1,
  'alerta contestacao_vencida registrado em privado.alerta_emitido para contestação vencida'
);

-- ── Teste 4: operacao_moderar_conteudo('ocultar') fecha denúncia pendente ─────
-- Cria nova denúncia para a vaga
create temp table den_vaga as
select gen_random_uuid() as den_id;

insert into public.ocorrencia (id, tipo, turno_id, usuario_id, autor_id, motivo, relato, criada_em)
values (
  (select den_id from den_vaga),
  'denuncia',
  (select turno_id from ids),
  (select casa_usr from ids),
  (select prof_usr from ids),
  'outro',
  'Denuncia a ser fechada pela moderacao de conteudo',
  privado.agora()
);

select is(
  (select resolvido_em is null from public.ocorrencia where id = (select den_id from den_vaga)),
  true,
  'denúncia inicia não resolvida (resolvido_em is null)'
);

-- Modera a vaga ocultando
select lives_ok(
  format($$ select privado.operacao_moderar_conteudo(%L, 'ocultar', 'Violacao constatada', %L) $$,
         (select vaga_id from ids), (select equipe_usr from ids)),
  'operacao_moderar_conteudo oculta vaga com sucesso'
);

select is(
  (select resolvido_em is not null from public.ocorrencia where id = (select den_id from den_vaga)),
  true,
  'operacao_moderar_conteudo preenche resolvido_em da denúncia da vaga'
);

-- ── Teste 5: operacao_moderar_texto fecha denúncia pendente ────────────────────
-- Cria denúncia com estabelecimento
create temp table den_texto as
select gen_random_uuid() as den_id;

insert into public.ocorrencia (id, tipo, estabelecimento_id, autor_id, motivo, relato, criada_em)
values (
  (select den_id from den_texto),
  'denuncia',
  (select estab_id from ids),
  (select prof_usr from ids),
  'outro',
  'Denuncia de texto ofensivo',
  privado.agora()
);

-- Modera texto
select lives_ok(
  format($$ select privado.operacao_moderar_texto(%L, 'ocultar', 'Texto ofensivo removido', %L) $$,
         (select vaga_id from ids), (select equipe_usr from ids)),
  'operacao_moderar_texto oculta texto da vaga com sucesso'
);

select is(
  (select resolvido_em is not null from public.ocorrencia where id = (select den_id from den_texto)),
  true,
  'operacao_moderar_texto preenche resolvido_em da denúncia do estabelecimento'
);

-- ── Teste 6: operacao_reativar_conta fecha contestações pendentes ──────────────
-- Suspende conta para poder reativar
update public.usuario set estado = 'suspensa' where id = (select prof_usr from ids);

create temp table cont_usuario as
select gen_random_uuid() as cont_id;

insert into public.ocorrencia (id, tipo, usuario_id, autor_id, motivo, relato, criada_em)
values (
  (select cont_id from cont_usuario),
  'contestacao',
  (select prof_usr from ids),
  (select prof_usr from ids),
  'Contestação ativa',
  'Relato de contestacao ativa com mais de dez caracteres',
  privado.agora()
);

select lives_ok(
  format($$ select privado.operacao_reativar_conta(%L, 'Justificativa acolhida', %L) $$,
         (select prof_usr from ids), (select equipe_usr from ids)),
  'operacao_reativar_conta reativa com sucesso'
);

select is(
  (select resolvido_em is not null from public.ocorrencia where id = (select cont_id from cont_usuario)),
  true,
  'operacao_reativar_conta preenche resolvido_em da contestação do usuário'
);

-- ── Teste 7: contestar_suspensao recusa relato maior que 5000 caracteres ───────
-- Suspende novamente a conta para testar contestar_suspensao
update public.usuario set estado = 'suspensa' where id = (select prof_usr from ids);

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$,
         (select prof_usr from ids),
         format('select public.contestar_suspensao(%L)', repeat('a', 5001))),
  'PGRST',
  pg_temp.erro('campo_invalido', 'relato'),
  'contestar_suspensao recusa relato com mais de 5000 caracteres com 422 campo_invalido relato'
);

select * from finish();
rollback;
