-- 20261013110000_nao_filtrar_relato_de_contestacao.sql
--
-- Decisão J1=B da revisão de termos bloqueados (cartão ggEzge6h, 13/10/2026).
--
-- Remove a chamada a privado.exigir_texto_aceitavel no relato de:
--   - public.pedir_revisao_despacho (20261006160000, Opção B)
--   - public.contestar_suspensao (20261001100000)
--
-- O relato das contestações é lido exclusivamente pela Equipe Frila (F12) e
-- é onde a vítima/profissional cita o que ouviu ao apresentar sua defesa.
-- Bloquear a citação punia quem contestava (mesmo desenho já adotado em denunciar).
-- O filtro de termos continua ativo em nome, endereço, texto da vaga e motivo de cancelamento.
-- As validações de presença (campo_obrigatorio) e tamanho mínimo de 10 caracteres (campo_invalido)
-- permanecem inalteradas.

-- ── 1. pedir_revisao_despacho ────────────────────────────────────────────────────

-- contrato: corpo-sem-mudanca-de-superficie public.pedir_revisao_despacho 0.2.41
create or replace function public.pedir_revisao_despacho(relato text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_relato text := pg_catalog.btrim(pedir_revisao_despacho.relato);
  v_oc     public.ocorrencia%rowtype;
  v_agora  timestamptz;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('profissional');
  perform privado.exigir_conta_ativa();

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  if v_relato is null or v_relato = '' then
    perform public.erro(422, 'campo_obrigatorio', 'relato');
  end if;

  if pg_catalog.length(v_relato) < 10 then
    perform public.erro(422, 'campo_invalido', 'relato');
  end if;

  -- J1=B: relato lido apenas pela Equipe Frila; não filtra por termos bloqueados

  -- Opção B (0.2.37, RF27): apenas 1 contestação por despacho pelo app.
  -- Se já existir ocorrência do tipo 'revisao_despacho' para o autor (em análise ou respondida),
  -- recusa nova contestação pelo aplicativo com 409 contestacao_ja_aberta.
  if exists (
    select 1
      from public.ocorrencia o
     where o.autor_id = v_uid
       and o.tipo = 'revisao_despacho'
  ) then
    perform public.erro(409, 'contestacao_ja_aberta');
  end if;

  v_agora := privado.agora();

  insert into public.ocorrencia (
    autor_id,
    tipo,
    motivo,
    relato,
    criada_em
  ) values (
    v_uid,
    'revisao_despacho',
    'revisao_despacho',
    v_relato,
    v_agora
  ) returning * into v_oc;

  -- Enfileira o aviso de e-mail à Equipe Frila, só com o ID (RN15: sem relato nem dado pessoal na fila)
  perform pgmq.send('email', jsonb_build_object(
    'tipo',          'revisao_despacho',
    'ocorrencia_id', v_oc.id
  ));

  return jsonb_build_object(
    'ocorrencia_id',      v_oc.id,
    'tipo',               'revisao_despacho',
    'criada_em',          v_oc.criada_em,
    'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em)
  );
end $$;

comment on function public.pedir_revisao_despacho(text) is
  'Contestar o despacho com pedido de revisão à Equipe Frila (RF27, LGPD art. 20). Devolve Protocolo com prazo em até 5 dias úteis. Apenas 1 contestação pelo app (0.2.37).';

revoke execute on function public.pedir_revisao_despacho(text) from public, anon;
grant  execute on function public.pedir_revisao_despacho(text) to authenticated;


-- ── 2. contestar_suspensao ────────────────────────────────────────────────────────

-- contrato: corpo-sem-mudanca-de-superficie public.contestar_suspensao 0.2.41
create or replace function public.contestar_suspensao(relato text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid      uuid := (select auth.uid());
  v_usuario  public.usuario%rowtype;
  v_relato   text := pg_catalog.btrim(contestar_suspensao.relato);
  v_agora    timestamptz := privado.agora();
  v_susp     public.ocorrencia%rowtype;
  v_oc       public.ocorrencia%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  select * into v_usuario
    from public.usuario u
   where u.id = v_uid;

  if not found or v_usuario.estado = 'anonimizada' then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if v_usuario.estado <> 'suspensa' then
    perform public.erro(422, 'sem_suspensao_ativa');
  end if;

  if v_relato is null or v_relato = '' then
    perform public.erro(422, 'campo_obrigatorio', 'relato');
  end if;

  if pg_catalog.length(v_relato) < 10 then
    perform public.erro(422, 'campo_invalido', 'relato');
  end if;

  -- J1=B: relato lido apenas pela Equipe Frila; não filtra por termos bloqueados

  select * into v_susp
    from public.ocorrencia o
   where o.usuario_id = v_uid
     and o.tipo = 'suspensao'
   order by o.criada_em desc
   limit 1;

  if exists (
    select 1
      from public.ocorrencia c
     where c.usuario_id = v_uid
       and c.tipo = 'contestacao'
       and c.criada_em >= coalesce(v_susp.criada_em, '-infinity'::timestamptz)
  ) then
    perform public.erro(409, 'contestacao_ja_aberta');
  end if;

  insert into public.ocorrencia (
    tipo,
    usuario_id,
    autor_id,
    motivo,
    relato,
    criada_em
  ) values (
    'contestacao',
    v_uid,
    v_uid,
    'Contestação de suspensão',
    v_relato,
    v_agora
  ) returning * into v_oc;

  -- Enfileira o aviso de e-mail à Equipe Frila, só com o ID (RN15: sem relato nem dado pessoal na fila)
  perform pgmq.send('email', jsonb_build_object(
    'tipo',          'contestacao',
    'ocorrencia_id', v_oc.id
  ));

  return jsonb_build_object(
    'ocorrencia_id',      v_oc.id,
    'tipo',               'contestacao',
    'criada_em',          v_oc.criada_em,
    'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em)
  );
end $$;

comment on function public.contestar_suspensao(text) is
  'Contestar a suspensão com envio de protocolo à Equipe Frila e prazo de 5 dias úteis (RF24, RN13, UC15).';

revoke execute on function public.contestar_suspensao(text) from public, anon;
grant  execute on function public.contestar_suspensao(text) to authenticated;
