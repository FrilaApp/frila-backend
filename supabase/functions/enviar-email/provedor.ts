// O provedor de e-mail (cartão 7yq1flLG).
//
// ── Por que SMTP, e não a API de um provedor ──────────────────────────────────
//
// O provedor ainda não foi escolhido: a pendência D02 do vault ("Escolher o provedor de
// e-mail (SMTP) do código de entrada, antes do piloto") continua aberta, e o cartão
// depende de *S1 · Infra · SMTP próprio no Supabase Auth*. SMTP é o único denominador
// comum entre os candidatos, é o que o `.env` deste repositório já reserva
// (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`) e é o que o Supabase Auth vai
// usar para o código de entrada. Escolhido o provedor, entram as credenciais por
// `supabase secrets set` e nada aqui muda.
//
// ── O erro que o banco guarda ─────────────────────────────────────────────────
//
// A `privado.registrar_falha_email` só aceita código em `snake_case`, porque a mensagem
// crua do provedor costuma trazer o endereço do destinatário dentro (RN15). A
// classificação é aqui, e é ela que também decide se vale insistir: 4xx é o provedor
// pedindo para voltar depois, 5xx é recusa definitiva.

export interface Email {
  para: string;
  assunto: string;
  texto: string;
  responderPara?: string;
}

export interface ResultadoEnvio {
  ok: boolean;
  codigo?: string;
  transitorio?: boolean;
}

export type Enviar = (email: Email) => Promise<ResultadoEnvio>;

export interface ConfiguracaoSmtp {
  host: string;
  porta: number;
  usuario?: string;
  senha?: string;
  remetente: string;
  tls: boolean;
}

export function lerConfiguracaoSmtp(): ConfiguracaoSmtp | null {
  const host = Deno.env.get("SMTP_HOST")?.trim();
  // `SMTP_SENDER` é o nome que o `.env.example` da raiz já usava para o remetente do
  // código de entrada. Dois nomes para o mesmo endereço custaria um e-mail que não sai
  // porque a variável certa tem o nome do outro arquivo.
  const remetente = (Deno.env.get("EMAIL_REMETENTE") || Deno.env.get("SMTP_SENDER"))?.trim();
  if (!host || !remetente) return null;

  const porta = Number(Deno.env.get("SMTP_PORT") ?? "587");
  return {
    host,
    porta: Number.isFinite(porta) && porta > 0 ? porta : 587,
    usuario: Deno.env.get("SMTP_USER")?.trim() || undefined,
    senha: Deno.env.get("SMTP_PASS")?.trim() || undefined,
    remetente,
    // 465 é TLS implícito; 587 e 25 sobem por STARTTLS. `SMTP_TLS=0` existe para o
    // Mailpit local, que não fala TLS nenhum.
    tls: (Deno.env.get("SMTP_TLS") ?? "1") !== "0" && porta === 465,
  };
}

// A classe do erro, em `snake_case`, e se vale tentar de novo.
//
// A leitura é pelo código SMTP de três dígitos no início da mensagem, que é o que todo
// servidor devolve. Sem código reconhecível, o erro conta como transitório: insistir
// cinco vezes num erro definitivo custa quatro chamadas; desistir de um transitório
// custa a denúncia de alguém.
export function classificarErro(erro: unknown): { codigo: string; transitorio: boolean } {
  const texto = erro instanceof Error ? erro.message : String(erro ?? "");

  if (/\b(ECONNREFUSED|ECONNRESET|ETIMEDOUT|connection (refused|reset|closed)|timed? ?out)\b/i.test(texto)) {
    return { codigo: "falha_de_conexao", transitorio: true };
  }

  const m = /(?:^|\s)([245])(\d{2})(?:\s|-|$)/.exec(texto);
  if (m) {
    const classe = m[1];
    const completo = `${m[1]}${m[2]}`;
    if (classe === "2") return { codigo: `smtp_${completo}`, transitorio: false };
    if (classe === "4") return { codigo: `smtp_${completo}`, transitorio: true };
    // 550, 553 e companhia: caixa que não existe ou recusa. Insistir não muda.
    return { codigo: `smtp_${completo}`, transitorio: false };
  }

  if (/\b(auth|authentication|credential)/i.test(texto)) {
    return { codigo: "falha_de_autenticacao", transitorio: false };
  }

  return { codigo: "erro_nao_classificado", transitorio: true };
}

// O `denomailer` entra por importação dinâmica, e não no topo do arquivo, para que
// `deno test` não precise de rede: os testes injetam o envio e nunca chegam aqui.
export function criarEnvioSmtp(cfg: ConfiguracaoSmtp): Enviar {
  return async (email: Email): Promise<ResultadoEnvio> => {
    try {
      const { SMTPClient } = await import(
        "https://deno.land/x/denomailer@1.6.0/mod.ts"
      );
      const cliente = new SMTPClient({
        connection: {
          hostname: cfg.host,
          port: cfg.porta,
          tls: cfg.tls,
          auth: cfg.usuario && cfg.senha
            ? { username: cfg.usuario, password: cfg.senha }
            : undefined,
        },
      });
      try {
        await cliente.send({
          from: cfg.remetente,
          to: email.para,
          subject: email.assunto,
          content: email.texto,
          replyTo: email.responderPara,
        });
      } finally {
        await cliente.close();
      }
      return { ok: true };
    } catch (erro) {
      const { codigo, transitorio } = classificarErro(erro);
      return { ok: false, codigo, transitorio };
    }
  };
}
