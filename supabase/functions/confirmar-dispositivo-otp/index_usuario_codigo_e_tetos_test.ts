// oa8y5IFj: o que o `index_test.ts` não mede em `confirmar-dispositivo-otp`.
//   1. O GoTrue confirma o código mas devolve OUTRO usuário que o do desafio: 401 codigo_invalido, a sessão recém-criada é revogada (no GoTrue e no
//      Postgres), nada é concluído e nenhuma sessão sai na resposta (login cruzado).
//   2. Código errado: 401 codigo_invalido; GoTrue 429 -> 429; GoTrue 5xx -> 503; sessão ilegível -> 503.
//   3. Os tetos de força bruta: por e-mail (10 em 600 s, só com e-mail informado) e por IP (25 em 600 s): 429 quando `consumirRateLimit` devolve
//      `false` PARA AQUELA CHAVE, com a chave, o limite e a janela certos, sem chamar o GoTrue nem gastar tentativa do desafio.
// Só função, sem banco: o `db` e o `fetch` são falsos. Só dados sintéticos.
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { hashSha256Hex, hashTokenDispositivo } from "../_compartilhado/dispositivo_auth.ts";
import { type ConfirmarDispositivoDb, tratarConfirmarDispositivoOtp } from "./index.ts";

const SEGREDO = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const CARIMBO = 1764030000;
const OPCOES_IP = { chavesBrutas: `a1:${SEGREDO}`, agoraSegundos: CARIMBO + 10 };
const DESAFIO = "11111111-1111-4111-8111-111111111111";

async function cabecalhosWeb(ipVisitante: string): Promise<Record<string, string>> {
  const hmac = await hashTokenDispositivo(`v1|${ipVisitante}|${CARIMBO}|anon`, SEGREDO);
  return {
    "Content-Type": "application/json",
    "cf-connecting-ip": "198.51.100.1",
    "x-frila-ip-visitante": ipVisitante,
    "x-frila-ip-carimbo": String(CARIMBO),
    "x-frila-ip-assinatura": `v1;k=a1;${hmac}`,
  };
}

function fakeJwt(sessionId: string, sub: string): string {
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" })).replace(/=/g, "");
  const payload = btoa(JSON.stringify({ sub, session_id: sessionId })).replace(/=/g, "");
  return `${header}.${payload}.sig`;
}

function sessaoFake(sessionId: string, userId: string) {
  return {
    access_token: fakeJwt(sessionId, userId),
    token_type: "bearer",
    expires_in: 3600,
    refresh_token: "ref-" + sessionId,
    user: { id: userId, email: "ana@frila.test" },
  };
}

interface Registro {
  fetch: { url: string; metodo: string; autorizacao: string | null }[];
  limites: { chave: string; limite: number; janela: number }[];
  reservas: string[];
  concluidos: number;
  revogados: { sessionId: string | null; usuarioId: string }[];
}

/** Um `db` falso que registra tudo. `negar(chave)` decide quais chaves de rate limit são recusadas. */
function dbRegistrando(
  registro: Registro,
  opcoes: { negar?: (chave: string) => boolean; usuarioDoDesafio?: string } = {},
): ConfirmarDispositivoDb {
  return {
    consumirRateLimit: (chave, limite, janela) => {
      registro.limites.push({ chave, limite, janela });
      return Promise.resolve(!(opcoes.negar?.(chave) ?? false));
    },
    reservarTentativaDesafio: (desafioId) => {
      registro.reservas.push(desafioId);
      return Promise.resolve({
        status: "ok" as const,
        usuario_id: opcoes.usuarioDoDesafio ?? "user-1",
        email_normalizado: "ana@frila.test",
        plataforma: "web" as const,
      });
    },
    concluirDesafioERegistrarSessao: () => {
      registro.concluidos++;
      return Promise.resolve({ ok: true, dispositivo_expira_em: null, precisa_definir_senha: false });
    },
    revogarSessaoPontual: (sessionId, usuarioId) => {
      registro.revogados.push({ sessionId, usuarioId });
      return Promise.resolve();
    },
  };
}

function novoRegistro(): Registro {
  return { fetch: [], limites: [], reservas: [], concluidos: 0, revogados: [] };
}

