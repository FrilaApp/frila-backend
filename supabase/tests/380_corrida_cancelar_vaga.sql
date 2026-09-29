-- `cancelar_vaga × candidatar`: nenhuma posição confirmada em vaga cancelada
-- (cartão nspP9YDU, RNF14).
--
-- A corrida (scripts/corrida-ciclo.sh, cenário 2) deixava, em 19 de 50 rodadas, a vaga
-- `cancelada` com a posição que o candidato acabara de confirmar. O entrelaçamento:
--
--   cancelar_vaga                          candidatar
--   ─────────────                          ──────────
--                                          confirma a posição P (segura a linha)
--   varre as confirmadas: P não está
--   update das abertas: chega a P, espera
--                                          commit
--   relê P: já não é `aberta`, pula
--   cancela a vaga                         → P confirmada em vaga cancelada
--
-- O pgTAP roda numa sessão só e não abre a segunda transação. O que ele faz é pôr o
-- candidato exatamente no ponto da corrida: um gatilho de teste, criado e desfeito dentro
-- desta transação, confirma a posição aberta no instante em que `cancelar_vaga` chega a
-- ela e devolve nulo — o `update` pula a linha, como pula sob a corrida de verdade. Com a
-- ordem antiga (confirmadas antes das abertas), a posição sobra confirmada. Com a nova
-- (trava, abertas, depois confirmadas), o laço das confirmadas a encontra e cancela.
--
-- Ids próprios, começando em `c5c00000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(8);

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

select pg_temp.conta('c5c00000-0000-4000-8000-0000000000d1', 'dona@corrida-cancelar.test',
                     'contratante', '+5561922220001');
select pg_temp.conta('c5c00000-0000-4000-8000-0000000000e1', 'e1@corrida-cancelar.test',
                     'profissional', '+5561922220011');
select pg_temp.conta('c5c00000-0000-4000-8000-0000000000e2', 'e2@corrida-cancelar.test',
                     'profissional', '+5561922220012');

insert into public.profissional (id, usuario_id, ponto_base)
values ('c5c00000-0000-4000-8000-0000000000f1', 'c5c00000-0000-4000-8000-0000000000e1',
        'POINT(-47.8850 -15.7900)'::extensions.geography),
       ('c5c00000-0000-4000-8000-0000000000f2', 'c5c00000-0000-4000-8000-0000000000e2',
        'POINT(-47.8850 -15.7900)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ('c5c00000-0000-4000-8000-0000000000c1', 'Casa que Cancela', '55443322000191',
        'food_service', 'SCLN 305', 'POINT(-47.8860 -15.7910)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c5c00000-0000-4000-8000-0000000000d1', 'c5c00000-0000-4000-8000-0000000000c1',
        'administrador');

-- a1: uma posição, aberta — o candidato chega nela no meio do cancelamento.
-- a2: duas posições, uma confirmada e uma aberta — o caminho de sempre, sem corrida.
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, chave_cliente,
                         publicado_por)
select x.id, 'c5c00000-0000-4000-8000-0000000000c1',
       (select id from public.funcao where nome = 'garçom'),
       now() + interval '3 days' + x.dia, now() + interval '3 days 6 hours' + x.dia,
       'SCLN 305', 'POINT(-47.8860 -15.7910)'::extensions.geography,
       18000, x.posicoes, true, true, false, 'Seu Zé', 'urgencia', gen_random_uuid(),
       'c5c00000-0000-4000-8000-0000000000d1'
  from (values ('c5c00000-0000-4000-8000-0000000000a1'::uuid, 1, interval '0'),
               ('c5c00000-0000-4000-8000-0000000000a2'::uuid, 2, interval '1 day')) x(id, posicoes, dia);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em)
select x.id, v.id, v.inicio_em, v.fim_em, x.estado::public.estado_posicao, x.prof, x.confirmado
  from (values
    ('c5c00000-0000-4000-8000-0000000000b1'::uuid, 'c5c00000-0000-4000-8000-0000000000a1'::uuid,
     'aberta', null::uuid, null::timestamptz),
    ('c5c00000-0000-4000-8000-0000000000b2'::uuid, 'c5c00000-0000-4000-8000-0000000000a2'::uuid,
     'confirmada', 'c5c00000-0000-4000-8000-0000000000f2'::uuid, now()),
    ('c5c00000-0000-4000-8000-0000000000b3'::uuid, 'c5c00000-0000-4000-8000-0000000000a2'::uuid,
     'aberta', null::uuid, null::timestamptz)) x(id, vaga, estado, prof, confirmado)
  join public.vaga v on v.id = x.vaga;

insert into public.turno (posicao_id, valor_acordado_centavos)
values ('c5c00000-0000-4000-8000-0000000000b2', 18000);

-- ── O candidato no ponto da corrida ──────────────────────────────────────────
--
-- Quando o `update` das abertas de `cancelar_vaga` chega à posição b1, o candidato e1
-- acaba de confirmá-la — o mesmo que `candidatar` grava — e o `update` pula a linha, que
-- já não é `aberta`. É o que o Postgres faz sob READ COMMITTED quando a linha esperada
-- muda antes de ser liberada. Criado dentro desta transação; o rollback o desfaz.
create function public.teste_candidato_chega_no_meio() returns trigger
language plpgsql as $$
begin
  if old.id = 'c5c00000-0000-4000-8000-0000000000b1'
     and old.estado = 'aberta' and new.estado = 'cancelada' then
    update public.posicao
       set estado = 'confirmada',
           profissional_id = 'c5c00000-0000-4000-8000-0000000000f1',
           confirmado_em = now()
     where id = old.id;
    insert into public.candidatura (posicao_id, profissional_id, estado)
    values (old.id, 'c5c00000-0000-4000-8000-0000000000f1', 'aceita');
    insert into public.turno (posicao_id, valor_acordado_centavos)
    values (old.id, 18000);
    return null;
  end if;
  return new;
end $$;

create trigger teste_candidato_chega_no_meio
  before update of estado on public.posicao
  for each row execute function public.teste_candidato_chega_no_meio();

select is(
  pg_temp.como('c5c00000-0000-4000-8000-0000000000d1',
    $$ select public.cancelar_vaga('c5c00000-0000-4000-8000-0000000000a1', 'a casa fechou') $$)
    - 'vaga_id',
  '{"estado": "cancelada", "posicoes_canceladas": 1}'::jsonb,
  'cancelar_vaga com o candidato chegando no meio: a vaga sai cancelada, com a posição dele');

select is((select estado::text from public.posicao where id = 'c5c00000-0000-4000-8000-0000000000b1'),
          'cancelada',
          'a posição que o candidato confirmou no meio do cancelamento não sobra confirmada');

select is((select verificacao::text from public.turno
            where posicao_id = 'c5c00000-0000-4000-8000-0000000000b1'),
          'nao_verificado', 'e o turno dele sai junto, como no cancelamento de sempre');

select is((select falta from public.posicao where id = 'c5c00000-0000-4000-8000-0000000000b1'),
          false, 'e o cancelamento pela casa não vira falta dele (RN12)');

select ok(exists (select 1 from public.ocorrencia o
                   where o.posicao_id = 'c5c00000-0000-4000-8000-0000000000b1'
                     and o.tipo = 'cancelamento'),
          'e fica a ocorrência do cancelamento, que é a trilha que a auditoria lê');

drop trigger teste_candidato_chega_no_meio on public.posicao;

-- ── O caminho de sempre continua igual ───────────────────────────────────────

select is(
  pg_temp.como('c5c00000-0000-4000-8000-0000000000d1',
    $$ select public.cancelar_vaga('c5c00000-0000-4000-8000-0000000000a2', 'evento adiado') $$)
    - 'vaga_id',
  '{"estado": "cancelada", "posicoes_canceladas": 2}'::jsonb,
  'sem corrida, cancelar_vaga cancela a confirmada e a aberta');

select is((select count(*)::int from public.posicao
            where vaga_id = 'c5c00000-0000-4000-8000-0000000000a2' and estado = 'confirmada'),
          0, 'e nenhuma posição da vaga cancelada fica confirmada');

-- A releitura depois da trava: a segunda chamada vê a vaga já cancelada.
select throws_ok(
  $$ select pg_temp.como('c5c00000-0000-4000-8000-0000000000d1',
       $x$ select public.cancelar_vaga('c5c00000-0000-4000-8000-0000000000a2', 'de novo') $x$) $$,
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : null, "hint" : null}',
  'cancelar de novo a vaga cancelada é 409 vaga_encerrada');

select * from finish();
rollback;
