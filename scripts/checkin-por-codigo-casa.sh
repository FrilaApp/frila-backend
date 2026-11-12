#!/usr/bin/env bash
# Liga, desliga e consulta o check-in por código para um estabelecimento específico (RN46).
#
# Uso:
#   ./scripts/checkin-por-codigo-casa.sh estado <estabelecimento_id>
#   ./scripts/checkin-por-codigo-casa.sh ligar <estabelecimento_id> [--sim] [--seco] [--versao-minima <versao>]
#   ./scripts/checkin-por-codigo-casa.sh desligar <estabelecimento_id> [--sim] [--seco]
#
#   estado      mostra se a chave está em vigor para o estabelecimento (somente leitura)
#   ligar       habilita o check-in por código na casa, garantindo chave global,
#               versão mínima do app e cadastro da casa (exige confirmação explícita)
#   desligar    remove o estabelecimento da lista, voltando ao fluxo legado na hora
#
# Opções:
#   --seco      mostra o que faria e não escreve nada no banco
#   --sim       dispensa a confirmação interativa (para automação e testes)
#   --versao-minima <v>  versão mínima do iOS em privado.recurso_versao_minima (padrão: 1.2.0)
#
# Alvo do banco:
#   DATABASE_URL se exportada; senão o contêiner local (${DB_CONTAINER:-supabase_db_frila-backend}).
#   Credenciais e segredos nunca são impressos no terminal ou logs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"
VERSAO_MINIMA_PADRAO="1.2.0"

uso() {
  cat >&2 <<'TXT'
uso: checkin-por-codigo-casa.sh <comando> <estabelecimento_id> [opções]

Comandos:
  estado <uuid>      consulta o estado do recurso para o estabelecimento (somente leitura)
  ligar <uuid>       liga o recurso para o estabelecimento (exige confirmação)
  desligar <uuid>    desliga o recurso para o estabelecimento, voltando ao legado

Opções:
  --seco             mostra o que faria sem alterar o banco
  --sim              não pede confirmação interativa
  --versao-minima <v> versão mínima do iOS (padrão: 1.2.0)
  -h, --help         mostra esta ajuda
TXT
  exit 1
}

psql_q() {
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 "$@"
  else
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 "$@"
  fi
}

# Alvo sem segredos/senhas para exibição segura
alvo() {
  if [ -n "${DATABASE_URL:-}" ]; then
    python3 - "$DATABASE_URL" <<'PY'
import sys
from urllib.parse import urlsplit
u = urlsplit(sys.argv[1])
host = u.hostname or '?'
port = f":{u.port}" if u.port else ""
path = u.path or ''
print(f"{host}{port}{path} (DATABASE_URL)")
PY
  else
    printf 'contêiner %s (banco local)\n' "$DB_CONTAINER"
  fi
}

validar_uuid() {
  local id="$1"
  if ! [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    printf '✗ UUID inválido para estabelecimento_id: %s\n' "$id" >&2
    exit 1
  fi
}

obter_nome_estabelecimento() {
  local id="$1"
  local id_escapado
  id_escapado="$(printf '%s' "$id" | sed "s/'/''/g")"
  psql_q -c "select nome from public.estabelecimento where id = '$id_escapado'"
}

verificar_tabelas() {
  local res
  res="$(psql_q -c "
    select (to_regclass('privado.recurso') is not null
            and to_regclass('privado.recurso_estabelecimento') is not null
            and to_regclass('privado.recurso_versao_minima') is not null)::text
  ")"
  if [ "$res" != "true" ]; then
    printf '✗ Tabelas de controle de recurso não encontradas neste banco.\n' >&2
    printf '  Aplique as migrações 20261108150000, 20261109101000 e 20261111203000 antes.\n' >&2
    exit 1
  fi
}

# ── Parse de Argumentos ────────────────────────────────────────────────────────

[ $# -ge 2 ] || uso

comando="$1"
estab_id="$2"
shift 2

case "$comando" in
  estado|ligar|desligar) ;;
  -h|--help) uso ;;
  *) printf '✗ Comando desconhecido: %s\n' "$comando" >&2; uso ;;
esac

validar_uuid "$estab_id"

seco=0
sim=0
versao_minima="$VERSAO_MINIMA_PADRAO"

