-- 879_vaga_publica.sql
--
-- A vaga pelo link, sem login (migração 20261117070000, contrato 0.2.100, web B5).
--   A  a função: security definer, search_path vazio; anon e authenticated executam, PUBLIC não
--   B  a vaga normal: anon e authenticated leem com exatamente as chaves de VagaPublica, os mesmos valores
--      para os dois; nada do estabelecimento, do endereço, do ponto, do texto livre ou de quem publicou
--   C  os 404: vaga direta, vaga oculta, vaga de conta de demonstração (também para quem é de
--      demonstração), id que não é uuid (nunca 22P02), texto vazio, nulo e vaga inexistente; todos com
--      o mesmo envelope (message e detail) da vaga inexistente
--   D  200 com o estado real: cancelada e preenchida aparecem; região inativa no catálogo = null
--   E  RLS e grant: anon não lê public.vaga direto
-- O vermelho (sem o filtro de demonstração e sem o de vaga direta, este arquivo falha) é provado no
-- roteiro do despacho B-037, trocando o corpo da função e rodando este arquivo.
-- Desde a 0.2.101 a casa 21 é de CPF (11 dígitos): o nome dela não sai, e o 'nada da casa' segue valendo.
-- O nome de casa com CNPJ é o 881.
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-17 12:00:00+00', true);
select plan(36);

-- Chama como anon (conta nula) ou como a conta dada.
create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  if conta is null then
    execute 'set local role anon';
    execute 'set local request.jwt.claims = ''{"role":"anon"}''';
  else
    execute 'set local role authenticated';
    execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  end if;
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;
-- O envelope inteiro da recusa (sqlstate, message e detail), ou 'ok'.
create function pg_temp.recusa(conta uuid, sql text) returns text language plpgsql as $$
declare e text; m text; d text;
begin
  perform pg_temp.como(conta, sql);
  return 'ok';
exception when others then
  get stacked diagnostics e = returned_sqlstate, m = message_text, d = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return concat_ws(' | ', e, m, d);
end $$;
create function pg_temp.vp(conta uuid, id text) returns jsonb language sql as $$
  select pg_temp.como(conta, format('select public.vaga_publica(%L)', id)) $$;
create function pg_temp.vp_recusa(conta uuid, id text) returns text language sql as $$
  select pg_temp.recusa(conta, format('select public.vaga_publica(%L)', id)) $$;
