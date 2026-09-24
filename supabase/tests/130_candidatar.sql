-- `candidatar`: onde o produto quebra se errar.
--
-- No modo urgência o primeiro elegível que aceita é confirmado, e quem chega depois
-- recebe `409 posicao_ja_preenchida` — que é **funcionamento normal**, e não erro. Este
-- arquivo cobre o que uma sessão só consegue ver; a corrida de verdade, com vinte
-- conexões simultâneas, está em `scripts/corrida-candidatar.sh`, porque o pgTAP roda
-- numa sessão só e nunca enxergaria RN19 falhar.
--
--   RN19  uma posição nunca é confirmada para dois profissionais
--   RN21  ninguém fica com dois turnos sobrepostos
--   RN10  o contato só existe depois da confirmação, e com prazo
--   RN11  o valor é copiado para o turno, não lido por junção
--
-- Ids próprios, começando em `ac000000`: o banco não nasce vazio.

begin;
select plan(29);

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

-- d1 é a dona · e1 e e2 são garçons · e3 é bartender · e4 bloqueou a dona
-- e5 está suspenso
select pg_temp.autenticar('ac000000-0000-4000-8000-0000000000d1','dona@cand.test');
select pg_temp.autenticar('ac000000-0000-4000-8000-0000000000e1','e1@cand.test');
select pg_temp.autenticar('ac000000-0000-4000-8000-0000000000e2','e2@cand.test');
select pg_temp.autenticar('ac000000-0000-4000-8000-0000000000e3','e3@cand.test');
select pg_temp.autenticar('ac000000-0000-4000-8000-0000000000e4','e4@cand.test');
select pg_temp.autenticar('ac000000-0000-4000-8000-0000000000e5','e5@cand.test');
select pg_temp.autenticar('ac000000-0000-4000-8000-0000000000e6','e6@cand.test');

select pg_temp.como('ac000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona da Corrida','+5561988880001','1980-01-01','2026-09-22') $$);
select pg_temp.como('ac000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Garçom Um','+5561988880011','1995-01-01','2026-09-22') $$);
select pg_temp.como('ac000000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Garçom Dois','+5561988880012','1995-01-01','2026-09-22') $$);
select pg_temp.como('ac000000-0000-4000-8000-0000000000e3',
  $$ select public.criar_conta('profissional','Só Bartender','+5561988880013','1995-01-01','2026-09-22') $$);
select pg_temp.como('ac000000-0000-4000-8000-0000000000e4',
  $$ select public.criar_conta('profissional','Quem Bloqueou','+5561988880014','1995-01-01','2026-09-22') $$);
select pg_temp.como('ac000000-0000-4000-8000-0000000000e5',
  $$ select public.criar_conta('profissional','Suspenso','+5561988880015','1995-01-01','2026-09-22') $$);
-- e6 não se candidata a nada até o fim: é ele que exercita a vaga que já começou, sem
-- esbarrar na idempotência de quem já tem posição.
select pg_temp.como('ac000000-0000-4000-8000-0000000000e6',
  $$ select public.criar_conta('profissional','Atrasado','+5561988880016','1995-01-01','2026-09-22') $$);

create temp table fn as
  select (select id from public.funcao where nome = 'garçom')    as garcom,
         (select id from public.funcao where nome = 'bartender') as bartender;

create function pg_temp.perfil(conta uuid, funcao uuid) returns void
language plpgsql as $corpo$
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, funcao));
end $corpo$;

select pg_temp.perfil('ac000000-0000-4000-8000-0000000000e1', (select garcom from fn));
select pg_temp.perfil('ac000000-0000-4000-8000-0000000000e2', (select garcom from fn));
select pg_temp.perfil('ac000000-0000-4000-8000-0000000000e3', (select bartender from fn));
select pg_temp.perfil('ac000000-0000-4000-8000-0000000000e4', (select garcom from fn));
select pg_temp.perfil('ac000000-0000-4000-8000-0000000000e5', (select garcom from fn));
select pg_temp.perfil('ac000000-0000-4000-8000-0000000000e6', (select garcom from fn));

update public.usuario set estado = 'suspensa'
 where id = 'ac000000-0000-4000-8000-0000000000e5';

create temp table casa as
  select (pg_temp.como('ac000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa da Corrida','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create temp table quando as
  select (privado.agora() + interval '3 days')            as ini,
         (privado.agora() + interval '3 days 6 hours')    as fim,
         (privado.agora() + interval '3 days 2 hours')    as ini_cruza,
         (privado.agora() + interval '3 days 8 hours')    as fim_cruza;

create function pg_temp.publicar(funcao uuid, ini timestamptz, fim timestamptz,
                                 posicoes int, chave uuid) returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como('ac000000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 406',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, %s, true, true, false, 'Seu Zé', 'urgencia', %L) $sql$,
    (select id from casa), funcao, ini, fim, posicoes, chave))->>'vaga_id')::uuid;
end $corpo$;

