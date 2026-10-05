-- Curto-circuito idempotente no reenvio de cancelamento de posição e vaga (cartão pVvubZJy, contrato 0.2.35).
--
-- Decisão de produto do João Paulo (05/10/2026): Opção A (Sucesso Idempotente).
-- Em rede móvel instável (TestFlight / piloto), um pacote de confirmação de cancelamento pode ser
-- perdido após o commit no banco. Repetir `cancelar_posicao` ou `cancelar_vaga` pelo MESMO autor
-- em algo já cancelado por ele devolve 200 com o objeto cancelado, em vez de 409
-- `posicao_nao_cancelavel` / `vaga_encerrada`.
--
-- O que continua sendo 409:
--   · Cancelar o que NÃO é seu (outro estabelecimento ou outro profissional sem relação) -> 404 / 403;
--   · Cancelar o que foi cancelado pela contraparte ou outro autor -> 409;
--   · Posição aberta sem confirmação -> 409 posicao_nao_cancelavel;
--   · Turno já em andamento ou cumprido -> 409 posicao_nao_cancelavel;
--   · Vaga já encerrada por horário -> 409 vaga_encerrada.
--
-- Efeitos colaterais no reenvio:
--   · Nenhuma notificação duplicada;
--   · Nenhuma ocorrência duplicada;
--   · Nenhuma penalidade adicional na taxa de comparecimento (RN12);
--   · Nenhuma posição reaberta duplicada.

-- ── cancelar_posicao ──────────────────────────────────────────────────────────

