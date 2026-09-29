-- `denunciar` e `bloquear` (RF26, RN13, RN15, UC17), e o bloqueio filtrando cada leitura.
--
-- O bloqueio é imediato e vale nos dois sentidos: as partes não voltam a se cruzar em
-- notificação, lista ou candidatura. Cada caminho por onde uma vaga chega a alguém tem
-- aqui uma asserção antes e outra depois do bloqueio — a de antes prova que o caminho
-- estava aberto, senão a de depois não prova nada:
--
--   vagas_abertas · detalhe_vaga · candidatar · privado.elegiveis (despacho)
--   privado.liberar_teto_do_profissional (o despacho que esperava o teto da RN23)
--   privado.notificacao_expirada (o aviso de vaga já enfileirado para o push)
--   candidatura_leitura (a lista de candidatos que a casa lê)
--
-- A denúncia grava a `ocorrencia` com o relato em coluna própria, que a retenção apaga,
-- e deixa na fila `email` só o id — o corpo do e-mail é montado no envio (7yq1flLG).
--
-- Dados do cenário (`cenarios.sql`): Ana (a…01 / e…01) e Karen (a…11 / e…11) são
-- elegíveis para a vaga d…01 do Bar do Cerrado (c…01); Heitor (e…08) também, e é o
-- controle do teto. Zélia (b…01) administra o bar e Paulo (b…04) é operador. Felipe
-- (a…06 / e…06) já estava bloqueado pela Zélia.

begin;
select plan(58);

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

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create temp table ids as select
  'a0000000-0000-4000-8000-000000000001'::uuid as ana,
  'e0000000-0000-4000-8000-000000000001'::uuid as ana_prof,
  'a0000000-0000-4000-8000-000000000011'::uuid as karen,
  'e0000000-0000-4000-8000-000000000011'::uuid as karen_prof,
  'a0000000-0000-4000-8000-000000000008'::uuid as heitor,
  'e0000000-0000-4000-8000-000000000008'::uuid as heitor_prof,
  'a0000000-0000-4000-8000-000000000006'::uuid as felipe,
  'e0000000-0000-4000-8000-000000000006'::uuid as felipe_prof,
  'b0000000-0000-4000-8000-000000000001'::uuid as zelia,
  'b0000000-0000-4000-8000-000000000004'::uuid as paulo,
  'c0000000-0000-4000-8000-000000000001'::uuid as bar,
  'd0000000-0000-4000-8000-000000000001'::uuid as vaga,
  'f1000000-0000-4000-8000-000000000101'::uuid as posicao;

-- As contas do cenário existem em `usuario`; o token precisa de `auth.users`.
select pg_temp.autenticar(ana,    'ana@frila.test')    from ids;
select pg_temp.autenticar(karen,  'karen@frila.test')  from ids;
select pg_temp.autenticar(felipe, 'felipe@frila.test') from ids;
select pg_temp.autenticar(zelia,  'zelia@frila.test')  from ids;
select pg_temp.autenticar(paulo,  'paulo@frila.test')  from ids;

-- ── 1. As assinaturas e quem chama ────────────────────────────────────────────

select has_function('public', 'bloquear', array['text', 'uuid'],
  'public.bloquear(alvo_tipo, alvo_id) existe');
select has_function('public', 'denunciar', array['text', 'uuid', 'text', 'text', 'uuid', 'uuid'],
  'public.denunciar(alvo_tipo, alvo_id, motivo, relato, chave, turno_id) existe');

select is(
  has_function_privilege('anon', 'public.bloquear(text, uuid)', 'execute')
  or has_function_privilege('anon', 'public.denunciar(text, uuid, text, text, uuid, uuid)', 'execute'),
  false,
  'anon não chama bloquear nem denunciar');

select is(
  has_function_privilege('authenticated', 'public.bloquear(text, uuid)', 'execute')
  and has_function_privilege('authenticated', 'public.denunciar(text, uuid, text, text, uuid, uuid)', 'execute'),
  true,
  'authenticated chama bloquear e denunciar');

