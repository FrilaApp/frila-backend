#!/usr/bin/env bash
# A resposta de cada RPC casa com o schema do contrato?
#
# Cartão `0uROtsRX`. O Postgres monta o JSON de cada RPC à mão: basta renomear uma chave
# para quebrar o app sem erro no banco, sem teste vermelho e sem log. Os outros dois
# portões de contrato não alcançam isso — um compara o espelho com o original, o outro
# exige que o PR que mexe em `public` mexa no contrato. Nenhum dos dois olha um corpo.
#
# Duas peças: `contrato-respostas.sql` colhe uma resposta real de cada RPC, com o relógio
# do produto sob controle; `contrato_responde.py` julga cada uma contra o
# `contrato/openapi.yaml`.
#
# Uso:  ./scripts/contrato-responde.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}
VENV=.venv-contrato

if ! docker exec -i "$DB" psql -U postgres -d postgres -tAc 'select 1' >/dev/null 2>&1; then
  echo "✗ Não alcancei o banco no contêiner $DB. Suba o ambiente: supabase start" >&2
  exit 1
fi

# O validador precisa de `PyYAML` e `jsonschema`, e nenhum dos dois vem com o Python da
# máquina. Um `pip install` global esbarra no Python gerenciado pelo Homebrew e, pior,
# deixaria as quatro máquinas com versões diferentes do validador — que é exatamente o
# tipo de diferença que faz "passa aqui e falha na CI".
#
# Por isso um ambiente próprio, com as versões fixadas, criado na primeira execução e
# reusado depois. Ele é ignorado pelo git.
if [ ! -x "$VENV/bin/python" ]; then
  echo "▸ Criando o ambiente do validador (só na primeira vez)"
  python3 -m venv "$VENV" >/dev/null 2>&1 \
    || { echo "✗ python3 -m venv falhou. O validador precisa de Python 3." >&2; exit 1; }
  "$VENV/bin/pip" install -q 'PyYAML==6.0.2' 'jsonschema==4.23.0' \
    || { echo "✗ Não consegui instalar PyYAML e jsonschema em $VENV." >&2; exit 1; }
fi

echo "▸ Colhendo uma resposta real de cada RPC"
colheita=$(docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 -f - \
             < scripts/contrato-respostas.sql 2>&1)
estado=$?

# Harness que falha é portão **não rodado**, e não portão limpo. Sair 0 aqui seria dizer
# "as respostas casam" sobre respostas que ninguém colheu.
if [ $estado -ne 0 ] || ! printf '%s' "$colheita" | grep -q '^{'; then
  echo "✗ O harness SQL não colheu resposta nenhuma." >&2
  printf '%s\n' "$colheita" >&2
  exit 1
fi

printf '%s\n' "$colheita" | "$VENV/bin/python" scripts/contrato_responde.py
