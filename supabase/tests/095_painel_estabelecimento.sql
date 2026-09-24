-- `painel_estabelecimento`: o que o gestor olha na sexta às 20h.
--
-- Não existe operador do Frila olhando esta tela (D01). Se o alerta de vaga vazia ou o
-- de atraso não aparece aqui, ninguém mais vê. Por isso os dois são calculados **na
-- leitura**, pelo relógio do produto, e testados com o relógio parado em instantes
-- escolhidos — antes, em cima e depois de cada limite.
--
--   alerta_vaga_vazia  há posição aberta, a vaga está publicada, e o relógio está dentro
--                      da janela crítica: de `inicio_em - alerta_antecedencia` até o início
--   em_atraso          posição confirmada, sem check-in, 15 minutos depois do início (D06)
--                      e antes do fim
--   checkins_pendentes turno com check-in manual esperando a confirmação do contratante
--   candidatos_pendentes candidaturas pendentes, sem as de quem tem bloqueio com a casa (RF26)
--
-- E o documento do estabelecimento — CPF de quem contrata diarista — não sai em leitura
-- nenhuma feita por profissional.

begin;
select plan(35);

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

-- Varre toda tabela de `public` como a conta, procurando `texto` em qualquer coluna de
-- qualquer linha que a política deixa ler. Devolve os nomes das tabelas onde achou.
create function pg_temp.tabelas_com_texto(conta uuid, texto text) returns text
language plpgsql as $$
declare
  t   text;
  n   int;
  achou text[] := '{}';
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  for t in select tablename from pg_tables where schemaname = 'public' order by 1 loop
    begin
      execute format('select count(*) from public.%I x where x::text like %L', t, '%' || texto || '%')
         into n;
      if n > 0 then achou := achou || t; end if;
    exception when insufficient_privilege then
      null;   -- sem grant de select é, por construção, leitura nenhuma
    end;
  end loop;
  reset role;
  execute 'reset request.jwt.claims';
  return array_to_string(achou, ',');
end $$;

-- ── O cenário ──────────────────────────────────────────────────────────────────
--
-- Sexta, 10/10/2026, 20:00 UTC. O Bar do Zé tem três vagas na janela do painel:
--
--   V1  começa às 21:00 · 2 posições: uma aberta (→ alerta), uma confirmada com o Beto
--   V2  começa amanhã às 20:00 · 1 aberta · candidaturas: Ana pendente, Caio pendente
--       (bloqueado pelo Zé), Duda recusada
--   V3  começou às 19:30 · Ana confirmada sem check-in (→ atraso) · Duda com check-in
--       manual esperando confirmação
--
-- Fora do painel: V4, do Zé, fora da janela de datas; V5, do Buffet da Rita.

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('d1000000-0000-4000-8000-000000000001','profissional','Ana',  '+5561999990001','ana@t.test', '1995-01-01','2026-09-22', now()),
  ('d1000000-0000-4000-8000-000000000002','profissional','Beto', '+5561999990002','beto@t.test','1995-01-01','2026-09-22', now()),
  ('d1000000-0000-4000-8000-000000000003','profissional','Caio', '+5561999990003','caio@t.test','1995-01-01','2026-09-22', now()),
  ('d1000000-0000-4000-8000-000000000004','profissional','Duda', '+5561999990004','duda@t.test','1995-01-01','2026-09-22', now()),
  ('d2000000-0000-4000-8000-000000000001','contratante', 'Zé',   '+5561999990011','ze@t.test',  '1980-01-01','2026-09-22', now()),
  ('d2000000-0000-4000-8000-000000000002','contratante', 'Rita', '+5561999990012','rita@t.test','1980-01-01','2026-09-22', now());

insert into public.profissional (id, usuario_id, ponto_base) values
  ('d3000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000001','POINT(-47.88 -15.79)'::extensions.geography),
  ('d3000000-0000-4000-8000-000000000002','d1000000-0000-4000-8000-000000000002','POINT(-47.88 -15.79)'::extensions.geography),
  ('d3000000-0000-4000-8000-000000000003','d1000000-0000-4000-8000-000000000003','POINT(-47.88 -15.79)'::extensions.geography),
  ('d3000000-0000-4000-8000-000000000004','d1000000-0000-4000-8000-000000000004','POINT(-47.88 -15.79)'::extensions.geography);

