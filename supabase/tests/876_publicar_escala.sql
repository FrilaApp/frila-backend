-- 876_publicar_escala.sql
--
-- publicar_escala (migração 20261117030000, contrato 0.2.96, RF19; B-031, cartão 6mi66YDp). O pgTAP
-- mínimo do Juiz (orquestracao/retornos/P-028-parecer-juiz.md, item 8) e a decisão da Bússola de
-- 16/11/2026 sobre o evento:
--   A  quem pode, na ordem de publicar_vaga, e a chave antes do corpo
--   B  5 funções e 40 posições numa chamada: 1 evento, 5 vagas na ordem dos itens, 40 posições e
--      5 mensagens de despacho; cada vaga com o local, a região e o ponto do evento e chave própria
--   C  o reenvio devolve a mesma escala sem despachar de novo, também depois de o horário passar e com
--      outro corpo; a unique (estabelecimento_id, chave) recusa a segunda escala com a mesma chave
--   D  tudo ou nada: a recusa no item 7 de 8 não deixa evento, vaga, posição nem mensagem, e a chave
--      segue livre
--   E  recusas e o caminho em details: [150] sozinho, soma, quantidade, o evento campo a campo, tipo
--      errado no item, horário e RN24 por item, filtro de termos; publicar_vaga segue com 200
--   F  conta de demonstração publica e não enfileira
--   G  republicar_vaga de uma vaga da escala não copia o evento_id
--   H  RLS: só membro da casa lê o evento
--   I  o evento segue as vagas: exclusão de conta, limpeza de 15 dias e expurgo de 5 anos (nome e local
--      com o marcador das vagas; a data fica)
-- O resto de publicar_vaga (a mesma conferência, agora em privado.validar_nova_vaga) é a suíte antiga.
-- A corrida de dois envios simultâneos é do scripts/corrida-escala.sh. Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2030-03-04 15:00:00+00', true);   -- segunda, 12h em Brasília
set local frila.agendador_secret = 'segredo-de-teste-876';
select plan(56);

-- ── Ajudantes ────────────────────────────────────────────────────────────────
create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

-- A recusa como '<status> <code> [details]', ou 'ok'. Sem conta, chama sem sessão.
create function pg_temp.recusa(conta uuid, sql text) returns text language plpgsql as $$
declare m text; d text;
begin
  begin
    if conta is null then
      execute 'set local role authenticated';
      execute sql;
      reset role;
    else
      perform pg_temp.como(conta, sql);
    end if;
  exception when others then
    get stacked diagnostics m = message_text, d = pg_exception_detail;
    if m !~ '^\s*\{' then
      return 'sqlstate ' || sqlstate;
    end if;
    return concat_ws(' ', d::jsonb->>'status', m::jsonb->>'code', m::jsonb->>'details');
  end;
  return 'ok';
end $$;

create function pg_temp.u(n int) returns uuid language sql immutable as $$
  select ('c8760000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.casa(n int) returns uuid language sql immutable as $$
  select ('c8760000-0000-4000-8000-00000000e0' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.chave(n int) returns uuid language sql immutable as $$
  select ('c8760000-0000-4000-8000-0000000c00' || lpad(n::text, 2, '0'))::uuid $$;

-- A chamada de publicar_escala, como texto.
create function pg_temp.sql(casa uuid, evento jsonb, vagas jsonb, chave uuid) returns text language sql immutable as $$
  select format('select public.publicar_escala(estabelecimento_id => %L::uuid, evento => %L::jsonb, vagas => %L::jsonb, chave => %L::uuid)',
                casa, evento, vagas, chave) $$;

-- O evento da escala e um item válido (turno de 6 h, urgência).
create function pg_temp.evento() returns jsonb language sql immutable as $$
  select '{"nome": "Formatura de Direito 876", "data": "2030-03-06", "local": "SHN Quadra 5, Salão Nobre",
           "regiao_administrativa": "Plano Piloto", "ponto": {"latitude": -15.7840, "longitude": -47.8890}}'::jsonb $$;
create function pg_temp.item(p_funcao text, p_inicio timestamptz, p_posicoes int) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'funcao_id', (select f.id from public.funcao f where f.nome = p_funcao),
    'inicio_em', p_inicio, 'fim_em', p_inicio + interval '6 hours',
    'valor_centavos', 18000, 'posicoes', p_posicoes,
    'inclui_refeicao', true, 'inclui_transporte', false, 'exige_material_proprio', false,
    'responsavel_local', 'Cerimonial', 'modo', 'urgencia') $$;
