-- Sinal de idade do cadastro (ECA Digital, cartão LQlwDaYZ): `criar_conta` aceita o
-- parâmetro opcional `sinal_idade` e grava só a faixa, o método e o instante.
--
-- O que este arquivo prova, na ordem:
--   1. cada um dos três valores aceitos grava as três colunas, com o método derivado;
--   2. nada disso volta na resposta de `criar_conta` nem de `minha_conta`;
--   3. sem o parâmetro (o app de hoje) e com `null` explícito, a conta nasce igual à de
--      antes, com as três colunas nulas;
--   4. valor fora da lista é `422 campo_invalido` com `details: sinal_idade`, sem gravar;
--   5. o reenvio idempotente não reescreve o sinal;
--   6. nada além das três colunas é gravado;
--   7. os dois CHECKs seguram o que a RPC não alcança (escrita por fora);
--   8. quem lê o quê: o dono lê a própria linha, outra conta e `anon` não.

begin;
select plan(23);

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

-- As três colunas da linha, como o banco as guardou.
create function pg_temp.sinal(conta uuid) returns jsonb
language sql as $$
  select jsonb_build_object('sinal_idade',       u.sinal_idade,
                            'idade_aferida_por', u.idade_aferida_por,
                            'idade_aferida_em',  u.idade_aferida_em)
    from public.usuario u where u.id = conta
$$;

-- Relógio do produto fixo: `idade_aferida_em` tem de ser **este** instante, e não um
-- `now()` que passaria em qualquer teste de janela.
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2026-10-18 15:00:00-03', true);

select pg_temp.autenticar('f0000000-0000-4000-8000-0000000007a1', 'aparelho@t.test');
select pg_temp.autenticar('f0000000-0000-4000-8000-0000000007a2', 'recusou@t.test');
select pg_temp.autenticar('f0000000-0000-4000-8000-0000000007a3', 'indisponivel@t.test');
select pg_temp.autenticar('f0000000-0000-4000-8000-0000000007a4', 'app-de-hoje@t.test');
select pg_temp.autenticar('f0000000-0000-4000-8000-0000000007a5', 'nulo-explicito@t.test');
select pg_temp.autenticar('f0000000-0000-4000-8000-0000000007a6', 'invalido@t.test');
select pg_temp.autenticar('f0000000-0000-4000-8000-0000000007a7', 'outra-conta@t.test');

-- ── 1. Os três valores aceitos ─────────────────────────────────────────────────

create temp table r1 as select pg_temp.como('f0000000-0000-4000-8000-0000000007a1',
  $$ select public.criar_conta('profissional','Ana Aparelho','+5561999990701','1995-01-01','2026-10-15','dezoito_ou_mais') $$) as j;

select is(
  pg_temp.sinal('f0000000-0000-4000-8000-0000000007a1'),
  jsonb_build_object('sinal_idade', 'dezoito_ou_mais', 'idade_aferida_por', 'aparelho',
                     'idade_aferida_em', privado.agora()),
  'dezoito_ou_mais: faixa gravada, método "aparelho", instante do relógio do produto');

select pg_temp.como('f0000000-0000-4000-8000-0000000007a2',
  $$ select public.criar_conta('profissional','Bia Recusou','+5561999990702','1995-01-01','2026-10-15','recusou') $$);

select is(
  pg_temp.sinal('f0000000-0000-4000-8000-0000000007a2'),
  jsonb_build_object('sinal_idade', 'recusou', 'idade_aferida_por', 'declaracao',
                     'idade_aferida_em', privado.agora()),
  'recusou: quem não compartilha a faixa não é menor por isso; vale a declaração (data + termos)');

select pg_temp.como('f0000000-0000-4000-8000-0000000007a3',
  $$ select public.criar_conta('profissional','Caio Sem Sinal','+5561999990703','1995-01-01','2026-10-15','indisponivel') $$);

select is(
  pg_temp.sinal('f0000000-0000-4000-8000-0000000007a3'),
  jsonb_build_object('sinal_idade', 'indisponivel', 'idade_aferida_por', 'declaracao',
                     'idade_aferida_em', privado.agora()),
  'indisponivel (iOS 17 a 26.1): método "declaracao", como no parecer');

-- ── 2. Nada de idade volta para a tela ─────────────────────────────────────────
--
-- O schema `Usuario` do contrato tem sete campos. A faixa, o método e o instante são
-- prova de conformidade, não dado do perfil: nem o dono os recebe por aqui.
select is(
  (select count(*)::int from jsonb_object_keys((select j from r1)) k
    where k not in ('id','perfil','nome','telefone','email','nascimento','estado')),
  0,
  'a resposta de criar_conta com sinal_idade traz só os sete campos do schema Usuario');

