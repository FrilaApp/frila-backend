// Testes da Edge Function moderar-midia (cartão B4c · RN37 · RN15).
//
// Tudo por injeção de dependência: nem rede, nem banco, nem provedor de verdade. O que o
// suíte precisa provar não é "retornou 200", é a regra de FALHA FECHADA: qualquer dúvida
// mantém a mídia `em_analise`, não a publica e não tira a mensagem da fila. Por isso o
// mundo em memória abaixo (Storage, `privado.midia`, fila e consumo do provedor) tem a
// semântica real das consultas, e cada teste olha o estado final dele, não só a resposta.
//
// Os JPEGs são reais (codificados com jpeg-js), porque sanitizar e gerar miniatura sobre
// bytes inventados provaria só que o teste concorda consigo mesmo.

import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.19";
import jpeg from "npm:jpeg-js@0.4.4";
import {
  caminhoMiniatura,
  criarProvedor,
  dimensoesValidas,
  ErroConfiguracao,
  ErroMiniaturaExcedeMemoria,
  ErroProvedor,
  gerarMiniaturaJpeg,
  handler,
  HandlerDeps,
  lerTetoMensal,
  MensagemModeracao,
  MOTIVOS_RECUSA,
  provedorAzure,
  provedorLocal,
  provedorOpenAI,
  ProvedorModeracao,
  ReservaChamada,
  sanitizarJpeg,
  temMagicBytesJpeg,
} from "./index.ts";

const MOCK_URL = "http://127.0.0.1:54321";
const MOCK_SERVICE_ROLE = "service-role-key-mock";
const MOCK_SECRET = "segredo-agendador-mock";
const MOCK_DB_URL = "postgresql://mock:mock@localhost:5432/mock";

const MIDIA_1 = "b4c00000-0000-4000-8000-000000000001";
const MIDIA_2 = "b4c00000-0000-4000-8000-000000000002";

// ---------------------------------------------------------------------------------------
// Fábrica de JPEGs
// ---------------------------------------------------------------------------------------

function fazerJpeg(largura: number, altura: number): Uint8Array {
  const dados = new Uint8Array(largura * altura * 4);
  for (let y = 0; y < altura; y++) {
    for (let x = 0; x < largura; x++) {
      const p = (y * largura + x) * 4;
      dados[p] = (x * 255 / largura) | 0;
      dados[p + 1] = (y * 255 / altura) | 0;
      dados[p + 2] = 128;
      dados[p + 3] = 255;
    }
  }
  return new Uint8Array(jpeg.encode({ data: dados, width: largura, height: altura }, 85).data);
}

function segmento(marcador: number, corpo: Uint8Array): Uint8Array {
  const tamanho = corpo.length + 2;
  return Uint8Array.of(0xff, marcador, tamanho >> 8, tamanho & 0xff, ...corpo);
}

function texto(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

function juntar(...partes: Uint8Array[]): Uint8Array {
  const saida = new Uint8Array(partes.reduce((n, p) => n + p.length, 0));
  let pos = 0;
  for (const p of partes) {
    saida.set(p, pos);
    pos += p.length;
  }
  return saida;
}

function contem(bytes: Uint8Array, trecho: string): boolean {
  return new TextDecoder("latin1").decode(bytes).includes(trecho);
}

/** Insere segmentos logo depois do SOI. */
function injetarDepoisDoSoi(b: Uint8Array, ...segmentos: Uint8Array[]): Uint8Array {
  return juntar(b.subarray(0, 2), ...segmentos, b.subarray(2));
}

const EXIF_COM_GPS = segmento(
  0xe1,
  texto("Exif\0\0MM GPSLatitude=-15.7942 GPSLongitude=-47.8822 Make=Apple Model=iPhone"),
);

/** Reescreve largura e altura no SOF0 sem tocar no resto (a validação não decodifica). */
function comDimensoes(b: Uint8Array, largura: number, altura: number): Uint8Array {
  const copia = b.slice();
  let i = 2;
  while (i < copia.length) {
    const m = copia[i + 1];
    const tamanho = (copia[i + 2] << 8) | copia[i + 3];
    if (m === 0xc0) {
      copia[i + 5] = altura >> 8;
      copia[i + 6] = altura & 0xff;
      copia[i + 7] = largura >> 8;
      copia[i + 8] = largura & 0xff;
      return copia;
    }
    i += 2 + tamanho;
  }
  throw new Error("SOF0 não encontrado no JPEG de teste");
}

/** JPEG progressivo (SOF2) sintético, com duas varreduras, preenchimento, RST e lixo no fim. */
function fazerProgressivoSintetico(largura: number, altura: number): { entrada: Uint8Array; esperado: Uint8Array } {
  const sof2 = segmento(0xc2, Uint8Array.of(8, altura >> 8, altura & 0xff, largura >> 8, largura & 0xff, 1, 1, 0x11, 0));
  const dht = segmento(0xc4, Uint8Array.of(0xaa, 0xbb));
  const sos = segmento(0xda, Uint8Array.of(1, 1, 0, 0, 0x3f, 0));
  const varredura1 = Uint8Array.of(0x12, 0xff, 0x00, 0x34, 0xff, 0xd0, 0x56, 0x78);
  const varredura2 = Uint8Array.of(0x9a, 0xbc);
  const soi = Uint8Array.of(0xff, 0xd8);
  const eoi = Uint8Array.of(0xff, 0xd9);
  const corpo = juntar(soi, sof2, dht, sos, varredura1, Uint8Array.of(0xff), dht, sos, varredura2, eoi);
  return { entrada: juntar(corpo, Uint8Array.of(0xde, 0xad, 0xbe, 0xef)), esperado: corpo };
}

// ---------------------------------------------------------------------------------------
// Sanitização: magic bytes, dimensões, metadados
// ---------------------------------------------------------------------------------------

Deno.test("magic bytes: só FF D8 FF é JPEG", () => {
  assert(temMagicBytesJpeg(fazerJpeg(200, 200)));
  assertFalse(temMagicBytesJpeg(Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))); // PNG
  assertFalse(temMagicBytesJpeg(Uint8Array.of(0xff, 0xd8, 0x00, 0xe0))); // FF D8 sem o terceiro FF
  assertFalse(temMagicBytesJpeg(Uint8Array.of(0xff, 0xd8, 0xff))); // curto demais
  assertFalse(temMagicBytesJpeg(new Uint8Array(0)));
  assertFalse(temMagicBytesJpeg(texto("GIF89a-isto-nao-e-jpeg")));
});

Deno.test("sanitizar: arquivo que não é JPEG falha com formato_invalido", () => {
  const r = sanitizarJpeg(Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0));
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.motivo, "formato_invalido");
});

Deno.test("sanitizar: lê largura e altura no SOF0 (baseline)", () => {
  const r = sanitizarJpeg(fazerJpeg(320, 240));
  assert(r.ok);
  if (r.ok) {
    assertEquals(r.largura, 320);
    assertEquals(r.altura, 240);
  }
});

Deno.test("sanitizar: lê largura e altura no SOF2 (progressivo) e preserva as duas varreduras", () => {
  const { entrada, esperado } = fazerProgressivoSintetico(640, 480);
  const r = sanitizarJpeg(entrada);
  assert(r.ok);
  if (r.ok) {
    assertEquals(r.largura, 640);
    assertEquals(r.altura, 480);
    assertEquals(r.sanitizado, esperado); // nada além do lixo depois do EOI foi tocado
  }
});

Deno.test("sanitizar: remove APP1 (EXIF/GPS), APP13 e COM, e a imagem continua decodificando", () => {
  const original = injetarDepoisDoSoi(
    fazerJpeg(300, 200),
    EXIF_COM_GPS,
    segmento(0xed, texto("Photoshop 3.0 IPTC Byline=Fulano")),
    segmento(0xfe, texto("comentario-com-nome-do-titular")),
  );
  assert(contem(original, "GPSLatitude"));
  assert(contem(original, "iPhone"));

  const r = sanitizarJpeg(original);
  assert(r.ok);
  if (!r.ok) return;
  assertFalse(contem(r.sanitizado, "GPSLatitude"));
  assertFalse(contem(r.sanitizado, "Exif"));
  assertFalse(contem(r.sanitizado, "iPhone"));
  assertFalse(contem(r.sanitizado, "Photoshop"));
  assertFalse(contem(r.sanitizado, "comentario-com-nome"));
  assert(r.sanitizado.length < original.length);

  const lido = jpeg.decode(r.sanitizado, { useTArray: true });
  assertEquals(lido.width, 300);
  assertEquals(lido.height, 200);
});

