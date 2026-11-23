#!/usr/bin/env bash
# Prepara o frila-dev (ou o banco local, no ensaio) para o teste de ponta a ponta da busca de profissionais
# (B-027.f; contrato 0.2.88): uma casa de TESTE e três profissionais de TESTE, todos sintéticos, que o iOS
# (Prisma) consegue buscar e chamar. Nada de pessoa real, nada no Prod.
#
# ── O que fica criado (ids fixos, então rodar de novo repara e não duplica) ───────────────────────────────
#
#   conta      e-mail                       id                                     perfil
#   casa       busca-casa@frila.test        b027f000-0000-4000-8000-000000000001   contratante (admin da casa)
#   prof 1     busca-prof-1@frila.test      b027f000-0000-4000-8000-000000000011   profissional
#   prof 2     busca-prof-2@frila.test      b027f000-0000-4000-8000-000000000012   profissional
#   prof 3     busca-prof-3@frila.test      b027f000-0000-4000-8000-000000000013   profissional
#   estabelecimento "Casa Teste Busca"      b027f000-0000-4000-8000-0000000000c1   (CNPJ sintético, Plano Piloto)
#   profissional.id: ...0021, ...0022, ...0023 (na mesma ordem dos prof 1, 2, 3)
#
#   prof 1  Ana Faxineira Teste     faxina residencial (diária)    TODO O DF         até 5 km    seg a sex 08h-18h
#   prof 2  Bruno Garçom Teste      garçom (hora), cozinheiro de   Plano Piloto +    5 a 15 km   qui a dom 18h-02h
#                                   festa (evento)                 Guará
#   prof 3  Clara Cozinheira Teste  cozinheiro de festa (por       Plano Piloto      mais de     sáb e dom 10h-22h
#                                   pessoa), garçom (a combinar)   (só ela)          15 km
#
# Todos com "Aceito chamadas diretas" ligado (pela RPC definir_preferencia_chamadas, como o profissional) e um
# aparelho iOS na versão mínima da chamada_direta. A casa e os profissionais são da MESMA população
# (usuario.demonstracao = false), que é o que a busca exige (privado.profissionais_na_busca).
#
# ── Como o Prisma entra (login por código de e-mail) ──────────────────────────────────────────────────────
#
# O e-mail @frila.test não recebe nada. O código vem de `codigo <e-mail>`, que pede ao Auth do projeto um
# código de uma vez só (a mesma chamada de e-mail+código que o app faz) e o escreve no terminal de quem rodou.
# Ele nunca vai para arquivo, log ou documento. Ordem certa, porque pedir um código novo no app invalida o
# anterior:
#   1. no app, digite o e-mail e toque em pedir código (a tela passa para o campo do código);
#   2. `./scripts/dev-busca-teste.sh --alvo dev codigo busca-casa@frila.test`;
#   3. digite o código na tela. Vale uma vez e por até 1 hora (o padrão do Auth).
# `codigo` só aceita os 4 e-mails acima, e só de conta que `montar` já criou (o id fixo e o e-mail conferem
# no Auth): nunca cria conta nem gera código para e-mail de pessoa. Ele só fala HTTPS com a Admin API do Auth
# (a chave service_role vem da Management API): não usa psql nem a porta do banco, então funciona mesmo
# quando a rede barra a 5432/6543. Quem roda: só o Cauê ou o Prisma. Agente nenhum roda `codigo`.
#
# ── Uso ───────────────────────────────────────────────────────────────────────────────────────────────────
#
#   ./scripts/dev-busca-teste.sh [--alvo local|dev] [--via https|psql] montar [--minimo-busca <versão>]
#   ./scripts/dev-busca-teste.sh [--alvo local|dev] conferir        # 4 buscas como a casa, transação desfeita
#   ./scripts/dev-busca-teste.sh [--alvo local|dev] http            # entra pelo Auth e busca pelo REST (4 logins)
#   ./scripts/dev-busca-teste.sh [--alvo local|dev] codigo <e-mail> # o código de entrada, para o Prisma
#   ./scripts/dev-busca-teste.sh [--alvo local|dev] estado          # chaves, versões mínimas e o resumo
#   ./scripts/dev-busca-teste.sh --alvo dev acesso                  # grava ~/.config/frila/dev-teste-busca.md (600)
#   ./scripts/dev-busca-teste.sh --alvo local acesso --saida <arquivo>   # ensaio: a saída tem de ficar fora do repo
#
# O alvo padrão é o banco LOCAL (o ensaio). `--alvo dev` lê a conexão de ~/.config/frila/dev-db-url sem
# imprimi-la e confere o ref dela (trava abaixo). Não existe alvo prod: o script não sabe falar com ele.
#
# No dev, o SQL vai de dois jeitos (`--via`):
#   https (padrão)  pela Management API (POST /v1/projects/<ref>/database/query), com o token de conta de
#                   ~/.config/frila/supabase-token: nenhuma senha de banco e nenhuma porta do Postgres, então
#                   funciona com a 5432/6543 barradas pela rede (B-027.k);
#   psql            o psql pela conexão do dev, que nunca recebe a URL na linha de comando (nada dela aparece no
#                   `ps`): a senha vai num arquivo de senhas temporário (600, apagado na saída) e o resto em
#                   variáveis PG* só do psql.
#
# ── O que `montar` faz e o que NÃO faz com as chaves ──────────────────────────────────────────────────────
#
# Liga `busca_profissionais` e `chamada_direta` em privado.recurso (no dev; no Prod isso é ato do O2).
# A VERSÃO MÍNIMA do iOS é por chave em privado.recurso_versao_minima, e o app só vê
# `recursos.busca_profissionais = true` se existir a linha da busca (a migração não cria nenhuma). Decisão da
# Forja (16/11/2026): no dev, sem linha, o `montar` copia a mínima da chamada_direta (o Prisma testa com o
# build atual); linha que já existe não é tocada, e `--minimo-busca <versão>` sobrescreve.
# No Android (B-027.g), `montar` grava 1.0.0 para as duas chaves quando não há linha (no dev já há, à mão: não é tocada).
# A casa de teste fica com os Termos 1.1 aceitos (termos_versao 2026-11-13), que a busca exige desde a migração 20261116230000. No Prod o script
# não roda: a chave fica desligada e a mínima se decide ao ligar.
#
# Aparelhos de teste: o token FCM é falso de propósito. Se alguma chamada de teste tentar mandar push a um
# deles, o FCM responde UNREGISTERED e o enviar-push APAGA a linha do aparelho (supabase/functions/enviar-push/
# index.ts); sem aparelho, o profissional some da busca. É só rodar `montar` de novo.
#
# (Medido no dev em 16/11/2026: o token falso de hoje recebe INVALID_ARGUMENT, e com esse erro o enviar-push NÃO
# apaga o aparelho; só 404/410 ou UNREGISTERED apagam.)
#
# Chamadas de teste (B-027.k): a busca tira da casa quem já tem chamada ABERTA dela (RN34) e quem recusou chamada
# dela há menos de 24 h ou tem as 3 últimas recusadas/expiradas (CD-C13). Testar o chamar no app deixa isso para
# trás: em 16/11 Bruno recusou às 17:51 e Clara ficou com uma aberta às 18:28, e os dois sumiram das buscas de
# garçom. O `montar` limpa só entre a casa de teste e as 3 profissionais de teste: a aberta a casa cancela pelo
# caminho do produto (cancelar_chamada, como a casa; cancelada não conta na busca), e as recusadas e expiradas
# desse par saem (nenhum caminho do produto desfaz uma recusa; nada depende da linha da chamada). Aceitas (com
# vaga e turno) não são tocadas.
#
# Pelo banco compartilhado: no local, rode pela fila (orquestracao/scripts/fila.sh rodar banco <dono> -- ...).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ALVO=local
DB_CONTAINER=${DB_CONTAINER:-supabase_db_frila-backend}
PSQL=${PSQL:-/opt/homebrew/opt/postgresql@16/bin/psql}
MINIMO_BUSCA=""
SAIDA=""
VIA=https
# O checkout principal (Ground): é o caminho que o arquivo de acesso cita depois da mescla do #518.
CAMINHO_GROUND="$HOME/Documents/Projetos/Frila/frila-backend"