select is(
  (select count(*)::int from jsonb_object_keys(
     pg_temp.como('f0000000-0000-4000-8000-0000000007a1', 'select public.minha_conta()')) k
    where k not in ('id','perfil','nome','telefone','email','nascimento','estado')),
  0,
  'e minha_conta também não devolve sinal_idade, idade_aferida_por nem idade_aferida_em');

-- ── 3. Retrocompatível: o app de hoje não envia o parâmetro ────────────────────

select lives_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-0000000007a4',
       $x$ select public.criar_conta('profissional','Caio Sem Sinal','+5561999990703','1995-01-01','2026-10-15') $x$) $$,
  'a chamada de cinco argumentos, a que o app de hoje faz, continua funcionando');

select is(
  pg_temp.sinal('f0000000-0000-4000-8000-0000000007a4'),
  '{"sinal_idade": null, "idade_aferida_por": null, "idade_aferida_em": null}'::jsonb,
  'e sem o parâmetro as três colunas ficam nulas, como nas contas antigas');

select lives_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-0000000007a5',
       $x$ select public.criar_conta('profissional','Dani Nulo','+5561999990705','1995-01-01','2026-10-15', null) $x$) $$,
  'null explícito também é aceito');

select is(
  pg_temp.sinal('f0000000-0000-4000-8000-0000000007a5'),
  '{"sinal_idade": null, "idade_aferida_por": null, "idade_aferida_em": null}'::jsonb,
  'e é tratado como ausência: nada de método nem instante sem faixa');

-- ── 4. Valor fora da lista ─────────────────────────────────────────────────────
--
-- `abaixo_de_18` é o caso que mais importa recusar: o app bloqueia antes de chamar, e um
-- servidor que o gravasse estaria registrando um menor que entrou — em vez de um que foi
-- barrado. Valor desconhecido é erro do cliente, com o código que a tela sabe ler.
select throws_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-0000000007a6',
       $x$ select public.criar_conta('profissional','Edu Inválido','+5561999990706','1995-01-01','2026-10-15','abaixo_de_18') $x$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "sinal_idade", "hint" : null}',
  'abaixo_de_18 não é valor aceito: 422 campo_invalido com details sinal_idade');

select throws_ok(
  $$ select pg_temp.como('f0000000-0000-4000-8000-0000000007a6',
       $x$ select public.criar_conta('profissional','Edu Inválido','+5561999990706','1995-01-01','2026-10-15','') $x$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "sinal_idade", "hint" : null}',
  'texto vazio também é inválido — ausência é null, não string vazia');

select is(
  (select count(*)::int from public.usuario where id = 'f0000000-0000-4000-8000-0000000007a6'),
  0,
  'e a recusa acontece antes do insert: nada é gravado');

-- ── 5. Reenvio idempotente não reescreve o sinal ───────────────────────────────
--
-- A rede cai, o app reenvia; se vier outro valor, a conta que já existe é devolvida e a
-- prova original fica como estava — ela diz o que o aparelho respondeu **no cadastro**.
select pg_temp.como('f0000000-0000-4000-8000-0000000007a1',
  $$ select public.criar_conta('profissional','Ana Aparelho','+5561999990701','1995-01-01','2026-10-15','recusou') $$);

select is(
  pg_temp.sinal('f0000000-0000-4000-8000-0000000007a1')->>'sinal_idade',
  'dezoito_ou_mais',
  'reenviar com outro sinal devolve a conta existente e mantém o sinal do cadastro');

-- ── 6. Nada além do pedido é gravado ───────────────────────────────────────────
--
-- Mesmo nome, telefone, nascimento, termos e relógio: a linha criada com o sinal e a
-- criada sem ele só podem diferir nas três colunas — mais id e e-mail, que são da conta,
-- e `criado_em`, que é `now()` de verdade e muda a cada insert.
select is(
  (select to_jsonb(u) - 'id' - 'email' - 'criado_em' - 'sinal_idade' - 'idade_aferida_por' - 'idade_aferida_em'
     from public.usuario u where u.id = 'f0000000-0000-4000-8000-0000000007a3'),
  (select to_jsonb(u) - 'id' - 'email' - 'criado_em' - 'sinal_idade' - 'idade_aferida_por' - 'idade_aferida_em'
     from public.usuario u where u.id = 'f0000000-0000-4000-8000-0000000007a4'),
  'com ou sem sinal, a linha de usuario é a mesma fora das três colunas — nada mais foi gravado');

