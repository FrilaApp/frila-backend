"""Valida a resposta real de cada RPC contra o schema do contrato.

Cartão `0uROtsRX`. O Postgres monta o JSON de cada RPC à mão, com
`jsonb_build_object`: basta renomear uma chave para quebrar o app sem erro nenhum no
banco, sem teste vermelho e sem log. Os portões que existiam antes deste não alcançavam
esse caso — o `contrato-em-dia.sh` compara o espelho com o original, o
`contrato-acompanha-o-codigo.sh` exige que o PR que mexe em `public` mexa no contrato, e
nenhum dos dois olha o corpo de uma resposta.

Entrada: as linhas `{"op": …, "corpo": …}` que `scripts/contrato-respostas.sql` colhe.
Saída: verde, ou vermelho dizendo **qual operação, qual caminho e qual campo**.

Duas conferências, e a segunda é a que pega o caso difícil:

1. O corpo casa com o schema declarado — `required`, tipo, `enum`, formato. Campo que
   sumiu ou foi renomeado cai aqui, porque o nome dele está em `required`.
2. O corpo não traz chave que o schema não declara. Sem isto, renomear um campo
   **opcional** passaria em silêncio: o `required` não reclama, e o contrato do OpenAPI
   não proíbe extra por padrão. É a diferença entre "o app não quebra" e "o app recebe
   uma chave que o modelo gerado não tem".
"""

import json
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

RAIZ = Path(__file__).resolve().parent.parent
CONTRATO = RAIZ / "contrato" / "openapi.yaml"


def carrega_contrato():
    with CONTRATO.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def schemas_por_operacao(doc):
    """operationId -> schema da resposta 200, para cada /rpc/… do contrato."""
    fora = {}
    for caminho, item in doc.get("paths", {}).items():
        if not caminho.startswith("/rpc/"):
            continue
        for metodo in ("get", "post"):
            op = item.get(metodo)
            if not op:
                continue
            ok = op.get("responses", {}).get("200") or op.get("responses", {}).get(200)
            if not ok:
                continue
            corpo = ok.get("content", {}).get("application/json", {})
            if "schema" in corpo:
                fora[op["operationId"]] = corpo["schema"]
    return fora


def chaves_nao_declaradas(schema, valor, doc, caminho="$"):
    """Chaves presentes no corpo que o schema não declara, com o caminho de cada uma.

    Percorre só o que o contrato descreve: onde o schema não diz nada sobre a forma
    (`type` ausente, `oneOf`, objeto livre), a função não inventa exigência.
    """
    schema = resolve(schema, doc)
    achados = []

    if schema.get("type") == "object" or "properties" in schema:
        props = schema.get("properties", {})
        if isinstance(valor, dict):
            if props and schema.get("additionalProperties") is not False:
                for k in valor:
                    if k not in props:
                        achados.append(f"{caminho}.{k}")
            for k, v in valor.items():
                if k in props:
                    achados += chaves_nao_declaradas(props[k], v, doc, f"{caminho}.{k}")
    elif schema.get("type") == "array" or "items" in schema:
        if isinstance(valor, list) and "items" in schema:
            for i, v in enumerate(valor):
                achados += chaves_nao_declaradas(schema["items"], v, doc, f"{caminho}[{i}]")

    return achados


def resolve(schema, doc):
    """Segue um `$ref` interno até o schema de verdade. Só `#/…`, que é o que o contrato usa."""
    visto = 0
    while isinstance(schema, dict) and "$ref" in schema and visto < 20:
        ref = schema["$ref"]
        if not ref.startswith("#/"):
            return schema
        alvo = doc
        for parte in ref[2:].split("/"):
            alvo = alvo[parte]
        schema = alvo
        visto += 1
    return schema if isinstance(schema, dict) else {}


def main():
    doc = carrega_contrato()
    por_op = schemas_por_operacao(doc)
    erro_schema = doc["components"]["schemas"]["Erro"]

    colhidas = []
    for linha in sys.stdin:
        linha = linha.strip()
        if not linha.startswith("{"):
            continue
        colhidas.append(json.loads(linha))

    if not colhidas:
        print("✗ Nenhuma resposta colhida. O harness SQL não produziu saída.", file=sys.stderr)
        return 1

    falhas = []
    validadas = set()

    for item in colhidas:
        op, corpo = item["op"], item["corpo"]

        if op.startswith("erro:"):
            codigo = op.split(":", 1)[1]
            schema = erro_schema
            rotulo = f"recusa {codigo}"
            if corpo is None:
                falhas.append(f"{rotulo}: a chamada não recusou — nenhum envelope para conferir")
                continue
            if corpo.get("code") != codigo:
                falhas.append(f"{rotulo}: o envelope veio com code '{corpo.get('code')}'")
        else:
            if op not in por_op:
                falhas.append(f"{op}: colhida, mas o contrato não descreve resposta 200 para ela")
                continue
            schema = por_op[op]
            rotulo = op
            validadas.add(op)

        # O schema da operação é validado **com `components` pendurado na raiz**, e não
        # resolvido antes. Resolver o `$ref` de cima deixava os `$ref` de dentro sem base:
        # `#/components/schemas/Uuid` passava a ser procurado dentro do próprio sub-schema,
        # e a validação morria com `PointerToNowhere`. Medido.
        v = Draft202012Validator({"components": doc["components"], **schema})
        for e in sorted(v.iter_errors(corpo), key=lambda e: list(e.path)):
            onde = "$" + "".join(f"[{p!r}]" if isinstance(p, int) else f".{p}" for p in e.path)
            falhas.append(f"{rotulo}: {onde} {e.message}")

        for extra in chaves_nao_declaradas(schema, corpo, doc):
            falhas.append(f"{rotulo}: {extra} não está declarada no contrato")

    # Inventário: operação do contrato que ainda não tem implementação. Não é falha — é o
    # que falta do Sprint 2 em diante —, mas é o número que diz o quanto este portão
    # cobre, e ele tem de sair na saída para ninguém achar que cobre tudo.
    sem_cobertura = sorted(set(por_op) - validadas)

    print(f"Operações do contrato com resposta 200: {len(por_op)}")
    print(f"Validadas com corpo real:               {len(validadas)}")
    print(f"Envelopes de recusa conferidos:         {sum(1 for i in colhidas if i['op'].startswith('erro:'))}")
    if sem_cobertura:
        print(f"\nAinda sem implementação ({len(sem_cobertura)}), e por isso fora deste portão:")
        for op in sem_cobertura:
            print(f"    {op}")

    if falhas:
        print(f"\n✗ {len(falhas)} divergência(s) entre a resposta e o contrato:\n", file=sys.stderr)
        for f in falhas:
            print(f"    {f}", file=sys.stderr)
        print(
            "\n  O contrato é a fonte dos modelos do iOS, do Android e da web. Uma chave que\n"
            "  muda aqui e não muda lá é um cliente desserializando errado no aparelho de\n"
            "  alguém. Se a mudança é intencional, ela nasce em FrilaApp/frila-docs.",
            file=sys.stderr,
        )
        return 1

    print("\n✓ Toda resposta colhida casa com o schema do contrato, e nenhuma traz chave que ele não declare.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