CASA_USUARIO=b027f000-0000-4000-8000-000000000001
CASA_ESTAB=b027f000-0000-4000-8000-0000000000c1
EMAILS_DE_TESTE="busca-casa@frila.test busca-prof-1@frila.test busca-prof-2@frila.test busca-prof-3@frila.test"

ok()      { printf '  ✓ %s\n' "$1"; }
aviso()   { printf '  ! %s\n' "$1" >&2; }
falhou()  { printf '  ✗ %s\n' "$1" >&2; exit 1; }

# Nada que identifique o projeto ou carregue senha sai na tela, nem num erro do psql.
redigir() {
  sed -E 's#postgres(ql)?://[^[:space:]"]+#postgres://<oculto>#g; s#(host|at) "[^"]*"#\1 "<oculto>"#g; s#postgres\.[a-z0-9]{20}#postgres.<ref>#g; s#[a-z0-9]{20}\.(supabase|pooler\.supabase)\.(co|com)#<ref>.\1.\2#g'
}

# ── Argumentos (as opções valem antes ou depois do comando) ───────────────
COMANDO=""; ARG1=""
while [ $# -gt 0 ]; do
  case "$1" in
    --alvo)          ALVO="${2:-}"; shift 2 || break ;;
    --minimo-busca)  MINIMO_BUSCA="${2:-}"; shift 2 || break ;;
    --saida)         SAIDA="${2:-}"; shift 2 || break ;;
    --via)           VIA="${2:-}"; shift 2 || break ;;
    -h|--ajuda)      sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)              falhou "opção desconhecida: $1 (veja --ajuda)" ;;
    *)               if [ -z "$COMANDO" ]; then COMANDO="$1"; elif [ -z "$ARG1" ]; then ARG1="$1"; else falhou "argumento a mais: $1"; fi; shift ;;
  esac
done
case "$ALVO" in local|dev) ;; *) falhou "--alvo vale local ou dev (recebi \"$ALVO\"). Prod não existe aqui." ;; esac
case "$VIA" in https|psql) ;; *) falhou "--via vale https ou psql (recebi \"$VIA\")" ;; esac
case "$COMANDO" in montar|conferir|http|codigo|estado|acesso) ;; *) falhou "uso: dev-busca-teste.sh [--alvo local|dev] montar|conferir|http|codigo <e-mail>|estado|acesso (veja --ajuda)" ;; esac
if [ -n "$MINIMO_BUSCA" ] && ! printf '%s' "$MINIMO_BUSCA" | grep -Eq '^[0-9]{1,6}(\.[0-9]{1,6}){0,2}$'; then
  falhou "--minimo-busca precisa ter de 1 a 3 partes numéricas (ex.: 1.2.0)"
fi

# ── Acesso ao banco ────────────────────────────────────────────────────────
PGURL=""; REF=""
# Trava POSITIVA contra o Prod (parecer do Lince, S1): o ref do projeto sai da URL e o seu sha256 tem de ser o
# do frila-dev, gravado aqui (o ref em si não aparece em lugar nenhum). Qualquer outro ref, ou URL que não dê
# para ler, sai com erro ANTES de qualquer psql ou curl. A constante é o sha256 do ref do frila-dev.
REF_DEV_SHA256="32177c7c441023509f4274c29fbbffb4eb9c216c9d192c7fb2ddf6b6492c3fbd"
# TODOS os refs que a URL traz (usuário postgres.<ref> e/ou host <ref>.supabase.co), um por linha.
refs_da_url() {
  { printf '%s' "$1" | grep -oE 'postgres\.[a-z0-9]{20}' | sed 's/^postgres\.//'
    printf '%s' "$1" | grep -oE '[a-z0-9]{20}\.(pooler\.)?supabase\.(co|com)' | cut -c1-20
  } || true
}
# `codigo` só fala HTTPS com o Auth (Admin API): não usa psql, nem a porta do banco, nem o contêiner local.
usa_banco() { [ "$COMANDO" != codigo ]; }

# Senha fora da linha de comando (B-027.j). O psql do dev nunca recebe a URL: a senha vai num arquivo de senhas
# do libpq (PGPASSFILE) temporário, 600, numa pasta 700 fora do repositório, criado com umask 077 e apagado na
# saída (também no erro e no Ctrl-C); host, porta, usuário e banco vão em variáveis PG* só no ambiente do psql.
# Assim nada da conexão aparece no `ps`. O arquivo só nasce DEPOIS da trava do ref.
CONEXAO_DIR=""; CON_HOST=""; CON_PORT=""; CON_USER=""; CON_DB=""; CON_SSLMODE=""; CON_TIMEOUT=""; CON_APPNAME=""
limpar_conexao() { if [ -n "$CONEXAO_DIR" ]; then rm -rf "$CONEXAO_DIR"; CONEXAO_DIR=""; fi; }
trap limpar_conexao EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

# Lê a URL pela entrada (nunca por argumento), como o libpq a lê: o usuário e a senha vão até a primeira @ antes
# da primeira /, o %XX é decodificado e ssl=true vale sslmode=require. É mais estrito que o libpq: um host só,
# usuário e host sem %, e só os parâmetros sslmode, connect_timeout e application_name (hostaddr, host, service,
# passfile e qualquer outro saem com erro, para nada desviar a conexão que a trava conferiu). Grava a senha no
# arquivo do argumento 1 e devolve o resto (sem a senha), um campo por linha. Erro: só o motivo, nunca a URL.
LER_URL_PY='import os, re, sys
def sair(motivo):
    sys.stderr.write("  ✗ conexão do dev: " + motivo + "\n")
    sys.exit(2)
def dec(s, campo):
    b = s.encode("utf-8"); out = bytearray(); i = 0
    while i < len(b):
        if b[i] == 37:
            h = b[i + 1:i + 3]
            if len(h) != 2 or not all(c in b"0123456789abcdefABCDEF" for c in h):
                sair("% sem dois dígitos hexadecimais em " + campo)
            if int(h, 16) == 0:
                sair("%00 em " + campo)
            out.append(int(h, 16)); i += 3
        else:
            out.append(b[i]); i += 1
    try:
        t = out.decode("utf-8")
    except UnicodeDecodeError:
        sair(campo + " não é UTF-8")
    if "\n" in t or "\r" in t:
        sair("quebra de linha em " + campo)
    return t
u = sys.stdin.read()
r = None
for prefixo in ("postgresql://", "postgres://"):
    if u.startswith(prefixo):
        r = u[len(prefixo):]
        break
if r is None:
    sair("não começa com postgresql://")
i = 0
while i < len(r) and r[i] not in "@/":
    i += 1
if i == len(r) or r[i] != "@":
    sair("sem usuário e senha antes do host")
user, tem_senha, senha = r[:i].partition(":")
if not tem_senha or not senha:
    sair("sem senha")
r = r[i + 1:]
j = 0
while j < len(r) and r[j] not in ":/?,":
    j += 1
host, sep, r = r[:j], r[j:j + 1], r[j + 1:]
porta = ""
if sep == ":":
    j = 0
    while j < len(r) and r[j] not in "/?,":
        j += 1
    porta, sep, r = r[:j], r[j:j + 1], r[j + 1:]
if sep == ",":
    sair("mais de um host")
banco, query = "", ""
if sep == "/":
    banco, _, query = r.partition("?")
elif sep == "?":
    query = r
if not re.fullmatch(r"[A-Za-z0-9._-]+", user):
    sair("usuário fora do formato (só letras, dígitos, ponto, hífen e sublinhado)")
if not re.fullmatch(r"[A-Za-z0-9.-]+", host):
    sair("host fora do formato (um nome ou IPv4, sem %)")
if not re.fullmatch(r"[0-9]{0,5}", porta):
    sair("porta não numérica")
banco = dec(banco, "banco")
if banco and not re.fullmatch(r"[A-Za-z0-9._-]+", banco):
    sair("nome do banco fora do formato")