Deno.test("sanitizar: mantém APP0 (JFIF) e APP2 (perfil de cor)", () => {
  const original = injetarDepoisDoSoi(fazerJpeg(200, 200), segmento(0xe2, texto("ICC_PROFILE\0marcador-de-cor")));
  const r = sanitizarJpeg(original);
  assert(r.ok);
  if (r.ok) {
    assert(contem(r.sanitizado, "JFIF"));
    assert(contem(r.sanitizado, "ICC_PROFILE"));
  }
});

Deno.test("sanitizar: bytes depois do EOI são descartados", () => {
  const limpo = fazerJpeg(200, 200);
  const r = sanitizarJpeg(juntar(limpo, texto("PAYLOAD-ESCONDIDO-DEPOIS-DO-EOI")));
  assert(r.ok);
  if (r.ok) {
    assertFalse(contem(r.sanitizado, "PAYLOAD-ESCONDIDO"));
    assertEquals(r.sanitizado, limpo);
  }
});

Deno.test("sanitizar: é idempotente (sanitizar o já sanitizado não muda nada)", () => {
  const primeiro = sanitizarJpeg(injetarDepoisDoSoi(fazerJpeg(250, 250), EXIF_COM_GPS));
  assert(primeiro.ok);
  if (!primeiro.ok) return;
  const segundo = sanitizarJpeg(primeiro.sanitizado);
  assert(segundo.ok);
  if (segundo.ok) assertEquals(segundo.sanitizado, primeiro.sanitizado);
});

Deno.test("sanitizar: estrutura quebrada falha fechada", () => {
  const valido = fazerJpeg(200, 200);
  const casos: Record<string, Uint8Array> = {
    "truncado, sem EOI": valido.subarray(0, valido.length - 2),
    "truncado no meio de um segmento": valido.subarray(0, 40),
    "tamanho de segmento maior que o arquivo": juntar(Uint8Array.of(0xff, 0xd8), Uint8Array.of(0xff, 0xe0, 0xff, 0xff, 0x00)),
    "tamanho de segmento menor que 2": juntar(Uint8Array.of(0xff, 0xd8), Uint8Array.of(0xff, 0xe0, 0x00, 0x01)),
    "sem SOF antes do SOS": juntar(Uint8Array.of(0xff, 0xd8), segmento(0xda, Uint8Array.of(1, 1, 0, 0, 0x3f, 0)), Uint8Array.of(1, 2, 0xff, 0xd9)),
    "EOI sem SOF": Uint8Array.of(0xff, 0xd8, 0xff, 0xd9, 0, 0),
    "SOI repetido": juntar(Uint8Array.of(0xff, 0xd8), Uint8Array.of(0xff, 0xd8, 0xff, 0xe0, 0, 2)),
    "lixo no lugar do marcador": juntar(Uint8Array.of(0xff, 0xd8, 0xff), Uint8Array.of(0xe0, 0, 2), Uint8Array.of(0x41, 0x42, 0x43, 0x44)),
  };
  for (const [nome, bytes] of Object.entries(casos)) {
    assertEquals(sanitizarJpeg(bytes).ok, false, nome);
  }
});

Deno.test("sanitizar: SOF que não é baseline nem progressivo (SOF1, SOF3, aritmético) é recusado", () => {
  for (const marcador of [0xc1, 0xc3, 0xc5, 0xc9, 0xcf]) {
    const sof = segmento(marcador, Uint8Array.of(8, 0, 200, 0, 200, 1, 1, 0x11, 0));
    const bytes = juntar(
      Uint8Array.of(0xff, 0xd8),
      sof,
      segmento(0xda, Uint8Array.of(1, 1, 0, 0, 0x3f, 0)),
      Uint8Array.of(0x01, 0xff, 0xd9),
    );
    assertEquals(sanitizarJpeg(bytes).ok, false, `SOF 0x${marcador.toString(16)}`);
  }
});

Deno.test("sanitizar: dois SOF no mesmo arquivo é recusado (ambiguidade de dimensão)", () => {
  const sof = segmento(0xc0, Uint8Array.of(8, 0, 200, 0, 200, 1, 1, 0x11, 0));
  const bytes = juntar(Uint8Array.of(0xff, 0xd8), sof, sof, segmento(0xda, Uint8Array.of(1, 1, 0, 0, 0x3f, 0)), Uint8Array.of(1, 0xff, 0xd9));
  assertEquals(sanitizarJpeg(bytes).ok, false);
});

Deno.test("dimensões: 200..5000 por lado e proporção entre 0,5 e 2,0", () => {
  assert(dimensoesValidas(200, 200));
  assert(dimensoesValidas(5000, 5000));
  assert(dimensoesValidas(200, 400)); // proporção 0,5 exata
  assert(dimensoesValidas(400, 200)); // proporção 2,0 exata
  assertFalse(dimensoesValidas(199, 300));
  assertFalse(dimensoesValidas(300, 199));
  assertFalse(dimensoesValidas(5001, 3000));
  assertFalse(dimensoesValidas(3000, 5001));
  assertFalse(dimensoesValidas(200, 410)); // 0,487
  assertFalse(dimensoesValidas(410, 200)); // 2,05
  assertFalse(dimensoesValidas(0, 0));
  assertFalse(dimensoesValidas(4000, 1900)); // 2,1
});

Deno.test("miniatura: lado maior em 256 px, proporção mantida e JPEG decodificável", () => {
  const miniatura = gerarMiniaturaJpeg(fazerJpeg(600, 300));
  assert(temMagicBytesJpeg(miniatura));
  const lida = jpeg.decode(miniatura, { useTArray: true });
  assertEquals(lida.width, 256);
  assertEquals(lida.height, 128);
});

Deno.test("miniatura: imagem pequena não é ampliada", () => {
  const lida = jpeg.decode(gerarMiniaturaJpeg(fazerJpeg(200, 150)), { useTArray: true });
  assertEquals(lida.width, 200);
  assertEquals(lida.height, 150);
});

Deno.test("miniatura: não carrega metadados", () => {
  const entrada = injetarDepoisDoSoi(fazerJpeg(300, 300), EXIF_COM_GPS);
  assertFalse(contem(gerarMiniaturaJpeg(entrada), "GPSLatitude"));
});

Deno.test("miniatura: imagem grande demais para a memória lança erro próprio (não derruba o worker)", () => {
  // O jpeg-js confere a memória pelas dimensões do SOF, antes de decodificar um pixel.
  const grande = comDimensoes(fazerJpeg(300, 300), 4000, 3000);
  try {
    gerarMiniaturaJpeg(grande);
    throw new Error("deveria lançar");
  } catch (err) {
    assert(err instanceof ErroMiniaturaExcedeMemoria, String(err));
  }
});

Deno.test("miniatura: caminho segue perfil/<midia_id>_thumb.jpg", () => {
  assertEquals(caminhoMiniatura(MIDIA_1), `perfil/${MIDIA_1}_thumb.jpg`);
});

// ---------------------------------------------------------------------------------------
// Provedores de moderação
// ---------------------------------------------------------------------------------------

interface ChamadaHttp {
  url: string;
  metodo: string;
  cabecalhos: Record<string, string>;
  corpo: unknown;
}

function fetchGravando(
  responder: (c: ChamadaHttp) => Response | Promise<Response>,
): { fetchFn: typeof fetch; chamadas: ChamadaHttp[] } {
  const chamadas: ChamadaHttp[] = [];
  const fetchFn = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const chamada: ChamadaHttp = {
      url,
      metodo: init?.method ?? "GET",
      cabecalhos: { ...(init?.headers as Record<string, string> ?? {}) },
      corpo: typeof init?.body === "string" ? JSON.parse(init.body) : init?.body,
    };
    chamadas.push(chamada);
    return await responder(chamada);
  };
  return { fetchFn: fetchFn as unknown as typeof fetch, chamadas };
}

function json(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json" } });
}

const ENTRADA = { original: fazerJpeg(200, 200), miniatura: fazerJpeg(200, 200) };

Deno.test("provedor local: aprova, determinístico, sem tocar na rede", async () => {
  const p = provedorLocal();
  assertEquals(p.nome, "local");
  assertEquals(p.externo, false);
  assertEquals(await p.analisar(ENTRADA), { aprovada: true });
  assertEquals(await p.analisar(ENTRADA), { aprovada: true });
});

