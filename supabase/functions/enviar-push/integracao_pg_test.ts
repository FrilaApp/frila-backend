// Integração com Postgres REAL (não o sqlClient falso dos outros testes): o parâmetro JSON chega
// ao banco como lista. Com `${JSON.stringify(lista)}::jsonb`, o postgres.js 3.4.4 codificava de novo e
// o banco recebia um texto JSON: jsonb_to_recordset falhava SEMPRE (22023) e nenhum aviso chamada_*
// saía (B-019, achado no ponta a ponta do frila-dev, 13/11/2026). Roda só com FRILA_PG_TESTE_URL
// apontando para um banco LOCAL com as migrações (ex.: postgresql://postgres:postgres@127.0.0.1:54322/postgres).
import "./test_setup.ts";
import postgres from "npm:postgres@3.4.4";
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { criarSqlClient } from "./index.ts";

const URL = Deno.env.get("FRILA_PG_TESTE_URL");

Deno.test({
  name: "integração Postgres: aparelhosQueRecebemChamada manda a lista como jsonb e filtra pelo mínimo",
  ignore: !URL,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const adm = postgres(URL!, { max: 1, connect_timeout: 5 });
    const [antes] = await adm`select ligado from privado.recurso where chave = 'chamada_direta'`;
    const minimo = await adm`select versao_minima from privado.recurso_versao_minima where recurso = 'chamada_direta' and plataforma = 'ios'`;
    try {
      await adm`update privado.recurso set ligado = true where chave = 'chamada_direta'`;
      await adm`insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
                on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima`;
      const cliente = criarSqlClient({ dbUrl: URL });
      const recebem = await cliente.aparelhosQueRecebemChamada!([
        { id: "a", plataforma: "ios", versao_app: "1.2.0" },
        { id: "b", plataforma: "ios", versao_app: null },
        { id: "c", plataforma: "ios", versao_app: "1.1.0" },
        { id: "d", plataforma: "android", versao_app: "9.9.9" },
      ]);
      assertEquals(recebem, ["a"], "só o aparelho iOS no mínimo recebe o aviso de chamada");
    } finally {
      await adm`update privado.recurso set ligado = ${antes?.ligado ?? false} where chave = 'chamada_direta'`;
      await adm`delete from privado.recurso_versao_minima where recurso = 'chamada_direta' and plataforma = 'ios'`;
      if (minimo.length) {
        await adm`insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', ${minimo[0].versao_minima})`;
      }
      await adm.end({ timeout: 2 });
    }
  },
});
