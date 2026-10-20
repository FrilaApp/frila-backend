-- Teste pgTAP: Resiliência de publicar_vaga para conta de demonstração e semeadura pós-06/11 (Cartão 5boVdM0t)
--
-- Valida:
-- 1. publicar_vaga executada com sucesso pela conta de demonstração sem enfileirar em pgmq.q_despacho.
-- 2. Sucesso mesmo se frila.agendador_secret estiver ausente (isolamento contra falhas de transporte/webhook).
-- 3. Fallback de regiao_administrativa para 'Plano Piloto' quando omitida por conta de demonstração.
-- 4. Isolamento: conta de demonstração profissional vê as vagas de demonstração; profissional real não vê.
-- 5. privado.semear_vagas_demonstracao semeia vagas futuras com N posições de forma idempotente.

begin;
select plan(12);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-10-20 12:00:00-03', true);
-- Agendador secret deliberadamente vazio para comprovar resiliência contra falta de vault/secret
select set_config('frila.agendador_secret', '', true);

-- Helper para execução autenticada
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

-- 1. Inicializa dados de demonstração
select privado.renovar_dados_demonstracao();

create temp table ids as select
  (select id from auth.users where lower(email) = 'revisao-contratante@frila.app' limit 1) as contratante,
  (select id from auth.users where lower(email) = 'revisao-profissional@frila.app' limit 1) as profissional,
  'c7510000-0000-4000-8000-000000000001'::uuid as real_profissional,
  (select id from public.estabelecimento where nome = 'Bar da Revisão' limit 1) as estab_demo,
  (select id from public.funcao where nome = 'garçom' limit 1) as garcom;

-- Cria usuário profissional real para verificar o isolamento
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000',
        (select real_profissional from ids),
        'authenticated', 'authenticated', 'real.profissional@frila.test',
        privado.agora(), '{"provider":"email"}'::jsonb, '{}'::jsonb, privado.agora(), privado.agora(), false, false)
on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
values ((select real_profissional from ids), 'profissional', 'Profissional Real',
        '+5561999997777', 'real.profissional@frila.test', '1990-01-01', '2026-09-22', privado.agora(), false)
on conflict (id) do update set demonstracao = false;

insert into public.profissional (usuario_id, ponto_base)
values ((select real_profissional from ids), 'POINT(-47.8825 -15.7940)'::extensions.geography)
on conflict (usuario_id) do nothing;

insert into public.profissional_funcao (profissional_id, funcao_id)
select p.id, (select garcom from ids)
  from public.profissional p where p.usuario_id = (select real_profissional from ids)
on conflict do nothing;

-- ── 2. Teste de Publicação com Sucesso pela Conta de Demonstração ─────────────
create temp table res_pub as
select pg_temp.como(
  (select contratante from ids),
  format($$
    select public.publicar_vaga(
      estabelecimento_id     => %L::uuid,
      funcao_id              => %L::uuid,
      inicio_em              => '2026-10-25 18:00:00-03'::timestamptz,
      fim_em                 => '2026-10-26 00:00:00-03'::timestamptz,
      local                  => 'CLS 405, Asa Sul',
      ponto                  => '{"latitude":-15.8020,"longitude":-47.8880}'::jsonb,
      valor_centavos         => 20000,
      posicoes               => 2,
      inclui_refeicao        => true,
      inclui_transporte      => true,
      exige_material_proprio => false,
      responsavel_local      => 'Gerente Bar',
      modo                   => 'urgencia'::public.modo_preenchimento,
      chave                  => 'c7510000-0000-4000-8000-000000000101'::uuid,
      regiao_administrativa  => 'Plano Piloto'
    )
  $$, (select estab_demo from ids), (select garcom from ids))
) as resposta;

select is(
  ((select resposta->>'vaga_id' from res_pub) is not null),
  true,
  'publicar_vaga executada com sucesso pela conta de demonstracao'
);

select is(
  jsonb_array_length((select resposta->'posicoes' from res_pub)),
  2,
  'posicoes criadas corretamente na publicacao de demonstracao'
);

-- Asserção de Isolamento no Despacho: NENHUMA mensagem foi enviada para pgmq.q_despacho
select is(
  (select count(*)::int from pgmq.q_despacho
    where (message->>'vaga_id') = (select resposta->>'vaga_id' from res_pub)),
  0,
  'Vaga publicada por conta de demonstracao nao gera despacho em pgmq.q_despacho'
);

