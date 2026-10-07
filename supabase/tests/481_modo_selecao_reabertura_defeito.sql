-- 481_modo_selecao_reabertura_defeito.sql
--
-- Reprodução do defeito apontado pelo Oráculo no modo seleção:
-- cancelar_posicao e reabrir_por_atraso reabrem a posição em vagas de modo seleção,
-- mas quando o início do turno está a menos de 24 h (ou já passou):
--   1. fechar_selecoes (a cada minuto) cancela a posição reaberta aberta e encerra a vaga;
--   2. candidatar / escolher recusam com 409 vaga_encerrada;
--   3. O turno fica descoberto enquanto a notificação para a casa diz reaberta: true.
--
-- Cenários testados:
--   - Controle (> 24 h): cancelamento de escolhido reabre normalmente e aceita nova escolha
--   - Caminho 1 (< 24 h): cancelamento de escolhido dentro das 24 h
--   - Caminho 2 (< 24 h / em andamento): reabertura por atraso aos 15 min do turno
--
-- Prefixo `ca`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(29);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-11-02 12:00:00+00', true);

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

create function pg_temp.p(n int) returns uuid language sql as $$
  select ('ca000000-0000-4000-8000-00000000000' || n)::uuid
$$;

select pg_temp.autenticar('ca000000-0000-4000-8000-0000000000d1', 'dona@selecao-defeito.test');
select pg_temp.autenticar(pg_temp.p(n), 'garcom' || n || '@selecao-defeito.test')
  from generate_series(1, 6) n;

select pg_temp.como('ca000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona do Defeito','+5561966660001','1980-01-01','2026-09-22') $$);
select pg_temp.como(pg_temp.p(n),
  format($$ select public.criar_conta('profissional','Garçom %s','+556196666001%s','1995-01-01','2026-09-22') $$, n, n))
  from generate_series(1, 6) n;

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como(pg_temp.p(n),
  format($$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)))
  from generate_series(1, 6) n;

create temp table casa as
  select (pg_temp.como('ca000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Bar do Defeito','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create function pg_temp.publicar(ini timestamptz, fim timestamptz, chave uuid) returns uuid
language plpgsql as $$
begin
  return (pg_temp.como('ca000000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 406',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, 'Dono', 'selecao', %L) $sql$,
    (select id from casa), (select garcom from fn), ini, fim, chave))->>'vaga_id')::uuid;
end $$;

create function pg_temp.cand(n int, vaga uuid) returns uuid language sql as $$
  select c.id from public.candidatura c
    join public.posicao x on x.id = c.posicao_id
    join public.profissional pr on pr.id = c.profissional_id
   where x.vaga_id = vaga and pr.usuario_id = pg_temp.p(n)
$$;

create function pg_temp.pos_da_vaga(vaga uuid) returns uuid language sql as $$
  select id from public.posicao where vaga_id = vaga and estado = 'confirmada' limit 1;
$$;

create function pg_temp.pos_aberta_da_vaga(vaga uuid) returns uuid language sql as $$
  select id from public.posicao where vaga_id = vaga and estado = 'aberta' limit 1;
$$;

-- ════════════════════════════════════════════════════════════════════════════════
-- 1. CONTROLE (> 24 h): Cancelamento de escolhido com mais de 24 h de antecedência
-- ════════════════════════════════════════════════════════════════════════════════

-- Publica vaga com início em 05/11 20:00 (estamos em 02/11 12:00: > 72 h de antecedência)
create temp table vaga_ctrl as select pg_temp.publicar(
  '2026-11-05 20:00+00', '2026-11-06 02:00+00', 'ca000000-0000-4000-8000-00000000c001') as id;

-- Profissional p1 se candidata e é escolhido
select pg_temp.como(pg_temp.p(1), format($$ select public.candidatar(%L) $$, (select id from vaga_ctrl)));
select pg_temp.como('ca000000-0000-4000-8000-0000000000d1',
  format($$ select public.escolher_candidato(%L) $$, pg_temp.cand(1, (select id from vaga_ctrl))));

select is((select estado::text from public.vaga where id = (select id from vaga_ctrl)), 'preenchida',
  'controle (>24h): vaga de seleção preenchida após escolha');

-- Avança relógio para 04/11 12:00 (28 h antes do início de 05/11 20:00 -> > 24 h)
select set_config('frila.agora', '2026-11-04 12:00:00+00', true);

