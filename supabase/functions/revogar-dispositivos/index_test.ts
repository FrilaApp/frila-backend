import { assertEquals } from "jsr:@std/assert@1.0.19";
import { tratarRevogarDispositivos } from "./index.ts";

Deno.test("revogar-dispositivos: sem Authorization devolve 401 nao_autenticado", async () => {
  const req = new Request("https://local/functions/v1/revogar-dispositivos", { method: "POST" });
  const res = await tratarRevogarDispositivos(req, {
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: {
      verificarSessaoOnline: () => Promise.resolve(true),
      revogarTodosDispositivos: () => Promise.resolve(0),
    },
  });
  assertEquals(res.status, 401);
  assertEquals((await res.json()).code, "nao_autenticado");
});

Deno.test("revogar-dispositivos: bloqueia sessão não verificada com 401 dispositivo_nao_verificado sem revogar", async () => {
  let chamouRevogar = false;
  const req = new Request("https://local/functions/v1/revogar-dispositivos", {
    method: "POST",
    headers: { "Authorization": "Bearer jwt-bypass" },
  });
  const res = await tratarRevogarDispositivos(req, {
    fetchFn: () => Promise.resolve(Response.json({ id: "user-99" })),
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: {
      verificarSessaoOnline: () => Promise.resolve(false),
      revogarTodosDispositivos: () => {
        chamouRevogar = true;
        return Promise.resolve(0);
      },
    },
  });
  assertEquals(res.status, 401);
  assertEquals((await res.json()).code, "dispositivo_nao_verificado");
  assertEquals(chamouRevogar, false);
});

Deno.test("revogar-dispositivos: revoga todos dispositivos no banco e chama logout scope=global no GoTrue", async () => {
  const chamadas: string[] = [];
  const fetchFn: typeof fetch = (input) => {
    const url = String(input);
    chamadas.push(url);
    if (url.includes("/auth/v1/user")) return Promise.resolve(Response.json({ id: "user-99" }));
    if (url.includes("/auth/v1/logout?scope=global")) return Promise.resolve(new Response(null, { status: 204 }));
    throw new Error(`URL inesperada: ${url}`);
  };

  let uidRevogado = "";
  const req = new Request("https://local/functions/v1/revogar-dispositivos", {
    method: "POST",
    headers: { "Authorization": "Bearer jwt-valido" },
  });

  const res = await tratarRevogarDispositivos(req, {
    fetchFn,
    supabaseUrl: "https://proj.supabase.co",
    anonKey: "anon-test",
    db: {
      verificarSessaoOnline: () => Promise.resolve(true),
      revogarTodosDispositivos: (uid) => {
        uidRevogado = uid;
        return Promise.resolve(3);
      },
    },
  });

  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.ok, true);
  assertEquals(body.dispositivos_revogados, 3);
  assertEquals(uidRevogado, "user-99");
  assertEquals(chamadas.some((u) => u.includes("scope=global")), true);
});
