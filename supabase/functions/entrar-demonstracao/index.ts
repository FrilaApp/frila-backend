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
// Não cria conta, não aceita endereço fora da lista declarada e não expõe credenciais.
// E-mail desconhecido, corpo malformado e falhas de configuração (janela inativa/ausente/sem fuso
// ou código fixo ausente/<6 caracteres) recebem uniformemente `404 nao_encontrado`.
//
// Para endereços da lista declarada: código incorreto recebe `404 nao_encontrado` enquanto
// dentro do teto (até 10 tentativas em 10 minutos por e-mail ou IP); ao ultrapassar o teto
// na janela recente, o ramo incorreto passa a responder `429 excesso_tentativas` e emite
// alerta operacional. O código correto para e-mail da lista é sempre validado com precedência
// (nunca bloqueado por tentativas incorretas acumuladas) enquanto dentro da janela ativa.
//
// ── Tempo de resposta e enumeração ──────────────────────────────────────────────────
//
// Endereços fora da lista retornam 404 imediato sem tocar o banco (~1-5ms), enquanto
// endereços da lista com código incorreto executam consulta e gravação no banco (~30-80ms).
// Optou-se por documentar essa diferença e não aplicar atraso artificial (sleep):
// a lista de e-mails de demonstração é pública no repositório e declarada abertamente
// no App Store Connect para a equipe de revisão da Apple, tornando inócua a enumeração por
// temporização e preservando a eficiência computacional das instâncias Edge.

// O teto de tentativas contra o código fixo.
export const JANELA_MINUTOS = 10;
export const TETO_TENTATIVAS = 10;
// Comprimento mínimo do código de demonstração: 6 dígitos (compatível com a tela de OTP do iOS)
export const MIN_COMPRIMENTO_CODIGO = 6;
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
  ativaAte?: string;
}

export function recusa(status: number, code: string, details: string | null = null): Response {
  const corpo: Erro = { code, message: code, details };
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Comparação que não entrega o prefixo certo pelo tempo que leva para falhar (mitigação timing attack).
import { igualEmTempoConstante } from "../_compartilhado/auth.ts";
export { igualEmTempoConstante };

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

// Extração segura do IP do cliente:
// Na infraestrutura Supabase Edge Functions (Deno Deploy / Cloudflare):
// 1. `cf-connecting-ip`: injetado pela Cloudflare com o IP público real de borda do cliente.
//    O cliente não consegue forjar esse cabeçalho, pois a Cloudflare o substitui na borda.
// 2. `x-real-ip`: cabeçalho de fallback fornecido pelo gateway Kong / proxy reverso.
// 3. `x-forwarded-for`: lista encadeada onde o cliente controla o primeiro elemento,
//    e proxies intermediários acrescentam ao final. Portanto, utiliza-se estritamente
//    o ÚLTIMO elemento da lista para evitar IP spoofing.
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

// Valida e converte a data limite da janela de demonstração.
// Exige formato ISO-8601 estrito com 'T' e fuso horário explícito ('Z' ou offset [+-]HH:MM).
// Formatos sem fuso (ex.: "2026-10-30" ou "2026-10-30T23:59:00") são ambíguos quanto ao fuso
// do ambiente (ex.: meia-noite UTC = 21h BRT do dia anterior) e são rejeitados com fail-closed (NaN).
export function parseLimiteJanela(isoStr: string): number {
  const str = isoStr.trim();
  if (!str) return NaN;
  const padraoIsoComFuso = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})$/i;
  if (!padraoIsoComFuso.test(str)) return NaN;
  const t = new Date(str).getTime();
  return isNaN(t) ? NaN : t;
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

  // 1. Janela de demonstração (Opção A): DEMONSTRACAO_ATIVA_ATE é obrigatória (fail-closed se ausente)
  // Fora da janela, se ausente, ou se sem fuso horário explícito: fecha a porta com 404 e emite alerta operacional.
  const ativaAte = deps.ativaAte ?? (Deno.env.get("DEMONSTRACAO_ATIVA_ATE") ?? "");
  const limiteMs = parseLimiteJanela(ativaAte);
  const janelaValida = !isNaN(limiteMs) && Date.now() <= limiteMs;
  if (!janelaValida) {
    console.error(
      "[ALERTA_CONFIG_DEMONSTRACAO] DEMONSTRACAO_ATIVA_ATE ausente, invalida, sem fuso horario explicito ou expirada",
    );
    return recusa(404, "nao_encontrado");
  }

  // 2. Segredo do código de demonstração: obrigatório e com no mínimo 6 dígitos (compatível com app iOS)
  // Se ausente, vazio ou menor que 6 caracteres: falha fechado com 404 uniforme e emite alerta operacional.
  const esperado = deps.codigoEsperado ?? (Deno.env.get("DEMONSTRACAO_CODIGO") ?? "");
  const codigoValidoConfigurado = esperado !== "" && esperado.length >= MIN_COMPRIMENTO_CODIGO;
  if (!codigoValidoConfigurado) {
    console.error(
      "[ALERTA_CONFIG_DEMONSTRACAO] DEMONSTRACAO_CODIGO ausente ou com comprimento insuficiente (minimo 6 caracteres)",
    );
    return recusa(404, "nao_encontrado");
  }
  const codigoCorreto = igualEmTempoConstante(codigo, esperado);

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

  // 1. Teto por IP no ramo errado: se o IP já atingiu o teto na janela,
  // emite [ALERTA_DEMONSTRACAO] e recusa com 429 limite_excedido sem bater no banco (atenua DoS/força bruta).
  if (!verificarLimiteIp(ip)) {
    console.error(
      "[ALERTA_DEMONSTRACAO] Teto de tentativas incorretas excedido para IP na janela recente",
    );
    return recusa(429, "limite_excedido", "tentativas");
  }

  // Registra a tentativa associada ao IP
  registrarTentativaIp(ip);

  // 2. Contar ANTES de inserir no banco: se o e-mail já atingiu o teto na janela recente,
  // emite [ALERTA_DEMONSTRACAO], não grava mais linhas (previne inundação da tabela) e recusa com 429 limite_excedido
  // conforme especificado no contrato OpenAPI (/entrar-demonstracao -> 429 LimiteExcedido).
  const inicioDaJanela = new Date(Date.now() - JANELA_MINUTOS * 60_000).toISOString();

  const janela = await rest(
    `entrada_demonstracao?select=id&email=eq.${encodeURIComponent(email)}` +
      `&em=gte.${encodeURIComponent(inicioDaJanela)}&aceita=eq.false&limit=${TETO_TENTATIVAS + 1}`,
  );
  if (!janela.ok) return recusa(500, "erro_interno");
  const tentativasErradas = await janela.json();

  if (Array.isArray(tentativasErradas) && tentativasErradas.length >= TETO_TENTATIVAS) {
    console.error(
      "[ALERTA_DEMONSTRACAO] Teto de tentativas incorretas excedido para e-mail na janela recente",
    );
    // Teto por e-mail atingido: não grava mais no banco
    return recusa(429, "limite_excedido", "tentativas");
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
