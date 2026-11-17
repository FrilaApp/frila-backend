-- A vaga direta cancelada fecha as chamadas abertas dela (B-035, issue #539).
--
-- public.cancelar_vaga é de 20261005090000, de antes da chamada direta, e nenhum gatilho de
-- public.vaga mexia em public.chamada. Cancelada a vaga, a chamada seguia aberta: o profissional
-- ainda a via, e o índice chamada_uma_aberta_por_par (RN34) travava o par casa × profissional até
-- ela vencer (409 chamada_ja_aberta). Prova: supabase/tests/877_vaga_cancelada_fecha_chamadas.sql.
--
--   1. Gatilho AFTER UPDATE OF estado em public.vaga, na ida a cancelada: vale para cancelar_vaga e
--      para os outros caminhos que cancelam vaga (excluir_conta e operacao_suspender_conta, na casa
--      de membro único). As chamadas abertas vão a encerrada, que é o desfecho do contrato
--      (EstadoChamada: "encerrada (... a vaga foi cancelada ...)"), com respondida_em. Desfecho
--      final não muda: a aceita fica aceita, e o turno dela é recolhido pelo cancelamento como
--      qualquer confirmado (vaga_cancelada_recolhe_confirmadas e o laço de cancelar_vaga).
--      - Aviso: o que já existe para a chamada que a casa desfez, chamada_cancelada ("O contratante
--        cancelou a chamada. Nada muda para você."), com chamada_id e vaga_id, como em
--        cancelar_chamada. O de encerrada (chamada_encerrada) diz "fechou com outro profissional",
--        o que aqui não é verdade. Nenhum tipo novo.
--      - A chamada já vencida (expira_em <= agora) e ainda aberta é do privado.expirar_chamadas,
--        que a expira em até um minuto, com o aviso dele. O job trava a chamada antes da vaga; se o
--        gatilho também a quisesse, os dois fechariam um ciclo.
--   2. cancelar_vaga trava a vaga direta antes das posições. O aceite (responder_chamada) trava a
--      vaga, depois a chamada, depois a posição; cancelar_vaga travava a posição aberta e só depois
--      a vaga. Com o aceite parado entre a vaga e a posição, os dois se esperavam e um saía em
--      40P01: medido no cenário 6b de scripts/corrida-chamada.sh, 4 de 4 rodadas na develop. Na
--      vaga direta, a ordem passa a ser a do aceite e a do #525 (20261117010000): vaga, chamada,
--      usuario (a chave estrangeira do aviso). A vaga é relida já travada, e as conferências de
--      estado usam essa leitura.
--      - Só na vaga direta: na vaga de publicação, candidatar trava a posição e depois a vaga
--        (cancelar_vaga_sem_corrida, 20260929120000), e a ordem de lá segue a dele. A vaga direta
--        não recebe candidatura (404 em candidatar desde 0.2.55).
--
-- Ordem de travas, por caminho, com este conserto:
--   cancelar_vaga (direta): vaga -> posições -> [gatilhos] chamadas, por id -> usuario (FK do aviso)
--   responder_chamada:      vaga -> chamada -> posição -> usuario
--   excluir_conta:          vagas -> chamadas -> usuario (#525); o gatilho só alcança chamadas de
--                           vagas que ela já travou
-- Resíduo conhecido, o mesmo do #525: operacao_suspender_conta e o gatilho da suspensão pegam o
-- usuario antes da chamada. O gatilho daqui segue a regra; o ciclo, se fechar, é da suspensão.
--
-- cancelar_vaga: corpo copiado de 20261005090000, com só o bloco "B-035" a mais. Nenhuma
-- assinatura muda; a resposta (posicoes_canceladas) é a mesma.

select set_config('lock_timeout', '2s', true);

-- ── 1. O gatilho ──────────────────────────────────────────────────────────────

create or replace function privado.vaga_cancelada_fecha_chamadas()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora timestamptz := privado.agora();
  r       record;
begin
  -- Por id, como o resto das travas de chamada. Uma chamada que outra transação segura (uma
  -- recusa em curso, por exemplo) é esperada e relida: se já não estiver aberta, fica como está.
  for r in
    select c.id, p.usuario_id as prof_usuario_id
      from public.chamada c
      join public.profissional p on p.id = c.profissional_id
     where c.vaga_id = new.id
       and c.estado = 'aberta'
       and c.expira_em > v_agora
     order by c.id
       for update of c
  loop
    update public.chamada c
       set estado = 'encerrada',
           respondida_em = coalesce(c.respondida_em, v_agora)
     where c.id = r.id;

    perform privado.notificar(r.prof_usuario_id, 'chamada_cancelada', r.id,
      jsonb_build_object('chamada_id', r.id, 'vaga_id', new.id));
  end loop;

  return null;
end $$;

comment on function privado.vaga_cancelada_fecha_chamadas() is
  'Gatilho AFTER de vaga: ao ir para cancelada, as chamadas abertas e no prazo vão a encerrada (EstadoChamada: a vaga foi cancelada), e o profissional recebe chamada_cancelada. A vencida fica para expirar_chamadas. Libera o par casa × profissional (RN34). B-035.';

revoke execute on function privado.vaga_cancelada_fecha_chamadas() from public, anon, authenticated;
grant  execute on function privado.vaga_cancelada_fecha_chamadas() to service_role;

drop trigger if exists vaga_cancelada_fecha_chamadas on public.vaga;
create trigger vaga_cancelada_fecha_chamadas
  after update of estado on public.vaga
  for each row
  when (new.estado = 'cancelada' and old.estado is distinct from 'cancelada')
  execute function privado.vaga_cancelada_fecha_chamadas();

-- ── 2. cancelar_vaga trava a vaga direta primeiro ─────────────────────────────

-- contrato: corpo-sem-mudanca-de-superficie public.cancelar_vaga 0.2.95
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

  -- B-035: na vaga direta, a vaga antes das posições, a ordem do aceite (responder_chamada) e
  -- do #525. Relida já travada: um aceite ou uma conversão que terminou enquanto esta esperava
  -- entra nas conferências abaixo. A vaga de publicação segue a ordem de candidatar (posição e
  -- depois vaga, 20260929120000).
  if v.origem = 'chamada_direta' then
    select * into v from public.vaga g where g.id = cancelar_vaga.vaga_id for update;
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

  -- Os gatilhos da vaga cancelada recolhem a confirmada que entrou no meio
  -- (vaga_cancelada_recolhe_confirmadas), expiram as candidaturas pendentes e fecham as
  -- chamadas abertas (vaga_cancelada_fecha_chamadas, B-035).
  update public.vaga g set estado = 'cancelada' where g.id = cancelar_vaga.vaga_id;

  return jsonb_build_object(
    'vaga_id',             v.id,
    'estado',              'cancelada',
    'posicoes_canceladas', v_abertas + v_confirmadas);
end $$;

comment on function public.cancelar_vaga(uuid, text) is
  'Cancela a vaga inteira, com motivo (RF14, RN12). Reenvio pelo mesmo contratante autor é idempotente e devolve 200 (0.2.35). Só o contratante membro da casa; as posições confirmadas são canceladas sem reabrir, e sem gerar falta para ninguém. Na vaga direta, trava a vaga antes das posições (a ordem do aceite), e as chamadas abertas vão a encerrada pelo gatilho vaga_cancelada_fecha_chamadas (B-035).';

revoke execute on function public.cancelar_vaga(uuid, text) from public, anon;
grant  execute on function public.cancelar_vaga(uuid, text) to authenticated;
