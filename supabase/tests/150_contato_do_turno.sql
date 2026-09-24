-- `contato_do_turno`: o telefone, com prazo.
--
-- RN10 é uma regra de tempo, e regra de tempo só é testável com o relógio na mão. O
-- arquivo inteiro gira em torno de três instantes: antes da confirmação, dentro do
-- prazo, e um dia depois dele.
--
--   antes da confirmação   404 — ainda não há contrato a executar
--   dentro do prazo        o contato dos dois lados
--   8 dias depois do fim   403 contato_expirado
--   com bloqueio           404, e não 403: o 403 confirmaria que o turno existe
--
-- Ids próprios, começando em `ae000000`.

begin;
select plan(16);

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

select pg_temp.autenticar('ae000000-0000-4000-8000-0000000000d1','dona@contato.test');
select pg_temp.autenticar('ae000000-0000-4000-8000-0000000000e1','e1@contato.test');
select pg_temp.autenticar('ae000000-0000-4000-8000-0000000000e2','e2@contato.test');

select pg_temp.como('ae000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona do Contato','+5561955550001','1980-01-01','2026-09-22') $$);
select pg_temp.como('ae000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Contato Um','+5561955550011','1995-01-01','2026-09-22') $$);
select pg_temp.como('ae000000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Contato Dois','+5561955550012','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create function pg_temp.perfil(conta uuid) returns void
language plpgsql as $corpo$
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, (select garcom from fn)));
end $corpo$;

select pg_temp.perfil('ae000000-0000-4000-8000-0000000000e1');
select pg_temp.perfil('ae000000-0000-4000-8000-0000000000e2');

