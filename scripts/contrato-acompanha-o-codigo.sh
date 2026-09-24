#!/usr/bin/env bash
# Um PR que muda a superfície da API tem de mudar o contrato, no mesmo PR.
#
# O contrato é a fonte dos modelos de três clientes nativos. Quando a assinatura de uma
# RPC muda aqui e o contrato não acompanha, o iOS continua gerando o modelo antigo e
# ninguém descobre até a chamada falhar em runtime — do lado de quem instalou o app.
#
# Este portão fecha a janela. Se o PR toca uma função do schema `public` em
# `supabase/migrations/`, então `contrato/openapi.yaml` também tem de mudar **e** o
# `info.version` tem de subir.
#
#   ./scripts/contrato-acompanha-o-codigo.sh                 compara com origin/main
#   ./scripts/contrato-acompanha-o-codigo.sh origin/s0/algo  compara com outra base
#
# ── O que este portão NÃO cobre ───────────────────────────────────────────────
#
# Ele lê o diff, não o banco. Uma função criada por caminho que o padrão abaixo não
# reconhece passa batido, e uma mudança de corpo que não altera a assinatura é acusada
# à toa — o primeiro é o erro caro, e por isso o padrão é largo de propósito.
#
# Quem mede a superfície de verdade é o teste de contrato contra o banco de pé. Este
# portão é a rede que pega o esquecimento antes de o PR ser aberto.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE="${1:-origin/main}"
ESPELHO=contrato/openapi.yaml
SOMA=contrato/openapi.yaml.sha256

# O `actions/checkout` traz só o necessário para o commit de merge; a base vem por
# aqui. O `|| true` é para o clone local, onde a base já existe e pode não haver rede.
git fetch --quiet origin "${BASE#origin/}" 2>/dev/null || true

# Sem a base não há o que comparar, e um portão que não consegue medir reprova em vez
# de passar — é a regra que este repositório já pagou cinco vezes para aprender.
git rev-parse --verify --quiet "$BASE" >/dev/null || {
  echo "✗ Base '$BASE' não existe neste clone, e sem ela não há o que comparar."
  echo "  Na CI, passe origin/\$GITHUB_BASE_REF. No local, 'git fetch origin main'."
  exit 1
}

# ── O PR mexeu em função de `public`? ──────────────────────────────────────────
#
# `create function`, `create or replace function`, `drop function` e `alter function`,
# com o nome qualificado — que é como este repositório escreve, sem exceção, porque
# toda migração roda com `search_path = ''`.
#
# Só as linhas **adicionadas**: uma migração removida do PR não muda a superfície do
# ambiente, que só conhece o que foi aplicado.
tocadas=$(git diff "$BASE"...HEAD -- supabase/migrations \
  | grep -E '^\+' \
  | grep -viE '^\+\s*--' \
  | grep -oiE '(create|drop|alter)[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?function[[:space:]]+public\.[a-z0-9_]+' \
  | grep -oiE 'public\.[a-z0-9_]+' \
  | sort -u || true)

if [ -z "$tocadas" ]; then
  echo "Nenhuma função de public tocada em supabase/migrations. Nada a exigir do contrato."
  exit 0
fi

echo "Funções de public tocadas neste PR:"
printf '  %s\n' $tocadas
echo

falta=0

# ── O contrato mudou? ──────────────────────────────────────────────────────────
if git diff --quiet "$BASE"...HEAD -- "$ESPELHO"; then
  echo "✗ $ESPELHO não mudou."
  echo
  echo "  O contrato é a fonte dos modelos do iOS, do Android e da web. Uma RPC que"
  echo "  muda aqui e não muda lá é um cliente gerando o modelo antigo até a chamada"
  echo "  falhar no aparelho de alguém."
  echo
  echo "  O contrato nasce em BlendOps/Frila · Documentos/API/openapi.yaml, num PR"
  echo "  próprio. Depois traga o arquivo e regrave a soma:"
  echo
  echo "    gh api repos/BlendOps/Frila/contents/Documentos/API/openapi.yaml \\"
  echo "      -H 'Accept: application/vnd.github.raw' > $ESPELHO"
  echo "    shasum -a 256 $ESPELHO | awk '{print \$1}' > $SOMA"
  falta=1
else
  echo "✓ $ESPELHO mudou neste PR."
fi

# ── A versão subiu? ────────────────────────────────────────────────────────────
#
# Não basta o arquivo ter mudado: sem a versão subindo, o cliente não tem como saber
# que o modelo que ele gerou é de antes. É a única coisa que um app já publicado
# consegue comparar.
versao_de() {
  local ref="$1"
  if [ "$ref" = "HEAD" ]; then
    sed -n 's/^  version: *//p' "$ESPELHO" | head -1
  else
    git show "$ref:$ESPELHO" 2>/dev/null | sed -n 's/^  version: *//p' | head -1
  fi
}

antes=$(versao_de "$BASE")
depois=$(versao_de HEAD)

if [ -z "$depois" ]; then
  echo "✗ Não achei info.version em $ESPELHO."
  falta=1
elif [ -z "$antes" ]; then
  echo "· Contrato novo na base ($depois). Nada com que comparar a versão."
elif [ "$antes" = "$depois" ]; then
  echo "✗ info.version continua $depois."
  echo
  echo "  Adição compatível sobe o patch: $antes → ${antes%.*}.$(( ${antes##*.} + 1 ))."
  echo "  Mudança incompatível não sobe versão: vira função nova (publicar_vaga_v2),"
  echo "  e a antiga fica no ar enquanto houver app antigo na loja."
  falta=1
else
  # `sort -V` decide a ordem; "subiu" é o que interessa, não quanto. O caso de
  # igualdade já saiu no ramo anterior.
  menor=$(printf '%s\n%s\n' "$antes" "$depois" | sort -V | head -1)
  if [ "$menor" != "$antes" ]; then
    echo "✗ info.version foi de $antes para $depois — isso é descer."
    falta=1
  else
    echo "✓ info.version: $antes → $depois."
  fi
fi

echo
if [ "$falta" -ne 0 ]; then
  echo "O contrato não acompanhou o código."
  exit 1
fi

echo "O contrato acompanhou o código."
