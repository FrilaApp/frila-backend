-- 20261014160000_recusar_contato_e_link_texto_vaga.sql
--
-- Cartão J5 (pBXTS4vv): Recusar telefone, e-mail e link no texto livre da vaga (RN10, decisão J5).
-- A regra de negócio RN10 estabelece que dados de contato entre contratante e
-- profissional só devem ser liberados após a confirmação do turno (via contato_do_turno).
-- Textos livres em publicar_vaga/republicar_vaga (e cadastrar_estabelecimento) são validados
-- contra padrões de contato/link para evitar burlar essa proteção.
--
-- Critérios (LGPD / RN15):
-- 1. A recusa NÃO grava o texto digitado em log nem em ocorrência.
-- 2. Recusa com 422 campo_invalido e o nome do campo específico em details.
-- 3. Trata falsos positivos legítimos (horários, valores monetários, CEP, numeração de endereço, datas).

create or replace function privado.contem_contato_ou_link(t text)
returns boolean
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v_limpo text;
begin
  if t is null or t = '' then
    return false;
  end if;

  -- 1. E-mail: padrão com @ seguido de domínio com ponto
  if t ~* '[a-z0-9._%+-]+\s*@\s*[a-z0-9.-]+\.[a-z]{2,}' then
    return true;
  end if;

  -- 2. Links e URLs: http://, https://, www., encurtadores e domínios com TLDs comuns
  if t ~* '(https?://|www\.)[^\s]+'
     or t ~* '\y(wa\.me|bit\.ly|t\.me|linktr\.ee)\y'
     or t ~* '\y[a-z0-9.-]+\.(com\.br|com|net|org|app|io|me|link|site|online|dev|co)\M([/?#][^\s]*)?' then
    return true;
  end if;

  -- 3. Telefone / WhatsApp: sequências de 8 ou mais dígitos (mesmo com espaços, pontos, barras e hífens).
  -- Mascara falsos positivos legítimos antes da contagem de dígitos:
  -- - Datas (ex: 15/10/2026, 15-10-2026, 15.10.2026, 2026-10-15)
  -- - CEP (ex: CEP 70000-000, 70000-000, CEP 70000000)
  -- - Valores monetários (ex: R$ 1.200,00, R$ 80,00, 150 reais)
  -- - Horários e períodos (ex: 14:00, das 14:00 às 22:00, 14:00-22:00)
  v_limpo := regexp_replace(t, '\y\d{1,2}[/\.-]\d{1,2}[/\.-]\d{2,4}\y', ' ', 'g');
  v_limpo := regexp_replace(v_limpo, '\y\d{4}[/\.-]\d{1,2}[/\.-]\d{1,2}\y', ' ', 'g');
  v_limpo := regexp_replace(v_limpo, '\y(CEP\s*:?\s*\d{5}[-.]?\d{3}|\d{5}[-.]\d{3})\y', ' ', 'gi');
  v_limpo := regexp_replace(v_limpo, 'R\$\s*\d+([.,]\d+)*', ' ', 'gi');
  v_limpo := regexp_replace(v_limpo, '\y\d+([.,]\d+)*\s*reais\y', ' ', 'gi');
  v_limpo := regexp_replace(v_limpo, '\y\d{1,2}:\d{2}(\s*([–\-\/]|às|a)\s*\d{1,2}:\d{2})?\y', ' ', 'gi');

  if v_limpo ~ '(\d[[:space:].\-/()]*){8}' then
    return true;
  end if;

  return false;
end $$;

comment on function privado.contem_contato_ou_link(text) is
  'Verdadeiro quando o texto contém telefone/WhatsApp (8+ dígitos com separadores), e-mail (@ + domínio) ou URL/link (http, www ou TLD comum), protegendo a RN10 (decisão J5, cartão pBXTS4vv).';

revoke execute on function privado.contem_contato_ou_link(text) from public, anon, authenticated;
grant  execute on function privado.contem_contato_ou_link(text) to service_role;

-- Atualiza privado.exigir_texto_aceitavel para verificar tanto termos ofensivos quanto contato/links
create or replace function privado.exigir_texto_aceitavel(campos jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  k text;
  v text;
begin
  for k in select jsonb_object_keys(campos) loop
    v := campos->>k;
    if not privado.texto_aceitavel(v) then
      perform public.erro(422, 'campo_invalido', k);
    end if;
    if privado.contem_contato_ou_link(v) then
      perform public.erro(422, 'campo_invalido', k);
    end if;
  end loop;
end $$;

comment on function privado.exigir_texto_aceitavel(jsonb) is
  'Recusa com 422 campo_invalido o primeiro campo cujo texto contenha termo bloqueado (diretriz 1.2) ou dados de contato/links (RN10, decisão J5). A chave do jsonb é o nome que vai em details.';
