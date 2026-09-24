// A porta de entrada das contas de revisão da App Store.
//
// O Frila entra por código de seis dígitos no e-mail, e o revisor da Apple não tem a
// caixa de entrada de ninguém. Sem esta porta a revisão para na primeira tela, que é a
// diretriz 2.1. Ela aceita só os endereços declarados no App Store Connect, com um
// código fixo guardado em segredo, e devolve a mesma `Sessao` do fluxo normal — daí para
// a frente o app não sabe que a conta é de demonstração.
//
// Roda como Edge Function, e não como RPC, porque emitir sessão é trabalho do Supabase
// Auth e não do Postgres. O contrato diz isso com todas as letras: uma função do Postgres
// com esse poder ficaria exposta em `rest/v1` para qualquer um tentar.
//
// ── Como a sessão nasce ───────────────────────────────────────────────────────────────
//
// Em dois passos, medidos contra a pilha local em 25/09:
//
//   POST /auth/v1/admin/generate_link  {type: magiclink, email}   → devolve `email_otp`
//   POST /auth/v1/verify               {type: magiclink, email, token}  → devolve a sessão
//
// O primeiro usa a chave `service_role` e não manda e-mail nenhum: o código volta no
// corpo da resposta. O segundo é a mesma chamada que o app faz quando a pessoa digita o
// código que recebeu. A resposta do segundo é exatamente o schema `Sessao` do contrato:
// `access_token`, `token_type: bearer`, `expires_in`, `refresh_token` e `user`.
//
// ── O que esta porta não faz ──────────────────────────────────────────────────────────
//
// Não cria conta, não aceita endereço fora da lista declarada e não diz o que deu errado.
// E-mail desconhecido, código errado e corpo malformado recebem todos o mesmo `404
// nao_encontrado`: um `401` no código errado confirmaria que aquele endereço existe, e a
// lista de endereços da revisão é justamente o que não deve ser descoberto.

// O teto de tentativas contra o código fixo. Um código de seis dígitos que nunca expira
// precisa disto: sem o teto, o espaço inteiro sai em poucas horas.
const JANELA_MINUTOS = 10;
const TETO_TENTATIVAS = 10;

const ORIGEM = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

type Erro = { code: string; message: string; details: string | null };

function recusa(status: number, code: string, details: string | null = null): Response {
  const corpo: Erro = { code, message: code, details };
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Comparação que não entrega o prefixo certo pelo tempo que leva para falhar. O
// `localeCompare` e o `===` de string saem no primeiro byte diferente; com um código
// fixo e um teto alto de tentativas isso é explorável.
function igualEmTempoConstante(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diferenca = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diferenca |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diferenca === 0;
}

// Os endereços declarados no App Store Connect, separados por vírgula no segredo.
//
// O contrato fala em **um** e-mail; o cartão `7gpPBgTH` pede **dois**, contratante e
// profissional, porque RN25 dá um perfil por conta e o revisor precisa ver os dois lados.
// Uma lista atende aos dois: com um endereço só, o comportamento é letra por letra o que
// o contrato descreve. A divergência está registrada no cartão e no docs/ESTADO.md.
function emailsDeclarados(): string[] {
  return (Deno.env.get("DEMONSTRACAO_EMAILS") ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter((e) => e.length > 0);
}

async function rest(caminho: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${ORIGEM}/rest/v1/${caminho}`, {
    ...init,
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return recusa(404, "nao_encontrado");

  let email = "";
  let codigo = "";
  try {
    const corpo = await req.json();
    email = String(corpo?.email ?? "").trim().toLowerCase();
    codigo = String(corpo?.codigo ?? "");
  } catch {
    return recusa(404, "nao_encontrado");
  }
  if (email === "" || codigo === "") return recusa(404, "nao_encontrado");

  // O endereço desconhecido sai antes de gravar qualquer coisa. Gravar a tentativa de
  // todo endereço que chega transformaria a tabela num depósito de lixo de quem varre a
  // internet, e o teto de tentativas é por endereço — lixo não precisa de teto.
  if (!emailsDeclarados().includes(email)) return recusa(404, "nao_encontrado");

  // A tentativa é gravada **antes** de conferir o código: quem erra o código tem de
  // consumir a cota igual a quem acerta, senão o teto não segura nada.
  //
  // O carimbo `em` vem do banco, pelo `privado.agora()`, e é ele que define a janela.
  // Calcular a janela com o relógio da função deixaria o teto fora de fase com o resto do
  // produto no dia em que o relógio for deslocado num teste.
  const gravada = await rest("entrada_demonstracao", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({ email, aceita: false }),
  });
  if (!gravada.ok) return recusa(500, "erro_interno");
  const [tentativa] = await gravada.json();
  const inicioDaJanela = new Date(
    new Date(tentativa.em).getTime() - JANELA_MINUTOS * 60_000,
  ).toISOString();

  const janela = await rest(
    `entrada_demonstracao?select=id&email=eq.${encodeURIComponent(email)}` +
      `&em=gte.${encodeURIComponent(inicioDaJanela)}&limit=${TETO_TENTATIVAS + 1}`,
  );
  if (!janela.ok) return recusa(500, "erro_interno");
  if ((await janela.json()).length > TETO_TENTATIVAS) {
    return recusa(429, "limite_excedido", "tentativas");
  }

  const esperado = Deno.env.get("DEMONSTRACAO_CODIGO") ?? "";
  if (esperado === "" || !igualEmTempoConstante(codigo, esperado)) {
    return recusa(404, "nao_encontrado");
  }

  // Passo 1: o código de uso único, sem passar pela caixa de e-mail de ninguém.
  const link = await fetch(`${ORIGEM}/auth/v1/admin/generate_link`, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ type: "magiclink", email }),
  });
  if (!link.ok) return recusa(404, "nao_encontrado");
  const { email_otp } = await link.json();

  // Passo 2: a mesma troca que o app faz com o código digitado.
  const sessao = await fetch(`${ORIGEM}/auth/v1/verify`, {
    method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ type: "magiclink", email, token: email_otp }),
  });
  if (!sessao.ok) return recusa(404, "nao_encontrado");

  await rest(`entrada_demonstracao?id=eq.${tentativa.id}`, {
    method: "PATCH",
    body: JSON.stringify({ aceita: true }),
  });

  return new Response(await sessao.text(), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
