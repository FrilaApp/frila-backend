// Integração com Postgres REAL: o resolvedor da ler-midia (privado.resolver_link_leitura_midia) pelo
// mesmo driver da função (postgres.js 3.4.4), com o uuid e o token como parâmetros. Prova que o link
// cunhado pelo banco resolve para a miniatura, que um token adivinhado não resolve e que o link
// vence em 1 h. Roda só com FRILA_PG_TESTE_URL apontando para um banco LOCAL com as migrações.
import postgres from "npm:postgres@3.4.4";
import { assertEquals, assertMatch } from "jsr:@std/assert@1.0.19";
import { resolverPadrao } from "./index.ts";

const URL = Deno.env.get("FRILA_PG_TESTE_URL");

Deno.test({
  name: "integração Postgres: o link do dono resolve para a miniatura; token adivinhado e vencido não",
  ignore: !URL,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const adm = postgres(URL!, { max: 1, connect_timeout: 5 });
    const usuario = crypto.randomUUID();
    const midia = crypto.randomUUID();
    let desligadas: string[] = [];
    try {
      await adm`insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
                values (${usuario}, 'profissional', 'Integração ler-midia', '+5561999990858', ${"integ-" + usuario + "@test.invalid"},
                        '1990-01-01', '1.0', now())`;
      await adm`insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
                values (${midia}, ${usuario}, 'profissional', 'foto_perfil', ${"perfil/" + midia + ".jpg"}, 'image/jpeg', 1000, 'aprovada')`;
      desligadas = (await adm`update privado.configuracao_app set foto_de_perfil = true where not foto_de_perfil returning plataforma`)
        .map((l) => String(l.plataforma));

      const [{ url }] = await adm`select privado.cunhar_link_leitura_midia(${midia}::uuid, ${usuario}::uuid) as url`;
      assertMatch(String(url), new RegExp(`/functions/v1/ler-midia\\?midia_id=${midia}&token=[0-9a-f]{64}$`));
      const token = String(url).split("token=")[1];

      const resolver = resolverPadrao({ dbUrl: URL });
      assertEquals(await resolver(midia, token), `perfil/${midia}_thumb.jpg`, "o link do dono resolve");
      assertEquals(await resolver(midia, "e".repeat(64)), null, "token adivinhado não resolve");
      assertEquals(await resolver(crypto.randomUUID(), token), null, "o token não serve a outro id");

      await adm`update privado.midia_link_leitura set expira_em = now() - interval '1 second' where midia_id = ${midia}`;
      assertEquals(await resolver(midia, token), null, "link vencido não resolve");
    } finally {
      if (desligadas.length) await adm`update privado.configuracao_app set foto_de_perfil = false where plataforma in ${adm(desligadas)}`;
      await adm`delete from privado.midia where id = ${midia}`;
      await adm`delete from public.usuario where id = ${usuario}`;
      await adm.end({ timeout: 2 });
    }
  },
});
