#!/usr/bin/env bash
# Prova que os testes cobrem as restrições, em vez de apenas rodarem ao lado delas.
#
# Uma suíte verde não diz nada sobre o que ela protege. Este script derruba cada
# `CHECK`, cada `EXCLUDE` e cada trigger do esquema, um por vez, roda o pgTAP e exige
# que ele fique **vermelho**. Restrição que sobrevive à própria remoção sem nenhum teste
# reclamar é restrição que a próxima refatoração remove de graça.
#
# Escrito depois de uma revisão medir que 11 de 31 restrições estavam nessa situação.
#
# Uso:  ./scripts/mutacao.sh              todas as restrições
#       ./scripts/mutacao.sh sem_turno    só as que casam com o texto
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}
filtro="${1:-}"

psql() { docker exec -i "$DB" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }

# `mapfile` é do bash 4; o macOS traz o 3.2. Um while-read resolve e roda em todo lugar.
alvos=()
while IFS= read -r linha; do
  [ -n "$linha" ] && alvos+=("$linha")
done < <(psql -tAc "
  select c.conrelid::regclass || '|' || c.conname || '|' ||
         'alter table ' || c.conrelid::regclass || ' add constraint ' ||
         quote_ident(c.conname) || ' ' || pg_get_constraintdef(c.oid)
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public' and c.contype in ('c','x')
   order by c.conrelid::regclass::text, c.conname")

sobreviventes=()
mortos=0

for alvo in ${alvos[@]+"${alvos[@]}"}; do
  tabela=${alvo%%|*}; resto=${alvo#*|}
  nome=${resto%%|*};  recriar=${resto#*|}

  [ -n "$filtro" ] && [[ "$nome" != *"$filtro"* ]] && continue

  printf '  %-45s ' "$nome"

  if ! psql -q -c "alter table $tabela drop constraint \"$nome\";" >/dev/null 2>&1; then
    echo "não consegui derrubar — pulando"
    continue
  fi

  if supabase test db >/dev/null 2>&1; then
    echo "SOBREVIVEU — nenhum teste reclamou"
    sobreviventes+=("$tabela.$nome")
  else
    echo "morreu ✓"
    mortos=$((mortos + 1))
  fi

  psql -q -c "$recriar" >/dev/null
done

echo
echo "cobertas: $mortos · sem cobertura: ${#sobreviventes[@]}"

if [ ${#sobreviventes[@]+x} ] && [ ${#sobreviventes[@]} -gt 0 ]; then
  printf '  %s\n' "${sobreviventes[@]}"
  echo
  echo "Cada uma dessas precisa de uma asserção que fique vermelha sem ela."
  exit 1
fi
