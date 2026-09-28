-- A janela do registro de presença não se aplica à conta de revisão da App Store.
--
-- O `seed.sql` semeia para a revisão um turno confirmado que começa dois dias depois de
-- o seed rodar, e `privado.exigir_janela` aceita registro de 60 minutos antes do início
-- até o fim previsto. O resultado é uma janela de sete horas que abre 47 horas depois do
-- seed e nunca mais volta: em produção o seed entra uma vez, e quando o revisor chega —
-- Beta App Review a partir de 20/10, revisão da loja em 06/11 — qualquer tentativa de
-- bater o ponto responde `422 fora_da_janela`. Medido em 25/09 contra o banco local, com
-- a sessão de `revisao-profissional@frila.app`, antes de existir a isenção que este
-- arquivo cobre.
--
-- A diretriz 2.1 é exatamente sobre isso: o revisor precisa percorrer o produto, e o
-- check-in é o meio do ciclo. Sem ele, metade do que o app faz fica inalcançável.
--
-- A isenção é **só** da janela relativa ao turno. Registro no futuro continua recusado
-- para todo mundo, inclusive para a revisão: registro no futuro é o caminho mais curto
-- para fabricar presença, e afrouxá-lo por causa da revisão abriria a porta para valer.
--
-- O par de controle é o que dá sentido ao arquivo. A asserção da conta de demonstração
-- tem a asserção gêmea da conta real, no mesmo cenário e no mesmo relógio: é ela que
-- prova que a janela continua valendo para o produto, e que morre no dia em que alguém
-- trocar a condição da isenção por um `true`.
--
-- Ids próprios, começando em `f8000000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(9);

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

-- `d` é a dona da casa, `e` o profissional. O sufixo 1 é o par real; o 2, o de revisão.
select pg_temp.autenticar('f8000000-0000-4000-8000-0000000000d1','casa-real@janela.test');
select pg_temp.autenticar('f8000000-0000-4000-8000-0000000000e1','prof-real@janela.test');
select pg_temp.autenticar('f8000000-0000-4000-8000-0000000000d2','casa-demo@janela.test');
select pg_temp.autenticar('f8000000-0000-4000-8000-0000000000e2','prof-demo@janela.test');

select pg_temp.como('f8000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Casa Real','+5561955550001','1980-01-01','2026-09-22') $$);
select pg_temp.como('f8000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Prof Real','+5561955550011','1995-01-01','2026-09-22') $$);
select pg_temp.como('f8000000-0000-4000-8000-0000000000d2',
  $$ select public.criar_conta('contratante','Casa da Revisao','+5561955550002','1980-01-01','2026-09-22') $$);
select pg_temp.como('f8000000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Perfil da Revisao','+5561955550012','1995-01-01','2026-09-22') $$);

-- A marca de demonstração, nas duas contas do par de revisão. É a mesma coluna que o
-- `seed.sql` usa, e a mesma que isola as duas populações nas leituras de vaga.
update public.usuario set demonstracao = true
 where id in ('f8000000-0000-4000-8000-0000000000d2','f8000000-0000-4000-8000-0000000000e2');

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create function pg_temp.perfil(conta uuid) returns void
language plpgsql as $corpo$
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, (select garcom from fn)));
end $corpo$;

select pg_temp.perfil('f8000000-0000-4000-8000-0000000000e1');
select pg_temp.perfil('f8000000-0000-4000-8000-0000000000e2');

create temp table casas as
  select (pg_temp.como('f8000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Bar Real','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as casa_real,
         (pg_temp.como('f8000000-0000-4000-8000-0000000000d2',
    $$ select public.cadastrar_estabelecimento('Bar da Revisao','68558622000173','food_service',
         'SCLN 407','{"latitude":-15.7915,"longitude":-47.8865}') $$)->>'id')::uuid as casa_demo;

-- Dois dias adiante, como no `seed.sql`: fora da janela por 47 horas.
create temp table quando as
  select (privado.agora() + interval '2 days')         as ini,
         (privado.agora() + interval '2 days 6 hours') as fim;

create function pg_temp.publicar(conta uuid, casa uuid, chave uuid) returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como(conta, format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 406',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, 'Seu Ze', 'urgencia', %L) $sql$,
    casa, (select garcom from fn), (select ini from quando), (select fim from quando),
    chave))->>'vaga_id')::uuid;
end $corpo$;

create temp table t as
  select (pg_temp.como('f8000000-0000-4000-8000-0000000000e1',
            format($$ select public.candidatar(%L) $$,
                   pg_temp.publicar('f8000000-0000-4000-8000-0000000000d1',
                                    (select casa_real from casas),
                                    'f8000000-0000-4000-8000-000000000001')))->>'turno_id')::uuid as turno_real,
         (pg_temp.como('f8000000-0000-4000-8000-0000000000e2',
            format($$ select public.candidatar(%L) $$,
                   pg_temp.publicar('f8000000-0000-4000-8000-0000000000d2',
                                    (select casa_demo from casas),
                                    'f8000000-0000-4000-8000-000000000002')))->>'turno_id')::uuid as turno_demo;

select isnt((select turno_real from t), null, 'o turno do par real nasceu confirmado');
select isnt((select turno_demo from t), null, 'o turno do par de revisão nasceu confirmado');

-- ── O relógio fica onde o revisor chega: hoje, com o turno dois dias à frente ──
--
-- Sem mexer no relógio, `privado.agora()` já está 47 horas antes da abertura da janela.
-- O `frila.agora` entra fixo de propósito: as asserções comparam contra ele, e um
-- relógio que anda entre duas linhas tornaria a última asserção dependente do tempo de
-- execução do arquivo.
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', now()::text, true);

-- ── A conta real: a janela continua fechada ───────────────────────────────────
select throws_ok(
  format($$ select pg_temp.como('f8000000-0000-4000-8000-0000000000e1',
       $x$ select public.fazer_checkin(%L, null, %L) $x$) $$,
         (select turno_real from t), privado.agora()),
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'a janela continua valendo para o produto: conta real recebe 422 fora_da_janela');

-- ── A isenção não é passe livre: o turno tem de ser da pessoa ─────────────────
select throws_ok(
  format($$ select pg_temp.como('f8000000-0000-4000-8000-0000000000e2',
       $x$ select public.fazer_checkin(%L, null, %L) $x$) $$,
         (select turno_real from t), privado.agora()),
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'o turno de outra pessoa continua 404 para a conta de revisão');

-- ── A conta de demonstração: entra, e entra como manual ───────────────────────
--
-- Sem distância, RN22 manda o servidor decidir `manual` e `pendente`. O revisor está
-- fora do DF, e é esse o caminho que as notas da revisão descrevem.
select is(
  (pg_temp.como('f8000000-0000-4000-8000-0000000000e2',
    format($$ select public.fazer_checkin(%L, null, %L) $$,
           (select turno_demo from t), privado.agora())))->>'tipo',
  'manual',
  'diretriz 2.1: a conta de revisão bate o ponto fora da janela, e o registro é manual');

select is(
  (select tu.verificacao::text from public.turno tu where tu.id = (select turno_demo from t)),
  'pendente',
  'e nasce pendente: a isenção afrouxa a janela, não a verificação da presença');

-- ── A casa de demonstração confirma, e só então é presença ────────────────────
select is(
  (pg_temp.como('f8000000-0000-4000-8000-0000000000d2',
    format($$ select public.confirmar_checkin_manual(%L) $$,
           (select turno_demo from t))))->>'verificacao',
  'verificado',
  'RF20: a casa da revisão confirma o manual, e o turno vira verificado');

-- ── O que a isenção não cobre: registro no futuro ─────────────────────────────
--
-- Vai pelo check-out, que é o próximo registro que a janela guarda. Tem de vir antes do
-- check-out válido: `fazer_checkout` devolve o registro já gravado antes de chegar à
-- janela, e depois disso esta asserção mediria a idempotência, não a recusa.
select throws_ok(
  format($$ select pg_temp.como('f8000000-0000-4000-8000-0000000000e2',
       $x$ select public.fazer_checkout(%L, null, %L) $x$) $$,
         (select turno_demo from t), privado.agora() + interval '1 day'),
  'PGRST',
  '{"code" : "registro_no_futuro", "message" : "registro_no_futuro", "details" : null, "hint" : null}',
  'registro no futuro continua recusado para a conta de revisão: a isenção é só da janela');

-- ── O check-out também está fora da janela, e também passa ────────────────────
select isnt(
  (pg_temp.como('f8000000-0000-4000-8000-0000000000e2',
    format($$ select public.fazer_checkout(%L, null, %L) $$,
           (select turno_demo from t), privado.agora())))->>'registrado_em',
  null,
  'o check-out da revisão também atravessa a janela — meio ciclo não serve para a revisão');

select * from finish();
rollback;
