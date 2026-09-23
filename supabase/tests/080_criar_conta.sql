-- `criar_conta`: o passo entre "o código do e-mail foi confirmado" e "existe conta".
--
-- Depois do código, existe uma linha em `auth.users` e uma sessão — mas nenhuma conta
-- no produto. Esta é a função que fecha esse vão, e é onde RN20 (maioridade) e RN25
-- (um perfil por conta) são cobradas pela primeira vez, com o código de erro que o
-- aplicativo sabe ler em vez de um `23514` cru.

begin;
select plan(19);

-- Os `throws_like` daqui casam com o **código** do erro, não só com o `sqlstate`.
-- Uma revisão mediu o custo de conferir só o sqlstate: trocando
-- `erro(422,'menor_de_idade')` por `erro(500,'codigo_totalmente_errado')` a suíte
-- inteira continuava verde. Como esta é a primeira RPC do projeto e vira molde para as
-- treze do Sprint 1, o buraco se replicaria treze vezes.
--
-- O **status** não dá para conferir aqui: ele viaja no `DETAIL` e quem o traduz é o
-- PostgREST. Isso é trabalho do `scripts/ciclo-completo.sh`, que chama por HTTP.

-- Cria a credencial de autenticação e chama `criar_conta` como ela. É o mais perto que
-- um teste de banco chega do que o PostgREST faz: `auth.uid()` lê o `sub` do JWT.
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

select pg_temp.autenticar('f0000000-0000-4000-8000-000000000001','ana@t.test');
select pg_temp.autenticar('f0000000-0000-4000-8000-000000000002','ze@t.test');
select pg_temp.autenticar('f0000000-0000-4000-8000-000000000003','menor@t.test');
select pg_temp.autenticar('f0000000-0000-4000-8000-000000000004','outra@t.test');

-- ── Sem sessão não há conta ────────────────────────────────────────────────────
select throws_like(
  $$ select public.criar_conta('profissional','Ana','+5561999990001','1995-01-01','2026-09-22') $$,
  '%nao_autenticado%',
  'sem token não se cria conta');

-- ── O caminho feliz ────────────────────────────────────────────────────────────
create temp table r as select pg_temp.como('f0000000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('profissional','Ana Ribeiro','+5561999990001','1995-01-01','2026-09-22') $$) as j;

select is((select j->>'perfil' from r), 'profissional', 'a conta nasce com o perfil escolhido');
select is((select j->>'nome'   from r), 'Ana Ribeiro',  'e com o nome informado');
select is((select j->>'estado' from r), 'ativa',        'e ativa');

-- O e-mail vem da conta já confirmada pelo código, não da tela: é o único dado aqui que
-- o Auth já provou pertencer a quem está chamando.
select is((select j->>'email' from r), 'ana@t.test',
  'o e-mail é copiado de auth.users, e não aceito do cliente');

select is(
  (select termos_versao from public.usuario where id = 'f0000000-0000-4000-8000-000000000001'),
  '2026-09-22',
  'o aceite dos termos fica registrado com a versão');

select ok(
  (select termos_aceite_em from public.usuario where id = 'f0000000-0000-4000-8000-000000000001')
    between now() - interval '5 s' and now() + interval '5 s',
  'e com o instante carimbado pelo servidor — data de aceite enviada pelo cliente é forjável');

-- ── Idempotência ───────────────────────────────────────────────────────────────
--
-- A rede cai, o aplicativo reenvia. A chave natural é a própria credencial.
select is(
  pg_temp.como('f0000000-0000-4000-8000-000000000001',
    $$ select public.criar_conta('profissional','Ana Ribeiro','+5561999990001','1995-01-01','2026-09-22') $$)->>'id',
  'f0000000-0000-4000-8000-000000000001',
  'reenviar o mesmo cadastro devolve a mesma conta, sem criar outra');

select is(
  (select count(*)::int from public.usuario where id = 'f0000000-0000-4000-8000-000000000001'),
  1,
  'e continua havendo uma linha só');

-- RN25: o perfil não muda, nem por um reenvio com outro valor. Sobrescrever em silêncio
-- seria a pior resposta das três.
select throws_like(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000001',
       $x$ select public.criar_conta('contratante','Ana','+5561999990001','1995-01-01','2026-09-22') $x$) $$,
  '%conta_existente%',
  'RN25: reenviar com outro perfil é conflito, não atualização');

-- ── RN20: a maioridade é do banco, não da tela ─────────────────────────────────
select throws_like(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000003',
       $x$ select public.criar_conta('profissional','Menor','+5561999990003',
             (current_date - interval '17 years')::date, '2026-09-22') $x$) $$,
  '%menor_de_idade%',
  'RN20: menos de 18 anos é recusado, com o código que o aplicativo compara');

select is(
  (select count(*)::int from public.usuario where id = 'f0000000-0000-4000-8000-000000000003'),
  0,
  'e nada é gravado — a recusa acontece antes do insert');

select lives_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000003',
       $x$ select public.criar_conta('profissional','No limite','+5561999990003',
             (current_date - interval '18 years')::date, '2026-09-22') $x$) $$,
  'RN20: exatamente 18 anos entra');

-- ── Campos obrigatórios ────────────────────────────────────────────────────────
select throws_like(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000004',
       $x$ select public.criar_conta('profissional','Fulano','61999990004','1990-01-01','2026-09-22') $x$) $$,
  '%campo_obrigatorio%',
  'telefone fora do formato E.164 é recusado com código do contrato, não com 23514');

-- O aceite não é opcional: a App Store e a LGPD pedem o registro, e uma conta sem ele
-- é uma conta que ninguém consegue provar que concordou com nada.
select throws_like(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000004',
       $x$ select public.criar_conta('profissional','Fulano','+5561999990004','1990-01-01','  ') $x$) $$,
  '%campo_obrigatorio%',
  'sem o aceite dos termos não se cria conta');

-- ── RN25 nas duas contas da mesma pessoa ───────────────────────────────────────
--
-- Quem é garçom num fim de semana e opera o cadastro do buffet do cunhado no outro tem
-- duas contas, com dois e-mails. O telefone pode ser o mesmo.
select lives_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000002',
       $x$ select public.criar_conta('contratante','Zé','+5561999990001','1980-01-01','2026-09-22') $x$) $$,
  'RN25: a mesma pessoa cria a segunda conta, com outro e-mail e o mesmo telefone');

-- ── minha_conta ────────────────────────────────────────────────────────────────
--
-- O aplicativo pergunta isto ao abrir. Sem ela, manda para o cadastro quem já cadastrou.
select is(
  pg_temp.como('f0000000-0000-4000-8000-000000000002',
    'select public.minha_conta()')->>'perfil',
  'contratante',
  'minha_conta devolve a conta de quem chama');

select throws_like(
  $$ select pg_temp.como('f0000000-0000-4000-8000-000000000004',
       $x$ select public.minha_conta() $x$) $$,
  '%nao_encontrado%',
  'e recusa quem tem sessão mas ainda não criou conta — é assim que o aplicativo sabe mandar para o cadastro');

-- ── O que a resposta não pode trazer ───────────────────────────────────────────
--
-- O schema `Usuario` do contrato tem sete campos. Devolver a linha inteira vazaria o
-- aceite, a data de criação e o carimbo de anonimização para a tela.
select is(
  (select count(*)::int from jsonb_object_keys(
     pg_temp.como('f0000000-0000-4000-8000-000000000002','select public.minha_conta()')) k
    where k not in ('id','perfil','nome','telefone','email','nascimento','estado')),
  0,
  'a resposta traz exatamente os campos do schema Usuario do contrato');

select * from finish();
rollback;
