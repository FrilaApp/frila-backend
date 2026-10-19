-- 20261008110000_abrir_suporte.sql
--
-- Suporte por e-mail a partir do turno (v1.1, RF23, UC14, D1=C, D12=A, D13=A, D14=A, D15=A).
-- Passo P2:
--   RPC public.abrir_suporte(turno_id uuid, categoria text, chave uuid)
--   - Security definer, search_path = ''
--   - Grants: revoke from public, anon; grant to authenticated
--   - Molde de public.denunciar
--   - Ordem estrita das 8 conferências descritas na seção 6 de requisitos/ingestao-email-suporte-v1.1.md

create or replace function public.abrir_suporte(
  turno_id  uuid,
  categoria text,
  chave     uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid            uuid := (select auth.uid());
  v_turno          uuid := abrir_suporte.turno_id;
  v_categoria_raw  text := abrir_suporte.categoria;
  v_categoria      text := btrim(abrir_suporte.categoria);
  v_chave          uuid := abrir_suporte.chave;
  v_oc             public.ocorrencia%rowtype;
  v_pos            public.posicao%rowtype;
  v_estab          uuid;
  v_eh_prof        boolean;
  v_limite_dia     int;
  v_hoje_sp        timestamptz;
  v_contagem_dia   int;
begin
  -- 1. Sem sessão: 401 nao_autenticado
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- 2. privado.exigir_conta_ativa(): anonimizada 401; suspensa 403 sem_permissao, details: conta_suspensa
  perform privado.exigir_conta_ativa();

  -- 3. chave nula: 422 campo_obrigatorio, details: chave
  if v_chave is null then
    perform public.erro(422, 'campo_obrigatorio', 'chave');
  end if;

  -- 4. Reenvio idempotente: já existe ocorrência suporte do mesmo autor com essa chave:
  -- devolve o mesmo Protocolo e encerra (antes do teto e das conferências de turno).
  select * into v_oc from public.ocorrencia o
   where o.autor_id = v_uid and o.chave_cliente = v_chave and o.tipo = 'suporte';
  if found then
    return jsonb_build_object(
      'ocorrencia_id', v_oc.id,
      'tipo', 'suporte',
      'criada_em', v_oc.criada_em,
      'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em)
    );
  end if;

  -- 5. turno_id nulo: 422 campo_obrigatorio, details: turno_id
  if v_turno is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  -- categoria nula ou vazia: 422 campo_obrigatorio, details: categoria
  if v_categoria_raw is null or v_categoria = '' then
    perform public.erro(422, 'campo_obrigatorio', 'categoria');
  end if;

  -- 6. categoria fora do enum: 422 campo_invalido, details: categoria
  if not (v_categoria = any (enum_range(null::public.categoria_suporte)::text[])) then
    perform public.erro(422, 'campo_invalido', 'categoria');
  end if;

  -- 7. Turno inexistente ou que não é do chamador: 404 nao_encontrado (mesma resposta para os dois)
  -- Quem pode chamar: profissional do turno OU membro do estabelecimento da vaga (SU-RN01, D14).
  select p.* into v_pos
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = v_turno;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  v_estab := privado.estabelecimento_da_vaga(v_pos.vaga_id);
  v_eh_prof := (privado.usuario_do_profissional(v_pos.profissional_id) = v_uid);

  if not v_eh_prof and not privado.eh_membro(v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- 8. Limite diário: serializa por conta com advisory lock transacional
  perform pg_catalog.pg_advisory_xact_lock(hashtextextended('suporte_diario:' || v_uid::text, 0));

  v_limite_dia := privado.limite_de_suporte_por_dia();
  v_hoje_sp := date_trunc('day', privado.agora() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';

  select count(*)::int into v_contagem_dia
    from public.ocorrencia o
   where o.autor_id = v_uid
     and o.tipo = 'suporte'
     and o.origem = 'app'
     and o.criada_em >= v_hoje_sp;

  if v_contagem_dia >= v_limite_dia then
    perform public.erro(429, 'limite_excedido');
  end if;

  -- Gravação em public.ocorrencia
  insert into public.ocorrencia (
    tipo,
    origem,
    turno_id,
    autor_id,
    motivo,
    relato,
    usuario_id,
    estabelecimento_id,
    chave_cliente,
    criada_em
  )
  values (
    'suporte',
    'app',
    v_turno,
    v_uid,
    v_categoria,
    null,
    null,
    null,
    v_chave,
    privado.agora()
  )
  on conflict (autor_id, chave_cliente) do nothing
  returning * into v_oc;

  if v_oc.id is null then
    -- Corrida de dois reenvios simultâneos: o outro gravou primeiro
    select * into v_oc from public.ocorrencia o
     where o.autor_id = v_uid and o.chave_cliente = v_chave and o.tipo = 'suporte';
  end if;

  return jsonb_build_object(
    'ocorrencia_id', v_oc.id,
    'tipo', 'suporte',
    'criada_em', v_oc.criada_em,
    'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em)
  );
end $$;

comment on function public.abrir_suporte(uuid, text, uuid) is
  'Abre um chamado de suporte a partir de um turno (RF23, UC14, contrato 0.2.40). O Frila não guarda o texto no banco (RN15); o app monta o assunto com o protocolo curto para envio a suporte@frila.app. Idempotente pela chave. Limite de 5 chamados por dia por conta (SU-RN06).';

revoke execute on function public.abrir_suporte(uuid, text, uuid) from public, anon;
grant  execute on function public.abrir_suporte(uuid, text, uuid) to authenticated;
