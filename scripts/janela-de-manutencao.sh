#!/usr/bin/env bash
# Recusa publicar no frila-prod dentro da janela proibida da RNF12: de quinta a domingo, das
# 16h às 2h do dia seguinte, no horário de São Paulo. É quando os turnos acontecem, e uma
# migração que trava tabela ou uma Edge Function que sobe quebrada derruba o check-in de
# quem está trabalhando.
#
# O fim da janela conta no dia seguinte: sexta à 1h ainda é a noite de quinta, e segunda à
# 1h30 ainda é a noite de domingo.
#
# Uso:  ./scripts/janela-de-manutencao.sh
#       FRILA_AGORA="2026-10-02 20:00" ./scripts/janela-de-manutencao.sh   (autoteste)
#
# Saída: 0 fora da janela, 1 dentro dela, 2 quando não conseguiu ler a hora.
set -uo pipefail

python3 - <<'PY'
import os, sys
from datetime import datetime
from zoneinfo import ZoneInfo

SP = ZoneInfo("America/Sao_Paulo")
texto = os.environ.get("FRILA_AGORA", "").strip()
try:
    agora = (datetime.strptime(texto, "%Y-%m-%d %H:%M").replace(tzinfo=SP)
             if texto else datetime.now(SP))
except ValueError:
    print(f"✗ não medi: FRILA_AGORA={texto!r} não está no formato AAAA-MM-DD HH:MM")
    sys.exit(2)

DIAS = ["segunda", "terça", "quarta", "quinta", "sexta", "sábado", "domingo"]
dia = agora.weekday()  # 0 = segunda
# Noite que começa hoje (quinta a domingo, depois das 16h) ou madrugada que termina uma
# noite de quinta a domingo (sexta a segunda, antes das 2h).
bloqueado = (dia in (3, 4, 5, 6) and agora.hour >= 16) or \
            (dia in (4, 5, 6, 0) and agora.hour < 2)

quando = f"{DIAS[dia]}, {agora:%d/%m %H:%M} em São Paulo"
if bloqueado:
    print(f"✗ {quando}: dentro da janela proibida (quinta a domingo, das 16h às 2h, RNF12).")
    print("  Publique fora dela, ou rode o workflow de novo depois das 2h.")
    sys.exit(1)
print(f"✓ {quando}: fora da janela proibida.")
PY