-- p1 cancela a posição a mais de 24 h do início
create temp table res_canc_ctrl as select pg_temp.como(pg_temp.p(1),
  format($$ select public.cancelar_posicao(%L, 'imprevisto a tempo') $$,
         pg_temp.pos_da_vaga((select id from vaga_ctrl)))) as r;

select is(((select r from res_canc_ctrl)->>'falta')::boolean, false,
  'controle (>24h): cancelamento com >24h não gera falta');
select is(((select r from res_canc_ctrl)->>'reaberta')::boolean, true,
  'controle (>24h): cancelamento com >24h reabre a vaga');
select is((select estado::text from public.vaga where id = (select id from vaga_ctrl)), 'publicada',
  'controle (>24h): vaga volta para publicada');
select is((select estado::text from public.posicao where id = pg_temp.pos_aberta_da_vaga((select id from vaga_ctrl))), 'aberta',
  'controle (>24h): nova posição nasce aberta');

-- Job fechar_selecoes roda a 28 h do início
select cmp_ok(privado.fechar_selecoes(), '>=', 0, 'fechar_selecoes executa');
select is((select estado::text from public.posicao where id = pg_temp.pos_aberta_da_vaga((select id from vaga_ctrl))), 'aberta',
  'controle (>24h): fechar_selecoes NÃO cancela a posição reaberta com >24h');
select is((select estado::text from public.vaga where id = (select id from vaga_ctrl)), 'publicada',
  'controle (>24h): vaga continua publicada');

-- p2 se candidata e é escolhido normalmente
select is((pg_temp.como(pg_temp.p(2), format($$ select public.candidatar(%L) $$, (select id from vaga_ctrl)))->>'estado'),
  'pendente', 'controle (>24h): novo profissional candidata-se com sucesso na posição reaberta');
select is((pg_temp.como('ca000000-0000-4000-8000-0000000000d1',
  format($$ select public.escolher_candidato(%L) $$, pg_temp.cand(2, (select id from vaga_ctrl))))->>'estado'),
  'confirmada', 'controle (>24h): casa consegue escolher o novo candidato');
select is((select estado::text from public.vaga where id = (select id from vaga_ctrl)), 'preenchida',
  'controle (>24h): vaga volta a ficar preenchida');


-- ════════════════════════════════════════════════════════════════════════════════
-- 2. CAMINHO 1: Cancelamento de escolhido a MENOS de 24 h do início
-- ════════════════════════════════════════════════════════════════════════════════

-- Volta o relógio para antes das 24 h para publicar e escolher
select set_config('frila.agora', '2026-11-02 12:00:00+00', true);

create temp table vaga_def1 as select pg_temp.publicar(
  '2026-11-05 20:00+00', '2026-11-06 02:00+00', 'ca000000-0000-4000-8000-00000000d001') as id;

-- Profissional p3 se candidata e é escolhido
select pg_temp.como(pg_temp.p(3), format($$ select public.candidatar(%L) $$, (select id from vaga_def1)));
select pg_temp.como('ca000000-0000-4000-8000-0000000000d1',
  format($$ select public.escolher_candidato(%L) $$, pg_temp.cand(3, (select id from vaga_def1))));

select is((select estado::text from public.vaga where id = (select id from vaga_def1)), 'preenchida',
  'caminho 1: vaga preenchida com p3');

-- Avança relógio para 05/11 08:00 (12 h antes do início de 05/11 20:00 -> < 24 h)
select set_config('frila.agora', '2026-11-05 08:00:00+00', true);

-- p3 cancela a posição a 12 h do início
create temp table res_canc_def1 as select pg_temp.como(pg_temp.p(3),
  format($$ select public.cancelar_posicao(%L, 'imprevisto de saúde') $$,
         pg_temp.pos_da_vaga((select id from vaga_def1)))) as r;

select is(((select r from res_canc_def1)->>'falta')::boolean, true,
  'caminho 1: cancelamento com <24h gera falta');
select is(((select r from res_canc_def1)->>'reaberta')::boolean, true,
  'caminho 1: retorno da RPC diz reaberta: true');

-- Guarda o ID da posição reaberta criada
create temp table pos_reaberta_def1 as select pg_temp.pos_aberta_da_vaga((select id from vaga_def1)) as id;

-- D4=C: a vaga é convertida para modo urgência dentro das 24 h
select is((select modo::text from public.vaga where id = (select id from vaga_def1)), 'urgencia',
  'caminho 1 (D4=C): a menos de 24h a vaga reaberta passa para o modo urgencia');

