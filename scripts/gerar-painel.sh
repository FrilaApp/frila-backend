#!/usr/bin/env bash
# scripts/gerar-painel.sh
# Gera uma página HTML autocontida com as métricas do piloto do Frila para a leitura semanal.
#
# Lê as 7 views do schema metrica.* via psql:
#   - metrica.north_star_semanal
#   - metrica.funil_geral
#   - metrica.funil_por_dia
#   - metrica.funil_por_estabelecimento
#   - metrica.funil_por_vaga
#   - metrica.funil_confirmacoes
#   - metrica.eventos_app_por_dia
#
# Uso:
#   ./scripts/gerar-painel.sh                      # Imprime o HTML na saída padrão
#   ./scripts/gerar-painel.sh -o painel.html      # Salva o HTML em arquivo
#   ./scripts/gerar-painel.sh --teste             # Valida colunas das views e testa geração
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"
ARQUIVO_SAIDA=""
MODO_TESTE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--saida)
      ARQUIVO_SAIDA="$2"
      shift 2
      ;;
    --teste|--validar-colunas)
      MODO_TESTE=1
      shift
      ;;
    -h|--ajuda|--help)
      echo "Uso: $0 [-o ARQUIVO] [--teste]"
      echo ""
      echo "Opções:"
      echo "  -o, --saida ARQUIVO   Caminho do arquivo HTML a ser gerado"
      echo "  --teste               Valida colunas de cada view do schema metrica.* e testa integridade"
      echo "  -h, --ajuda           Exibe esta mensagem de ajuda"
      exit 0
      ;;
    *)
      echo "Opção inválida: $1" >&2
      exit 1
      ;;
  esac
done

exec_psql_quiet() {
  local query="$1"
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "$query"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DB_CONTAINER}$"; then
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 -c "$query"
  else
    psql -h localhost -p 54322 -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 -c "$query"
  fi
}

# 1. Consulta o schema das colunas reais de todas as views em metrica.*
SQL_COLUNAS="
select json_object_agg(table_name, colunas)
from (
  select table_name, json_agg(column_name order by ordinal_position) as colunas
  from information_schema.columns
  where table_schema = 'metrica'
  group by table_name
) s;
"

COLUNAS_JSON=$(exec_psql_quiet "$SQL_COLUNAS")

# 2. Consulta os dados de todas as 7 views em metrica.* em formato JSON
SQL_DADOS="
select json_build_object(
  'north_star_semanal', (select coalesce(json_agg(t), '[]'::json) from metrica.north_star_semanal t),
  'funil_geral', (select coalesce(json_agg(t), '[]'::json) from metrica.funil_geral t),
  'funil_por_dia', (select coalesce(json_agg(t), '[]'::json) from metrica.funil_por_dia t),
  'funil_por_estabelecimento', (select coalesce(json_agg(t), '[]'::json) from metrica.funil_por_estabelecimento t),
  'funil_por_vaga', (select coalesce(json_agg(t), '[]'::json) from metrica.funil_por_vaga t),
  'funil_confirmacoes', (select coalesce(json_agg(t), '[]'::json) from metrica.funil_confirmacoes t),
  'eventos_app_por_dia', (select coalesce(json_agg(t), '[]'::json) from metrica.eventos_app_por_dia t)
)::text;
"

DADOS_JSON=$(exec_psql_quiet "$SQL_DADOS")

