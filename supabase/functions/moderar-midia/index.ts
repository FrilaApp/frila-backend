// Edge Function moderar-midia (cartão B4c · RN37 · RN15 · CD-M01/M04).
//
// Consome `pgmq.moderacao_midia`, que `confirmar_upload_midia` alimenta quando a foto de
// perfil vai para `em_analise`. A função decide se a foto pode ser publicada e, no caminho,
// tira dela tudo o que não deveria sair do aparelho do titular.
//
// O ciclo, por mensagem `{ midia_id, reanalise? }`:
// 1. Lê a linha de `privado.midia`. Se não está mais `em_analise` (removida, já analisada),
//    a mensagem sai da fila sem efeito: é o que torna a função idempotente.
// 2. Baixa o objeto do bucket privado `midia-perfil`.
// 3. Valida os magic bytes JPEG (FF D8 FF) e lê largura e altura nos marcadores SOF0/SOF2.
//    Fora do permitido, a mídia é `recusada` e a mensagem sai da fila.
// 4. Remove do arquivo os segmentos de metadados (APP1: EXIF, GPS, XMP; APP13: IPTC; COM) e
//    os bytes soltos depois do EOI, e grava o resultado de volta em `storage_path` (RN15).
// 5. Gera a miniatura no servidor e grava em `perfil/<midia_id>_thumb.jpg`.
// 6. Chama o provedor de moderação (no máximo 1 vez por foto, +1 se for reanálise) e só então
//    marca `aprovada` ou `recusada`.
//
// FALHA FECHADA. Qualquer dúvida mantém `em_analise`: nada é publicado e a mensagem NÃO sai
// da fila, voltando quando a visibilidade expira. Vale para erro de rede, de Storage, de
// banco, timeout, provedor fora do ar e teto mensal estourado. Só é "recusada" o que é
// determinístico (formato, dimensão, veredito do provedor): reler não mudaria o resultado.
//
// Nada de dado pessoal em log (RN15): o que sai daqui é id da mídia, contagem e status HTTP.

import postgres from "npm:postgres@3.4.4";
import jpeg from "npm:jpeg-js@0.4.4";
import { segredoAgendadorValido } from "../_compartilhado/auth.ts";

const BUCKET = "midia-perfil";
const LOTE_PADRAO = 20;
const LOTE_MAXIMO = 100;
const VISIBILIDADE_SEGUNDOS = 120;
/** Leituras repetidas da mesma mensagem viram sinal: algo não sai do estado `em_analise`. */
const LEITURAS_PARA_ALERTA = 5;
const TIMEOUT_REDE_MS = 15_000;
const TAMANHO_MAXIMO_BYTES = 5_242_880;

const LADO_MINIMO_PX = 200;
const LADO_MAXIMO_PX = 5000;
const PROPORCAO_MINIMA = 0.5;
const PROPORCAO_MAXIMA = 2.0;
const LADO_MINIATURA_PX = 256;
const QUALIDADE_MINIATURA = 80;
/**
 * Teto de memória do decodificador. A Edge Function tem 256 MB, e o jpeg-js decodifica a imagem
 * inteira (medido: ~180 MB de pico para 3 MP, ~570 MB para 12 MP). Estourar o teto LANÇA erro,
 * o que é recuperável; estourar a memória do worker o mata sem aviso e a mensagem fica presa.
 */
const MEMORIA_MAXIMA_DECODIFICACAO_MB = 96;

/** Teto mensal padrão: a cota gratuita do Azure Content Safety. Zero chamadas pagas. */
const TETO_MENSAL_PADRAO = 5000;
/** Severidade do Azure (0, 2, 4, 6) a partir da qual a foto é reprovada. */
const AZURE_SEVERIDADE_REPROVACAO = 4;
/** Limite de imagem do Azure Content Safety; acima disso vai a miniatura. */
const AZURE_LIMITE_IMAGEM_BYTES = 4 * 1024 * 1024;

export type MotivoCodigo = "formato_invalido" | "dimensoes_invalidas" | "conteudo_improprio";
export type MotivoRecusaPublico = "foto_inadequada" | "texto_ou_dado_pessoal" | "nao_e_pessoa_ou_servico" | "nao_analisada";

/** Motivo genérico público aderente ao enum MotivoRecusaMidia do contrato 0.2.57. */
export const MOTIVOS_RECUSA: Record<MotivoCodigo, MotivoRecusaPublico> = {
  formato_invalido: "foto_inadequada",
  dimensoes_invalidas: "foto_inadequada",
  conteudo_improprio: "foto_inadequada",
};

// ---------------------------------------------------------------------------------------
// JPEG: validação, dimensões e remoção de metadados
// ---------------------------------------------------------------------------------------

/**
 * A foto é um JPEG válido, mas grande demais para este decodificador caber na memória da
 * função. Não é defeito da foto: a mídia fica `em_analise`, com alerta, até haver outro meio
 * de gerar a miniatura.
 */
export class ErroMiniaturaExcedeMemoria extends Error {
  constructor() {
    super("miniatura_excede_memoria");
    this.name = "ErroMiniaturaExcedeMemoria";
  }
}

export type ResultadoJpeg =
  | { ok: true; largura: number; altura: number; sanitizado: Uint8Array }
  | { ok: false; motivo: "formato_invalido" };

