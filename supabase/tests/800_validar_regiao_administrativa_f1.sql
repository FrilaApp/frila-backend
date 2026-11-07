-- 800_validar_regiao_administrativa_f1.sql
--
-- Validar e migrar regiao_administrativa (RN44). Contratação direta, fatia F1 · brief B2 ·
-- contrato 0.2.52. Ids próprios, começando em `d8000000`.
--
-- O que este arquivo prova, um grupo por critério de aceite do cartão:
--   0. Estrutura: as duas chaves estrangeiras para `public.regiao_administrativa (nome)` existem
--      e o banco recusa, sozinho, texto fora do catálogo.
--   1. Texto legado reconhecível (`Ceilandia`, `Aguas Claras`, `ASA NORTE`) vira o nome oficial,
--      e o resto da linha fica intacto.
--   2. Texto legado sem correspondência (`Entorno Desconhecido`) vira `Plano Piloto` e o texto
--      original fica em `privado.pendencia_regiao_administrativa`, sem perda. A função é
--      idempotente e, depois dela, a chave estrangeira volta a poder ser criada.
--   3. Região inválida (`Nárnia`, `Área 51`, região inativa) é recusada com `422 campo_invalido`
--      em `cadastrar_estabelecimento` e em `publicar_vaga`, e nada parcial é criado.
--   4. Vaga em região válida continua indo para a fila do despacho e aparecendo na lista com a
--      distância calculada do ponto do profissional (RN05), sem depender das regiões do perfil.
--
-- A migração roda antes dos testes e já deixou as chaves no lugar. Para provar o que ela fez com
-- dado legado, o teste derruba as chaves DENTRO da transação, fabrica linhas legadas e chama
-- `privado.conciliar_regiao_administrativa_legada()`, a mesma função que a migração chamou.
-- Tudo desfeito no `rollback`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(36);

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

-- Cadastra um estabelecimento como a conta `dona`.
create function pg_temp.cadastrar(nome text, documento text, regiao text) returns jsonb
language sql as $$
  select pg_temp.como('d8000000-0000-4000-8000-000000000001',
    format($x$ select public.cadastrar_estabelecimento(%L, %L, 'food_service',
                'CLN 201 Bloco B', '{"latitude":-15.7942,"longitude":-47.8822}'::jsonb, %L) $x$,
           nome, documento, regiao))
$$;

-- Publica uma vaga como a conta `dona`. `regiao` nula = omitida (herda da casa).
create function pg_temp.publicar(estab uuid, lat numeric, lon numeric, regiao text) returns jsonb
language sql as $$
  select pg_temp.como('d8000000-0000-4000-8000-000000000001',
    format($x$ select public.publicar_vaga(
                 estabelecimento_id     => %L::uuid,
                 funcao_id              => %L::uuid,
                 inicio_em              => now() + interval '4 hours',
                 fim_em                 => now() + interval '8 hours',
                 local                  => 'CLN 201',
                 ponto                  => jsonb_build_object('latitude', %s, 'longitude', %s),
                 valor_centavos         => 18000,
                 posicoes               => 1,
                 inclui_refeicao        => true,
                 inclui_transporte      => true,
                 exige_material_proprio => false,
                 responsavel_local      => 'Seu Zé',
                 modo                   => 'urgencia',
                 chave                  => gen_random_uuid(),
                 regiao_administrativa  => %L) $x$,
           estab, (select id from public.funcao where nome = 'garçom'), lat, lon, regiao))
$$;

-- ── Contas ─────────────────────────────────────────────────────────────────────

select pg_temp.autenticar('d8000000-0000-4000-8000-000000000001', 'dona.b2@frila.test');
select pg_temp.autenticar('d8000000-0000-4000-8000-000000000002', 'garcom.b2@frila.test');