-- Um item de garçom com campos trocados por p_troca.
create function pg_temp.garcom(p_troca jsonb default '{}') returns jsonb language sql stable as $$
  select pg_temp.item('garçom', '2030-03-06 21:00:00+00', 2) || p_troca $$;
-- A recusa de uma escala da casa 1, com chave nova.
create function pg_temp.recusa_escala(p_evento jsonb, p_vagas jsonb) returns text language sql as $$
  select pg_temp.recusa(pg_temp.u(1), pg_temp.sql(pg_temp.casa(1), p_evento, p_vagas, gen_random_uuid())) $$;

-- ── Massa ─────────────────────────────────────────────────────────────────────
-- Contratantes: 1 (casa 1, a principal), 2 (casa 2), 3 suspensa (casa 3), 4 de demonstração (casa 4) e
-- 5 (sozinha na casa 5, para a exclusão de conta). Profissional: 11.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao, estado)
select pg_temp.u(n), 'contratante', 'Contratante 876 ' || n, '+5561955876' || lpad(n::text, 3, '0'),
       'c' || n || '@t876.test', '1985-01-01', '2026-11-13', privado.agora(), n = 4,
       (case when n = 3 then 'suspensa' else 'ativa' end)::public.estado_conta
  from generate_series(1, 5) n;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values (pg_temp.u(11), 'profissional', 'Prof 876', '+5561987876011', 'p11@t876.test', '1990-01-01', '2026-11-13', privado.agora());
insert into public.profissional (usuario_id, ponto_base)
values (pg_temp.u(11), 'POINT(-47.8822 -15.7800)'::extensions.geography);
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
select pg_temp.casa(n), 'Casa 876 ' || n, '8761234' || n || '666', 'evento', 'SHN Quadra ' || n,
       'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'
  from generate_series(1, 5) n;
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select pg_temp.u(n), pg_temp.casa(n), 'administrador' from generate_series(1, 5) n;

-- O que entrou na fila de despacho desde o começo deste arquivo.
create temp table fila0 as select count(*)::int as n from pgmq.q_despacho;
create function pg_temp.fila() returns int language sql as $$
  select (select count(*)::int from pgmq.q_despacho) - (select n from fila0) $$;

-- ── A. Quem pode, e a chave antes do corpo ───────────────────────────────────
select is(pg_temp.recusa(null, pg_temp.sql(pg_temp.casa(1), pg_temp.evento(), jsonb_build_array(pg_temp.garcom()), pg_temp.chave(1))),
  '401 nao_autenticado', 'A1 sem sessão: 401 nao_autenticado');
select is(pg_temp.recusa(pg_temp.u(11), pg_temp.sql(pg_temp.casa(1), pg_temp.evento(), jsonb_build_array(pg_temp.garcom()), pg_temp.chave(1))),
  '422 perfil_incompativel', 'A2 conta de profissional: 422 perfil_incompativel');
select is(pg_temp.recusa(pg_temp.u(2), pg_temp.sql(pg_temp.casa(1), pg_temp.evento(), jsonb_build_array(pg_temp.garcom()), pg_temp.chave(1))),
  '403 sem_permissao', 'A3 quem não é membro da casa: 403 sem_permissao');
select is(pg_temp.recusa(pg_temp.u(3), pg_temp.sql(pg_temp.casa(3), pg_temp.evento(), jsonb_build_array(pg_temp.garcom()), pg_temp.chave(3))),
  '403 sem_permissao conta_suspensa', 'A4 conta suspensa: 403 sem_permissao, details conta_suspensa');
select is(pg_temp.recusa(pg_temp.u(1), pg_temp.sql(null, pg_temp.evento(), jsonb_build_array(pg_temp.garcom()), pg_temp.chave(1))),
  '403 sem_permissao', 'A5 sem estabelecimento_id: 403 sem_permissao, como em publicar_vaga');
select is(pg_temp.recusa(pg_temp.u(1), pg_temp.sql(pg_temp.casa(1), null, null, null)),
  '422 campo_obrigatorio chave', 'A6 sem chave: 422 campo_obrigatorio chave, antes do corpo');

-- ── B. Cinco funções e 40 posições numa chamada ──────────────────────────────
create temp table cinco as select jsonb_build_array(
  pg_temp.item('garçom',            '2030-03-06 21:00:00+00', 20),
  pg_temp.item('bartender',         '2030-03-06 21:00:00+00', 10),
  pg_temp.item('copeiro',           '2030-03-06 21:00:00+00', 5),
  pg_temp.item('recepcionista',     '2030-03-06 18:00:00+00', 3),
  pg_temp.item('segurança de sala', '2030-03-06 22:00:00+00', 2)) as vagas;

