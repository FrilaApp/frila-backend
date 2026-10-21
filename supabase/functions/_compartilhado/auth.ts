// Módulo de segurança compartilhado das Edge Functions (AUDITORIA-EDGE-SEG.md · Achado 3).
//
// Centraliza o núcleo de validação de autenticação:
// 1. Comparação de segredos em tempo constante contra timing attacks (CWE-208 / RN15).
// 2. Validação e extração do cabeçalho de autenticação Bearer para endpoints de usuário.
// 3. Validação uniforme do segredo de agendador (x-agendador-secret / Bearer).

/**
 * Regex estrita para validação do formato do cabeçalho Authorization: Bearer <token>.
 * Exige "Bearer " seguido de pelo menos um caractere que não seja espaço em branco (case-insensitive).
 */
export const BEARER_REGEX = /^Bearer\s+\S+$/i;

/**
 * Comparação de strings em tempo constante para mitigar timing attacks (CWE-208 / RN15).
 * Executa XOR acumulado em todos os bytes e compara os comprimentos.
 */
export function igualEmTempoConstante(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diferenca = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diferenca |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diferenca === 0;
}

/**
 * Valida se o cabeçalho Authorization segue estritamente o formato `Bearer <token>`.
 */
export function validarFormatoBearer(autorizacao: string | null): boolean {
  if (!autorizacao) return false;
  return BEARER_REGEX.test(autorizacao);
}

/**
 * Extrai o token Bearer do cabeçalho Authorization se o formato for válido; retorna null caso contrário.
 */
export function extrairBearerToken(autorizacao: string | null): string | null {
  if (!autorizacao) return null;
  const match = autorizacao.match(/^Bearer\s+(\S+)$/i);
  return match ? match[1] : null;
}

export interface OpcoesValidarSegredo {
  /**
   * Se true, aceita também o segredo enviado via `Authorization: Bearer <segredo>`.
   * Padrão: true.
   */
  permitirBearer?: boolean;
}

/**
 * Valida o segredo do agendador em tempo constante contra `x-agendador-secret`
 * ou alternativamente `Authorization: Bearer <segredo>` (se permitido).
 */
export function segredoAgendadorValido(
  req: Request,
  segredoEsperado: string,
  opcoes: OpcoesValidarSegredo = {},
): boolean {
  if (!segredoEsperado || segredoEsperado.trim() === "") {
    return false;
  }

  const cabecalho = req.headers.get("x-agendador-secret");
  if (cabecalho && igualEmTempoConstante(cabecalho, segredoEsperado)) {
    return true;
  }

  const permitirBearer = opcoes.permitirBearer ?? true;
  if (permitirBearer) {
    const authHeader = req.headers.get("Authorization") ?? "";
    const match = authHeader.match(/^Bearer\s+(.+)$/i);
    if (match && igualEmTempoConstante(match[1], segredoEsperado)) {
      return true;
    }
  }

  return false;
}