select pg_temp.como('d8000000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante', 'Dona B2', '+5561999990801', '1985-05-10', '2026-11-07') $$);
select pg_temp.como('d8000000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('profissional', 'Garçom B2', '+5561999990802', '1990-06-15', '2026-11-07') $$);

-- Sem nenhuma região marcada no perfil: o critério 4 exige que a lista não dependa delas.
select pg_temp.como('d8000000-0000-4000-8000-000000000002',
  format($$ select public.criar_perfil_profissional(
              array[%L]::uuid[],
              '{"latitude":-15.7942,"longitude":-47.8822}'::jsonb) $$,
         (select id from public.funcao where nome = 'garçom')));

-- ── 0. Estrutura ──────────────────────────────────────────────────────────────

select fk_ok('public', 'estabelecimento', 'regiao_administrativa',
             'public', 'regiao_administrativa', 'nome',
             'estabelecimento.regiao_administrativa aponta para o catálogo (RN44)');
select fk_ok('public', 'vaga', 'regiao_administrativa',
             'public', 'regiao_administrativa', 'nome',
             'vaga.regiao_administrativa aponta para o catálogo (RN44)');

create temp table t_estab_a as
  select pg_temp.cadastrar('Bar Taguatinga', '04252011000110', 'Taguatinga') as r;
create temp table t_estab_b as
  select pg_temp.cadastrar('Bar Asa Norte', '11222333000181', 'Plano Piloto') as r;
create temp table t_estab_c as
  select pg_temp.cadastrar('Bar Desconhecido', '45223011000179', 'Plano Piloto') as r;

select throws_ok(
  format($$ update public.estabelecimento set regiao_administrativa = 'Nárnia' where id = %L $$,
         (select (r->>'id')::uuid from t_estab_a)),
  '23503', null,
  'o banco recusa estabelecimento com região fora do catálogo, sem passar pela RPC');

create temp table t_vaga_a as
  select pg_temp.publicar((select (r->>'id')::uuid from t_estab_a), -15.8300, -48.0500, null) as r;

select throws_ok(
  format($$ update public.vaga set regiao_administrativa = 'Área 51' where id = %L $$,
         (select (r->>'vaga_id')::uuid from t_vaga_a)),
  '23503', null,
  'o banco recusa vaga com região fora do catálogo, sem passar pela RPC');

create temp table t_vaga_b as
  select pg_temp.publicar((select (r->>'id')::uuid from t_estab_b), -15.7942, -47.8822, null) as r;
create temp table t_vaga_c as
  select pg_temp.publicar((select (r->>'id')::uuid from t_estab_c), -15.7942, -47.8822, null) as r;

-- ── 1 e 2. Dado legado ────────────────────────────────────────────────────────
--
-- Derruba as chaves (só nesta transação), fabrica o legado e roda a função da migração.

alter table public.estabelecimento drop constraint estabelecimento_regiao_administrativa_fkey;
alter table public.vaga            drop constraint vaga_regiao_administrativa_fkey;

-- Fotografia do que NÃO pode mudar: a linha inteira menos a região.
create temp table t_antes as
  select e.id,
         to_jsonb(e) - 'regiao_administrativa' as estab_sem_ra,
         extensions.st_astext(e.ponto::extensions.geometry) as ponto_txt
    from public.estabelecimento e
   where e.id in (select (r->>'id')::uuid from t_estab_a
                  union all select (r->>'id')::uuid from t_estab_b
                  union all select (r->>'id')::uuid from t_estab_c);
create temp table t_antes_vaga as
  select v.id, to_jsonb(v) - 'regiao_administrativa' as vaga_sem_ra
    from public.vaga v
   where v.id in (select (r->>'vaga_id')::uuid from t_vaga_a
                  union all select (r->>'vaga_id')::uuid from t_vaga_b
                  union all select (r->>'vaga_id')::uuid from t_vaga_c);

update public.estabelecimento set regiao_administrativa = 'Ceilandia'
 where id = (select (r->>'id')::uuid from t_estab_a);
update public.estabelecimento set regiao_administrativa = '  ASA NORTE '
 where id = (select (r->>'id')::uuid from t_estab_b);
update public.estabelecimento set regiao_administrativa = 'Entorno Desconhecido'
 where id = (select (r->>'id')::uuid from t_estab_c);

update public.vaga set regiao_administrativa = 'Aguas Claras'
 where id = (select (r->>'vaga_id')::uuid from t_vaga_a);
update public.vaga set regiao_administrativa = 'riacho fundo i'
 where id = (select (r->>'vaga_id')::uuid from t_vaga_b);
update public.vaga set regiao_administrativa = 'Entorno Desconhecido'
 where id = (select (r->>'vaga_id')::uuid from t_vaga_c);

select lives_ok($$ select privado.conciliar_regiao_administrativa_legada() $$,
  'a conciliação do dado legado roda');

-- Critério 1: reconhecível vira o nome oficial.
select is((select regiao_administrativa from public.estabelecimento
            where id = (select (r->>'id')::uuid from t_estab_a)),
  'Ceilândia', 'critério 1: estabelecimento "Ceilandia" aponta para Ceilândia');
select is((select regiao_administrativa from public.estabelecimento
            where id = (select (r->>'id')::uuid from t_estab_b)),
  'Plano Piloto', 'critério 1: estabelecimento "  ASA NORTE " aponta para Plano Piloto');
select is((select regiao_administrativa from public.vaga
            where id = (select (r->>'vaga_id')::uuid from t_vaga_a)),
  'Águas Claras', 'critério 1: vaga "Aguas Claras" aponta para Águas Claras');
select is((select regiao_administrativa from public.vaga
            where id = (select (r->>'vaga_id')::uuid from t_vaga_b)),
  'Riacho Fundo', 'critério 1: vaga "riacho fundo i" aponta para Riacho Fundo');

select is(
  (select count(*)::int from public.estabelecimento e
     join t_antes a on a.id = e.id
    where to_jsonb(e) - 'regiao_administrativa' = a.estab_sem_ra
      and extensions.st_astext(e.ponto::extensions.geometry) = a.ponto_txt),
  3, 'critério 1: nome, documento, tipo, endereço e ponto dos estabelecimentos ficam intactos');
select is(
  (select count(*)::int from public.vaga v
     join t_antes_vaga a on a.id = v.id
    where to_jsonb(v) - 'regiao_administrativa' = a.vaga_sem_ra),
  3, 'critério 1: o resto de cada vaga fica intacto');
select is(
  (select count(*)::int from privado.pendencia_regiao_administrativa
    where registro_id in (select (r->>'id')::uuid from t_estab_a
                          union all select (r->>'id')::uuid from t_estab_b
                          union all select (r->>'vaga_id')::uuid from t_vaga_a
                          union all select (r->>'vaga_id')::uuid from t_vaga_b)),
  0, 'critério 1: o que foi reconhecido não gera pendência');

-- Critério 2: sem correspondência vira Plano Piloto, com o texto original guardado.
select is((select regiao_administrativa from public.estabelecimento
            where id = (select (r->>'id')::uuid from t_estab_c)),
  'Plano Piloto', 'critério 2: estabelecimento "Entorno Desconhecido" cai no fallback Plano Piloto');
select is((select regiao_administrativa from public.vaga
            where id = (select (r->>'vaga_id')::uuid from t_vaga_c)),
  'Plano Piloto', 'critério 2: vaga "Entorno Desconhecido" cai no fallback Plano Piloto');
select is(
  (select texto_original from privado.pendencia_regiao_administrativa
    where origem = 'estabelecimento' and registro_id = (select (r->>'id')::uuid from t_estab_c)),
  'Entorno Desconhecido', 'critério 2: a pendência do estabelecimento guarda o texto original');
select is(
  (select texto_original || '/' || regiao_aplicada from privado.pendencia_regiao_administrativa
    where origem = 'vaga' and registro_id = (select (r->>'vaga_id')::uuid from t_vaga_c)),
  'Entorno Desconhecido/Plano Piloto', 'critério 2: a pendência da vaga guarda o texto original e a região aplicada');
select is(
  (select count(*)::int from public.estabelecimento e
     join t_antes a on a.id = e.id
    where to_jsonb(e) - 'regiao_administrativa' = a.estab_sem_ra
      and e.id = (select (r->>'id')::uuid from t_estab_c)),
  1, 'critério 2: o resto do estabelecimento em fallback fica intacto');

select lives_ok($$ select privado.conciliar_regiao_administrativa_legada() $$,
  'rodar a conciliação de novo não quebra');
select is(
  (select count(*)::int from privado.pendencia_regiao_administrativa
    where texto_original = 'Entorno Desconhecido'),
  2, 'a conciliação é idempotente: continua uma pendência por registro');

select lives_ok($$
  alter table public.estabelecimento
    add constraint estabelecimento_regiao_administrativa_fkey
    foreign key (regiao_administrativa) references public.regiao_administrativa (nome)
    on update cascade;
  alter table public.vaga
    add constraint vaga_regiao_administrativa_fkey
    foreign key (regiao_administrativa) references public.regiao_administrativa (nome)
    on update cascade $$,
  'depois da conciliação, as chaves estrangeiras voltam sem violação');

-- ── 3. Região inválida ────────────────────────────────────────────────────────

create temp table t_contagem as
  select (select count(*) from public.estabelecimento) as estabs,
         (select count(*) from public.vaga)            as vagas,
         (select count(*) from public.posicao)         as posicoes,
         (select count(*) from pgmq.q_despacho)        as fila;

-- Critério 3: Compatibilidade com o app iOS 1.0.0 (35 strings) e recusa de região inválida.

select is(
  (with app_ras(orig) as (
     values
       ('Água Quente'), ('Águas Claras'), ('Arapoanga'), ('Arniqueira'), ('Brazlândia'),
       ('Candangolândia'), ('Ceilândia'), ('Cruzeiro'), ('Fercal'), ('Gama'),
       ('Guará'), ('Itapoã'), ('Jardim Botânico'), ('Lago Norte'), ('Lago Sul'),
       ('Núcleo Bandeirante'), ('Paranoá'), ('Park Way'), ('Planaltina'), ('Plano Piloto'),
       ('Recanto das Emas'), ('Riacho Fundo'), ('Riacho Fundo II'), ('Samambaia'), ('Santa Maria'),
       ('São Sebastião'), ('SCIA / Estrutural'), ('SIA'), ('Sobradinho'), ('Sobradinho II'),
       ('Sol Nascente/Pôr do Sol'), ('Sudoeste/Octogonal'), ('Taguatinga'), ('Varjão'), ('Vicente Pires')
   )
   select count(*)::int from app_ras a
    where not exists (
      select 1 from public.regiao_administrativa r
       where r.nome = privado.resolver_regiao_administrativa(a.orig)
         and r.ativo
    )),
  0,
  'critério 3: todas as 35 strings exatas do app iOS 1.0.0 resolvem para região oficial ativa');

select throws_ok(
  $$ select pg_temp.cadastrar('Bar Nárnia', '19131905000129', 'Nárnia') $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "regiao_administrativa", "hint" : null}',
  'critério 3: cadastrar_estabelecimento recusa "Nárnia" com 422 campo_invalido');