insert into public.profissional_funcao (profissional_id, funcao_id)
select 'd3000000-0000-4000-8000-000000000002', id from public.funcao where nome = 'garçom';

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('d4000000-0000-4000-8000-000000000001','Bar do Zé','11222333000181','food_service','CLN 201',
   'POINT(-47.8822 -15.7942)'::extensions.geography),
  ('d4000000-0000-4000-8000-000000000002','Buffet da Rita','45223011000179','evento','SIA',
   'POINT(-47.9 -15.8)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('d2000000-0000-4000-8000-000000000001','d4000000-0000-4000-8000-000000000001','administrador'),
  ('d2000000-0000-4000-8000-000000000002','d4000000-0000-4000-8000-000000000002','administrador');

create function pg_temp.vaga(id uuid, estab uuid, inicio timestamptz, fim timestamptz, n int)
returns void language sql as $$
  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente)
  values (id, estab, (select f.id from public.funcao f where f.nome = 'garçom'),
          inicio, fim, 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, n, true, false, false, 'Maître Zé', 'urgencia', gen_random_uuid());
$$;

select pg_temp.vaga('d5000000-0000-4000-8000-000000000001','d4000000-0000-4000-8000-000000000001',
                    '2026-10-10 21:00+00','2026-10-11 03:00+00', 2);
select pg_temp.vaga('d5000000-0000-4000-8000-000000000002','d4000000-0000-4000-8000-000000000001',
                    '2026-10-11 20:00+00','2026-10-12 02:00+00', 1);
select pg_temp.vaga('d5000000-0000-4000-8000-000000000003','d4000000-0000-4000-8000-000000000001',
                    '2026-10-10 19:30+00','2026-10-10 23:30+00', 2);
select pg_temp.vaga('d5000000-0000-4000-8000-000000000004','d4000000-0000-4000-8000-000000000001',
                    '2026-10-20 19:30+00','2026-10-20 23:30+00', 1);
select pg_temp.vaga('d5000000-0000-4000-8000-000000000005','d4000000-0000-4000-8000-000000000002',
                    '2026-10-10 21:00+00','2026-10-11 03:00+00', 1);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em) values
  -- V1
  ('d6000000-0000-4000-8000-0000000001a0','d5000000-0000-4000-8000-000000000001','aberta',null,null,
   '2026-10-10 21:00+00','2026-10-11 03:00+00'),
  ('d6000000-0000-4000-8000-0000000001b0','d5000000-0000-4000-8000-000000000001','confirmada',
   'd3000000-0000-4000-8000-000000000002','2026-10-09 12:00+00','2026-10-10 21:00+00','2026-10-11 03:00+00'),
  -- V2
  ('d6000000-0000-4000-8000-0000000002a0','d5000000-0000-4000-8000-000000000002','aberta',null,null,
   '2026-10-11 20:00+00','2026-10-12 02:00+00'),
  -- V3
  ('d6000000-0000-4000-8000-0000000003a0','d5000000-0000-4000-8000-000000000003','confirmada',
   'd3000000-0000-4000-8000-000000000001','2026-10-09 12:00+00','2026-10-10 19:30+00','2026-10-10 23:30+00'),
  ('d6000000-0000-4000-8000-0000000003b0','d5000000-0000-4000-8000-000000000003','confirmada',
   'd3000000-0000-4000-8000-000000000004','2026-10-09 12:00+00','2026-10-10 19:30+00','2026-10-10 23:30+00'),
  -- V4 e V5
  ('d6000000-0000-4000-8000-0000000004a0','d5000000-0000-4000-8000-000000000004','aberta',null,null,
   '2026-10-20 19:30+00','2026-10-20 23:30+00'),
  ('d6000000-0000-4000-8000-0000000005a0','d5000000-0000-4000-8000-000000000005','aberta',null,null,
   '2026-10-10 21:00+00','2026-10-11 03:00+00');

insert into public.candidatura (posicao_id, profissional_id, estado) values
  ('d6000000-0000-4000-8000-0000000002a0','d3000000-0000-4000-8000-000000000001','pendente'),
  ('d6000000-0000-4000-8000-0000000002a0','d3000000-0000-4000-8000-000000000003','pendente'),
  ('d6000000-0000-4000-8000-0000000002a0','d3000000-0000-4000-8000-000000000004','recusada');

