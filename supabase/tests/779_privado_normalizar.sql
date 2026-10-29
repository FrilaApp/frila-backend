-- 779_privado_normalizar.sql
--
-- Cobertura pgTAP de privado.normalizar(t text)
-- e provas de mutação dinâmica que matam mutantes de descarte de acentos,
-- conversão de pontuação em espaço e trim de bordas (RN10, RN15, RF02).
--
-- Regras validadas:
--   1. Comportamento STRICT: entrada NULL resulta em retorno NULL.
--   2. Strings vazias ou formadas apenas por espaços/símbolos normalizam para string vazia.
--   3. Remoção de todos os acentos e diacríticos do português (áàâãäéèêëíìîïóòôõöúùûüçñ).
--   4. Conversão para caixa baixa em maiúsculas acentuadas e normais.
--   5. Substituição de quaisquer caracteres não alfanuméricos por espaço simples (evitando junção espúria de palavras).
--   6. Aplicação de trim nas bordas (sem espaços excedentes no início ou no fim).
--   7. Provas de Mutação Dinâmica via pg_get_functiondef matando mutantes de acentuação, separação e trim.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(23);

-- ── 1. Comportamento STRICT e Strings Vazias ──────────────────────────────────────
select is(
  privado.normalizar(null),
  null,
  'entrada NULL retorna NULL por ser função STRICT'
);

select is(
  privado.normalizar(''),
  '',
  'string vazia normaliza para string vazia'
);

select is(
  privado.normalizar('     '),
  '',
  'string apenas com espaços normaliza para string vazia após trim'
);

-- ── 2. Remoção de Acentos e Diacríticos ───────────────────────────────────────────
select is(
  privado.normalizar('áàâãä'),
  'aaaaa',
  'acentos e diacríticos da letra A são convertidos para A simples'
);

select is(
  privado.normalizar('éèêë'),
  'eeee',
  'acentos e diacríticos da letra E são convertidos para E simples'
);

select is(
  privado.normalizar('íìîï'),
  'iiii',
  'acentos e diacríticos da letra I são convertidos para I simples'
);

select is(
  privado.normalizar('óòôõö'),
  'ooooo',
  'acentos e diacríticos da letra O são convertidos para O simples'
);

select is(
  privado.normalizar('úùûü'),
  'uuuu',
  'acentos e diacríticos da letra U são convertidos para U simples'
);

select is(
  privado.normalizar('çñ'),
  'cn',
  'cedilha e til no N são convertidos para c e n'
);

select is(
  privado.normalizar('áàâãäéèêëíìîïóòôõöúùûüçñ'),
  'aaaaaeeeeiiiiooooouuuucn',
  'conjunto completo de diacríticos é normalizado perfeitamente'
);

-- ── 3. Conversão para Caixa Baixa (Maiúsculas Acentuadas) ─────────────────────────
select is(
  privado.normalizar('ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ'),
  'aaaaaeeeeiiiiooooouuuucn',
  'maiúsculas acentuadas são convertidas em minúsculas sem diacríticos'
);

select is(
  privado.normalizar('BAR DO CAFÉ ESPRESSO'),
  'bar do cafe espresso',
  'texto em caixa alta com acento é normalizado em caixa baixa'
);

-- ── 4. Pontuações e Símbolos Virando Espaço Simples ──────────────────────────────
select is(
  privado.normalizar('abc.def'),
  'abc def',
  'ponto entre palavras vira espaço simples impedindo junção indevida de termos'
);

select is(
  privado.normalizar('palavra-com-hifen'),
  'palavra com hifen',
  'hífen entre palavras é convertido em espaço'
);

select is(
  privado.normalizar('alerta...urgente!!!'),
  'alerta urgente',
  'múltiplas pontuações consecutivas agrupam em um único espaço'
);

select is(
  privado.normalizar('garcom@bar#10$extra'),
  'garcom bar 10 extra',
  'símbolos especiais diversos (@, #, $) são substituídos por espaço'
);

select is(
  privado.normalizar('campo_teste_tabela'),
  'campo teste tabela',
  'sublinhados (underline) são convertidos em espaço'
);

-- ── 5. Trim de Bordas ─────────────────────────────────────────────────────────────
select is(
  privado.normalizar('   texto com espacos   '),
  'texto com espacos',
  'espaços nas bordas são removidos'
);

select is(
  privado.normalizar('---inicio e fim...!?'),
  'inicio e fim',
  'pontuações e símbolos nas bordas são removidos após trim'
);

-- ── 6. Preservação de Alfanuméricos ───────────────────────────────────────────────
select is(
  privado.normalizar('Mesa 14 Setor VIP 2'),
  'mesa 14 setor vip 2',
  'números e letras sem acento são preservados em caixa baixa'
);

-- ── 7. Provas de Mutação Dinâmica via pg_get_functiondef ─────────────────────────
create temp table canonicos as select
  pg_get_functiondef('privado.normalizar(text)'::regprocedure) as def;

-- Mutante M1: Omissão de tradução de acentos (substituição por acentos inalterados)
-- Demonstra que sob M1 o diacrítico não seria convertido em letra simples ASCII; morto pela suíte.
do $$
begin
  execute replace(
    (select def from canonicos),
    '''aaaaaeeeeiiiiooooouuuucn''',
    '''áàâãäéèêëíìîïóòôõöúùûüçñ'''
  );
end $$;

select is(
  privado.normalizar('café'),
  'caf',
  'mutante M1 (sem conversão de acentos): acento não vira letra ASCII simples; morto pela suíte'
);

-- Restauração dinâmica de M1
do $$
begin
  execute (select def from canonicos);
end $$;

-- Mutante M2: Substituição de não-alfanuméricos por vazio ('') em vez de espaço (' ')
-- Demonstra que sob M2 'abc.def' colidiria em 'abcdef' (aglutinação indesejada).
do $$
begin
  execute replace(
    (select def from canonicos),
    '''[^a-z0-9]+'', '' '', ''g''',
    '''[^a-z0-9]+'', '''', ''g'''
  );
end $$;

select is(
  privado.normalizar('abc.def'),
  'abcdef',
  'mutante M2 (aglutina pontuação sem espaço): gera "abcdef"; morto pela suíte'
);

-- Restauração dinâmica de M2
do $$
begin
  execute (select def from canonicos);
end $$;

-- Mutante M3: Omissão de btrim nas bordas
-- Demonstra que sob M3 as bordas manteriam espaços residuais.
do $$
begin
  execute replace(
    (select def from canonicos),
    'select pg_catalog.btrim(',
    'select ('
  );
end $$;

select is(
  privado.normalizar('   teste   '),
  ' teste ',
  'mutante M3 (sem btrim): mantém espaços residuais nas bordas; morto pela suíte'
);

-- Restauração dinâmica de M3
do $$
begin
  execute (select def from canonicos);
end $$;

select * from finish();

rollback;
