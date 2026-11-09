-- Reforço do filtro de contato e Pix, v2 (cartão oU0Wl3hI · RN38).
--
-- Quatro ajustes em privado.texto_sem_contato_ou_pix, sobre a definição de 20261107330000:
--
-- 1. Dígitos Lao (U+0ED0-0ED9) e Myanmar (U+1040-1049) entram na tabela de transliteração para 0-9.
--    Eram Nd fora dos 12 blocos mapeados: "໖໑໙໘໘໘໘໗໗໗໗" passava por não ter nenhum dígito ASCII.
-- 2. `.tech` entra na lista de TLDs de domínio.
-- 3. Data normal ("12/05/2020", "01-10-2022") deixa de ser contada como número de telefone na regra
--    de 8 ou mais itens. A regra 12 passou a avaliar CORRIDAS de itens (dígitos e números por extenso
--    com separadores): uma corrida que é só uma data VÁLIDA (dia 1-31, mês 1-12, ano 19xx ou 20xx)
--    é a única exceção. Data colada a outro dígito ou a número por extenso ("nove 12/05/2020",
--    "seis um nove 12/05/2020") continua barrada, e número de 8 dígitos formatado como "99.88.7766"
--    ou "61.99.8765" não é data e segue barrado. Uma primeira versão mascarava a data antes de
--    contar e deixava passar esses textos; o Lince apontou o furo no PR #446.
-- 4. A regra 10 (10 ou mais itens) passa a contar também números por extenso, sem máscara de data.
--    A regra 11 (palavra de contato por perto) olha o texto sem máscara: "zap 12/05/2020" é barrado.
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
  v_corrida text;
begin
  if texto is null or texto = '' then return true; end if;

  -- 1. Normalização Unicode NFKC (decompõe e recompõe para forma canônica de compatibilidade)
  v_norm := normalize(texto, NFKC);

  -- 2. Remoção de caracteres invisíveis e de formatação (U+200B-U+200F, U+2028-U+202F, U+2060-U+206F, U+FE00-U+FE0F, U+FEFF, U+00AD, U+180E)
  v_norm := regexp_replace(v_norm, '[​-‏ - ⁠-⁯︀-️﻿­᠎]', '', 'g');

  -- 3. Minúsculas
  v_norm := lower(v_norm);

  -- 4. Mapear para ASCII 0-9 os dígitos de 14 blocos Unicode: árabe-índico, persa, devanágari, bengali,
  -- gurmukhi, gujarati, oriá, tâmil, telugu, canarês, malaiala, tailandês, lao e myanmar. Outros blocos
  -- Nd (por exemplo tibetano, khmer e mongol) NÃO são mapeados.
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

  -- 10. Sequências de 10 ou mais itens, dígitos ou números por extenso, com separadores (espaço, ponto,
  -- hífen, parênteses, barra, +, _): REJEITADA SEMPRE, sem exceção por palavra vizinha (reais, R$, etc.)
  -- e SEM máscara de data. Contar só dígitos deixava passar "seis um nove 12/05/2020" quando a data
  -- passou a ser mascarada na regra 12 (parecer do Lince no PR #446).
  if v_norm ~ '(([0-9]|\y(zero|um|uma|dois|duas|tr[eê]s|quatro|cinco|seis|sete|oito|nove)\y)[[:space:].\-/()+_]*){10,}' then
    return false;
  end if;

  -- 11. De 8 a 9 dígitos com palavra de contato a até 20 caracteres
  if v_norm ~ '(\y(zap|whats|whatsapp|wpp|tel|cel|celular|fone|telefone|ligue|liga|chama|contato|pix)\y[^0-9]{0,20}([0-9][[:space:].\-/()+_]*){8,9})|(([0-9][[:space:].\-/()+_]*){8,9}[^0-9]{0,20}\y(zap|whats|whatsapp|wpp|tel|cel|celular|fone|telefone|ligue|liga|chama|contato|pix)\y)' then
    return false;
  end if;

  -- 12. Corridas de 8 ou mais itens (dígitos e números por extenso) com separadores.
  -- Intervalos de anos ("2019-2023", "2019 a 2023") são mascarados antes. Uma corrida que é SÓ uma data
  -- válida ("12/05/2020") é a única exceção: ela é avaliada inteira, e uma data colada a outro dígito ou
  -- a um número por extenso ("nove 12/05/2020", "seis um nove 12/05/2020") continua barrada, porque é
  -- assim que um telefone se disfarça de data. Em regex do PostgreSQL `\b` é backspace; a fronteira de
  -- palavra é `\y`.
  v_sem_anos := regexp_replace(v_norm, '(?<![0-9)+])(?<![0-9)+] )\y(19|20)\d{2}\s*(-|–|até|a)\s*(19|20)\d{2}\y', ' ', 'g');
  for v_corrida in
    select m[1]
      from regexp_matches(v_sem_anos,
        '((?:(?:[0-9]|\y(?:zero|um|uma|dois|duas|tr[eê]s|quatro|cinco|seis|sete|oito|nove)\y)[[:space:].\-/()+_]*){8,})', 'g') m
  loop
    if v_corrida !~ '^(0[1-9]|[12][0-9]|3[01])[/.\-](0[1-9]|1[0-2])[/.\-](19|20)[0-9]{2}[[:space:].\-/()+_]*$' then
      return false;
    end if;
  end loop;

  return true;
end $$;
comment on function privado.texto_sem_contato_ou_pix(text) is
 'Verdadeiro quando o texto não traz telefone, e-mail, link, @ nem chave Pix (RN38). Mapeia para ASCII os dígitos de 14 blocos Unicode (inclui Lao e Myanmar; outros blocos Nd não são mapeados) e normaliza em NFKC antes de validar; mascara intervalo de anos e aceita uma corrida de 8+ itens só se ela for uma data válida inteira. Nunca grava nem registra o texto recebido (RN15).';
revoke execute on function privado.texto_sem_contato_ou_pix(text) from public, anon, authenticated;
grant execute on function privado.texto_sem_contato_ou_pix(text) to service_role;
