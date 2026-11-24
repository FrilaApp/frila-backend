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
# SEGUNDA REGRA (B-111/B-111b/B-111c, 24/11/2026): início ABSOLUTO de vaga de seleção que vence.
# `selecao_com_antecedencia` exige inicio_em > publicado_em + 24 h e `publicado_em` nasce com o
# now() REAL, mesmo com frila.agora congelado. Teste que crava a data de início fica vermelho no dia
# em que a data fica a menos de 24 h do relógio real (757 e 871 em 24/11/2026 18:00 UTC; a CI de
# todos os PRs ficou vermelha). A regra é estática e lê o SQL com um léxico mínimo (comentário `--` e
# `/* */`, string, `$$..$$`/`$tag$..$tag$`): o literal de timestamp/date absoluto >= hoje ('...', ou $$...$$ e $tag$...$tag$
# com a data colada nas marcas) dentro de um
# `insert into public.vaga` ou de uma chamada `publicar_vaga(` que tem 'selecao' NO MESMO STATEMENT
# (até o `;`; modo de outro statement não conta):
#   vence = data - 24 h;  FALHA se vence <= hoje + 30 dias;  acima disso só imprime o vencimento.
# Fica fora da regra: literal de frila.agora/set_config, criar_conta/nascimento/termos_versao, a linha
# com o comentário `-- relogio: ok <motivo>`, e as duas formas de prender a publicação ao relógio de teste:
#   (1) `insert into public.vaga (...)` que lista `publicado_em` com valor que NÃO depende do relógio real
#       (literal fixo isenta; now(), current_timestamp, clock_timestamp, transaction_timestamp, default,
#       'now' etc. NÃO isentam; privado.agora() só isenta se frila.agora já estava congelado);
#   (2) `alter table public.vaga alter column publicado_em set default privado.agora()` como STATEMENT de verdade
#       (fora de comentário, de string e de corpo $$..$$: o texto do alter dentro de um `select '...'` não conta),
#       ANTES da primeira publicação de vaga e do rollback/finish, com frila.agora congelado antes da primeira
#       publicação.
# Data passada nunca falha. "Hoje" vem de `date -u`; injete com RELOGIO_HOJE=AAAA-MM-DD (autoteste).
#
# COBERTURA PARCIAL (assumida, B-111c): cobre literal direto em insert/publicar_vaga; NÃO cobre helper nem
# expressão montada (format, concatenação, make_timestamptz) e nem data passada como parâmetro a função do
# arquivo. Caso real que fica de fora e está fixado no autoteste: o 530 antigo (data na linha 143, passada
# ao helper das linhas 96-103). O gate NÃO substitui a revisão de teste novo de seleção.
#
# Uso:  ./scripts/relogio-em-testes.sh [pasta_ou_arquivo]
#       ./scripts/relogio-em-testes.sh --help
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

case "${1:-}" in
  -h|--help)
    cat << 'AJUDA'
Uso: scripts/relogio-em-testes.sh [pasta_ou_arquivo]    (padrão: supabase/tests)
Recusa teste pgTAP com bomba-relógio: (1) data absoluta de vaga/turno sem congelar frila.agora antes de
chamar função que lê o relógio; (2) início absoluto de vaga de seleção que vence em até 30 dias
(selecao_com_antecedencia usa publicado_em = now() real). RELOGIO_HOJE=AAAA-MM-DD injeta o "hoje" (UTC).
Saída: 0 limpo, 1 achado, 2 não mediu (alvo vazio/inexistente ou RELOGIO_HOJE inválido).
Cobertura parcial: cobre literal direto em insert/publicar_vaga; não cobre helper nem expressão montada.
AJUDA
    exit 0
    ;;
esac

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


# ── Segunda regra: início absoluto de seleção que vence (B-111b/B-111c) ───────────────────────
import datetime as dt
import bisect
try:
    HOJE = dt.datetime.strptime(os.environ['RELOGIO_HOJE'], '%Y-%m-%d').date()
