-- Validação das constraints de apresentacao, onde_trabalhei, experiencia_faixa, cursos e idiomas (B3b).
-- Valida as constraints previamente adicionadas com NOT VALID em 20261107110000,
-- evitando retenção prolongada de AccessExclusiveLock em tabelas com volume.

set lock_timeout = '2s';

alter table public.profissional validate constraint profissional_apresentacao_check;
alter table public.profissional validate constraint profissional_onde_trabalhei_check;
alter table public.profissional validate constraint profissional_experiencia_faixa_check;
alter table public.profissional validate constraint profissional_cursos_check;
alter table public.profissional validate constraint profissional_idiomas_check;