select throws_ok(
  $$ select pg_temp.cadastrar('Bar Área 51', '19131905000129', 'Área 51') $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "regiao_administrativa", "hint" : null}',
  'critério 3: cadastrar_estabelecimento recusa "Área 51" com 422 campo_invalido');

select is(
  (select count(*)::int from public.estabelecimento where documento = '19131905000129'),
  0, 'critério 3: cadastro recusado não deixa estabelecimento parcial');

select throws_ok(
  format($$ select pg_temp.publicar(%L::uuid, -15.7942, -47.8822, 'Nárnia') $$,
         (select (r->>'id')::uuid from t_estab_a)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "regiao_administrativa", "hint" : null}',
  'critério 3: publicar_vaga recusa "Nárnia" com 422 campo_invalido');
select throws_ok(
  format($$ select pg_temp.publicar(%L::uuid, -15.7942, -47.8822, 'Entorno Desconhecido') $$,
         (select (r->>'id')::uuid from t_estab_a)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "regiao_administrativa", "hint" : null}',
  'critério 3: publicar_vaga recusa texto livre com 422 campo_invalido');

-- Região inativa no catálogo: existe, mas não vale para escrita nova.
update public.regiao_administrativa set ativo = false where nome = 'Gama';
select throws_ok(
  $$ select pg_temp.cadastrar('Bar Gama', '19131905000129', 'Gama') $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "regiao_administrativa", "hint" : null}',
  'critério 3: região inativa no catálogo é recusada no cadastro');
