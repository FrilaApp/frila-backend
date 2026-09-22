-- Vaga, posição e evento: o eixo do produto.
--
-- A cadeia é vaga → posicao → turno → avaliacao. `posicoes` é o número pedido na
-- publicação; a função que publica cria uma linha de `posicao` por unidade.

create type public.modo_preenchimento as enum ('urgencia', 'selecao');
create type public.estado_vaga        as enum ('publicada', 'preenchida', 'encerrada', 'cancelada');
create type public.estado_posicao     as enum ('aberta', 'confirmada', 'cumprida', 'cancelada');

-- Só a escala em lote (RF19) agrupa vagas; por isso `vaga.evento_id` é nulo na maioria
-- dos casos. Forçar todo turno urgente de sexta a inventar um evento seria burocracia
-- inventada pelo esquema.
create table public.evento (
  id                 uuid primary key default gen_random_uuid(),
  estabelecimento_id uuid not null references public.estabelecimento(id),
  nome               text not null,
  data               date not null,
  local              text not null
);

create table public.vaga (
  id                     uuid primary key default gen_random_uuid(),
  estabelecimento_id     uuid not null references public.estabelecimento(id),
  evento_id              uuid references public.evento(id),
  funcao_id              uuid not null references public.funcao(id),
  inicio_em              timestamptz not null,
  fim_em                 timestamptz not null,
  local                  text not null,
  ponto                  extensions.geography(Point, 4326) not null,
  -- RN18: centavo inteiro não acumula erro de arredondamento, e bigint não estoura
  -- em escala de evento — quarenta posições de uma formatura somadas cabem com folga.
  valor_centavos         bigint  not null check (valor_centavos > 0),
  posicoes               smallint not null check (posicoes between 1 and 200),

  -- RN02 escrita em SQL. Boolean e não texto: marcar sim ou não é um toque cada,
  -- mantém a publicação curta e deixa duas vagas do mesmo valor comparáveis — com e
  -- sem refeição não são a mesma diária.
  inclui_refeicao        boolean not null,
  inclui_transporte      boolean not null,
  exige_material_proprio boolean not null,   -- sim = o profissional leva o material
  responsavel_local      text    not null,   -- quem recebe o profissional no local

  traje                  text,
  participa_rateio       boolean,            -- 10% da taxa de serviço (Lei 13.419/2017)
  observacoes            text,

  modo                   public.modo_preenchimento not null,
  -- Janela crítica: quanto tempo antes do início, com a posição ainda vaga, o
  -- contratante recebe o alerta. Padrão de 3 horas, ajustável na publicação (B18).
  alerta_antecedencia    interval not null default '3 hours',
  estado                 public.estado_vaga not null default 'publicada',
  publicado_em           timestamptz not null default now(),
  -- Idempotência da publicação: o app gera a chave uma vez por ação, e o reenvio
  -- devolve a vaga já gravada em vez de criar outra.
  chave_cliente          uuid not null,

  constraint publicacao_unica unique (estabelecimento_id, chave_cliente),
  constraint turno_tem_duracao check (fim_em > inicio_em),
  constraint alerta_positivo   check (alerta_antecedencia > interval '0'),

  -- RN24. O modo seleção fecha sozinho 24 horas antes do início, então uma vaga de
  -- seleção que começa em menos de 24 horas nasceria fechada — ela nem entra.
  constraint selecao_com_antecedencia check (
    modo <> 'selecao' or inicio_em > publicado_em + interval '24 hours')
);

create table public.posicao (
  id              uuid primary key default gen_random_uuid(),
  vaga_id         uuid not null references public.vaga(id) on delete cascade,
  estado          public.estado_posicao not null default 'aberta',
  -- Mantido depois do cancelamento: é ele que diz de quem foi a falta e quem
  -- cancelou, o que RN12 exige registrar e a taxa de comparecimento precisa ler.
  profissional_id uuid references public.profissional(id),
  confirmado_em   timestamptz,
  falta           boolean not null default false,

  -- Desnormalizado de vaga só para a constraint de sobreposição abaixo: um índice
  -- GIST não atravessa junção.
  inicio_em       timestamptz not null,
  fim_em          timestamptz not null,

  constraint confirmacao_coerente check (
    estado not in ('confirmada','cumprida')
      or (profissional_id is not null and confirmado_em is not null)),
  constraint aberta_sem_profissional check (
    estado <> 'aberta' or profissional_id is null),
  constraint falta_so_em_cancelada check (not falta or estado = 'cancelada')
);

-- RN21. Sem ela, o mesmo profissional seria confirmado para dois turnos que se
-- cruzam: aceitaria os dois de boa-fé e faltaria a um, desabando a própria taxa de
-- comparecimento por um buraco do sistema, não por comportamento.
alter table public.posicao add constraint sem_turno_sobreposto
  exclude using gist (
    profissional_id with =,
    tstzrange(inicio_em, fim_em) with &&
  ) where (estado in ('confirmada','cumprida'));

-- O preço da desnormalização: quando o horário da vaga muda, as posições acompanham.
-- Só acontece antes de haver confirmação.
create or replace function privado.sincronizar_horario_da_posicao()
returns trigger
language plpgsql
as $$
begin
  update public.posicao
     set inicio_em = new.inicio_em, fim_em = new.fim_em
   where vaga_id = new.id
     and estado = 'aberta';
  return new;
end $$;

create trigger vaga_horario_sincroniza
  after update of inicio_em, fim_em on public.vaga
  for each row
  when (new.inicio_em is distinct from old.inicio_em
     or new.fim_em    is distinct from old.fim_em)
  execute function privado.sincronizar_horario_da_posicao();
