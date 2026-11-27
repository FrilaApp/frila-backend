// Testes unitários dos utilitários B-116 de `dispositivo_auth.ts` (cartão 7Tu72MYA): o IP do visitante assinado pelo
// Worker (carimbo, chave, escopo), a leitura das chaves, a resolução do IP para o rate limit, o `session_id` do JWT e
// a validação da sessão do GoTrue. Até aqui só os testes das Edge Functions passavam por eles, de longe.
// Chaves e IPs sintéticos; nenhum segredo real. A assinatura é calculada aqui, com o `crypto.subtle` direto, e não
// pela função que está sendo testada.
import { assertEquals, assertStrictEquals } from "jsr:@std/assert@1.0.19";
import {
  extrairSessionIdDoJwt,
  lerChavesIpVisitante,
  resolverIpParaRateLimit,
  validarSessaoGoTrue,
  verificarIpVisitanteAssinado,
} from "./dispositivo_auth.ts";

const CHAVE_K1 = "a1".repeat(32);
const CHAVE_K2 = "b2".repeat(32);
const CHAVES = `k1:${CHAVE_K1},k2:${CHAVE_K2}`;
const AGORA = 1_795_000_000;
const UID = "11111111-2222-4333-8444-555555555555";

async function hmacHex(segredo: string, mensagem: string): Promise<string> {
  const chave = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(segredo),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bruto = new Uint8Array(await crypto.subtle.sign("HMAC", chave, new TextEncoder().encode(mensagem)));
  return Array.from(bruto).map((b) => b.toString(16).padStart(2, "0")).join("");
}

interface Assinada {
  ip: string;
  carimbo: number | string;
  escopo?: string;
  id?: string;
  segredo?: string;
  assinatura?: string;
}

/** Cabeçalhos B-116 como o Worker os manda; `assinatura` sobrescreve o valor calculado (para adulterar). */
async function cabecalhos(a: Assinada): Promise<Record<string, string>> {
  const hex = await hmacHex(a.segredo ?? CHAVE_K1, `v1|${a.ip}|${a.carimbo}|${a.escopo ?? "anon"}`);
  return {
    "x-frila-ip-visitante": a.ip,
    "x-frila-ip-carimbo": String(a.carimbo),
    "x-frila-ip-assinatura": a.assinatura ?? `v1;k=${a.id ?? "k1"};${hex}`,
  };
}

/** Request de verdade (o `Headers` normaliza espaços nas pontas e some com o que o helper confere). */
function pedido(cab: Record<string, string>, extra: Record<string, string> = {}): Request {
  return new Request("https://exemplo.invalid/", { method: "POST", headers: { ...cab, ...extra } });
}

/** Stub que devolve o valor cru, sem a normalização do `Headers`: prova que o helper não depende dela. */
function pedidoCru(cab: Record<string, string>): Request {
  return { headers: { get: (nome: string) => cab[nome.toLowerCase()] ?? null } } as unknown as Request;
}

const opcoes = (extra: Record<string, unknown> = {}) => ({ chavesBrutas: CHAVES, agoraSegundos: AGORA, ...extra });

// ── verificarIpVisitanteAssinado ────────────────────────────────────────────

Deno.test("B-116: assinatura válida de rota anônima devolve o IP", async () => {
  const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(cab), opcoes()), "203.0.113.7");
});

Deno.test("B-116: IPv6 com dois-pontos é aceito", async () => {
  const cab = await cabecalhos({ ip: "2001:db8::1", carimbo: AGORA });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(cab), opcoes()), "2001:db8::1");
});

Deno.test("B-116: sem escopo nas opções vale 'anon'", async () => {
  const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA, escopo: "anon" });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(cab), { chavesBrutas: CHAVES, agoraSegundos: AGORA }), "203.0.113.7");
});

Deno.test("B-116: assinatura feita para o escopo anon não vale para uma rota autenticada (uid), e vice-versa", async () => {
  const paraAnon = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA, escopo: "anon" });
  const paraUid = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA, escopo: UID });

  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(paraAnon), opcoes({ escopo: UID })), null);
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(paraUid), opcoes({ escopo: "anon" })), null);
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(paraUid), opcoes()), null);

  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(paraUid), opcoes({ escopo: UID })), "203.0.113.7");
});

