-- contrato: corpo-sem-mudanca-de-superficie public.contestar_suspensao 0.2.33
-- Corrige defeito pVvubZJy: permite nova contestação de suspensão após a contestação
-- anterior ter sido resolvida/negada pela equipe Frila (alinhado a public.situacao_da_conta).

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

  -- Diretriz 1.2 da App Store nos campos livres
  perform privado.exigir_texto_aceitavel(jsonb_build_object('relato', v_relato));

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
       and c.resolvido_em is null
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
  'Contestar a suspensão com envio de protocolo à Equipe Frila e prazo de 5 dias úteis (RF24, RN13, UC15). Permite novo envio caso a contestação anterior já tenha sido resolvida.';

revoke execute on function public.contestar_suspensao(text) from public, anon;
grant  execute on function public.contestar_suspensao(text) to authenticated;
