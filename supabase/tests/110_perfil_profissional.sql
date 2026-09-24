-- As três RPCs do perfil profissional: criar, ler e atualizar.
--
-- É aqui que o profissional declara o que decide se ele recebe cada vaga: as funções, o
-- ponto base e a grade semanal. Não há raio configurável e não há "disponível agora" —
-- os dois saíram do produto em 21 e 22/09, e a única coisa que vale é a grade.
--
-- A janela que atravessa a meia-noite (18:00–02:00) tem asserção própria porque é a
-- mais comum do setor, e porque é a que um `CHECK (hora_fim > hora_inicio)` escrito por
-- reflexo excluiria do produto — justamente o turno que o Frila existe para preencher.

begin;
select plan(33);

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

-- ── Duas contas: uma de profissional, uma de contratante ─────────────────────

select pg_temp.autenticar('d1000000-0000-4000-8000-000000000001','perfil-prof@t.test');
select pg_temp.autenticar('d1000000-0000-4000-8000-000000000002','perfil-cont@t.test');
select pg_temp.autenticar('d1000000-0000-4000-8000-000000000003','perfil-sem@t.test');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('d1000000-0000-4000-8000-000000000001','profissional','Nina Alves','+5561999990401','perfil-prof@t.test','1995-02-10','2026-09-22', now()),
  ('d1000000-0000-4000-8000-000000000002','contratante', 'Rui Peixoto','+5561999990402','perfil-cont@t.test','1980-02-10','2026-09-22', now()),
  ('d1000000-0000-4000-8000-000000000003','profissional','Tom Barros','+5561999990403','perfil-sem@t.test','1993-02-10','2026-09-22', now());

create temp table f as
  select (select id from public.funcao where nome = 'garçom')    as garcom,
         (select id from public.funcao where nome = 'bartender') as bartender,
         (select id from public.funcao where nome = 'chapeiro')  as chapeiro;

-- ── RN25: a conta de contratante não tem perfil de profissional ──────────────
--
-- Primeira linha da função, e não uma checagem no fim: a recusa tem de vir antes de
-- qualquer escrita, senão sobra linha órfã quando a validação seguinte falhar.

select throws_ok(
  format($$ select pg_temp.como('d1000000-0000-4000-8000-000000000002',
    $c$ select public.criar_perfil_profissional(
          array[%L]::uuid[],
          '{"latitude":-15.79,"longitude":-47.88}'::jsonb,
          '[]'::jsonb) $c$) $$, (select garcom from f)),
  'PGRST',
  '{"code" : "perfil_incompativel", "message" : "perfil_incompativel", "details" : null, "hint" : null}',
  'RN25: conta de contratante recebe perfil_incompativel');

-- ── Ler antes de criar ────────────────────────────────────────────────────────

select throws_ok(
  $$ select pg_temp.como('d1000000-0000-4000-8000-000000000001',
       $c$ select public.meu_perfil_profissional() $c$) $$,
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'antes de criar, meu_perfil_profissional devolve nao_encontrado');

-- ── O caminho feliz ───────────────────────────────────────────────────────────

create temp table p as select pg_temp.como('d1000000-0000-4000-8000-000000000001', format(
  $c$ select public.criar_perfil_profissional(
        array[%L,%L]::uuid[],
        '{"latitude":-15.7650,"longitude":-47.8830}'::jsonb,
        '[{"dia_semana":5,"hora_inicio":"18:00","hora_fim":"02:00"},
          {"dia_semana":6,"hora_inicio":"06:00","hora_fim":"14:00"}]'::jsonb) $c$,
  (select garcom from f), (select bartender from f))) as j;

select is((select j->>'usuario_id' from p), 'd1000000-0000-4000-8000-000000000001',
  'o perfil nasce ligado à conta do chamador');

select is((select jsonb_array_length(j->'funcoes') from p), 2,
  'com as duas funções declaradas');

-- O contrato devolve `Funcao` inteira, não só o id: a tela mostra o nome, e obrigá-la a
-- cruzar com o catálogo para escrever "garçom" seria uma chamada a mais em toda abertura.
select is(
  (select jsonb_agg(x->>'nome' order by x->>'nome') from p, jsonb_array_elements(j->'funcoes') x),
  '["bartender", "garçom"]'::jsonb,
  'e cada função vem com nome e categoria, não só com o id');

select is((select (j->'ponto_base'->>'latitude')::numeric from p), -15.7650,
  'o ponto base volta como latitude e longitude, e não como geography crua');
select is((select (j->'ponto_base'->>'longitude')::numeric from p), -47.8830,
  'nas duas coordenadas');

select is((select jsonb_array_length(j->'disponibilidades') from p), 2,
  'com as duas janelas da grade');

-- A janela que atravessa a meia-noite, que é o critério de aceite do cartão.
select is(
  (select x from p, jsonb_array_elements(j->'disponibilidades') x
    where (x->>'dia_semana')::int = 5),
  '{"dia_semana": 5, "hora_fim": "02:00", "hora_inicio": "18:00"}'::jsonb,
  'a janela 18:00–02:00 é gravada e lida de volta igual');

