-- Índices do caminho quente com o volume do Distrito Federal simulado (RNF11, RNF01, RNF03).
-- Cartão IYAb8v1i.
--
-- No volume da praça-piloto (30 mil estabelecimentos, 100 mil profissionais, 20 mil vagas),
-- as leituras críticas `vagas_abertas` e `privado.elegiveis` precisam responder abaixo
-- de 300 ms sem varredura sequencial em tabelas grandes.
--
-- 1. `vaga_data_publicada`: índice funcional parcial sobre a data no fuso de Brasília.
--    Evita Seq Scan em `public.vaga` quando o profissional filtra turnos por dia.

create index if not exists vaga_data_publicada
  on public.vaga ((((inicio_em at time zone 'America/Sao_Paulo')::date)))
  where estado = 'publicada';

comment on index public.vaga_data_publicada is
  'Índice funcional parcial para filtro por data em vagas_abertas (RNF11). Evita varredura sequencial na tabela vaga.';

