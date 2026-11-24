#!/usr/bin/env bash
# Autoteste do portão `relogio-em-testes.sh` contra casos conhecidos de sucesso e falha.
#
# Portão com furo aprova calado: este autoteste prova que o portão pega as bombas-relógio
# reais que quebraram a CI em 02/10 (teste 250) e em 04/10 (teste 280), extraídas diretamente
# do histórico do Git, bem como casos sintéticos de chamada sem congelamento ou com
# congelamento tardio.
#
# Uso:  ./scripts/teste-relogio-em-testes.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PORTAO="${RELOGIO_PORTAO:-$PWD/scripts/relogio-em-testes.sh}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

caso() {
  local nome="$1" esperado="$2" frase="$3" arquivo="$4"
  casos=$((casos + 1))

  local saida codigo
  set +e
  saida=$("$PORTAO" "$arquivo" 2>&1)
  codigo=$?
  set -e

  if [ "$codigo" = "$esperado" ] && printf '%s\n' "$saida" | grep -qF "$frase"; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperava saída $esperado com \"$frase\", veio $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

echo "▸ Portão: prevenção de bomba-relógio em testes pgTAP"

# ── 1. Casos históricos reais extraídos do Git ──────────────────────────────────
#
# Se o repositório estiver com clone raso (shallow), aprofunda para alcançar os commits
if ! git rev-parse 18197c3~1 >/dev/null 2>&1 || ! git rev-parse 3604bea~1 >/dev/null 2>&1 \
   || ! git rev-parse c2907db >/dev/null 2>&1; then
  git fetch --unshallow 2>/dev/null || git fetch --depth=100 origin 2>/dev/null || true
fi

# O teste 250 original antes do commit 18197c3 (PR #132) criava vagas para 02/10 às 18h
# e chamava candidatar() antes do primeiro set_config('frila.agora').
git show 18197c3~1:supabase/tests/250_turnos_nao_verificados_e_reconciliacao.sql > "$TMP/hist_250.sql"
caso "reprova o teste 250 original (bomba-relógio de 02/10 extraída do git)" 1 \
  "Chamada sensível ao relógio (candidatar) na linha 176" \
  "$TMP/hist_250.sql"

# O teste 280 original antes do commit 3604bea (PR #141) criava vagas para 03/10 às 18h
# e chamava candidatar() antes do primeiro set_config('frila.agora').
git show 3604bea~1:supabase/tests/280_fechamento_turno_vaga.sql > "$TMP/hist_280.sql"
caso "reprova o teste 280 original (bomba-relógio de 04/10 extraída do git)" 1 \
  "Chamada sensível ao relógio (vagas_abertas) na linha 123" \
  "$TMP/hist_280.sql"

# ── 2. Casos sintéticos de falha ───────────────────────────────────────────────

# Falha: data absoluta em vaga e chamada de relógio sem NUNCA congelar frila.agora
cat << 'SQL' > "$TMP/falha_sem_congelamento.sql"
begin;
select plan(1);
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em)
values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
        '2026-11-10 18:00:00-03', '2026-11-10 23:00:00-03');
select public.candidatar('b6000000-0000-4000-8000-000000000011');
select finish();
rollback;
SQL
caso "reprova teste com data absoluta e candidatar sem nunca congelar relógio" 1 \
  "frila.agora NUNCA é congelado no arquivo" \
  "$TMP/falha_sem_congelamento.sql"

# Falha: format($$ select public.candidatar... $$) antes de set_config
cat << 'SQL' > "$TMP/falha_candidatar_tardio.sql"
begin;
select plan(1);
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em)
values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
        '2026-12-01 18:00:00-03', '2026-12-01 23:00:00-03');
select lives_ok(format($$ select public.candidatar(%L) $$, 'b6000000-0000-4000-8000-000000000011'));
select set_config('frila.agora', '2026-11-30 12:00:00-03', true);
select finish();
rollback;
SQL
caso "reprova format($$ select candidatar $$) antes de set_config" 1 \
  "DEPOIS da chamada" \
  "$TMP/falha_candidatar_tardio.sql"