Deno.test("provedor openai: envia a imagem em data URL com a chave e respeita `flagged`", async () => {
  const { fetchFn, chamadas } = fetchGravando(() => json({ results: [{ flagged: false }] }));
  const p = provedorOpenAI("chave-openai-mock", fetchFn);
  assertEquals(p.nome, "openai");
  assertEquals(p.externo, true);
  assertEquals(await p.analisar(ENTRADA), { aprovada: true });

  assertEquals(chamadas.length, 1);
  assertEquals(chamadas[0].url, "https://api.openai.com/v1/moderations");
  assertEquals(chamadas[0].metodo, "POST");
  assertEquals(chamadas[0].cabecalhos["Authorization"], "Bearer chave-openai-mock");
  const corpo = chamadas[0].corpo as { model: string; input: Array<{ type: string; image_url: { url: string } }> };
  assertEquals(corpo.model, "omni-moderation-latest");
  assertEquals(corpo.input[0].type, "image_url");
  assert(corpo.input[0].image_url.url.startsWith("data:image/jpeg;base64,/9j/"));
});

Deno.test("provedor openai: flagged=true reprova", async () => {
  const { fetchFn } = fetchGravando(() => json({ results: [{ flagged: true, categories: { sexual: true } }] }));
  assertEquals(await provedorOpenAI("k", fetchFn).analisar(ENTRADA), { aprovada: false });
});

Deno.test("provedor openai: erro de HTTP, rede, corpo ilegível ou inesperado vira ErroProvedor (nunca aprova)", async () => {
  const casos: Array<[string, () => Response | Promise<Response>, number]> = [
    ["HTTP 500", () => json({}, 500), 500],
    ["HTTP 429", () => json({}, 429), 429],
    ["HTTP 401", () => json({}, 401), 401],
    ["rede", () => Promise.reject(new TypeError("rede caiu")) as unknown as Response, 0],
    ["timeout", () => Promise.reject(new DOMException("tempo", "TimeoutError")) as unknown as Response, 0],
    ["corpo ilegível", () => new Response("<html>", { status: 200 }), 200],
    ["sem results", () => json({}), 200],
    ["flagged não booleano", () => json({ results: [{ flagged: "sim" }] }), 200],
  ];
  for (const [nome, responder, statusEsperado] of casos) {
    const { fetchFn } = fetchGravando(responder);
    try {
      await provedorOpenAI("k", fetchFn).analisar(ENTRADA);
      throw new Error(`${nome}: deveria lançar`);
    } catch (err) {
      assert(err instanceof ErroProvedor, `${nome}: ${err}`);
      assertEquals((err as ErroProvedor).status, statusEsperado, nome);
    }
  }
});

Deno.test("provedor azure: endpoint, chave, categorias e limiar de severidade", async () => {
  const severidades: number[][] = [[0, 0], [2, 2], [4, 0], [0, 6]];
  const esperado = [true, true, false, false];
  for (let i = 0; i < severidades.length; i++) {
    const [sexual, violencia] = severidades[i];
    const { fetchFn, chamadas } = fetchGravando(() =>
      json({ categoriesAnalysis: [{ category: "Sexual", severity: sexual }, { category: "Violence", severity: violencia }] })
    );
    const p = provedorAzure("chave-azure-mock", "https://frila.cognitiveservices.azure.com/", fetchFn);
    assertEquals(p.nome, "azure");
    assertEquals(p.externo, true);
    assertEquals((await p.analisar(ENTRADA)).aprovada, esperado[i], `severidades ${severidades[i]}`);

    assertEquals(chamadas[0].url, "https://frila.cognitiveservices.azure.com/contentsafety/image:analyze?api-version=2023-10-01");
    assertEquals(chamadas[0].cabecalhos["Ocp-Apim-Subscription-Key"], "chave-azure-mock");
    const corpo = chamadas[0].corpo as { image: { content: string }; categories: string[] };
    assertEquals(corpo.categories, ["Sexual", "Violence"]);
    assert(corpo.image.content.startsWith("/9j/"));
  }
});

Deno.test("provedor azure: acima de 4 MB manda a miniatura em vez do original", async () => {
  const { fetchFn, chamadas } = fetchGravando(() => json({ categoriesAnalysis: [{ category: "Sexual", severity: 0 }, { category: "Violence", severity: 0 }] }));
  const grande = new Uint8Array(4 * 1024 * 1024 + 1);
  grande.set([0xff, 0xd8, 0xff]);
  const miniatura = fazerJpeg(200, 200);
  await provedorAzure("k", "https://x.example", fetchFn).analisar({ original: grande, miniatura });
  const enviado = (chamadas[0].corpo as { image: { content: string } }).image.content;
  assertEquals(enviado.length, btoa(String.fromCharCode(...miniatura)).length);
});

Deno.test("provedor azure: falha de HTTP ou resposta sem análise vira ErroProvedor", async () => {
  const casos: Array<() => Response> = [
    () => json({}, 503),
    () => json({}),
    () => json({ categoriesAnalysis: [] }),
    () => json({ categoriesAnalysis: [{ category: "Sexual" }] }),
  ];
  for (const responder of casos) {
    const { fetchFn } = fetchGravando(responder);
    try {
      await provedorAzure("k", "https://x.example", fetchFn).analisar(ENTRADA);
      throw new Error("deveria lançar");
    } catch (err) {
      assert(err instanceof ErroProvedor);
    }
  }
});

Deno.test("criarProvedor: padrão é local; exige credenciais; rejeita nome desconhecido e mock por ambiente", () => {
  const nada = fetchGravando(() => json({})).fetchFn;
  assertEquals(criarProvedor({}, nada).nome, "local");
  assertEquals(criarProvedor({ MODERACAO_PROVEDOR: "  " }, nada).nome, "local");
  assertEquals(criarProvedor({ MODERACAO_PROVEDOR: "LOCAL" }, nada).nome, "local");
  assertEquals(criarProvedor({ MODERACAO_PROVEDOR: "openai", OPENAI_API_KEY: "k" }, nada).nome, "openai");
  assertEquals(
    criarProvedor({ MODERACAO_PROVEDOR: "azure", AZURE_CONTENT_SAFETY_KEY: "k", AZURE_CONTENT_SAFETY_ENDPOINT: "https://e" }, nada).nome,
    "azure",
  );

  const invalidos: Array<Record<string, string>> = [
    { MODERACAO_PROVEDOR: "openai" },
    { MODERACAO_PROVEDOR: "azure", AZURE_CONTENT_SAFETY_KEY: "k" },
    { MODERACAO_PROVEDOR: "azure", AZURE_CONTENT_SAFETY_ENDPOINT: "https://e" },
    { MODERACAO_PROVEDOR: "mock" },
    { MODERACAO_PROVEDOR: "google" },
  ];
  for (const env of invalidos) {
    try {
      criarProvedor(env, nada);
      throw new Error(`deveria lançar para ${JSON.stringify(env)}`);
    } catch (err) {
      assert(err instanceof ErroConfiguracao, String(err));
    }
  }
});

Deno.test("teto mensal: padrão 5000 (cota gratuita), aceita inteiro >= 0, rejeita o resto", () => {
  assertEquals(lerTetoMensal({}), 5000);
  assertEquals(lerTetoMensal({ MODERACAO_TETO_MENSAL: "" }), 5000);
  assertEquals(lerTetoMensal({ MODERACAO_TETO_MENSAL: "120" }), 120);
  assertEquals(lerTetoMensal({ MODERACAO_TETO_MENSAL: "0" }), 0);
  for (const ruim of ["-1", "abc", "1.5", "1e3x"]) {
    try {
      lerTetoMensal({ MODERACAO_TETO_MENSAL: ruim });
      throw new Error(`deveria lançar para ${ruim}`);
    } catch (err) {
      assert(err instanceof ErroConfiguracao, ruim);
    }
  }
});

// ---------------------------------------------------------------------------------------
// Mundo em memória para o handler
// ---------------------------------------------------------------------------------------

interface MidiaFake {
  id: string;
  storage_path: string;
  estado: string;
  motivo_codigo: string | null;
  motivo_recusa: string | null;
}

type FalhaStorage = number | "rede" | undefined;

interface Mundo {
  objetos: Map<string, Uint8Array>;
  midias: Map<string, MidiaFake>;
  fila: MensagemModeracao[];
  removidosDaFila: number[];
  reservas: Array<{ midia_id: string; provedor: string; mes: string }>;
  alertas: Array<Record<string, unknown>>;
  chamadasStorage: string[];
  chamadasProvedor: number;
  lerLoteArgs: Array<[number, number]>;
  reservasPedidas: Array<{ mes: string; teto: number; maximoPorFoto: number }>;
  falhaStorage?: (metodo: string, caminho: string) => FalhaStorage;
  falhaBanco?: Partial<Record<"obterMidia" | "marcarAprovada" | "marcarRecusada" | "lerLote" | "reservar", () => boolean>>;
  apiExterna?: (url: string, init?: RequestInit) => Response | Promise<Response>;
}

