begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(16);

insert into privado.ambiente (eh_teste) values (true);

create temp table ids as
select
  'b8000000-0000-4000-8000-000000000001'::uuid as profissional_usuario,
  'b8000000-0000-4000-8000-000000000003'::uuid as profissional_usuario_2,
  'b8000000-0000-4000-8000-000000000002'::uuid as contratante_usuario,
  'b8000000-0000-4000-8000-000000000011'::uuid as profissional,
  'b8000000-0000-4000-8000-000000000012'::uuid as profissional_2,
  'b8000000-0000-4000-8000-000000000021'::uuid as estabelecimento,
  'b8000000-0000-4000-8000-000000000031'::uuid as vaga_turno,
  'b8000000-0000-4000-8000-000000000032'::uuid as vaga_vazia,
  'b8000000-0000-4000-8000-000000000033'::uuid as vaga_sem_prova,
  'b8000000-0000-4000-8000-000000000034'::uuid as vaga_duas_posicoes,
  'b8000000-0000-4000-8000-000000000041'::uuid as posicao_turno,
  'b8000000-0000-4000-8000-000000000042'::uuid as posicao_vazia,
  'b8000000-0000-4000-8000-000000000043'::uuid as posicao_sem_prova,
  'b8000000-0000-4000-8000-000000000044'::uuid as posicao_duas_1,
  'b8000000-0000-4000-8000-000000000045'::uuid as posicao_duas_2,
  'b8000000-0000-4000-8000-000000000051'::uuid as turno,
  'b8000000-0000-4000-8000-000000000052'::uuid as turno_sem_prova;

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}', '{}', now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

create function pg_temp.como(conta uuid, consulta text) returns jsonb
language plpgsql as $$
declare resultado jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute consulta into resultado;
  reset role;
  execute 'reset request.jwt.claims';
  return resultado;
end $$;

select pg_temp.autenticar(profissional_usuario, 'prof-fechamento@test.invalid')
  from ids;
select pg_temp.autenticar(profissional_usuario_2, 'prof-fechamento-2@test.invalid')
  from ids;

insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em
)
select profissional_usuario, 'profissional'::public.perfil_conta, 'Profissional Fechamento',
       '+5561999990001', 'prof-fechamento@test.invalid', '1990-01-01'::date,
       '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids
union all
select contratante_usuario, 'contratante'::public.perfil_conta, 'Casa Fechamento',
       '+5561999990002', 'casa-fechamento@test.invalid', '1985-01-01'::date,
       '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids;

insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em
)
select profissional_usuario_2, 'profissional'::public.perfil_conta, 'Profissional Fechamento 2',
       '+5561999990003', 'prof-fechamento-2@test.invalid', '1990-01-01'::date,
       '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids;

insert into public.profissional (id, usuario_id, ponto_base)
select profissional, profissional_usuario, 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.profissional (id, usuario_id, ponto_base)
select profissional_2, profissional_usuario_2, 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.profissional_funcao (profissional_id, funcao_id)
select profissional, (select id from public.funcao limit 1) from ids
union all
select profissional_2, (select id from public.funcao limit 1) from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select estabelecimento, 'Casa Fechamento', '80000000000191', 'food_service',
       'Endereco de teste', 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select contratante_usuario, estabelecimento, 'administrador'
  from ids;

insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em,
  chave_cliente, publicado_por
)
select vaga_duas_posicoes, estabelecimento, (select id from public.funcao limit 1),
       '2026-10-03 18:00:00-03'::timestamptz, '2026-10-03 23:00:00-03'::timestamptz,
       'Local', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 2, false, false, false, 'Responsavel', 'urgencia', 'publicada',
       '2026-09-20 12:00:00-03', gen_random_uuid(), contratante_usuario
  from ids;

insert into public.posicao (id, vaga_id, inicio_em, fim_em)
select posicao_duas_1, vaga_duas_posicoes,
       '2026-10-03 18:00:00-03'::timestamptz, '2026-10-03 23:00:00-03'::timestamptz
  from ids
union all
select posicao_duas_2, vaga_duas_posicoes,
       '2026-10-03 18:00:00-03'::timestamptz, '2026-10-03 23:00:00-03'::timestamptz
  from ids;

select is(
  (select count(*)::int from jsonb_array_elements(pg_temp.como(
    (select profissional_usuario from ids), $$ select public.vagas_abertas() $$))
    item where item->>'id' = (select vaga_duas_posicoes::text from ids)),
  1,
  'vaga de duas posições aparece antes das confirmações');

select pg_temp.como(
  (select profissional_usuario from ids),
  format($$ select public.candidatar(%L) $$, (select vaga_duas_posicoes from ids)));

select is(
  (select count(*)::int from jsonb_array_elements(pg_temp.como(
    (select profissional_usuario from ids), $$ select public.vagas_abertas() $$))
    item where item->>'id' = (select vaga_duas_posicoes::text from ids)),
  1,
  'vaga de duas posições continua na lista após a primeira confirmação');

select pg_temp.como(
  (select profissional_usuario_2 from ids),
  format($$ select public.candidatar(%L) $$, (select vaga_duas_posicoes from ids)));

select is(
  (select count(*)::int from jsonb_array_elements(pg_temp.como(
    (select profissional_usuario from ids), $$ select public.vagas_abertas() $$))
    item where item->>'id' = (select vaga_duas_posicoes::text from ids)),
  0,
  'vaga de duas posições some da lista após a segunda confirmação');