select throws_ok(
  format($$ select public.bloquear('estabelecimento', %L) $$, (select bar from ids)),
  'PGRST', pg_temp.erro('nao_autenticado'),
  'bloquear sem sessão é 401');

select throws_ok(
  format($$ select public.denunciar('estabelecimento', %L, 'assedio',
            'Relato longo o bastante', gen_random_uuid()) $$, (select bar from ids)),
  'PGRST', pg_temp.erro('nao_autenticado'),
  'denunciar sem sessão é 401');

-- ── 2. Antes do bloqueio, todos os caminhos estão abertos ─────────────────────

create temp table antes as select
  pg_temp.como((select ana from ids), $$ select public.vagas_abertas(limite => 500) $$) as lista;

select ok(
  exists (select 1 from jsonb_array_elements((select lista from antes)) v
           where (v->>'id')::uuid = (select vaga from ids)),
  'antes: a vaga do bar aparece em vagas_abertas para a Ana');

select is(
  (pg_temp.como((select ana from ids),
     format($$ select public.detalhe_vaga(%L) $$, (select vaga from ids)))->>'id')::uuid,
  (select vaga from ids),
  'antes: detalhe_vaga abre para a Ana');

select ok(
  exists (select 1 from privado.elegiveis((select vaga from ids)) e
           where e.profissional_id = (select ana_prof from ids)),
  'antes: a Ana é elegível para a vaga do bar (despacho)');

select ok(
  exists (select 1 from privado.elegiveis((select vaga from ids)) e
           where e.profissional_id = (select karen_prof from ids)),
  'antes: a Karen é elegível para a vaga do bar (despacho)');

-- O aviso de vaga já enfileirado para a Ana, à espera do push.
create temp table aviso as
  select privado.notificar((select ana from ids), 'vaga', (select vaga from ids),
           jsonb_build_object('vaga_id', (select vaga from ids))) as id;

select is(
  privado.notificacao_expirada((select id from aviso)),
  false,
  'antes: o aviso de vaga para a Ana ainda serve');

-- A candidatura da Karen, que a casa lê na lista de candidatos.
insert into public.candidatura (posicao_id, profissional_id)
select posicao, karen_prof from ids;

select is(
  (pg_temp.como((select zelia from ids), format(
     $$ select to_jsonb(count(*)) from public.candidatura c
         where c.profissional_id = %L $$, (select karen_prof from ids))))::int,
  1,
  'antes: a Zélia vê a candidatura da Karen');

-- ── 3. bloquear: o profissional bloqueia o estabelecimento ────────────────────

create temp table b1 as
  select pg_temp.como((select ana from ids), format(
    $$ select public.bloquear('estabelecimento', %L) $$, (select bar from ids))) as j;

select is(
  (select j - 'criado_em' from b1),
  jsonb_build_object('alvo_tipo', 'estabelecimento', 'alvo_id', (select bar from ids)),
  'bloquear devolve o par que recebeu (schema Bloqueio)');

select ok((select (j->>'criado_em')::timestamptz is not null from b1),
  'bloquear devolve criado_em');

select set_eq(
  format($$ select bloqueado_id from public.bloqueio where autor_id = %L $$, (select ana from ids)),
  format($$ select usuario_id from public.membro_estabelecimento where estabelecimento_id = %L $$,
         (select bar from ids)),
  'o estabelecimento é bloqueado com todos os membros');

select is(
  pg_temp.como((select ana from ids), format(
    $$ select public.bloquear('estabelecimento', %L) $$, (select bar from ids))),
  (select j from b1),
  'bloquear de novo devolve o mesmo bloqueio (idempotente por par)');

select is(
  (select count(*)::int from public.bloqueio b, ids where b.autor_id = ids.ana),
  2,
  'o reenvio não cria linha nova');