senha = dec(senha, "senha")
campos = [("host", host), ("port", porta), ("user", user), ("dbname", banco)]
partes = query.split("&") if query else []
if partes and partes[-1] == "":
    partes.pop()
for par in partes:
    if par.count("=") != 1:
        sair("parâmetro sem um = só")
    k, v = par.split("=")
    k, v = dec(k, "nome de parâmetro"), dec(v, "valor de parâmetro")
    if k == "ssl" and v == "true":
        k, v = "sslmode", "require"
    if k == "sslmode" and v in ("disable", "allow", "prefer", "require", "verify-ca", "verify-full"):
        campos.append((k, v))
    elif k == "connect_timeout" and re.fullmatch(r"[0-9]{1,4}", v):
        campos.append((k, v))
    elif k == "application_name" and re.fullmatch(r"[A-Za-z0-9 ._-]{0,63}", v):
        campos.append((k, v))
    else:
        sair("parâmetro não aceito aqui: " + re.sub(r"[^A-Za-z0-9_]", "?", k)[:40])
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("*:*:*:*:" + senha.replace("\\", "\\\\").replace(":", "\\:") + "\n")
for k, v in campos:
    if v:
        print(k + "=" + v)'

preparar_conexao_dev() {
  local campos linha valor
  CONEXAO_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/frila-dev-busca.XXXXXX") \
    || falhou "não consegui criar a pasta temporária da conexão"
  campos=$(umask 077; printf '%s' "$PGURL" | python3 -I -c "$LER_URL_PY" "$CONEXAO_DIR/pgpass") \
    || falhou "a conexão do dev (.config/frila/dev-db-url) não está no formato esperado. Nada foi conectado."
  while IFS= read -r linha; do
    valor=${linha#*=}
    case "$linha" in
      host=*)             CON_HOST=$valor ;;
      port=*)             CON_PORT=$valor ;;
      user=*)             CON_USER=$valor ;;
      dbname=*)           CON_DB=$valor ;;
      sslmode=*)          CON_SSLMODE=$valor ;;
      connect_timeout=*)  CON_TIMEOUT=$valor ;;
      application_name=*) CON_APPNAME=$valor ;;
    esac
  done <<< "$campos"
  [ -n "$CON_HOST" ] && [ -n "$CON_USER" ] && [ -s "$CONEXAO_DIR/pgpass" ] \
    || falhou "a conexão do dev ficou incompleta (host, usuário ou senha). Nada foi conectado."
}

if [ "$ALVO" = dev ]; then
  ARQUIVO_URL="${FRILA_DEV_DB_URL_ARQUIVO:-$HOME/.config/frila/dev-db-url}"
  [ -f "$ARQUIVO_URL" ] || falhou "não achei o arquivo da conexão do dev (.config/frila/dev-db-url)"
  PGURL="$(tr -d '\n' < "$ARQUIVO_URL" | sed 's/^[A-Za-z_]*=//')"
  [ -n "$PGURL" ] || falhou "o arquivo da conexão do dev está vazio"
  # Todos os refs achados têm de ser o do dev (uma URL com um ref do dev e outro de outro projeto também sai).
  REF=""; ref=""
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    [ "$(printf '%s' "$ref" | shasum -a 256 | cut -d' ' -f1)" = "$REF_DEV_SHA256" ] \
      || falhou "a conexão lida NÃO é a do frila-dev (um ref da URL tem sha256 diferente). Nada foi conectado."
    REF="$ref"
  done <<< "$(refs_da_url "$PGURL")"
  [ -n "$REF" ] || falhou "a conexão lida NÃO é a do frila-dev (nenhum ref reconhecível na URL). Nada foi conectado."
  if usa_banco && [ "$VIA" = psql ]; then
    [ -x "$PSQL" ] || falhou "não achei o psql em $PSQL (defina PSQL)"
    preparar_conexao_dev
  elif usa_banco; then
    [ -f "$HOME/.config/frila/supabase-token" ] || falhou "não achei ~/.config/frila/supabase-token (o SQL por HTTPS usa o token de conta)"
  fi
  PGURL=""   # daqui em diante a URL (com a senha) não é usada: o psql lê o arquivo de senhas; o https, o token
elif usa_banco; then
  docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER" \
    || falhou "o contêiner $DB_CONTAINER não está de pé (supabase start; ou defina DB_CONTAINER)"
fi

# SQL pela Management API (--via https, o padrão no dev). Aceita as mesmas opções que o psql_ recebe (-v nome=valor
# e -c "sql"; sem -c, o SQL vem pela entrada), troca cada :'nome' pelo valor como literal SQL (aspas dobradas) e
# imprime como o `psql -t -A`: uma linha por linha, colunas separadas por |, booleano t/f, nulo vazio. O endpoint
# devolve só o resultado da ÚLTIMA instrução que tem linhas (medido em 16/11/2026), então cada SQL daqui tem no
# máximo uma consulta que devolve linhas; begin/set/DO/commit em volta não atrapalham. E cada coluna precisa de nome
# único: a resposta é JSON, e duas colunas `to_char` virariam uma só. O token é lido do arquivo pelo
# python e o ref vai pelo ambiente: nenhum dos dois na linha de comando nem na saída. Erro do banco sai com o código
# e a mensagem do Postgres, e o script para (como o ON_ERROR_STOP do psql).
SQL_HTTPS_PY='import json, os, re, sys, urllib.error, urllib.request
args, valores, sql = sys.argv[1:], {}, None
i = 0
while i < len(args):
    if args[i] == "-v" and i + 1 < len(args):
        k, _, v = args[i + 1].partition("=")
        valores[k] = v
        i += 2
    elif args[i] == "-c" and i + 1 < len(args):
        sql = args[i + 1]
        i += 2
    else:
        i += 1
if sql is None:
    sql = sys.stdin.read()
def literal(m):
    if m.group(1) not in valores:
        sys.exit("  ✗ SQL por HTTPS: a variável :" + chr(39) + m.group(1) + chr(39) + " não recebeu valor")
    return chr(39) + valores[m.group(1)].replace(chr(39), chr(39) * 2) + chr(39)
sql = re.sub(r":" + chr(39) + r"([A-Za-z_][A-Za-z0-9_]*)" + chr(39), literal, sql)
token = re.sub(r"^[A-Za-z_]*=", "", open(os.environ["FRILA_TOKEN_ARQUIVO"], encoding="utf-8").read().strip())
pedido = urllib.request.Request("https://api.supabase.com/v1/projects/" + os.environ["FRILA_REF_DEV"] + "/database/query",
    data=json.dumps({"query": sql}).encode(), method="POST",
    headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(pedido, timeout=120) as r:
        linhas = json.load(r)
except urllib.error.HTTPError as e:
    try:
        msg = json.loads(e.read()).get("message", "")
    except Exception:
        msg = ""
    sys.exit("  ✗ SQL por HTTPS (%d): %s" % (e.code, msg[:600]))
except (urllib.error.URLError, OSError) as e:
    sys.exit("  ✗ a Management API não respondeu: " + str(getattr(e, "reason", e))[:200])
def texto(v):
    if v is None:
        return ""
    if v is True or v is False:
        return "t" if v else "f"
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False)
    return str(v)
for linha in linhas if isinstance(linhas, list) else []:
    print("|".join(texto(v) for v in linha.values()))'

sql_https() {
  FRILA_REF_DEV="$REF" FRILA_TOKEN_ARQUIVO="$HOME/.config/frila/supabase-token" python3 -I -c "$SQL_HTTPS_PY" "$@" 2> >(redigir >&2)
}

