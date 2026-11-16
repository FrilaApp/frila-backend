-- 870_busca_cartao_sigilo_limite.sql
--
-- buscar_profissionais (B-027, contrato 0.2.85, frila-documentacao #259): o que NÃO é elegibilidade nem ordem
-- (isso é do 869). Aqui: o cartão (CD-B07, CD-S03), o sigilo das tabelas e dos helpers, o limite de 60 buscas
-- por hora (CD-B08), o cursor assinado (20 por página, 200 no máximo, outro dia, outros filtros, adulterado)
-- e a ordem dos erros.
--   Contratantes: C1 (membro da casa 1 e da casa 2), C2 (cursor), C3 (limite), C4 (não membro),
--                 CS (suspensa, membro), C5 (só chamadas inválidas: não pode gastar o limite)
--   Profissionais: P1 "Maria Souza" (barista, grade cobre terça 17/11 15h-19h), P2 "Rafaela" (barista,
--                 sem grade, a combinar, longe), LG (barista, linha de preferência SEM aceita_chamadas:
--                 o caso "existentes"), PN (sem linha de preferência) e 230 de garçom (cursor e limite).
-- Só dados sintéticos.
begin;
create extension if not exists pgtap with schema extensions;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);   -- segunda 12h em Brasília
select plan(115);

-- ── Quem já existia: ninguém aceita chamada direta antes dos meus dados ──────
select is((select count(*)::int from public.profissional_preferencia_chamada where aceita_chamadas), 0,
  'nenhuma linha que já existia tem aceita_chamadas ligado (opt-in, CD-P10)');
select col_not_null('public', 'profissional_preferencia_chamada', 'aceita_chamadas', 'aceita_chamadas é not null');
select col_default_is('public', 'profissional_preferencia_chamada', 'aceita_chamadas', 'false', 'aceita_chamadas nasce false');

-- ── Ajudantes ────────────────────────────────────────────────────────────────
-- Chama como a conta (null = sem login) e devolve o jsonb.
create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 case when conta is null then '{"role":"authenticated"}'
                      else json_build_object('sub', conta, 'role', 'authenticated')::text end);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;
-- O envelope inteiro da recusa ("status code details"), ou 'ok'. A chamada roda numa subtransação: o +1 do
-- contador de uma busca recusada se desfaz, como na produção.
create function pg_temp.r(conta uuid, sql text) returns text language plpgsql as $$
declare m text; d text;
begin
  perform pg_temp.como(conta, sql);
  return 'ok';
exception when others then
  get stacked diagnostics m = message_text, d = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return case when m ~ '^\s*\{' then concat_ws(' ', d::jsonb->>'status', m::jsonb->>'code', m::jsonb->>'details') else 'sqlstate:' || sqlstate end;
end $$;
-- O SQLSTATE de um comando como a conta ('ok' se passou).
create function pg_temp.estado_sql(papel text, sql text) returns text language plpgsql as $$
begin
  execute format('set local role %I', papel);
  execute sql;
  reset role;
  return 'ok';
exception when others then
  reset role;
  return sqlstate;
end $$;
-- A chamada da busca: casa 1 e garçom (padrão), mais os argumentos extras.
create function pg_temp.q(extra text default '') returns text language sql as $$
  select format($a$ select public.buscar_profissionais(estabelecimento_id => 'c8700000-0000-4000-8000-0000000000e1',
    funcao_id => %L %s) $a$, (select id from public.funcao where nome = 'garçom'), extra) $$;
create function pg_temp.q_barista(extra text default '') returns text language sql as $$
  select format($a$ select public.buscar_profissionais(estabelecimento_id => 'c8700000-0000-4000-8000-0000000000e1',
    funcao_id => %L %s) $a$, (select id from public.funcao where nome = 'barista'), extra) $$;