-- RF26: o Zé bloqueou o Caio. A candidatura dele continua na tabela, mas não é contada.
insert into public.bloqueio (autor_id, bloqueado_id)
values ('d2000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000003');

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, valor_acordado_centavos) values
  -- Ana: turno criado na confirmação, sem check-in.
  ('d7000000-0000-4000-8000-0000000003a0','d6000000-0000-4000-8000-0000000003a0', null, null, null, 12000),
  -- Duda: check-in manual às 19:35, esperando o toque do contratante.
  ('d7000000-0000-4000-8000-0000000003b0','d6000000-0000-4000-8000-0000000003b0',
   '2026-10-10 19:35+00','manual', 450, 12000),
  -- Beto: turno da V1, ainda sem check-in porque a vaga não começou.
  ('d7000000-0000-4000-8000-0000000001b0','d6000000-0000-4000-8000-0000000001b0', null, null, null, 12000);

-- O relógio: marcador de teste escrito aqui dentro, e levado pelo rollback.
insert into privado.ambiente (id, eh_teste) values (true, true);

create function pg_temp.painel(conta uuid) returns jsonb language sql as $$
  select pg_temp.como(conta,
    $x$ select public.painel_estabelecimento('d4000000-0000-4000-8000-000000000001'::uuid,
                                             '2026-10-10 00:00+00'::timestamptz,
                                             '2026-10-12 00:00+00'::timestamptz) $x$)
$$;

create function pg_temp.vaga_de(p jsonb, id text) returns jsonb language sql as $$
  select v from jsonb_array_elements(p->'vagas') v where v->'vaga'->>'id' = id
$$;

create function pg_temp.posicao_de(p jsonb, id text) returns jsonb language sql as $$
  select x from jsonb_array_elements(p->'vagas') v, jsonb_array_elements(v->'posicoes') x
   where x->>'id' = id
$$;

-- ── Quem pode ler ──────────────────────────────────────────────────────────────
select throws_ok(
  $$ select public.painel_estabelecimento('d4000000-0000-4000-8000-000000000001',
       '2026-10-10 00:00+00','2026-10-12 00:00+00') $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não há painel');

select throws_ok(
  $$ select pg_temp.painel('d1000000-0000-4000-8000-000000000001') $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'o profissional não lê o painel do estabelecimento, nem o de onde trabalha');

select throws_ok(
  $$ select pg_temp.painel('d2000000-0000-4000-8000-000000000002') $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'o contratante de outro estabelecimento também não');

select throws_ok(
  $$ select pg_temp.como('d2000000-0000-4000-8000-000000000001',
       $x$ select public.painel_estabelecimento('d4000000-0000-4000-8000-000000000001', null,
             '2026-10-12 00:00+00') $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "de", "hint" : null}',
  'o intervalo é obrigatório: sem ele o painel viraria a história inteira da casa');

-- ── Sexta, 20:00 ───────────────────────────────────────────────────────────────
set local frila.agora = '2026-10-10 20:00:00+00';
create temp table p as select pg_temp.painel('d2000000-0000-4000-8000-000000000001') as j;

select is((select j->>'estabelecimento_id' from p), 'd4000000-0000-4000-8000-000000000001',
  'o painel é do estabelecimento pedido');

select is(
  (select array_agg(v->'vaga'->>'id' order by v->'vaga'->>'id') from p, jsonb_array_elements(p.j->'vagas') v),
  array['d5000000-0000-4000-8000-000000000001','d5000000-0000-4000-8000-000000000002',
        'd5000000-0000-4000-8000-000000000003'],
  'traz as vagas da casa no intervalo pedido — nem a de outra data, nem a do buffet ao lado');

-- RF20: a vaga vazia dentro da janela crítica.
select is((select pg_temp.vaga_de(j,'d5000000-0000-4000-8000-000000000001')->'alerta_vaga_vazia' from p),
  'true'::jsonb,
  'RF20: posição aberta a 1 h do início, com janela de 3 h, está em alerta');
select is((select pg_temp.vaga_de(j,'d5000000-0000-4000-8000-000000000002')->'alerta_vaga_vazia' from p),
  'false'::jsonb,
  'RF20: posição aberta a 24 h do início ainda não está em alerta');
select is((select pg_temp.vaga_de(j,'d5000000-0000-4000-8000-000000000003')->'alerta_vaga_vazia' from p),
  'false'::jsonb,
  'RF20: vaga sem posição aberta não está em alerta');

-- RF26: candidatos pendentes sem o bloqueado e sem o recusado.
select is((select pg_temp.vaga_de(j,'d5000000-0000-4000-8000-000000000002')->'candidatos_pendentes' from p),
  '1'::jsonb,
  'RF26: candidatos_pendentes não conta quem tem bloqueio com a casa, nem candidatura recusada');

-- D06: 15 minutos sem check-in.
select is((select pg_temp.posicao_de(j,'d6000000-0000-4000-8000-0000000003a0')->'em_atraso' from p),
  'true'::jsonb,
  'D06: confirmada, sem check-in, 30 minutos depois do início, está em atraso');
select is((select pg_temp.posicao_de(j,'d6000000-0000-4000-8000-0000000003b0')->'em_atraso' from p),
  'false'::jsonb,
  'D06: quem fez check-in, mesmo manual e ainda sem confirmação, não está em atraso');
select is((select pg_temp.posicao_de(j,'d6000000-0000-4000-8000-0000000001b0')->'em_atraso' from p),
  'false'::jsonb,
  'D06: turno que ainda não começou não está em atraso');

select is((select j->'checkins_pendentes' from p),
  '["d7000000-0000-4000-8000-0000000003b0"]'::jsonb,
  'checkins_pendentes traz o turno com check-in manual esperando o contratante, e só ele');

select is((select pg_temp.posicao_de(j,'d6000000-0000-4000-8000-0000000003a0')->>'turno_id' from p),
  'd7000000-0000-4000-8000-0000000003a0', 'a posição confirmada traz o turno');
select is((select pg_temp.posicao_de(j,'d6000000-0000-4000-8000-0000000003a0')->>'verificacao' from p),
  'pendente', 'e a verificação dele');

select is(
  (select jsonb_build_array(x->'profissional', x->'turno_id', x->'verificacao', x->>'estado')
     from p, pg_temp.posicao_de(j,'d6000000-0000-4000-8000-0000000001a0') x),
  '[null, null, null, "aberta"]'::jsonb,
  'a posição aberta vem sem profissional, sem turno e sem verificação — nulos, não ausentes');

-- O profissional aparece como PerfilPublico: nome e reputação com denominador (RN08).
select is(
  (select (x->'profissional') - 'id' from p, pg_temp.posicao_de(j,'d6000000-0000-4000-8000-0000000001b0') x),
  '{"tipo":"profissional","nome":"Beto","funcoes":["garçom"],
    "reputacao":{"positivas":0,"total":0,"taxa_comparecimento":null,"turnos_considerados":0}}'::jsonb,
  'RN08: o contratado aparece como PerfilPublico — sem histórico é total 0 e taxa nula, nunca nota zero');