Deno.test("B-116: assinatura de outro uid não vale para este uid", async () => {
  const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA, escopo: "99999999-2222-4333-8444-555555555555" });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(cab), opcoes({ escopo: UID })), null);
});

Deno.test("B-116: carimbo dentro de ±60 s passa e fora recusa (bordas 60 e 61)", async () => {
  for (const [delta, esperado] of [[0, true], [60, true], [-60, true], [61, false], [-61, false], [3600, false], [-3600, false]] as const) {
    const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA + delta });
    assertStrictEquals(
      await verificarIpVisitanteAssinado(pedido(cab), opcoes()),
      esperado ? "203.0.113.7" : null,
      `delta ${delta} s`,
    );
  }
});

Deno.test("B-116: carimbo que não é só dígitos recusa", async () => {
  for (const carimbo of ["", "abc", "12.5", "-1", "1e9", " 1795000000", "1795000000 "]) {
    const cab = await cabecalhos({ ip: "203.0.113.7", carimbo });
    assertStrictEquals(await verificarIpVisitanteAssinado(pedidoCru(cab), opcoes()), null, `carimbo '${carimbo}'`);
  }
});

Deno.test("B-116: k= desconhecido recusa, e k= conhecido de outra chave também", async () => {
  const comOutraChave = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA, id: "k9", segredo: "c3".repeat(32) });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(comOutraChave), opcoes()), null);

  // k= desconhecido com a assinatura calculada com uma chave que existe: não vale cair numa chave "parecida".
  for (const segredo of [CHAVE_K1, CHAVE_K2]) {
    const comChaveExistente = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA, id: "k9", segredo });
    assertStrictEquals(await verificarIpVisitanteAssinado(pedido(comChaveExistente), opcoes()), null);
  }

  // k=k1 na assinatura, mas calculada com a chave do k2: a chave certa é a do id.
  const trocada = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA, id: "k1", segredo: CHAVE_K2 });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(trocada), opcoes()), null);
});

Deno.test("B-116: a rotação de chaves aceita a assinatura de qualquer chave configurada", async () => {
  const k2 = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA, id: "k2", segredo: CHAVE_K2 });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(k2), opcoes()), "203.0.113.7");
});

Deno.test("B-116: sem chaves configuradas nada é aceito", async () => {
  const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(cab), opcoes({ chavesBrutas: "" })), null);
});

Deno.test("B-116: formato da assinatura fora de 'v1;k=<id>;<64 hex minúsculos>' recusa", async () => {
  const valida = (await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA }))["x-frila-ip-assinatura"];
  const hex = valida.split(";")[2];
  const ruins = [
    valida.replace("v1;", "v2;"),
    valida.replace("k=k1", "k=K1"),
    valida.replace("k=k1", "k="),
    valida.replace(";k=k1;", ";"),
    `v1;k=k1;${hex.toUpperCase()}`,
    `v1;k=k1;${hex.slice(1)}`,
    `v1;k=k1;${hex}0`,
    `v1;k=k1;${"x".repeat(64)}`,
    `${valida};`,
    ` ${valida}`,
  ];
  for (const assinatura of ruins) {
    const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA, assinatura });
    assertStrictEquals(await verificarIpVisitanteAssinado(pedidoCru(cab), opcoes()), null, assinatura);
  }
});

Deno.test("B-116: um caractere da assinatura adulterado recusa", async () => {
  const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA });
  const ass = cab["x-frila-ip-assinatura"];
  const ultimo = ass.slice(-1);
  cab["x-frila-ip-assinatura"] = ass.slice(0, -1) + (ultimo === "0" ? "1" : "0");
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(cab), opcoes()), null);
});

Deno.test("B-116: assinatura de outro IP não vale", async () => {
  const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA });
  cab["x-frila-ip-visitante"] = "203.0.113.8";
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(cab), opcoes()), null);
});

Deno.test("B-116: IP com '/' (máscara) recusa mesmo com a assinatura correta", async () => {
  for (const ip of ["203.0.113.0/24", "2001:db8::/32", "/", "10.0.0.1/"]) {
    const cab = await cabecalhos({ ip, carimbo: AGORA });
    assertStrictEquals(await verificarIpVisitanteAssinado(pedido(cab), opcoes()), null, ip);
  }
});