create temp table r1 as select pg_temp.como(pg_temp.u(1),
  pg_temp.sql(pg_temp.casa(1), pg_temp.evento(), (select vagas from cinco), pg_temp.chave(1))) as j;
create temp table e1 as select (j->>'evento_id')::uuid as id from r1;

select is(
  (select string_agg(f.nome || ':' || jsonb_array_length(t.x->'posicoes'), ',' order by t.o)
     from r1
     cross join lateral jsonb_array_elements(r1.j->'vagas') with ordinality as t(x, o)
     join public.vaga v on v.id = (t.x->>'vaga_id')::uuid
     join public.funcao f on f.id = v.funcao_id),
  'garçom:20,bartender:10,copeiro:5,recepcionista:3,segurança de sala:2',
  'B1 uma vaga por item, na ordem dos itens, com as posições pedidas');

select is(
  (select row(e.estabelecimento_id = pg_temp.casa(1), e.nome, e.data, e.local, e.chave = pg_temp.chave(1),
              e.vagas = array(select (t.x->>'vaga_id')::uuid
                                from r1 cross join lateral jsonb_array_elements(r1.j->'vagas') with ordinality as t(x, o)
                               order by t.o))::text
     from public.evento e where e.id = (select id from e1)),
  '(t,"Formatura de Direito 876",2030-03-06,"SHN Quadra 5, Salão Nobre",t,t)',
  'B2 um evento, com nome, data, local, a chave da escala e as vagas na ordem dos itens');

select is(
  (select count(*)::int from public.vaga v
    where v.evento_id = (select id from e1)
      and v.estabelecimento_id = pg_temp.casa(1)
      and v.local = 'SHN Quadra 5, Salão Nobre'
      and v.regiao_administrativa = 'Plano Piloto'
      and extensions.st_astext(v.ponto::extensions.geometry) = 'POINT(-47.889 -15.784)'
      and v.publicado_por = pg_temp.u(1)
      and v.chave_cliente <> pg_temp.chave(1)
      and v.estado = 'publicada'),
  5, 'B3 as cinco vagas são do evento, com o local, a região e o ponto dele, quem publicou e chave que não é a da escala');

select is((select count(distinct v.chave_cliente)::int from public.vaga v where v.evento_id = (select id from e1)),
  5, 'B4 cada vaga tem chave própria, gerada no servidor');

select is(
  (select count(*)::int from public.posicao p join public.vaga v on v.id = p.vaga_id
    where v.evento_id = (select id from e1) and p.estado = 'aberta'),
  40, 'B5 quarenta posições abertas');

select is(
  (select count(distinct q.message->>'vaga_id')::int from pgmq.q_despacho q
    where (q.message->>'vaga_id')::uuid in (select v.id from public.vaga v where v.evento_id = (select id from e1))),
  5, 'B6 uma mensagem de despacho para cada uma das cinco vagas');

select is(pg_temp.fila(), 5, 'B7 cinco mensagens na fila, nenhuma a mais');

-- ── C. A chave da escala ──────────────────────────────────────────────────────
select is(pg_temp.como(pg_temp.u(1), pg_temp.sql(pg_temp.casa(1), pg_temp.evento(), (select vagas from cinco), pg_temp.chave(1))),
  (select j from r1), 'C1 o reenvio com a mesma chave devolve a mesma escala');
select is(pg_temp.fila(), 5, 'C2 e não despacha de novo');

select set_config('frila.agora', '2030-03-10 15:00:00+00', true);   -- as cinco vagas já terminaram
select is(pg_temp.como(pg_temp.u(1), pg_temp.sql(pg_temp.casa(1), pg_temp.evento(), (select vagas from cinco), pg_temp.chave(1))),
  (select j from r1), 'C3 o reenvio depois de o horário passar devolve 200 com a mesma escala, e não horario_invalido');
select is(pg_temp.como(pg_temp.u(1), pg_temp.sql(pg_temp.casa(1), null, null, pg_temp.chave(1))),
  (select j from r1), 'C4 o reenvio não confere o corpo de novo');
select set_config('frila.agora', '2030-03-04 15:00:00+00', true);

select is((select count(*)::int from public.evento where estabelecimento_id = pg_temp.casa(1)), 1,
  'C5 os reenvios não gravaram outro evento');
