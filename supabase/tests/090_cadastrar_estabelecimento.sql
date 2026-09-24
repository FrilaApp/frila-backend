-- `cadastrar_estabelecimento`: a conta de contratante passa a ter por quem contratar.
--
-- É a primeira escrita do lado de quem publica. Três regras são cobradas aqui pela
-- primeira vez, com o código que o aplicativo compara:
--
--   RN25  conta de profissional não cadastra estabelecimento (422 perfil_incompativel)
--   RF02  CPF ou CNPJ conferido pelo dígito verificador, e um documento por cadastro
--   RF21  quem cadastra vira administrador — o estabelecimento nasce com responsável
--
-- Cada recusa é conferida nos dois eixos, como em 080_criar_conta.sql: o `sqlstate`
-- `PGRST` e o envelope inteiro, que fixa `code` e `details`.
--
-- Documentos usados, todos com dígito verificador calculado à parte:
--   CNPJ válidos  11222333000181 · 45223011000179 · 19131905000129
--   CPF  válidos  52998224725 · 11144477735
--   inválidos     11222333000182 (CNPJ, último dígito trocado)
--                 52998224724    (CPF, último dígito trocado)

begin;
select plan(27);

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

-- a1: contratante que cadastra · a2: outro contratante · p1: profissional
select pg_temp.autenticar('e0000000-0000-4000-8000-0000000000a1','dona@t.test');
select pg_temp.autenticar('e0000000-0000-4000-8000-0000000000a2','outro@t.test');
select pg_temp.autenticar('e0000000-0000-4000-8000-0000000000b1','garcom@t.test');

select pg_temp.como('e0000000-0000-4000-8000-0000000000a1',
  $$ select public.criar_conta('contratante','Dona do Bar','+5561999990101','1980-01-01','2026-09-22') $$);
select pg_temp.como('e0000000-0000-4000-8000-0000000000a2',
  $$ select public.criar_conta('contratante','Outro Dono','+5561999990102','1981-01-01','2026-09-22') $$);
select pg_temp.como('e0000000-0000-4000-8000-0000000000b1',
  $$ select public.criar_conta('profissional','Garçom','+5561999990103','1995-01-01','2026-09-22') $$);

