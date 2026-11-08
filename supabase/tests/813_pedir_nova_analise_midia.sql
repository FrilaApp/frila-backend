-- 813_pedir_nova_analise_midia.sql
--
-- Pedir nova análise de foto recusada (contrato 0.2.54; RN37, RN46; LGPD art. 20). Ids
-- próprios, começando em `81300000`. Só dados sintéticos.
--
-- O que este arquivo prova, um grupo por regra do contrato:
--   1. Porta: 401 sem sessão, 403 recurso_desligado, 403 conta_suspensa, 404 de foto alheia.
--   2. Caminho feliz: recusada volta a em_analise, vai para a fila da moderação, perde o
--      motivo, e `pode_pedir_nova_analise` passa de true para false. Vale para nao_publicada.
--   3. Uma vez por foto: repetir devolve o estado atual e não enfileira outra análise.
--   4. 409 midia_indisponivel: estado_invalido (aprovada; outra foto em análise) e expurgada
--      (já expurgada; prazo de 24 h vencido).
--   5. Retenção: o pedido não estende o prazo. A nova recusa vence no prazo da primeira
--      decisão, e a nova análise parada também é expurgada nesse prazo.

begin;
select plan(27);

insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
set local "frila.agora" = '2026-11-20 12:00:00+00';

create function pg_temp.erro(sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  execute sql; return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  return msg::jsonb || det::jsonb;
end $$;

create function pg_temp.sessao(conta uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    case when conta is null then '' else json_build_object('sub', conta, 'role', 'authenticated')::text end, true);
end $$;

-- Foto sintética do profissional `dono`, no estado e com a decisão no instante pedidos.
create function pg_temp.foto(id uuid, dono uuid, estado text, decidida timestamptz) returns uuid
language sql as $$
  insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado,
                             motivo_recusa, motivo_codigo, criado_em, atualizado_em)
  values (id, dono, 'profissional', 'foto_perfil', 'perfil/' || id || '.jpg', 'image/jpeg', 1024, estado,
          case when estado = 'recusada' then 'texto_ou_dado_pessoal' end,
          case when estado = 'recusada' then 'interno_sintetico' end, decidida, decidida)
  returning id
$$;

create function pg_temp.na_fila(midia uuid) returns bigint language sql as $$
  select count(*) from pgmq.q_moderacao_midia where message->>'midia_id' = midia::text
$$;

insert into auth.users (id, email) values
  ('81300000-0000-4000-8000-000000000001', 'um@813.test'),
  ('81300000-0000-4000-8000-000000000002', 'dois@813.test'),
  ('81300000-0000-4000-8000-000000000003', 'tres@813.test');
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em)
select id, 'profissional', 'Pessoa sintética', email, '+55619555081' || row_number() over (order by email),
       '1995-01-01', '1.0', now()
  from auth.users where email like '%@813.test';

-- Decisões: A recusada há 1 h; B não publicada há 2 h; C aprovada; D recusada há 25 h;
-- E já expurgada; F recusada da conta 2 (alheia à conta 1).
select pg_temp.foto('81300000-0000-4000-8000-0000000000a1', '81300000-0000-4000-8000-000000000001', 'recusada',      '2026-11-20 11:00:00+00');
select pg_temp.foto('81300000-0000-4000-8000-0000000000f1', '81300000-0000-4000-8000-000000000002', 'recusada',      '2026-11-20 11:00:00+00');

-- ── 1. Porta ──────────────────────────────────────────────────────────────────

select pg_temp.sessao(null);
select is(pg_temp.erro($$select public.pedir_nova_analise_midia('81300000-0000-4000-8000-0000000000a1')$$)->>'status',
  '401', 'sem sessão: 401 nao_autenticado');

select pg_temp.sessao('81300000-0000-4000-8000-000000000001');
update privado.configuracao_app set foto_de_perfil = false;
select is(pg_temp.erro($$select public.pedir_nova_analise_midia('81300000-0000-4000-8000-0000000000a1')$$)->>'details',
  'recurso_desligado', 'RN46: recurso desligado barra com 403 recurso_desligado');
