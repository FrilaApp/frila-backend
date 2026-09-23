-- RN02, RN18, RN21, RN24 e a máquina de estados da posição.

begin;
select plan(15);

create function pg_temp.cenario()
returns table (estab uuid, funcao uuid, prof1 uuid, prof2 uuid)
language plpgsql as $$
declare
  v_estab uuid; v_funcao uuid; v_p1 uuid; v_p2 uuid;
begin
  insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
  values ('Bar do Zé', '11222333000181', 'food_service', 'CLN 201',
          'POINT(-47.8822 -15.7942)'::extensions.geography)
  returning id into v_estab;

  select id into v_funcao from public.funcao where nome = 'garçom';

  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
    ('aaaaaaaa-0000-0000-0000-000000000001','profissional','Ana','+5561999990001','ana@t.test','1995-01-01', '2026-09-22', now()),
    ('aaaaaaaa-0000-0000-0000-000000000002','profissional','Beto','+5561999990002','beto@t.test','1995-01-01', '2026-09-22', now());

  insert into public.profissional (usuario_id, ponto_base) values
    ('aaaaaaaa-0000-0000-0000-000000000001','POINT(-47.88 -15.79)'::extensions.geography),
    ('aaaaaaaa-0000-0000-0000-000000000002','POINT(-47.88 -15.79)'::extensions.geography);

  select p.id into v_p1 from public.profissional p where p.usuario_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  select p.id into v_p2 from public.profissional p where p.usuario_id = 'aaaaaaaa-0000-0000-0000-000000000002';

  return query select v_estab, v_funcao, v_p1, v_p2;
end $$;

create temp table cen as select * from pg_temp.cenario();

create function pg_temp.nova_vaga(p_inicio timestamptz, p_fim timestamptz,
                                  p_modo public.modo_preenchimento default 'urgencia',
                                  p_posicoes smallint default 1,
                                  p_valor bigint default 12000)
returns uuid language sql as $$
  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente)
  select estab, funcao, p_inicio, p_fim, 'CLN 201',
         'POINT(-47.8822 -15.7942)'::extensions.geography,
         p_valor, p_posicoes, true, false, false, 'Maître Zé', p_modo, gen_random_uuid()
    from cen
  returning id;
$$;

-- ── RN02: vaga incompleta não existe ───────────────────────────────────────────
select throws_ok(
  $$ insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                              valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                              exige_material_proprio, modo, chave_cliente)
     select estab, funcao, now() + interval '2 h', now() + interval '10 h', 'CLN 201',
            'POINT(-47.88 -15.79)'::extensions.geography, 12000, 1::smallint,
            true, false, false, 'urgencia', gen_random_uuid() from cen $$,
  '23502',
  null,
  'RN02: vaga sem responsavel_local não entra');

-- ── Horário ────────────────────────────────────────────────────────────────────
select throws_ok(
  $$ select pg_temp.nova_vaga(now() + interval '10 h', now() + interval '2 h') $$,
  '23514',
  null,
  'fim antes do início é recusado');

-- ── RN18: dinheiro em centavos inteiros, e sempre positivo ─────────────────────
select throws_ok(
  $$ select pg_temp.nova_vaga(now() + interval '2 h', now() + interval '10 h', 'urgencia', 1::smallint, 0::bigint) $$,
  '23514',
  null,
  'RN18: valor zero não é uma vaga');

select is(
  (select data_type from information_schema.columns
    where table_schema = 'public' and table_name = 'vaga' and column_name = 'valor_centavos'),
  'bigint',
  'RN18: dinheiro é inteiro em centavos, nunca numeric ou float');

-- ── RN24: modo seleção só com mais de 24 horas ─────────────────────────────────
select throws_ok(
  $$ select pg_temp.nova_vaga(now() + interval '10 h', now() + interval '18 h', 'selecao') $$,
  '23514',
  null,
  'RN24: seleção em vaga que começa em menos de 24 h nasceria fechada — nem entra');

select lives_ok(
  $$ select pg_temp.nova_vaga(now() + interval '48 h', now() + interval '56 h', 'selecao') $$,
  'RN24: seleção com mais de 24 h de antecedência entra');

