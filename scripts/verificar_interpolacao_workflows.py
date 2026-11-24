#!/usr/bin/env python3
"""
Aponta expressões `${{ ... }}` com valor controlado por quem abre PR, issue ou branch dentro de `run:`.

Endurecimento dos workflows: esses valores passam por `env:` e entram no comando como "$VAR".
Contextos vetados no texto do `run:`: `github.event.*` (menos `github.event_name`), `github.head_ref`,
`github.ref_name`, `github.actor` e `inputs.*`. Leitura linha a linha, sem dependência (o runner não
tem PyYAML). Sai com 1 se achar algum, com `arquivo:linha: expressão` por ocorrência.

Uso: verificar_interpolacao_workflows.py arquivo.yml [outro.yml ...]
"""
import re
import sys

VETADO = re.compile(r"github\.event\.|github\.head_ref|github\.ref_name|github\.actor|(?<![\w.])inputs\.")
EXPRESSAO = re.compile(r"\$\{\{(.*?)\}\}")
RUN = re.compile(r"^(\s*)(?:-\s+)?run:\s*(.*)$")
BLOCO = re.compile(r"^[|>][+-]?\d*\s*(#.*)?$")


def achados(caminho: str) -> list[tuple[int, str]]:
    linhas = open(caminho, encoding="utf-8").read().splitlines()
    saida: list[tuple[int, str]] = []
    i = 0
    while i < len(linhas):
        m = RUN.match(linhas[i])
        if not m:
            i += 1
            continue
        recuo, resto = len(m.group(1)), m.group(2).strip()
        trechos = [(i + 1, resto)]
        if BLOCO.match(resto):
            trechos = []
            j = i + 1
            while j < len(linhas) and (not linhas[j].strip() or len(linhas[j]) - len(linhas[j].lstrip()) > recuo):
                trechos.append((j + 1, linhas[j]))
                j += 1
            i = j - 1
        for numero, texto in trechos:
            for expr in EXPRESSAO.findall(texto):
                if VETADO.search(expr):
                    saida.append((numero, expr.strip()))
        i += 1
    return saida


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    total = 0
    for caminho in argv:
        for numero, expr in achados(caminho):
            print(f"{caminho}:{numero}: ${{{{ {expr} }}}} dentro de run:")
            total += 1
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