function novoMundo(): Mundo {
  return {
    objetos: new Map(),
    midias: new Map(),
    fila: [],
    removidosDaFila: [],
    reservas: [],
    alertas: [],
    chamadasStorage: [],
    chamadasProvedor: 0,
    lerLoteArgs: [],
    reservasPedidas: [],
  };
}

let proximoMsgId = 100;

function semear(
  mundo: Mundo,
  id: string,
  bytes: Uint8Array,
  opcoes: { estado?: string; reanalise?: boolean; read_ct?: number } = {},
): MensagemModeracao {
  const caminho = `perfil/${id}.jpg`;
  mundo.objetos.set(caminho, bytes);
  mundo.midias.set(id, {
    id,
    storage_path: caminho,
    estado: opcoes.estado ?? "em_analise",
    motivo_codigo: null,
    motivo_recusa: null,
  });
  const msg: MensagemModeracao = {
    msg_id: proximoMsgId++,
    read_ct: opcoes.read_ct ?? 1,
    midia_id: id,
    reanalise: opcoes.reanalise ?? false,
  };
  mundo.fila.push(msg);
  return msg;
}

function quebrar(mundo: Mundo, nome: keyof NonNullable<Mundo["falhaBanco"]>): boolean {
  return mundo.falhaBanco?.[nome]?.() === true;
}

function criarDeps(mundo: Mundo, extra: Partial<HandlerDeps> = {}): HandlerDeps {
  const fetchFn = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (!url.startsWith(MOCK_URL)) {
      mundo.chamadasProvedor += 1;
      if (!mundo.apiExterna) return Promise.reject(new Error(`chamada externa inesperada: ${url}`));
      return Promise.resolve(mundo.apiExterna(url, init));
    }

    const cabecalhos = (init?.headers ?? {}) as Record<string, string>;
    if (cabecalhos["Authorization"] !== `Bearer ${MOCK_SERVICE_ROLE}`) {
      return Promise.resolve(new Response("{}", { status: 401 }));
    }
    const m = url.match(/\/storage\/v1\/object\/midia-perfil\/(.+)$/);
    if (!m) return Promise.resolve(new Response("{}", { status: 404 }));
    const caminho = m[1].split("/").map(decodeURIComponent).join("/");
    const metodo = init?.method ?? "GET";
    mundo.chamadasStorage.push(`${metodo} ${caminho}`);

    const falha = mundo.falhaStorage?.(metodo, caminho);
    if (falha === "rede") return Promise.reject(new TypeError("rede caiu"));
    if (typeof falha === "number") return Promise.resolve(new Response("{}", { status: falha }));

    if (metodo === "GET") {
      const obj = mundo.objetos.get(caminho);
      if (!obj) return Promise.resolve(new Response("{}", { status: 404 }));
      return Promise.resolve(new Response(obj.slice(), { status: 200 }));
    }
    if (metodo === "POST") {
      if (cabecalhos["x-upsert"] !== "true") return Promise.resolve(new Response("{}", { status: 409 }));
      mundo.objetos.set(caminho, (init?.body as Uint8Array).slice());
      return Promise.resolve(new Response("{}", { status: 200 }));
    }
    if (metodo === "DELETE") {
      mundo.objetos.delete(caminho);
      return Promise.resolve(new Response("{}", { status: 200 }));
    }
    return Promise.resolve(new Response("{}", { status: 405 }));
  };

  return {
    fetchFn: fetchFn as unknown as typeof fetch,
    supabaseUrl: MOCK_URL,
    serviceRoleKey: MOCK_SERVICE_ROLE,
    agendadorSecret: MOCK_SECRET,
    dbUrl: MOCK_DB_URL,
    env: {},
    agora: () => new Date("2026-11-07T15:00:00Z"),
    alerta: (e) => mundo.alertas.push(e),
    sqlClient: {
      lerLote: (q, v) => {
        mundo.lerLoteArgs.push([q, v]);
        if (quebrar(mundo, "lerLote")) return Promise.reject(new Error("fila ilegivel"));
        return Promise.resolve(mundo.fila.filter((x) => !mundo.removidosDaFila.includes(x.msg_id)).slice(0, q));
      },
      obterMidia: (id) => {
        if (quebrar(mundo, "obterMidia")) return Promise.reject(new Error("banco fora"));
        const m = mundo.midias.get(id);
        return Promise.resolve(m ? { id: m.id, storage_path: m.storage_path, estado: m.estado } : null);
      },
      marcarAprovada: (id) => {
        if (quebrar(mundo, "marcarAprovada")) return Promise.reject(new Error("banco fora"));
        const m = mundo.midias.get(id);
        if (!m || m.estado !== "em_analise") return Promise.resolve(false);
        m.estado = "aprovada";
        return Promise.resolve(true);
      },
      marcarRecusada: (id, codigo, motivo) => {
        if (quebrar(mundo, "marcarRecusada")) return Promise.reject(new Error("banco fora"));
        const m = mundo.midias.get(id);
        if (!m || m.estado !== "em_analise") return Promise.resolve(false);
        m.estado = "recusada";
        m.motivo_codigo = codigo;
        m.motivo_recusa = motivo;
        return Promise.resolve(true);
      },
      removerDaFila: (msgId) => {
        mundo.removidosDaFila.push(msgId);
        return Promise.resolve();
      },
      reservarChamada: (midiaId, provedor, mes, teto, maximoPorFoto): Promise<ReservaChamada> => {
        if (quebrar(mundo, "reservar")) return Promise.reject(new Error("tabela de consumo indisponivel"));
        mundo.reservasPedidas.push({ mes, teto, maximoPorFoto });
        if (mundo.reservas.filter((r) => r.mes === mes && r.provedor === provedor).length >= teto) {
          return Promise.resolve("teto_mensal");
        }
        if (mundo.reservas.filter((r) => r.midia_id === midiaId).length >= maximoPorFoto) {
          return Promise.resolve("limite_foto");
        }
        mundo.reservas.push({ midia_id: midiaId, provedor, mes });
        return Promise.resolve("ok");
      },
      liberarChamada: (midiaId, provedor, mes) => {
        const i = mundo.reservas.findLastIndex((r) => r.midia_id === midiaId && r.provedor === provedor && r.mes === mes);
        if (i >= 0) mundo.reservas.splice(i, 1);
        return Promise.resolve();
      },
    },
    ...extra,
  };
}

function provedorMock(
  mundo: Mundo,
  veredito: (() => boolean | Promise<boolean>) | "falha" = () => true,
  externo = true,
): ProvedorModeracao {
  return {
    nome: "mock",
    externo,
    analisar: async () => {
      mundo.chamadasProvedor += 1;
      if (veredito === "falha") throw new ErroProvedor("rede_ou_timeout", 0);
      return { aprovada: await veredito() };
    },
  };
}

interface Rodada {
  resp: Response;
  corpo: Record<string, unknown>;
}

async function rodar(deps: HandlerDeps, corpoReq?: unknown): Promise<Rodada> {
  const req = new Request("http://localhost/moderar-midia", {
    method: "POST",
    headers: { "x-agendador-secret": MOCK_SECRET, "Content-Type": "application/json" },
    body: corpoReq === undefined ? undefined : JSON.stringify(corpoReq),
  });
  const resp = await handler(req, deps);
  return { resp, corpo: await resp.json() };
}

const IMAGEM_BOA = injetarDepoisDoSoi(fazerJpeg(400, 300), EXIF_COM_GPS);

// ---------------------------------------------------------------------------------------
// Autenticação e roteamento
// ---------------------------------------------------------------------------------------

Deno.test("handler: só aceita POST", async () => {
  const mundo = novoMundo();
  const resp = await handler(new Request("http://localhost/", { method: "GET" }), criarDeps(mundo));
  assertEquals(resp.status, 405);
  await resp.body?.cancel();
});

Deno.test("handler: sem segredo ou com segredo errado responde 401 e não lê a fila", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  const tentativas: Array<Record<string, string>> = [{}, { "x-agendador-secret": "errado" }, { Authorization: "Bearer errado" }];
  for (const cabecalhos of tentativas) {
    const resp = await handler(new Request("http://localhost/", { method: "POST", headers: cabecalhos }), criarDeps(mundo));
    assertEquals(resp.status, 401);
    assertEquals((await resp.json()).code, "nao_autenticado");
  }
  assertEquals(mundo.lerLoteArgs.length, 0);
  assertEquals(mundo.midias.get(MIDIA_1)?.estado, "em_analise");
});