/** `fetch` falso: `verify` devolve o que o teste pedir; o resto (logout, refresh) responde bem e fica registrado. */
function fetchRegistrando(registro: Registro, verify: () => Response): typeof fetch {
  return (input, init) => {
    const url = String(input);
    const cab = new Headers(init?.headers);
    registro.fetch.push({ url, metodo: init?.method ?? "GET", autorizacao: cab.get("Authorization") });
    if (url.includes("/auth/v1/verify")) return Promise.resolve(verify());
    if (url.includes("/auth/v1/logout")) return Promise.resolve(new Response(null, { status: 204 }));
    if (url.includes("grant_type=refresh_token")) return Promise.resolve(Response.json(sessaoFake("sess-final", "user-1")));
    return Promise.reject(new Error(`URL inesperada: ${url}`));
  };
}

const DEPS_BASE = { supabaseUrl: "https://proj.supabase.co", anonKey: "anon-test", opcoesIp: OPCOES_IP };

function reqLogin(cabecalhos: Record<string, string>, codigo = "123456"): Request {
  return new Request("https://local/functions/v1/confirmar-dispositivo-otp", {
    method: "POST",
    headers: cabecalhos,
    body: JSON.stringify({ tipo: "login_dispositivo", desafio_id: DESAFIO, codigo, plataforma: "web", lembrar_dispositivo: false }),
  });
}

function reqCadastro(email: string, plataforma: "ios" | "android" = "ios", cabecalhos: Record<string, string> = {}): Request {
  return new Request("https://local/functions/v1/confirmar-dispositivo-otp", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...cabecalhos },
    body: JSON.stringify({ tipo: "cadastro", email, codigo: "654321", plataforma, lembrar_dispositivo: false }),
  });
}

// ── 1. O GoTrue devolve outro usuário que o do desafio ────────────────────────

Deno.test("confirmar-dispositivo-otp: usuário do GoTrue diferente do desafio recusa 401, revoga a sessão e não conclui nada", async () => {
  const reg = novoRegistro();
  const intrusa = sessaoFake("sess-cruzada", "user-OUTRO");
  const res = await tratarConfirmarDispositivoOtp(reqLogin(await cabecalhosWeb("203.0.113.42")), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(reg, () => Response.json(intrusa)),
    db: dbRegistrando(reg, { usuarioDoDesafio: "user-1" }),
  });

  assertEquals(res.status, 401);
  const corpo = await res.json();
  assertEquals(corpo.code, "codigo_invalido");
  assertEquals(corpo.sessao, undefined, "nenhuma sessão na resposta");
  assertEquals(JSON.stringify(corpo).includes("user-OUTRO"), false, "e o outro usuário não vaza");
  // A sessão recém-criada do outro usuário é derrubada no GoTrue, com o token dela...
  const logout = reg.fetch.filter((f) => f.url.includes("/auth/v1/logout"));
  assertEquals(logout.length, 1);
  assertEquals(logout[0].url.endsWith("scope=local"), true);
  assertEquals(logout[0].autorizacao, `Bearer ${intrusa.access_token}`);
  // ...e no Postgres, para o usuário e a sessão que o GoTrue devolveu.
  assertEquals(reg.revogados, [{ sessionId: "sess-cruzada", usuarioId: "user-OUTRO" }]);
  // Nada é concluído e não há renovação de sessão.
  assertEquals(reg.concluidos, 0);
  assertEquals(reg.fetch.some((f) => f.url.includes("grant_type=refresh_token")), false);
});

Deno.test("confirmar-dispositivo-otp: o mesmo usuário do desafio conclui (controle do login cruzado)", async () => {
  const reg = novoRegistro();
  const res = await tratarConfirmarDispositivoOtp(reqLogin(await cabecalhosWeb("203.0.113.42")), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(reg, () => Response.json(sessaoFake("sess-ok", "user-1"))),
    db: dbRegistrando(reg, { usuarioDoDesafio: "user-1" }),
  });

  assertEquals(res.status, 200);
  assertEquals(reg.concluidos, 1);
  assertEquals(reg.revogados, []);
  assertEquals(reg.fetch.some((f) => f.url.includes("/auth/v1/logout")), false);
});

Deno.test("confirmar-dispositivo-otp: cadastro e recuperação (sem desafio) aceitam o usuário que o GoTrue devolve", async () => {
  for (const tipo of ["cadastro", "recuperacao"] as const) {
    const reg = novoRegistro();
    const req = new Request("https://local/functions/v1/confirmar-dispositivo-otp", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tipo, email: "novo@frila.test", codigo: "654321", plataforma: "ios", lembrar_dispositivo: false }),
    });
    const res = await tratarConfirmarDispositivoOtp(req, {
      ...DEPS_BASE,
      fetchFn: fetchRegistrando(reg, () => Response.json(sessaoFake("sess-novo", "user-qualquer"))),
      db: dbRegistrando(reg),
    });
    assertEquals(res.status, 200, tipo);
    assertEquals(reg.revogados, [], tipo);
  }
});