create function pg_temp.conta(n int) returns uuid language sql as $$
  select ('c8700000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
-- As chaves de um objeto, em ordem, separadas por vírgula.
create function pg_temp.chaves(j jsonb) returns text language sql as $$
  select string_agg(k, ',' order by k) from jsonb_object_keys(j) k $$;
-- Percorre todas as páginas de uma busca como a conta: quantos itens, quantos distintos, quantas páginas
-- e se terminou por proximo_cursor null.
create function pg_temp.paginar(conta uuid, extra text) returns jsonb language plpgsql as $$
declare cur text; pag jsonb; ids text[] := '{}'; n int := 0;
begin
  loop
    pag := pg_temp.como(conta, pg_temp.q(extra || case when cur is null then '' else ', cursor => ' || quote_literal(cur) end));
    n := n + 1;
    ids := ids || array(select x->>'id' from jsonb_array_elements(pag->'itens') x);
    cur := pag->>'proximo_cursor';
    exit when cur is null or n > 30;
  end loop;
  return jsonb_build_object('paginas', n, 'itens', cardinality(ids), 'distintos', (select count(distinct i) from unnest(ids) i),
                            'terminou_nulo', cur is null);
end $$;
-- Mexe no número de entregues do cursor sem refazer a assinatura (o teto de 200 não se fura).
create function pg_temp.forjar(c text) returns text language plpgsql as $$
declare t text := translate(split_part(c, '.', 1), '-_', '+/'); j text;
begin
  t := rpad(t, ((length(t) + 3) / 4) * 4, '=');
  j := regexp_replace(convert_from(decode(t, 'base64'), 'UTF8'), '"n": ?[0-9]+', '"n": 1');
  return translate(encode(convert_to(j, 'UTF8'), 'base64'), E'+/=\n', '-_') || '.' || split_part(c, '.', 2);
end $$;
-- Quantas buscas a conta já gastou na hora de 15h UTC.
create function pg_temp.gasto(conta uuid) returns int language sql as $$
  select coalesce((select total from privado.contador_busca where usuario_id = conta and hora = '2026-11-16 15:00:00+00'), 0) $$;

-- ── Dados ────────────────────────────────────────────────────────────────────
-- Contas: 1 a 6 contratantes; 101, 102, 103, 104 profissionais nomeados; 1001+ os de garçom.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
select pg_temp.conta(n), 'contratante', 'Contratante ' || n, '+556195558700' || n, 'c' || n || '@t870.test', '1985-01-01',
       case when n = 5 then 'suspensa' else 'ativa' end::public.estado_conta, '1.0', privado.agora()
  from generate_series(1, 6) n;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  (pg_temp.conta(101), 'profissional', 'Maria Souza',  '+5561987654321', 'maria.souza@t870.test', '1990-03-15', '1.0', privado.agora()),
  (pg_temp.conta(102), 'profissional', 'Rafaela',      '+5561987650102', 'rafaela@t870.test',      '1992-05-20', '1.0', privado.agora()),
  (pg_temp.conta(103), 'profissional', 'Legado Silva', '+5561987650103', 'legado@t870.test',       '1991-07-01', '1.0', privado.agora()),
  (pg_temp.conta(104), 'profissional', 'Novo Pereira', '+5561987650104', 'novo@t870.test',         '1993-09-09', '1.0', privado.agora());
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select pg_temp.conta(1000 + n), 'profissional', 'Garcom ' || n || ' Teste', '+55619' || lpad((70000000 + n)::text, 8, '0'),
       'g' || n || '@t870.test', '1990-01-01', '1.0', privado.agora()
  from generate_series(1, 230) n;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('c8700000-0000-4000-8000-0000000000e1', 'Casa 870 Plano', '87012345666', 'food_service', 'CLN 201',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('c8700000-0000-4000-8000-0000000000e2', 'Casa 870 Gama',  '87012345777', 'food_service', 'Quadra 1 Gama',
   'POINT(-48.0600 -16.0200)'::extensions.geography, 'Gama');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select pg_temp.conta(n), 'c8700000-0000-4000-8000-0000000000e1', 'administrador' from unnest(array[1, 2, 3, 5, 6]) n;
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values (pg_temp.conta(1), 'c8700000-0000-4000-8000-0000000000e2', 'administrador');

insert into public.profissional (usuario_id, ponto_base, atende_todo_df, apresentacao, aval_positivas, aval_total, turnos_realizados, taxa_comparecimento)
values (pg_temp.conta(101), 'POINT(-47.8822 -15.7800)'::extensions.geography, false, 'Apresentação da Maria', 8, 10, 12, 0.950),
       (pg_temp.conta(102), 'POINT(-48.0500 -15.8300)'::extensions.geography, true,  null, 0, 0, 0, null),
       (pg_temp.conta(103), 'POINT(-47.8822 -15.7800)'::extensions.geography, true,  null, 0, 0, 0, null),
       (pg_temp.conta(104), 'POINT(-47.8822 -15.7800)'::extensions.geography, true,  null, 0, 0, 0, null);
insert into public.profissional (usuario_id, ponto_base, atende_todo_df)
select pg_temp.conta(1000 + n), 'POINT(-47.8822 -15.7800)'::extensions.geography, true from generate_series(1, 230) n;

-- Serviços: P1 barista por hora (com extras, que não podem sair), P2 e LG barista a combinar, os 230 garçom por hora.
insert into public.profissional_funcao (profissional_id, funcao_id)
select p.id, (select id from public.funcao where nome = 'barista')
  from public.profissional p where p.usuario_id in (pg_temp.conta(101), pg_temp.conta(102), pg_temp.conta(103));
insert into public.profissional_funcao (profissional_id, funcao_id)
select p.id, (select id from public.funcao where nome = 'garçom')
  from public.profissional p where p.usuario_id >= pg_temp.conta(1001) and p.usuario_id::text like 'c8700000-%';
insert into public.profissional_servico (profissional_id, funcao_id, unidade, valor_centavos, extras, descricao_pacote)
select p.id, (select id from public.funcao where nome = 'barista'), 'hora', 5000, '{"segredo_extra": 1}'::jsonb, 'Pacote da Maria'
  from public.profissional p where p.usuario_id = pg_temp.conta(101);
insert into public.profissional_servico (profissional_id, funcao_id, unidade)
select p.id, (select id from public.funcao where nome = 'barista'), 'a_combinar'
  from public.profissional p where p.usuario_id in (pg_temp.conta(102), pg_temp.conta(103));
insert into public.profissional_servico (profissional_id, funcao_id, unidade, valor_centavos)
select p.id, (select id from public.funcao where nome = 'garçom'), 'hora', 4000
  from public.profissional p where p.usuario_id >= pg_temp.conta(1001) and p.usuario_id::text like 'c8700000-%';
insert into public.profissional_regiao (profissional_id, regiao_id)
select p.id, r from public.profissional p, unnest(array[1::smallint, 2::smallint]) r where p.usuario_id = pg_temp.conta(101);
-- A grade da Maria cobre terça 17/11 das 14h às 20h em Brasília.
insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
select p.id, 2, '14:00', '20:00' from public.profissional p where p.usuario_id = pg_temp.conta(101);

-- Preferências: LG sem aceita_chamadas (o caso das linhas que já existiam), PN sem linha nenhuma.
insert into public.profissional_preferencia_chamada (profissional_id)
select p.id from public.profissional p where p.usuario_id = pg_temp.conta(103);
insert into public.profissional_preferencia_chamada (profissional_id, aceita_chamadas, aceita_chamadas_em, versao_texto_busca)
select p.id, true, privado.agora(), 'v1' from public.profissional p
 where p.usuario_id in (pg_temp.conta(101), pg_temp.conta(102))
    or (p.usuario_id >= pg_temp.conta(1001) and p.usuario_id::text like 'c8700000-%');
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select u.id, 'tok-870-' || u.id::text, 'ios', '1.2.0' from public.usuario u
 where u.perfil = 'profissional' and u.id::text like 'c8700000-%';
update privado.recurso set ligado = true where chave in ('chamada_direta', 'busca_profissionais');
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;

-- ── aceita_chamadas nasce FALSE ───────────────────────────────────────────────
select is((select aceita_chamadas from public.profissional_preferencia_chamada pc join public.profissional p on p.id = pc.profissional_id
            where p.usuario_id = pg_temp.conta(103)), false,
  'a linha criada sem o campo (como as que já existiam) fica com aceita_chamadas false');
select is(pg_temp.como(pg_temp.conta(104), $$ select public.definir_preferencia_chamadas(antecedencia_minima_h => 24) $$) ->> 'aceita_chamadas',
  'false', 'quem define outra preferência pela primeira vez não liga aceita_chamadas');
select is((select aceita_chamadas from public.profissional_preferencia_chamada pc join public.profissional p on p.id = pc.profissional_id
            where p.usuario_id = pg_temp.conta(104)), false, 'e a linha gravada fica false');
select is(jsonb_array_length(pg_temp.como(pg_temp.conta(1), pg_temp.q_barista()) -> 'itens'), 2,
  'a busca de barista traz só P1 e P2: o profissional sem aceita_chamadas (LG) não aparece');

-- ── Cartão (CD-B07, CD-S03) ───────────────────────────────────────────────────
create temp table guarda (k text primary key, v jsonb);
grant all on guarda to public;
insert into guarda select 'sem_horario', pg_temp.como(pg_temp.conta(1), pg_temp.q_barista());
insert into guarda select 'com_horario', pg_temp.como(pg_temp.conta(1),
  pg_temp.q_barista($$, inicio_em => '2026-11-17 18:00:00+00', fim_em => '2026-11-17 22:00:00+00'$$));
create function pg_temp.cartao(busca text, quem int) returns jsonb language sql as $$
  select x from guarda g, jsonb_array_elements(g.v -> 'itens') x
   where g.k = busca and x ->> 'id' = (select p.id::text from public.profissional p where p.usuario_id = pg_temp.conta(quem)) $$;

select is(pg_temp.chaves(pg_temp.cartao('sem_horario', 101)),
  'atende_todo_df,distancia_faixa,id,nome,regioes,reputacao,servico',
  'cartão sem horário: o conjunto EXATO de chaves, sem disponivel_no_horario');
select is(pg_temp.chaves(pg_temp.cartao('com_horario', 101)),
  'atende_todo_df,disponivel_no_horario,distancia_faixa,id,nome,regioes,reputacao,servico',
  'cartão com horário: as mesmas chaves mais disponivel_no_horario');
select is(pg_temp.cartao('sem_horario', 101) ->> 'nome', 'Maria S.', 'nome: primeiro nome e inicial do sobrenome');
select is(pg_temp.cartao('sem_horario', 102) ->> 'nome', 'Rafaela', 'nome de uma palavra só fica inteiro, sem ponto');
select is(pg_temp.cartao('sem_horario', 101) ->> 'id', (select p.id::text from public.profissional p where p.usuario_id = pg_temp.conta(101)),
  'id é o do profissional (o mesmo de chamar_profissional), não o da conta');
select ok(pg_temp.cartao('sem_horario', 101)::text !~* 'souza',
  'nenhum valor traz o sobrenome completo');
select ok(pg_temp.cartao('sem_horario', 101)::text !~ '61987654321|987654321|\+55',
  'nenhum valor traz o telefone');
select ok(pg_temp.cartao('sem_horario', 101)::text !~* 'maria\.souza|@t870',
  'nenhum valor traz o e-mail');
select ok(pg_temp.cartao('sem_horario', 101)::text !~ '1990|1990-03-15',
  'nenhum valor traz a data de nascimento');
select ok(pg_temp.cartao('sem_horario', 101)::text !~ '47\.88|15\.78|POINT',
  'nenhum valor traz o ponto base (coordenadas)');
select ok(pg_temp.cartao('sem_horario', 101)::text !~* 'telefone|email|e-mail|nascimento|ponto_base|usuario_id|foto|disponibilidade|apresentacao',
  'nenhuma chave de contato, nascimento, ponto base, grade, foto ou apresentação');
select ok(not (pg_temp.cartao('sem_horario', 101) -> 'servico' ?| array['profissional_id', 'extras', 'atualizado_em']),
  'servico sem profissional_id, extras nem atualizado_em');
select ok(pg_temp.cartao('sem_horario', 101)::text !~ 'segredo_extra',
  'o conteúdo de extras não vaza');
select is(pg_temp.cartao('sem_horario', 101) -> 'servico' ->> 'unidade', 'hora', 'servico traz a unidade');
select is((pg_temp.cartao('sem_horario', 101) -> 'servico' ->> 'valor_centavos')::int, 5000, 'servico traz o preço');
select is(pg_temp.cartao('sem_horario', 101) -> 'servico' -> 'funcao' ->> 'nome', 'barista', 'servico traz a função buscada');
select is(pg_temp.cartao('sem_horario', 102) -> 'servico' ->> 'unidade', 'a_combinar',
  'a_combinar também é serviço (CD-P09)');
select is(pg_temp.cartao('sem_horario', 101) ->> 'distancia_faixa', 'ate_5_km', 'P1 mora a ~1,5 km da casa: ate_5_km');
select is(pg_temp.cartao('sem_horario', 102) ->> 'distancia_faixa', 'mais_de_15_km', 'P2 mora a ~18 km da casa: mais_de_15_km');
select is((pg_temp.cartao('sem_horario', 101) -> 'regioes' -> 0 ->> 'id')::int, 1, 'regioes traz as RAs marcadas');
select is(jsonb_array_length(pg_temp.cartao('sem_horario', 101) -> 'regioes'), 2, 'as duas RAs de P1');
select is((pg_temp.cartao('sem_horario', 101) -> 'reputacao' ->> 'total')::int, 10, 'reputacao com o denominador (RN08)');
select is(pg_temp.cartao('sem_horario', 102) ->> 'atende_todo_df', 'true', 'atende_todo_df');
select is(pg_temp.cartao('com_horario', 101) ->> 'disponivel_no_horario', 'true', 'P1: a grade cobre terça 15h-19h');
select is(pg_temp.cartao('com_horario', 102) ->> 'disponivel_no_horario', 'false', 'P2 sem grade: false, mas continua na lista');
select is((select string_agg(x ->> 'nome', ',' order by o) from guarda g, jsonb_array_elements(g.v -> 'itens') with ordinality t(x, o)
            where g.k = 'com_horario'), 'Maria S.,Rafaela', 'com horário, quem a grade cobre vem antes');

-- ── Sigilo ───────────────────────────────────────────────────────────────────
select is((select array_agg(column_name::text order by ordinal_position) from information_schema.columns
            where table_schema = 'privado' and table_name = 'contador_busca'), array['usuario_id', 'hora', 'total'],
  'o contador guarda só usuario_id, hora e total: nenhum filtro (CD-B09)');
select is((select array_agg(column_name::text) from information_schema.columns
            where table_schema = 'privado' and table_name = 'chave_cursor_busca'), array['chave'], 'a chave do cursor é uma coluna só');
select is((select count(*)::int from privado.chave_cursor_busca), 1, 'uma linha de chave');
select is((select length(chave) from privado.chave_cursor_busca), 32, 'chave aleatória de 32 bytes (gerada pela migração)');
select ok(not exists (select 1 from privado.contador_busca c
                       where c::text like '%c8700000-0000-4000-8000-0000000000e1%'
                          or c::text like '%' || (select id::text from public.funcao where nome = 'barista') || '%'),
  'nenhuma linha do contador contém a casa nem a função buscada');
select is(pg_temp.estado_sql('authenticated', 'select * from privado.contador_busca'), '42501', 'authenticated não lê privado.contador_busca');
select is(pg_temp.estado_sql('authenticated', 'select * from privado.chave_cursor_busca'), '42501', 'authenticated não lê a tabela da chave');
select is(pg_temp.estado_sql('anon', 'select * from privado.contador_busca'), '42501', 'anon não lê privado.contador_busca');
select is(pg_temp.estado_sql('anon', 'select * from privado.chave_cursor_busca'), '42501', 'anon não lê a tabela da chave');
select is(pg_temp.estado_sql('authenticated', $$ insert into privado.contador_busca values (gen_random_uuid(), now(), 0) $$), '42501',
  'authenticated não zera nem cria contador');
select is(pg_temp.estado_sql('authenticated', 'update privado.contador_busca set total = 0'), '42501', 'authenticated não zera o contador');
select is(pg_temp.estado_sql('authenticated', 'update privado.chave_cursor_busca set chave = chave'), '42501', 'authenticated não troca a chave');
select ok(not exists (select 1 from unnest(array['anon', 'authenticated']) r, unnest(array['select', 'insert', 'update', 'delete']) p,
                              unnest(array['privado.contador_busca', 'privado.chave_cursor_busca']) t
                       where has_table_privilege(r, t, p)), 'nenhum privilégio de tabela a anon nem authenticated nas duas tabelas');
select ok(has_function_privilege('authenticated', 'public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int)', 'execute'),
  'authenticated executa buscar_profissionais');
select ok(not has_function_privilege('anon', 'public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int)', 'execute'),
  'anon não executa buscar_profissionais');
select is((select count(*)::int from pg_proc p, aclexplode(p.proacl) a
            where p.oid = 'public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int)'::regprocedure
              and a.privilege_type = 'EXECUTE' and a.grantee = 0), 0, 'PUBLIC não executa buscar_profissionais');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'privado'
              and p.proname in ('profissionais_na_busca', 'cartao_profissional', 'grade_cobre', 'pendencias_para_busca', 'limpar_contador_busca')),
  5, 'os cinco helpers estão no privado (nenhum no public)');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'privado'
              and p.proname in ('profissionais_na_busca', 'cartao_profissional', 'grade_cobre', 'pendencias_para_busca', 'limpar_contador_busca')
              and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0,
  'nenhum helper da busca é executável por anon nem por authenticated');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('profissionais_na_busca', 'cartao_profissional', 'grade_cobre', 'pendencias_para_busca', 'limpar_contador_busca')), 0,
  'nenhum helper da busca vazou para o schema public');