# ── 3. Casos de sucesso ─────────────────────────────────────────────────────────

# Sucesso: teste 250 atual da árvore
caso "aprova o teste 250 atual (com frila.agora congelado antes da vaga)" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "supabase/tests/250_turnos_nao_verificados_e_reconciliacao.sql"

# Sucesso: teste 280 atual da árvore
caso "aprova o teste 280 atual (com frila.agora congelado no topo do arquivo)" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "supabase/tests/280_fechamento_turno_vaga.sql"

# Sucesso: congelamento prévio antes de inserir e chamar
cat << 'SQL' > "$TMP/sucesso_congelado_no_topo.sql"
begin;
select plan(1);
select set_config('frila.agora', '2026-11-01 12:00:00-03', true);
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em)
values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
        '2026-11-02 18:00:00-03', '2026-11-02 23:00:00-03');
select public.candidatar('b6000000-0000-4000-8000-000000000011');
select finish();
rollback;
SQL
caso "aprova teste com congelamento prévio de frila.agora" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "$TMP/sucesso_congelado_no_topo.sql"

# Sucesso: teste que usa apenas datas relativas dinâmicas sem datas fixas de vaga
cat << 'SQL' > "$TMP/sucesso_datas_relativas.sql"
begin;
select plan(1);
create temp table quando as
  select (privado.agora() + interval '3 days') as inicio,
         (privado.agora() + interval '3 days 6 hours') as fim;
select throws_ok(
  format($$ select public.candidatar(%L) $$, gen_random_uuid()),
  'PGRST');
select finish();
rollback;
SQL
caso "aprova teste com horários puramente relativos (privado.agora + interval)" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "$TMP/sucesso_datas_relativas.sql"

# Sucesso: datas absolutas apenas em dados de usuário (termos_versao / nascimento)
cat << 'SQL' > "$TMP/sucesso_apenas_usuario.sql"
begin;
select plan(1);
select public.criar_conta('contratante','Dona do Bar','+5561999990201','1980-01-01','2026-09-22');
select finish();
rollback;
SQL
caso "aprova teste com datas absolutas restritas a nascimento e termos_versao" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "$TMP/sucesso_apenas_usuario.sql"


# ── 5. Início ABSOLUTO de vaga de seleção que vence (B-111/B-111b, 24/11/2026) ──────────────────
#
# `selecao_com_antecedencia` compara inicio_em com publicado_em + 24 h, e publicado_em nasce com o
# now() REAL. 757 e 871 cravavam 2026-11-25 18:00 UTC e ficaram vermelhos às 18:00 UTC de 24/11, na
# CI de todo PR. A regra tem de reprovar os dois ORIGINAIS (c2907db, antes do #610) um mês antes,
# e de aprovar os arquivos corrigidos. "Hoje" é injetado por RELOGIO_HOJE.
git show c2907db:supabase/tests/757_privado_candidatura_em_json.sql > "$TMP/antigo_757.sql"
git show c2907db:supabase/tests/871_busca_chamar_e_perfil.sql > "$TMP/antigo_871.sql"

RELOGIO_HOJE=2026-10-25 caso "reprova o 757 ANTIGO a 30 dias (25/10/2026), com a linha exata" 1 \
  "antigo_757.sql:73: início absoluto 2026-11-25, vence em 30 dias (2026-11-24) (selecao_com_antecedencia usa now() real)" \
  "$TMP/antigo_757.sql"
RELOGIO_HOJE=2026-10-25 caso "reprova o 871 ANTIGO a 30 dias (25/10/2026), com a linha exata" 1 \
  "antigo_871.sql:166: início absoluto 2026-11-25, vence em 30 dias (2026-11-24) (selecao_com_antecedencia usa now() real)" \
  "$TMP/antigo_871.sql"
