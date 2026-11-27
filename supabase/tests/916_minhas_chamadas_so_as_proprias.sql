-- 916_minhas_chamadas_so_as_proprias.sql
--
-- minhas_chamadas lista só as chamadas de quem pergunta: o profissional vê as que recebeu (c.profissional_id), e a casa vê
-- as das casas de que é membro (me.usuario_id). Os testes do 809 só conferem que vem ao menos um item, então tirar um dos
-- dois filtros vazaria as chamadas das outras contas sem nenhum teste cair. Aqui são dois profissionais e duas casas, com
-- uma chamada de cada casa para cada lado, e cada conta tem de ver exatamente as suas: nem menos, nem as dos outros.
--
-- Chamadas: X -> A, Y -> B e Y -> A.
--   profissional A vê X->A e Y->A;  profissional B vê Y->B;
--   dono de X vê X->A;              dono de Y vê Y->B e Y->A.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_temp;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

insert into privado.recurso (chave, ligado) values ('chamada_direta', true)
on conflict (chave) do update set ligado = true;

select set_config('frila.agora', '2026-11-20 14:00:00-03', true);

select plan(8);

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', conta, 'role', 'authenticated')::text, true);
  execute sql into r;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return r;
end $$;

-- Os ids das chamadas que minhas_chamadas devolveu para a conta, em ordem: a comparação é do conjunto inteiro.
create function pg_temp.ids_vistos(conta uuid) returns text[] language sql as $$
  select coalesce(array_agg(item ->> 'id' order by item ->> 'id'), '{}')
    from jsonb_array_elements(pg_temp.como(conta, $q$select public.minhas_chamadas(limite => 20)$q$) -> 'itens') item
$$;

-- ── Contas ───────────────────────────────────────────────────────────────────────
insert into auth.users (id, aud, role, email) values
  ('91600000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'prof916_a@frila.test'),
  ('91600000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'prof916_b@frila.test'),
  ('91600000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'dono916_x@frila.test'),
  ('91600000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'dono916_y@frila.test');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('91600000-0000-4000-8000-000000000001', 'profissional', 'Profissional A', '+5561999916001', 'prof916_a@frila.test', '1995-05-10', 'ativa', '1.0', now()),
  ('91600000-0000-4000-8000-000000000002', 'profissional', 'Profissional B', '+5561999916002', 'prof916_b@frila.test', '1996-06-11', 'ativa', '1.0', now()),
  ('91600000-0000-4000-8000-000000000003', 'contratante', 'Dono da X', '+5561999916003', 'dono916_x@frila.test', '1988-03-03', 'ativa', '1.0', now()),
  ('91600000-0000-4000-8000-000000000004', 'contratante', 'Dono da Y', '+5561999916004', 'dono916_y@frila.test', '1982-04-04', 'ativa', '1.0', now());

insert into public.profissional (id, usuario_id, ponto_base) values
  ('91600000-0000-4000-8000-000000000011', '91600000-0000-4000-8000-000000000001', 'POINT(-47.8825 -15.7942)'::extensions.geography),
  ('91600000-0000-4000-8000-000000000012', '91600000-0000-4000-8000-000000000002', 'POINT(-47.8825 -15.7942)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('91600000-0000-4000-8000-000000000021', 'Casa X', '11222333000181', 'food_service', 'CLS 201 Bloco B', 'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('91600000-0000-4000-8000-000000000022', 'Casa Y', '11222333000262', 'food_service', 'CLS 202 Bloco C', 'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('91600000-0000-4000-8000-000000000021', '91600000-0000-4000-8000-000000000003', 'administrador'),
  ('91600000-0000-4000-8000-000000000022', '91600000-0000-4000-8000-000000000004', 'administrador');

-- ── Chamadas: X -> A, Y -> B, Y -> A ────────────────────────────────────────────────
create function pg_temp.chamar(chamada uuid, casa uuid, dono uuid, prof uuid) returns void language plpgsql as $$
declare v_vaga uuid;
begin
  insert into public.vaga (
    estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa, ponto,
    valor_centavos, posicoes, publicado_por, modo, origem, chave_cliente,
    inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local
  )
  select casa, f.id, '2026-11-21 18:00:00-03', '2026-11-21 23:00:00-03',
         'Local', 'Plano Piloto', 'POINT(-47.8825 -15.7942)'::extensions.geography, 15000, 1,
         dono, 'urgencia', 'chamada_direta', gen_random_uuid(),
         false, false, false, 'Responsável'
    from public.funcao f
   limit 1
  returning id into v_vaga;

  insert into public.chamada (id, vaga_id, profissional_id, estabelecimento_id, criada_por, expira_em, criada_em, chave)
  values (chamada, v_vaga, prof, casa, dono, '2026-11-20 20:00:00-03', '2026-11-20 13:00:00-03', gen_random_uuid());
end $$;

select pg_temp.chamar('91600000-0000-4000-8000-000000000031', '91600000-0000-4000-8000-000000000021',
                      '91600000-0000-4000-8000-000000000003', '91600000-0000-4000-8000-000000000011');
select pg_temp.chamar('91600000-0000-4000-8000-000000000032', '91600000-0000-4000-8000-000000000022',
                      '91600000-0000-4000-8000-000000000004', '91600000-0000-4000-8000-000000000012');
select pg_temp.chamar('91600000-0000-4000-8000-000000000033', '91600000-0000-4000-8000-000000000022',
                      '91600000-0000-4000-8000-000000000004', '91600000-0000-4000-8000-000000000011');

-- ── Profissional: só as chamadas que recebeu (c.profissional_id = v_prof_id) ───────────
select is(
  pg_temp.ids_vistos('91600000-0000-4000-8000-000000000001'),
  array['91600000-0000-4000-8000-000000000031', '91600000-0000-4000-8000-000000000033'],
  'profissional A vê exatamente as duas chamadas que recebeu, de casas diferentes'
);

select is(
  pg_temp.ids_vistos('91600000-0000-4000-8000-000000000002'),
  array['91600000-0000-4000-8000-000000000032'],
  'profissional B vê exatamente a sua chamada'
);

select ok(
  not ('91600000-0000-4000-8000-000000000032' = any (pg_temp.ids_vistos('91600000-0000-4000-8000-000000000001'))),
  'profissional A não vê a chamada feita para o profissional B'
);

select ok(
  not ('91600000-0000-4000-8000-000000000031' = any (pg_temp.ids_vistos('91600000-0000-4000-8000-000000000002'))),
  'profissional B não vê a chamada feita para o profissional A'
);

-- ── Casa: só as chamadas das casas de que é membro (me.usuario_id = v_uid) ─────────────
select is(
  pg_temp.ids_vistos('91600000-0000-4000-8000-000000000003'),
  array['91600000-0000-4000-8000-000000000031'],
  'dono da casa X vê exatamente a chamada da casa X'
);

select is(
  pg_temp.ids_vistos('91600000-0000-4000-8000-000000000004'),
  array['91600000-0000-4000-8000-000000000032', '91600000-0000-4000-8000-000000000033'],
  'dono da casa Y vê exatamente as duas chamadas da casa Y'
);

select ok(
  not ('91600000-0000-4000-8000-000000000033' = any (pg_temp.ids_vistos('91600000-0000-4000-8000-000000000003'))),
  'dono da casa X não vê a chamada que a casa Y fez para o mesmo profissional'
);

select ok(
  not ('91600000-0000-4000-8000-000000000031' = any (pg_temp.ids_vistos('91600000-0000-4000-8000-000000000004'))),
  'dono da casa Y não vê a chamada da casa X'
);

select * from finish();
rollback;
