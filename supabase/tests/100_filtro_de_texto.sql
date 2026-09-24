-- O filtro de texto ofensivo (diretriz 1.2 da App Store).
--
-- Dois erros são possíveis aqui, e eles não custam a mesma coisa.
--
-- O falso negativo — texto ofensivo que passa — tem denúncia e bloqueio atrás dele
-- (RF26): alguém vê, alguém reporta, e o sistema tem o que fazer.
--
-- O falso positivo — nome de gente recusado no cadastro — não tem nada atrás. A pessoa
-- tenta se cadastrar, é recusada por um motivo que ela não entende, e vai embora. Não
-- existe fila de recurso, não existe atendimento, e ninguém no time fica sabendo.
--
-- Por isso metade deste arquivo mede o que o filtro **aceita**.

begin;
select plan(26);

-- ── Normalização ──────────────────────────────────────────────────────────────

select is(privado.normalizar('Ana Ribeiro'), 'ana ribeiro',
  'minúsculas');
select is(privado.normalizar('JOÃO ÁVILA'), 'joao avila',
  'sem acento, e em minúsculas');
select is(privado.normalizar('Conceição'), 'conceicao',
  'o cedilha vira c');
select is(privado.normalizar('  Ana   Maria  '), 'ana maria',
  'espaço repetido colapsa, e as pontas somem');
select is(privado.normalizar('e-mail@teste.com'), 'e mail teste com',
  'pontuação vira espaço');

-- Se a pontuação virasse vazio, `a.cu.rado` viraria `acurado`; e o contrário, um texto
-- montado com pontos no meio de um termo, casaria por acidente.
select is(privado.normalizar('abc.def'), 'abc def',
  'pontuação separa, não junta: abc.def não pode virar abcdef');

select is(privado.normalizar(null), null,
  'nulo entra, nulo sai');

-- ── A lista existe e está gravada na forma que o filtro compara ──────────────

select cmp_ok((select count(*)::int from privado.termo_bloqueado), '>', 20,
  'a lista de partida tem termos');

-- Termo gravado com acento ou maiúscula nunca casaria com nada, e o filtro pareceria
-- instalado sem estar. O CHECK da tabela impede; esta asserção mede que ele impede.
select is(
  (select count(*)::int from privado.termo_bloqueado
    where termo <> privado.normalizar(termo)),
  0,
  'todo termo está gravado já normalizado');

select throws_ok(
  $$ insert into privado.termo_bloqueado (termo, categoria) values ('Porra', 'palavrao') $$,
  '23514',
  null,
  'a tabela recusa termo fora da forma normalizada');

-- Termo de uma letra casaria com metade do português, e um `a` na lista recusaria todo
-- nome que tivesse um `a` solto. A restrição é barata e o estrago que ela evita não.
select throws_ok(
  $$ insert into privado.termo_bloqueado (termo, categoria) values ('a', 'palavrao') $$,
  '23514',
  null,
  'e recusa termo de uma letra só');

-- ── O filtro recusa ───────────────────────────────────────────────────────────

select ok(not privado.texto_aceitavel('caralho'),
  'recusa o termo sozinho');
select ok(not privado.texto_aceitavel('Ana Caralho Silva'),
  'recusa o termo no meio de um texto');
select ok(not privado.texto_aceitavel('CARALHO'),
  'recusa em maiúsculas');
select ok(not privado.texto_aceitavel('Você é um Otário!'),
  'recusa com acento e pontuação em volta');

-- Termo de duas palavras: se a comparação fosse token a token, este passaria.
select ok(not privado.texto_aceitavel('procura-se garota de programa'),
  'recusa termo composto de mais de uma palavra');

-- ── O filtro aceita: a metade que custa caro errar ───────────────────────────
--
-- `cu` está na lista, e está dentro de Cunha, Cuiabá, curso, cuidado e açucar. Um
-- filtro por substring recusaria os cinco. Estas asserções existem para que ninguém
-- reintroduza `like '%termo%'` achando que está apertando a segurança.

select ok(privado.texto_aceitavel('Ana Cunha'),
  'FALSO POSITIVO: Cunha é sobrenome, e contém um termo da lista');
select ok(privado.texto_aceitavel('Buffet Cuiabá'),
  'FALSO POSITIVO: Cuiabá contém o mesmo termo');
select ok(privado.texto_aceitavel('curso de bartender'),
  'FALSO POSITIVO: curso contém o mesmo termo');
select ok(privado.texto_aceitavel('levar cuidado com o material'),
  'FALSO POSITIVO: cuidado também');

-- Sobrenomes que ficaram deliberadamente fora da lista, e que precisam continuar fora.
-- Se alguém acrescentar `pinto` sem ler o comentário do seed, esta asserção reprova.
select ok(privado.texto_aceitavel('Rodrigo Pinto'),
  'Pinto é sobrenome comuníssimo e não está na lista, por decisão');

select ok(privado.texto_aceitavel(null),
  'nulo é aceitável: ausência é assunto de campo_obrigatorio, não deste filtro');
select ok(privado.texto_aceitavel(''),
  'vazio também');

-- ── criar_conta: o primeiro ponto de uso ─────────────────────────────────────

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

select pg_temp.autenticar('c1000000-0000-4000-8000-000000000001','filtro-a@t.test');
select pg_temp.autenticar('c1000000-0000-4000-8000-000000000002','filtro-b@t.test');

-- Conferido nos dois eixos, como toda recusa deste repositório: o `sqlstate` `PGRST`,
-- que é o que faz o PostgREST traduzir em vez de devolver 500, e o envelope inteiro,
-- que fixa o `code` e o `details`. Só o `sqlstate` deixaria passar `campo_obrigatorio`
-- no lugar de `campo_invalido`, e a tela mostraria "preencha o nome" para quem
-- preencheu.
select throws_ok(
  $$ select pg_temp.como('c1000000-0000-4000-8000-000000000001',
       $c$ select public.criar_conta('profissional','Ana Caralho','+5561999990301','1995-01-01','2026-09-22') $c$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "nome", "hint" : null}',
  'diretriz 1.2: nome com termo da lista sai como campo_invalido, com o campo no details');

-- Nome vazio continua saindo como `campo_obrigatorio`, e não como `campo_invalido`: a
-- ordem das duas conferências é parte do contrato, porque a tela mostra texto diferente
-- para "faltou" e para "não serve".
select throws_ok(
  $$ select pg_temp.como('c1000000-0000-4000-8000-000000000001',
       $c$ select public.criar_conta('profissional',' ','+5561999990301','1995-01-01','2026-09-22') $c$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "nome", "hint" : null}',
  'nome ausente continua sendo campo_obrigatorio, e não campo_invalido');

-- O caso que o critério de aceite do cartão pede por escrito.
select is(
  (select pg_temp.como('c1000000-0000-4000-8000-000000000002',
     $c$ select public.criar_conta('profissional','Ana Cunha','+5561999990302','1995-01-01','2026-09-22') $c$) ->> 'nome'),
  'Ana Cunha',
  'e o sobrenome que contém parte de um termo cadastra normalmente');

select * from finish();
rollback;
