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


# Operações que este portão não alcança, e o motivo de cada uma. A lista é declarada à
# mão de propósito: operação fora do alcance e operação ainda sem implementação saem em
# seções diferentes da saída, porque são coisas diferentes — uma nunca vai ser coberta
# por aqui, a outra está esperando alguém escrever.
#
# Cartão `oCv0WPNY`. Até 01/10 este portão só varria `/rpc/`, e nenhum dos três portões do
# contrato olhava o corpo de uma Edge Function: o `contrato-acompanha-o-codigo.sh` só
# dispara em função de `public`, e a `privado.meus_dados` que monta a exportação não é.
FORA_DO_ALCANCE = {
    "confirmarCodigo": "a Sessao é emitida pelo Supabase Auth, e não por código deste repositório",
    "renovarSessao": "a Sessao é emitida pelo Supabase Auth, e não por código deste repositório",
    "entrarDemonstracao": "devolve a Sessao do Supabase Auth; a Edge Function só a repassa",
    "listarFuncoes": "leitura de tabela pelo PostgREST: o corpo é dele, e não de função nossa",
    "exportarTurnos": "devolve text/csv e application/pdf, e não JSON: não há schema para conferir",
    "pedirCodigo": "a resposta não tem corpo",
}


# ── A direção contrato-à-frente ───────────────────────────────────────────────
#
# Cartão `EFveOeIb`. Os três portões de contrato deste repositório medem o contrato ATRÁS
# do código. A direção em que o **contrato promete e o código não entrega** não tinha
# portão: a 0.2.28 passou a prometer `404` em `perfil_publico` entre partes bloqueadas, a
# função não filtra bloqueio, e nada reprovou.
#
# ── Por que uma lista, e não "todas as operações de uma vez" ──────────────────
#
# O contrato declara **118** pares (operação, status de recusa) em 49 operações, medido em
# 01/10. Exigir os 118 de uma vez faria o portão nascer vermelho em ~110 pares que ninguém
# decidiu ainda — e portão que nasce vermelho é portão que o time aprende a reexecutar sem
# ler. É o mesmo raciocínio do teste `440`, que classifica tabela por tabela em vez de
# afirmar um total.
#
# Então o portão **reprova só os pares desta lista**, e imprime quantos ainda não vigia.
# Entrar aqui é uma decisão, e custa escrever o cenário de recusa em
# `scripts/contrato-respostas.sql`. Sair daqui, nunca: par vigiado que deixa de ser
# medido é o buraco voltando.
VIGIADAS = {
    # O caso que motivou o cartão. Contrato 0.2.28, cartão 1aGJPQK2.
    ("perfilPublico", "404"): "nao_encontrado",
    # Os 15 pares de maior risco (privacidade, dinheiro, exclusão, bloqueio, autorização, operações)
    ("contatoDoTurno", "403"): "sem_permissao",
    ("contatoDoTurno", "404"): "nao_encontrado",
    ("cancelarPosicao", "409"): "posicao_nao_cancelavel",
    ("cancelarVaga", "409"): "vaga_encerrada",
    ("excluirConta", "409"): "administrador_unico",
    ("bloquear", "403"): "sem_permissao",
    ("bloquear", "422"): "campo_invalido",
    ("denunciar", "403"): "sem_permissao",
    ("contestarSuspensao", "409"): "contestacao_ja_aberta",
    ("contestarSuspensao", "422"): "sem_suspensao_ativa",
    ("reabrirPorAtraso", "409"): "posicao_nao_cancelavel",
    ("reabrirPorAtraso", "403"): "sem_permissao",
    ("confirmarCheckinManual", "409"): "checkin_ja_confirmado",
    ("fazerCheckin", "409"): "vaga_encerrada",
    ("fazerCheckout", "409"): "checkin_pendente",
    # Lote 2: mais 20 pares críticos por risco (cancelamentos, seleção, candidaturas, cadastro, bloqueio)
    ("cancelarPosicao", "404"): "nao_encontrado",
    ("cancelarPosicao", "403"): "sem_permissao",
    ("cancelarVaga", "404"): "nao_encontrado",
    ("cancelarVaga", "403"): "sem_permissao",
    ("publicarVaga", "403"): "sem_permissao",
    ("candidatar", "404"): "nao_encontrado",
    ("candidatar", "409"): "vaga_encerrada",
    ("retirarCandidatura", "404"): "nao_encontrado",
    ("retirarCandidatura", "409"): "candidatura_indisponivel",
    ("escolherCandidato", "403"): "sem_permissao",
    ("escolherCandidato", "409"): "posicao_ja_preenchida",
    ("avaliar", "403"): "sem_permissao",
    ("avaliar", "409"): "avaliacao_ja_registrada",
    ("cadastrarEstabelecimento", "409"): "documento_ja_cadastrado",
    ("cadastrarEstabelecimento", "403"): "sem_permissao",
    ("bloquear", "404"): "nao_encontrado",
    ("denunciar", "404"): "nao_encontrado",
    ("denunciar", "422"): "campo_invalido",
    ("avisarACaminho", "403"): "sem_permissao",
    ("configuracaoDoApp", "404"): "nao_encontrado",
    # Lote 3: mais 15 pares críticos por risco (presença, turnos, vagas, equipe)
    ("confirmarCheckinManual", "403"): "sem_permissao",
    ("confirmarCheckinManual", "404"): "nao_encontrado",
    ("fazerCheckin", "403"): "sem_permissao",
    ("fazerCheckin", "404"): "nao_encontrado",
    ("fazerCheckout", "403"): "sem_permissao",
    ("fazerCheckout", "404"): "nao_encontrado",
    ("republicarVaga", "403"): "sem_permissao",
    ("republicarVaga", "404"): "nao_encontrado",
    ("detalheVaga", "403"): "sem_permissao",
    ("detalheVaga", "404"): "nao_encontrado",
    ("candidatosDaVaga", "403"): "sem_permissao",
    ("candidatosDaVaga", "404"): "nao_encontrado",
    ("incluirNaEquipe", "403"): "sem_permissao",
    ("incluirNaEquipe", "404"): "nao_encontrado",
    ("removerDaEquipe", "403"): "sem_permissao",
}