Deno.test("handler: aceita o segredo também por Authorization: Bearer", async () => {
  const mundo = novoMundo();
  const resp = await handler(
    new Request("http://localhost/", { method: "POST", headers: { Authorization: `Bearer ${MOCK_SECRET}` } }),
    criarDeps(mundo),
  );
  assertEquals(resp.status, 200);
  await resp.body?.cancel();
});

Deno.test("handler: fila vazia devolve zeros", async () => {
  const mundo = novoMundo();
  const { resp, corpo } = await rodar(criarDeps(mundo));
  assertEquals(resp.status, 200);
  assertEquals(corpo.mensagens_lidas, 0);
  assertEquals(corpo.aprovadas, 0);
  assertEquals(corpo.pendentes, []);
});

Deno.test("handler: lote padrão 20, visibilidade 120 s, e o lote pedido é limitado a 1..100", async () => {
  const mundo = novoMundo();
  await rodar(criarDeps(mundo));
  await rodar(criarDeps(mundo), { lote: 500 });
  await rodar(criarDeps(mundo), { lote: 0 });
  await rodar(criarDeps(mundo), { lote: 7.9 });
  await rodar(criarDeps(mundo), { lote: "muitos" });
  assertEquals(mundo.lerLoteArgs, [[20, 120], [100, 120], [1, 120], [7, 120], [20, 120]]);
});

Deno.test("handler: fila ilegível responde 500 (não finge fila vazia)", async () => {
  const mundo = novoMundo();
  mundo.falhaBanco = { lerLote: () => true };
  const { resp, corpo } = await rodar(criarDeps(mundo));
  assertEquals(resp.status, 500);
  assertEquals(corpo.code, "erro_interno");
});

// ---------------------------------------------------------------------------------------
// Caminho feliz, recusas determinísticas e idempotência
// ---------------------------------------------------------------------------------------

Deno.test("handler: foto válida é sanitizada, ganha miniatura, é aprovada e sai da fila", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
  const { resp, corpo } = await rodar(criarDeps(mundo));

  assertEquals(resp.status, 200);
  assertEquals(corpo.aprovadas, 1);
  assertEquals(mundo.midias.get(MIDIA_1)?.estado, "aprovada");
  assertEquals(mundo.removidosDaFila, [msg.msg_id]);

  // O original foi regravado SEM metadados, no mesmo storage_path.
  const gravado = mundo.objetos.get(`perfil/${MIDIA_1}.jpg`)!;
  assertFalse(contem(gravado, "GPSLatitude"));
  assertFalse(contem(gravado, "iPhone"));
  assertEquals(jpeg.decode(gravado, { useTArray: true }).width, 400);

  // A miniatura nasceu no servidor, em perfil/<id>_thumb.jpg.
  const miniatura = mundo.objetos.get(`perfil/${MIDIA_1}_thumb.jpg`)!;
  assert(miniatura);
  const lida = jpeg.decode(miniatura, { useTArray: true });
  assertEquals(lida.width, 256);
  assertEquals(lida.height, 192);
  assertFalse(contem(miniatura, "GPSLatitude"));
});

Deno.test("handler: provedor local não consulta nem consome o teto", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  await rodar(criarDeps(mundo));
  assertEquals(mundo.reservasPedidas.length, 0);
  assertEquals(mundo.chamadasProvedor, 0);
});

Deno.test("handler: sem MODERACAO_PROVEDOR o padrão é local (aprova sem rede)", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  const { corpo } = await rodar(criarDeps(mundo, { env: {} }));
  assertEquals(corpo.aprovadas, 1);
  assertEquals(mundo.chamadasProvedor, 0);
});

Deno.test("handler: o que não é JPEG é recusado com formato_invalido e sai da fila", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3));
  const { corpo } = await rodar(criarDeps(mundo, { provedor: provedorMock(mundo) }));

  const m = mundo.midias.get(MIDIA_1)!;
  assertEquals(corpo.recusadas, 1);
  assertEquals(m.estado, "recusada");
  assertEquals(m.motivo_codigo, "formato_invalido");
  assertEquals(m.motivo_recusa, "foto_inadequada");
  assertEquals(mundo.removidosDaFila, [msg.msg_id]);
  assertEquals(mundo.chamadasProvedor, 0);
  assertEquals(mundo.reservas.length, 0);
  assertFalse(mundo.objetos.has(`perfil/${MIDIA_1}_thumb.jpg`));
});

Deno.test("handler: JPEG com estrutura quebrada também é formato_invalido", async () => {
  const mundo = novoMundo();
  const inteiro = fazerJpeg(300, 300);
  semear(mundo, MIDIA_1, inteiro.subarray(0, inteiro.length - 10));
  await rodar(criarDeps(mundo));
  assertEquals(mundo.midias.get(MIDIA_1)?.motivo_codigo, "formato_invalido");
});

Deno.test("handler: arquivo acima de 5 MB é formato_invalido", async () => {
  const mundo = novoMundo();
  const grande = juntar(fazerJpeg(300, 300), new Uint8Array(5_242_880));
  semear(mundo, MIDIA_1, grande);
  await rodar(criarDeps(mundo));
  assertEquals(mundo.midias.get(MIDIA_1)?.motivo_codigo, "formato_invalido");
});

Deno.test("handler: dimensões ou proporção fora do permitido viram dimensoes_invalidas", async () => {
  const casos: Array<[string, number, number]> = [
    ["largura pequena", 199, 300],
    ["altura pequena", 300, 199],
    ["largura grande", 5001, 3000],
    ["altura grande", 3000, 5001],
    ["proporção alta", 4000, 1900],
    ["proporção baixa", 1900, 4000],
    ["altura zero (DNL)", 400, 0],
  ];
  for (const [nome, largura, altura] of casos) {
    const mundo = novoMundo();
    const msg = semear(mundo, MIDIA_1, comDimensoes(fazerJpeg(300, 300), largura, altura));
    const { corpo } = await rodar(criarDeps(mundo, { provedor: provedorMock(mundo) }));

    const m = mundo.midias.get(MIDIA_1)!;
    assertEquals(corpo.recusadas, 1, nome);
    assertEquals(m.estado, "recusada", nome);
    assertEquals(m.motivo_codigo, "dimensoes_invalidas", nome);
    assertEquals(m.motivo_recusa, "foto_inadequada", nome);
    assertEquals(mundo.removidosDaFila, [msg.msg_id], nome);
    assertEquals(mundo.chamadasProvedor, 0, nome);
  }
});

Deno.test("handler: limites exatos de dimensão são aceitos", async () => {
  for (const [largura, altura] of [[200, 200], [200, 400], [400, 200]]) {
    const mundo = novoMundo();
    semear(mundo, MIDIA_1, fazerJpeg(largura, altura));
    await rodar(criarDeps(mundo));
    assertEquals(mundo.midias.get(MIDIA_1)?.estado, "aprovada", `${largura}x${altura}`);
  }
});

Deno.test("handler: provedor que reprova marca conteudo_improprio e sai da fila", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
  const { corpo } = await rodar(criarDeps(mundo, { provedor: provedorMock(mundo, () => false) }));

  const m = mundo.midias.get(MIDIA_1)!;
  assertEquals(corpo.recusadas, 1);
  assertEquals(m.estado, "recusada");
  assertEquals(m.motivo_codigo, "conteudo_improprio");
  assertEquals(m.motivo_recusa, MOTIVOS_RECUSA.conteudo_improprio);
  assertEquals(m.motivo_recusa, "foto_inadequada");
  assertEquals(mundo.removidosDaFila, [msg.msg_id]);
});

Deno.test("handler: mídia que não está mais em_analise é ignorada sem tocar no Storage (idempotência)", async () => {
  for (const estado of ["aprovada", "recusada", "removida", "expurgada", "ocultada", "enviando"]) {
    const mundo = novoMundo();
    const msg = semear(mundo, MIDIA_1, IMAGEM_BOA, { estado });
    const antes = mundo.objetos.get(`perfil/${MIDIA_1}.jpg`)!.slice();
    const { corpo } = await rodar(criarDeps(mundo, { provedor: provedorMock(mundo) }));

    assertEquals(corpo.ignoradas, 1, estado);
    assertEquals(mundo.midias.get(MIDIA_1)?.estado, estado, estado);
    assertEquals(mundo.removidosDaFila, [msg.msg_id], estado);
    assertEquals(mundo.chamadasStorage, [], estado);
    assertEquals(mundo.chamadasProvedor, 0, estado);
    assertEquals(mundo.objetos.get(`perfil/${MIDIA_1}.jpg`), antes, estado);
  }
});