// ── 2. Código errado e falhas do GoTrue ───────────────────────────────────────

Deno.test("confirmar-dispositivo-otp: código recusado pelo GoTrue (4xx) devolve 401 codigo_invalido, sem sessão e sem revogar nada", async () => {
  for (const status of [400, 401, 403, 404, 422]) {
    const reg = novoRegistro();
    const res = await tratarConfirmarDispositivoOtp(reqLogin(await cabecalhosWeb("203.0.113.42"), "000000"), {
      ...DEPS_BASE,
      fetchFn: fetchRegistrando(reg, () => Response.json({ error: "otp_expired" }, { status })),
      db: dbRegistrando(reg),
    });
    assertEquals(res.status, 401, `GoTrue ${status}`);
    const corpo = await res.json();
    assertEquals(corpo.code, "codigo_invalido", `GoTrue ${status}`);
    assertEquals(JSON.stringify(corpo).includes("ana@frila.test"), false, `GoTrue ${status}: nunca ecoa o e-mail resolvido`);
    assertEquals(reg.reservas.length, 1, `GoTrue ${status}: a tentativa do desafio foi gasta`);
    assertEquals(reg.concluidos, 0, `GoTrue ${status}`);
    assertEquals(reg.revogados, [], `GoTrue ${status}`);
  }
});

Deno.test("confirmar-dispositivo-otp: GoTrue 429 devolve 429 limite_excedido, e 5xx devolve 503 indisponivel", async () => {
  const casos: [number, number, string][] = [
    [429, 429, "limite_excedido"],
    [500, 503, "indisponivel"],
    [502, 503, "indisponivel"],
    [503, 503, "indisponivel"],
  ];
  for (const [statusGoTrue, esperado, code] of casos) {
    const reg = novoRegistro();
    const res = await tratarConfirmarDispositivoOtp(reqLogin(await cabecalhosWeb("203.0.113.42")), {
      ...DEPS_BASE,
      fetchFn: fetchRegistrando(reg, () => new Response("{}", { status: statusGoTrue })),
      db: dbRegistrando(reg),
    });
    assertEquals(res.status, esperado, `GoTrue ${statusGoTrue}`);
    assertEquals((await res.json()).code, code, `GoTrue ${statusGoTrue}`);
    assertEquals(reg.concluidos, 0, `GoTrue ${statusGoTrue}`);
  }
});

Deno.test("confirmar-dispositivo-otp: resposta 200 do GoTrue sem sessão legível devolve 503 indisponivel", async () => {
  for (const corpo of [{}, { access_token: "x" }, "texto"]) {
    const reg = novoRegistro();
    const res = await tratarConfirmarDispositivoOtp(reqLogin(await cabecalhosWeb("203.0.113.42")), {
      ...DEPS_BASE,
      fetchFn: fetchRegistrando(reg, () => Response.json(corpo)),
      db: dbRegistrando(reg),
    });
    assertEquals(res.status, 503, JSON.stringify(corpo));
    assertEquals((await res.json()).code, "indisponivel");
    assertEquals(reg.concluidos, 0);
  }
});

// ── 3. Os tetos por e-mail e por IP ───────────────────────────────────────────

Deno.test("confirmar-dispositivo-otp: teto por e-mail (10 em 600 s) devolve 429 sem chamar o GoTrue, e só para o e-mail recusado", async () => {
  const email = "cadastro.teto@frila.test";
  const chaveEmail = `auth:verify:email:${await hashSha256Hex(email)}`;

  const reg = novoRegistro();
  const res = await tratarConfirmarDispositivoOtp(reqCadastro(email), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(reg, () => Response.json(sessaoFake("sess-novo", "user-1"))),
    db: dbRegistrando(reg, { negar: (chave) => chave === chaveEmail }),
  });
  assertEquals(res.status, 429);
  assertEquals((await res.json()).code, "limite_excedido");
  assertEquals(reg.limites[0], { chave: chaveEmail, limite: 10, janela: 600 });
  assertEquals(reg.fetch.length, 0, "o GoTrue não é chamado");

  // Outro e-mail, com a mesma recusa só para a chave do primeiro: passa do teto e segue (aqui, até o código recusado).
  const reg2 = novoRegistro();
  const res2 = await tratarConfirmarDispositivoOtp(reqCadastro("outro.email@frila.test"), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(reg2, () => Response.json({}, { status: 400 })),
    db: dbRegistrando(reg2, { negar: (chave) => chave === chaveEmail }),
  });
  assertEquals(res2.status, 401);
  assertEquals(reg2.fetch.length, 1, "o GoTrue foi chamado: o teto do outro e-mail não estourou");
});

