-- 786_matriz_autorizacao_papeis_rpc.sql
--
-- Matriz exaustiva de autorizacao Papel x RPC cobrindo as 44 rotinas publicas do Frila:
--   * Papel anon (nao autenticado / chave publica)
--   * Papel profissional (autenticado, perfil='profissional')
--   * Papel outro contratante (autenticado, perfil='contratante', nao proprietario/alheio)
--   * Papel dono (autenticado, proprietario/membro autorizado do recurso)
--
-- Total de assercoes: 177 (1 censo de catalogo + 44 RPCs x 4 papeis)

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_temp;

-- 1. Setup de ambiente e congelamento do relogio
insert into privado.ambiente(id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-20 21:00:00+00', true);
set local "frila.agendador_secret" = 'segredo_teste_agendador_123';

select plan(177);

-- 2. Censo rigoroso do catalogo de rotinas publicas
select is(
  (select count(*) from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prosecdef = true
     and p.proname not in ('rls_auto_enable')),
  44::bigint,
  'censo de RPCs: schema public contem exatamente 44 RPCs expostas'
);

-- 3. Fixtures e contas representativas da matriz
insert into auth.users (id, aud, role, email, email_confirmed_at, raw_user_meta_data)
values
  ('78600000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'dono@teste.com', now(), '{"nome":"Dono"}'::jsonb),
  ('78600000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'outro_c@teste.com', now(), '{"nome":"Outro C"}'::jsonb),
  ('78600000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'prof@teste.com', now(), '{"nome":"Prof"}'::jsonb),
  ('78600000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'outro_p@teste.com', now(), '{"nome":"Outro P"}'::jsonb)
on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
values
  ('78600000-0000-4000-8000-000000000001', 'contratante', 'Contratante Dono', '+5561999910001', 'dono@teste.com', '1985-01-01', 'ativa', '1.0', now()),
  ('78600000-0000-4000-8000-000000000002', 'contratante', 'Outro Contratante', '+5561999910002', 'outro_c@teste.com', '1986-02-02', 'ativa', '1.0', now()),
  ('78600000-0000-4000-8000-000000000003', 'profissional', 'Profissional Teste', '+5561999910003', 'prof@teste.com', '1990-03-03', 'ativa', '1.0', now()),
  ('78600000-0000-4000-8000-000000000004', 'profissional', 'Outro Profissional', '+5561999910004', 'outro_p@teste.com', '1992-04-04', 'ativa', '1.0', now())
on conflict (id) do nothing;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values
  ('78600000-0000-4000-8000-000000000010', 'Restaurante do Dono', '11222333000199', 'food_service', 'CLN 201 Bloco A', 'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('78600000-0000-4000-8000-000000000020', 'Bar do Outro Contratante', '22333444000188', 'food_service', 'CLN 202 Bloco B', 'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto')
on conflict (id) do nothing;

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values
  ('78600000-0000-4000-8000-000000000010', '78600000-0000-4000-8000-000000000001', 'administrador'),
  ('78600000-0000-4000-8000-000000000020', '78600000-0000-4000-8000-000000000002', 'administrador')
on conflict (estabelecimento_id, usuario_id) do nothing;

insert into public.profissional (id, usuario_id, ponto_base)
values
  ('78600000-0000-4000-8000-000000000030', '78600000-0000-4000-8000-000000000003', 'POINT(-47.8825 -15.7942)'::extensions.geography),
  ('78600000-0000-4000-8000-000000000040', '78600000-0000-4000-8000-000000000004', 'POINT(-47.8825 -15.7942)'::extensions.geography)
on conflict (id) do nothing;

insert into public.profissional_funcao (profissional_id, funcao_id)
select p.id, f.id
from (values
  ('78600000-0000-4000-8000-000000000030'::uuid),
  ('78600000-0000-4000-8000-000000000040'::uuid)
) p(id)
cross join (select id from public.funcao where nome = 'garçom' limit 1) f
on conflict do nothing;

insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, publicado_em, publicado_por,
  estado, modo, valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, local, ponto, chave_cliente, regiao_administrativa
)
values (
  '78600000-0000-4000-8000-000000000100',
  '78600000-0000-4000-8000-000000000010',
  (select id from public.funcao where nome = 'garçom' limit 1),
  '2026-11-20 14:00:00+00',
  '2026-11-20 20:00:00+00',
  '2026-11-19 10:00:00+00',
  '78600000-0000-4000-8000-000000000001',
  'publicada',
  'urgencia',
  15000,
  2,
  false,
  false,
  false,
  'Chefe',
  'Restaurante do Dono',
  'POINT(-47.8825 -15.7942)'::extensions.geography,
  '78600000-0000-4000-8000-000000000999',
  'Plano Piloto'
) on conflict (id) do nothing;

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values
  ('78600000-0000-4000-8000-000000000101', '78600000-0000-4000-8000-000000000100', 'confirmada', '78600000-0000-4000-8000-000000000030', '2026-11-19 12:00:00+00', '2026-11-20 14:00:00+00', '2026-11-20 20:00:00+00'),
  ('78600000-0000-4000-8000-000000000102', '78600000-0000-4000-8000-000000000100', 'aberta', null, null, '2026-11-20 14:00:00+00', '2026-11-20 20:00:00+00')
on conflict (id) do nothing;

insert into public.candidatura (id, posicao_id, profissional_id, estado, criada_em)
values (
  '78600000-0000-4000-8000-000000000201',
  '78600000-0000-4000-8000-000000000102',
  '78600000-0000-4000-8000-000000000030',
  'pendente',
  '2026-11-19 12:00:00+00'
) on conflict (id) do nothing;

insert into public.turno (
  id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
  checkout_em, checkout_distancia_m, verificacao, valor_acordado_centavos
)
values (
  '78600000-0000-4000-8000-000000000301',
  '78600000-0000-4000-8000-000000000101',
  '2026-11-20 14:00:00+00',
  'geolocalizado',
  50,
  '2026-11-20 20:00:00+00',
  50,
  'verificado',
  15000
) on conflict (id) do nothing;

-- 4. Motor de Execucao e Prova de Autorizacao com Reversao Automatica (SUCES)
create or replace function pg_temp.testar_autorizacao(
  p_papel text,
  p_uid uuid,
  p_sql text
) returns text language plpgsql as $$
declare
  v_res text;
begin
  if p_papel = 'anon' then
    execute 'set local role anon';
    execute 'set local "request.jwt.claims" = ''{"role": "anon"}''';
    begin
      execute p_sql;
      raise exception using errcode = 'SUCES';
    exception
      when sqlstate 'SUCES' then
        v_res := 'AUTORIZADO';
      when insufficient_privilege then
        v_res := '42501_SEM_EXECUTE';
      when sqlstate 'PGRST' then
        v_res := 'PGRST:' || coalesce(SQLERRM::jsonb ->> 'code', SQLERRM);
      when others then
        v_res := SQLSTATE || ':' || SQLERRM;
    end;
    reset role;
    execute 'reset "request.jwt.claims"';
    return v_res;
  else
    execute 'set local role authenticated';
    execute format('set local "request.jwt.claims" = %L',
                   json_build_object('sub', p_uid::text, 'role', 'authenticated')::text);
    execute format('set local "request.jwt.claim.sub" = %L', p_uid::text);
    begin
      execute p_sql;
      raise exception using errcode = 'SUCES';
    exception
      when sqlstate 'SUCES' then
        v_res := 'AUTORIZADO';
      when sqlstate 'PGRST' then
        declare
          v_code text := SQLERRM::jsonb ->> 'code';
        begin
          if v_code = 'perfil_incompativel' then
            v_res := '403_PERFIL_INCOMPATIVEL';
          elsif v_code = 'sem_permissao' then
            v_res := '403_SEM_PERMISSAO';
          elsif v_code = 'nao_encontrado' then
            v_res := '404_NAO_ENCONTRADO';
          else
            v_res := 'AUTORIZADO';
          end if;
        exception when others then
          v_res := 'PGRST:' || SQLERRM;
        end;
      when insufficient_privilege then
        v_res := '42501_SEM_EXECUTE';
      when others then
        v_res := SQLSTATE || ':' || SQLERRM;
    end;
    reset role;
    execute 'reset "request.jwt.claims"';
    execute 'reset "request.jwt.claim.sub"';
    return v_res;
  end if;
end;
$$;

-- ============================================================================
-- 5. Execucao Exaustiva da Matriz Papel x RPC (44 RPCs x 4 Papeis)
-- ============================================================================

-- --- configuracao_do_app ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.configuracao_do_app(''ios'')'), 'AUTORIZADO', 'configuracao_do_app [anon]: anon acessa configuracao_do_app livremente');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.configuracao_do_app(''ios'')'), 'AUTORIZADO', 'configuracao_do_app [profissional]: profissional acessa configuracao_do_app');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.configuracao_do_app(''ios'')'), 'AUTORIZADO', 'configuracao_do_app [outro contratante]: outro contratante acessa configuracao_do_app');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.configuracao_do_app(''ios'')'), 'AUTORIZADO', 'configuracao_do_app [dono]: dono acessa configuracao_do_app');

-- --- criar_conta ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.criar_conta(''profissional''::public.perfil_conta, ''Nome'', ''+5561999999999'', ''1990-01-01''::date, ''1.0'', ''maior_18'')'), '42501_SEM_EXECUTE', 'criar_conta [anon]: anon nao possui EXECUTE em criar_conta');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.criar_conta(''profissional''::public.perfil_conta, ''Nome'', ''+5561999999999'', ''1990-01-01''::date, ''1.0'', ''maior_18'')'), 'AUTORIZADO', 'criar_conta [profissional]: profissional autenticado pode invocar criar_conta');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.criar_conta(''profissional''::public.perfil_conta, ''Nome'', ''+5561999999999'', ''1990-01-01''::date, ''1.0'', ''maior_18'')'), 'AUTORIZADO', 'criar_conta [outro contratante]: outro contratante pode invocar criar_conta');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.criar_conta(''profissional''::public.perfil_conta, ''Nome'', ''+5561999999999'', ''1990-01-01''::date, ''1.0'', ''maior_18'')'), 'AUTORIZADO', 'criar_conta [dono]: dono pode invocar criar_conta');