select is(
  (select x->'profissional'->>'id' from p, pg_temp.posicao_de(j,'d6000000-0000-4000-8000-0000000001b0') x),
  'd3000000-0000-4000-8000-000000000002',
  'e o id do PerfilPublico é o do profissional, o mesmo que perfil_publico recebe');

-- ── O formato do contrato ──────────────────────────────────────────────────────
select is(
  (select array_agg(k order by k) from p, jsonb_object_keys(p.j) k),
  array['checkins_pendentes','estabelecimento_id','vagas'],
  'o painel traz exatamente os campos do schema Painel');
select is(
  (select array_agg(k order by k) from p,
          jsonb_object_keys(pg_temp.vaga_de(j,'d5000000-0000-4000-8000-000000000001')) k),
  array['alerta_vaga_vazia','candidatos_pendentes','estado','modo','posicoes','vaga'],
  'cada vaga traz exatamente os campos de VagaNoPainel');
select is(
  (select (pg_temp.vaga_de(j,'d5000000-0000-4000-8000-000000000001')->'vaga') - 'inicio_em' - 'fim_em' from p),
  '{"id":"d5000000-0000-4000-8000-000000000001","funcao":"garçom","local":"CLN 201","valor_centavos":12000}'::jsonb,
  'VagaResumo traz a função pelo nome e o valor em centavos inteiros (RN18)');
select is(
  (select (pg_temp.vaga_de(j,'d5000000-0000-4000-8000-000000000001')->'vaga'->>'inicio_em')::timestamptz from p),
  '2026-10-10 21:00+00'::timestamptz,
  'e o início como instante');
select is(
  (select array_agg(k order by k) from p,
          jsonb_object_keys(pg_temp.posicao_de(j,'d6000000-0000-4000-8000-0000000003a0')) k),
  array['em_atraso','estado','id','profissional','turno_id','verificacao'],
  'cada posição traz exatamente os campos de PosicaoNoPainel');