create temp table casa as
  select (pg_temp.como('ae000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa do Contato','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create temp table quando as
  select (privado.agora() + interval '2 days')         as ini,
         (privado.agora() + interval '2 days 6 hours') as fim;

create temp table vaga as
  select (pg_temp.como('ae000000-0000-4000-8000-0000000000d1', format(
    $$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 406',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 2, true, true, false, 'Seu Zé', 'urgencia',
         'ae000000-0000-4000-8000-000000000001') $$,
    (select id from casa), (select garcom from fn),
    (select ini from quando), (select fim from quando)))->>'vaga_id')::uuid as id;

-- ── Antes da confirmação ──────────────────────────────────────────────────────
--
-- A posição existe e está aberta; o turno ainda não nasceu. Pedir o contato de um
-- turno que não existe é 404, e é assim que o app sabe que ainda não pode ligar.
select throws_ok(
  $$ select pg_temp.como('ae000000-0000-4000-8000-0000000000e1',
       $x$ select public.contato_do_turno('00000000-0000-4000-8000-000000000000') $x$) $$,
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'turno que não existe é 404 — antes da confirmação não há contato');

create temp table t as
  select (pg_temp.como('ae000000-0000-4000-8000-0000000000e1',
    format($$ select public.candidatar(%L) $$, (select id from vaga)))->>'turno_id')::uuid as id;

-- ── Sem sessão ────────────────────────────────────────────────────────────────
select throws_ok(
  format($$ select public.contato_do_turno(%L) $$, (select id from t)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não há contato');

-- ── O profissional pede, e recebe a casa ──────────────────────────────────────
create temp table c as
  select pg_temp.como('ae000000-0000-4000-8000-0000000000e1',
    format($$ select public.contato_do_turno(%L) $$, (select id from t))) as j;

select is(
  (select array_agg(k order by k) from c, jsonb_object_keys((select j from c)) k),
  array['nome','telefone','visivel_ate','whatsapp_url'],
  'o contato traz exatamente os campos do schema Contato');

select is((select j->>'nome' from c), 'Casa do Contato',
  'para o profissional, o nome é o do estabelecimento');

select is((select j->>'telefone' from c), '+5561955550001',
  'e o telefone é o de quem publicou');

select is((select j->>'whatsapp_url' from c), 'https://wa.me/5561955550001',
  'o link do WhatsApp sai sem o + do E.164, que o wa.me não aceita');

select is(
  (select (j->>'visivel_ate')::timestamptz from c),
  (select fim + interval '7 days' from quando),
  'RN10: o prazo é o fim previsto mais 7 dias');

-- ── A casa pede, e recebe a pessoa ────────────────────────────────────────────
create temp table cd as
  select pg_temp.como('ae000000-0000-4000-8000-0000000000d1',
    format($$ select public.contato_do_turno(%L) $$, (select id from t))) as j;

select is((select j->>'nome' from cd), 'Contato Um',
  'para a casa, o nome é o da pessoa — deste lado há gente, não marca');

select is((select j->>'telefone' from cd), '+5561955550011',
  'e o telefone é o do profissional confirmado');

-- ── Quem não é de nenhum dos lados ────────────────────────────────────────────
select throws_ok(
  format($$ select pg_temp.como('ae000000-0000-4000-8000-0000000000e2',
       $x$ select public.contato_do_turno(%L) $x$) $$, (select id from t)),
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'quem não é nenhum dos dois lados recebe 404, e não 403');

-- ── O bloqueio ────────────────────────────────────────────────────────────────
--
-- Feito depois da confirmação, que é o caso real: as pessoas se desentendem durante o
-- turno. O contato fecha nos dois sentidos.
insert into public.bloqueio (autor_id, bloqueado_id)
values ('ae000000-0000-4000-8000-0000000000e1','ae000000-0000-4000-8000-0000000000d1');

select throws_ok(
  format($$ select pg_temp.como('ae000000-0000-4000-8000-0000000000e1',
       $x$ select public.contato_do_turno(%L) $x$) $$, (select id from t)),
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'RF26: com bloqueio, o contato fecha para quem bloqueou');

select throws_ok(
  format($$ select pg_temp.como('ae000000-0000-4000-8000-0000000000d1',
       $x$ select public.contato_do_turno(%L) $x$) $$, (select id from t)),
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'e fecha também para o outro lado: o bloqueio vale nos dois sentidos');

delete from public.bloqueio
 where autor_id = 'ae000000-0000-4000-8000-0000000000e1';

-- ── O prazo ───────────────────────────────────────────────────────────────────
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- Sete dias depois do fim, no último instante: ainda vale.
select set_config('frila.agora',
  (select (fim + interval '7 days')::text from quando), true);

select is(
  pg_temp.como('ae000000-0000-4000-8000-0000000000e1',
    format($$ select public.contato_do_turno(%L) $$, (select id from t)))->>'telefone',
  '+5561955550001',
  'RN10: no último instante do sétimo dia o contato ainda sai');

-- Oito dias: acabou.
select set_config('frila.agora',
  (select (fim + interval '8 days')::text from quando), true);

select throws_ok(
  format($$ select pg_temp.como('ae000000-0000-4000-8000-0000000000e1',
       $x$ select public.contato_do_turno(%L) $x$) $$, (select id from t)),
  'PGRST',
  '{"code" : "contato_expirado", "message" : "contato_expirado", "details" : null, "hint" : null}',
  'RN10: oito dias depois do fim, 403 contato_expirado');

select throws_ok(
  format($$ select pg_temp.como('ae000000-0000-4000-8000-0000000000d1',
       $x$ select public.contato_do_turno(%L) $x$) $$, (select id from t)),
  'PGRST',
  '{"code" : "contato_expirado", "message" : "contato_expirado", "details" : null, "hint" : null}',
  'e o prazo vale para os dois lados, não só para o profissional');

select set_config('frila.agora', '', true);

-- Com o relógio de volta ao normal, o contato volta: a recusa era do prazo, e não um
-- efeito colateral que ficou gravado em algum lugar.
select is(
  pg_temp.como('ae000000-0000-4000-8000-0000000000e1',
    format($$ select public.contato_do_turno(%L) $$, (select id from t)))->>'telefone',
  '+5561955550001',
  'e nada foi gravado: com o relógio de volta, o contato volta');

select * from finish();
rollback;