psql_() {
  if [ "$ALVO" = dev ] && [ "$VIA" = https ]; then
    sql_https "$@"
  elif [ "$ALVO" = dev ]; then
    # Num subshell, para as PG* valerem só neste psql. Antes, sai toda PG* herdada do terminal (PGHOSTADDR,
    # PGSERVICE, PGPASSWORD, PGOPTIONS...): nenhuma desvia a conexão nem põe outra senha. O connect_timeout
    # padrão (15 s) faz a rede que barra a porta falhar logo, em vez de esperar o TCP desistir.
    ( for v in $(compgen -e); do case "$v" in PG*) unset "$v" ;; esac; done
      export PGPASSFILE="$CONEXAO_DIR/pgpass" PGHOST="$CON_HOST" PGUSER="$CON_USER" PGCONNECT_TIMEOUT="${CON_TIMEOUT:-15}"
      [ -z "$CON_PORT" ] || export PGPORT="$CON_PORT"
      [ -z "$CON_DB" ] || export PGDATABASE="$CON_DB"
      [ -z "$CON_SSLMODE" ] || export PGSSLMODE="$CON_SSLMODE"
      [ -z "$CON_APPNAME" ] || export PGAPPNAME="$CON_APPNAME"
      "$PSQL" -X -q -t -A -v ON_ERROR_STOP=1 "$@" 2> >(redigir >&2)
    )
  else
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 "$@"
  fi
}

# A busca precisa existir neste banco (a migração 20261116210000). A de chamar (20261116220000) é só informada.
checar_migracoes() {
  local presentes
  presentes=$(psql_ -c "select coalesce(string_agg(version, ' ' order by version), '') from supabase_migrations.schema_migrations
                         where version in ('20261116210000', '20261116220000', '20261116230000');")
  case " $presentes " in
    *" 20261116210000 "*) ok "migração da busca (20261116210000) está neste banco" ;;
    *) falhou "a migração 20261116210000 NÃO está neste banco ($ALVO). Espere a Entrega aplicar depois da mescla do #517" ;;
  esac
  case " $presentes " in
    *" 20261116220000 "*) ok "migração de chamar e perfil (20261116220000) também está" ;;
    *) aviso "a migração 20261116220000 (chamar_profissional pela busca, perfil) ainda NÃO está: a busca roda, o chamar a partir dela não" ;;
  esac
  case " $presentes " in
    *" 20261116230000 "*) ok "migração dos Termos 1.1 (20261116230000) também está: a casa de teste precisa ter aceito a 1.1 (o montar grava)" ;;
    *) aviso "a migração 20261116230000 (busca só com os Termos 1.1) ainda NÃO está: a busca vale para qualquer casa até ela entrar" ;;
  esac
}

# ── Resumo (chaves, versões mínimas, ids e o que cada um tem) ──────────────
recursos() {
  echo "▸ Chaves e versões mínimas ($ALVO)"
  # Uma consulta só (o SQL por HTTPS devolve só a última que tem linhas).
  psql_ <<'SQL' | sed 's/^/    /'
select linha from (
  select 1 as ordem, r.chave::text as k1, ''::text as k2, 'chave   ' || r.chave || ' = ' || r.ligado as linha
    from privado.recurso r where r.chave in ('busca_profissionais', 'chamada_direta', 'perfil_rico')
  union all
  select 2, m.recurso::text, m.plataforma::text, 'mínimo  ' || m.recurso || ' / ' || m.plataforma || ' >= ' || m.versao_minima
    from privado.recurso_versao_minima m where m.recurso in ('busca_profissionais', 'chamada_direta', 'perfil_rico')
  union all
  select 3, x.recurso, '', 'SEM mínimo para ' || x.recurso || ' no iOS: o app NÃO verá o recurso (configuracao_do_app dá false sem a linha)'
    from (values ('busca_profissionais'), ('chamada_direta')) x(recurso)
   where not exists (select 1 from privado.recurso_versao_minima m where m.recurso = x.recurso and m.plataforma = 'ios')
  union all
  select 4, x.recurso, '', 'SEM mínimo para ' || x.recurso || ' no Android: o app NÃO verá o recurso'
    from (values ('busca_profissionais'), ('chamada_direta')) x(recurso)
   where not exists (select 1 from privado.recurso_versao_minima m where m.recurso = x.recurso and m.plataforma = 'android')
) t order by ordem, k1, k2;
SQL
}

resumo() {
  echo "▸ Quem existe ($ALVO)"
  # Uma consulta só (o SQL por HTTPS devolve só a última que tem linhas): a casa primeiro, depois as profissionais.
  psql_ <<'SQL' | sed 's/^/    /'
select linha from (
select 0 as ordem, ''::text as email, 'casa   usuario_id=' || u.id || '  estabelecimento_id=' || e.id || '  ' || u.email || '  (' || e.nome || ', ' || e.regiao_administrativa || ')'
       || E'\n         termos aceitos: ' || u.termos_versao || ' (a busca exige 2026-11-13 ou mais nova)' as linha
  from public.usuario u
  join public.membro_estabelecimento m on m.usuario_id = u.id
  join public.estabelecimento e on e.id = m.estabelecimento_id
 where u.id = 'b027f000-0000-4000-8000-000000000001'
union all
select 1, u.email::text, 'prof   usuario_id=' || u.id || '  profissional_id=' || p.id || '  ' || u.email
       || E'\n         nome curto: ' || privado.nome_curto(u.nome)
       || ' · faixa: ' || case when extensions.ST_DWithin(p.ponto_base, e.ponto, 5000) then 'até 5 km'
                               when extensions.ST_DWithin(p.ponto_base, e.ponto, 15000) then '5 a 15 km' else 'mais de 15 km' end
       || ' (' || round((extensions.ST_Distance(p.ponto_base, e.ponto) / 1000)::numeric, 1) || ' km)'
       || E'\n         serviços: ' || coalesce((select string_agg(f.nome || ' [' || s.unidade || coalesce(' ' || s.valor_centavos, '') || ']', ', ' order by f.nome)
                                                  from public.profissional_servico s join public.funcao f on f.id = s.funcao_id
                                                 where s.profissional_id = p.id), '-')
       || E'\n         regiões: ' || case when p.atende_todo_df then 'todo o DF'
                                          else coalesce((select string_agg(r.nome, ' + ' order by r.id)
                                                           from public.profissional_regiao pr join public.regiao_administrativa r on r.id = pr.regiao_id
                                                          where pr.profissional_id = p.id), '-') end
       || E'\n         grade: ' || coalesce((select string_agg(d.dia_semana || ' ' || to_char(d.hora_inicio, 'HH24:MI') || '-' || to_char(d.hora_fim, 'HH24:MI'),
                                                                 ', ' order by d.dia_semana, d.hora_inicio)
                                                from public.disponibilidade d where d.profissional_id = p.id), '-') || '  (0 = domingo)'
       || E'\n         chamadas: ' || coalesce((select pc.aceita_chamadas::text from public.profissional_preferencia_chamada pc where pc.profissional_id = p.id), 'sem linha')
       || ' · pendências p/ busca: ' || privado.pendencias_para_busca(p.id)::text
       || ' · aparelho: ' || coalesce((select string_agg(d.plataforma || ' ' || d.versao_app, ', ') from public.dispositivo d where d.usuario_id = u.id), 'NENHUM')
       || E'\n         foto de perfil: ' || coalesce((select m.estado from privado.midia m where m.dono_usuario_id = u.id and m.tipo = 'foto_perfil'
                                                     order by (m.estado = 'aprovada') desc, m.atualizado_em desc limit 1), 'nenhuma') as linha
  from public.usuario u
  join public.profissional p on p.usuario_id = u.id
  cross join public.estabelecimento e
 where e.id = 'b027f000-0000-4000-8000-0000000000c1'
   and u.id in ('b027f000-0000-4000-8000-000000000011', 'b027f000-0000-4000-8000-000000000012', 'b027f000-0000-4000-8000-000000000013')
) t order by ordem, email;
SQL
}

