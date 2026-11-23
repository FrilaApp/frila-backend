#!/usr/bin/env python3
"""
scripts/vigia_saude.py

Vigia externo da Edge Function `saude` do frila-prod (cartão bB0tV5R8; docs/RunbookWalESlot.md, seção 6).
Chamado a cada 10 min pelo workflow .github/workflows/vigia-saude.yml.

O que faz, em ordem:
  1. GET na URL da variável FRILA_PROD_URL_SAUDE (env URL_SAUDE). Só lê; não grava nada no Prod.
  2. Se não vier HTTP 200 com {"ok": true, ...}, espera ~60 s e tenta de novo. Só a segunda falha conta
     (evita alarme por piscada, deploy ou projeto acordando).
  3. Lê as execuções anteriores do próprio workflow (API do Actions, GITHUB_TOKEN) para decidir se avisa.
     O estado é a conclusão de cada execução: este script sai 1 quando a saúde está fora, então
     "execução vermelha" = "estava fora". Nada é gravado em lugar nenhum.
  4. Avisa o Slack pelo scripts/notificar-slack.sh, sem enxurrada:
       - primeiro aviso: a saúde caiu agora (a execução anterior estava boa ou não existe);
       - lembrete: uma vez a cada ~1 h de queda contínua;
       - volta ao normal: uma vez, na primeira execução boa depois da queda;
       - vigia atrasado: a última execução do vigia é mais velha que o limite (padrão 45 min).

Saída: 0 se a saúde respondeu bem; 1 se está fora (a execução fica vermelha de propósito: é o registro
do estado). Falha de Slack ou de leitura do histórico NUNCA muda a saída: só avisa no log.

Segurança: a URL e o webhook não são impressos. O corpo público da `saude` não traz nome de job; só o campo
`status` (texto curto) entra na mensagem. Zero PII.

Uso local (sem rede do Prod): ver scripts/teste-vigia-saude.sh.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
NOTIFICAR = RAIZ / "scripts" / "notificar-slack.sh"
WORKFLOW_PADRAO = "vigia-saude.yml"
MAX_PAGINAS_HISTORICO = 3  # 300 execuções = ~50 h de histórico a cada 10 min


@dataclass
class Resultado:
    ok: bool
    motivo: str = ""


@dataclass
class Execucao:
    """Uma execução anterior do vigia que chegou a medir a saúde (sucesso ou falha)."""

    criado_em: datetime
    ok: bool


def agora_utc() -> datetime:
    return datetime.now(timezone.utc)


def parse_data(texto: str) -> datetime:
    return datetime.fromisoformat(texto.replace("Z", "+00:00"))


def formatar_duracao(segundos: float) -> str:
    minutos = int(segundos // 60)
    if minutos < 60:
        return f"{minutos} min"
    horas, resto = divmod(minutos, 60)
    return f"{horas} h {resto:02d} min" if resto else f"{horas} h"


# ─────────────────────────────────────────────────────────────────────────────
# 1. Sonda
# ─────────────────────────────────────────────────────────────────────────────
def sondar(url: str, timeout: float) -> Resultado:
    """Um GET na `saude`. Nunca levanta exceção e nunca devolve a URL."""
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "frila-vigia-saude"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            codigo = resp.getcode()
            corpo = resp.read(65536)
    except urllib.error.HTTPError as e:
        codigo = e.code
        try:
            corpo = e.read(65536)
        except Exception:
            corpo = b""
    except urllib.error.URLError as e:
        if isinstance(e.reason, (TimeoutError, socket.timeout)):
            return Resultado(False, f"sem resposta em {timeout:g} s")
        return Resultado(False, f"erro de rede ({type(e.reason).__name__})")
    except (TimeoutError, socket.timeout):
        return Resultado(False, f"sem resposta em {timeout:g} s")
    except Exception as e:  # noqa: BLE001 - qualquer outra falha também é "fora do ar"
        return Resultado(False, f"erro ao consultar ({type(e).__name__})")

    try:
        dados = json.loads(corpo.decode("utf-8"))
    except Exception:
        dados = None
    status = None
    if isinstance(dados, dict):
        s = dados.get("status")
        if isinstance(s, str) and re.fullmatch(r"[a-z_]{1,30}", s):
            status = s

    if codigo == 200:
        if isinstance(dados, dict) and dados.get("ok") is True:
            return Resultado(True)
        if dados is None:
            return Resultado(False, "HTTP 200 com corpo que não é JSON")
        return Resultado(False, "HTTP 200 sem ok=true")
    detalhe = f" (status: {status})" if status else ""
    return Resultado(False, f"HTTP {codigo}{detalhe}")


def medir(url: str | None, timeout: float, espera: float, permitir_http: bool) -> Resultado:
    """Sonda; se falhar, espera e sonda de novo. Só a segunda falha conta."""
    if not url or not url.strip():
        return Resultado(
            False,
            "a variável de repositório FRILA_PROD_URL_SAUDE não está configurada "
            "(Settings → Secrets and variables → Actions → Variables)",
        )
    url = url.strip()
    esquemas = ("https://", "http://") if permitir_http else ("https://",)
    if not url.startswith(esquemas):
        return Resultado(False, "a variável FRILA_PROD_URL_SAUDE precisa começar com https://")

    primeira = sondar(url, timeout)
    if primeira.ok:
        return primeira
    print(f"::warning::Primeira tentativa falhou ({primeira.motivo}); confirmando em {espera:g} s.")
    time.sleep(espera)
    segunda = sondar(url, timeout)
    if segunda.ok:
        print("::notice::A segunda tentativa respondeu 200 ok=true: foi uma piscada, sem alerta.")
        return segunda
    return segunda


# ─────────────────────────────────────────────────────────────────────────────
# 2. Histórico (execuções anteriores do próprio workflow)
# ─────────────────────────────────────────────────────────────────────────────
def interpretar_execucoes(runs: list[dict], run_id: str | None, antes_de: datetime | None) -> list[Execucao]:
    """Execuções concluídas com sucesso ou falha, da mais nova para a mais antiga, sem a atual."""
    saida: list[Execucao] = []
    for r in runs:
        if run_id and str(r.get("id")) == str(run_id):
            continue
        conclusao = r.get("conclusion")
        if conclusao not in ("success", "failure"):
            continue  # cancelada, pulada, expirada: não diz nada sobre a saúde
        criado = parse_data(r["created_at"])
        if antes_de and criado >= antes_de:
            continue
        saida.append(Execucao(criado, conclusao == "success"))
    saida.sort(key=lambda e: e.criado_em, reverse=True)
    return saida


def _api(caminho: str, token: str) -> dict:
    req = urllib.request.Request(
        f"https://api.github.com{caminho}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "frila-vigia-saude",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8"))


def buscar_historico_api(repo: str, run_id: str, workflow: str, token: str) -> tuple[list[Execucao], datetime]:
    """Devolve (execuções anteriores, hora de criação da execução atual)."""
    atual = parse_data(_api(f"/repos/{repo}/actions/runs/{run_id}", token)["created_at"])
    runs: list[dict] = []
    for pagina in range(1, MAX_PAGINAS_HISTORICO + 1):
        dados = _api(
            f"/repos/{repo}/actions/workflows/{workflow}/runs?status=completed&per_page=100&page={pagina}",
            token,
        )
        lote = dados.get("workflow_runs", [])
        runs.extend(lote)
        if len(lote) < 100:
            break
    return interpretar_execucoes(runs, run_id, atual), atual


# ─────────────────────────────────────────────────────────────────────────────
# 3. Decisão (função pura, sem rede nem relógio)
# ─────────────────────────────────────────────────────────────────────────────
def decidir(
    ok_agora: bool,
    historico: list[Execucao] | None,
    agora: datetime,
    lembrete_s: float = 3600.0,
    limite_atraso_s: float = 45 * 60.0,
) -> list[tuple[str, float]]:
    """
    Devolve a lista de avisos a mandar: ("primeiro" | "lembrete" | "recuperado" | "atraso", segundos).
    `historico` é da mais nova para a mais antiga e não inclui a execução atual; None = não deu para ler.
    `agora` é a hora de criação da execução atual (a mesma base das anteriores, para o lembrete não repetir).
    """
    acoes: list[tuple[str, float]] = []

    if historico is None:
        # Sem histórico não dá para saber se já avisamos. Melhor um aviso a mais que silêncio.
        if not ok_agora:
            acoes.append(("primeiro", 0.0))
        return acoes

    if historico:
        parado = (agora - historico[0].criado_em).total_seconds()
        if parado > limite_atraso_s:
            acoes.append(("atraso", parado))

    queda: list[Execucao] = []
    for e in historico:
        if e.ok:
            break
        queda.append(e)

    if ok_agora:
        if queda:
            acoes.append(("recuperado", (agora - queda[-1].criado_em).total_seconds()))
        return acoes

    if not queda:
        acoes.append(("primeiro", 0.0))
        return acoes

    inicio = queda[-1].criado_em
    antes = (queda[0].criado_em - inicio).total_seconds()
    depois = (agora - inicio).total_seconds()
    if depois // lembrete_s > antes // lembrete_s:
        acoes.append(("lembrete", depois))
    return acoes


# ─────────────────────────────────────────────────────────────────────────────
# 4. Slack
# ─────────────────────────────────────────────────────────────────────────────
def montar_aviso(acao: str, segundos: float, motivo: str, limite_atraso_s: float) -> dict:
    guia = "Runbook: `docs/RunbookWalESlot.md` (seções 3 e 6)."
    if acao == "primeiro":
        return {
            "tipo": "alerta_banco",
            "titulo": "Prod: a função saude não responde",
            "mensagem": (
                "A `saude` do frila-prod não respondeu 200 com `ok: true` em duas tentativas com ~60 s de intervalo.\n"
                f"*Motivo:* {motivo}.\n"
                "Próximo aviso: lembrete a cada ~1 h enquanto durar e um aviso quando voltar ao normal. "
                "Abra o projeto no painel do Supabase antes de supor pausa. " + guia
            ),
        }
    if acao == "lembrete":
        return {
            "tipo": "alerta_banco",
            "titulo": "Prod: a função saude continua sem responder",
            "mensagem": (
                f"A `saude` do frila-prod segue fora há pelo menos {formatar_duracao(segundos)}.\n"
                f"*Último motivo:* {motivo}.\n" + guia
            ),
        }
    if acao == "recuperado":
        return {
            "tipo": "alerta_banco_recuperado",
            "titulo": "Prod: a função saude voltou ao normal",
            "mensagem": (
                f"A `saude` do frila-prod voltou a responder 200 com `ok: true` depois de cerca de {formatar_duracao(segundos)} "
                "de queda (medida a cada 10 min)."
            ),
        }
    return {  # atraso
        "tipo": "generico",
        "status": "aviso",
        "titulo": "Vigia da saúde ficou sem rodar",
        "mensagem": (
            f"A última execução do vigia da `saude` foi há {formatar_duracao(segundos)} (limite: {formatar_duracao(limite_atraso_s)}). "
            "O agendamento do GitHub atrasou ou pulou execuções. Se repetir, abra Actions → Vigia da saúde do Prod "
            "e confira se o workflow não foi desativado por inatividade (60 dias). Enquanto isso, o Prod não está sendo vigiado."
        ),
    }


def avisar(aviso: dict, url_execucao: str | None, dry_run: bool) -> None:
    cmd = [str(NOTIFICAR), "--tipo", aviso["tipo"], "--titulo", aviso["titulo"], "--mensagem", aviso["mensagem"], "--ambiente", "prod"]
    if aviso.get("status"):
        cmd += ["--status", aviso["status"]]
    if url_execucao:
        cmd += ["--url", url_execucao]
    if dry_run:
        cmd.append("--dry-run")
    try:
        resultado = subprocess.run(cmd, check=False, timeout=60)
        if resultado.returncode != 0:
            print(f"::warning::O envio ao Slack terminou com código {resultado.returncode}.", file=sys.stderr)
    except Exception as e:  # noqa: BLE001
        print(f"::warning::Não consegui chamar o notificador do Slack ({type(e).__name__}).", file=sys.stderr)


def escrever_resumo(linhas: list[str]) -> None:
    caminho = os.environ.get("GITHUB_STEP_SUMMARY")
    if not caminho:
        return
    try:
        with open(caminho, "a", encoding="utf-8") as f:
            f.write("\n".join(linhas) + "\n")
    except OSError:
        pass


# ─────────────────────────────────────────────────────────────────────────────
def main() -> int:
    p = argparse.ArgumentParser(description="Vigia da função saude do frila-prod (GitHub Actions → Slack)")
    p.add_argument("--url", default=os.environ.get("URL_SAUDE"), help="URL da saude (padrão: env URL_SAUDE)")
    p.add_argument("--timeout", type=float, default=20.0, help="timeout de cada GET, em s")
    p.add_argument("--espera-confirmacao", type=float, default=60.0, help="espera antes da 2ª tentativa, em s")
    p.add_argument("--lembrete-segundos", type=float, default=3600.0)
    p.add_argument("--limite-atraso-min", type=float, default=45.0)
    p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    p.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID"))
    p.add_argument("--workflow", default=WORKFLOW_PADRAO)
    p.add_argument("--historico-json", help="JSON da API do Actions (para teste); no lugar da chamada à API")
    p.add_argument("--agora", help="ISO 8601 da execução atual (só com --historico-json, para teste)")
    p.add_argument("--permitir-http", action="store_true", help="aceita http:// (só para teste local)")
    p.add_argument("--dry-run", action="store_true", help="imprime o aviso em vez de mandar ao Slack")
    args = p.parse_args()

    resultado = medir(args.url, args.timeout, args.espera_confirmacao, args.permitir_http)

    # Histórico: da API (produção) ou de um arquivo (teste). Falhar aqui não derruba o vigia.
    historico: list[Execucao] | None = None
    agora = agora_utc()
    try:
        if args.historico_json:
            if args.agora:
                agora = parse_data(args.agora)
            runs = json.loads(Path(args.historico_json).read_text(encoding="utf-8")).get("workflow_runs", [])
            historico = interpretar_execucoes(runs, args.run_id, agora)
        else:
            token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
            if not (token and args.repo and args.run_id):
                raise RuntimeError("faltam GITHUB_TOKEN, GITHUB_REPOSITORY ou GITHUB_RUN_ID")
            historico, agora = buscar_historico_api(args.repo, args.run_id, args.workflow, token)
    except Exception as e:  # noqa: BLE001
        print(f"::warning::Não consegui ler as execuções anteriores ({type(e).__name__}: {e}); decidindo sem histórico.", file=sys.stderr)

    limite_s = args.limite_atraso_min * 60.0
    acoes = decidir(resultado.ok, historico, agora, args.lembrete_segundos, limite_s)

    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    url_execucao = f"{server}/{args.repo}/actions/runs/{args.run_id}" if args.repo and args.run_id else None

    if resultado.ok:
        print("✓ saude respondeu 200 com ok=true.")
    else:
        print(f"::error::A saude do frila-prod está fora: {resultado.motivo}.")
    nomes = ", ".join(a for a, _ in acoes) or "nenhum (sem enxurrada)"
    print(f"Avisos desta execução: {nomes}.")

    for acao, segundos in acoes:
        avisar(montar_aviso(acao, segundos, resultado.motivo, limite_s), url_execucao, args.dry_run)

    escrever_resumo(
        [
            "### Vigia da saúde do Prod",
            "",
            "`saude` respondeu 200 com `ok: true`." if resultado.ok else f"`saude` **fora**: {resultado.motivo}.",
            f"Avisos ao Slack nesta execução: {nomes}.",
        ]
    )
    return 0 if resultado.ok else 1


if __name__ == "__main__":
    sys.exit(main())
