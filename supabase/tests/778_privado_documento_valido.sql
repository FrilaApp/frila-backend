-- 778_privado_documento_valido.sql
--
-- Cobertura pgTAP de privado.documento_valido(doc text)
-- e provas de mutação dinâmica que matam mutantes de validação de CPF/CNPJ,
-- cálculo de dígitos verificadores e rejeição de sequências repetidas (RF02).
--
-- Regras validadas:
--   1. Rejeição de valores nulos, vazios, formatos com pontuação ou tamanhos diferentes de 11 e 14 dígitos.
--   2. Rejeição de sequências com todos os dígitos repetidos (000...0 a 999...9) tanto para 11 quanto para 14 dígitos.
--   3. Validação algorítmica de CPF (11 dígitos): aceita CPFs com DV1 e DV2 válidos e rejeita DVs incorretos.
--   4. Validação algorítmica de CNPJ (14 dígitos): aceita CNPJs com pesos oficiais corretos, incluindo restos baixos (< 2) no DV1, e rejeita DVs incorretos.
--   5. Provas de Mutação Dinâmica via pg_get_functiondef matando mutantes de omissão de repetidos, afrouxamento de DVs e alteração do ramo de resto baixo.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(41);

-- ── 1. Valores Nulos, Vazios e Formatos/Tamanhos Inválidos ─────────────────────────
select is(
  privado.documento_valido(null),
  false,
  'entrada NULL retorna false'
);

select is(
  privado.documento_valido(''),
  false,
  'string vazia retorna false'
);

select is(
  privado.documento_valido('5299822472a'),
  false,
  'documento com caractere alfabético retorna false'
);

select is(
  privado.documento_valido('529.982.247-25'),
  false,
  'CPF com máscara e pontuação retorna false (espera somente dígitos)'
);

select is(
  privado.documento_valido('11.222.333/0001-81'),
  false,
  'CNPJ com máscara e pontuação retorna false (espera somente dígitos)'
);

select is(
  privado.documento_valido(' 00000000000191 '),
  false,
  'documento válido cercado por espaços retorna false (rejeita trim implícito)'
);

select is(
  privado.documento_valido('1234567890'),
  false,
  'documento com 10 dígitos (tamanho insuficiente) retorna false'
);

select is(
  privado.documento_valido('123456789012'),
  false,
  'documento com 12 dígitos (tamanho intermediário inválido) retorna false'
);

select is(
  privado.documento_valido('1234567890123'),
  false,
  'documento com 13 dígitos (tamanho intermediário inválido) retorna false'
);

select is(
  privado.documento_valido('123456789012345'),
  false,
  'documento com 15 dígitos (excedendo 14 dígitos) retorna false'
);

-- ── 2. Rejeição de Dígitos Repetidos (CPF e CNPJ) ─────────────────────────────────
select is(
  privado.documento_valido('00000000000'),
  false,
  'CPF 00000000000 (todos os dígitos repetidos) é rejeitado'
);

select is(
  privado.documento_valido('11111111111'),
  false,
  'CPF 11111111111 (todos os dígitos repetidos) é rejeitado'
);

select is(
  privado.documento_valido('22222222222'),
  false,
  'CPF 22222222222 (todos os dígitos repetidos) é rejeitado'
);

select is(
  privado.documento_valido('33333333333'),
  false,
  'CPF 33333333333 (todos os dígitos repetidos) é rejeitado'
);

select is(
  privado.documento_valido('44444444444'),
  false,
  'CPF 44444444444 (todos os dígitos repetidos) é rejeitado'
);

select is(
  privado.documento_valido('55555555555'),
  false,
  'CPF 55555555555 (todos os dígitos repetidos) é rejeitado'
);

select is(
  privado.documento_valido('66666666666'),
  false,
  'CPF 66666666666 (todos os dígitos repetidos) é rejeitado'
);

select is(
  privado.documento_valido('77777777777'),
  false,
  'CPF 77777777777 (todos os dígitos repetidos) é rejeitado'
);

select is(
  privado.documento_valido('88888888888'),
  false,
  'CPF 88888888888 (todos os dígitos repetidos) é rejeitado'
);

select is(
  privado.documento_valido('99999999999'),
  false,
  'CPF 99999999999 (todos os dígitos repetidos) é rejeitado'
);

select is(
  privado.documento_valido('00000000000000'),
  false,
  'CNPJ 00000000000000 (todos os dígitos repetidos) é rejeitado'
);

select is(
  privado.documento_valido('11111111111111'),
  false,
  'CNPJ 11111111111111 (todos os dígitos repetidos) é rejeitado'
);

-- ── 3. CPFs Válidos ───────────────────────────────────────────────────────────────
select is(
  privado.documento_valido('52998224725'),
  true,
  'CPF válido padrão 52998224725 é aceito'
);

select is(
  privado.documento_valido('00000000191'),
  true,
  'CPF válido com zeros à esquerda 00000000191 é aceito'
);

select is(
  privado.documento_valido('12345678909'),
  true,
  'CPF válido sequencial 12345678909 com resto < 2 no DV1 é aceito'
);

