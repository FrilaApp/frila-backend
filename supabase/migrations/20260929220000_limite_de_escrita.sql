-- Limite por conta nas escritas, com 429 limite_excedido (cartão kT7NhMGV, RNF07).
--
-- Antes de gente de verdade, uma conta não pode disparar escrita em rajada: um app com
-- laço errado, um toque repetido sem fim ou um script com o token de alguém. O teto é
-- por conta, numa janela de um minuto, e a recusa usa o código que o contrato já
-- cataloga para isso: `429 limite_excedido`.
--
-- ── Onde a conferência mora ───────────────────────────────────────────────────
--
-- Na opção `db_pre_request` do PostgREST, e não dentro de cada RPC. Assim nenhuma função
-- de `public` muda de corpo, toda RPC de escrita nova já nasce coberta, e ninguém precisa
-- lembrar de chamar o limite. O PostgREST roda a função dentro da mesma transação da
-- requisição, com o papel e as claims de quem chama.
--
-- A função mora num esquema próprio, `requisicao`, porque o PostgREST a chama com o papel
-- da requisição — inclusive `anon`, que não enxerga `privado`, e não pode enxergar. O
-- esquema não é exposto pela API (config.toml, `[api] schemas`), então a função não vira
-- rota. Ela é security definer: quem chama não lê nem escreve o contador.
--
-- ── O que conta como escrita ──────────────────────────────────────────────────
--
-- Requisição de conta autenticada, com método que não seja GET ou HEAD, em transação que
-- aceita escrita. O PostgREST abre transação só de leitura para GET e para RPC `stable`
-- ou `immutable`; as de leitura chamadas por POST, portanto, não contam. Anônimo não
-- conta — o que ele alcança é o Auth, que tem limite próprio por IP. `service_role` não
-- conta: é o agendador e as Edge Functions, que respondem pelo próprio volume.
--
-- ── O que o contador não vê ───────────────────────────────────────────────────
--
-- A escrita recusada por regra de negócio desfaz a transação inteira, e o incremento vai
-- junto. Só escrita que passou conta. É o que o limite protege — o banco de crescer em
-- rajada —, e a recusa de regra já não grava nada. A própria recusa do limite também
-- desfaz o incremento: o contador para no teto, e a conta volta a escrever quando o
-- minuto vira.
--
-- ── O teto ────────────────────────────────────────────────────────────────────
--
-- 60 escritas por minuto por conta. Nenhum fluxo do app chega perto: o ciclo completo de
-- um turno, das duas partes, são menos de 15 escritas espalhadas por horas. O número não
-- está em documento de requisito; fica escrito no PR como decisão a confirmar, e muda por
-- migração nova em `privado.limite_de_escrita_por_minuto()`.

-- ── O contador ────────────────────────────────────────────────────────────────

create table privado.escrita_por_conta (
  usuario_id uuid primary key,
  janela     timestamptz not null,
  contagem   int not null check (contagem > 0)
);

alter table privado.escrita_por_conta enable row level security;
revoke all on table privado.escrita_por_conta from public, anon, authenticated;

comment on table privado.escrita_por_conta is
  'Contador de escritas por conta no minuto corrente, para o limite de requisições (RNF07, cartão kT7NhMGV). Uma linha por conta, reescrita a cada janela. Guarda só a referência da conta e um número — nenhum dado pessoal, nenhuma rota, nenhum conteúdo (RN15).';
comment on column privado.escrita_por_conta.usuario_id is
  'A conta autenticada (sub do JWT). Sem chave estrangeira: um token ainda válido de conta encerrada não pode transformar o limite num erro de integridade.';
comment on column privado.escrita_por_conta.janela is
  'Início do minuto a que a contagem se refere, pelo relógio do produto.';
comment on column privado.escrita_por_conta.contagem is
  'Escritas aceitas da conta nesta janela.';

-- ── O teto ────────────────────────────────────────────────────────────────────

create or replace function privado.limite_de_escrita_por_minuto() returns int
language sql immutable set search_path = '' as $$
  select 60
$$;

revoke execute on function privado.limite_de_escrita_por_minuto() from public, anon, authenticated;
grant  execute on function privado.limite_de_escrita_por_minuto() to service_role;

comment on function privado.limite_de_escrita_por_minuto() is
  'Quantas escritas uma conta faz por minuto antes de receber 429 limite_excedido (RNF07).';

-- ── A conferência ─────────────────────────────────────────────────────────────

create schema requisicao;
revoke all on schema requisicao from public;
grant usage on schema requisicao to anon, authenticated, service_role;

comment on schema requisicao is
  'Funções que o PostgREST chama por conta própria em cada requisição (db_pre_request). Não exposto pela API.';

create or replace function requisicao.conferir_limite() returns void
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_papel    text := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role';
  v_metodo   text := coalesce(current_setting('request.method', true), '');
  v_janela   timestamptz;
  v_contagem int;
begin
  if v_uid is null
     or v_papel is distinct from 'authenticated'
     or v_metodo in ('', 'GET', 'HEAD')
     or current_setting('transaction_read_only') = 'on' then
    return;
  end if;

  v_janela := date_trunc('minute', privado.agora());

  insert into privado.escrita_por_conta as e (usuario_id, janela, contagem)
  values (v_uid, v_janela, 1)
  on conflict (usuario_id) do update
     set contagem = case when e.janela = excluded.janela then e.contagem + 1 else 1 end,
         janela   = excluded.janela
  returning e.contagem into v_contagem;

  if v_contagem > privado.limite_de_escrita_por_minuto() then
    perform public.erro(429, 'limite_excedido');
  end if;
end $$;

revoke execute on function requisicao.conferir_limite() from public;
grant  execute on function requisicao.conferir_limite() to anon, authenticated, service_role;

comment on function requisicao.conferir_limite() is
  'db_pre_request do PostgREST: conta as escritas da conta autenticada no minuto e recusa com 429 limite_excedido acima de privado.limite_de_escrita_por_minuto() (RNF07, cartão kT7NhMGV).';

-- ── O PostgREST passa a chamar ────────────────────────────────────────────────

alter role authenticator set pgrst.db_pre_request = 'requisicao.conferir_limite';
notify pgrst, 'reload config';
