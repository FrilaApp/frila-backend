// Hrl32RqG (102): o teto por IP de `autenticar-senha` (20 em 600 s, chave auth:senha:ip:<sha256>) vale MESMO com o e-mail dentro do limite.
// O teste antigo recusa todas as chaves, e o do e-mail dispara antes: o do IP nunca era exercitado sozinho.
// Só função, sem banco: `db` e `fetch` são falsos e registram as chamadas. Só dados sintéticos.
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { hashSha256Hex } from "../_compartilhado/dispositivo_auth.ts";
import { type AutenticarSenhaDb, tratarAutenticarSenha } from "./index.ts";

const DEPS_BASE = { supabaseUrl: "https://proj.supabase.co", anonKey: "anon-test" };

function req(email: string, ip: string): Request {
  return new Request("https://local/functions/v1/autenticar-senha", {
    method: "POST",
    headers: { "Content-Type": "application/json", "cf-connecting-ip": ip },
    body: JSON.stringify({ email, senha: "senha-sintetica", plataforma: "ios" }),
  });
}

function dbRegistrando(limites: { chave: string; limite: number; janela: number }[], negar: (chave: string) => boolean): AutenticarSenhaDb {
  return {
    consumirRateLimit: (chave, limite, janela) => {
      limites.push({ chave, limite, janela });
      return Promise.resolve(!negar(chave));
    },
    validarEMarcarDispositivo: () => Promise.resolve({ valido: false }),
    criarDesafio: () => Promise.resolve({ desafio_id: "11111111-1111-4111-8111-111111111111", expira_em: "2026-11-27T12:10:00Z" }),
    revogarSessaoPontual: () => Promise.resolve(),
  };
}

Deno.test("autenticar-senha: teto por IP (20 em 600 s) devolve 429 antes do GoTrue mesmo com o e-mail dentro do limite, e só para o IP recusado", async () => {
  const email = "ana@frila.test";
  const ip = "198.51.100.10";
  const chaveEmail = `auth:senha:email:${await hashSha256Hex(email)}`;
  const chaveIp = `auth:senha:ip:${await hashSha256Hex(ip)}`;

  const limites: { chave: string; limite: number; janela: number }[] = [];
  const chamadas: string[] = [];
  const res = await tratarAutenticarSenha(req(email, ip), {
    ...DEPS_BASE,
    fetchFn: (input) => {
      chamadas.push(String(input));
      return Promise.resolve(Response.json({}));
    },
    db: dbRegistrando(limites, (c) => c === chaveIp),
  });
  assertEquals(res.status, 429);
  assertEquals((await res.json()).code, "limite_excedido");
  // O e-mail foi consumido e liberado (10/600); o IP é que recusou (20/600).
  assertEquals(limites, [
    { chave: chaveEmail, limite: 10, janela: 600 },
    { chave: chaveIp, limite: 20, janela: 600 },
  ]);
  assertEquals(chamadas, [], "o GoTrue não é chamado");

  // Outro IP passa do teto e chega ao GoTrue (aqui, credencial recusada: 401).
  const limites2: { chave: string; limite: number; janela: number }[] = [];
  const chamadas2: string[] = [];
  const res2 = await tratarAutenticarSenha(req(email, "198.51.100.11"), {
    ...DEPS_BASE,
    fetchFn: (input) => {
      chamadas2.push(String(input));
      return Promise.resolve(new Response("{}", { status: 400 }));
    },
    db: dbRegistrando(limites2, (c) => c === chaveIp),
  });
  assertEquals(res2.status, 401);
  assertEquals(chamadas2.length, 1);
});

Deno.test("autenticar-senha: teto por e-mail recusado devolve 429 sem nem consumir o do IP", async () => {
  const email = "bia@frila.test";
  const chaveEmail = `auth:senha:email:${await hashSha256Hex(email)}`;
  const limites: { chave: string; limite: number; janela: number }[] = [];
  const res = await tratarAutenticarSenha(req(email, "198.51.100.12"), {
    ...DEPS_BASE,
    fetchFn: () => Promise.resolve(Response.json({})),
    db: dbRegistrando(limites, (c) => c === chaveEmail),
  });
  assertEquals(res.status, 429);
  assertEquals(limites.map((l) => l.chave), [chaveEmail]);
});
