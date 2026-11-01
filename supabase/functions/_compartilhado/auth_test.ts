import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  BEARER_REGEX,
  extrairBearerToken,
  igualEmTempoConstante,
  segredoAgendadorValido,
  validarFormatoBearer,
} from "./auth.ts";

Deno.test("auth._compartilhado: igualEmTempoConstante compara igualdade estrita", () => {
  assertEquals(igualEmTempoConstante("segredo", "segredo"), true);
  assertEquals(igualEmTempoConstante("segredo", "outro"), false);
  assertEquals(igualEmTempoConstante("segredo", "segred"), false);
  assertEquals(igualEmTempoConstante("segredo", "segredoo"), false);
  assertEquals(igualEmTempoConstante("", ""), true);
  assertEquals(igualEmTempoConstante("a", ""), false);
  assertEquals(igualEmTempoConstante("", "b"), false);
});

Deno.test("auth._compartilhado: validarFormatoBearer e BEARER_REGEX validam formato estrito", () => {
  assertEquals(validarFormatoBearer("Bearer token-valido"), true);
  assertEquals(validarFormatoBearer("bearer token-valido"), true);
  assertEquals(validarFormatoBearer("BEARER token-valido"), true);

  // Formatos malformados
  assertEquals(validarFormatoBearer("Bearer"), false);
  assertEquals(validarFormatoBearer("Bearer "), false);
  assertEquals(validarFormatoBearer("Bearer   "), false);
  assertEquals(validarFormatoBearer("Bearertoken"), false);
  assertEquals(validarFormatoBearer("X Bearer token"), false);
  assertEquals(validarFormatoBearer("Bearer token extra"), false);
  assertEquals(validarFormatoBearer(null), false);
  assertEquals(validarFormatoBearer(""), false);
});

Deno.test("auth._compartilhado: extrairBearerToken recupera o token corretamente", () => {
  assertEquals(extrairBearerToken("Bearer meu-token-123"), "meu-token-123");
  assertEquals(extrairBearerToken("bearer meu-token-123"), "meu-token-123");
  assertEquals(extrairBearerToken("BEARER meu-token-123"), "meu-token-123");
  assertEquals(extrairBearerToken("Bearer "), null);
  assertEquals(extrairBearerToken("Token 123"), null);
  assertEquals(extrairBearerToken(null), null);
});

Deno.test("auth._compartilhado: segredoAgendadorValido valida via header x-agendador-secret", () => {
  const req = new Request("http://localhost", {
    headers: { "x-agendador-secret": "segredo-super-secreto" },
  });
  assertEquals(segredoAgendadorValido(req, "segredo-super-secreto"), true);
  assertEquals(segredoAgendadorValido(req, "segredo-incorreto"), false);
  assertEquals(segredoAgendadorValido(req, ""), false);
});

Deno.test("auth._compartilhado: segredoAgendadorValido valida via Authorization: Bearer por padrão", () => {
  const req = new Request("http://localhost", {
    headers: { Authorization: "Bearer segredo-super-secreto" },
  });
  assertEquals(segredoAgendadorValido(req, "segredo-super-secreto"), true);
  assertEquals(segredoAgendadorValido(req, "segredo-incorreto"), false);
});

Deno.test("auth._compartilhado: segredoAgendadorValido recusa Bearer quando permitirBearer é false", () => {
  const req = new Request("http://localhost", {
    headers: { Authorization: "Bearer segredo-super-secreto" },
  });
  assertEquals(
    segredoAgendadorValido(req, "segredo-super-secreto", { permitirBearer: false }),
    false,
  );

  const reqHeader = new Request("http://localhost", {
    headers: { "x-agendador-secret": "segredo-super-secreto" },
  });
  assertEquals(
    segredoAgendadorValido(reqHeader, "segredo-super-secreto", { permitirBearer: false }),
    true,
  );
});

Deno.test("auth._compartilhado: segredoAgendadorValido recusa segredo esperado vazio ou com espacos", () => {
  const req = new Request("http://localhost", {
    headers: { "x-agendador-secret": "   " },
  });
  assertEquals(segredoAgendadorValido(req, ""), false);
  assertEquals(segredoAgendadorValido(req, "   "), false);
});

Deno.test("auth._compartilhado: segredoAgendadorValido ignora esquemas de autorizacao nao-Bearer", () => {
  const reqBasic = new Request("http://localhost", {
    headers: { Authorization: "Basic dXNlcjpwYXNz" },
  });
  assertEquals(segredoAgendadorValido(reqBasic, "dXNlcjpwYXNz"), false);

  const reqToken = new Request("http://localhost", {
    headers: { Authorization: "Token meu-segredo" },
  });
  assertEquals(segredoAgendadorValido(reqToken, "meu-segredo"), false);
});