# 3. Processamento em Python: validação estrita de colunas e renderização do HTML autocontido
HTML_GERADO=$(python3 - "$COLUNAS_JSON" "$DADOS_JSON" "$MODO_TESTE" <<'PY'
import html
import json
import sys
from datetime import datetime, timezone

colunas_raw = sys.argv[1].strip()
dados_raw = sys.argv[2].strip()
modo_teste = sys.argv[3] == "1"

try:
    schema_atual = json.loads(colunas_raw)
except Exception as e:
    print(f"Erro ao analisar colunas retornadas do Postgres: {e}\nRaw: {colunas_raw}", file=sys.stderr)
    sys.exit(1)

try:
    dados = json.loads(dados_raw)
except Exception as e:
    print(f"Erro ao analisar dados retornados das views metrica.*: {e}\nRaw: {dados_raw}", file=sys.stderr)
    sys.exit(1)

# Schema contratual esperado das 7 views do schema metrica.*
COLUNAS_ESPERADAS = {
    "north_star_semanal": [
        "semana_inicio",
        "turnos_concluidos_com_presenca_verificada"
    ],
    "funil_geral": [
        "vagas_publicadas",
        "notificacoes_enviadas",
        "candidaturas",
        "confirmacoes",
        "checkins",
        "avaliacoes",
        "tempo_mediano_confirmacao",
        "tempo_mediano_confirmacao_segundos"
    ],
    "funil_por_dia": [
        "dia",
        "vagas_publicadas",
        "notificacoes_enviadas",
        "candidaturas",
        "confirmacoes",
        "checkins",
        "avaliacoes",
        "tempo_mediano_confirmacao",
        "tempo_mediano_confirmacao_segundos"
    ],
    "funil_por_estabelecimento": [
        "estabelecimento_id",
        "estabelecimento_nome",
        "vagas_publicadas",
        "notificacoes_enviadas",
        "candidaturas",
        "confirmacoes",
        "checkins",
        "avaliacoes",
        "tempo_mediano_confirmacao",
        "tempo_mediano_confirmacao_segundos"
    ],
    "funil_por_vaga": [
        "vaga_id",
        "estabelecimento_id",
        "estabelecimento_nome",
        "dia",
        "publicado_em",
        "posicoes_ofertadas",
        "notificacoes_enviadas",
        "candidaturas",
        "confirmacoes",
        "checkins",
        "avaliacoes"
    ],
    "funil_confirmacoes": [
        "posicao_id",
        "vaga_id",
        "estabelecimento_id",
        "dia",
        "publicado_em",
        "confirmado_em",
        "duracao_confirmacao_segundos"
    ],
    "eventos_app_por_dia": [
        "dia",
        "evento",
        "total"
    ]
}

# Validação estrita de cada view e de cada coluna
erros = []
for view_nome, colunas_esperadas in COLUNAS_ESPERADAS.items():
    if view_nome not in schema_atual:
        erros.append(f"View 'metrica.{view_nome}' não encontrada no banco de dados!")
        continue

    colunas_reais = schema_atual[view_nome]
    faltantes = [c for c in colunas_esperadas if c not in colunas_reais]
    if faltantes:
        erros.append(f"View 'metrica.{view_nome}' com colunas ausentes: {faltantes}")

if erros:
    print("✗ ERRO DE CONTRATO DE VIEWS:", file=sys.stderr)
    for err in erros:
        print(f"  - {err}", file=sys.stderr)
    sys.exit(1)

if modo_teste:
    print("✓ Schema das 7 views de metrica.* validado com sucesso!")
    for v_nome, cols in COLUNAS_ESPERADAS.items():
        print(f"  ✓ metrica.{v_nome} ({len(cols)} colunas)")

# Função auxiliar para gerar tabela HTML estilizada
def render_table(headers, rows, empty_msg="Nenhum registro encontrado."):
    if not rows:
        return f'<div class="empty-state">{empty_msg}</div>'
    
    th_html = "".join(f"<th>{html.escape(str(h))}</th>" for h in headers)
    tr_list = []
    for row in rows:
        td_html = "".join(f"<td>{html.escape(str(cell if cell is not None else '—'))}</td>" for cell in row)
        tr_list.append(f"<tr>{td_html}</tr>")
    
    tbody_html = "".join(tr_list)
    return f"""<div class="table-container">
  <table>
    <thead><tr>{th_html}</tr></thead>
    <tbody>{tbody_html}</tbody>
  </table>
</div>"""

# Extrai destaques do resumo geral
geral = (dados.get("funil_geral") or [{}])[0]
north_star = (dados.get("north_star_semanal") or [{}])[0]

vagas_pub = geral.get("vagas_publicadas", 0)
notifs_env = geral.get("notificacoes_enviadas", 0)
cand = geral.get("candidaturas", 0)
conf = geral.get("confirmacoes", 0)
checkins = geral.get("checkins", 0)
aval = geral.get("avaliacoes", 0)
tempo_conf = geral.get("tempo_mediano_confirmacao") or "—"
ns_turnos = north_star.get("turnos_concluidos_com_presenca_verificada", 0)

data_geracao = datetime.now(timezone.utc).strftime("%d/%m/%Y às %H:%M:%S UTC")

# 1. North Star
ns_headers = ["Início da Semana", "Turnos Concluídos (Presença Verificada)"]
ns_rows = [[r.get("semana_inicio"), r.get("turnos_concluidos_com_presenca_verificada")] for r in dados.get("north_star_semanal", [])]
ns_table = render_table(ns_headers, ns_rows)

# 2. Funil Geral
fg_headers = ["Vagas Publicadas", "Notificações", "Candidaturas", "Confirmações", "Check-ins", "Avaliações", "Tempo Mediano (Interval)", "Tempo Mediano (Segundos)"]
fg_rows = [[
    r.get("vagas_publicadas"),
    r.get("notificacoes_enviadas"),
    r.get("candidaturas"),
    r.get("confirmacoes"),
    r.get("checkins"),
    r.get("avaliacoes"),
    r.get("tempo_mediano_confirmacao"),
    r.get("tempo_mediano_confirmacao_segundos")
] for r in dados.get("funil_geral", [])]
fg_table = render_table(fg_headers, fg_rows)

# 3. Funil por Dia
fd_headers = ["Dia", "Vagas", "Notificações", "Candidaturas", "Confirmações", "Check-ins", "Avaliações", "Tempo Mediano"]
fd_rows = [[
    r.get("dia"),
    r.get("vagas_publicadas"),
    r.get("notificacoes_enviadas"),
    r.get("candidaturas"),
    r.get("confirmacoes"),
    r.get("checkins"),
    r.get("avaliacoes"),
    r.get("tempo_mediano_confirmacao")
] for r in dados.get("funil_por_dia", [])]
fd_table = render_table(fd_headers, fd_rows)

# 4. Funil por Estabelecimento
fe_headers = ["Estabelecimento", "Vagas", "Notificações", "Candidaturas", "Confirmações", "Check-ins", "Avaliações", "Tempo Mediano"]
fe_rows = [[
    r.get("estabelecimento_nome") or r.get("estabelecimento_id"),
    r.get("vagas_publicadas"),
    r.get("notificacoes_enviadas"),
    r.get("candidaturas"),
    r.get("confirmacoes"),
    r.get("checkins"),
    r.get("avaliacoes"),
    r.get("tempo_mediano_confirmacao")
] for r in dados.get("funil_por_estabelecimento", [])]
fe_table = render_table(fe_headers, fe_rows)

# 5. Funil por Vaga
fv_headers = ["Vaga ID", "Estabelecimento", "Dia", "Ofertadas", "Notificações", "Candidaturas", "Confirmações", "Check-ins", "Avaliações"]
fv_rows = [[
    r.get("vaga_id"),
    r.get("estabelecimento_nome"),
    r.get("dia"),
    r.get("posicoes_ofertadas"),
    r.get("notificacoes_enviadas"),
    r.get("candidaturas"),
    r.get("confirmacoes"),
    r.get("checkins"),
    r.get("avaliacoes")
] for r in dados.get("funil_por_vaga", [])]
fv_table = render_table(fv_headers, fv_rows)

# 6. Tempos de Confirmação
fc_headers = ["Posição ID", "Vaga ID", "Dia", "Publicado Em", "Confirmado Em", "Duração (s)"]
fc_rows = [[
    r.get("posicao_id"),
    r.get("vaga_id"),
    r.get("dia"),
    r.get("publicado_em"),
    r.get("confirmado_em"),
    f"{float(r.get('duracao_confirmacao_segundos')):.2f}" if r.get("duracao_confirmacao_segundos") is not None else "—"
] for r in dados.get("funil_confirmacoes", [])]
fc_table = render_table(fc_headers, fc_rows)

# 7. Eventos do App por Dia
ea_headers = ["Dia", "Evento", "Total de Ocorrências"]
ea_rows = [[r.get("dia"), r.get("evento"), r.get("total")] for r in dados.get("eventos_app_por_dia", [])]
ea_table = render_table(ea_headers, ea_rows, empty_msg="Nenhum evento registrado ainda na telemetria (exclui contas de teste/equipe).")

html_doc = f"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Frila · Painel de Métricas do Piloto</title>
  <style>
    :root {{
      --cor-fundo: #0d1117;
      --cor-superficie: #161b22;
      --cor-borda: #30363d;
      --cor-texto: #c9d1d9;
      --cor-texto-forte: #f0f6fc;
      --cor-texto-fraco: #8b949e;
      --cor-primaria: #f77f00;
      --cor-destaque: #2ea043;
      --cor-aviso: #d29922;
      --cor-info: #58a6ff;
    }}
    * {{
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }}
    body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background-color: var(--cor-fundo);
      color: var(--cor-texto);
      line-height: 1.5;
      padding: 24px;
    }}
    header {{
      background: var(--cor-superficie);
      border: 1px solid var(--cor-borda);
      border-radius: 8px;
      padding: 24px;
      margin-bottom: 24px;
    }}
    .marca-topo {{
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 12px;
      flex-wrap: wrap;
      gap: 8px;
    }}
    .badge {{
      background: rgba(247, 127, 0, 0.15);
      color: var(--cor-primaria);
      padding: 4px 12px;
      border-radius: 12px;
      font-size: 0.85rem;
      font-weight: 600;
      letter-spacing: 0.5px;
      border: 1px solid rgba(247, 127, 0, 0.3);
    }}
    h1 {{
      color: var(--cor-texto-forte);
      font-size: 1.8rem;
      font-weight: 700;
      margin-bottom: 6px;
    }}
    p.subtitulo {{
      color: var(--cor-texto-fraco);
      font-size: 0.95rem;
    }}
    .cards-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
      gap: 16px;
      margin-bottom: 28px;
    }}
    .card {{
      background: var(--cor-superficie);
      border: 1px solid var(--cor-borda);
      border-radius: 8px;
      padding: 16px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
    }}
    .card-label {{
      color: var(--cor-texto-fraco);
      font-size: 0.8rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin-bottom: 8px;
    }}
    .card-valor {{
      color: var(--cor-texto-forte);
      font-size: 1.8rem;
      font-weight: 700;
    }}
    .card-destaque {{
      border-color: rgba(46, 160, 67, 0.4);
      background: linear-gradient(180deg, rgba(46, 160, 67, 0.08) 0%, var(--cor-superficie) 100%);
    }}
    .card-destaque .card-valor {{
      color: var(--cor-destaque);
    }}
    section {{
      background: var(--cor-superficie);
      border: 1px solid var(--cor-borda);
      border-radius: 8px;
      padding: 20px;
      margin-bottom: 24px;
    }}
    section h2 {{
      color: var(--cor-texto-forte);
      font-size: 1.25rem;
      font-weight: 600;
      margin-bottom: 4px;
    }}
    section p.desc {{
      color: var(--cor-texto-fraco);
      font-size: 0.85rem;
      margin-bottom: 16px;
    }}
    .table-container {{
      overflow-x: auto;
      border: 1px solid var(--cor-borda);
      border-radius: 6px;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      font-size: 0.9rem;
      text-align: left;
    }}
    th {{
      background: #21262d;
      color: var(--cor-texto-forte);
      padding: 10px 14px;
      font-weight: 600;
      border-bottom: 1px solid var(--cor-borda);
      white-space: nowrap;
    }}
    td {{
      padding: 10px 14px;
      border-bottom: 1px solid var(--cor-borda);
      color: var(--cor-texto);
      white-space: nowrap;
    }}
    tr:last-child td {{
      border-bottom: none;
    }}
    tr:hover td {{
      background: rgba(255, 255, 255, 0.02);
    }}
    .empty-state {{
      padding: 24px;
      text-align: center;
      color: var(--cor-texto-fraco);
      font-size: 0.9rem;
      border: 1px dashed var(--cor-borda);
      border-radius: 6px;
    }}
    footer {{
      margin-top: 40px;
      text-align: center;
      color: var(--cor-texto-fraco);
      font-size: 0.8rem;
      padding: 16px;
    }}
  </style>
