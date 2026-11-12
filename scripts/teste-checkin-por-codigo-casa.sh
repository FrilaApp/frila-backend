#!/usr/bin/env bash
# Autotestes para o script de operação scripts/checkin-por-codigo-casa.sh.
# Roda contra o banco local (contêiner supabase_db_frila-backend ou DATABASE_URL).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="./scripts/checkin-por-codigo-casa.sh"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"

psql_q() {
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 "$@"
  else
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 "$@"
  fi
}

casos=0
falhas=0

passou() {
  casos=$((casos + 1))
  printf '  ✓ %s\n' "$1"
}

falhou() {
  casos=$((casos + 1))
  falhas=$((falhas + 1))
  printf '  ✗ %s\n' "$1" >&2
}

echo "▸ Testes do script checkin-por-codigo-casa.sh"

# 1. Recusa UUID com formato inválido
saida=$( "$SCRIPT" estado "nao-e-uuid" 2>&1 ) && codigo=0 || codigo=$?
if [ "$codigo" -ne 0 ] && printf '%s\n' "$saida" | grep -q "UUID inválido"; then
  passou "recusa UUID com formato inválido"
else
  falhou "deveria recusar UUID inválido (veio exit $codigo: $saida)"
fi

# 2. Recusa UUID de estabelecimento inexistente
uuid_inexistente="e0000000-0000-4000-8000-000000000001"
saida=$( "$SCRIPT" estado "$uuid_inexistente" 2>&1 ) && codigo=0 || codigo=$?
if [ "$codigo" -ne 0 ] && printf '%s\n' "$saida" | grep -q "Estabelecimento não encontrado"; then
  passou "recusa estabelecimento que não existe no banco"
else
  falhou "deveria recusar estabelecimento inexistente (veio exit $codigo: $saida)"
fi

# Criar estabelecimento e dados de teste temporários no banco
TEST_ESTAB_ID="e8440000-0000-4000-8000-000000000999"
TEST_USER_ID="a8440000-0000-4000-8000-000000000999"

limpar_dados() {
  psql_q -c "
    delete from privado.recurso_estabelecimento where estabelecimento_id = '$TEST_ESTAB_ID';
    delete from public.membro_estabelecimento where estabelecimento_id = '$TEST_ESTAB_ID';
    delete from public.estabelecimento where id = '$TEST_ESTAB_ID';
    delete from public.usuario where id = '$TEST_USER_ID';
  " >/dev/null 2>&1 || true
}
trap limpar_dados EXIT
limpar_dados

psql_q -c "
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values ('$TEST_USER_ID', 'contratante', 'Dono Teste Chave', '+5561999998499', 'chave-teste@frilabr.com', '1990-01-01', '1.0', now())
  on conflict do nothing;
  insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
  values ('$TEST_ESTAB_ID', 'Bar da Chave de Teste', '80000000000999', 'food_service', 'Rua Teste', 'POINT(-47.88 -15.77)')
  on conflict do nothing;
  insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
  values ('$TEST_USER_ID', '$TEST_ESTAB_ID', 'administrador')
  on conflict do nothing;
" >/dev/null

# 3. Estado inicial: deve ser INATIVO
saida=$( "$SCRIPT" estado "$TEST_ESTAB_ID" )
if printf '%s\n' "$saida" | grep -q "Estado consolidado: INATIVO"; then
  passou "estado inicial da casa é INATIVO"
else
  falhou "estado inicial deveria ser INATIVO: $saida"
fi

# 4. ligar --seco não deve persistir nada no banco
saida=$( "$SCRIPT" ligar "$TEST_ESTAB_ID" --seco )
if printf '%s\n' "$saida" | grep -q "MODO SECO"; then
  estado_pos_seco=$( "$SCRIPT" estado "$TEST_ESTAB_ID" )
  if printf '%s\n' "$estado_pos_seco" | grep -q "Estado consolidado: INATIVO"; then
    passou "ligar --seco exibe o plano sem alterar o banco"
  else
    falhou "ligar --seco alterou o banco indevidamente"
  fi
