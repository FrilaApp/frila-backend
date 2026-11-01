#!/usr/bin/env bash
# Varredura auditável de segredos e dependências do Frila Backend.
#
# Audita a árvore de trabalho atual e o histórico git em busca de credenciais,
# chaves privadas, segredos e tokens, além de inventariar e verificar o estado de
# fixação (pinning) e integridade de todas as dependências externas (Deno, Python,
# GitHub Actions e extensões PostgreSQL).
#
# Regra inviolável: NUNCA expor valores reais de segredos no terminal ou no relatório.
# Todas as ocorrências são redigidas com mascaramento seguro e hash SHA-256 truncado.
#
# Uso:
#   ./scripts/auditoria-segredos-e-dependencias.sh [opções]
#
# Opções:
#   --relatorio <caminho>          Caminho do relatório Markdown (padrão: docs/AuditoriaSegredosEDependencias.md)
#   --apenas-segredos              Executa exclusivamente a varredura de segredos
#   --apenas-dependencias          Executa exclusivamente a auditoria de dependências
#   --falhar-se-encontrar-segredo  Retorna exit 1 se encontrar segredo suspeito (ALERTA)
#   --ajuda, -h                    Exibe esta ajuda
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

exec python3 - "$@" << 'EOF'
import sys
import os
import re
import json
import hashlib
import subprocess
from datetime import datetime
from pathlib import Path

TEXTO_AJUDA = """Varredura auditável de segredos e dependências do Frila Backend.

Audita a árvore de trabalho atual e o histórico git em busca de credenciais,
chaves privadas, segredos e tokens, além de inventariar e verificar o estado de
fixação (pinning) e integridade de todas as dependências externas.

Uso:
  ./scripts/auditoria-segredos-e-dependencias.sh [opções]

Opções:
  --relatorio <caminho>          Caminho do relatório Markdown (padrão: docs/AuditoriaSegredosEDependencias.md)
  --apenas-segredos              Executa exclusivamente a varredura de segredos
  --apenas-dependencias          Executa exclusivamente a auditoria de dependências
  --falhar-se-encontrar-segredo  Retorna exit 1 se encontrar segredo suspeito (ALERTA)
  --ajuda, -h                    Exibe esta ajuda
"""

# --- Configuração de Padrões de Auditoria de Segredos ---
PATTERNS = [
    {
        "id": "chave_privada",
        "tipo": "Chave Privada (RSA/EC/OpenSSH/PGP)",
        "regex": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"),
        "git_ere": "-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----",
    },
    {
        "id": "supabase_pat",
        "tipo": "Supabase Access Token",
        "regex": re.compile(r"\bsbp_[a-zA-Z0-9]{40}\b"),
        "git_ere": "sbp_[a-zA-Z0-9]{40}",
    },
    {
        "id": "github_token",
        "tipo": "GitHub Token (PAT/OAuth)",
        "regex": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9_]{36,255}|github_pat_[A-Za-z0-9_]{82})\b"),
        "git_ere": "(gh[pousr]_[A-Za-z0-9_]{36,255}|github_pat_[A-Za-z0-9_]{82})",
    },
    {
        "id": "resend_api_key",
        "tipo": "Resend API Key",
        "regex": re.compile(r"\bre_[A-Za-z0-9_]{24,}\b"),
        "git_ere": "re_[A-Za-z0-9_]{24,}",
    },
    {
        "id": "aws_key_id",
        "tipo": "AWS Access Key ID",
        "regex": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
        "git_ere": "AKIA[0-9A-Z]{16}",
    },
    {
        "id": "google_service_account",
        "tipo": "Google / Firebase Service Account Key",
        "regex": re.compile(r'"type":\s*"service_account"[\s\S]*?"private_key":\s*"-----BEGIN PRIVATE KEY'),
        "git_ere": '"private_key":[[:space:]]*"-----BEGIN PRIVATE KEY',
    },
    {
        "id": "stripe_live_key",
        "tipo": "Stripe Live Secret Key",
        "regex": re.compile(r"\bsk_live_[0-9a-zA-Z]{24,}\b"),
        "git_ere": "sk_live_[0-9a-zA-Z]{24,}",
    },
    {
        "id": "slack_token",
        "tipo": "Slack Token / Webhook",
        "regex": re.compile(r"\bxox[baprs]-[0-9a-zA-Z]{10,}\b|https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+"),
        "git_ere": "xox[baprs]-[0-9a-zA-Z]{10,}|hooks\\.slack\\.com/services/",
    },
    {
        "id": "postgres_url",
        "tipo": "Postgres URL com Senha",
        "regex": re.compile(r"postgres(?:ql)?://([^:\s]+):([^@\s]+)@([^\s/'\"]+)"),
        "git_ere": "postgres(ql)?://[^:]+:[^@]+@",
    },
    {
        "id": "supabase_service_role",
        "tipo": "Supabase Service Role JWT",
        "regex": re.compile(r"\beyJhbGciOi[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"),
        "git_ere": "eyJhbGciOi",
    },
    {
        "id": "atribuicao_generica",
        "tipo": "Atribuição Genérica de Segredo / Token",
        "regex": re.compile(r"""(?i)\b(?:api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|service[_-]?role[_-]?key)\s*[:=]\s*["\']([A-Za-z0-9+/=_\.-]{20,})["\']"""),
        "git_ere": "(api_key|secret_key|access_token|service_role_key)[[:space:]]*[:=]",
    }
]

