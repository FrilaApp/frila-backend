-- Os códigos de erro que o contrato promete e que nenhum teste provava.
--
-- Auditoria contrato × implementação (29/09). Cada recusa abaixo é prometida pelo
-- `contrato/openapi.yaml` — no catálogo de erros da descrição da API ou na descrição da
-- própria operação — e o código já a levantava, mas nenhum pgTAP, nenhum passo HTTP do
-- `ciclo-completo.sh` e nenhuma colheita do `contrato-responde.sh` chegava até ela. Uma
-- recusa sem teste é a que muda de `code` numa refatoração sem ninguém ver, e o app
-- compara o `code` sem traduzir.
--
-- Só entra aqui o que o contrato **declara** para a operação. Recusa que o código
-- levanta com status que a operação não declara (por exemplo, `404` em
-- `confirmar_checkin_manual`) é divergência, e está listada no relatório da auditoria
-- para o contrato decidir; prová-la aqui cristalizaria o que ainda não foi decidido.
--
-- Ids próprios, começando em `c4800000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(38);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2027-03-01 12:00:00+00', true);

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

-- A chamada `sql` feita por `conta`, pronta para o `throws_ok`.
create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

create temp table ids as select
  'c4800000-0000-4000-8000-0000000000d1'::uuid as dona,
  'c4800000-0000-4000-8000-0000000000d2'::uuid as suspenso,
  'c4800000-0000-4000-8000-0000000000e1'::uuid as ana,
  'c4800000-0000-4000-8000-0000000000e2'::uuid as sem_perfil,
  'c4800000-0000-4000-8000-0000000000f1'::uuid as sem_conta;

select pg_temp.autenticar((select dona from ids),       'dona@c48.test');
select pg_temp.autenticar((select suspenso from ids),   'suspenso@c48.test');
select pg_temp.autenticar((select ana from ids),        'ana@c48.test');
select pg_temp.autenticar((select sem_perfil from ids), 'sem-perfil@c48.test');
select pg_temp.autenticar((select sem_conta from ids),  'sem-conta@c48.test');

select pg_temp.como((select dona from ids),
  $$ select public.criar_conta('contratante','Dona da Auditoria','+5561948000001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select suspenso from ids),
  $$ select public.criar_conta('contratante','Conta Suspensa','+5561948000002','1980-01-01','2026-09-22') $$);
select pg_temp.como((select ana from ids),
  $$ select public.criar_conta('profissional','Ana da Auditoria','+5561948000011','1995-01-01','2026-09-22') $$);
select pg_temp.como((select sem_perfil from ids),
  $$ select public.criar_conta('profissional','Sem Perfil','+5561948000012','1995-01-01','2026-09-22') $$);
update public.usuario set estado = 'suspensa' where id = (select suspenso from ids);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select ana from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));

create temp table casa as
  select (pg_temp.como((select dona from ids),
    $$ select public.cadastrar_estabelecimento('Casa da Auditoria','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

-- A chamada de `publicar_vaga` com todos os campos, por nome. `sem` troca um deles por
-- nulo, e `extra` acrescenta argumentos — é assim que cada recusa abaixo muda uma coisa
-- só.
create function pg_temp.sql_publicar(chave uuid, inicio text, fim text,
                                     sem text default null, extra text default '')
returns text language plpgsql as $corpo$
declare
  v_args text[][] := array[
    array['estabelecimento_id',     quote_literal((select id from casa)) || '::uuid'],
    array['funcao_id',              quote_literal((select garcom from fn)) || '::uuid'],
    array['inicio_em',              quote_literal(inicio) || '::timestamptz'],
    array['fim_em',                 quote_literal(fim) || '::timestamptz'],
    array['local',                  quote_literal('CLN 406')],
    array['ponto',                  quote_literal('{"latitude":-15.7910,"longitude":-47.8860}') || '::jsonb'],
    array['valor_centavos',         '18000'],
    array['posicoes',               '1'],
    array['inclui_refeicao',        'true'],
    array['inclui_transporte',      'true'],
    array['exige_material_proprio', 'false'],
    array['responsavel_local',      quote_literal('Seu Zé')],
    array['modo',                   quote_literal('urgencia') || '::public.modo_preenchimento'],
    array['chave',                  quote_literal(chave) || '::uuid']];
  v_partes text[] := '{}';
  i int;
begin
  for i in 1 .. array_length(v_args, 1) loop
    v_partes := v_partes || format('%s => %s', v_args[i][1],
      case when v_args[i][1] = sem then 'null' else v_args[i][2] end);
  end loop;
  return format('select public.publicar_vaga(%s%s)', array_to_string(v_partes, ', '), extra);
end $corpo$;

create function pg_temp.publicar(chave uuid, inicio text, fim text) returns uuid
language sql as $$
  select (pg_temp.como((select dona from ids),
            pg_temp.sql_publicar(chave, inicio, fim))->>'vaga_id')::uuid
$$;

-- Três vagas em dias diferentes, para a Ana não cruzar turnos (RN21).
create temp table v as select
  pg_temp.publicar('c4800000-0000-4000-8000-000000000001',
                   '2027-03-03 21:00:00+00', '2027-03-04 03:00:00+00') as da_ana,
  pg_temp.publicar('c4800000-0000-4000-8000-000000000002',
                   '2027-03-05 21:00:00+00', '2027-03-06 03:00:00+00') as vazia,
  pg_temp.publicar('c4800000-0000-4000-8000-000000000003',
                   '2027-03-07 21:00:00+00', '2027-03-08 03:00:00+00') as desistida;

create temp table t as select
  (pg_temp.como((select ana from ids),
     format($$ select public.candidatar(%L) $$, (select da_ana from v)))->>'turno_id')::uuid as turno,
  (pg_temp.como((select ana from ids),
     format($$ select public.candidatar(%L) $$, (select desistida from v)))->>'posicao_id')::uuid as desistida,
  (select p.id from public.posicao p where p.vaga_id = (select vazia from v)) as aberta;

-- ── Sem sessão ────────────────────────────────────────────────────────────────
select throws_ok(
  $$ select public.minha_conta() $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'minha_conta sem token é 401 nao_autenticado');

select throws_ok(
  format($$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.79,"longitude":-47.88}'::jsonb) $$, (select garcom from fn)),
  'PGRST', pg_temp.erro('nao_autenticado'),
  'criar_perfil_profissional sem token é 401 nao_autenticado');

select throws_ok(
  format($$ select public.fazer_checkout(%L, 50, now()) $$, (select turno from t)),
  'PGRST', pg_temp.erro('nao_autenticado'),
  'fazer_checkout sem token é 401 nao_autenticado');

-- ── Cadastro e perfil ─────────────────────────────────────────────────────────
select throws_ok(
  pg_temp.por((select sem_conta from ids),
    $$ select public.criar_conta('profissional','Nome Bom','+5561948000099',null,'2026-09-22') $$),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'nascimento'),
  'criar_conta sem nascimento é 422 campo_obrigatorio, details nascimento (RN02, RN20)');

select throws_ok(
  pg_temp.por((select sem_perfil from ids),
    $$ select public.atualizar_perfil_profissional(ponto_base => '{"latitude":-15.79,"longitude":-47.88}'::jsonb) $$),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'atualizar_perfil_profissional antes de criar o perfil é 404 nao_encontrado');

select throws_ok(
  pg_temp.por((select ana from ids),
    $$ select public.atualizar_perfil_profissional(funcoes => array['c4800000-0000-4000-8000-00000000ffff']::uuid[]) $$),
  'PGRST', pg_temp.erro('campo_invalido', 'funcoes'),
  'atualizar_perfil_profissional com função fora do catálogo é 422 campo_invalido, details funcoes');

select throws_ok(
  pg_temp.por((select ana from ids),
    $$ select public.atualizar_perfil_profissional(ponto_base => '{"latitude":120,"longitude":-47.88}'::jsonb) $$),
  'PGRST', pg_temp.erro('campo_invalido', 'ponto_base'),
  'atualizar_perfil_profissional com latitude fora da faixa é 422 campo_invalido, details ponto_base');

select throws_ok(
  pg_temp.por((select ana from ids),
    $$ select public.atualizar_perfil_profissional(disponibilidades =>
         '[{"dia_semana":7,"hora_inicio":"18:00","hora_fim":"23:00"}]'::jsonb) $$),
  'PGRST', pg_temp.erro('campo_invalido', 'disponibilidades'),
  'atualizar_perfil_profissional com dia_semana fora de 0..6 é 422 campo_invalido, details disponibilidades');

select throws_ok(
  pg_temp.por((select dona from ids),
    $$ select public.cadastrar_estabelecimento('Outra Casa','11222333000181',null,
         'CLN 201','{"latitude":-15.79,"longitude":-47.88}') $$),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'tipo'),
  'cadastrar_estabelecimento sem tipo é 422 campo_obrigatorio, details tipo (RN02)');

-- ── publicar_vaga: "campo obrigatório ausente, com o nome do campo em details" ──
--
-- O contrato promete o nome do campo em `details` para cada um. O teste confere todos:
-- a tela destaca o campo pelo `details`, e trocar um nome aqui deixa o app sem saber
-- qual campo destacar.
select throws_ok(
  pg_temp.por((select dona from ids),
    pg_temp.sql_publicar(gen_random_uuid(), '2027-03-10 21:00:00+00', '2027-03-11 03:00:00+00', campo)),
  'PGRST', pg_temp.erro('campo_obrigatorio', campo),
  format('publicar_vaga sem %s é 422 campo_obrigatorio, details %s (RN02)', campo, campo))
from unnest(array['funcao_id', 'inicio_em', 'fim_em', 'local', 'valor_centavos', 'posicoes',
                  'inclui_refeicao', 'inclui_transporte', 'exige_material_proprio', 'modo',
                  'chave']) as campo;

select throws_ok(
  pg_temp.por((select dona from ids),
    pg_temp.sql_publicar(gen_random_uuid(), '2027-03-10 21:00:00+00', '2027-03-11 03:00:00+00',
                         extra => ', alerta_antecedencia_min => 0')),
  'PGRST', pg_temp.erro('campo_invalido', 'alerta_antecedencia_min'),
  'publicar_vaga com alerta_antecedencia_min zero é 422 campo_invalido, details alerta_antecedencia_min');

-- ── Vagas e candidatura ───────────────────────────────────────────────────────
select throws_ok(
  pg_temp.por((select ana from ids), $$ select public.candidatar(null) $$),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'vaga_id'),
  'candidatar sem vaga_id é 422 campo_obrigatorio, details vaga_id');

select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.detalhe_vaga(%L) $$, (select vazia from v))),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'detalhe_vaga pedido por conta de contratante é 422 perfil_incompativel');

select throws_ok(
  pg_temp.por((select ana from ids), $$ select public.vagas_abertas(deslocamento => -1) $$),
  'PGRST', pg_temp.erro('campo_invalido', 'deslocamento'),
  'vagas_abertas com deslocamento negativo é 422 campo_invalido, details deslocamento');

select throws_ok(
  pg_temp.por((select sem_perfil from ids), $$ select public.vagas_abertas() $$),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'latitude'),
  'vagas_abertas sem coordenada e sem ponto base é 422 campo_obrigatorio, details latitude');

-- ── Posição que não está confirmada ───────────────────────────────────────────
select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.cancelar_posicao(%L, 'mudou o evento') $$, (select aberta from t))),
  'PGRST', pg_temp.erro('posicao_nao_cancelavel'),
  'cancelar_posicao de posição aberta é 409 posicao_nao_cancelavel — aberta não tem o que cancelar');

select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.reabrir_por_atraso(%L) $$, (select aberta from t))),
  'PGRST', pg_temp.erro('posicao_nao_cancelavel'),
  'reabrir_por_atraso de posição aberta é 409 posicao_nao_cancelavel');

select lives_ok(
  pg_temp.por((select ana from ids),
    format($$ select public.cancelar_posicao(%L, 'não vou poder') $$, (select desistida from t))),
  'a Ana cancela a posição da terceira vaga, com mais de 24 h');

select throws_ok(
  pg_temp.por((select ana from ids),
    format($$ select public.cancelar_posicao(%L, 'não vou poder') $$, (select desistida from t))),
  'PGRST', pg_temp.erro('posicao_nao_cancelavel'),
  'cancelar_posicao de posição já cancelada é 409 posicao_nao_cancelavel — não volta atrás');

-- ── Presença ──────────────────────────────────────────────────────────────────
select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.confirmar_checkin_manual(%L) $$, (select turno from t))),
  'PGRST', pg_temp.erro('checkin_pendente'),
  'confirmar_checkin_manual de turno sem check-in é 409 checkin_pendente');

select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.fazer_checkin(%L, 50, now()) $$, (select turno from t))),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'fazer_checkin por conta de contratante é 422 perfil_incompativel');

select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.fazer_checkout(%L, 50, now()) $$, (select turno from t))),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'fazer_checkout por conta de contratante é 422 perfil_incompativel');

select throws_ok(
  pg_temp.por((select ana from ids),
    format($$ select public.fazer_checkin(%L, 50, null) $$, (select turno from t))),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'registrado_em'),
  'fazer_checkin sem registrado_em é 422 campo_obrigatorio, details registrado_em');

-- O relógio do produto vai para 30 minutos antes do início: dentro da janela.
select set_config('frila.agora', '2027-03-03 20:30:00+00', true);

select throws_ok(
  pg_temp.por((select ana from ids),
    format($$ select public.fazer_checkin(%L, -1, '2027-03-03 20:30:00+00') $$, (select turno from t))),
  'PGRST', pg_temp.erro('campo_invalido', 'distancia_m'),
  'fazer_checkin com distância negativa é 422 campo_invalido, details distancia_m');

select lives_ok(
  pg_temp.por((select ana from ids),
    format($$ select public.fazer_checkin(%L, 50, '2027-03-03 20:30:00+00') $$, (select turno from t))),
  'a Ana faz o check-in a 50 m, dentro da janela');

-- Uma hora depois do fim previsto: o check-out já não cabe na janela (RN22).
select set_config('frila.agora', '2027-03-04 04:00:00+00', true);

select throws_ok(
  pg_temp.por((select ana from ids),
    format($$ select public.fazer_checkout(%L, 50, '2027-03-04 04:00:00+00') $$, (select turno from t))),
  'PGRST', pg_temp.erro('fora_da_janela'),
  'fazer_checkout depois do fim previsto é 422 fora_da_janela');

-- ── Avaliação e equipe ────────────────────────────────────────────────────────
select throws_ok(
  pg_temp.por((select ana from ids),
    format($$ select public.avaliar(%L, null) $$, (select turno from t))),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'resposta'),
  'avaliar sem resposta é 422 campo_obrigatorio, details resposta');

select throws_ok(
  pg_temp.por((select suspenso from ids),
    format($$ select public.remover_da_equipe(%L, 'c4800000-0000-4000-8000-00000000eeee') $$,
           (select id from casa))),
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'remover_da_equipe por conta suspensa é 403 sem_permissao, details conta_suspensa (RN13)');

select * from finish();
rollback;
