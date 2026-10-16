-- 713_idempotencia_chave_publicar_e_denunciar.sql
--
-- Cobertura de Idempotência por Chave em publicar_vaga e denunciar:
--   1. Repetição com a mesma chave:
--      - Retorna exatamente o mesmo payload/identificadores (vaga_id, posicoes, ocorrencia_id);
--      - Não cria registros duplicados em public.vaga, public.posicao ou public.ocorrencia;
--      - Não enfileira mensagens secundárias espúrias em pgmq.q_email.
--   2. Chamada com chave diferente:
--      - Cria novos registros com identificadores distintos (vaga_id distinto, ocorrencia_id distinto);
--      - Incrementa as contagens correspondentes.
--   3. Validação de obrigatoriedade:
--      - Chave nula é recusada com 422 campo_obrigatorio (chave).

begin;
select plan(25);

perform privado.ambiente(eh_teste => true);
set local frila.agora = '2026-10-25 12:00:00+00';

-- ── 1. Auxiliares ──────────────────────────────────────────────────────────────

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

create function pg_temp.erro(p_code text, p_campo text default null) returns text
language sql as $$
  select case
    when p_campo is not null then
      json_build_object('code', p_code, 'message', p_code, 'details', json_build_object('campo', p_campo))::text
    else
      json_build_object('code', p_code, 'message', p_code)::text
  end;
$$;

-- ── 2. Cenário Hermético ───────────────────────────────────────────────────────

create temp table ids as select
  '71300000-0000-4000-8000-000000000001'::uuid as c_dona,       -- contratante
  '71300000-0000-4000-8000-000000000002'::uuid as p_ana,        -- profissional
  '71300000-0000-4000-8000-000000000010'::uuid as estab,        -- estabelecimento
  '71300000-0000-4000-8000-000000000020'::uuid as funcao_garcom,-- funcao
  '71300000-0000-4000-8000-0000000000a1'::uuid as chave_vaga_1, -- chave de vaga 1
  '71300000-0000-4000-8000-0000000000a2'::uuid as chave_vaga_2, -- chave de vaga 2
  '71300000-0000-4000-8000-0000000000d1'::uuid as chave_den_1,  -- chave denúncia 1
  '71300000-0000-4000-8000-0000000000d2'::uuid as chave_den_2;  -- chave denúncia 2

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
values
  ('00000000-0000-0000-0000-000000000000', (select c_dona from ids), 'authenticated', 'authenticated',
   'dona.713@test.com', '2026-10-25 12:00:00+00', '{"provider":"email"}', '{}',
   '2026-10-25 12:00:00+00', '2026-10-25 12:00:00+00', false, false),
  ('00000000-0000-0000-0000-000000000000', (select p_ana from ids), 'authenticated', 'authenticated',
   'ana.713@test.com', '2026-10-25 12:00:00+00', '{"provider":"email"}', '{}',
   '2026-10-25 12:00:00+00', '2026-10-25 12:00:00+00', false, false);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values
  ((select c_dona from ids), 'contratante',  'Dona Estabelecimento', '+5561997130001', 'dona.713@test.com', '1982-04-10', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_ana from ids),  'profissional', 'Ana Garçonete',       '+5561997130002', 'ana.713@test.com',  '1995-09-15', '2026-09-22', '2026-10-25 12:00:00+00');

