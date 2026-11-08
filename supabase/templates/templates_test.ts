import email from "./codigo-de-entrada.html" with { type: "text" };
import pagina from "./pagina-codigo/index.html" with { type: "text" };
import config from "../config.toml" with { type: "text" };
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

// Seção de `supabase/config.toml`, sem dependência de parser: o arquivo só tem pares
// `chave = valor` de uma linha nas seções que o e-mail usa.
function secao(nome: string): Record<string, string> {
  const inicio = config.indexOf(`[${nome}]\n`);
  conferir(inicio >= 0, `Seção [${nome}] no config.toml`);
  const corpo = config.slice(inicio + nome.length + 3).split(/^\[/m)[0];
  return Object.fromEntries(
    [...corpo.matchAll(/^([a-z_]+)\s*=\s*(.+?)\s*$/gm)].map((m) => [
      m[1],
      m[2].replace(/^"(.*)"$/, "$1"),
    ]),
  );
}

Deno.test("e-mail do código não tem link, botão nem instrução de toque", () => {
  // O arquivo inteiro, comentário incluído: o comentário também vai no e-mail.
  conferir(
    !/\b(?:href|src|action)\s*=/i.test(email),
    "Nenhum href, src ou action",
  );
  conferir(
    !/<(?:a|button|form|table|img)[\s>]/i.test(email),
    "Nenhum link, botão, formulário, tabela ou imagem",
  );
  conferir(
    !/https?:\/\/|www\.|frilabr\.com/i.test(email),
    "Nenhum endereço em texto",
  );
  conferir(
    !/copiar|toque e segure/i.test(email),
    'Sem botão de cópia nem "toque e segure"',
  );
  conferir(!email.includes("ConfirmationURL"), "Sem link mágico, nem citado");
});

Deno.test("código grande, com os seis dígitos juntos e o respiro só por letter-spacing", () => {
  const acoes = [...email.matchAll(/{{[^}]*}}/g)].map((m) => m[0]);
  conferir(
    acoes.length === 1 && acoes[0] === "{{ .Token }}",
    "Só {{ .Token }}, uma vez",
  );
  const p = email.match(/<p style="([^"]*)">{{ \.Token }}<\/p>/);
  conferir(p, "Token sozinho num <p>, sem espaço nem quebra em volta");
  const tamanho = Number(p[1].match(/font-size:\s*(\d+)px/)?.[1] ?? 0);
  conferir(tamanho >= 32, `Código grande (font-size ${tamanho}px)`);
  conferir(/letter-spacing:\s*\d+px/.test(p[1]), "Respiro por letter-spacing");
  // O que o titular recebe: o <p> do código contém exatamente os seis dígitos, sem
  // espaço, &nbsp;, espaço fino ou marcação entre eles.
  const renderizado = email.replace("{{ .Token }}", "012345");
  const codigo = renderizado.match(
    /<p style="[^"]*letter-spacing[^"]*">([^]*?)<\/p>/,
  )?.[1];
  conferir(
    codigo === "012345",
    `Seis dígitos juntos no HTML (veio ${JSON.stringify(codigo)})`,
  );
});

Deno.test("texto da validade bate com otp_expiry e avisa quem não pediu", () => {
  const auth = secao("auth.email");
  const minutos = Number(auth.otp_expiry) / 60;
  conferir(
    Number.isInteger(minutos) && minutos > 0,
    `otp_expiry em minutos inteiros (${auth.otp_expiry})`,
  );
  conferir(auth.otp_length === "6", "Código de 6 dígitos");
  conferir(
    email.includes(`vale por ${minutos} minutos`),
    `Validade de ${minutos} minutos no texto`,
  );
  conferir(email.includes("serve uma vez só"), "Uso único");
  conferir(
    email.includes("Se não foi você que pediu, ignore este e-mail"),
    "Quem não pediu ignora",
  );
});

Deno.test("assunto e modelo iguais no login e na confirmação do cadastro", () => {
  for (const tipo of ["magic_link", "confirmation"]) {
    const t = secao(`auth.email.template.${tipo}`);
    conferir(
      t.subject === "Seu código de entrada no Frila",
      `Assunto de ${tipo}`,
    );
    conferir(
      t.content_path === "./supabase/templates/codigo-de-entrada.html",
      `Modelo de ${tipo}`,
    );
  }
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

Deno.test("botão da página tem texto branco explícito e foco visível", () => {
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
