-- 777_privado_contem_contato_ou_link.sql
--
-- Cobertura pgTAP de privado.contem_contato_ou_link(t text)
-- e provas de mutação dinâmica que matam mutantes de omissão de telefone,
-- encurtadores de links, e-mail genérico e filtros de falsos positivos (RN10, RN15, RF02).
--
-- Defeitos preexistentes identificados na revisão R-002 (Lince), preservados sem alteração de código:
--   1. CEP com ponto de milhar ('CEP 70.000-000'): classificado indevidamente como contato (true)
--      porque a regex em 20261014160000:53 espera '\d{5}[-.]?\d{3}' e não cobre '\d{2}\.\d{3}'.
--   2. CEP com espaço ('CEP 70000 000'): classificado indevidamente como contato (true)
--      pois a regex não prevê espaço entre os blocos numéricos do CEP.
--   3. Data e hora ISO com 'T' ('Evento 2026-10-29T14:30:00-03:00'): classificada indevidamente
--      como contato (true) porque o separador 'T' impede o limite de palavra (\y) após o dia,
--      sobrando a sequência numérica da data para o detector de telefone.
--   4. Ambiguidade de heurística ('Código do pedido 1234-5678'): oito dígitos com hífen
--      aciona o detector de telefone (decisão de produto necessária para não criar bypass).
--
-- Regras validadas:
--   1. Casos neutros: NULL, string vazia e texto livre sem dados de contato retornam false.
--   2. Detecção de telefones e WhatsApp (8+ dígitos com máscaras, espaços, barras e pontos) retorna true.
--   3. Detecção de endereços de e-mail (com @ e domínios com ponto, inclusive TLDs genéricos como .test) retorna true.
--   4. Detecção de URLs, links diretos e encurtadores (http, https, www, wa.me, bit.ly, t.me, linktr.ee, TLDs comuns) retorna true.
--   5. Imunidade contra falsos positivos legítimos (UUIDs, datas com barra/hífen/ponto/ISO, CEPs, valores monetários em R$ incluindo 8+ dígitos e reais, horários e períodos) retornam false.
--   6. Provas de Mutação Dinâmica via pg_get_functiondef comprovando que mutantes divergem do comportamento canônico e são mortos pela suíte.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(47);

-- ── 1. Casos Neutros e Nulos ──────────────────────────────────────────────────────
select is(
  privado.contem_contato_ou_link(null),
  false,
  'entrada NULL retorna false'
);

select is(
  privado.contem_contato_ou_link(''),
  false,
  'string vazia retorna false'
);

select is(
  privado.contem_contato_ou_link('Vaga para garçom com experiência em atendimento de salão e bandeja.'),
  false,
  'texto descritivo comum sem contato retorna false'
);

-- ── 2. Telefones e WhatsApp ───────────────────────────────────────────────────────
select is(
  privado.contem_contato_ou_link('Chame no (61) 98765-4321 para combinar'),
  true,
  'telefone celular com DDD e formatação padrão é detectado'
);

select is(
  privado.contem_contato_ou_link('Contato direto 61987654321 falar com gerente'),
  true,
  'telefone celular contínuo de 11 dígitos sem formatação é detectado'
);

select is(
  privado.contem_contato_ou_link('Telefone fixo da recepção (61) 3321-1234'),
  true,
  'telefone fixo com DDD é detectado'
);

select is(
  privado.contem_contato_ou_link('Celular 9 8 7 6 5 4 3 2 1 envie mensagem'),
  true,
  'número com dígitos separados por espaços é detectado'
);

select is(
  privado.contem_contato_ou_link('Número local 98765-4321 disponível'),
  true,
  'número de 8 dígitos com hífen sem DDD é detectado'
);

select is(
  privado.contem_contato_ou_link('Plantão 61/98765.4321 chamar urgente'),
  true,
  'número com barras e pontos é detectado'
);

-- ── 3. Endereços de E-mail ────────────────────────────────────────────────────────
select is(
  privado.contem_contato_ou_link('Envie seu currículo para contato@frila.com.br'),
  true,
  'e-mail padrão com domínio .com.br é detectado'
);

select is(
  privado.contem_contato_ou_link('Contato em vagas+corporativo@restaurante.com'),
  true,
  'e-mail com sub-endereçamento (+) e domínio .com é detectado'
);

select is(
  privado.contem_contato_ou_link('Mande para financeiro @ bar.net hoje'),
  true,
  'e-mail com espaçamento ao redor do @ é detectado'
);

select is(
  privado.contem_contato_ou_link('Envie candidatura para vagas@exemplo.test'),
  true,
  'e-mail com TLD genérico (.test) não coberto por regras de link é detectado pela condição de e-mail'
);

-- ── 4. Links, URLs e Encurtadores ─────────────────────────────────────────────────
select is(
  privado.contem_contato_ou_link('Acesse nossa página https://frila.com.br/vagas'),
  true,
  'URL completa com https:// é detectada'
);

