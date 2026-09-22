-- Despacho, notificação, candidatura, turno, avaliação, bloqueio e ocorrência.

create type public.estado_entrega     as enum ('pendente','enviada','entregue','falhou');
create type public.estado_candidatura as enum ('pendente','aceita','recusada','retirada','expirada');
create type public.tipo_registro      as enum ('geolocalizado','manual');
create type public.verificacao_turno  as enum ('pendente','verificado','nao_verificado');
create type public.tipo_ocorrencia    as enum
  ('cancelamento','suspensao','contestacao','suporte','denuncia','revisao_despacho');
create type public.plataforma         as enum ('ios','android','web');
create type public.motivo_denuncia    as enum ('assedio','discriminacao','risco_seguranca','outro');

-- Quem negou a permissão de notificação não tem linha aqui e, para o despacho, não é
-- alcançável.
create table public.dispositivo (
  id            uuid primary key default gen_random_uuid(),
  usuario_id    uuid not null references public.usuario(id) on delete cascade,
  token_fcm     text not null unique,      -- um aparelho, um token
  plataforma    public.plataforma not null,
  atualizado_em timestamptz not null default now()
);

-- `despacho` e `notificacao` são duas coisas, e separar as duas é o que torna o teto
-- de RN23 possível. `despacho` diz QUEM foi considerado para QUAL vaga; `notificacao`
-- diz QUAL push saiu, quando, e se chegou. Um push agrupado ("4 vagas novas perto de
-- você") é uma notificacao com quatro despacho apontando para ela.
create table public.notificacao (
  id              uuid primary key default gen_random_uuid(),
  profissional_id uuid not null references public.profissional(id),
  enviada_em      timestamptz not null default now(),
  urgente         boolean not null default false,   -- furou o agrupamento (RN23)
  estado_entrega  public.estado_entrega not null default 'pendente',
  entregue_em     timestamptz,
  motivo_falha    text
);

create table public.despacho (
  id              uuid primary key default gen_random_uuid(),
  vaga_id         uuid not null references public.vaga(id) on delete cascade,
  profissional_id uuid not null references public.profissional(id),
  notificacao_id  uuid references public.notificacao(id),   -- nulo enquanto espera o teto
  criado_em       timestamptz not null default now(),

  -- RN05 contra o modo de falha mais banal: a mesma vaga reenviada para quem já
  -- recebeu. O efeito colateral na reabertura (o profissional que já foi notificado
  -- não recebe a posição reaberta) está na fila de decisão do cartão de produto,
  -- prazo 02/10.
  unique (vaga_id, profissional_id)
);

create table public.candidatura (
  id              uuid primary key default gen_random_uuid(),
  posicao_id      uuid not null references public.posicao(id) on delete cascade,
  profissional_id uuid not null references public.profissional(id),
  criada_em       timestamptz not null default now(),
  estado          public.estado_candidatura not null default 'pendente',
  unique (posicao_id, profissional_id)
);

create table public.turno (
  id                      uuid primary key default gen_random_uuid(),
  posicao_id              uuid not null unique references public.posicao(id),

  -- Guarda a DISTÂNCIA medida no toque, nunca a coordenada (RN22). O app lê a
  -- localização só no momento do check-in, calcula a distância até o endereço da vaga
  -- e envia só ela. É o que basta para saber se o check-in vale, e é o mínimo de dado
  -- pessoal que resolve o problema.
  checkin_em              timestamptz,
  checkin_tipo            public.tipo_registro,
  checkin_distancia_m     integer check (checkin_distancia_m >= 0),
  checkin_confirmado_em   timestamptz,               -- contratante, só no manual
  checkout_em             timestamptz,
  -- Sem teto de 200 m aqui, ao contrário da tabela da Modelagem: um CHECK
  -- BETWEEN 0 AND 200 recusaria a escrita de quem sai do local e tenta encerrar,
  -- deixando o turno sem check-out em vez de com um check-out distante. A distância
  -- é registrada como medida; quem classifica é a regra, não a constraint.
  -- Decisão em aberto no cartão S0 · Produto · Decisões que travam o código (02/10).
  checkout_distancia_m    integer check (checkout_distancia_m >= 0),
  verificacao             public.verificacao_turno not null default 'pendente',
  -- Copiado da vaga na confirmação, não lido por junção: se o estabelecimento
  -- republicar com outro valor, o turno executado precisa continuar dizendo quanto
  -- foi combinado. Registro que muda sozinho não vale nada (RN11).
  valor_acordado_centavos bigint not null check (valor_acordado_centavos > 0),

  -- RN22: o geolocalizado só vale a até 200 m do endereço da vaga.
  constraint checkin_no_raio check (
    checkin_tipo is distinct from 'geolocalizado'
      or (checkin_distancia_m is not null and checkin_distancia_m <= 200)),
  constraint confirmacao_so_no_manual check (
    checkin_confirmado_em is null or checkin_tipo = 'manual'),
  -- 'verificado' só com prova, e nunca sem marcar quando a prova existe.
  constraint verificacao_coerente check (
    (verificacao = 'verificado') = coalesce(
      checkin_tipo = 'geolocalizado'
        or (checkin_tipo = 'manual' and checkin_confirmado_em is not null), false))
);

-- `resposta boolean` é a aposta central do produto codificada no tipo. Não existe
-- caminho no esquema que aceite uma nota de 1 a 5 — RN07 proíbe, e um smallint "para
-- o caso de mudarmos de ideia" é exatamente como a regra se perde.
create table public.avaliacao (
  id        uuid primary key default gen_random_uuid(),
  turno_id  uuid not null references public.turno(id) on delete cascade,
  autor_id  uuid not null references public.usuario(id),
  alvo_tipo text not null check (alvo_tipo in ('profissional','estabelecimento')),
  alvo_id   uuid not null,
  resposta  boolean not null,
  criada_em timestamptz not null default now(),
  unique (turno_id, autor_id)
);

-- Vale nos dois sentidos: quem bloqueou não recebe mais nada de quem foi bloqueado, e
-- vice-versa. Quando uma das contas é membro de estabelecimento, o bloqueio passa a
-- valer para as vagas do estabelecimento inteiro (RF26).
create table public.bloqueio (
  id           uuid primary key default gen_random_uuid(),
  autor_id     uuid not null references public.usuario(id),
  bloqueado_id uuid not null references public.usuario(id),
  criado_em    timestamptz not null default now(),
  unique (autor_id, bloqueado_id),
  constraint nao_bloqueia_a_si check (autor_id <> bloqueado_id)
);

-- Uma tabela só para seis coisas diferentes é escolha: todas são o MESMO ato do ponto
-- de vista do registro — alguém saiu do curso normal, num momento, por um motivo
-- declarado. `motivo not null` é o que impede a suspensão silenciosa, queixa recorrente
-- nos concorrentes.
create table public.ocorrencia (
  id            uuid primary key default gen_random_uuid(),
  tipo          public.tipo_ocorrencia not null,
  posicao_id    uuid references public.posicao(id),
  turno_id      uuid references public.turno(id),
  usuario_id    uuid references public.usuario(id),   -- alvo, quando houver
  autor_id      uuid not null references public.usuario(id),
  motivo        text not null check (length(btrim(motivo)) > 0),
  criada_em     timestamptz not null default now(),
  resultado     text,
  resolvido_em  timestamptz,
  chave_cliente uuid,                                  -- idempotência da denúncia
  unique (autor_id, chave_cliente)
);