except (KeyError, ValueError):
    print(f"RELOGIO_HOJE inválido ('{os.environ.get('RELOGIO_HOJE')}'): use AAAA-MM-DD.", file=sys.stderr)
    sys.exit(2)
LIMITE_DIAS = 30
COBERTURA = ("Cobertura parcial: cobre literal direto em insert/publicar_vaga; "
             "não cobre helper nem expressão montada.")
data_re = re.compile(r"\d{4}-\d{2}-\d{2}[^']*")
aninhado_re = re.compile(r"''(\d{4}-\d{2}-\d{2}[^']*?)''")
# Literal de data entre marcas dollar iguais ($$2027-01-15 18:00:00+00$$ ou $ts$...$ts$), achado no texto cru:
# não depende de como as marcas se emparelham (o controle do Lince põe $$ dentro de outro $$).
dollar_data_re = re.compile(r"(\$(?:[^\W\d]\w*)?\$)(\d{4}-\d{2}-\d{2}[^$']*?)\1")
ts_re = re.compile(r'(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?)?$')
pin_re = re.compile(r'alter\s+table\s+public\.vaga\s+alter\s+column\s+publicado_em\s+set\s+default\s+privado\.agora\s*\(\s*\)', re.I)
excecao_re = re.compile(r'--\s*relogio:\s*ok\b', re.I)
fora_re = re.compile(r'frila\.agora|set_config|criar_conta|nascimento|termos_versao', re.I)
vaga_ctx_re = re.compile(r'insert\s+into\s+public\.vaga\b|publicar_vaga\s*\(', re.I)
insert_vaga_re = re.compile(r'insert\s+into\s+public\.vaga\s*\(', re.I)
selecao_re = re.compile(r'\bselecao\b', re.I)
fim_re = re.compile(r'(?<!\w)rollback\b(?!\s+to\b)|\bfinish\s*\(', re.I)
tag_re = re.compile(r'\$(?:[^\W\d]\w*)?\$')
# Valor de publicado_em que depende do relógio REAL (a constraint compararia com o now() de verdade).
relogio_real_re = re.compile(r'\b(?:now|current_timestamp|current_date|localtimestamp|clock_timestamp|'
                             r'transaction_timestamp|statement_timestamp|timeofday|default)\b', re.I)
relogio_texto_re = re.compile(r"'\s*(?:now|today|tomorrow|yesterday)\s*'", re.I)
agora_re = re.compile(r'\bagora\s*\(', re.I)

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

