#!/usr/bin/env python3
"""A ponte entre o quadro do Trello e o log de fatos da Bancada.

O `bancada-sync.sh` leva os **commits** deste repositório para o vault. O quadro não
chegava por caminho nenhum: `trello.sh` só fala com o Trello, e nenhum script levava o
movimento de cartão para o vault. Em 27/10/2026 isso foi medido — 62 cartões de Backend
concluídos entre 26/09 e 27/10, dos quais 21 não apareciam em lugar nenhum do vault — e
esta ponte existe para fechar esse buraco.

O que ela leva, e o que não leva
--------------------------------
Leva **fato**: cartão movido de uma lista para outra, e comentário escrito no cartão.
Os dois têm data, hora, autor e id de ação do Trello, que é o que torna o registro
auditável e a repetição inofensiva.

Não leva **narrativa**. A regra de ouro do vault é que fato e narrativa são camadas
separadas, e um script que transformasse movimento de cartão em prosa estaria inventando
a camada de cima. O estado dos cartões de Backend vai para a T-0025 em forma de tabela,
entre marcadores, porque tabela de estado é dado — não é interpretação do dia.

Escrita no log
--------------
Só pela porta do vault: `<vault>/scripts/registrar-fato.sh externo`. Esta ponte nunca
abre o arquivo do log para escrever, pela mesma razão que o `pre-commit` do vault recusa
quem o faz: a procedência é o que dá valor ao registro.

Idempotência
------------
Cada fato carrega `trello:<id da ação>`, e o id de uma ação do Trello não muda. Antes de
registrar, a ponte procura esse id no acervo inteiro de `05 - Registros/`. Rodar duas
vezes no mesmo intervalo não acrescenta linha nenhuma.

Há uma segunda guarda, para o que foi registrado à mão antes desta ponte existir: se o
arquivo do dia já tem uma linha que cita o `shortLink` do cartão **e** a lista de
destino, o movimento é tratado como já registrado. Sem ela, a recuperação de 28/09 em
diante duplicaria as 22 linhas escritas à mão em 27/10.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import unicodedata
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta

API = "https://api.trello.com/1"

# O log guarda a hora local de quem agiu. O Trello devolve UTC, e o quadro é operado no
# fuso de Brasília: sem o deslocamento, o trabalho das 21h entra no log do dia seguinte.
FUSO_DO_QUADRO = timedelta(hours=-3)

TIPO_MOVIMENTO = "quadro"
TIPO_COMENTARIO = "quadro-comentario"


def sem_acento(s: str) -> str:
    return "".join(
        c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn"
    ).lower()


def ler_env(caminho: str) -> dict:
    """Lê o `.env` do repositório sem depender de shell."""
    env = {}
    if not os.path.exists(caminho):
        return env
    with open(caminho, encoding="utf-8") as f:
        for linha in f:
            linha = linha.strip()
            if not linha or linha.startswith("#") or "=" not in linha:
                continue
            k, v = linha.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


class Trello:
    """Só leitura. Esta ponte não escreve no quadro — quem escreve é o `trello.sh`."""

    def __init__(self, chave: str, token: str, quadro: str):
        self.k, self.t, self.quadro = chave, token, quadro

    def _get(self, caminho: str, **q):
        q.update(key=self.k, token=self.t)
        url = f"{API}{caminho}?" + urllib.parse.urlencode(q)
        with urllib.request.urlopen(url, timeout=60) as r:
            return json.load(r)

    def cartoes(self):
        return self._get(
            f"/boards/{self.quadro}/cards", fields="name,shortLink,labels,idList", filter="all"
        )

    def acoes(self, filtro: str, desde: str):
        """Pagina para trás, porque o Trello devolve no máximo 1000 ações por chamada."""
        out, antes = [], None
        while True:
            q = dict(filter=filtro, limit=1000, since=desde)
            if antes:
                q["before"] = antes
            lote = self._get(f"/boards/{self.quadro}/actions", **q)
            out += lote
            if len(lote) < 1000:
                return out
            antes = lote[-1]["date"]


def da_fixture(caminho: str):
    """Entrada de mentira para o autoteste: mesmo formato que a API devolve.

    O teste não pode depender da rede nem das credenciais de ninguém, e um teste que
    chama a API de verdade mede o quadro de hoje — que muda — em vez de medir a ponte.
    """
    with open(caminho, encoding="utf-8") as f:
        d = json.load(f)
    return d.get("cards", []), d.get("actions", [])


def hora_local(iso: str) -> tuple[str, str]:
    dt = datetime.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S") + FUSO_DO_QUADRO
    return dt.strftime("%Y-%m-%d"), dt.strftime("%H:%M")


class Log:
    """O acervo de fatos, lido uma vez e mantido em memória durante a passagem."""

    def __init__(self, vault: str):
        self.vault = vault
        self.pasta = os.path.join(vault, "05 - Registros")
        self.acervo = ""
        self.por_dia: dict[str, str] = {}
        self.recarregar()

    def recarregar(self):
        self.acervo = ""
        self.por_dia = {}
        # Instantâneo das linhas **sem** id de ação, por dia: é contra elas que a segunda
        # guarda compara. Ele não cresce durante a passagem, de propósito. Se crescesse,
        # um comentário registrado agora — que carrega o texto da pessoa, e pode citar o
        # nome de uma lista — faria a ponte pular o movimento daquele cartão para aquela
        # lista no mesmo dia. Falso positivo de guarda é fato perdido em silêncio.
        self.legado_por_dia: dict[str, str] = {}
        for raiz, _, arquivos in os.walk(self.pasta):
            for nome in arquivos:
                if not nome.endswith(".md"):
                    continue
                with open(os.path.join(raiz, nome), encoding="utf-8") as f:
                    texto = f.read()
                self.acervo += texto
                self.por_dia[nome[:-3]] = texto
                self.legado_por_dia[nome[:-3]] = "\n".join(
                    l for l in texto.split("\n") if l.startswith("- `") and "trello:" not in l
                )

    def tem_acao(self, id_acao: str) -> bool:
        return f"trello:{id_acao}" in self.acervo

    def ja_registrado_a_mao(self, dia: str, short: str, lista: str) -> bool:
        """A guarda para o que entrou no log antes desta ponte existir.

        Compara só contra o instantâneo de linhas sem `trello:`, e só no arquivo do dia.
        Em 27/10/2026 foram 22 linhas escritas à mão sobre cartão movido para Concluído;
        sem esta guarda, a recuperação de 28/09 em diante as duplicaria.
        """
        texto = sem_acento(self.legado_por_dia.get(dia, ""))
        if not texto:
            return False
        return sem_acento(short) in texto and sem_acento(lista.split()[0]) in texto

    def registrar(self, dia: str, hora: str, quem: str, tipo: str, desc: str, seco: bool):
        if seco:
            print(f"  registraria: {dia} {hora} · {quem} · [{tipo}] {desc[:90]}")
            return
        porta = os.path.join(self.vault, "scripts", "registrar-fato.sh")
        r = subprocess.run(
            [porta, "externo", dia, hora, quem, tipo, desc],
            capture_output=True,
            text=True,
            cwd=self.vault,
        )
        if r.returncode != 0:
            raise SystemExit(f"✗ registrar-fato.sh recusou o fato de {dia} {hora}: {r.stderr.strip()}")
        # O acervo cresce durante a passagem: sem isto, duas ações iguais no mesmo lote
        # entrariam duas vezes, e a segunda guarda não veria o que a primeira escreveu.
        linha = f"- `{hora}` · **{quem}** · `{tipo}` · {desc}"
        self.acervo += "\n" + linha
        self.por_dia[dia] = self.por_dia.get(dia, "") + "\n" + linha


NOMES = {
    "matheussilva95408964": "Matheus Silva",
    "joaopauloalbuquerque7": "João Paulo",
    "cauecarneiroc": "Cauê Carneiro",
    "juliaclovandi": "Júlia Clovandi",
    "fabriciotosta3": "Fabrício Tosta",
}


def nome_de(username: str, nome_cheio: str | None) -> str:
    """O log usa o nome da pessoa, como o resto do vault. O username é o que a API dá."""
    return NOMES.get(username) or (nome_cheio or username)


def achar_vault(explicito: str | None, raiz_backend: str) -> str:
    """Mesma ordem declarada do `bancada-sync.sh`, e pelo mesmo motivo.

    Existem três pastas chamadas `doc-harness` na máquina e só uma é o vault vivo;
    escrever na errada é fácil e silencioso.
    """
    candidatos = []
    if explicito:
        candidatos.append(explicito)
    if os.environ.get("BANCADA_DIR"):
        candidatos.append(os.environ["BANCADA_DIR"])
    acima = os.path.dirname(raiz_backend)
    candidatos += [
        os.path.join(acima, "monorepo", "doc-harness"),
        os.path.join(acima, "doc-harness"),
    ]
    for c in candidatos:
        if os.path.isdir(os.path.join(c, "05 - Registros")) and os.access(
            os.path.join(c, "scripts", "registrar-fato.sh"), os.X_OK
        ):
            return os.path.abspath(c)
    raise SystemExit(
        "✗ vault não encontrado: aponte --vault ou BANCADA_DIR para a pasta do doc-harness vivo"
    )


def tabela_t25(cartoes, listas, etiqueta) -> str:
    """O estado dos cartões da etiqueta que ainda não fecharam, em tabela, para a T-0025.

    Dado, não narrativa: lista atual, cartão, título e etiquetas. Quem escreve o que isso
    significou continua sendo gente.

    Cartão em Concluído fica de fora, e só é contado. Medido em 27/10/2026: com ele
    dentro, a tabela saía com 88 linhas, 81 delas de cartão fechado — e o histórico dos
    concluídos, com data do movimento e PR, já está na própria T-0025, escrito à mão.
    Tabela que repete o que já existe é tabela que ninguém lê até ela mentir.
    """
    da_etiqueta = [c for c in cartoes if any(etiqueta in l["name"] for l in c.get("labels", []))]
    def lista_de(c):
        return listas.get(c["idList"], "")
    fechados = [c for c in da_etiqueta if sem_acento(lista_de(c)).startswith("concluido")]
    abertos = [c for c in da_etiqueta if c not in fechados and lista_de(c)]

    ordem = {"Em andamento": 0, "Revisão": 1, "Teste": 2}
    abertos.sort(key=lambda c: (ordem.get(lista_de(c), 9), lista_de(c), c["name"]))

    linhas = ["| lista | cartão | título | etiquetas |", "|---|---|---|---|"]
    for c in abertos:
        rotulos = ", ".join(l["name"] for l in c.get("labels", []))
        linhas.append(
            f"| {lista_de(c)} | `{c['shortLink']}` | "
            f"{c['name'].replace('|','/')} | {rotulos} |"
        )
    if not abertos:
        linhas.append("| — | — | nenhum cartão aberto com esta etiqueta | — |")
    linhas.append("")
    linhas.append(
        f"{len(fechados)} cartão(ões) com etiqueta {etiqueta} em Concluído não entram nesta "
        f"tabela; o histórico deles, com data do movimento e PR, está na seção acima."
    )
    return "\n".join(linhas)


MARCA_INICIO = "<!-- quadro-backend:inicio -->"
MARCA_FIM = "<!-- quadro-backend:fim -->"


def atualizar_t25(vault: str, tabela: str, quando: str, seco: bool) -> str:
    """Troca só o trecho entre os marcadores. Fora deles, o texto é de gente."""
    import glob

    alvos = glob.glob(os.path.join(vault, "04 - Tarefas", "T-0025 *.md"))
    if not alvos:
        return "T-0025 não encontrada — tabela não escrita"
    caminho = alvos[0]
    with open(caminho, encoding="utf-8") as f:
        texto = f.read()
    if MARCA_INICIO not in texto or MARCA_FIM not in texto:
        return (
            "T-0025 sem os marcadores "
            f"{MARCA_INICIO} … {MARCA_FIM} — tabela não escrita (acrescente-os uma vez, à mão)"
        )
    bloco = (
        f"{MARCA_INICIO}\n"
        f"<!-- gerado por scripts/bancada-trello.sh · não editar à mão -->\n"
        f"Estado do quadro em {quando}, lido da API do Trello:\n\n"
        f"{tabela}\n"
        f"{MARCA_FIM}"
    )
    novo = re.sub(
        re.escape(MARCA_INICIO) + r".*?" + re.escape(MARCA_FIM), lambda _m: bloco, texto, flags=re.S
    )
    if novo == texto:
        return "T-0025 já estava com esta tabela"
    if seco:
        return "T-0025 seria atualizada entre os marcadores"
    with open(caminho, "w", encoding="utf-8") as f:
        f.write(novo)
    return "T-0025 atualizada entre os marcadores"


def main() -> int:
    raiz_backend = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    p = argparse.ArgumentParser(description="Leva o quadro do Trello para o log de fatos do vault.")
    p.add_argument("--desde", help="AAAA-MM-DD (padrão: ontem)")
    p.add_argument("--ate", help="AAAA-MM-DD (padrão: hoje)")
    p.add_argument("--etiqueta", default="Backend", help="etiqueta do cartão (padrão: Backend)")
    p.add_argument("--todas-etiquetas", action="store_true", help="ignora o filtro de etiqueta")
    p.add_argument("--autor", help="só ações desta pessoa (trecho do nome ou do username)")
    p.add_argument("--sem-comentarios", action="store_true", help="só movimentos de lista")
    p.add_argument("--max-texto", type=int, default=500, help="corte do texto do comentário")
    p.add_argument("--seco", action="store_true", help="mostra o que faria")
    p.add_argument("--vault", help="pasta do doc-harness")
    p.add_argument("--sem-t25", action="store_true", help="não mexe na T-0025")
    a = p.parse_args()

    hoje = date.today()
    desde = a.desde or (hoje - timedelta(days=1)).isoformat()
    ate = a.ate or hoje.isoformat()
    for d in (desde, ate):
        if not re.match(r"^\d{4}-\d{2}-\d{2}$", d):
            raise SystemExit(f"✗ data em formato inesperado: {d} (use AAAA-MM-DD)")

    vault = achar_vault(a.vault, raiz_backend)
    print(f"▸ Vault: {vault}")
    print(f"▸ Intervalo: {desde} a {ate}" + (f" · autor ~ {a.autor}" if a.autor else ""))

    fixture = os.environ.get("BANCADA_TRELLO_FIXTURE")
    if fixture:
        print(f"▸ Fonte: fixture {fixture} (sem rede)")
        cartoes, acoes = da_fixture(fixture)
        listas = {}
    else:
        env = ler_env(os.path.join(raiz_backend, ".env"))
        falta = [k for k in ("TRELLO_API_KEY", "TRELLO_TOKEN", "TRELLO_BOARD_ID") if not env.get(k)]
        if falta:
            raise SystemExit(f"✗ falta no .env: {', '.join(falta)}")
        api = Trello(env["TRELLO_API_KEY"], env["TRELLO_TOKEN"], env["TRELLO_BOARD_ID"])
        print("▸ Fonte: API do Trello")
        cartoes = api.cartoes()
        desde_iso = f"{desde}T00:00:00.000Z"
        acoes = api.acoes("updateCard", desde_iso) + (
            [] if a.sem_comentarios else api.acoes("commentCard", desde_iso)
        )
        listas = {l["id"]: l["name"] for l in api._get(f"/boards/{api.quadro}/lists", fields="name")}

    etiquetas = {c["shortLink"]: [l["name"] for l in c.get("labels", [])] for c in cartoes}
    titulos = {c["shortLink"]: c["name"] for c in cartoes}

    def interessa(ac) -> bool:
        short = ac["data"].get("card", {}).get("shortLink", "")
        if not a.todas_etiquetas and not any(a.etiqueta in e for e in etiquetas.get(short, [])):
            return False
        if a.autor:
            mc = ac.get("memberCreator", {})
            alvo = sem_acento(a.autor)
            if alvo not in sem_acento(mc.get("username", "")) and alvo not in sem_acento(
                mc.get("fullName", "") or ""
            ):
                return False
        dia, _ = hora_local(ac["date"])
        return desde <= dia <= ate

    log = Log(vault)
    novos = pulados = 0
    por_dia: dict[str, int] = {}

    for ac in sorted((x for x in acoes if interessa(x)), key=lambda x: x["date"]):
        dia, hora = hora_local(ac["date"])
        mc = ac.get("memberCreator", {})
        quem = nome_de(mc.get("username", "?"), mc.get("fullName"))
        short = ac["data"].get("card", {}).get("shortLink", "?")
        titulo = titulos.get(short, ac["data"].get("card", {}).get("name", "?"))

        if ac["type"] == "updateCard":
            if "listAfter" not in ac["data"]:
                continue
            de = ac["data"]["listBefore"]["name"]
            para = ac["data"]["listAfter"]["name"]
            desc = (
                f"`{short}` movido de {de} para {para} · {titulo} · "
                f"trello:{ac['id']}"
            )
            tipo = TIPO_MOVIMENTO
            legado = log.ja_registrado_a_mao(dia, short, para)
        else:
            texto = " ".join(ac["data"]["text"].split())
            if len(texto) > a.max_texto:
                texto = texto[: a.max_texto - 1] + "…"
            desc = f"`{short}` · {titulo} · comentário: {texto} · trello:{ac['id']}"
            tipo = TIPO_COMENTARIO
            legado = False

        if log.tem_acao(ac["id"]) or legado:
            pulados += 1
            continue
        log.registrar(dia, hora, quem, tipo, desc, a.seco)
        novos += 1
        por_dia[dia] = por_dia.get(dia, 0) + 1

    print()
    print(f"  {novos} fato(s) novo(s), {pulados} já registrado(s).")
    if por_dia:
        print("  por dia: " + ", ".join(f"{d}={n}" for d, n in sorted(por_dia.items())))

    if not a.sem_t25 and listas:
        print("  " + atualizar_t25(vault, tabela_t25(cartoes, listas, a.etiqueta), date.today().isoformat(), a.seco))

    print()
    print("  O fato fica no working tree do vault. Publicar é do humano: o `pre-push` do")
    print("  vault exige Touch ID e é ele quem commita o log. Nunca use SKIP_BIOMETRICS.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