select is(
  privado.contem_contato_ou_link('Site do evento http://restaurante.com/info'),
  true,
  'URL completa com http:// é detectada'
);

select is(
  privado.contem_contato_ou_link('Veja os detalhes em www.eventofrila.com'),
  true,
  'endereço iniciado com www. é detectado'
);

select is(
  privado.contem_contato_ou_link('Fale no wa.me/chatfrila para mais dados'),
  true,
  'link do WhatsApp wa.me é detectado'
);

select is(
  privado.contem_contato_ou_link('Inscrições em bit.ly/vaga-extra-hoje'),
  true,
  'link encurtado bit.ly é detectado'
);

select is(
  privado.contem_contato_ou_link('Grupo no t.me/frilabr oficial'),
  true,
  'link do Telegram t.me é detectado'
);

select is(
  privado.contem_contato_ou_link('Cardápio em linktr.ee/restaurantedf'),
  true,
  'link linktr.ee é detectado'
);

select is(
  privado.contem_contato_ou_link('Confira em restobar.com.br/menu a escala'),
  true,
  'domínio .com.br sem esquema http é detectado'
);

select is(
  privado.contem_contato_ou_link('Acesse o aplicativo menu.app/cadastro'),
  true,
  'domínio com TLD moderno .app é detectado'
);

select is(
  privado.contem_contato_ou_link('Consulte pedidos.online com o código'),
  true,
  'domínio com TLD .online é detectado'
);

-- ── 5. Falsos Positivos Legítimos (NÃO podem ser barrados) ─────────────────────────
select is(
  privado.contem_contato_ou_link('Referência da vaga: 4ffd2bd3-3c19-4a1a-bc7d-4f7256348732 no sistema'),
  false,
  'falso positivo: UUID de 36 caracteres não é barrado como contato'
);

select is(
  privado.contem_contato_ou_link('Turno programado para o dia 15/10/2026 no salão nobre'),
  false,
  'falso positivo: data com barras e ano de 4 dígitos não é barrada'
);

select is(
  privado.contem_contato_ou_link('Treinamento obrigatório em 15/10/26 às 14h'),
  false,
  'falso positivo: data com barras e ano de 2 dígitos não é barrada'
);

select is(
  privado.contem_contato_ou_link('Início do evento previsto para 15-10-2026 sem atrasos'),
  false,
  'falso positivo: data separada por hífens não é barrada'
);

select is(
  privado.contem_contato_ou_link('Apresentação dos candidatos em 15.10.2026'),
  false,
  'falso positivo: data separada por pontos não é barrada'
);

select is(
  privado.contem_contato_ou_link('Data de emissão do contrato: 2026-10-15 no registro'),
  false,
  'falso positivo: data no padrão ISO (YYYY-MM-DD) não é barrada'
);

select is(
  privado.contem_contato_ou_link('Local do evento fica no CEP 70000-000 em Brasília'),
  false,
  'falso positivo: CEP com prefixo CEP e hífen não é barrado'
);

select is(
  privado.contem_contato_ou_link('Endereço de entrega: 70000-000 Asa Sul'),
  false,
  'falso positivo: CEP sem palavra CEP apenas com hífen não é barrado'
);

select is(
  privado.contem_contato_ou_link('Localização da empresa CEP: 70000-000 Asa Norte'),
  false,
  'falso positivo: CEP com dois pontos e hífen não é barrado'
);

select is(
  privado.contem_contato_ou_link('Próximo à estação central CEP 70000000'),
  false,
  'falso positivo: CEP com prefixo CEP e dígitos contínuos não é barrado'
);

select is(
  privado.contem_contato_ou_link('Remuneração da diária: R$ 1.200,00 com refeição'),
  false,
  'falso positivo: valor monetário formatado com milhar e centavos não é barrado'
);

select is(
  privado.contem_contato_ou_link('Ajuda de custo transporte: R$ 80,00 paga no dia'),
  false,
  'falso positivo: valor monetário simples em R$ não é barrado'
);

select is(
  privado.contem_contato_ou_link('Orçamento R$ 12345678,90'),
  false,
  'falso positivo: valor monetário em R$ com 8+ dígitos não é barrado como telefone (exercita a máscara R$)'
);

select is(
  privado.contem_contato_ou_link('Valor acordado: 150 reais ao término do expediente'),
  false,
  'falso positivo: valor com sufixo reais por extenso não é barrado'
);

select is(
  privado.contem_contato_ou_link('Orçamento 12345678,90 reais'),
  false,
  'falso positivo: valor monetário com sufixo reais e 8+ dígitos não é barrado como telefone (exercita a máscara reais)'
);

select is(
  privado.contem_contato_ou_link('Turno das 14:00 às 22:00 com 1 hora de descanso'),
  false,
  'falso positivo: intervalo de horários com dois pontos (hh:mm às hh:mm) não é barrado'
);

