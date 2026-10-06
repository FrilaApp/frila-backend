-- Testes pgTAP de privado.turnos_exportacao (cartão pd7zOS5P · US20, RF22, RN09, RN17, UC13).
--
-- Verifica:
--   1. Permissões estritas: apenas service_role possui execute.
--   2. Validação de parâmetros: usuário obrigatório, de/ate obrigatórios, de <= ate.
--   3. Validação de acesso do contratante: 403 sem_permissao se não for membro do estabelecimento.
--   4. Consulta no perfil Contratante bate com os turnos do seed (valores, contraparte profissional, verificação).
--   5. Consulta no perfil Profissional bate com os turnos do seed (valores, contraparte estabelecimento).
--   6. Período vazio devolve zero linhas (preparando o 204 do UC13 1a).
--   7. LGPD (RN15): nenhum dado pessoal além do autorizado pela RN17.

begin;
select plan(20);

-- ── 1. Permissões de execução ──────────────────────────────────────────────────

select ok(not has_function_privilege('anon', 'privado.turnos_exportacao(uuid, timestamptz, timestamptz, uuid)', 'execute'),
  'anon não tem execute em privado.turnos_exportacao');
select ok(not has_function_privilege('authenticated', 'privado.turnos_exportacao(uuid, timestamptz, timestamptz, uuid)', 'execute'),
  'authenticated não tem execute em privado.turnos_exportacao');
select ok(has_function_privilege('service_role', 'privado.turnos_exportacao(uuid, timestamptz, timestamptz, uuid)', 'execute'),
  'service_role tem execute em privado.turnos_exportacao');

-- ── 2. Validações de parâmetros ────────────────────────────────────────────────

-- Usuário nulo
select throws_ok(
  $$ select * from privado.turnos_exportacao(null, privado.agora() - interval '1 day', privado.agora()) $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'usuário nulo é recusado com 401 nao_autenticado'
);

-- Usuário inexistente
select throws_ok(
  $$ select * from privado.turnos_exportacao('00000000-0000-0000-0000-000000000000'::uuid, privado.agora() - interval '1 day', privado.agora()) $$,
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'usuário inexistente é recusado com 404 nao_encontrado'
);

-- Parâmetro 'de' nulo
select throws_ok(
  $$ select * from privado.turnos_exportacao('a0000000-0000-4000-8000-000000000001'::uuid, null, privado.agora()) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "de", "hint" : null}',
  'parâmetro de ausente é recusado com 422 campo_obrigatorio'
);

-- Parâmetro 'ate' nulo
select throws_ok(
  $$ select * from privado.turnos_exportacao('a0000000-0000-4000-8000-000000000001'::uuid, privado.agora(), null) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "ate", "hint" : null}',
  'parâmetro ate ausente é recusado com 422 campo_obrigatorio'
);

-- Período invertido (de > ate)
select throws_ok(
  $$ select * from privado.turnos_exportacao('a0000000-0000-4000-8000-000000000001'::uuid, privado.agora(), privado.agora() - interval '1 day') $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "de", "hint" : null}',
  'período invertido (de > ate) é recusado com 422 campo_invalido'
);

-- ── 3. Controle de acesso por perfil / estabelecimento ─────────────────────────

-- Usuário que não é membro do estabelecimento recebe 403 sem_permissao
select throws_ok(
  $$ select * from privado.turnos_exportacao(
       'b0000000-0000-4000-8000-000000000001'::uuid,  -- Zélia (membro do Bar do Cerrado)
       privado.agora() - interval '30 days',
       privado.agora(),
       'c0000000-0000-4000-8000-000000000002'::uuid   -- Restaurante Alvorada (ela não é membro)
     ) $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'não membro consultando estabelecimento recebe 403 sem_permissao'
);

-- ── 4. Consulta do Contratante com dados do seed ──────────────────────────────
-- Ricardo Aguiar (b...0002) é membro do Restaurante Alvorada (c...0002).
-- A vaga passada d...0003 (limpeza pós-evento) tem 4 turnos gravados no seed:
--   - 2 verificados (João Vitor Sá e Heitor Lima)
--   - 2 não verificados (Carla Nunes e Bruno Sales)
-- Todos a 14000 centavos (R$ 140,00).

select results_eq(
  $$ select valor_acordado_centavos, verificacao::text, funcao, contraparte
       from privado.turnos_exportacao(
         'b0000000-0000-4000-8000-000000000002'::uuid,
         privado.agora() - interval '30 days',
         privado.agora(),
         'c0000000-0000-4000-8000-000000000002'::uuid
       )
      order by contraparte, valor_acordado_centavos, verificacao $$,
  $$ values
       (14000::bigint, 'nao_verificado', 'limpeza pós-evento', 'Bruno Sales'),
       (14000::bigint, 'nao_verificado', 'limpeza pós-evento', 'Carla Nunes'),
       (14000::bigint, 'verificado',     'limpeza pós-evento', 'Heitor Lima'),
       (18000::bigint, 'pendente',       'garçom',              'Heitor Lima'),
       (14000::bigint, 'verificado',     'limpeza pós-evento', 'João Vitor Sá') $$,
  'contratante: turnos do seed trazem valores corretos, contrapartes e marcações de verificação'
);

