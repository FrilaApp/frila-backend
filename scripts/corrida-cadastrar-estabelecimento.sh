#!/usr/bin/env bash
# `cadastrar_estabelecimento` com dois pedidos no ar ao mesmo tempo.
#
# O pgTAP roda numa sessão só e não enxerga corrida. Aqui são duas conexões de verdade:
# a sessão A cadastra o documento e segura o commit com `pg_sleep`; a sessão B dispara o
# mesmo cadastro, fica presa no índice único esperando A, e só termina depois que A
# comita. É o caso real do app que dá timeout e reenvia com o primeiro pedido no ar.
#
# Dois cenários, e o script exige os dois:
#
#   mesmo dono   B recebe o estabelecimento que A criou — a idempotência pela chave
#                natural que a função promete vale também sob concorrência
#   outra conta  B recebe 409 documento_ja_cadastrado, e não vira membro de nada
#
# Defesa contra passar por motivo errado: o script confere em `pg_stat_activity` que B
# ficou de fato esperando lock enquanto A segurava o commit. Se B não esperou, a corrida
# não aconteceu e o resultado não prova nada — isso reprova.
#
# Cada execução usa contas e documento novos, e apaga o que criou ao sair.
#
# Uso:  ./scripts/corrida-cadastrar-estabelecimento.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}
SEGURA=${SEGURA:-4}   # segundos que A segura o commit

psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

ok()    { printf '  ✓ %s\n' "$1"; }
falhou(){ printf '  ✗ %s\n' "$1" >&2; falha=1; }

TMP=$(mktemp -d)
falha=0

uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
DONO=$(uuid); OUTRO=$(uuid)

# Um CNPJ válido novo: 12 dígitos ao acaso e o par verificador que a própria função do
# banco aceita. Documento fixo colidiria com a execução anterior.
DOC=$(psql -tAc "
  select c from (select b || lpad(i::text, 2, '0') c
                   from (select lpad((floor(random() * 1e12))::bigint::text, 12, '0') b) s,
                        generate_series(0, 99) i) t
   where privado.documento_valido(c) limit 1")
[ -n "$DOC" ] || { echo "não consegui gerar um CNPJ válido" >&2; exit 1; }

limpar() {
  psql >/dev/null <<SQL || echo "  aviso: a limpeza falhou; sobrou dado das contas $DONO e $OUTRO" >&2
delete from public.membro_estabelecimento
 where estabelecimento_id in (select id from public.estabelecimento where documento = '$DOC');
delete from public.estabelecimento where documento = '$DOC';
delete from public.usuario where id in ('$DONO', '$OUTRO');
delete from auth.users     where id in ('$DONO', '$OUTRO');
SQL
  rm -rf "$TMP"
}
trap limpar EXIT

# As duas contas de contratante, criadas pela RPC, como o app cria.
criar() { # uuid email telefone
  psql >/dev/null <<SQL
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', '$1', 'authenticated', 'authenticated',
        '$2', now(), '{"provider":"email"}', '{}', now(), now(), false, false);
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"$1","role":"authenticated"}', true);
select public.criar_conta('contratante', 'Corrida', '$3', '1980-01-01', '2026-09-22');
commit;
SQL
}
criar "$DONO"  "corrida-$DONO@frila.test"  "+55619$(printf '%08d' $((RANDOM * RANDOM % 100000000)))" || exit 1
criar "$OUTRO" "corrida-$OUTRO@frila.test" "+55619$(printf '%08d' $((RANDOM * RANDOM % 100000000)))" || exit 1

cadastro="select public.cadastrar_estabelecimento('Bar da Corrida', '$DOC', 'food_service',
            'SCLN 405, Asa Norte', '{\"latitude\":-15.7942,\"longitude\":-47.8822}')"

# sessão <nome> <uuid> <segurar?>
sessao() {
  local espera=""
  [ "$3" = sim ] && espera="select pg_sleep($SEGURA);"
  psql -tA -v ON_ERROR_STOP=1 <<SQL
set application_name = 'corrida_$1';
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"$2","role":"authenticated"}', true) \\g /dev/null
$cadastro;
$espera
commit;
SQL
}

