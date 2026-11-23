// Integração com Postgres REAL: os caminhos chegam a privado.validar_expurgo_midia_perfil como LISTA
// jsonb. Com `${JSON.stringify(caminhos)}::jsonb`, o postgres.js 3.4.4 codificava de novo, o banco
// recebia um texto JSON (jsonb_typeof = 'string') e a conferência dos caminhos era pulada em silêncio:
// um pedido com caminho de outra mídia passava (B-019, 13/11/2026). Roda só com FRILA_PG_TESTE_URL
// apontando para um banco LOCAL com as migrações.
import postgres from "npm:postgres@3.4.4";
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { criarSqlClient } from "./index.ts";

const URL = Deno.env.get("FRILA_PG_TESTE_URL");

Deno.test({
  name: "integração Postgres: validarExpurgo confere os caminhos (lista jsonb), e caminho de outra mídia é recusado",
  ignore: !URL,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const adm = postgres(URL!, { max: 1, connect_timeout: 5 });
    const usuario = crypto.randomUUID();
    const midia = crypto.randomUUID();
    try {
      await adm`insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
                values (${usuario}, 'profissional', 'Integração expurgo', '+5561999990999', ${"integ-" + usuario + "@test.invalid"},
                        '1990-01-01', '1.0', now())`;
      await adm`insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
                values (${midia}, ${usuario}, 'profissional', 'foto_perfil', ${"perfil/" + midia + ".jpg"}, 'image/jpeg', 1000, 'removida')`;
      const cliente = criarSqlClient({ dbUrl: URL });
      assertEquals(
        await cliente.validarExpurgo!(midia, "foto_perfil", "midia-perfil", [`perfil/${midia}.jpg`, `perfil/${midia}_thumb.jpg`]),
        true,
        "os caminhos da própria mídia passam",
      );
      assertEquals(
        await cliente.validarExpurgo!(midia, "foto_perfil", "midia-perfil", ["perfil/outra-midia.jpg"]),
        false,
        "caminho de outra mídia é recusado",
      );
    } finally {
      await adm`delete from privado.midia where id = ${midia}`;
      await adm`delete from public.usuario where id = ${usuario}`;
      await adm.end({ timeout: 2 });
    }
  },
});
