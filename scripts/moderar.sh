#!/usr/bin/env bash
# Moderação de conteúdo denunciado — a porta da Equipe Frila para a diretriz 1.2.
#
#   ./scripts/moderar.sh pendentes [horas]
#   ./scripts/moderar.sh ocultar        <vaga> <operador> <motivo…>
#   ./scripts/moderar.sh reexibir       <vaga> <operador> <motivo…>
#   ./scripts/moderar.sh ocultar-texto  <vaga> <operador> <motivo…>
#   ./scripts/moderar.sh reexibir-texto <vaga> <operador> <motivo…>
#
# `ocultar` tira a vaga inteira da vitrine, do detalhe, da candidatura e do despacho, sem
# cancelá-la: quem já tem turno confirmado continua com ele. `ocultar-texto` deixa a vaga
# no ar e tira só o texto livre — que é o caso comum, porque uma linha ofensiva nas
# observações não é motivo para cancelar o turno de ninguém.
#
# As duas gravam `ocorrencia` de `suporte` assinada pelo **operador**, e não pelo alvo. As
# duas são reversíveis, e a reexibição devolve o texto inteiro.
#
# ── Por que um script, e não uma RPC ──────────────────────────────────────────
#
# Porque isto não é operação de app. As funções vivem em `privado`, fora do PostgREST, e
# só o `service_role` as executa: não há como um cliente autenticado ocultar a vaga de
# outra pessoa, nem por engano nem de propósito. A Equipe Frila age daqui, com a conta de
# serviço, e cada ação fica registrada com o nome de quem assinou.
#
# ── O prazo ───────────────────────────────────────────────────────────────────
#
# A diretriz 1.2 pede ação sobre conteúdo denunciado em até 24 h, inclusive no fim de
# semana do piloto. `pendentes` é a fila de plantão: mostra o que está aberto, até quando
# tratar, e marca o que já venceu. A RN13 continua inteira — a resposta ao denunciante
# segue em até 5 dias úteis, e este prazo é sobre agir no conteúdo, não sobre responder.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}

psql() { docker exec -i "$DB" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }

if ! psql -tAc 'select 1' >/dev/null 2>&1; then
  echo "Banco '$DB' não responde. Suba com 'supabase start' ou aponte DB_CONTAINER." >&2
  exit 2
fi

# O motivo é texto de quem opera e vai para a `ocorrencia`. Entra por variável de ligação,
# e nunca interpolado no SQL: um apóstrofo no motivo não pode virar sintaxe.
acao_na_vaga() {
  local funcao="$1" vaga="$2" operador="$3" acao="$4" motivo="$5"
  psql -tA \
    -v vaga="$vaga" -v operador="$operador" -v acao="$acao" -v motivo="$motivo" \
    -c "select jsonb_pretty(privado.$funcao(:'vaga'::uuid, :'acao', :'motivo', :'operador'::uuid))"
}

case "${1:?uso: moderar.sh <comando> …}" in

  pendentes)
    horas="${2:-24}"
    psql -v horas="$horas" <<'SQL'
\pset border 2
\pset title 'Denúncias abertas e o prazo da Diretriz 1.2'
select ocorrencia_id            as protocolo,
       to_char(criada_em  at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as aberta,
       to_char(tratar_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as tratar_ate,
       case when vencida then 'VENCIDA' else 'no prazo' end as prazo,
       motivo
  from privado.moderacao_pendente((:'horas' || ' hours')::interval);
SQL
    ;;

  ocultar)        acao_na_vaga operacao_moderar_conteudo "${2:?vaga}" "${3:?operador}" ocultar  "${*:4}" ;;
  reexibir)       acao_na_vaga operacao_moderar_conteudo "${2:?vaga}" "${3:?operador}" reexibir "${*:4}" ;;
  ocultar-texto)  acao_na_vaga operacao_moderar_texto    "${2:?vaga}" "${3:?operador}" ocultar  "${*:4}" ;;
  reexibir-texto) acao_na_vaga operacao_moderar_texto    "${2:?vaga}" "${3:?operador}" reexibir "${*:4}" ;;

  *) sed -n '2,30p' "$0"; exit 2 ;;
esac