create temp table vagas as
  select pg_temp.publicar((select garcom from fn), (select ini from quando),
           (select fim from quando), 1, 'ac000000-0000-4000-8000-000000000001') as uma,
         pg_temp.publicar((select garcom from fn), (select ini_cruza from quando),
           (select fim_cruza from quando), 2, 'ac000000-0000-4000-8000-000000000002') as cruza,
         pg_temp.publicar((select garcom from fn), (select ini from quando),
           (select fim from quando), 1, 'ac000000-0000-4000-8000-000000000003') as cancelada;

update public.vaga set estado = 'cancelada' where id = (select cancelada from vagas);

insert into public.bloqueio (autor_id, bloqueado_id)
values ('ac000000-0000-4000-8000-0000000000e4','ac000000-0000-4000-8000-0000000000d1');

-- ── Sem sessão, e do lado errado ──────────────────────────────────────────────
select throws_ok(
  format($$ select public.candidatar(%L) $$, (select uma from vagas)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não se candidata');

select throws_ok(
  format($$ select pg_temp.como('ac000000-0000-4000-8000-0000000000d1',
       $x$ select public.candidatar(%L) $x$) $$, (select uma from vagas)),
  'PGRST',
  '{"code" : "perfil_incompativel", "message" : "perfil_incompativel", "details" : null, "hint" : null}',
  'RN25: conta de contratante não se candidata');

-- ── O que não existe, e o que não deveria ser alcançado ───────────────────────
select throws_ok(
  $$ select pg_temp.como('ac000000-0000-4000-8000-0000000000e1',
       $x$ select public.candidatar('00000000-0000-4000-8000-000000000000') $x$) $$,
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'vaga que não existe é 404');

select throws_ok(
  format($$ select pg_temp.como('ac000000-0000-4000-8000-0000000000e4',
       $x$ select public.candidatar(%L) $x$) $$, (select uma from vagas)),
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'RF26: para quem bloqueou a casa, a vaga é 404 — o mesmo que o detalhe responde');

select throws_ok(
  format($$ select pg_temp.como('ac000000-0000-4000-8000-0000000000e1',
       $x$ select public.candidatar(%L) $x$) $$, (select cancelada from vagas)),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : null, "hint" : null}',
  'vaga cancelada é 409 vaga_encerrada, e não 404: ela existe e o profissional a viu');

-- ── Elegibilidade ─────────────────────────────────────────────────────────────
select throws_ok(
  format($$ select pg_temp.como('ac000000-0000-4000-8000-0000000000e5',
       $x$ select public.candidatar(%L) $x$) $$, (select uma from vagas)),
  'PGRST',
  '{"code" : "inelegivel", "message" : "inelegivel", "details" : "perfil_suspenso", "hint" : null}',
  'RN13: conta suspensa é inelegivel com details perfil_suspenso');

select throws_ok(
  format($$ select pg_temp.como('ac000000-0000-4000-8000-0000000000e3',
       $x$ select public.candidatar(%L) $x$) $$, (select uma from vagas)),
  'PGRST',
  '{"code" : "inelegivel", "message" : "inelegivel", "details" : "funcao_incompativel", "hint" : null}',
  'RN05: quem não tem a função da vaga é inelegivel com details funcao_incompativel');

-- ── O caminho feliz ───────────────────────────────────────────────────────────
create temp table r as
  select pg_temp.como('ac000000-0000-4000-8000-0000000000e1',
    format($$ select public.candidatar(%L) $$, (select uma from vagas))) as j;

select is(
  (select array_agg(k order by k) from r, jsonb_object_keys((select j from r)) k),
  array['candidatura_id','contato','estado','posicao_id','turno_id'],
  'a resposta traz exatamente os campos do schema ResultadoCandidatura');

select is((select j->>'estado' from r), 'confirmada',
  'RN19: no modo urgência o primeiro elegível já sai confirmado');

select isnt((select j->>'turno_id' from r), null,
  'e o turno nasce junto com a confirmação');

select is(
  (select estado::text from public.posicao where id = (select (j->>'posicao_id')::uuid from r)),
  'confirmada',
  'a posição fica confirmada');

select is(
  (select profissional_id from public.posicao where id = (select (j->>'posicao_id')::uuid from r)),
  (select p.id from public.profissional p where p.usuario_id = 'ac000000-0000-4000-8000-0000000000e1'),
  'e com o profissional que se candidatou');

select is(
  (select estado::text from public.candidatura where id = (select (j->>'candidatura_id')::uuid from r)),
  'aceita',
  'a candidatura fica aceita');

-- RN11: o valor viaja para o turno em vez de ser lido por junção. Se a casa republicar
-- com outro valor, o turno executado continua dizendo quanto foi combinado.
select is(
  (select t.valor_acordado_centavos from public.turno t
    where t.id = (select (j->>'turno_id')::uuid from r)),
  18000::bigint,
  'RN11: o valor é copiado para o turno, e não lido da vaga');

select is(
  (select estado::text from public.vaga where id = (select uma from vagas)),
  'preenchida',
  'a vaga passa a preenchida quando não sobra posição aberta');

-- ── O contato, que é o que o profissional espera ──────────────────────────────
select is(
  (select array_agg(k order by k) from r, jsonb_object_keys((select j->'contato' from r)) k),
  array['nome','telefone','visivel_ate','whatsapp_url'],
  'o contato vem com os quatro campos do schema Contato');

select is((select j->'contato'->>'nome' from r), 'Casa da Corrida',
  'o nome do contato é o do estabelecimento, não o da pessoa física');

select is((select j->'contato'->>'telefone' from r), '+5561988880001',
  'o telefone é o de quem publicou');

select is((select j->'contato'->>'whatsapp_url' from r), 'https://wa.me/5561988880001',
  'e o link do WhatsApp sai pronto, sem o + que o wa.me não aceita');

-- RN10: o contato tem prazo, e ele é o fim previsto mais 7 dias.
select is(
  (select (j->'contato'->>'visivel_ate')::timestamptz from r),
  (select fim + interval '7 days' from quando),
  'RN10: o contato vale até 7 dias depois do fim previsto do turno');

-- ── Reenviar é seguro ─────────────────────────────────────────────────────────
--
-- A rede cai depois do commit e o app reenvia. A chave natural é (vaga, profissional):
-- a segunda chamada devolve o mesmo turno, e não toma uma segunda posição.
select is(
  pg_temp.como('ac000000-0000-4000-8000-0000000000e1',
    format($$ select public.candidatar(%L) $$, (select uma from vagas)))->>'turno_id',
  (select j->>'turno_id' from r),
  'reenviar devolve o mesmo turno');

select is(
  (select count(*)::int from public.candidatura c
    join public.posicao p on p.id = c.posicao_id
   where p.vaga_id = (select uma from vagas)),
  1,
  'e não cria uma segunda candidatura');

-- ── Quem chega depois ─────────────────────────────────────────────────────────
select throws_ok(
  format($$ select pg_temp.como('ac000000-0000-4000-8000-0000000000e2',
       $x$ select public.candidatar(%L) $x$) $$, (select uma from vagas)),
  'PGRST',
  '{"code" : "posicao_ja_preenchida", "message" : "posicao_ja_preenchida", "details" : null, "hint" : null}',
  'RN19: a única posição já foi, e quem chega depois recebe 409 posicao_ja_preenchida');

select is(
  (select count(*)::int from public.posicao
    where vaga_id = (select uma from vagas) and estado = 'confirmada'),
  1,
  'e continua havendo uma confirmação só');

-- ── RN21: dois turnos que se cruzam ───────────────────────────────────────────
--
-- A segunda vaga começa duas horas depois da primeira e termina depois dela. Sem o
-- `EXCLUDE`, a pessoa aceitaria as duas de boa-fé e faltaria a uma, desabando a própria
-- taxa de comparecimento por um buraco do sistema.
select throws_ok(
  format($$ select pg_temp.como('ac000000-0000-4000-8000-0000000000e1',
       $x$ select public.candidatar(%L) $x$) $$, (select cruza from vagas)),
  'PGRST',
  '{"code" : "inelegivel", "message" : "inelegivel", "details" : "turno_sobreposto", "hint" : null}',
  'RN21: turno sobreposto é inelegivel com details turno_sobreposto, e não erro de constraint');

select is(
  (select count(*)::int from public.posicao
    where vaga_id = (select cruza from vagas) and estado <> 'aberta'),
  0,
  'e nenhuma posição da segunda vaga foi tocada');

-- Outro profissional, sem turno naquele horário, entra sem problema.
select is(
  pg_temp.como('ac000000-0000-4000-8000-0000000000e2',
    format($$ select public.candidatar(%L) $$, (select cruza from vagas)))->>'estado',
  'confirmada',
  'quem não tem turno no horário entra na vaga que cruza');

select is(
  (select estado::text from public.vaga where id = (select cruza from vagas)),
  'publicada',
  'e a vaga de duas posições continua publicada, porque ainda sobra uma');

-- ── A vaga que já começou ─────────────────────────────────────────────────────
--
-- Sobrepor o relógio do produto em vez de esperar três dias: é para isso que
-- `privado.ambiente` existe, e a linha é escrita aqui dentro da transação, nunca por
-- arquivo do repositório.
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
-- Uma hora depois do início da vaga que cruza, que é a que este caso usa.
select set_config('frila.agora',
  (select (ini_cruza + interval '1 hour')::text from quando), true);

select throws_ok(
  format($$ select pg_temp.como('ac000000-0000-4000-8000-0000000000e6',
       $x$ select public.candidatar(%L) $x$) $$, (select cruza from vagas)),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : null, "hint" : null}',
  'vaga cujo início já passou é 409 vaga_encerrada');

select set_config('frila.agora', '', true);

select * from finish();
rollback;
