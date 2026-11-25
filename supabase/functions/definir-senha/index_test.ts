import { assertEquals } from "jsr:@std/assert@1.0.19";
import { tratarDefinirSenha } from "./index.ts";

function fakeJwt(sessionId: string): string {
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" })).replace(/=/g, "");
  const payload = btoa(JSON.stringify({ sub: "user-1", session_id: sessionId })).replace(/=/g, "");
  return `${header}.${payload}.sig`;
}

Deno.test("definir-senha: atualiza senha, limpa pendência, revoga dispositivos e renova sessão quando refresh_token é enviado", async () => {
  const fetchFn: typeof fetch = (input, init) => {
    const url = String(input);
    if (url.includes("/auth/v1/user") && (init?.method ?? "GET") === "GET") {
      return Promise.resolve(Response.json({ id: "user-1" }));
    }
    if (url.includes("/auth/v1/user") && init?.method === "PUT") {
      return Promise.resolve(Response.json({ id: "user-1" }));
    }
    if (url.includes("grant_type=refresh_token")) {
      return Promise.resolve(
        Response.json({
          access_token: fakeJwt("sess-1"),
          token_type: "bearer",
          expires_in: 3600,
          refresh_token: "ref-novo",
          user: { id: "user-1", email: "ana@frila.test" },
        }),
      );
    }
    throw new Error(`URL inesperada: ${url}`);
  };

  let manterHashRecebido: string | null = "sentinela";
  const req = new Request("https://local/functions/v1/definir-senha", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${fakeJwt("sess-1")}`,
    },
    body: JSON.stringify({
      nova_senha: "NovaSenhaForte123!",
      refresh_token: "ref-antigo",
    }),
  });

  const res = await tratarDefinirSenha(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    pepper: "pepper-test",
    db: {
      verificarSessaoOnline: () => Promise.resolve(true),
      concluirDefinicaoSenha: (_uid, _sid, manterHash) => {
        manterHashRecebido = manterHash;
        return Promise.resolve({ dispositivos_revogados: 2 });
      },
    },
  });

  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.ok, true);
  assertEquals(body.precisa_definir_senha, false);
  assertEquals(body.dispositivos_revogados, 2);
  assertEquals(body.sessao.refresh_token, "ref-novo");
  assertEquals(manterHashRecebido, null);
});

Deno.test("definir-senha: sem refresh_token devolve sessao=null, trata reauthentication_needed, bloqueia bypass 401 e fail-closed 503 sem pepper", async () => {
  const reqOk = new Request("https://local/functions/v1/definir-senha", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${fakeJwt("sess-1")}`,
    },
    body: JSON.stringify({ nova_senha: "NovaSenhaForte123!" }),
  });
  const resOk = await tratarDefinirSenha(reqOk, {
    fetchFn: () => Promise.resolve(Response.json({ id: "user-1" })),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: {
      verificarSessaoOnline: () => Promise.resolve(true),
      concluirDefinicaoSenha: () => Promise.resolve({ dispositivos_revogados: 1 }),
    },
  });
  assertEquals(resOk.status, 200);
  assertEquals((await resOk.json()).sessao, null);

  const reqReauth = new Request("https://local/functions/v1/definir-senha", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${fakeJwt("sess-1")}`,
    },
    body: JSON.stringify({ nova_senha: "NovaSenhaForte123!" }),
  });
  const resReauth = await tratarDefinirSenha(reqReauth, {
    fetchFn: (_input, init) => {
      if ((init?.method ?? "GET") === "GET") return Promise.resolve(Response.json({ id: "user-1" }));
      return Promise.resolve(Response.json({ error_code: "reauthentication_needed" }, { status: 401 }));
    },
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: {
      verificarSessaoOnline: () => Promise.resolve(true),
      concluirDefinicaoSenha: () => Promise.resolve({ dispositivos_revogados: 0 }),
    },
  });
  assertEquals(resReauth.status, 401);
  assertEquals((await resReauth.json()).code, "reautenticacao_necessaria");

  // Bypass GoTrue (sessão não verificada) -> 401 dispositivo_nao_verificado antes de PUT /auth/v1/user
  let chamouPut = false;
  const reqBypass = new Request("https://local/functions/v1/definir-senha", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${fakeJwt("sess-bypass")}`,
    },
    body: JSON.stringify({ nova_senha: "NovaSenhaForte123!" }),
  });
  const resBypass = await tratarDefinirSenha(reqBypass, {
    fetchFn: (_input, init) => {
      if (init?.method === "PUT") chamouPut = true;
      return Promise.resolve(Response.json({ id: "user-1" }));
    },
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: {
      verificarSessaoOnline: () => Promise.resolve(false),
      concluirDefinicaoSenha: () => Promise.resolve({ dispositivos_revogados: 0 }),
    },
  });
  assertEquals(resBypass.status, 401);
  assertEquals((await resBypass.json()).code, "dispositivo_nao_verificado");
  assertEquals(chamouPut, false);

  // Fail-closed: manter_dispositivo_atual=true sem pepper -> 503 indisponivel
  const reqSemPepper = new Request("https://local/functions/v1/definir-senha", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${fakeJwt("sess-1")}`,
    },
    body: JSON.stringify({
      nova_senha: "NovaSenhaForte123!",
      manter_dispositivo_atual: true,
      device_token_atual: "tok-atual",
    }),
  });
  const resSemPepper = await tratarDefinirSenha(reqSemPepper, {
    fetchFn: () => Promise.resolve(Response.json({ id: "user-1" })),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    pepper: "",
    db: {
      verificarSessaoOnline: () => Promise.resolve(true),
      concluirDefinicaoSenha: () => Promise.resolve({ dispositivos_revogados: 0 }),
    },
  });
  assertEquals(resSemPepper.status, 503);
  assertEquals((await resSemPepper.json()).code, "indisponivel");
});