Deno.test("confirmar-dispositivo-otp: teto por IP (25 em 600 s) devolve 429 sem chamar o GoTrue nem gastar tentativa do desafio, e só para o IP recusado", async () => {
  const ip = "198.51.100.77";
  const chaveIp = `auth:verify:ip:${await hashSha256Hex(ip)}`;
  // Cliente nativo (ios): o IP vem do cf-connecting-ip.
  const cab = { "Content-Type": "application/json", "cf-connecting-ip": ip };
  const corpo = JSON.stringify({ tipo: "login_dispositivo", desafio_id: DESAFIO, codigo: "123456", plataforma: "ios", lembrar_dispositivo: false });

  const reg = novoRegistro();
  const res = await tratarConfirmarDispositivoOtp(new Request("https://local/x", { method: "POST", headers: cab, body: corpo }), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(reg, () => Response.json(sessaoFake("sess-ok", "user-1"))),
    db: dbRegistrando(reg, { negar: (chave) => chave === chaveIp }),
  });
  assertEquals(res.status, 429);
  assertEquals((await res.json()).code, "limite_excedido");
  // Login por desafio não tem e-mail informado: só o teto de IP é consumido.
  assertEquals(reg.limites, [{ chave: chaveIp, limite: 25, janela: 600 }]);
  assertEquals(reg.reservas, [], "a tentativa do desafio não é gasta");
  assertEquals(reg.fetch.length, 0, "o GoTrue não é chamado");

  // Outro IP: passa do teto e chega ao GoTrue.
  const reg2 = novoRegistro();
  const res2 = await tratarConfirmarDispositivoOtp(
    new Request("https://local/x", { method: "POST", headers: { ...cab, "cf-connecting-ip": "198.51.100.78" }, body: corpo }),
    {
      ...DEPS_BASE,
      fetchFn: fetchRegistrando(reg2, () => Response.json({}, { status: 400 })),
      db: dbRegistrando(reg2, { negar: (chave) => chave === chaveIp }),
    },
  );
  assertEquals(res2.status, 401);
  assertEquals(reg2.reservas.length, 1);
});

Deno.test("confirmar-dispositivo-otp: no cadastro, o teto de e-mail vem antes do de IP, e cada um é consumido com a sua chave", async () => {
  const email = "ordem.tetos@frila.test";
  const ip = "198.51.100.90";
  const chaveEmail = `auth:verify:email:${await hashSha256Hex(email)}`;
  const chaveIp = `auth:verify:ip:${await hashSha256Hex(ip)}`;
  const req = () => reqCadastro(email, "ios", { "cf-connecting-ip": ip });

  // Os dois liberados: as duas chaves são consumidas, nesta ordem, com os limites certos.
  const reg = novoRegistro();
  const res = await tratarConfirmarDispositivoOtp(req(), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(reg, () => Response.json(sessaoFake("sess-novo", "user-1"))),
    db: dbRegistrando(reg),
  });
  assertEquals(res.status, 200);
  assertEquals(reg.limites, [
    { chave: chaveEmail, limite: 10, janela: 600 },
    { chave: chaveIp, limite: 25, janela: 600 },
  ]);

  // E-mail recusado: o IP nem é consumido.
  const regEmail = novoRegistro();
  const resEmail = await tratarConfirmarDispositivoOtp(req(), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(regEmail, () => Response.json({})),
    db: dbRegistrando(regEmail, { negar: (chave) => chave === chaveEmail }),
  });
  assertEquals(resEmail.status, 429);
  assertEquals(regEmail.limites.map((l) => l.chave), [chaveEmail]);

  // IP recusado, e-mail liberado: 429 do mesmo jeito.
  const regIp = novoRegistro();
  const resIp = await tratarConfirmarDispositivoOtp(req(), {
    ...DEPS_BASE,
    fetchFn: fetchRegistrando(regIp, () => Response.json({})),
    db: dbRegistrando(regIp, { negar: (chave) => chave === chaveIp }),
  });
  assertEquals(resIp.status, 429);
  assertEquals(regIp.fetch.length, 0);
});