RELOGIO_HOJE=2026-10-24 caso "o 757 ANTIGO ainda não reprova a 31 dias (24/10/2026): só imprime o vencimento" 0 \
  "antigo_757.sql:73: 2026-11-25 18:00:00+00 vence em 2026-11-24 (31 dias)" \
  "$TMP/antigo_757.sql"
RELOGIO_HOJE=2026-10-25 caso "aprova o 757 CORRIGIDO (início now() + 3 dias)" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "supabase/tests/757_privado_candidatura_em_json.sql"
RELOGIO_HOJE=2026-10-25 caso "aprova o 871 CORRIGIDO (início now() + 3 dias)" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "supabase/tests/871_busca_chamar_e_perfil.sql"

# O 807 congela frila.agora em 2027 e prende publicado_em ao relógio de teste: aprova. O MESMO arquivo
# sem a linha do `alter` (a linha vira vazia, para não mexer na numeração) reprova com a data a vencer.
RELOGIO_HOJE=2026-12-20 caso "aprova o 807 com publicado_em preso ao relógio de teste (alter ... privado.agora())" 0 \
  "arquivo(s) prendem publicado_em ao relógio de teste" \
  "supabase/tests/807_leitura_perfil_e_candidato_f2.sql"
sed 's/^alter table public\.vaga alter column publicado_em set default privado\.agora();$//' \
  supabase/tests/807_leitura_perfil_e_candidato_f2.sql > "$TMP/807_sem_o_alter.sql"
RELOGIO_HOJE=2026-12-20 caso "reprova o 807 SEM o alter (início 2027-01-15, vence 14/01, a 25 dias)" 1 \
  "início absoluto 2027-01-15, vence em 25 dias (2027-01-14)" \
  "$TMP/807_sem_o_alter.sql"

cat << 'SQL' > "$TMP/selecao_data_fixa.sql"
begin;
select plan(1);
select public.publicar_vaga('b6000000-0000-4000-8000-000000000011', 'b6000000-0000-4000-8000-000000000012',
  '2026-12-05 18:00:00+00'::timestamptz, '2026-12-05 23:00:00+00'::timestamptz,
  'Local', '{}'::jsonb, 10000, 1, true, false, false, 'Resp', 'selecao', gen_random_uuid());
select finish();
rollback;
SQL
RELOGIO_HOJE=2026-11-24 caso "reprova seleção com início fixo a 10 dias (vence em 2026-12-04)" 1 \
  "selecao_data_fixa.sql:4: início absoluto 2026-12-05, vence em 10 dias (2026-12-04)" \
  "$TMP/selecao_data_fixa.sql"
RELOGIO_HOJE=2026-12-06 caso "data passada nunca falha (hoje depois do início)" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "$TMP/selecao_data_fixa.sql"
RELOGIO_HOJE=2026-10-01 caso "data a mais de 30 dias só imprime a tabela de vencimentos" 0 \
  "selecao_data_fixa.sql:4: 2026-12-05 18:00:00+00 vence em 2026-12-04 (64 dias)" \
  "$TMP/selecao_data_fixa.sql"

sed 's/^\(  .2026-12-05 18:00:00+00.*\)$/\1 -- relogio: ok publicado_em segue frila.agora/' "$TMP/selecao_data_fixa.sql" \
  | sed 's/^\(  .Local.*\)$/\1/' > "$TMP/selecao_com_excecao.sql"
RELOGIO_HOJE=2026-11-24 caso "a exceção '-- relogio: ok <motivo>' na linha da data aprova" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "$TMP/selecao_com_excecao.sql"
grep -q 'relogio: ok' "$TMP/selecao_com_excecao.sql" || { echo "  ✗ o caso da exceção não montou o arquivo"; falhas=$((falhas + 1)); }

