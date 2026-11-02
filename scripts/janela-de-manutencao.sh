#!/usr/bin/env bash
# Recusa publicar no frila-prod dentro da janela proibida da RNF12: de quinta a domingo, das
# 16h às 2h do dia seguinte, no horário de São Paulo. É quando os turnos acontecem, e uma
# migração que trava tabela ou uma Edge Function que sobe quebrada derruba o check-in de
# quem está trabalhando.
#
# O fim da janela conta no dia seguinte: sexta à 1h ainda é a noite de quinta, e segunda à
# 1h30 ainda é a noite de domingo.
#
# Parâmetros opcionais por variáveis de ambiente:
#   FRILA_AGORA="AAAA-MM-DD HH:MM"  (simula o instante atual em São Paulo para autoteste)
#   FRILA_MARGEM_MIN="30"           (margem de término em minutos; padrão 0). Quando definida,
#                                   também recusa se agora + margem cair dentro da janela.
#
# Uso:  ./scripts/janela-de-manutencao.sh
#       FRILA_AGORA="2026-10-02 20:00" ./scripts/janela-de-manutencao.sh   (autoteste)
#       FRILA_AGORA="2026-10-01 15:40" FRILA_MARGEM_MIN="30" ./scripts/janela-de-manutencao.sh
#
# Saída: 0 fora da janela, 1 dentro dela, 2 quando não conseguiu ler a hora ou a margem.
set -uo pipefail

python3 - <<'PY'
import os, sys
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

SP = ZoneInfo("America/Sao_Paulo")
texto = os.environ.get("FRILA_AGORA", "").strip()
try:
    agora = (datetime.strptime(texto, "%Y-%m-%d %H:%M").replace(tzinfo=SP)
             if texto else datetime.now(SP))
except ValueError:
    print(f"✗ não medi: FRILA_AGORA={texto!r} não está no formato AAAA-MM-DD HH:MM")
    sys.exit(2)

margem_texto = os.environ.get("FRILA_MARGEM_MIN", "0").strip()
try:
    margem_min = int(margem_texto) if margem_texto else 0
    if margem_min < 0:
        raise ValueError
except ValueError:
    print(f"✗ não medi: FRILA_MARGEM_MIN={margem_texto!r} deve ser um inteiro maior ou igual a zero")
    sys.exit(2)

DIAS = ["segunda", "terça", "quarta", "quinta", "sexta", "sábado", "domingo"]

def esta_na_janela(dt):
    d = dt.weekday()  # 0 = segunda
    # Noite que começa hoje (quinta a domingo, depois das 16h) ou madrugada que termina uma
    # noite de quinta a domingo (sexta a segunda, antes das 2h).
    return (d in (3, 4, 5, 6) and dt.hour >= 16) or \
           (d in (4, 5, 6, 0) and dt.hour < 2)

dia = agora.weekday()
quando = f"{DIAS[dia]}, {agora:%d/%m %H:%M} em São Paulo"

if esta_na_janela(agora):
    print(f"✗ {quando}: dentro da janela proibida (quinta a domingo, das 16h às 2h, RNF12).")
    print("  Publique fora dela, ou rode o workflow de novo depois das 2h.")
    sys.exit(1)

if margem_min > 0:
    termino = agora + timedelta(minutes=margem_min)
    if esta_na_janela(termino):
        dia_ter = termino.weekday()
        quando_ter = f"{DIAS[dia_ter]}, {termino:%d/%m %H:%M}"
        print(f"✗ {quando}: término previsto às {quando_ter} (margem {margem_min} min) cai na janela proibida da RNF12.")
        print("  Inicie antes ou aguarde a liberação após as 2h.")
        sys.exit(1)

msg_margem = f" (margem de término: {margem_min} min OK)" if margem_min > 0 else ""
print(f"✓ {quando}: fora da janela proibida{msg_margem}.")
PY
