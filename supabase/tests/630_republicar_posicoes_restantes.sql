-- 630_republicar_posicoes_restantes.sql
--
-- Republicar as posições restantes em urgência (modo seleção, D1-C, RR-RN01 a RR-RN10, contrato 0.2.41).
-- Passo P5 do plano (requisitos/republicar-posicoes-restantes-plano.md).
-- Critérios de aceite 1 a 10 de requisitos/republicar-posicoes-restantes-v1.1.md e casos de teste da Bigorna:
--   1. Fórmula de sobras (3 nominais, 1 escolhida -> 2; 3 nominais, nenhuma escolhida -> 3; 3 nominais, todas escolhidas -> sem_posicoes_restantes)
--   2. Os 6 details de 422 republicacao_indisponivel:
--      nao_e_selecao, selecao_em_curso, vaga_cancelada, ja_comecou, sem_posicoes_restantes, ja_republicada
--   3. Idempotência por chave (mesma chave devolve a mesma vaga nova e posições, sem criar outra)
--   4. Liberação do índice único parcial quando a vaga nova é cancelada (permite nova republicação ativa)
--   5. Origem oculta (422 vaga_oculta)
--   6. Conta suspensa (403 conta_suspensa)
--   7. Profissional chamando (422 perfil_incompativel)
--   8. Membro de outra casa chamando (403 sem_permissao)
--   9. Anon chamando (401 sem sessão / sem execute)
--  10. Nulos (vaga_id e chave com 422 campo_obrigatorio)
--  11. Origem inexistente (404 nao_encontrado)
--  12. vaga.republicada_de preenchida na vaga nova
--  13. Despacho enfileirado para a vaga de urgência criada
--  14. Escolhido da origem não consegue se candidatar à vaga nova do mesmo horário (RN21)
--  15. painel_estabelecimento.republicavel_em_urgencia idêntico ao que a RPC faria (N quando apta, null quando inapta)
--  16. Quatro casos do plano exigidos pela revisão da Bigorna:
--      Caso 1: Desistência antes das 24h (linha nova em posicao) não distorce a fórmula de sobras
--      Caso 2: Posições canceladas no fechamento automático
--      Caso 3: Republicação com tudo preenchido
--      Caso 4: Limitação conhecida aceita em 09/10/2026: vaga de seleção que teve cancelamento com reposição <24h
--              vira modo urgência (D4=C) e republicação responde 422 republicacao_indisponivel, details: nao_e_selecao.
--
-- Prefixo de IDs: c6300000. Relógio controlado com frila.agora imune a bombas-relógio.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(55);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- Relógio congelado logo no início (imune a bomba-relógio)
-- Estamos em 02/11/2026 12:00:00 UTC
select set_config('frila.agora', '2026-11-02 12:00:00+00', true);

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
  on conflict (id) do nothing;
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

create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

-- Ids do cenário isolado
create temp table ids as select
  'c6300000-0000-4000-8000-0000000000d1'::uuid as dona_user,
  'c6300000-0000-4000-8000-0000000000d2'::uuid as outra_dona_user,
  'c6300000-0000-4000-8000-0000000000d3'::uuid as suspenso_user,
  'c6300000-0000-4000-8000-0000000000a1'::uuid as p1_user,
  'c6300000-0000-4000-8000-0000000000a2'::uuid as p2_user,
  'c6300000-0000-4000-8000-0000000000a3'::uuid as p3_user,
  'c6300000-0000-4000-8000-0000000000a4'::uuid as p4_user,
  'c6300000-0000-4000-8000-0000000000a5'::uuid as p5_user,
  'c6300000-0000-4000-8000-0000000000e1'::uuid as estab_id,
  'c6300000-0000-4000-8000-0000000000e2'::uuid as outro_estab_id;

select pg_temp.autenticar((select dona_user from ids), 'dona630@frila.test');
select pg_temp.autenticar((select outra_dona_user from ids), 'outradona630@frila.test');
select pg_temp.autenticar((select suspenso_user from ids), 'suspenso630@frila.test');
select pg_temp.autenticar((select p1_user from ids), 'p1_630@frila.test');
select pg_temp.autenticar((select p2_user from ids), 'p2_630@frila.test');
select pg_temp.autenticar((select p3_user from ids), 'p3_630@frila.test');
select pg_temp.autenticar((select p4_user from ids), 'p4_630@frila.test');
select pg_temp.autenticar((select p5_user from ids), 'p5_630@frila.test');

