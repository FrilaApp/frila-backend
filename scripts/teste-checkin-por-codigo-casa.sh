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

echo "▸ Testes do script checkin-por-codigo-casa.sh (somente leitura)"

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

# 3. Recusa explícita do comando 'ligar' (operações de escrita são exclusivas por migração)
saida=$( "$SCRIPT" ligar "$uuid_inexistente" 2>&1 ) && codigo=0 || codigo=$?
if [ "$codigo" -ne 0 ] && printf '%s\n' "$saida" | grep -q "não é permitido via script" && printf '%s\n' "$saida" | grep -q "exclusivamente por migração"; then
  passou "recusa subcomando ligar e orienta uso de migração"
else
  falhou "deveria recusar comando ligar orientando migração (veio exit $codigo: $saida)"
fi

# 4. Recusa explícita do comando 'desligar'
saida=$( "$SCRIPT" desligar "$uuid_inexistente" 2>&1 ) && codigo=0 || codigo=$?
if [ "$codigo" -ne 0 ] && printf '%s\n' "$saida" | grep -q "não é permitido via script" && printf '%s\n' "$saida" | grep -q "exclusivamente por migração"; then
  passou "recusa subcomando desligar e orienta uso de migração"
else
  falhou "deveria recusar comando desligar orientando migração (veio exit $codigo: $saida)"
fi

# Criar estabelecimento e dados de teste temporários no banco
TEST_ESTAB_ID="e8440000-0000-4000-8000-000000000999"
TEST_USER_ID="a8440000-0000-4000-8000-000000000999"

limpar_dados() {
  psql_q -c "
    update privado.recurso set ligado = false where chave = 'checkin_por_codigo';
    delete from privado.recurso_versao_minima where recurso = 'checkin_por_codigo';
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

# 5. Estado inicial: deve ser INATIVO (fluxo legado)
saida=$( "$SCRIPT" estado "$TEST_ESTAB_ID" )
if printf '%s\n' "$saida" | grep -q "Estado consolidado: INATIVO"; then
  passou "estado inicial da casa é INATIVO"
else
  falhou "estado inicial deveria ser INATIVO: $saida"
fi

# 6. Estado global sem argumentos
saida=$( "$SCRIPT" estado )
if printf '%s\n' "$saida" | grep -q "Estado consolidado: INATIVO" && \
   printf '%s\n' "$saida" | grep -q "Abrangência:.*todos os estabelecimentos"; then
  passou "estado global sem argumentos mostra INATIVO e abrangência geral"
else
  falhou "estado global deveria ser INATIVO: $saida"
fi

# 7. Simular aplicação da migração (chave ligada e versão mínima)
psql_q -c "
  insert into privado.recurso (chave, ligado) values ('checkin_por_codigo', true)
    on conflict (chave) do update set ligado = true;
  insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
    values ('checkin_por_codigo', 'ios', '1.2.0')
    on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;
  insert into privado.recurso_estabelecimento (chave, estabelecimento_id)
    values ('checkin_por_codigo', '$TEST_ESTAB_ID')
    on conflict do nothing;
" >/dev/null

saida=$( "$SCRIPT" estado "$TEST_ESTAB_ID" )
if printf '%s\n' "$saida" | grep -q "Estado consolidado: ATIVO" && \
   printf '%s\n' "$saida" | grep -q "Versão mínima iOS.*1.2.0" && \
   printf '%s\n' "$saida" | grep -q "Abrangência:.*todos os estabelecimentos"; then
  passou "estado reflete chave ligada (ATIVO) e versão mínima 1.2.0"
else
  falhou "estado após migração simulada deveria ser ATIVO: $saida"
fi

# 8. Simular desativação da chave global (rollback de contingência)
psql_q -c "
  update privado.recurso set ligado = false where chave = 'checkin_por_codigo';
  delete from privado.recurso_versao_minima where recurso = 'checkin_por_codigo' and plataforma = 'ios';
  delete from privado.recurso_estabelecimento where estabelecimento_id = '$TEST_ESTAB_ID';
" >/dev/null

saida=$( "$SCRIPT" estado "$TEST_ESTAB_ID" )
if printf '%s\n' "$saida" | grep -q "Estado consolidado: INATIVO" && \
   printf '%s\n' "$saida" | grep -q "desligada (false)"; then
  passou "estado reflete contingência de desligamento (INATIVO)"
else
  falhou "estado após rollback simulado deveria ser INATIVO: $saida"
fi

# 8. Sanitização de segredos: DATABASE_URL com senha nunca vaza no terminal
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