select throws_ok(
  format($$ insert into public.evento (estabelecimento_id, nome, data, local, chave)
            values (%L, 'Outra escala', '2030-03-07', 'SHN Quadra 5', %L) $$, pg_temp.casa(1), pg_temp.chave(1)),
  '23505', null, 'C6 a unique (estabelecimento_id, chave) não deixa a mesma chave gravar duas escalas na casa');

-- ── D. Tudo ou nada ───────────────────────────────────────────────────────────
create temp table oito as select jsonb_agg(
  case when n = 7 then pg_temp.item('garçom', '2030-03-01 21:00:00+00', 2)   -- já passou
       else pg_temp.item('garçom', '2030-03-06 21:00:00+00', 2) end order by n) as vagas
  from generate_series(1, 8) n;

select is(pg_temp.recusa(pg_temp.u(2), pg_temp.sql(pg_temp.casa(2), pg_temp.evento(), (select vagas from oito), pg_temp.chave(2))),
  '422 horario_invalido vagas[6]', 'D1 a recusa do item 7 de 8 é a dele: 422 horario_invalido, details vagas[6]');
select is(
  row((select count(*) from public.evento where estabelecimento_id = pg_temp.casa(2)),
      (select count(*) from public.vaga where estabelecimento_id = pg_temp.casa(2)),
      (select count(*) from public.posicao p join public.vaga v on v.id = p.vaga_id where v.estabelecimento_id = pg_temp.casa(2)),
      pg_temp.fila())::text,
  '(0,0,0,5)', 'D2 nada fica: 0 evento, 0 vaga e 0 posição na casa, e a fila só com as 5 da escala B');

create temp table r2 as select pg_temp.como(pg_temp.u(2), pg_temp.sql(pg_temp.casa(2), pg_temp.evento(),
  (select jsonb_agg(pg_temp.item('garçom', '2030-03-06 21:00:00+00', 2)) from generate_series(1, 8)), pg_temp.chave(2))) as j;
select is(jsonb_array_length((select j->'vagas' from r2)), 8,
  'D3 a chave da escala recusada não ficou gasta: o envio corrigido grava as 8 vagas');

-- ── E. Recusas e o caminho em details ────────────────────────────────────────
select is(pg_temp.recusa_escala(pg_temp.evento(), jsonb_build_array(pg_temp.garcom('{"posicoes": 150}'))),
  '422 campo_invalido vagas[0].posicoes', 'E1 [150] sozinho: a soma não o conta, e o item é recusado nele mesmo');
select is(pg_temp.recusa_escala(pg_temp.evento(), jsonb_build_array(pg_temp.garcom('{"posicoes": 60}'), pg_temp.garcom('{"posicoes": 50}'))),
  '422 campo_invalido posicoes', 'E2 acima de 100 posições somadas: details posicoes');
select is(pg_temp.recusa_escala(pg_temp.evento(), '[]'),
  '422 campo_invalido vagas', 'E3 lista vazia: details vagas');
select is(pg_temp.recusa_escala(pg_temp.evento(), (select jsonb_agg(pg_temp.garcom()) from generate_series(1, 11))),
  '422 campo_invalido vagas', 'E4 mais de 10 itens: details vagas');
select is(pg_temp.recusa_escala(null, jsonb_build_array(pg_temp.garcom())),
  '422 campo_obrigatorio evento', 'E5 sem evento');
select is(pg_temp.recusa_escala(pg_temp.evento(), null),
  '422 campo_obrigatorio vagas', 'E6 sem vagas');
select is(pg_temp.recusa_escala(pg_temp.evento() - 'nome', jsonb_build_array(pg_temp.garcom())),
  '422 campo_obrigatorio evento.nome', 'E7 evento sem nome');
select is(pg_temp.recusa_escala(pg_temp.evento() || '{"nome": "ab"}', jsonb_build_array(pg_temp.garcom())),
  '422 campo_invalido evento.nome', 'E8 nome com menos de 3 caracteres');
select is(pg_temp.recusa_escala(pg_temp.evento() || '{"data": "06/03/2030"}', jsonb_build_array(pg_temp.garcom())),
  '422 campo_invalido evento.data', 'E9 data fora do formato de data');
select is(pg_temp.recusa_escala(pg_temp.evento() || '{"local": "  "}', jsonb_build_array(pg_temp.garcom())),
  '422 campo_obrigatorio evento.local', 'E10 local em branco');