# ── montar ─────────────────────────────────────────────────────────────────
montar() {
  echo "▸ montar ($ALVO)"
  checar_migracoes
  recursos
  # Uma transação só: ou fica tudo, ou não fica nada.
  psql_ -v "minimo_busca=$MINIMO_BUSCA" <<'SQL' >/dev/null
begin;
set local statement_timeout = '60s';
set local lock_timeout = '5s';

-- 0. O que precisa existir neste banco.
do $$
begin
  if to_regprocedure('public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int)') is null then
    raise exception 'buscar_profissionais não existe neste banco: a migração 20261116210000 não foi aplicada';
  end if;
  if (select count(*) from public.funcao where nome in ('garçom', 'faxina residencial', 'cozinheiro de festa') and ativo) <> 3 then
    raise exception 'faltam funções do catálogo (garçom, faxina residencial, cozinheiro de festa)';
  end if;
  if (select count(*) from public.regiao_administrativa where id in (1, 3, 10) and ativo) <> 3 then
    raise exception 'faltam regiões do catálogo (1 Plano Piloto, 3 Taguatinga, 10 Guará)';
  end if;
  if not exists (select 1 from privado.recurso_versao_minima where recurso = 'chamada_direta' and plataforma = 'ios') then
    raise exception 'chamada_direta não tem versão mínima no iOS: sem ela nenhum aparelho de teste passa na busca (decisão do O2/Forja)';
  end if;
end $$;

-- 1. As chaves, só neste banco. A versão mínima da busca só entra com --minimo-busca.
update privado.recurso set ligado = true where chave in ('busca_profissionais', 'chamada_direta');
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
select 'busca_profissionais', 'ios', :'minimo_busca' where nullif(:'minimo_busca', '') is not null
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima, atualizado_em = privado.agora();
-- Sem --minimo-busca e sem linha da busca: a mesma mínima da chamada_direta (decisão da Forja, 16/11/2026, para o
-- Prisma testar com o build atual). Quem já tem linha não é tocado.
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
select 'busca_profissionais', 'ios', m.versao_minima
  from privado.recurso_versao_minima m
 where m.recurso = 'chamada_direta' and m.plataforma = 'ios'
on conflict (recurso, plataforma) do nothing;
-- Android (B-027.g): o app Android do time também testa a busca e a chamada no dev. Mínimo 1.0.0 nas duas chaves;
-- linha que já existe (o dev já a tem, gravada à mão) não é tocada, então rodar de novo não muda nada.
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
values ('busca_profissionais', 'android', '1.0.0'), ('chamada_direta', 'android', '1.0.0')
on conflict (recurso, plataforma) do nothing;

-- 2. As contas. O Auth precisa da linha em auth.users (e em auth.identities) para o código de e-mail entrar;
--    public.usuario não tem chave para auth.users, então as duas são criadas aqui.
create temp table _contas on commit drop as
select * from (values
  ('b027f000-0000-4000-8000-000000000001'::uuid, 'contratante'::public.perfil_conta, 'Carla Casa Teste',         'busca-casa@frila.test',   '+5561990000001'),
  ('b027f000-0000-4000-8000-000000000011'::uuid, 'profissional'::public.perfil_conta, 'Ana Faxineira Teste',     'busca-prof-1@frila.test', '+5561990000011'),
  ('b027f000-0000-4000-8000-000000000012'::uuid, 'profissional'::public.perfil_conta, 'Bruno Garçom Teste',      'busca-prof-2@frila.test', '+5561990000012'),
  ('b027f000-0000-4000-8000-000000000013'::uuid, 'profissional'::public.perfil_conta, 'Clara Cozinheira Teste',  'busca-prof-3@frila.test', '+5561990000013')
) v(id, perfil, nome, email, telefone);

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, is_sso_user, is_anonymous,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000', c.id, 'authenticated', 'authenticated', c.email, now(),
       '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(), false, false, '', '', '', ''
  from _contas c
 where not exists (select 1 from auth.users x where x.id = c.id);

insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select c.id::text, c.id,
       jsonb_build_object('sub', c.id::text, 'email', c.email, 'email_verified', true, 'phone_verified', false),
       'email', now(), now(), now()
  from _contas c
 where not exists (select 1 from auth.identities i where i.user_id = c.id and i.provider = 'email');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select c.id, c.perfil, c.nome, c.telefone, c.email, date '1990-01-01', '2026-11-13', now() from _contas c
on conflict (id) do update set nome = excluded.nome, estado = 'ativa', anonimizado_em = null,
  -- I6 (16/11/2026): a busca só vale para quem aceitou os Termos 1.1 (termos_versao >= 2026-11-13, a data da
  -- publicação). A casa de teste aceita; quem já tem a 1.1 ou mais nova não muda, e o instante só anda quando a versão anda.
  termos_versao = case when public.usuario.termos_versao ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                        and public.usuario.termos_versao collate "C" >= excluded.termos_versao collate "C"
                       then public.usuario.termos_versao else excluded.termos_versao end,
  termos_aceite_em = case when public.usuario.termos_versao ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                           and public.usuario.termos_versao collate "C" >= excluded.termos_versao collate "C"
                          then public.usuario.termos_aceite_em else excluded.termos_aceite_em end;

-- 3. A casa: Plano Piloto, perto do ponto base do prof 1. CNPJ sintético (14 dígitos, sem dígito verificador).
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('b027f000-0000-4000-8000-0000000000c1', 'Casa Teste Busca', '99027000000100', 'outro',
        'CLN 201 Bloco A, Asa Norte (endereço de teste)', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto')
on conflict (id) do update set nome = excluded.nome, ponto = excluded.ponto, regiao_administrativa = excluded.regiao_administrativa;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('b027f000-0000-4000-8000-000000000001', 'b027f000-0000-4000-8000-0000000000c1', 'administrador')
on conflict (usuario_id, estabelecimento_id) do update set papel = 'administrador';

-- 4. Os três profissionais. Ponto base em faixas diferentes da casa (medidas no `estado`):
--    prof 1 a ~1,6 km (até 5 km) · prof 2 a ~10 km (5 a 15 km) · prof 3 a ~23 km (mais de 15 km).
insert into public.profissional (id, usuario_id, ponto_base, atende_todo_df) values
  ('b027f000-0000-4000-8000-000000000021', 'b027f000-0000-4000-8000-000000000011', 'POINT(-47.8822 -15.7800)'::extensions.geography, true),
  ('b027f000-0000-4000-8000-000000000022', 'b027f000-0000-4000-8000-000000000012', 'POINT(-47.9400 -15.8700)'::extensions.geography, false),
  ('b027f000-0000-4000-8000-000000000023', 'b027f000-0000-4000-8000-000000000013', 'POINT(-48.0800 -15.8700)'::extensions.geography, false)
on conflict (id) do update set ponto_base = excluded.ponto_base, atende_todo_df = excluded.atende_todo_df;

create temp table _servicos on commit drop as
select * from (values
  ('b027f000-0000-4000-8000-000000000021'::uuid, 'faxina residencial',  'diaria',     15000, 8,    null::int, null::int, null::int, null::int),
  ('b027f000-0000-4000-8000-000000000022'::uuid, 'garçom',              'hora',        4000, null, 4,         null,      null,      null),
  ('b027f000-0000-4000-8000-000000000022'::uuid, 'cozinheiro de festa', 'evento',     60000, null, null,      5,         50,        null),
  ('b027f000-0000-4000-8000-000000000023'::uuid, 'cozinheiro de festa', 'por_pessoa',  3500, null, null,      null,      null,      20),
  ('b027f000-0000-4000-8000-000000000023'::uuid, 'garçom',              'a_combinar', null,  null, null,      null,      null,      null)
) v(prof, funcao, unidade, valor, horas_incl, min_horas, duracao_h, ate_pessoas, min_pessoas);

insert into public.profissional_funcao (profissional_id, funcao_id)
select s.prof, f.id from _servicos s join public.funcao f on f.nome = s.funcao and f.ativo
on conflict do nothing;

delete from public.profissional_servico
 where profissional_id in ('b027f000-0000-4000-8000-000000000021', 'b027f000-0000-4000-8000-000000000022', 'b027f000-0000-4000-8000-000000000023');
insert into public.profissional_servico (profissional_id, funcao_id, unidade, valor_centavos, horas_incluidas, minimo_horas,
                                         duracao_tipica_h, ate_pessoas, minimo_pessoas, leva_material)
select s.prof, f.id, s.unidade, s.valor, s.horas_incl, s.min_horas, s.duracao_h, s.ate_pessoas, s.min_pessoas,
       case when s.unidade = 'diaria' then 'depende' end
  from _servicos s join public.funcao f on f.nome = s.funcao and f.ativo;

-- Regiões: prof 1 atende todo o DF (sem linha em profissional_regiao); prof 2 duas RAs; prof 3 uma só.
delete from public.profissional_regiao
 where profissional_id in ('b027f000-0000-4000-8000-000000000021', 'b027f000-0000-4000-8000-000000000022', 'b027f000-0000-4000-8000-000000000023');
insert into public.profissional_regiao (profissional_id, regiao_id) values
  ('b027f000-0000-4000-8000-000000000022', 1), ('b027f000-0000-4000-8000-000000000022', 10),
  ('b027f000-0000-4000-8000-000000000023', 1);

-- Grade semanal (0 = domingo). Prof 2 vira a noite (18h às 02h): é a janela mais comum do setor.
delete from public.disponibilidade
 where profissional_id in ('b027f000-0000-4000-8000-000000000021', 'b027f000-0000-4000-8000-000000000022', 'b027f000-0000-4000-8000-000000000023');
insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
select 'b027f000-0000-4000-8000-000000000021'::uuid, d, time '08:00', time '18:00' from generate_series(1, 5) d
union all
select 'b027f000-0000-4000-8000-000000000022'::uuid, d, time '18:00', time '02:00' from unnest(array[4, 5, 6, 0]) d
union all
select 'b027f000-0000-4000-8000-000000000023'::uuid, d, time '10:00', time '22:00' from unnest(array[6, 0]) d;

-- 5. O aparelho iOS na versão mínima da chamada_direta. Token falso de propósito (ver o cabeçalho do script).
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select v.usuario, 'tok-busca-teste-b027-' || v.n || '-0000000000', 'ios',
       (select m.versao_minima from privado.recurso_versao_minima m where m.recurso = 'chamada_direta' and m.plataforma = 'ios')
  from (values ('b027f000-0000-4000-8000-000000000011'::uuid, 'p1'),
               ('b027f000-0000-4000-8000-000000000012'::uuid, 'p2'),
               ('b027f000-0000-4000-8000-000000000013'::uuid, 'p3')) v(usuario, n)
on conflict (token_fcm) do update set usuario_id = excluded.usuario_id, versao_app = excluded.versao_app, atualizado_em = now();

-- 6. "Aceito chamadas diretas", pela RPC, como o próprio profissional (grava também o registro do pedido do
--    titular). Só para quem ainda não ligou, para rodar de novo não empilhar registro.
do $$
declare r record;
begin
  for r in select p.usuario_id from public.profissional p
            where p.id in ('b027f000-0000-4000-8000-000000000021', 'b027f000-0000-4000-8000-000000000022', 'b027f000-0000-4000-8000-000000000023')
              and not coalesce((select pc.aceita_chamadas from public.profissional_preferencia_chamada pc where pc.profissional_id = p.id), false)
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.usuario_id, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.definir_preferencia_chamadas(aceita_chamadas => true, versao_texto_busca => 'teste-b027');
    execute 'reset role';
  end loop;
end $$;

-- 7. As chamadas de teste não escondem ninguém da busca da casa de teste (B-027.k; ver o cabeçalho). Só entre a casa
--    de teste e as 3 profissionais de teste. A ABERTA a casa cancela pelo caminho do produto (cancelar_chamada, como
--    a casa): cancelada não conta na busca. As RECUSADAS e EXPIRADAS desse par saem: nenhum caminho do produto desfaz
--    uma recusa, e nada depende da linha da chamada. Aceitas (com vaga e turno) ficam.
do $$
declare r record;
begin
  for r in select ch.id from public.chamada ch
            where ch.estabelecimento_id = 'b027f000-0000-4000-8000-0000000000c1' and ch.estado = 'aberta'
              and ch.profissional_id in ('b027f000-0000-4000-8000-000000000021', 'b027f000-0000-4000-8000-000000000022', 'b027f000-0000-4000-8000-000000000023')
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', 'b027f000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.cancelar_chamada(chamada_id => r.id);
    execute 'reset role';
  end loop;
end $$;
delete from public.chamada ch
 where ch.estabelecimento_id = 'b027f000-0000-4000-8000-0000000000c1' and ch.estado in ('recusada', 'expirada')
   and ch.profissional_id in ('b027f000-0000-4000-8000-000000000021', 'b027f000-0000-4000-8000-000000000022', 'b027f000-0000-4000-8000-000000000023');

commit;
SQL
  ok "contas, casa, profissionais, grade, aparelhos e preferência gravados; chamadas de teste que escondiam alguém da busca limpas"
  recursos
  resumo
}

# ── conferir: a busca como a casa, numa transação desfeita ─────────────────
conferir() {
  echo "▸ conferir ($ALVO): 4 buscas como a casa de teste (transação desfeita; o contador do limite não fica)"
  local linha sab_ini sab_fim seg_ini seg_fim f_garcom f_faxina
  # Horários futuros em America/Sao_Paulo, com folga de 2 dias (a antecedência padrão é 6 h): o próximo sábado
  # 11h-15h (a grade do prof 3 cobre, a do prof 2 não) e a próxima segunda 09h-13h (a grade do prof 1 cobre).
  linha=$(psql_ <<'SQL'
with sp as (select (privado.agora() at time zone 'America/Sao_Paulo')::date + 2 as d),
     dias as (select d + ((6 - extract(dow from d)::int + 7) % 7) as sab, d + ((1 - extract(dow from d)::int + 7) % 7) as seg from sp)
select to_char(((sab + time '11:00') at time zone 'America/Sao_Paulo') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as sab_ini,
       to_char(((sab + time '15:00') at time zone 'America/Sao_Paulo') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as sab_fim,
       to_char(((seg + time '09:00') at time zone 'America/Sao_Paulo') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as seg_ini,
       to_char(((seg + time '13:00') at time zone 'America/Sao_Paulo') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as seg_fim,
       (select id from public.funcao where nome = 'garçom' and ativo) as f_garcom,
       (select id from public.funcao where nome = 'faxina residencial' and ativo) as f_faxina
  from dias;
SQL
  )
  IFS='|' read -r sab_ini sab_fim seg_ini seg_fim f_garcom f_faxina <<< "$linha"
  [ -n "$f_faxina" ] || falhou "não consegui montar os horários e as funções da conferência"
  echo "    sábado $sab_ini a $sab_fim · segunda $seg_ini a $seg_fim (UTC)"

  local saida
  # As claims da casa vão por `set local` (e não por set_config + \gset, comando do psql que o SQL por HTTPS não tem).
  saida=$(psql_ -v "claims={\"sub\":\"$CASA_USUARIO\",\"role\":\"authenticated\"}" -v "estab=$CASA_ESTAB" -v "sab_ini=$sab_ini" \
                -v "sab_fim=$sab_fim" -v "seg_ini=$seg_ini" -v "seg_fim=$seg_fim" -v "f_garcom=$f_garcom" -v "f_faxina=$f_faxina" <<'SQL'
begin;
set local request.jwt.claims = :'claims';
set local role authenticated;
with b(k, r) as (values
  ('B1', public.buscar_profissionais(estabelecimento_id => :'estab'::uuid, funcao_id => :'f_garcom'::uuid)),
  ('B2', public.buscar_profissionais(estabelecimento_id => :'estab'::uuid, funcao_id => :'f_garcom'::uuid,
                                     inicio_em => :'sab_ini'::timestamptz, fim_em => :'sab_fim'::timestamptz)),
  ('B3', public.buscar_profissionais(estabelecimento_id => :'estab'::uuid, funcao_id => :'f_faxina'::uuid, regiao_id => 3,
                                     inicio_em => :'seg_ini'::timestamptz, fim_em => :'seg_fim'::timestamptz)),
  ('B4', public.buscar_profissionais(estabelecimento_id => :'estab'::uuid, funcao_id => :'f_garcom'::uuid, regiao_id => 10)))
select b.k || '|' || coalesce(string_agg(i.item->>'nome' || ' (' || (i.item->>'distancia_faixa')
         || coalesce(case i.item->>'disponivel_no_horario' when 'true' then ', na grade' when 'false' then ', fora da grade' end, '')
         || ')', ' > ' order by i.ord), '(ninguém)')
  from b left join lateral jsonb_array_elements(b.r->'itens') with ordinality i(item, ord) on true
 group by b.k order by b.k;
rollback;
SQL
  )
  local falhas=0 k obtido esperado desc
  while IFS='|' read -r k obtido; do
    case "$k" in
      B1) esperado="Bruno T. (de_5_a_15_km) > Clara T. (mais_de_15_km)";                                  desc="garçom, Plano Piloto, sem horário" ;;
      B2) esperado="Clara T. (mais_de_15_km, na grade) > Bruno T. (de_5_a_15_km, fora da grade)";       desc="garçom, Plano Piloto, sábado 11h-15h" ;;
      B3) esperado="Ana T. (ate_5_km, na grade)";                                                          desc="faxina residencial, Taguatinga, segunda 09h-13h" ;;
      B4) esperado="Bruno T. (de_5_a_15_km)";                                                              desc="garçom, Guará, sem horário" ;;
      *) continue ;;
    esac
    if [ "$obtido" = "$esperado" ]; then ok "$k  $desc → $obtido"
    else printf '  ✗ %s  %s\n      esperado: %s\n      obtido:   %s\n' "$k" "$desc" "$esperado" "$obtido" >&2; falhas=$((falhas + 1)); fi
  done <<< "$saida"
  [ "$(printf '%s\n' "$saida" | grep -c '^B[1-4]|')" = 4 ] || { aviso "a conferência não devolveu as 4 linhas (saída: $(printf '%s' "$saida" | head -c 300))"; falhas=$((falhas + 1)); }
  [ "$falhas" = 0 ] || falhou "a conferência divergiu em $falhas ponto(s). Se apareceu gente a mais, há conta de outra origem com 'aceita chamadas' ligado neste banco; se faltou gente, rode montar (o aparelho de teste pode ter sido apagado por um push)."
  ok "as 4 buscas deram o resultado esperado"
}

