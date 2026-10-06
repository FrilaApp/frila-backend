-- Revisão de despacho: trava de unicidade de contestação no app (Opção B, contrato 0.2.37, RF27).
--
-- O titular pode submeter no máximo uma contestação por despacho através do aplicativo.
-- Se já existir ocorrência do tipo 'revisao_despacho' para o autor (em análise ou respondida),
-- a operação responde com 409 contestacao_ja_aberta. Recurso posterior exclusivamente por e-mail.

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

  -- Diretriz 1.2 da App Store nos campos livres
  perform privado.exigir_texto_aceitavel(jsonb_build_object('relato', v_relato));

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