select throws_ok(
  format($$ select pg_temp.publicar(%L::uuid, -15.7942, -47.8822, 'Gama') $$,
         (select (r->>'id')::uuid from t_estab_a)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "regiao_administrativa", "hint" : null}',
  'critério 3: região inativa no catálogo é recusada na publicação');
update public.regiao_administrativa set ativo = true where nome = 'Gama';

select is(
  (select (select count(*) from public.estabelecimento) - estabs from t_contagem)
  + (select (select count(*) from public.vaga) - vagas from t_contagem)
  + (select (select count(*) from public.posicao) - posicoes from t_contagem)
  + (select (select count(*) from pgmq.q_despacho) - fila from t_contagem),
  0::bigint,
  'critério 3: as recusas não criam estabelecimento, vaga, posição nem mensagem de despacho');

-- App legado envia 'SCIA / Estrutural' ou caixa baixa: RPC aceita e normaliza para o catálogo
create temp table t_estab_scia as
  select pg_temp.cadastrar('Bar SCIA', '88888011000109', 'SCIA / Estrutural') as r;
select is(
  (select regiao_administrativa from public.estabelecimento
    where id = (select (r->>'id')::uuid from t_estab_scia)),
  'SCIA', 'critério 3: cadastrar_estabelecimento aceita "SCIA / Estrutural" e normaliza para SCIA');