-- --- minha_conta ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.minha_conta()'), '42501_SEM_EXECUTE', 'minha_conta [anon]: anon nao possui EXECUTE em minha_conta');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.minha_conta()'), 'AUTORIZADO', 'minha_conta [profissional]: profissional le os dados da propria conta');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.minha_conta()'), 'AUTORIZADO', 'minha_conta [outro contratante]: outro contratante le os dados da propria conta');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.minha_conta()'), 'AUTORIZADO', 'minha_conta [dono]: dono le os dados da propria conta');

-- --- situacao_da_conta ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.situacao_da_conta()'), '42501_SEM_EXECUTE', 'situacao_da_conta [anon]: anon nao possui EXECUTE em situacao_da_conta');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.situacao_da_conta()'), 'AUTORIZADO', 'situacao_da_conta [profissional]: profissional consulta situacao da conta');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.situacao_da_conta()'), 'AUTORIZADO', 'situacao_da_conta [outro contratante]: outro contratante consulta situacao da conta');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.situacao_da_conta()'), 'AUTORIZADO', 'situacao_da_conta [dono]: dono consulta situacao da conta');

-- --- contestar_suspensao ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.contestar_suspensao(''Relato detalhado com mais de dez caracteres'')'), '42501_SEM_EXECUTE', 'contestar_suspensao [anon]: anon nao possui EXECUTE em contestar_suspensao');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.contestar_suspensao(''Relato detalhado com mais de dez caracteres'')'), 'AUTORIZADO', 'contestar_suspensao [profissional]: profissional tem acesso a RPC de contestar_suspensao');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.contestar_suspensao(''Relato detalhado com mais de dez caracteres'')'), 'AUTORIZADO', 'contestar_suspensao [outro contratante]: outro contratante tem acesso a RPC de contestar_suspensao');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.contestar_suspensao(''Relato detalhado com mais de dez caracteres'')'), 'AUTORIZADO', 'contestar_suspensao [dono]: dono tem acesso a RPC de contestar_suspensao');

-- --- registrar_dispositivo ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.registrar_dispositivo(''token_fcm_valido_com_mais_de_vinte_caracteres'', ''ios'')'), '42501_SEM_EXECUTE', 'registrar_dispositivo [anon]: anon nao possui EXECUTE em registrar_dispositivo');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.registrar_dispositivo(''token_fcm_valido_com_mais_de_vinte_caracteres'', ''ios'')'), 'AUTORIZADO', 'registrar_dispositivo [profissional]: profissional registra dispositivo push');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.registrar_dispositivo(''token_fcm_valido_com_mais_de_vinte_caracteres'', ''ios'')'), 'AUTORIZADO', 'registrar_dispositivo [outro contratante]: outro contratante registra dispositivo push');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.registrar_dispositivo(''token_fcm_valido_com_mais_de_vinte_caracteres'', ''ios'')'), 'AUTORIZADO', 'registrar_dispositivo [dono]: dono registra dispositivo push');