cat << 'SQL' > "$TMP/selecao_publicado_em_explicito.sql"
begin;
select plan(1);
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, modo, publicado_em)
values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
        '2026-12-05 18:00:00+00', '2026-12-05 23:00:00+00', 'selecao', '2026-11-01 12:00:00+00');
select finish();
rollback;
SQL
RELOGIO_HOJE=2026-11-24 caso "insert com publicado_em explícito na lista de colunas aprova (a constraint usa o valor dado)" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "$TMP/selecao_publicado_em_explicito.sql"

# ── 6. Ajustes do parecer do Lince Codex no #612 (B-111c, 24/11/2026) ──────────────────────────────
PRESO='alter table public.vaga alter column publicado_em set default privado.agora();'
git show 94f6478:supabase/tests/807_leitura_perfil_e_candidato_f2.sql > "$TMP/807_base.sql"
FRASE_807='início absoluto 2027-01-15, vence em 25 dias (2027-01-14)'

# (a) O alter só isenta se for EXECUTÁVEL e vier ANTES da primeira publicação.
{ cat "$TMP/807_base.sql"; echo "$PRESO"; } > "$TMP/807_alter_depois_do_rollback.sql"
RELOGIO_HOJE=2026-12-20 caso "(a) reprova o 807 com o alter no FIM, depois do rollback" 1 \
  "$FRASE_807" "$TMP/807_alter_depois_do_rollback.sql"
awk -v alter="/* $PRESO */" '{print} /^begin;$/ && !d {print alter; d=1}' "$TMP/807_base.sql" > "$TMP/807_alter_em_bloco.sql"
grep -qF "/* $PRESO */" "$TMP/807_alter_em_bloco.sql" || { echo "  ✗ (a) o caso do alter em /* */ não montou o arquivo"; falhas=$((falhas + 1)); }
RELOGIO_HOJE=2026-12-20 caso "(a) reprova o 807 com o alter só dentro de /* ... */" 1 \
  "$FRASE_807" "$TMP/807_alter_em_bloco.sql"
awk -v alter="-- $PRESO" '{print} /^begin;$/ && !d {print alter; d=1}' "$TMP/807_base.sql" > "$TMP/807_alter_em_linha.sql"
RELOGIO_HOJE=2026-12-20 caso "(a) reprova o 807 com o alter só em comentário de linha (--)" 1 \
  "$FRASE_807" "$TMP/807_alter_em_linha.sql"

# Alter depois da primeira publicação, sem frila.agora congelado, ou depois do rollback: não prende nada.
pub_selecao() {  # imprime um publicar_vaga de seleção com início fixo em 2026-12-05
  cat << 'SQL'
select public.publicar_vaga('b6000000-0000-4000-8000-000000000011', 'b6000000-0000-4000-8000-000000000012',
  '2026-12-05 18:00:00+00'::timestamptz, '2026-12-05 23:00:00+00'::timestamptz,
  'Local', '{}'::jsonb, 10000, 1, true, false, false, 'Resp', 'selecao', gen_random_uuid());
SQL
}
CONGELA="select set_config('frila.agora', '2026-11-24 12:00:00+00', true);"
{ echo 'begin;'; echo "$CONGELA"; pub_selecao; echo "$PRESO"; echo 'select * from finish();'; echo 'rollback;'; } > "$TMP/alter_depois_da_publicacao.sql"
RELOGIO_HOJE=2026-11-24 caso "(a) reprova alter DEPOIS da primeira publicação (antes do rollback)" 1 \
  "início absoluto 2026-12-05, vence em 10 dias" "$TMP/alter_depois_da_publicacao.sql"
{ echo 'begin;'; echo "$PRESO"; pub_selecao; echo 'select * from finish();'; echo 'rollback;'; } > "$TMP/alter_sem_congelar.sql"
RELOGIO_HOJE=2026-11-24 caso "(a) reprova alter sem frila.agora congelado antes da publicação" 1 \
  "início absoluto 2026-12-05, vence em 10 dias" "$TMP/alter_sem_congelar.sql"
{ echo 'begin;'; echo "$CONGELA"; echo "$PRESO"; pub_selecao; echo 'select * from finish();'; echo 'rollback;'; } > "$TMP/alter_na_ordem_certa.sql"
RELOGIO_HOJE=2026-11-24 caso "(a) aprova a ordem certa: begin, congela, alter, publicação, finish, rollback" 0 \
  "arquivo(s) prendem publicado_em ao relógio de teste" "$TMP/alter_na_ordem_certa.sql"