-- ── Idempotência da publicação ─────────────────────────────────────────────────
select throws_ok(
  $$ insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                              valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                              exige_material_proprio, responsavel_local, modo, chave_cliente)
     select estab, funcao, now() + interval '2 h', now() + interval '10 h', 'x',
            'POINT(-47.88 -15.79)'::extensions.geography, 12000, 1::smallint,
            true, false, false, 'Zé', 'urgencia'::public.modo_preenchimento,
            '11111111-1111-1111-1111-111111111111'::uuid from cen
     union all
     select estab, funcao, now() + interval '3 h', now() + interval '11 h', 'y',
            'POINT(-47.88 -15.79)'::extensions.geography, 12000, 1::smallint,
            true, false, false, 'Zé', 'urgencia'::public.modo_preenchimento,
            '11111111-1111-1111-1111-111111111111'::uuid from cen $$,
  '23505',
  null,
  'a mesma chave do cliente não publica duas vagas');

-- ── A máquina de estados da posição ────────────────────────────────────────────
create temp table v as
  select pg_temp.nova_vaga(now() + interval '2 h', now() + interval '10 h') as id;

select throws_ok(
  $$ insert into public.posicao (vaga_id, estado, inicio_em, fim_em)
     select id, 'confirmada', now() + interval '2 h', now() + interval '10 h' from v $$,
  '23514',
  null,
  'posição confirmada sem profissional é incoerente');

select throws_ok(
  $$ insert into public.posicao (vaga_id, estado, profissional_id, inicio_em, fim_em)
     select v.id, 'aberta', cen.prof1, now() + interval '2 h', now() + interval '10 h'
       from v, cen $$,
  '23514',
  null,
  'posição aberta com profissional é incoerente');

select throws_ok(
  $$ insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em)
     select v.id, 'confirmada', cen.prof1, now(), true, now() + interval '2 h', now() + interval '10 h'
       from v, cen $$,
  '23514',
  null,
  'falta só existe em posição cancelada');

-- ── RN21: nenhum profissional com dois turnos que se cruzam ────────────────────
--
-- Sem ela, a pessoa aceitaria os dois de boa-fé e faltaria a um, desabando a própria
-- taxa de comparecimento por um buraco do sistema, não por comportamento.
insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select v.id, 'confirmada', cen.prof1, now(),
       '2026-10-10 18:00-03', '2026-10-11 02:00-03' from v, cen;

select throws_ok(
  $$ insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
     select v.id, 'confirmada', cen.prof1, now(),
            '2026-10-10 23:00-03', '2026-10-11 04:00-03' from v, cen $$,
  '23P01',
  null,
  'RN21: dois turnos confirmados que se sobrepõem, para o mesmo profissional, são recusados');

select lives_ok(
  $$ insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
     select v.id, 'confirmada', cen.prof1, now(),
            '2026-10-11 02:00-03', '2026-10-11 08:00-03' from v, cen $$,
  'RN21: turno que começa exatamente quando o outro acaba é permitido');

select lives_ok(
  $$ insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
     select v.id, 'confirmada', cen.prof2, now(),
            '2026-10-10 20:00-03', '2026-10-11 01:00-03' from v, cen $$,
  'RN21: dois profissionais diferentes no mesmo horário são o caso normal');

select lives_ok(
  $$ insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em)
     select v.id, 'cancelada', cen.prof1, now(), true,
            '2026-10-10 19:00-03', '2026-10-10 23:00-03' from v, cen $$,
  'RN21: posição cancelada sai da restrição — o histórico da falta é preservado');

-- ── O horário da posição acompanha o da vaga, enquanto está aberta ─────────────
create temp table v2 as
  select pg_temp.nova_vaga('2026-11-01 18:00-03', '2026-11-02 02:00-03') as id;
insert into public.posicao (vaga_id, inicio_em, fim_em)
select id, '2026-11-01 18:00-03', '2026-11-02 02:00-03' from v2;

update public.vaga set inicio_em = '2026-11-01 20:00-03', fim_em = '2026-11-02 04:00-03'
 where id = (select id from v2);

select is(
  (select inicio_em from public.posicao where vaga_id = (select id from v2)),
  '2026-11-01 20:00-03'::timestamptz,
  'a desnormalização de horário em posicao acompanha a vaga enquanto a posição está aberta');

select * from finish();
rollback;