-- --- remover_dispositivo ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.remover_dispositivo(''token_fcm_valido_com_mais_de_vinte_caracteres'')'), '42501_SEM_EXECUTE', 'remover_dispositivo [anon]: anon nao possui EXECUTE em remover_dispositivo');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.remover_dispositivo(''token_fcm_valido_com_mais_de_vinte_caracteres'')'), 'AUTORIZADO', 'remover_dispositivo [profissional]: profissional remove dispositivo push');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.remover_dispositivo(''token_fcm_valido_com_mais_de_vinte_caracteres'')'), 'AUTORIZADO', 'remover_dispositivo [outro contratante]: outro contratante remove dispositivo push');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.remover_dispositivo(''token_fcm_valido_com_mais_de_vinte_caracteres'')'), 'AUTORIZADO', 'remover_dispositivo [dono]: dono remove dispositivo push');

-- --- registrar_evento ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.registrar_evento(''app_aberto'', null, null, null)'), '42501_SEM_EXECUTE', 'registrar_evento [anon]: anon nao possui EXECUTE em registrar_evento');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.registrar_evento(''app_aberto'', null, null, null)'), 'AUTORIZADO', 'registrar_evento [profissional]: profissional registra evento de telemetria');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.registrar_evento(''app_aberto'', null, null, null)'), 'AUTORIZADO', 'registrar_evento [outro contratante]: outro contratante registra evento de telemetria');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.registrar_evento(''app_aberto'', null, null, null)'), 'AUTORIZADO', 'registrar_evento [dono]: dono registra evento de telemetria');

-- --- perfil_publico ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.perfil_publico(''78600000-0000-4000-8000-000000000030''::uuid)'), '42501_SEM_EXECUTE', 'perfil_publico [anon]: anon nao possui EXECUTE em perfil_publico');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.perfil_publico(''78600000-0000-4000-8000-000000000030''::uuid)'), 'AUTORIZADO', 'perfil_publico [profissional]: profissional consulta perfil publico');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.perfil_publico(''78600000-0000-4000-8000-000000000030''::uuid)'), 'AUTORIZADO', 'perfil_publico [outro contratante]: outro contratante consulta perfil publico');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.perfil_publico(''78600000-0000-4000-8000-000000000030''::uuid)'), 'AUTORIZADO', 'perfil_publico [dono]: dono consulta perfil publico');

-- --- bloquear ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.bloquear(''profissional'', ''78600000-0000-4000-8000-000000000040''::uuid)'), '42501_SEM_EXECUTE', 'bloquear [anon]: anon nao possui EXECUTE em bloquear');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.bloquear(''estabelecimento'', ''78600000-0000-4000-8000-000000000020''::uuid)'), 'AUTORIZADO', 'bloquear [profissional]: profissional bloqueia estabelecimento');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.bloquear(''profissional'', ''78600000-0000-4000-8000-000000000040''::uuid)'), 'AUTORIZADO', 'bloquear [outro contratante]: outro contratante bloqueia profissional');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.bloquear(''profissional'', ''78600000-0000-4000-8000-000000000040''::uuid)'), 'AUTORIZADO', 'bloquear [dono]: dono bloqueia profissional');

-- --- denunciar ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.denunciar(''profissional'', ''78600000-0000-4000-8000-000000000040''::uuid, ''assedio'', ''Relato valido com mais de dez caracteres'', gen_random_uuid(), null)'), '42501_SEM_EXECUTE', 'denunciar [anon]: anon nao possui EXECUTE em denunciar');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.denunciar(''estabelecimento'', ''78600000-0000-4000-8000-000000000020''::uuid, ''assedio'', ''Relato valido com mais de dez caracteres'', gen_random_uuid(), null)'), 'AUTORIZADO', 'denunciar [profissional]: profissional denuncia estabelecimento');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.denunciar(''profissional'', ''78600000-0000-4000-8000-000000000040''::uuid, ''assedio'', ''Relato valido com mais de dez caracteres'', gen_random_uuid(), null)'), 'AUTORIZADO', 'denunciar [outro contratante]: outro contratante denuncia profissional');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.denunciar(''profissional'', ''78600000-0000-4000-8000-000000000040''::uuid, ''assedio'', ''Relato valido com mais de dez caracteres'', gen_random_uuid(), null)'), 'AUTORIZADO', 'denunciar [dono]: dono denuncia profissional');

-- --- criar_perfil_profissional ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.criar_perfil_profissional(array[(select id from public.funcao where nome = ''garçom'' limit 1)], ''{"latitude": -15.79, "longitude": -47.88}''::jsonb, ''[]''::jsonb)'), '42501_SEM_EXECUTE', 'criar_perfil_profissional [anon]: anon nao possui EXECUTE em criar_perfil_profissional');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.criar_perfil_profissional(array[(select id from public.funcao where nome = ''garçom'' limit 1)], ''{"latitude": -15.79, "longitude": -47.88}''::jsonb, ''[]''::jsonb)'), 'AUTORIZADO', 'criar_perfil_profissional [profissional]: profissional tem autorizacao para criar_perfil_profissional');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.criar_perfil_profissional(array[(select id from public.funcao where nome = ''garçom'' limit 1)], ''{"latitude": -15.79, "longitude": -47.88}''::jsonb, ''[]''::jsonb)'), '403_PERFIL_INCOMPATIVEL', 'criar_perfil_profissional [outro contratante]: outro contratante toma 403 perfil_incompativel em criar_perfil_profissional');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.criar_perfil_profissional(array[(select id from public.funcao where nome = ''garçom'' limit 1)], ''{"latitude": -15.79, "longitude": -47.88}''::jsonb, ''[]''::jsonb)'), '403_PERFIL_INCOMPATIVEL', 'criar_perfil_profissional [dono]: dono toma 403 perfil_incompativel em criar_perfil_profissional');

-- --- meu_perfil_profissional ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.meu_perfil_profissional()'), '42501_SEM_EXECUTE', 'meu_perfil_profissional [anon]: anon nao possui EXECUTE em meu_perfil_profissional');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.meu_perfil_profissional()'), 'AUTORIZADO', 'meu_perfil_profissional [profissional]: profissional consulta meu_perfil_profissional');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.meu_perfil_profissional()'), '404_NAO_ENCONTRADO', 'meu_perfil_profissional [outro contratante]: outro contratante sem perfil profissional toma 404');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.meu_perfil_profissional()'), '404_NAO_ENCONTRADO', 'meu_perfil_profissional [dono]: dono sem perfil profissional toma 404');

