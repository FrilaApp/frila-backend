-- O registro de uso da porta de demonstração.
--
-- A Edge Function `entrar-demonstracao` aceita um conjunto pequeno de e-mails declarados
-- no App Store Connect com um código fixo guardado em segredo. Código fixo que nunca
-- expira precisa de duas coisas que o código de seis dígitos do e-mail já tem de graça:
-- um teto de tentativas, para que ninguém varra o espaço do código, e um registro de
-- quem entrou e quando, para que um uso fora da janela da revisão apareça.
--
-- Mora em `public` e não em `privado` porque quem escreve aqui é a Edge Function pela
-- chave `service_role`, e o PostgREST só alcança `public` e `graphql_public`. A tabela é
-- inalcançável mesmo assim: RLS ligada e **nenhuma** política, que é o mesmo desenho já
-- usado em `pgmq.q_despacho`. `service_role` passa por cima da RLS; `anon` e
-- `authenticated` não têm nem a concessão nem a política.
--
-- Não há função de `public` nova nesta migração, de propósito. O contrato descreve esta
-- porta como Edge Function e diz, no `openapi.yaml`, que não existe RPC equivalente —
-- uma função do Postgres com esse poder ficaria exposta em `rest/v1` para qualquer um
-- tentar.

create table public.entrada_demonstracao (
  id       bigint generated always as identity primary key,
  email    text        not null,
  aceita   boolean     not null,
  em       timestamptz not null default privado.agora()
);

comment on table public.entrada_demonstracao is
  'Tentativas de entrada pela porta de demonstração da revisão da App Store (diretriz 2.1). Finalidade: limitar tentativas contra o código fixo e registrar o uso das contas de revisão.';

comment on column public.entrada_demonstracao.email is
  'O endereço declarado no App Store Connect na tentativa. Não é dado pessoal de usuário do produto: são as contas de revisão, que não pertencem a ninguém (RN15).';

comment on column public.entrada_demonstracao.aceita is
  'Verdadeiro quando o par e-mail e código foi aceito e a sessão foi emitida.';

comment on column public.entrada_demonstracao.em is
  'Relógio do produto (privado.agora()), e não now(): a janela do teto de tentativas tem de andar junto com o resto.';

-- A consulta do teto é sempre "quantas tentativas deste e-mail na janela".
create index entrada_demonstracao_email_em on public.entrada_demonstracao (email, em desc);

alter table public.entrada_demonstracao enable row level security;

-- Sem política nenhuma, e sem concessão: a leitura e a escrita são só da `service_role`,
-- que passa por cima da RLS. As linhas abaixo são redundantes com o `alter default
-- privileges` de 20260922190000, e estão aqui porque redundância que o próximo leitor
-- enxerga vale mais do que um padrão que ele precisa ir procurar.
revoke all on public.entrada_demonstracao from anon, authenticated;
