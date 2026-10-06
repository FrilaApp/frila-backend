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
# Uso:  ./scripts/relogio-em-testes.sh [pasta_ou_arquivo]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

python3 - "$@" << 'PY'
import sys, os, glob, re

# Funções do produto que consom privado.agora() e são sensíveis ao encerramento de vagas/turnos
CLOCK_FUNCS = [
    'candidatar', 'publicar_vaga', 'fazer_checkin', 'fazer_checkout',
    'fechar_turnos_e_vagas', 'fechar_turnos_passados', 'confirmar_checkin_manual',
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

violations = []
for f in files:
    ok, info = scan_file(f)
    if not ok:
        violations.append((f, info))

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
    sys.exit(1)

print(f"Todos os {len(files)} testes pgTAP estão imunes a bombas-relógio de relógio.")
sys.exit(0)
PY
