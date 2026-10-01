-- O pedido de exclusão de conta deixa rastro mesmo quando a transação volta atrás
-- (cartão SHUDSozj, RF25, LGPD).
--
-- O problema, medido em 29/09 na develop 6bdfd65: o cenário 9 de `scripts/corrida-ciclo.sh`
-- termina 6 de 50 rodadas com `privado.excluir_conta` batendo em 40P01. A função roda
-- inteira numa transação só — não há `commit` em `20260929160000_excluir_conta_autor.sql` —
-- e `supabase/functions/excluir-conta/index.ts` a chama num único `select`. Quando ela
-- aborta, a transação volta atrás e leva junto tudo que ela escreveu. O titular recebe erro
-- e o sistema não guarda que ele pediu: não sobra nem referência para reprocessar.
--
-- Nenhum arranjo dentro de uma transação resolve isso, e vale dizer por quê, para ninguém
-- tentar de novo:
--
--   · registrar no corpo da função e reerguer o erro descarta o registro junto, porque o
--     `raise` desfaz o bloco inteiro, inclusive o que o handler escreveu;
--   · engolir o erro deixaria o registro, mas devolveria sucesso sobre uma exclusão que não
--     aconteceu — trocar um rastro perdido por uma mentira é pior.
--
-- Por isso o registro é chamada própria, que o chamador faz **antes** da exclusão, em
-- transação separada. É a mesma forma que `denunciar` usa ao enfileirar o e-mail: o pedido
-- existe como fato antes de a consequência ser tentada.
--
-- Fora de escopo, por decisão: retentativa automática. Repetir sozinha uma anonimização
-- irreversível é decisão de produto, não de quem conserta o rastro. Esta migração entrega o
-- registro e a lista de pendentes; quem decidir o reprocessamento tem onde se apoiar.

-- ── A tabela ──────────────────────────────────────────────────────────────────
--
-- `usuario_id` **não** tem chave estrangeira para `public.usuario`, e isso é deliberado.
-- `privado.excluir_conta` tem um caminho de retorno antecipado para conta que nunca chegou
-- a `public.usuario` (existe em `auth.users` e nada mais), e o pedido dessa conta tem de
-- ficar registrado igual. Uma FK aqui recusaria justamente o caso em que o rastro é a única
-- coisa que sobra. A contrapartida é que a linha sobrevive à conta, que é o que a LGPD pede
-- de um registro de operação.
create table if not exists public.pedido_de_exclusao (
  id           uuid primary key default gen_random_uuid(),
  usuario_id   uuid not null unique,
  pedido_em    timestamptz not null default now(),
  estado       text not null default 'pendente',
  tentativas   integer not null default 1,
  concluido_em timestamptz,
  constraint pedido_de_exclusao_estado_conhecido
    check (estado in ('pendente', 'concluido')),
  constraint pedido_de_exclusao_tentativas_positivas
    check (tentativas >= 1),
  -- Concluído sem data, ou data sem concluído, é registro que não conta nada.
  constraint pedido_de_exclusao_conclusao_coerente
    check ((estado = 'concluido') = (concluido_em is not null))
);

comment on table public.pedido_de_exclusao is
  'Registro de que uma conta pediu exclusão (RF25). Escrito antes da exclusão ser tentada, '
  'em transação própria, para o pedido sobreviver ao rollback dela. Guarda referência e '
  'estado, nunca cópia de dado pessoal (RN15).';
comment on column public.pedido_de_exclusao.usuario_id is
  'Conta que pediu a exclusão. Sem FK de propósito: o pedido tem de existir para conta que '
  'nunca chegou a public.usuario, e tem de sobreviver à anonimização dela.';
comment on column public.pedido_de_exclusao.tentativas is
  'Quantas vezes o pedido foi registrado. Quem insiste porque a exclusão falhou aparece aqui.';

create index if not exists pedido_de_exclusao_pendentes
  on public.pedido_de_exclusao (pedido_em)
  where estado = 'pendente';

-- A tabela guarda que uma pessoa pediu para sair, e isso é dado pessoal. Ninguém do lado do
-- app a alcança: sem política nenhuma, o RLS ligado fecha tudo, e a leitura sai por função.
alter table public.pedido_de_exclusao enable row level security;

-- `execute` de função nasce concedido ao PUBLIC, então revogar só de `anon` e
-- `authenticated` não fecha nada: os dois herdam por PUBLIC. O `from public` é o que fecha.
revoke all on public.pedido_de_exclusao from anon, authenticated;

-- ── Registrar ─────────────────────────────────────────────────────────────────

