-- Ciclo de vida da contestação de suspensão no app (Opção B, contrato 0.2.36).
--
-- public.situacao_da_conta devolve o Protocolo da contestação vinculada à suspensão
-- em vigor, quer ela esteja em análise (resolvido_em is null) ou já respondida
-- pela Equipe Frila (resolvido_em is not null).
--
-- Regras de negócio preservadas:
--   · Apenas uma contestação por suspensão (RF24);
--   · Nenhum resultado interno de suporte é exposto na resposta (RN07);
--   · Recurso fora do app: após resposta, não há reenvio no app (contestar_suspensao
--     continua devolvendo 409 contestacao_ja_aberta);
--   · Assinatura e schema idênticos (Protocolo | null).

create or replace function public.situacao_da_conta()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_usuario  public.usuario%rowtype;
  v_susp     public.ocorrencia%rowtype;
  v_cont     public.ocorrencia%rowtype;
  v_cont_obj jsonb := null;
  v_susp_obj jsonb := null;
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

  if v_usuario.estado = 'suspensa' then
    select * into v_susp
      from public.ocorrencia o
     where o.usuario_id = v_uid
       and o.tipo = 'suspensao'
     order by o.criada_em desc
     limit 1;

    -- Opção B (0.2.36): devolve o protocolo da contestação da suspensão em vigor,
    -- esteja em análise ou já respondida, sem filtrar por resolvido_em is null.
    select * into v_cont
      from public.ocorrencia c
     where c.usuario_id = v_uid
       and c.tipo = 'contestacao'
       and c.criada_em >= coalesce(v_susp.criada_em, '-infinity'::timestamptz)
     order by c.criada_em desc
     limit 1;

    if v_cont.id is not null then
      v_cont_obj := jsonb_build_object(
        'ocorrencia_id',      v_cont.id,
        'tipo',               'contestacao',
        'criada_em',          v_cont.criada_em,
        'prazo_resposta_ate', privado.prazo_de_resposta(v_cont.criada_em)
      );
    end if;

    v_susp_obj := jsonb_build_object(
      'motivo',      coalesce(v_susp.motivo, 'Suspensão de conta pela Equipe Frila'),
      'desde',       coalesce(v_susp.criada_em, v_usuario.criado_em),
      'contestacao', v_cont_obj
    );
  end if;

  return jsonb_build_object(
    'estado',    v_usuario.estado,
    'suspensao', v_susp_obj
  );
end $$;

comment on function public.situacao_da_conta() is
  'Situação da conta e da suspensão, se houver (RF24, RN13, UC15). Devolve o protocolo da contestação em análise ou já respondida (0.2.36).';

revoke execute on function public.situacao_da_conta() from public, anon;
grant  execute on function public.situacao_da_conta() to authenticated;