# Espera até a sessão aparecer no estado pedido; devolve 1 se não aparecer a tempo.
esperar_estado() { # application_name condição
  for _ in $(seq 1 50); do
    n=$(psql -tAc "select count(*) from pg_stat_activity where application_name = '$1' and $2")
    [ "$n" = "1" ] && return 0
    sleep 0.1
  done
  return 1
}

rodada() { # rótulo uuid_de_B
  local rotulo=$1 b=$2
  echo "▸ $rotulo"

  sessao "a" "$DONO" sim >"$TMP/a.out" 2>"$TMP/a.err" &
  local pa=$!
  # A já inseriu e está dormindo com o commit pendente.
  esperar_estado corrida_a "query like '%pg_sleep%'" \
    || { falhou "a sessão A não chegou a segurar o commit"; wait $pa; return; }

  sessao "b" "$b" nao >"$TMP/b.out" 2>"$TMP/b.err" &
  local pb=$!
  if esperar_estado corrida_b "wait_event_type = 'Lock'"; then
    ok "B ficou esperando o lock de A — a corrida aconteceu"
  else
    falhou "B não esperou A; a corrida não aconteceu e o resultado não prova nada"
  fi

  wait $pa; local sa=$?
  wait $pb; local sb=$?

  [ $sa -eq 0 ] || { falhou "a sessão A falhou: $(cat "$TMP/a.err")"; return; }
  id_a=$(python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['id'])" <"$TMP/a.out")
  ok "A cadastrou o estabelecimento $id_a"
}

# ── Mesmo dono, dois pedidos ao mesmo tempo ────────────────────────────────────
rodada "mesmo dono, dois pedidos ao mesmo tempo" "$DONO"
if [ -s "$TMP/b.err" ]; then
  falhou "B recebeu erro em vez do estabelecimento: $(tr '\n' ' ' <"$TMP/b.err")"
else
  id_b=$(python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['id'])" <"$TMP/b.out" 2>/dev/null)
  papel_b=$(python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['papel'])" <"$TMP/b.out" 2>/dev/null)
  [ "$id_b" = "${id_a:-}" ] && ok "B recebeu o mesmo estabelecimento ($id_b)" \
    || falhou "B recebeu '$id_b', esperado '${id_a:-}'"
  [ "$papel_b" = "administrador" ] && ok "e como administrador" \
    || falhou "B recebeu papel '$papel_b'"
fi
n=$(psql -tAc "select count(*) from public.estabelecimento where documento = '$DOC'")
[ "$n" = "1" ] && ok "uma linha de estabelecimento só" || falhou "$n linhas para o documento"
n=$(psql -tAc "select count(*) from public.membro_estabelecimento where usuario_id = '$DONO'")
[ "$n" = "1" ] && ok "um vínculo de membro só" || falhou "$n vínculos de membro para o dono"

# Apaga para a segunda rodada começar do zero com o mesmo documento.
psql >/dev/null <<SQL
delete from public.membro_estabelecimento
 where estabelecimento_id in (select id from public.estabelecimento where documento = '$DOC');
delete from public.estabelecimento where documento = '$DOC';
SQL

# ── Outra conta, ao mesmo tempo ────────────────────────────────────────────────
rodada "outra conta com o mesmo documento, ao mesmo tempo" "$OUTRO"
if grep -q '"code" : "documento_ja_cadastrado"' "$TMP/b.err" && grep -q '"status" : 409' "$TMP/b.err"; then
  ok "B recebeu 409 documento_ja_cadastrado"
else
  falhou "B deveria receber 409 documento_ja_cadastrado; recebeu: $(cat "$TMP/b.out" "$TMP/b.err" | tr '\n' ' ')"
fi
n=$(psql -tAc "select count(*) from public.membro_estabelecimento where usuario_id = '$OUTRO'")
[ "$n" = "0" ] && ok "e a outra conta não virou membro de nada" || falhou "a outra conta tem $n vínculos"

echo
if [ $falha -ne 0 ]; then
  echo "Corrida no cadastro: FALHOU"
  exit 1
fi
echo "Corrida no cadastro: ok"