/** SOF0 (baseline) e SOF2 (progressivo): os únicos formatos que aceitamos e decodificamos. */
const SOF_ACEITOS = new Set([0xc0, 0xc2]);

function ehMarcadorSof(m: number): boolean {
  // C4 = DHT, C8 = JPG reservado, CC = DAC: ocupam a faixa mas não são quadros.
  return m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc;
}

/** APP1 (EXIF, GPS, XMP), APP13 (IPTC/Photoshop) e COM (comentário livre). */
function ehMetadadoRemovivel(m: number): boolean {
  return m === 0xe1 || m === 0xed || m === 0xfe;
}

export function temMagicBytesJpeg(b: Uint8Array): boolean {
  return b.length >= 4 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
}

/**
 * Percorre os segmentos do JPEG, devolve largura e altura do SOF e uma cópia sem metadados.
 * Estrutura quebrada, SOF ausente ou de outro tipo, e arquivo sem EOI são `formato_invalido`:
 * não há como afirmar que o que sobraria é uma imagem segura.
 */
export function sanitizarJpeg(b: Uint8Array): ResultadoJpeg {
  const invalido: ResultadoJpeg = { ok: false, motivo: "formato_invalido" };
  if (!temMagicBytesJpeg(b)) return invalido;

  const n = b.length;
  const partes: Uint8Array[] = [b.subarray(0, 2)];
  let i = 2;
  let dimensoes: { largura: number; altura: number } | null = null;

  while (true) {
    if (i >= n || b[i] !== 0xff) return invalido;
    while (i < n && b[i] === 0xff) i++; // bytes de preenchimento antes do marcador
    if (i >= n) return invalido;
    const m = b[i];
    i++;

    if (m === 0x00 || m === 0xd8) return invalido;
    if (m === 0xd9) { // EOI: o que vier depois é descartado
      if (!dimensoes) return invalido;
      partes.push(Uint8Array.of(0xff, 0xd9));
      break;
    }
    if (m === 0x01 || (m >= 0xd0 && m <= 0xd7)) { // marcadores sem corpo
      partes.push(Uint8Array.of(0xff, m));
      continue;
    }

    if (i + 2 > n) return invalido;
    const tamanho = (b[i] << 8) | b[i + 1];
    if (tamanho < 2 || i + tamanho > n) return invalido;
    const corpo = b.subarray(i + 2, i + tamanho);
    const fimSegmento = i + tamanho;

    if (ehMarcadorSof(m)) {
      if (!SOF_ACEITOS.has(m) || dimensoes || corpo.length < 6) return invalido;
      dimensoes = { altura: (corpo[1] << 8) | corpo[2], largura: (corpo[3] << 8) | corpo[4] };
    }

    if (!ehMetadadoRemovivel(m)) {
      partes.push(Uint8Array.of(0xff, m), b.subarray(i, fimSegmento));
    }
    i = fimSegmento;

    if (m === 0xda) { // SOS: segue o dado entropy-coded até o próximo marcador de verdade
      if (!dimensoes) return invalido;
      const inicio = i;
      while (i < n) {
        if (b[i] !== 0xff) { i++; continue; }
        const proximo = i + 1 < n ? b[i + 1] : -1;
        if (proximo === -1) return invalido;
        if (proximo === 0x00 || (proximo >= 0xd0 && proximo <= 0xd7)) { i += 2; continue; }
        if (proximo === 0xff) { i++; continue; }
        break;
      }
      if (i >= n) return invalido;
      partes.push(b.subarray(inicio, i));
    }
  }

  if (!dimensoes) return invalido;
  const total = partes.reduce((soma, p) => soma + p.length, 0);
  const sanitizado = new Uint8Array(total);
  let pos = 0;
  for (const p of partes) {
    sanitizado.set(p, pos);
    pos += p.length;
  }
  return { ok: true, largura: dimensoes.largura, altura: dimensoes.altura, sanitizado };
}

export function dimensoesValidas(largura: number, altura: number): boolean {
  if (largura < LADO_MINIMO_PX || largura > LADO_MAXIMO_PX) return false;
  if (altura < LADO_MINIMO_PX || altura > LADO_MAXIMO_PX) return false;
  const proporcao = largura / altura;
  return proporcao >= PROPORCAO_MINIMA && proporcao <= PROPORCAO_MAXIMA;
}

/**
 * Miniatura JPEG com o lado maior em 256 px (média por blocos). Decodifica a imagem inteira,
 * então a memória é proporcional aos megapixels: por isso o teto de 5000 px por lado antes.
 */