-- ── 4. Depois do bloqueio, cada caminho está fechado para a Ana ───────────────

select ok(
  not exists (select 1 from jsonb_array_elements(
                pg_temp.como((select ana from ids), $$ select public.vagas_abertas(limite => 500) $$)) v
               where (v->>'id')::uuid = (select vaga from ids)),
  'depois: a vaga do bar some de vagas_abertas');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select ana from ids),
         format('select public.detalhe_vaga(%L)', (select vaga from ids))),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'depois: detalhe_vaga responde 404');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select ana from ids),
         format('select public.candidatar(%L)', (select vaga from ids))),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'depois: candidatar responde 404');

select ok(
  not exists (select 1 from privado.elegiveis((select vaga from ids)) e
               where e.profissional_id = (select ana_prof from ids)),
  'depois: o despacho não alcança a Ana');

select is(
  privado.notificacao_expirada((select id from aviso)),
  true,
  'depois: o aviso de vaga já enfileirado não sai para a Ana');

-- O despacho que esperava o teto da RN23. Heitor é o controle: a mesma espera, sem
-- bloqueio, vira notificação.
-- A janela do teto fica para trás para os dois: sem isto, o aviso recente da Ana faria
-- `liberar_teto` devolver nulo pelo teto, e não pelo bloqueio.
update public.notificacao n set enviada_em = n.enviada_em - interval '1 day'
  from ids where n.usuario_id in (ids.ana, ids.heitor);

insert into public.despacho (vaga_id, profissional_id)
select vaga, heitor_prof from ids;
insert into public.despacho (vaga_id, profissional_id)
select vaga, ana_prof from ids
on conflict (vaga_id, profissional_id) do nothing;

select isnt(
  privado.liberar_teto_do_profissional((select heitor_prof from ids)),
  null,
  'controle: o despacho que esperava o teto vira notificação para quem não bloqueou');

select is(
  privado.liberar_teto_do_profissional((select ana_prof from ids)),
  null,
  'depois: o despacho que esperava o teto não vira notificação para a Ana');

-- ── 5. bloquear: o membro bloqueia o profissional ─────────────────────────────

create temp table b2 as
  select pg_temp.como((select paulo from ids), format(
    $$ select public.bloquear('profissional', %L) $$, (select karen_prof from ids))) as j;

select is(
  (select j - 'criado_em' from b2),
  jsonb_build_object('alvo_tipo', 'profissional', 'alvo_id', (select karen_prof from ids)),
  'o membro bloqueia o profissional pelo id do PerfilPublico');

select is(
  (select count(*)::int from public.bloqueio b, ids
    where b.autor_id = ids.paulo and b.bloqueado_id = ids.karen),
  1,
  'o profissional é bloqueado na conta dele');

select ok(
  not exists (select 1 from privado.elegiveis((select vaga from ids)) e
               where e.profissional_id = (select karen_prof from ids)),
  'o bloqueio de um operador tira a Karen do despacho do estabelecimento inteiro');

select is(
  (pg_temp.como((select zelia from ids), format(
     $$ select to_jsonb(count(*)) from public.candidatura c
         where c.profissional_id = %L $$, (select karen_prof from ids))))::int,
  0,
  'a outra administradora também deixa de ver a candidatura da Karen');

select is(
  (pg_temp.como((select paulo from ids), format(
     $$ select to_jsonb(count(*)) from public.candidatura c
         where c.profissional_id = %L $$, (select karen_prof from ids))))::int,
  0,
  'quem bloqueou não vê a Karen na lista de candidatos');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select karen from ids),
         format('select public.detalhe_vaga(%L)', (select vaga from ids))),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'vale nos dois sentidos: a Karen também deixa de ver a vaga do bar');

select is(
  (pg_temp.como((select karen from ids),
     $$ select to_jsonb(count(*)) from public.bloqueio $$))::int,
  0,
  'quem foi bloqueado não lê o bloqueio');

