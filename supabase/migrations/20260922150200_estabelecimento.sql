-- Estabelecimento, quem opera por ele e a equipe de confiança.
--
-- A conta é separada do papel porque o histórico do estabelecimento precisa
-- sobreviver à troca de responsável (RF21): o maître sai, o bar continua.

create type public.tipo_estabelecimento as enum
  ('food_service', 'evento', 'varejo', 'logistica', 'servico_domestico', 'outro');

create type public.papel_membro as enum ('administrador', 'operador');

create table public.estabelecimento (
  id             uuid primary key default gen_random_uuid(),
  nome           text not null,
  -- CNPJ (14) ou CPF (11), só dígitos. Aceita CPF porque serviço doméstico também
  -- contrata pelo Frila.
  documento      text not null unique
                   check (documento ~ '^([0-9]{11}|[0-9]{14})$'),
  -- A plataforma é horizontal (A01, A15): `tipo` serve para leitura e filtro, nunca
  -- para barrar ninguém. 'outro' existe para que nenhum negócio fique de fora por
  -- falta de categoria.
  tipo           public.tipo_estabelecimento not null,
  endereco       text not null,
  ponto          extensions.geography(Point, 4326) not null,
  criado_em      timestamptz not null default now(),
  -- O estabelecimento tem reputação própria porque RN07 manda avaliar nos dois
  -- sentidos. É a correção de assimetria que o produto usa contra o setor inteiro:
  -- em todo concorrente pesquisado só o contratante avalia, e as piores notas vêm
  -- de quem trabalha.
  aval_positivas integer not null default 0,
  aval_total     integer not null default 0,

  constraint estabelecimento_aval_coerente check (aval_positivas <= aval_total)
);

create table public.membro_estabelecimento (
  id                 uuid primary key default gen_random_uuid(),
  usuario_id         uuid not null,
  perfil             public.perfil_conta not null default 'contratante'
                       check (perfil = 'contratante'),
  estabelecimento_id uuid not null references public.estabelecimento(id),
  papel              public.papel_membro not null,
  criado_em          timestamptz not null default now(),

  unique (usuario_id, estabelecimento_id),
  constraint so_conta_de_contratante
    foreign key (usuario_id, perfil) references public.usuario (id, perfil)
);

-- Não muda a ordem de ninguém — não existe ordem (RN06). Muda QUEM recebe: o
-- profissional da equipe é notificado das vagas daquele estabelecimento mesmo além
-- dos 15 km, desde que tenha a função e esteja disponível (RF18).
create table public.equipe_confianca (
  estabelecimento_id uuid not null references public.estabelecimento(id),
  profissional_id    uuid not null references public.profissional(id),
  adicionado_em      timestamptz not null default now(),
  primary key (estabelecimento_id, profissional_id)
);
