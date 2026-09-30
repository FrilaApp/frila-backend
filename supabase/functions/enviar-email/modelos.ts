// Os modelos de e-mail transacional (cartão 7yq1flLG).
//
// ── De onde sai este texto, e o que ainda falta ───────────────────────────────
//
// O cartão depende de *S1 · Design + Produto · Modelos de e-mail*, que ainda não
// entregou. O que está aqui é o conteúdo que o próprio cartão descreve — protocolo,
// categoria e prazo —, escrito no tom dos textos de push já aprovados, e nada além. É a
// mesma escolha que o `enviar-push` fez enquanto a planilha de notificações não existia:
// texto que cumpre a regra agora, num arquivo só, para o design trocar as palavras sem
// tocar em lógica nenhuma.
//
// ── O que nenhum destes modelos leva ─────────────────────────────────────────
//
// O relato, o nome de quem denunciou, o nome de quem foi denunciado e o endereço da
// outra parte. O e-mail da equipe leva protocolo, categoria e prazo; quem lê abre a
// ocorrência pelo protocolo. O motivo para isso não é pudor: tudo que entra no corpo de
// um e-mail é copiado para os logs do provedor, que estão fora do alcance da retenção
// da RF25 e da anonimização (RN15).

export interface DadosDaOcorrencia {
  ocorrencia_id: string;
  tipo: string;
  motivo: string;
  criada_em: string;
  prazo_resposta_ate: string;
  alvo_tipo?: string | null;
}

export interface Mensagem {
  assunto: string;
  texto: string;
}

// O protocolo é o id da ocorrência, como o contrato define em `Protocolo`. No assunto
// vai o prefixo, que é o que cabe numa lista de caixa de entrada; o corpo leva o id
// inteiro, que é o que a pessoa cola de volta quando responde.
export function protocoloCurto(ocorrenciaId: string): string {
  return ocorrenciaId.replace(/-/g, "").slice(0, 8).toUpperCase();
}

// Data no formato de quem lê, no fuso de Brasília. O prazo vem do banco como `date`
// (`2026-10-06`), já calculado em dias úteis por `privado.prazo_de_resposta`; formatá-lo
// com `new Date()` o jogaria para o dia anterior em UTC−3.
export function formatarData(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  if (!m) return iso;
  return `${m[3]}/${m[2]}/${m[1]}`;
}

const CATEGORIAS: Record<string, string> = {
  assedio: "Assédio",
  discriminacao: "Discriminação",
  risco_seguranca: "Risco à segurança",
  outro: "Outro",
};

// A categoria é um valor do enum `motivo_denuncia`. Um motivo que não seja do enum — a
// contestação e o suporte gravam texto livre em `motivo` — não é interpolado: viraria
// texto de outra pessoa dentro do assunto de um e-mail.
export function categoria(motivo: string): string {
  return CATEGORIAS[motivo] ?? "Não classificado";
}

const ASSINATURA = "Equipe Frila\nfrila.app";

// ── Denúncia (RF26, RN13) ─────────────────────────────────────────────────────

export function denunciaParaEquipe(d: DadosDaOcorrencia): Mensagem {
  const curto = protocoloCurto(d.ocorrencia_id);
  const prazo = formatarData(d.prazo_resposta_ate);
  const alvo = d.alvo_tipo === "estabelecimento"
    ? "um estabelecimento"
    : d.alvo_tipo === "profissional"
    ? "um profissional"
    : "a outra parte";

  return {
    assunto: `[Frila] Denúncia ${curto} · responder até ${prazo}`,
    texto: [
      `Uma denúncia foi registrada contra ${alvo}.`,
      "",
      `Protocolo: ${d.ocorrencia_id}`,
      `Categoria: ${categoria(d.motivo)}`,
      `Aberta em: ${formatarData(d.criada_em)}`,
      `Prazo de resposta: ${prazo} (5 dias úteis)`,
      "",
      "O relato não vai por e-mail. Abra a ocorrência pelo protocolo para lê-lo.",
      "",
      ASSINATURA,
    ].join("\n"),
  };
}