-- ── 6. bloquear: recusas ──────────────────────────────────────────────────────

select throws_ok(
  format($$ select pg_temp.como(%L, 'select public.bloquear(''estabelecimento'', gen_random_uuid())') $$,
         (select ana from ids)),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'bloquear alvo que não existe é 404');

select throws_ok(
  format($$ select pg_temp.como(%L, 'select public.bloquear(''estabelecimento'', null)') $$,
         (select ana from ids)),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'alvo_id'),
  'bloquear sem alvo_id é 422 campo_obrigatorio');

select throws_ok(
  format($$ select pg_temp.como(%L, 'select public.bloquear(null, gen_random_uuid())') $$,
         (select ana from ids)),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'alvo_tipo'),
  'bloquear sem alvo_tipo é 422 campo_obrigatorio');

select throws_ok(
  format($$ select pg_temp.como(%L, 'select public.bloquear(''vaga'', gen_random_uuid())') $$,
         (select ana from ids)),
  'PGRST', pg_temp.erro('campo_invalido', 'alvo_tipo'),
  'alvo_tipo fora de TipoDeAlvo é 422 campo_invalido');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select ana from ids),
         format('select public.bloquear(''profissional'', %L)', (select felipe_prof from ids))),
  'PGRST', pg_temp.erro('campo_invalido', 'alvo_tipo'),
  'profissional não bloqueia profissional: as partes do produto são a pessoa e a casa');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select zelia from ids),
         format('select public.bloquear(''estabelecimento'', %L)', (select bar from ids))),
  'PGRST', pg_temp.erro('campo_invalido', 'alvo_tipo'),
  'membro não bloqueia estabelecimento, nem o próprio');

-- ── 7. denunciar ──────────────────────────────────────────────────────────────

-- A Ana denuncia o bar, citando o turno de sábado — e a denúncia vale mesmo depois do
-- bloqueio, que é a ordem natural de quem se sentiu ameaçado.
create temp table turno_ana as
  select t.id from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v on v.id = p.vaga_id
   where p.profissional_id = (select ana_prof from ids)
     and v.estabelecimento_id = (select bar from ids)
   limit 1;

create temp table d1 as
  select pg_temp.como((select ana from ids), format(
    $$ select public.denunciar(alvo_tipo => 'estabelecimento', alvo_id => %L,
         turno_id => %L, motivo => 'assedio',
         relato => 'O gerente gritou comigo na frente dos clientes.',
         chave => 'ad360000-0000-4000-8000-000000000001') $$,
    (select bar from ids), (select id from turno_ana))) as j;

select is(
  (select array_agg(k order by k) from d1, jsonb_object_keys(j) k),
  array['criada_em', 'ocorrencia_id', 'prazo_resposta_ate', 'tipo'],
  'denunciar devolve o schema Protocolo, e nada além');

select is((select j->>'tipo' from d1), 'denuncia', 'o protocolo é de denúncia');

-- Cinco dias úteis contados no dia de Brasília seguinte ao registro, sem sábado e domingo.
select is(
  (select (j->>'prazo_resposta_ate')::date from d1),
  (select d::date from d1,
          generate_series(((j->>'criada_em')::timestamptz at time zone 'America/Sao_Paulo')::date + 1,
                          ((j->>'criada_em')::timestamptz at time zone 'America/Sao_Paulo')::date + 14,
                          interval '1 day') d
    where extract(isodow from d) < 6
    order by d offset 4 limit 1),
  'o prazo de resposta é de 5 dias úteis');

select is(privado.prazo_de_resposta('2026-10-02 12:00-03'), '2026-10-09'::date,
  'denúncia de sexta: o prazo é a sexta seguinte');

-- Domingo 22h em Brasília já é segunda em UTC. Contado em UTC, o prazo cairia em 12/10.
select is(privado.prazo_de_resposta('2026-10-05 01:00+00'), '2026-10-09'::date,
  'o dia que conta é o de Brasília, e não o de UTC');

