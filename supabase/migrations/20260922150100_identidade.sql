-- Identidade: a conta e o perfil de profissional.
--
-- RN25 (22/09): cada conta tem UM perfil, escolhido no cadastro e sem troca. Quem é
-- garçom num fim de semana e opera o cadastro do buffet no outro tem duas contas,
-- com dois e-mails; o telefone pode ser o mesmo.
--
-- A regra é escrita em três peças, e as três precisam existir:
--   1. `criar_conta` grava o perfil escolhido;
--   2. o trigger recusa qualquer UPDATE que o mude;
--   3. `profissional` e `membro_estabelecimento` apontam para o par (id, perfil),
--      então nem um bug de função consegue dar perfil de profissional a uma conta
--      de contratante.

create type public.estado_conta  as enum ('ativa', 'suspensa', 'anonimizada');
create type public.perfil_conta  as enum ('profissional', 'contratante');

create table public.usuario (
  -- É o id da conta no Supabase Auth, gravado por criar_conta a partir de auth.uid().
  -- Sem chave estrangeira para auth.users de propósito: a exclusão de conta apaga o
  -- registro de autenticação e mantém esta linha anonimizada (RF25). Com a chave, o
  -- Supabase recusaria apagar a conta de quem ainda tem histórico.
  id              uuid primary key,
  perfil          public.perfil_conta  not null,
  nome            text                 not null,
  telefone        text,
  email           extensions.citext,
  nascimento      date                 not null,
  estado          public.estado_conta  not null default 'ativa',
  criado_em       timestamptz          not null default now(),
  anonimizado_em  timestamptz,

  -- RN20: a maioridade é verificada na escrita, a partir da data de nascimento.
  -- Um booleano enviado pela tela não verifica nada — é a tela dizendo ao banco
  -- aquilo que a tela quis.
  constraint maior_de_idade
    check (nascimento <= (current_date - interval '18 years')),

  constraint anonimizacao_coerente
    check ((estado = 'anonimizada') = (anonimizado_em is not null)),
  constraint email_ate_anonimizar
    check (estado = 'anonimizada' or email is not null),
  -- Obrigatório enquanto a conta existe, porque é o contato do turno (RN10).
  -- Sem verificação por SMS e sem unicidade: só o formato E.164 é conferido.
  constraint telefone_ate_anonimizar
    check (estado = 'anonimizada' or telefone is not null),
  constraint telefone_e164
    check (telefone ~ '^\+[1-9][0-9]{7,14}$'),

  -- Alvo das chaves estrangeiras compostas de RN25.
  constraint usuario_id_perfil unique (id, perfil)
);

-- Parcial de propósito: RF25 manda anonimizar em vez de apagar, para preservar o
-- histórico da contraparte. Com unicidade total, o e-mail de uma conta encerrada
-- bloquearia para sempre quem quisesse voltar com o mesmo endereço.
create unique index usuario_email_ativo
  on public.usuario (email) where estado <> 'anonimizada';

create or replace function privado.perfil_imutavel()
returns trigger
language plpgsql
as $$
begin
  raise exception 'o perfil da conta não muda (RN25)' using errcode = 'check_violation';
end $$;

create trigger usuario_perfil_imutavel
  before update of perfil on public.usuario
  for each row when (new.perfil is distinct from old.perfil)
  execute function privado.perfil_imutavel();

create table public.profissional (
  id                  uuid primary key default gen_random_uuid(),
  usuario_id          uuid not null unique,
  perfil              public.perfil_conta not null default 'profissional'
                        check (perfil = 'profissional'),
  ponto_base          extensions.geography(Point, 4326) not null,

  -- Desnormalizações de leitura. A verdade está em posicao/turno/avaliacao; estas
  -- colunas são cache, recalculado por trigger e por job de reconciliação. Quando
  -- divergirem do histórico, o histórico ganha.
  --
  -- Nula até existir histórico, e isso é deliberado: RF16 exige que perfil sem
  -- histórico apareça como sem histórico, não como nota zero. 0.0 e NULL contam
  -- histórias opostas sobre quem acabou de chegar.
  taxa_comparecimento numeric(4,3) check (taxa_comparecimento between 0 and 1),
  turnos_realizados   integer not null default 0,
  -- O par, nunca só o percentual: é o denominador que separa confiança real de
  -- amostra pequena (RN08, "7 de 7 chamariam de novo").
  aval_positivas      integer not null default 0,
  aval_total          integer not null default 0,

  constraint aval_coerente check (aval_positivas <= aval_total),
  constraint so_conta_de_profissional
    foreign key (usuario_id, perfil) references public.usuario (id, perfil)
);

-- Não existe `raio_km`. Desde 21/09 (B07) o profissional não declara raio: a
-- distância que decide a notificação é do sistema, 15 km do ponto base até o local
-- da vaga, e a lista mostra todas as vagas do DF, das mais próximas às mais distantes.