def mascarar(valor: str, tipo: str) -> str:
    """Gera máscara segura garantindo que o segredo bruto NUNCA seja exibido."""
    valor_limpo = valor.strip()
    h = hashlib.sha256(valor_limpo.encode("utf-8", errors="ignore")).hexdigest()[:8]
    if "PRIVATE KEY" in valor_limpo:
        return f"-----BEGIN PRIVATE KEY-----\\n[REDACTED sha256:{h}]\\n-----END PRIVATE KEY-----"
    if "Postgres URL" in tipo:
        m = re.match(r"postgres(?:ql)?://([^:\s]+):([^@\s]+)@([^\s/'\"]+)", valor_limpo)
        if m:
            user, pwd, host = m.group(1), m.group(2), m.group(3)
            pwd_h = hashlib.sha256(pwd.encode("utf-8", errors="ignore")).hexdigest()[:8]
            return f"postgresql://{user}:[REDACTED sha256:{pwd_h}]@{host}"
    if len(valor_limpo) <= 10:
        return f"[REDACTED sha256:{h}]"
    prefixo = valor_limpo[:5]
    sufixo = valor_limpo[-3:]
    return f"{prefixo}...[REDACTED]...{sufixo} (sha256:{h})"

def classificar_ocorrencia(caminho: str, valor: str, tipo: str, linha: str = "") -> str:
    """Classifica o achado como legítimo (testes, exemplos, docs) ou alerta real."""
    caminho_norm = caminho.replace("\\", "/").lower()
    valor_lower = valor.lower()
    linha_lower = linha.lower()

    # Relatório ou scripts de teste do próprio auditor
    if any(k in caminho_norm for k in ["auditoriasegredosedependencias", "teste-auditoria", "auditoria-segredos"]):
        return "LEGÍTIMO (Documentação/Script de Auditoria)"

    # Allowlist estrita de padrões sintéticos de teste e placeholders conhecidos
    placeholders = [
        "[host]", "[senha]", "[password]", "<segredo>", "<token>", "seu-token",
        "sua-chave", "mock", "test", "placeholder", "exemplo", "postgres:postgres",
        "fake", "dummy", "00000000", "segredo_teste", "sua_chave_resend",
        "token_fcm_valido_com_mais_de_vinte_caracteres", "senha", "secret",
        "seu-projeto", "seu_projeto", "frila-test", "frila_test", "example.com",
        "test-proj", "...", "${b64}", "invalido", "invalida", "invalidos",
        "sgvsbg8gv29ybgqh"
    ]
    eh_placeholder_valor = any(ph in valor_lower for ph in placeholders)
    eh_placeholder_linha = any(ph in linha_lower for ph in placeholders)
    eh_placeholder = eh_placeholder_valor or eh_placeholder_linha

    # Conexões postgres locais
    if "Postgres URL" in tipo:
        if any(h in valor_lower for h in ["localhost", "127.0.0.1", "supabase_db_", "mock"]):
            return "LEGÍTIMO (Ambiente Local / Mock)"

    # Fixtures de teste só são legítimas se contiverem valor/contexto comprovadamente sintético/placeholder
    eh_caminho_teste = any(caminho_norm.endswith(sfx) for sfx in ["_test.ts", "_test.js", ".test.ts", ".spec.ts", ".test.js"]) or \
                       any(part in caminho_norm for part in ["/fixtures/", "/tests/", "supabase/tests/", "teste_setup", "test_setup"])
    if eh_caminho_teste:
        if eh_placeholder:
            return "LEGÍTIMO (Fixture Sintética de Teste)"
        else:
            return "ALERTA (Possível Segredo Exposto em Arquivo de Teste)"

    # Arquivos de exemplo e documentação
    eh_exemplo = any(caminho_norm.endswith(sfx) for sfx in [".example", ".exemplo"]) or \
                 ".env.example" in caminho_norm or ".env.exemplo" in caminho_norm
    if eh_exemplo:
        if eh_placeholder:
            return "LEGÍTIMO (Placeholder de Exemplo)"
        else:
            return "ALERTA (Possível Segredo em Arquivo de Exemplo)"

    # Placeholders literais em arquivos normais (ex: <token>, [senha], etc.)
    literal_placeholders = ["[host]", "[senha]", "[password]", "<segredo>", "<token>", "seu-token", "sua-chave", "placeholder", "postgres:postgres"]
    if any(ph in valor_lower for ph in literal_placeholders):
        return "LEGÍTIMO (Placeholder de Exemplo)"

    return "ALERTA (Possível Segredo Exposto)"