# Pares que o portão não consegue medir por aqui, com o motivo. Separados dos "ainda não
# vigiados" porque são coisas diferentes: estes nunca vão entrar pela colheita no banco.
ISENTAS = {
    ("entrarDemonstracao", "429"): "limite de tentativas do Supabase Auth, fora do Postgres",
    ("pedirCodigo", "429"): "limite de reenvio do Supabase Auth, fora do Postgres",
    ("exportarMeusDados", "405"): "método não permitido é decidido pela Edge Function, não pelo banco",
}


def recusas_declaradas(doc):
    """operationId -> conjunto de status de recusa que o contrato declara."""
    fora = {}
    for item in (doc.get("paths") or {}).values():
        for metodo in ("get", "post"):
            op = item.get(metodo)
            if not op:
                continue
            for codigo in (op.get("responses") or {}):
                if str(codigo)[0] in "45":
                    fora.setdefault(op["operationId"], set()).add(str(codigo))
    return fora


def schemas_por_operacao(doc):
    """operationId -> schema do corpo JSON de sucesso, para cada operação do contrato.

    Varre **todos** os caminhos, e não só `/rpc/`. As Edge Functions vivem em
    `/functions/v1/` e ficavam de fora: a resposta delas podia ganhar campo, perder campo
    obrigatório ou trocar nome, e nenhum portão avisava.

    Qualquer 2xx serve, e não só o 200: a `excluirConta` responde **202**, e exigir 200
    deixaria de fora justamente a operação que mexe em conta.
    """
    fora = {}
    for item in doc.get("paths", {}).values():
        for metodo in ("get", "post"):
            op = item.get(metodo)
            if not op:
                continue
            for codigo, resposta in (op.get("responses") or {}).items():
                if not str(codigo).startswith("2"):
                    continue
                corpo = (resposta.get("content") or {}).get("application/json", {})
                if "schema" in corpo:
                    fora[op["operationId"]] = corpo["schema"]
                    break
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