select ok(pg_temp.como(pg_temp.conta(2), pg_temp.q('')) ::text !~ encode((select chave from privado.chave_cursor_busca), 'hex'),
  'a resposta não traz a chave do cursor');

-- ── Cursor: 20 por página, até 200, assinado ─────────────────────────────────
insert into guarda select 'pag1', pg_temp.como(pg_temp.conta(2), pg_temp.q(''));
select is(jsonb_array_length((select v from guarda where k = 'pag1') -> 'itens'), 20, 'a primeira página traz 20');
select ok((select v from guarda where k = 'pag1') ->> 'proximo_cursor' is not null, 'e um proximo_cursor');
insert into guarda select 'pag2', pg_temp.como(pg_temp.conta(2), pg_temp.q(format(', cursor => %L', (select v ->> 'proximo_cursor' from guarda where k = 'pag1'))));
select is(jsonb_array_length((select v from guarda where k = 'pag2') -> 'itens'), 20, 'a segunda página também traz 20');
select is((select count(*)::int from jsonb_array_elements((select v from guarda where k = 'pag1') -> 'itens') a
             join jsonb_array_elements((select v from guarda where k = 'pag2') -> 'itens') b on a ->> 'id' = b ->> 'id'), 0,
  'as duas páginas não repetem ninguém');
