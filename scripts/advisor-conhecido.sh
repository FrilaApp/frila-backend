#!/usr/bin/env bash
# Advisor de segurança do Supabase com os achados esperados declarados por nome.
#
# A regra `authenticated_security_definer_function_executable` vai disparar para **toda
# RPC do produto**, e isso é a arquitetura, não defeito: a Modelagem manda que nenhuma
# tabela tenha política de escrita e que toda escrita passe por função `security
# definer` chamada pelo cliente. Sem declarar o esperado, o advisor vira ruído e o
# critério "advisor sem alerta" vira inatingível — e portão inatingível é portão que o
# time aprende a ignorar.
#
# Por que não está na integração contínua: o advisor é da Management API e exige o token
# de conta, que alcança toda a conta do Supabase. Esse token não entra em segredo de
# repositório. Este script roda antes do merge, com o `.env` local.
#
# Uso:  ./scripts/advisor-conhecido.sh [project_ref]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; source .env; set +a

REF="${1:-${FRILA_DEV_PROJECT_REF:?falta FRILA_DEV_PROJECT_REF no .env}}"
: "${SUPABASE_ACCESS_TOKEN:?falta SUPABASE_ACCESS_TOKEN no .env}"

# regra|schema.função — uma por linha. Cada linha aqui é uma afirmação de que o alerta é
# consequência declarada do desenho, e quem acrescentar uma precisa poder defendê-la.
#
# As RPCs abaixo são `security definer` de propósito: elas leem `auth.users` e escrevem
# em tabelas que não têm política de escrita para ninguém. É esse o desenho.
ESPERADOS="authenticated_security_definer_function_executable|public.criar_conta
authenticated_security_definer_function_executable|public.minha_conta"

resposta=$(curl -sS -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/$REF/advisors/security") || {
  echo "  NÃO CONSEGUI FALAR COM O ADVISOR — isto não é advisor limpo"; exit 1; }

achados=$(printf '%s' "$resposta" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ls = d.get('lints', d if isinstance(d, list) else [])
for l in ls:
    m = l.get('metadata') or {}
    alvo = f\"{m.get('schema','?')}.{m.get('name','?')}\" if m else '?'
    print(f\"{l.get('name')}|{alvo}\")
") || { echo "  NÃO CONSEGUI LER A RESPOSTA DO ADVISOR"; printf '%s\n' "$resposta"; exit 1; }

falta=0
while IFS= read -r a; do
  [ -z "$a" ] && continue
  if printf '%s\n' "$ESPERADOS" | grep -qxF "$a"; then
    echo "  esperado: $a"
  else
    echo "  NOVO: $a"
    falta=1
  fi
done <<< "$achados"

while IFS= read -r e; do
  [ -z "$e" ] && continue
  printf '%s\n' "$achados" | grep -qxF "$e" \
    || { echo "  SUMIU: $e — tire da lista em scripts/advisor-conhecido.sh"; falta=1; }
done <<< "$ESPERADOS"

if [ "$falta" -ne 0 ]; then
  echo
  echo "O advisor mudou."
  exit 1
fi

echo "  advisor sem alerta além dos declarados"