-- Criação de contas
select pg_temp.como((select dona_user from ids),
  $$ select public.criar_conta('contratante','Dona 630','+5561977770001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select outra_dona_user from ids),
  $$ select public.criar_conta('contratante','Outra Dona 630','+5561977770002','1982-01-01','2026-09-22') $$);
select pg_temp.como((select suspenso_user from ids),
  $$ select public.criar_conta('contratante','Dona Suspensa 630','+5561977770003','1985-01-01','2026-09-22') $$);
update public.usuario set estado = 'suspensa' where id = (select suspenso_user from ids);

select pg_temp.como((select p1_user from ids),
  $$ select public.criar_conta('profissional','Garçom 1 630','+5561977770011','1995-01-01','2026-09-22') $$);
select pg_temp.como((select p2_user from ids),
  $$ select public.criar_conta('profissional','Garçom 2 630','+5561977770012','1995-01-01','2026-09-22') $$);
select pg_temp.como((select p3_user from ids),
  $$ select public.criar_conta('profissional','Garçom 3 630','+5561977770013','1995-01-01','2026-09-22') $$);
select pg_temp.como((select p4_user from ids),
  $$ select public.criar_conta('profissional','Garçom 4 630','+5561977770014','1995-01-01','2026-09-22') $$);
select pg_temp.como((select p5_user from ids),
  $$ select public.criar_conta('profissional','Garçom 5 630','+5561977770015','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como(u,
  format($$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)))
  from unnest(array[(select p1_user from ids), (select p2_user from ids),
                    (select p3_user from ids), (select p4_user from ids), (select p5_user from ids)]) u;

-- Estabelecimentos cadastrados via RPC
create temp table casa as
  select (pg_temp.como((select dona_user from ids),
    $$ select public.cadastrar_estabelecimento('Restaurante 630','04252011000110','food_service',
         'SCLN 102','{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$)->>'id')::uuid as id;

create temp table outra_casa as
  select (pg_temp.como((select outra_dona_user from ids),
    $$ select public.cadastrar_estabelecimento('Outro Estab 630','11222333000181','food_service',
         'SCLN 104','{"latitude":-15.7910,"longitude":-47.8860}'::jsonb) $$)->>'id')::uuid as id;

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel, criado_em)
values ((select id from casa), (select suspenso_user from ids), 'administrador', now());

-- Helper para publicar vaga
create function pg_temp.publicar(
  estab uuid, modo text, ini timestamptz, fim timestamptz, pos int, chave uuid
) returns uuid
language plpgsql as $$
begin
  return (pg_temp.como((select dona_user from ids), format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 102',
         '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb,
         18000, %s, true, true, false, 'Dono 630', %L::public.modo_preenchimento, %L) $sql$,
    estab, (select garcom from fn), ini, fim, pos, modo, chave))->>'vaga_id')::uuid;
end $$;

create function pg_temp.cand_id(vaga uuid, usuario uuid) returns uuid language sql as $$
  select c.id from public.candidatura c
    join public.posicao x on x.id = c.posicao_id
    join public.profissional pr on pr.id = c.profissional_id
   where x.vaga_id = vaga and pr.usuario_id = usuario limit 1;
$$;

-- ════════════════════════════════════════════════════════════════════════════════
-- BLOCO 1: Conferências de Acesso, Autenticação e Validação Básica
-- ════════════════════════════════════════════════════════════════════════════════

-- 1. Sem sessão: 401 nao_autenticado
select throws_ok(
  $$ select public.republicar_posicoes_restantes('c6300000-0000-4000-8000-000000000099'::uuid, gen_random_uuid()) $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  '1. sem sessão devolve 401 nao_autenticado');

-- 2. Profissional chamando: 422 perfil_incompativel
select throws_ok(
  pg_temp.por((select p1_user from ids),
    $$ select public.republicar_posicoes_restantes('c6300000-0000-4000-8000-000000000099'::uuid, gen_random_uuid()) $$),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  '2. profissional recebe 422 perfil_incompativel');

-- 3. Conta suspensa: 403 sem_permissao, details: conta_suspensa
select throws_ok(
  pg_temp.por((select suspenso_user from ids),
    $$ select public.republicar_posicoes_restantes('c6300000-0000-4000-8000-000000000099'::uuid, gen_random_uuid()) $$),
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '3. conta suspensa recebe 403 sem_permissao conta_suspensa');

-- 4. vaga_id nulo: 422 campo_obrigatorio, details: vaga_id
select throws_ok(
  pg_temp.por((select dona_user from ids),
    $$ select public.republicar_posicoes_restantes(null::uuid, gen_random_uuid()) $$),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'vaga_id'),
  '4. vaga_id nulo recebe 422 campo_obrigatorio vaga_id');