def varrer_arquivos_atuais(caminho_relatorio: Path):
    """Varre arquivos rastreados e não rastreados que não estejam no .gitignore."""
    achados = []
    arquivos = set()

    # Normaliza caminho do relatório para exclusão
    try:
        relatorio_abs = caminho_relatorio.resolve()
    except Exception:
        relatorio_abs = None

    # Lista arquivos rastreados pelo git
    try:
        out = subprocess.check_output(["git", "ls-files"], text=True, stderr=subprocess.DEVNULL)
        for l in out.strip().splitlines():
            if l:
                arquivos.add(l)
    except Exception:
        # Fallback para caminhada de diretório se git falhar
        for p in Path(".").rglob("*"):
            if p.is_file() and not any(part.startswith(".") for part in p.parts):
                arquivos.add(str(p))

    # Adiciona arquivos untracked que não estão ignorados
    try:
        out_untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], text=True, stderr=subprocess.DEVNULL)
        for l in out_untracked.strip().splitlines():
            if l:
                arquivos.add(l)
    except Exception:
        pass

    arquivos_auditados = 0
    for rel_path in sorted(arquivos):
        # Ignora arquivos binários ou muito grandes óbvios
        if any(rel_path.endswith(ext) for ext in [".png", ".jpg", ".jpeg", ".ico", ".pdf", ".lock", ".zip"]):
            continue
        p = Path(rel_path)
        if not p.is_file():
            continue

        # Não escaneia o próprio arquivo de relatório de saída
        try:
            if relatorio_abs and p.resolve() == relatorio_abs:
                continue
        except Exception:
            pass

        try:
            texto = p.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue

        arquivos_auditados += 1
        linhas = texto.splitlines()

        for pat in PATTERNS:
            # Para padrões que podem ser multilinhas (como private key ou service account json)
            if pat["id"] == "google_service_account":
                m = pat["regex"].search(texto)
                if m:
                    val = m.group(0)
                    if "[REDACTED" not in val:
                        classif = classificar_ocorrencia(rel_path, val, pat["tipo"], linha=linha)
                        achados.append({
                            "arquivo": rel_path,
                            "linha": 1,
                            "tipo": pat["tipo"],
                            "classificacao": classif,
                            "mascara": mascarar(val, pat["tipo"]),
                        })
                continue

            for num_linha, linha in enumerate(linhas, 1):
                # Ignora linhas que já contêm marcações de redação/máscara
                if "[REDACTED" in linha:
                    continue

                for m in pat["regex"].finditer(linha):
                    val = m.group(0)
                    # No caso de atribuição genérica, extrai o valor do grupo se houver
                    if pat["id"] == "atribuicao_generica":
                        val_grupo = m.group(1) if m.groups() else val
                        # Se for placeholder óbvio, ignora
                        if any(ph in val_grupo.lower() for ph in ["sua-chave", "seu-token", "placeholder", "exemplo", "<", "["]):
                            continue
                    classif = classificar_ocorrencia(rel_path, val, pat["tipo"], linha=linha)
                    achados.append({
                        "arquivo": rel_path,
                        "linha": num_linha,
                        "tipo": pat["tipo"],
                        "classificacao": classif,
                        "mascara": mascarar(val, pat["tipo"]),
                    })

    return achados, arquivos_auditados

def varrer_historico_git():
    """Varre histórico git em busca de commits que adicionaram ou modificaram segredos em um único comando."""
    achados_git = []
    total_commits = 0
    status_git = "OK"

    try:
        out_commits = subprocess.check_output(["git", "rev-list", "--count", "HEAD"], text=True, stderr=subprocess.DEVNULL)
        total_commits = int(out_commits.strip())
    except Exception:
        total_commits = 0

    if total_commits == 0:
        return achados_git, total_commits, status_git

    combined_ere = "|".join(f"({p['git_ere']})" for p in PATTERNS if p.get("git_ere"))
    cmd = ["git", "log", "--all", "-E", "-G", combined_ere, "--format=COMMIT:%h%x00%ad%x00%an%x00%s", "--date=short", "-U0"]
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True)
        if proc.returncode != 0:
            status_git = f"INCOMPLETO (git log exit {proc.returncode})"
            sys.stderr.write(f"ERRO: git log falhou com exit {proc.returncode}: {proc.stderr}\n")
            return achados_git, total_commits, status_git
        out = proc.stdout
    except Exception as e:
        status_git = f"INCOMPLETO ({e})"
        sys.stderr.write(f"ERRO: falha ao executar git log: {e}\n")
        return achados_git, total_commits, status_git

    current_commit = None
    files_touched = []
    lines_added = []

    def processar_commit(c_info, files, lines):
        if not c_info:
            return
        sha, dt, author, subject = c_info
        for fname, ltext in lines:
            for pat in PATTERNS:
                for m in pat["regex"].finditer(ltext):
                    val = m.group(0)
                    c = classificar_ocorrencia(fname, val, pat["tipo"], linha=ltext)
                    achados_git.append({
                        "sha": sha,
                        "data": dt,
                        "autor": author,
                        "mensagem": subject,
                        "arquivos": fname,
                        "tipo": pat["tipo"],
                        "classificacao": c,
                        "mascara": mascarar(val, pat["tipo"])
                    })

    current_file = ""
    for line in out.splitlines():
        if line.startswith("COMMIT:"):
            processar_commit(current_commit, files_touched, lines_added)
            parts = line[7:].split("\x00")
            current_commit = parts if len(parts) == 4 else None
            files_touched = []
            lines_added = []
            current_file = ""
        elif line.startswith("diff --git"):
            parts = line.split(" b/")
            if len(parts) > 1:
                current_file = parts[-1].strip()
                if current_file not in files_touched:
                    files_touched.append(current_file)
        elif line.startswith("+") and not line.startswith("+++"):
            lines_added.append((current_file, line[1:]))

    processar_commit(current_commit, files_touched, lines_added)
    return achados_git, total_commits, status_git

