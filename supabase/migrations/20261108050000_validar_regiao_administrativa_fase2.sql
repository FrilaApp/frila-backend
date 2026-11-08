-- Validar regiao_administrativa (RN44). Contratação direta, fatia F1 · brief B2 (Fase 2: VALIDATE).
--
-- A Fase 1 (20261108040000) conciliou o legado e instalou as duas chaves estrangeiras para
-- `public.regiao_administrativa (nome)` com NOT VALID: escrita nova já é conferida, mas o
-- banco ainda não atestou que nenhuma linha antiga ficou fora do catálogo. Esta migração
-- fecha isso.
--
-- Por que conciliar de novo antes do VALIDATE: uma escrita antiga em voo pode ter terminado
-- depois do snapshot da conciliação da Fase 1 e antes da instalação da chave (nota do Lince
-- no #430). O que sobrar recebe o mesmo tratamento da Fase 1, pela mesma função idempotente:
-- grafia conhecida vira o nome oficial, e texto sem correspondência vira 'Plano Piloto', com o
-- original guardado em `privado.pendencia_regiao_administrativa`. Sem resíduo, a chamada não
-- altera nada. O roteiro de Prod reconta o resíduo antes de aplicar e para acima de 1000
-- linhas, porque a conciliação roda nesta transação.
--
-- Locks: VALIDATE CONSTRAINT de chave estrangeira pega SHARE UPDATE EXCLUSIVE na tabela
-- validada e ROW SHARE no catálogo. Não bloqueia leitura nem escrita do app, só DDL
-- concorrente. O `lock_timeout` local de 2 s faz a migração desistir, em vez de enfileirar
-- atrás de uma transação longa e travar quem chegar depois.
--
-- Nenhuma RPC muda; nenhum contrato muda.

select set_config('lock_timeout', '2s', true);

select privado.conciliar_regiao_administrativa_legada();

alter table public.estabelecimento validate constraint estabelecimento_regiao_administrativa_fkey;
alter table public.vaga            validate constraint vaga_regiao_administrativa_fkey;

comment on constraint estabelecimento_regiao_administrativa_fkey on public.estabelecimento is
  'RN44: a região do estabelecimento é um nome do catálogo public.regiao_administrativa. Instalada NOT VALID na Fase 1 (20261108040000) e validada na Fase 2 (20261108050000).';
comment on constraint vaga_regiao_administrativa_fkey on public.vaga is
  'RN44: a região da vaga é um nome do catálogo public.regiao_administrativa. Instalada NOT VALID na Fase 1 (20261108040000) e validada na Fase 2 (20261108050000).';
