-- RN22 (presença com prova) e RN07 (avaliação binária, após o fim, com presença).

begin;
select plan(14);

create function pg_temp.montar(p_inicio timestamptz, p_fim timestamptz)
returns uuid language plpgsql as $$
declare
  v_estab uuid; v_funcao uuid; v_prof uuid; v_vaga uuid; v_pos uuid;
begin
  -- Um estabelecimento e um profissional para o arquivo inteiro: a chamada seguinte
  -- reaproveita, porque o documento e o e-mail são únicos.
  select id into v_estab from public.estabelecimento where documento = '11222333000181';
  if v_estab is null then
    insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
    values ('Bar do Zé', '11222333000181', 'food_service', 'CLN 201',
            'POINT(-47.8822 -15.7942)'::extensions.geography)
    returning id into v_estab;
  end if;

  select id into v_funcao from public.funcao where nome = 'garçom';

  select id into v_prof from public.profissional
   where usuario_id = 'bbbbbbbb-0000-0000-0000-000000000001';
  if v_prof is null then
    insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
    values ('bbbbbbbb-0000-0000-0000-000000000001','profissional','Ana',
            '+5561999990001','ana@t.test','1995-01-01', '2026-09-22', now());
    insert into public.profissional (usuario_id, ponto_base)
    values ('bbbbbbbb-0000-0000-0000-000000000001','POINT(-47.88 -15.79)'::extensions.geography)
    returning id into v_prof;
  end if;

  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente)
  values (v_estab, v_funcao, p_inicio, p_fim, 'CLN 201',
          'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1, true, false, false, 'Maître Zé', 'urgencia', gen_random_uuid())
  returning id into v_vaga;

  insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_vaga, 'confirmada', v_prof, now(), p_inicio, p_fim)
  returning id into v_pos;

  return v_pos;
end $$;

-- Turno já terminado, para o caminho feliz de RN07.
create temp table t as
  select pg_temp.montar(now() - interval '10 h', now() - interval '2 h') as posicao_id;

-- Desde que `supabase/cenarios.sql` povoa o banco no `db reset`, `from public.turno`
-- sem filtro deixou de significar "o turno deste teste": significa oito turnos, sete
-- deles do cenário. O mesmo vale para os `limit 1` sem `order by` que escolhiam um
-- profissional e um estabelecimento quaisquer.
--
-- Daqui para baixo, toda consulta se limita ao que este arquivo criou. A alternativa
-- seria manter o banco vazio depois do reset, e aí o cenário de desenvolvimento não
-- existiria.
create temp table meu as select
  (select id from public.estabelecimento where documento = '11222333000181') as estab,
  'bbbbbbbb-0000-0000-0000-000000000001'::uuid                                as prof_usuario;

-- ── RN22: 'verificado' só com prova ────────────────────────────────────────────
select throws_ok(
  $$ insert into public.turno (posicao_id, verificacao, valor_acordado_centavos)
     select posicao_id, 'verificado', 12000 from t $$,
  '23514',
  null,
  'RN22: não há como marcar verificado sem check-in nenhum');

select throws_ok(
  $$ insert into public.turno (posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
                               verificacao, valor_acordado_centavos)
     select posicao_id, now(), 'geolocalizado', 350, 'verificado', 12000 from t $$,
  '23514',
  null,
  'RN22: check-in geolocalizado a mais de 200 m não vale');

select throws_ok(
  $$ insert into public.turno (posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
                               verificacao, valor_acordado_centavos)
     select posicao_id, now(), 'geolocalizado', null, 'verificado', 12000 from t $$,
  '23514',
  null,
  'RN22: geolocalizado sem distância medida não é prova de nada');

select throws_ok(
  $$ insert into public.turno (posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
                               checkin_confirmado_em, verificacao, valor_acordado_centavos)
     select posicao_id, now(), 'geolocalizado', 50, now(), 'verificado', 12000 from t $$,
  '23514',
  null,
  'a confirmação do contratante só existe no check-in manual');

select throws_ok(
  $$ insert into public.turno (posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
                               verificacao, valor_acordado_centavos)
     select posicao_id, now(), 'manual', null, 'verificado', 12000 from t $$,
  '23514',
  null,
  'RN22: manual sem confirmação do contratante não conta como presença');

select lives_ok(
  $$ insert into public.turno (posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
                               verificacao, valor_acordado_centavos)
     select posicao_id, now(), 'manual', null, 'pendente', 12000 from t $$,
  'manual sem confirmação fica pendente, que é o estado certo');

select throws_ok(
  $$ update public.turno set checkin_confirmado_em = now()
      where posicao_id = (select posicao_id from t) $$,
  '23514',
  null,
  'confirmar o manual sem passar a verificacao para verificado é incoerente');

update public.turno set checkin_confirmado_em = now(), verificacao = 'verificado'
 where posicao_id = (select posicao_id from t);

select is(
  (select verificacao from public.turno where posicao_id = (select posicao_id from t))::text,
  'verificado',
  'RN22: manual confirmado pelo contratante vale como presença');

-- ── RN07: a avaliação ──────────────────────────────────────────────────────────
create temp table ids as
  select tu.id as turno_id, m.prof_usuario, m.estab
    from public.turno tu, t, meu m
   where tu.posicao_id = t.posicao_id;

select lives_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select turno_id, prof_usuario, 'estabelecimento', estab, true from ids $$,
  'RN07: turno terminado e com presença verificada libera a avaliação');

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select turno_id, prof_usuario, 'estabelecimento', estab, false from ids $$,
  '23505',
  null,
  'RN07: um autor avalia um turno uma vez só');

select is(
  (select pg_typeof(a.resposta)::text from public.avaliacao a, ids
    where a.turno_id = ids.turno_id limit 1),
  'boolean',
  'RN07: a resposta é binária. Não existe caminho no esquema que aceite nota de 1 a 5');

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select turno_id, prof_usuario, 'qualquer_coisa', estab, true from ids $$,
  '23514',
  null,
  'o alvo da avaliação é profissional ou estabelecimento, e nada mais');

-- Turno que ainda não acabou: a avaliação não abre.
create temp table futuro as
  select pg_temp.montar(now() + interval '2 h', now() + interval '10 h') as posicao_id;

insert into public.turno (posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
                          verificacao, valor_acordado_centavos)
select posicao_id, now(), 'geolocalizado', 50, 'verificado', 12000 from futuro;

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select tu.id, m.prof_usuario, 'estabelecimento', m.estab, true
       from public.turno tu join futuro f on f.posicao_id = tu.posicao_id, meu m $$,
  'PGRST',
  null,
  'RN07: antes do fim previsto a avaliação é recusada, com o código do contrato');

-- E o turno sem presença verificada também não.
update public.turno t
   set verificacao = 'nao_verificado', checkin_em = null, checkin_tipo = null,
       checkin_distancia_m = null
  from futuro f where f.posicao_id = t.posicao_id;

-- Janela que não cruza a do primeiro turno: RN21 vale aqui também, e é o próprio
-- EXCLUDE que recusaria o UPDATE se este teste fosse desleixado com o horário.
update public.posicao p set inicio_em = now() - interval '30 h', fim_em = now() - interval '25 h'
  from futuro f where f.posicao_id = p.id;

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select tu.id, m.prof_usuario, 'estabelecimento', m.estab, true
       from public.turno tu join futuro f on f.posicao_id = tu.posicao_id, meu m $$,
  'PGRST',
  null,
  'RN07: quem faltou não é avaliado — a falta já pesa na taxa, e não deve pesar duas vezes');

select * from finish();
rollback;