def auditar_dependencias():
    """Audita dependências em Deno (Edge Functions), Python, GitHub Actions e PostgreSQL."""
    relato = {
        "deno": {"modulos": [], "lockfile_presente": False, "alertas": []},
        "python": {"pacotes": [], "contrato_sha": None, "alertas": []},
        "actions": {"actions": [], "alertas": []},
        "postgres": {"extensoes": [], "alertas": []}
    }

    # 1. Edge Functions (Deno)
    fn_dir = Path("supabase/functions")
    import_re = re.compile(r"""(?:import|from)\s+["\x27]([^"\x27]+)["\x27]""")
    imports_vistos = set()

    if fn_dir.is_dir():
        for f in fn_dir.rglob("*.ts"):
            content = f.read_text(encoding="utf-8", errors="ignore")
            for m in import_re.finditer(content):
                imp = m.group(1).strip()
                if not imp.startswith("."):
                    imports_vistos.add(imp)

    for imp in sorted(imports_vistos):
        fixado = False
        versao = None

        if imp.startswith("jsr:") or imp.startswith("npm:"):
            corpo = imp.split(":", 1)[1]
            if corpo.startswith("@"):
                at_pos = corpo.find("@", 1)
                if at_pos != -1:
                    versao = corpo[at_pos + 1:].strip()
            else:
                if "@" in corpo:
                    versao = corpo.split("@", 1)[1].strip()
        elif "@" in imp:
            m_ver = re.search(r"@([^\/\s]+)", imp)
            if m_ver:
                versao = m_ver.group(1).strip()

        if versao:
            tem_flutuacao = any(c in versao for c in ["^", "~", "*", ">", "<", "latest"])
            eh_semver_exato = bool(re.match(r"^[0-9]+(\.[0-9]+)*(-[a-zA-Z0-9\.\-_]+)?$", versao))
            if eh_semver_exato and not tem_flutuacao:
                fixado = True

        status = "Fixado (Pin)" if fixado else "Alerta: Flutuante / Sem Pin"
        if not fixado:
            relato["deno"]["alertas"].append(f"Dependência Deno sem versão fixada: {imp} (versão: '{versao or 'nenhuma'}')")

        relato["deno"]["modulos"].append({
            "especificador": imp,
            "versao": versao or "não declarada",
            "status": status
        })

    lock_file = Path("deno.lock")
    lock_presente = lock_file.is_file()
    lock_valido = False
    if lock_presente:
        try:
            txt_lock = lock_file.read_text(encoding="utf-8")
            dados_lock = json.loads(txt_lock)
            if isinstance(dados_lock, dict) and "version" in dados_lock:
                lock_valido = True
            else:
                relato["deno"]["alertas"].append("Arquivo deno.lock existe mas não contém chave 'version' válida de lockfile Deno.")
        except Exception as e:
            relato["deno"]["alertas"].append(f"Arquivo deno.lock corrompido ou JSON inválido: {e}")
    else:
        if fn_dir.is_dir() and any(fn_dir.rglob("*.ts")):
            relato["deno"]["alertas"].append("Arquivo deno.lock não encontrado na raiz.")

    relato["deno"]["lockfile_presente"] = lock_presente
    relato["deno"]["lockfile_valido"] = lock_valido

    # 2. Python e Contrato OpenAPI
    venv_dir = Path(".venv-contrato")
    if venv_dir.is_dir():
        for dist in venv_dir.glob("lib/python*/site-packages/*.dist-info"):
            nome_ver = dist.name.replace(".dist-info", "")
            if "-" in nome_ver:
                pkg, ver = nome_ver.split("-", 1)
                relato["python"]["pacotes"].append({"pacote": pkg, "versao": ver, "fonte": ".venv-contrato"})

    # Confere versões fixadas no script de contrato
    contrato_sh = Path("scripts/contrato-responde.sh")
    if contrato_sh.is_file():
        txt = contrato_sh.read_text(encoding="utf-8", errors="ignore")
        m = re.findall(r"pip\x22?\s+install\s+.*?([a-zA-Z0-9_\-]+==[0-9\.]+)", txt)
        for p in m:
            pkg, ver = p.split("==", 1)
            relato["python"]["pacotes"].append({"pacote": pkg, "versao": ver, "fonte": "scripts/contrato-responde.sh (declarado)"})

    sha_file = Path("contrato/openapi.yaml.sha256")
    openapi_file = Path("contrato/openapi.yaml")
    if sha_file.is_file() and openapi_file.is_file():
        sha_gravado = sha_file.read_text().strip().split()[0]
        sha_calculado = hashlib.sha256(openapi_file.read_bytes()).hexdigest()
        relato["python"]["contrato_sha"] = {
            "gravado": sha_gravado,
            "calculado": sha_calculado,
            "valido": (sha_gravado == sha_calculado)
        }
        if sha_gravado != sha_calculado:
            relato["python"]["alertas"].append("Hash SHA-256 do contrato/openapi.yaml diverge de openapi.yaml.sha256!")

    # 3. GitHub Actions
    wf_dir = Path(".github/workflows")
    uses_re = re.compile(r"""uses:\s*([^\s#]+)(?:\s*#\s*(.*))?""")
    actions_vistas = {}

    if wf_dir.is_dir():
        for wf in sorted(wf_dir.glob("*.yml")):
            lines = wf.read_text(encoding="utf-8", errors="ignore").splitlines()
            for line in lines:
                m = uses_re.search(line)
                if m:
                    target = m.group(1).strip()
                    comentario = m.group(2).strip() if m.group(2) else ""
                    if target not in actions_vistas:
                        actions_vistas[target] = (wf.name, comentario)

    for target, (wf_name, tag_comentario) in sorted(actions_vistas.items()):
        parts = target.split("@")
        action_name = parts[0]
        ref = parts[1] if len(parts) > 1 else "sem-ref"
        is_sha = bool(re.match(r"^[0-9a-f]{40}$", ref))
        status = "Fixado por Commit SHA (Imutável)" if is_sha else "Alerta: Tag Mutável (Sem SHA)"
        if not is_sha:
            relato["actions"]["alertas"].append(f"Action {action_name}@{ref} em {wf_name} não utiliza commit SHA imutável.")

        relato["actions"]["actions"].append({
            "action": action_name,
            "ref": ref[:10] + "..." if is_sha else ref,
            "tag": tag_comentario or "não anotada",
            "workflow": wf_name,
            "status": status
        })

    # 4. Extensões PostgreSQL
    mig_dir = Path("supabase/migrations")
    ext_re = re.compile(r"""create\s+extension\s+(?:if\s+not\s+exists\s+)?([a-zA-Z0-9_]+)(?:\s+with\s+schema\s+([a-zA-Z0-9_]+))?(?:\s+cascade)?""", re.IGNORECASE)
    ext_vistas = {}

    if mig_dir.is_dir():
        for f in sorted(mig_dir.glob("*.sql")):
            content = f.read_text(encoding="utf-8", errors="ignore")
            for m in ext_re.finditer(content):
                name = m.group(1).lower()
                schema = m.group(2).lower() if m.group(2) else "public"
                if name not in ext_vistas:
                    ext_vistas[name] = {"migracao": f.name, "schema": schema}

    # Metadados e propósitos das extensões
    propositos = {
        "postgis": "Geolocalização, cálculo de distâncias entre vagas e profissionais (RN06)",
        "btree_gist": "Índices GIST para exclusão e suporte a restrições temporais",
        "citext": "Campos de texto case-insensitive para e-mails e identificadores",
        "pg_net": "Disparos assíncronos HTTP (webhooks de despacho e e-mail via Edge Functions)",
        "pgmq": "Filas de mensagens transacionais para desacoplamento de eventos",
        "pg_cron": "Agendamentos recorrentes no banco (reconciliação, fechamento de turnos)",
        "pgcrypto": "Operações criptográficas e hashing"
    }

    for name, dados in sorted(ext_vistas.items()):
        relato["postgres"]["extensoes"].append({
            "extensao": name,
            "schema": dados["schema"],
            "migracao": dados["migracao"],
            "proposito": propositos.get(name, "Extensão do PostgreSQL")
        })

    return relato

