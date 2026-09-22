-- Catálogo de funções e a grade semanal de disponibilidade.
--
-- Os dois lados da elegibilidade de RN05, junto com a distância.

-- Catálogo fechado, nunca texto livre. Se o profissional digita "garçom", "garcom" e
-- "Garçonete", a elegibilidade vira busca por aproximação — e notificar quem não é
-- elegível é o erro que mata o canal de notificação, que é o produto.
create table public.funcao (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null unique,
  categoria text not null,
  ativo     boolean not null default true
);

create table public.profissional_funcao (
  profissional_id uuid not null references public.profissional(id) on delete cascade,
  funcao_id       uuid not null references public.funcao(id),
  primary key (profissional_id, funcao_id)
);

-- A grade semanal é a única fonte de disponibilidade. O "disponível agora", que abria
-- uma exceção por algumas horas, saiu do produto em 22/09.
create table public.disponibilidade (
  id              uuid primary key default gen_random_uuid(),
  profissional_id uuid not null references public.profissional(id) on delete cascade,
  dia_semana      smallint not null check (dia_semana between 0 and 6),  -- 0 = domingo
  hora_inicio     time not null,
  hora_fim        time not null,

  -- A restrição NÃO exige hora_fim > hora_inicio. Um bar fecha às 2h; a janela
  -- 18:00–02:00 é a mais comum do setor, não uma exceção. Quem escreve
  -- CHECK (hora_fim > hora_inicio) por reflexo exclui do produto justamente o turno
  -- que ele existe para preencher.
  constraint janela_nao_vazia check (hora_inicio <> hora_fim),

  unique (profissional_id, dia_semana, hora_inicio, hora_fim)
);
