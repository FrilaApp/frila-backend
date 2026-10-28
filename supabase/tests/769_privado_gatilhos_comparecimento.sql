-- 769_privado_gatilhos_comparecimento.sql
-- Cobertura direta dos dois gatilhos que mantêm profissional.turnos_realizados e
-- profissional.taxa_comparecimento (RF16, definição canônica da Modelagem de Banco):
--   privado.gatilho_turno_recalcular_comparecimento()    AFTER INSERT OR UPDATE OF verificacao ON turno
--   privado.gatilho_posicao_recalcular_comparecimento()  AFTER INSERT OR UPDATE OF falta, estado,
--                                                        profissional_id ON posicao
-- O recálculo em si (privado.recalcular_comparecimento) não é o alvo; os testes medem QUANDO ele
-- é disparado e PARA QUEM. A técnica: "sujar" os contadores do profissional (99 / 0,500, um
-- estado que nenhum recálculo real produz), mexer na tabela, e ver se o contador foi consertado
-- (o gatilho disparou) ou continuou sujo (não disparou).
--
-- Armadilha de `UPDATE OF col` (docs/TESTES-PGTAP-PADROES.md, seção 5): os casos negativos
-- abaixo põem a coluna vigiada no SET com o MESMO valor, para exercitar a condição da função e
-- não só o filtro de coluna do PostgreSQL.
--
-- Mutantes que estes testes matam (ver PR):
--   T1  gatilho do turno sem a trava frila.em_lote                   -> teste 6 fica vermelho
--   T2  gatilho do turno ignora o INSERT                              -> teste 1 fica vermelho
--   T3  gatilho do turno sem `old.verificacao is distinct from`       -> teste 4 fica vermelho
--   T4  gatilho do turno recalcula um profissional nulo               -> testes 1 e 2 ficam vermelhos
--   P1  gatilho da posição sem a trava frila.em_lote                  -> teste 15 fica vermelho
--   P2  gatilho da posição sem recalcular o profissional ANTIGO        -> teste 13 fica vermelho
--   P3  INSERT da posição recalcula mesmo sem falta                   -> teste 9 fica vermelho
--   P4  UPDATE da posição ignora a mudança de `falta`                 -> teste 10 fica vermelho
--   P5  UPDATE da posição ignora a mudança de `estado`                -> teste 12 fica vermelho
--   P6  UPDATE da posição recalcula sem mudança (`falta` sempre "mudou") -> teste 11 fica vermelho
--   P7  apagar o ramo `elsif TG_OP = 'INSERT'` do gatilho da posição  -> teste 17 fica vermelho

begin;
select plan(17);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
-- Relógio fixo ANTES dos dados (docs/TESTES-PGTAP-PADROES.md, seção 3).
select set_config('frila.agora', '2026-10-20 12:00:00+00', true);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76900000-0000-4000-8000-0000000000a1', 'contratante',  'Dono 769', '+5561976900001', 'dono-769@t.test', '1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('76900000-0000-4000-8000-0000000000b1', 'profissional', 'Pro 769',  '+5561976900002', 'pro-769@t.test',  '1995-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('76900000-0000-4000-8000-0000000000e1', 'Casa 769', '76900000000001', 'food_service', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography);
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('76900000-0000-4000-8000-0000000000a1', '76900000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('76900000-0000-4000-8000-0000000000c1', '76900000-0000-4000-8000-0000000000b1',
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
  values ('76900000-0000-4000-8000-0000000000e1', (select id from public.funcao order by nome limit 1),
          p_inicio, p_fim, 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1, true, false, false, 'Responsável', 'urgencia', gen_random_uuid(),
          '76900000-0000-4000-8000-0000000000a1', p_inicio - interval '1 day')
  returning id into v_vaga;
  insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_vaga, 'confirmada', '76900000-0000-4000-8000-0000000000c1', p_inicio - interval '12 hours', p_inicio, p_fim)
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

-- Um segundo profissional (c2): serve de controle ("não mexe em quem não é o da linha") e de
-- destino da troca de profissional.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76900000-0000-4000-8000-0000000000b2', 'profissional', 'Pro dois 769', '+556197690003', 'pro2-769@t.test', '1994-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('76900000-0000-4000-8000-0000000000c2', '76900000-0000-4000-8000-0000000000b2', 'POINT(-47.88 -15.79)'::extensions.geography);

-- "turnos_realizados/taxa" legível, e o estado sujo que nenhum recálculo real produz.
create function pg_temp.estado(p uuid) returns text language sql as $$
  select turnos_realizados::text || '/' || coalesce(taxa_comparecimento::text, 'nulo')
    from public.profissional where id = p
$$;
create function pg_temp.sujar() returns void language sql as $$
  update public.profissional set turnos_realizados = 99, taxa_comparecimento = 0.500
   where id in ('76900000-0000-4000-8000-0000000000c1', '76900000-0000-4000-8000-0000000000c2')
$$;

-- ── Gatilho do TURNO ──────────────────────────────────────────────────────────────────────
-- INSERT dispara: turno novo (pendente) recalcula o profissional — que passa de sujo a 0/nulo.
select pg_temp.sujar();
create temp table w1 as select pg_temp.montar('2026-10-21 10:00+00', '2026-10-21 14:00+00', 'pendente') as turno;
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c1'), '0/nulo',
  'INSERT de turno recalcula o profissional (pendente: nenhum verificado, sem denominador)');

