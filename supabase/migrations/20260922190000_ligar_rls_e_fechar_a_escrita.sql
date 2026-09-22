-- Liga o Row Level Security nas dezenove tabelas e fecha a escrita direta.
--
-- Por que numa migração própria, e não junto com as políticas de leitura: sem isto,
-- as tabelas nascem com as concessões padrão do Supabase e `anon` — a role da chave
-- publicável, que vai dentro do app — tem INSERT, UPDATE e DELETE em todas elas.
-- Medido: `set role anon; insert into public.usuario (…)` devolvia `INSERT 0 1`.
--
-- As políticas de leitura são do cartão seguinte. Até elas chegarem, `authenticated`
-- também não lê: RLS sem política nega tudo. É o lado certo para errar, e o intervalo
-- é de horas, não de dias.
--
-- O que NÃO muda: `service_role` fica fora do RLS por construção, então o agendador e
-- a CI continuam funcionando, e o pgTAP roda como superusuário.

alter table public.usuario                enable row level security;
alter table public.profissional           enable row level security;
alter table public.estabelecimento        enable row level security;
alter table public.membro_estabelecimento enable row level security;
alter table public.equipe_confianca       enable row level security;
alter table public.funcao                 enable row level security;
alter table public.profissional_funcao    enable row level security;
alter table public.disponibilidade        enable row level security;
alter table public.evento                 enable row level security;
alter table public.vaga                   enable row level security;
alter table public.posicao                enable row level security;
alter table public.dispositivo            enable row level security;
alter table public.notificacao            enable row level security;
alter table public.despacho               enable row level security;
alter table public.candidatura            enable row level security;
alter table public.turno                  enable row level security;
alter table public.avaliacao              enable row level security;
alter table public.bloqueio               enable row level security;
alter table public.ocorrencia             enable row level security;

-- Escrita só por função (frase 1 da Modelagem). Sem política de escrita o RLS já
-- recusaria; o revoke deixa isso explícito e independe de alguém lembrar de não criar
-- uma política de insert por engano.
revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant  select on all tables in schema public to authenticated;

-- E a tabela criada depois desta migração nasce igual, sem depender de quem a criou
-- lembrar do revoke.
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public
  revoke insert, update, delete, truncate on tables from authenticated;

-- Função nova nasce sem execute para anon; authenticated continua chamando as RPCs.
alter default privileges in schema public revoke execute on functions from public, anon;

-- ── Dívida declarada ───────────────────────────────────────────────────────────

-- O enum existe para a assinatura de `denunciar` no contrato (schema MotivoDenuncia) e
-- ainda não tem coluna: `ocorrencia.motivo` é texto, e a RPC que junta motivo e relato
-- entra no Sprint 2. Comentado para que não pareça sobra de refatoração.
comment on type public.motivo_denuncia is
  'Motivos de denúncia do contrato (MotivoDenuncia). Consumido pela RPC denunciar, no Sprint 2; ocorrencia.motivo guarda o texto final.';