create or replace function public.cancelar_posicao(posicao_id uuid, motivo text)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid         uuid := (select auth.uid());
  v_motivo      text := btrim(cancelar_posicao.motivo);
  v_pos         public.posicao%rowtype;
  v_estab       uuid;
  v_eh_prof     boolean;
  v_nova        uuid;
  v_reaberta    boolean;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  if cancelar_posicao.posicao_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'posicao_id');
  end if;

  -- O motivo não é burocracia: ele é o que a outra parte lê, e o que a auditoria tem
  -- para distinguir o imprevisto do descaso. O contrato pede pelo menos três letras.
  if v_motivo is null or length(v_motivo) < 3 then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  if not privado.texto_aceitavel(v_motivo) then
    perform public.erro(422, 'campo_invalido', 'motivo');
  end if;

  select * into v_pos from public.posicao p where p.id = cancelar_posicao.posicao_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  v_estab := privado.estabelecimento_da_vaga(v_pos.vaga_id);
  v_eh_prof := v_pos.profissional_id is not null
               and privado.usuario_do_profissional(v_pos.profissional_id) = v_uid;

  if not v_eh_prof and not privado.eh_membro(v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Curto-circuito idempotente (0.2.35, decisão pVvubZJy): reenvio após queda de rede pelo MESMO autor
  if v_pos.estado = 'cancelada' then
    if exists (
      select 1 from public.ocorrencia o
       where o.posicao_id = v_pos.id
         and o.tipo = 'cancelamento'
         and o.autor_id = v_uid
    ) then
      select (n.payload->>'reaberta')::boolean into v_reaberta
        from public.notificacao n
       where (n.payload->>'posicao_id')::uuid = v_pos.id
         and n.tipo = 'cancelamento'
       order by n.enviada_em desc
       limit 1;

      select p.id into v_nova
        from public.posicao p
       where p.vaga_id = v_pos.vaga_id
         and p.id <> v_pos.id
         and p.inicio_em = v_pos.inicio_em
         and p.fim_em = v_pos.fim_em
         and exists (
           select 1 from privado.auditoria_ciclo a
            where a.entidade = 'posicao'
              and a.entidade_id = p.id
              and a.acao = 'criou'
              and a.autor_id = v_uid
         )
       order by p.id desc
       limit 1;

      if v_reaberta is null then
        v_reaberta := (v_nova is not null);
      end if;

      if not v_reaberta then
        v_nova := null;
      end if;

      return jsonb_build_object(
        'posicao_id',      v_pos.id,
        'falta',           v_pos.falta,
        'reaberta',        v_reaberta,
        'nova_posicao_id', v_nova);
    end if;

    -- Cancelada por outra parte (ou outro membro/autor) não é idempotente: conflito.
    perform public.erro(409, 'posicao_nao_cancelavel');
  end if;

  if v_pos.estado <> 'confirmada' then
    -- Posição aberta não tem o que cancelar, e cumprida não volta atrás.
    perform public.erro(409, 'posicao_nao_cancelavel');
  end if;

  return privado.cancelar_uma_posicao(cancelar_posicao.posicao_id, v_uid, v_motivo, true);
end $$;

comment on function public.cancelar_posicao(uuid, text) is
  'Cancela uma posição confirmada, de qualquer um dos dois lados, com motivo (RF14, RN12). Reenvio pelo mesmo autor é idempotente e devolve 200 (0.2.35). Antes do início, a vaga ganha posição nova e o despacho sai de novo. Nenhum cancelamento muda o estado da conta (RN13). Exige conta ativa.';

revoke execute on function public.cancelar_posicao(uuid, text) from public, anon;
grant  execute on function public.cancelar_posicao(uuid, text) to authenticated;

-- ── cancelar_vaga ─────────────────────────────────────────────────────────────

create or replace function public.cancelar_vaga(vaga_id uuid, motivo text)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid         uuid := (select auth.uid());
  v_motivo      text := btrim(cancelar_vaga.motivo);
  v             public.vaga%rowtype;
  v_pos         uuid;
  v_abertas     int := 0;
  v_confirmadas int := 0;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();
  perform privado.exigir_perfil('contratante');

  if cancelar_vaga.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;
  if v_motivo is null or length(v_motivo) < 3 then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;
  if not privado.texto_aceitavel(v_motivo) then
    perform public.erro(422, 'campo_invalido', 'motivo');
  end if;

  select * into v from public.vaga g where g.id = cancelar_vaga.vaga_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if not privado.eh_membro(v.estabelecimento_id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Curto-circuito idempotente (0.2.35, decisão pVvubZJy): reenvio após queda de rede pelo MESMO autor
  if v.estado in ('cancelada', 'encerrada') then
    if v.estado = 'cancelada' then
      if exists (
        select 1 from privado.auditoria_ciclo a
         where a.entidade = 'vaga'
           and a.entidade_id = v.id
           and a.estado_novo = 'cancelada'
           and a.autor_id = v_uid
      ) or exists (
        select 1 from public.ocorrencia o
          join public.posicao p on p.id = o.posicao_id
         where p.vaga_id = v.id
           and o.tipo = 'cancelamento'
           and o.autor_id = v_uid
      ) then
        return jsonb_build_object(
          'vaga_id',             v.id,
          'estado',              'cancelada',
          'posicoes_canceladas', (select count(*)::int from public.posicao p where p.vaga_id = v.id and p.estado = 'cancelada'));
      end if;
    end if;

    perform public.erro(409, 'vaga_encerrada');
  end if;

  -- As confirmadas passam pelo mesmo caminho do cancelamento avulso, e **sem** reabrir:
  -- a vaga inteira está saindo do ar. Cancelamento pelo contratante não gera falta para
  -- ninguém, e é o autor que decide isso lá dentro.
  for v_pos in select p.id from public.posicao p
                where p.vaga_id = cancelar_vaga.vaga_id and p.estado = 'confirmada'
  loop
    perform privado.cancelar_uma_posicao(v_pos, v_uid, v_motivo, false);
    v_confirmadas := v_confirmadas + 1;
  end loop;

  update public.posicao p
     set estado = 'cancelada'
   where p.vaga_id = cancelar_vaga.vaga_id and p.estado = 'aberta';
  get diagnostics v_abertas = row_count;

  update public.vaga g set estado = 'cancelada' where g.id = cancelar_vaga.vaga_id;

  return jsonb_build_object(
    'vaga_id',             v.id,
    'estado',              'cancelada',
    'posicoes_canceladas', v_abertas + v_confirmadas);
end $$;

comment on function public.cancelar_vaga(uuid, text) is
  'Cancela a vaga inteira, com motivo (RF14, RN12). Reenvio pelo mesmo contratante autor é idempotente e devolve 200 (0.2.35). Só o contratante membro da casa; as posições confirmadas são canceladas sem reabrir, e sem gerar falta para ninguém.';

revoke execute on function public.cancelar_vaga(uuid, text) from public, anon;
grant  execute on function public.cancelar_vaga(uuid, text) to authenticated;