while [ $# -gt 0 ]; do
  case "$1" in
    --seco) seco=1 ;;
    --sim)  sim=1 ;;
    --versao-minima)
      [ $# -ge 2 ] || uso
      versao_minima="$2"
      shift
      ;;
    -h|--help) uso ;;
    *) printf '✗ Opção desconhecida: %s\n' "$1" >&2; uso ;;
  esac
  shift
done

verificar_tabelas

estab_nome="$(obter_nome_estabelecimento "$estab_id")"
if [ -z "$estab_nome" ]; then
  printf '✗ Estabelecimento não encontrado: %s\n' "$estab_id" >&2
  printf '  Verifique o ID em public.estabelecimento em %s.\n' "$(alvo)" >&2
  exit 1
fi

ler_estado() {
  local id="$1"
  local id_escapado
  id_escapado="$(printf '%s' "$id" | sed "s/'/''/g")"
  psql_q -c "
    select coalesce((select ligado::text from privado.recurso where chave = 'checkin_por_codigo'), 'false')
           || '|' ||
           coalesce((select versao_minima from privado.recurso_versao_minima where recurso = 'checkin_por_codigo' and plataforma = 'ios'), 'ausente')
           || '|' ||
           exists(select 1 from privado.recurso_estabelecimento where chave = 'checkin_por_codigo' and estabelecimento_id = '$id_escapado')::text
           || '|' ||
           privado.recurso_ligado_para('checkin_por_codigo', '$id_escapado')::text
  "
}

exibir_estado_formatado() {
  local raw="$1"
  local global v_ios na_casa consolidado
  IFS='|' read -r global v_ios na_casa consolidado <<< "$raw"

  if [ "$consolidado" = "true" ]; then
    printf '  Estado consolidado: ATIVO (check-in por código em vigor para esta casa)\n'
  else
    printf '  Estado consolidado: INATIVO (fluxo legado em vigor para esta casa)\n'
  fi
  printf '    • Chave global (privado.recurso):                  %s\n' "$([ "$global" = "true" ] && echo "ligada (true)" || echo "desligada ($global)")"
  printf '    • Versão mínima iOS (privado.recurso_versao_minima): %s\n' "$v_ios"
  printf '    • Casa no piloto (privado.recurso_estabelecimento):  %s\n' "$([ "$na_casa" = "true" ] && echo "cadastrada (true)" || echo "não cadastrada (false)")"
}

# ── 1. Comando: estado ────────────────────────────────────────────────────────

if [ "$comando" = "estado" ]; then
  printf 'Estabelecimento: %s (%s)\n' "$estab_nome" "$estab_id"
  printf 'Alvo: %s\n' "$(alvo)"
  raw_estado="$(ler_estado "$estab_id")"
  exibir_estado_formatado "$raw_estado"
  exit 0
fi

# ── 2. Comando: ligar ─────────────────────────────────────────────────────────