create temp table oc1 as
  select o.* from public.ocorrencia o where o.id = (select (j->>'ocorrencia_id')::uuid from d1);

select is(
  (select jsonb_build_object('tipo', tipo, 'autor_id', autor_id, 'motivo', motivo,
            'estabelecimento_id', estabelecimento_id, 'usuario_id', usuario_id,
            'turno_id', turno_id, 'chave_cliente', chave_cliente) from oc1),
  jsonb_build_object('tipo', 'denuncia', 'autor_id', (select ana from ids), 'motivo', 'assedio',
            'estabelecimento_id', (select bar from ids), 'usuario_id', null,
            'turno_id', (select id from turno_ana),
            'chave_cliente', 'ad360000-0000-4000-8000-000000000001'),
  'a ocorrência guarda tipo, autor, alvo, turno, motivo e chave');

select is((select relato from oc1), 'O gerente gritou comigo na frente dos clientes.',
  'o relato vai para ocorrencia.relato');

-- A fila `email`: um pedido por denúncia, só com ids (RN15). O relato não entra.
select is(
  (select count(*)::int from pgmq.q_email
    where message->>'ocorrencia_id' = (select j->>'ocorrencia_id' from d1)),
  1,
  'a denúncia enfileira um e-mail na fila email');

select is(
  (select message from pgmq.q_email
    where message->>'ocorrencia_id' = (select j->>'ocorrencia_id' from d1)),
  jsonb_build_object('tipo', 'denuncia', 'ocorrencia_id', (select j->>'ocorrencia_id' from d1)),
  'o pedido de e-mail leva só o tipo e o id da ocorrência (RN15)');

select is(
  pg_temp.como((select ana from ids), format(
    $$ select public.denunciar('estabelecimento', %L, 'outro', 'Outro texto qualquer aqui.',
         'ad360000-0000-4000-8000-000000000001') $$, (select bar from ids))),
  (select j from d1),
  'reenviar com a mesma chave devolve o mesmo protocolo');

select is(
  (select count(*)::int from pgmq.q_email
    where message->>'ocorrencia_id' = (select j->>'ocorrencia_id' from d1)),
  1,
  'o reenvio não enfileira segundo e-mail');

-- O membro denuncia o profissional: o alvo é a conta dele.
create temp table d2 as
  select pg_temp.como((select zelia from ids), format(
    $$ select public.denunciar('profissional', %L, 'risco_seguranca',
         'Chegou alterado e ameaçou a equipe.', 'ad360000-0000-4000-8000-000000000002') $$,
    (select felipe_prof from ids))) as j;

select is(
  (select jsonb_build_object('usuario_id', o.usuario_id, 'estabelecimento_id', o.estabelecimento_id,
                             'motivo', o.motivo)
     from public.ocorrencia o where o.id = (select (j->>'ocorrencia_id')::uuid from d2)),
  jsonb_build_object('usuario_id', (select felipe from ids), 'estabelecimento_id', null,
                     'motivo', 'risco_seguranca'),
  'denúncia de profissional aponta a conta dele');

select is(
  (pg_temp.como((select felipe from ids), format(
     $$ select to_jsonb(count(*)) from public.ocorrencia o where o.id = %L $$,
     (select j->>'ocorrencia_id' from d2))))::int,
  0,
  'o denunciado não lê a denúncia');

select is(
  (pg_temp.como((select zelia from ids), format(
     $$ select to_jsonb(count(*)) from public.ocorrencia o where o.id = %L $$,
     (select j->>'ocorrencia_id' from d2))))::int,
  1,
  'quem denunciou lê a própria denúncia');

