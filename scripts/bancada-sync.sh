#!/usr/bin/env bash
# A ponte entre este repositório e o vault da Bancada.
#
# Os commits daqui não chegam lá sozinhos: o hook do vault registra os commits do
# próprio vault, e este repositório é outro. Sem esta ponte, o backend trabalha e a
# Bancada — que é onde os mentores acompanham o processo — não vê nada.
#
#   ./scripts/bancada-sync.sh                     os commits de hoje
#   ./scripts/bancada-sync.sh 2026-09-22          os de outro dia
#   ./scripts/bancada-sync.sh --seco              mostra o que faria
#   ./scripts/bancada-sync.sh --fato <tipo> <descrição…>
#
# O vault é procurado em `../monorepo/doc-harness` e depois em `../doc-harness`;
# `BANCADA_DIR` no `.env` sobrepõe. Ver "Achar o vault", abaixo: são três pastas com o
# mesmo nome e a mesma estrutura, e só uma é a viva.
#
# ── O que este script NÃO faz ─────────────────────────────────────────────────
#
# Ele não escreve a narrativa do dia. A regra de ouro do vault é que fato e narrativa
# são camadas separadas, e que nenhum bullet da nota diária pode existir sem um fato
# por trás. Um script que transformasse assunto de commit em prosa estaria inventando
# a camada de cima a partir da de baixo — que é exatamente o que a regra proíbe.
#
# O que ele faz é levar os **fatos** para o outro lado e deixar a nota do dia pronta,
# com os fatos listados na saída para quem for escrever a narrativa. A última seção
# da saída diz o que falta.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[ -f .env ] && { set -a; source .env; set +a; }

# ── Achar o vault ──────────────────────────────────────────────────────────────
#
# Existem três pastas chamadas `doc-harness` na máquina e só uma é o vault vivo:
#
#   monorepo/doc-harness   FrilaApp/Bancada · é este. Tem 07 - Arquitetura, e é o que
#                          publica em bancada-buu.pages.dev a cada push
#   doc-harness            FrilaApp/Bancada · o repositório avulso de antes da
#                          migração para o monorepo. Parou em 2026-09-10
#   Frila/doc-harness      cópia dentro do monorepo do Frila, mais antiga ainda
#
# Escrever na errada é fácil e silencioso: as três têm a mesma estrutura e os mesmos
# scripts. Por isso a escolha é por ordem declarada, e não por "a primeira que eu
# achar" — e `BANCADA_DIR` no `.env` sobrepõe quando a máquina for diferente.
achar_vault() {
  local c
  for c in "$@"; do
    [ -d "$c/.git" ] || [ -d "$c/05 - Registros" ] || continue
    [ -x "$c/scripts/registrar-fato.sh" ] || continue
    printf '%s' "$c"
    return 0
  done
  return 1
}

ACIMA="$(cd .. && pwd)"
VAULT="${BANCADA_DIR:-$(achar_vault "$ACIMA/monorepo/doc-harness" "$ACIMA/doc-harness" || true)}"
SECO=0

ok()     { printf '  ✓ %s\n' "$1"; }
pulo()   { printf '  · %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; exit 1; }

[ -n "$VAULT" ] \
  || falhou "vault não encontrado em ../monorepo/doc-harness nem em ../doc-harness — aponte BANCADA_DIR no .env"
[ -x "$VAULT/scripts/registrar-fato.sh" ] \
  || falhou "$VAULT/scripts/registrar-fato.sh ausente ou sem permissão de execução"

# Os hooks do vault ficam desligados sem avisar — `core.hooksPath` apontando para um
# caminho que não existe faz o git não rodar hook nenhum e não reclamar. Foi o que
# manteve o registro parado entre 10/09 e 23/09. Aqui o aviso é alto, porque sem hook
# os fatos que esta ponte escreve nunca são commitados nem publicados.
raiz_git_vault="$(git -C "$VAULT" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$raiz_git_vault" ]; then
  hooks="$(git -C "$VAULT" config core.hooksPath 2>/dev/null || true)"
  if [ -z "$hooks" ] || [ ! -d "$raiz_git_vault/$hooks" ]; then
    printf '  ⚠ Os hooks do vault não estão instalados (core.hooksPath: %s).\n' "${hooks:-vazio}" >&2
    printf '    Os fatos escritos agora não serão commitados nem publicados.\n' >&2
    printf '    Conserte com: (cd %s && ./scripts/bootstrap.sh)\n\n' "$VAULT" >&2
  fi