if [ "$comando" = "ligar" ]; then
  printf 'Estabelecimento: %s (%s)\n' "$estab_nome" "$estab_id"
  printf 'Alvo: %s\n' "$(alvo)"
  printf '\n[ANTES]\n'
  antes="$(ler_estado "$estab_id")"
  exibir_estado_formatado "$antes"

  IFS='|' read -r _ antes_v_ios _ antes_cons <<< "$antes"
  if [ "$antes_cons" = "true" ] && [ "$antes_v_ios" = "$versao_minima" ]; then
    printf '\n✓ O recurso já está totalmente ATIVO com a versão %s para esta casa. Nenhuma alteração feita.\n' "$versao_minima"
    exit 0
  fi

  if [ "$seco" -eq 1 ]; then
    printf '\n[MODO SECO] Operação não executada. As seguintes alterações seriam feitas:\n'
    printf '  1. update privado.recurso set ligado = true where chave = '\''checkin_por_codigo'\'';\n'
    printf '  2. insert/update privado.recurso_versao_minima: recurso='\''checkin_por_codigo'\'', plataforma='\''ios'\'', versao_minima='\''%s'\'';\n' "$versao_minima"
    printf '  3. insert into privado.recurso_estabelecimento (chave, estabelecimento_id) values ('\''checkin_por_codigo'\'', '\''%s'\'') on conflict do nothing;\n' "$estab_id"
    exit 0
  fi

  if [ "$sim" -eq 0 ]; then
    printf '\nATENÇÃO: Ligar o check-in por código fará todas as chegadas nesta casa exigirem\n'
    printf 'validação de código de 6 dígitos pela casa. Recomenda-se ligar FORA de turnos em andamento.\n'
    read -r -p "Confirma ligar o check-in por código para '$estab_nome' em $(alvo)? [s/N] " resp
    case "$resp" in
      s|S|sim|SIM|y|Y) ;;
      *) printf 'Operação cancelada pelo operador.\n'; exit 1 ;;
    esac
  fi

  id_esc="$(printf '%s' "$estab_id" | sed "s/'/''/g")"
  ver_esc="$(printf '%s' "$versao_minima" | sed "s/'/''/g")"

  psql_q -c "
    begin;
    insert into privado.recurso (chave, ligado) values ('checkin_por_codigo', true)
      on conflict (chave) do update set ligado = true;
    insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
      values ('checkin_por_codigo', 'ios', '$ver_esc')
      on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;
    insert into privado.recurso_estabelecimento (chave, estabelecimento_id)
      values ('checkin_por_codigo', '$id_esc')
      on conflict do nothing;
    commit;
  "

  printf '\n[DEPOIS]\n'
  depois="$(ler_estado "$estab_id")"
  exibir_estado_formatado "$depois"

  IFS='|' read -r _ _ _ depois_cons <<< "$depois"
  if [ "$depois_cons" = "true" ]; then
    printf '\n✓ Check-in por código ATIVADO com sucesso para '\''%s'\'' (%s).\n' "$estab_nome" "$estab_id"
  else
    printf '\n✗ Falha: estado consolidado não resultou ativo.\n' >&2
    exit 1
  fi
  exit 0
fi

# ── 3. Comando: desligar ──────────────────────────────────────────────────────

if [ "$comando" = "desligar" ]; then
  printf 'Estabelecimento: %s (%s)\n' "$estab_nome" "$estab_id"
  printf 'Alvo: %s\n' "$(alvo)"
  printf '\n[ANTES]\n'
  antes="$(ler_estado "$estab_id")"
  exibir_estado_formatado "$antes"

  IFS='|' read -r _ _ antes_na_casa antes_cons <<< "$antes"
  if [ "$antes_na_casa" = "false" ] && [ "$antes_cons" = "false" ]; then
    printf '\n✓ O recurso já está DESLIGADO para esta casa (fluxo legado ativo). Nenhuma alteração feita.\n'
    exit 0
  fi

  if [ "$seco" -eq 1 ]; then
    printf '\n[MODO SECO] Operação não executada. As seguintes alterações seriam feitas:\n'
    printf '  delete from privado.recurso_estabelecimento where chave = '\''checkin_por_codigo'\'' and estabelecimento_id = '\''%s'\'';\n' "$estab_id"
    exit 0
  fi

  if [ "$sim" -eq 0 ]; then
    printf '\nATENÇÃO: Desligar o recurso volta imediatamente ao fluxo legado (geolocalizado automático <= 200 m).\n'
    printf 'Se houver código já gerado na tela da casa, a validação por código será bloqueada na hora (403)\n'
    printf 'e a presença só poderá ser confirmada via confirmação manual pela casa.\n'
    read -r -p "Confirma desligar o check-in por código para '$estab_nome' em $(alvo)? [s/N] " resp
    case "$resp" in
      s|S|sim|SIM|y|Y) ;;
      *) printf 'Operação cancelada pelo operador.\n'; exit 1 ;;
    esac
  fi

  id_esc="$(printf '%s' "$estab_id" | sed "s/'/''/g")"
  psql_q -c "
    delete from privado.recurso_estabelecimento
     where chave = 'checkin_por_codigo' and estabelecimento_id = '$id_esc';
  "

  printf '\n[DEPOIS]\n'
  depois="$(ler_estado "$estab_id")"
  exibir_estado_formatado "$depois"

  IFS='|' read -r _ _ depois_na_casa depois_cons <<< "$depois"
  if [ "$depois_na_casa" = "false" ] && [ "$depois_cons" = "false" ]; then
    printf '\n✓ Check-in por código DESLIGADO com sucesso para '\''%s'\'' (%s). Casa no fluxo legado.\n' "$estab_nome" "$estab_id"
  else
    printf '\n✗ Falha: estabelecimento continua com recurso ativo.\n' >&2
    exit 1
  fi
  exit 0
fi