export function denunciaParaAutor(d: DadosDaOcorrencia): Mensagem {
  const curto = protocoloCurto(d.ocorrencia_id);
  const prazo = formatarData(d.prazo_resposta_ate);

  return {
    assunto: `Recebemos sua denúncia · protocolo ${curto}`,
    texto: [
      "Recebemos sua denúncia e ela já está com a Equipe Frila.",
      "",
      `Protocolo: ${d.ocorrencia_id}`,
      `Prazo de resposta: até ${prazo}`,
      "",
      "A Equipe Frila responde por e-mail em até 5 dias úteis. Guarde o protocolo:",
      "é por ele que acompanhamos o caso.",
      "",
      "Se você estiver em risco imediato, procure a autoridade policial. O Frila não",
      "substitui esse atendimento.",
      "",
      ASSINATURA,
    ].join("\n"),
  };
}

// ── Contestação de suspensão (RF24) ───────────────────────────────────────────
//
// A RPC `contestar_suspensao` é do cartão BsXIZHOw e ainda não entrou. Os modelos ficam
// aqui porque o pedido de e-mail é o mesmo — uma ocorrência de outro `tipo` na mesma
// fila — e porque um consumidor que não reconhece o tipo arquivaria o pedido em
// silêncio. Chegando a RPC, a contestação já sai.

export function contestacaoParaEquipe(d: DadosDaOcorrencia): Mensagem {
  const curto = protocoloCurto(d.ocorrencia_id);
  const prazo = formatarData(d.prazo_resposta_ate);

  return {
    assunto: `[Frila] Contestação de suspensão ${curto} · responder até ${prazo}`,
    texto: [
      "Uma contestação de suspensão foi registrada.",
      "",
      `Protocolo: ${d.ocorrencia_id}`,
      `Aberta em: ${formatarData(d.criada_em)}`,
      `Prazo de resposta: ${prazo} (5 dias úteis)`,
      "",
      "O texto da contestação não vai por e-mail. Abra a ocorrência pelo protocolo.",
      "",
      ASSINATURA,
    ].join("\n"),
  };
}

export function contestacaoParaAutor(d: DadosDaOcorrencia): Mensagem {
  const curto = protocoloCurto(d.ocorrencia_id);
  const prazo = formatarData(d.prazo_resposta_ate);

  return {
    assunto: `Recebemos sua contestação · protocolo ${curto}`,
    texto: [
      "Recebemos sua contestação e ela já está com a Equipe Frila.",
      "",
      `Protocolo: ${d.ocorrencia_id}`,
      `Prazo de resposta: até ${prazo}`,
      "",
      "A Equipe Frila responde por e-mail em até 5 dias úteis.",
      "",
      ASSINATURA,
    ].join("\n"),
  };
}

// ── Alerta do monitoramento (cartão 5bPJvMIo) ─────────────────────────────────
//
// O cartão 7yq1flLG diz que a fila e esta função saem primeiro *porque o alerta do
// monitoramento sai por elas*. O alerta não tem ocorrência: leva um código e, quando
// houver, um número. Nada de texto livre — um alerta que aceitasse texto viraria o
// caminho mais curto para dado pessoal chegar ao provedor sem ninguém notar.

export function alertaParaEquipe(codigo: string, valor?: number): Mensagem {
  const linhaValor = typeof valor === "number" && Number.isFinite(valor)
    ? `Valor: ${valor}`
    : null;

  return {
    assunto: `[Frila] Alerta: ${codigo}`,
    texto: [
      "O monitoramento do backend disparou um alerta.",
      "",
      `Código: ${codigo}`,
      ...(linhaValor ? [linhaValor] : []),
      "",
      ASSINATURA,
    ].join("\n"),
  };
}

// ── Roteamento por tipo ───────────────────────────────────────────────────────

export type Destino = "equipe" | "autor";

export function modeloDe(
  tipo: string,
  destino: Destino,
  d: DadosDaOcorrencia,
): Mensagem | null {
  if (tipo === "denuncia") {
    return destino === "equipe" ? denunciaParaEquipe(d) : denunciaParaAutor(d);
  }
  if (tipo === "contestacao") {
    return destino === "equipe" ? contestacaoParaEquipe(d) : contestacaoParaAutor(d);
  }
  return null;
}
