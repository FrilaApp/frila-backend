#!/usr/bin/env bash
# Recusa testes pgTAP com bomba-relógio de relógio (datas absolutas em vaga/turno sem
# congelar frila.agora antes de ler o relógio).
#
# Contexto: em 02/10 o teste 250 falhou após a meia-noite porque criava vagas em 02/10 18h
# e chamava candidatar() antes do set_config('frila.agora'). Em 04/10 o teste 280 falhou
# exatamente pelo mesmo motivo (vagas em 03/10 18h, candidatar na linha 130 e set_config
# apenas na linha 150). A partir da virada do relógio real, candidatar() lia now(),
# considerava a vaga encerrada (409 vaga_encerrada) e deixava a CI de todos os PRs
# vermelha em "Migrações e pgTAP".
#
# Este portão é estático e barato (sem Postgres, sem rede). Ele inspeciona cada arquivo
# em supabase/tests/*.sql e garante que, caso o teste declare vaga/turno com data
# absoluta futura, ele DEVE congelar frila.agora antes de qualquer chamada que consuma
# o relógio do produto (privado.agora).
#
# SEGUNDA REGRA (B-111/B-111b, 24/11/2026): início ABSOLUTO de vaga de seleção que vence.
# `selecao_com_antecedencia` exige inicio_em > publicado_em + 24 h e `publicado_em` nasce com o
# now() REAL, mesmo com frila.agora congelado. Teste que crava a data de início fica vermelho no dia
# em que a data fica a menos de 24 h do relógio real (757 e 871 em 24/11/2026 18:00 UTC; a CI de
# todos os PRs ficou vermelha). A regra é estática: para cada literal de timestamp/date absoluto >=
# hoje, dentro de `insert into public.vaga` ou de uma chamada `publicar_vaga(` e a ±15 linhas de 'selecao',
#   vence = data - 24 h;  FALHA se vence <= hoje + 30 dias;  acima disso só imprime o vencimento.
# Fica fora da regra: literal de frila.agora/set_config, criar_conta/nascimento/termos_versao,
# a linha com o comentário `-- relogio: ok <motivo>`, o `insert into public.vaga (...)` que lista
# `publicado_em` nas colunas (a constraint compara com o valor dado, não com o now() real) e o arquivo
# que prende a publicação ao relógio de teste
# (`alter table public.vaga alter column publicado_em set default privado.agora()`).
# Data passada nunca falha. "Hoje" vem de `date -u`; injete com RELOGIO_HOJE=AAAA-MM-DD (autoteste).
#
# Uso:  ./scripts/relogio-em-testes.sh [pasta_ou_arquivo]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Dia UTC de "hoje" (injetável) para a regra de vencimento; formato validado no Python.
RELOGIO_HOJE="${RELOGIO_HOJE:-$(date -u +%F)}"
export RELOGIO_HOJE

python3 - "$@" << 'PY'
import sys, os, glob, re

# Funções do produto que consom privado.agora() e são sensíveis ao encerramento de vagas/turnos
CLOCK_FUNCS = [
    'candidatar', 'publicar_vaga', 'fazer_checkin', 'fazer_checkout',
    'fechar_turnos_e_vagas', 'fechar_turnos_passados', 'confirmar_checkin_manual', 'gerar_codigo_checkin', 'validar_codigo_checkin',
    'cancelar_uma_posicao', 'cancelamento_da_posicao', 'cancelar_posicao',
    'cancelar_vaga', 'despachar_vaga', 'avaliar', 'pode_avaliar',
    'avaliacao_permitida', 'reabrir_por_atraso', 'enviar_lembretes_turno',
    'alertar_atrasos', 'alertar_vagas_vazias', 'alertar_fim_sem_checkout',
    'vagas_abertas', 'detalhe_vaga', 'contato_do_turno', 'meus_turnos',
    'contestar_suspensao', 'pedir_revisao_despacho', r'privado\.agora\(',
    'excluir_conta', 'avisar_a_caminho', 'fechar_selecoes'
]

