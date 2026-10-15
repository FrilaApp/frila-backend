#!/usr/bin/env bash
# Autoteste do portão `planos-com-carga.sh` contra casos conhecidos de sucesso e falha.
#
# Cartão mhHuBOeG. Um portão com furo aprova calado: este autoteste prova que o portão:
#   1. Aprova quando o caminho quente não tem Seq Scan em tabelas grandes e os tempos
#      (mediana e p95) estão abaixo dos tetos.
#   2. Reprova quando ocorre Seq Scan em tabela grande (ex: vaga, disponibilidade),
#      nomeando a tabela e a contagem de linhas lidas.
#   3. Tolera Seq Scan em tabela pequena de catálogo (ex: funcao com 33 linhas).
#   4. Reprova quando a mediana de vagas_abertas ultrapassa o teto.
#   5. Reprova quando o p95 de vagas_abertas ultrapassa o teto.
#   6. Reprova quando a mediana de privado.elegiveis ultrapassa o teto.
#   7. Reprova quando o p95 de privado.elegiveis ultrapassa o teto.
#   8. Sai 2 (NÃO MEDI) quando a saída está corrompida ou incompleta.
#
# Não precisa de Docker nem de Postgres: alimenta o portão com saídas sintéticas
# através da opção `--julgar <arquivo>`.
#
# Uso:  ./scripts/teste-planos-com-carga.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PORTAO="$PWD/scripts/planos-com-carga.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