select is(jsonb_array_length(pg_temp.como(pg_temp.conta(2), pg_temp.q(', limite => 5')) -> 'itens'), 5, 'limite => 5 devolve 5');
select is(pg_temp.paginar(pg_temp.conta(2), ''), '{"paginas": 10, "itens": 200, "distintos": 200, "terminou_nulo": true}'::jsonb,
  '230 elegíveis: 10 páginas, 200 entregues sem repetir, e a última sem proximo_cursor (teto de 200)');

-- cursor adulterado, de outra busca, de outro dia
insert into guarda select 'cur', to_jsonb(pg_temp.como(pg_temp.conta(2), pg_temp.q('')) ->> 'proximo_cursor');
select is(pg_temp.r(pg_temp.conta(2), pg_temp.q(format(', cursor => %L', (select v #>> '{}' from guarda where k = 'cur')))), 'ok',
  'controle: o cursor intacto passa');
select is(pg_temp.r(pg_temp.conta(2), pg_temp.q(format(', cursor => %L',
    left((select v #>> '{}' from guarda where k = 'cur'), -1) || case right((select v #>> '{}' from guarda where k = 'cur'), 1) when '0' then '1' else '0' end))),
  '422 cursor_invalido', 'assinatura adulterada: 422 cursor_invalido');
select is(pg_temp.r(pg_temp.conta(2), pg_temp.q(format(', cursor => %L', 'Z' || substr((select v #>> '{}' from guarda where k = 'cur'), 2)))),
  '422 cursor_invalido', 'conteúdo adulterado: 422 cursor_invalido');
select isnt(pg_temp.forjar((select v #>> '{}' from guarda where k = 'cur')), (select v #>> '{}' from guarda where k = 'cur'),
  'controle: o cursor forjado difere do original');
select is(pg_temp.r(pg_temp.conta(2), pg_temp.q(format(', cursor => %L', pg_temp.forjar((select v #>> '{}' from guarda where k = 'cur'))))),
  '422 cursor_invalido', 'entregues reescrito com a assinatura antiga: 422 (o teto de 200 não se fura)');
select is(pg_temp.r(pg_temp.conta(2), pg_temp.q(', cursor => ''abc''')), '422 cursor_invalido', 'cursor lixo: 422 cursor_invalido');
select is(pg_temp.r(pg_temp.conta(2), pg_temp.q(', cursor => ''''')), '422 cursor_invalido', 'cursor vazio: 422 cursor_invalido');
select is(pg_temp.r(pg_temp.conta(2), replace(pg_temp.q(format(', cursor => %L', (select v #>> '{}' from guarda where k = 'cur'))),
                    (select id::text from public.funcao where nome = 'garçom'), (select id::text from public.funcao where nome = 'barista'))),
  '422 cursor_invalido', 'cursor de outra função: 422 cursor_invalido');
select is(pg_temp.r(pg_temp.conta(2), pg_temp.q(format(', regiao_id => 2, cursor => %L', (select v #>> '{}' from guarda where k = 'cur')))),
  '422 cursor_invalido', 'cursor de outra região: 422 cursor_invalido');
select is(pg_temp.r(pg_temp.conta(2), pg_temp.q(format($$, inicio_em => '2026-11-17 18:00:00+00', fim_em => '2026-11-17 22:00:00+00', cursor => %L$$,
                                                      (select v #>> '{}' from guarda where k = 'cur')))),
  '422 cursor_invalido', 'cursor de outro horário: 422 cursor_invalido');
select is(pg_temp.r(pg_temp.conta(1), pg_temp.q(format(', cursor => %L', (select v #>> '{}' from guarda where k = 'cur')))),
  '422 cursor_invalido', 'cursor de outra conta: 422 cursor_invalido');
-- O dia do cursor é o de Brasília. O cursor nasce às 23h50 de segunda (perto da virada, para o tempo de vida
-- do cursor não interferir) e é testado às 23h59 de segunda e às 00h00 de terça.
select set_config('frila.agora', '2026-11-17 02:50:00+00', true);
insert into guarda select 'cur_noite', to_jsonb(pg_temp.como(pg_temp.conta(2), pg_temp.q('')) ->> 'proximo_cursor');
select set_config('frila.agora', '2026-11-17 02:59:00+00', true);   -- ainda segunda 23h59 em Brasília
select is(pg_temp.r(pg_temp.conta(2), pg_temp.q(format(', cursor => %L', (select v #>> '{}' from guarda where k = 'cur_noite')))), 'ok',
  'o dia é o de Brasília: às 23h59 de segunda o cursor de segunda ainda vale');
select set_config('frila.agora', '2026-11-17 03:00:00+00', true);   -- terça 00h00 em Brasília
select is(pg_temp.r(pg_temp.conta(2), pg_temp.q(format(', cursor => %L', (select v #>> '{}' from guarda where k = 'cur_noite')))),
  '422 cursor_invalido', 'cursor de outro dia (terça, 00h em Brasília): 422 cursor_invalido');
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);

-- páginas com cursor não contam
create temp table antes as select pg_temp.gasto(pg_temp.conta(2)) as n;
select ok(pg_temp.como(pg_temp.conta(2), pg_temp.q(format(', cursor => %L', (select v #>> '{}' from guarda where k = 'cur')))) is not null, 'página com cursor (1)');
select ok(pg_temp.como(pg_temp.conta(2), pg_temp.q(format(', cursor => %L', (select v ->> 'proximo_cursor' from guarda where k = 'pag1')))) is not null, 'página com cursor (2)');
select is(pg_temp.gasto(pg_temp.conta(2)), (select n from antes), 'duas páginas com cursor não mexem no contador');

-- ── Limite: 60 buscas por hora (CD-B08) ──────────────────────────────────────
-- C3: a 1ª busca guarda um cursor; mais 59 primeiras páginas fecham 60; a 61ª é 429.
insert into guarda select 'cur3', to_jsonb(pg_temp.como(pg_temp.conta(3), pg_temp.q('')) ->> 'proximo_cursor');
select is(pg_temp.gasto(pg_temp.conta(3)), 1, 'a primeira busca gasta 1');
create function pg_temp.rajada(conta uuid, n int) returns int language plpgsql as $$
declare ok int := 0;
begin
  for i in 1..n loop perform pg_temp.como(conta, pg_temp.q(', limite => 1')); ok := ok + 1; end loop;
  return ok;
end $$;
select is(pg_temp.rajada(pg_temp.conta(3), 59), 59, 'as outras 59 primeiras páginas passam (60 na hora)');
select is(pg_temp.gasto(pg_temp.conta(3)), 60, 'o contador chegou a 60');
select is(pg_temp.r(pg_temp.conta(3), pg_temp.q()), '429 limite_excedido', 'a 61ª busca da hora: 429 limite_excedido');
select is(pg_temp.gasto(pg_temp.conta(3)), 60, 'a recusa não passa de 60 (o +1 se desfaz)');
select is(pg_temp.r(pg_temp.conta(3), pg_temp.q_barista()), '429 limite_excedido', 'o limite vale para qualquer filtro');
select is(pg_temp.r(pg_temp.conta(3), pg_temp.q(format(', cursor => %L', (select v #>> '{}' from guarda where k = 'cur3')))), 'ok',
  'com 60 gastas, a página com cursor ainda passa (não conta)');
select is(pg_temp.gasto(pg_temp.conta(3)), 60, 'e não mexeu no contador');
select is(pg_temp.r(pg_temp.conta(3), pg_temp.q(', cursor => ''lixo''')), '422 cursor_invalido',
  'com o limite estourado, cursor inválido é 422 (vem antes do 429)');
select is(pg_temp.r(pg_temp.conta(3), pg_temp.q(', limite => 99')), '422 campo_invalido limite',
  'com o limite estourado, filtro inválido é 422 (vem antes do 429)');
select is(pg_temp.r(pg_temp.conta(2), pg_temp.q('')), 'ok', 'o limite é por conta: C2 segue buscando');
select set_config('frila.agora', '2026-11-16 16:00:00+00', true);
select is(pg_temp.r(pg_temp.conta(3), pg_temp.q()), 'ok', 'na hora seguinte o contador é outro e a busca passa');
select is((select array_agg(total order by hora) from privado.contador_busca where usuario_id = pg_temp.conta(3)), array[60, 1],
  'duas linhas do contador: 60 na hora que acabou e 1 na nova');
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);
select is((select count(*)::int from privado.contador_busca where usuario_id = pg_temp.conta(3)), 2, 'só usuario_id, hora e total: uma linha por hora');

-- ── Erros, na ordem ──────────────────────────────────────────────────────────
update privado.recurso set ligado = false where chave = 'busca_profissionais';
select is(pg_temp.r(null, pg_temp.q()), '401 nao_autenticado', '1) sem login: 401, antes de tudo');
select is(pg_temp.r(pg_temp.conta(1), pg_temp.q()), '403 sem_permissao recurso_desligado', '2) recurso desligado: 403 recurso_desligado');
select is(pg_temp.r(pg_temp.conta(1001), pg_temp.q()), '403 sem_permissao recurso_desligado', '2) o recurso vem antes do perfil');
update privado.recurso set ligado = true where chave = 'busca_profissionais';
update privado.recurso set ligado = false where chave = 'chamada_direta';
select is(pg_temp.r(pg_temp.conta(1), pg_temp.q()), '403 sem_permissao recurso_desligado',
  '2) a busca não vale com a chamada direta desligada');
update privado.recurso set ligado = true where chave = 'chamada_direta';
select is(pg_temp.r(pg_temp.conta(1001), pg_temp.q()), '403 sem_permissao', '3) profissional não busca: 403');
select is(pg_temp.r(pg_temp.conta(5), pg_temp.q()), '403 sem_permissao conta_suspensa', '4) conta suspensa: 403 conta_suspensa');
select is(pg_temp.r(pg_temp.conta(5), 'select public.buscar_profissionais()'), '403 sem_permissao conta_suspensa',
  '4) a suspensão vem antes dos campos obrigatórios');
select is(pg_temp.r(pg_temp.conta(1), 'select public.buscar_profissionais()'), '422 campo_obrigatorio estabelecimento_id',
  '5) sem nada: 422 campo_obrigatorio, estabelecimento_id primeiro');
select is(pg_temp.r(pg_temp.conta(1), $$ select public.buscar_profissionais(estabelecimento_id => 'c8700000-0000-4000-8000-0000000000e1') $$),
  '422 campo_obrigatorio funcao_id', '5) sem funcao_id: 422 campo_obrigatorio');
select is(pg_temp.r(pg_temp.conta(4), $$ select public.buscar_profissionais(funcao_id => gen_random_uuid()) $$),
  '422 campo_obrigatorio estabelecimento_id', '5) os obrigatórios vêm antes do 403 de quem não é membro');
select is(pg_temp.r(pg_temp.conta(4), pg_temp.q()), '403 sem_permissao', '6) contratante que não é da casa: 403');
select is(pg_temp.r(pg_temp.conta(4), replace(pg_temp.q(), 'c8700000-0000-4000-8000-0000000000e1', gen_random_uuid()::text)), '403 sem_permissao',
  '6) casa que não existe: o mesmo 403 (não revela quais casas existem)');
select is(pg_temp.r(pg_temp.conta(4), pg_temp.q(', limite => 99')), '403 sem_permissao', '6) o 403 vem antes dos 422 de filtro inválido');
select is(pg_temp.r(pg_temp.conta(5 + 1), $$ select public.buscar_profissionais(estabelecimento_id => 'c8700000-0000-4000-8000-0000000000e1', funcao_id => gen_random_uuid()) $$),
  '422 campo_invalido funcao_id', '7) função que não existe: 422 campo_invalido');
select is(pg_temp.r(pg_temp.conta(6), pg_temp.q(', regiao_id => 999')), '422 campo_invalido regiao_id', '7) região que não existe: 422');
select is(pg_temp.r(pg_temp.conta(6), pg_temp.q($$, inicio_em => '2026-11-17 18:00:00+00'$$)), '422 campo_invalido fim_em', '7) início sem fim: 422');
select is(pg_temp.r(pg_temp.conta(6), pg_temp.q($$, fim_em => '2026-11-17 22:00:00+00'$$)), '422 campo_invalido inicio_em', '7) fim sem início: 422');
select is(pg_temp.r(pg_temp.conta(6), pg_temp.q($$, inicio_em => '2026-11-17 22:00:00+00', fim_em => '2026-11-17 22:00:00+00'$$)),
  '422 campo_invalido fim_em', '7) fim igual ao início: 422');
select is(pg_temp.r(pg_temp.conta(6), pg_temp.q($$, inicio_em => '2026-11-16 14:00:00+00', fim_em => '2026-11-16 18:00:00+00'$$)),
  '422 campo_invalido inicio_em', '7) início no passado: 422');
select is(pg_temp.r(pg_temp.conta(6), pg_temp.q(', limite => 0')), '422 campo_invalido limite', '7) limite 0: 422');
select is(pg_temp.r(pg_temp.conta(6), pg_temp.q(', limite => 21')), '422 campo_invalido limite', '7) limite 21: 422');
select is(pg_temp.r(pg_temp.conta(6), pg_temp.q(', limite => 99, cursor => ''lixo''')), '422 campo_invalido limite',
  '8) filtro inválido vem antes do cursor inválido');
update public.regiao_administrativa set ativo = false where nome = 'Gama';
select is(pg_temp.r(pg_temp.conta(1), replace(pg_temp.q(), 'c8700000-0000-4000-8000-0000000000e1', 'c8700000-0000-4000-8000-0000000000e2')),
  '422 campo_obrigatorio regiao_id', 'casa sem região válida e sem regiao_id: 422 campo_obrigatorio');
select is(pg_temp.r(pg_temp.conta(1), replace(pg_temp.q(', regiao_id => 1'), 'c8700000-0000-4000-8000-0000000000e1', 'c8700000-0000-4000-8000-0000000000e2')),
  'ok', 'a mesma casa, com regiao_id: passa');
select is((select count(*)::int from privado.contador_busca where usuario_id = pg_temp.conta(6)), 0,
  'chamadas inválidas (C5) não gastaram o limite: nenhuma linha no contador');
select is((select count(*)::int from privado.contador_busca where usuario_id = pg_temp.conta(4) or usuario_id = pg_temp.conta(5)), 0,
  'quem foi barrado (não membro, suspensa) também não gastou');

select * from finish();
rollback;