create temp table t_estab_min as
  select pg_temp.cadastrar('Bar Minúsculo', '77777011000107', 'taguatinga') as r;
select is(
  (select regiao_administrativa from public.estabelecimento
    where id = (select (r->>'id')::uuid from t_estab_min)),
  'Taguatinga', 'critério 3: cadastrar_estabelecimento aceita "taguatinga" e normaliza para Taguatinga');

create temp table t_vaga_scia as
  select pg_temp.publicar((select (r->>'id')::uuid from t_estab_a), -15.7942, -47.8822, 'SCIA / Estrutural') as r;
select is(
  (select regiao_administrativa from public.vaga
    where id = (select (r->>'vaga_id')::uuid from t_vaga_scia)),
  'SCIA', 'critério 3: publicar_vaga aceita "SCIA / Estrutural" e normaliza para SCIA');

-- ── 4. Região válida: o despacho e a distância seguem iguais ───────────────────

create temp table t_perto as
  select pg_temp.publicar((select (r->>'id')::uuid from t_estab_a), -15.7950, -47.8830, 'Taguatinga') as r;
create temp table t_longe as
  select pg_temp.publicar((select (r->>'id')::uuid from t_estab_a), -15.8300, -48.0500, 'Taguatinga') as r;

select is(
  (select regiao_administrativa from public.vaga where id = (select (r->>'vaga_id')::uuid from t_perto)),
  'Taguatinga', 'critério 4: a vaga em região válida grava a região informada');

select is(
  (select count(*)::int from pgmq.q_despacho
    where (message->>'vaga_id')::uuid in (select (r->>'vaga_id')::uuid from t_perto
                                          union all select (r->>'vaga_id')::uuid from t_longe)),
  2, 'critério 4: as duas vagas entram na fila do despacho');

create temp table t_lista as
  select pg_temp.como('d8000000-0000-4000-8000-000000000002',
    $$ select public.vagas_abertas(latitude => -15.7942, longitude => -47.8822) $$) as r;

select ok(
  (select (jsonb_path_query_first(r, '$[*] ? (@.id == $v).distancia_km',
             jsonb_build_object('v', (select r->>'vaga_id' from t_perto))) #>> '{}')::numeric
     from t_lista)
  <
  (select (jsonb_path_query_first(r, '$[*] ? (@.id == $v).distancia_km',
             jsonb_build_object('v', (select r->>'vaga_id' from t_longe))) #>> '{}')::numeric
     from t_lista),
  'critério 4: a distância calculada (RN05) é menor para a vaga perto que para a vaga longe');

select ok(
  (select (jsonb_path_query_first(r, '$[*] ? (@.id == $v).distancia_km',
             jsonb_build_object('v', (select r->>'vaga_id' from t_longe))) #>> '{}')::numeric
     from t_lista) > 5,
  'critério 4: a vaga em Taguatinga fica a mais de 5 km do ponto base, medida pela posição e não pela região');

select * from finish();
rollback;
