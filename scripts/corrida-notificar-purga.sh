#!/usr/bin/env bash
# Prova determinística de concorrência entre notificar e expurgo (K-001k/K-001l, Risco N1).
#
# O pgTAP roda numa única sessão SQL e não consegue reproduzir a corrida onde
# `privado.notificar` consulta a tabela antes do expurgo, uma sessão concorrente
# purga a notificação antiga (60 dias) e comita, e a primeira sessão tenta inserir
# novamente a mesma chave.
#
# Este script abre DUAS sessões concorrentes:
#   - Sessão 1 (Purga): abre transação, segura lock SHARE em public.notificacao por 1.5s,
#     purga a notificação expirada e comita.
#   - Sessão 2 (Notificar): dispara enquanto Sessão 1 segura o lock SHARE.
#     Com a marca atuando como autoridade atômica, Notificar não recria a notificação
#     mesmo após a purga apagar a linha antiga.
#
# O que o script exige ao final:
#   1. A notificação antiga com mais de 60 dias é purgada pela Sessão 1.
#   2. Notificar não re-insere o aviso expurgado (aviso_recriado = 0).
#   3. A marca durável em privado.marca_notificacao permanece intacta (marca_preservada = 1).
#
# Uso: ./scripts/corrida-notificar-purga.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}

psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

TMP=$(mktemp -d)
falha=0

U_ID="784b0000-0000-4000-8000-000000000001"
REF_ID="784b0000-0000-4000-8000-000000000002"

limpar_dados() {
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: a limpeza falhou na corrida de notificar/purga" >&2
set session_replication_role = 'replica';
delete from public.notificacao where usuario_id = '$U_ID';
do \$\$
begin
  if to_regclass('privado.marca_notificacao') is not null then
    delete from privado.marca_notificacao where usuario_id = '$U_ID';
  end if;
end \$\$;
delete from public.usuario where id = '$U_ID';
set session_replication_role = 'origin';
SQL
}

limpar_tudo() {
  limpar_dados
  rm -rf "$TMP"
}
trap limpar_tudo EXIT

echo "▸ Montando cenário de corrida entre notificar e purga (N1)"

# Limpa resíduos prévios se houver
limpar_dados >/dev/null 2>&1 || true

# Cria usuário de teste e notificação expirada (70 dias atrás)
psql >/dev/null <<SQL
insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado
) values (
  '$U_ID', 'profissional', 'Teste Concorrência Purga', '+5561984400001',
  'corrida_notificar_purga@frila.test', '1995-05-10', '1.0', now(), 'ativa'
) on conflict do nothing;

insert into public.notificacao (
  usuario_id, tipo, referencia_id, enviada_em
) values (
  '$U_ID', 'lembrete_24h', '$REF_ID', privado.agora() - interval '70 days'
);
SQL

# Garante que a notificação e a marca foram criadas
marca_inicial=$(psql -tAc "select count(*) from privado.marca_notificacao where usuario_id = '$U_ID' and referencia_id = '$REF_ID';")
if [ "$marca_inicial" -ne 1 ]; then
  falhou "marca inicial não foi registrada"
  exit 1
fi

echo "▸ Disparando sessões concorrentes de purga e notificar"

# Sessão 1: adquire lock SHARE em notificacao, dorme 1.5s, purga a notificação e commita
psql -tA <<SQL >"$TMP/sessao1.out" 2>"$TMP/sessao1.err" &
set application_name = 'corrida_purga_sessao1';
begin;
set local statement_timeout = '12s';
lock public.notificacao in share mode;
select pg_sleep(1.5);
select 'purgados=' || privado.limpar_notificacoes_antigas(60, 5000);
commit;
SQL
PID_SESSAO1=$!

# Aguarda 0.3s para garantir que a Sessão 1 adquiriu o lock SHARE
sleep 0.3

# Sessão 2: executa privado.notificar enquanto a Sessão 1 segura o lock SHARE
psql -tA <<SQL >"$TMP/sessao2.out" 2>"$TMP/sessao2.err" &
set application_name = 'corrida_notificar_sessao2';
set statement_timeout = '10s';
select privado.notificar('$U_ID', 'lembrete_24h', '$REF_ID');
SQL
PID_SESSAO2=$!

# Aguarda ambas as sessões terminarem
wait $PID_SESSAO1; S1_EXIT=$?
wait $PID_SESSAO2; S2_EXIT=$?

if [ $S1_EXIT -ne 0 ]; then
  falhou "Sessão 1 (purga) falhou: $(cat "$TMP/sessao1.err")"
fi

if [ $S2_EXIT -ne 0 ]; then
  falhou "Sessão 2 (notificar) falhou: $(cat "$TMP/sessao2.err")"
fi

echo "▸ Verificando resultado da corrida"

recriado=$(psql -tAc "select count(*) from public.notificacao where usuario_id = '$U_ID' and referencia_id = '$REF_ID';")
marca_final=$(psql -tAc "select count(*) from privado.marca_notificacao where usuario_id = '$U_ID' and referencia_id = '$REF_ID';")

if [ "$recriado" -eq 0 ]; then
  ok "Aviso expurgado não foi recriado concorrentemente (recriado = 0)"
else
  falhou "Aviso expurgado foi recriado indevidamente (recriado = $recriado)"
fi

if [ "$marca_final" -eq 1 ]; then
  ok "Marca durável foi preservada (marca = 1)"
else
  falhou "Marca durável foi perdida (marca = $marca_final)"
fi

echo
if [ "$falha" -eq 0 ]; then
  echo "✓ Prova de concorrência notificar x purga aprovada: marca impede recriação."
  exit 0
else
  echo "✗ Falha na prova de concorrência notificar x purga."
  exit 1
fi