Deno.test("B-116: IP com espaço nas pontas recusa mesmo com a assinatura correta (sem depender do Headers)", async () => {
  for (const ip of [" 203.0.113.7", "203.0.113.7 ", " 203.0.113.7 ", "\t203.0.113.7"]) {
    const cab = await cabecalhos({ ip, carimbo: AGORA });
    assertStrictEquals(await verificarIpVisitanteAssinado(pedidoCru(cab), opcoes()), null, JSON.stringify(ip));
  }
});

Deno.test("B-116: IP com mais de 64 caracteres recusa e com exatamente 64 passa", async () => {
  const ip64 = "2001:db8:aaaa:bbbb:cccc:dddd:eeee:ffff:1111:2222:3333:4444:5555:6".slice(0, 64);
  assertStrictEquals(ip64.length, 64);
  const cab64 = await cabecalhos({ ip: ip64, carimbo: AGORA });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(cab64), opcoes()), ip64);

  const ip65 = ip64 + "7";
  const cab65 = await cabecalhos({ ip: ip65, carimbo: AGORA });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(cab65), opcoes()), null);
});

Deno.test("B-116: falta de qualquer um dos três cabeçalhos devolve null", async () => {
  const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA });
  for (const nome of Object.keys(cab)) {
    const sem = { ...cab };
    delete sem[nome];
    assertStrictEquals(await verificarIpVisitanteAssinado(pedido(sem), opcoes()), null, nome);
  }
});

// ── lerChavesIpVisitante ────────────────────────────────────────────────────

Deno.test("lerChavesIpVisitante: lê 'id:64hex' separado por vírgula, com espaços em volta", () => {
  const mapa = lerChavesIpVisitante(` k1 : ${CHAVE_K1} , k2:${CHAVE_K2}, `);
  assertEquals([...mapa.entries()], [["k1", CHAVE_K1], ["k2", CHAVE_K2]]);
});

Deno.test("lerChavesIpVisitante: ignora entradas inválidas e fica com as válidas", () => {
  const mapa = lerChavesIpVisitante([
    `sem-dois-pontos${CHAVE_K1}`,
    `:${CHAVE_K1}`,
    `K1:${CHAVE_K1}`,
    `id-com-hifen:${CHAVE_K1}`,
    `${"x".repeat(17)}:${CHAVE_K1}`,
    `curta:${"a1".repeat(31)}`,
    `longa:${"a1".repeat(33)}`,
    `maiusc:${"A1".repeat(32)}`,
    `naohex:${"zz".repeat(32)}`,
    `boa:${CHAVE_K2}`,
  ].join(","));
  assertEquals([...mapa.entries()], [["boa", CHAVE_K2]]);
});

Deno.test("lerChavesIpVisitante: id repetido fica com a última chave e id de 16 caracteres é aceito", () => {
  const id16 = "a".repeat(16);
  const mapa = lerChavesIpVisitante(`k1:${CHAVE_K1},k1:${CHAVE_K2},${id16}:${CHAVE_K1}`);
  assertEquals(mapa.get("k1"), CHAVE_K2);
  assertEquals(mapa.get(id16), CHAVE_K1);
});

Deno.test("lerChavesIpVisitante: texto vazio não cai no par de variáveis; indefinido cai", () => {
  const antesId = Deno.env.get("IP_VISITANTE_HMAC_ID");
  const antesSeg = Deno.env.get("IP_VISITANTE_HMAC");
  try {
    Deno.env.set("IP_VISITANTE_HMAC_ID", "unico");
    Deno.env.set("IP_VISITANTE_HMAC", CHAVE_K1);
    assertEquals(lerChavesIpVisitante("").size, 0);
    assertEquals(lerChavesIpVisitante("lixo").size, 0);
    assertEquals([...lerChavesIpVisitante(undefined).entries()], [["unico", CHAVE_K1]]);

    Deno.env.set("IP_VISITANTE_HMAC", "curta");
    assertEquals(lerChavesIpVisitante(undefined).size, 0);
  } finally {
    if (antesId === undefined) Deno.env.delete("IP_VISITANTE_HMAC_ID"); else Deno.env.set("IP_VISITANTE_HMAC_ID", antesId);
    if (antesSeg === undefined) Deno.env.delete("IP_VISITANTE_HMAC"); else Deno.env.set("IP_VISITANTE_HMAC", antesSeg);
  }
});