def tokenizar(txt):
    """Léxico mínimo do Postgres. Devolve (code, masked, strings, pontos_e_virgula, crua, corpos):
    code   = o texto com comentários (-- e /* */ aninhado) e as marcas $tag$ trocados por espaços (mesmos
             deslocamentos e quebras de linha); o conteúdo de string e o de $$...$$ continuam, porque o
             teste monta SQL dentro deles;
    masked = code com o conteúdo das strings trocado por 'x' (estrutura sem parêntese/vírgula de string);
    strings = [(ini, fim)] do conteúdo de cada string de aspas simples;
    pontos_e_virgula = deslocamentos dos ';' fora de string e de comentário (fim de statement);
    crua   = só os comentários trocados por espaços (as marcas $tag$ ficam);
    corpos = [(ini, fim)] do corpo de cada $tag$...$tag$ de nível de cima (texto que o Postgres NÃO executa
             como SQL do arquivo: é argumento de função)."""
    n = len(txt)
    code = list(txt)
    strings, semis, pilha, corpos, marcas = [], [], [], [], []
    estado, ini_str, prof, ini_corpo = None, 0, 0, 0
    i = 0
    while i < n:
        if pilha and txt.startswith(pilha[-1], i):   # fecha o $tag$ aberto (vale em qualquer estado)
            if estado == 'str':
                strings.append((ini_str, i))
            estado, prof = None, 0
            for k in range(i, i + len(pilha[-1])):
                code[k] = ' '
            marcas.append((i, i + len(pilha[-1])))
            if len(pilha) == 1:
                corpos.append((ini_corpo, i))
            i += len(pilha.pop())
            continue
        c = txt[i]
        if estado is None:
            if c == "'":
                estado, ini_str = 'str', i + 1
            elif txt.startswith('--', i):
                estado = 'lin'
                code[i] = code[i + 1] = ' '
                i += 1
            elif txt.startswith('/*', i):
                estado, prof = 'blo', 1
                code[i] = code[i + 1] = ' '
                i += 1
            elif c == '$':
                m = tag_re.match(txt, i)
                if m:
                    if not pilha:
                        ini_corpo = m.end()
                    pilha.append(m.group())
                    for k in range(m.start(), m.end()):
                        code[k] = ' '
                    marcas.append((m.start(), m.end()))
                    i = m.end()
                    continue
            elif c == ';':
                semis.append(i)
        elif estado == 'str':
            if c == "'":
                if txt.startswith("''", i):
                    i += 1
                else:
                    strings.append((ini_str, i))
                    estado = None
        elif estado == 'lin':
            if c == '\n':
                estado = None
            else:
                code[i] = ' '
        else:  # 'blo'
            if txt.startswith('/*', i):
                prof += 1
                code[i] = code[i + 1] = ' '
                i += 1
            elif txt.startswith('*/', i):
                prof -= 1
                code[i] = code[i + 1] = ' '
                i += 1
                if prof == 0:
                    estado = None
            elif c != '\n':
                code[i] = ' '
        i += 1
    if estado == 'str':
        strings.append((ini_str, n))
    if pilha:
        corpos.append((ini_corpo, n))
    crua = list(code)
    for (a, b) in marcas:
        crua[a:b] = txt[a:b]
    masked = list(code)
    for (a, b) in strings:
        for k in range(a, b):
            if masked[k] != '\n':
                masked[k] = 'x'
    return ''.join(code), ''.join(masked), strings, semis, ''.join(crua), corpos

def fecha_parenteses(masked, i):
    """masked[i] == '('. Devolve o deslocamento do ')' que o fecha (ou None)."""
    prof = 0
    for k in range(i, len(masked)):
        if masked[k] == '(':
            prof += 1
        elif masked[k] == ')':
            prof -= 1
            if prof == 0:
                return k
    return None

def divide_virgulas(masked, ini, fim):
    """Intervalos [(a, b)] dos itens separados por vírgula no nível de cima de masked[ini:fim]."""
    itens, prof, a = [], 0, ini
    for k in range(ini, fim):
        c = masked[k]
        if c == '(':
            prof += 1
        elif c == ')':
            prof -= 1
        elif c == ',' and prof == 0:
            itens.append((a, k))
            a = k + 1
    itens.append((a, fim))
    return itens

def publicado_em_fixo(code, masked, ini_stmt, lit, freeze_off):
    """O `insert into public.vaga (...)` do statement lista publicado_em E todo valor dado a ele independe
    do relógio real? Só então a constraint compara com um instante fixo. now(), current_timestamp,
    clock_timestamp, transaction_timestamp, default etc. NÃO isentam; privado.agora() só se frila.agora já
    estava congelado antes do insert; insert ... select (sem VALUES) não dá para ler: não isenta."""
    ms = list(insert_vaga_re.finditer(masked, ini_stmt, lit))
    if not ms:
        return False
    m = ms[-1]
    abre = m.end() - 1
    fecha = fecha_parenteses(masked, abre)
    if fecha is None:
        return False
    cols = [c.strip().lower() for c in masked[abre + 1:fecha].split(',')]
    if 'publicado_em' not in cols:
        return False
    idx = cols.index('publicado_em')
    v = re.compile(r'\s*values\b', re.I).match(masked, fecha + 1)
    if not v:
        return False
    pos, tuplas = v.end(), 0
    while True:
        while pos < len(masked) and masked[pos].isspace():
            pos += 1
        if pos >= len(masked) or masked[pos] != '(':
            return False
        fim = fecha_parenteses(masked, pos)
        if fim is None:
            return False
        itens = divide_virgulas(masked, pos + 1, fim)
        if idx >= len(itens):
            return False
        a, b = itens[idx]
        if relogio_real_re.search(masked[a:b]) or relogio_texto_re.search(code[a:b]):
            return False
        if agora_re.search(masked[a:b]) and not (freeze_off is not None and freeze_off < m.start()):
            return False
        tuplas += 1
        pos = fim + 1
        while pos < len(masked) and masked[pos].isspace():
            pos += 1
        if pos < len(masked) and masked[pos] == ',':
            pos += 1
            continue
        return tuplas > 0

