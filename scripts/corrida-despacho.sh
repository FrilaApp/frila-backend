#!/usr/bin/env bash
# Prova de concorrência e atomicidade do motor de despacho (cartão 7XS6MQGg).
#
# Em duas execuções concorrentes de privado.despachar_vaga(vaga_id), ambas tentam
# criar despachos e notificações para os elegíveis ao mesmo tempo.
#
# O teste de concorrência abre DUAS sessões simultâneas no banco:
# - A sessão A e a sessão B invocam privado.despachar_vaga para a mesma vaga.
# - A e B disputam as mesmas linhas e o mesmo momento.
#
# O que o script exige ao final:
#   1. Ambas as sessões completam sem erro de deadlock não tratado.
#   2. O número total de linhas em public.despacho para a vaga é exatamente igual ao
#      número de elegíveis (sem duplicatas).
#   3. O número total de linhas em public.notificacao para a vaga (tipo 'vaga') é
#      EXATAMENTE igual ao número de elegíveis (a marca de envio com UNIQUE impede
#      que duas notificações sejam geradas para o mesmo profissional).
#   4. Nenhum despacho fica órfão ou com notificacao_id nula.
#
# Uso:  ./scripts/corrida-despacho.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}

psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

TMP=$(mktemp -d)
falha=0

# Vaga de teste isolada para a corrida
VAGA_ID="d0000000-0000-4000-8000-000000000077"

limpar() {
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: a limpeza falhou na vaga $VAGA_ID" >&2
set session_replication_role = 'replica';
delete from public.despacho where vaga_id = '$VAGA_ID';
delete from public.notificacao where referencia_id = '$VAGA_ID';
delete from public.vaga where id = '$VAGA_ID';
set session_replication_role = 'origin';
SQL
  rm -rf "$TMP"
}
trap limpar EXIT

echo "▸ Montando o cenário da corrida de despacho"

# Insere a vaga no horário da âncora (sexta 18h) com 1 posição e função garçom
# No seed, essa vaga tem exatamente 5 profissionais elegíveis (Ana, Heitor, Iara, Katia, Lucas).
psql >/dev/null <<SQL
set session_replication_role = 'replica';
delete from public.despacho where vaga_id = '$VAGA_ID';
delete from public.notificacao where referencia_id = '$VAGA_ID';
delete from public.vaga where id = '$VAGA_ID';
set session_replication_role = 'origin';
do \$\$
declare
  v_ini timestamptz;
  v_fim timestamptz;
begin
  delete from public.despacho where vaga_id = '$VAGA_ID';
  delete from public.notificacao where referencia_id = '$VAGA_ID';
  delete from public.vaga where id = '$VAGA_ID';

  select inicio_em, fim_em into v_ini, v_fim
    from public.vaga
   where id = 'd0000000-0000-4000-8000-000000000001';

  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, publicado_por, modo, estado, chave_cliente
  ) values (
    '$VAGA_ID',
    'c0000000-0000-4000-8000-000000000001',
    (select id from public.funcao where nome = 'garçom'),
    v_ini, v_fim,
    'CLN 208, Bloco B', 'POINT(-47.8869 -15.7620)'::extensions.geography,
    15000, 1, false, false, false, 'Gerente Teste',
    'a0000000-0000-4000-8000-000000000001', 'urgencia', 'publicada', gen_random_uuid()
  );
end \$\$;
SQL

total_elegiveis=$(psql -tAc "select count(*)::int from privado.elegiveis('$VAGA_ID')")
[ "$total_elegiveis" -gt 0 ] || { echo "  ✗ Falha ao obter elegíveis para $VAGA_ID" >&2; exit 1; }
ok "Cenário criado: vaga $VAGA_ID com $total_elegiveis profissionais elegíveis"

echo "▸ Disparando sessões A e B em concorrência real"

# Sessão A
psql -tA <<SQL >"$TMP/a.out" 2>"$TMP/a.err" &
set application_name = 'corrida_despacho_a';
begin;
select privado.despachar_vaga('$VAGA_ID');
commit;
SQL
pa=$!

# Sessão B (dispara simultaneamente)
psql -tA <<SQL >"$TMP/b.out" 2>"$TMP/b.err" &
set application_name = 'corrida_despacho_b';
begin;
select privado.despachar_vaga('$VAGA_ID');
commit;
SQL
pb=$!

wait $pa; sa=$?
wait $pb; sb=$?

[ $sa -eq 0 ] || falhou "Sessão A falhou com erro: $(cat "$TMP/a.err")"
[ $sb -eq 0 ] || falhou "Sessão B falhou com erro: $(cat "$TMP/b.err")"

res_a=$(cat "$TMP/a.out" 2>/dev/null || echo "0")
res_b=$(cat "$TMP/b.out" 2>/dev/null || echo "0")
echo "  Despachos retornados por A: $res_a | por B: $res_b"

echo "▸ Verificando integridade e atomicidade pós-corrida"

# 1. Contagem de despachos
n_despachos=$(psql -tAc "select count(*)::int from public.despacho where vaga_id = '$VAGA_ID'")
if [ "$n_despachos" -eq "$total_elegiveis" ]; then
  ok "Exatamente $total_elegiveis despachos gravados em public.despacho (sem duplicidade)"
else
  falhou "Esperava $total_elegiveis despachos, encontrou $n_despachos"
fi

# 2. Contagem de notificações de vaga
n_notificacoes=$(psql -tAc "
  select count(*)::int from public.notificacao
   where tipo = 'vaga' and referencia_id = '$VAGA_ID'")
if [ "$n_notificacoes" -eq "$total_elegiveis" ]; then
  ok "Exatamente $total_elegiveis notificações criadas (UNIQUE de marca de envio impediu duplicatas na corrida)"
else
  falhou "Notificações duplicadas detectadas! Esperava $total_elegiveis, encontrou $n_notificacoes"
fi

# 3. Associação 1:1 entre despacho e notificacao_id
n_validos=$(psql -tAc "
  select count(*)::int from public.despacho
   where vaga_id = '$VAGA_ID' and notificacao_id is not null")
if [ "$n_validos" -eq "$total_elegiveis" ]; then
  ok "Cada despacho aponta para uma notificação válida"
else
  falhou "Despachos sem notificacao_id válida: $n_validos de $total_elegiveis"
fi

echo
if [ "$falha" -eq 0 ]; then
  echo "✓ Prova de concorrência aprovada: despacho e notificação são atômicos sob concorrência."
  exit 0
else
  echo "✗ Falha na prova de concorrência."
  exit 1
fi