-- ── 8. denunciar: recusas ─────────────────────────────────────────────────────

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select ana from ids),
    $x$ select public.denunciar('profissional', gen_random_uuid(), 'assedio',
          'Relato longo o bastante', gen_random_uuid()) $x$),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'denunciar alvo que não existe é 404');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select ana from ids),
    format($x$ select public.denunciar('estabelecimento', %L, 'assedio',
                 'Relato longo o bastante', gen_random_uuid(), gen_random_uuid()) $x$,
           (select bar from ids))),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'turno_id que não é entre as duas partes é 404');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select karen from ids),
    format($x$ select public.denunciar('estabelecimento', %L, 'assedio',
                 'Relato longo o bastante', gen_random_uuid(), %L) $x$,
           (select bar from ids), (select id from turno_ana))),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'o turno de outra pessoa é 404');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select ana from ids),
    format($x$ select public.denunciar('estabelecimento', %L, 'assedio', 'curto', gen_random_uuid()) $x$,
           (select bar from ids))),
  'PGRST', pg_temp.erro('campo_invalido', 'relato'),
  'relato com menos de 10 caracteres é 422 campo_invalido');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select ana from ids),
    format($x$ select public.denunciar('estabelecimento', %L, 'assedio', null, gen_random_uuid()) $x$,
           (select bar from ids))),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'relato'),
  'relato ausente é 422 campo_obrigatorio');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select ana from ids),
    format($x$ select public.denunciar('estabelecimento', %L, 'fraude', 'Relato longo o bastante',
                 gen_random_uuid()) $x$, (select bar from ids))),
  'PGRST', pg_temp.erro('campo_invalido', 'motivo'),
  'motivo fora de MotivoDenuncia é 422 campo_invalido');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select ana from ids),
    format($x$ select public.denunciar('estabelecimento', %L, 'assedio', 'Relato longo o bastante',
                 null) $x$, (select bar from ids))),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'chave'),
  'denúncia sem chave é 422 campo_obrigatorio');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select ana from ids),
    format($x$ select public.denunciar('profissional', %L, 'assedio', 'Relato longo o bastante',
                 gen_random_uuid()) $x$, (select ana_prof from ids))),
  'PGRST', pg_temp.erro('campo_invalido', 'alvo_id'),
  'ninguém denuncia a si mesmo');

select throws_ok(
  format($$ select pg_temp.como(%L, %L) $$, (select zelia from ids),
    format($x$ select public.denunciar('estabelecimento', %L, 'assedio', 'Relato longo o bastante',
                 gen_random_uuid()) $x$, (select bar from ids))),
  'PGRST', pg_temp.erro('campo_invalido', 'alvo_id'),
  'o membro não denuncia a própria casa');

-- ── 9. A retenção apaga o relato ──────────────────────────────────────────────

select pg_temp.autenticar('ad360000-0000-4000-8000-0000000000e1', 'relato@denuncia.test');
select pg_temp.como('ad360000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional', 'Quem Denunciou', '+5561936000001', '1990-06-15', '2026-09-22') $$);

create temp table d3 as
  select pg_temp.como('ad360000-0000-4000-8000-0000000000e1', format(
    $$ select public.denunciar('estabelecimento', %L, 'discriminacao',
         'Recusaram por causa do meu sotaque.', 'ad360000-0000-4000-8000-000000000003') $$,
    (select bar from ids))) as j;

select privado.excluir_conta('ad360000-0000-4000-8000-0000000000e1');
update public.usuario set anonimizado_em = privado.agora() - interval '16 days'
 where id = 'ad360000-0000-4000-8000-0000000000e1';
select privado.limpar_contas_anonimizadas(15);

select is(
  (select relato from public.ocorrencia o where o.id = (select (j->>'ocorrencia_id')::uuid from d3)),
  null,
  'a retenção apaga ocorrencia.relato da conta anonimizada (RF25, RN15)');

select is(
  (select tipo::text || ':' || motivo from public.ocorrencia o
    where o.id = (select (j->>'ocorrencia_id')::uuid from d3)),
  'denuncia:[removido por exclusão de conta]',
  'a ocorrência sobrevive como registro, sem o relato');

select * from finish();
rollback;