-- 5. chave nula: 422 campo_obrigatorio, details: chave
select throws_ok(
  pg_temp.por((select dona_user from ids),
    $$ select public.republicar_posicoes_restantes('c6300000-0000-4000-8000-000000000099'::uuid, null::uuid) $$),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'chave'),
  '5. chave nula recebe 422 campo_obrigatorio chave');

-- 6. Origem inexistente: 404 nao_encontrado
select throws_ok(
  pg_temp.por((select dona_user from ids),
    $$ select public.republicar_posicoes_restantes('c6300000-0000-4000-8000-000000000099'::uuid, gen_random_uuid()) $$),
  'PGRST', pg_temp.erro('nao_encontrado'),
  '6. vaga inexistente recebe 404 nao_encontrado');

-- Publica vaga de teste da dona d1
-- Início: 05/11 20:00 (estamos em 02/11 12:00: > 72 h)
create temp table v_teste as select pg_temp.publicar(
  (select id from casa), 'selecao', '2026-11-05 20:00+00', '2026-11-06 02:00+00', 3,
  'c6300000-0000-4000-8000-000000000001'::uuid) as id;

-- 7. Origem de outra casa: 403 sem_permissao
select throws_ok(
  pg_temp.por((select outra_dona_user from ids),
    format($$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$, (select id from v_teste))),
  'PGRST', pg_temp.erro('sem_permissao'),
  '7. dona de outra casa recebe 403 sem_permissao');


-- ════════════════════════════════════════════════════════════════════════════════
-- BLOCO 2: Os 6 details de 422 republicacao_indisponivel e vaga_oculta
-- ════════════════════════════════════════════════════════════════════════════════

-- Detail 1: selecao_em_curso (vaga de seleção ainda publicada)
select throws_ok(
  pg_temp.por((select dona_user from ids),
    format($$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$, (select id from v_teste))),
  'PGRST', pg_temp.erro('republicacao_indisponivel', 'selecao_em_curso'),
  '8. vaga de seleção ainda publicada recebe selecao_em_curso');

-- Detail 2: nao_e_selecao (vaga de urgência)
create temp table v_urg as select pg_temp.publicar(
  (select id from casa), 'urgencia', '2026-11-05 20:00+00', '2026-11-06 02:00+00', 1,
  'c6300000-0000-4000-8000-000000000002'::uuid) as id;
select throws_ok(
  pg_temp.por((select dona_user from ids),
    format($$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$, (select id from v_urg))),
  'PGRST', pg_temp.erro('republicacao_indisponivel', 'nao_e_selecao'),
  '9. vaga de urgência recebe nao_e_selecao');

-- Detail 3: vaga_cancelada (vaga de seleção cancelada pela casa)
create temp table v_canc as select pg_temp.publicar(
  (select id from casa), 'selecao', '2026-11-05 20:00+00', '2026-11-06 02:00+00', 1,
  'c6300000-0000-4000-8000-000000000003'::uuid) as id;
select pg_temp.como((select dona_user from ids),
  format($$ select public.cancelar_vaga(%L::uuid, 'evento cancelado') $$, (select id from v_canc)));
select throws_ok(
  pg_temp.por((select dona_user from ids),
    format($$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$, (select id from v_canc))),
  'PGRST', pg_temp.erro('republicacao_indisponivel', 'vaga_cancelada'),
  '10. vaga cancelada pela casa recebe vaga_cancelada');