-- O painel é do estabelecimento, e mesmo assim não repete o documento nem expõe o
-- telefone de ninguém: contato sai só por contato_do_turno (RN10).
select ok(
  (select position('11222333000181' in j::text) = 0 and position('+5561' in j::text) = 0 from p),
  'RN10: o painel não traz o documento da casa nem telefone de profissional');

-- ── Os limites, com o relógio parado em cada um ────────────────────────────────
set local frila.agora = '2026-10-10 19:44:59+00';
select is(pg_temp.posicao_de(pg_temp.painel('d2000000-0000-4000-8000-000000000001'),
            'd6000000-0000-4000-8000-0000000003a0')->'em_atraso',
  'false'::jsonb, 'D06: 14 minutos e 59 segundos depois do início ainda não é atraso');

set local frila.agora = '2026-10-10 19:45:00+00';
select is(pg_temp.posicao_de(pg_temp.painel('d2000000-0000-4000-8000-000000000001'),
            'd6000000-0000-4000-8000-0000000003a0')->'em_atraso',
  'true'::jsonb, 'D06: aos 15 minutos em ponto, é');

set local frila.agora = '2026-10-10 23:30:00+00';
select is(pg_temp.posicao_de(pg_temp.painel('d2000000-0000-4000-8000-000000000001'),
            'd6000000-0000-4000-8000-0000000003a0')->'em_atraso',
  'false'::jsonb, 'D06: depois do fim já não é atraso — não há o que esperar nem o que reabrir');

set local frila.agora = '2026-10-10 17:59:59+00';
select is(pg_temp.vaga_de(pg_temp.painel('d2000000-0000-4000-8000-000000000001'),
            'd5000000-0000-4000-8000-000000000001')->'alerta_vaga_vazia',
  'false'::jsonb, 'RF20: um segundo antes da janela crítica de 3 h, sem alerta');

set local frila.agora = '2026-10-10 18:00:00+00';
select is(pg_temp.vaga_de(pg_temp.painel('d2000000-0000-4000-8000-000000000001'),
            'd5000000-0000-4000-8000-000000000001')->'alerta_vaga_vazia',
  'true'::jsonb, 'RF20: na abertura da janela, com alerta');

set local frila.agora = '2026-10-10 21:00:00+00';
select is(pg_temp.vaga_de(pg_temp.painel('d2000000-0000-4000-8000-000000000001'),
            'd5000000-0000-4000-8000-000000000001')->'alerta_vaga_vazia',
  'false'::jsonb, 'RF20: a vaga que já começou saiu da janela — ninguém mais se candidata a ela');

-- A janela é da vaga, não fixa: publicada com 30 minutos, o alerta só abre às 20:30.
update public.vaga set alerta_antecedencia = '30 minutes'
 where id = 'd5000000-0000-4000-8000-000000000001';
set local frila.agora = '2026-10-10 20:00:00+00';
select is(pg_temp.vaga_de(pg_temp.painel('d2000000-0000-4000-8000-000000000001'),
            'd5000000-0000-4000-8000-000000000001')->'alerta_vaga_vazia',
  'false'::jsonb, 'RF20: a janela crítica é a escolhida na publicação, não 3 h para todas');

-- Vaga cancelada com posição aberta não é vaga vazia: é vaga que não existe mais.
update public.vaga set alerta_antecedencia = '3 hours', estado = 'cancelada'
 where id = 'd5000000-0000-4000-8000-000000000001';
select is(pg_temp.vaga_de(pg_temp.painel('d2000000-0000-4000-8000-000000000001'),
            'd5000000-0000-4000-8000-000000000001')->'alerta_vaga_vazia',
  'false'::jsonb, 'RF20: vaga cancelada não alerta');

-- ── O documento não aparece em leitura feita por profissional ─────────────────
--
-- A Ana tem turno no Bar do Zé, candidatura e vaga visíveis. Nenhuma tabela que ela
-- consegue ler carrega o CNPJ da casa — e a mesma varredura, como o Zé, acha: é a prova
-- de que a varredura enxerga o que procura.
select is(pg_temp.tabelas_com_texto('d1000000-0000-4000-8000-000000000001', '11222333000181'), '',
  'o documento não aparece em nenhuma tabela que o profissional lê');
select is(pg_temp.tabelas_com_texto('d2000000-0000-4000-8000-000000000001', '11222333000181'),
  'estabelecimento',
  'e a mesma varredura, como membro, acha o documento — a varredura funciona');

select * from finish();
rollback;