create or replace function privado.registrar_pedido_de_exclusao(p_usuario_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_linha public.pedido_de_exclusao;
begin
  if p_usuario_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'usuario_id');
  end if;

  -- Idempotente por conta: um pedido por titular. Pedir de novo não cria linha nova, mas
  -- conta como tentativa — quem insistiu porque a exclusão falhou aparece na lista.
  insert into public.pedido_de_exclusao (usuario_id)
  values (p_usuario_id)
  on conflict (usuario_id) do update
    set tentativas = public.pedido_de_exclusao.tentativas + 1
  returning * into v_linha;

  return jsonb_build_object(
    'pedido_em',  v_linha.pedido_em,
    'estado',     v_linha.estado,
    'tentativas', v_linha.tentativas);
end $$;

comment on function privado.registrar_pedido_de_exclusao(uuid) is
  'Registra o pedido de exclusão numa transação própria, antes de privado.excluir_conta. '
  'O chamador faz esta chamada primeiro; se a exclusão voltar atrás, esta linha fica.';

revoke all on function privado.registrar_pedido_de_exclusao(uuid) from public, anon, authenticated;
grant execute on function privado.registrar_pedido_de_exclusao(uuid) to service_role;

-- ── Listar os pendentes ───────────────────────────────────────────────────────
--
-- É o que torna o pedido recuperável: sem esta lista, a linha existe e ninguém olha.

create or replace function privado.pedidos_de_exclusao_pendentes()
returns table (usuario_id uuid, pedido_em timestamptz, tentativas integer)
language sql
stable
security definer set search_path = ''
as $$
  select p.usuario_id, p.pedido_em, p.tentativas
    from public.pedido_de_exclusao p
   where p.estado = 'pendente'
   order by p.pedido_em;
$$;

comment on function privado.pedidos_de_exclusao_pendentes() is
  'Pedidos de exclusão que ainda não concluíram. Referência e estado, sem dado pessoal (RN15).';

revoke all on function privado.pedidos_de_exclusao_pendentes() from public, anon, authenticated;
grant execute on function privado.pedidos_de_exclusao_pendentes() to service_role;

-- ── Fechar o pedido quando a exclusão conclui ─────────────────────────────────
--
-- Esta marcação fica **dentro** da transação de `privado.excluir_conta`, e é isso que a
-- torna correta: se a exclusão volta atrás, a marcação volta com ela e o pedido continua
-- pendente. O registro é que precisa estar fora; a conclusão precisa estar dentro.

create or replace function privado.concluir_pedido_de_exclusao(p_usuario_id uuid, p_em timestamptz)
returns void
language sql
security definer set search_path = ''
as $$
  update public.pedido_de_exclusao
     set estado = 'concluido', concluido_em = p_em
   where usuario_id = p_usuario_id
     and estado = 'pendente';
$$;

comment on function privado.concluir_pedido_de_exclusao(uuid, timestamptz) is
  'Marca o pedido como concluído. Roda dentro da transação da exclusão de propósito: se ela '
  'voltar atrás, a marcação volta junto e o pedido segue pendente.';

revoke all on function privado.concluir_pedido_de_exclusao(uuid, timestamptz) from public, anon, authenticated;
grant execute on function privado.concluir_pedido_de_exclusao(uuid, timestamptz) to service_role;

-- O gatilho, e por que não é `create or replace function privado.excluir_conta`
--
-- Pendurar a conclusão na anonimização, e não dentro da `excluir_conta`, evita reescrever
-- uma função de 280 linhas para acrescentar uma chamada — reescrita é onde a próxima
-- correção perde um pedaço sem ninguém notar. E vale mais largo: qualquer caminho que
-- anonimize a conta fecha o pedido, não só o que existe hoje.
--
-- Fica dentro da transação da exclusão, que é o lado certo da fronteira: se ela volta atrás,
-- a anonimização não aconteceu, o gatilho não disparou, e o pedido continua pendente.
create or replace function privado.pedido_de_exclusao_concluido()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  perform privado.concluir_pedido_de_exclusao(
    new.id, coalesce(new.anonimizado_em, privado.agora()));
  return new;
end $$;

comment on function privado.pedido_de_exclusao_concluido() is
  'Fecha o pedido de exclusão quando a conta é anonimizada (RF25).';

revoke all on function privado.pedido_de_exclusao_concluido() from public, anon, authenticated;

drop trigger if exists pedido_de_exclusao_concluido on public.usuario;

create trigger pedido_de_exclusao_concluido
after update of estado on public.usuario
for each row
when (new.estado = 'anonimizada' and old.estado <> 'anonimizada')
execute function privado.pedido_de_exclusao_concluido();