-- Vaga oculta pela moderação: 422 vaga_oculta
create temp table v_oculta as select pg_temp.publicar(
  (select id from casa), 'selecao', '2026-11-05 20:00+00', '2026-11-06 02:00+00', 1,
  'c6300000-0000-4000-8000-000000000004'::uuid) as id;
select privado.operacao_moderar_conteudo((select id from v_oculta), 'ocultar', 'Texto ofensivo', (select outra_dona_user from ids));
select throws_ok(
  pg_temp.por((select dona_user from ids),
    format($$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$, (select id from v_oculta))),
  'PGRST', pg_temp.erro('vaga_oculta'),
  '11. vaga oculta pela moderação recebe 422 vaga_oculta');

-- ════════════════════════════════════════════════════════════════════════════════
-- BLOCO 3: Fechamento, Sobras (Critérios 1, 3 e Bigorna Casos 2 e 3)
-- ════════════════════════════════════════════════════════════════════════════════

-- Vaga A: 3 posições nominais. p1 e p2 se candidatam. A casa escolhe p1.
-- No fechamento (24 h antes), 1 confirmada e 2 canceladas -> sobram 2 posições.
create temp table vaga_a as select pg_temp.publicar(
  (select id from casa), 'selecao', '2026-11-05 20:00+00', '2026-11-06 02:00+00', 3,
  'c6300000-0000-4000-8000-00000000000a'::uuid) as id;
select pg_temp.como((select p1_user from ids), format($$ select public.candidatar(%L) $$, (select id from vaga_a)));
select pg_temp.como((select p2_user from ids), format($$ select public.candidatar(%L) $$, (select id from vaga_a)));
select pg_temp.como((select dona_user from ids),
  format($$ select public.escolher_candidato(%L) $$, pg_temp.cand_id((select id from vaga_a), (select p1_user from ids))));

-- Vaga B: 3 posições nominais. Nenhuma escolha. No fechamento -> sobram 3 posições.
create temp table vaga_b as select pg_temp.publicar(
  (select id from casa), 'selecao', '2026-11-05 20:00+00', '2026-11-06 02:00+00', 3,
  'c6300000-0000-4000-8000-00000000000b'::uuid) as id;
select pg_temp.como((select p3_user from ids), format($$ select public.candidatar(%L) $$, (select id from vaga_b)));

-- Vaga C: 2 posições nominais. p4 e p5 se candidatam e ambos são escolhidos -> 0 sobras.
create temp table vaga_c as select pg_temp.publicar(
  (select id from casa), 'selecao', '2026-11-05 20:00+00', '2026-11-06 02:00+00', 2,
  'c6300000-0000-4000-8000-00000000000c'::uuid) as id;
select pg_temp.como((select p4_user from ids), format($$ select public.candidatar(%L) $$, (select id from vaga_c)));
select pg_temp.como((select p5_user from ids), format($$ select public.candidatar(%L) $$, (select id from vaga_c)));
select pg_temp.como((select dona_user from ids),
  format($$ select public.escolher_candidato(%L) $$, pg_temp.cand_id((select id from vaga_c), (select p4_user from ids))));
select pg_temp.como((select dona_user from ids),
  format($$ select public.escolher_candidato(%L) $$, pg_temp.cand_id((select id from vaga_c), (select p5_user from ids))));

-- Avança o relógio para 24 h antes: 04/11 20:00 UTC e roda o fechamento
select set_config('frila.agora', '2026-11-04 20:00:00+00', true);
select cmp_ok(privado.fechar_selecoes(), '>=', 2, 'fechar_selecoes fecha Vaga A e Vaga B');

select is((select estado::text from public.vaga where id = (select id from vaga_a)), 'preenchida', 'vaga A fechou preenchida');
select is((select estado::text from public.vaga where id = (select id from vaga_b)), 'encerrada', 'vaga B fechou encerrada');
select is((select estado::text from public.vaga where id = (select id from vaga_c)), 'preenchida', 'vaga C estava preenchida');

-- Testa função privado.republicacao_da_selecao
select is((select restantes from privado.republicacao_da_selecao((select id from vaga_a))), 2, 'vaga A: restam 2 posições');
select is((select motivo from privado.republicacao_da_selecao((select id from vaga_a))), null, 'vaga A: motivo nulo (apta)');