# (e) publicado_em na lista de colunas só isenta se o VALOR não depender do relógio real.
insert_com_publicado_em() {  # $1 = valor(es) de publicado_em (um por linha de VALUES), $2 = arquivo
  {
    echo 'begin;'
    echo 'select plan(1);'
    echo 'insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, modo, publicado_em)'
    echo "values $1;"
    echo 'select finish();'
    echo 'rollback;'
  } > "$2"
}
linha_vaga() { echo "(gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), '2026-12-05 18:00:00+00', '2026-12-05 23:00:00+00', 'selecao', $1)"; }
for valor in "now()" "default" "current_timestamp" "clock_timestamp()" "transaction_timestamp()" "now() - interval '2 days'" "'now'::timestamptz" "statement_timestamp()"; do
  insert_com_publicado_em "$(linha_vaga "$valor")" "$TMP/pub_relogio.sql"
  RELOGIO_HOJE=2026-11-24 caso "(e) reprova insert com publicado_em = $valor (depende do relógio real)" 1 \
    "início absoluto 2026-12-05, vence em 10 dias" "$TMP/pub_relogio.sql"
done
insert_com_publicado_em "$(linha_vaga "'2026-11-01 12:00:00+00'"), $(linha_vaga "now()")" "$TMP/pub_segunda_tupla.sql"
RELOGIO_HOJE=2026-11-24 caso "(e) reprova multi-linha se UMA tupla usa now() em publicado_em" 1 \
  "início absoluto 2026-12-05, vence em 10 dias" "$TMP/pub_segunda_tupla.sql"
insert_com_publicado_em "$(linha_vaga "'2026-11-01 12:00:00+00'"), $(linha_vaga "'2026-11-02 12:00:00+00'")" "$TMP/pub_literais.sql"
RELOGIO_HOJE=2026-11-24 caso "(e) aprova multi-linha com publicado_em literal fixo em todas as tuplas" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." "$TMP/pub_literais.sql"
{ echo 'begin;'; echo "$CONGELA"; echo 'insert into public.vaga (id, inicio_em, fim_em, modo, publicado_em)'
  echo "values (gen_random_uuid(), '2026-12-05 18:00:00+00', '2026-12-05 23:00:00+00', 'selecao', privado.agora());"
  echo 'rollback;'; } > "$TMP/pub_agora_congelado.sql"
RELOGIO_HOJE=2026-11-24 caso "(e) aprova publicado_em = privado.agora() com frila.agora congelado antes" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." "$TMP/pub_agora_congelado.sql"
sed '2d' "$TMP/pub_agora_congelado.sql" > "$TMP/pub_agora_solto.sql"
RELOGIO_HOJE=2026-11-24 caso "(e) reprova publicado_em = privado.agora() SEM congelar frila.agora" 1 \
  "início absoluto 2026-12-05, vence em 10 dias" "$TMP/pub_agora_solto.sql"

# (d) Modo e início têm de estar no MESMO statement: a seleção de outro statement não contamina.
RELOGIO_HOJE=2030-02-10 caso "(d) o 876 (modo urgencia na linha 279, seleção de outro statement na 269) sai 0" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "supabase/tests/876_publicar_escala.sql"
cat << 'SQL' > "$TMP/selecao_em_outro_statement.sql"
begin;
select plan(1);
select is((select modo from public.vaga where id = 'b6000000-0000-4000-8000-000000000011'), 'selecao', 'a seleção é desta vaga');
select public.publicar_vaga('b6000000-0000-4000-8000-000000000011', 'b6000000-0000-4000-8000-000000000012',
  '2026-12-05 18:00:00+00'::timestamptz, '2026-12-05 23:00:00+00'::timestamptz,
  'Local', '{}'::jsonb, 10000, 1, true, false, false, 'Resp', 'urgencia', gen_random_uuid());
