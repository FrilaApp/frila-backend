-- 765_privado_candidatar_na_selecao.sql
-- Cobertura direta de privado.candidatar_na_selecao(vaga, profissional, agora): o miolo da
-- candidatura no modo seleção — fecha 24 h antes do início (RN24), é idempotente pela chave
-- natural (vaga, profissional), recusa turno sobreposto (RN21) e deixa desfazer a retirada.
--
-- Mutantes que estes testes matam (ver PR):
--   M1  `>=` -> `>` na fronteira das 24 h                          -> teste 3 fica vermelho
--   M2  remover o retorno idempotente do estado `pendente`         -> teste 6 fica vermelho
--   M3  remover a checagem de turno sobreposto (RN21)              -> teste 7 fica vermelho
--   M4  retirada/recusada não voltam a `pendente`                  -> teste 10 fica vermelho
--   M5  não recusar vaga sem posição aberta                        -> teste 11 fica vermelho
--   M6  intervalo fechado `[]` no teste de sobreposição (adjacente conflita) -> teste 13 fica vermelho
--   M7  qualquer estado de posição bloqueia (cancelada sobreposta conflita)  -> teste 14 fica vermelho

begin;
select plan(14);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
-- Relógio fixo ANTES dos dados (docs/TESTES-PGTAP-PADROES.md, seção 3).
select set_config('frila.agora', '2026-10-20 12:00:00+00', true);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76500000-0000-4000-8000-0000000000a1', 'contratante',  'Dono 765', '+5561976500001', 'dono-765@t.test', '1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('76500000-0000-4000-8000-0000000000b1', 'profissional', 'Pro 765',  '+5561976500002', 'pro-765@t.test',  '1995-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('76500000-0000-4000-8000-0000000000e1', 'Casa 765', '76500000000001', 'food_service', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography);
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('76500000-0000-4000-8000-0000000000a1', '76500000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('76500000-0000-4000-8000-0000000000c1', '76500000-0000-4000-8000-0000000000b1',
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
  values ('76500000-0000-4000-8000-0000000000e1', (select id from public.funcao order by nome limit 1),
          p_inicio, p_fim, 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1, true, false, false, 'Responsável', 'urgencia', gen_random_uuid(),
          '76500000-0000-4000-8000-0000000000a1', p_inicio - interval '1 day')
  returning id into v_vaga;
  insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_vaga, 'confirmada', '76500000-0000-4000-8000-0000000000c1', p_inicio - interval '12 hours', p_inicio, p_fim)
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

-- Dois outros profissionais: c2 (candidata-se junto) e c3 (já tem turno confirmado no horário).
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76500000-0000-4000-8000-0000000000b2', 'profissional', 'Pro dois 765', '+556197650003', 'pro2-765@t.test', '1994-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('76500000-0000-4000-8000-0000000000b3', 'profissional', 'Pro tres 765', '+556197650004', 'pro3-765@t.test', '1993-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('76500000-0000-4000-8000-0000000000c2', '76500000-0000-4000-8000-0000000000b2', 'POINT(-47.88 -15.79)'::extensions.geography),
  ('76500000-0000-4000-8000-0000000000c3', '76500000-0000-4000-8000-0000000000b3', 'POINT(-47.88 -15.79)'::extensions.geography);

-- Vaga de seleção: começa em 22/10 18:00Z, com duas posições abertas. `publicado_em` explícito:
-- selecao_com_antecedencia exige > 24 h de folga e não pode depender do now() da máquina.
create function pg_temp.vaga(p_id uuid, p_modo public.modo_preenchimento, p_inicio timestamptz, p_fim timestamptz)
returns void language sql as $$
  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente,
                           publicado_por, publicado_em)
  values (p_id, '76500000-0000-4000-8000-0000000000e1', (select id from public.funcao order by nome limit 1),
          p_inicio, p_fim, 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 2, true, false, false, 'Responsável', p_modo, gen_random_uuid(),
          '76500000-0000-4000-8000-0000000000a1', '2026-10-19 12:00+00')
$$;

select pg_temp.vaga('76500000-0000-4000-8000-0000000000d1', 'selecao', '2026-10-22 18:00+00', '2026-10-22 22:00+00');
insert into public.posicao (id, vaga_id, inicio_em, fim_em) values
  ('76500000-0000-4000-8000-0000000000f1', '76500000-0000-4000-8000-0000000000d1', '2026-10-22 18:00+00', '2026-10-22 22:00+00'),
  ('76500000-0000-4000-8000-0000000000f2', '76500000-0000-4000-8000-0000000000d1', '2026-10-22 18:00+00', '2026-10-22 22:00+00');

-- c3 tem turno confirmado de 17h às 21h do mesmo dia: sobrepõe a vaga de seleção.
select pg_temp.vaga('76500000-0000-4000-8000-0000000000d2', 'urgencia', '2026-10-22 17:00+00', '2026-10-22 21:00+00');
insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em) values
  ('76500000-0000-4000-8000-0000000000d2', 'confirmada', '76500000-0000-4000-8000-0000000000c3',
   '2026-10-19 12:00+00', '2026-10-22 17:00+00', '2026-10-22 21:00+00');

