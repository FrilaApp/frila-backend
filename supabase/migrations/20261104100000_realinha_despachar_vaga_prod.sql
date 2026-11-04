-- Realinha `privado.despachar_vaga` no frila-prod com a definição do repositório.
--
-- Achado em 04/11/2026, no passo `desvio.sh` do deploy `backend-v1.1.0`: o Prod tem a versão
-- ANTIGA da função (a de `20260928210000_teto_e_agrupamento_rn23.sql`), sem a rodada de
-- despacho (`20260929110000`) e sem a vaga ocultada pela Equipe Frila (`20260929230000`),
-- embora essas duas migrações constem no histórico do Prod. A versão antiga faz
-- `on conflict (vaga_id, profissional_id)`, e a tabela `despacho` do Prod só tem a restrição
-- `unique (vaga_id, profissional_id, rodada)`: o `insert` falha com "no unique or exclusion
-- constraint matching the ON CONFLICT specification" e NENHUM despacho é criado (o Prod tem
-- 0 linhas em `despacho`). É a causa provável do push que não chega nos testes do 0.5.5.
--
-- Esta migração NÃO muda a regra: reproduz, byte a byte, a definição vigente em
-- `20260929230000_operacao_equipe_frila.sql` (a última do repositório). Onde a função já está
-- certa (frila-dev, banco local) o `create or replace` é um no-op. A migração é idempotente.

create or replace function privado.despachar_vaga(
  p_vaga_id     uuid,
  p_motivo      text default null,
  p_excluir     uuid default null
)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v                   public.vaga%rowtype;
  v_agora             timestamptz := privado.agora();
  v_urgente           boolean;
  v_reaberta          boolean;
  v_elegiveis         uuid[];
  v_prof_id           uuid;
  v_usr_id            uuid;
  v_desp_id           uuid;
  v_notif_id          uuid;
  v_payload           jsonb;
  v_despachos_criados int := 0;
  v_ja_despachados    int;
begin
  select * into v from public.vaga where id = p_vaga_id;
  -- A vaga ocultada pela Equipe Frila não é oferecida; a reexibição volta a despachá-la.
  if not found or v.estado <> 'publicada' or privado.vaga_oculta(v.id) then
    return 0;
  end if;

  v_reaberta := coalesce(p_motivo = 'reabertura', false) or v.rodada_despacho > 1;

  -- A ordem por id é só a ordem de aquisição das travas do teto (ver liberar_teto), e
  -- não decide quem recebe: todo elegível recebe (RN06).
  select array_agg(e.profissional_id order by e.profissional_id) into v_elegiveis
    from privado.elegiveis(p_vaga_id, p_excluir) e;

  if v_elegiveis is null or cardinality(v_elegiveis) = 0 then
    select count(*)::int into v_ja_despachados
      from public.despacho
     where vaga_id = p_vaga_id;

    -- Sem nenhum elegível no primeiro despacho: avisa o contratante uma vez (UC02 1a)
    if v_ja_despachados = 0 then
      perform privado.notificar_membros(
        v.estabelecimento_id,
        'vaga_sem_elegiveis',
        v.id,
        jsonb_build_object('vaga_id', v.id)
      );
    end if;

    return 0;
  end if;

  -- RN23: a vaga que começa em menos de 2 h fura o agrupamento. Conta o tempo até o
  -- início, e não o modo: a vaga de seleção só chega a menos de 2 h por reabertura, e a
  -- reabertura em cima da hora é o caso que mais precisa sair na hora. A reabertura por
  -- atraso acontece depois do início, então a rodada dela é sempre urgente.
  v_urgente := v.inicio_em - v_agora < privado.parametro_de_notificacao('urgente_antecedencia');

  foreach v_prof_id in array v_elegiveis loop
    perform privado.travar_teto(v_prof_id);

    insert into public.despacho (vaga_id, profissional_id, notificacao_id, criado_em, reaberta, rodada)
    values (v.id, v_prof_id, null, v_agora, v_reaberta, v.rodada_despacho)
    on conflict (vaga_id, profissional_id, rodada) do nothing
    returning id into v_desp_id;

    if v_desp_id is null then
      continue;
    end if;
    v_despachos_criados := v_despachos_criados + 1;

    if v_urgente then
      select p.usuario_id into v_usr_id from public.profissional p where p.id = v_prof_id;

      v_payload := jsonb_build_object('vaga_id', v.id);
      if v_reaberta then
        v_payload := v_payload || jsonb_build_object('reaberta', true);
      end if;

      -- A marca de envio de `vaga` em (tipo, referencia_id, usuario_id, rodada) mantém a
      -- idempotência sob chamadas concorrentes.
      v_notif_id := privado.notificar(v_usr_id, 'vaga', v.id, v_payload);

      update public.notificacao n set urgente = true where n.id = v_notif_id;
      update public.despacho d set notificacao_id = v_notif_id where d.id = v_desp_id;
    else
      -- Janela fechada: sai agora, junto com o que ainda esperava. Janela aberta: fica
      -- esperando, com `notificacao_id` nulo, até o agendador liberar.
      perform privado.liberar_teto_do_profissional(v_prof_id);
    end if;
  end loop;

  return v_despachos_criados;
end $$;

comment on function privado.despachar_vaga(uuid, text, uuid) is
  'Cria o despacho de cada elegível da rodada corrente de uma vaga e passa pelo teto da RN23: sai na hora se a janela do profissional fechou ou se a vaga começa em menos de 2 h; senão espera o agendador (liberar_teto). Da rodada 2 em diante o push é o de vaga reaberta. Se não há elegível, envia vaga_sem_elegiveis.';

revoke execute on function privado.despachar_vaga(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function privado.despachar_vaga(uuid, text, uuid) to service_role;