-- UPDATE da verificação dispara: pendente -> verificado conta 1 turno, taxa 1.000.
--    O profissional c2 (outro) está sujo e NÃO pode ser tocado.
select pg_temp.sujar();
update public.turno
   set checkin_em = '2026-10-21 10:00+00', checkin_tipo = 'geolocalizado', checkin_distancia_m = 40,
       verificacao = 'verificado'
 where id = (select turno from w1);
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c1'), '1/1.000',
  'UPDATE de verificacao para verificado recalcula: 1 turno, taxa 1.000');
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c2'), '99/0.500',
  'o recálculo é só do profissional da posição: outro profissional fica como estava');

-- Negativo real da condição: verificacao no SET com o mesmo valor — gatilho dispara pelo
--    `OF verificacao`, e a função decide não recalcular porque nada mudou.
select pg_temp.sujar();
update public.turno set verificacao = verificacao where id = (select turno from w1);
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c1'), '99/0.500',
  'SET verificacao = verificacao (sem mudança) não recalcula');

-- Outra coluna do turno no SET: o `OF verificacao` descarta o gatilho (teste de coluna vizinha).
select pg_temp.sujar();
update public.turno set valor_acordado_centavos = 13000 where id = (select turno from w1);
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c1'), '99/0.500',
  'alterar outra coluna do turno não dispara o gatilho (descarte por UPDATE OF)');

-- frila.em_lote = true suspende o recálculo (cargas em lote recalculam uma vez no fim).
select pg_temp.sujar();
select set_config('frila.em_lote', 'true', true);
create temp table w2 as select pg_temp.montar('2026-10-22 10:00+00', '2026-10-22 14:00+00', 'verificado') as turno;
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c1'), '99/0.500',
  'com frila.em_lote = true o INSERT de turno não recalcula');
select set_config('frila.em_lote', 'false', true);

-- Turno em posição SEM profissional não explode nem recalcula ninguém.
create temp table w3 as
  with p as (select pg_temp.montar('2026-10-23 10:00+00', '2026-10-23 14:00+00', 'nenhum') as id)
  select id from p;
create temp table aberta as
  with n as (
    insert into public.posicao (vaga_id, inicio_em, fim_em)
    select vaga_id, inicio_em, fim_em from public.posicao where id = (select id from w3)
    returning id)
  select id from n;
select pg_temp.sujar();
select lives_ok(
  $$ insert into public.turno (posicao_id, valor_acordado_centavos) select id, 12000 from aberta $$,
  'turno em posição sem profissional é aceito (o gatilho não recalcula ninguém)');
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c1'), '99/0.500',
  '...e o contador do profissional não muda');

