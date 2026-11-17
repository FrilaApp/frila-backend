#!/usr/bin/env python3
"""
scripts/notificar_slack.py

Envio de avisos operacionais da equipe no Slack via Webhook (Cartões zYC0uhH2 e bB0tV5R8).

Casos atendidos:
  1. Falha de CI (develop, main e branches de teste).
  2. Entrega:
     - Tag aguardando aprovação manual em Produção.
     - Tag aplicada com sucesso em Produção.
     - Falha de publicação (frila-dev ou frila-prod).
  3. Backup diário do frila-prod:
     - Sucesso diário resumido (tamanho, integridade, storage).
     - Falha de backup.
     - Aviso de backup ausente (> 30 h sem sucesso).
  4. Mantém o Prod vivo / Alertas de banco (Fase 2 de bB0tV5R8, compatível com probe pg_cron):
     - Falha de integridade/jobs atrasados.
     - Recuperação ("voltou").
  5. Aviso manual (--tipo aviso_manual): texto livre de quem dispara o workflow, com `&`, `<` e `>` escapados
     (sem menção nem link) e limitado a 1000 caracteres.

Segurança e Privacidade (RN15):
  - Zero PII: nenhuma mensagem transporta nome de usuário, telefone, e-mail ou dados pessoais.
  - O webhook é lido estritamente de variável de ambiente (SLACK_WEBHOOK_URL ou SLACK_ALERTAS_WEBHOOK).
  - Sem o segredo configurado, o script emite aviso no log e encerra com código 0 (o job não quebra).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

LIMITE_AVISO_MANUAL = 1000


def obter_webhook_url(args_url: str | None) -> str | None:
    """Retorna a URL do webhook do Slack a partir dos argumentos ou ambiente."""
    if args_url and args_url.strip():
        return args_url.strip()

    env_url = os.environ.get("SLACK_WEBHOOK_URL") or os.environ.get("SLACK_ALERTAS_WEBHOOK")
    if env_url and env_url.strip():
        return env_url.strip()

    return None


_ESCAPES_MRKDWN = {"&": "&amp;", "<": "&lt;", ">": "&gt;"}


def escapar_mrkdwn_limitado(texto: str, limite: int) -> str:
    """
    Torna o texto livre inerte para o Slack e o limita a `limite` caracteres já escapados.

    O Slack trata `<...>` como marcação: `<!channel>`, `<!here>`, `<!everyone>` e `<!subteam^ID>`
    avisam o canal ou um grupo, `<@ID>` avisa uma pessoa, `<#ID>` e `<url|rótulo>` viram link.
    A regra documentada do Slack é trocar só `&`, `<` e `>` por `&amp;`, `&lt;` e `&gt;`; o Slack
    mostra os caracteres originais, sem interpretá-los. Vale para todos de uma vez, sem lista de menções.
    URL solta continua virando link sozinha. O corte é feito por caractere original, para não partir
    uma entidade ao meio.
    """
    pecas = [_ESCAPES_MRKDWN.get(c, c) for c in texto]
    if sum(len(p) for p in pecas) <= limite:
        return "".join(pecas)
    saida: list[str] = []
    usado = 0
    for peca in pecas:
        if usado + len(peca) > limite - 1:
            break
        saida.append(peca)
        usado += len(peca)
    return "".join(saida) + "…"


def construir_payload(
    titulo: str,
    mensagem: str,
    status: str = "aviso",
    url: str | None = None,
    ambiente: str | None = None,
    branch: str | None = None,
    sha: str | None = None,
    workflow: str | None = None,
) -> dict:
    """Monta o payload JSON do Slack no formato Block Kit padronizado."""
    icones = {
        "falha": "🔴",
        "sucesso": "🟢",
        "aguardando": "🟡",
        "aviso": "⚠️",
    }
    icone = icones.get(status.lower(), "ℹ️")

    # Header
    titulo_formatado = f"{icone} {titulo.strip()}"
    if len(titulo_formatado) > 150:
        titulo_formatado = titulo_formatado[:147] + "..."

    blocks = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": titulo_formatado,
                "emoji": True,
            },
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": mensagem.strip(),
            },
        },
    ]

    # Metadados de contexto
    elementos_contexto = []
    if ambiente:
        elementos_contexto.append(f"*Ambiente:* `{ambiente}`")
    if workflow:
        elementos_contexto.append(f"*Workflow:* `{workflow}`")
    if branch:
        branch_curto = branch.replace("refs/heads/", "").replace("refs/tags/", "")
        elementos_contexto.append(f"*Branch/Ref:* `{branch_curto}`")
    if sha:
        sha_curto = sha[:7]
        elementos_contexto.append(f"*Commit:* `{sha_curto}`")

    agora_utc = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    elementos_contexto.append(f"*Horário:* {agora_utc}")

    if elementos_contexto:
        blocks.append(
            {
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": " • ".join(elementos_contexto),
                    }
                ],
            }
        )

    # Link para GitHub Actions se fornecido
    if url and url.strip():
        blocks.append(
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": f"🔗 <{url.strip()}|Ver execução no GitHub Actions>",
                },
            }
        )

    return {
        "text": f"{titulo_formatado}: {mensagem.strip()}",
        "blocks": blocks,
    }


def enviar_slack(webhook_url: str, payload: dict, strict: bool = False) -> bool:
    """Envia o payload via HTTP POST para a URL do webhook."""
    dados = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=dados,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            codigo = resp.getcode()
            if codigo == 200:
                print("✓ Notificação enviada ao Slack com sucesso.")
                return True
            else:
                msg = f"::warning::Slack webhook respondeu HTTP {codigo}"
                print(msg, file=sys.stderr)
                if strict:
                    sys.exit(1)
                return False
    except urllib.error.HTTPError as e:
        msg = f"::warning::Erro HTTP ao enviar notificação ao Slack: {e.code} {e.reason}"
        print(msg, file=sys.stderr)
        if strict:
            sys.exit(1)
        return False
    except Exception as e:
        msg = f"::warning::Falha de rede ao conectar ao Slack: {e}"
        print(msg, file=sys.stderr)
        if strict:
            sys.exit(1)
        return False


def processar_evento_workflow_run(args) -> tuple[dict | None, str | None]:
    """
    Avalia a conclusão do workflow informado via workflow_run e retorna
    (payload, status) se deve notificar, ou (None, None) se deve silenciar.
    """
    nome = (args.workflow_nome or "").strip()
    conclusao = (args.conclusao or "").strip().lower()
    branch = (args.branch or "").strip()
    sha = (args.sha or "").strip()
    url = (args.url or "").strip()

    branch_nome = branch.replace("refs/heads/", "").replace("refs/tags/", "")

    # 1. CI
    if nome == "CI":
        if conclusao == "failure":
            # Notifica falha na develop, na main ou em branches de teste/ci
            eh_ramo_relevante = (
                branch_nome in ("develop", "main")
                or branch_nome.startswith("test")
                or branch_nome.startswith("teste")
                or branch_nome.startswith("ci")
            )
            if eh_ramo_relevante:
                titulo = f"CI Quebrou: {branch_nome}"
                mensagem = f"A execução da CI falhou na branch `{branch_nome}` ({sha[:7] if sha else 'HEAD'}). Verifique os testes ou portões que fecharam."
                payload = construir_payload(
                    titulo=titulo,
                    mensagem=mensagem,
                    status="falha",
                    url=url,
                    ambiente="ci",
                    branch=branch_nome,
                    sha=sha,
                    workflow=nome,
                )
                return payload, "falha"
        # Sucesso de CI é silencioso
        return None, None

    # 2. Entrega
    if nome == "Entrega":
        if conclusao == "failure":
            titulo = f"Falha na Entrega: {branch_nome or 'develop'}"
            mensagem = f"O workflow de Entrega falhou ({sha[:7] if sha else 'commit'}). Verifique migrações, Edge Functions ou desvio de esquema."
            payload = construir_payload(
                titulo=titulo,
                mensagem=mensagem,
                status="falha",
                url=url,
                ambiente="prod" if "backend-v" in branch_nome else "dev",
                branch=branch_nome,
                sha=sha,
                workflow=nome,
            )
            return payload, "falha"
        elif conclusao == "success":
            # Sucesso de tag de produção
            if branch_nome.startswith("backend-v") or branch_nome.startswith("v"):
                titulo = f"Tag Aplicada em Produção: {branch_nome}"
                mensagem = f"A tag `{branch_nome}` foi aplicada com sucesso no ambiente `frila-prod`."
                payload = construir_payload(
                    titulo=titulo,
                    mensagem=mensagem,
                    status="sucesso",
                    url=url,
                    ambiente="prod",
                    branch=branch_nome,
                    sha=sha,
                    workflow=nome,
                )
                return payload, "sucesso"
        # Sucesso de entrega no dev é silencioso
        return None, None

    # 3. Backup diário do frila-prod
    if nome in ("Backup diário do frila-prod", "backup-prod"):
        if conclusao == "failure":
            titulo = "Falha no Backup Diário do frila-prod"
            mensagem = "O backup diário de produção falhou. Verifique storage S3/R2/B2, chave age e conexão ao banco."
            payload = construir_payload(
                titulo=titulo,
                mensagem=mensagem,
                status="falha",
                url=url,
                ambiente="prod",
                branch=branch_nome,
                sha=sha,
                workflow=nome,
            )
            return payload, "falha"
        elif conclusao == "success":
            titulo = "Backup Diário do frila-prod Concluído"
            mensagem = "Backup lógico empacotado (pacote v2: dump, extensões e formato) cifrado com chave age e enviado com sucesso ao storage."
            payload = construir_payload(
                titulo=titulo,
                mensagem=mensagem,
                status="sucesso",
                url=url,
                ambiente="prod",
                branch=branch_nome,
                sha=sha,
                workflow=nome,
            )
            return payload, "sucesso"
        return None, None

    # 4. Mantém o Prod vivo
    if nome in ("Mantém o Prod vivo", "mantem-prod-vivo"):
        if conclusao == "failure":
            titulo = "Prod Vivo Falhou (Alerta de Disponibilidade)"
            mensagem = "O probe diário na função `saude` do frila-prod falhou ou não retornou HTTP 200 com ok=true. O banco pode estar pausado ou instável."
            payload = construir_payload(
                titulo=titulo,
                mensagem=mensagem,
                status="falha",
                url=url,
                ambiente="prod",
                branch=branch_nome,
                sha=sha,
                workflow=nome,
            )
            return payload, "falha"
        # Sucesso é silencioso
        return None, None

    # Outros workflows: notifica apenas se falhar
    if conclusao == "failure":
        titulo = f"Falha no Workflow {nome}"
        mensagem = f"A execução do workflow `{nome}` falhou na branch `{branch_nome}`."
        payload = construir_payload(
            titulo=titulo,
            mensagem=mensagem,
            status="falha",
            url=url,
            branch=branch_nome,
            sha=sha,
            workflow=nome,
        )
        return payload, "falha"

    return None, None


def checar_backup_30h(
    limite_horas: float = 30.0,
    json_input: str | None = None,
    webhook_url: str | None = None,
    strict: bool = False,
    dry_run: bool = False,
) -> int:
    """
    Verifica se o último backup do frila-prod com sucesso ocorreu há mais de limite_horas (30h).
    Se tiver mais de 30h (ou nenhum backup for encontrado), dispara aviso no Slack.
    """
    runs = None
    if json_input:
        try:
            runs = json.loads(json_input)
        except Exception as e:
            print(f"::error::Falha ao ler json_input: {e}", file=sys.stderr)
            return 1
    else:
        # Chama a CLI gh para obter o último run com sucesso
        cmd = [
            "gh",
            "run",
            "list",
            "--workflow",
            "backup-prod.yml",
            "--status",
            "success",
            "--limit",
            "1",
            "--json",
            "createdAt,url,databaseId",
        ]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, check=True)
            runs = json.loads(res.stdout)
        except Exception as e:
            print(f"::warning::Falha ao consultar gh run list para backup: {e}", file=sys.stderr)
            # Sem gh ou sem permissão, não quebra
            return 0

    agora = datetime.now(timezone.utc)

    if not runs or len(runs) == 0:
        titulo = "⚠️ Alerta de Backup: Nenhum backup recente encontrado"
        mensagem = f"Nenhuma execução com sucesso de `backup-prod.yml` foi localizada nos últimos registros. O limite seguro é de {limite_horas} horas."
        payload = construir_payload(
            titulo=titulo,
            mensagem=mensagem,
            status="aviso",
            ambiente="prod",
            workflow="Backup diário do frila-prod",
        )
        return emitir_ou_dry_run(payload, webhook_url, strict, dry_run)

    ultimo = runs[0]
    criado_em_str = ultimo.get("createdAt")
    url_run = ultimo.get("url")

    # Tratamento de timestamp ISO8601 UTC
    try:
        # Substitui Z por +00:00 se necessário
        criado_em_str_clean = criado_em_str.replace("Z", "+00:00")
        criado_em = datetime.fromisoformat(criado_em_str_clean)
    except Exception as e:
        print(f"::error::Erro ao converter timestamp '{criado_em_str}': {e}", file=sys.stderr)
        return 1

    idade_segundos = (agora - criado_em).total_seconds()
    idade_horas = idade_segundos / 3600.0

    if idade_horas > limite_horas:
        titulo = f"⚠️ Alerta: Backup do frila-prod ausente há {idade_horas:.1f} h"
        mensagem = (
            f"O último backup com sucesso do `frila-prod` foi registrado há {idade_horas:.1f} horas "
            f"({criado_em.strftime('%Y-%m-%d %H:%M UTC')}). O limite operacional tolerado sem backup é de {limite_horas} horas."
        )
        payload = construir_payload(
            titulo=titulo,
            mensagem=mensagem,
            status="aviso",
            url=url_run,
            ambiente="prod",
            workflow="Backup diário do frila-prod",
        )
        return emitir_ou_dry_run(payload, webhook_url, strict, dry_run)
    else:
        print(f"✓ Último backup com sucesso foi há {idade_horas:.1f} h (dentro da janela de {limite_horas} h).")
        return 0


def emitir_ou_dry_run(
    payload: dict,
    webhook_url: str | None,
    strict: bool = False,
    dry_run: bool = False,
) -> int:
    """Valida segredo, emite aviso amigável se ausente, ou envia notificação."""
    if dry_run:
        print("=== [DRY-RUN] Notificação do Slack ===")
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    if not webhook_url:
        print(
            "::warning::SLACK_WEBHOOK_URL não configurado nos segredos do repositório. Notificação do Slack ignorada.",
            file=sys.stderr,
        )
        if strict:
            return 1
        return 0

    sucesso = enviar_slack(webhook_url, payload, strict=strict)
    return 0 if sucesso else (1 if strict else 0)


def main() -> int:
    parser = argparse.ArgumentParser(description="Notificador Slack do Frila (CI, Entrega, Backup e Banco)")

    # Parâmetros gerais
    parser.add_argument("--webhook-url", help="URL do Webhook do Slack (se omitido, lê SLACK_WEBHOOK_URL)")
    parser.add_argument("--dry-run", action="store_true", help="Apenas imprime o payload JSON sem enviar")
    parser.add_argument("--strict", action="store_true", help="Falha com código 1 caso o webhook ou envio falhe")

    # Modo Workflow Run (Centralizado)
    parser.add_argument("--evento-workflow-run", action="store_true", help="Processa evento github.event.workflow_run")
    parser.add_argument("--workflow-nome", help="Nome do workflow de origem")
    parser.add_argument("--conclusao", help="Conclusão do workflow (success, failure, etc.)")

    # Modo Alerta Ausente de Backup (30h)
    parser.add_argument("--checar-backup-30h", action="store_true", help="Verifica se o último backup tem > 30h")
    parser.add_argument("--limite-horas", type=float, default=30.0, help="Limite em horas para backup ausente (padrão: 30.0)")
    parser.add_argument("--json-input", help="JSON mock com execuções do workflow para testes")

    # Modo Direto / Manual
    parser.add_argument("--tipo", choices=[
        "ci_falha",
        "entrega",
        "backup_sucesso",
        "backup_falha",
        "backup_ausente",
        "alerta_banco",
        "alerta_banco_recuperado",
        "aviso_manual",
        "generico",
    ], help="Tipo padronizado de mensagem")
    parser.add_argument("--status", choices=["sucesso", "falha", "aguardando", "aviso"], default="aviso")
    parser.add_argument("--titulo", help="Título da notificação")
    parser.add_argument("--mensagem", help="Corpo da mensagem (texto objetivo sem PII)")
    parser.add_argument("--url", help="Link do GitHub Actions ou documentação")
    parser.add_argument("--ambiente", choices=["prod", "dev", "ci"], help="Ambiente relacionado")
    parser.add_argument("--branch", help="Nome da branch ou ref")
    parser.add_argument("--sha", help="SHA do commit")

    args = parser.parse_args()

    webhook_url = obter_webhook_url(args.webhook_url)

    # 1. Modo Verificação de Backup 30h
    if args.checar_backup_30h:
        return checar_backup_30h(
            limite_horas=args.limite_horas,
            json_input=args.json_input,
            webhook_url=webhook_url,
            strict=args.strict,
            dry_run=args.dry_run,
        )

    # 2. Modo Evento workflow_run
    if args.evento_workflow_run:
        payload, status = processar_evento_workflow_run(args)
        if payload is None:
            # Caso silencioso (ex: sucesso de CI ou sucesso de entrega em dev)
            print(f"ℹ Workflow '{args.workflow_nome}' com conclusão '{args.conclusao}' não requer aviso no Slack (silencioso).")
            return 0
        return emitir_ou_dry_run(payload, webhook_url, strict=args.strict, dry_run=args.dry_run)

    # 3. Modo Direto / Específico
    status = args.status
    titulo = args.titulo
    mensagem = args.mensagem or ""

    if args.tipo == "ci_falha":
        status = "falha"
        titulo = titulo or f"CI Quebrou: {args.branch or 'develop'}"
        mensagem = mensagem or f"A execução da CI falhou ({args.sha[:7] if args.sha else 'HEAD'})."
    elif args.tipo == "entrega":
        if status == "aguardando":
            titulo = titulo or f"Tag Aguardando Aprovação: {args.branch or 'backend-v*'}"
            mensagem = mensagem or "Uma tag de produção foi enviada e aguarda aprovação manual no Environment frila-prod."
        elif status == "sucesso":
            titulo = titulo or f"Tag Aplicada em Produção: {args.branch or 'backend-v*'}"
            mensagem = mensagem or "A tag de produção foi aplicada com sucesso no frila-prod."
        elif status == "falha":
            titulo = titulo or f"Falha na Entrega: {args.branch or 'develop'}"
            mensagem = mensagem or "A publicação no ambiente falhou."
    elif args.tipo == "backup_sucesso":
        status = "sucesso"
        titulo = titulo or "Backup Diário do frila-prod Concluído"
        mensagem = mensagem or "Backup lógico cifrado do frila-prod concluído e salvo no armazenamento externo com sucesso."
    elif args.tipo == "backup_falha":
        status = "falha"
        titulo = titulo or "Falha no Backup Diário do frila-prod"
        mensagem = mensagem or "O backup diário de produção falhou. Verifique storage S3 e credenciais."
    elif args.tipo == "backup_ausente":
        status = "aviso"
        titulo = titulo or "⚠️ Alerta: Backup do frila-prod Ausente (>30h)"
        mensagem = mensagem or "Nenhum backup de produção com sucesso foi registrado nas últimas 30 horas."
    elif args.tipo == "alerta_banco":
        status = "falha"
        titulo = titulo or "🚨 Alerta de Banco: Jobs pg_cron Atrasados"
        mensagem = mensagem or "O monitor externo detectou jobs essenciais de despacho ou vigia inativos ou atrasados."
    elif args.tipo == "alerta_banco_recuperado":
        status = "sucesso"
        titulo = titulo or "🟢 Alerta de Banco Resolvido: Jobs pg_cron Normalizados"
        mensagem = mensagem or "Os jobs essenciais de despacho e vigia do pg_cron voltaram a responder dentro do prazo."
    elif args.tipo == "aviso_manual":
        status = "aviso"
        titulo = titulo or "Aviso da equipe"
        mensagem = mensagem.strip()
        if not mensagem:
            parser.error("--tipo aviso_manual exige --mensagem não vazia")
        mensagem = escapar_mrkdwn_limitado(mensagem, LIMITE_AVISO_MANUAL)

    if not titulo:
        parser.error("Informe --titulo ou utilize --tipo padronizado (--tipo ci_falha, entrega, etc.)")

    payload = construir_payload(
        titulo=titulo,
        mensagem=mensagem,
        status=status,
        url=args.url,
        ambiente=args.ambiente,
        branch=args.branch,
        sha=args.sha,
    )

    return emitir_ou_dry_run(payload, webhook_url, strict=args.strict, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