select is((select estado from privado.midia where id = '81300000-0000-4000-8000-0000000000a1'),
  'recusada', 'recurso desligado: a foto não muda de estado');
update privado.configuracao_app set foto_de_perfil = true;

select is(pg_temp.erro($$select public.pedir_nova_analise_midia('81300000-0000-4000-8000-0000000000f1')$$)->>'status',
  '404', 'foto de outra conta: 404, sem revelar que existe');
select is(pg_temp.erro($$select public.pedir_nova_analise_midia('81300000-0000-4000-8000-0000000000ff')$$)->>'code',
  'nao_encontrado', 'foto inexistente: 404 nao_encontrado');

update public.usuario set estado = 'suspensa' where id = '81300000-0000-4000-8000-000000000003';
select pg_temp.sessao('81300000-0000-4000-8000-000000000003');
select is(pg_temp.erro($$select public.pedir_nova_analise_midia('81300000-0000-4000-8000-0000000000a1')$$)->>'details',
  'conta_suspensa', 'conta suspensa: 403 conta_suspensa');

-- ── 2. Caminho feliz ──────────────────────────────────────────────────────────

select pg_temp.sessao('81300000-0000-4000-8000-000000000001');
select is((select e->>'pode_pedir_nova_analise' from jsonb_array_elements(public.minhas_midias()) e
            where e->>'id' = '81300000-0000-4000-8000-0000000000a1'),
  'true', 'recusada dentro das 24 h: pode_pedir_nova_analise = true');

create temp table r1 as
  select public.pedir_nova_analise_midia('81300000-0000-4000-8000-0000000000a1') as resposta;
select is((select resposta->>'estado' from r1), 'em_analise', 'recusada volta a em_analise');
select is((select resposta->>'pode_pedir_nova_analise' from r1), 'false', 'depois do pedido: pode_pedir_nova_analise = false');
select ok((select resposta->'motivo_recusa' = 'null'::jsonb from r1), 'em análise não carrega o motivo da recusa anterior');
select is(pg_temp.na_fila('81300000-0000-4000-8000-0000000000a1'), 1::bigint, 'a análise automática é refeita: uma mensagem na fila');
select is((select expurgo_ate from privado.midia where id = '81300000-0000-4000-8000-0000000000a1'),
  '2026-11-21 11:00:00+00'::timestamptz, 'prazo de expurgo congelado em decisão original + 24 h');

select pg_temp.foto('81300000-0000-4000-8000-0000000000b1', '81300000-0000-4000-8000-000000000003', 'nao_publicada', '2026-11-20 10:00:00+00');
update public.usuario set estado = 'ativa' where id = '81300000-0000-4000-8000-000000000003';
select pg_temp.sessao('81300000-0000-4000-8000-000000000003');
select is(public.pedir_nova_analise_midia('81300000-0000-4000-8000-0000000000b1')->>'estado',
  'em_analise', 'nao_publicada também volta a em_analise');

-- ── 3. Uma vez por foto ───────────────────────────────────────────────────────

select pg_temp.sessao('81300000-0000-4000-8000-000000000001');
-- A moderação recusa de novo (como a Edge Function grava: só em linha em_analise, regravando atualizado_em).
set local "frila.agora" = '2026-11-20 12:30:00+00';
update privado.midia set estado = 'recusada', motivo_recusa = 'texto_ou_dado_pessoal', atualizado_em = privado.agora()
 where id = '81300000-0000-4000-8000-0000000000a1' and estado = 'em_analise';

select is(public.pedir_nova_analise_midia('81300000-0000-4000-8000-0000000000a1')->>'estado',
  'recusada', 'repetir o pedido devolve o estado atual');
select is(pg_temp.na_fila('81300000-0000-4000-8000-0000000000a1'), 1::bigint, 'repetir o pedido não gera outra análise');
select is((select e->>'pode_pedir_nova_analise' from jsonb_array_elements(public.minhas_midias()) e
            where e->>'id' = '81300000-0000-4000-8000-0000000000a1'),
  'false', 'recusada de novo: pode_pedir_nova_analise continua false');

