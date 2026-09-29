-- Limite de requisições de escrita por conta (RNF07). Cartão kT7NhMGV.
--
-- O contrato já declara a recusa desde a 0.2.1 — `| 429 | limite_excedido | Limite de
-- requisições |`, com `components/responses/LimiteExcedido` e `details: null` — e até aqui
-- nada a produzia. O único 429 do sistema era o teto de tentativas da Edge Function
-- `entrar-demonstracao`, que é outra regra.
--
-- Onde o limite mora, e por quê. O PostgREST chama `pgrst.db_pre_request` antes de cada
-- requisição, e ali dá para decidir uma vez, em vez de repetir a checagem nas 24 RPCs e
-- torcer para a próxima não esquecer. Medido em 29/09, dentro de uma RPC:
--
--   request.method = POST · request.path = /rpc/<nome> · auth.uid() = a conta
--
-- E o recorte "só escrita" sai de graça do desenho que o repositório já tem: o PostgREST
-- chama função `stable` por GET e função `volatile` por POST, e aqui toda leitura é
-- `stable` — é o que o `lint-conhecido.sh` cobra. Então `POST /rpc/` é exatamente o
-- conjunto das escritas, sem lista escrita à mão que envelhece.
--
-- O que NÃO é limitado, e é decisão, não esquecimento:
--   - sessão ausente: quem não tem `auth.uid()` esbarra no 401 das RPCs, e limitar por
--     IP é trabalho de camada de borda, não de banco;
--   - `service_role`: o agendador, as Edge Functions e o `pg_cron` escrevem em lote por
--     desenho, e limitá-los seria limitar o próprio produto;
--   - GET: leitura não gasta o teto de escrita.

-- ── 1. O parâmetro, que muda sem migração de código ────────────────────────────
create table privado.limite_requisicao (
  escopo    text        primary key,
  teto      int         not null,
  janela    interval    not null,
  descricao text        not null,
  constraint teto_positivo   check (teto > 0),
  constraint janela_positiva check (janela > interval '0')
);

comment on table privado.limite_requisicao is
  'Parâmetros do limite de requisições por conta (RNF07). Mudam sem migração: privado.limitar_requisicoes lê daqui a cada decisão.';

insert into privado.limite_requisicao (escopo, teto, janela, descricao) values
  ('escrita', 60, interval '1 minute',
   'RNF07: escritas por conta por minuto. 60 é folgado para uso humano — publicar, candidatar e bater ponto são ações de segundos — e é o suficiente para conter script.');

alter table privado.limite_requisicao enable row level security;

-- ── 2. O contador ──────────────────────────────────────────────────────────────
-- A janela é arredondada, e não deslizante: com `date_trunc` o contador é uma linha por
-- conta e por janela, e a decisão é um `upsert` e uma comparação. Janela deslizante
-- exigiria guardar cada requisição, que é justamente o que RN15 não quer no banco.
create table privado.contador_requisicao (
  usuario_id uuid        not null,
  escopo     text        not null,
  janela_em  timestamptz not null,
  contagem   int         not null default 0,
  primary key (usuario_id, escopo, janela_em),
  constraint contagem_positiva check (contagem >= 0)
);

comment on table privado.contador_requisicao is
  'Contagem de requisições por conta e janela (RNF07). Não guarda o que foi pedido, nem quando: só quantas na janela, porque RN15 proíbe dado pessoal em registro de tráfego.';

alter table privado.contador_requisicao enable row level security;

-- ── 3. A decisão ───────────────────────────────────────────────────────────────
create or replace function privado.limitar_requisicoes()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid;
  v_metodo  text;
  v_caminho text;
  v_teto    int;
  v_janela  interval;
  v_inicio  timestamptz;
  v_agora   int;
begin
  -- `service_role` escreve em lote por desenho: agendador, Edge Functions, pg_cron.
  if current_user = 'service_role' or (select auth.role()) = 'service_role' then
    return;
  end if;

  v_metodo  := current_setting('request.method', true);
  v_caminho := current_setting('request.path', true);

  -- Só escrita: função volátil chega por POST, e toda leitura aqui é stable.
  if v_metodo is distinct from 'POST' then return; end if;
  if v_caminho is null or v_caminho not like '/rpc/%' then return; end if;

  v_uid := (select auth.uid());
  if v_uid is null then return; end if;

  select l.teto, l.janela into v_teto, v_janela
    from privado.limite_requisicao l
   where l.escopo = 'escrita';
  if not found then return; end if;

  -- A janela arredondada no relógio do produto, para o teste conseguir deslocá-la.
  v_inicio := to_timestamp(
    floor(extract(epoch from privado.agora()) / extract(epoch from v_janela))
    * extract(epoch from v_janela));

  insert into privado.contador_requisicao (usuario_id, escopo, janela_em, contagem)
  values (v_uid, 'escrita', v_inicio, 1)
  on conflict (usuario_id, escopo, janela_em)
    do update set contagem = privado.contador_requisicao.contagem + 1
  returning contagem into v_agora;

  -- Janelas vencidas da própria conta saem junto, para a tabela não crescer sem job novo.
  delete from privado.contador_requisicao c
   where c.usuario_id = v_uid and c.escopo = 'escrita' and c.janela_em < v_inicio;

  if v_agora > v_teto then
    perform public.erro(429, 'limite_excedido');
  end if;
end $$;

comment on function privado.limitar_requisicoes() is
  'Limite de requisições de escrita por conta (RNF07). Chamada pelo PostgREST como pgrst.db_pre_request antes de cada requisição; recusa com 429 limite_excedido acima do teto de privado.limite_requisicao.';

revoke execute on function privado.limitar_requisicoes() from public, anon;
grant  execute on function privado.limitar_requisicoes() to authenticated, service_role;

-- ── 4. Ligar no PostgREST ──────────────────────────────────────────────────────
-- Vale para o papel que o PostgREST usa. O `notify` faz o PostgREST reler a configuração
-- sem reiniciar; sem ele a mudança só valeria no próximo start, e a migração passaria
-- sem ter ligado nada.
alter role authenticator set pgrst.db_pre_request = 'privado.limitar_requisicoes';
notify pgrst, 'reload config';