-- O job fechar_selecoes() não cancela a posição reaberta em urgência
select cmp_ok(privado.fechar_selecoes(), '>=', 0, 'caminho 1: executa fechar_selecoes');

select is((select estado::text from public.posicao where id = (select id from pos_reaberta_def1)), 'aberta',
  'caminho 1: posição reaberta permanece aberta (fechar_selecoes não a cancela)');
select is((select estado::text from public.vaga where id = (select id from vaga_def1)), 'publicada',
  'caminho 1: vaga permanece publicada');

-- Candidatura na vaga com posição reaberta a <24h: primeiro elegível confirma na hora (urgência)
select is((pg_temp.como(pg_temp.p(4), format($$ select public.candidatar(%L) $$, (select id from vaga_def1)))->>'estado'),
  'confirmada',
  'caminho 1 (D4=C): candidato confirma na hora cobrindo o turno em urgência');
select is((select estado::text from public.vaga where id = (select id from vaga_def1)), 'preenchida',
  'caminho 1: vaga volta a preenchida após confirmação');


-- ════════════════════════════════════════════════════════════════════════════════
-- 3. CAMINHO 2: Reabertura por atraso aos 15 minutos do turno
-- ════════════════════════════════════════════════════════════════════════════════

-- Volta o relógio para antes das 24 h para publicar e escolher
select set_config('frila.agora', '2026-11-02 12:00:00+00', true);

create temp table vaga_def2 as select pg_temp.publicar(
  '2026-11-05 20:00+00', '2026-11-06 02:00+00', 'ca000000-0000-4000-8000-00000000e001') as id;

-- Profissional p5 se candidata e é escolhido
select pg_temp.como(pg_temp.p(5), format($$ select public.candidatar(%L) $$, (select id from vaga_def2)));
select pg_temp.como('ca000000-0000-4000-8000-0000000000d1',
  format($$ select public.escolher_candidato(%L) $$, pg_temp.cand(5, (select id from vaga_def2))));

select is((select estado::text from public.vaga where id = (select id from vaga_def2)), 'preenchida',
  'caminho 2: vaga preenchida com p5');

-- Turno começa às 20:00. Avança relógio para 20:15 (tolerância de 15 min de atraso, D06)
select set_config('frila.agora', '2026-11-05 20:15:00+00', true);

-- Contratante chama reabrir_por_atraso
create temp table res_atraso_def2 as select pg_temp.como('ca000000-0000-4000-8000-0000000000d1',
  format($$ select public.reabrir_por_atraso(%L) $$, pg_temp.pos_da_vaga((select id from vaga_def2)))) as r;

select is(((select r from res_atraso_def2)->>'falta')::boolean, true,
  'caminho 2: reabrir_por_atraso marca falta');
select is(((select r from res_atraso_def2)->>'reaberta')::boolean, true,
  'caminho 2: retorno da RPC diz reaberta: true');

-- Guarda ID da nova posição reaberta por atraso
create temp table pos_reaberta_def2 as select ((select r from res_atraso_def2)->>'nova_posicao_id')::uuid as id;

-- D5=A: a vaga é convertida para modo urgência
select is((select modo::text from public.vaga where id = (select id from vaga_def2)), 'urgencia',
  'caminho 2 (D5=A): reabertura por atraso converte a vaga para modo urgencia');

-- O fechar_selecoes() não cancela a posição reaberta por atraso em urgência
select cmp_ok(privado.fechar_selecoes(), '>=', 0, 'caminho 2: executa fechar_selecoes');

select is((select estado::text from public.posicao where id = (select id from pos_reaberta_def2)), 'aberta',
  'caminho 2: posição reaberta por atraso permanece aberta (fechar_selecoes não a cancela)');
select is((select estado::text from public.vaga where id = (select id from vaga_def2)), 'publicada',
  'caminho 2: vaga permanece publicada');

-- Candidatura na posição reaberta por atraso: primeiro elegível confirma na hora (urgência)
select is((pg_temp.como(pg_temp.p(6), format($$ select public.candidatar(%L) $$, (select id from vaga_def2)))->>'estado'),
  'confirmada',
  'caminho 2 (D5=A): candidato substituto confirma na hora cobrindo o turno');
select is((select estado::text from public.vaga where id = (select id from vaga_def2)), 'preenchida',
  'caminho 2: vaga volta a preenchida após confirmação do substituto');

select * from finish();
rollback;