select finish();
rollback;
SQL
RELOGIO_HOJE=2026-11-24 caso "(d) modo urgencia no statement do início, 'selecao' no statement de cima: aprova" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." "$TMP/selecao_em_outro_statement.sql"

# (b/c) Literal dentro de $$ ... $$ ou $tag$ ... $tag$ também entra na análise.
dollar() {  # $1 = tag ($$ ou $t$), $2 = arquivo
  {
    echo 'begin;'
    echo "$CONGELA"
    echo "select lives_ok($1"
    pub_selecao | sed 's/^select //;1s/^/select /'
    echo "$1, 'publica a seleção');"
    echo 'rollback;'
  } > "$2"
}
dollar '$$' "$TMP/dollar_simples.sql"
RELOGIO_HOJE=2026-11-24 caso "(b/c) reprova início fixo dentro de \$\$ ... \$\$ (controle com aspas simples também sai 1)" 1 \
  "início absoluto 2026-12-05, vence em 10 dias" "$TMP/dollar_simples.sql"
# shellcheck disable=SC2016  # $teste$ é a marca do Postgres, não uma variável
dollar '$teste$' "$TMP/dollar_tag.sql"
RELOGIO_HOJE=2026-11-24 caso "(b/c) reprova início fixo dentro de \$tag\$ ... \$tag\$" 1 \
  "início absoluto 2026-12-05, vence em 10 dias" "$TMP/dollar_tag.sql"
{ echo 'begin;'; echo 'select plan(1);'; echo "select lives_ok(format(\$\$ $(pub_selecao | tr '\n' ' ' | sed 's/%/%%/g') \$\$), 'monta com format');"; echo 'rollback;'; } > "$TMP/dollar_format.sql"
RELOGIO_HOJE=2026-11-24 caso "(b/c) reprova início fixo dentro de format(\$\$ ... \$\$, ...)" 1 \
  "início absoluto 2026-12-05, vence em 10 dias" "$TMP/dollar_format.sql"
# O 'select' do comentário e do $$ não pode desligar o léxico: comentário com aspas/$$ no meio não quebra a leitura.
{ echo 'begin;'; echo "-- não é string: it's \$\$ e /* sem fechar"; echo "/* outro ' comentário \$\$ */"; pub_selecao; echo 'rollback;'; } > "$TMP/comentario_com_aspas.sql"
RELOGIO_HOJE=2026-11-24 caso "comentário com aspa, \$\$ e /* não confunde o léxico: a publicação depois dele ainda reprova" 1 \
  "início absoluto 2026-12-05, vence em 10 dias" "$TMP/comentario_com_aspas.sql"

# (b/c) LIMITE CONHECIDO, fixado de propósito: helper e expressão montada ficam fora. O 530 ANTIGO
# (94f6478) passa a data na linha 143 a um helper (linhas 96-103), e a seleção vence em 03/05/2027:
# o gate NÃO pega, nem a 12 dias do vencimento. Este caso documenta o limite em vez de fingir cobertura;
# se um dia o gate passar a pegar, este caso falha e o limite some do topo do script junto.
git show 94f6478:supabase/tests/530_modo_selecao_recusas.sql > "$TMP/530_antigo.sql"
RELOGIO_HOJE=2027-04-20 caso "LIMITE CONHECIDO: o 530 antigo (data passada a helper) NÃO é pego, e o gate diz que a cobertura é parcial" 0 \
  "Cobertura parcial: cobre literal direto em insert/publicar_vaga; não cobre helper nem expressão montada." \
  "$TMP/530_antigo.sql"
