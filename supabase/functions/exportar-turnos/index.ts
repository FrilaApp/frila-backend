// Edge Function exportar-turnos (cartão pd7zOS5P · US20, RF22, RN09, RN17, RN18, UC13).
//
// Exporta os turnos realizados de um período em formato CSV ou PDF.
// O arquivo é retornado diretamente no corpo da resposta (sem links temporários).
//
//   1. Valida o método HTTP (apenas POST) e os parâmetros obrigatórios: de, ate, formato.
//   2. Valida o token Bearer no endpoint auth/v1/user do Supabase Auth.
//   3. Consulta `privado.turnos_exportacao(usuario, de, ate, estabelecimento_id)`.
//   4. Período sem turnos retorna 204 No Content sem corpo/arquivo (UC13 1a).
//   5. Gera o arquivo no formato solicitado (CSV ou PDF) com Cache-Control: no-store (RN15).

import postgres from "npm:postgres@3.4.4";
import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";

export interface TurnoExportacao {
  turno_id: string;
  data: string; // YYYY-MM-DD
  funcao: string;
  inicio_em: string;
  fim_em: string;
  checkin_em: string | null;
  checkout_em: string | null;
  valor_acordado_centavos: number | string;
  contraparte: string;
  verificacao: string;
}

export interface Erro {
  code: string;
  message: string;
  details: string | null;
  hint?: string | null;
}

export interface SqlClient {
  turnosExportacao: (
    userId: string,
    de: string,
    ate: string,
    estabelecimentoId: string | null
  ) => Promise<TurnoExportacao[]>;
}

export interface HandlerDeps {
  fetchFn?: typeof fetch;
  sqlClient?: SqlClient;
  supabaseUrl?: string;
  anonKey?: string;
  dbUrl?: string;
}

function respostaJson(status: number, corpo: unknown, headersExtra?: Record<string, string>): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...headersExtra,
    },
  });
}

function erro(status: number, code: string, details: string | null = null): Response {
  return respostaJson(status, {
    code,
    message: code,
    details,
    hint: null,
  } satisfies Erro);
}

function obterVariavel(nome: string, injetada?: string): string {
  const valor = (injetada ?? Deno.env.get(nome))?.trim();
  if (!valor) {
    throw new Error(`${nome} é obrigatório e deve estar configurado no ambiente.`);
  }
  return valor;
}

export function formatarCentavosReais(centavos: number | string): string {
  const num = typeof centavos === "string" ? parseInt(centavos, 10) : centavos;
  const reais = (num / 100).toFixed(2).replace(".", ",");
  return `R$ ${reais}`;
}

export function formatarHoraLocal(dataIso: string | null): string {
  if (!dataIso) return "-";
  try {
    const d = new Date(dataIso);
    if (isNaN(d.getTime())) return "-";
    // Exibe no fuso America/Sao_Paulo (RN18)
    return new Intl.DateTimeFormat("pt-BR", {
      timeZone: "America/Sao_Paulo",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    }).format(d);
  } catch {
    return "-";
  }
}

export function formatarDataLocal(dataStr: string | null): string {
  if (!dataStr) return "-";
  try {
    const d = new Date(dataStr.includes("T") ? dataStr : `${dataStr}T12:00:00Z`);
    if (isNaN(d.getTime())) return dataStr;
    return new Intl.DateTimeFormat("pt-BR", {
      timeZone: "America/Sao_Paulo",
      day: "2-digit",
      month: "2-digit",
      year: "numeric",
    }).format(d);
  } catch {
    return dataStr;
  }
}

export function gerarCsv(turnos: TurnoExportacao[]): string {
  const cabecalhos = [
    "Data",
    "Funcao",
    "Inicio Previsto",
    "Fim Previsto",
    "Checkin",
    "Checkout",
    "Valor Acordado",
    "Contraparte",
    "Status",
  ];

  const linhas = [cabecalhos.join(",")];

  for (const t of turnos) {
    const dataFmt = formatarDataLocal(t.data);
    const inicioFmt = formatarHoraLocal(t.inicio_em);
    const fimFmt = formatarHoraLocal(t.fim_em);
    const checkinFmt = formatarHoraLocal(t.checkin_em);
    const checkoutFmt = formatarHoraLocal(t.checkout_em);
    const valorFmt = formatarCentavosReais(t.valor_acordado_centavos);
    const statusFmt =
      t.verificacao === "verificado"
        ? "Verificado"
        : t.verificacao === "nao_verificado"
        ? "Nao verificado"
        : "Pendente";

    const escapar = (val: string) => {
      if (val.includes(",") || val.includes('"') || val.includes("\n")) {
        return `"${val.replace(/"/g, '""')}"`;
      }
      return val;
    };

    linhas.push(
      [
        escapar(dataFmt),
        escapar(t.funcao),
        escapar(inicioFmt),
        escapar(fimFmt),
        escapar(checkinFmt),
        escapar(checkoutFmt),
        escapar(valorFmt),
        escapar(t.contraparte),
        escapar(statusFmt),
      ].join(","),
    );
  }

  return linhas.join("\r\n");
}