-- --- atualizar_perfil_profissional ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.atualizar_perfil_profissional(null, ''{"latitude": -15.79, "longitude": -47.88}''::jsonb, null)'), '42501_SEM_EXECUTE', 'atualizar_perfil_profissional [anon]: anon nao possui EXECUTE em atualizar_perfil_profissional');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.atualizar_perfil_profissional(null, ''{"latitude": -15.79, "longitude": -47.88}''::jsonb, null)'), 'AUTORIZADO', 'atualizar_perfil_profissional [profissional]: profissional atualiza proprio perfil');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.atualizar_perfil_profissional(null, ''{"latitude": -15.79, "longitude": -47.88}''::jsonb, null)'), '403_PERFIL_INCOMPATIVEL', 'atualizar_perfil_profissional [outro contratante]: outro contratante toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.atualizar_perfil_profissional(null, ''{"latitude": -15.79, "longitude": -47.88}''::jsonb, null)'), '403_PERFIL_INCOMPATIVEL', 'atualizar_perfil_profissional [dono]: dono toma 403 perfil_incompativel');

-- --- criterios_de_notificacao ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.criterios_de_notificacao()'), '42501_SEM_EXECUTE', 'criterios_de_notificacao [anon]: anon nao possui EXECUTE em criterios_de_notificacao');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.criterios_de_notificacao()'), 'AUTORIZADO', 'criterios_de_notificacao [profissional]: profissional consulta criterios_de_notificacao');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.criterios_de_notificacao()'), '403_PERFIL_INCOMPATIVEL', 'criterios_de_notificacao [outro contratante]: outro contratante toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.criterios_de_notificacao()'), '403_PERFIL_INCOMPATIVEL', 'criterios_de_notificacao [dono]: dono toma 403 perfil_incompativel');

-- --- pedir_revisao_despacho ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.pedir_revisao_despacho(''Relato de contestacao de despacho com mais de dez letras'')'), '42501_SEM_EXECUTE', 'pedir_revisao_despacho [anon]: anon nao possui EXECUTE em pedir_revisao_despacho');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.pedir_revisao_despacho(''Relato de contestacao de despacho com mais de dez letras'')'), 'AUTORIZADO', 'pedir_revisao_despacho [profissional]: profissional pede revisao de despacho');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.pedir_revisao_despacho(''Relato de contestacao de despacho com mais de dez letras'')'), '403_PERFIL_INCOMPATIVEL', 'pedir_revisao_despacho [outro contratante]: outro contratante toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.pedir_revisao_despacho(''Relato de contestacao de despacho com mais de dez letras'')'), '403_PERFIL_INCOMPATIVEL', 'pedir_revisao_despacho [dono]: dono toma 403 perfil_incompativel');

-- --- vagas_abertas ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.vagas_abertas(-15.79, -47.88, null, null, null, 10, 0)'), '42501_SEM_EXECUTE', 'vagas_abertas [anon]: anon nao possui EXECUTE em vagas_abertas');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.vagas_abertas(-15.79, -47.88, null, null, null, 10, 0)'), 'AUTORIZADO', 'vagas_abertas [profissional]: profissional consulta vagas_abertas');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.vagas_abertas(-15.79, -47.88, null, null, null, 10, 0)'), '403_PERFIL_INCOMPATIVEL', 'vagas_abertas [outro contratante]: outro contratante toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.vagas_abertas(-15.79, -47.88, null, null, null, 10, 0)'), '403_PERFIL_INCOMPATIVEL', 'vagas_abertas [dono]: dono toma 403 perfil_incompativel');

-- --- detalhe_vaga ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.detalhe_vaga(''78600000-0000-4000-8000-000000000100''::uuid)'), '42501_SEM_EXECUTE', 'detalhe_vaga [anon]: anon nao possui EXECUTE em detalhe_vaga');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.detalhe_vaga(''78600000-0000-4000-8000-000000000100''::uuid)'), 'AUTORIZADO', 'detalhe_vaga [profissional]: profissional consulta detalhe_vaga');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.detalhe_vaga(''78600000-0000-4000-8000-000000000100''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'detalhe_vaga [outro contratante]: outro contratante toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.detalhe_vaga(''78600000-0000-4000-8000-000000000100''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'detalhe_vaga [dono]: dono toma 403 perfil_incompativel');

-- --- candidatar ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.candidatar(''78600000-0000-4000-8000-000000000100''::uuid)'), '42501_SEM_EXECUTE', 'candidatar [anon]: anon nao possui EXECUTE em candidatar');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.candidatar(''78600000-0000-4000-8000-000000000100''::uuid)'), 'AUTORIZADO', 'candidatar [profissional]: profissional se candidata a vaga');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.candidatar(''78600000-0000-4000-8000-000000000100''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'candidatar [outro contratante]: outro contratante toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.candidatar(''78600000-0000-4000-8000-000000000100''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'candidatar [dono]: dono toma 403 perfil_incompativel');

-- --- retirar_candidatura ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.retirar_candidatura(''78600000-0000-4000-8000-000000000201''::uuid)'), '42501_SEM_EXECUTE', 'retirar_candidatura [anon]: anon nao possui EXECUTE em retirar_candidatura');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.retirar_candidatura(''78600000-0000-4000-8000-000000000201''::uuid)'), 'AUTORIZADO', 'retirar_candidatura [profissional]: profissional retira a propria candidatura');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.retirar_candidatura(''78600000-0000-4000-8000-000000000201''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'retirar_candidatura [outro contratante]: outro contratante toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.retirar_candidatura(''78600000-0000-4000-8000-000000000201''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'retirar_candidatura [dono]: dono toma 403 perfil_incompativel');

-- --- minhas_candidaturas ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.minhas_candidaturas(null)'), '42501_SEM_EXECUTE', 'minhas_candidaturas [anon]: anon nao possui EXECUTE em minhas_candidaturas');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.minhas_candidaturas(null)'), 'AUTORIZADO', 'minhas_candidaturas [profissional]: profissional lista suas candidaturas');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.minhas_candidaturas(null)'), '403_PERFIL_INCOMPATIVEL', 'minhas_candidaturas [outro contratante]: outro contratante toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.minhas_candidaturas(null)'), '403_PERFIL_INCOMPATIVEL', 'minhas_candidaturas [dono]: dono toma 403 perfil_incompativel');