-- ── Gatilho da POSIÇÃO ────────────────────────────────────────────────────────────────────
-- Estado de partida real: recalcula c1 (verificados: w1 e w2 = 2; faltas: 0 => 2/1.000).
select privado.recalcular_comparecimento('76900000-0000-4000-8000-0000000000c1');
select privado.recalcular_comparecimento('76900000-0000-4000-8000-0000000000c2');

-- INSERT sem falta não recalcula (P3).
select pg_temp.sujar();
create temp table p_cancelada as
  with n as (
    insert into public.posicao (vaga_id, estado, profissional_id, falta, inicio_em, fim_em)
    select vaga_id, 'cancelada', '76900000-0000-4000-8000-0000000000c1', false, inicio_em, fim_em
      from public.posicao where id = (select id from w3)
    returning id)
  select id from n;
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c1'), '99/0.500',
  'INSERT de posição sem falta não recalcula');

-- UPDATE falta false -> true recalcula: 2 verificados e 1 falta => 2/0.667.
select pg_temp.sujar();
update public.posicao set falta = true where id = (select id from p_cancelada);
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c1'), '2/0.667',
  'UPDATE de falta para true recalcula: 2 verificados e 1 falta = 0.667');

-- falta no SET com o mesmo valor: nada mudou, não recalcula (P4/P6).
select pg_temp.sujar();
update public.posicao set falta = falta where id = (select id from p_cancelada);
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c1'), '99/0.500',
  'SET falta = falta (sem mudança) não recalcula');

-- Mudança de estado recalcula (P5): a posição de w2 passa de confirmada a cumprida.
select pg_temp.sujar();
update public.posicao set estado = 'cumprida'
 where id = (select posicao_id from public.turno where id = (select turno from w2));
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c1'), '2/0.667',
  'UPDATE de estado da posição recalcula o profissional');

-- Troca de profissional: recalcula o ANTIGO (P2) e o NOVO. A posição de w3 passa de c1 a c2.
select pg_temp.sujar();
update public.posicao set profissional_id = '76900000-0000-4000-8000-0000000000c2'
 where id = (select id from w3);
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c1'), '2/0.667',
  'troca de profissional recalcula o profissional ANTIGO');
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c2'), '0/nulo',
  'troca de profissional recalcula o profissional NOVO');

-- frila.em_lote = true suspende também o gatilho da posição.
select pg_temp.sujar();
select set_config('frila.em_lote', 'true', true);
update public.posicao set estado = 'cumprida' where id = (select id from w3);
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c2'), '99/0.500',
  'com frila.em_lote = true o UPDATE de posição não recalcula');
select set_config('frila.em_lote', 'false', true);

-- Os dois gatilhos existem, ligados nas colunas certas (a cobertura acima só vale se estão ativos).
select is(
  (select array_agg(tgname::text order by tgname) from pg_trigger
    where tgfoid in ('privado.gatilho_turno_recalcular_comparecimento()'::regprocedure,
                     'privado.gatilho_posicao_recalcular_comparecimento()'::regprocedure)
      and not tgisinternal),
  array['posicao_recalcula_comparecimento', 'turno_recalcula_comparecimento'],
  'os dois gatilhos estão ligados às suas tabelas');

-- Ramo INSERT com falta: posição já nasce faltosa (cancelada com falta = true) e recalcula. Estado de
-- partida sujo; c1 tem 2 verificados e, com a falta de p_cancelada mais esta, 2 faltas => 2/0.500.
select pg_temp.sujar();
insert into public.posicao (vaga_id, estado, profissional_id, falta, inicio_em, fim_em)
select vaga_id, 'cancelada', '76900000-0000-4000-8000-0000000000c1', true, inicio_em, fim_em
  from public.posicao where id = (select id from w3);
select is(pg_temp.estado('76900000-0000-4000-8000-0000000000c1'), '2/0.500',
  'INSERT de posição já com falta = true recalcula o profissional: 2 verificados e 2 faltas = 0.500');

select * from finish();
rollback;