export function gerarMiniaturaJpeg(entrada: Uint8Array): Uint8Array {
  let img: { width: number; height: number; data: Uint8Array };
  try {
    img = jpeg.decode(entrada, {
      useTArray: true,
      formatAsRGBA: true,
      maxMemoryUsageInMB: MEMORIA_MAXIMA_DECODIFICACAO_MB,
    });
  } catch (err) {
    if (err instanceof Error && err.message.includes("maxMemoryUsageInMB")) {
      throw new ErroMiniaturaExcedeMemoria();
    }
    throw err;
  }
  const escala = Math.min(1, LADO_MINIATURA_PX / Math.max(img.width, img.height));
  const largura = Math.max(1, Math.round(img.width * escala));
  const altura = Math.max(1, Math.round(img.height * escala));
  const saida = new Uint8Array(largura * altura * 4);
  const origem = img.data as Uint8Array;

  for (let y = 0; y < altura; y++) {
    const y0 = Math.floor((y * img.height) / altura);
    const y1 = Math.max(y0 + 1, Math.floor(((y + 1) * img.height) / altura));
    for (let x = 0; x < largura; x++) {
      const x0 = Math.floor((x * img.width) / largura);
      const x1 = Math.max(x0 + 1, Math.floor(((x + 1) * img.width) / largura));
      let r = 0, g = 0, bl = 0, c = 0;
      for (let yy = y0; yy < y1; yy++) {
        for (let xx = x0; xx < x1; xx++) {
          const p = (yy * img.width + xx) * 4;
          r += origem[p];
          g += origem[p + 1];
          bl += origem[p + 2];
          c++;
        }
      }
      const q = (y * largura + x) * 4;
      saida[q] = Math.round(r / c);
      saida[q + 1] = Math.round(g / c);
      saida[q + 2] = Math.round(bl / c);
      saida[q + 3] = 255;
    }
  }
  const codificada = jpeg.encode({ data: saida, width: largura, height: altura }, QUALIDADE_MINIATURA);
  return new Uint8Array(codificada.data);
}

export const QUALIDADE_ORIGINAL_RECODIFICADO = 90;

/**
 * Decodifica o JPEG e o recodifica puramente a partir de seus pixels RGB/RGBA,
 * eliminando qualquer segmento APP/EXIF/metadado residual antes do envio externo
 * ou gravação no Storage (achado 2 do Lince Codex).
 */
export function recodificarOriginalJpeg(entrada: Uint8Array): {
  largura: number;
  altura: number;
  recodificado: Uint8Array;
  miniatura: Uint8Array;
} {
  let img: { width: number; height: number; data: Uint8Array };
  try {
    img = jpeg.decode(entrada, {
      useTArray: true,
      formatAsRGBA: true,
      maxMemoryUsageInMB: MEMORIA_MAXIMA_DECODIFICACAO_MB,
    });
  } catch (err) {
    if (err instanceof Error && err.message.includes("maxMemoryUsageInMB")) {
      throw new ErroMiniaturaExcedeMemoria();
    }
    throw err;
  }

  const codificada = jpeg.encode(
    { data: img.data, width: img.width, height: img.height },
    QUALIDADE_ORIGINAL_RECODIFICADO,
  );
  const recodificado = new Uint8Array(codificada.data);

  const escala = Math.min(1, LADO_MINIATURA_PX / Math.max(img.width, img.height));
  const larguraThumb = Math.max(1, Math.round(img.width * escala));
  const alturaThumb = Math.max(1, Math.round(img.height * escala));
  const saidaThumb = new Uint8Array(larguraThumb * alturaThumb * 4);
  const origem = img.data as Uint8Array;

  for (let y = 0; y < alturaThumb; y++) {
    const y0 = Math.floor((y * img.height) / alturaThumb);
    const y1 = Math.max(y0 + 1, Math.floor(((y + 1) * img.height) / alturaThumb));
    for (let x = 0; x < larguraThumb; x++) {
      const x0 = Math.floor((x * img.width) / larguraThumb);
      const x1 = Math.max(x0 + 1, Math.floor(((x + 1) * img.width) / larguraThumb));
      let r = 0, g = 0, bl = 0, c = 0;
      for (let yy = y0; yy < y1; yy++) {
        for (let xx = x0; xx < x1; xx++) {
          const p = (yy * img.width + xx) * 4;
          r += origem[p];
          g += origem[p + 1];
          bl += origem[p + 2];
          c++;
        }
      }
      const q = (y * larguraThumb + x) * 4;
      saidaThumb[q] = Math.round(r / c);
      saidaThumb[q + 1] = Math.round(g / c);
      saidaThumb[q + 2] = Math.round(bl / c);
      saidaThumb[q + 3] = 255;
    }
  }
  const codificadaThumb = jpeg.encode(
    { data: saidaThumb, width: larguraThumb, height: alturaThumb },
    QUALIDADE_MINIATURA,
  );
  const miniatura = new Uint8Array(codificadaThumb.data);

  return {
    largura: img.width,
    altura: img.height,
    recodificado,
    miniatura,
  };
}

// ---------------------------------------------------------------------------------------
// Adaptador de análise de imagem
// ---------------------------------------------------------------------------------------

/** Falha do provedor ou da rede: não é veredito. A mídia fica `em_analise`. */
export class ErroProvedor extends Error {
  constructor(message: string, public status = 0) {
    super(message);
    this.name = "ErroProvedor";
  }
}

export interface EntradaAnalise {
  original: Uint8Array;
  miniatura: Uint8Array;
}

export interface ProvedorModeracao {
  nome: string;
  /** Provedor que sai da função pela rede: só ele consome teto e cota por foto. */
  externo: boolean;
  analisar(entrada: EntradaAnalise): Promise<{ aprovada: boolean }>;
}

export interface FonteEnv {
  [nome: string]: string | undefined;
}

function paraBase64(bytes: Uint8Array): string {
  let s = "";
  const passo = 0x8000;
  for (let i = 0; i < bytes.length; i += passo) {
    s += String.fromCharCode(...bytes.subarray(i, i + passo));
  }
  return btoa(s);
}