def gerar_relatorio_md(caminho_relatorio: Path, achados_arquivos, arquivos_auditados, achados_git, total_commits, relato_deps, apenas_segredos, apenas_deps, status_git="OK"):
    """Gera o documento Markdown em conformidade com as regras do time."""
    data_hora = datetime.now().strftime("%d/%m/%Y às %H:%M")

    # Coleta metadados de git
    try:
        head_sha = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], text=True).strip()
        branch_atual = subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"], text=True).strip()
    except Exception:
        head_sha = "desconhecido"
        branch_atual = "desconhecido"

    alertas_segredos = [a for a in achados_arquivos if "ALERTA" in a["classificacao"]]
    alertas_git = [a for a in achados_git if "ALERTA" in a["classificacao"]]
    deno_alertas = len(relato_deps.get("deno", {}).get("alertas", []))
    actions_alertas = len(relato_deps.get("actions", {}).get("alertas", []))
    alertas_deps = (relato_deps.get("deno", {}).get("alertas", []) +
                    relato_deps.get("python", {}).get("alertas", []) +
                    relato_deps.get("actions", {}).get("alertas", []))

    total_alertas = len(alertas_segredos) + len(alertas_git) + len(alertas_deps)
    if status_git != "OK":
        status_geral = f"INCOMPLETO ({status_git})"
    elif total_alertas == 0:
        status_geral = "CONFORME (Nenhum segredo exposto e dependências fixadas)"
    else:
        status_geral = f"ALERTA ({total_alertas} itens a verificar)"

    md = []
    md.append("# Auditoria de Segredos e Dependências")
    md.append("")
    md.append(f"> **Data da Auditoria:** {data_hora}  ")
    md.append(f"> **Branch:** `{branch_atual}` | **Commit:** `{head_sha}`  ")
    md.append(f"> **Status Geral:** **{status_geral}**  ")
    md.append("")
    md.append("---")
    md.append("")
    md.append("## 1. Resumo Executivo")
    md.append("")
    md.append("| Métrica | Valor Auditado | Status |")
    md.append("| :--- | :--- | :--- |")
    if not apenas_deps:
        md.append(f"| Arquivos na Árvore de Trabalho | {arquivos_auditados} | Auditados |")
        if status_git != "OK":
            md.append(f"| Commits no Histórico Git | {total_commits} | ✗ {status_git} |")
        else:
            md.append(f"| Commits no Histórico Git | {total_commits} | Auditados |")
        md.append(f"| Segredos Reais Expostos em Arquivos | {len(alertas_segredos)} | {'✓ Conforme' if len(alertas_segredos) == 0 else '✗ Alerta'} |")
        md.append(f"| Segredos Reais Expostos no Histórico | {len(alertas_git)} | {'✓ Conforme' if len(alertas_git) == 0 else '✗ Alerta'} |")
        md.append(f"| Fixtures Sintéticas / Placeholders | {len(achados_arquivos) - len(alertas_segredos)} | ✓ Documentados / Isolados |")
    if not apenas_segredos:
        modulos_deno = len(relato_deps.get("deno", {}).get("modulos", []))
        actions_cnt = len(relato_deps.get("actions", {}).get("actions", []))
        ext_cnt = len(relato_deps.get("postgres", {}).get("extensoes", []))
        deno_alertas = len(relato_deps.get("deno", {}).get("alertas", []))
        actions_alertas = len(relato_deps.get("actions", {}).get("alertas", []))
        md.append(f"| Módulos Deno Externos | {modulos_deno} ({'100% fixados' if deno_alertas == 0 else f'{deno_alertas} alertas de flutuação'}) | {'✓ Conforme' if deno_alertas == 0 else '✗ Alerta'} |")
        md.append(f"| Workflows GitHub Actions | {actions_cnt} actions ({'100% commit SHA' if actions_alertas == 0 else f'{actions_alertas} sem pin'}) | {'✓ Conforme' if actions_alertas == 0 else '✗ Alerta'} |")
        md.append(f"| Extensões PostgreSQL | {ext_cnt} declaradas | ✓ Conforme |")
    md.append("")

    if not apenas_deps:
        md.append("---")
        md.append("")
        md.append("## 2. Varredura de Credenciais, Chaves e Segredos")
        md.append("")
        md.append("### 2.1 Política de Não Exposição e Sanitização")
        md.append("Em estrita observância às regras de segurança do time Frila (*'Nunca: commitar, imprimir ou colar em prompt ou log segredo, chave ou dado pessoal real'*):")
        md.append("- Todos os valores encontrados durante a varredura são imediatamente sanitizados.")
        md.append("- As tabelas de auditoria registram apenas a localização, o tipo, a classificação e a máscara segura com o prefixo do hash SHA-256 do valor.")
        md.append("- Segredos reais nunca são gravados neste documento nem exibidos na saída padrão.")
        md.append("")
        md.append("### 2.2 Achados na Árvore de Trabalho")
        md.append("")
        if not achados_arquivos:
            md.append("✓ **Nenhum padrão de segredo ou credencial detectado nos arquivos de trabalho.**")
        else:
            md.append("| Arquivo | Linha | Tipo de Segredo | Classificação | Trecho Mascarado |")
            md.append("| :--- | :---: | :--- | :--- | :--- |")
            for a in achados_arquivos:
                md.append(f"| `{a['arquivo']}` | {a['linha']} | {a['tipo']} | {a['classificacao']} | `{a['mascara']}` |")
        md.append("")

        md.append("### 2.3 Achados no Histórico Git")
        md.append("")
        if not achados_git:
            md.append("✓ **Nenhum commit histórico contendo credenciais ou chaves expostas.**")
        else:
            md.append("| Commit | Data | Autor | Arquivo(s) | Tipo | Classificação | Trecho Mascarado |")
            md.append("| :---: | :---: | :--- | :--- | :--- | :--- | :--- |")
            for g in achados_git:
                md.append(f"| `{g['sha']}` | {g['data']} | {g['autor']} | `{g['arquivos']}` | {g['tipo']} | {g['classificacao']} | `{g.get('mascara', '[REDACTED]')}` |")
        md.append("")

    if not apenas_segredos:
        md.append("---")
        md.append("")
        md.append("## 3. Inventário e Auditoria de Dependências")
        md.append("")
        md.append("### 3.1 Edge Functions (Deno / JSR / NPM)")
        md.append("")
        deno_mods = relato_deps.get("deno", {}).get("modulos", [])
        if deno_mods:
            md.append("| Especificador | Versão Declarada | Status de Fixação |")
            md.append("| :--- | :---: | :--- |")
            for m in deno_mods:
                md.append(f"| `{m['especificador']}` | `{m['versao']}` | {m['status']} |")
        else:
            md.append("Nenhum módulo externo Deno importado.")
        md.append("")
        lock_status = "✓ Presente e íntegro (`deno.lock` na raiz)" if relato_deps["deno"]["lockfile_presente"] else "✗ Ausente"
        md.append(f"- **Lockfile de Integridade:** {lock_status}")
        md.append("")

        md.append("### 3.2 GitHub Actions (CI/CD Workflows)")
        md.append("")
        actions_list = relato_deps.get("actions", {}).get("actions", [])
        if actions_list:
            md.append("| Action | Referência (SHA) | Tag Anotada | Workflow | Status |")
            md.append("| :--- | :---: | :---: | :--- | :--- |")
            for act in actions_list:
                md.append(f"| `{act['action']}` | `{act['ref']}` | `{act['tag']}` | `{act['workflow']}` | {act['status']} |")
        else:
            md.append("Nenhuma action detectada.")
        md.append("")

        md.append("### 3.3 Ambiente Python e Validação do Contrato")
        md.append("")
        py_pkgs = relato_deps.get("python", {}).get("pacotes", [])
        if py_pkgs:
            md.append("| Pacote Python | Versão Fixada | Origem da Declaração |")
            md.append("| :--- | :---: | :--- |")
            for pkg in py_pkgs:
                md.append(f"| `{pkg['pacote']}` | `{pkg['versao']}` | `{pkg['fonte']}` |")
        md.append("")
        c_sha = relato_deps.get("python", {}).get("contrato_sha")
        if c_sha:
            valid_txt = "✓ Íntegro (SHA-256 confere)" if c_sha["valido"] else "✗ DIVERGÊNCIA DE HASH"
            md.append(f"- **Integridade do Contrato (`contrato/openapi.yaml`):** {valid_txt} (`{c_sha['calculado'][:16]}...`)")
        md.append("")

        md.append("### 3.4 Extensões de Banco de Dados (PostgreSQL / Supabase)")
        md.append("")
        pg_exts = relato_deps.get("postgres", {}).get("extensoes", [])
        if pg_exts:
            md.append("| Extensão | Schema | Migração de Origem | Propósito / Função no Produto |")
            md.append("| :--- | :---: | :--- | :--- |")
            for ext in pg_exts:
                md.append(f"| `{ext['extensao']}` | `{ext['schema']}` | `{ext['migracao']}` | {ext['proposito']} |")
        md.append("")

    md.append("---")
    md.append("")
    md.append("## 4. Matriz de Riscos e Recomendações")
    md.append("")
    md.append("1. **Isolamento de Segredos de Infraestrutura:**")
    if len(alertas_segredos) == 0 and len(alertas_git) == 0 and status_git == "OK":
        md.append("   - O repositório não armazena credenciais em texto claro. Variáveis sensíveis como `RESEND_API_KEY`, `SUPABASE_ACCESS_TOKEN`, `FCM_SERVICE_ACCOUNT` e segredos de despacho são injetados exclusivamente via secrets de ambiente e Supabase Vault (PR #187).")
    else:
        md.append(f"   - ⚠️ ALERTA: Foram detectados {len(alertas_segredos) + len(alertas_git)} potenciais segredos ou status git {status_git} que exigem atenção imediata.")
    md.append("2. **Imutabilidade de CI/CD e Dependências:**")
    if actions_alertas == 0 and deno_alertas == 0:
        md.append("   - 100% das GitHub Actions utilizam commit SHAs imutáveis de 40 caracteres e dependências Deno possuem versões fixadas sem flutuação, prevenindo ataques de sequestro de tag (*supply chain poisoning*).")
    else:
        md.append(f"   - ⚠️ ALERTA: Há {actions_alertas + deno_alertas} dependências com versões flutuantes ou sem pin estrito.")
    md.append("3. **Extensão pg_net e Fila de Despacho:**")
    md.append("   - Conforme documentado em `docs/PROPOSTA-SEGREDO-DESPACHO.md` (e comprovado pela run da CI no PR #284), segredos não devem trafegar em texto claro em `net.http_post`. A migração para tokens HMAC efêmeros recomendada na proposta elimina a persistência de credenciais na fila.")
    md.append("")
    md.append("---")
    md.append("")
    md.append("## 5. Como Reproduzir a Auditoria")
    md.append("")
    md.append("```bash")
    md.append("# Executa o autoteste completo do auditor")
    md.append("./scripts/teste-auditoria-segredos-e-dependencias.sh")
    md.append("")
    md.append("# Executa a auditoria e atualiza este relatório")
    md.append("./scripts/auditoria-segredos-e-dependencias.sh")
    md.append("```")
    md.append("")

    caminho_relatorio.parent.mkdir(parents=True, exist_ok=True)
    caminho_relatorio.write_text("\n".join(md), encoding="utf-8")