-- c4 tem turno confirmado de 14h às 18h: TERMINA no instante em que a vaga de seleção começa (adjacente).
-- c5 tem uma posição CANCELADA de 17h às 21h, sobreposta ao horário: cancelada não ocupa a agenda.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76500000-0000-4000-8000-0000000000b4', 'profissional', 'Pro quatro 765', '+556197650005', 'pro4-765@t.test', '1992-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('76500000-0000-4000-8000-0000000000b5', 'profissional', 'Pro cinco 765',  '+556197650006', 'pro5-765@t.test', '1991-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('76500000-0000-4000-8000-0000000000c4', '76500000-0000-4000-8000-0000000000b4', 'POINT(-47.88 -15.79)'::extensions.geography),
  ('76500000-0000-4000-8000-0000000000c5', '76500000-0000-4000-8000-0000000000b5', 'POINT(-47.88 -15.79)'::extensions.geography);
select pg_temp.vaga('76500000-0000-4000-8000-0000000000d4', 'urgencia', '2026-10-22 14:00+00', '2026-10-22 18:00+00');
insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em) values
  ('76500000-0000-4000-8000-0000000000d4', 'confirmada', '76500000-0000-4000-8000-0000000000c4',
   '2026-10-19 12:00+00', '2026-10-22 14:00+00', '2026-10-22 18:00+00');
insert into public.posicao (vaga_id, estado, profissional_id, inicio_em, fim_em) values
  ('76500000-0000-4000-8000-0000000000d2', 'cancelada', '76500000-0000-4000-8000-0000000000c5',
   '2026-10-22 17:00+00', '2026-10-22 21:00+00');

-- Vaga de seleção SEM nenhuma posição aberta.
select pg_temp.vaga('76500000-0000-4000-8000-0000000000d3', 'selecao', '2026-10-27 18:00+00', '2026-10-27 22:00+00');

create function pg_temp.cand(p_vaga uuid, p_prof uuid, p_agora timestamptz) returns jsonb
language sql as $$
  select privado.candidatar_na_selecao((select v from public.vaga v where v.id = p_vaga), p_prof, p_agora)
$$;

-- 1. Caminho feliz: devolve a candidatura pendente, sem posição, turno nem contato (nada confirmado).
select is(
  (pg_temp.cand('76500000-0000-4000-8000-0000000000d1', '76500000-0000-4000-8000-0000000000c1', '2026-10-20 12:00+00'))
    - 'candidatura_id',
  '{"estado":"pendente","posicao_id":null,"turno_id":null,"contato":null}'::jsonb,
  'candidatar-se dentro do prazo devolve pendente, sem posição, turno nem contato');

-- 2. A candidatura nasce na posição aberta de menor id.
select is(
  (select posicao_id from public.candidatura where profissional_id = '76500000-0000-4000-8000-0000000000c1'),
  '76500000-0000-4000-8000-0000000000f1'::uuid,
  'a candidatura nasce na posição aberta de menor id');

-- 3. RN24: a 24 h exatas do início já está fechada (a regra é `agora >= inicio - 24 h`).
select throws_ok(
  $$ select pg_temp.cand('76500000-0000-4000-8000-0000000000d1', '76500000-0000-4000-8000-0000000000c2', '2026-10-21 18:00+00') $$,
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : null, "hint" : null}',
  'RN24: exatamente 24 h antes do início a vaga de seleção está encerrada');

-- 4. Um segundo antes da fronteira ainda aceita.
select is(
  (pg_temp.cand('76500000-0000-4000-8000-0000000000d1', '76500000-0000-4000-8000-0000000000c2', '2026-10-21 17:59:59+00')) ->> 'estado',
  'pendente', 'um segundo antes das 24 h a candidatura ainda é aceita');