Deno.test("handler: mídia inexistente ou mensagem sem midia_id saem da fila sem efeito", async () => {
  const mundo = novoMundo();
  const fantasma: MensagemModeracao = { msg_id: 900, read_ct: 1, midia_id: MIDIA_2, reanalise: false };
  const vazia: MensagemModeracao = { msg_id: 901, read_ct: 1, midia_id: "", reanalise: false };
  mundo.fila.push(fantasma, vazia);
  const { corpo } = await rodar(criarDeps(mundo));
  assertEquals(corpo.ignoradas, 2);
  assertEquals(mundo.removidosDaFila, [900, 901]);
  assertEquals(mundo.chamadasStorage, []);
});

Deno.test("handler: reentrega da mesma mensagem não reprocessa nem chama o provedor de novo", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
  const deps = criarDeps(mundo, { provedor: provedorMock(mundo) });
  await rodar(deps);
  assertEquals(mundo.chamadasProvedor, 1);
  const storageAntes = mundo.chamadasStorage.length;

  // A fila reentrega (a remoção anterior "se perdeu"): o estado agora é aprovada.
  mundo.removidosDaFila = [];
  const { corpo } = await rodar(deps);
  assertEquals(corpo.ignoradas, 1);
  assertEquals(corpo.aprovadas, 0);
  assertEquals(mundo.chamadasProvedor, 1);
  assertEquals(mundo.chamadasStorage.length, storageAntes);
  assertEquals(mundo.reservas.length, 1);
  assertEquals(mundo.removidosDaFila, [msg.msg_id]);
});

Deno.test("handler: se o titular removeu a foto durante a análise, nada gravado fica e o estado não é sobrescrito", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
  // O titular remove a foto enquanto o provedor ainda está pensando.
  const provedor = provedorMock(mundo, () => {
    mundo.midias.get(MIDIA_1)!.estado = "removida";
    return true;
  });
  const { corpo } = await rodar(criarDeps(mundo, { provedor }));

  assertEquals(corpo.aprovadas, 0);
  assertEquals(corpo.ignoradas, 1);
  assertEquals(mundo.midias.get(MIDIA_1)?.estado, "removida");
  assertFalse(mundo.objetos.has(`perfil/${MIDIA_1}.jpg`));
  assertFalse(mundo.objetos.has(`perfil/${MIDIA_1}_thumb.jpg`));
  assertEquals(mundo.removidosDaFila, [msg.msg_id]);
});

Deno.test("handler: remoção durante a análise também limpa o que a recusa por conteúdo gravou", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  const provedor = provedorMock(mundo, () => {
    mundo.midias.get(MIDIA_1)!.estado = "removida";
    return false;
  });
  await rodar(criarDeps(mundo, { provedor }));
  assertEquals(mundo.midias.get(MIDIA_1)?.estado, "removida");
  assertFalse(mundo.objetos.has(`perfil/${MIDIA_1}_thumb.jpg`));
});

Deno.test("handler: processa várias mensagens do lote de forma independente", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  semear(mundo, MIDIA_2, Uint8Array.of(1, 2, 3, 4, 5));
  const { corpo } = await rodar(criarDeps(mundo));
  assertEquals(corpo.mensagens_lidas, 2);
  assertEquals(corpo.aprovadas, 1);
  assertEquals(corpo.recusadas, 1);
  assertEquals(mundo.midias.get(MIDIA_1)?.estado, "aprovada");
  assertEquals(mundo.midias.get(MIDIA_2)?.estado, "recusada");
});

// ---------------------------------------------------------------------------------------
// Falha fechada: o que NÃO pode acontecer quando algo dá errado
// ---------------------------------------------------------------------------------------

/** Falha transitória: nada publicado, nada recusado, mensagem continua na fila. */
function assertFalhouFechado(mundo: Mundo, corpo: Record<string, unknown>, msg: MensagemModeracao, motivo?: string) {
  const m = mundo.midias.get(msg.midia_id)!;
  assertEquals(m.estado, "em_analise");
  assertEquals(m.motivo_codigo, null);
  assertEquals(mundo.removidosDaFila, []);
  assertEquals(corpo.aprovadas, 0);
  assertEquals(corpo.recusadas, 0);
  const pendentes = corpo.pendentes as Array<{ midia_id: string; motivo: string }>;
  assertEquals(pendentes.length, 1);
  assertEquals(pendentes[0].midia_id, msg.midia_id);
  if (motivo) assertEquals(pendentes[0].motivo, motivo);
}

Deno.test("falha fechada: Storage fora do ar no download mantém em_analise e a mensagem na fila", async () => {
  for (const falha of ["rede", 500, 503, 404] as FalhaStorage[]) {
    const mundo = novoMundo();
    const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
    mundo.falhaStorage = (metodo) => metodo === "GET" ? falha : undefined;
    const { resp, corpo } = await rodar(criarDeps(mundo));
    assertEquals(resp.status, 200, String(falha));
    assertFalhouFechado(mundo, corpo, msg);
  }
});

Deno.test("falha fechada: erro ao gravar o original ou a miniatura não aprova", async () => {
  for (const alvo of [`perfil/${MIDIA_1}.jpg`, `perfil/${MIDIA_1}_thumb.jpg`]) {
    for (const falha of ["rede", 500] as FalhaStorage[]) {
      const mundo = novoMundo();
      const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
      mundo.falhaStorage = (metodo, caminho) => metodo === "POST" && caminho === alvo ? falha : undefined;
      const provedor = provedorMock(mundo);
      const { corpo } = await rodar(criarDeps(mundo, { provedor }));
      assertFalhouFechado(mundo, corpo, msg, falha === "rede" ? "storage_indisponivel" : "storage_upload");
      assertEquals(mundo.chamadasProvedor, 0, "o provedor só é chamado depois que tudo foi gravado");
      assertEquals(mundo.reservas.length, 0);
    }
  }
});

Deno.test("falha fechada: banco fora ao ler a mídia mantém tudo como está", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
  mundo.falhaBanco = { obterMidia: () => true };
  const { corpo } = await rodar(criarDeps(mundo));
  assertFalhouFechado(mundo, corpo, msg, "erro_interno");
  assertEquals(mundo.chamadasStorage, []);
});

Deno.test("falha fechada: banco fora ao aprovar não confirma a mensagem", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
  mundo.falhaBanco = { marcarAprovada: () => true };
  const { corpo } = await rodar(criarDeps(mundo));
  assertFalhouFechado(mundo, corpo, msg, "erro_interno");
});

Deno.test("falha fechada: banco fora ao recusar não confirma a mensagem", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, Uint8Array.of(1, 2, 3, 4));
  mundo.falhaBanco = { marcarRecusada: () => true };
  const { corpo } = await rodar(criarDeps(mundo));
  assertFalhouFechado(mundo, corpo, msg, "erro_interno");
});

Deno.test("falha fechada: uma mensagem com falha não impede as outras do lote", async () => {
  const mundo = novoMundo();
  const msg1 = semear(mundo, MIDIA_1, IMAGEM_BOA);
  semear(mundo, MIDIA_2, IMAGEM_BOA);
  mundo.falhaStorage = (_m, caminho) => caminho === `perfil/${MIDIA_1}.jpg` ? 500 : undefined;
  const { corpo } = await rodar(criarDeps(mundo));
  assertEquals(corpo.aprovadas, 1);
  assertEquals(mundo.midias.get(MIDIA_1)?.estado, "em_analise");
  assertEquals(mundo.midias.get(MIDIA_2)?.estado, "aprovada");
  assertFalse(mundo.removidosDaFila.includes(msg1.msg_id));
});

Deno.test("falha fechada: gerador de miniatura que quebra recusa como formato_invalido (determinístico)", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  const { corpo } = await rodar(criarDeps(mundo, {
    gerarMiniatura: () => {
      throw new Error("decodificação falhou");
    },
  }));
  assertEquals(corpo.recusadas, 1);
  assertEquals(mundo.midias.get(MIDIA_1)?.motivo_codigo, "formato_invalido");
  assertFalse(mundo.objetos.has(`perfil/${MIDIA_1}_thumb.jpg`));
});

Deno.test("falha fechada: foto válida mas grande demais para a memória fica em_analise, com alerta (não é recusada)", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, comDimensoes(fazerJpeg(300, 300), 4000, 3000));
  const { corpo } = await rodar(criarDeps(mundo, { provedor: provedorMock(mundo) }));
  assertFalhouFechado(mundo, corpo, msg, "miniatura_excede_memoria");
  assertEquals(mundo.chamadasProvedor, 0);
  assertEquals(mundo.alertas, [{ evento: "moderacao_miniatura_excede_memoria", midia_id: MIDIA_1 }]);
  assertFalse(mundo.objetos.has(`perfil/${MIDIA_1}_thumb.jpg`));
});