-- --- avisar_a_caminho ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.avisar_a_caminho(''78600000-0000-4000-8000-000000000301''::uuid)'), '42501_SEM_EXECUTE', 'avisar_a_caminho [anon]: anon nao possui EXECUTE em avisar_a_caminho');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.avisar_a_caminho(''78600000-0000-4000-8000-000000000301''::uuid)'), 'AUTORIZADO', 'avisar_a_caminho [profissional]: profissional tem autorizacao para avisar_a_caminho');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.avisar_a_caminho(''78600000-0000-4000-8000-000000000301''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'avisar_a_caminho [outro contratante]: outro contratante toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.avisar_a_caminho(''78600000-0000-4000-8000-000000000301''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'avisar_a_caminho [dono]: dono toma 403 perfil_incompativel');

-- --- fazer_checkin ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.fazer_checkin(''78600000-0000-4000-8000-000000000301''::uuid, 10, ''2026-11-20 14:05:00+00''::timestamptz)'), '42501_SEM_EXECUTE', 'fazer_checkin [anon]: anon nao possui EXECUTE em fazer_checkin');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.fazer_checkin(''78600000-0000-4000-8000-000000000301''::uuid, 10, ''2026-11-20 14:05:00+00''::timestamptz)'), 'AUTORIZADO', 'fazer_checkin [profissional]: profissional tem autorizacao para fazer_checkin');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.fazer_checkin(''78600000-0000-4000-8000-000000000301''::uuid, 10, ''2026-11-20 14:05:00+00''::timestamptz)'), '403_PERFIL_INCOMPATIVEL', 'fazer_checkin [outro contratante]: outro contratante toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.fazer_checkin(''78600000-0000-4000-8000-000000000301''::uuid, 10, ''2026-11-20 14:05:00+00''::timestamptz)'), '403_PERFIL_INCOMPATIVEL', 'fazer_checkin [dono]: dono toma 403 perfil_incompativel');

-- --- fazer_checkout ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.fazer_checkout(''78600000-0000-4000-8000-000000000301''::uuid, 10, ''2026-11-20 20:05:00+00''::timestamptz)'), '42501_SEM_EXECUTE', 'fazer_checkout [anon]: anon nao possui EXECUTE em fazer_checkout');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.fazer_checkout(''78600000-0000-4000-8000-000000000301''::uuid, 10, ''2026-11-20 20:05:00+00''::timestamptz)'), 'AUTORIZADO', 'fazer_checkout [profissional]: profissional tem autorizacao para fazer_checkout');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.fazer_checkout(''78600000-0000-4000-8000-000000000301''::uuid, 10, ''2026-11-20 20:05:00+00''::timestamptz)'), '403_PERFIL_INCOMPATIVEL', 'fazer_checkout [outro contratante]: outro contratante toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.fazer_checkout(''78600000-0000-4000-8000-000000000301''::uuid, 10, ''2026-11-20 20:05:00+00''::timestamptz)'), '403_PERFIL_INCOMPATIVEL', 'fazer_checkout [dono]: dono toma 403 perfil_incompativel');

-- --- cadastrar_estabelecimento ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.cadastrar_estabelecimento(''Bar Novo'', ''11222333000181'', ''food_service''::public.tipo_estabelecimento, ''Rua 1'', ''{"latitude": -15.79, "longitude": -47.88}''::jsonb, ''Plano Piloto'')'), '42501_SEM_EXECUTE', 'cadastrar_estabelecimento [anon]: anon nao possui EXECUTE em cadastrar_estabelecimento');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.cadastrar_estabelecimento(''Bar Novo'', ''11222333000181'', ''food_service''::public.tipo_estabelecimento, ''Rua 1'', ''{"latitude": -15.79, "longitude": -47.88}''::jsonb, ''Plano Piloto'')'), '403_PERFIL_INCOMPATIVEL', 'cadastrar_estabelecimento [profissional]: profissional toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.cadastrar_estabelecimento(''Bar Novo'', ''11222333000181'', ''food_service''::public.tipo_estabelecimento, ''Rua 1'', ''{"latitude": -15.79, "longitude": -47.88}''::jsonb, ''Plano Piloto'')'), 'AUTORIZADO', 'cadastrar_estabelecimento [outro contratante]: outro contratante cadastra estabelecimento com sucesso');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.cadastrar_estabelecimento(''Bar Novo'', ''11222333000181'', ''food_service''::public.tipo_estabelecimento, ''Rua 1'', ''{"latitude": -15.79, "longitude": -47.88}''::jsonb, ''Plano Piloto'')'), 'AUTORIZADO', 'cadastrar_estabelecimento [dono]: dono cadastra estabelecimento com sucesso');

-- --- meus_estabelecimentos ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.meus_estabelecimentos()'), '42501_SEM_EXECUTE', 'meus_estabelecimentos [anon]: anon nao possui EXECUTE em meus_estabelecimentos');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.meus_estabelecimentos()'), '403_PERFIL_INCOMPATIVEL', 'meus_estabelecimentos [profissional]: profissional toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.meus_estabelecimentos()'), 'AUTORIZADO', 'meus_estabelecimentos [outro contratante]: outro contratante lista seus estabelecimentos');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.meus_estabelecimentos()'), 'AUTORIZADO', 'meus_estabelecimentos [dono]: dono lista seus estabelecimentos');

