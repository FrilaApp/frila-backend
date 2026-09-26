#!/usr/bin/env bash
# Recusa duas migrações com a mesma versão.
#
# `supabase_migrations.schema_migrations` tem `version` como chave primária, e a versão é
# o prefixo datado do nome do arquivo. Dois arquivos com o mesmo prefixo aplicam os dois e
# registram um: o segundo `INSERT` viola a chave e o `db reset` morre no meio, com o banco
# já parcialmente migrado.
#
# Isto não é hipótese. Medido em 25/09, com o branch `s0/configuracao-do-app` fundido ao
# `main`:
#
#   Applying migration 20260925230000_configuracao_do_app.sql...
#   Applying migration 20260925230000_janela_da_demonstracao.sql...
#   ERROR: duplicate key value violates unique constraint "schema_migrations_pkey"
#   (SQLSTATE 23505) Key (version)=(20260925230000) already exists.
#
# Duas pessoas escreveram uma migração na mesma hora redonda do mesmo dia, cada uma no seu
# branch, e nada avisou. `supabase migration new` usa o segundo corrente e nunca colide;
# quem escolhe o nome à mão — e neste repositório é o comum, porque o nome conta o que a
# migração faz — escolhe uma hora redonda, e hora redonda é justamente o que duas pessoas
# escolhem igual.
#
# O portão é barato de propósito: `ls`, `sort` e `uniq`, sem Postgres e sem rede. Ele roda
# ao lado do `migracoes-imutaveis.sh`, que cobre o outro jeito de quebrar a pasta.
#
# Uso:  ./scripts/migracoes-sem-colisao.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ ! -d supabase/migrations ]; then
  echo "supabase/migrations não existe — nada a conferir, e isso não é verde." >&2
  exit 2
fi

# A versão é o que vem antes do primeiro `_`. A CLI lê exatamente isso.
versoes=$(find supabase/migrations -maxdepth 1 -name '*.sql' -exec basename {} \; \
          | sed 's/_.*//' | sort)

if [ -z "$versoes" ]; then
  echo "Nenhuma migração em supabase/migrations — nada a conferir, e isso não é verde." >&2
  exit 2
fi

repetidas=$(printf '%s\n' "$versoes" | uniq -d)

if [ -n "$repetidas" ]; then
  echo "Duas ou mais migrações com a mesma versão:"
  echo
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    echo "  versão $v"
    find supabase/migrations -maxdepth 1 -name "${v}_*.sql" -exec basename {} \; \
      | sort | sed 's/^/    /'
    # A saída sugerida é por versão, e não uma linha genérica no fim: quem lê o vermelho
    # está com pressa, e uma sugestão com `<versao>` no lugar do número obriga a voltar
    # à lista de cima para completá-la.
    echo "    → renomeia quem ainda não entrou no main, porque migração já aplicada é"
    echo "      imutável. Um segundo de diferença basta:"
    echo "        git mv supabase/migrations/${v}_<nome>.sql \\"
    echo "               supabase/migrations/$((v + 1))_<nome>.sql"
    echo
  done <<< "$repetidas"
  echo "A versão é chave primária em supabase_migrations.schema_migrations: o db reset"
  echo "aplica as duas e registra uma, e morre no segundo INSERT com o banco meio"
  echo "migrado."
  exit 1
fi

total=$(printf '%s\n' "$versoes" | wc -l | tr -d ' ')
echo "As $total migrações têm versões distintas."
