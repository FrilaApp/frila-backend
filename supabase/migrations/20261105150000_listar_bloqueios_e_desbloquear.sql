-- Listar e desfazer bloqueios (RF26, RN10, UC17). Cartão Y18NMyPo · decisão A8 da PO.
-- Contrato 0.2.51.
--
-- O bloqueio já existia e não tinha volta: `public.bloquear` cria, e nada desfazia. A
-- decisão A8 da PO fecha o ciclo — a tela de bloqueados mostra quem o chamador bloqueou e
-- oferece o desbloqueio, com a volta imediata e automática, do mesmo jeito que a ida.
--
-- A assimetria que estas duas funções têm de respeitar, e que vem de `bloquear`:
--   · Profissional bloqueando estabelecimento grava UMA linha por membro da casa
--     (`autor_id` = profissional, `bloqueado_id` = cada membro).
--   · Membro bloqueando profissional grava UMA linha só (`autor_id` = aquele membro), e o
--     efeito alcança a casa inteira porque quem lê é
--     `privado.bloqueado_com_estabelecimento`, que olha qualquer membro.
-- Logo, desbloquear do lado da casa tem de apagar as linhas de TODOS os membros das casas
-- de quem chama. Apagar só a própria linha deixaria a vaga invisível para o profissional
-- por causa de um colega, e o operador veria o botão "desbloquear" não funcionar — o pior
-- tipo de defeito: a tela diz que desfez e o despacho continua cortando.
--
-- Nenhuma das duas devolve `usuario_id` (RN10 estrita): o par que sai é `alvo_tipo` +
-- `alvo_id` do `PerfilPublico`, o mesmo que `bloquear` recebe.

-- ── 1. listar_bloqueios ───────────────────────────────────────────────────────

create or replace function public.listar_bloqueios()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_perfil public.perfil_conta;
  v_itens  jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  v_perfil := privado.perfil_da_conta();

  if v_perfil = 'profissional' then
    -- Do lado do profissional, N linhas (uma por membro) são UM bloqueio de casa. O
    -- `min(criado_em)` é o instante em que ele bloqueou, e não o da última linha gravada
    -- quando a casa ganhou membro novo depois.
    select coalesce(jsonb_agg(item order by (item->>'criado_em') desc), '[]'::jsonb)
      into v_itens
      from (
        select jsonb_build_object(
                 'alvo_tipo', 'estabelecimento',
                 'alvo_id',   e.id,
                 'nome',      e.nome,
                 'criado_em', min(b.criado_em)
               ) as item
          from public.bloqueio b
          join public.membro_estabelecimento m on m.usuario_id = b.bloqueado_id
          join public.estabelecimento e       on e.id = m.estabelecimento_id
         where b.autor_id = v_uid
         group by e.id, e.nome
      ) q;
  else
    -- Conta encerrada continua na lista, com o nome público que o resto do produto usa
    -- (RF25): esconder o item deixaria um bloqueio ativo sem nenhuma forma de desfazer.
    select coalesce(jsonb_agg(item order by (item->>'criado_em') desc), '[]'::jsonb)
      into v_itens
      from (
        select jsonb_build_object(
                 'alvo_tipo', 'profissional',
                 'alvo_id',   p.id,
                 'nome',      case when u.estado = 'anonimizada' then 'Conta encerrada' else u.nome end,
                 'criado_em', b.criado_em
               ) as item
          from public.bloqueio b
          join public.profissional p on p.usuario_id = b.bloqueado_id
          join public.usuario u      on u.id = p.usuario_id
         where b.autor_id = v_uid
      ) q;
  end if;

  return coalesce(v_itens, '[]'::jsonb);
end $$;

comment on function public.listar_bloqueios() is
  'Bloqueios criados por quem chama, do mais recente para o mais antigo (RF26, UC17, decisão A8). Devolve o par alvo_tipo + alvo_id do PerfilPublico, o nome público e o instante; nunca o usuario_id da outra parte (RN10). Sem bloqueio nenhum, lista vazia e não erro. Bloqueio que a outra parte criou contra o chamador não aparece, para não revelar quem o bloqueou.';