-- --- publicar_vaga ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.publicar_vaga(''78600000-0000-4000-8000-000000000010''::uuid, (select id from public.funcao where nome = ''garçom'' limit 1), ''2026-11-21 14:00:00+00''::timestamptz, ''2026-11-21 20:00:00+00''::timestamptz, ''Local''::text, ''{"latitude": -15.7942, "longitude": -47.8825}''::jsonb, 15000, 1, false, false, false, ''Chefe''::text, ''urgencia''::public.modo_preenchimento, gen_random_uuid(), null, false, null, 120, ''Plano Piloto''::text)'), '42501_SEM_EXECUTE', 'publicar_vaga [anon]: anon nao possui EXECUTE em publicar_vaga');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.publicar_vaga(''78600000-0000-4000-8000-000000000010''::uuid, (select id from public.funcao where nome = ''garçom'' limit 1), ''2026-11-21 14:00:00+00''::timestamptz, ''2026-11-21 20:00:00+00''::timestamptz, ''Local''::text, ''{"latitude": -15.7942, "longitude": -47.8825}''::jsonb, 15000, 1, false, false, false, ''Chefe''::text, ''urgencia''::public.modo_preenchimento, gen_random_uuid(), null, false, null, 120, ''Plano Piloto''::text)'), '403_PERFIL_INCOMPATIVEL', 'publicar_vaga [profissional]: profissional toma 403 perfil_incompativel em publicar_vaga');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.publicar_vaga(''78600000-0000-4000-8000-000000000010''::uuid, (select id from public.funcao where nome = ''garçom'' limit 1), ''2026-11-21 14:00:00+00''::timestamptz, ''2026-11-21 20:00:00+00''::timestamptz, ''Local''::text, ''{"latitude": -15.7942, "longitude": -47.8825}''::jsonb, 15000, 1, false, false, false, ''Chefe''::text, ''urgencia''::public.modo_preenchimento, gen_random_uuid(), null, false, null, 120, ''Plano Piloto''::text)'), '403_SEM_PERMISSAO', 'publicar_vaga [outro contratante]: outro contratante toma 403 sem_permissao em est alheio');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.publicar_vaga(''78600000-0000-4000-8000-000000000010''::uuid, (select id from public.funcao where nome = ''garçom'' limit 1), ''2026-11-21 14:00:00+00''::timestamptz, ''2026-11-21 20:00:00+00''::timestamptz, ''Local''::text, ''{"latitude": -15.7942, "longitude": -47.8825}''::jsonb, 15000, 1, false, false, false, ''Chefe''::text, ''urgencia''::public.modo_preenchimento, gen_random_uuid(), null, false, null, 120, ''Plano Piloto''::text)'), 'AUTORIZADO', 'publicar_vaga [dono]: dono publica vaga no proprio estabelecimento');

-- --- cancelar_vaga ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.cancelar_vaga(''78600000-0000-4000-8000-000000000100''::uuid, ''Motivo de cancelamento'')'), '42501_SEM_EXECUTE', 'cancelar_vaga [anon]: anon nao possui EXECUTE em cancelar_vaga');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.cancelar_vaga(''78600000-0000-4000-8000-000000000100''::uuid, ''Motivo de cancelamento'')'), '403_PERFIL_INCOMPATIVEL', 'cancelar_vaga [profissional]: profissional toma 403 perfil_incompativel em cancelar_vaga');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.cancelar_vaga(''78600000-0000-4000-8000-000000000100''::uuid, ''Motivo de cancelamento'')'), '404_NAO_ENCONTRADO', 'cancelar_vaga [outro contratante]: outro contratante toma 404 nao_encontrado em vaga alheia');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.cancelar_vaga(''78600000-0000-4000-8000-000000000100''::uuid, ''Motivo de cancelamento'')'), 'AUTORIZADO', 'cancelar_vaga [dono]: dono cancela a propria vaga');

-- --- republicar_vaga ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.republicar_vaga(''78600000-0000-4000-8000-000000000100''::uuid, ''2026-11-22 14:00:00+00''::timestamptz, ''2026-11-22 20:00:00+00''::timestamptz, gen_random_uuid())'), '42501_SEM_EXECUTE', 'republicar_vaga [anon]: anon nao possui EXECUTE em republicar_vaga');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.republicar_vaga(''78600000-0000-4000-8000-000000000100''::uuid, ''2026-11-22 14:00:00+00''::timestamptz, ''2026-11-22 20:00:00+00''::timestamptz, gen_random_uuid())'), '403_PERFIL_INCOMPATIVEL', 'republicar_vaga [profissional]: profissional toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.republicar_vaga(''78600000-0000-4000-8000-000000000100''::uuid, ''2026-11-22 14:00:00+00''::timestamptz, ''2026-11-22 20:00:00+00''::timestamptz, gen_random_uuid())'), '403_SEM_PERMISSAO', 'republicar_vaga [outro contratante]: outro contratante toma 403 sem_permissao em vaga alheia');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.republicar_vaga(''78600000-0000-4000-8000-000000000100''::uuid, ''2026-11-22 14:00:00+00''::timestamptz, ''2026-11-22 20:00:00+00''::timestamptz, gen_random_uuid())'), 'AUTORIZADO', 'republicar_vaga [dono]: dono republica vaga do proprio estabelecimento');

-- --- republicar_posicoes_restantes ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.republicar_posicoes_restantes(''78600000-0000-4000-8000-000000000100''::uuid, gen_random_uuid())'), '42501_SEM_EXECUTE', 'republicar_posicoes_restantes [anon]: anon nao possui EXECUTE em republicar_posicoes_restantes');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.republicar_posicoes_restantes(''78600000-0000-4000-8000-000000000100''::uuid, gen_random_uuid())'), '403_PERFIL_INCOMPATIVEL', 'republicar_posicoes_restantes [profissional]: profissional toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.republicar_posicoes_restantes(''78600000-0000-4000-8000-000000000100''::uuid, gen_random_uuid())'), '403_SEM_PERMISSAO', 'republicar_posicoes_restantes [outro contratante]: outro contratante toma 403 sem_permissao em vaga alheia');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.republicar_posicoes_restantes(''78600000-0000-4000-8000-000000000100''::uuid, gen_random_uuid())'), 'AUTORIZADO', 'republicar_posicoes_restantes [dono]: dono tem autorizacao para republicar posicoes restantes');

-- --- candidatos_da_vaga ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.candidatos_da_vaga(''78600000-0000-4000-8000-000000000100''::uuid)'), '42501_SEM_EXECUTE', 'candidatos_da_vaga [anon]: anon nao possui EXECUTE em candidatos_da_vaga');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.candidatos_da_vaga(''78600000-0000-4000-8000-000000000100''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'candidatos_da_vaga [profissional]: profissional toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.candidatos_da_vaga(''78600000-0000-4000-8000-000000000100''::uuid)'), '403_SEM_PERMISSAO', 'candidatos_da_vaga [outro contratante]: outro contratante toma 403 sem_permissao em vaga alheia');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.candidatos_da_vaga(''78600000-0000-4000-8000-000000000100''::uuid)'), 'AUTORIZADO', 'candidatos_da_vaga [dono]: dono visualiza candidatos da propria vaga');

