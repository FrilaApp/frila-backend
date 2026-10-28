#!/usr/bin/env bash
# Teste automatizado das ferramentas SQL da operação (supabase/operacao/*.sql)
#
# Brief B-004 (b):
#   - supabase/operacao/consultar-ocorrencias.sql
#   - supabase/operacao/fechar-chamado-sem-email.sql
#   - supabase/operacao/moderar-conteudo.sql
#   - supabase/operacao/reativar-conta.sql
#   - supabase/operacao/suspender-conta.sql
#
# Cria fixtures controladas e isoladas, executa cada ferramenta via psql com as
# variáveis requeridas e valida os efeitos no banco. Ao final, limpa todas as fixtures.
#
# Uso:
#   ./scripts/teste-operacao-sql.sh          # Execução padrão dos testes
#   ./scripts/teste-operacao-sql.sh --mutar  # Prova de mutação (verifica que o teste pega alterações)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DIR_OPERACAO="${DIR_OPERACAO:-supabase/operacao}"
DB=${DB_CONTAINER:-supabase_db_frila-backend}

psql_cmd() {
  docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
}

psql_file() {
  local sql_file="$1"
  shift
  docker exec -i "$DB" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 "$@" -f - < "$sql_file"
}

uuid_gen() {
  python3 -c 'import uuid; print(uuid.uuid4())'
}

validar_inteiro() {
  local nome="$1" val="$2"
  [[ "$val" =~ ^[0-9]+$ ]] || { echo "✗ $nome: esperado inteiro, obteve '$val'" >&2; exit 1; }
}

# ── Modo de mutação ───────────────────────────────────────────────────────────
rodar_mutacao() {
  local descricao="$1"
  local tmp_dir="$2"
  local arquivo_rel="$3"
  local original="$4"
  local mutante="$5"
  local erro_esperado="$6"

  echo "▸ Testando mutação: $descricao"
  # Restaura cópia original limpa antes de aplicar a mutação na pasta temporária
  cp "supabase/operacao/$arquivo_rel" "$tmp_dir/operacao/$arquivo_rel"
  sed -i.tmp "s|$original|$mutante|g" "$tmp_dir/operacao/$arquivo_rel"
  rm -f "$tmp_dir/operacao/$arquivo_rel.tmp"

  local saida_mut codigo_mut
  set +e
  saida_mut=$(DIR_OPERACAO="$tmp_dir/operacao" "$0" --sem-mutar 2>&1)
  codigo_mut=$?
  set -e

  # Restaura a cópia para não contaminar o próximo teste de mutação
  cp "supabase/operacao/$arquivo_rel" "$tmp_dir/operacao/$arquivo_rel"

  if [ "$codigo_mut" -eq 0 ]; then
    echo "  ✗ Mutante sobreviveu! O teste deveria ter falhado." >&2
    exit 1
  fi

  if printf '%s\n' "$saida_mut" | grep -qF "$erro_esperado"; then
    echo "  ✓ Mutante morto com sucesso! Falha capturada esperada:"
    printf '%s\n' "$saida_mut" | grep -F "$erro_esperado" | sed 's/^/      /'
  else
    echo "  ✗ Teste falhou por motivo inesperado (esperava \"$erro_esperado\"):" >&2
    printf '%s\n' "$saida_mut" | sed 's/^/      /' >&2
    exit 1
  fi
}