export async function gerarPdf(turnos: TurnoExportacao[], deStr: string, ateStr: string): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const fontRegular = await doc.embedFont(StandardFonts.Helvetica);
  const fontBold = await doc.embedFont(StandardFonts.HelveticaBold);

  const corTexto = rgb(0.15, 0.15, 0.15);
  const corCinza = rgb(0.45, 0.45, 0.45);
  const corLinha = rgb(0.85, 0.85, 0.85);
  const corDestaque = rgb(0.8, 0.15, 0.15); // Para 'Não verificado'

  const larguraPagina = 841.89; // A4 landscape
  const alturaPagina = 595.28;
  const margemX = 36;
  let y = alturaPagina - 40;

  let pagina = doc.addPage([larguraPagina, alturaPagina]);

  const desenharCabecalho = () => {
    pagina.drawText("Frila - Relatorio Consolidado de Turnos", {
      x: margemX,
      y,
      size: 15,
      font: fontBold,
      color: corTexto,
    });
    y -= 16;

    const periodoFormatado = `Periodo: ${formatarDataLocal(deStr)} a ${formatarDataLocal(ateStr)}`;
    pagina.drawText(periodoFormatado, {
      x: margemX,
      y,
      size: 9,
      font: fontRegular,
      color: corCinza,
    });
    y -= 22;

    // Cabeçalho da tabela
    const colunas = [
      { titulo: "Data", x: margemX, w: 60 },
      { titulo: "Funcao", x: margemX + 60, w: 120 },
      { titulo: "Inicio", x: margemX + 180, w: 55 },
      { titulo: "Fim", x: margemX + 235, w: 55 },
      { titulo: "Check-in", x: margemX + 290, w: 55 },
      { titulo: "Check-out", x: margemX + 345, w: 55 },
      { titulo: "Valor Acordado", x: margemX + 400, w: 85 },
      { titulo: "Contraparte", x: margemX + 485, w: 175 },
      { titulo: "Status", x: margemX + 660, w: 105 },
    ];

    pagina.drawLine({
      start: { x: margemX, y: y + 4 },
      end: { x: larguraPagina - margemX, y: y + 4 },
      thickness: 1,
      color: corLinha,
    });

    for (const col of colunas) {
      pagina.drawText(col.titulo, {
        x: col.x,
        y: y - 8,
        size: 8.5,
        font: fontBold,
        color: corTexto,
      });
    }

    y -= 14;
    pagina.drawLine({
      start: { x: margemX, y },
      end: { x: larguraPagina - margemX, y },
      thickness: 1,
      color: corLinha,
    });
    y -= 14;
  };

  desenharCabecalho();

  let totalCentavos = 0;

  for (const t of turnos) {
    if (y < 60) {
      pagina = doc.addPage([larguraPagina, alturaPagina]);
      y = alturaPagina - 40;
      desenharCabecalho();
    }

    const valCentavos = typeof t.valor_acordado_centavos === "string"
      ? parseInt(t.valor_acordado_centavos, 10)
      : t.valor_acordado_centavos;
    totalCentavos += isNaN(valCentavos) ? 0 : valCentavos;

    const dataFmt = formatarDataLocal(t.data);
    const inicioFmt = formatarHoraLocal(t.inicio_em);
    const fimFmt = formatarHoraLocal(t.fim_em);
    const checkinFmt = formatarHoraLocal(t.checkin_em);
    const checkoutFmt = formatarHoraLocal(t.checkout_em);
    const valorFmt = formatarCentavosReais(t.valor_acordado_centavos);
    const statusFmt =
      t.verificacao === "verificado"
        ? "Verificado"
        : t.verificacao === "nao_verificado"
        ? "Nao verificado"
        : "Pendente";

    const corStatus = t.verificacao === "nao_verificado" ? corDestaque : corTexto;

    pagina.drawText(dataFmt, { x: margemX, y, size: 8, font: fontRegular, color: corTexto });
    pagina.drawText(t.funcao.substring(0, 24), { x: margemX + 60, y, size: 8, font: fontRegular, color: corTexto });
    pagina.drawText(inicioFmt, { x: margemX + 180, y, size: 8, font: fontRegular, color: corTexto });
    pagina.drawText(fimFmt, { x: margemX + 235, y, size: 8, font: fontRegular, color: corTexto });
    pagina.drawText(checkinFmt, { x: margemX + 290, y, size: 8, font: fontRegular, color: corTexto });
    pagina.drawText(checkoutFmt, { x: margemX + 345, y, size: 8, font: fontRegular, color: corTexto });
    pagina.drawText(valorFmt, { x: margemX + 400, y, size: 8, font: fontRegular, color: corTexto });
    pagina.drawText(t.contraparte.substring(0, 36), { x: margemX + 485, y, size: 8, font: fontRegular, color: corTexto });
    pagina.drawText(statusFmt, {
      x: margemX + 660,
      y,
      size: 8,
      font: t.verificacao === "nao_verificado" ? fontBold : fontRegular,
      color: corStatus,
    });

    y -= 14;
  }

  // Rodapé do relatório com totalizador e nota da RN09
  y -= 8;
  pagina.drawLine({
    start: { x: margemX, y: y + 4 },
    end: { x: larguraPagina - margemX, y: y + 4 },
    thickness: 1,
    color: corLinha,
  });
  y -= 10;

  const resumo = `Total: ${turnos.length} turno(s) | Valor total acordado: ${formatarCentavosReais(totalCentavos)}`;
  pagina.drawText(resumo, { x: margemX, y, size: 8.5, font: fontBold, color: corTexto });

  y -= 14;
  const notaRn09 = "O valor exibido e o acordado e registrado entre as partes, nunca um pagamento processado pelo Frila (RN09).";
  pagina.drawText(notaRn09, { x: margemX, y, size: 7.5, font: fontRegular, color: corCinza });

  return await doc.save();
}