else
  falhou "ligar --seco não exibiu MODO SECO: $saida"
fi

# 5. ligar --sim ativa o recurso e mostra antes/depois
saida=$( "$SCRIPT" ligar "$TEST_ESTAB_ID" --sim )
if printf '%s\n' "$saida" | grep -q "Check-in por código ATIVADO com sucesso" && \
   printf '%s\n' "$saida" | grep -q "ANTES" && \
   printf '%s\n' "$saida" | grep -q "DEPOIS"; then
  passou "ligar --sim ativa o recurso e mostra antes/depois"
else
  falhou "ligar --sim falhou ou não mostrou antes/depois: $saida"
fi

# 6. estado após ligar é ATIVO
saida=$( "$SCRIPT" estado "$TEST_ESTAB_ID" )
if printf '%s\n' "$saida" | grep -q "Estado consolidado: ATIVO"; then
  passou "estado após ligar é ATIVO"
else
  falhou "estado após ligar deveria ser ATIVO: $saida"
fi

# 7. ligar idempotente: ligar novamente avisa e não altera
saida=$( "$SCRIPT" ligar "$TEST_ESTAB_ID" --sim )
if printf '%s\n' "$saida" | grep -q "já está totalmente ATIVO"; then
  passou "ligar é idempotente quando já ativo"
else
  falhou "ligar deveria ser idempotente: $saida"
fi

# 8. desligar --seco não altera o banco
saida=$( "$SCRIPT" desligar "$TEST_ESTAB_ID" --seco )
if printf '%s\n' "$saida" | grep -q "MODO SECO"; then
  estado_pos_desl_seco=$( "$SCRIPT" estado "$TEST_ESTAB_ID" )
  if printf '%s\n' "$estado_pos_desl_seco" | grep -q "Estado consolidado: ATIVO"; then
    passou "desligar --seco exibe o plano sem alterar o banco"
  else
    falhou "desligar --seco alterou o banco indevidamente"
  fi
else
  falhou "desligar --seco não exibiu MODO SECO: $saida"
fi

# 9. desligar --sim desliga o recurso e volta ao legado na hora
saida=$( "$SCRIPT" desligar "$TEST_ESTAB_ID" --sim )
if printf '%s\n' "$saida" | grep -q "Check-in por código DESLIGADO com sucesso" && \
   printf '%s\n' "$saida" | grep -q "ANTES" && \
   printf '%s\n' "$saida" | grep -q "DEPOIS"; then
  passou "desligar --sim desliga o recurso e mostra antes/depois"
else
  falhou "desligar --sim falhou: $saida"
fi

# 10. estado após desligar volta a ser INATIVO
saida=$( "$SCRIPT" estado "$TEST_ESTAB_ID" )
if printf '%s\n' "$saida" | grep -q "Estado consolidado: INATIVO"; then
  passou "estado após desligar é INATIVO (legado)"
else
  falhou "estado após desligar deveria ser INATIVO: $saida"
fi

# 11. desligar idempotente: desligar novamente avisa e não altera
saida=$( "$SCRIPT" desligar "$TEST_ESTAB_ID" --sim )
if printf '%s\n' "$saida" | grep -q "já está DESLIGADO para esta casa"; then
  passou "desligar é idempotente quando já desligado"
else
  falhou "desligar deveria ser idempotente: $saida"
fi

# 12. Sanitização de segredos: DATABASE_URL com senha nunca vaza no terminal
saida=$( DATABASE_URL="postgres://usuario_secreto:senha_super_secreta_123@db.empresa.test:5432/frila_banco" \
         "$SCRIPT" -h 2>&1 || true )
if printf '%s\n' "$saida" | grep -q "senha_super_secreta_123"; then
  falhou "segredo vazou na saída do script!"
else
  passou "segredos e credenciais de DATABASE_URL nunca são impressos"
fi

echo
if [ "$falhas" -eq 0 ]; then
  echo "Todos os $casos casos passaram."
  exit 0
else
  echo "$falhas de $casos casos falharam."
  exit 1
fi
