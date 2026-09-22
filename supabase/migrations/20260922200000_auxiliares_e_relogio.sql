-- As funções auxiliares do schema `privado` e o relógio.
--
-- As políticas fazem sempre as mesmas perguntas: qual é o perfil da conta, qual é o meu
-- `profissional`, sou membro deste estabelecimento, há bloqueio entre nós. Cada pergunta
-- vira uma função, num schema que a API não expõe.
--
-- `security definer` para ler as tabelas sem cair em recursão de política, `stable` para
-- o planejador reaproveitar o resultado, e `set search_path = ''` com nomes qualificados
-- para que nenhuma delas possa ser sequestrada por um schema no caminho de busca.

-- ── O relógio ──────────────────────────────────────────────────────────────────
--
-- Toda regra de prazo do produto passa por aqui: os 7 dias do contato (RN10), o fim
-- previsto que libera a avaliação (RN07), as 24 horas do modo seleção (RN24), os 15
-- minutos do alerta de atraso, a janela crítica da vaga vazia.
--
-- Testar prazo com `now()` obriga o teste a inventar datas no futuro e a torcer para o
-- relógio não virar no meio. Com um relógio sobreponível, o teste diz "são 3 horas
-- depois" e pronto.
--
-- A sobreposição só vale onde o ambiente é de teste, e o marcador do ambiente vem de uma
-- tabela que **só a semente preenche**. `supabase db reset` roda a semente no local e na
-- CI; `supabase db push` para o frila-dev e o frila-prod não roda. Não há variável de
-- ambiente para alguém esquecer ligada, e não há como o remoto ficar sobreponível por
-- descuido: lá a tabela está vazia.

create table privado.ambiente (
  id        boolean primary key default true check (id),
  eh_teste  boolean not null default false
);

comment on table privado.ambiente is
  'Marcador de ambiente de teste. Preenchido só pela semente, que não roda em ambiente remoto. Uma linha, no máximo.';

create or replace function privado.agora() returns timestamptz
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_sobreposto text;
begin
  if exists (select 1 from privado.ambiente where eh_teste) then
    v_sobreposto := current_setting('frila.agora', true);
    if v_sobreposto is not null and v_sobreposto <> '' then
      return v_sobreposto::timestamptz;
    end if;
  end if;
  return now();
end $$;

comment on function privado.agora() is
  'O relógio do produto. Sobreponível por frila.agora apenas onde privado.ambiente.eh_teste, que só a semente liga.';

-- ── Quem é quem ────────────────────────────────────────────────────────────────

create or replace function privado.perfil_da_conta() returns public.perfil_conta
language sql stable security definer set search_path = '' as $$
  select u.perfil from public.usuario u where u.id = (select auth.uid())
$$;

create or replace function privado.meu_profissional_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select p.id from public.profissional p where p.usuario_id = (select auth.uid())
$$;

create or replace function privado.eh_membro(estab uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.membro_estabelecimento m
                  where m.estabelecimento_id = estab
                    and m.usuario_id = (select auth.uid()))
$$;

create or replace function privado.eh_administrador(estab uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.membro_estabelecimento m
                  where m.estabelecimento_id = estab
                    and m.usuario_id = (select auth.uid())
                    and m.papel = 'administrador')
$$;

-- RF26: o bloqueio vale nos dois sentidos, e entre uma conta e qualquer membro do
-- estabelecimento — bloquear o maître tira você das vagas da casa inteira.
create or replace function privado.bloqueado_com_estabelecimento(conta uuid, estab uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.bloqueio b
                   join public.membro_estabelecimento m
                     on m.usuario_id in (b.autor_id, b.bloqueado_id)
                  where m.estabelecimento_id = estab
                    and conta in (b.autor_id, b.bloqueado_id))
$$;

create or replace function privado.estabelecimento_da_vaga(v uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select estabelecimento_id from public.vaga where id = v
$$;

create or replace function privado.estabelecimento_da_posicao(pos uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select v.estabelecimento_id
    from public.posicao p join public.vaga v on v.id = p.vaga_id
   where p.id = pos
$$;

create or replace function privado.usuario_do_profissional(prof uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select usuario_id from public.profissional where id = prof
$$;

create or replace function privado.ocupa_posicao_na_vaga(v uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.posicao p
                  where p.vaga_id = v
                    and p.profissional_id = privado.meu_profissional_id())
$$;

create or replace function privado.candidatou_na_vaga(v uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.candidatura c
                   join public.posicao p on p.id = c.posicao_id
                  where p.vaga_id = v
                    and c.profissional_id = privado.meu_profissional_id())
$$;

create or replace function privado.lado_da_posicao(pos uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.posicao p
                  where p.id = pos
                    and p.profissional_id = privado.meu_profissional_id())
      or privado.eh_membro(privado.estabelecimento_da_posicao(pos))
$$;

-- Primeira linha de toda RPC que é de um perfil só (RN25).
create or replace function privado.exigir_perfil(esperado public.perfil_conta) returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if privado.perfil_da_conta() is distinct from esperado then
    perform public.erro(422, 'perfil_incompativel');
  end if;
end $$;

revoke execute on all functions in schema privado from public, anon;
grant  execute on all functions in schema privado to authenticated, service_role;
alter default privileges in schema privado revoke execute on functions from public, anon;