export function tratarErroBanco(err: unknown): Response {
  const erroPg = err as { code?: string; message?: string; detail?: string };
  if (erroPg?.code === "PGRST" && erroPg.message) {
    try {
      const corpoErro = JSON.parse(erroPg.message) as Erro;
      let status = 400;
      if (erroPg.detail) {
        try {
          const detailObj = JSON.parse(erroPg.detail) as { status?: number };
          if (typeof detailObj.status === "number") {
            status = detailObj.status;
          }
        } catch {
          // Mantém 400 se o JSON do detail não contiver status numérico
        }
      }
      return respostaJson(status, corpoErro);
    } catch {
      return erro(400, erroPg.message);
    }
  }
  // Sem vazar mensagens de erro do Postgres (RN15)
  console.error("exportar-turnos: erro interno ao consultar turnos");
  return erro(500, "erro_interno");
}

export function criarSqlClient(deps?: HandlerDeps): SqlClient {
  if (deps?.sqlClient) return deps.sqlClient;
  const dbUrl = obterVariavel("SUPABASE_DB_URL", deps?.dbUrl);
  return {
    async turnosExportacao(
      userId: string,
      de: string,
      ate: string,
      estabelecimentoId: string | null
    ): Promise<TurnoExportacao[]> {
      const sql = postgres(dbUrl, { max: 1, connect_timeout: 5 });
      try {
        const rows = await sql`
          select turno_id,
                 data::text,
                 funcao,
                 inicio_em::text,
                 fim_em::text,
                 checkin_em::text,
                 checkout_em::text,
                 valor_acordado_centavos,
                 contraparte,
                 verificacao::text
            from privado.turnos_exportacao(
              ${userId}::uuid,
              ${de}::timestamptz,
              ${ate}::timestamptz,
              ${estabelecimentoId ? estabelecimentoId : null}::uuid
            )
        `;
        return rows as unknown as TurnoExportacao[];
      } finally {
        await sql.end({ timeout: 2 });
      }
    },
  };
}