def publicacao_presa(code, fora, freeze_off):
    """O `alter table public.vaga alter column publicado_em set default privado.agora()` é um STATEMENT de
    verdade (`fora` = sem comentário, sem string e sem corpo $tag$...$tag$: texto que só aparece como dado não
    executa o alter), vem antes da primeira publicação de vaga e antes do rollback/finish, e frila.agora já
    estava congelado antes da primeira publicação? Alter depois do rollback, em comentário, em string ou em
    dollar-quote NÃO isenta."""
    pub = vaga_ctx_re.search(code)
    pub_off = pub.start() if pub else len(code)
    fim = fim_re.search(fora)
    fim_off = fim.start() if fim else len(code)
    if freeze_off is None or freeze_off >= pub_off:
        return False
    return any(p.start() < pub_off and p.start() < fim_off for p in pin_re.finditer(fora))

def scan_vencimentos(filepath):
    """Devolve (pinado, [(linha, texto_da_data, vence_data, dias)]) dos inícios absolutos de seleção."""
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        txt = f.read()
    code, masked, strings, semis, crua, corpos = tokenizar(txt)
    fz = freeze_re.search(code)
    freeze_off = fz.start() if fz else None
    fora = list(masked)
    for (a, b) in corpos:
        for k in range(a, b):
            if fora[k] != '\n':
                fora[k] = 'x'
    if publicacao_presa(code, ''.join(fora), freeze_off):
        return True, []
    limpas = code.split('\n')
    brutas = txt.split('\n')
    candidatos = set()   # (deslocamento, texto) de literal de data: string, 'aninhada' em SQL montado ou $tag$..$tag$
    for (a, b) in strings:
        conteudo = txt[a:b]
        if data_re.fullmatch(conteudo):
            candidatos.add((a, conteudo))
        else:
            candidatos.update((a + m.start(1), m.group(1)) for m in aninhado_re.finditer(conteudo))
    candidatos.update((m.start(2), m.group(2)) for m in dollar_data_re.finditer(crua))
    achados = []
    for (off, texto) in sorted(candidatos):
        linha = txt.count('\n', 0, off)
        if fora_re.search(limpas[linha]) or excecao_re.search(brutas[linha]):
            continue
        inst = parse_instante(texto)
        if inst is None or inst.date() < HOJE:
            continue  # passada (ou ilegível): nunca falha
        k = bisect.bisect_left(semis, off)
        ini_stmt = semis[k - 1] + 1 if k > 0 else 0
        fim_stmt = semis[k] if k < len(semis) else len(code)
        # Modo e início na MESMA chamada (statement, até o ';'): 'selecao' de outro statement não conta.
        if not selecao_re.search(code[ini_stmt:fim_stmt]):
            continue
        if not vaga_ctx_re.search(code[ini_stmt:off]):
            continue  # fora de insert into public.vaga / publicar_vaga( : fixture de posição, turno etc.
        if publicado_em_fixo(code, masked, ini_stmt, off, freeze_off):
            continue
        vence = (inst - dt.timedelta(hours=24)).date()
        achados.append((linha + 1, texto, vence, (vence - HOJE).days))
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
print(COBERTURA)
sys.exit(0)
PY