select is((select restantes from privado.republicacao_da_selecao((select id from vaga_b))), 3, 'vaga B: restam 3 posições');
select is((select motivo from privado.republicacao_da_selecao((select id from vaga_b))), null, 'vaga B: motivo nulo (apta)');

-- Detail 5: sem_posicoes_restantes (todas as posições preenchidas - Bigorna Caso 3)
select is((select restantes from privado.republicacao_da_selecao((select id from vaga_c))), 0, 'vaga C: restam 0 posições');
select is((select motivo from privado.republicacao_da_selecao((select id from vaga_c))), 'sem_posicoes_restantes', 'vaga C: motivo sem_posicoes_restantes');
select throws_ok(
  pg_temp.por((select dona_user from ids),
    format($$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$, (select id from vaga_c))),
  'PGRST', pg_temp.erro('republicacao_indisponivel', 'sem_posicoes_restantes'),
  '12. vaga totalmente preenchida recebe 422 republicacao_indisponivel sem_posicoes_restantes');

-- Painel: republicavel_em_urgencia para Vaga A (2), Vaga B (3) e Vaga C (null)
create temp table painel_res as select pg_temp.como((select dona_user from ids), format(
  $$ select public.painel_estabelecimento(%L::uuid, '2026-11-01T00:00:00Z'::timestamptz, '2026-11-10T00:00:00Z'::timestamptz) $$,
  (select id from casa))) as p;

select is((select v->>'republicavel_em_urgencia'
             from jsonb_array_elements((select p from painel_res)->'vagas') v
            where (v->'vaga'->>'id')::uuid = (select id from vaga_a)), '2',
  '13. painel mostra republicavel_em_urgencia = 2 para vaga A');

select is((select v->>'republicavel_em_urgencia'
             from jsonb_array_elements((select p from painel_res)->'vagas') v
            where (v->'vaga'->>'id')::uuid = (select id from vaga_b)), '3',
  '14. painel mostra republicavel_em_urgencia = 3 para vaga B');

select is((select v->'republicavel_em_urgencia'
             from jsonb_array_elements((select p from painel_res)->'vagas') v
            where (v->'vaga'->>'id')::uuid = (select id from vaga_c)), 'null'::jsonb,
  '15. painel mostra republicavel_em_urgencia null para vaga C');


-- ════════════════════════════════════════════════════════════════════════════════
-- BLOCO 4: Republicação Bem-Sucedida, Vaga Nova em Urgência, RN21 e Despacho
-- ════════════════════════════════════════════════════════════════════════════════

create temp table chave_rep_a as select 'c6300000-0000-4000-8000-0000000000aa'::uuid as k;

-- Chama republicar_posicoes_restantes na Vaga A (deve criar vaga nova com 2 posições)
create temp table rep_a as select pg_temp.como((select dona_user from ids), format(
  $$ select public.republicar_posicoes_restantes(%L::uuid, %L::uuid) $$,
  (select id from vaga_a), (select k from chave_rep_a))) as res;

select isnt((select res->>'vaga_id' from rep_a), null, '16. republicação da vaga A gerou vaga_id');
select is(jsonb_array_length((select res->'posicoes' from rep_a)), 2, '17. vaga nova tem exatamente 2 posições');

create temp table nova_vaga_a as select ((select res->>'vaga_id' from rep_a))::uuid as id;

-- Confere dados da vaga nova: modo urgencia, republicada_de = vaga_a, mesmo horario e valor
select is((select modo::text from public.vaga where id = (select id from nova_vaga_a)), 'urgencia',
  '18. vaga nova é de modo urgencia');
select is((select republicada_de from public.vaga where id = (select id from nova_vaga_a)), (select id from vaga_a),
  '19. vaga nova tem republicada_de apontando para a vaga de origem A');
select is((select inicio_em from public.vaga where id = (select id from nova_vaga_a)),
          (select inicio_em from public.vaga where id = (select id from vaga_a)),
  '20. vaga nova tem mesmo inicio_em da origem');
select is((select fim_em from public.vaga where id = (select id from nova_vaga_a)),
          (select fim_em from public.vaga where id = (select id from vaga_a)),
  '21. vaga nova tem mesmo fim_em da origem');