def varrer_colecoes(schema, valor, doc, caminho="$"):
    """Varre o corpo colhido confrontando com o schema para medir o tamanho de cada coleção (array).

    Retorna um dicionário {caminho: [tamanhos_encontrados]}.
    Coleção com tamanho 0 em todas as amostras colhidas significa que o schema
    de seus itens nunca foi exercitado pelo portão, deixando chaves extras,
    ausentes ou de tipos divergentes passarem sem validação.
    """
    schema = resolve(schema, doc)
    achados = {}
    if schema.get("type") == "array" or "items" in schema:
        if isinstance(valor, list):
            achados.setdefault(caminho, []).append(len(valor))
            if "items" in schema:
                for v in valor:
                    sub = varrer_colecoes(schema["items"], v, doc, f"{caminho}[]")
                    for k, s in sub.items():
                        achados.setdefault(k, []).extend(s)
    elif schema.get("type") == "object" or "properties" in schema:
        props = schema.get("properties", {})
        if isinstance(valor, dict):
            for k, v in valor.items():
                if k in props:
                    sub = varrer_colecoes(
                        props[k], v, doc, f"{caminho}.{k}" if caminho != "$" else f"$.{k}"
                    )
                    for sk, s in sub.items():
                        achados.setdefault(sk, []).extend(s)
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
    colecoes_observadas = {}

    for item in colhidas:
        op, corpo = item["op"], item["corpo"]

        # As entradas da direção contrato-à-frente não são corpo de sucesso: elas trazem
        # `{"status": n}`, e quem as julga é o bloco de promessas, mais abaixo.
        if op.startswith("promete:"):
            continue

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
            achados_cols = varrer_colecoes(schema, corpo, doc)
            for cam, tam in achados_cols.items():
                colecoes_observadas.setdefault((op, cam), []).extend(tam)

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

    # ── A direção contrato-à-frente ───────────────────────────────────────────
    #
    # `promete:<operacao>:<status>` traz o status que a tentativa de fato produziu. O
    # portão não pergunta "o corpo casa"; pergunta "a recusa que o contrato promete
    # aconteceu".
    declaradas = recusas_declaradas(doc)
    observados = {}
    for item in colhidas:
        if not item["op"].startswith("promete:"):
            continue
        _, operacao, esperado = item["op"].split(":", 2)
        corpo = item["corpo"] or {}
        observados.setdefault((operacao, esperado), []).append(
            (corpo.get("status"), corpo.get("code"))
        )

    promessas_quebradas = []
    for par, codigo_esperado in sorted(VIGIADAS.items()):
        operacao, esperado = par
        if esperado not in declaradas.get(operacao, set()):
            # O contrato deixou de prometer. Não é falha do código — é a lista que
            # envelheceu, e ela tem de dizer isso em voz alta em vez de passar verde.
            promessas_quebradas.append(
                f"{operacao}: o contrato não declara mais {esperado}, e o par está em "
                f"VIGIADAS. Tire-o da lista no mesmo PR que mudou o contrato"
            )
            continue
        vistos = observados.get(par)
        if vistos is None:
            promessas_quebradas.append(
                f"{operacao}: o contrato promete {esperado} e a colheita não tentou. "
                f"Sem cenário em contrato-respostas.sql, este par não está medido"
            )
        elif not any(str(st) == esperado for st, cd in vistos):
            status_vistos = [st for st, cd in vistos]
            promessas_quebradas.append(
                f"{operacao}: o contrato promete {esperado} e o código devolveu "
                f"{', '.join(str(v) for v in status_vistos)}"
            )
        elif codigo_esperado is not None and not any(
            str(st) == esperado and cd == codigo_esperado for st, cd in vistos
        ):
            codigos_vistos = [cd for st, cd in vistos if str(st) == esperado]
            promessas_quebradas.append(
                f"{operacao}: o contrato promete {esperado} com code '{codigo_esperado}', "
                f"mas o código devolveu code {codigos_vistos}"
            )

    vigiadas_ok = len(VIGIADAS) - len(promessas_quebradas)
    nao_vigiados = sum(len(v) for v in declaradas.values()) - len(VIGIADAS) - len(ISENTAS)

    # Inventário: operação do contrato que ainda não tem implementação. Não é falha — é o
    # que falta do Sprint 2 em diante —, mas é o número que diz o quanto este portão
    # cobre, e ele tem de sair na saída para ninguém achar que cobre tudo.
    sem_cobertura = sorted(set(por_op) - validadas - set(FORA_DO_ALCANCE))
    fora_do_alcance = sorted(set(por_op) & set(FORA_DO_ALCANCE) - validadas)

    print(f"Operações do contrato com resposta 200: {len(por_op)}")
    print(f"Validadas com corpo real:               {len(validadas)}")
    print(f"Envelopes de recusa conferidos:         {sum(1 for i in colhidas if i['op'].startswith('erro:'))}")
    if sem_cobertura:
        print(f"\nAinda sem implementação ({len(sem_cobertura)}), e por isso fora deste portão:")
        for op in sem_cobertura:
            print(f"    {op}")

    # Em seção própria, e nomeando o motivo: operação que este portão nunca vai cobrir não
    # pode se parecer com operação que alguém ainda vai implementar. Sem isto, a lista de
    # "sem cobertura" encolhe sozinha com o tempo e passa a parecer que o portão cobre tudo.
    if fora_do_alcance:
        print(f"\nFora do alcance deste portão ({len(fora_do_alcance)}), e por quê:")
        for op in fora_do_alcance:
            print(f"    {op}: {FORA_DO_ALCANCE[op]}")

    print(f"\nContrato à frente do código — pares (operação, status) de recusa:")
    print(f"    declarados no contrato: {sum(len(v) for v in declaradas.values())}")
    print(f"    vigiados e alcançados:  {vigiadas_ok} de {len(VIGIADAS)}")
    print(f"    isentos, com motivo:    {len(ISENTAS)}")
    print(f"    ainda não vigiados:     {nao_vigiados}")

    # ── Auditoria de coleções declaradas e exercitadas ─────────────────────────
    #
    # Uma coleção colhida vazia (`[]`) valida como array válido no JSON Schema, mas nunca
    # passa pelos schemas de seus itens nem por `chaves_nao_declaradas`: qualquer chave
    # inventada ou renomeada dentro de um item passará sem ser vista.
    colecoes_vazias = []
    colecoes_exercitadas = []
    for (op, caminho), tamanhos in sorted(colecoes_observadas.items()):
        total_itens = sum(tamanhos)
        if total_itens == 0:
            colecoes_vazias.append((op, caminho, len(tamanhos)))
        else:
            colecoes_exercitadas.append((op, caminho, total_itens, len(tamanhos)))

    if colecoes_observadas:
        print(f"\nColeções declaradas e observadas nas respostas:")
        print(f"    encontradas nas respostas: {len(colecoes_observadas)}")
        print(f"    exercitadas com itens:     {len(colecoes_exercitadas)} de {len(colecoes_observadas)}")
        print(f"    vazias (nunca exercitadas): {len(colecoes_vazias)}")

    if promessas_quebradas:
        print(
            f"\n✗ {len(promessas_quebradas)} promessa(s) do contrato que o código não cumpre:\n",
            file=sys.stderr,
        )
        for m in promessas_quebradas:
            print(f"    {m}", file=sys.stderr)
        print(
            "\n  O contrato é a fonte dos modelos do iOS, do Android e da web (B16). Uma\n"
            "  recusa prometida e não levantada chega ao usuário como chamada que falha em\n"
            "  runtime, semanas depois, sem log que ligue o defeito à mudança.",
            file=sys.stderr,
        )

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

    if colecoes_vazias:
        print(
            f"\n⚠ {len(colecoes_vazias)} coleção(ões) declarada(s) colhida(s) vazia(s) (nunca exercitadas):\n",
            file=sys.stderr,
        )
        for op, caminho, n in colecoes_vazias:
            print(f"    {op}: {caminho} (0 itens em {n} amostra(s))", file=sys.stderr)
        print(
            "\n  Coleção vazia não exercita o schema dos seus itens contra o contrato:\n"
            "  chaves não declaradas, ausentes ou com tipos divergentes passam sem validação.\n"
            "  Semeie dados para estas coleções em scripts/contrato-respostas.sql.",
            file=sys.stderr,
        )

    falhar_vazias = "--falhar-vazias" in sys.argv or "--falhar-colecoes-vazias" in sys.argv

    # Reprovação: falhas de corpo, promessas quebradas ou coleções vazias sob modo estrito.
    if falhas or promessas_quebradas or (falhar_vazias and colecoes_vazias):
        return 1

    print("\n✓ Toda resposta colhida casa com o schema do contrato, e nenhuma traz chave que ele não declare.")
    print("✓ Toda recusa vigiada que o contrato promete é alcançável no banco.")
    if colecoes_observadas and not colecoes_vazias:
        print("✓ Toda coleção declarada observada nas respostas foi exercitada com itens reais.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