revoke execute on function public.listar_bloqueios() from public, anon;
grant  execute on function public.listar_bloqueios() to authenticated;

-- ── 2. desbloquear ────────────────────────────────────────────────────────────

create or replace function public.desbloquear(alvo_tipo text, alvo_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_tipo    text := desbloquear.alvo_tipo;
  v_alvo    uuid := desbloquear.alvo_id;
  v_perfil  public.perfil_conta;
  v_contas  uuid[];
  v_autores uuid[];
  v_criado  timestamptz;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  -- Mesma ordem de recusa de `bloquear`, para o cliente não precisar aprender duas
  -- gramáticas de erro para a ida e a volta.
  if v_tipo is null then
    perform public.erro(422, 'campo_obrigatorio', 'alvo_tipo');
  end if;
  if v_alvo is null then
    perform public.erro(422, 'campo_obrigatorio', 'alvo_id');
  end if;
  if v_tipo not in ('profissional', 'estabelecimento') then
    perform public.erro(422, 'campo_invalido', 'alvo_tipo');
  end if;

  v_perfil := privado.perfil_da_conta();
  if (v_perfil = 'profissional') is distinct from (v_tipo = 'estabelecimento') then
    perform public.erro(422, 'campo_invalido', 'alvo_tipo');
  end if;

  if v_tipo = 'estabelecimento' then
    select array_agg(m.usuario_id) into v_contas
      from public.membro_estabelecimento m
     where m.estabelecimento_id = v_alvo;
    v_autores := array[v_uid];
  else
    select array_agg(p.usuario_id) into v_contas
      from public.profissional p
     where p.id = v_alvo;

    -- O desbloqueio do lado da casa vale para a casa inteira: apaga a linha de qualquer
    -- membro das casas de quem chama. Ver o cabeçalho desta migração.
    select array_agg(distinct colega.usuario_id) into v_autores
      from public.membro_estabelecimento meu
      join public.membro_estabelecimento colega on colega.estabelecimento_id = meu.estabelecimento_id
     where meu.usuario_id = v_uid;
  end if;

  if v_contas is null then
    perform public.erro(404, 'nao_encontrado');
  end if;
  if v_autores is null then
    v_autores := array[v_uid];
  end if;

  -- O `criado_em` sai ANTES do delete: é o instante do bloqueio que deixou de valer, e é o
  -- que o contrato promete devolver. Ler depois devolveria nulo sempre.
  select min(b.criado_em) into v_criado
    from public.bloqueio b
   where b.autor_id = any (v_autores)
     and b.bloqueado_id = any (v_contas);

  delete from public.bloqueio b
   where b.autor_id = any (v_autores)
     and b.bloqueado_id = any (v_contas);

  -- Idempotente: desbloquear quem já não estava bloqueado é 200, e o instante é o da
  -- chamada. 404 aqui faria a tela acusar erro por um estado que é o desejado.
  return jsonb_build_object(
    'alvo_tipo', v_tipo,
    'alvo_id',   v_alvo,
    'criado_em', coalesce(v_criado, privado.agora())
  );
end $$;

comment on function public.desbloquear(text, uuid) is
  'Desfaz o bloqueio criado por quem chama, pelo par alvo_tipo + alvo_id do PerfilPublico (RF26, UC17, decisão A8). Profissional desfaz com o estabelecimento inteiro; membro de estabelecimento desfaz para a casa inteira, como bloquear vale para a casa inteira. Imediato, idempotente (200 mesmo sem bloqueio), e nunca devolve usuario_id (RN10).';

revoke execute on function public.desbloquear(text, uuid) from public, anon;
grant  execute on function public.desbloquear(text, uuid) to authenticated;