async function enviarJson(
  fetchFn: typeof fetch,
  url: string,
  cabecalhos: Record<string, string>,
  corpo: unknown,
): Promise<unknown> {
  let resp: Response;
  try {
    resp = await fetchFn(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...cabecalhos },
      body: JSON.stringify(corpo),
      signal: AbortSignal.timeout(TIMEOUT_REDE_MS),
    });
  } catch (_err) {
    throw new ErroProvedor("rede_ou_timeout", 0);
  }
  if (!resp.ok) {
    await resp.body?.cancel().catch(() => {});
    throw new ErroProvedor("resposta_nao_ok", resp.status);
  }
  try {
    return await resp.json();
  } catch (_err) {
    throw new ErroProvedor("resposta_ilegivel", resp.status);
  }
}

/** Padrão seguro: não sai da função, não depende de rede e dá sempre a mesma resposta. */
export function provedorLocal(): ProvedorModeracao {
  return {
    nome: "local",
    externo: false,
    analisar: () => Promise.resolve({ aprovada: true }),
  };
}

/** OpenAI omni-moderation (gratuita). */
export function provedorOpenAI(chave: string, fetchFn: typeof fetch): ProvedorModeracao {
  return {
    nome: "openai",
    externo: true,
    async analisar({ original }) {
      const dados = await enviarJson(
        fetchFn,
        "https://api.openai.com/v1/moderations",
        { Authorization: `Bearer ${chave}` },
        {
          model: "omni-moderation-latest",
          input: [{
            type: "image_url",
            image_url: { url: `data:image/jpeg;base64,${paraBase64(original)}` },
          }],
        },
      ) as { results?: Array<{ flagged?: unknown }> };
      const resultado = dados?.results?.[0];
      if (!resultado || typeof resultado.flagged !== "boolean") {
        throw new ErroProvedor("resposta_inesperada", 200);
      }
      return { aprovada: !resultado.flagged };
    },
  };
}

/** Azure Content Safety (5.000 chamadas por mês gratuitas). */
export function provedorAzure(chave: string, endpoint: string, fetchFn: typeof fetch): ProvedorModeracao {
  const base = endpoint.replace(/\/+$/, "");
  return {
    nome: "azure",
    externo: true,
    async analisar({ original, miniatura }) {
      const imagem = original.length > AZURE_LIMITE_IMAGEM_BYTES ? miniatura : original;
      const dados = await enviarJson(
        fetchFn,
        `${base}/contentsafety/image:analyze?api-version=2023-10-01`,
        { "Ocp-Apim-Subscription-Key": chave },
        {
          image: { content: paraBase64(imagem) },
          categories: ["Sexual", "Violence"],
          outputType: "FourSeverityLevels",
        },
      ) as { categoriesAnalysis?: Array<{ severity?: unknown }> };
      const analises = dados?.categoriesAnalysis;
      if (!Array.isArray(analises)) {
        throw new ErroProvedor("resposta_inesperada", 200);
      }
      const esperadas = new Set(["Sexual", "Violence"]);
      const vistas = new Set<string>();
      const severidadesValidas = new Set([0, 2, 4, 6]);
      let reprovada = false;

      for (const a of analises) {
        if (!a || typeof a !== "object") throw new ErroProvedor("resposta_inesperada", 200);
        const cat = (a as { category?: unknown }).category;
        const sev = (a as { severity?: unknown }).severity;
        if (typeof cat !== "string" || !esperadas.has(cat) || vistas.has(cat)) {
          throw new ErroProvedor("resposta_inesperada", 200);
        }
        if (typeof sev !== "number" || !Number.isInteger(sev) || !severidadesValidas.has(sev)) {
          throw new ErroProvedor("resposta_inesperada", 200);
        }
        vistas.add(cat);
        if (sev >= AZURE_SEVERIDADE_REPROVACAO) reprovada = true;
      }

      if (vistas.size !== esperadas.size) {
        throw new ErroProvedor("resposta_inesperada", 200);
      }
      return { aprovada: !reprovada };
    },
  };
}

export class ErroConfiguracao extends Error {}

export function criarProvedor(env: FonteEnv, fetchFn: typeof fetch): ProvedorModeracao {
  const nome = (env.MODERACAO_PROVEDOR ?? "").trim().toLowerCase() || "local";
  switch (nome) {
    case "local":
      return provedorLocal();
    case "openai": {
      const chave = env.OPENAI_API_KEY?.trim();
      if (!chave) throw new ErroConfiguracao("OPENAI_API_KEY ausente");
      return provedorOpenAI(chave, fetchFn);
    }
    case "azure": {
      const chave = env.AZURE_CONTENT_SAFETY_KEY?.trim();
      const endpoint = env.AZURE_CONTENT_SAFETY_ENDPOINT?.trim();
      if (!chave || !endpoint) throw new ErroConfiguracao("AZURE_CONTENT_SAFETY_KEY/ENDPOINT ausente");
      return provedorAzure(chave, endpoint, fetchFn);
    }
    default:
      // "mock" só existe por injeção nos testes; em produção também cai aqui.
      throw new ErroConfiguracao(`MODERACAO_PROVEDOR desconhecido: ${nome}`);
  }
}