-- 5-6. Idempotência pela chave natural: o reenvio devolve a mesma candidatura e NÃO reescreve nada
-- (criada_em continua a do primeiro envio, embora o relógio do reenvio seja outro).
select is(
  (pg_temp.cand('76500000-0000-4000-8000-0000000000d1', '76500000-0000-4000-8000-0000000000c1', '2026-10-20 13:00+00')) ->> 'candidatura_id',
  (select id::text from public.candidatura where profissional_id = '76500000-0000-4000-8000-0000000000c1'),
  'o reenvio devolve a mesma candidatura');
select is(
  (select row(count(*), min(criada_em)) from public.candidatura where profissional_id = '76500000-0000-4000-8000-0000000000c1'),
  row(1::bigint, '2026-10-20 12:00:00+00'::timestamptz),
  'o reenvio não cria outra linha nem reescreve criada_em');

-- 7. RN21 já na candidatura: turno confirmado sobreposto é 422 inelegivel / turno_sobreposto.
select throws_ok(
  $$ select pg_temp.cand('76500000-0000-4000-8000-0000000000d1', '76500000-0000-4000-8000-0000000000c3', '2026-10-20 12:00+00') $$,
  'PGRST',
  '{"code" : "inelegivel", "message" : "inelegivel", "details" : "turno_sobreposto", "hint" : null}',
  'RN21: quem tem turno confirmado no horário não pode se candidatar');

-- 8-10. Retirada e recusada voltam a valer: a mesma candidatura reabre, sem linha nova.
update public.candidatura set estado = 'retirada'
 where profissional_id = '76500000-0000-4000-8000-0000000000c2';
select is(
  (pg_temp.cand('76500000-0000-4000-8000-0000000000d1', '76500000-0000-4000-8000-0000000000c2', '2026-10-20 14:00+00')) ->> 'estado',
  'pendente', 'candidatar-se de novo desfaz a retirada');

update public.candidatura set estado = 'recusada'
 where profissional_id = '76500000-0000-4000-8000-0000000000c2';
select is(
  (pg_temp.cand('76500000-0000-4000-8000-0000000000d1', '76500000-0000-4000-8000-0000000000c2', '2026-10-20 15:00+00')) ->> 'estado',
  'pendente', 'candidatar-se de novo reabre a recusada de uma vaga que reabriu');
-- Em instrução separada: a subconsulta só enxerga o update da função na instrução seguinte.
select is(
  (select array[count(*)::text, min(estado::text)] from public.candidatura
    where profissional_id = '76500000-0000-4000-8000-0000000000c2'),
  array['1', 'pendente'],
  'a reabertura reaproveita a mesma linha, já pendente');

-- 11. Sem posição aberta: 409 posicao_ja_preenchida (e não violação de NOT NULL).
select throws_ok(
  $$ select pg_temp.cand('76500000-0000-4000-8000-0000000000d3', '76500000-0000-4000-8000-0000000000c1', '2026-10-20 12:00+00') $$,
  'PGRST',
  '{"code" : "posicao_ja_preenchida", "message" : "posicao_ja_preenchida", "details" : null, "hint" : null}',
  'vaga sem posição aberta é 409 posicao_ja_preenchida');

-- 12. A reabertura carimba criada_em com o relógio recebido (ordem da fila de seleção).
select is(
  (select criada_em from public.candidatura where profissional_id = '76500000-0000-4000-8000-0000000000c2'),
  '2026-10-20 15:00:00+00'::timestamptz,
  'a candidatura reaberta leva criada_em = agora do reenvio');

-- 13. Turno adjacente (termina quando a vaga começa) não é sobreposição: o intervalo é [início, fim).
select lives_ok(
  $$ select pg_temp.cand('76500000-0000-4000-8000-0000000000d1', '76500000-0000-4000-8000-0000000000c4', '2026-10-20 12:00+00') $$,
  'RN21: turno que termina às 18h não impede candidatura a vaga que começa às 18h');

-- 14. Posição cancelada sobreposta não ocupa a agenda: só confirmada e cumprida contam.
select lives_ok(
  $$ select pg_temp.cand('76500000-0000-4000-8000-0000000000d1', '76500000-0000-4000-8000-0000000000c5', '2026-10-20 12:00+00') $$,
  'RN21: posição cancelada no mesmo horário não bloqueia a candidatura');

select * from finish();
rollback;
