-- 873_busca_foto_no_cartao.sql
--
-- Busca de profissionais, PR 3 (migração 20261116233000, contrato 0.2.90, frila-documentacao #262): a foto
-- aprovada vai no cartão da busca (CD-B07, decisão do Cauê, pedido 2026-11-16-13) e o vínculo pela busca,
-- com os Termos 1.1 aceitos, abre também a foto no perfil_publico e no link da ler-midia.
--   A  o cartão: foto aprovada traz foto_id e foto_url (link de 1 h da ler-midia); pendente, recusada,
--      removida e sem foto: as duas chaves AUSENTES; o conjunto exato de chaves; nada do storage nem da
--      moderação; recurso foto_de_perfil desligado: sem foto; a foto não filtra nem ordena (RN39)
--   B  perfil_publico: com o aceite a foto vem pela busca; sem o aceite, fora da busca, pendente, com o
--      recurso desligado ou de outra população: não vem; o vínculo antigo (equipe de confiança) segue igual
--   C  o resolvedor do link (privado.resolver_link_leitura_midia) reconfere o vínculo da busca na leitura
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);   -- segunda 12h em Brasília
set local frila.agendador_secret = 'segredo-de-teste-873';
set local frila.ler_midia_function_url = 'http://funcoes.invalid/functions/v1/ler-midia';
select plan(36);

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
create function pg_temp.u(n int) returns uuid language sql immutable as $$
  select ('c8730000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;
-- O id do PERFIL do profissional cuja conta é u(n).
create function pg_temp.p(n int) returns uuid language sql stable as $$
  select id from public.profissional where usuario_id = pg_temp.u(n) $$;
create function pg_temp.midia(n int) returns uuid language sql immutable as $$
  select ('c8730000-0000-4000-8000-0000000002' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.casa(n int) returns uuid language sql immutable as $$
  select ('c8730000-0000-4000-8000-00000000e0' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.chaves(j jsonb) returns text language sql as $$
  select string_agg(k, ',' order by k) from jsonb_object_keys(j) k $$;
-- A busca da casa como a conta (garçom, região da casa).
create function pg_temp.busca(conta uuid, casa uuid) returns jsonb language plpgsql as $$
begin
  delete from privado.contador_busca;
  return pg_temp.como(conta, format(
    'select public.buscar_profissionais(estabelecimento_id => %L, funcao_id => %L)',
    casa, (select id from public.funcao where nome = 'garçom')));
end $$;
-- O cartão do profissional n numa resposta da busca.
create function pg_temp.cartao(busca jsonb, n int) returns jsonb language sql as $$
  select x from jsonb_array_elements(busca -> 'itens') x where x ->> 'id' = pg_temp.p(n)::text $$;
-- Os dois últimos dígitos da conta de cada cartão, na ordem da lista.
create function pg_temp.ordem(busca jsonb) returns text language sql as $$
  select string_agg(right((select u.id::text from public.profissional p join public.usuario u on u.id = p.usuario_id
                             where p.id = (x ->> 'id')::uuid), 2), ',' order by o)
    from jsonb_array_elements(busca -> 'itens') with ordinality t(x, o) $$;
create function pg_temp.perfil(leitor uuid, alvo uuid) returns jsonb language sql as
  $$ select pg_temp.como(leitor, format('select public.perfil_publico(%L::uuid)', alvo)) $$;
-- O token de um foto_url.
create function pg_temp.token(url text) returns text language sql immutable as $$
  select substring(url from 'token=([0-9a-f]{64})$') $$;

-- ── Massa ─────────────────────────────────────────────────────────────────────
-- Contratantes: 1 (casa 1, aceitou os Termos 1.1), 2 (casa 2, termos 1.0: não aceitou), 3 (casa 3, demonstração).
-- Profissionais: 11 foto aprovada, 12 em análise, 13 recusada, 14 sem foto, 15 aprovada mas FORA da busca
-- (não aceita chamadas), 16 de demonstração com foto aprovada, 17 foto removida.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
select pg_temp.u(n), 'contratante', 'Contratante ' || n, '+5561955587' || lpad(n::text, 3, '0'), 'c' || n || '@t873.test', '1985-01-01',
       case when n = 2 then '1.0' else '2026-11-13' end, privado.agora(), n = 3
  from generate_series(1, 3) n;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
select pg_temp.u(n), 'profissional', 'Prof ' || n || ' Sobrenome', '+5561987587' || lpad(n::text, 3, '0'), 'p' || n || '@t873.test',
       '1990-01-01', '1.0', privado.agora(), n = 16
  from generate_series(11, 17) n;
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
select pg_temp.casa(n), 'Casa 873 ' || n, '8731234' || n || '666', 'food_service', 'CLN 20' || n,
       'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'
  from generate_series(1, 3) n;
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select pg_temp.u(n), pg_temp.casa(n), 'administrador' from generate_series(1, 3) n;
insert into public.profissional (usuario_id, ponto_base, atende_todo_df, apresentacao)
select pg_temp.u(n), 'POINT(-47.8822 -15.7800)'::extensions.geography, true, 'Apresentação ' || n from generate_series(11, 17) n;
insert into public.profissional_funcao (profissional_id, funcao_id)
select pg_temp.p(n), (select id from public.funcao where nome = 'garçom') from generate_series(11, 17) n;
insert into public.profissional_servico (profissional_id, funcao_id, unidade)
select pg_temp.p(n), (select id from public.funcao where nome = 'garçom'), 'a_combinar' from generate_series(11, 17) n;
insert into public.profissional_preferencia_chamada (profissional_id, aceita_chamadas, aceita_chamadas_em, versao_texto_busca)
select pg_temp.p(n), n <> 15, privado.agora(), 'v1' from generate_series(11, 17) n;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select pg_temp.u(n), 'tok-873-' || n, 'ios', '1.2.0' from generate_series(11, 17) n;
update privado.recurso set ligado = true where chave in ('chamada_direta', 'busca_profissionais');
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;

update privado.configuracao_app set foto_de_perfil = true;
delete from vault.secrets where name in ('storage_jwt_secret', 'ler_midia_function_url');
insert into privado.midia (id, dono_usuario_id, estabelecimento_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
select pg_temp.midia(n), pg_temp.u(n), null, 'profissional', 'foto_perfil', 'perfil/' || pg_temp.midia(n) || '.jpg', 'image/jpeg', 1000,
       case n when 11 then 'aprovada' when 12 then 'em_analise' when 13 then 'recusada' when 15 then 'aprovada'
              when 16 then 'aprovada' when 17 then 'removida' end
  from generate_series(11, 17) n where n <> 14;

-- ══ A. O cartão ═══════════════════════════════════════════════════════════════
create temp table guarda (k text primary key, v jsonb);
grant all on guarda to public;
insert into guarda select 'com_foto', pg_temp.busca(pg_temp.u(1), pg_temp.casa(1));
update privado.configuracao_app set foto_de_perfil = false;
insert into guarda select 'sem_recurso', pg_temp.busca(pg_temp.u(1), pg_temp.casa(1));
update privado.configuracao_app set foto_de_perfil = true;
insert into guarda select 'demo', pg_temp.busca(pg_temp.u(3), pg_temp.casa(3));
create function pg_temp.g(k text) returns jsonb language sql as $$ select v from guarda where guarda.k = $1 $$;

select is(pg_temp.cartao(pg_temp.g('com_foto'), 11) ->> 'foto_id', pg_temp.midia(11)::text,
  'A1 foto aprovada: o cartão traz foto_id');
select ok(pg_temp.cartao(pg_temp.g('com_foto'), 11) ->> 'foto_url'
            ~ ('^http://funcoes\.invalid/functions/v1/ler-midia\?midia_id=' || pg_temp.midia(11) || '&token=[0-9a-f]{64}$'),
  'A2 e foto_url é o link da ler-midia (a mesma forma do perfil), com token de 64 hex');
select is(pg_temp.chaves(pg_temp.cartao(pg_temp.g('com_foto'), 11)),
  'atende_todo_df,distancia_faixa,foto_id,foto_url,id,nome,regioes,reputacao,servico',
  'A3 o conjunto EXATO de chaves do cartão com foto (lista explícita; sem horário)');
select is(pg_temp.chaves(pg_temp.cartao(pg_temp.g('com_foto'), 12)),
  'atende_todo_df,distancia_faixa,id,nome,regioes,reputacao,servico',
  'A4 foto em análise: nenhuma das duas chaves (ausentes, não nulas)');
select is(pg_temp.chaves(pg_temp.cartao(pg_temp.g('com_foto'), 13)),
  'atende_todo_df,distancia_faixa,id,nome,regioes,reputacao,servico', 'A5 foto recusada: sem as chaves');
select is(pg_temp.chaves(pg_temp.cartao(pg_temp.g('com_foto'), 14)),
  'atende_todo_df,distancia_faixa,id,nome,regioes,reputacao,servico', 'A6 sem foto nenhuma: sem as chaves');
select is(pg_temp.chaves(pg_temp.cartao(pg_temp.g('com_foto'), 17)),
  'atende_todo_df,distancia_faixa,id,nome,regioes,reputacao,servico', 'A7 foto removida: sem as chaves');
select ok(pg_temp.cartao(pg_temp.g('com_foto'), 15) is null, 'A8 quem não aceita chamadas não está na lista, nem com foto aprovada');
select ok(pg_temp.cartao(pg_temp.g('com_foto'), 11)::text !~* 'perfil/|\.jpg|storage|motivo|moderac|denuncia|dono_usuario|em_analise|aprovada',
  'A9 do cartão não sai caminho do storage, estado nem dado da moderação');
select is(pg_temp.chaves(pg_temp.cartao(pg_temp.g('sem_recurso'), 11)),
  'atende_todo_df,distancia_faixa,id,nome,regioes,reputacao,servico',
  'A10 com recursos.foto_de_perfil desligado, o cartão não traz a foto (a mesma regra do perfil)');
select is(pg_temp.ordem(pg_temp.g('com_foto')), pg_temp.ordem(pg_temp.g('sem_recurso')),
  'A11 a foto não ordena: a lista tem a mesma ordem com e sem o recurso (RN39)');
select is(jsonb_array_length(pg_temp.g('com_foto') -> 'itens'), jsonb_array_length(pg_temp.g('sem_recurso') -> 'itens'),
  'A12 a foto não filtra: quem não tem foto está na lista, a mesma contagem com e sem o recurso');
select is(jsonb_array_length(pg_temp.g('com_foto') -> 'itens'), 5, 'A13 a lista tem os cinco da busca real (11, 12, 13, 14, 17)');
select is(pg_temp.cartao(pg_temp.g('demo'), 16) ->> 'foto_id', pg_temp.midia(16)::text,
  'A14 a demonstração vê a foto de quem é de demonstração, pelo mesmo caminho');
select ok(pg_temp.cartao(pg_temp.g('com_foto'), 16) is null, 'A15 e a população real não lista o profissional de demonstração');
select is((select p.provolatile from pg_proc p where p.oid = 'privado.cartao_profissional(uuid, uuid, smallint, boolean, boolean)'::regprocedure),
  'v', 'A16 o cartão é volátil (a projeção grava o hash do link)');
select is((select count(*)::int from privado.midia_link_leitura where midia_id = pg_temp.midia(12)), 0,
  'A17 só quem tem foto aprovada ganha link: a foto em análise não cunhou nenhum');

-- ══ B. perfil_publico ═════════════════════════════════════════════════════════
select is(pg_temp.perfil(pg_temp.u(1), pg_temp.p(11)) ->> 'foto_id', pg_temp.midia(11)::text,
  'B1 o contratante com os Termos 1.1 aceitos lê a foto pelo vínculo da busca');
select ok(pg_temp.perfil(pg_temp.u(1), pg_temp.p(11)) ->> 'foto_url' like 'http://funcoes.invalid/functions/v1/ler-midia?midia_id=%',
  'B2 e foto_url é o link da ler-midia');
select ok(not (pg_temp.perfil(pg_temp.u(2), pg_temp.p(11)) ? 'foto_id') and not (pg_temp.perfil(pg_temp.u(2), pg_temp.p(11)) ? 'foto_url'),
  'B3 SEM o aceite dos Termos 1.1: sem foto');
select ok(not (pg_temp.perfil(pg_temp.u(2), pg_temp.p(11)) ? 'apresentacao'),
  'B4 e sem o perfil rico (o aceite vale igual para os dois)');
select ok(not (pg_temp.perfil(pg_temp.u(1), pg_temp.p(15)) ? 'foto_id'),
  'B5 fora da busca (não aceita chamadas): sem foto, mesmo aprovada');
select ok(not (pg_temp.perfil(pg_temp.u(1), pg_temp.p(12)) ? 'foto_id'), 'B6 foto em análise: sem foto');
select ok(not (pg_temp.perfil(pg_temp.u(1), pg_temp.p(16)) ? 'foto_id'),
  'B7 a demonstração não vaza: contratante real não lê a foto do profissional de demonstração');
update privado.configuracao_app set foto_de_perfil = false;
select ok(not (pg_temp.perfil(pg_temp.u(1), pg_temp.p(11)) ? 'foto_id'), 'B8 recurso foto_de_perfil desligado: sem foto');
update privado.configuracao_app set foto_de_perfil = true;
update privado.recurso set ligado = false where chave = 'busca_profissionais';
select ok(not (pg_temp.perfil(pg_temp.u(1), pg_temp.p(11)) ? 'foto_id'), 'B9 busca_profissionais desligada: a busca não é vínculo da foto');
update privado.recurso set ligado = true where chave = 'busca_profissionais';
-- O vínculo antigo segue igual: equipe de confiança abre a foto mesmo sem o aceite.
insert into public.equipe_confianca (estabelecimento_id, profissional_id) values (pg_temp.casa(2), pg_temp.p(11));
select is(pg_temp.perfil(pg_temp.u(2), pg_temp.p(11)) ->> 'foto_id', pg_temp.midia(11)::text,
  'B10 vínculo antigo (equipe de confiança): a foto vem, com ou sem o aceite');
select ok(not (pg_temp.perfil(pg_temp.u(2), pg_temp.p(14)) ? 'foto_id'), 'B11 sem foto aprovada nem com vínculo: sem as chaves');

-- ══ C. O resolvedor do link ═══════════════════════════════════════════════════
create temp table link as
  select pg_temp.token(pg_temp.cartao(pg_temp.g('com_foto'), 11) ->> 'foto_url') as t;
select is(privado.resolver_link_leitura_midia(pg_temp.midia(11), (select t from link)),
  'perfil/' || pg_temp.midia(11) || '_thumb.jpg',
  'C1 o link do cartão abre a miniatura para quem o recebeu (vínculo da busca com o aceite)');
update public.usuario set termos_versao = '1.0' where id = pg_temp.u(1);
select is(privado.resolver_link_leitura_midia(pg_temp.midia(11), (select t from link)), null,
  'C2 se o leitor perde o aceite dentro da hora, o link deixa de abrir (o resolvedor reconfere)');
update public.usuario set termos_versao = '2026-11-13' where id = pg_temp.u(1);
update public.profissional_preferencia_chamada set aceita_chamadas = false where profissional_id = pg_temp.p(11);
select is(privado.resolver_link_leitura_midia(pg_temp.midia(11), (select t from link)), null,
  'C3 se o profissional sai da busca dentro da hora, o link deixa de abrir');
update public.profissional_preferencia_chamada set aceita_chamadas = true where profissional_id = pg_temp.p(11);
select is(privado.resolver_link_leitura_midia(pg_temp.midia(11), (select t from link)),
  'perfil/' || pg_temp.midia(11) || '_thumb.jpg', 'C4 voltou à busca: o mesmo link abre de novo');
update privado.recurso set ligado = false where chave = 'busca_profissionais';
select is(privado.resolver_link_leitura_midia(pg_temp.midia(11), (select t from link)), null,
  'C4b se a chave busca_profissionais desliga dentro da hora, o link deixa de abrir');
update privado.recurso set ligado = true where chave = 'busca_profissionais';
select is(privado.resolver_link_leitura_midia(pg_temp.midia(11), (select t from link)),
  'perfil/' || pg_temp.midia(11) || '_thumb.jpg', 'C4c a chave volta: o mesmo link abre de novo');
-- Link cunhado para quem não tem vínculo nenhum (sem o aceite e fora da equipe) não abre.
delete from public.equipe_confianca where profissional_id = pg_temp.p(11);
create temp table link_sem as
  select pg_temp.token(privado.cunhar_link_leitura_midia(pg_temp.midia(11), pg_temp.u(2))) as t;
select is(privado.resolver_link_leitura_midia(pg_temp.midia(11), (select t from link_sem)), null,
  'C5 link cunhado para quem não aceitou os Termos 1.1 e não tem vínculo: não abre');
insert into public.equipe_confianca (estabelecimento_id, profissional_id) values (pg_temp.casa(2), pg_temp.p(11));
select is(privado.resolver_link_leitura_midia(pg_temp.midia(11), (select t from link_sem)),
  'perfil/' || pg_temp.midia(11) || '_thumb.jpg', 'C6 o mesmo link, com equipe de confiança (vínculo antigo): abre');

select * from finish();
rollback;