// ── resolverIpParaRateLimit ─────────────────────────────────────────────────

Deno.test("resolverIpParaRateLimit: web sem chaves configuradas é 503 indisponivel", async () => {
  const r = await resolverIpParaRateLimit(pedido({}), "web", { chavesBrutas: "", agoraSegundos: AGORA });
  assertEquals(r, { ok: false, status: 503, code: "indisponivel" });
});

Deno.test("resolverIpParaRateLimit: web com chaves mas sem cabeçalhos B-116 é 403", async () => {
  const r = await resolverIpParaRateLimit(pedido({ "cf-connecting-ip": "198.51.100.1" }), "web", opcoes());
  assertEquals(r, { ok: false, status: 403, code: "assinatura_ip_invalida" });
});

Deno.test("resolverIpParaRateLimit: web com cabeçalhos válidos devolve o IP assinado, não o do cf-connecting-ip", async () => {
  const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA });
  const r = await resolverIpParaRateLimit(pedido(cab, { "cf-connecting-ip": "198.51.100.1" }), "web", opcoes());
  assertEquals(r, { ok: true, ip: "203.0.113.7" });
});

Deno.test("resolverIpParaRateLimit: com os 3 cabeçalhos B-116, vencidos ou adulterados são 403, também no mobile", async () => {
  const vencido = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA - 61 });
  assertEquals(
    await resolverIpParaRateLimit(pedido(vencido), "ios", opcoes()),
    { ok: false, status: 403, code: "assinatura_ip_invalida" },
  );
  const adulterado = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA });
  adulterado["x-frila-ip-visitante"] = "203.0.113.99";
  assertEquals(
    await resolverIpParaRateLimit(pedido(adulterado), "web", opcoes()),
    { ok: false, status: 403, code: "assinatura_ip_invalida" },
  );
});

Deno.test("resolverIpParaRateLimit: com os 3 cabeçalhos B-116 no mobile e sem chaves configuradas é 503", async () => {
  const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA });
  const r = await resolverIpParaRateLimit(pedido(cab), "android", { chavesBrutas: "", agoraSegundos: AGORA });
  assertEquals(r, { ok: false, status: 503, code: "indisponivel" });
});

Deno.test("resolverIpParaRateLimit: mobile sem B-116 usa o cf-connecting-ip, ou nulo se não vier", async () => {
  assertEquals(
    await resolverIpParaRateLimit(pedido({ "cf-connecting-ip": " 198.51.100.1 " }), "ios", opcoes()),
    { ok: true, ip: "198.51.100.1" },
  );
  assertEquals(await resolverIpParaRateLimit(pedido({}), "android", opcoes()), { ok: true, ip: null });
});

Deno.test("resolverIpParaRateLimit: sem plataforma, 'origin' sem B-116 é 403 e sem 'origin' usa o cf-connecting-ip", async () => {
  assertEquals(
    await resolverIpParaRateLimit(pedido({ origin: "https://exemplo.invalid" }), null, opcoes()),
    { ok: false, status: 403, code: "assinatura_ip_invalida" },
  );
  assertEquals(
    await resolverIpParaRateLimit(pedido({ "cf-connecting-ip": "198.51.100.1" }), null, opcoes()),
    { ok: true, ip: "198.51.100.1" },
  );
});

// ── extrairSessionIdDoJwt ───────────────────────────────────────────────────

