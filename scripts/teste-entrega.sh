#!/usr/bin/env bash
# Testa os dois portões da entrega contínua sem rede e sem banco: a janela de manutenção
# (`janela-de-manutencao.sh`) e a comparação do desvio (`desvio.sh`).
#
# Os dois só rodam de verdade no workflow `Entrega`, contra o frila-dev e o frila-prod, e um
# portão com furo aprova calado. Cada caso confere o código de saída **e** a frase do
# veredito: sair 1 por um motivo qualquer não conta como reprovar pelo motivo certo.
#
#   ./scripts/teste-entrega.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
falhas=0
casos=0

conferir() {  # conferir <descrição> <saída esperada> <frase esperada> <comando...>
  local desc="$1" esperado="$2" frase="$3"; shift 3
  local saida codigo
  saida=$("$@" 2>&1); codigo=$?
  casos=$((casos+1))
  if [ "$codigo" = "$esperado" ] && printf '%s' "$saida" | grep -qF -- "$frase"; then
    echo "  ✓ $desc"
  else
    echo "  ✗ $desc: saiu $codigo (esperado $esperado)"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas+1))
  fi
}

janela() { FRILA_AGORA="$1" ./scripts/janela-de-manutencao.sh; }

echo "▸ Janela de manutenção (RNF12)"
# 01/10/2026 é uma quinta-feira.
conferir "sexta às 20h é recusada (critério 3)"     1 "dentro da janela" janela "2026-10-02 20:00"
conferir "quinta às 15h59 passa"                   0 "fora da janela"   janela "2026-10-01 15:59"
conferir "quinta às 16h é recusada"                1 "dentro da janela" janela "2026-10-01 16:00"
conferir "sexta à 1h59 ainda é a noite de quinta"  1 "dentro da janela" janela "2026-10-02 01:59"
conferir "sexta às 2h passa"                       0 "fora da janela"   janela "2026-10-02 02:00"
conferir "sábado às 10h passa"                     0 "fora da janela"   janela "2026-10-03 10:00"
conferir "domingo às 23h é recusado"               1 "dentro da janela" janela "2026-10-04 23:00"
conferir "segunda à 1h30 ainda é a noite de domingo" 1 "dentro da janela" janela "2026-10-05 01:30"
conferir "segunda às 20h passa"                    0 "fora da janela"   janela "2026-10-05 20:00"
conferir "quarta às 23h passa"                     0 "fora da janela"   janela "2026-09-30 23:00"
conferir "hora ilegível não mede"                  2 "não medi"         janela "sexta 20h"

echo "▸ Desvio"
printf 'funcao privado.a() md5=1\nrelacao public.x tipo=r rls=true forcado=false\n' > "$TMP/base"
printf 'relacao public.x tipo=r rls=true forcado=false\nfuncao privado.a() md5=1\n' > "$TMP/igual"
printf 'funcao privado.a() md5=2\nrelacao public.x tipo=r rls=true forcado=false\n' > "$TMP/editada"
printf 'funcao privado.a() md5=1\nrelacao public.x tipo=r rls=false forcado=false\n' > "$TMP/sem_rls"
cp "$TMP/base" "$TMP/extra"; echo 'execucao public.b() anon=true' >> "$TMP/extra"
: > "$TMP/vazio"

desvio() { DESVIO_LOCAL="$TMP/$1" DESVIO_REMOTO="$TMP/$2" ./scripts/desvio.sh; }
conferir "mesma lista em outra ordem não é desvio"   0 "sem desvio"          desvio base igual
conferir "função reescrita pelo painel é desvio"     1 "Só no remoto"        desvio base editada
conferir "RLS desligado pelo painel é desvio"        1 "rls=false"           desvio base sem_rls
conferir "grant novo pelo painel é desvio"           1 "+ execucao public.b" desvio base extra
conferir "migração não aplicada aparece do outro lado" 1 "Só no repositório" desvio extra base
conferir "lista remota vazia não é banco igual"      2 "não medi"            desvio base vazio

echo
if [ "$falhas" -gt 0 ]; then
  echo "✗ $falhas de $casos casos falharam"
  exit 1
fi
echo "✓ $casos casos"