fi

echo "▸ Vault: $VAULT"
echo

# `registrar-fato.sh` é a única porta de escrita do log, e o hook `PreToolUse` do vault
# recusa qualquer outro caminho. Este script não tenta nenhum: ele chama o script.
#
# Duas formas, e a diferença importa:
#
#   externo   carrega a data, a hora e o autor do commit daqui. É o que o log precisa:
#             o fato sobre um commit pertence ao dia em que o commit foi feito.
#   arbitrária  carimba o agora e esta máquina. Certa para o fato que acontece agora —
#             um portão que reprovou, um PR aberto.
#
# A primeira versão desta ponte usava a arbitrária para tudo, e uma jornada inteira de
# 22/09 aterrissou no log de 23/09. O diário daquele dia passaria a dizer que o esquema
# do banco nasceu num dia em que ninguém o escreveu.
registrar_commit() { # registrar_commit <data> <hora> <autor> <descrição>
  if [ "$SECO" = 1 ]; then printf '  registraria: %s %s · %s\n' "$1" "$2" "$4"; return 0; fi
  ( cd "$VAULT" && ./scripts/registrar-fato.sh externo "$1" "$2" "$3" frila-backend "$4" )
}

registrar_agora() { # registrar_agora <tipo> <descrição>
  if [ "$SECO" = 1 ]; then printf '  registraria: [%s] %s\n' "$1" "$2"; return 0; fi
  ( cd "$VAULT" && ./scripts/registrar-fato.sh "$1" "$2" )
}

ja_registrado() { grep -rqF -- "\`$1\`" "$VAULT/05 - Registros" 2>/dev/null; }

# ── Fato avulso ────────────────────────────────────────────────────────────────
#
# Para o que foi medido e não é commit: um PR aberto, um portão que reprovou, um
# número que vai importar depois. Sem isto, esse tipo de fato só existiria na cabeça
# de quem mediu, e a narrativa do dia não teria de onde sair.
if [ "${1:-}" = "--fato" ]; then
  shift
  tipo="${1:?uso: bancada-sync.sh --fato <tipo> <descrição…>}"; shift
  [ $# -gt 0 ] || falhou "falta a descrição do fato"
  registrar_agora "$tipo" "$*"
  ok "fato registrado: [$tipo] $*"
  exit 0
fi

DIA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --seco) SECO=1 ;;
    -*)     falhou "opção desconhecida: $1" ;;
    *)      DIA="$1" ;;
  esac
  shift
done
DIA="${DIA:-$(date +%Y-%m-%d)}"

printf '%s\n' "$DIA" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
  || falhou "data em formato inesperado: $DIA (use AAAA-MM-DD)"

echo "▸ Commits do backend em $DIA"

# `--branches` e não `--all`: trabalho em branch ainda não mergeada é trabalho feito, e
# a Bancada registra o processo, não só o que chegou ao main — mas `--all` inclui
# `refs/stash`, e um `git stash` vira dois commits com assunto "index on <branch>" e
# "untracked files on <branch>". Eles chegaram a entrar no log antes de isto virar
# `--branches`. Guardar trabalho não é trabalho.
#
# `--no-merges` porque o merge não é trabalho novo: o que ele traz já foi registrado
# quando foi commitado.
#
# Sem `mapfile`: o bash do macOS é 3.2, e o array vem de um arquivo temporário. Um
# `while read` alimentado por cano rodaria num subshell, e os contadores voltariam
# zerados — o script diria "0 fatos novos" depois de registrar oito.
lista=$(mktemp)
trap 'rm -f "$lista"' EXIT
# `--since/--until` filtram pela data do committer. O fato, porém, pertence ao dia
# em que o autor escreveu o commit. Um rebase ou cherry-pick pode mover a data do
# committer para outro dia sem mudar a data do autor, então filtramos a data do
# autor explicitamente depois da coleta. O ISO 8601 preserva também o fuso original
# para que a hora registrada seja a hora do autor, não a hora desta máquina.
git log --branches --no-merges \
  --format='%h%x09%aI%x09%an%x09%s' \
  | awk -F '\t' -v dia="$DIA" 'substr($2, 1, 10) == dia { print }' > "$lista"