executar_mutacoes() {
  echo "═══════════════════════════════════════════════════════════════════"
  echo "▸ Prova de mutação: quebrando filtros/lógicas intencionalmente"
  echo "═══════════════════════════════════════════════════════════════════"

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT INT TERM

  mkdir -p "$tmp_dir/operacao"
  cp -r supabase/operacao/* "$tmp_dir/operacao/"

  # Mutação 1: fechar-chamado-sem-email.sql alterando filtro de tipo
  rodar_mutacao \
    "fechar-chamado-sem-email.sql (tipo alterado de suporte para denuncia)" \
    "$tmp_dir" \
    "fechar-chamado-sem-email.sql" \
    "and tipo = 'suporte'" \
    "and tipo = 'denuncia'" \
    "fechar-chamado-sem-email.sql (por ID): chamado não foi marcado como resolvido"

  # Mutação 2: consultar-ocorrencias.sql alterando filtro de resolvidas
  rodar_mutacao \
    "consultar-ocorrencias.sql (filtra apenas ocorrências resolvidas)" \
    "$tmp_dir" \
    "consultar-ocorrencias.sql" \
    "where o.resolvido_em is null" \
    "where o.resolvido_em is not null" \
    "consultar-ocorrencias.sql: protocolo de teste não encontrado na listagem"

  # Mutação 3: suspender-conta.sql removendo chamada de suspensão
  rodar_mutacao \
    "suspender-conta.sql (ignora chamada de suspensão)" \
    "$tmp_dir" \
    "suspender-conta.sql" \
    "select privado.suspender(:'usuario_id'::uuid, :'motivo', :'operador_id'::uuid);" \
    "select null;" \
    "suspender-conta.sql: estado da conta não foi alterado para suspensa"

  # Mutação 4: moderar-conteudo.sql ignorando ação de ocultar
  rodar_mutacao \
    "moderar-conteudo.sql (ignora chamada de moderação)" \
    "$tmp_dir" \
    "moderar-conteudo.sql" \
    "select privado.operacao_moderar_conteudo(:'vaga_id'::uuid, :'acao', :'motivo', :'operador_id'::uuid);" \
    "select null;" \
    "moderar-conteudo.sql: vaga não foi ocultada"

  rm -rf "$tmp_dir"
  trap - EXIT INT TERM
  echo ""
  echo "✓ Todas as mutações foram capturadas pelos testes e os mutantes morreram."
  exit 0
}

if [ "${1:-}" = "--mutar" ]; then
  executar_mutacoes
fi

# ── Verificação do banco ──────────────────────────────────────────────────────
if ! psql_cmd -tAc 'select 1' >/dev/null 2>&1; then
  echo "✗ Não alcancei o banco no contêiner '$DB'. Suba com 'supabase start'." >&2
  exit 1
fi

CONFIGUROU_AGENDADOR=0
VALOR_PREVIO_AGENDADOR=""
CRIOU_FIXTURES=0

OPERADOR_ID=""
ALVO_ID=""
PUB_ID=""
ESTAB_ID=""
VAGA_ID=""
OC_SUPORTE_1=""
OC_SUPORTE_2=""
OC_DENUNCIA=""

limpar() {
  local code=$?
  if [ "$CRIOU_FIXTURES" -eq 1 ]; then
    psql_cmd -c "
      begin;
      set local privado.retencao = 'on';
      delete from privado.texto_da_vaga_ocultado where vaga_id = '$VAGA_ID';
      delete from privado.vaga_ocultada where vaga_id = '$VAGA_ID';
      delete from public.ocorrencia where autor_id in ('$OPERADOR_ID', '$ALVO_ID', '$PUB_ID')
         or usuario_id in ('$OPERADOR_ID', '$ALVO_ID', '$PUB_ID')
         or estabelecimento_id = '$ESTAB_ID'
         or id in ('$OC_SUPORTE_1', '$OC_SUPORTE_2', '$OC_DENUNCIA');
      delete from public.despacho where vaga_id = '$VAGA_ID';
      delete from public.posicao where vaga_id = '$VAGA_ID';
      delete from public.vaga where id = '$VAGA_ID';
      delete from public.membro_estabelecimento where estabelecimento_id = '$ESTAB_ID';
      delete from public.estabelecimento where id = '$ESTAB_ID';
      delete from public.notificacao where usuario_id in ('$OPERADOR_ID', '$ALVO_ID', '$PUB_ID');
      delete from privado.conta_equipe where usuario_id = '$OPERADOR_ID';
      delete from public.usuario where id in ('$OPERADOR_ID', '$ALVO_ID', '$PUB_ID');
      commit;
    " >/dev/null 2>&1 || true
  fi

  # Se configurou o agendador_secret, restaura o valor prévio ou faz reset
  if [ "$CONFIGUROU_AGENDADOR" -eq 1 ]; then
    if [ -n "$VALOR_PREVIO_AGENDADOR" ]; then
      docker exec -e PGPASSWORD=postgres -i "$DB" \
        psql -U supabase_admin -d postgres -X -q \
        -c "alter database postgres set frila.agendador_secret = '$VALOR_PREVIO_AGENDADOR';" >/dev/null 2>&1 || true
    else
      docker exec -e PGPASSWORD=postgres -i "$DB" \
        psql -U supabase_admin -d postgres -X -q \
        -c "alter database postgres reset frila.agendador_secret;" >/dev/null 2>&1 || true
    fi
  fi

  exit "$code"
}

# Trap ativo ANTES de qualquer alteração ou configuração
trap limpar EXIT INT TERM

# Salva valor prévio se houver e assegura agendador_secret se ausente
VALOR_PREVIO_AGENDADOR=$(psql_cmd -tAc "select nullif(current_setting('frila.agendador_secret', true), '');" 2>/dev/null || true)

if [ -z "$VALOR_PREVIO_AGENDADOR" ] && [ "$(psql_cmd -tAc "select not exists (select 1 from vault.decrypted_secrets where name = 'agendador_secret');")" = "t" ]; then
  docker exec -e PGPASSWORD=postgres -i "$DB" \
    psql -U supabase_admin -d postgres -X -q -v ON_ERROR_STOP=1 \
    -c "alter database postgres set frila.agendador_secret = 'segredo-teste-operacao';"
  CONFIGUROU_AGENDADOR=1
fi

# ── Geração de IDs e fixtures ─────────────────────────────────────────────────
OPERADOR_ID=$(uuid_gen)
ALVO_ID=$(uuid_gen)
PUB_ID=$(uuid_gen)
ESTAB_ID=$(uuid_gen)
VAGA_ID=$(uuid_gen)
CHAVE_VAGA=$(uuid_gen)
OC_SUPORTE_1=$(uuid_gen)
OC_SUPORTE_2=$(uuid_gen)
OC_DENUNCIA=$(uuid_gen)

PROTO_SUPORTE_2=$(printf '%s' "$OC_SUPORTE_2" | tr -d '-' | cut -c 1-8 | tr '[:lower:]' '[:upper:]')
PROTO_DENUNCIA=$(printf '%s' "$OC_DENUNCIA" | tr -d '-' | cut -c 1-8 | tr '[:lower:]' '[:upper:]')

# Gera um CNPJ válido aleatório
DOC=$(psql_cmd -tAc "
  select c from (select b || lpad(i::text, 2, '0') c
                   from (select lpad((floor(random() * 1e12))::bigint::text, 12, '0') b) s,
                        generate_series(0, 99) i) t
   where privado.documento_valido(c) limit 1;")
[ -n "$DOC" ] || { echo "✗ Não foi possível gerar CNPJ válido para o estabelecimento de teste." >&2; exit 1; }

RAND_SFX=$(python3 -c 'import secrets; print(secrets.token_hex(4))')

# Criação das fixtures no banco
psql_cmd -c "
  -- 1. Usuários
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
  values
    ('$OPERADOR_ID', 'contratante', 'Operador Teste Operacao', '+5561999990091', 'op-$RAND_SFX@frila.test', '1990-01-01', '2026-09-22', now(), 'ativa'),
    ('$ALVO_ID', 'profissional', 'Alvo Teste Operacao', '+5561999990092', 'alvo-$RAND_SFX@frila.test', '1995-05-10', '2026-09-22', now(), 'ativa'),
    ('$PUB_ID', 'contratante', 'Publicador Teste Operacao', '+5561999990093', 'pub-$RAND_SFX@frila.test', '1985-08-20', '2026-09-22', now(), 'ativa');

  insert into privado.conta_equipe (usuario_id) values ('$OPERADOR_ID');

  -- 2. Estabelecimento e membro
  insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
  values ('$ESTAB_ID', 'Estabelecimento Teste Operacao', '$DOC', 'food_service', 'SCS Quadra 1 Bloco B',
          'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto');

  insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
  values ('$ESTAB_ID', '$PUB_ID', 'administrador');

  -- 3. Vaga publicada
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
    responsavel_local, modo, estado, chave_cliente, publicado_por
  ) values (
    '$VAGA_ID', '$ESTAB_ID', (select id from public.funcao limit 1),
    now() + interval '2 days', now() + interval '2 days 6 hours',
    'Local Teste Operacao', 'POINT(-47.8825 -15.7942)'::extensions.geography,
    15000, 1, true, false, false, 'Gerente Teste', 'urgencia', 'publicada',
    '$CHAVE_VAGA', '$PUB_ID'
  );

  -- 4. Ocorrências iniciais
  insert into public.ocorrencia (id, tipo, autor_id, usuario_id, motivo, origem, criada_em)
  values
    ('$OC_SUPORTE_1', 'suporte', '$ALVO_ID', '$ALVO_ID', 'Chamado teste sem email 1', 'app', now()),
    ('$OC_SUPORTE_2', 'suporte', '$ALVO_ID', '$ALVO_ID', 'Chamado teste sem email 2', 'app', now());

  insert into public.ocorrencia (id, tipo, autor_id, estabelecimento_id, motivo, relato, origem, criada_em)
  values
    ('$OC_DENUNCIA', 'denuncia', '$ALVO_ID', '$ESTAB_ID', 'outro', 'Relato teste denuncia operacao', 'app', now());
" >/dev/null

CRIOU_FIXTURES=1

echo "▸ Executando testes das ferramentas SQL da operação..."

# ── Teste 1: consultar-ocorrencias.sql ────────────────────────────────────────
saida_consulta=$(psql_file "$DIR_OPERACAO/consultar-ocorrencias.sql")
if ! printf '%s\n' "$saida_consulta" | grep -qF "$PROTO_DENUNCIA"; then
  echo "✗ consultar-ocorrencias.sql: protocolo de teste não encontrado na listagem" >&2
  printf '%s\n' "$saida_consulta" >&2
  exit 1
fi
if ! printf '%s\n' "$saida_consulta" | grep -qF "Relato teste denuncia operacao"; then
  echo "✗ consultar-ocorrencias.sql: relato da ocorrência de teste não encontrado na listagem" >&2
  exit 1
fi
echo "  ✓ consultar-ocorrencias.sql: listou ocorrência aberta com protocolo $PROTO_DENUNCIA"

# ── Teste 2: fechar-chamado-sem-email.sql ─────────────────────────────────────
# Caso 2A: Fechar por ID com resultado default ('sem_email_recebido')
psql_file "$DIR_OPERACAO/fechar-chamado-sem-email.sql" \
  -v ocorrencia_id="$OC_SUPORTE_1" >/dev/null

res_1=$(psql_cmd -tAc "select resolvido_em is not null and resultado = 'sem_email_recebido' from public.ocorrencia where id = '$OC_SUPORTE_1';")
if [ "$res_1" != "t" ]; then
  echo "✗ fechar-chamado-sem-email.sql (por ID): chamado não foi marcado como resolvido com 'sem_email_recebido'" >&2
  exit 1
fi
echo "  ✓ fechar-chamado-sem-email.sql: fechou chamado por ocorrencia_id com resultado default"

# Caso 2B: Fechar por protocolo_curto com resultado customizado
psql_file "$DIR_OPERACAO/fechar-chamado-sem-email.sql" \
  -v protocolo_curto="$PROTO_SUPORTE_2" \
  -v resultado="atendido_direto" >/dev/null

res_2=$(psql_cmd -tAc "select resolvido_em is not null and resultado = 'atendido_direto' from public.ocorrencia where id = '$OC_SUPORTE_2';")
if [ "$res_2" != "t" ]; then
  echo "✗ fechar-chamado-sem-email.sql (por protocolo_curto): chamado não foi marcado como resolvido com 'atendido_direto'" >&2
  exit 1
fi
echo "  ✓ fechar-chamado-sem-email.sql: fechou chamado por protocolo_curto com resultado customizado"

# ── Teste 3: suspender-conta.sql ──────────────────────────────────────────────
psql_file "$DIR_OPERACAO/suspender-conta.sql" \
  -v usuario_id="$ALVO_ID" \
  -v motivo="Violação confirmada das regras operacionais" \
  -v operador_id="$OPERADOR_ID" >/dev/null

estado_susp=$(psql_cmd -tAc "select estado from public.usuario where id = '$ALVO_ID';")
if [ "$estado_susp" != "suspensa" ]; then
  echo "✗ suspender-conta.sql: estado da conta não foi alterado para suspensa (veio '$estado_susp')" >&2
  exit 1
fi

oc_susp=$(psql_cmd -tAc "select count(*) from public.ocorrencia where usuario_id = '$ALVO_ID' and tipo = 'suspensao' and autor_id = '$OPERADOR_ID';")
validar_inteiro "oc_susp" "$oc_susp"
if [ "$oc_susp" -lt 1 ]; then
  echo "✗ suspender-conta.sql: ocorrência de suspensão não foi registrada no banco" >&2
  exit 1
fi
echo "  ✓ suspender-conta.sql: suspendeu conta e gravou ocorrência de suspensao"

# ── Teste 4: reativar-conta.sql ───────────────────────────────────────────────
psql_file "$DIR_OPERACAO/reativar-conta.sql" \
  -v usuario_id="$ALVO_ID" \
  -v justificativa="Contestação acolhida após envio de comprovação" \
  -v operador_id="$OPERADOR_ID" >/dev/null

estado_reativ=$(psql_cmd -tAc "select estado from public.usuario where id = '$ALVO_ID';")
if [ "$estado_reativ" != "ativa" ]; then
  echo "✗ reativar-conta.sql: estado da conta não foi alterado para ativa (veio '$estado_reativ')" >&2
  exit 1
fi

oc_reativ=$(psql_cmd -tAc "select count(*) from public.ocorrencia where usuario_id = '$ALVO_ID' and tipo = 'suporte' and autor_id = '$OPERADOR_ID' and motivo like 'Reativação de conta:%';")
validar_inteiro "oc_reativ" "$oc_reativ"
if [ "$oc_reativ" -lt 1 ]; then
  echo "✗ reativar-conta.sql: ocorrência de reativação não foi registrada no banco" >&2
  exit 1
fi
echo "  ✓ reativar-conta.sql: reativou conta e gravou ocorrência de suporte"

# ── Teste 5: moderar-conteudo.sql ─────────────────────────────────────────────
# 5A: Ocultar vaga
psql_file "$DIR_OPERACAO/moderar-conteudo.sql" \
  -v vaga_id="$VAGA_ID" \
  -v acao="ocultar" \
  -v motivo="Termo ofensivo denunciado" \
  -v operador_id="$OPERADOR_ID" >/dev/null

vaga_oculta=$(psql_cmd -tAc "select privado.vaga_oculta('$VAGA_ID'::uuid);")
if [ "$vaga_oculta" != "t" ]; then
  echo "✗ moderar-conteudo.sql: vaga não foi ocultada (privado.vaga_oculta retornou '$vaga_oculta')" >&2
  exit 1
fi

oc_ocultar=$(psql_cmd -tAc "select count(*) from public.ocorrencia where estabelecimento_id = '$ESTAB_ID' and autor_id = '$OPERADOR_ID' and motivo like 'Moderação Diretriz 1.2:%';")
validar_inteiro "oc_ocultar" "$oc_ocultar"
if [ "$oc_ocultar" -lt 1 ]; then
  echo "✗ moderar-conteudo.sql: ocorrência de ocultação não foi registrada" >&2
  exit 1
fi
echo "  ✓ moderar-conteudo.sql: ocultou vaga denunciada e gravou ocorrência"

# 5B: Reexibir vaga
psql_file "$DIR_OPERACAO/moderar-conteudo.sql" \
  -v vaga_id="$VAGA_ID" \
  -v acao="reexibir" \
  -v motivo="Denúncia improcedente após análise minuciosa" \
  -v operador_id="$OPERADOR_ID" >/dev/null

vaga_reexibida=$(psql_cmd -tAc "select privado.vaga_oculta('$VAGA_ID'::uuid);")
if [ "$vaga_reexibida" != "f" ]; then
  echo "✗ moderar-conteudo.sql: vaga continua oculta após reexibir (privado.vaga_oculta retornou '$vaga_reexibida')" >&2
  exit 1
fi

oc_reexibir=$(psql_cmd -tAc "select count(*) from public.ocorrencia where estabelecimento_id = '$ESTAB_ID' and autor_id = '$OPERADOR_ID' and motivo like 'Moderação Reexibir:%';")
validar_inteiro "oc_reexibir" "$oc_reexibir"
if [ "$oc_reexibir" -lt 1 ]; then
  echo "✗ moderar-conteudo.sql: ocorrência de reexibição não foi registrada" >&2
  exit 1
fi
echo "  ✓ moderar-conteudo.sql: reexibiu vaga e gravou ocorrência"

echo "✓ Todos os 5 scripts de supabase/operacao/ foram testados com sucesso."