RELOGIO_HOJE=2027-05-02 caso "LIMITE CONHECIDO: o 530 antigo também passa na véspera do vencimento (02/05/2027)" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." "$TMP/530_antigo.sql"
if "$PORTAO" --help | grep -qF "Cobertura parcial: cobre literal direto em insert/publicar_vaga; não cobre helper nem expressão montada."; then
  echo "  ✓ --help declara a cobertura parcial"
else
  echo "  ✗ --help não declara a cobertura parcial"
  falhas=$((falhas + 1))
fi
casos=$((casos + 1))

# ── 7. Rodada 2 do Lince Codex no #612 (B-111c, 24/11/2026) ────────────────────────────────────────
# (a) O alter tem de ser um STATEMENT de verdade: texto do alter dentro de string ou de dollar-quote
# (um SELECT que só devolve o texto) não prende nada. Controle do Lince: no 807 antigo, o texto entra
# antes da primeira publicação, depois do freeze que o arquivo já tem.
awk -v t="select '$PRESO';" '/^-- Casa 1 publica vaga no modo seleção/ && !d {print t; d=1} {print}' "$TMP/807_base.sql" > "$TMP/807_alter_em_string.sql"
grep -qF "select '$PRESO';" "$TMP/807_alter_em_string.sql" || { echo "  ✗ (a) o caso do alter em string não montou o arquivo"; falhas=$((falhas + 1)); }
RELOGIO_HOJE=2026-12-20 caso "(a/r2) reprova o 807 com o texto do alter num SELECT 'alter ...' (string) antes da publicação" 1 \
  "$FRASE_807" "$TMP/807_alter_em_string.sql"
awk -v t="select \$\$$PRESO\$\$;" '/^-- Casa 1 publica vaga no modo seleção/ && !d {print t; d=1} {print}' "$TMP/807_base.sql" > "$TMP/807_alter_em_dollar.sql"
grep -qF "select \$\$$PRESO\$\$;" "$TMP/807_alter_em_dollar.sql" || { echo "  ✗ (a) o caso do alter em dollar-quote não montou o arquivo"; falhas=$((falhas + 1)); }
RELOGIO_HOJE=2026-12-20 caso "(a/r2) reprova o 807 com o texto do alter dentro de \$\$ ... \$\$ antes da publicação" 1 \
  "$FRASE_807" "$TMP/807_alter_em_dollar.sql"
awk -v t="select pg_temp.como('c8070000-0000-4000-8000-000000000003', \$\$$PRESO\$\$);" '/^-- Casa 1 publica vaga no modo seleção/ && !d {print t; d=1} {print}' "$TMP/807_base.sql" > "$TMP/807_alter_em_argumento.sql"
RELOGIO_HOJE=2026-12-20 caso "(a/r2) reprova o 807 com o alter como argumento dollar-quoted de função" 1 \
  "$FRASE_807" "$TMP/807_alter_em_argumento.sql"
# E o statement de verdade, no mesmo ponto (antes da publicação, depois do freeze), continua prendendo.
awk -v t="$PRESO" '/^-- Casa 1 publica vaga no modo seleção/ && !d {print t; d=1} {print}' "$TMP/807_base.sql" > "$TMP/807_alter_real_no_mesmo_ponto.sql"
RELOGIO_HOJE=2026-12-20 caso "(a/r2) aprova o 807 com o alter de verdade (statement) no mesmo ponto" 0 \
  "arquivo(s) prendem publicado_em ao relógio de teste" "$TMP/807_alter_real_no_mesmo_ponto.sql"
# A palavra rollback/finish() só dentro de texto (string ou dollar-quote) não encerra a transação do arquivo:
# o alter de verdade que vem depois dela, antes da publicação, segue prendendo.
{ echo 'begin;'; echo "$CONGELA"; echo "select 'rollback; select * from finish();';"; echo 'select $$ rollback $$;'
  echo "$PRESO"; pub_selecao; echo 'select * from finish();'; echo 'rollback;'; } > "$TMP/rollback_so_em_texto.sql"
