-- cancelar_vaga na vaga de publicação: a vaga antes das posições abertas (B-072, issue #572).
--
-- Na vaga de publicação, public.cancelar_vaga (20261117050000:174-189) pegava as confirmadas, depois
-- as posições abertas (o update delas) e só então a vaga. Quem pega a vaga antes da posição aberta
-- fechava ciclo com ele (medido com a ordem forçada por uma terceira conexão em
-- scripts/corrida-chamada.sh, 40P01 em 4 de 4 rodadas de cada):
--   28.  privado.fechar_turnos_e_vagas, vaga terminada com posição aberta: a pré-trava da
--        20261117190000 pega a vaga antes de cancelar as abertas (o parecer do B-071);
--   30a. privado.excluir_conta da casa de membro único, a mesma vaga: a exclusão pega as vagas por id
--        antes de tudo (20261117010000:79-94);
--   30b. a mesma exclusão numa vaga futura (anterior ao #567).
-- O comentário que justificava a ordem está velho: public.candidatar também pega a vaga antes da
-- posição, em privado.travar_candidatura (FOR UPDATE, 20260929153712), e o comentário do próprio
-- candidatar (20261107300000:598-600, "sempre posição e depois vaga") não foi atualizado. Não reescrevo
-- candidatar por causa de um comentário.
--
-- Conserto: depois do laço das confirmadas e antes do update das abertas, a trava da vaga, em toda
-- vaga. A ordem passa a ser confirmada -> vaga -> aberta:
--   · antes das abertas: a de candidatar, do fechamento e da exclusão;
--   · depois das confirmadas: privado.fechar_turnos_passados pega a confirmada que terminou antes da
--     vaga (20261112220000:215-279). Com a vaga no começo, como na direta, esse cruzamento fechava ciclo
--     (cenário 28b: 40P01 em 3 de 3 rodadas, medido com o corpo em pg_temp);
--   · FOR NO KEY UPDATE: o modo do update da vaga, logo abaixo, e o de privado.cancelar_uma_posicao na
--     confirmada futura (20261108070000:307-309). Em FOR UPDATE, a trava subiria de modo com um
--     candidato já na fila da vaga (cenário 29b).
-- Na vaga direta, a vaga já é desta transação desde o começo (B-035): a trava nova não espera nada.
-- Sem disputa, nada muda: os mesmos estados, a mesma resposta e os mesmos erros
-- (supabase/tests/890_cancelar_vaga_ordem_de_travas.sql). Na disputa com o fechamento, o cancelamento
-- espera a vaga e, depois dele, a cancela, o desfecho que a base já dava quando não fechava ciclo.
-- Resíduo conhecido, fora daqui: o cancelamento da vaga direta pega a vaga antes da confirmada
-- terminada, e o fechamento pega a confirmada antes da vaga (o parecer do B-071, anterior ao #567).
--
-- Corpo copiado de 20261117050000 (a última definição na develop; nenhum PR aberto a redefine,
-- conferido com git grep e gh pr diff), com só o bloco "B-072" e duas frases nos comentários.
-- Assinatura, SECURITY DEFINER, search_path vazio, resposta e grants iguais.

select set_config('lock_timeout', '2s', true);

-- contrato: corpo-sem-mudanca-de-superficie public.cancelar_vaga 0.2.105
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
  -- entra nas conferências abaixo. A vaga de publicação trava a vaga depois das confirmadas e
  -- antes das abertas (B-072, abaixo).
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

  -- B-072 (#572): a vaga antes das posições abertas, a ordem de quem pega as duas (candidatar por
  -- privado.travar_candidatura, o fechamento pela pré-trava, excluir_conta). Depois das
  -- confirmadas: o fechamento pega a confirmada que terminou antes da vaga. Em no key update, o
  -- modo do update da vaga logo abaixo e o de cancelar_uma_posicao na confirmada futura: a trava
  -- não sobe de modo. Na vaga direta, já travada lá em cima, não espera nada.
  perform 1 from public.vaga g where g.id = cancelar_vaga.vaga_id for no key update;

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
  'Cancela a vaga inteira, com motivo (RF14, RN12). Reenvio pelo mesmo contratante autor é idempotente e devolve 200 (0.2.35). Só o contratante membro da casa; as posições confirmadas são canceladas sem reabrir, e sem gerar falta para ninguém. Na vaga direta, trava a vaga antes das posições (a ordem do aceite), e as chamadas abertas vão a encerrada pelo gatilho vaga_cancelada_fecha_chamadas (B-035). Na de publicação, trava a vaga depois das confirmadas e antes das abertas (B-072, #572).';

revoke execute on function public.cancelar_vaga(uuid, text) from public, anon;
grant  execute on function public.cancelar_vaga(uuid, text) to authenticated;