# ── Chaves do Auth (só para codigo e http; nunca impressas) ────────────────
API_URL=""; ANON_KEY=""; SR_KEY=""
carregar_chaves() {
  if [ "$ALVO" = local ]; then
    local env_
    env_=$(supabase status -o env ${SUPABASE_WORKDIR:+--workdir "$SUPABASE_WORKDIR"} 2>/dev/null) \
      || falhou "o supabase status não respondeu (stack parada? defina SUPABASE_WORKDIR para a pasta do stack)"
    API_URL=$(printf '%s\n' "$env_" | sed -nE 's/^API_URL="?([^"]*)"?$/\1/p' | head -1)
    ANON_KEY=$(printf '%s\n' "$env_" | sed -nE 's/^(ANON_KEY|PUBLISHABLE_KEY)="?([^"]*)"?$/\2/p' | head -1)
    SR_KEY=$(printf '%s\n' "$env_" | sed -nE 's/^(SERVICE_ROLE_KEY|SECRET_KEY)="?([^"]*)"?$/\2/p' | head -1)
  else
    # O projeto sai da própria conexão do dev (nunca de uma variável solta, para não apontar sem querer ao Prod);
    # as chaves, da Management API, com o token de conta do dev.
    local ref="$REF" token chaves
    [ -n "$ref" ] || falhou "projeto do dev não confirmado"
    [ -f "$HOME/.config/frila/supabase-token" ] || falhou "não achei ~/.config/frila/supabase-token"
    token="$(tr -d '\n' < "$HOME/.config/frila/supabase-token" | sed 's/^[A-Za-z_]*=//')"
    chaves=$(curl -sS -K - <<EOF
url = "https://api.supabase.com/v1/projects/$ref/api-keys"
header = "Authorization: Bearer $token"
EOF
    ) || falhou "a Management API não respondeu"
    API_URL="https://$ref.supabase.co"
    ANON_KEY=$(printf '%s' "$chaves" | python3 -I -c 'import json,sys
try: print(next((k["api_key"] for k in json.load(sys.stdin) if k.get("name") == "anon"), ""))
except Exception: print("")')
    SR_KEY=$(printf '%s' "$chaves" | python3 -I -c 'import json,sys
try: print(next((k["api_key"] for k in json.load(sys.stdin) if k.get("name") == "service_role"), ""))
except Exception: print("")')
  fi
  [ -n "$API_URL" ] && [ -n "$ANON_KEY" ] && [ -n "$SR_KEY" ] || falhou "não consegui as chaves do Auth de $ALVO (nenhuma é impressa)"
}

# api <método> <caminho> <apikey> <bearer> [corpo-json]  (a chave vai por stdin, não por argumento)
api() {
  curl -sS -X "$1" -K - ${5:+-d "$5"} <<EOF
url = "$API_URL$2"
header = "apikey: $3"
header = "Authorization: Bearer $4"
header = "Content-Type: application/json"
EOF
}

json_campo() { python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get(sys.argv[1]) or "")
except Exception: print("")' "$1"; }

so_email_de_teste() {
  local e achou=0
  for e in $EMAILS_DE_TESTE; do [ "$e" = "$1" ] && achou=1; done
  [ "$achou" = 1 ] || falhou "só gero código para os e-mails de teste: $EMAILS_DE_TESTE"
  [ "$(psql_ -c "select count(*) from auth.users u join public.usuario p on p.id = u.id where lower(u.email) = '$1' and not p.demonstracao;")" = 1 ] \
    || falhou "a conta $1 não existe neste banco: rode montar antes (o código nunca cria conta)"
}

# O código de uma vez só (a mesma chamada de e-mail+código do app). Sai em stdout, para quem o pediu.
# REGRA: `codigo` IMPRIME o código; agente NÃO o roda (só o Cauê ou o Prisma). O `http` não imprime.
gerar_codigo() {
  api POST /auth/v1/admin/generate_link "$SR_KEY" "$SR_KEY" "{\"type\":\"magiclink\",\"email\":\"$1\"}" | json_campo email_otp
}

# O id fixo de cada e-mail de teste (o do cabeçalho). Fora desta lista, nada.
id_da_conta_de_teste() {
  case "$1" in
    busca-casa@frila.test)   echo b027f000-0000-4000-8000-000000000001 ;;
    busca-prof-1@frila.test) echo b027f000-0000-4000-8000-000000000011 ;;
    busca-prof-2@frila.test) echo b027f000-0000-4000-8000-000000000012 ;;
    busca-prof-3@frila.test) echo b027f000-0000-4000-8000-000000000013 ;;
    *) return 1 ;;
  esac
}