RELOGIO_HOJE=2026-11-24 caso "(a/r2) 'rollback' só dentro de string/\$\$ não encerra a transação: o alter depois dele ainda prende" 0 \
  "arquivo(s) prendem publicado_em ao relógio de teste" "$TMP/rollback_so_em_texto.sql"

# (b/c) Timestamp dollar-quoted: $$2027-01-15 18:00:00+00$$::timestamptz e a forma com tag ($ts$ ... $ts$).
# Controle do Lince: no 807 antigo, só as aspas dos dois timestamps (linhas 116 e 117) viram $$ ou $ts$.
sed "116,117s/'\\(2027-[^']*\\)'/\$\$\\1\$\$/" "$TMP/807_base.sql" > "$TMP/807_ts_dollar.sql"
sed "116,117s/'\\(2027-[^']*\\)'/\$ts\$\\1\$ts\$/" "$TMP/807_base.sql" > "$TMP/807_ts_tag.sql"
# shellcheck disable=SC2016  # $$ e $ts$ são marcas do Postgres, não variáveis
if ! { grep -qF '$$2027-01-15 18:00:00+00$$::timestamptz' "$TMP/807_ts_dollar.sql" \
       && grep -qF '$ts$2027-01-16 02:00:00+00$ts$::timestamptz' "$TMP/807_ts_tag.sql"; }; then
  echo "  ✗ (b/c) os casos de timestamp dollar-quoted não montaram os arquivos"
  falhas=$((falhas + 1))
fi
RELOGIO_HOJE=2026-12-20 caso "(b/c/r2) reprova o 807 antigo com os timestamps em \$\$2027-01-15 ...\$\$::timestamptz" 1 \
  "$FRASE_807" "$TMP/807_ts_dollar.sql"
RELOGIO_HOJE=2026-12-20 caso "(b/c/r2) reprova o 807 antigo com os timestamps em \$ts\$2027-01-15 ...\$ts\$::timestamptz" 1 \
  "início absoluto 2027-01-16, vence em 26 dias (2027-01-15)" "$TMP/807_ts_tag.sql"
sed "s/'\\(2026-12-05 [^']*\\)'/\$\$\\1\$\$/" "$TMP/selecao_data_fixa.sql" > "$TMP/selecao_data_dollar.sql"
RELOGIO_HOJE=2026-11-24 caso "(b/c/r2) reprova publicar_vaga de seleção com início \$\$2026-12-05 ...\$\$::timestamptz (SQL válido, nível de cima)" 1 \
  "início absoluto 2026-12-05, vence em 10 dias" "$TMP/selecao_data_dollar.sql"
RELOGIO_HOJE=2026-12-06 caso "(b/c/r2) timestamp dollar-quoted passado nunca falha" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." "$TMP/selecao_data_dollar.sql"

RELOGIO_HOJE=ontem caso "RELOGIO_HOJE inválido sai 2, não mediu" 2 \
  "RELOGIO_HOJE inválido ('ontem')" \
  "$TMP/selecao_data_fixa.sql"

# ── 4. Casos limite: pasta vazia ou inexistente (regra de portão: sai 2) ───────
mkdir -p "$TMP/pasta_vazia"
caso "rejeita pasta sem nenhum teste sql (sai 2, não mediu)" 2 \
  "nada a conferir, e isso não é verde" \
  "$TMP/pasta_vazia"

caso "rejeita pasta inexistente (sai 2, não mediu)" 2 \
  "nada a conferir, e isso não é verde" \
  "$TMP/pasta_que_nao_existe"

echo
if [ "$falhas" -gt 0 ]; then
  echo "$falhas de $casos casos falharam."
  exit 1
fi

echo "Todos os $casos casos do autoteste passaram."
exit 0