call_re = re.compile(
    r'(?:select|perform)\s+(?:public\.|privado\.)?(' + '|'.join(CLOCK_FUNCS) + r')\s*\(' +
    r'|format\s*\(\s*[\x27\$]+[^;\n]*\b(?:public\.|privado\.)?(' + '|'.join(CLOCK_FUNCS) + r')\b' +
    r'|(?:throws_ok|lives_ok)\s*\(\s*[\x27\$]+[^;\n]*\b(?:public\.|privado\.)?(' + '|'.join(CLOCK_FUNCS) + r')\b',
    re.I
)

freeze_re = re.compile(r'set_config\s*\(\s*[\x27\x22]frila\.agora[\x27\x22]|set\s+(?:local\s+)?frila\.agora', re.I)
date_re = re.compile(r'202[5-9]-[0-9]{2}-[0-9]{2}')
vaga_context_re = re.compile(r'\b(vaga|turno|posicao|posicoes|posições|inicio_em|fim_em|t[12]_inicio|nova_vaga|horarios?)\b', re.I)

def scan_file(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        lines = f.readlines()
        
    first_freeze = None
    first_vaga_date = None
    first_vaga_date_snippet = None
    first_clock = None
    first_clock_func = None
    in_vaga_insert = False
    in_block_comment = False
    
    for idx, raw_line in enumerate(lines, 1):
        line = raw_line
        if '/*' in line and '*/' in line:
            line = re.sub(r'/\*.*?\*/', '', line)
        elif '/*' in line:
            in_block_comment = True
            line = line.split('/*')[0]
        elif '*/' in line:
            in_block_comment = False
            line = line.split('*/')[1]
        elif in_block_comment:
            continue
            
        clean = line.split('--')[0]
        if not clean.strip():
            continue
            
        if freeze_re.search(clean) and first_freeze is None:
            first_freeze = idx
            
        if re.search(r'insert\s+into\s+public\.(?:vaga|turno|posicao)', clean, re.I):
            in_vaga_insert = True
            
        lower = clean.lower()
        is_user_line = ('termos_versao' in lower or 'nascimento' in lower or 'usuario' in lower or 'criar_conta' in lower)
        
        if date_re.search(clean) and not is_user_line:
            if vaga_context_re.search(clean) or in_vaga_insert:
                if first_vaga_date is None:
                    first_vaga_date = idx
                    first_vaga_date_snippet = clean.strip()
                    
        if in_vaga_insert and ';' in clean:
            in_vaga_insert = False
            
        if first_vaga_date is not None and first_clock is None:
            if 'cron.job' in clean or 'has_function' in clean:
                continue
            m = call_re.search(clean)
            if m:
                first_clock = idx
                first_clock_func = m.group(1) or m.group(2) or m.group(3)
                
    if first_vaga_date is not None and first_clock is not None:
        if first_freeze is None:
            return False, {
                'vaga_line': first_vaga_date,
                'vaga_snippet': first_vaga_date_snippet,
                'clock_line': first_clock,
                'clock_func': first_clock_func,
                'freeze_line': None
            }
        elif first_clock < first_freeze:
            return False, {
                'vaga_line': first_vaga_date,
                'vaga_snippet': first_vaga_date_snippet,
                'clock_line': first_clock,
                'clock_func': first_clock_func,
                'freeze_line': first_freeze
            }
            
    return True, None

target = sys.argv[1] if len(sys.argv) > 1 else 'supabase/tests'

files = []
if os.path.isfile(target):
    files = [target]
elif os.path.isdir(target):
    files = sorted(glob.glob(os.path.join(target, '*.sql')))
else:
    print(f"Alvo '{target}' não encontrado — nada a conferir, e isso não é verde.", file=sys.stderr)
    sys.exit(2)

if not files:
    print(f"Nenhum teste encontrado em '{target}' — nada a conferir, e isso não é verde.", file=sys.stderr)
    sys.exit(2)


# ── Segunda regra: início absoluto de seleção que vence (B-111b) ──────────────────────────────
import datetime as dt
try:
    HOJE = dt.datetime.strptime(os.environ['RELOGIO_HOJE'], '%Y-%m-%d').date()
except (KeyError, ValueError):
    print(f"RELOGIO_HOJE inválido ('{os.environ.get('RELOGIO_HOJE')}'): use AAAA-MM-DD.", file=sys.stderr)
    sys.exit(2)
LIMITE_DIAS = 30
JANELA = 15
quoted_re = re.compile(r"'(\d{4}-\d{2}-\d{2}[^']*)'")
ts_re = re.compile(r'(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?)?$')
pin_re = re.compile(r'alter\s+table\s+public\.vaga\s+alter\s+column\s+publicado_em\s+set\s+default\s+privado\.agora\s*\(\s*\)', re.I)
excecao_re = re.compile(r'--\s*relogio:\s*ok\b', re.I)
fora_re = re.compile(r'frila\.agora|set_config|criar_conta|nascimento|termos_versao', re.I)
vaga_ctx_re = re.compile(r'insert\s+into\s+public\.vaga\b|publicar_vaga', re.I)

def parse_instante(txt):
    m = ts_re.match(txt.strip())
    if not m:
        return None
    ano, mes, dia, hh, mm, ss, tz = m.groups()
    try:
        base = dt.datetime(int(ano), int(mes), int(dia), int(hh or 0), int(mm or 0), int(ss or 0))
    except ValueError:
        return None
    off = dt.timedelta(0)
    if tz and tz != 'Z':
        sinal = -1 if tz[0] == '-' else 1
        dig = tz[1:].replace(':', '')
        off = sinal * dt.timedelta(hours=int(dig[:2]), minutes=int(dig[2:] or 0))
    return base - off  # UTC ingênuo

ins_vaga_re = re.compile(r'insert\s+into\s+public\.vaga\s*\(([^)]*)\)', re.I)

def insert_com_publicado_em(limpas, i):
    """A linha i está num `insert into public.vaga (..., publicado_em, ...)`? Então a constraint
    compara com o valor explícito, e não com o now() real."""
    for ini in range(i, max(-1, i - 40), -1):
        if re.search(r'insert\s+into\s+public\.vaga\b', limpas[ini], re.I):
            fim = ini
            while fim < len(limpas) - 1 and ';' not in limpas[fim]:
                fim += 1
            if fim < i:
                return False  # outro statement
            m = ins_vaga_re.search('\n'.join(limpas[ini:fim + 1]))
            return bool(m and re.search(r'\bpublicado_em\b', m.group(1), re.I))
        if ';' in limpas[ini] and ini < i:
            return False
    return False

def no_inicio_de_vaga(limpas, i):
    """O literal da linha i está dentro de um `insert into public.vaga` ou de uma chamada
    `publicar_vaga(` (até o ';' do statement)? Fixture de posição, turno ou chamada perto não conta."""
    for ini in range(i, max(-1, i - 12), -1):
        if vaga_ctx_re.search(limpas[ini]):
            return True
        if ini < i and ';' in limpas[ini]:
            return False
    return False

def scan_vencimentos(filepath):
    """Devolve (pinado, [(linha, texto_da_data, vence_data, dias)]) dos inícios absolutos de seleção."""
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        brutas = f.read().split('\n')
    limpas = [l.split('--')[0] for l in brutas]
    if pin_re.search('\n'.join(limpas)):
        return True, []
    achados = []
    for i, limpa in enumerate(limpas):
        if fora_re.search(limpa) or excecao_re.search(brutas[i]):
            continue
        for m in quoted_re.finditer(limpa):
            inst = parse_instante(m.group(1))
            if inst is None or inst.date() < HOJE:
                continue  # passada (ou ilegível): nunca falha
            lo, hi = max(0, i - JANELA), min(len(limpas), i + JANELA + 1)
            janela = '\n'.join(limpas[lo:hi])
            if 'selecao' not in janela.lower() or not vaga_ctx_re.search(janela):
                continue
            if not no_inicio_de_vaga(limpas, i) or insert_com_publicado_em(limpas, i):
                continue
            vence = (inst - dt.timedelta(hours=24)).date()
            achados.append((i + 1, m.group(1), vence, (vence - HOJE).days))
    return False, achados

violations = []
vencem = []   # falham: vence <= hoje + 30 dias
a_vencer = [] # só imprime
n_pinados = 0
for f in files:
    ok, info = scan_file(f)
    if not ok:
        violations.append((f, info))
    pinado, achados = scan_vencimentos(f)
    n_pinados += 1 if pinado else 0
    for (linha, txt, vence, dias) in achados:
        (vencem if dias <= LIMITE_DIAS else a_vencer).append((f, linha, txt, vence, dias))

if a_vencer:
    print(f"Inícios absolutos de vaga de seleção ainda longe de vencer (hoje {HOJE}, limite {LIMITE_DIAS} dias):")
    for (f, linha, txt, vence, dias) in sorted(a_vencer, key=lambda x: (x[3], x[0], x[1])):
        print(f"  {f}:{linha}: {txt} vence em {vence} ({dias} dias)")
if n_pinados:
    print(f"{n_pinados} arquivo(s) prendem publicado_em ao relógio de teste (fora da regra de vencimento).")

if vencem:
    print(f"Início absoluto de vaga de seleção vence em até {LIMITE_DIAS} dias em {len({v[0] for v in vencem})} teste(s) pgTAP (hoje {HOJE}):", file=sys.stderr)
    for (f, linha, txt, vence, dias) in sorted(vencem, key=lambda x: (x[0], x[1])):
        print(f"  {f}:{linha}: início absoluto {txt[:10]}, vence em {dias} dias ({vence}) (selecao_com_antecedencia usa now() real); "
              f"use now() + interval '3 days', ou prenda a publicação ao relógio de teste "
              f"(alter table public.vaga alter column publicado_em set default privado.agora();), "
              f"ou marque a linha com `-- relogio: ok <motivo>`", file=sys.stderr)
    print(file=sys.stderr)

if violations:
    print(f"Bomba-relógio detectada em {len(violations)} teste(s) pgTAP:", file=sys.stderr)
    print(file=sys.stderr)
    for f, info in violations:
        print(f"  • {f}:", file=sys.stderr)
        print(f"      - Data absoluta em vaga/turno na linha {info['vaga_line']}:", file=sys.stderr)
        print(f"        `{info['vaga_snippet']}`", file=sys.stderr)
        print(f"      - Chamada sensível ao relógio ({info['clock_func']}) na linha {info['clock_line']}", file=sys.stderr)
        if info['freeze_line'] is None:
            print(f"      - frila.agora NUNCA é congelado no arquivo!", file=sys.stderr)
        else:
            print(f"      - frila.agora só é congelado na linha {info['freeze_line']} (DEPOIS da chamada)", file=sys.stderr)
        print(file=sys.stderr)
        print("      → Solução: congele frila.agora antes da primeira inserção ou chamada:", file=sys.stderr)
        print("          select set_config('frila.agora', '2026-10-02 12:00:00-03', true);", file=sys.stderr)
        print("        ou use deslocamentos dinâmicos (privado.agora() + interval '...').", file=sys.stderr)
        print(file=sys.stderr)

if violations or vencem:
    sys.exit(1)

print(f"Todos os {len(files)} testes pgTAP estão imunes a bombas-relógio de relógio.")
sys.exit(0)
PY