select is(pg_temp.recusa_escala(pg_temp.evento() || '{"local": "Chame no 61 99876-5432"}', jsonb_build_array(pg_temp.garcom())),
  '422 campo_invalido evento.local', 'E11 local com contato: o filtro de termos de publicar_vaga');
select is(pg_temp.recusa_escala(pg_temp.evento() || '{"regiao_administrativa": "Atlântida"}', jsonb_build_array(pg_temp.garcom())),
  '422 campo_invalido evento.regiao_administrativa', 'E12 região fora do catálogo ativo');
select is(pg_temp.recusa_escala(pg_temp.evento() || '{"ponto": {"latitude": 120, "longitude": -47.9}}', jsonb_build_array(pg_temp.garcom())),
  '422 campo_invalido evento.ponto', 'E13 coordenada inválida');
select is(pg_temp.recusa_escala(pg_temp.evento() || '{"nome": "ab"}', jsonb_build_array(pg_temp.garcom('{"posicoes": 150}'))),
  '422 campo_invalido evento.nome', 'E14 o evento é conferido antes dos itens');
select is(pg_temp.recusa_escala(pg_temp.evento(), jsonb_build_array(pg_temp.garcom(), '876'::jsonb)),
  '422 campo_invalido vagas[1]', 'E15 item que não é objeto');
select is(pg_temp.recusa_escala(pg_temp.evento(), jsonb_build_array(pg_temp.garcom('{"funcao_id": "nao-e-uuid"}'))),
  '422 campo_invalido vagas[0].funcao_id', 'E16 uuid malformado no item');
select is(pg_temp.recusa_escala(pg_temp.evento(), jsonb_build_array(pg_temp.garcom('{"valor_centavos": "18000"}'))),
  '422 campo_invalido vagas[0].valor_centavos', 'E17 texto onde vai número');
select is(pg_temp.recusa_escala(pg_temp.evento(), jsonb_build_array(pg_temp.garcom(), pg_temp.garcom() - 'responsavel_local')),
  '422 campo_obrigatorio vagas[1].responsavel_local', 'E18 campo obrigatório ausente no segundo item');
select is(pg_temp.recusa_escala(pg_temp.evento(), jsonb_build_array(pg_temp.garcom('{"valor_centavos": 0}'))),
  '422 campo_invalido vagas[0].valor_centavos', 'E19 valor que a regra recusa');
select is(pg_temp.recusa_escala(pg_temp.evento(), jsonb_build_array(pg_temp.garcom(), pg_temp.garcom('{"fim_em": "2030-03-06T20:00:00Z"}'))),
  '422 horario_invalido vagas[1]', 'E20 horario_invalido aponta o item');
select is(pg_temp.recusa_escala(pg_temp.evento(), jsonb_build_array(
    pg_temp.garcom('{"modo": "selecao", "inicio_em": "2030-03-05T09:00:00Z", "fim_em": "2030-03-05T15:00:00Z"}'))),
  '422 selecao_sem_antecedencia vagas[0]', 'E21 RN24 por item');
select is(pg_temp.recusa_escala(pg_temp.evento(), jsonb_build_array(pg_temp.garcom('{"observacoes": "detalhes em www.exemplo.com.br"}'))),
  '422 campo_invalido vagas[0].observacoes', 'E22 filtro de termos no texto livre do item');
select is(pg_temp.recusa_escala(pg_temp.evento(), jsonb_build_array(pg_temp.garcom('{"modo": "talvez"}'))),
  '422 campo_invalido vagas[0].modo', 'E23 modo que não existe');
