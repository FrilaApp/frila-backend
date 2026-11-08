import email from "./codigo-de-entrada.html" with { type: "text" };
import pagina from "./pagina-codigo/index.html" with { type: "text" };
import { runInNewContext } from "node:vm";

function conferir(condicao: unknown, mensagem: string): asserts condicao {
  if (!condicao) throw new Error(mensagem);
}

function abrir(
  hash: string,
  clipboard: "ok" | "ausente" | "recusado" = "ok",
  fallback = true,
) {
  const elementos = Object.fromEntries(
    ["codigo", "valido", "invalido", "copiar", "estado"].map((
      id,
    ) => [id, {
      textContent: "",
      hidden: id === "valido",
      addEventListener: (_: string, fn: () => Promise<void>) => clicar = fn,
      focus() {},
    }]),
  );
  let clicar: () => Promise<void> = async () => {};
  const copiados: string[] = [];
  let selecionado = "", removido = false;
  const document = {
    getElementById: (id: string) => elementos[id],
    createElement: () => ({
      value: "",
      style: {},
      setAttribute() {},
      select() {
        selecionado = this.value;
      },
      remove() {
        removido = true;
      },
    }),
    body: { appendChild() {} },
    execCommand: (comando: string) => {
      conferir(comando === "copy", "Comando de cópia");
      copiados.push(selecionado);
      return fallback;
    },
  };
  const navigator = clipboard === "ausente" ? {} : {
    clipboard: {
      writeText: (valor: string) => {
        if (clipboard === "recusado") {
          return Promise.reject(
            new Error("Sem permissão"),
          );
        }
        copiados.push(valor);
        return Promise.resolve();
      },
    },
  };
  const script = pagina.match(/<script>([\s\S]*?)<\/script>/)?.[1];
  conferir(script, "Script inline presente");
  runInNewContext(script, {
    window: { location: { hash, search: "?codigo=654321" } },
    document,
    navigator,
  });
  return {
    elementos,
    copiados,
    clicar: () => clicar(),
    removido: () => removido,
  };
}

Deno.test("e-mail mantém o código no corpo e uma única vez no fragmento do botão", () => {
  const corpo = email.replace(/<!--[\s\S]*?-->/g, "");
  const links = [...corpo.matchAll(/href="([^"]+)"/g)].map((m) => m[1]);
  conferir(
    links.length === 1 &&
      links[0] === "https://frilabr.com/codigo#{{ .Token }}",
    "Link sem query nem tracking",
  );
  conferir(
    (corpo.match(/#{{ \.Token }}/g) ?? []).length === 1,
    "Um token no fragmento",
  );
  conferir(
    /<p[^>]*>\s*{{ \.Token }}\s*<\/p>/.test(corpo),
    "Código selecionável no texto",
  );
  conferir(
    corpo.includes("10 minutos") && corpo.includes("ignore este e-mail"),
    "Validade e segurança preservadas",
  );
  conferir(
    corpo.includes("ou toque e segure o código acima para copiar"),
    "Alternativa de cópia visível",
  );
  conferir(
    /<table[^>]*role="presentation"/.test(corpo),
    "Botão em tabela de apresentação",
  );
});

Deno.test("página restringe recursos, indexação e referência sem dependências externas", () => {
  conferir(pagina.includes('content="noindex, nofollow"'), "Sem indexação");
  conferir(
    pagina.includes('name="referrer" content="no-referrer"'),
    "Sem referência",
  );
  conferir(
    pagina.includes(
      "http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';\"",
    ),
    "CSP restritiva",
  );
  conferir(
    !/<(?:script|link|img)[^>]+(?:src|href)=/i.test(pagina),
    "Sem recursos externos",
  );
  conferir(
    pagina.includes('lang="pt-BR"') &&
      pagina.includes("prefers-color-scheme: dark"),
    "Idioma e tema escuro",
  );
});

Deno.test("botões da marca têm texto branco explícito e foco visível na página", () => {
  conferir(
    /<a[^>]*style="[^"]*background-color: #EA5A36;[^\"]*color: #ffffff;/i.test(
      email,
    ),
    "Link com branco sobre laranja",
  );
  conferir(
    /button\s*\{[^}]*background: #EA5A36;[^}]*color: #ffffff;/i.test(pagina),
    "Botão com branco sobre laranja",
  );
  conferir(
    pagina.includes("min-height: 60px") &&
      pagina.includes("button:focus-visible"),
    "Alvo de toque e foco",
  );
});

Deno.test("aceita seis dígitos preservando zeros e copia pela API de clipboard", async () => {
  for (const codigo of ["123456", "000001", "000000", "999999"]) {
    const tela = abrir(`#${codigo}`);
    conferir(
      !tela.elementos.valido.hidden && tela.elementos.invalido.hidden,
      "Código aceito",
    );
    conferir(tela.elementos.codigo.textContent === codigo, "Código integral");
    await tela.clicar();
    conferir(tela.copiados.join() === codigo, "Clipboard recebe só o código");
    conferir(
      tela.elementos.copiar.textContent === "Copiado!",
      "Feedback de sucesso",
    );
    conferir(
      tela.elementos.estado.textContent === "Volte ao Frila e cole o código",
      "Orientação após copiar",
    );
  }
});

Deno.test("recusa fragmento ausente ou diferente de seis dígitos ASCII, inclusive query válida", async () => {
  for (
    const hash of [
      "",
      "#",
      "#12345",
      "#1234567",
      "#12345a",
      "# 123456",
      "#123456 ",
      "#123456\n",
      "#１２３４５６",
      "#%31%32%33%34%35%36",
      "#123456?utm_source=email",
      "#<script>",
    ]
  ) {
    const tela = abrir(hash);
    conferir(
      tela.elementos.valido.hidden && !tela.elementos.invalido.hidden,
      `Recusar ${JSON.stringify(hash)}`,
    );
    conferir(
      pagina.includes("Abra o link do e-mail de novo"),
      "Mensagem amiga",
    );
    await tela.clicar();
    conferir(tela.copiados.length === 0, "Não copia valor inválido");
  }
});

Deno.test("fallback copia quando API não existe ou recusa e remove o campo temporário", async () => {
  for (const api of ["ausente", "recusado"] as const) {
    const tela = abrir("#012345", api);
    await tela.clicar();
    conferir(
      tela.copiados.join() === "012345" && tela.removido(),
      "Fallback copia e limpa",
    );
    conferir(
      tela.elementos.copiar.textContent === "Copiado!",
      "Sucesso somente após cópia",
    );
  }
});

Deno.test("falha das duas formas de cópia orienta seleção manual sem falso sucesso", async () => {
  const tela = abrir("#123456", "recusado", false);
  await tela.clicar();
  conferir(
    tela.elementos.copiar.textContent !== "Copiado!",
    "Não anuncia cópia que falhou",
  );
  conferir(
    tela.elementos.estado.textContent.includes("toque e segure"),
    "Alternativa manual",
  );
  conferir(tela.removido(), "Campo temporário removido mesmo na falha");
});
