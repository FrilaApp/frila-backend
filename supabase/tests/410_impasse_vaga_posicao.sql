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
-- A correção é a ordem das travas: em turno futuro, todo caminho trava a vaga antes da
-- posição (`candidatar` por `travar_candidatura`, `cancelar_uma_posicao`), e o gatilho,
-- que já segura a vaga, trava as posições por id e espera.
--
-- O pgTAP roda numa sessão só e não abre a segunda transação. O que ele faz é pôr cada
-- lado no estado em que fica depois da espera: a desistência encontra a vaga já
-- cancelada, e o gatilho encontra a posição aberta que nasceu depois do update das
-- abertas. O impasse de verdade, com as conexões, é o cenário 6 do harness.
--
-- Ids próprios, começando em `c5e00000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(12);

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

-- O laço das confirmadas de `cancelar_vaga`: a casa cancela sem reabrir.
create function pg_temp.como_casa(conta uuid, posicao uuid) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', conta, 'role', 'authenticated')::text, true);
  r := privado.cancelar_uma_posicao(posicao, conta, 'a casa fechou', false);
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
-- Numa sessão só não se vê quem espera quem, mas se vê o que cada caminho trava. O
-- `pgrowlocks` lê as travas de linha da própria transação: `candidatar` e a desistência
-- de turno futuro seguram a vaga (e o fazem antes da posição, no código); a de turno já
-- começado não, porque `reabrir_por_atraso` trava a posição primeiro.

create extension if not exists pgrowlocks with schema extensions;

-- A inserção de uma posição já segura `key share` na vaga (a chave estrangeira); o que
-- importa aqui é a trava de escrita, a que o gatilho e as outras escritas disputam.
create function pg_temp.vaga_travada(p_vaga uuid) returns text
language sql as $$
  select case when exists (
    select 1
      from extensions.pgrowlocks('public.vaga') r, unnest(r.modes) m
     where r.locked_row = (select g.ctid from public.vaga g where g.id = p_vaga)
       and r.locker::text = (pg_current_xact_id()::text::bigint % 4294967296)::text
       and m in ('For No Key Update', 'For Update', 'No Key Update', 'Update'))
    then 'travada' else 'livre' end
$$;

-- a3: vaga publicada para a candidatura. a4 e a5: preenchidas, com a posição
-- confirmada de e1 em turno futuro (a4) e já começado (a5).
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, estado,
                         chave_cliente, publicado_por)
select x.id, 'c5e00000-0000-4000-8000-0000000000c1',
       (select id from public.funcao where nome = 'garçom'),
       now() + x.desloca, now() + x.desloca + interval '6 hours',
       'SCLN 307', 'POINT(-47.8860 -15.7910)'::extensions.geography,
       18000, 1, true, true, false, 'Seu Zé', 'urgencia', x.estado::public.estado_vaga,
       gen_random_uuid(), 'c5e00000-0000-4000-8000-0000000000d1'
  from (values ('c5e00000-0000-4000-8000-0000000000a3'::uuid, 'publicada',  interval '2 days'),
               ('c5e00000-0000-4000-8000-0000000000a4'::uuid, 'preenchida', interval '3 days'),
               ('c5e00000-0000-4000-8000-0000000000a5'::uuid, 'preenchida', interval '-1 hour')
       ) x(id, estado, desloca);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em)
select x.pos, v.id, v.inicio_em, v.fim_em, 'confirmada',
       'c5e00000-0000-4000-8000-0000000000f1', now() - interval '1 day'
  from (values ('c5e00000-0000-4000-8000-0000000000b4'::uuid, 'c5e00000-0000-4000-8000-0000000000a4'::uuid),
               ('c5e00000-0000-4000-8000-0000000000b5'::uuid, 'c5e00000-0000-4000-8000-0000000000a5'::uuid)
       ) x(pos, vaga)
  join public.vaga v on v.id = x.vaga;

select privado.travar_candidatura('c5e00000-0000-4000-8000-0000000000a3',
                                  'c5e00000-0000-4000-8000-0000000000f1');

select is(pg_temp.vaga_travada('c5e00000-0000-4000-8000-0000000000a3'), 'travada',
  'candidatar trava a vaga na primeira trava que pede (travar_candidatura)');

-- A casa cancela a posição de a4 sem reabrir, como o laço de cancelar_vaga: nada muda
-- na vaga, e mesmo assim ela fica travada.
select pg_temp.como_casa('c5e00000-0000-4000-8000-0000000000d1',
                         'c5e00000-0000-4000-8000-0000000000b4');

select is(pg_temp.vaga_travada('c5e00000-0000-4000-8000-0000000000a4'), 'travada',
  'o cancelamento de turno futuro trava a vaga, mesmo sem reabrir');

select pg_temp.como_casa('c5e00000-0000-4000-8000-0000000000d1',
                         'c5e00000-0000-4000-8000-0000000000b5');

select is(pg_temp.vaga_travada('c5e00000-0000-4000-8000-0000000000a5'), 'livre',
  'o de turno já começado não trava a vaga: a ordem ali é a de reabrir_por_atraso');

select * from finish();
rollback;