select is(
  privado.contem_contato_ou_link('Horário da escala: 18h30 às 23h30'),
  false,
  'falso positivo: intervalo de horários com h (18h30 às 23h30) não é barrado'
);

select is(
  privado.contem_contato_ou_link('Chegada pontual às 18h no setor de credenciamento'),
  false,
  'falso positivo: horário simples com h (18h) não é barrado'
);

select is(
  privado.contem_contato_ou_link('Turno dia 25/11/2026 das 14:00 às 22:00, cachê de R$ 250,00, CEP 70000-000'),
  false,
  'falso positivo: combinação com data, horário, valor monetário e CEP no mesmo texto não é barrada'
);

-- ── 6. Provas de Mutação Dinâmica via pg_get_functiondef ─────────────────────────
create temp table canonicos as select
  pg_get_functiondef('privado.contem_contato_ou_link(text)'::regprocedure) as def;

-- Mutante M1: Omissão da verificação de telefone (substituída por if false)
-- Demonstra que sob M1 o número de telefone passaria indetectado; morto pela suíte.
do $$
begin
  execute replace(
    (select def from canonicos),
    'if v_limpo ~ ''(\d[[:space:].\-/()]*){8}'' then',
    'if false and v_limpo ~ ''(\d[[:space:].\-/()]*){8}'' then'
  );
end $$;

select is(
  privado.contem_contato_ou_link('Chame no (61) 98765-4321 para combinar'),
  false,
  'mutante M1 (sem checagem de telefone): deixa telefone vazar retornando false; morto pela suíte'
);

-- Restauração dinâmica de M1
do $$
begin
  execute (select def from canonicos);
end $$;

-- Mutante M2: Omissão da limpeza de falso positivo de CEP
-- Demonstra que sob M2 o CEP seria erroneamente marcado como telefone (falso positivo indevido).
do $$
begin
  execute replace(
    (select def from canonicos),
    'v_limpo := regexp_replace(v_limpo, ''\y(CEP\s*:?\s*\d{5}[-.]?\d{3}|\d{5}[-.]\d{3})\y'', '' '', ''gi'');',
    '-- sem limpeza de cep'
  );
end $$;

select is(
  privado.contem_contato_ou_link('Endereço de entrega: 70000-000 Asa Sul'),
  true,
  'mutante M2 (sem filtro de CEP): gera falso positivo indevido retornando true; morto pela suíte'
);

-- Restauração dinâmica de M2
do $$
begin
  execute (select def from canonicos);
end $$;

-- Mutante M3: Omissão da detecção de encurtadores wa.me e bit.ly
-- Demonstra que sob M3 encurtadores passariam ilesos retornando false.
do $$
begin
  execute replace(
    (select def from canonicos),
    'or t ~* ''\y(wa\.me|bit\.ly|t\.me|linktr\.ee)\y''',
    'or false'
  );
end $$;

select is(
  privado.contem_contato_ou_link('Inscrições em bit.ly/vaga-extra-hoje'),
  false,
  'mutante M3 (sem wa.me/bit.ly): deixa link encurtado vazar retornando false; morto pela suíte'
);

-- Restauração dinâmica de M3
do $$
begin
  execute (select def from canonicos);
end $$;

-- Mutante M4: Omissão da condição de e-mail
-- Demonstra que sob M4 e-mails com TLDs genéricos não cobertos por links passam ilesos.
do $$
begin
  execute replace(
    (select def from canonicos),
    'if t ~* ''[a-z0-9._%+-]+\s*@\s*[a-z0-9.-]+\.[a-z]{2,}'' then',
    'if false and t ~* ''[a-z0-9._%+-]+\s*@\s*[a-z0-9.-]+\.[a-z]{2,}'' then'
  );
end $$;

select is(
  privado.contem_contato_ou_link('Envie candidatura para vagas@exemplo.test'),
  false,
  'mutante M4 (sem regra de e-mail): deixa e-mail .test vazar retornando false; morto pela suíte'
);

-- Restauração dinâmica de M4
do $$
begin
  execute (select def from canonicos);
end $$;

-- Mutante M5: Omissão da máscara de valor monetário R$
-- Demonstra que sob M5 valores com 8+ dígitos acionam indevidamente o detector de telefone.
do $$
begin
  execute replace(
    (select def from canonicos),
    'v_limpo := regexp_replace(v_limpo, ''R\$\s*\d+([.,]\d+)*'', '' '', ''gi'');',
    '-- sem mascara R$'
  );
end $$;

select is(
  privado.contem_contato_ou_link('Orçamento R$ 12345678,90'),
  true,
  'mutante M5 (sem mascara R$): valor de 8+ digitos vira falso positivo como telefone retornando true; morto pela suite'
);

-- Restauração dinâmica de M5
do $$
begin
  execute (select def from canonicos);
end $$;

select * from finish();

rollback;
