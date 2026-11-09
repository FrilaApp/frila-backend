-- 820_chamar_profissional_valor_rn29.sql · RN29 na chamar_profissional (contrato 0.2.62, /rpc/chamar_profissional).
-- A recusa mora na RPC (20261107300000:149, redefinida em 20261107370000): valor_centavos <= 0 devolve
-- 422 campo_invalido com details valor_centavos. Sem este teste, tirar a linha não deixava nenhum teste vermelho:
-- o CHECK de public.vaga ainda barraria o valor, mas com 23514 cru no lugar do envelope do contrato.
-- Valor zero e negativo: recusa com sqlstate, status, code e details, sem gravar vaga, posição nem chamada.
-- Um centavo: aceito (controle). O controle reusa a chave da primeira recusa: se ela tivesse gravado a chamada,
-- a idempotência devolveria a chamada antiga, e não uma vaga nova de 1 centavo.
-- Casa CNPJ (sem a confirmação de recorrência da J7) e profissional da equipe de confiança (RN28).
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-07 15:00:00+00', true);
select plan(7);

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;
-- {"ok": true} ou o envelope inteiro de public.erro: sqlstate, status HTTP, code e details.
create function pg_temp.resultado(conta uuid, sql text) returns jsonb language plpgsql as $$
declare v_estado text; v_msg text; v_detalhe text;
begin
  perform pg_temp.como(conta, sql);
  return '{"ok": true}'::jsonb;
exception when others then
  get stacked diagnostics v_estado = returned_sqlstate, v_msg = message_text, v_detalhe = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  if v_msg !~ '^\s*\{' then return jsonb_build_object('sqlstate', v_estado, 'message', v_msg); end if;
  return jsonb_build_object('sqlstate', v_estado, 'status', (nullif(v_detalhe, '')::jsonb ->> 'status')::int,
                            'code', v_msg::jsonb ->> 'code', 'details', v_msg::jsonb ->> 'details');
end $$;
create function pg_temp.chamar(valor bigint, chave uuid default gen_random_uuid()) returns text language sql as $$
  select format($a$ select public.chamar_profissional(chave => %L, profissional_id => %L,
    estabelecimento_id => 'c8200000-0000-4000-8000-0000000000e1', funcao_id => %L,
    inicio_em => '2026-11-08 18:00+00', fim_em => '2026-11-08 23:00+00', local => 'CLN 201',
    regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}',
    valor_centavos => %s, inclui_refeicao => true, inclui_transporte => false,
    exige_material_proprio => false, responsavel_local => 'Maitre') $a$,
    chave, (select p.id from public.profissional p where p.usuario_id = 'c8200000-0000-4000-8000-000000000002'),
    (select f.id from public.funcao f where f.nome = 'garçom'), valor) $$;

insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', ('c8200000-0000-4000-8000-00000000000' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '@t820.test', privado.agora(), privado.agora(), false, false
  from generate_series(1, 2) n;
select pg_temp.como(('c8200000-0000-4000-8000-00000000000' || n)::uuid, format(
  $$ select public.criar_conta(%L, 'Pessoa %s', '+556195555820%s', '1990-01-01', '2026-09-22') $$,
  case when n = 1 then 'contratante' else 'profissional' end, n, n)) from generate_series(1, 2) n;
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c8200000-0000-4000-8000-0000000000e1', 'Casa 820', '82012345000101', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c8200000-0000-4000-8000-000000000001', 'c8200000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (usuario_id, ponto_base)
values ('c8200000-0000-4000-8000-000000000002', 'POINT(-47.8822 -15.7800)'::extensions.geography);
insert into public.profissional_funcao (profissional_id, funcao_id)
select p.id, (select f.id from public.funcao f where f.nome = 'garçom')
  from public.profissional p where p.usuario_id = 'c8200000-0000-4000-8000-000000000002';
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select 'c8200000-0000-4000-8000-0000000000e1', p.id
  from public.profissional p where p.usuario_id = 'c8200000-0000-4000-8000-000000000002';
update privado.recurso set ligado = true where chave = 'chamada_direta';
-- 0.2.66 (20261108160000): só se chama quem tem aparelho na versão mínima de chamada_direta.
-- Este arquivo mede a chamada com o portão satisfeito; o portão em si é o 830.
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do nothing;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select p.usuario_id, 'tok-teste-' || p.usuario_id, 'ios', '1.2.0'
  from public.profissional p where p.usuario_id::text like 'c8200000-%'
on conflict (token_fcm) do nothing;

-- ── RN29: zero e negativo são recusados com o envelope do contrato ───────────
select is(pg_temp.resultado('c8200000-0000-4000-8000-000000000001',
            pg_temp.chamar(0, 'c8200000-0000-4000-8000-0000000000c1')),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  'RN29: valor_centavos = 0 → 422 campo_invalido (valor_centavos)');
select is(pg_temp.resultado('c8200000-0000-4000-8000-000000000001', pg_temp.chamar(-1)),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  'RN29: valor_centavos = -1 → 422 campo_invalido (valor_centavos)');
select is(pg_temp.resultado('c8200000-0000-4000-8000-000000000001', pg_temp.chamar(-15000)),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  'RN29: valor_centavos = -15000 → 422 campo_invalido (valor_centavos)');
select results_eq($$
  select (select count(*)::int from public.vaga g where g.estabelecimento_id = 'c8200000-0000-4000-8000-0000000000e1'),
         (select count(*)::int from public.posicao p join public.vaga g on g.id = p.vaga_id
           where g.estabelecimento_id = 'c8200000-0000-4000-8000-0000000000e1'),
         (select count(*)::int from public.chamada c where c.estabelecimento_id = 'c8200000-0000-4000-8000-0000000000e1') $$,
  $$ values (0, 0, 0) $$,
  'RN29: a recusa não grava vaga, posição nem chamada');

-- ── Controle: 1 centavo passa, com a mesma chave da primeira recusa ──────────
select is(pg_temp.resultado('c8200000-0000-4000-8000-000000000001',
            pg_temp.chamar(1, 'c8200000-0000-4000-8000-0000000000c1')),
  '{"ok": true}'::jsonb,
  'controle: valor_centavos = 1 é aceito');
select results_eq($$
  select c.estado, g.valor_centavos, g.origem from public.chamada c join public.vaga g on g.id = c.vaga_id
   where c.estabelecimento_id = 'c8200000-0000-4000-8000-0000000000e1' $$,
  $$ values ('aberta'::text, 1::bigint, 'chamada_direta'::text) $$,
  'controle: uma chamada aberta, numa vaga direta de 1 centavo');
select is((select count(*)::int from public.chamada c where c.chave = 'c8200000-0000-4000-8000-0000000000c1'), 1,
  'controle: a chave da recusa não ficou gasta');

select * from finish();
rollback;
