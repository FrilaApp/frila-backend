-- O impasse entre o gatilho da vaga cancelada e a desistência que reabre (cartão
-- CPD2c74A, RNF14). Observado na revisão do #62.
--
-- A corrida a três (scripts/corrida-ciclo.sh, cenários 5 e 6):
--
--   cancelar_vaga (casa)       candidatar (prof)      cancelar_posicao (o mesmo prof)
--   ────────────────────       ─────────────────      ───────────────────────────────
--   laço das confirmadas:
--   não vê P (aberta)
--                              confirma P, commit
--   update das abertas:
--   não vê P (confirmada)
--                                                     trava P, cancela, abre P'
--   update da vaga (trava V)
--   gatilho: espera P
--                                                     update de V: espera V → 40P01
--
-- Todos os caminhos travam a posição antes da vaga; o gatilho do #60 era o único que
-- esperava uma posição segurando a vaga. Agora ele pula a posição que outra transação
-- segura (`skip locked`), e quem a segura confere a vaga, travada, antes de reabrir.
--
-- O pgTAP roda numa sessão só e não abre a segunda transação. O que ele faz é pôr cada
-- lado no estado em que fica depois da espera: a desistência encontra a vaga já
-- cancelada, e o gatilho encontra a posição aberta que nasceu depois do update das
-- abertas. O impasse de verdade, com as conexões, é o cenário 6 do harness.
--
-- Ids próprios, começando em `c5e00000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(11);

create function pg_temp.conta(id uuid, email text, perfil public.perfil_conta, fone text)
returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false);
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (id, perfil, 'Conta ' || email, fone, email,
          case when perfil = 'contratante' then date '1980-01-01' else date '1995-01-01' end,
          '2026-09-22', now());
end $$;

-- A mesma chamada que `cancelar_posicao` faz depois de conferir a posição, com a conta
-- dele no JWT.
create function pg_temp.desistir(conta uuid, posicao uuid) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', conta, 'role', 'authenticated')::text, true);
  r := privado.cancelar_uma_posicao(posicao, conta, 'imprevisto de família', true);
  perform set_config('request.jwt.claims', '', true);
  return r;
end $$;

-- O último comando de `cancelar_vaga`, com a conta da casa no JWT: é o que dispara o
-- gatilho.
create function pg_temp.cancelar_a_vaga(conta uuid, vaga uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', conta, 'role', 'authenticated')::text, true);
  update public.vaga g set estado = 'cancelada' where g.id = vaga;
  perform set_config('request.jwt.claims', '', true);
end $$;

select pg_temp.conta('c5e00000-0000-4000-8000-0000000000d1', 'dona@impasse.test',
                     'contratante', '+5561944440001');
select pg_temp.conta('c5e00000-0000-4000-8000-0000000000e1', 'e1@impasse.test',
                     'profissional', '+5561944440011');

insert into public.profissional (id, usuario_id, ponto_base)
values ('c5e00000-0000-4000-8000-0000000000f1', 'c5e00000-0000-4000-8000-0000000000e1',
        'POINT(-47.8850 -15.7900)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ('c5e00000-0000-4000-8000-0000000000c1', 'Casa do Impasse', '55443322000353',
        'food_service', 'SCLN 307', 'POINT(-47.8860 -15.7910)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c5e00000-0000-4000-8000-0000000000d1', 'c5e00000-0000-4000-8000-0000000000c1',
        'administrador');

-- a1: a desistência que chega depois do cancelamento da vaga.
-- a2: a posição aberta que nasce depois do update das abertas de `cancelar_vaga`.
-- Os turnos começam em 12 horas: a desistência de e1 é falta (RN12).
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, estado,
                         chave_cliente, publicado_por)
select x.id, 'c5e00000-0000-4000-8000-0000000000c1',
       (select id from public.funcao where nome = 'garçom'),
       now() + interval '12 hours', now() + interval '18 hours',
       'SCLN 307', 'POINT(-47.8860 -15.7910)'::extensions.geography,
       18000, 1, true, true, false, 'Seu Zé', 'urgencia', x.estado::public.estado_vaga,
       gen_random_uuid(), 'c5e00000-0000-4000-8000-0000000000d1'
  from (values ('c5e00000-0000-4000-8000-0000000000a1'::uuid, 'cancelada'),
               ('c5e00000-0000-4000-8000-0000000000a2'::uuid, 'publicada')) x(id, estado);

-- b1: a posição de e1, que o gatilho da vaga pulou porque e1 a segurava. A vaga já está
-- cancelada: é o que e1 encontra quando a casa comita.
insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em)
select 'c5e00000-0000-4000-8000-0000000000b1', v.id, v.inicio_em, v.fim_em, 'confirmada',
       'c5e00000-0000-4000-8000-0000000000f1', now() - interval '1 day'
  from public.vaga v where v.id = 'c5e00000-0000-4000-8000-0000000000a1';

insert into public.turno (posicao_id, valor_acordado_centavos)
values ('c5e00000-0000-4000-8000-0000000000b1', 18000);

-- b2: a posição aberta que uma desistência reabriu e comitou depois de o update das
-- abertas de `cancelar_vaga` passar.
insert into public.posicao (id, vaga_id, inicio_em, fim_em)
select 'c5e00000-0000-4000-8000-0000000000b2', v.id, v.inicio_em, v.fim_em
  from public.vaga v where v.id = 'c5e00000-0000-4000-8000-0000000000a2';

-- ── A desistência que chega depois da vaga cancelada ────────────────────────

select is(
  pg_temp.desistir('c5e00000-0000-4000-8000-0000000000e1',
                   'c5e00000-0000-4000-8000-0000000000b1') - 'posicao_id' - 'nova_posicao_id',
  '{"falta": true, "reaberta": false}'::jsonb,
  'a desistência de e1 depois da vaga cancelada vale, com falta (RN12), e não reabre');

select is((select count(*)::int from public.posicao
            where vaga_id = 'c5e00000-0000-4000-8000-0000000000a1'
              and estado in ('aberta', 'confirmada')),
          0, 'e nenhuma posição viva sobra na vaga cancelada');

select is((select estado::text from public.vaga where id = 'c5e00000-0000-4000-8000-0000000000a1'),
          'cancelada', 'e a vaga continua cancelada: não volta a publicada');

select is((select count(*)::int from pgmq.q_despacho
            where message->>'vaga_id' = 'c5e00000-0000-4000-8000-0000000000a1'),
          0, 'e nenhum despacho sai para a vaga cancelada');

select is((select count(*)::int from public.ocorrencia
            where posicao_id = 'c5e00000-0000-4000-8000-0000000000b1' and tipo = 'cancelamento'),
          1, 'e a posição tem um cancelamento só, o de e1');

select is((select count(*)::int from public.notificacao n
            where n.usuario_id = 'c5e00000-0000-4000-8000-0000000000d1'
              and n.tipo = 'cancelamento'
              and n.referencia_id = 'c5e00000-0000-4000-8000-0000000000b1'
              and n.payload @> '{"reaberta": false}'),
          1, 'e a casa é avisada com reaberta = false');

-- ── O gatilho e a posição aberta que nasceu depois ──────────────────────────

select lives_ok(
  $$ select pg_temp.cancelar_a_vaga('c5e00000-0000-4000-8000-0000000000d1',
                                    'c5e00000-0000-4000-8000-0000000000a2') $$,
  'a vaga com uma posição aberta nascida depois do update das abertas é cancelada');

select is((select estado::text from public.posicao where id = 'c5e00000-0000-4000-8000-0000000000b2'),
          'cancelada', 'e o gatilho recolhe a posição aberta junto');

select is((select count(*)::int from public.ocorrencia
            where posicao_id = 'c5e00000-0000-4000-8000-0000000000b2'),
          0, 'e a aberta sai sem ocorrência, como no update das abertas de cancelar_vaga');

-- ── A ordem das travas ──────────────────────────────────────────────────────
--
-- O que o pgTAP não alcança numa sessão só, ele confere no texto: o gatilho não espera
-- posição travada, e a reabertura trava a vaga antes de criar a posição nova.

select ok(
  pg_get_functiondef('privado.vaga_cancelada_recolhe_confirmadas()'::regprocedure)
    ~* 'for\s+no\s+key\s+update\s+skip\s+locked',
  'o gatilho da vaga cancelada pula a posição que outra transação segura (skip locked)');

select ok(
  pg_get_functiondef('privado.cancelar_uma_posicao(uuid, uuid, text, boolean)'::regprocedure)
    ~* 'from\s+public\.vaga\s+g\s+where\s+g\.id\s*=\s*v_pos\.vaga_id\s+for\s+no\s+key\s+update',
  'a reabertura trava a vaga antes de criar a posição nova');

select * from finish();
rollback;