export async function handler(req: Request, deps?: HandlerDeps): Promise<Response> {
  if (req.method !== "POST") {
    return erro(405, "metodo_nao_permitido");
  }

  const autorizacao = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+$/i.test(autorizacao)) {
    return erro(401, "nao_autenticado");
  }

  let corpo: {
    de?: unknown;
    ate?: unknown;
    formato?: unknown;
    estabelecimento_id?: unknown;
  };

  try {
    corpo = await req.json();
  } catch {
    return erro(422, "campo_obrigatorio", "de");
  }

  if (typeof corpo !== "object" || corpo === null) {
    return erro(422, "campo_obrigatorio", "de");
  }

  // 1. Validação do campo 'de'
  if (corpo.de === undefined || corpo.de === null || (typeof corpo.de === "string" && !corpo.de.trim())) {
    return erro(422, "campo_obrigatorio", "de");
  }
  if (typeof corpo.de !== "string" || isNaN(Date.parse(corpo.de))) {
    return erro(422, "campo_invalido", "de");
  }

  // 2. Validação do campo 'ate'
  if (corpo.ate === undefined || corpo.ate === null || (typeof corpo.ate === "string" && !corpo.ate.trim())) {
    return erro(422, "campo_obrigatorio", "ate");
  }
  if (typeof corpo.ate !== "string" || isNaN(Date.parse(corpo.ate))) {
    return erro(422, "campo_invalido", "ate");
  }

  // 3. Validação do intervalo de datas (de <= ate)
  if (new Date(corpo.de) > new Date(corpo.ate)) {
    return erro(422, "campo_invalido", "de");
  }

  // 4. Validação do campo 'formato'
  if (corpo.formato === undefined || corpo.formato === null || (typeof corpo.formato === "string" && !corpo.formato.trim())) {
    return erro(422, "campo_obrigatorio", "formato");
  }
  if (corpo.formato !== "csv" && corpo.formato !== "pdf") {
    return erro(422, "campo_invalido", "formato");
  }

  // 5. Validação de 'estabelecimento_id' quando fornecido
  let estabId: string | null = null;
  if (corpo.estabelecimento_id !== undefined && corpo.estabelecimento_id !== null) {
    if (
      typeof corpo.estabelecimento_id !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(corpo.estabelecimento_id)
    ) {
      return erro(422, "campo_invalido", "estabelecimento_id");
    }
    estabId = corpo.estabelecimento_id;
  }

  const fetchFn = deps?.fetchFn ?? fetch;
  const origem = obterVariavel("SUPABASE_URL", deps?.supabaseUrl);
  const anon = obterVariavel("SUPABASE_ANON_KEY", deps?.anonKey);

  // 6. Autenticação e validação do token no Supabase Auth
  const usuarioRes = await fetchFn(`${origem}/auth/v1/user`, {
    headers: {
      apikey: anon,
      Authorization: autorizacao,
      "Content-Type": "application/json",
    },
  });

  if (!usuarioRes.ok) {
    return erro(401, "nao_autenticado");
  }

  const usuario = (await usuarioRes.json()) as { id?: unknown };
  if (typeof usuario.id !== "string") {
    return erro(401, "nao_autenticado");
  }

  const sqlClient = criarSqlClient(deps);

  // 7. Consulta no banco de dados
  let turnos: TurnoExportacao[];
  try {
    turnos = await sqlClient.turnosExportacao(usuario.id, corpo.de, corpo.ate, estabId);
  } catch (err: unknown) {
    return tratarErroBanco(err);
  }

  // 8. Período sem turnos devolve 204 sem arquivo (UC13 1a)
  if (!turnos || turnos.length === 0) {
    return new Response(null, {
      status: 204,
      headers: {
        "Cache-Control": "no-store",
      },
    });
  }

  // 9. Devolve arquivo no corpo da resposta
  if (corpo.formato === "csv") {
    const csvContent = gerarCsv(turnos);
    return new Response(csvContent, {
      status: 200,
      headers: {
        "Content-Type": "text/csv; charset=utf-8",
        "Content-Disposition": 'attachment; filename="turnos.csv"',
        "Cache-Control": "no-store",
      },
    });
  } else {
    const pdfBytes = await gerarPdf(turnos, corpo.de, corpo.ate);
    return new Response(pdfBytes as unknown as BodyInit, {
      status: 200,
      headers: {
        "Content-Type": "application/pdf",
        "Content-Disposition": 'attachment; filename="turnos.pdf"',
        "Cache-Control": "no-store",
      },
    });
  }
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => await handler(req));
}
