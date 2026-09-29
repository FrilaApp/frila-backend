#!/usr/bin/env bash
# Prova de concorrência do teto da RN23 (cartão ee3MT3fH).
#
# O pgTAP roda numa sessão só e não enxerga corrida. Aqui, duas sessões despacham ao
# mesmo tempo DUAS vagas diferentes, não urgentes, para os mesmos elegíveis, e seguram o
# commit por um segundo depois de decidir. Sem a trava por profissional
# (`privado.travar_teto`, `pg_advisory_xact_lock`), cada sessão olha a última notificação
# no próprio snapshot, nenhuma vê a da outra, e o profissional recebe duas notificações de
# vaga no mesmo minuto. Com a trava, a segunda espera a primeira terminar, vê a notificação
# dela e deixa a sua vaga esperando o teto.
#
# O que se exige, para cada elegível que não tinha notificação de vaga na janela:
#   1. exatamente uma notificação de vaga entre as duas vagas;
#   2. dois despachos (um por vaga), sendo um deles esperando o teto.
#
# Uso:  ./scripts/corrida-teto.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}

psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

TMP=$(mktemp -d)
falha=0

VAGA_A="d0000000-0000-4000-8000-0000000000a7"
VAGA_B="d0000000-0000-4000-8000-0000000000b7"

limpar() {
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: a limpeza falhou" >&2
set session_replication_role = 'replica';
delete from public.despacho where vaga_id in ('$VAGA_A', '$VAGA_B');
delete from public.notificacao where referencia_id in ('$VAGA_A', '$VAGA_B');
delete from public.vaga where id in ('$VAGA_A', '$VAGA_B');
set session_replication_role = 'origin';
SQL
  rm -rf "$TMP"
}
trap limpar EXIT
limpar; TMP=$(mktemp -d)

echo "▸ Montando o cenário: duas vagas no horário da vaga de referência do seed"

psql >/dev/null <<SQL
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, publicado_por, modo, estado, chave_cliente)
select x.id, r.estabelecimento_id, r.funcao_id, r.inicio_em, r.fim_em, r.local, r.ponto,
       r.valor_centavos, 1, false, false, false, r.responsavel_local, r.publicado_por,
       r.modo, 'publicada', gen_random_uuid()
  from public.vaga r,
       (values ('$VAGA_A'::uuid), ('$VAGA_B'::uuid)) as x(id)
 where r.id = 'd0000000-0000-4000-8000-000000000001';
SQL

urgente=$(psql -tAc "
  select (inicio_em - privado.agora()) < privado.parametro_de_notificacao('urgente_antecedencia')
    from public.vaga where id = '$VAGA_A'")
[ "$urgente" = "f" ] || { echo "  ✗ A vaga de referência começa em menos de 2 h: a corrida precisa de vaga não urgente" >&2; exit 1; }

# Os elegíveis livres: sem notificação de vaga dentro da janela. Os outros esperariam o
# teto de qualquer jeito, e não provam nada sobre a corrida.
psql -tAc "
  select e.profissional_id
    from privado.elegiveis('$VAGA_A') e
    join public.profissional p on p.id = e.profissional_id
   where coalesce(privado.ultima_no_teto(p.usuario_id), '-infinity')
         <= privado.agora() - privado.parametro_de_notificacao('teto_janela')" > "$TMP/livres"
n_livres=$(grep -c . "$TMP/livres" || true)
[ "$n_livres" -gt 0 ] || { echo "  ✗ Nenhum elegível livre do teto: a corrida não provaria nada" >&2; exit 1; }
ok "Cenário: $n_livres elegíveis sem notificação de vaga na janela"

echo "▸ Disparando as sessões A e B em concorrência real (cada uma segura o commit 1 s)"

for s in A B; do
  vaga=$([ "$s" = A ] && echo "$VAGA_A" || echo "$VAGA_B")
  psql -tA <<SQL >"$TMP/$s.out" 2>"$TMP/$s.err" &
set application_name = 'corrida_teto_$s';
begin;
select privado.despachar_vaga('$vaga');
select pg_sleep(1);
commit;
SQL
  eval "p$s=\$!"
done

wait "$pA"; sA=$?
wait "$pB"; sB=$?
[ $sA -eq 0 ] || falhou "Sessão A falhou: $(cat "$TMP/A.err")"
[ $sB -eq 0 ] || falhou "Sessão B falhou: $(cat "$TMP/B.err")"

echo "▸ Verificando o teto depois da corrida"

livres=$(sed "s/.*/'&'/" "$TMP/livres" | paste -sd, -)

duas=$(psql -tAc "
  select count(*) from (
    select d.profissional_id
      from public.despacho d
      join public.notificacao n on n.id = d.notificacao_id
     where d.vaga_id in ('$VAGA_A', '$VAGA_B')
       and d.profissional_id in ($livres)
     group by d.profissional_id
    having count(distinct n.id) <> 1) x")
if [ "$duas" -eq 0 ]; then
  ok "Cada um dos $n_livres elegíveis livres recebeu exatamente uma notificação de vaga"
else
  falhou "$duas profissionais não receberam exatamente uma notificação (teto furado pela corrida)"
fi

esperando=$(psql -tAc "
  select count(*) from public.despacho d
   where d.vaga_id in ('$VAGA_A', '$VAGA_B')
     and d.profissional_id in ($livres)
     and d.notificacao_id is null")
if [ "$esperando" -eq "$n_livres" ]; then
  ok "A outra vaga de cada um ficou esperando o teto ($esperando despachos sem notificação)"
else
  falhou "Esperava $n_livres despachos esperando o teto, encontrou $esperando"
fi

echo
if [ "$falha" -eq 0 ]; then
  echo "✓ Prova de concorrência do teto aprovada: dois executores não mandam duas."
  exit 0
else
  echo "✗ Falha na prova de concorrência do teto."
  exit 1
fi
