-- 812_validar_regiao_administrativa_f2.sql
--
-- Validar regiao_administrativa (RN44). Brief B2, Fase 2: VALIDATE das chaves estrangeiras que
-- a Fase 1 (20261108040000) instalou NOT VALID. Ids próprios, começando em `d8120000`.
--
-- O que este arquivo prova:
--   1. Depois da migração, as duas chaves estão validadas (convalidated = true) e o banco recusa
--      região fora do catálogo com 23503.
--   2. O motivo da ordem da migração: com resíduo legado fora do catálogo (escrita em voo da
--      Fase 1), VALIDATE sozinho falha com 23503; depois da conciliação, VALIDATE passa, o
--      resíduo vira 'Plano Piloto' e o texto original fica na pendência.
--
-- Para fabricar o resíduo, o teste derruba a chave de estabelecimento DENTRO da transação,
-- grava a linha fora do catálogo e reinstala a chave NOT VALID, exatamente o estado que a
-- Fase 1 pode deixar. Tudo desfeito no `rollback`.

begin;
select plan(9);

-- ── 1. Estado depois da migração ──────────────────────────────────────────────

select ok(convalidated, 'estabelecimento_regiao_administrativa_fkey validada na Fase 2 (RN44)')
  from pg_constraint where conname = 'estabelecimento_regiao_administrativa_fkey';
select ok(convalidated, 'vaga_regiao_administrativa_fkey validada na Fase 2 (RN44)')
  from pg_constraint where conname = 'vaga_regiao_administrativa_fkey';

insert into public.estabelecimento (id, nome, documento, tipo, endereco, regiao_administrativa, ponto)
values ('d8120000-0000-4000-8000-000000000010', 'Casa Sintética F2', '81200000000191',
        'food_service', 'Rua Sintética, 1', 'Plano Piloto',
        'POINT(-47.8880 -15.8020)'::extensions.geography);

select throws_ok(
  $$ update public.estabelecimento set regiao_administrativa = 'Nárnia'
      where id = 'd8120000-0000-4000-8000-000000000010' $$,
  '23503', null,
  'critério 1: região fora do catálogo é recusada pela chave estrangeira (RN44)');

-- ── 2. Resíduo legado: conciliar antes de validar ─────────────────────────────

alter table public.estabelecimento drop constraint estabelecimento_regiao_administrativa_fkey;
update public.estabelecimento set regiao_administrativa = 'Entorno Residual F2'
 where id = 'd8120000-0000-4000-8000-000000000010';
alter table public.estabelecimento
  add constraint estabelecimento_regiao_administrativa_fkey
  foreign key (regiao_administrativa) references public.regiao_administrativa (nome)
  on update cascade
  not valid;

select throws_ok(
  $$ alter table public.estabelecimento validate constraint estabelecimento_regiao_administrativa_fkey $$,
  '23503', null,
  'critério 2: VALIDATE sem conciliar falha quando sobra resíduo fora do catálogo');

select lives_ok(
  $$ select privado.conciliar_regiao_administrativa_legada() $$,
  'critério 2: a conciliação da Fase 1 trata o resíduo');

select lives_ok(
  $$ alter table public.estabelecimento validate constraint estabelecimento_regiao_administrativa_fkey $$,
  'critério 2: depois da conciliação, VALIDATE passa');

select is(
  (select regiao_administrativa from public.estabelecimento
    where id = 'd8120000-0000-4000-8000-000000000010'),
  'Plano Piloto',
  'critério 2: o resíduo sem correspondência recebe Plano Piloto');

select is(
  (select texto_original from privado.pendencia_regiao_administrativa
    where origem = 'estabelecimento' and registro_id = 'd8120000-0000-4000-8000-000000000010'),
  'Entorno Residual F2',
  'critério 2: o texto original do resíduo fica guardado na pendência');

select ok(convalidated, 'critério 2: a chave termina validada')
  from pg_constraint where conname = 'estabelecimento_regiao_administrativa_fkey';

select * from finish();
rollback;
