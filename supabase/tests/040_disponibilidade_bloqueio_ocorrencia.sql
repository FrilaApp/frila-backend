-- A grade semanal, o bloqueio, a ocorrência e o catálogo.

begin;
select plan(11);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('cccccccc-0000-0000-0000-000000000001','profissional','Ana','+5561999990001','ana@t.test','1995-01-01', '2026-09-22', now()),
  ('cccccccc-0000-0000-0000-000000000002','profissional','Beto','+5561999990002','beto@t.test','1995-01-01', '2026-09-22', now());

insert into public.profissional (usuario_id, ponto_base) values
  ('cccccccc-0000-0000-0000-000000000001','POINT(-47.88 -15.79)'::extensions.geography),
  ('cccccccc-0000-0000-0000-000000000002','POINT(-47.88 -15.79)'::extensions.geography);

create temp table p as
  select id from public.profissional where usuario_id = 'cccccccc-0000-0000-0000-000000000001';

-- ── A janela que vira a noite ──────────────────────────────────────────────────
--
-- Um bar fecha às 2h. A janela 18:00–02:00 é a mais comum do setor, não uma exceção.
-- Quem escreve CHECK (hora_fim > hora_inicio) por reflexo exclui do produto justamente
-- o turno que ele existe para preencher.
select lives_ok(
  $$ insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
     select id, 5, '18:00', '02:00' from p $$,
  'a grade aceita a janela que atravessa a meia-noite');

select lives_ok(
  $$ insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
     select id, 6, '08:00', '16:00' from p $$,
  'a grade aceita a janela comum');

select throws_ok(
  $$ insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
     select id, 0, '18:00', '18:00' from p $$,
  '23514',
  null,
  'janela de duração zero não é disponibilidade');

select throws_ok(
  $$ insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
     select id, 7, '18:00', '22:00' from p $$,
  '23514',
  null,
  'o dia da semana vai de 0 (domingo) a 6');

-- ── Bloqueio ──────────────────────────────────────────────────────────────────
select throws_ok(
  $$ insert into public.bloqueio (autor_id, bloqueado_id)
     values ('cccccccc-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001') $$,
  '23514',
  null,
  'ninguém bloqueia a si mesmo');

insert into public.bloqueio (autor_id, bloqueado_id)
values ('cccccccc-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000002');

select throws_ok(
  $$ insert into public.bloqueio (autor_id, bloqueado_id)
     values ('cccccccc-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000002') $$,
  '23505',
  null,
  'bloquear duas vezes é o mesmo bloqueio — a chave natural torna a operação idempotente');

-- ── Ocorrência ────────────────────────────────────────────────────────────────
--
-- `motivo` nunca vazio é o que impede a suspensão silenciosa, queixa recorrente nos
-- concorrentes pesquisados (RN12, RN13).
select throws_ok(
  $$ insert into public.ocorrencia (tipo, autor_id, motivo)
     values ('suspensao','cccccccc-0000-0000-0000-000000000001','   ') $$,
  '23514',
  null,
  'RN13: não existe ocorrência sem motivo declarado');

insert into public.ocorrencia (tipo, autor_id, motivo, chave_cliente)
values ('denuncia','cccccccc-0000-0000-0000-000000000001','Assédio no local',
        'dddddddd-0000-0000-0000-000000000001');

select throws_ok(
  $$ insert into public.ocorrencia (tipo, autor_id, motivo, chave_cliente)
     values ('denuncia','cccccccc-0000-0000-0000-000000000001','Assédio no local',
             'dddddddd-0000-0000-0000-000000000001') $$,
  '23505',
  null,
  'a mesma chave do cliente não registra duas denúncias');

-- ── Catálogo ──────────────────────────────────────────────────────────────────
--
-- Fechado, nunca texto livre: se o profissional digita "garçom", "garcom" e
-- "Garçonete", a elegibilidade de RN05 vira busca por aproximação.
select is(
  (select count(*)::int from public.funcao),
  32,
  'o catálogo tem as 32 funções da Modelagem');

select is(
  (select count(distinct categoria)::int from public.funcao),
  7,
  'em 7 categorias');

select throws_ok(
  $$ insert into public.funcao (nome, categoria) values ('garçom', 'Salão') $$,
  '23505',
  null,
  'o nome da função é único: não há "garçom" e "garcom" ao mesmo tempo');

select * from finish();
rollback;
