-- 827_rn22_caminho_do_codigo.sql
--
-- RN22 com o terceiro caminho, o código da casa validado (contrato 0.2.68; migrações
-- 20261109100000 e 20261109100100). Um teste por CHECK, com o nome da regra, e a regressão dos
-- dois caminhos de antes: o geolocalizado a até 200 m e o manual só confirmado.
--
-- Cada `update` grava as quatro colunas que as regras leem, para o estado de um teste não
-- vazar no outro. Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-01-11 21:30:00+00', true);
select plan(13);

create temp table ids as
select
  'c8270000-0000-4000-8000-000000000001'::uuid as prof_user,
  'c8270000-0000-4000-8000-000000000002'::uuid as casa_user,
  'c8270000-0000-4000-8000-000000000011'::uuid as profissional,
  'c8270000-0000-4000-8000-000000000021'::uuid as estabelecimento,
  'c8270000-0000-4000-8000-000000000031'::uuid as vaga,
  'c8270000-0000-4000-8000-000000000041'::uuid as posicao,
  'c8270000-0000-4000-8000-000000000051'::uuid as turno;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select prof_user, 'profissional'::public.perfil_conta, 'Prof 827', '+5561999998271',
       'prof827@test.invalid', '1992-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz from ids
union all
select casa_user, 'contratante'::public.perfil_conta, 'Casa 827', '+5561999998272',
       'casa827@test.invalid', '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz from ids;

insert into public.profissional (id, usuario_id, ponto_base)
select profissional, prof_user, 'POINT(-47.8800 -15.7700)'::extensions.geography from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select estabelecimento, 'Bar 827', '80000000000827', 'food_service', 'Endereço de teste',
       'POINT(-47.8800 -15.7700)'::extensions.geography from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select casa_user, estabelecimento, 'administrador' from ids;

insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por)
select vaga, estabelecimento, (select id from public.funcao limit 1),
       '2027-01-11 21:00:00+00', '2027-01-12 02:00:00+00', 'Local 827',
       'POINT(-47.8800 -15.7700)'::extensions.geography, 15000, 1, false, false, false,
       'Gerente', 'urgencia', 'publicada', '2027-01-10 12:00:00+00', gen_random_uuid(), casa_user
  from ids;

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select posicao, vaga, 'confirmada', profissional, '2027-01-10 13:00:00+00',
       '2027-01-11 21:00:00+00', '2027-01-12 02:00:00+00' from ids;

-- O check-in por código nasce manual e pendente, como qualquer check-in manual.
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, verificacao, valor_acordado_centavos)
select turno, posicao, '2027-01-11 21:05:00+00', 'manual'::public.tipo_registro,
       'pendente'::public.verificacao_turno, 15000 from ids;

-- Grava as quatro colunas que a RN22 lê, de uma vez.
create function pg_temp.registro(tipo text, distancia int, confirmado boolean, verificacao text)
returns text language sql as $$
  select format($q$update public.turno
       set checkin_tipo = %L::public.tipo_registro, checkin_distancia_m = %s,
           checkin_confirmado_em = %s, verificacao = %L::public.verificacao_turno
     where id = 'c8270000-0000-4000-8000-000000000051'$q$,
    tipo, coalesce(distancia::text, 'null'),
    case when confirmado then $c$'2027-01-11 21:10:00+00'::timestamptz$c$ else 'null' end,
    verificacao) $$;

create function pg_temp.violacao(restricao text) returns text language sql as $$
  select format('new row for relation "turno" violates check constraint "%s"', restricao) $$;

-- ── 1. O tipo e as restrições no catálogo ─────────────────────────────────────
select is(enum_range(null::public.tipo_registro)::text[], array['geolocalizado', 'manual', 'codigo'],
  'tipo_registro: codigo entra depois de geolocalizado e manual (0.2.68)');

select is(
  (select array_agg(conname::text order by conname) from pg_constraint
    where conrelid = 'public.turno'::regclass
      and conname in ('confirmacao_so_no_manual', 'confirmacao_no_manual_ou_codigo',
                      'codigo_sempre_confirmado', 'verificacao_coerente')),
  array['codigo_sempre_confirmado', 'confirmacao_no_manual_ou_codigo', 'verificacao_coerente'],
  'turno: confirmacao_so_no_manual sai, e as três restrições da RN22 estão no catálogo');

-- ── 2. O caminho do código ────────────────────────────────────────────────────
select lives_ok(pg_temp.registro('codigo', null, true, 'verificado'),
  'RN22 verificacao_coerente: código validado (codigo, com a hora da validação) é presença verificada');

select throws_ok(pg_temp.registro('codigo', null, false, 'pendente'),
  '23514', pg_temp.violacao('codigo_sempre_confirmado'),
  'RN22 codigo_sempre_confirmado: tipo codigo sem a hora da validação não existe');

select throws_ok(pg_temp.registro('codigo', null, true, 'pendente'),
  '23514', pg_temp.violacao('verificacao_coerente'),
  'RN22 verificacao_coerente: código validado e não marcado verificado é recusado');

select throws_ok(pg_temp.registro('codigo', null, true, 'nao_verificado'),
  '23514', pg_temp.violacao('verificacao_coerente'),
  'RN22 verificacao_coerente: código validado não fecha como nao_verificado');

-- ── 3. A hora de confirmação só no manual e no código ─────────────────────────
select throws_ok(pg_temp.registro('geolocalizado', 50, true, 'verificado'),
  '23514', pg_temp.violacao('confirmacao_no_manual_ou_codigo'),
  'RN22 confirmacao_no_manual_ou_codigo: geolocalizado não tem hora de confirmação');

-- ── 4. Regressão: os dois caminhos de antes não mudam ────────────────────────
select lives_ok(pg_temp.registro('geolocalizado', 200, false, 'verificado'),
  'RN22 regressão: geolocalizado a 200 m segue verificado na hora');

select throws_ok(pg_temp.registro('geolocalizado', 50, false, 'pendente'),
  '23514', pg_temp.violacao('verificacao_coerente'),
  'RN22 regressão verificacao_coerente: geolocalizado não fica pendente');

select lives_ok(pg_temp.registro('manual', null, true, 'verificado'),
  'RN22 regressão: manual confirmado pela casa segue verificado');

select throws_ok(pg_temp.registro('manual', null, false, 'verificado'),
  '23514', pg_temp.violacao('verificacao_coerente'),
  'RN22 regressão verificacao_coerente: manual sem confirmação não é verificado');

select lives_ok(pg_temp.registro('manual', null, false, 'nao_verificado'),
  'RN22 regressão: manual sem confirmação fecha nao_verificado, como o agendador faz');

select throws_ok(pg_temp.registro('manual', null, true, 'pendente'),
  '23514', pg_temp.violacao('verificacao_coerente'),
  'RN22 regressão verificacao_coerente: manual confirmado e não marcado é recusado');

select * from finish();
rollback;
