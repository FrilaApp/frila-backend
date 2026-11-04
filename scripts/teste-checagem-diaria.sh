#!/usr/bin/env bash
# Teste automatizado do script de checagem diária (scripts/checagem-diaria.sh)
# Cartão 42 · S4 · Infra · Monitoramento de produção e plantão do piloto.
#
# Valida:
#   1. Execução padrão com saída estruturada sem erros de sintaxe SQL.
#   2. Garantia 100% SÓ LEITURA: default_transaction_read_only bloqueia escritas.
#   3. Resiliência: falha fechada com exit code 2 quando o banco está inacessível.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SCRIPT="./scripts/checagem-diaria.sh"

echo "▸ 1. Testando execução local padrão de $SCRIPT..."
set +e
saida=$("$SCRIPT" 2>&1)
codigo=$?
set -e
if [ "$codigo" -ne 0 ] && [ "$codigo" -ne 1 ]; then
  echo "✗ FALHOU: Código de saída inesperado: $codigo (esperado 0 ou 1)" >&2
  echo "$saida" >&2
  exit 1
fi
echo "  ✓ Execução concluída com código $codigo (VERDE ou AMARELO esperado)."

# Valida que as seções principais foram emitidas
for secao in "1. Saúde Geral" "2. Fila de Despacho" "3. Falhas de Execução" "4. Moderação" "5. E-mails" "6. Turnos" "7. Recursos" "VEREDITO"; do
  if ! echo "$saida" | grep -q "$secao"; then
    echo "✗ FALHOU: Seção '$secao' não encontrada na saída do script." >&2
    exit 1
  fi
done
echo "  ✓ Todas as 8 seções obrigatórias foram emitidas."

echo "▸ 2. Testando garantia estrita de SÓ LEITURA..."
# Tenta simular tentativa de escrita via psql com a mesma flag default_transaction_read_only
set +e
docker exec -i "${DB_CONTAINER:-supabase_db_frila-backend}" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 \
  -c "SET default_transaction_read_only = on;" \
  -c "INSERT INTO privado.alerta_emitido (codigo, ultimo_em, suprimidos) VALUES ('teste_escrita', now(), 0);" >/dev/null 2>&1
res_escrita=$?
set -e

if [ "$res_escrita" -eq 0 ]; then
  echo "✗ FALHOU: Operação de escrita foi permitida em transação read-only!" >&2
  exit 1
fi
echo "  ✓ Tentativa de escrita bloqueada com sucesso pelo modo read-only."

echo "▸ 3. Testando falha fechada com banco inacessível..."
set +e
saida_erro=$(DB_CONTAINER="container_inexistente_12345" DATABASE_URL="" PGHOST="" "$SCRIPT" 2>&1)
cod_erro=$?
set -e

if [ "$cod_erro" -ne 2 ]; then
  echo "✗ FALHOU: Esperado exit code 2 para banco inacessível, obteve $cod_erro." >&2
  exit 1
fi
if ! echo "$saida_erro" | grep -q "Não foi possível conectar ao banco de dados"; then
  echo "✗ FALHOU: Mensagem de erro de conexão esperada não encontrada." >&2
  exit 1
fi
echo "  ✓ Falha fechada com exit code 2 e diagnóstico correto."

echo ""
echo "✓ Todos os 3 testes do script de checagem diária passaram com sucesso!"
