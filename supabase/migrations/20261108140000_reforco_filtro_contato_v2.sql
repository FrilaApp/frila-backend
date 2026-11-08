-- Reforço do filtro de contato e Pix, v2 (cartão oU0Wl3hI · RN38).
--
-- Três ajustes em privado.texto_sem_contato_ou_pix, sobre a definição de 20261107330000:
--
-- 1. Dígitos Lao (U+0ED0-0ED9) e Myanmar (U+1040-1049) entram na tabela de transliteração para 0-9.
--    Eram Nd fora dos 12 blocos mapeados: "໖໑໙໘໘໘໘໗໗໗໗" passava por não ter nenhum dígito ASCII.
-- 2. `.tech` entra na lista de TLDs de domínio.
-- 3. Data normal ("12/05/2020", "01-10-2022") deixa de ser contada como número de telefone na regra
--    de 8 ou mais dígitos. A máscara só vale para data VÁLIDA (dia 1-31, mês 1-12, ano 19xx ou 20xx):
--    número de 8 dígitos formatado como "99.88.7766" ou "61.99.8765" não é data e segue barrado.
--    A máscara fica só na regra 12; as regras 10 (10 ou mais dígitos) e 11 (palavra de contato por
--    perto) olham o texto sem máscara, e "zap 12/05/2020" continua barrado.
--
-- Mesma assinatura, mesmo nome de parâmetro (create or replace não aceita trocar o nome) e mesmos
-- privilégios. Nada de schema público muda.

create or replace function privado.texto_sem_contato_ou_pix(texto text) returns boolean
language plpgsql immutable security definer set search_path = '' as $$
declare
  v_norm text;
  v_de_digitos text;
  v_para_digitos text;
  v_sem_anos text;
begin
  if texto is null or texto = '' then return true; end if;

  -- 1. Normalização Unicode NFKC (decompõe e recompõe para forma canônica de compatibilidade)
  v_norm := normalize(texto, NFKC);

  -- 2. Remoção de caracteres invisíveis e de formatação (U+200B-U+200F, U+2028-U+202F, U+2060-U+206F, U+FE00-U+FE0F, U+FEFF, U+00AD, U+180E)
  v_norm := regexp_replace(v_norm, '[​-‏ - ⁠-⁯︀-️﻿­᠎]', '', 'g');

  -- 3. Minúsculas
  v_norm := lower(v_norm);

  -- 4. Mapear TODO dígito Unicode (blocos Nd comuns) para ASCII 0-9. O último bloco é Lao e Myanmar.
  v_de_digitos := '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹०१२३४५६७८९০১২৩৪৫৬৭৮৯੦੧੨੩੪੫੬੭੮੯૦૧૨૩૪૫૬૭૮૯୦୧୨୩୪୫୬୭୮୯௦௧௨௩௪௫௬௭௮௯౦౧౨౩౪౫౬౭౮౯೦೧೨೩೪೫೬೭೮೯൦൧൨൩൪൫൬൭൮൯๐๑๒๓๔๕๖๗๘๙'
    || U&'\0ED0\0ED1\0ED2\0ED3\0ED4\0ED5\0ED6\0ED7\0ED8\0ED9'
    || U&'\1040\1041\1042\1043\1044\1045\1046\1047\1048\1049';
  v_para_digitos := repeat('0123456789', 14);
  v_norm := translate(v_norm, v_de_digitos, v_para_digitos);

  -- 5. Transliteração de homóglifos cirílicos comuns em domínios/e-mails
  v_norm := translate(v_norm, 'асеорху', 'aceopxy');

  -- 6. Tratamento de variantes de arroba e ponto em texto (sem converter preposição 'at' em inglês)
  v_norm := regexp_replace(v_norm, '(\(at\)|\[at\]|\s+arroba\s+|[＠﹫])', '@', 'g');
  v_norm := regexp_replace(v_norm, '\s+ponto\s+', '.', 'g');

  -- 7. @ é proibido (handles de redes sociais e e-mails)
  if position('@' in v_norm) > 0 then return false; end if;

  -- 8. Chave aleatória Pix (UUID de 32 hexadecimais com ou sem hífens)
  if v_norm ~ '[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}' then return false; end if;
  if v_norm ~ '\y[0-9a-f]{32}\y' then return false; end if;

  -- 9. URLs e domínios com TLDs comuns (com ou sem esquema)
  if v_norm ~ '(https?://|www\.)[^\s]+'
     or v_norm ~ '\y(wa\.me|bit\.ly|t\.me|linktr\.ee)\y'
     or v_norm ~ '\y[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.(com\.br|com|br|net|org|site|xyz|app|link|me|io|co|tv|ly|gl|bio|shop|online|store|info|dev|cc|page|tech)\M' then
    return false;
  end if;

  -- 10. Sequências de 10 ou mais dígitos com separadores (espaço, ponto, hífen, parênteses, barra, +, _):
  -- REJEITADA SEMPRE, sem exceção por palavra vizinha (reais, R$, etc.)
  if v_norm ~ '([0-9][[:space:].\-/()+_]*){10,}' then
    return false;
  end if;

  -- 11. De 8 a 9 dígitos com palavra de contato a até 20 caracteres
  if v_norm ~ '(\y(zap|whats|whatsapp|wpp|tel|cel|celular|fone|telefone|ligue|liga|chama|contato|pix)\y[^0-9]{0,20}([0-9][[:space:].\-/()+_]*){8,9})|(([0-9][[:space:].\-/()+_]*){8,9}[^0-9]{0,20}\y(zap|whats|whatsapp|wpp|tel|cel|celular|fone|telefone|ligue|liga|chama|contato|pix)\y)' then
    return false;
  end if;

  -- 12. Dígitos e números por extenso combinados ou por extenso puros:
  -- Mascara intervalos de anos ("2019-2023", "2019 a 2023") e datas válidas ("12/05/2020") antes de
  -- checar 8+ itens. Em regex do PostgreSQL `\b` é backspace; a fronteira de palavra é `\y`.
  v_sem_anos := regexp_replace(v_norm, '(?<![0-9)+])(?<![0-9)+] )\y(19|20)\d{2}\s*(-|–|até|a)\s*(19|20)\d{2}\y', ' ', 'g');
  v_sem_anos := regexp_replace(v_sem_anos, '\y(0?[1-9]|[12][0-9]|3[01])[/.\-](0?[1-9]|1[0-2])[/.\-](19|20)\d{2}\y', ' ', 'g');
  if v_sem_anos ~ '(([0-9]|\y(zero|um|uma|dois|duas|tr[eê]s|quatro|cinco|seis|sete|oito|nove)\y)[[:space:].\-/()+_]*){8,}' then
    return false;
  end if;

  return true;
end $$;
comment on function privado.texto_sem_contato_ou_pix(text) is
 'Verdadeiro quando o texto não traz telefone, e-mail, link, @ nem chave Pix (RN38). Mapeia todo dígito Unicode Nd (inclui Lao e Myanmar) para ASCII e normaliza em NFKC antes de validar; mascara data válida e intervalo de anos na regra de 8+ dígitos. Nunca grava nem registra o texto recebido (RN15).';
revoke execute on function privado.texto_sem_contato_ou_pix(text) from public, anon, authenticated;
grant execute on function privado.texto_sem_contato_ou_pix(text) to service_role;