total=$(grep -c . "$lista" || true)
novos=0

if [ "$total" -eq 0 ]; then
  pulo "nenhum commit neste dia — um dia sem registro é um dado, não um problema"
else
  while IFS=$'\t' read -r sha data quem assunto; do
    [ -n "$sha" ] || continue
    if ja_registrado "$sha"; then
      pulo "$sha já estava no log"
      continue
    fi
    hora="${data:11:5}"
    n=$(git show --pretty="" --name-only "$sha" | grep -c . || true)
    if [ "$n" -eq 1 ]; then arquivos="1 arquivo"; else arquivos="$n arquivos"; fi
    registrar_commit "$DIA" "$hora" "$quem" "\`$sha\` — $assunto · $arquivos"
    ok "$sha $assunto"
    novos=$((novos+1))
  done < "$lista"
  echo
  echo "  $novos fato(s) novo(s) de $total commit(s)."
fi

# ── A nota do dia ──────────────────────────────────────────────────────────────

NOTA="$VAULT/02 - Atualizações Diárias/${DIA:0:4}/${DIA:5:2}/$DIA.md"

echo
echo "▸ Nota diária"

if [ -f "$NOTA" ]; then
  ok "já existe: ${NOTA#"$VAULT"/}"
elif [ "$SECO" = 1 ]; then
  pulo "criaria ${NOTA#"$VAULT"/} a partir do modelo"
else
  mkdir -p "$(dirname "$NOTA")"
  # As cinco seções são fixas por regra do vault: não inventar, não renomear, não
  # remover. Saem do modelo em vez de serem copiadas aqui, para que uma mudança no
  # modelo não deixe este script escrevendo a versão antiga em silêncio.
  modelo="$VAULT/02 - Atualizações Diárias/Template - Atualização Diária.md"
  [ -f "$modelo" ] || falhou "modelo da nota diária não encontrado em $modelo"
  sed -e "s/^data: $/data: $DIA/" -e "s/{{AAAA-MM-DD}}/$DIA/" "$modelo" > "$NOTA"
  ok "criada a partir do modelo: ${NOTA#"$VAULT"/}"
fi

# ── O que falta, dito em voz alta ──────────────────────────────────────────────
#
# Um portão que termina em silêncio quando não fez nada é um portão que ensina o time
# a ignorá-lo. Este diz o que sobrou para a pessoa.

LOG="$VAULT/05 - Registros/${DIA:0:4}/${DIA:5:2}/$DIA.md"

echo
echo "▸ Falta escrever"
if [ -f "$LOG" ]; then
  echo "  Os fatos de $DIA, que são a matéria-prima da narrativa:"
  grep -c '^- `' "$LOG" >/dev/null 2>&1 && grep '^- `' "$LOG" | sed 's/^/    /'
else
  echo "  (sem log de fatos em $DIA)"
fi
echo
echo "  A narrativa não é escrita por este script: cada bullet da nota diária tem de"
echo "  sair de um fato acima, e um script que virasse assunto de commit em prosa"
echo "  estaria inventando a camada que a regra do vault manda não inventar."
echo
echo "  Escreva em: ${NOTA#"$VAULT"/}"
echo "  Seções fixas: O que foi feito · Decisões · Bloqueios · Aprendizados · Próximos passos"
echo
echo "  O push do vault exige Touch ID, e é deliberado. Nunca use SKIP_BIOMETRICS=1."