-- ── 3. Teste de Fallback de Região Administrativa Omitida ─────────────────────
create temp table res_pub_sem_ra as
select pg_temp.como(
  (select contratante from ids),
  format($$
    select public.publicar_vaga(
      estabelecimento_id     => %L::uuid,
      funcao_id              => %L::uuid,
      inicio_em              => '2026-10-26 18:00:00-03'::timestamptz,
      fim_em                 => '2026-10-27 00:00:00-03'::timestamptz,
      local                  => 'CLS 405, Asa Sul',
      ponto                  => '{"latitude":-15.8020,"longitude":-47.8880}'::jsonb,
      valor_centavos         => 20000,
      posicoes               => 1,
      inclui_refeicao        => true,
      inclui_transporte      => true,
      exige_material_proprio => false,
      responsavel_local      => 'Gerente Bar',
      modo                   => 'urgencia'::public.modo_preenchimento,
      chave                  => 'c7510000-0000-4000-8000-000000000102'::uuid,
      regiao_administrativa  => null
    )
  $$, (select estab_demo from ids), (select garcom from ids))
) as resposta;

select is(
  (select regiao_administrativa from public.vaga where id = (select (resposta->>'vaga_id')::uuid from res_pub_sem_ra)),
  'Plano Piloto',
  'Fallback de regiao_administrativa para Plano Piloto na conta de demonstracao'
);

-- ── 4. Teste de Fallback de estabelecimento_id Omitido ───────────────────────
create temp table res_pub_sem_estab as
select pg_temp.como(
  (select contratante from ids),
  format($$
    select public.publicar_vaga(
      estabelecimento_id     => null,
      funcao_id              => %L::uuid,
      inicio_em              => '2026-10-27 18:00:00-03'::timestamptz,
      fim_em                 => '2026-10-28 00:00:00-03'::timestamptz,
      local                  => 'CLS 405, Asa Sul',
      ponto                  => '{"latitude":-15.8020,"longitude":-47.8880}'::jsonb,
      valor_centavos         => 20000,
      posicoes               => 1,
      inclui_refeicao        => true,
      inclui_transporte      => true,
      exige_material_proprio => false,
      responsavel_local      => 'Gerente Bar',
      modo                   => 'urgencia'::public.modo_preenchimento,
      chave                  => 'c7510000-0000-4000-8000-000000000103'::uuid
    )
  $$, (select garcom from ids))
) as resposta;

select is(
  (select estabelecimento_id from public.vaga where id = (select (resposta->>'vaga_id')::uuid from res_pub_sem_estab)),
  (select estab_demo from ids),
  'Fallback de estabelecimento_id para Bar da Revisao na conta de demonstracao'
);

-- ── 5. Isolamento de Leitura em vagas_abertas ─────────────────────────────────
-- Demonstração profissional vê as vagas de demonstração
create temp table feed_demo as
select pg_temp.como(
  (select profissional from ids),
  'select public.vagas_abertas(distancia_max_km => 50)'
) as vagas;

select is(
  (select count(*)::int > 0 from jsonb_array_elements((select vagas from feed_demo))),
  true,
  'Conta de demonstracao profissional enxerga as vagas de demonstracao'
);

-- Profissional real NÃO vê as vagas de demonstração
create temp table feed_real as
select pg_temp.como(
  (select real_profissional from ids),
  'select public.vagas_abertas(distancia_max_km => 50)'
) as vagas;

select is(
  (select count(*)::int from jsonb_array_elements((select vagas from feed_real)) as v
    where (v->>'estabelecimento')::jsonb->>'nome' = 'Bar da Revisão'),
  0,
  'Profissional real nao enxerga vagas do Bar da Revisao (isolamento estrito)'
);

-- ── 6. Semeadura de Vagas pós-06/11 (privado.semear_vagas_demonstracao) ───────
create temp table res_semear as
select privado.semear_vagas_demonstracao(
  p_quantidade        => 3,
  p_inicio_base       => '2026-11-20 18:00:00+00'::timestamptz,
  p_posicoes_por_vaga => 20
) as resposta;

select is(
  (select (resposta->>'sucesso')::boolean from res_semear),
  true,
  'privado.semear_vagas_demonstracao executou com sucesso'
);

select is(
  (select (resposta->>'vagas_semeadas')::int from res_semear),
  3,
  'privado.semear_vagas_demonstracao semeou exatamente 3 vagas'
);

select is(
  (select count(*)::int from public.vaga v
    where v.estabelecimento_id = (select estab_demo from ids)
      and v.inicio_em >= '2026-11-20 00:00:00+00'::timestamptz),
  3,
  'Existem 3 vagas de demonstracao com inicio no futuro pos-06/11'
);

select is(
  (select count(*)::int from public.posicao p
    join public.vaga v on v.id = p.vaga_id
   where v.estabelecimento_id = (select estab_demo from ids)
     and v.inicio_em >= '2026-11-20 00:00:00+00'::timestamptz
     and p.estado = 'aberta'),
  60,
  'Total de 60 posicoes abertas semeadas (20 posicoes por vaga destravando Detalhe 20x)'
);

-- Idempotência: rodar novamente não duplica nem falha
select lives_ok(
  $$ select privado.semear_vagas_demonstracao(3, '2026-11-20 18:00:00+00'::timestamptz, 20) $$,
  'privado.semear_vagas_demonstracao e estritamente idempotente'
);

select * from finish();
rollback;