function base64url(texto: string): string {
  const bytes = new TextEncoder().encode(texto);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function jwtComPayload(payload: unknown): string {
  return `${base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }))}.${base64url(JSON.stringify(payload))}.assinatura-sintetica`;
}

Deno.test("extrairSessionIdDoJwt: lê o session_id com payloads de todos os restos de padding (0, 2 e 3 sobrando)", () => {
  const vistos = new Set<number>();
  for (let n = 0; n < 12; n++) {
    const sid = "s".repeat(1 + n);
    const payload = base64url(JSON.stringify({ session_id: sid }));
    vistos.add(payload.length % 4);
    assertStrictEquals(extrairSessionIdDoJwt(jwtComPayload({ session_id: sid })), sid, `n=${n}`);
  }
  assertEquals([...vistos].sort(), [0, 2, 3]);
});

Deno.test("extrairSessionIdDoJwt: decodifica base64url com '-' e '_' no payload", () => {
  const payload = { session_id: "sessao-sintetica", nota: "ûÿþ>>>???~~~" };
  const codificado = base64url(JSON.stringify(payload));
  assertEquals(/[-_]/.test(codificado), true, "o fixture precisa ter '-' ou '_' para provar a troca");
  assertStrictEquals(extrairSessionIdDoJwt(jwtComPayload(payload)), "sessao-sintetica");
});

Deno.test("extrairSessionIdDoJwt: sem session_id utilizável devolve null", () => {
  assertStrictEquals(extrairSessionIdDoJwt(jwtComPayload({})), null);
  assertStrictEquals(extrairSessionIdDoJwt(jwtComPayload({ session_id: "" })), null);
  assertStrictEquals(extrairSessionIdDoJwt(jwtComPayload({ session_id: 42 })), null);
  assertStrictEquals(extrairSessionIdDoJwt(jwtComPayload({ session_id: null })), null);
  assertStrictEquals(extrairSessionIdDoJwt(jwtComPayload(null)), null);
});

Deno.test("extrairSessionIdDoJwt: texto que não é JWT devolve null sem lançar", () => {
  for (const jwt of ["", "so-uma-parte", "a.b", "a.!!!.c", `a.${base64url("não é json")}.c`]) {
    assertStrictEquals(extrairSessionIdDoJwt(jwt), null, jwt);
  }
});

// ── validarSessaoGoTrue ─────────────────────────────────────────────────────

const sessaoValida = () => ({
  access_token: "acesso-sintetico",
  token_type: "bearer",
  expires_in: 3600,
  refresh_token: "refresh-sintetico",
  user: { id: UID, email: "pessoa@exemplo.invalid", app_metadata: { a: 1 } },
});

Deno.test("validarSessaoGoTrue: resposta completa volta com os mesmos campos e o user inteiro", () => {
  assertEquals(validarSessaoGoTrue(sessaoValida()), sessaoValida());
});

Deno.test("validarSessaoGoTrue: token_type ausente ou não-string vira 'bearer', e campos extras do topo não passam", () => {
  const { token_type: _, ...semTipo } = sessaoValida();
  assertEquals(validarSessaoGoTrue(semTipo)?.token_type, "bearer");
  assertEquals(validarSessaoGoTrue({ ...sessaoValida(), token_type: 7 })?.token_type, "bearer");
  const comExtra = validarSessaoGoTrue({ ...sessaoValida(), provider_token: "x" }) as unknown as Record<string, unknown>;
  assertEquals("provider_token" in comExtra, false);
});

Deno.test("validarSessaoGoTrue: expires_in 0 é válido; string, ausente ou nulo não", () => {
  assertEquals(validarSessaoGoTrue({ ...sessaoValida(), expires_in: 0 })?.expires_in, 0);
  assertStrictEquals(validarSessaoGoTrue({ ...sessaoValida(), expires_in: "3600" }), null);
  assertStrictEquals(validarSessaoGoTrue({ ...sessaoValida(), expires_in: null }), null);
  const { expires_in: _, ...sem } = sessaoValida();
  assertStrictEquals(validarSessaoGoTrue(sem), null);
});

Deno.test("validarSessaoGoTrue: tokens vazios, ausentes ou de outro tipo recusam", () => {
  for (const campo of ["access_token", "refresh_token"] as const) {
    assertStrictEquals(validarSessaoGoTrue({ ...sessaoValida(), [campo]: "" }), null, `${campo} vazio`);
    assertStrictEquals(validarSessaoGoTrue({ ...sessaoValida(), [campo]: 123 }), null, `${campo} numérico`);
    const copia: Record<string, unknown> = sessaoValida();
    delete copia[campo];
    assertStrictEquals(validarSessaoGoTrue(copia), null, `${campo} ausente`);
  }
});

Deno.test("validarSessaoGoTrue: user ausente, não-objeto ou sem id string recusa", () => {
  for (const user of [undefined, null, "texto", 5, {}, { id: 5 }, { id: null }]) {
    assertStrictEquals(validarSessaoGoTrue({ ...sessaoValida(), user }), null, JSON.stringify(user));
  }
});

Deno.test("validarSessaoGoTrue: o que não é objeto devolve null", () => {
  for (const entrada of [null, undefined, "", "texto", 0, 42, true]) {
    assertStrictEquals(validarSessaoGoTrue(entrada), null, String(entrada));
  }
});

// ── regras que ainda faltavam (parecer do time sobre o #654) ───────────────────────────────────

Deno.test("resolverIpParaRateLimit: um cabeçalho B-116 sozinho já fecha (403), sem cair no cf-connecting-ip", async () => {
  const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA });
  for (const [nome, valor] of Object.entries(cab)) {
    assertEquals(
      await resolverIpParaRateLimit(pedido({ [nome]: valor }, { "cf-connecting-ip": "198.51.100.1" }), "ios", opcoes()),
      { ok: false, status: 403, code: "assinatura_ip_invalida" },
      nome,
    );
  }
});

