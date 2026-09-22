#!/usr/bin/env bash
# Prova que os testes cobrem as regras do banco, em vez de apenas rodarem ao lado delas.
#
# Uma suíte verde não diz nada sobre o que ela protege. Este script derruba cada
# `CHECK`, cada `EXCLUDE` e cada trigger do esquema, um por vez, roda o pgTAP e exige
# que ele fique **vermelho**. Regra que sobrevive à própria remoção sem nenhum teste
# reclamar é regra que a próxima refatoração remove de graça.
#
# Escrito depois de uma revisão medir que 11 de 31 restrições estavam nessa situação.
#
# Três defesas contra o próprio script mentir, porque agora ele é um portão de CI e o
# time vai parar de conferir à mão:
#
#   1. **Linha de base.** A suíte tem que estar verde antes de mutar. Sem isso, uma
#      suíte quebrada por motivo alheio faz tudo parecer coberto.
#   2. **Identidade, não código de saída.** Não basta a suíte ficar vermelha: o
#      arquivo de teste que falha tem que ser diferente dos que já falhavam. Um
#      `exit 1` por qualquer motivo não conta como detecção.
#   3. **Restauração obrigatória.** Se a regra não voltar, o script aborta em vez de
#      seguir mutando um banco já mutilado — modo de falha observado em revisão.
#
# Uso:  ./scripts/mutacao.sh              tudo
#       ./scripts/mutacao.sh sem_turno    só o que casa com o texto
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}
filtro="${1:-}"

psql() { docker exec -i "$DB" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }

# Nomes dos arquivos de teste que falharam nesta rodada, um por linha.
falhas() { supabase test db 2>&1 | sed -n 's|.*/supabase/tests/\([0-9a-z_]*\)\.sql.*Failed.*|\1|p;
                                           s|^/.*tests/\([0-9a-z_]*\)\.sql .*Dubious.*|\1|p' | sort -u; }

# ── Defesa 1: a linha de base ──────────────────────────────────────────────────
printf '▸ Linha de base... '
if ! supabase test db >/dev/null 2>&1; then
  echo "SUÍTE JÁ VERMELHA"
  echo
  echo "Mutação não diz nada com a suíte quebrada: toda regra pareceria coberta."
  echo "Rode 'supabase test db' e conserte antes."
  exit 1
fi
echo "verde ✓"
echo

# ── Os alvos: restrições e triggers ────────────────────────────────────────────
alvos=()
adicionar() { while IFS= read -r l; do [ -n "$l" ] && alvos+=("$l"); done; }

# tipo|rótulo|derrubar|restaurar
adicionar < <(psql -tAc "
  select 'restrição|' || c.conname || '|' ||
         'alter table ' || c.conrelid::regclass || ' drop constraint ' || quote_ident(c.conname) || '|' ||
         'alter table ' || c.conrelid::regclass || ' add constraint ' ||
           quote_ident(c.conname) || ' ' || pg_get_constraintdef(c.oid)
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public' and c.contype in ('c','x')
   order by c.conname")

# Trigger não se derruba e se recria de graça — desabilitar basta e é reversível.
adicionar < <(psql -tAc "
  select 'trigger|' || t.tgname || '|' ||
         'alter table ' || t.tgrelid::regclass || ' disable trigger ' || quote_ident(t.tgname) || '|' ||
         'alter table ' || t.tgrelid::regclass || ' enable trigger ' || quote_ident(t.tgname)
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and not t.tgisinternal
   order by t.tgname")

# Política de RLS, por dois caminhos opostos, porque as falhas são opostas.
#
#   **ausente**  — a política some e a tabela fecha. Mata o teste que afirma que alguém
#                  LÊ algo. Pega a política sem nenhuma asserção positiva.
#   **frouxa**   — o `using` vira `true` e a tabela abre inteira. Mata o teste que afirma
#                  que alguém NÃO lê algo. Pega o `using (true)` posto por engano, que a
#                  mutação por ausência não enxerga: toda asserção de "fulano lê o
#                  próprio" continua verdadeira com a tabela escancarada.
#
# A segunda existe porque uma revisão mediu seis políticas que sobreviviam a ela, com a
# suíte verde — e o que passaria era token de push, distância de check-in e valor de
# turno de terceiros.
adicionar < <(psql -tAc "
  select 'frouxa|' || p.polname || '|' ||
         'alter policy ' || quote_ident(p.polname) || ' on ' || p.polrelid::regclass ||
           ' using (true)' || '|' ||
         'alter policy ' || quote_ident(p.polname) || ' on ' || p.polrelid::regclass ||
           ' using (' || pg_get_expr(p.polqual, p.polrelid) || ')'
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and p.polqual is not null
     -- A política do catálogo de funções é using(true) por definição: ele é aberto a
     -- quem está logado. Afrouxá-la não muda nada, e cobrá-la seria cobrar um teste
     -- impossível.
     and pg_get_expr(p.polqual, p.polrelid) <> 'true'
   order by p.polname")

adicionar < <(psql -tAc "
  select 'ausente|' || p.polname || '|' ||
         'drop policy ' || quote_ident(p.polname) || ' on ' || p.polrelid::regclass || '|' ||
         'create policy ' || quote_ident(p.polname) || ' on ' || p.polrelid::regclass ||
           ' as ' || case when p.polpermissive then 'permissive' else 'restrictive' end ||
           ' for ' || case p.polcmd when 'r' then 'select' when 'a' then 'insert'
                                    when 'w' then 'update' when 'd' then 'delete'
                                    else 'all' end ||
           ' to ' || coalesce((select string_agg(quote_ident(r.rolname), ', ')
                                 from pg_roles r where r.oid = any (p.polroles)), 'public') ||
           coalesce(' using (' || pg_get_expr(p.polqual, p.polrelid) || ')', '') ||
           coalesce(' with check (' || pg_get_expr(p.polwithcheck, p.polrelid) || ')', '')
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
   order by p.polname")

sobreviventes=()
pulados=()
mortos=0

for alvo in ${alvos[@]+"${alvos[@]}"}; do
  IFS='|' read -r tipo nome derrubar restaurar <<< "$alvo"

  [ -n "$filtro" ] && [[ "$nome" != *"$filtro"* ]] && continue

  printf '  %-9s %-40s ' "$tipo" "$nome"

  # Alvo que não se consegue mutar é alvo **não medido**, e não medido nunca conta como
  # coberto. Regra geral deste repositório para portão: qualquer caminho que não seja
  # "medi e o resultado foi X" tem que sair diferente de zero.
  if ! psql -q -c "$derrubar" >/dev/null 2>&1; then
    echo "NÃO CONSEGUI MUTAR — não medido"
    pulados+=("$tipo $nome")
    continue
  fi

  quem=$(falhas)

  # ── Defesa 3: a restauração é obrigatória ────────────────────────────────────
  if ! psql -q -c "$restaurar" >/dev/null 2>&1; then
    echo "RESTAURAÇÃO FALHOU"
    echo
    echo "O banco ficou sem '$nome' e o script parou aqui de propósito: seguir mutando"
    echo "um esquema mutilado produziria um relatório que não vale nada."
    echo "Restaure com 'supabase db reset'."
    exit 1
  fi

  # ── Defesa 2: identidade do que falhou ───────────────────────────────────────
  if [ -z "$quem" ]; then
    echo "SOBREVIVEU — nenhum teste reclamou"
    sobreviventes+=("$tipo $nome")
  else
    echo "morreu ✓  ($(echo "$quem" | tr '\n' ' ' | sed 's/ $//'))"
    mortos=$((mortos + 1))
  fi
done

echo
echo "cobertas: $mortos · sem cobertura: ${#sobreviventes[@]} · não medidas: ${#pulados[@]}"

falta=0

if [ "${#sobreviventes[@]}" -gt 0 ]; then
  echo
  echo "Sem cobertura — cada uma precisa de uma asserção que fique vermelha sem ela:"
  printf '  %s\n' "${sobreviventes[@]}"
  falta=1
fi

if [ "${#pulados[@]}" -gt 0 ]; then
  echo
  echo "Não medidas — o comando de mutação falhou, então o portão não sabe nada sobre elas:"
  printf '  %s\n' "${pulados[@]}"
  falta=1
fi

[ "$falta" -ne 0 ] && exit 1
exit 0