create function pg_temp.id(n int) returns uuid language sql immutable as $$
  select ('c8790000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;

-- ── Contas, casas e vagas ─────────────────────────────────────────────────────
-- 1 contratante real, 2 contratante de demonstração, 3 profissional real, 4 profissional de demonstração.
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data,
                        raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', pg_temp.id(n), 'authenticated', 'authenticated',
       'conta' || n || '.879@teste.invalid', '2026-11-01 12:00:00+00', '{"provider":"email"}', '{}',
       '2026-11-01 12:00:00+00', '2026-11-01 12:00:00+00', false, false
  from generate_series(1, 4) n;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
values (pg_temp.id(1), 'contratante',  'Contratante 879',      '+5561987900001', 'conta1.879@teste.invalid', '1980-01-01', '2026-09-22', '2026-11-01 12:00:00+00', false),
       (pg_temp.id(2), 'contratante',  'Contratante Demo 879', '+5561987900002', 'conta2.879@teste.invalid', '1980-01-01', '2026-09-22', '2026-11-01 12:00:00+00', true),
       (pg_temp.id(3), 'profissional', 'Profissional 879',     '+5561987900003', 'conta3.879@teste.invalid', '1995-01-01', '2026-09-22', '2026-11-01 12:00:00+00', false),
       (pg_temp.id(4), 'profissional', 'Profissional Demo 879','+5561987900004', 'conta4.879@teste.invalid', '1995-01-01', '2026-09-22', '2026-11-01 12:00:00+00', true);
insert into public.profissional (id, usuario_id, ponto_base)
values (pg_temp.id(13), pg_temp.id(3), 'POINT(-47.8820 -15.7940)'::extensions.geography),
       (pg_temp.id(14), pg_temp.id(4), 'POINT(-47.8820 -15.7940)'::extensions.geography);
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values (pg_temp.id(21), 'CasaSigilosa879', '94827987001', 'food_service', 'EnderecoSigiloso879',
        'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto'),
       (pg_temp.id(22), 'CasaDemo879', '94827987000188', 'food_service', 'EnderecoDemo879',
        'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values (pg_temp.id(1), pg_temp.id(21), 'administrador'),
       (pg_temp.id(2), pg_temp.id(22), 'administrador');

-- 31 normal · 32 direta · 33 oculta · 34 demonstração · 35 cancelada · 36 preenchida
-- 37 outra vaga normal · 38 região do catálogo inativa (Taguatinga, desligada só neste teste; a FK
-- vaga.regiao_administrativa → catálogo impede nome fora dele)
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos,
                         posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
                         traje, observacoes, participa_rateio, modo, estado, chave_cliente, publicado_por,
                         publicado_em, regiao_administrativa, origem)
select pg_temp.id(n), case when n = 34 then pg_temp.id(22) else pg_temp.id(21) end,
       (select id from public.funcao where nome = 'garçom'),
       '2026-11-20 21:00:00+00', '2026-11-21 02:00:00+00', 'LocalSigiloso879',
       'POINT(-47.88 -15.79)'::extensions.geography, 18000, 2, true, false, true, 'ResponsavelSigiloso879',
       'TrajeSigiloso879', 'ObservacaoSigilosa879', true, 'urgencia',
       (case n when 35 then 'cancelada' when 36 then 'preenchida' else 'publicada' end)::public.estado_vaga,
       gen_random_uuid(), case when n = 34 then pg_temp.id(2) else pg_temp.id(1) end,
       '2026-11-16 15:00:00+00',
       case n when 38 then 'Taguatinga' else 'Plano Piloto' end,
       case when n = 32 then 'chamada_direta' else 'publicacao' end
  from generate_series(31, 38) n;
insert into public.posicao (vaga_id, inicio_em, fim_em, estado)
select g.id, g.inicio_em, g.fim_em,
       (case when g.estado = 'cancelada' then 'cancelada' else 'aberta' end)::public.estado_posicao
  from public.vaga g, generate_series(1, 2)
 where g.id between pg_temp.id(31) and pg_temp.id(38);
insert into public.ocorrencia (id, tipo, autor_id, motivo, criada_em)
values (pg_temp.id(90), 'suporte', pg_temp.id(1), 'Ocultação sintética 879', '2026-11-16 16:00:00+00');
insert into privado.vaga_ocultada (vaga_id, ocorrencia_id, oculta_em)
values (pg_temp.id(33), pg_temp.id(90), '2026-11-16 16:05:00+00');
update public.regiao_administrativa set ativo = false where nome = 'Taguatinga';

-- ── A: a função ───────────────────────────────────────────────────────────────
select ok((select p.prosecdef and p.proconfig @> array['search_path=""']
             from pg_proc p where p.oid = 'public.vaga_publica(text)'::regprocedure),
          'A: vaga_publica(text) é security definer e com search_path vazio');
select ok(has_function_privilege('anon', 'public.vaga_publica(text)', 'execute'), 'A: anon executa vaga_publica');
select ok(has_function_privilege('authenticated', 'public.vaga_publica(text)', 'execute'), 'A: authenticated executa vaga_publica');
select is((select count(*)::int from information_schema.routine_privileges
            where specific_schema = 'public' and routine_name = 'vaga_publica' and grantee = 'PUBLIC'),
          0, 'A: PUBLIC não tem grant em vaga_publica');

-- ── B: a vaga normal ──────────────────────────────────────────────────────────
create temp table r as select pg_temp.vp(null, pg_temp.id(31)::text) as anon,
                              pg_temp.vp(pg_temp.id(3), pg_temp.id(31)::text) as prof,
                              pg_temp.vp(pg_temp.id(1), pg_temp.id(31)::text) as casa;

select is((select array_agg(k order by k) from r, jsonb_object_keys(r.anon) k),
          array['estabelecimento_nome','estado','fim_em','funcao','id','inclusos','inicio_em','modo','posicoes_abertas',
                'publicado_em','regiao_administrativa','valor_centavos'],
          'B: anon recebe exatamente as chaves de VagaPublica');
select is((select array_agg(k order by k) from r, jsonb_object_keys(r.anon->'funcao') k),
          array['categoria','id','nome'], 'B: funcao só com id, nome e categoria');
select is((select array_agg(k order by k) from r, jsonb_object_keys(r.anon->'inclusos') k),
          array['exige_material_proprio','inclui_refeicao','inclui_transporte'], 'B: inclusos só com os três booleanos');
select is((select prof from r), (select anon from r), 'B: profissional logado recebe o mesmo que anon, sem nada a mais');
select is((select casa from r), (select anon from r), 'B: membro da casa recebe o mesmo que anon, sem nada a mais');
select is((select anon->>'id' from r), pg_temp.id(31)::text, 'B: id da vaga');
select is((select anon->'funcao'->>'nome' from r), 'garçom', 'B: nome da função');
select is((select anon->>'regiao_administrativa' from r), 'Plano Piloto', 'B: região pelo nome do catálogo');
select is((select (anon->>'inicio_em')::timestamptz from r), '2026-11-20 21:00:00+00'::timestamptz, 'B: inicio_em');
select is((select (anon->>'fim_em')::timestamptz from r), '2026-11-21 02:00:00+00'::timestamptz, 'B: fim_em');
select is((select (anon->>'valor_centavos')::int from r), 18000, 'B: valor_centavos');
select is((select (anon->>'publicado_em')::timestamptz from r), '2026-11-16 15:00:00+00'::timestamptz, 'B: publicado_em');
select is((select anon->'inclusos' from r),
          '{"inclui_refeicao": true, "inclui_transporte": false, "exige_material_proprio": true}'::jsonb, 'B: inclusos');
select is((select anon->>'modo' from r), 'urgencia', 'B: modo');
select is((select (anon->>'posicoes_abertas')::int from r), 2, 'B: posicoes_abertas pela regra de detalhe_vaga');
select is((select anon->>'estado' from r), 'publicada', 'B: estado');
select ok((select anon::text !~ '(Sigilos|CasaSigilosa|879@|Contratante|\+5561|94827987)' from r),
          'B: nada da casa, do endereço, do texto livre ou de quem publicou no corpo');

-- ── C: os 404, todos iguais à vaga inexistente ────────────────────────────────
create temp table inexistente as select pg_temp.vp_recusa(null, pg_temp.id(99)::text) as e;
select is((select e from inexistente),
          'PGRST | {"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null} | {"status" : 404, "headers" : {}}',
          'C: vaga inexistente = 404 nao_encontrado sem details');
select is(pg_temp.vp_recusa(null, pg_temp.id(32)::text), (select e from inexistente), 'C: vaga direta (anon) = o mesmo 404');
select is(pg_temp.vp_recusa(pg_temp.id(1), pg_temp.id(32)::text), (select e from inexistente),
          'C: vaga direta = o mesmo 404 também para a própria casa');
select is(pg_temp.vp_recusa(null, pg_temp.id(33)::text), (select e from inexistente), 'C: vaga oculta = o mesmo 404');
select is(pg_temp.vp_recusa(null, pg_temp.id(34)::text), (select e from inexistente), 'C: vaga de conta de demonstração (anon) = o mesmo 404');
select is(pg_temp.vp_recusa(pg_temp.id(4), pg_temp.id(34)::text), (select e from inexistente),
          'C: vaga de demonstração = o mesmo 404 também para profissional de demonstração');
select is(pg_temp.vp_recusa(null, 'nao-e-uuid'), (select e from inexistente), 'C: id malformado = o mesmo 404, não 22P02');
select is(pg_temp.vp_recusa(null, pg_temp.id(31)::text || 'x'), (select e from inexistente), 'C: uuid com sobra = o mesmo 404');
select is(pg_temp.vp_recusa(null, ''), (select e from inexistente), 'C: texto vazio = o mesmo 404');
select is(pg_temp.recusa(null, 'select public.vaga_publica(null)'), (select e from inexistente), 'C: nulo = o mesmo 404');

-- ── D: 200 com o estado real ──────────────────────────────────────────────────
select is(pg_temp.vp(null, pg_temp.id(35)::text)->>'estado', 'cancelada', 'D: vaga cancelada responde 200 com estado cancelada');
select is((pg_temp.vp(null, pg_temp.id(35)::text)->>'posicoes_abertas')::int, 0, 'D: vaga cancelada sem posições abertas');
select is(pg_temp.vp(null, pg_temp.id(36)::text)->>'estado', 'preenchida', 'D: vaga preenchida responde 200 com estado preenchida');
select ok((pg_temp.vp(null, pg_temp.id(38)::text) ? 'regiao_administrativa')
          and pg_temp.vp(null, pg_temp.id(38)::text)->'regiao_administrativa' = 'null'::jsonb,
          'D: região do catálogo inativa = null, com a chave presente');

-- ── E: RLS e grant da tabela ──────────────────────────────────────────────────
select is(pg_temp.recusa(null, 'select to_jsonb(count(*)) from public.vaga') ~ '^42501', true,
          'E: anon recebe 42501 ao ler public.vaga direto');

select * from finish();
rollback;
