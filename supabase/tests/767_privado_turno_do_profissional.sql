-- 767_privado_turno_do_profissional.sql
-- Cobertura direta de privado.turno_do_profissional(uuid): devolve a posição do turno SÓ para a
-- conta do profissional dono dela (auth.uid()). É a porta de check-in, check-out e "a caminho":
-- quem não é o profissional recebe a posição nula, e a RPC chamadora responde 404 sem vazar que o
-- turno existe (RN22).
--
-- Mutantes que estes testes matam (ver PR):
--   M1  remover a condição de auth.uid()              -> testes 4, 5 e 6 ficam vermelhos
--   M2  remover o filtro `t.id = turno`               -> testes 2 e 7 ficam vermelhos
--   M3  comparar com a conta do estabelecimento        -> testes 1, 2, 3 e 5 ficam vermelhos

begin;
select plan(7);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
-- Relógio fixo ANTES dos dados (docs/TESTES-PGTAP-PADROES.md, seção 3).
select set_config('frila.agora', '2026-10-20 12:00:00+00', true);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76700000-0000-4000-8000-0000000000a1', 'contratante',  'Dono 767', '+5561976700001', 'dono-767@t.test', '1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('76700000-0000-4000-8000-0000000000b1', 'profissional', 'Pro 767',  '+5561976700002', 'pro-767@t.test',  '1995-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('76700000-0000-4000-8000-0000000000e1', 'Casa 767', '76700000000001', 'food_service', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography);
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('76700000-0000-4000-8000-0000000000a1', '76700000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('76700000-0000-4000-8000-0000000000c1', '76700000-0000-4000-8000-0000000000b1',
   'POINT(-47.88 -15.79)'::extensions.geography);

-- Vaga com uma posição confirmada para o profissional e, opcionalmente, um turno.
-- Devolve o id do turno (ou o da posição, quando p_turno = 'nenhum').
create function pg_temp.montar(p_inicio timestamptz, p_fim timestamptz, p_turno text default 'verificado')
returns uuid language plpgsql as $$
declare v_vaga uuid; v_pos uuid; v_turno uuid;
begin
  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente,
                           publicado_por, publicado_em)
  values ('76700000-0000-4000-8000-0000000000e1', (select id from public.funcao order by nome limit 1),
          p_inicio, p_fim, 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1, true, false, false, 'Responsável', 'urgencia', gen_random_uuid(),
          '76700000-0000-4000-8000-0000000000a1', p_inicio - interval '1 day')
  returning id into v_vaga;
  insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_vaga, 'confirmada', '76700000-0000-4000-8000-0000000000c1', p_inicio - interval '12 hours', p_inicio, p_fim)
  returning id into v_pos;
  if p_turno = 'nenhum' then return v_pos; end if;
  if p_turno = 'verificado' then
    insert into public.turno (posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
    values (v_pos, p_inicio, 'geolocalizado', 50, 'verificado', 12000) returning id into v_turno;
  else
    insert into public.turno (posicao_id, valor_acordado_centavos)
    values (v_pos, 12000) returning id into v_turno;
  end if;
  return v_turno;
end $$;

-- Um segundo profissional, que NÃO é o do turno.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76700000-0000-4000-8000-0000000000b2', 'profissional', 'Pro dois 767', '+556197670003', 'pro2-767@t.test', '1994-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('76700000-0000-4000-8000-0000000000c2', '76700000-0000-4000-8000-0000000000b2', 'POINT(-47.88 -15.79)'::extensions.geography);

-- Dois turnos do mesmo profissional, para provar que o filtro é pelo turno pedido.
create temp table t as select
  pg_temp.montar('2026-10-21 10:00+00', '2026-10-21 14:00+00') as turno_a,
  pg_temp.montar('2026-10-22 10:00+00', '2026-10-22 14:00+00') as turno_b;

create function pg_temp.como(p_conta uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_conta, 'role', 'authenticated')::text, true)
$$;

-- 1. Caminho feliz: o profissional do turno recebe a posição do turno.
select pg_temp.como('76700000-0000-4000-8000-0000000000b1');
select is(
  (select (privado.turno_do_profissional(turno_a)).profissional_id from t),
  '76700000-0000-4000-8000-0000000000c1'::uuid,
  'o profissional do turno recebe a posição do turno');

-- 2. O turno pedido é o turno devolvido (e não outro do mesmo profissional).
select is(
  (select (privado.turno_do_profissional(turno_b)).inicio_em from t),
  '2026-10-22 10:00+00'::timestamptz,
  'devolve a posição do turno pedido, não de outro turno do mesmo profissional');

-- 3. Devolve a posição inteira (a RPC usa estado, vaga e janela).
select is(
  (select (privado.turno_do_profissional(turno_a)).estado::text from t),
  'confirmada', 'a posição devolvida traz o estado');

-- 4. Outro profissional: nada. A função devolve o tipo composto, e "nada" é o composto nulo
--    (o `id` nulo), não zero linhas — por isso a asserção é sobre `id`.
select pg_temp.como('76700000-0000-4000-8000-0000000000b2');
select is(
  (select (privado.turno_do_profissional(turno_a)).id from t),
  null::uuid, 'outro profissional recebe posição nula (nenhuma linha de posicao)');

-- 5. A casa dona da vaga também não passa por aqui: o check-in é só do profissional.
select pg_temp.como('76700000-0000-4000-8000-0000000000a1');
select is(
  (select (privado.turno_do_profissional(turno_a)).id from t),
  null::uuid, 'o dono do estabelecimento também recebe nada pela porta do profissional');

-- 6. Sem autenticação (sem claims): nada, sem erro.
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);
select is(
  (select (privado.turno_do_profissional(turno_a)).id from t),
  null::uuid, 'sem conta autenticada não há posição');

-- 7. Turno inexistente: nada, mesmo para quem seria o profissional.
select pg_temp.como('76700000-0000-4000-8000-0000000000b1');
select is(
  (privado.turno_do_profissional('76700000-0000-4000-8000-0000000000ff')).id,
  null::uuid, 'turno inexistente não devolve linha');

select * from finish();
rollback;