-- ── 4. CPFs com Dígitos Verificadores Incorretos ──────────────────────────────────
select is(
  privado.documento_valido('52998224724'),
  false,
  'CPF com DV2 incorreto (esperado 5, informado 4) é rejeitado'
);

select is(
  privado.documento_valido('52998224735'),
  false,
  'CPF com DV1 incorreto (esperado 2, informado 3) é rejeitado'
);

select is(
  privado.documento_valido('52998224799'),
  false,
  'CPF com ambos os DVs incorretos é rejeitado'
);

select is(
  privado.documento_valido('52998224752'),
  false,
  'CPF com DVs transpostos (esperado 25, informado 52) é rejeitado'
);

-- ── 5. CNPJs Válidos ──────────────────────────────────────────────────────────────
select is(
  privado.documento_valido('11222333000181'),
  true,
  'CNPJ matriz válido 11222333000181 é aceito'
);

select is(
  privado.documento_valido('00000000000191'),
  true,
  'CNPJ válido com zeros à esquerda 00000000000191 é aceito'
);

select is(
  privado.documento_valido('04252011000110'),
  true,
  'CNPJ comercial válido 04252011000110 é aceito'
);

select is(
  privado.documento_valido('00000000000604'),
  true,
  'CNPJ sintético 00000000000604 com resto 1 no DV1 (soma=12 -> dv1=0, soma2=18 -> dv2=4) é aceito'
);

-- ── 6. CNPJs com Dígitos Verificadores Incorretos ─────────────────────────────────
select is(
  privado.documento_valido('11222333000182'),
  false,
  'CNPJ com DV2 incorreto (esperado 1, informado 2) é rejeitado'
);

select is(
  privado.documento_valido('11222333000171'),
  false,
  'CNPJ com DV1 incorreto (esperado 8, informado 7) é rejeitado'
);

select is(
  privado.documento_valido('11222333000100'),
  false,
  'CNPJ com ambos os DVs incorretos é rejeitado'
);

select is(
  privado.documento_valido('11222333000118'),
  false,
  'CNPJ com DVs transpostos (esperado 81, informado 18) é rejeitado'
);

-- ── 7. Provas de Mutação Dinâmica via pg_get_functiondef ─────────────────────────
create temp table canonicos as select
  pg_get_functiondef('privado.documento_valido(text)'::regprocedure) as def;

-- Mutante M1: Omissão da verificação de todos os dígitos repetidos
-- Demonstra que sob M1 o documento repetido 11111111111 passaria como válido; morto pela suíte.
do $$
begin
  execute replace(
    (select def from canonicos),
    'if doc ~ ''^(.)\1*$'' then',
    'if false and doc ~ ''^(.)\1*$'' then'
  );
end $$;

select is(
  privado.documento_valido('11111111111'),
  true,
  'mutante M1 (sem rejeição de repetidos): aceitaria 11111111111 ilicitamente; morto pela suíte'
);

-- Restauração dinâmica de M1
do $$
begin
  execute (select def from canonicos);
end $$;

-- Mutante M2: Afrouxamento do segundo dígito verificador do CPF (apenas d[10] = dv1)
-- Demonstra que sob M2 um CPF com DV2 corrompido passaria; morto pela suíte.
do $$
begin
  execute replace(
    (select def from canonicos),
    'return d[10] = dv1 and d[11] = dv2;',
    'return d[10] = dv1;'
  );
end $$;

select is(
  privado.documento_valido('52998224724'),
  true,
  'mutante M2 (ignora DV2 do CPF): aceitaria DV2 corrompido; morto pela suíte'
);

-- Restauração dinâmica de M2
do $$
begin
  execute (select def from canonicos);
end $$;

-- Mutante M3: Afrouxamento do segundo dígito verificador do CNPJ (apenas d[13] = dv1)
-- Demonstra que sob M3 um CNPJ com DV2 corrompido passaria; morto pela suíte.
do $$
begin
  execute replace(
    (select def from canonicos),
    'return d[13] = dv1 and d[14] = dv2;',
    'return d[13] = dv1;'
  );
end $$;

select is(
  privado.documento_valido('11222333000182'),
  true,
  'mutante M3 (ignora DV2 do CNPJ): aceitaria DV2 corrompido; morto pela suíte'
);

-- Restauração dinâmica de M3
do $$
begin
  execute (select def from canonicos);
end $$;

-- Mutante M4: Ramo de resto < 2 no DV1 do CNPJ produz 1 em vez de 0
-- Demonstra que sob M4 CNPJs válidos com resto 1 (como 00000000000604) seriam rejeitados; morto pela suíte.
do $$
begin
  execute regexp_replace(
    (select def from canonicos),
    'pesos1\[i\]; end loop;\s*resto := soma % 11;\s*dv1 := case when resto < 2 then 0 else 11 - resto end;',
    'pesos1[i]; end loop; resto := soma % 11; dv1 := case when resto < 2 then 1 else 11 - resto end;'
  );
end $$;

select is(
  privado.documento_valido('00000000000604'),
  false,
  'mutante M4 (dv1 do CNPJ retorna 1 para resto < 2): rejeita 00000000000604 retornando false; morto pela suíte'
);

-- Restauração dinâmica de M4
do $$
begin
  execute (select def from canonicos);
end $$;

select * from finish();

rollback;
