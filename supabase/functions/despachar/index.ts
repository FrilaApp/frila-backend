// A porta do motor de despacho. Por enquanto, só a porta.
//
// Quem chama esta função é o agendador — o `pg_cron` e, no Sprint 2, o `net.http_post`
// do `publicar_vaga` e do `cancelar_posicao` —, e nunca um app. A chave publicável está
// dentro do app, que qualquer um descompila; se ela abrisse esta porta, qualquer um
// dispararia despacho. Por isso a função recusa tudo que não traga o segredo do
// agendador no cabeçalho `x-segredo-agendador` (cartão ZqmkOaHn, "Ambientes e segredos").
//
// ── Por que `verify_jwt` desligado ────────────────────────────────────────────────────
//
// Com ele ligado, quem decide é o gateway, e o gateway aceita qualquer JWT válido do
// projeto — inclusive o de uma sessão de usuário comum. A decisão tem de ser desta
// função, e o critério é um só: o segredo. Está no `config.toml`.
//
// ── O que esta porta ainda não faz ────────────────────────────────────────────────────
//
// Não lê a fila `despacho`. Elegibilidade, `despacho`, `notificacao` e o push são do
// cartão 7XS6MQGg (Motor de despacho, Sprint 2). Ler a fila aqui sem o motor apagaria as
// mensagens que o `publicar_vaga` já deixou — a fila é durável justamente para esperar
// por ele. A resposta 200 diz isso: `processadas: 0`.

type Erro = { code: string; message: string; details: string | null };

function recusa(status: number, code: string, details: string | null = null): Response {
  const corpo: Erro = { code, message: code, details };
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Mesma comparação da `entrar-demonstracao`: o `===` de string sai no primeiro byte
// diferente, e o tempo que ele leva entrega o prefixo certo.
function igualEmTempoConstante(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diferenca = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diferenca |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diferenca === 0;
}

Deno.serve((req: Request): Response => {
  // Sem o segredo configurado, a porta fica fechada para todo mundo. Uma variável vazia
  // comparada com um cabeçalho vazio daria "igual", e a porta abriria justamente no
  // ambiente onde alguém esqueceu de configurar.
  const esperado = Deno.env.get("SEGREDO_AGENDADOR") ?? "";
  const recebido = req.headers.get("x-segredo-agendador") ?? "";
  if (esperado === "" || !igualEmTempoConstante(recebido, esperado)) {
    return recusa(401, "nao_autenticado");
  }

  if (req.method !== "POST") return recusa(404, "nao_encontrado");

  return new Response(JSON.stringify({ processadas: 0 }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
