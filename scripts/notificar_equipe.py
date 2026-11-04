#!/usr/bin/env python3
"""Despacho de e-mail de aviso para os sócios do Frila.

Existe para que um passo de pipeline (entrega contínua, checagem diária, purga) possa
avisar Cauê, Jotapê e Fabrício sem que ninguém decore endereço nem cole senha em
comando. A `Edge Function enviar-email` continua sendo o caminho do e-mail de produto
(código de entrada, denúncia, contestação); este script é a ferramenta de operação, roda
na máquina de quem opera e nunca no runtime do app.

Contrato de saída, que o pipeline depende
-----------------------------------------
- `0` com e-mail enviado.
- `0` sem credencial de SMTP configurada, ou com `--dry-run`: imprime o que faria e sai
  limpo. Um aviso que não sai não pode derrubar a entrega que ele estava anunciando.
- `1` em erro de uso (falta assunto ou corpo, destinatário inválido).
- `2` em falha de SMTP com credencial presente: aí há o que consertar, e o silêncio
  custaria mais que a falha.

Variáveis (lidas do ambiente, que o `notificar-equipe.sh` carrega do `.env`)
---------------------------------------------------------------------------
`SMTP_HOST`, `SMTP_PORT` (587), `SMTP_USER`, `SMTP_PASS`, `SMTP_SENDER` e `SMTP_TLS`.
Os nomes são os mesmos que o `.env.example` e a `enviar-email` já usam — dois nomes para
o mesmo endereço custaria um e-mail que não sai porque a variável certa tem o nome do
outro arquivo. `SMTP_TLS=0` existe para apontar o Mailpit local, que não fala TLS.
"""

from __future__ import annotations

import argparse
import os
import smtplib
import sys
from email.message import EmailMessage

# Os três sócios que recebem aviso de operação. Júlia (PO) não entra por padrão: ela
# decide produto, e aviso de pipeline não é decisão dela.
DESTINATARIOS_PADRAO = (
    "cauecarneiroc@gmail.com",
    "joaopauloalbuquerque606@gmail.com",
    "fbtostadev@gmail.com",
)

REMETENTE_PADRAO = "nao-responda@frila.app"

USO = (
    "uso: notificar-equipe.sh --assunto <texto> --corpo <texto> "
    "[--para a@b.com[,c@d.com]] [--dry-run]"
)


def erro_de_uso(mensagem: str) -> None:
    """Imprime o erro e o uso, e sai 1 — nunca 2, que é o código do argparse."""
    print(f"✗ {mensagem}", file=sys.stderr)
    print(USO, file=sys.stderr)
    raise SystemExit(1)


def validar_endereco(endereco: str) -> bool:
    """Recusa o que não é endereço e o que carrega cabeçalho embutido.

    `\\r` e `\\n` num endereço são injeção de cabeçalho SMTP: quem controla o texto
    passa a controlar `Bcc`. A `enviar-email` faz a mesma recusa do lado do produto.
    """
    if not endereco or any(c in endereco for c in "\r\n"):
        return False
    partes = endereco.split("@")
    return len(partes) == 2 and all(partes) and "." in partes[1]


def validar_cabecalho(texto: str) -> bool:
    """Assunto com quebra de linha também é injeção de cabeçalho."""
    return not any(c in texto for c in "\r\n")


def destinatarios_de(valores: list[str] | None) -> tuple[str, ...]:
    """Aceita `--para` repetido e lista separada por vírgula, nas duas formas."""
    if not valores:
        return DESTINATARIOS_PADRAO
    saida: list[str] = []
    for valor in valores:
        for pedaco in valor.split(","):
            pedaco = pedaco.strip()
            if pedaco and pedaco not in saida:
                saida.append(pedaco)
    return tuple(saida)