select is(
  (select array_agg(column_name::text order by column_name)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'usuario'
      and (column_name like '%idade%' or column_name like '%sinal%' or column_name like '%aparelho%')),
  array['idade_aferida_em', 'idade_aferida_por', 'sinal_idade'],
  'em usuario, as colunas de idade são exatamente as três do cartão: nem data nem identificador do aparelho');

-- ── 7. Os CHECKs seguram a escrita por fora da RPC ─────────────────────────────
--
-- `sinal_idade_valores` é o que o cartão pede. `idade_aferida_coerente` é o que faz a
-- prova valer: sem ele, um `update` deixaria "aparelho" num sinal de recusa.
select throws_ok(
  $$ insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                                 termos_versao, termos_aceite_em,
                                 sinal_idade, idade_aferida_por, idade_aferida_em)
     values ('f0000000-0000-4000-8000-0000000007a6', 'profissional', 'Edu Inválido',
             '+5561999990706', 'invalido@t.test', '1995-01-01', '2026-10-15', privado.agora(),
             'abaixo_de_18', 'declaracao', privado.agora()) $$,
  '23514', null,
  'CHECK sinal_idade_valores: abaixo_de_18 não entra nem por insert direto');

select throws_ok(
  $$ insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                                 termos_versao, termos_aceite_em,
                                 sinal_idade, idade_aferida_por, idade_aferida_em)
     values ('f0000000-0000-4000-8000-0000000007a6', 'profissional', 'Edu Inválido',
             '+5561999990706', 'invalido@t.test', '1995-01-01', '2026-10-15', privado.agora(),
             'recusou', 'aparelho', privado.agora()) $$,
  '23514', null,
  'CHECK idade_aferida_coerente: "aparelho" só com dezoito_ou_mais');

select throws_ok(
  $$ insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                                 termos_versao, termos_aceite_em,
                                 sinal_idade, idade_aferida_por, idade_aferida_em)
     values ('f0000000-0000-4000-8000-0000000007a6', 'profissional', 'Edu Inválido',
             '+5561999990706', 'invalido@t.test', '1995-01-01', '2026-10-15', privado.agora(),
             'dezoito_ou_mais', 'aparelho', null) $$,
  '23514', null,
  'CHECK idade_aferida_coerente: faixa sem instante não é prova');

select throws_ok(
  $$ insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                                 termos_versao, termos_aceite_em,
                                 sinal_idade, idade_aferida_por, idade_aferida_em)
     values ('f0000000-0000-4000-8000-0000000007a6', 'profissional', 'Edu Inválido',
             '+5561999990706', 'invalido@t.test', '1995-01-01', '2026-10-15', privado.agora(),
             null, 'declaracao', privado.agora()) $$,
  '23514', null,
  'CHECK idade_aferida_coerente: método e instante sem faixa também não');

-- ── 8. Quem lê o quê ───────────────────────────────────────────────────────────
--
-- RLS filtra linha, não coluna: a política `usuario_leitura` abre a própria linha para
-- o dono, inteira. As três colunas ficam, portanto, visíveis **só** a quem elas
-- descrevem — e a nenhuma outra conta, nem à chave publicável.
select is(
  pg_temp.como('f0000000-0000-4000-8000-0000000007a1',
    $$ select jsonb_build_object('sinal_idade', u.sinal_idade)
         from public.usuario u where u.id = 'f0000000-0000-4000-8000-0000000007a1' $$)->>'sinal_idade',
  'dezoito_ou_mais',
  'o dono lê o próprio sinal_idade pela linha que a RLS já lhe abre');

select is(
  pg_temp.como('f0000000-0000-4000-8000-0000000007a7',
    $$ select jsonb_build_object('n', count(*))
         from public.usuario u where u.id = 'f0000000-0000-4000-8000-0000000007a1' $$)->>'n',
  '0',
  'outra conta autenticada não enxerga a linha, logo nem as três colunas');

select is(
  has_table_privilege('anon', 'public.usuario', 'select'),
  false,
  'anon não tem select em usuario: a chave publicável não alcança o sinal');

-- Uma função só, com o parâmetro opcional. Com duas (a antiga de cinco argumentos e a
-- nova de seis), o PostgREST casaria as duas no corpo de cinco campos e recusaria a
-- chamada do app de hoje por ambiguidade.
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'criar_conta'),
  1,
  'existe uma única criar_conta: a assinatura antiga foi substituída, não duplicada');

select * from finish();
rollback;
