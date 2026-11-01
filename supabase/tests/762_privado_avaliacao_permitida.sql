-- 762_privado_avaliacao_permitida.sql
-- Cobertura direta do gatilho privado.avaliacao_permitida() (BEFORE INSERT em public.avaliacao):
-- a trava de RN07 para quem escrever direto na tabela — só as duas partes do turno avaliam, só
-- depois do fim, só com presença verificada.
--
-- Mutantes que estes testes matam (ver PR):
--   M1  remover o bloco "autor e alvo são as duas partes"     -> testes 3, 4, 5 e 11 ficam vermelhos
--   M2  trocar `<` por `>` em `agora < v_fim`                  -> testes 1, 2, 6, 7 e 9 ficam vermelhos
--   M2b trocar `<` por `<=` em `agora < v_fim`                 -> só o teste 10 (fronteira exata) fica vermelho
--   M3  remover a checagem `v_verificacao is distinct from`    -> teste 7 fica vermelho
--   M4  trocar `new.alvo_id = v_estab` por `new.alvo_id = v_prof_conta`
--       (ramo em que o alvo é o estabelecimento)               -> testes 1, 6, 7 e 10 ficam vermelhos
--   M5  remover `new.alvo_id = v_prof` (ramo em que o alvo é o profissional)
--                                                              -> teste 11 fica vermelho

begin;
select plan(11);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
-- Relógio fixo ANTES dos dados (docs/TESTES-PGTAP-PADROES.md, seção 3).
select set_config('frila.agora', '2026-10-20 12:00:00+00', true);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76200000-0000-4000-8000-0000000000a1', 'contratante',  'Dono 762', '+5561976200001', 'dono-762@t.test', '1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('76200000-0000-4000-8000-0000000000b1', 'profissional', 'Pro 762',  '+5561976200002', 'pro-762@t.test',  '1995-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('76200000-0000-4000-8000-0000000000e1', 'Casa 762', '76200000000001', 'food_service', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography);
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('76200000-0000-4000-8000-0000000000a1', '76200000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('76200000-0000-4000-8000-0000000000c1', '76200000-0000-4000-8000-0000000000b1',
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
  values ('76200000-0000-4000-8000-0000000000e1', (select id from public.funcao order by nome limit 1),
          p_inicio, p_fim, 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1, true, false, false, 'Responsável', 'urgencia', gen_random_uuid(),
          '76200000-0000-4000-8000-0000000000a1', p_inicio - interval '1 day')
  returning id into v_vaga;
  insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_vaga, 'confirmada', '76200000-0000-4000-8000-0000000000c1', p_inicio - interval '12 hours', p_inicio, p_fim)
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

-- Uma segunda casa, com outro dono, para provar que "membro de OUTRA casa" não avalia.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76200000-0000-4000-8000-0000000000a2', 'contratante', 'Dono Outra', '+556197620002', 'outro-762@t.test', '1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('76200000-0000-4000-8000-0000000000e2', 'Outra Casa 762', '76200000000002', 'food_service', 'CLS 305',
   'POINT(-47.8822 -15.7942)'::extensions.geography);
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('76200000-0000-4000-8000-0000000000a2', '76200000-0000-4000-8000-0000000000e2', 'administrador');

-- Um profissional que NÃO é o do turno, para o alvo errado do lado do profissional.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76200000-0000-4000-8000-0000000000b2', 'profissional', 'Pro dois 762', '+556197620003', 'pro2-762@t.test', '1994-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('76200000-0000-4000-8000-0000000000c2', '76200000-0000-4000-8000-0000000000b2', 'POINT(-47.88 -15.79)'::extensions.geography);

create temp table t as select
  pg_temp.montar('2026-10-19 10:00+00', '2026-10-19 14:00+00')              as encerrado,
  pg_temp.montar('2026-10-20 10:00+00', '2026-10-20 18:00+00')              as em_curso,
  pg_temp.montar('2026-10-18 10:00+00', '2026-10-18 14:00+00', 'pendente')  as sem_presenca;

-- ── Caminho feliz: as duas partes, turno terminado e verificado ────────────────────────────
select lives_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select encerrado, '76200000-0000-4000-8000-0000000000b1', 'estabelecimento',
            '76200000-0000-4000-8000-0000000000e1', true from t $$,
  'o profissional do turno avalia o estabelecimento da vaga depois do fim');

