-- `cancelar_vaga × cancelar_posicao`: nenhuma posição reaberta em vaga cancelada, e um
-- cancelamento só por posição (cartão xJ53t3tX, RNF14).
--
-- A corrida (scripts/corrida-ciclo.sh, cenário 4). `cancelar_posicao` lê a posição sem
-- trava, e `privado.cancelar_uma_posicao` a atualizava sem reconferir o estado:
--
--   cancelar_vaga (casa)                   cancelar_posicao (profissional)
--   ────────────────────                   ───────────────────────────────
--   cancela a posição P (segura a linha)
--                                          lê P: ainda confirmada, segue
--                                          update de P: espera
--   cancela a vaga, commit
--                                          recancela P, abre posição nova na vaga
--                                          cancelada e enfileira o despacho
--
-- Na ordem inversa, o laço das confirmadas de `cancelar_vaga` recancelava a posição que
-- o profissional acabara de largar: ocorrência dobrada, aviso de cancelamento pela casa
-- ao profissional que desistiu, e a falta dele (RN12) apagada pelo `update`.
--
-- O pgTAP roda numa sessão só e não abre a segunda transação. O que ele faz é pôr
-- `privado.cancelar_uma_posicao` no estado em que ela fica depois da espera: quem a
-- chama já conferiu que a posição estava confirmada, e a linha que ela encontra é a que
-- o outro lado deixou ao comitar. A corrida de verdade, com duas conexões, é o cenário 4
-- do harness.
--
-- Ids próprios, começando em `c5d00000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(16);

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

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

-- O lado que chega depois da espera: a mesma chamada que `cancelar_posicao`,
-- `cancelar_vaga` e `excluir_conta` fazem, com a conta dele no JWT e a posição que o
-- outro lado já cancelou.
create function pg_temp.depois_da_espera(conta uuid, posicao uuid, motivo text,
                                         reabrir boolean) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', conta, 'role', 'authenticated')::text, true);
  r := privado.cancelar_uma_posicao(posicao, conta, motivo, reabrir);
  perform set_config('request.jwt.claims', '', true);
  return r;
end $$;

select pg_temp.conta('c5d00000-0000-4000-8000-0000000000d1', 'dona@corrida-posicao.test',
                     'contratante', '+5561933330001');
select pg_temp.conta('c5d00000-0000-4000-8000-0000000000e1', 'e1@corrida-posicao.test',
                     'profissional', '+5561933330011');
select pg_temp.conta('c5d00000-0000-4000-8000-0000000000e2', 'e2@corrida-posicao.test',
                     'profissional', '+5561933330012');

insert into public.profissional (id, usuario_id, ponto_base)
values ('c5d00000-0000-4000-8000-0000000000f1', 'c5d00000-0000-4000-8000-0000000000e1',
        'POINT(-47.8850 -15.7900)'::extensions.geography),
       ('c5d00000-0000-4000-8000-0000000000f2', 'c5d00000-0000-4000-8000-0000000000e2',
        'POINT(-47.8850 -15.7900)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ('c5d00000-0000-4000-8000-0000000000c1', 'Casa que Fecha Cedo', '55443322000272',
        'food_service', 'SCLN 306', 'POINT(-47.8860 -15.7910)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c5d00000-0000-4000-8000-0000000000d1', 'c5d00000-0000-4000-8000-0000000000c1',
        'administrador');

-- a1: a casa cancela antes, o profissional e1 chega depois.
-- a2: o profissional e2 desiste antes, a casa chega depois.
-- Os dois turnos começam em 12 horas: dentro das 24 h, a desistência do profissional é
-- falta (RN12), e o cancelamento pela casa não é. A falta mostra quem cancelou de fato.
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, estado,
                         chave_cliente, publicado_por)
select x.id, 'c5d00000-0000-4000-8000-0000000000c1',
       (select id from public.funcao where nome = 'garçom'),
       now() + interval '12 hours', now() + interval '18 hours',
       'SCLN 306', 'POINT(-47.8860 -15.7910)'::extensions.geography,
       18000, 1, true, true, false, 'Seu Zé', 'urgencia', 'preenchida', gen_random_uuid(),
       'c5d00000-0000-4000-8000-0000000000d1'
  from (values ('c5d00000-0000-4000-8000-0000000000a1'::uuid),
               ('c5d00000-0000-4000-8000-0000000000a2'::uuid)) x(id);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em)
select x.id, v.id, v.inicio_em, v.fim_em, 'confirmada', x.prof, now() - interval '1 day'
  from (values
    ('c5d00000-0000-4000-8000-0000000000b1'::uuid, 'c5d00000-0000-4000-8000-0000000000a1'::uuid,
     'c5d00000-0000-4000-8000-0000000000f1'::uuid),
    ('c5d00000-0000-4000-8000-0000000000b2'::uuid, 'c5d00000-0000-4000-8000-0000000000a2'::uuid,
     'c5d00000-0000-4000-8000-0000000000f2'::uuid)) x(id, vaga, prof)
  join public.vaga v on v.id = x.vaga;

insert into public.turno (posicao_id, valor_acordado_centavos)
values ('c5d00000-0000-4000-8000-0000000000b1', 18000),
       ('c5d00000-0000-4000-8000-0000000000b2', 18000);

-- ── A casa antes, o profissional depois ─────────────────────────────────────

select is(
  pg_temp.como('c5d00000-0000-4000-8000-0000000000d1',
    $$ select public.cancelar_vaga('c5d00000-0000-4000-8000-0000000000a1', 'a casa fechou') $$)
    - 'vaga_id',
  '{"estado": "cancelada", "posicoes_canceladas": 1}'::jsonb,
  'a casa cancela a vaga com a posição confirmada de e1');

-- `cancelar_posicao` de e1 já conferiu que a posição estava confirmada, e esperou a
-- casa comitar. O que ele encontra agora é a posição cancelada.
select throws_ok(
  $$ select pg_temp.depois_da_espera('c5d00000-0000-4000-8000-0000000000e1',
       'c5d00000-0000-4000-8000-0000000000b1', 'imprevisto de família', true) $$,
  'PGRST',
  '{"code" : "posicao_nao_cancelavel", "message" : "posicao_nao_cancelavel", "details" : null, "hint" : null}',
  'o profissional que chega depois da casa recebe 409 posicao_nao_cancelavel, como se chegasse depois do commit');

select is((select count(*)::int from public.posicao
            where vaga_id = 'c5d00000-0000-4000-8000-0000000000a1'
              and estado in ('aberta', 'confirmada')),
          0, 'e nenhuma posição é reaberta na vaga cancelada');

select is((select count(*)::int from public.ocorrencia
            where posicao_id = 'c5d00000-0000-4000-8000-0000000000b1' and tipo = 'cancelamento'),
          1, 'e a posição tem um cancelamento só, o da casa');

select is((select falta from public.posicao where id = 'c5d00000-0000-4000-8000-0000000000b1'),
          false, 'e o cancelamento pela casa não vira falta de e1 (RN12)');

-- A exclusão de conta do profissional passa pelo mesmo caminho, com reabertura. Se a
-- casa cancelou antes, não há o que desfazer, e a exclusão segue.
select set_config('frila.exclusao_de_conta', 'on', true);
select lives_ok(
  $$ select pg_temp.depois_da_espera('c5d00000-0000-4000-8000-0000000000e1',
       'c5d00000-0000-4000-8000-0000000000b1', 'exclusão de conta', true) $$,
  'a exclusão de conta que chega depois da casa não derruba a exclusão');
select set_config('frila.exclusao_de_conta', 'off', true);

select is((select count(*)::int from public.posicao
            where vaga_id = 'c5d00000-0000-4000-8000-0000000000a1'
              and estado in ('aberta', 'confirmada')),
          0, 'e também não reabre posição na vaga cancelada');

-- ── O profissional antes, a casa depois ─────────────────────────────────────

select is(
  pg_temp.como('c5d00000-0000-4000-8000-0000000000e2',
    $$ select public.cancelar_posicao('c5d00000-0000-4000-8000-0000000000b2', 'imprevisto de família') $$)
    - 'nova_posicao_id' - 'posicao_id',
  '{"falta": true, "reaberta": true}'::jsonb,
  'e2 desiste a 12 horas do início: falta dele, e a vaga ganha posição nova');

-- O laço das confirmadas de `cancelar_vaga` leu a posição de e2 ainda confirmada e
-- esperou o commit dele. O que encontra agora é a posição já cancelada por e2.
select lives_ok(
  $$ select pg_temp.depois_da_espera('c5d00000-0000-4000-8000-0000000000d1',
       'c5d00000-0000-4000-8000-0000000000b2', 'a casa fechou', false) $$,
  'a casa que chega depois da desistência não derruba o cancelamento da vaga');

select is((select falta from public.posicao where id = 'c5d00000-0000-4000-8000-0000000000b2'),
          true, 'e a falta de e2 continua dele (RN12): a casa não a apaga');

select is((select count(*)::int from public.ocorrencia
            where posicao_id = 'c5d00000-0000-4000-8000-0000000000b2' and tipo = 'cancelamento'),
          1, 'e a posição tem um cancelamento só, o de e2');

select is((select array_agg(o.autor_id) from public.ocorrencia o
            where o.posicao_id = 'c5d00000-0000-4000-8000-0000000000b2' and o.tipo = 'cancelamento'),
          array['c5d00000-0000-4000-8000-0000000000e2'::uuid], 'e o autor dele é e2');

select is((select count(*)::int from public.notificacao n
            where n.usuario_id = 'c5d00000-0000-4000-8000-0000000000e2'
              and n.tipo = 'cancelamento'
              and n.referencia_id = 'c5d00000-0000-4000-8000-0000000000b2'),
          0, 'e e2 não é avisado de um cancelamento pela casa que não aconteceu');

-- O resto de `cancelar_vaga` segue: a posição que e2 reabriu cai junto com a vaga.
select is(
  pg_temp.como('c5d00000-0000-4000-8000-0000000000d1',
    $$ select public.cancelar_vaga('c5d00000-0000-4000-8000-0000000000a2', 'a casa fechou') $$)
    - 'vaga_id' - 'posicoes_canceladas',
  '{"estado": "cancelada"}'::jsonb,
  'a casa cancela a vaga que e2 largou');

select is((select count(*)::int from public.posicao
            where vaga_id = 'c5d00000-0000-4000-8000-0000000000a2'
              and estado in ('aberta', 'confirmada')),
          0, 'e a posição reaberta por e2 cai junto: nenhuma viva na vaga cancelada');

select is((select falta from public.posicao where id = 'c5d00000-0000-4000-8000-0000000000b2'),
          true, 'e a falta de e2 sobrevive ao cancelamento da vaga');

select * from finish();
rollback;