# A conta de teste existe no Auth, com o id fixo E o mesmo e-mail? Pela Admin API, sem psql. Tem de vir antes do
# generate_link: o tipo magiclink CRIA a conta quando o e-mail não existe, e o `codigo` nunca cria conta.
conta_de_teste_no_auth() {
  local email="$1" id resp
  id=$(id_da_conta_de_teste "$email") || falhou "só gero código para os e-mails de teste: $EMAILS_DE_TESTE"
  resp=$(api GET "/auth/v1/admin/users/$id" "$SR_KEY" "$SR_KEY") || falhou "o Auth de $ALVO não respondeu"
  [ "$(printf '%s' "$resp" | json_campo id)" = "$id" ] && [ "$(printf '%s' "$resp" | json_campo email)" = "$email" ] \
    || falhou "a conta $email não existe no Auth de $ALVO com o id de teste: rode montar antes (o código nunca cria conta)"
}

# Só HTTPS: a lista fixa, a chave service_role pela Management API (carregar_chaves), a conta conferida pela
# Admin API e o código pelo generate_link. Nenhum psql: funciona com a 5432/6543 barradas.
codigo() {
  local email="${1:-}"
  [ -n "$email" ] || falhou "uso: codigo <e-mail de teste>"
  id_da_conta_de_teste "$email" >/dev/null || falhou "só gero código para os e-mails de teste: $EMAILS_DE_TESTE"
  carregar_chaves
  conta_de_teste_no_auth "$email"
  local otp
  otp=$(gerar_codigo "$email")
  [ -n "$otp" ] || falhou "o Auth não devolveu código para $email"
  echo "Código de entrada de $email ($ALVO): $otp"
  echo "Vale uma vez e por até 1 hora. Digite na tela agora; não guarde em arquivo. Se pedir código de novo no app, peça outro aqui."
}