-- ── 4. 409 midia_indisponivel ─────────────────────────────────────────────────

select pg_temp.foto('81300000-0000-4000-8000-0000000000c1', '81300000-0000-4000-8000-000000000002', 'aprovada', '2026-11-20 09:00:00+00');
select pg_temp.sessao('81300000-0000-4000-8000-000000000002');
select is(pg_temp.erro($$select public.pedir_nova_analise_midia('81300000-0000-4000-8000-0000000000c1')$$),
  '{"status":409,"code":"midia_indisponivel","message":"midia_indisponivel","details":"estado_invalido","hint":null,"headers":{}}'::jsonb,
  'aprovada: 409 midia_indisponivel estado_invalido');

-- A conta 2 tem a F recusada e a C aprovada: foto aprovada não impede (é a troca de foto).
select is((select e->>'pode_pedir_nova_analise' from jsonb_array_elements(public.minhas_midias()) e
            where e->>'id' = '81300000-0000-4000-8000-0000000000f1'),
  'true', 'com outra foto só aprovada: pode_pedir_nova_analise = true');
-- Com outra foto em análise, a F não pode voltar a em_analise (índice de foto única).
select pg_temp.foto('81300000-0000-4000-8000-0000000000c2', '81300000-0000-4000-8000-000000000002', 'em_analise', '2026-11-20 11:30:00+00');
select is((select e->>'pode_pedir_nova_analise' from jsonb_array_elements(public.minhas_midias()) e
            where e->>'id' = '81300000-0000-4000-8000-0000000000f1'),
  'false', 'com outra foto em análise: pode_pedir_nova_analise = false');
select is(pg_temp.erro($$select public.pedir_nova_analise_midia('81300000-0000-4000-8000-0000000000f1')$$)->>'details',
  'estado_invalido', 'com outra foto em análise: 409 estado_invalido, sem quebrar o índice de foto única');
select is((select estado from privado.midia where id = '81300000-0000-4000-8000-0000000000f1'),
  'recusada', 'a recusa por outra foto em análise não muda a foto');

select pg_temp.foto('81300000-0000-4000-8000-0000000000d1', '81300000-0000-4000-8000-000000000001', 'recusada', '2026-11-19 11:00:00+00');
select pg_temp.sessao('81300000-0000-4000-8000-000000000001');
select is(pg_temp.erro($$select public.pedir_nova_analise_midia('81300000-0000-4000-8000-0000000000d1')$$)->>'details',
  'expurgada', 'recusada há mais de 24 h, ainda não varrida: 409 expurgada (não estende a retenção)');

select pg_temp.foto('81300000-0000-4000-8000-0000000000e1', '81300000-0000-4000-8000-000000000001', 'expurgada', '2026-11-19 10:00:00+00');
select is(pg_temp.erro($$select public.pedir_nova_analise_midia('81300000-0000-4000-8000-0000000000e1')$$)->>'details',
  'expurgada', 'já expurgada: 409 expurgada');

-- ── 5. Retenção: o prazo é o da primeira decisão ──────────────────────────────

-- A (recusada de novo às 12:30) vence às 11:00 do dia 21, e não às 12:30.
set local "frila.agora" = '2026-11-21 11:30:00+00';
select lives_ok($$select privado.expurgar_midias_recusadas()$$, 'a rotina de expurgo roda');
select is((select estado from privado.midia where id = '81300000-0000-4000-8000-0000000000a1'),
  'expurgada', 'nova recusa vence no prazo da primeira decisão, e não 24 h depois da segunda');

-- B (nao_publicada às 10:00, ainda em_analise) vence às 10:00 do dia 21, mesmo sem veredito.
select is((select estado from privado.midia where id = '81300000-0000-4000-8000-0000000000b1'),
  'expurgada', 'nova análise parada também é expurgada no prazo original');

-- F (recusada às 11:00 do dia 20, sem pedido) segue a regra antiga das 24 h.
select is((select estado from privado.midia where id = '81300000-0000-4000-8000-0000000000f1'),
  'expurgada', 'sem pedido, o expurgo continua 24 h depois da decisão');

select * from finish();
rollback;