caso() {
  local nome="$1" esperado="$2" frase="$3" arquivo="$4"
  shift 4
  casos=$((casos + 1))

  local saida codigo
  set +e
  saida=$(env "$@" "$PORTAO" --julgar "$arquivo" 2>&1)
  codigo=$?
  set -e

  if [ "$codigo" = "$esperado" ] && printf '%s\n' "$saida" | grep -qF "$frase"; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperava saída $esperado com \"$frase\", veio $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

echo "▸ Autoteste do portão de plano com carga"

# ── 1. Fixture base verde ───────────────────────────────────────────────────────
cat <<'EOF' > "$TMP/ok.txt"
VOL usuario=130018 profissional=100013 vaga=20010 disponibilidade=200018
--- PLANO elegiveis ---
Bitmap Heap Scan on profissional p (cost=4.20..15.50 rows=25 width=16)
--- PLANO vagas_abertas por data ---
Limit (cost=0.28..12.50 rows=30 width=128)
  -> Index Scan using vaga_ponto on vaga v (cost=0.28..8500.00 rows=20000 width=128)
--- TEMPOS ---
NOTICE:  P95_ELEGIVEIS=25.4
NOTICE:  MEDIANA_ELEGIVEIS=18.2
NOTICE:  P95_VAGAS_ABERTAS=32.1
NOTICE:  P90_VAGAS_ABERTAS=28.5
NOTICE:  MEDIANA_VAGAS_ABERTAS=22.0
EOF

caso "caso verde passa (0 Seq Scan em tabela grande, medianas e p95 no teto)" 0 \
  "Caminho quente medido com o volume do DF" "$TMP/ok.txt"

# ── 2. Regressão de plano: Seq Scan em tabela grande ───────────────────────────
cat <<'EOF' > "$TMP/seq_vaga.txt"
VOL usuario=130018 profissional=100013 vaga=20010 disponibilidade=200018
--- PLANO vagas_abertas por data ---
Seq Scan on vaga v (cost=0.00..500.00 rows=20010 width=128)
  Rows Removed by Filter: 19980
NOTICE:  P95_ELEGIVEIS=25.4
NOTICE:  MEDIANA_ELEGIVEIS=18.2
NOTICE:  P95_VAGAS_ABERTAS=32.1
NOTICE:  P90_VAGAS_ABERTAS=28.5
NOTICE:  MEDIANA_VAGAS_ABERTAS=22.0
EOF

caso "Seq Scan em tabela grande (vaga) reprova" 1 \
  "varredura sequencial em tabela grande do caminho quente" "$TMP/seq_vaga.txt"

caso "Seq Scan em vaga nomeia a tabela e a contagem de linhas lidas" 1 \
  "vaga (39990 linhas lidas)" "$TMP/seq_vaga.txt"

cat <<'EOF' > "$TMP/seq_disp.txt"
VOL usuario=130018 profissional=100013 vaga=20010 disponibilidade=200018
Seq Scan on disponibilidade d (cost=0.00..500.00 rows=200000 width=64)
  Rows Removed by Filter: 150000
NOTICE:  P95_ELEGIVEIS=25.4
NOTICE:  MEDIANA_ELEGIVEIS=18.2
NOTICE:  P95_VAGAS_ABERTAS=32.1
NOTICE:  P90_VAGAS_ABERTAS=28.5
NOTICE:  MEDIANA_VAGAS_ABERTAS=22.0
EOF

caso "Seq Scan em disponibilidade reprova nomeando a tabela" 1 \
  "disponibilidade (350000 linhas lidas)" "$TMP/seq_disp.txt"

# ── 3. Seq Scan em tabela de catálogo pequena (< 1000 linhas) é tolerado ───────
cat <<'EOF' > "$TMP/seq_funcao.txt"
VOL usuario=130018 profissional=100013 vaga=20010 disponibilidade=200018
Seq Scan on funcao f (cost=0.00..1.33 rows=33 width=32)
  Rows Removed by Filter: 10
NOTICE:  P95_ELEGIVEIS=25.4
NOTICE:  MEDIANA_ELEGIVEIS=18.2
NOTICE:  P95_VAGAS_ABERTAS=32.1
NOTICE:  P90_VAGAS_ABERTAS=28.5
NOTICE:  MEDIANA_VAGAS_ABERTAS=22.0
EOF

caso "Seq Scan em tabela de catálogo pequena (funcao) passa" 0 \
  "nenhuma varredura sequencial acima de 1000 linhas" "$TMP/seq_funcao.txt"

# ── 4. Regressão de latência: tetos de vagas_abertas ────────────────────────────
caso "mediana de vagas_abertas acima do teto reprova" 1 \
  "mediana de vagas_abertas em 22.0 ms, acima do teto de 20 ms" "$TMP/ok.txt" \
  MED_MAX_VAGAS=20

caso "p95 de vagas_abertas acima do teto reprova" 1 \
  "p95 de vagas_abertas em 32.1 ms, acima do teto de 30 ms" "$TMP/ok.txt" \
  P95_MAX_VAGAS=30

# ── 5. Regressão de latência: tetos de privado.elegiveis ────────────────────────
caso "mediana de privado.elegiveis acima do teto reprova" 1 \
  "mediana de privado.elegiveis em 18.2 ms, acima do teto de 15 ms" "$TMP/ok.txt" \
  MED_MAX_ELEGIVEIS=15

caso "p95 de privado.elegiveis acima do teto reprova" 1 \
  "p95 de privado.elegiveis em 25.4 ms, acima do teto de 20 ms" "$TMP/ok.txt" \
  P95_MAX_ELEGIVEIS=20

# ── 6. Casos que não mediram (código 2, nunca verde por omissão) ───────────────
cat <<'EOF' > "$TMP/erro_psql.txt"
ERROR: table "vaga" does not exist
LINE 1: select * from vaga;
EOF

caso "saída com ERROR do Postgres sai 2 (NÃO MEDI)" 2 \
  "✗ NÃO MEDI" "$TMP/erro_psql.txt"

cat <<'EOF' > "$TMP/sem_tempos.txt"
VOL usuario=130018 profissional=100013 vaga=20010 disponibilidade=200018
Limit (cost=0.28..12.50 rows=30 width=128)
EOF

caso "saída sem tempos de medição sai 2 (NÃO MEDI)" 2 \
  "não achei os tempos na saída da medição" "$TMP/sem_tempos.txt"

echo
if [ "$falhas" -ne 0 ]; then
  echo "$falhas de $casos casos falharam."
  exit 1
fi
echo "Os $casos casos passaram."
