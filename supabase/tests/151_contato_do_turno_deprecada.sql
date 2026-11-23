-- `contato_do_turno` na 0.2.49: deprecada no contrato, mas ainda no ar.
--
-- Decisão de produto de 04/11/2026 (issue #396): o contato não é trocado pelo app. O
-- contrato 0.2.49 marca a operação como `deprecated` e diz que ela segue respondendo como
-- hoje enquanto houver app antigo na loja. Este arquivo trava as duas metades: a função
-- continua existindo e liberada só para `authenticated`, e o catálogo diz que está
-- deprecada. O comportamento da resposta (prazo, bloqueio, conta ativa) é de 150.

begin;
select plan(9);

select has_function('public', 'contato_do_turno', array['uuid'],
  'contato_do_turno segue no ar para os apps já publicados');

select ok(
  has_function_privilege('authenticated', 'public.contato_do_turno(uuid)', 'execute'),
  'authenticated segue executando contato_do_turno');

select ok(
  not has_function_privilege('anon', 'public.contato_do_turno(uuid)', 'execute'),
  'anon continua sem executar contato_do_turno');

select matches(
  obj_description('public.contato_do_turno(uuid)'::regprocedure, 'pg_proc'),
  '^DEPRECADA na 0\.2\.49',
  'o comentário da função abre dizendo que ela está deprecada na 0.2.49');

select matches(
  obj_description('public.contato_do_turno(uuid)'::regprocedure, 'pg_proc'),
  'contato_expirado',
  'o comentário mantém o comportamento vigente (403 contato_expirado)');

-- ── O arame de tropeço da compatibilidade ─────────────────────────────────────
--
-- A 0.2.49 é compatível por um motivo específico: ela tornou `contato` e
-- `contato_visivel_ate` opcionais e nuláveis, mas **o servidor continua preenchendo**, e é
-- isso que mantém de pé o app que já está na loja — aquele app ainda decodifica os dois
-- como obrigatórios, e omitir ou mandar `null` hoje quebraria a tela de confirmação dele.
--
-- As quatro asserções abaixo não medem resposta (isso é de 130, 140, 480 e 671): elas
-- travam a estrutura. Quem for implementar o resto da Fase 2 vai ver este teste ficar
-- vermelho, e é de propósito: parar de entregar o contato exige, antes, uma versão própria
-- do contrato e um corte por versão mínima de app. Mudar este arquivo é a hora de
-- perguntar se o app que tolera a ausência já está publicado.

select matches(
  pg_get_functiondef('public.candidatar(uuid)'::regprocedure),
  'contato_do_estabelecimento',
  'candidatar ainda monta o contato: a 0.2.49 permitiu omitir, não mandou parar');

select matches(
  pg_get_functiondef('public.escolher_candidato(uuid)'::regprocedure),
  'contato',
  'escolher_candidato ainda devolve contato na confirmação');

select matches(
  pg_get_functiondef('privado.turno_em_json(uuid,uuid)'::regprocedure),
  'contato_visivel_ate',
  'o turno ainda leva contato_visivel_ate: o prazo da RN10 só perde o sentido na Fase 3');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'contato_do_turno'),
  1,
  'nenhuma contato_do_turno_v2 nasceu junto: mudança incompatível vira função nova, e essa versão ainda não foi decidida');

select * from finish();
rollback;