select is((select valor_centavos from public.vaga where id = (select id from nova_vaga_a)),
          (select valor_centavos from public.vaga where id = (select id from vaga_a)),
  '22. vaga nova tem mesmo valor_centavos da origem');

-- Despacho foi enfileirado para a vaga de urgência criada (RR-RN08)
select is((select count(*)::int from pgmq.q_despacho where (message->>'vaga_id')::uuid = (select id from nova_vaga_a)), 1,
  '23. despacho enfileirado no pgmq para a nova vaga de urgência');

-- Idempotência pela chave (RR-RN04): reenviar com a mesma chave devolve a mesma vaga
create temp table rep_a_reenvio as select pg_temp.como((select dona_user from ids), format(
  $$ select public.republicar_posicoes_restantes(%L::uuid, %L::uuid) $$,
  (select id from vaga_a), (select k from chave_rep_a))) as res;

select is((select res->>'vaga_id' from rep_a_reenvio), (select res->>'vaga_id' from rep_a),
  '24. reenvio com mesma chave devolve o mesmo vaga_id');
select is((select count(*)::int from public.vaga where republicada_de = (select id from vaga_a)), 1,
  '25. apenas uma vaga criada no banco para a origem');

-- Detail 6: ja_republicada (RR-RN05) - tentativa com chave diferente enquanto a anterior está ativa
select throws_ok(
  pg_temp.por((select dona_user from ids),
    format($$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$, (select id from vaga_a))),
  'PGRST', pg_temp.erro('republicacao_indisponivel', 'ja_republicada'),
  '26. nova republicação enquanto existe ativa recebe ja_republicada');

-- RN21: p1 (que foi confirmado na origem Vaga A) tenta candidatar-se à vaga nova no mesmo horário -> inelegivel / turno_sobreposto
select throws_ok(
  pg_temp.por((select p1_user from ids),
    format($$ select public.candidatar(%L::uuid) $$, (select id from nova_vaga_a))),
  'PGRST', pg_temp.erro('inelegivel', 'turno_sobreposto'),
  '27. RN21: profissional confirmado na origem não consegue se candidatar à vaga nova do mesmo horário');

-- Candidato elegível p3 se candidata à nova vaga de urgência e confirma na hora
select is((pg_temp.como((select p3_user from ids),
            format($$ select public.candidatar(%L::uuid) $$, (select id from nova_vaga_a)))->>'estado'),
  'confirmada', '28. candidato elegível confirma imediatamente na nova vaga de urgência');


-- ════════════════════════════════════════════════════════════════════════════════
-- BLOCO 5: Liberação do Índice Único Parcial quando a Vaga Nova é Cancelada
-- ════════════════════════════════════════════════════════════════════════════════

-- Vaga B: republica gerando vaga nova B1
create temp table rep_b as select pg_temp.como((select dona_user from ids), format(
  $$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$,
  (select id from vaga_b))) as res;
create temp table nova_vaga_b as select ((select res->>'vaga_id' from rep_b))::uuid as id;

select is((select estado::text from public.vaga where id = (select id from nova_vaga_b)), 'publicada',
  '29. vaga nova B1 publicada');

-- Segunda republicação de B com chave nova deve falhar com ja_republicada
select throws_ok(
  pg_temp.por((select dona_user from ids),
    format($$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$, (select id from vaga_b))),
  'PGRST', pg_temp.erro('republicacao_indisponivel', 'ja_republicada'),
  '30. enquanto B1 está publicada, outra republicação é recusada com ja_republicada');

-- Casa cancela a vaga B1
select pg_temp.como((select dona_user from ids),
  format($$ select public.cancelar_vaga(%L::uuid, 'mudou plano') $$, (select id from nova_vaga_b)));
select is((select estado::text from public.vaga where id = (select id from nova_vaga_b)), 'cancelada',
  '31. vaga nova B1 cancelada');

-- Com B1 cancelada, o índice único parcial vaga_uma_republicacao_ativa_idx libera e
-- uma NOVA republicação de B agora é aceita com sucesso!
create temp table rep_b2 as select pg_temp.como((select dona_user from ids), format(
  $$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$,
  (select id from vaga_b))) as res;