Deno.test("resolverIpParaRateLimit: x-forwarded-for nunca vira IP", async () => {
  assertEquals(
    await resolverIpParaRateLimit(pedido({ "x-forwarded-for": "198.51.100.9" }), "android", opcoes()),
    { ok: true, ip: null },
  );
});

Deno.test("resolverIpParaRateLimit: no mobile, 'origin' sem B-116 segue pelo cf-connecting-ip", async () => {
  for (const plataforma of ["ios", "android"] as const) {
    assertEquals(
      await resolverIpParaRateLimit(
        pedido({ origin: "https://exemplo.invalid", "cf-connecting-ip": "198.51.100.1" }),
        plataforma,
        opcoes(),
      ),
      { ok: true, ip: "198.51.100.1" },
      plataforma,
    );
  }
});

Deno.test("B-116: sem relógio injetado, a janela usa a hora real", async () => {
  const agora = Math.floor(Date.now() / 1000);
  const novo = await cabecalhos({ ip: "203.0.113.7", carimbo: agora });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(novo), { chavesBrutas: CHAVES }), "203.0.113.7");
  const velho = await cabecalhos({ ip: "203.0.113.7", carimbo: agora - 3600 });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(velho), { chavesBrutas: CHAVES }), null);
});

Deno.test("B-116: carimbo com 13 dígitos recusa mesmo valendo uma hora dentro da janela", async () => {
  const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: `000${AGORA}` });
  assertStrictEquals(await verificarIpVisitanteAssinado(pedido(cab), opcoes()), null);
});

Deno.test("resolverIpParaRateLimit: em rota autenticada o escopo (uid) chega à verificação", async () => {
  const doUid = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA, escopo: UID });
  assertEquals(await resolverIpParaRateLimit(pedido(doUid), "web", opcoes({ escopo: UID })), { ok: true, ip: "203.0.113.7" });
  const anonimo = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA });
  assertEquals(
    await resolverIpParaRateLimit(pedido(anonimo), "web", opcoes({ escopo: UID })),
    { ok: false, status: 403, code: "assinatura_ip_invalida" },
  );
});

Deno.test("resolverIpParaRateLimit: sem plataforma, 'origin' sem B-116 é 403 mesmo com cf-connecting-ip", async () => {
  assertEquals(
    await resolverIpParaRateLimit(
      pedido({ origin: "https://exemplo.invalid", "cf-connecting-ip": "198.51.100.1" }),
      null,
      opcoes(),
    ),
    { ok: false, status: 403, code: "assinatura_ip_invalida" },
  );
});

Deno.test("B-116: sem chaves nas opções, as chaves vêm de IP_VISITANTE_HMAC_CHAVES (verificação e resolver)", async () => {
  const antes = Deno.env.get("IP_VISITANTE_HMAC_CHAVES");
  try {
    Deno.env.set("IP_VISITANTE_HMAC_CHAVES", CHAVES);
    const cab = await cabecalhos({ ip: "203.0.113.7", carimbo: AGORA });
    assertStrictEquals(await verificarIpVisitanteAssinado(pedido(cab), { agoraSegundos: AGORA }), "203.0.113.7");
    assertEquals(await resolverIpParaRateLimit(pedido(cab), "web", { agoraSegundos: AGORA }), { ok: true, ip: "203.0.113.7" });
  } finally {
    if (antes === undefined) Deno.env.delete("IP_VISITANTE_HMAC_CHAVES"); else Deno.env.set("IP_VISITANTE_HMAC_CHAVES", antes);
  }
});
