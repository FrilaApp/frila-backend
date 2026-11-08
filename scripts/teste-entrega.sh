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
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

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

# A RNF12 está suspensa por padrão (decisão do Cauê, 08/11/2026): os casos da regra rodam com
# RNF12_ATIVA=1, que a religa igual à de antes. O padrão tem o bloco próprio no fim da janela.
janela() { RNF12_ATIVA=1 FRILA_AGORA="$1" ./scripts/janela-de-manutencao.sh; }

echo "▸ Janela de manutenção (RNF12 ativa, RNF12_ATIVA=1)"
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

echo "▸ Janela de manutenção com margem de término (FRILA_MARGEM_MIN)"
janela_m() { RNF12_ATIVA=1 FRILA_AGORA="$1" FRILA_MARGEM_MIN="$2" ./scripts/janela-de-manutencao.sh; }
conferir "quinta 15h29 com margem 30 passa (término 15h59)"  0 "fora da janela"          janela_m "2026-10-01 15:29" "30"
conferir "quinta 15h30 com margem 30 recusa (término 16h00)" 1 "cai na janela proibida"  janela_m "2026-10-01 15:30" "30"
conferir "quinta 15h40 com margem 30 recusa (término 16h10)" 1 "cai na janela proibida"  janela_m "2026-10-01 15:40" "30"
conferir "quinta 15h44 com margem 15 passa (término 15h59)"  0 "fora da janela"          janela_m "2026-10-01 15:44" "15"
conferir "quinta 15h45 com margem 15 recusa (término 16h00)" 1 "cai na janela proibida"  janela_m "2026-10-01 15:45" "15"
conferir "sexta 02h00 com margem 30 passa"                   0 "fora da janela"          janela_m "2026-10-02 02:00" "30"
conferir "segunda 02h00 com margem 30 passa"                 0 "fora da janela"          janela_m "2026-10-05 02:00" "30"
conferir "margem não numérica não mede"                      2 "não medi"                janela_m "2026-10-01 12:00" "abc"
conferir "margem negativa não mede"                          2 "não medi"                janela_m "2026-10-01 12:00" "-15"

echo "▸ RNF12 suspensa (padrão): a janela não é conferida"
suspensa() { env -u RNF12_ATIVA FRILA_AGORA="$1" ./scripts/janela-de-manutencao.sh; }
rnf12() { env RNF12_ATIVA="$1" FRILA_AGORA="$2" ./scripts/janela-de-manutencao.sh; }
uma_linha() {  # o padrão sai com uma linha só
  local s c; s=$(suspensa "$1" 2>&1); c=$?
  printf '%s\nlinhas=%s\n' "$s" "$(printf '%s\n' "$s" | wc -l | tr -d ' ')"; return "$c"
}
conferir "padrão na sexta às 20h passa, com o aviso"      0 "RNF12 suspensa"   suspensa "2026-10-02 20:00"
conferir "padrão sai com uma linha só"                    0 "linhas=1"         uma_linha "2026-10-02 20:00"
conferir "padrão não lê a hora (hora ilegível passa)"     0 "RNF12 suspensa"   suspensa "sexta 20h"
conferir "RNF12_ATIVA vazia vale suspensa"                0 "RNF12 suspensa"   rnf12 "" "2026-10-02 20:00"
conferir "RNF12_ATIVA=0 vale suspensa"                    0 "RNF12 suspensa"   rnf12 "0" "2026-10-02 20:00"
conferir "RNF12_ATIVA=true não é aceita: sai 2"           2 "RNF12_ATIVA=true não é um valor aceito" rnf12 "true" "2026-10-02 20:00"
conferir "RNF12_ATIVA=sim não é aceita: sai 2"            2 "RNF12_ATIVA=sim não é um valor aceito"  rnf12 "sim" "2026-10-02 20:00"
conferir "RNF12_ATIVA=2 não é aceita: sai 2"              2 "não medi"         rnf12 "2" "2026-10-05 20:00"
conferir "RNF12_ATIVA=1 na sexta às 20h recusa"           1 "dentro da janela" rnf12 "1" "2026-10-02 20:00"
conferir "RNF12_ATIVA=1 na segunda às 20h passa"          0 "fora da janela"   rnf12 "1" "2026-10-05 20:00"

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