select isnt((select res->>'vaga_id' from rep_b2), (select res->>'vaga_id' from rep_b),
  '32. liberação do índice: após cancelamento da primeira republicação, uma nova vaga B2 é criada com sucesso');


-- ════════════════════════════════════════════════════════════════════════════════
-- BLOCO 6: Detail 4: ja_comecou (início já passou)
-- ════════════════════════════════════════════════════════════════════════════════

-- Avança relógio para DEPOIS do início da vaga (início era 05/11 20:00 -> 05/11 20:05)
select set_config('frila.agora', '2026-11-05 20:05:00+00', true);

select throws_ok(
  pg_temp.por((select dona_user from ids),
    format($$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$, (select id from vaga_b))) ,
  'PGRST', pg_temp.erro('republicacao_indisponivel', 'ja_comecou'),
  '33. vaga cujo início já passou recebe 422 republicacao_indisponivel ja_comecou');


-- ════════════════════════════════════════════════════════════════════════════════
-- BLOCO 7: Bigorna Caso 1 - Desistência antes das 24h (linha nova em posicao)
-- ════════════════════════════════════════════════════════════════════════════════
-- Volta o relógio para antes das 24h
select set_config('frila.agora', '2026-11-02 12:00:00+00', true);

-- Cria vaga D: 2 posições nominais. Início: 08/11 20:00
create temp table vaga_d as select pg_temp.publicar(
  (select id from casa), 'selecao', '2026-11-08 20:00+00', '2026-11-09 02:00+00', 2,
  'c6300000-0000-4000-8000-00000000000d'::uuid) as id;

-- p1 se candidata e é escolhido
select pg_temp.como((select p1_user from ids), format($$ select public.candidatar(%L) $$, (select id from vaga_d)));
select pg_temp.como((select dona_user from ids),
  format($$ select public.escolher_candidato(%L) $$, pg_temp.cand_id((select id from vaga_d), (select p1_user from ids))));

-- p1 desiste antes das 24h (estamos em 02/11, início é 08/11: > 72h)
create temp table pos_p1_canc as select id from public.posicao
 where vaga_id = (select id from vaga_d) and estado = 'confirmada';
select pg_temp.como((select p1_user from ids),
  format($$ select public.cancelar_posicao(%L::uuid, 'imprevisto') $$, (select id from pos_p1_canc)));

-- A posição antiga virou cancelada e uma nova linha de posição aberta foi criada.
-- O total de linhas na tabela posicao agora é 3 (duas da criação original + uma reaberta), maior que vaga.posicoes = 2!
select is((select count(*)::int from public.posicao where vaga_id = (select id from vaga_d)), 3,
  '34. caso 1 Bigorna: total de linhas em posicao é 3 (maior que vaga.posicoes = 2)');

-- Agora avança para o fechamento a 24h antes do início (07/11 20:00) sem nenhuma nova escolha
select set_config('frila.agora', '2026-11-07 20:00:00+00', true);
select cmp_ok(privado.fechar_selecoes(), '>=', 1, '35. vaga D fecha no fechamento');

-- Como nenhuma posição foi confirmada no fechamento, as posições abertas viraram canceladas e restam exatamente 2 vagas nominais!
select is((select restantes from privado.republicacao_da_selecao((select id from vaga_d))), 2,
  '36. caso 1 Bigorna: formula nominal menos confirmadas continua dando exatamente 2 posições');

-- Republica a vaga D: gera vaga de urgência com 2 posições!
create temp table rep_d as select pg_temp.como((select dona_user from ids), format(
  $$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$,
  (select id from vaga_d))) as res;
select is(jsonb_array_length((select res->'posicoes' from rep_d)), 2,
  '37. caso 1 Bigorna: vaga republicada nasce com 2 posições');