export function lerTetoMensal(env: FonteEnv): number {
  const bruto = env.MODERACAO_TETO_MENSAL?.trim();
  if (!bruto) return TETO_MENSAL_PADRAO;
  const n = Number(bruto);
  if (!Number.isInteger(n) || n < 0) throw new ErroConfiguracao("MODERACAO_TETO_MENSAL inválido");
  return n;
}

// ---------------------------------------------------------------------------------------
// Banco
// ---------------------------------------------------------------------------------------

export interface MensagemModeracao {
  msg_id: number;
  read_ct: number;
  midia_id: string;
  reanalise: boolean;
}

export interface MidiaModeracao {
  id: string;
  storage_path: string;
  estado: string;
}

export type ReservaChamada = "ok" | "teto_mensal" | "limite_foto";

export interface SqlClient {
  lerLote: (quantidade: number, visibilidade: number) => Promise<MensagemModeracao[]>;
  obterMidia: (id: string) => Promise<MidiaModeracao | null>;
  /** Só muda a linha se ela ainda estiver `em_analise`; devolve se mudou. */
  marcarAprovada: (id: string) => Promise<boolean>;
  marcarRecusada: (id: string, codigo: MotivoCodigo, motivo: string) => Promise<boolean>;
  removerDaFila: (msgId: number) => Promise<void>;
  /**
   * Reserva, de forma atômica, uma chamada ao provedor: confere o teto do mês e o limite por
   * foto e registra o consumo. Só é usada com provedor externo.
   */
  reservarChamada: (
    midiaId: string,
    provedor: string,
    mes: string,
    tetoMensal: number,
    maximoPorFoto: number,
  ) => Promise<ReservaChamada>;
  /** Devolve a reserva quando a chamada nem chegou a produzir veredito (falha de rede). */
  liberarChamada: (midiaId: string, provedor: string, mes: string) => Promise<void>;
  encerrar?: () => Promise<void>;
}

export interface HandlerDeps {
  fetchFn?: typeof fetch;
  sqlClient?: SqlClient;
  supabaseUrl?: string;
  serviceRoleKey?: string;
  agendadorSecret?: string;
  dbUrl?: string;
  env?: FonteEnv;
  /** Injeção direta de um provedor (testes). Tem precedência sobre MODERACAO_PROVEDOR. */
  provedor?: ProvedorModeracao;
  gerarMiniatura?: (jpegSanitizado: Uint8Array) => Uint8Array | Promise<Uint8Array>;
  agora?: () => Date;
  /** Destino dos alertas estruturados; o padrão é `console.error` em JSON. */
  alerta?: (evento: Record<string, unknown>) => void;
}

function obterVariavel(nome: string, injetada?: string): string {
  const valor = (injetada ?? Deno.env.get(nome))?.trim();
  if (!valor) {
    throw new Error(`${nome} é obrigatório e deve estar configurado no ambiente.`);
  }
  return valor;
}

