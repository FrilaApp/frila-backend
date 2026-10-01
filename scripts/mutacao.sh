#!/usr/bin/env bash
# Prova que os testes cobrem as regras do banco, em vez de apenas rodarem ao lado delas.
#
# Uma suíte verde não diz nada sobre o que ela protege. Este script derruba cada
# `CHECK`, cada `EXCLUDE`, cada restrição de unicidade e cada trigger do esquema, um por
# vez, roda o pgTAP e exige que ele fique **vermelho**. Regra que sobrevive à própria
# remoção sem nenhum teste reclamar é regra que a próxima refatoração remove de graça.
#
# Escrito depois de uma revisão medir que 11 de 31 restrições estavam nessa situação.
#
# Quatro defesas contra o próprio script mentir, porque agora ele é um portão de CI e o
# time vai parar de conferir à mão:
#
#   1. **Linha de base.** A suíte tem que estar verde antes de mutar. Sem isso, uma
#      suíte quebrada por motivo alheio faz tudo parecer coberto.
#   2. **Identidade, não código de saída.** Não basta a suíte ficar vermelha: o
#      arquivo de teste que falha tem que ser diferente dos que já falhavam. Um
#      `exit 1` por qualquer motivo não conta como detecção.
#   3. **Restauração obrigatória.** Se a regra não voltar, o script aborta em vez de
#      seguir mutando um banco já mutilado — modo de falha observado em revisão.
#   4. **Devolução no caminho interrompido.** Entre derrubar e restaurar há uma suíte
#      inteira, que leva minutos. `Ctrl-C`, `SIGTERM` ou timeout de CI nesse intervalo
#      deixavam o esquema sem o objeto, em silêncio e sem registro de qual era.
#
# E o total de alvos é impresso, por categoria, antes da primeira mutação. Até aqui o
# número não existia em nenhuma linha da saída: só a soma implícita de
# cobertas + sem cobertura + não medidas, no fim. Regra nova em categoria que ninguém
# varre só se denuncia por um total que não sobe, e um total que não se lê não denuncia
# nada.
#
# Uso:  ./scripts/mutacao.sh              tudo
#       ./scripts/mutacao.sh sem_turno    só o que casa com o texto
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}
filtro="${1:-}"

psql() { docker exec -i "$DB" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }

# Nomes dos arquivos de teste que falharam, extraídos de uma saída de `supabase test db`
# lida da entrada padrão, um por linha.
#
# A saída entra por stdin, e não rodando a suíte aqui dentro, de propósito: quem precisa do
# nome já tem a saída da rodada que reprovou, e rodar de novo para descobrir o nome dá a
# resposta de **outra** rodada. Neste repositório isso não é hipótese — há teste que passa
# em banco limpo e cai na segunda passada, depois que os scripts de corrida e de
# demonstração deixam dado atrás.
nomes_falhados() { sed -n 's|.*/supabase/tests/\([0-9a-z_]*\)\.sql.*Failed.*|\1|p;
                           s|^/.*tests/\([0-9a-z_]*\)\.sql .*Dubious.*|\1|p' | sort -u; }

# Nomes dos arquivos de teste que falharam nesta rodada, um por linha.
falhas() { supabase test db 2>&1 | nomes_falhados; }

# ── Defesa 1: a linha de base ──────────────────────────────────────────────────
#
# A saída é guardada, e não descartada em `/dev/null`. Descartá-la custou caro: em 29/09 a
# suíte ficou vermelha em três branches ao mesmo tempo e este portão dizia apenas "SUÍTE JÁ
# VERMELHA", sem o nome do teste. O passo `pgTAP` do mesmo job passava, então nem o log da
# CI tinha o vermelho em outro lugar — descobrir qual teste era exigiu banco na mão. Um
# portão que sabe que está vermelho e joga fora a única informação que resolve é o mesmo
# pecado que ele existe para pegar.
printf '▸ Linha de base... '
if ! base=$(supabase test db 2>&1); then
  echo "SUÍTE JÁ VERMELHA"
  echo
  vermelhos=$(printf '%s\n' "$base" | nomes_falhados)
  if [ -n "$vermelhos" ]; then
    echo "Vermelho em:"
    printf '%s\n' "$vermelhos" | sed 's/^/    /'
  else
    # Sem nome extraído, a suíte provavelmente morreu antes de rodar teste algum — banco
    # fora do ar, migração que não aplica. A cauda crua diz isso; "SUÍTE JÁ VERMELHA"
    # sozinho, não.
    echo "Nenhum arquivo de teste foi nomeado na saída: a suíte pode ter morrido antes de"
    echo "rodar. As últimas 20 linhas:"
    printf '%s\n' "$base" | tail -20 | sed 's/^/    /'
  fi
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
#
# `public` **e** `privado`. Até 23/09 só `public` era varrido, e a primeira tabela de
# `privado` com restrição — a lista de termos do filtro da diretriz 1.2 — entrou sem que
# o total de alvos subisse: o verificador continuou dizendo 71 de 71, que é o jeito mais
# convincente de um portão mentir. Regra nova em schema que ninguém varre é regra sem
# cobertura que se apresenta como coberta.
adicionar < <(psql -tAc "
  select 'restrição|' || c.conname || '|' ||
         'alter table ' || c.conrelid::regclass || ' drop constraint ' || quote_ident(c.conname) || '|' ||
         'alter table ' || c.conrelid::regclass || ' add constraint ' ||
           quote_ident(c.conname) || ' ' || pg_get_constraintdef(c.oid)
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname in ('public','privado') and c.contype in ('c','x')
   order by c.conname")

# Restrição de unicidade, em bloco próprio e não junto do `c`/`x` acima.
#
# Nove das dezesseis são o que torna uma RPC idempotente — candidatura por vaga e
# profissional, denúncia por chave do cliente, publicação por chave do cliente, avaliação
# por lado (RN07) — e `usuario_id_perfil` é RN25 inteira. Até aqui nenhuma delas era
# varrida: o filtro era `contype in ('c','x')` e 'u' não aparecia no arquivo.
#
# Bloco separado porque o comando de restauração **não** é o mesmo do `CHECK`:
#
#   · Derrubar uma unique derruba o índice por trás dela, e `add constraint ... UNIQUE
#     (cols)` constrói um índice novo com o nome da constraint. Isso é equivalente aqui
#     e não é equivalente num banco de produção, onde o índice pode ter sido criado
#     `concurrently`. Este portão só roda em banco de teste.
#
#   · Uma chave estrangeira pode depender do índice da unique, e aí o `drop` simples é
#     recusado pelo Postgres — medido em `usuario_id_perfil`, de quem dependem
#     `so_conta_de_profissional` e `so_conta_de_contratante`. Sem `cascade` a unique de
#     RN25 cairia em "não consegui mutar" para sempre, e um balde que não conta é o mesmo
#     pecado do "71 de 71". Com `cascade`, a restauração precisa devolver as três
#     constraints, e as definições das dependentes são colhidas **aqui**, antes do drop:
#     depois do drop elas não existem mais para serem lidas.
#
#   · A restauração vai dentro de `begin; … commit;`. DDL em Postgres é transacional, e
#     medido que `psql -c` com várias instruções reverte tudo se uma falhar. Sem isso um
#     restore de três passos teria dois estados intermediários em que o esquema está pela
#     metade, e a Defesa 3 só enxerga o resultado final.
#
# `cascade` só entra quando **todos** os dependentes são chaves estrangeiras, que são as
# únicas que esta consulta sabe devolver. Se algum dia algo mais depender do índice, a
# contagem não fecha, o `cascade` não é emitido, o `drop` simples é recusado e o alvo sai
# como "não medido" — ruidoso, em vez de um objeto perdido em silêncio.
adicionar < <(psql -tAc "
  select 'unicidade|' || c.conname || '|' ||
         'alter table ' || c.conrelid::regclass || ' drop constraint ' || quote_ident(c.conname) ||
           case when d.todos > 0 and d.todos = d.estrangeiras then ' cascade' else '' end || '|' ||
         'begin; ' ||
         'alter table ' || c.conrelid::regclass || ' add constraint ' ||
           quote_ident(c.conname) || ' ' || pg_get_constraintdef(c.oid) || '; ' ||
         coalesce(d.devolve, '') ||
         'commit;'
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    left join lateral (
      select count(*) as todos,
             count(*) filter (where f.contype = 'f') as estrangeiras,
             string_agg('alter table ' || f.conrelid::regclass || ' add constraint ' ||
                          quote_ident(f.conname) || ' ' || pg_get_constraintdef(f.oid) || '; ',
                        '' order by f.conname) filter (where f.contype = 'f') as devolve
        from pg_depend p
        left join pg_constraint f
               on f.oid = p.objid and p.classid = 'pg_constraint'::regclass
       where p.refobjid = c.conindid
         and p.refclassid = 'pg_class'::regclass
         and p.deptype = 'n') d on true
   where n.nspname in ('public','privado') and c.contype = 'u'
   order by c.conname")

# Índice único, que **não** é constraint: não tem `contype`, não está em `pg_constraint` e
# por isso estava fora do portão por dois motivos independentes — nem o filtro nem a
# tabela consultada o alcançavam.
#
# Os três da develop são parciais, e a cláusula `where` é a regra inteira:
# `usuario_email_ativo` só vale na conta não anonimizada (RF25 manda anonimizar em vez de
# apagar, e unicidade total trancaria o e-mail de quem encerrou a conta para sempre);
# `notificacao_marca_de_envio` só nos tipos que têm marca de envio; e
# `posicao_uma_reabertura_por_falta` só onde a coluna não é nula. Um restore que montasse
# o `create unique index` à mão perderia o `where` e **apertaria** a regra em silêncio —
# que é pior do que não medir, porque envenena todos os alvos seguintes com um esquema
# que ninguém sabe que mudou. `pg_get_indexdef` devolve a instrução completa, com o
# `where`, e é por isso que ela é o restore.
adicionar < <(psql -tAc "
  select 'índice|' || i.relname || '|' ||
         'drop index ' || quote_ident(n.nspname) || '.' || quote_ident(i.relname) || '|' ||
         pg_get_indexdef(x.indexrelid)
    from pg_index x
    join pg_class i on i.oid = x.indexrelid
    join pg_class t on t.oid = x.indrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname in ('public','privado')
     and x.indisunique
     and not exists (select 1 from pg_constraint c where c.conindid = x.indexrelid)
   order by i.relname")

# Trigger não se derruba e se recria de graça — desabilitar basta e é reversível.
adicionar < <(psql -tAc "
  select 'trigger|' || t.tgname || '|' ||
         'alter table ' || t.tgrelid::regclass || ' disable trigger ' || quote_ident(t.tgname) || '|' ||
         'alter table ' || t.tgrelid::regclass || ' enable trigger ' || quote_ident(t.tgname)
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public','privado') and not t.tgisinternal
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

# ── O total, por categoria ─────────────────────────────────────────────────────
#
# Impresso antes de mutar, e não só somado no fim. O caso de 23/09 é o argumento: a
# primeira tabela de `privado` com restrição entrou sem que o total subisse, o
# verificador continuou dizendo 71 de 71, e ninguém teve de onde desconfiar. Um total que
# aparece é a única asserção que o portão faz sobre a própria cobertura.
echo "Alvos montados: ${#alvos[@]}"
printf '%s\n' ${alvos[@]+"${alvos[@]}"} | cut -d'|' -f1 | sort | uniq -c |
  sort -rn | sed 's/^ */    /'
if [ -n "$filtro" ]; then
  echo
  echo "Filtro '$filtro': só os alvos cujo nome o contém são mutados."
fi
echo

sobreviventes=()
pulados=()
mortos=0

# ── Defesa 4: a janela entre derrubar e restaurar ──────────────────────────────
#
# A linha que derruba e a que restaura têm uma suíte pgTAP inteira entre elas, que leva
# minutos por alvo. Interrupção nesse intervalo — `Ctrl-C`, `SIGTERM`, timeout de CI,
# janela fechada — deixava o esquema sem o objeto, sem aviso, e sem nada no disco dizendo
# qual era. A Defesa 3 cobre "a restauração falhou"; não cobria "a restauração nunca foi
# tentada", e este portão passou de 117 para 136 alvos, o que é 19 janelas novas.
#
# Deliberadamente sem arquivo de trava e sem estado entre execuções: uma trava contra
# execução dupla trocaria "perde um alvo" por "não roda nunca mais, em silêncio", que é o
# modo de falha caro. No caminho normal `restaurar_pendente` está vazio quando o trap
# roda, e ele não imprime nada.
restaurar_pendente=''
restaurar_nome=''

devolver() {
  [ -z "$restaurar_pendente" ] && return 0
  local comando="$restaurar_pendente"
  restaurar_pendente=''
  echo
  if psql -q -c "$comando" >/dev/null 2>&1; then
    echo "Interrompido durante a mutação de '$restaurar_nome' — o objeto foi devolvido."
  else
    echo "ATENÇÃO: o banco ficou SEM '$restaurar_nome' e a devolução também falhou."
    echo "Nada medido neste banco vale enquanto isso não for consertado:"
    echo "rode 'supabase db reset'."
  fi
}

trap devolver EXIT
trap 'devolver; exit 130' INT
trap 'devolver; exit 143' TERM

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

  # Armada só depois de o drop ter dado certo: armar antes faria o trap tentar
  # restaurar um objeto que nunca saiu.
  restaurar_pendente="$restaurar"
  restaurar_nome="$nome"

  quem=$(falhas)

  # ── Defesa 3: a restauração é obrigatória ────────────────────────────────────
  if ! psql -q -c "$restaurar" >/dev/null 2>&1; then
    # Este ramo já diz tudo o que o trap diria, e com mais contexto. Desarmar evita a
    # mensagem em dobro no EXIT.
    restaurar_pendente=''
    echo "RESTAURAÇÃO FALHOU"
    echo
    echo "O banco ficou sem '$nome' e o script parou aqui de propósito: seguir mutando"
    echo "um esquema mutilado produziria um relatório que não vale nada."
    echo "Restaure com 'supabase db reset'."
    exit 1
  fi
  restaurar_pendente=''

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
echo "cobertas: $mortos · sem cobertura: ${#sobreviventes[@]} · não medidas: ${#pulados[@]}" \
     "· de ${#alvos[@]} alvos"

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