def configuracao_smtp() -> dict[str, object] | None:
    """Devolve a configuração de SMTP, ou `None` quando não há credencial utilizável.

    `None` não é erro: é o estado normal da máquina de quem ainda não configurou o
    `.env`, e o chamador trata saindo 0.
    """
    host = (os.environ.get("SMTP_HOST") or "").strip()
    remetente = (os.environ.get("SMTP_SENDER") or "").strip() or REMETENTE_PADRAO
    if not host or not validar_cabecalho(host) or not validar_endereco(remetente):
        return None

    try:
        porta = int((os.environ.get("SMTP_PORT") or "587").strip())
    except ValueError:
        porta = 587
    if porta <= 0:
        porta = 587

    return {
        "host": host,
        "porta": porta,
        "usuario": (os.environ.get("SMTP_USER") or "").strip() or None,
        "senha": os.environ.get("SMTP_PASS") or None,
        "remetente": remetente,
        # 465 é TLS implícito; 587 e 25 sobem por STARTTLS. `SMTP_TLS=0` desliga os dois,
        # para o Mailpit local.
        "tls": (os.environ.get("SMTP_TLS") or "1").strip() != "0",
    }


def montar_mensagem(assunto: str, corpo: str, remetente: str, para: tuple[str, ...]) -> EmailMessage:
    mensagem = EmailMessage()
    mensagem["Subject"] = assunto
    mensagem["From"] = remetente
    mensagem["To"] = ", ".join(para)
    mensagem.set_content(corpo)
    return mensagem


def enviar(configuracao: dict[str, object], mensagem: EmailMessage) -> None:
    host = str(configuracao["host"])
    porta = int(configuracao["porta"])
    tls = bool(configuracao["tls"])
    usuario = configuracao["usuario"]
    senha = configuracao["senha"]

    if tls and porta == 465:
        servidor: smtplib.SMTP = smtplib.SMTP_SSL(host, porta, timeout=30)
    else:
        servidor = smtplib.SMTP(host, porta, timeout=30)
    with servidor:
        servidor.ehlo()
        if tls and porta != 465:
            servidor.starttls()
            servidor.ehlo()
        if usuario and senha:
            servidor.login(str(usuario), str(senha))
        servidor.send_message(mensagem)


def main(argv: list[str] | None = None) -> int:
    analisador = argparse.ArgumentParser(add_help=True, usage=USO)
    # Nada é `required=True` de propósito: o argparse sairia 2, e o contrato de saída
    # deste script reserva o 1 para erro de uso.
    analisador.add_argument("--assunto")
    analisador.add_argument("--corpo")
    analisador.add_argument("--para", action="append")
    analisador.add_argument("--dry-run", action="store_true")
    argumentos = analisador.parse_args(argv)

    assunto = (argumentos.assunto or "").strip()
    corpo = argumentos.corpo or ""
    if not assunto:
        erro_de_uso("--assunto é obrigatório")
    if not corpo.strip():
        erro_de_uso("--corpo é obrigatório")
    if not validar_cabecalho(assunto):
        erro_de_uso("--assunto não pode conter quebra de linha")

    para = destinatarios_de(argumentos.para)
    invalidos = [e for e in para if not validar_endereco(e)]
    if invalidos:
        erro_de_uso(f"destinatário inválido: {', '.join(invalidos)}")

    configuracao = configuracao_smtp()

    if argumentos.dry_run:
        print("● Ensaio (--dry-run): nada foi enviado.")
        print(f"  Assunto: {assunto}")
        print(f"  Remetente: {(configuracao or {}).get('remetente', REMETENTE_PADRAO)}")
        for endereco in para:
            print(f"  Destinatário: {endereco}")
        print(f"  Corpo: {len(corpo)} caractere(s)")
        if configuracao is None:
            print("  SMTP: sem credencial no ambiente — o envio real sairia 0 sem enviar.")
        else:
            print(f"  SMTP: {configuracao['host']}:{configuracao['porta']} (TLS: {configuracao['tls']})")
        return 0

    if configuracao is None:
        print("● SMTP não configurado (falta SMTP_HOST ou SMTP_SENDER válido): nada enviado.")
        print("  Configure o `.env` a partir do `.env.example` para o aviso sair de verdade.")
        for endereco in para:
            print(f"  Destinatário que receberia: {endereco}")
        return 0

    mensagem = montar_mensagem(assunto, corpo, str(configuracao["remetente"]), para)
    try:
        enviar(configuracao, mensagem)
    except (OSError, smtplib.SMTPException) as falha:
        # A senha nunca entra no texto do erro: `falha` do smtplib carrega host e código,
        # não credencial.
        print(f"✗ falha ao enviar pelo SMTP {configuracao['host']}:{configuracao['porta']}: {falha}", file=sys.stderr)
        return 2

    print(f"✓ aviso enviado para {len(para)} destinatário(s): {', '.join(para)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