-- --- escolher_candidato ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.escolher_candidato(''78600000-0000-4000-8000-000000000201''::uuid)'), '42501_SEM_EXECUTE', 'escolher_candidato [anon]: anon nao possui EXECUTE em escolher_candidato');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.escolher_candidato(''78600000-0000-4000-8000-000000000201''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'escolher_candidato [profissional]: profissional toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.escolher_candidato(''78600000-0000-4000-8000-000000000201''::uuid)'), '403_SEM_PERMISSAO', 'escolher_candidato [outro contratante]: outro contratante toma 403 sem_permissao em candidatura alheia');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.escolher_candidato(''78600000-0000-4000-8000-000000000201''::uuid)'), 'AUTORIZADO', 'escolher_candidato [dono]: dono escolhe candidato para sua vaga');

-- --- reabrir_por_atraso ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.reabrir_por_atraso(''78600000-0000-4000-8000-000000000101''::uuid)'), '42501_SEM_EXECUTE', 'reabrir_por_atraso [anon]: anon nao possui EXECUTE em reabrir_por_atraso');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.reabrir_por_atraso(''78600000-0000-4000-8000-000000000101''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'reabrir_por_atraso [profissional]: profissional toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.reabrir_por_atraso(''78600000-0000-4000-8000-000000000101''::uuid)'), '403_SEM_PERMISSAO', 'reabrir_por_atraso [outro contratante]: outro contratante toma 403 sem_permissao em posicao alheia');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.reabrir_por_atraso(''78600000-0000-4000-8000-000000000101''::uuid)'), 'AUTORIZADO', 'reabrir_por_atraso [dono]: dono tem autorizacao para reabrir por atraso');

-- --- incluir_na_equipe ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.incluir_na_equipe(''78600000-0000-4000-8000-000000000010''::uuid, ''78600000-0000-4000-8000-000000000030''::uuid)'), '42501_SEM_EXECUTE', 'incluir_na_equipe [anon]: anon nao possui EXECUTE em incluir_na_equipe');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.incluir_na_equipe(''78600000-0000-4000-8000-000000000010''::uuid, ''78600000-0000-4000-8000-000000000030''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'incluir_na_equipe [profissional]: profissional toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.incluir_na_equipe(''78600000-0000-4000-8000-000000000010''::uuid, ''78600000-0000-4000-8000-000000000030''::uuid)'), '403_SEM_PERMISSAO', 'incluir_na_equipe [outro contratante]: outro contratante toma 403 sem_permissao em est alheio');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.incluir_na_equipe(''78600000-0000-4000-8000-000000000010''::uuid, ''78600000-0000-4000-8000-000000000030''::uuid)'), 'AUTORIZADO', 'incluir_na_equipe [dono]: dono inclui profissional em sua equipe');

-- --- remover_da_equipe ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.remover_da_equipe(''78600000-0000-4000-8000-000000000010''::uuid, ''78600000-0000-4000-8000-000000000030''::uuid)'), '42501_SEM_EXECUTE', 'remover_da_equipe [anon]: anon nao possui EXECUTE em remover_da_equipe');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.remover_da_equipe(''78600000-0000-4000-8000-000000000010''::uuid, ''78600000-0000-4000-8000-000000000030''::uuid)'), '403_PERFIL_INCOMPATIVEL', 'remover_da_equipe [profissional]: profissional toma 403 perfil_incompativel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.remover_da_equipe(''78600000-0000-4000-8000-000000000010''::uuid, ''78600000-0000-4000-8000-000000000030''::uuid)'), '403_SEM_PERMISSAO', 'remover_da_equipe [outro contratante]: outro contratante toma 403 sem_permissao em est alheio');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.remover_da_equipe(''78600000-0000-4000-8000-000000000010''::uuid, ''78600000-0000-4000-8000-000000000030''::uuid)'), 'AUTORIZADO', 'remover_da_equipe [dono]: dono remove profissional de sua equipe');

-- --- meu_estabelecimento ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.meu_estabelecimento(''78600000-0000-4000-8000-000000000010''::uuid)'), '42501_SEM_EXECUTE', 'meu_estabelecimento [anon]: anon nao possui EXECUTE em meu_estabelecimento');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.meu_estabelecimento(''78600000-0000-4000-8000-000000000010''::uuid)'), '403_SEM_PERMISSAO', 'meu_estabelecimento [profissional]: profissional nao-membro toma 403 sem_permissao');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.meu_estabelecimento(''78600000-0000-4000-8000-000000000010''::uuid)'), '403_SEM_PERMISSAO', 'meu_estabelecimento [outro contratante]: outro contratante nao-membro toma 403 sem_permissao');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.meu_estabelecimento(''78600000-0000-4000-8000-000000000010''::uuid)'), 'AUTORIZADO', 'meu_estabelecimento [dono]: dono consulta dados completos de seu estabelecimento');

-- --- painel_estabelecimento ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.painel_estabelecimento(''78600000-0000-4000-8000-000000000010''::uuid, ''2026-11-01 00:00:00+00''::timestamptz, ''2026-11-30 23:59:59+00''::timestamptz)'), '42501_SEM_EXECUTE', 'painel_estabelecimento [anon]: anon nao possui EXECUTE em painel_estabelecimento');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.painel_estabelecimento(''78600000-0000-4000-8000-000000000010''::uuid, ''2026-11-01 00:00:00+00''::timestamptz, ''2026-11-30 23:59:59+00''::timestamptz)'), '403_SEM_PERMISSAO', 'painel_estabelecimento [profissional]: profissional toma 403 sem_permissao no painel');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.painel_estabelecimento(''78600000-0000-4000-8000-000000000010''::uuid, ''2026-11-01 00:00:00+00''::timestamptz, ''2026-11-30 23:59:59+00''::timestamptz)'), '403_SEM_PERMISSAO', 'painel_estabelecimento [outro contratante]: outro contratante toma 403 sem_permissao no painel alheio');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.painel_estabelecimento(''78600000-0000-4000-8000-000000000010''::uuid, ''2026-11-01 00:00:00+00''::timestamptz, ''2026-11-30 23:59:59+00''::timestamptz)'), 'AUTORIZADO', 'painel_estabelecimento [dono]: dono acessa painel operacional de seu estabelecimento');

-- --- equipe_de_confianca ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.equipe_de_confianca(''78600000-0000-4000-8000-000000000010''::uuid)'), '42501_SEM_EXECUTE', 'equipe_de_confianca [anon]: anon nao possui EXECUTE em equipe_de_confianca');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.equipe_de_confianca(''78600000-0000-4000-8000-000000000010''::uuid)'), '403_SEM_PERMISSAO', 'equipe_de_confianca [profissional]: profissional toma 403 sem_permissao na equipe do est');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.equipe_de_confianca(''78600000-0000-4000-8000-000000000010''::uuid)'), '403_SEM_PERMISSAO', 'equipe_de_confianca [outro contratante]: outro contratante toma 403 sem_permissao na equipe alheia');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.equipe_de_confianca(''78600000-0000-4000-8000-000000000010''::uuid)'), 'AUTORIZADO', 'equipe_de_confianca [dono]: dono consulta lista de profissionais da sua equipe');