-- Sem histórico, a taxa é nula e não zero: as duas contam histórias opostas sobre quem
-- acabou de chegar, e a tela precisa saber a diferença (RF16).
select is((select j->'reputacao'->>'taxa_comparecimento' from p), null,
  'RF16: perfil novo vem sem histórico, com a taxa nula e não zero');
select is((select (j->'reputacao'->>'total')::int from p), 0,
  'e com o denominador zerado');

-- ── Ler de volta ──────────────────────────────────────────────────────────────

select is(
  (select pg_temp.como('d1000000-0000-4000-8000-000000000001',
     $c$ select public.meu_perfil_profissional() $c$) -> 'id'),
  (select j->'id' from p),
  'meu_perfil_profissional devolve o mesmo perfil que criar devolveu');

select is(
  (select jsonb_array_length(pg_temp.como('d1000000-0000-4000-8000-000000000001',
     $c$ select public.meu_perfil_profissional() $c$) -> 'disponibilidades')),
  2,
  'com a grade inteira');

-- ── Criar duas vezes ──────────────────────────────────────────────────────────

select throws_ok(
  format($$ select pg_temp.como('d1000000-0000-4000-8000-000000000001',
    $c$ select public.criar_perfil_profissional(array[%L]::uuid[],
          '{"latitude":-15.79,"longitude":-47.88}'::jsonb, '[]'::jsonb) $c$) $$,
    (select garcom from f)),
  'PGRST',
  '{"code" : "perfil_ja_existe", "message" : "perfil_ja_existe", "details" : null, "hint" : null}',
  'criar duas vezes é conflito, e não sobrescrita silenciosa');

-- ── As recusas de criar ───────────────────────────────────────────────────────

select throws_ok(
  $$ select pg_temp.como('d1000000-0000-4000-8000-000000000003',
    $c$ select public.criar_perfil_profissional(array[]::uuid[],
          '{"latitude":-15.79,"longitude":-47.88}'::jsonb, '[]'::jsonb) $c$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "funcoes", "hint" : null}',
  'sem nenhuma função não há perfil: é o que decide quem recebe a vaga (RN05)');

select throws_ok(
  format($$ select pg_temp.como('d1000000-0000-4000-8000-000000000003',
    $c$ select public.criar_perfil_profissional(array[%L]::uuid[], null, '[]'::jsonb) $c$) $$,
    (select garcom from f)),
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "ponto_base", "hint" : null}',
  'nem sem ponto base: sem ele não há distância para medir');

-- Id que não está no catálogo. A função nunca é texto livre (RN05), e aceitar um id
-- inexistente deixaria o profissional com uma função que nenhuma vaga pede.
select throws_ok(
  $$ select pg_temp.como('d1000000-0000-4000-8000-000000000003',
    $c$ select public.criar_perfil_profissional(
          array['00000000-0000-4000-8000-000000000000']::uuid[],
          '{"latitude":-15.79,"longitude":-47.88}'::jsonb, '[]'::jsonb) $c$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "funcoes", "hint" : null}',
  'função fora do catálogo é campo_invalido, não campo_obrigatorio');

select throws_ok(
  format($$ select pg_temp.como('d1000000-0000-4000-8000-000000000003',
    $c$ select public.criar_perfil_profissional(array[%L]::uuid[],
          '{"latitude":-120,"longitude":-47.88}'::jsonb, '[]'::jsonb) $c$) $$,
    (select garcom from f)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "ponto_base", "hint" : null}',
  'latitude fora de -90..90 é recusada antes de virar geography');

select throws_ok(
  format($$ select pg_temp.como('d1000000-0000-4000-8000-000000000003',
    $c$ select public.criar_perfil_profissional(array[%L]::uuid[],
          '{"latitude":-15.79,"longitude":-47.88}'::jsonb,
          '[{"dia_semana":9,"hora_inicio":"18:00","hora_fim":"02:00"}]'::jsonb) $c$) $$,
    (select garcom from f)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "disponibilidades", "hint" : null}',
  'dia_semana fora de 0..6 é recusado');

-- Janela de duração zero não é janela. A restrição da tabela recusa; a RPC devolve o
-- código que o app sabe ler, em vez de um 23514 cru.
select throws_ok(
  format($$ select pg_temp.como('d1000000-0000-4000-8000-000000000003',
    $c$ select public.criar_perfil_profissional(array[%L]::uuid[],
          '{"latitude":-15.79,"longitude":-47.88}'::jsonb,
          '[{"dia_semana":5,"hora_inicio":"18:00","hora_fim":"18:00"}]'::jsonb) $c$) $$,
    (select garcom from f)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "disponibilidades", "hint" : null}',
  'janela de duração zero é recusada — 18:00–02:00 vale, 18:00–18:00 não');

-- ── Grade vazia é aceita ──────────────────────────────────────────────────────
--
-- O cartão é explícito: perfil sem janela nenhuma é aceito, e o app avisa que ele não
-- vai receber notificação. Recusar aqui obrigaria a pessoa a inventar uma grade para
-- terminar o cadastro, e grade inventada é pior que grade vazia — ela produz despacho
-- para quem não vai atender.