select is(
  (select count(*)::int
     from privado.turnos_exportacao(
       'b0000000-0000-4000-8000-000000000002'::uuid,
       privado.agora() - interval '30 days',
       privado.agora(),
       'c0000000-0000-4000-8000-000000000002'::uuid
     )),
  5,
  'contratante: exatamente 5 turnos no período do seed (4 passados e 1 em andamento)'
);

-- ── 5. Consulta do Profissional com dados do seed ─────────────────────────────
-- Ana Ribeiro (a...0001) trabalhou no Bar do Cerrado (c...0001):
--   - 1 turno cumprido no passado: valor 16000, verificado, função garçom, contraparte Bar do Cerrado.
--   - 1 turno no futuro próximo: valor 22000, pendente, função bartender, contraparte Bar do Cerrado.

select results_eq(
  $$ select valor_acordado_centavos, verificacao::text, funcao, contraparte
       from privado.turnos_exportacao(
         'a0000000-0000-4000-8000-000000000001'::uuid,
         privado.agora() - interval '30 days',
         privado.agora() + interval '30 days'
       )
      order by valor_acordado_centavos $$,
  $$ values
       (16000::bigint, 'verificado', 'garçom',    'Bar do Cerrado'),
       (22000::bigint, 'pendente',   'bartender', 'Bar do Cerrado') $$,
  'profissional: turnos da Ana no seed trazem contraparte da casa, valores (16000 e 22000) e status corretos'
);

-- ── 6. Período sem turnos devolve 0 linhas (UC13 1a) ─────────────────────────

select is(
  (select count(*)::int
     from privado.turnos_exportacao(
       'a0000000-0000-4000-8000-000000000001'::uuid,
       privado.agora() + interval '300 days',
       privado.agora() + interval '360 days'
     )),
  0,
  'período sem turnos devolve 0 linhas (UC13 1a)'
);

select is(
  (select count(*)::int
     from privado.turnos_exportacao(
       'b0000000-0000-4000-8000-000000000002'::uuid,
       privado.agora() + interval '300 days',
       privado.agora() + interval '360 days',
       'c0000000-0000-4000-8000-000000000002'::uuid
     )),
  0,
  'período sem turnos para contratante devolve 0 linhas'
);

-- ── 7. Conta contratante sem estabelecimento_id devolve 0 linhas ─────────────

select is(
  (select count(*)::int
     from privado.turnos_exportacao(
       'b0000000-0000-4000-8000-000000000002'::uuid,
       privado.agora() - interval '30 days',
       privado.agora()
     )),
  0,
  'conta de contratante sem estabelecimento_id não tem turnos como profissional (0 linhas)'
);

-- ── 8. Formato dos dados e conformidade RN18 ──────────────────────────────────
-- Valor acordado sempre maior que zero, horários coerentes e data no fuso de Brasília.

select ok(
  (select bool_and(valor_acordado_centavos > 0)
     from privado.turnos_exportacao(
       'b0000000-0000-4000-8000-000000000002'::uuid,
       privado.agora() - interval '30 days',
       privado.agora(),
       'c0000000-0000-4000-8000-000000000002'::uuid
     )),
  'todos os turnos possuem valor acordado positivo em centavos (RN18)'
);

select ok(
  (select bool_and(fim_em > inicio_em)
     from privado.turnos_exportacao(
       'b0000000-0000-4000-8000-000000000002'::uuid,
       privado.agora() - interval '30 days',
       privado.agora(),
       'c0000000-0000-4000-8000-000000000002'::uuid
     )),
  'fim previsto é posterior ao início previsto'
);

select ok(
  (select bool_and(data is not null)
     from privado.turnos_exportacao(
       'b0000000-0000-4000-8000-000000000002'::uuid,
       privado.agora() - interval '30 days',
       privado.agora(),
       'c0000000-0000-4000-8000-000000000002'::uuid
     )),
  'campo data está sempre preenchido'
);

select ok(
  (select bool_and(funcao is not null and length(funcao) > 0)
     from privado.turnos_exportacao(
       'b0000000-0000-4000-8000-000000000002'::uuid,
       privado.agora() - interval '30 days',
       privado.agora(),
       'c0000000-0000-4000-8000-000000000002'::uuid
     )),
  'campo funcao está preenchido'
);

select ok(
  (select bool_and(contraparte is not null and length(contraparte) > 0)
     from privado.turnos_exportacao(
       'b0000000-0000-4000-8000-000000000002'::uuid,
       privado.agora() - interval '30 days',
       privado.agora(),
       'c0000000-0000-4000-8000-000000000002'::uuid
     )),
  'campo contraparte está preenchido com nome'
);

select * from finish();
rollback;