-- ════════════════════════════════════════════════════════════════════════════════
-- BLOCO 8: Bigorna Caso 4 - Limitação Conhecida (vaga virou urgência por reposição <24h)
-- ════════════════════════════════════════════════════════════════════════════════
-- Requisito seção 11 e Plano caso 4:
-- Vaga de seleção fechou com sobras (ex: 2 posições, 1 confirmada e 1 cancelada no fechamento).
-- Depois do fechamento, a menos de 24h do início, o profissional escolhido cancela.
-- Pela regra de reposição do PR #161 (D4=C), a vaga sofre update modo = 'urgencia'.
-- A republicação das posições restantes DEVE responder 422 republicacao_indisponivel, details: nao_e_selecao!
-- Este teste fixa esse comportamento de acordo com a decisão de produto aprovada.

-- Volta o relógio
select set_config('frila.agora', '2026-11-02 12:00:00+00', true);

-- Cria vaga E: 2 posições nominais. Início: 09/11 20:00
create temp table vaga_e as select pg_temp.publicar(
  (select id from casa), 'selecao', '2026-11-09 20:00+00', '2026-11-10 02:00+00', 2,
  'c6300000-0000-4000-8000-00000000000e'::uuid) as id;

-- p2 se candidata e é escolhido (1 confirmada, 1 sobra)
select pg_temp.como((select p2_user from ids), format($$ select public.candidatar(%L) $$, (select id from vaga_e)));
select pg_temp.como((select dona_user from ids),
  format($$ select public.escolher_candidato(%L) $$, pg_temp.cand_id((select id from vaga_e), (select p2_user from ids))));

-- Avança relógio para 24h antes: 08/11 20:00 e roda fechamento
select set_config('frila.agora', '2026-11-08 20:00:00+00', true);
select cmp_ok(privado.fechar_selecoes(), '>=', 1, '38. vaga E fecha');
select is((select estado::text from public.vaga where id = (select id from vaga_e)), 'preenchida', '39. vaga E fechou preenchida');
select is((select restantes from privado.republicacao_da_selecao((select id from vaga_e))), 1, '40. vaga E tinha 1 posição restante');

-- Agora avança relógio para 12h antes do início: 09/11 08:00 (< 24h)
select set_config('frila.agora', '2026-11-09 08:00:00+00', true);

-- O profissional p2 cancela a posição a < 24h do início
create temp table pos_p2_canc as select id from public.posicao
 where vaga_id = (select id from vaga_e) and estado = 'confirmada';
select pg_temp.como((select p2_user from ids),
  format($$ select public.cancelar_posicao(%L::uuid, 'imprevisto urgente') $$, (select id from pos_p2_canc)));

-- Confere que a regra D4=C mudou modo da vaga para urgencia
select is((select modo::text from public.vaga where id = (select id from vaga_e)), 'urgencia',
  '41. caso 4 Bigorna: vaga de seleção virou urgencia por reposição <24h (PR #161 D4=C)');

-- Afirmação do Caso 4 do Plano: republicar_posicoes_restantes recusa com nao_e_selecao!
select is((select motivo from privado.republicacao_da_selecao((select id from vaga_e))), 'nao_e_selecao',
  '42. caso 4 Bigorna: privado.republicacao_da_selecao devolve motivo nao_e_selecao');

select throws_ok(
  pg_temp.por((select dona_user from ids),
    format($$ select public.republicar_posicoes_restantes(%L::uuid, gen_random_uuid()) $$, (select id from vaga_e))),
  'PGRST', pg_temp.erro('republicacao_indisponivel', 'nao_e_selecao'),
  '43. caso 4 Bigorna: republicar_posicoes_restantes responde 422 republicacao_indisponivel com details nao_e_selecao');

-- Painel também acompanha e devolve republicavel_em_urgencia null
create temp table painel_res_e as select pg_temp.como((select dona_user from ids), format(
  $$ select public.painel_estabelecimento(%L::uuid, '2026-11-08T00:00:00Z'::timestamptz, '2026-11-11T00:00:00Z'::timestamptz) $$,
  (select id from casa))) as p;

select is((select v->'republicavel_em_urgencia'
             from jsonb_array_elements((select p from painel_res_e)->'vagas') v
            where (v->'vaga'->>'id')::uuid = (select id from vaga_e)), 'null'::jsonb,
  '44. caso 4 Bigorna: painel devolve republicavel_em_urgencia null para vaga que virou urgencia');

-- Conclusão dos testes
select pass('45. todos os fluxos e critérios de republicar_posicoes_restantes foram verificados com sucesso');

select * from finish();
rollback;