select lives_ok(
  format($$ select pg_temp.como('d1000000-0000-4000-8000-000000000003',
    $c$ select public.criar_perfil_profissional(array[%L]::uuid[],
          '{"latitude":-15.79,"longitude":-47.88}'::jsonb, '[]'::jsonb) $c$) $$,
    (select garcom from f)),
  'perfil sem nenhuma janela de disponibilidade é aceito');

select is(
  (select jsonb_array_length(pg_temp.como('d1000000-0000-4000-8000-000000000003',
     $c$ select public.meu_perfil_profissional() $c$) -> 'disponibilidades')),
  0,
  'e volta com a grade vazia, não com uma janela inventada');

-- ── Atualizar ─────────────────────────────────────────────────────────────────

select is(
  (select jsonb_array_length(pg_temp.como('d1000000-0000-4000-8000-000000000001',
     format($c$ select public.atualizar_perfil_profissional(funcoes => array[%L]::uuid[]) $c$,
            (select chapeiro from f))) -> 'funcoes')),
  1,
  'atualizar só as funções substitui a lista inteira');

-- O que não foi enviado fica como estava. É o que o contrato promete, e é o que evita
-- que uma tela que só edita funções apague a grade de quem a preencheu.
select is(
  (select jsonb_array_length(pg_temp.como('d1000000-0000-4000-8000-000000000001',
     $c$ select public.meu_perfil_profissional() $c$) -> 'disponibilidades')),
  2,
  'e a grade, que não foi enviada, continua intacta');

select is(
  (select (pg_temp.como('d1000000-0000-4000-8000-000000000001',
     $c$ select public.atualizar_perfil_profissional(
           ponto_base => '{"latitude":-15.8300,"longitude":-47.8400}'::jsonb) $c$)
     -> 'ponto_base' ->> 'latitude')::numeric),
  -15.8300,
  'atualizar só o ponto base move o ponto');

select is(
  (select jsonb_array_length(pg_temp.como('d1000000-0000-4000-8000-000000000001',
     $c$ select public.meu_perfil_profissional() $c$) -> 'funcoes')),
  1,
  'e não mexe nas funções');

select is(
  (select jsonb_array_length(pg_temp.como('d1000000-0000-4000-8000-000000000001',
     $c$ select public.atualizar_perfil_profissional(disponibilidades => '[]'::jsonb) $c$)
     -> 'disponibilidades')),
  0,
  'mandar disponibilidades vazia limpa a grade — é substituição, não acréscimo');

-- ── As recusas de atualizar ───────────────────────────────────────────────────
--
-- O critério de aceite do cartão, por escrito.

select throws_ok(
  $$ select pg_temp.como('d1000000-0000-4000-8000-000000000001',
       $c$ select public.atualizar_perfil_profissional(funcoes => array[]::uuid[]) $c$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "funcoes", "hint" : null}',
  'funcoes: [] em atualizar é campo_obrigatorio, com o campo no details');

-- Chamada sem nenhum campo não é erro de campo: é chamada sem pedido. `minProperties: 1`
-- no contrato diz o mesmo.
select throws_ok(
  $$ select pg_temp.como('d1000000-0000-4000-8000-000000000001',
       $c$ select public.atualizar_perfil_profissional() $c$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "nenhum_campo", "hint" : null}',
  'atualizar sem nenhum campo é recusado: não há o que atualizar');

select throws_ok(
  $$ select pg_temp.como('d1000000-0000-4000-8000-000000000002',
       $c$ select public.atualizar_perfil_profissional(
             ponto_base => '{"latitude":-15.79,"longitude":-47.88}'::jsonb) $c$) $$,
  'PGRST',
  '{"code" : "perfil_incompativel", "message" : "perfil_incompativel", "details" : null, "hint" : null}',
  'RN25 vale para atualizar também');

-- ── Sem sessão não se faz nada ────────────────────────────────────────────────

select throws_ok(
  $$ select public.meu_perfil_profissional() $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não se lê perfil');

select throws_ok(
  $$ select public.atualizar_perfil_profissional(ponto_base => '{"latitude":-15.79,"longitude":-47.88}'::jsonb) $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'nem se atualiza');

-- ── O filtro da diretriz 1.2 não se aplica aqui ──────────────────────────────
--
-- Não há campo de texto livre neste cartão: função é id do catálogo, ponto é número e
-- hora é hora. É o que torna o perfil profissional o lugar mais seguro do produto — e
-- é por isso que esta asserção existe, para que um campo de texto livre acrescentado
-- depois chegue com a pergunta feita.

select is(
  (select count(*)::int
     from information_schema.parameters
    where specific_schema = 'public'
      and specific_name like 'criar_perfil_profissional%'
      and data_type = 'text'),
  0,
  'criar_perfil_profissional não tem nenhum parâmetro de texto livre');

select * from finish();
rollback;