-- ── Sem sessão não há cadastro ─────────────────────────────────────────────────
select throws_ok(
  $$ select public.cadastrar_estabelecimento('Bar do Zé','11222333000181','food_service',
       'SCLN 405, Asa Norte','{"latitude":-15.78,"longitude":-47.88}') $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não se cadastra estabelecimento');

-- ── RN25: conta de profissional é recusada ─────────────────────────────────────
select throws_ok(
  $$ select pg_temp.como('e0000000-0000-4000-8000-0000000000b1',
       $x$ select public.cadastrar_estabelecimento('Bar do Garçom','45223011000179','food_service',
             'SCLN 405, Asa Norte','{"latitude":-15.78,"longitude":-47.88}') $x$) $$,
  'PGRST',
  '{"code" : "perfil_incompativel", "message" : "perfil_incompativel", "details" : null, "hint" : null}',
  'RN25: conta de profissional não cadastra estabelecimento (422 perfil_incompativel)');

select is(
  (select count(*)::int from public.estabelecimento where documento = '45223011000179'),
  0,
  'RN25: e nada é gravado — a recusa vem antes do insert');

-- ── O caminho feliz ────────────────────────────────────────────────────────────
create temp table r as select pg_temp.como('e0000000-0000-4000-8000-0000000000a1',
  $$ select public.cadastrar_estabelecimento('  Bar do Zé  ','11222333000181','food_service',
       'SCLN 405, Asa Norte','{"latitude":-15.7942,"longitude":-47.8822}') $$) as j;

select is((select j->>'papel' from r), 'administrador',
  'RF21: quem cadastra aparece como administrador na resposta');

select is(
  (select m.papel::text from public.membro_estabelecimento m
    where m.usuario_id = 'e0000000-0000-4000-8000-0000000000a1'
      and m.estabelecimento_id = (select (j->>'id')::uuid from r)),
  'administrador',
  'RF21: e o membro_estabelecimento administrador existe de fato no banco');

select is((select j->>'nome' from r), 'Bar do Zé', 'o nome é gravado sem os espaços das pontas');
select is((select j->>'documento' from r), '11222333000181', 'o documento volta para quem cadastrou');
select is((select j->>'tipo' from r), 'food_service', 'o tipo é o escolhido');
select is((select j->>'endereco' from r), 'SCLN 405, Asa Norte', 'o endereço é o informado');

-- A Coordenada do contrato vai e volta sem trocar latitude por longitude. Trocar as
-- duas põe o bar no meio do oceano Índico e desliga a elegibilidade por distância (RN05).
select is(
  (select round((j->'ponto'->>'latitude')::numeric, 4)  from r), -15.7942::numeric,
  'o ponto volta com a mesma latitude');
select is(
  (select round((j->'ponto'->>'longitude')::numeric, 4) from r), -47.8822::numeric,
  'e com a mesma longitude');

-- O schema `Estabelecimento` do contrato tem sete campos. A linha inteira vazaria a
-- reputação crua e a data de criação.
select is(
  (select array_agg(k order by k) from r, jsonb_object_keys(r.j) k),
  array['documento','endereco','id','nome','papel','ponto','tipo'],
  'a resposta traz exatamente os campos do schema Estabelecimento do contrato');

-- ── Idempotência pela chave natural ────────────────────────────────────────────
--
-- A rede cai e o app reenvia. O documento é a chave natural: o mesmo administrador
-- reenviando recebe o mesmo estabelecimento, e não um 409 que o faria achar que
-- alguém tomou o CNPJ dele.
select is(
  pg_temp.como('e0000000-0000-4000-8000-0000000000a1',
    $$ select public.cadastrar_estabelecimento('Bar do Zé','11222333000181','food_service',
         'SCLN 405, Asa Norte','{"latitude":-15.7942,"longitude":-47.8822}') $$)->>'id',
  (select j->>'id' from r),
  'reenviar o mesmo cadastro devolve o mesmo estabelecimento');

select is(
  (select count(*)::int from public.estabelecimento where documento = '11222333000181'),
  1,
  'e continua havendo uma linha só');

-- ── Documento repetido por outra conta ─────────────────────────────────────────
select throws_ok(
  $$ select pg_temp.como('e0000000-0000-4000-8000-0000000000a2',
       $x$ select public.cadastrar_estabelecimento('Outro Bar','11222333000181','food_service',
             'Outro endereço','{"latitude":-15.78,"longitude":-47.88}') $x$) $$,
  'PGRST',
  '{"code" : "documento_ja_cadastrado", "message" : "documento_ja_cadastrado", "details" : null, "hint" : null}',
  'documento já cadastrado por outra conta é 409 documento_ja_cadastrado');

select is(
  (select count(*)::int from public.membro_estabelecimento
    where usuario_id = 'e0000000-0000-4000-8000-0000000000a2'),
  0,
  'e a outra conta não vira membro de nada');

-- ── RF02: o dígito verificador ─────────────────────────────────────────────────
--
-- O código de erro segue o catálogo do contrato 0.2.1, que é o da main: `campo_obrigatorio`
-- com `details = documento`, como `criar_conta` faz com o telefone fora do E.164. O
-- cartão pede `campo_invalido`, que só existe no contrato 0.2.2 (PR #7, aberto). Quando
-- o 0.2.2 entrar, o código muda nesta asserção e numa linha da função.
select throws_ok(
  $$ select pg_temp.como('e0000000-0000-4000-8000-0000000000a2',
       $x$ select public.cadastrar_estabelecimento('Bar Errado','11222333000182','food_service',
             'SCLN 405','{"latitude":-15.78,"longitude":-47.88}') $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "documento", "hint" : null}',
  'RF02: CNPJ com dígito verificador errado é recusado com details = documento');

select throws_ok(
  $$ select pg_temp.como('e0000000-0000-4000-8000-0000000000a2',
       $x$ select public.cadastrar_estabelecimento('Diarista da Ana','52998224724','servico_domestico',
             'QI 5, Lago Sul','{"latitude":-15.83,"longitude":-47.87}') $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "documento", "hint" : null}',
  'RF02: CPF com dígito verificador errado é recusado com details = documento');

-- Sequência repetida passa na conta do dígito verificador — 111.111.111-11 fecha certo —
-- e é o primeiro número que alguém digita para "ver se passa".
select throws_ok(
  $$ select pg_temp.como('e0000000-0000-4000-8000-0000000000a2',
       $x$ select public.cadastrar_estabelecimento('Teste','11111111111','outro',
             'Algum lugar','{"latitude":-15.78,"longitude":-47.88}') $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "documento", "hint" : null}',
  'RF02: CPF de dígitos todos iguais é recusado, mesmo fechando o dígito verificador');

-- Pontuação e tamanho errado: o contrato pede só dígitos. Sem esta recusa, o CHECK da
-- tabela levantaria 23514, que o aplicativo não sabe ler.
select throws_ok(
  $$ select pg_temp.como('e0000000-0000-4000-8000-0000000000a2',
       $x$ select public.cadastrar_estabelecimento('Teste','11.222.333/0001-81','outro',
             'Algum lugar','{"latitude":-15.78,"longitude":-47.88}') $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "documento", "hint" : null}',
  'RF02: documento com pontuação é recusado com o código do contrato, não com 23514');

-- O outro lado do dígito verificador: CPF certo entra. Serviço doméstico também
-- contrata pelo Frila.
select is(
  pg_temp.como('e0000000-0000-4000-8000-0000000000a2',
    $$ select public.cadastrar_estabelecimento('Casa da Ana','52998224725','servico_domestico',
         'QI 5, Lago Sul','{"latitude":-15.83,"longitude":-47.87}') $$)->>'papel',
  'administrador',
  'RF02: CPF com dígito verificador certo é aceito');

select ok(
  privado.documento_valido('19131905000129') and privado.documento_valido('11144477735')
    and not privado.documento_valido('00000000000000')
    and not privado.documento_valido(null),
  'a conferência aceita outros CNPJ e CPF válidos e recusa zeros e nulo');

-- ── Campos obrigatórios ────────────────────────────────────────────────────────
select throws_ok(
  $$ select pg_temp.como('e0000000-0000-4000-8000-0000000000a2',
       $x$ select public.cadastrar_estabelecimento('   ','19131905000129','varejo',
             'Algum lugar','{"latitude":-15.78,"longitude":-47.88}') $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "nome", "hint" : null}',
  'nome em branco é campo_obrigatorio com details = nome');

select throws_ok(
  $$ select pg_temp.como('e0000000-0000-4000-8000-0000000000a2',
       $x$ select public.cadastrar_estabelecimento('Loja','19131905000129','varejo',
             '','{"latitude":-15.78,"longitude":-47.88}') $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "endereco", "hint" : null}',
  'endereço em branco é campo_obrigatorio com details = endereco');

select throws_ok(
  $$ select pg_temp.como('e0000000-0000-4000-8000-0000000000a2',
       $x$ select public.cadastrar_estabelecimento('Loja','19131905000129','varejo',
             'Algum lugar','{"latitude":-95,"longitude":-47.88}') $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "ponto", "hint" : null}',
  'latitude fora de -90..90 é recusada com details = ponto');

-- ── O documento não sai para outra conta ───────────────────────────────────────
select is(
  pg_temp.como('e0000000-0000-4000-8000-0000000000b1',
    $$ select to_jsonb(count(*)) from public.estabelecimento $$)::int,
  0,
  'o profissional não lê linha nenhuma de estabelecimento, e com ela o documento');

select is(
  pg_temp.como('e0000000-0000-4000-8000-0000000000a2',
    $$ select to_jsonb(count(*)) from public.estabelecimento where documento = '11222333000181' $$)::int,
  0,
  'o contratante de outro estabelecimento também não lê o documento alheio');

select * from finish();
rollback;