Deno.test("falha fechada: provedor fora do ar mantém em_analise, não publica e consome a tentativa", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
  const { corpo } = await rodar(criarDeps(mundo, { provedor: provedorMock(mundo, "falha") }));
  assertFalhouFechado(mundo, corpo, msg, "provedor_indisponivel");
  assertEquals(mundo.reservas.length, 1, "tentativa iniciada consome de forma irreversível");
});

Deno.test("falha fechada: provedor fora do ar na primeira rodada e reanálise na segunda aprova consumindo as 2 tentativas", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  let falhar = true;
  const provedor: ProvedorModeracao = {
    nome: "mock",
    externo: true,
    analisar: () => {
      mundo.chamadasProvedor += 1;
      if (falhar) return Promise.reject(new ErroProvedor("rede_ou_timeout", 0));
      return Promise.resolve({ aprovada: true });
    },
  };
  const deps = criarDeps(mundo, { provedor });
  await rodar(deps);
  assertEquals(mundo.midias.get(MIDIA_1)?.estado, "em_analise");
  falhar = false;
  mundo.removidosDaFila = [];
  mundo.fila[0].reanalise = true;
  const { corpo } = await rodar(deps);
  assertEquals(corpo.aprovadas, 1);
  assertEquals(mundo.reservas.length, 2);
});

Deno.test("falha fechada: tabela de consumo indisponível mantém em_analise (não chama o provedor às cegas)", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
  mundo.falhaBanco = { reservar: () => true };
  const { corpo } = await rodar(criarDeps(mundo, { provedor: provedorMock(mundo) }));
  assertFalhouFechado(mundo, corpo, msg, "erro_interno");
  assertEquals(mundo.chamadasProvedor, 0);
});

// ---------------------------------------------------------------------------------------
// Teto mensal e limite por foto
// ---------------------------------------------------------------------------------------

Deno.test("teto mensal: ao estourar mantém em_analise, não chama o provedor e emite alerta estruturado", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
  mundo.reservas.push({ midia_id: "outra", provedor: "mock", mes: "2026-11" }); // já gastou 1 de 1
  const { resp, corpo } = await rodar(criarDeps(mundo, {
    provedor: provedorMock(mundo),
    env: { MODERACAO_TETO_MENSAL: "1" },
  }));

  assertEquals(resp.status, 200);
  assertFalhouFechado(mundo, corpo, msg, "teto_mensal");
  assertEquals(mundo.chamadasProvedor, 0);
  assertEquals(mundo.reservas.length, 1);
  assertEquals(mundo.alertas.length, 1);
  assertEquals(mundo.alertas[0], { evento: "moderacao_teto_mensal_estourado", provedor: "mock", mes: "2026-11", teto: 1 });
});

Deno.test("teto mensal: a reserva usa o mês de agora() e o teto do ambiente; mês novo recomeça a conta", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  mundo.reservas.push({ midia_id: "antiga", provedor: "mock", mes: "2026-10" });
  const { corpo } = await rodar(criarDeps(mundo, {
    provedor: provedorMock(mundo),
    env: { MODERACAO_TETO_MENSAL: "1" },
  }));
  assertEquals(corpo.aprovadas, 1);
  assertEquals(mundo.reservasPedidas, [{ mes: "2026-11", teto: 1, maximoPorFoto: 1 }]);
});

Deno.test("teto mensal: sem MODERACAO_TETO_MENSAL vale 5000", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  await rodar(criarDeps(mundo, { provedor: provedorMock(mundo) }));
  assertEquals(mundo.reservasPedidas[0].teto, 5000);
});

Deno.test("teto mensal: estourou no meio do lote, as já aprovadas ficam e as demais esperam", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  semear(mundo, MIDIA_2, IMAGEM_BOA);
  const { corpo } = await rodar(criarDeps(mundo, {
    provedor: provedorMock(mundo),
    env: { MODERACAO_TETO_MENSAL: "1" },
  }));
  assertEquals(corpo.aprovadas, 1);
  assertEquals((corpo.pendentes as unknown[]).length, 1);
  assertEquals(mundo.midias.get(MIDIA_1)?.estado, "aprovada");
  assertEquals(mundo.midias.get(MIDIA_2)?.estado, "em_analise");
  assertEquals(mundo.chamadasProvedor, 1);
});

Deno.test("teto mensal zero bloqueia qualquer provedor externo, mas não o local", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  await rodar(criarDeps(mundo, { provedor: provedorMock(mundo), env: { MODERACAO_TETO_MENSAL: "0" } }));
  assertEquals(mundo.midias.get(MIDIA_1)?.estado, "em_analise");

  const mundoLocal = novoMundo();
  semear(mundoLocal, MIDIA_1, IMAGEM_BOA);
  await rodar(criarDeps(mundoLocal, { env: { MODERACAO_TETO_MENSAL: "0" } }));
  assertEquals(mundoLocal.midias.get(MIDIA_1)?.estado, "aprovada");
});

Deno.test("limite por foto: no máximo 1 chamada; sem veredito gravado a segunda rodada não chama de novo", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
  mundo.falhaBanco = { marcarAprovada: () => true }; // veredito obtido, mas o banco não gravou
  const deps = criarDeps(mundo, { provedor: provedorMock(mundo) });

  await rodar(deps);
  assertEquals(mundo.chamadasProvedor, 1);

  const { corpo } = await rodar(deps);
  assertEquals(mundo.chamadasProvedor, 1, "a segunda rodada não pode pagar outra chamada");
  assertFalhouFechado(mundo, corpo, msg, "limite_por_foto");
  assert(mundo.alertas.some((a) => a.evento === "moderacao_limite_por_foto" && a.midia_id === MIDIA_1));
});

Deno.test("limite por foto: pedido de reanálise libera exatamente 1 chamada extra", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  mundo.falhaBanco = { marcarAprovada: () => true };
  const provedor = provedorMock(mundo);
  await rodar(criarDeps(mundo, { provedor }));
  assertEquals(mundo.chamadasProvedor, 1);

  // O banco volta, e a fila recebe a mesma mídia marcada como reanálise.
  mundo.falhaBanco = undefined;
  mundo.removidosDaFila = [];
  mundo.fila[0].reanalise = true;
  const { corpo } = await rodar(criarDeps(mundo, { provedor }));
  assertEquals(corpo.aprovadas, 1);
  assertEquals(mundo.chamadasProvedor, 2);
  assertEquals(mundo.reservasPedidas.at(-1)?.maximoPorFoto, 2);

  // E uma terceira nunca é permitida.
  mundo.midias.get(MIDIA_1)!.estado = "em_analise";
  mundo.removidosDaFila = [];
  const { corpo: terceira } = await rodar(criarDeps(mundo, { provedor }));
  assertEquals(mundo.chamadasProvedor, 2);
  assertEquals((terceira.pendentes as unknown[]).length, 1);
});

// ---------------------------------------------------------------------------------------
// Alertas de mensagem presa
// ---------------------------------------------------------------------------------------

Deno.test("alerta: mensagem relida 5 vezes sem sair do lugar aparece em `alertas` e nos logs", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA, { read_ct: 5 });
  semear(mundo, MIDIA_2, IMAGEM_BOA, { read_ct: 4 });
  mundo.falhaStorage = (metodo) => metodo === "GET" ? 500 : undefined;
  const { corpo } = await rodar(criarDeps(mundo));

  const alertas = corpo.alertas as Array<{ midia_id: string; read_ct: number }>;
  assertEquals(alertas.length, 1);
  assertEquals(alertas[0].midia_id, MIDIA_1);
  assertEquals(alertas[0].read_ct, 5);
  assertEquals(mundo.alertas.filter((a) => a.evento === "moderacao_mensagem_presa").length, 1);
});

Deno.test("alerta: o log estruturado não carrega bytes, caminho nem metadados da imagem", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA, { read_ct: 9 });
  mundo.falhaStorage = () => 500;
  await rodar(criarDeps(mundo));
  const serializado = JSON.stringify(mundo.alertas);
  assertFalse(serializado.includes("GPSLatitude"));
  assertFalse(serializado.includes("perfil/"));
  assertFalse(serializado.includes(MOCK_SERVICE_ROLE));
});

// ---------------------------------------------------------------------------------------
// Configuração e seleção de provedor pelo ambiente
// ---------------------------------------------------------------------------------------