insert into public.profissional (usuario_id, ponto_base)
values ((select p_ana from ids), 'POINT(-47.8820 -15.7940)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values
  ((select estab from ids), 'Bar Idempotente 713', '84930291000155', 'food_service',
   'CLS 304 Bloco C', 'POINT(-47.8830 -15.7950)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ((select c_dona from ids), (select estab from ids), 'administrador');

select id from public.funcao where nome = 'garçom' limit 1;
update ids set funcao_garcom = (select id from public.funcao where nome = 'garçom' limit 1);

-- ── 3. Idempotência em public.publicar_vaga ───────────────────────────────────

-- 1ª chamada com chave_vaga_1
create temp table res_vaga_1 as
  select pg_temp.como((select c_dona from ids), format(
    $$ select public.publicar_vaga(
         estabelecimento_id => %L,
         funcao_id          => %L,
         inicio_em          => '2026-10-26 18:00:00+00'::timestamptz,
         fim_em             => '2026-10-26 23:00:00+00'::timestamptz,
         local              => 'Salão Principal',
         ponto              => '{"longitude": -47.8830, "latitude": -15.7950}'::jsonb,
         valor_centavos     => 15000,
         posicoes           => 2,
         inclui_refeicao    => true,
         inclui_transporte  => false,
         exige_material_proprio => false,
         responsavel_local  => 'Gerente Marcos',
         modo               => 'urgencia',
         chave              => %L
       ) $$,
    (select estab from ids),
    (select funcao_garcom from ids),
    (select chave_vaga_1 from ids)
  )) as j;

select isnt(
  (select (j->>'vaga_id')::uuid from res_vaga_1),
  null,
  '1. primeira chamada de publicar_vaga gera vaga_id não-nulo'
);

select is(
  (select jsonb_array_length(j->'posicoes') from res_vaga_1),
  2,
  '2. primeira chamada de publicar_vaga gera array com exatamente 2 posições'
);

select is(
  (select count(*)::int from public.vaga where estabelecimento_id = (select estab from ids)),
  1,
  '3. tabela public.vaga contém exatamente 1 vaga para o estabelecimento'
);

select is(
  (select count(*)::int from public.posicao
    where vaga_id = (select (j->>'vaga_id')::uuid from res_vaga_1)),
  2,
  '4. tabela public.posicao contém exatamente 2 posições vinculadas à vaga'
);

-- 2ª chamada: repetição estrita com a MESMA chave_vaga_1
create temp table res_vaga_1_rep as
  select pg_temp.como((select c_dona from ids), format(
    $$ select public.publicar_vaga(
         estabelecimento_id => %L,
         funcao_id          => %L,
         inicio_em          => '2026-10-26 18:00:00+00'::timestamptz,
         fim_em             => '2026-10-26 23:00:00+00'::timestamptz,
         local              => 'Salão Principal',
         ponto              => '{"longitude": -47.8830, "latitude": -15.7950}'::jsonb,
         valor_centavos     => 15000,
         posicoes           => 2,
         inclui_refeicao    => true,
         inclui_transporte  => false,
         exige_material_proprio => false,
         responsavel_local  => 'Gerente Marcos',
         modo               => 'urgencia',
         chave              => %L
       ) $$,
    (select estab from ids),
    (select funcao_garcom from ids),
    (select chave_vaga_1 from ids)
  )) as j;

select is(
  (select j->>'vaga_id' from res_vaga_1_rep),
  (select j->>'vaga_id' from res_vaga_1),
  '5. reenvio com mesma chave devolve estritamente o mesmo vaga_id'
);

select is(
  (select j->'posicoes' from res_vaga_1_rep),
  (select j->'posicoes' from res_vaga_1),
  '6. reenvio com mesma chave devolve estritamente os mesmos IDs de posição'
);

select is(
  (select count(*)::int from public.vaga where estabelecimento_id = (select estab from ids)),
  1,
  '7. reenvio idempotente não duplica linhas em public.vaga (continua 1)'
);

select is(
  (select count(*)::int from public.posicao
    where vaga_id = (select (j->>'vaga_id')::uuid from res_vaga_1)),
  2,
  '8. reenvio idempotente não duplica linhas em public.posicao (continua 2)'
);

-- 3ª chamada: publicação legítima com CHAVE DIFERENTE (chave_vaga_2)
create temp table res_vaga_2 as
  select pg_temp.como((select c_dona from ids), format(
    $$ select public.publicar_vaga(
         estabelecimento_id => %L,
         funcao_id          => %L,
         inicio_em          => '2026-10-26 19:00:00+00'::timestamptz,
         fim_em             => '2026-10-26 23:30:00+00'::timestamptz,
         local              => 'Varanda',
         ponto              => '{"longitude": -47.8830, "latitude": -15.7950}'::jsonb,
         valor_centavos     => 16000,
         posicoes           => 1,
         inclui_refeicao    => true,
         inclui_transporte  => true,
         exige_material_proprio => false,
         responsavel_local  => 'Gerente Marcos',
         modo               => 'urgencia',
         chave              => %L
       ) $$,
    (select estab from ids),
    (select funcao_garcom from ids),
    (select chave_vaga_2 from ids)
  )) as j;

select isnt(
  (select (j->>'vaga_id')::uuid from res_vaga_2),
  (select (j->>'vaga_id')::uuid from res_vaga_1),
  '9. chamada com chave diferente gera novo vaga_id distinto do anterior'
);

select isnt(
  (select j->'posicoes' from res_vaga_2),
  (select j->'posicoes' from res_vaga_1),
  '10. chamada com chave diferente gera novo conjunto de posições'
);

select is(
  (select count(*)::int from public.vaga where estabelecimento_id = (select estab from ids)),
  2,
  '11. contagem de vagas do estabelecimento agora é 2'
);

select is(
  (select count(*)::int from public.posicao
    where vaga_id in (
      (select (j->>'vaga_id')::uuid from res_vaga_1),
      (select (j->>'vaga_id')::uuid from res_vaga_2)
    )),
  3,
  '12. total de posições do estabelecimento agora é 3 (2 da primeira + 1 da segunda)'
);

-- Recusa com chave nula
select throws_ok(
  format(
    $$ select pg_temp.como(%L, format(
         'select public.publicar_vaga(%%L, %%L, ''2026-10-26 18:00+00''::timestamptz, ''2026-10-26 23:00+00''::timestamptz, ''Local'', ''{"longitude": -47.88, "latitude": -15.79}''::jsonb, 15000, 1, true, false, false, ''Resp'', ''urgencia'', null)',
         %L, %L)) $$,
    (select c_dona from ids),
    (select estab from ids),
    (select funcao_garcom from ids)
  ),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'chave'),
  '13. publicar_vaga com chave nula recusa 422 campo_obrigatorio (chave)'
);

-- ── 4. Idempotência em public.denunciar ────────────────────────────────────────

-- 1ª chamada com chave_den_1
create temp table res_den_1 as
  select pg_temp.como((select p_ana from ids), format(
    $$ select public.denunciar(
         alvo_tipo => 'estabelecimento',
         alvo_id   => %L,
         motivo    => 'assedio',
         relato    => 'Relato detalhado de conduta abusiva presenciada no local.',
         chave     => %L
       ) $$,
    (select estab from ids),
    (select chave_den_1 from ids)
  )) as j;

select isnt(
  (select (j->>'ocorrencia_id')::uuid from res_den_1),
  null,
  '14. primeira chamada de denunciar devolve ocorrencia_id não-nulo'
);

select is(
  (select j->>'tipo' from res_den_1),
  'denuncia',
  '15. protocolo devolvido confirma tipo denuncia'
);

select is(
  (select count(*)::int from pgmq.q_email
    where message->>'ocorrencia_id' = (select j->>'ocorrencia_id' from res_den_1)),
  1,
  '16. primeira denúncia enfileira exatamente 1 e-mail transacional na fila email'
);

select is(
  (select count(*)::int from public.ocorrencia where autor_id = (select p_ana from ids)),
  1,
  '17. tabela public.ocorrencia possui exatamente 1 registro para a autora'
);

-- 2ª chamada: repetição estrita com a MESMA chave_den_1 (mesmo com relato levemente modificado)
create temp table res_den_1_rep as
  select pg_temp.como((select p_ana from ids), format(
    $$ select public.denunciar(
         alvo_tipo => 'estabelecimento',
         alvo_id   => %L,
         motivo    => 'outro',
         relato    => 'Relato retransmitido pela rede após suposta perda de conexão.',
         chave     => %L
       ) $$,
    (select estab from ids),
    (select chave_den_1 from ids)
  )) as j;

select is(
  (select j->>'ocorrencia_id' from res_den_1_rep),
  (select j->>'ocorrencia_id' from res_den_1),
  '18. reenvio com mesma chave devolve estritamente o mesmo ocorrencia_id'
);

select is(
  (select j from res_den_1_rep),
  (select j from res_den_1),
  '19. reenvio com mesma chave devolve protocolo idêntico sem atualizar dados gravados'
);

select is(
  (select count(*)::int from public.ocorrencia where autor_id = (select p_ana from ids)),
  1,
  '20. reenvio idempotente não duplica linhas em public.ocorrencia (continua 1)'
);

select is(
  (select count(*)::int from pgmq.q_email
    where message->>'ocorrencia_id' = (select j->>'ocorrencia_id' from res_den_1)),
  1,
  '21. reenvio idempotente não enfileira segundo e-mail (continua 1)'
);

-- 3ª chamada: denúncia legítima com CHAVE DIFERENTE (chave_den_2)
create temp table res_den_2 as
  select pg_temp.como((select p_ana from ids), format(
    $$ select public.denunciar(
         alvo_tipo => 'estabelecimento',
         alvo_id   => %L,
         motivo    => 'risco_seguranca',
         relato    => 'Segundo fato distinto ocorrido em data e circunstâncias diferentes.',
         chave     => %L
       ) $$,
    (select estab from ids),
    (select chave_den_2 from ids)
  )) as j;

select isnt(
  (select (j->>'ocorrencia_id')::uuid from res_den_2),
  (select (j->>'ocorrencia_id')::uuid from res_den_1),
  '22. chamada com chave diferente gera novo ocorrencia_id distinto do anterior'
);

select is(
  (select count(*)::int from public.ocorrencia where autor_id = (select p_ana from ids)),
  2,
  '23. contagem de ocorrências da autora agora é 2'
);

select is(
  (select count(*)::int from pgmq.q_email
    where message->>'ocorrencia_id' in (
      (select j->>'ocorrencia_id' from res_den_1),
      (select j->>'ocorrencia_id' from res_den_2)
    )),
  2,
  '24. fila email possui 2 mensagens (1 para cada ocorrência distinta)'
);

-- Recusa com chave nula
select throws_ok(
  format(
    $$ select pg_temp.como(%L, format(
         'select public.denunciar(''estabelecimento'', %%L, ''outro'', ''Relato longo o bastante para passar'', null)',
         %L)) $$,
    (select p_ana from ids),
    (select estab from ids)
  ),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'chave'),
  '25. denunciar com chave nula recusa 422 campo_obrigatorio (chave)'
);

select * from finish();
rollback;