# Entra pelo Auth como cada conta (verify, como o app) e busca pelo REST como a casa: o caminho do Prisma, sem tela.
# Cada login gasta um código novo (invalida o que o Prisma tiver pedido): rode antes de passar o código a ele.
http() {
  echo "▸ http ($ALVO): login pelo Auth das 4 contas e a busca pelo REST como a casa"
  carregar_chaves
  local e otp resp acesso quem tipo casa_token=""
  for e in $EMAILS_DE_TESTE; do
    so_email_de_teste "$e"
    otp=$(gerar_codigo "$e"); [ -n "$otp" ] || falhou "sem código para $e"
    acesso=""
    for tipo in email magiclink; do
      resp=$(api POST /auth/v1/verify "$ANON_KEY" "$ANON_KEY" "{\"type\":\"$tipo\",\"email\":\"$e\",\"token\":\"$otp\"}")
      acesso=$(printf '%s' "$resp" | json_campo access_token)
      [ -n "$acesso" ] && break
      otp=$(gerar_codigo "$e")
    done
    [ -n "$acesso" ] || falhou "o verify não entregou sessão para $e"
    quem=$(api GET /auth/v1/user "$ANON_KEY" "$acesso" | json_campo email)
    [ "$quem" = "$e" ] || falhou "a sessão de $e não é de $e"
    ok "$e entrou (verify type=$tipo) e /auth/v1/user confere"
    [ "$e" = busca-casa@frila.test ] && casa_token="$acesso"
  done
  local f_garcom resp_busca
  f_garcom=$(psql_ -c "select id from public.funcao where nome = 'garçom' and ativo;")
  resp_busca=$(api POST /rest/v1/rpc/buscar_profissionais "$ANON_KEY" "$casa_token" "{\"estabelecimento_id\":\"$CASA_ESTAB\",\"funcao_id\":\"$f_garcom\"}")
  printf '%s' "$resp_busca" | python3 -I -c 'import json,sys
d = json.load(sys.stdin)
if "itens" not in d: sys.exit("a busca pelo REST não devolveu itens: " + str(d.get("code") or d.get("message") or d)[:200])
print("    garçom no Plano Piloto pelo REST:", " > ".join(i["nome"] + " (" + i["distancia_faixa"] + ")" for i in d["itens"]) or "(ninguém)")' \
    || falhou "a busca pelo REST falhou"
  ok "casa entrou e buscou pelo REST"
}

# O arquivo de acesso do Prisma: e-mails de teste, ids, papéis, o comando do código e as buscas de exemplo.
# Fica FORA do repositório, com permissão 600. Não leva código nem segredo: o código sai de `codigo`, na hora.
acesso() {
  local saida="$SAIDA" raiz pasta
  if [ -z "$saida" ]; then
    [ "$ALVO" = dev ] || falhou "no local, passe --saida <arquivo> (fora do repositório): o arquivo padrão é só do dev"
    saida="$HOME/.config/frila/dev-teste-busca.md"
  fi
  raiz=$(pwd -P); pasta=$(cd "$(dirname "$saida")" 2>/dev/null && pwd -P) || falhou "a pasta de $saida não existe"
  case "$pasta/" in "$raiz"/*) falhou "a saída tem de ficar fora do repositório" ;; esac
  if [ -e "$saida" ] && ! head -1 "$saida" | grep -q 'gerado por dev-busca-teste.sh'; then
    falhou "$saida já existe e não é um arquivo gerado por este script: não sobrescrevo"
  fi
  echo "▸ acesso ($ALVO): gravando o arquivo de acesso (permissão 600)"
  checar_migracoes
  local corpo_estado
  corpo_estado=$(recursos; resumo)
  ( umask 077
    {
      echo '<!-- gerado por dev-busca-teste.sh (B-027.f). Dados sintéticos; sem código nem segredo. Pode ser regerado. -->'
      echo "# Teste de ponta a ponta da busca de profissionais ($ALVO)"
      echo
      echo "Gerado em $(date '+%Y-%m-%d %H:%M') pelo scripts/dev-busca-teste.sh (\`acesso\`; no dev, o SQL vai por HTTPS)."
      echo
      echo '## Contas (todas entram por e-mail + código; o e-mail @frila.test não recebe nada)'
      echo
      echo '- casa (contratante, administradora da "Casa Teste Busca", Plano Piloto): busca-casa@frila.test'
      echo '- profissional 1, Ana T., faxina residencial: busca-prof-1@frila.test'
      echo '- profissional 2, Bruno T., garçom e cozinheiro de festa: busca-prof-2@frila.test'
      echo '- profissional 3, Clara T., cozinheiro de festa e garçom: busca-prof-3@frila.test'
      echo
      echo '## Como pegar o código (o código NÃO fica neste arquivo)'
      echo
      echo 'Quem roda: só o Cauê ou o Prisma. O código sai só no terminal de quem rodou: não vai para arquivo, log nem mensagem.'
      echo
      echo '1. No app, digite o e-mail e toque em pedir código (pedir de novo invalida o código anterior).'
      echo '2. Na sequência, rode:'
      echo
      echo '```'
      echo "$CAMINHO_GROUND/scripts/dev-busca-teste.sh --alvo $ALVO codigo <e-mail>"
      echo '```'
      echo
      if [ "$raiz" != "$CAMINHO_GROUND" ]; then
        echo "Enquanto esta versão do script não estiver na develop, use a deste floor: $raiz/scripts/dev-busca-teste.sh"
        echo
      fi
      echo "O \`codigo\` só fala HTTPS com a Admin API do Auth (a chave service_role vem da Management API): não usa psql nem a porta do banco, então funciona mesmo com a 5432/6543 barradas pela rede."
      echo
      echo "3. Digite o código que sai no terminal. Vale uma vez e por até 1 hora. Só funciona para os 4 e-mails acima, e só para conta que o \`montar\` já criou (o \`codigo\` nunca cria conta)."
      echo
      echo '## O que cada conta tem (lido do banco agora)'
      echo
      echo '```'
      printf '%s\n' "$corpo_estado"
      echo '```'
      echo
      echo '## Três buscas de exemplo (como a casa; a RPC é buscar_profissionais)'
      echo
      echo '1. garçom, região da casa (Plano Piloto), sem horário → Bruno T. (5 a 15 km) e depois Clara T. (mais de 15 km).'
      echo '2. garçom, Plano Piloto, no próximo sábado das 11h às 15h → Clara T. (na grade) antes de Bruno T. (fora da grade): quem cobre o horário vem primeiro, mesmo mais longe.'
      echo '3. faxina residencial, região Taguatinga, na próxima segunda das 9h às 13h → só Ana T. (atende todo o DF; na grade).'
      echo
      echo 'Extra: garçom em Guará → só Bruno T. Os horários precisam estar a mais de 6 horas do momento da busca.'
      echo
      echo 'Foto: a linha "foto de perfil" acima diz o estado de cada uma. Com "aprovada", o perfil_publico e o cartão da busca trazem foto_url (link do ler-midia, temporário). As fotos de teste são imagens sintéticas (cor e forma, sem pessoa).'
      echo
      echo "Se Bruno ou Clara sumirem da busca depois de testar o chamar no app: a busca esconde quem já tem chamada aberta desta casa e quem recusou chamada dela há menos de 24 h. O \`montar\` limpa essas chamadas de teste (só entre a casa de teste e as 3 profissionais de teste)."
      echo
      echo '## Refazer ou consertar'
      echo
      echo "Rode \`$CAMINHO_GROUND/scripts/dev-busca-teste.sh --alvo $ALVO montar\` (idempotente) e \`conferir\` para provar as 4 buscas."
    } > "$saida"
  )
  chmod 600 "$saida"
  ok "gravado em $saida (modo $(stat -f '%Lp' "$saida"))"
}

case "$COMANDO" in
  montar)   montar ;;
  conferir) checar_migracoes; conferir ;;
  http)     checar_migracoes; http ;;
  codigo)   codigo "$ARG1" ;;
  estado)   checar_migracoes; recursos; resumo ;;
  acesso)   acesso ;;
esac
