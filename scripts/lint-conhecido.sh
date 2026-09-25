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
# `supabase db lint` que falha é lint **não rodado**, e não lint limpo. Regra geral
# deste repositório para portão: qualquer caminho que não seja "medi e o resultado foi
# X" tem que sair diferente de zero. Sem isto, a própria divergência de versão de CLI
# que motivou este script passaria verde.
if ! bruto=$(supabase db lint --level warning --schema public,privado 2>&1); then
  echo "  NÃO CONSEGUI RODAR O LINT — isto não é lint limpo"
  printf '%s\n' "$bruto"
  exit 1
fi

# A CLI tem três saídas possíveis, e confundi-las já custou uma CI vermelha:
#   1. JSON, quando há achado — no formato antigo (array) ou no novo ({"results":[…]})
#   2. só "No schema errors found", quando não há. Na máquina ela imprime as duas
#      linhas; no servidor, sem terminal, só esta.
#   3. qualquer outra coisa, que é falha e sai diferente de zero.
# O recorte começa na primeira linha que abre JSON e termina onde o JSON termina. A
# segunda parte não é preciosismo: em 25/09 a CLI passou a imprimir "A new version of
# Supabase CLI is available" **depois** do JSON, e o recorte antigo, que ia até o fim da
# saída, entregava ao parser um documento com lixo colado no fim. O erro que aparecia era
# `JSONDecodeError: Extra data`, sobre um lint que estava limpo.
#
# Linha de aviso da CLI começa com letra na coluna zero; JSON começa com pontuação ou vem
# indentado. É por aí que as duas se separam.
saida=$(printf '%s' "$bruto" | sed -n '/^[[{]/,$p' | sed '/^[A-Za-z]/d')

if [ -z "$saida" ]; then
  if printf '%s' "$bruto" | grep -q 'No schema errors found'; then
    saida='[]'
  else
    echo "  A CLI não devolveu nem JSON nem 'No schema errors found'"
    printf '%s\n' "$bruto"
    exit 1
  fi
fi

# Saída ilegível também é falha: sair 0 aqui é dizer "está limpo" sobre o que não
# foi lido.
if ! achados=$(printf '%s' "$saida" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if isinstance(d, dict):
    d = d.get('results', [])
for f in d:
    for i in f.get('issues', []):
        print(f\"{f['function']}|{i.get('sqlState','?')}\")
" 2>&1); then
  echo "  NÃO CONSEGUI LER A SAÍDA DO LINT"
  printf '%s\n' "$achados"
  printf '%s\n' "$saida"
  exit 1
fi

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