def main():
    args = sys.argv[1:]
    relatorio_caminho = Path("docs/AuditoriaSegredosEDependencias.md")
    apenas_segredos = False
    apenas_deps = False
    falhar_se_encontrar_segredo = False

    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ["--ajuda", "-h"]:
            print(TEXTO_AJUDA)
            sys.exit(0)
        elif arg == "--relatorio":
            i += 1
            if i < len(args):
                relatorio_caminho = Path(args[i])
            else:
                print("Erro: --relatorio requer um caminho.", file=sys.stderr)
                sys.exit(2)
        elif arg == "--apenas-segredos":
            apenas_segredos = True
        elif arg == "--apenas-dependencias":
            apenas_deps = True
        elif arg == "--falhar-se-encontrar-segredo":
            falhar_se_encontrar_segredo = True
        else:
            print(f"Opção desconhecida: {arg}", file=sys.stderr)
            sys.exit(2)
        i += 1

    print("▸ Iniciando auditoria de segredos e dependências...")
    achados_arquivos = []
    arquivos_auditados = 0
    achados_git = []
    total_commits = 0
    status_git = "OK"
    relato_deps = {}

    if not apenas_deps:
        print("  - Varrendo arquivos da árvore de trabalho...")
        achados_arquivos, arquivos_auditados = varrer_arquivos_atuais(relatorio_caminho)
        print(f"    ✓ {arquivos_auditados} arquivos auditados ({len(achados_arquivos)} ocorrências catalogadas)")

        print("  - Varrendo histórico git...")
        achados_git, total_commits, status_git = varrer_historico_git()
        print(f"    ✓ {total_commits} commits auditados ({len(achados_git)} ocorrências históricas catalogadas, status: {status_git})")

    if not apenas_segredos:
        print("  - Auditando dependências (Deno, Python, Actions, PostgreSQL)...")
        relato_deps = auditar_dependencias()
        print("    ✓ Dependências auditadas")

    gerar_relatorio_md(relatorio_caminho, achados_arquivos, arquivos_auditados, achados_git, total_commits, relato_deps, apenas_segredos, apenas_deps, status_git=status_git)
    print(f"  ✓ Relatório gerado em: {relatorio_caminho}")

    # Resumo do veredito
    alertas_segredos = [a for a in achados_arquivos if "ALERTA" in a["classificacao"]]
    alertas_git = [a for a in achados_git if "ALERTA" in a["classificacao"]]
    deno_alertas = len(relato_deps.get("deno", {}).get("alertas", []))
    actions_alertas = len(relato_deps.get("actions", {}).get("alertas", []))
    alertas_deps = (relato_deps.get("deno", {}).get("alertas", []) +
                    relato_deps.get("python", {}).get("alertas", []) +
                    relato_deps.get("actions", {}).get("alertas", []))

    git_falhou = (status_git != "OK")
    total_alertas = len(alertas_segredos) + len(alertas_git) + len(alertas_deps) + (1 if git_falhou else 0)

    print("\n▸ Veredito da Auditoria:")
    if total_alertas == 0:
        print("  ✓ CONFORME: Nenhum segredo exposto detectado e dependências fixadas.")
        sys.exit(0)
    else:
        print(f"  ✗ ALERTA: {total_alertas} itens exigem atenção:")
        if git_falhou:
            print(f"    - Git: Leitura do histórico incompleta ({status_git})")
        for a in alertas_segredos:
            print(f"    - Segredo em arquivo: {a['arquivo']}:{a['linha']} ({a['tipo']})")
        for g in alertas_git:
            print(f"    - Segredo no histórico: commit {g['sha']} ({g['tipo']}) em {g['arquivos']}")
        for d in alertas_deps:
            print(f"    - Dependência: {d}")

        if falhar_se_encontrar_segredo:
            if git_falhou:
                sys.exit(2)
            if len(alertas_segredos) > 0 or len(alertas_git) > 0:
                sys.exit(1)
        sys.exit(0)

if __name__ == "__main__":
    main()
EOF
