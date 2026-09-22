#!/usr/bin/env bash
# `supabase db lint` com o conjunto de achados conhecidos fixado.
#
# O lint tem hoje exatamente um achado, e ele é artefato da ferramenta: o
# `plpgsql_check` entra em `public.erro` — cuja razão de existir é levantar exceção —
# e reporta o `RAISE` do envelope do contrato como erro de quem a chama. A prova de que
# é do tracer e não da função: `privado.avaliacao_permitida` chama a mesma `erro` e não
# gera achado nenhum.
#
# Duas saídas ruins existiam antes desta: deixar o lint fora da integração contínua, e
# perder o próximo erro de plpgsql de verdade; ou deixá-lo dentro e vermelho todo dia
# por um comportamento correto, que é como um portão ensina o time a ignorá-lo.
#
# Aqui o conhecido é declarado por nome. Achado novo reprova; achado conhecido que
# desaparece também avisa, porque ou a ferramenta mudou ou o código mudou, e nos dois
# casos esta lista está desatualizada.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# função|sqlState — um por linha.
# Vazio: hoje o lint está limpo. O primeiro achado que aparecer reprova, e quem for
# adicioná-lo aqui tem que justificar por que é artefato da ferramenta e não defeito.
CONHECIDOS=""

# A versão da CLI muda o conjunto de checagens do plpgsql_check. Rodar uma versão
# antiga aqui e `latest` na integração contínua faz o portão abrir na máquina e fechar
# no servidor — foi o que aconteceu no primeiro dia: a CI viu que `public.erro` estava
# marcada IMMUTABLE sem ser, e a máquina não. Imprimir a versão torna a divergência
# visível em vez de misteriosa.
echo "  supabase CLI $(supabase --version 2>/dev/null | head -1)"

# A CLI mudou o formato entre versões: era um array cru, virou {"results": [...]}.
# O parser aceita os dois, senão o portão passa a abrir em silêncio na próxima troca.
saida=$(supabase db lint --level warning --schema public,privado 2>/dev/null \
        | sed -n '/^[[{]/,$p')

achados=$(printf '%s' "$saida" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    d = d.get('results', [])
for f in d:
    for i in f.get('issues', []):
        print(f\"{f['function']}|{i.get('sqlState','?')}\")
")

falta=0
for a in $achados; do
  if printf '%s\n' "$CONHECIDOS" | grep -qxF "$a"; then
    echo "  conhecido: $a"
  else
    echo "  NOVO: $a"
    falta=1
  fi
done

for c in $CONHECIDOS; do
  if ! printf '%s\n' "$achados" | grep -qxF "$c"; then
    echo "  DESAPARECEU: $c — atualize a lista em scripts/lint-conhecido.sh"
    falta=1
  fi
done

if [ "$falta" -ne 0 ]; then
  echo
  echo "O lint mudou. Saída completa:"
  printf '%s\n' "$saida"
  exit 1
fi

echo "  lint sem achado novo"