select lives_ok(format(
  $$ select pg_temp.como(%L, format('select public.publicar_vaga(%%L::uuid, (select id from public.funcao where nome = ''garçom''),
       ''2030-03-06 21:00:00+00''::timestamptz, ''2030-03-07 03:00:00+00''::timestamptz, ''SHN Quadra 5'',
       ''{"latitude": -15.784, "longitude": -47.889}''::jsonb, 18000::bigint, 150, true, false, false, ''Cerimonial'',
       ''urgencia''::public.modo_preenchimento, gen_random_uuid())', %L::uuid)) $$,
  pg_temp.u(1), pg_temp.casa(1)),
  'E24 publicar_vaga segue aceitando 150 posições: o teto de 100 é só do item da escala');

-- ── F. Conta de demonstração ──────────────────────────────────────────────────
create temp table r4 as select pg_temp.como(pg_temp.u(4), pg_temp.sql(pg_temp.casa(4), pg_temp.evento(),
  jsonb_build_array(pg_temp.garcom(), pg_temp.garcom()), pg_temp.chave(4))) as j;
select is(jsonb_array_length((select j->'vagas' from r4)), 2, 'F1 a conta de demonstração publica a escala');
select is(
  (select count(*)::int from pgmq.q_despacho q
    where (q.message->>'vaga_id')::uuid in (select v.id from public.vaga v where v.estabelecimento_id = pg_temp.casa(4))),
  0, 'F2 e não enfileira despacho: a revisão da Apple não avisa profissional real');

-- ── G. A republicação não leva o evento ──────────────────────────────────────
create temp table r5 as select pg_temp.como(pg_temp.u(1), format(
  $$ select public.republicar_vaga(%L::uuid, '2030-03-13 21:00:00+00'::timestamptz, '2030-03-14 03:00:00+00'::timestamptz, %L::uuid) $$,
  (select (j->'vagas'->0->>'vaga_id')::uuid from r1), pg_temp.chave(5))) as j;
select is((select v.evento_id from public.vaga v where v.id = (select (j->>'vaga_id')::uuid from r5)), null::uuid,
  'G1 republicar_vaga de uma vaga da escala publica vaga sem evento_id');

-- ── H. Quem lê o evento ───────────────────────────────────────────────────────
select is(pg_temp.como(pg_temp.u(1), format('select to_jsonb(count(*)) from public.evento where id = %L', (select id from e1))),
  '1'::jsonb, 'H1 membro da casa lê o evento');
select is(pg_temp.como(pg_temp.u(11), format('select to_jsonb(count(*)) from public.evento where id = %L', (select id from e1))),
  '0'::jsonb, 'H2 o profissional não lê o evento (o nome pode trazer nome de pessoa)');
select is(pg_temp.como(pg_temp.u(2), format('select to_jsonb(count(*)) from public.evento where id = %L', (select id from e1))),
  '0'::jsonb, 'H3 outra casa não lê o evento');

-- ── I. O evento segue as vagas ────────────────────────────────────────────────
-- Exclusão de conta e limpeza de 15 dias: a casa 5 publica um casamento com duas vagas, e a segunda
-- fecha antes da exclusão (a exclusão só mexe nas vagas publicadas e preenchidas).
create temp table r6 as select pg_temp.como(pg_temp.u(5), pg_temp.sql(pg_temp.casa(5),
  pg_temp.evento() || '{"nome": "Casamento de Ana e Rui"}', jsonb_build_array(pg_temp.garcom(), pg_temp.garcom()), pg_temp.chave(6))) as j;
create temp table e6 as select (j->>'evento_id')::uuid as id,
  (j->'vagas'->0->>'vaga_id')::uuid as vaga_a, (j->'vagas'->1->>'vaga_id')::uuid as vaga_b from r6;
update public.vaga set estado = 'encerrada' where id = (select vaga_b from e6);

select privado.excluir_conta(pg_temp.u(5));
select is(
  row((select responsavel_local from public.vaga where id = (select vaga_a from e6)),
      (select responsavel_local from public.vaga where id = (select vaga_b from e6)),
      (select nome from public.evento where id = (select id from e6)),
      (select local from public.evento where id = (select id from e6)))::text,
  '("[removido por exclusão de conta]",Cerimonial,"Casamento de Ana e Rui","SHN Quadra 5, Salão Nobre")',
  'I1 na exclusão de conta uma vaga perde o texto e a outra não: o evento guarda nome e local');

update public.usuario set anonimizado_em = privado.agora() - interval '16 days' where id = pg_temp.u(5);
select privado.limpar_contas_anonimizadas(15);
select is((select row(nome, local, data)::text from public.evento where id = (select id from e6)),
  '("[removido por exclusão de conta]","[removido por exclusão de conta]",2030-03-06)',
  'I2 na limpeza de 15 dias a última vaga perde texto e local, e o evento também, com o mesmo marcador; a data fica');

-- Expurgo de 5 anos da escala B: as cinco vagas e o evento.
select set_config('frila.agora', '2035-04-01 15:00:00+00', true);
select is(privado.anonimizar_contexto_das_vagas((select e.vagas from public.evento e where e.id = (select id from e1))),
  5, 'I3 aos 5 anos o expurgo anonimiza as cinco vagas da escala');
select is((select row(nome, local, data)::text from public.evento where id = (select id from e1)),
  '("Expurgado (LGPD)","Expurgado (LGPD)",2030-03-06)',
  'I4 e o evento sai junto, com o marcador do expurgo; a data fica');

select * from finish();
rollback;