</head>
<body>
  <header>
    <div class="marca-topo">
      <span class="badge">FRILA · PILOTO BRASÍLIA</span>
      <span style="color: var(--cor-texto-fraco); font-size: 0.85rem;">Gerado em {data_geracao}</span>
    </div>
    <h1>Painel de Métricas do Piloto</h1>
    <p class="subtitulo">Leitura semanal do funil de conversão e North Star Metric (exclui contas de demonstração e equipe Frila)</p>
  </header>

  <div class="cards-grid">
    <div class="card card-destaque">
      <div class="card-label">North Star (Semanal)</div>
      <div class="card-valor">{ns_turnos}</div>
    </div>
    <div class="card">
      <div class="card-label">Vagas Publicadas</div>
      <div class="card-valor">{vagas_pub}</div>
    </div>
    <div class="card">
      <div class="card-label">Notificações</div>
      <div class="card-valor">{notifs_env}</div>
    </div>
    <div class="card">
      <div class="card-label">Candidaturas</div>
      <div class="card-valor">{cand}</div>
    </div>
    <div class="card">
      <div class="card-label">Confirmações</div>
      <div class="card-valor">{conf}</div>
    </div>
    <div class="card">
      <div class="card-label">Check-ins Verificados</div>
      <div class="card-valor">{checkins}</div>
    </div>
    <div class="card">
      <div class="card-label">Avaliações</div>
      <div class="card-valor">{aval}</div>
    </div>
    <div class="card">
      <div class="card-label">Tempo Confirmação</div>
      <div class="card-valor" style="font-size: 1.3rem;">{tempo_conf}</div>
    </div>
  </div>

  <section>
    <h2>1. North Star Metric Semanal (metrica.north_star_semanal)</h2>
    <p class="desc">Turnos concluídos (posicao.estado = 'cumprida') com presença efetivamente verificada por semana (início na segunda-feira).</p>
    {ns_table}
  </section>

  <section>
    <h2>2. Resumo Geral do Funil (metrica.funil_geral)</h2>
    <p class="desc">Totais consolidados do funil de conversão: publicar → notificar → candidatar → confirmar → check-in → avaliar.</p>
    {fg_table}
  </section>

  <section>
    <h2>3. Funil do Piloto por Dia (metrica.funil_por_dia)</h2>
    <p class="desc">Volume e tempos medianos de confirmação agrupados pela data de publicação da vaga (fuso America/Sao_Paulo).</p>
    {fd_table}
  </section>

  <section>
    <h2>4. Funil por Estabelecimento (metrica.funil_por_estabelecimento)</h2>
    <p class="desc">Desempenho de conversão segmentado por estabelecimento do piloto.</p>
    {fe_table}
  </section>

  <section>
    <h2>5. Detalhamento por Vaga (metrica.funil_por_vaga)</h2>
    <p class="desc">Base detalhada de conversão por vaga individual.</p>
    {fv_table}
  </section>

  <section>
    <h2>6. Tempos de Confirmação (metrica.funil_confirmacoes)</h2>
    <p class="desc">Duração em segundos entre a publicação da vaga e a confirmação de cada posição preenchida.</p>
    {fc_table}
  </section>

  <section>
    <h2>7. Telemetria de Eventos do App por Dia (metrica.eventos_app_por_dia)</h2>
    <p class="desc">Volume de eventos operacionais emitidos pelos aplicativos (iOS e Android).</p>
    {ea_table}
  </section>

  <footer>
    Frila · Painel de Métricas do Piloto · Fonte: Schema metrica.* (service_role) · Sem JS externo
  </footer>
</body>
</html>"""

print(html_doc)
PY
)

if [ -n "$ARQUIVO_SAIDA" ]; then
  mkdir -p "$(dirname "$ARQUIVO_SAIDA")"
  printf '%s\n' "$HTML_GERADO" > "$ARQUIVO_SAIDA"
  echo "✓ Painel gerado com sucesso em: $ARQUIVO_SAIDA"
elif [ "$MODO_TESTE" -eq 1 ]; then
  echo "✓ Teste do gerador concluído com sucesso: HTML válido gerado."
else
  printf '%s\n' "$HTML_GERADO"
fi