function criarSqlClient(deps?: HandlerDeps): SqlClient {
  if (deps?.sqlClient) return deps.sqlClient;
  const dbUrl = obterVariavel("SUPABASE_DB_URL", deps?.dbUrl);
  const sql = postgres(dbUrl, { max: 1, connect_timeout: 5 });
  return {
    async lerLote(quantidade, visibilidade) {
      const res = await sql`
        select msg_id,
               read_ct,
               message->>'midia_id' as midia_id,
               (message->>'reanalise') = 'true' as reanalise
          from pgmq.read('moderacao_midia', ${visibilidade}::integer, ${quantidade}::integer)
      `;
      return res.map((r) => ({
        msg_id: Number(r.msg_id),
        read_ct: Number(r.read_ct ?? 0),
        midia_id: String(r.midia_id ?? ""),
        reanalise: r.reanalise === true,
      }));
    },
    async obterMidia(id) {
      const res = await sql`
        select id::text as id, storage_path, estado
          from privado.midia
         where id = ${id}::uuid
      `;
      if (res.length === 0) return null;
      return {
        id: String(res[0].id),
        storage_path: String(res[0].storage_path),
        estado: String(res[0].estado),
      };
    },
    async marcarAprovada(id) {
      return await sql.begin(async (tx) => {
        const [alvo] = await tx`
          select id, dono_tipo, dono_usuario_id, estabelecimento_id
            from privado.midia
           where id = ${id}::uuid
             and estado = 'em_analise'
           for update
        `;
        if (!alvo) return false;

        const antigas = await tx`
          select id, storage_path
            from privado.midia
           where dono_tipo = ${alvo.dono_tipo}
             and coalesce(estabelecimento_id, dono_usuario_id) = coalesce(${alvo.estabelecimento_id}::uuid, ${alvo.dono_usuario_id}::uuid)
             and tipo = 'foto_perfil'
             and estado = 'aprovada'
             and id <> ${id}::uuid
           for update
        `;

        for (const antiga of antigas) {
          await tx`
            update privado.midia
               set estado = 'removida',
                   atualizado_em = privado.agora()
             where id = ${antiga.id}::uuid
          `;
          await tx`
            select pgmq.send(
              'expurgo_midia',
              jsonb_build_object(
                'verificacao_id', ${antiga.id}::text,
                'bucket', 'midia-perfil',
                'caminhos', jsonb_build_array(
                  ${antiga.storage_path}::text,
                  replace(${antiga.storage_path}::text, '.jpg', '_thumb.jpg')
                ),
                'origem', 'foto_perfil'
              )
            )
          `;
        }

        const res = await tx`
          update privado.midia
             set estado = 'aprovada',
                 motivo_codigo = null,
                 motivo_recusa = null,
                 atualizado_em = privado.agora()
           where id = ${id}::uuid
             and estado = 'em_analise'
          returning id
        `;
        return res.length > 0;
      });
    },
    async marcarRecusada(id, codigo, motivo) {
      const res = await sql`
        update privado.midia
           set estado = 'recusada',
               motivo_codigo = ${codigo},
               motivo_recusa = ${motivo},
               atualizado_em = privado.agora()
         where id = ${id}::uuid
           and estado = 'em_analise'
        returning id
      `;
      return res.length > 0;
    },
    async removerDaFila(msgId) {
      await sql`select pgmq.delete('moderacao_midia', ${msgId}::bigint)`;
    },
    // O consumo vive em `privado.moderacao_chamada`, que ainda precisa de migração própria.
    // Sem a tabela estas duas consultas falham, e falhar aqui é falhar fechado.
    async reservarChamada(midiaId, provedor, mes, tetoMensal, maximoPorFoto) {
      return await sql.begin(async (tx) => {
        await tx`select pg_advisory_xact_lock(hashtext('moderacao_chamada'))`;
        const [mesTotal] = await tx`
          select count(*)::int as n from privado.moderacao_chamada
           where mes = ${mes} and provedor = ${provedor}
        `;
        if (Number(mesTotal.n) >= tetoMensal) return "teto_mensal" as ReservaChamada;
        const [fotoTotal] = await tx`
          select count(*)::int as n from privado.moderacao_chamada
           where midia_id = ${midiaId}::uuid
        `;
        if (Number(fotoTotal.n) >= maximoPorFoto) return "limite_foto" as ReservaChamada;
        await tx`
          insert into privado.moderacao_chamada (midia_id, provedor, mes)
          values (${midiaId}::uuid, ${provedor}, ${mes})
        `;
        return "ok" as ReservaChamada;
      });
    },
    async liberarChamada(midiaId, provedor, mes) {
      await sql`
        delete from privado.moderacao_chamada
         where id = (
           select max(id) from privado.moderacao_chamada
            where midia_id = ${midiaId}::uuid and provedor = ${provedor} and mes = ${mes}
         )
      `;
    },
    async encerrar() {
      await sql.end({ timeout: 2 });
    },
  };
}

// ---------------------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------------------

/** Falha transitória: a mídia continua `em_analise` e a mensagem volta à fila. */
class FalhaTransitoria extends Error {
  constructor(public motivo: string, public status = 0) {
    super(motivo);
  }
}

interface ContextoStorage {
  fetchFn: typeof fetch;
  supabaseUrl: string;
  serviceRoleKey: string;
}

function urlObjeto(ctx: ContextoStorage, caminho: string): string {
  return `${ctx.supabaseUrl.replace(/\/+$/, "")}/storage/v1/object/${BUCKET}/${
    caminho.split("/").map(encodeURIComponent).join("/")
  }`;
}

function cabecalhosStorage(ctx: ContextoStorage): Record<string, string> {
  return { Authorization: `Bearer ${ctx.serviceRoleKey}`, apikey: ctx.serviceRoleKey };
}

async function baixarObjeto(ctx: ContextoStorage, caminho: string): Promise<Uint8Array> {
  let resp: Response;
  try {
    resp = await ctx.fetchFn(urlObjeto(ctx, caminho), {
      method: "GET",
      headers: cabecalhosStorage(ctx),
      signal: AbortSignal.timeout(TIMEOUT_REDE_MS),
    });
  } catch (_err) {
    throw new FalhaTransitoria("storage_indisponivel", 0);
  }
  if (!resp.ok) {
    await resp.body?.cancel().catch(() => {});
    throw new FalhaTransitoria("storage_download", resp.status);
  }
  try {
    return new Uint8Array(await resp.arrayBuffer());
  } catch (_err) {
    throw new FalhaTransitoria("storage_download", 0);
  }
}

async function gravarObjeto(ctx: ContextoStorage, caminho: string, bytes: Uint8Array): Promise<void> {
  let resp: Response;
  try {
    resp = await ctx.fetchFn(urlObjeto(ctx, caminho), {
      method: "POST",
      headers: { ...cabecalhosStorage(ctx), "Content-Type": "image/jpeg", "x-upsert": "true" },
      body: bytes as unknown as BodyInit,
      signal: AbortSignal.timeout(TIMEOUT_REDE_MS),
    });
  } catch (_err) {
    throw new FalhaTransitoria("storage_indisponivel", 0);
  }
  if (!resp.ok) {
    await resp.body?.cancel().catch(() => {});
    throw new FalhaTransitoria("storage_upload", resp.status);
  }
  await resp.body?.cancel().catch(() => {});
}

