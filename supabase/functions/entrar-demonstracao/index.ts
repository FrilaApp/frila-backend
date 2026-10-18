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

// O teto de tentativas contra o código fixo.
export const JANELA_MINUTOS = 10;
export const TETO_TENTATIVAS = 10;
// Entropia mínima do código de demonstração: falha fechado se for menor que 20 caracteres
export const MIN_COMPRIMENTO_CODIGO = 20;
// Limite máximo de entradas no mapa de IPs para evitar vazamento de memória
export const MAX_IPS_EM_MEMORIA = 1000;

export interface Erro {
  code: string;
  message: string;
  details: string | null;
}

export interface HandlerDeps {
  fetchFn?: typeof fetch;
  supabaseUrl?: string;
  serviceRoleKey?: string;
  anonKey?: string;
  emailsDeclarados?: string[];
  codigoEsperado?: string;
}

export function recusa(status: number, code: string, details: string | null = null): Response {
  const corpo: Erro = { code, message: code, details };
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Comparação que não entrega o prefixo certo pelo tempo que leva para falhar. O
// `localeCompare` e o `===` de string saem no primeiro byte diferente; com um código
// fixo e um teto alto de tentativas isso é explorável.
export function igualEmTempoConstante(a: string, b: string): boolean {
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
export function emailsDeclarados(): string[] {
  return (Deno.env.get("DEMONSTRACAO_EMAILS") ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter((e) => e.length > 0);
}

// Extração segura do IP do cliente: cabeçalho da borda que o cliente não consegue forjar.
// Se houver x-forwarded-for com múltiplos IPs, o cliente controla o primeiro,
// enquanto o proxy reverso/borda acrescenta o IP real ao final.
export function extrairIpCliente(req: Request): string {
  const cf = req.headers.get("cf-connecting-ip")?.trim();
  if (cf) return cf;
  const realIp = req.headers.get("x-real-ip")?.trim();
  if (realIp) return realIp;
  const xff = req.headers.get("x-forwarded-for");
  if (xff) {
    const partes = xff.split(",").map((p) => p.trim()).filter(Boolean);
    if (partes.length > 0) return partes[partes.length - 1];
  }
  return "desconhecido";
}

// Rate limit em memória por IP (10 tentativas erradas por 10 min)
const tentativasPorIp = new Map<string, number[]>();

function podarMapIp(agoraMs: number): void {
  for (const [chave, timestamps] of tentativasPorIp.entries()) {
    const validos = timestamps.filter((t) => agoraMs - t < JANELA_MINUTOS * 60_000);
    if (validos.length === 0) {
      tentativasPorIp.delete(chave);
    } else {
      tentativasPorIp.set(chave, validos);
    }
  }
  if (tentativasPorIp.size > MAX_IPS_EM_MEMORIA) {
    const excedente = tentativasPorIp.size - MAX_IPS_EM_MEMORIA;
    let removidos = 0;
    for (const chave of tentativasPorIp.keys()) {
      tentativasPorIp.delete(chave);
      removidos++;
      if (removidos >= excedente) break;
    }
  }
}

export function verificarLimiteIp(ip: string, agoraMs = Date.now()): boolean {
  if (!ip || ip === "desconhecido") return true;
  const timestamps = (tentativasPorIp.get(ip) ?? []).filter(
    (t) => agoraMs - t < JANELA_MINUTOS * 60_000,
  );
  return timestamps.length < TETO_TENTATIVAS;
}

export function registrarTentativaIp(ip: string, agoraMs = Date.now()): void {
  if (!ip || ip === "desconhecido") return;
  podarMapIp(agoraMs);
  const timestamps = (tentativasPorIp.get(ip) ?? []).filter(
    (t) => agoraMs - t < JANELA_MINUTOS * 60_000,
  );
  timestamps.push(agoraMs);
  tentativasPorIp.set(ip, timestamps);
}

export function resetarLimitesIp(): void {
  tentativasPorIp.clear();
}

export async function handler(req: Request, deps: HandlerDeps = {}): Promise<Response> {
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

  const listaEmails = deps.emailsDeclarados ?? emailsDeclarados();

  // O endereço desconhecido sai antes de gravar qualquer coisa. Gravar a tentativa de
  // todo endereço que chega transformaria a tabela num depósito de lixo de quem varre a
  // internet, e o teto de tentativas é por endereço — lixo não precisa de teto.
  if (!listaEmails.includes(email)) return recusa(404, "nao_encontrado");

  const fetchFn = deps.fetchFn ?? fetch;
  const origem = (deps.supabaseUrl ?? Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
  const serviceRole = deps.serviceRoleKey ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anon = deps.anonKey ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  const rest = async (caminho: string, init: RequestInit = {}): Promise<Response> => {
    return await fetchFn(`${origem}/rest/v1/${caminho}`, {
      ...init,
      headers: {
        apikey: serviceRole,
        Authorization: `Bearer ${serviceRole}`,
        "Content-Type": "application/json",
        ...(init.headers ?? {}),
      },
    });
  };

  const esperado = deps.codigoEsperado ?? (Deno.env.get("DEMONSTRACAO_CODIGO") ?? "");
  // O código fixo de demonstração DEVE ter alta entropia (mínimo 20 caracteres)
  // para tornar inviável busca exaustiva. Se for menor ou vazio, falha fechado.
  const codigoValidoConfigurado = esperado !== "" && esperado.length >= MIN_COMPRIMENTO_CODIGO;
  const codigoCorreto = codigoValidoConfigurado && igualEmTempoConstante(codigo, esperado);

  // DIRETRIZ 2.1 DA APPLE: o código CORRETO nunca é bloqueado por tentativas erradas
  // prévias nem por rate limit de IP (ataques de negação de serviço contra o revisor são neutralizados).
  if (codigoCorreto) {
    // Passo 1: o código de uso único, sem passar pela caixa de e-mail de ninguém.
    const link = await fetchFn(`${origem}/auth/v1/admin/generate_link`, {
      method: "POST",
      headers: {
        apikey: serviceRole,
        Authorization: `Bearer ${serviceRole}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ type: "magiclink", email }),
    });
    if (!link.ok) return recusa(404, "nao_encontrado");
    const { email_otp } = await link.json();

    // Passo 2: a mesma troca que o app faz com o código digitado.
    const sessao = await fetchFn(`${origem}/auth/v1/verify`, {
      method: "POST",
      headers: { apikey: anon, "Content-Type": "application/json" },
      body: JSON.stringify({ type: "magiclink", email, token: email_otp }),
    });
    if (!sessao.ok) return recusa(404, "nao_encontrado");

    // Registra a entrada bem-sucedida para auditoria
    const gravada = await rest("entrada_demonstracao", {
      method: "POST",
      body: JSON.stringify({ email, aceita: true }),
    });
    if (!gravada.ok) return recusa(500, "erro_interno");

    return new Response(await sessao.text(), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Código INCORRETO:
  const ip = extrairIpCliente(req);

  // 1. Teto por IP no ramo errado: se o IP já atingiu o teto na janela, recusa
  // uniformemente sem bater no banco (atenua DoS/força bruta).
  if (!verificarLimiteIp(ip)) {
    return recusa(404, "nao_encontrado");
  }

  // Registra a tentativa associada ao IP
  registrarTentativaIp(ip);

  // 2. Contar ANTES de inserir no banco: se o e-mail já atingiu o teto na janela recente,
  // não grava mais linhas (previne inundação da tabela) e recusa uniformemente com 404
  // (sem revelar 429 para não confirmar existência do e-mail na lista da Apple).
  const inicioDaJanela = new Date(Date.now() - JANELA_MINUTOS * 60_000).toISOString();

  const janela = await rest(
    `entrada_demonstracao?select=id&email=eq.${encodeURIComponent(email)}` +
      `&em=gte.${encodeURIComponent(inicioDaJanela)}&aceita=eq.false&limit=${TETO_TENTATIVAS + 1}`,
  );
  if (!janela.ok) return recusa(500, "erro_interno");
  const tentativasErradas = await janela.json();

  if (Array.isArray(tentativasErradas) && tentativasErradas.length >= TETO_TENTATIVAS) {
    // Teto por e-mail atingido: não grava mais no banco
    return recusa(404, "nao_encontrado");
  }

  // Grava a tentativa errada no banco para computar cota
  const gravada = await rest("entrada_demonstracao", {
    method: "POST",
    body: JSON.stringify({ email, aceita: false }),
  });
  if (!gravada.ok) return recusa(500, "erro_interno");

  return recusa(404, "nao_encontrado");
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => await handler(req));
}
