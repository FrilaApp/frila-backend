#!/usr/bin/env bash
# `privado.agora()` é o relógio do produto, e nenhuma função pode usar `now()` direto.
#
# Cartão `yKUkCjSU`, critério de aceite 3. O enunciado dele diz "busca no código", e é aí
# que mora a armadilha: **migração é histórico, não é o estado do banco.** O gatilho de
# RN07 nasceu com `now()` em `20260922150600`, foi corrigido por uma migração posterior, e
# aquele arquivo continua lá com o `now()` dentro — imutável, como manda a regra. Um grep
# nos arquivos reprova um repositório correto e, pior, aprovaria uma função criada fora de
# `supabase/migrations/`.
#
# Por isso este portão pergunta ao banco, e não ao diretório: lê o corpo vigente de cada
# função em `public` e `privado` no `pg_proc`.
#
# Por que a regra existe: com `now()` no meio do caminho, todo prazo do produto vira
# decoração dentro de um teste que controla o relógio — os 7 dias do contato (RN10), as
# 24 h do modo seleção (RN24), o fim previsto que libera a avaliação (RN07). O teste
# passa, e a regra some.
#
# Uso:  ./scripts/relogio-do-produto.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}

if ! docker exec -i "$DB" psql -U postgres -d postgres -tAc 'select 1' >/dev/null 2>&1; then
  echo "✗ Não alcancei o banco no contêiner $DB. Suba o ambiente: supabase start" >&2
  exit 1
fi

# `privado.agora()` é a única que pode: é ela que devolve `now()` quando não há relógio
# de teste. Fixada por nome — se ela sumir, o portão avisa em vez de ficar verde por
# não ter o que reprovar.
#
# O corpo vai sem comentário antes da busca: `publicar_vaga` **explica** em um `--` por
# que usa `privado.agora()` e não `now()`, e essa frase casaria com o padrão. Medido: sem
# a limpeza, a função correta aparecia na lista de infratoras.
achados=$(docker exec -i "$DB" psql -U postgres -d postgres -tAc "
  select n.nspname || '.' || p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public','privado')
     and p.prokind = 'f'
     and not (n.nspname = 'privado' and p.proname = 'agora')
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g')
         ~* '(^|[^._[:alnum:]])now[[:space:]]*\([[:space:]]*\)'
   order by 1;")

if ! docker exec -i "$DB" psql -U postgres -d postgres -tAc \
       "select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'privado' and p.proname = 'agora'" | grep -q 1; then
  echo "✗ privado.agora() não existe no banco." >&2
  echo "  O relógio do produto sumiu, e este portão não tem contra o que comparar." >&2
  exit 1
fi

if [ -n "$achados" ]; then
  echo "✗ Função usando now() direto, fora de privado.agora():"
  echo
  printf '%s\n' "$achados" | sed 's/^/    /'
  echo
  echo "  Todo prazo do produto passa por privado.agora(). Com now() no caminho, o teste"
  echo "  que controla o relógio deixa de provar a regra — ele passa, e a regra some."
  echo
  echo "  A correção entra como migração nova: arquivo aplicado é imutável."
  exit 1
fi

echo "✓ Nenhuma função de public ou privado usa now() direto."
echo "  privado.agora() é o único caminho para o relógio do produto."