Deno.test("configuração inválida responde 500 antes de tocar na fila", async () => {
  const invalidos: Array<Record<string, string>> = [
    { MODERACAO_PROVEDOR: "openai" },
    { MODERACAO_PROVEDOR: "azure" },
    { MODERACAO_PROVEDOR: "desconhecido" },
    { MODERACAO_PROVEDOR: "mock" },
    { MODERACAO_TETO_MENSAL: "muitas" },
  ];
  for (const env of invalidos) {
    const mundo = novoMundo();
    semear(mundo, MIDIA_1, IMAGEM_BOA);
    const { resp, corpo } = await rodar(criarDeps(mundo, { env }));
    assertEquals(resp.status, 500, JSON.stringify(env));
    assertEquals(corpo.code, "erro_configuracao");
    assertEquals(mundo.lerLoteArgs.length, 0, JSON.stringify(env));
    assertEquals(mundo.midias.get(MIDIA_1)?.estado, "em_analise");
  }
});

Deno.test("configuração inválida não vaza a chave no alerta", async () => {
  const mundo = novoMundo();
  await rodar(criarDeps(mundo, { env: { MODERACAO_PROVEDOR: "azure", AZURE_CONTENT_SAFETY_KEY: "chave-secreta-azure" } }));
  assertFalse(JSON.stringify(mundo.alertas).includes("chave-secreta-azure"));
});

Deno.test("MODERACAO_PROVEDOR=openai: uma chamada por foto, aprova quando não sinalizada", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  mundo.apiExterna = () => json({ results: [{ flagged: false }] });
  const { corpo } = await rodar(criarDeps(mundo, { env: { MODERACAO_PROVEDOR: "openai", OPENAI_API_KEY: "k-openai" } }));
  assertEquals(corpo.aprovadas, 1);
  assertEquals(mundo.chamadasProvedor, 1);
  assertEquals(mundo.reservas, [{ midia_id: MIDIA_1, provedor: "openai", mes: "2026-11" }]);
});

Deno.test("MODERACAO_PROVEDOR=openai: foto sinalizada vira conteudo_improprio", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  mundo.apiExterna = () => json({ results: [{ flagged: true }] });
  await rodar(criarDeps(mundo, { env: { MODERACAO_PROVEDOR: "openai", OPENAI_API_KEY: "k-openai" } }));
  assertEquals(mundo.midias.get(MIDIA_1)?.motivo_codigo, "conteudo_improprio");
});

Deno.test("MODERACAO_PROVEDOR=openai: HTTP 500 do provedor mantém em_analise", async () => {
  const mundo = novoMundo();
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
  mundo.apiExterna = () => json({}, 500);
  const { corpo } = await rodar(criarDeps(mundo, { env: { MODERACAO_PROVEDOR: "openai", OPENAI_API_KEY: "k-openai" } }));
  assertFalhouFechado(mundo, corpo, msg, "provedor_indisponivel");
  assertEquals((corpo.pendentes as Array<{ status: number }>)[0].status, 500);
  assertEquals(mundo.reservas.length, 1);
});

Deno.test("MODERACAO_PROVEDOR=azure: severidade alta reprova, baixa aprova", async () => {
  const env = {
    MODERACAO_PROVEDOR: "azure",
    AZURE_CONTENT_SAFETY_KEY: "k-azure",
    AZURE_CONTENT_SAFETY_ENDPOINT: "https://frila.cognitiveservices.azure.com",
  };
  const mundoReprova = novoMundo();
  semear(mundoReprova, MIDIA_1, IMAGEM_BOA);
  mundoReprova.apiExterna = () => json({ categoriesAnalysis: [{ category: "Violence", severity: 6 }, { category: "Sexual", severity: 0 }] });
  await rodar(criarDeps(mundoReprova, { env }));
  assertEquals(mundoReprova.midias.get(MIDIA_1)?.motivo_codigo, "conteudo_improprio");
  assertEquals(mundoReprova.reservas[0].provedor, "azure");

  const mundoAprova = novoMundo();
  semear(mundoAprova, MIDIA_1, IMAGEM_BOA);
  mundoAprova.apiExterna = () => json({ categoriesAnalysis: [{ category: "Violence", severity: 0 }, { category: "Sexual", severity: 2 }] });
  await rodar(criarDeps(mundoAprova, { env }));
  assertEquals(mundoAprova.midias.get(MIDIA_1)?.estado, "aprovada");
});

Deno.test("provedor injetado tem precedência sobre MODERACAO_PROVEDOR", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  const { corpo } = await rodar(criarDeps(mundo, {
    provedor: provedorMock(mundo, () => true, false),
    env: { MODERACAO_PROVEDOR: "openai" }, // sem chave: quebraria se fosse usado
  }));
  assertEquals(corpo.aprovadas, 1);
  assertEquals(mundo.chamadasProvedor, 1);
});

Deno.test("o provedor externo recebe a imagem já sanitizada, nunca o original com EXIF", async () => {
  const mundo = novoMundo();
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  let recebida: Uint8Array | null = null;
  const provedor: ProvedorModeracao = {
    nome: "mock",
    externo: true,
    analisar: ({ original }) => {
      recebida = original;
      return Promise.resolve({ aprovada: true });
    },
  };
  await rodar(criarDeps(mundo, { provedor }));
  assert(recebida);
  assertFalse(contem(recebida!, "GPSLatitude"));
  assertFalse(contem(recebida!, "iPhone"));
});

// ---------------------------------------------------------------------------------------
// #433: nova análise pedida pelo titular (LGPD art. 20). Regressão do Lince Codex.
// A recusa original gasta a única chamada por foto; a mensagem da RPC traz reanalise=true,
// que autoriza exatamente UMA consulta extra: 2 no total, nunca 3, sem autoaprovar.
// ---------------------------------------------------------------------------------------

async function recusadaPeloProvedor(mundo: Mundo, provedor: ReturnType<typeof provedorMock>) {
  semear(mundo, MIDIA_1, IMAGEM_BOA);
  await rodar(criarDeps(mundo, { provedor }));
  assertEquals(mundo.midias.get(MIDIA_1)?.estado, "recusada");
  assertEquals(mundo.chamadasProvedor, 1);
  // O pedido de nova análise devolve a foto a em_analise (a RPC limpa o motivo).
  const m = mundo.midias.get(MIDIA_1)!;
  m.estado = "em_analise";
  m.motivo_codigo = null;
  mundo.fila = [];
  mundo.removidosDaFila = [];
}

Deno.test("#433: nova análise com reanalise=true consulta o provedor uma segunda vez e publica a foto aprovada", async () => {
  const mundo = novoMundo();
  let n = 0;
  const provedor = provedorMock(mundo, () => ++n > 1);
  await recusadaPeloProvedor(mundo, provedor);
  semear(mundo, MIDIA_1, IMAGEM_BOA, { reanalise: true });
  await rodar(criarDeps(mundo, { provedor }));
  assertEquals(mundo.chamadasProvedor, 2, "o direito de revisão chega ao provedor");
  assertEquals(mundo.midias.get(MIDIA_1)?.estado, "aprovada");
});

Deno.test("#433: sem reanalise, a mesma foto não ganha consulta extra e fica em análise (falha fechada)", async () => {
  const mundo = novoMundo();
  let n = 0;
  const provedor = provedorMock(mundo, () => ++n > 1);
  await recusadaPeloProvedor(mundo, provedor);
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA);
  const { corpo } = await rodar(criarDeps(mundo, { provedor }));
  assertEquals(mundo.chamadasProvedor, 1);
  assertFalhouFechado(mundo, corpo, msg, "limite_por_foto");
});

Deno.test("#433: reanalise=true nunca dá uma terceira consulta, e a segunda recusa não vira aprovação", async () => {
  const mundo = novoMundo();
  const provedor = provedorMock(mundo, () => false);
  await recusadaPeloProvedor(mundo, provedor);
  semear(mundo, MIDIA_1, IMAGEM_BOA, { reanalise: true });
  await rodar(criarDeps(mundo, { provedor }));
  assertEquals(mundo.chamadasProvedor, 2);
  assertEquals(mundo.midias.get(MIDIA_1)?.estado, "recusada");
  // Uma mensagem forjada ou repetida com o marcador não abre uma terceira chamada.
  const m = mundo.midias.get(MIDIA_1)!;
  m.estado = "em_analise";
  m.motivo_codigo = null;
  mundo.fila = [];
  mundo.removidosDaFila = [];
  const msg = semear(mundo, MIDIA_1, IMAGEM_BOA, { reanalise: true });
  const { corpo } = await rodar(criarDeps(mundo, { provedor }));
  assertEquals(mundo.chamadasProvedor, 2, "teto de 2 chamadas no total por foto");
  assertFalhouFechado(mundo, corpo, msg, "limite_por_foto");
});
