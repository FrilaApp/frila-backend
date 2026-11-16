# shellcheck shell=bash
# Senha do Postgres fora da linha de comando (B-027.j). Para dar `source`; não roda sozinho.
#
# A linha de comando de qualquer processo aparece no `ps` para todo usuário da máquina, e a URL do banco traz a
# senha. Com este arquivo, a URL que vai ao psql, ao pg_dump ou ao python fica SEM a senha, e a senha vai SÓ no
# ambiente do processo filho, em PGPASSWORD. A URL é lida como o libpq a lê: usuário e senha vão até a primeira
# @ antes da primeira /, e a senha pode vir codificada (%40 é @, %3A é :, %25 é %), que aqui é decodificada.
# Sem senha na URL, nada muda: a URL segue igual e o PGPASSWORD (ou o .pgpass) de quem chamou continua valendo.
# Bash 3.2 (macOS) e 5 (Linux do runner), sem python: o backup do Prod roda no ubuntu-latest da CI.
#
#   separar_senha_da_url <url>        → PG_URL_SEM_SENHA (a URL sem a senha) e PG_SENHA (vazia se não havia)
#   com_senha_da_url <cmd> [args...]  → roda <cmd> com PGPASSWORD=PG_SENHA só no ambiente dele (sem senha: como veio)
#   psql_url <url> [args do psql...]  → psql na URL sem senha, com a senha só no ambiente do psql
#
# Erro (volta 2): só o motivo, em stderr. A URL nunca é mostrada.

PG_URL_SEM_SENHA=""
PG_SENHA=""

# %XX → o byte, como o libpq (conninfo_uri_decode): % sem dois dígitos hexadecimais é erro, e %00 também.
_PG_DECODIFICADA=""
_pg_decodificar() {
  local resto=$1 saida="" hex byte
  while [ -n "$resto" ]; do
    case "$resto" in
      %*)
        hex=${resto:1:2}
        case "$hex" in [0-9A-Fa-f][0-9A-Fa-f]) ;; *) return 2 ;; esac
        case "$hex" in 00) return 2 ;; esac
        printf -v byte '%b' "\\x$hex"
        saida=$saida$byte
        resto=${resto:3} ;;
      *)
        saida=$saida${resto:0:1}
        resto=${resto:1} ;;
    esac
  done
  _PG_DECODIFICADA=$saida
}

# As duas variáveis só recebem valor no sucesso: num erro ficam vazias (nunca sobra a URL com a senha nelas).
separar_senha_da_url() {
  local url=$1 prefixo resto antes_da_barra userinfo codificada consulta sem_senha senha=""
  PG_URL_SEM_SENHA=""
  PG_SENHA=""
  case "$url" in
    postgresql://*) prefixo=postgresql:// ;;
    postgres://*)   prefixo=postgres:// ;;
    *) printf 'pg-sem-senha: a URL do banco não começa com postgresql:// nem postgres:// (a URL não é mostrada)\n' >&2
       return 2 ;;
  esac
  sem_senha=$url
  resto=${url#"$prefixo"}
  antes_da_barra=${resto%%/*}
  case "$antes_da_barra" in
    *@*)
      userinfo=${antes_da_barra%%@*}
      case "$userinfo" in
        *:*)
          codificada=${userinfo#*:}
          if [ -n "$codificada" ]; then
            _pg_decodificar "$codificada" || {
              _PG_DECODIFICADA=""
              printf 'pg-sem-senha: a senha da URL tem um %% sem dois dígitos hexadecimais, ou %%00 (a URL não é mostrada)\n' >&2
              return 2
            }
            senha=$_PG_DECODIFICADA
            _PG_DECODIFICADA=""
            sem_senha=$prefixo${userinfo%%:*}@${resto#*@}
          fi ;;
      esac ;;
  esac
  # Senha nos parâmetros (?password=...) também iria para a linha de comando: recusa em vez de passar adiante.
  consulta=""
  case "$sem_senha" in *\?*) consulta=${sem_senha#*\?} ;; esac
  case "&$consulta" in
    *"&password="*)
      printf 'pg-sem-senha: a URL traz password= nos parâmetros; ponha a senha antes do @ (a URL não é mostrada)\n' >&2
      return 2 ;;
  esac
  PG_URL_SEM_SENHA=$sem_senha
  PG_SENHA=$senha
  return 0
}

com_senha_da_url() {
  if [ -n "$PG_SENHA" ]; then
    PGPASSWORD=$PG_SENHA "$@"
  else
    "$@"
  fi
}

psql_url() {
  local url=$1
  shift
  separar_senha_da_url "$url" || return 2
  com_senha_da_url psql "$PG_URL_SEM_SENHA" "$@"
}