async function removerObjetoMelhorEsforco(ctx: ContextoStorage, caminho: string): Promise<void> {
  try {
    const resp = await ctx.fetchFn(urlObjeto(ctx, caminho), {
      method: "DELETE",
      headers: cabecalhosStorage(ctx),
      signal: AbortSignal.timeout(TIMEOUT_REDE_MS),
    });
    await resp.body?.cancel().catch(() => {});
  } catch (_err) {
    // Melhor esforço: o expurgo de 24 h varre `storage_path` e a miniatura de qualquer forma.
  }
}

// ---------------------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------------------

type Desfecho = "aprovada" | "recusada" | "ignorada" | "pendente";

interface Pendente {
  midia_id: string;
  msg_id: number;
  motivo: string;
  status: number;
  read_ct: number;
}

export function caminhoMiniatura(midiaId: string): string {
  return `perfil/${midiaId}_thumb.jpg`;
}

function mesDe(data: Date): string {
  return data.toISOString().slice(0, 7);
}

function resposta(status: number, corpo: unknown): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function alertaPadrao(evento: Record<string, unknown>): void {
  console.error(JSON.stringify({ nivel: "alerta", funcao: "moderar-midia", ...evento }));
}

export async function handler(req: Request, deps?: HandlerDeps): Promise<Response> {
  if (req.method !== "POST") {
    return resposta(405, { code: "metodo_nao_permitido", message: "metodo_nao_permitido", details: null });
  }

  const agendadorSecret = obterVariavel("AGENDADOR_SECRET", deps?.agendadorSecret);
  if (!segredoAgendadorValido(req, agendadorSecret)) {
    return resposta(401, { code: "nao_autenticado", message: "nao_autenticado", details: null });
  }

  const supabaseUrl = obterVariavel("SUPABASE_URL", deps?.supabaseUrl);
  const serviceRoleKey = obterVariavel("SUPABASE_SERVICE_ROLE_KEY", deps?.serviceRoleKey);
  const fetchFn = deps?.fetchFn ?? fetch;
  const alerta = deps?.alerta ?? alertaPadrao;
  const agora = deps?.agora ?? (() => new Date());
  const gerarMiniatura = deps?.gerarMiniatura ?? gerarMiniaturaJpeg;
  const ctx: ContextoStorage = { fetchFn, supabaseUrl, serviceRoleKey };

  // Configuração errada é erro do operador: devolve 500 antes de tocar na fila, e nada é
  // publicado nem consumido.
  let provedor: ProvedorModeracao;
  let tetoMensal: number;
  try {
    const env = deps?.env ?? Object.fromEntries(
      ["MODERACAO_PROVEDOR", "MODERACAO_TETO_MENSAL", "OPENAI_API_KEY", "AZURE_CONTENT_SAFETY_KEY",
        "AZURE_CONTENT_SAFETY_ENDPOINT"].map((k) => [k, Deno.env.get(k)]),
    );
    provedor = deps?.provedor ?? criarProvedor(env, fetchFn);
    tetoMensal = lerTetoMensal(env);
  } catch (err) {
    alerta({ evento: "moderacao_configuracao_invalida", detalhe: err instanceof Error ? err.message : "erro" });
    return resposta(500, { code: "erro_configuracao", message: "erro_configuracao", details: null });
  }

  let sqlClient: SqlClient;
  try {
    sqlClient = criarSqlClient(deps);
  } catch (_err) {
    return resposta(500, { code: "erro_interno", message: "erro_interno", details: null });
  }

  try {
    let corpo: { lote?: unknown } = {};
    try {
      corpo = await req.json();
    } catch {
      corpo = {};
    }
    let lote = LOTE_PADRAO;
    if (typeof corpo.lote === "number" && Number.isFinite(corpo.lote)) {
      lote = Math.min(Math.max(Math.trunc(corpo.lote), 1), LOTE_MAXIMO);
    }

    let mensagens: MensagemModeracao[];
    try {
      mensagens = await sqlClient.lerLote(lote, VISIBILIDADE_SEGUNDOS);
    } catch (_err) {
      // Fila ilegível é portão não rodado, e não fila vazia: 500 para o agendador registrar.
      return resposta(500, { code: "erro_interno", message: "erro_interno", details: null });
    }

    const contagem = { aprovadas: 0, recusadas: 0, ignoradas: 0 };
    const pendentes: Pendente[] = [];
    const alertas: Array<{ midia_id: string; msg_id: number; read_ct: number }> = [];

    const sairDaFila = async (msgId: number): Promise<void> => {
      await sqlClient.removerDaFila(msgId).catch(() => {});
    };

    const recusar = async (
      msg: MensagemModeracao,
      codigo: MotivoCodigo,
      objetosParaLimpar: string[],
    ): Promise<Desfecho> => {
      const mudou = await sqlClient.marcarRecusada(msg.midia_id, codigo, MOTIVOS_RECUSA[codigo]);
      if (!mudou) {
        // Se a foto foi removida pelo titular ou expurgada, limpa o que foi gravado
        const atual = await sqlClient.obterMidia(msg.midia_id);
        if (!atual || atual.estado === "removida" || atual.estado === "expurgada") {
          for (const caminho of objetosParaLimpar) await removerObjetoMelhorEsforco(ctx, caminho);
        }
        await sairDaFila(msg.msg_id);
        return "ignorada";
      }
      await sairDaFila(msg.msg_id);
      return "recusada";
    };

    const processar = async (msg: MensagemModeracao): Promise<Desfecho> => {
      if (!msg.midia_id) {
        await sairDaFila(msg.msg_id); // sem id não há o que reanalisar
        return "ignorada";
      }

      const midia = await sqlClient.obterMidia(msg.midia_id);
      if (!midia || midia.estado !== "em_analise") {
        await sairDaFila(msg.msg_id);
        return "ignorada";
      }

      const original = await baixarObjeto(ctx, midia.storage_path);

      if (original.length > TAMANHO_MAXIMO_BYTES) return await recusar(msg, "formato_invalido", []);
      const analise = sanitizarJpeg(original);
      if (!analise.ok) return await recusar(msg, "formato_invalido", []);
      if (!dimensoesValidas(analise.largura, analise.altura)) {
        return await recusar(msg, "dimensoes_invalidas", []);
      }

      let originalRecodificado: Uint8Array;
      let miniatura: Uint8Array;
      try {
        const proc = recodificarOriginalJpeg(analise.sanitizado);
        originalRecodificado = proc.recodificado;
        miniatura = deps?.gerarMiniatura ? await deps.gerarMiniatura(analise.sanitizado) : proc.miniatura;
      } catch (err) {
        // Grande demais para a memória: falha fechada, sem culpar a foto.
        if (err instanceof ErroMiniaturaExcedeMemoria) {
          alerta({ evento: "moderacao_miniatura_excede_memoria", midia_id: midia.id });
          throw new FalhaTransitoria("miniatura_excede_memoria", 0);
        }
        // O decodificador não leu um JPEG com cabeçalho válido: reler não muda o resultado.
        return await recusar(msg, "formato_invalido", []);
      }

      const caminhoThumb = caminhoMiniatura(midia.id);
      await gravarObjeto(ctx, midia.storage_path, originalRecodificado);
      await gravarObjeto(ctx, caminhoThumb, miniatura);
      const gravados = [midia.storage_path, caminhoThumb];

      let aprovada = true;
      if (provedor.externo) {
        const mes = mesDe(agora());
        const reserva = await sqlClient.reservarChamada(
          midia.id,
          provedor.nome,
          mes,
          tetoMensal,
          msg.reanalise ? 2 : 1,
        );
        if (reserva === "teto_mensal") {
          alerta({ evento: "moderacao_teto_mensal_estourado", provedor: provedor.nome, mes, teto: tetoMensal });
          throw new FalhaTransitoria("teto_mensal", 0);
        }
        if (reserva === "limite_foto") {
          alerta({ evento: "moderacao_limite_por_foto", provedor: provedor.nome, midia_id: midia.id });
          throw new FalhaTransitoria("limite_por_foto", 0);
        }
        try {
          aprovada = (await provedor.analisar({ original: originalRecodificado, miniatura })).aprovada;
        } catch (err) {
          // O envio ao provedor foi iniciado e consome a saída/teto de forma irreversível (achado 1 do Lince Codex).
          throw new FalhaTransitoria("provedor_indisponivel", err instanceof ErroProvedor ? err.status : 0);
        }
      } else {
        aprovada = (await provedor.analisar({ original: originalRecodificado, miniatura })).aprovada;
      }

      if (!aprovada) return await recusar(msg, "conteudo_improprio", gravados);

      const mudou = await sqlClient.marcarAprovada(midia.id);
      if (!mudou) {
        // Se a foto já estiver aprovada por worker concorrente, não apaga os objetos válidos (achado 4 do Lince Codex)
        const atual = await sqlClient.obterMidia(midia.id);
        if (!atual || atual.estado === "removida" || atual.estado === "expurgada") {
          for (const caminho of gravados) await removerObjetoMelhorEsforco(ctx, caminho);
        }
        await sairDaFila(msg.msg_id);
        return "ignorada";
      }
      await sairDaFila(msg.msg_id);
      return "aprovada";
    };

    for (const msg of mensagens) {
      try {
        const desfecho = await processar(msg);
        if (desfecho === "aprovada") contagem.aprovadas += 1;
        else if (desfecho === "recusada") contagem.recusadas += 1;
        else contagem.ignoradas += 1;
      } catch (err) {
        // Falha fechada: não publica e não confirma. A mensagem reaparece sozinha.
        const falha = err instanceof FalhaTransitoria
          ? err
          : new FalhaTransitoria("erro_interno", 0);
        pendentes.push({
          midia_id: msg.midia_id,
          msg_id: msg.msg_id,
          motivo: falha.motivo,
          status: falha.status,
          read_ct: msg.read_ct,
        });
        if (msg.read_ct >= LEITURAS_PARA_ALERTA) {
          alertas.push({ midia_id: msg.midia_id, msg_id: msg.msg_id, read_ct: msg.read_ct });
          alerta({
            evento: "moderacao_mensagem_presa",
            midia_id: msg.midia_id,
            msg_id: msg.msg_id,
            read_ct: msg.read_ct,
            motivo: falha.motivo,
          });
        }
      }
    }

    return resposta(200, {
      ok: true,
      mensagens_lidas: mensagens.length,
      aprovadas: contagem.aprovadas,
      recusadas: contagem.recusadas,
      ignoradas: contagem.ignoradas,
      pendentes,
      alertas,
    });
  } finally {
    await sqlClient.encerrar?.().catch(() => {});
  }
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => {
    return await handler(req);
  });
}