-- --- confirmar_checkin_manual ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.confirmar_checkin_manual(''78600000-0000-4000-8000-000000000301''::uuid)'), '42501_SEM_EXECUTE', 'confirmar_checkin_manual [anon]: anon nao possui EXECUTE em confirmar_checkin_manual');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.confirmar_checkin_manual(''78600000-0000-4000-8000-000000000301''::uuid)'), '403_SEM_PERMISSAO', 'confirmar_checkin_manual [profissional]: profissional toma 403 ao tentar confirmar proprio checkin');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.confirmar_checkin_manual(''78600000-0000-4000-8000-000000000301''::uuid)'), '403_SEM_PERMISSAO', 'confirmar_checkin_manual [outro contratante]: outro contratante toma 403 sem_permissao em turno alheio');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.confirmar_checkin_manual(''78600000-0000-4000-8000-000000000301''::uuid)'), 'AUTORIZADO', 'confirmar_checkin_manual [dono]: dono tem autorizacao para confirmar checkin manual');

-- --- meus_turnos ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.meus_turnos(''2026-11-01 00:00:00+00''::timestamptz, ''2026-11-30 23:59:59+00''::timestamptz, null)'), '42501_SEM_EXECUTE', 'meus_turnos [anon]: anon nao possui EXECUTE em meus_turnos');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.meus_turnos(''2026-11-01 00:00:00+00''::timestamptz, ''2026-11-30 23:59:59+00''::timestamptz, null)'), 'AUTORIZADO', 'meus_turnos [profissional]: profissional consulta seus turnos');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.meus_turnos(''2026-11-01 00:00:00+00''::timestamptz, ''2026-11-30 23:59:59+00''::timestamptz, ''78600000-0000-4000-8000-000000000010''::uuid)'), '403_SEM_PERMISSAO', 'meus_turnos [outro contratante]: outro contratante toma 403 em estabelecimento alheio');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.meus_turnos(''2026-11-01 00:00:00+00''::timestamptz, ''2026-11-30 23:59:59+00''::timestamptz, ''78600000-0000-4000-8000-000000000010''::uuid)'), 'AUTORIZADO', 'meus_turnos [dono]: dono consulta turnos do seu estabelecimento');

-- --- contato_do_turno ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.contato_do_turno(''78600000-0000-4000-8000-000000000301''::uuid)'), '42501_SEM_EXECUTE', 'contato_do_turno [anon]: anon nao possui EXECUTE em contato_do_turno');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.contato_do_turno(''78600000-0000-4000-8000-000000000301''::uuid)'), 'AUTORIZADO', 'contato_do_turno [profissional]: profissional participante acessa contato do estabelecimento');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.contato_do_turno(''78600000-0000-4000-8000-000000000301''::uuid)'), '404_NAO_ENCONTRADO', 'contato_do_turno [outro contratante]: outro contratante nao participante toma 404');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.contato_do_turno(''78600000-0000-4000-8000-000000000301''::uuid)'), 'AUTORIZADO', 'contato_do_turno [dono]: dono acessa contato do profissional participante');

-- --- avaliar ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.avaliar(''78600000-0000-4000-8000-000000000301''::uuid, true)'), '42501_SEM_EXECUTE', 'avaliar [anon]: anon nao possui EXECUTE em avaliar');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.avaliar(''78600000-0000-4000-8000-000000000301''::uuid, true)'), 'AUTORIZADO', 'avaliar [profissional]: profissional participante avalia o turno');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.avaliar(''78600000-0000-4000-8000-000000000301''::uuid, true)'), '403_SEM_PERMISSAO', 'avaliar [outro contratante]: outro contratante nao participante toma 403');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.avaliar(''78600000-0000-4000-8000-000000000301''::uuid, true)'), 'AUTORIZADO', 'avaliar [dono]: dono avalia o profissional do turno');

-- --- cancelar_posicao ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.cancelar_posicao(''78600000-0000-4000-8000-000000000101''::uuid, ''Motivo de cancelamento'')'), '42501_SEM_EXECUTE', 'cancelar_posicao [anon]: anon nao possui EXECUTE em cancelar_posicao');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.cancelar_posicao(''78600000-0000-4000-8000-000000000101''::uuid, ''Motivo de cancelamento'')'), 'AUTORIZADO', 'cancelar_posicao [profissional]: profissional alocado cancela a propria posicao');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.cancelar_posicao(''78600000-0000-4000-8000-000000000101''::uuid, ''Motivo de cancelamento'')'), '404_NAO_ENCONTRADO', 'cancelar_posicao [outro contratante]: outro contratante toma 404 em posicao alheia');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.cancelar_posicao(''78600000-0000-4000-8000-000000000101''::uuid, ''Motivo de cancelamento'')'), 'AUTORIZADO', 'cancelar_posicao [dono]: dono da vaga cancela posicao do seu estabelecimento');

-- --- abrir_suporte ---
select is(pg_temp.testar_autorizacao('anon', null, 'select public.abrir_suporte(''78600000-0000-4000-8000-000000000301''::uuid, ''outro'', gen_random_uuid())'), '42501_SEM_EXECUTE', 'abrir_suporte [anon]: anon nao possui EXECUTE em abrir_suporte');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000003', 'select public.abrir_suporte(''78600000-0000-4000-8000-000000000301''::uuid, ''outro'', gen_random_uuid())'), 'AUTORIZADO', 'abrir_suporte [profissional]: profissional do turno abre suporte');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000002', 'select public.abrir_suporte(''78600000-0000-4000-8000-000000000301''::uuid, ''outro'', gen_random_uuid())'), '404_NAO_ENCONTRADO', 'abrir_suporte [outro contratante]: outro contratante toma 404 em turno alheio');
select is(pg_temp.testar_autorizacao('authenticated', '78600000-0000-4000-8000-000000000001', 'select public.abrir_suporte(''78600000-0000-4000-8000-000000000301''::uuid, ''outro'', gen_random_uuid())'), 'AUTORIZADO', 'abrir_suporte [dono]: dono abre suporte para turno do seu estabelecimento');

select * from finish();
rollback;