select lives_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select encerrado, '76200000-0000-4000-8000-0000000000a1', 'profissional',
            '76200000-0000-4000-8000-0000000000c1', false from t $$,
  'um membro do estabelecimento avalia o profissional do turno depois do fim');

-- ── Quem não é parte do turno ─────────────────────────────────────────────────────────────
select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select sem_presenca, '76200000-0000-4000-8000-0000000000a2', 'profissional',
            '76200000-0000-4000-8000-0000000000c1', true from t $$,
  '23514',
  'autor e alvo da avaliação têm de ser as duas partes do turno (RN07)',
  'membro de OUTRA casa não avalia o profissional (a trava de partes vem antes das demais)');

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select encerrado, '76200000-0000-4000-8000-0000000000a1', 'estabelecimento',
            '76200000-0000-4000-8000-0000000000e1', true from t $$,
  '23514',
  'autor e alvo da avaliação têm de ser as duas partes do turno (RN07)',
  'o dono não avalia a própria casa: alvo estabelecimento exige o profissional como autor');

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select encerrado, '76200000-0000-4000-8000-0000000000b1', 'estabelecimento',
            '76200000-0000-4000-8000-0000000000e2', true from t $$,
  '23514',
  'autor e alvo da avaliação têm de ser as duas partes do turno (RN07)',
  'o profissional não avalia um estabelecimento que não é o da vaga do turno');

-- ── Tempo e presença ──────────────────────────────────────────────────────────────────────
select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select em_curso, '76200000-0000-4000-8000-0000000000b1', 'estabelecimento',
            '76200000-0000-4000-8000-0000000000e1', true from t $$,
  'PGRST',
  '{"code" : "avaliacao_indisponivel", "message" : "avaliacao_indisponivel", "details" : "antes_do_fim", "hint" : null}',
  'RN07: turno em curso (agora < fim) é 422 avaliacao_indisponivel / antes_do_fim');

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select sem_presenca, '76200000-0000-4000-8000-0000000000b1', 'estabelecimento',
            '76200000-0000-4000-8000-0000000000e1', true from t $$,
  'PGRST',
  '{"code" : "avaliacao_indisponivel", "message" : "avaliacao_indisponivel", "details" : "sem_presenca_verificada", "hint" : null}',
  'RN07: turno terminado mas sem presença verificada é 422 / sem_presenca_verificada');

-- ── Bordas ────────────────────────────────────────────────────────────────────────────────
select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     values (gen_random_uuid(), '76200000-0000-4000-8000-0000000000b1', 'estabelecimento',
             '76200000-0000-4000-8000-0000000000e1', true) $$,
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'turno inexistente é 404 nao_encontrado, antes de a chave estrangeira responder');

-- O tipo de alvo desconhecido passa direto pelo gatilho para que a CHECK responda por ele.
select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select encerrado, '76200000-0000-4000-8000-0000000000b1', 'plataforma',
            '76200000-0000-4000-8000-0000000000e1', true from t $$,
  '23514',
  'new row for relation "avaliacao" violates check constraint "avaliacao_alvo_tipo_check"',
  'alvo_tipo fora dos dois conhecidos é recusado pela CHECK, e não pelo gatilho');

-- Fronteira exata: agora == fim já libera (a regra é `agora < fim`).
select set_config('frila.agora', '2026-10-20 18:00:00+00', true);
select lives_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select em_curso, '76200000-0000-4000-8000-0000000000b1', 'estabelecimento',
            '76200000-0000-4000-8000-0000000000e1', true from t $$,
  'fronteira: no instante exato do fim a avaliação é liberada');

-- Membro da casa certa, alvo 'profissional' com o id de OUTRO profissional: o alvo tem de ser o
-- profissional DO turno, e não qualquer um (a trava vale nos dois lados, não só no do estabelecimento).
select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select encerrado, '76200000-0000-4000-8000-0000000000a1', 'profissional',
            '76200000-0000-4000-8000-0000000000c2', true from t $$,
  '23514',
  'autor e alvo da avaliação têm de ser as duas partes do turno (RN07)',
  'o membro da casa não avalia um profissional que não é o do turno');

select * from finish();
rollback;