select set_config('frila.agora', '2026-10-02 12:00:00-03', true);
select pg_temp.como(
  (select profissional_usuario from ids),
  format($$ select public.cancelar_posicao(%L, 'imprevisto') $$,
         (select posicao_duas_1 from ids)));

select is(
  (select count(*)::int from jsonb_array_elements(pg_temp.como(
    (select profissional_usuario from ids), $$ select public.vagas_abertas() $$))
    item where item->>'id' = (select vaga_duas_posicoes::text from ids)),
  1,
  'vaga volta à lista após cancelamento com mais de 24 horas');

select set_config('frila.agora', '2026-09-26 00:00:00-03', true);

insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
)
select vaga_turno, estabelecimento, (select id from public.funcao limit 1),
       '2026-09-25 18:00:00-03', '2026-09-25 23:00:00-03',
       'Local', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 1, false, false, false, 'Responsavel', 'urgencia', 'preenchida',
       '2026-09-20 12:00:00-03', gen_random_uuid(), contratante_usuario
  from ids;

insert into public.posicao (
  id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em
)
select posicao_turno, vaga_turno, 'confirmada', profissional,
       '2026-09-20 12:00:00-03', '2026-09-25 18:00:00-03', '2026-09-25 23:00:00-03'
  from ids;

insert into public.turno (
  id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
  verificacao, valor_acordado_centavos
)
select turno, posicao_turno, '2026-09-25 18:01:00-03', 'geolocalizado', 50,
       'verificado', 15000
  from ids;

insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
)
select vaga_sem_prova, estabelecimento, (select id from public.funcao limit 1),
       '2026-09-24 18:00:00-03', '2026-09-24 23:00:00-03',
       'Local', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 1, false, false, false, 'Responsavel', 'urgencia', 'preenchida',
       '2026-09-20 12:00:00-03', gen_random_uuid(), contratante_usuario
  from ids;

insert into public.posicao (
  id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em
)
select posicao_sem_prova, vaga_sem_prova, 'confirmada', profissional,
       '2026-09-20 12:00:00-03', '2026-09-24 18:00:00-03', '2026-09-24 23:00:00-03'
  from ids;

insert into public.turno (id, posicao_id, verificacao, valor_acordado_centavos)
select turno_sem_prova, posicao_sem_prova, 'pendente', 15000
  from ids;

insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
)
select vaga_vazia, estabelecimento, (select id from public.funcao limit 1),
       '2026-09-25 18:00:00-03', '2026-09-25 23:00:00-03',
       'Local', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 1, false, false, false, 'Responsavel', 'urgencia', 'publicada',
       '2026-09-20 12:00:00-03', gen_random_uuid(), contratante_usuario
  from ids;

insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em)
select posicao_vazia, vaga_vazia, 'cancelada',
       '2026-09-25 18:00:00-03', '2026-09-25 23:00:00-03'
  from ids;

select set_config('frila.agora', '2026-09-26 00:00:00-03', true);

select lives_ok(
  $$ select privado.fechar_turnos_e_vagas() $$,
  'o job de fechamento pode ser chamado pelo agendador');

select is(
  has_function_privilege('authenticated', 'privado.fechar_turnos_e_vagas()', 'execute'),
  false,
  'authenticated não pode executar o job');

select is(
  has_function_privilege('service_role', 'privado.fechar_turnos_e_vagas()', 'execute'),
  true,
  'service_role pode executar o job');

select is(
  (select p.estado::text from public.posicao p, ids where p.id = ids.posicao_turno),
  'cumprida',
  'posição confirmada vira cumprida depois do fim');

select is(
  (select g.estado::text from public.vaga g, ids where g.id = ids.vaga_turno),
  'encerrada',
  'vaga sem posição aberta nem confirmada vira encerrada');

select is(
  (select g.estado::text from public.vaga g, ids where g.id = ids.vaga_vazia),
  'encerrada',
  'vaga sem posição aberta nem confirmada é encerrada mesmo sem turno');

select is(
  (select t.verificacao::text from public.turno t, ids where t.id = ids.turno_sem_prova),
  'pendente',
  'turno sem check-in mantém o comportamento pendente até a decisão 8zLfn0mt');

select is(
  (select p.estado::text from public.posicao p, ids where p.id = ids.posicao_sem_prova),
  'cumprida',
  'posição confirmada é concluída sem decidir o destino do turno sem check-in');

select is(
  (select count(*)::int from public.notificacao n, ids
    where n.tipo = 'avaliacao_disponivel'
      and n.referencia_id = ids.turno
      and n.usuario_id in (ids.profissional_usuario, ids.contratante_usuario)),
  2,
  'turno verificado notifica os dois lados');

select is(
  (select count(*)::int from public.notificacao n, ids
    where n.tipo = 'avaliacao_disponivel'
      and n.referencia_id = ids.turno),
  2,
  'a primeira execução cria uma notificação por lado');

select lives_ok(
  $$ select privado.fechar_turnos_e_vagas() $$,
  'o job pode ser executado novamente');

select is(
  (select count(*)::int from public.notificacao n, ids
    where n.tipo = 'avaliacao_disponivel'
      and n.referencia_id = ids.turno),
  2,
  'a marca de envio impede notificações duplicadas');

select * from finish();
rollback;
