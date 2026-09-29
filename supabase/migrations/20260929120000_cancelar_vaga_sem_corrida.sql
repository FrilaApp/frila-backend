-- `cancelar_vaga × candidatar` sem corrida (cartão nspP9YDU, RNF14).
--
-- Medido em `scripts/corrida-ciclo.sh`, cenário 2: com a casa cancelando a vaga no mesmo
-- instante em que um profissional aceita a última posição, 19 de 50 rodadas terminavam
-- com a vaga `cancelada` e a posição do candidato `confirmada` — o turno de pé numa vaga
-- que não existe mais, sem aviso a ninguém.
--
-- O caminho: `candidatar` confirma a posição e segura a linha até o commit. O laço das
-- confirmadas de `cancelar_vaga` lê um snapshot que ainda não tem essa confirmação. O
-- `update` das abertas chega à linha, espera o commit do candidato, relê a linha, vê que
-- ela já não é `aberta` e a pula. A vaga é cancelada por cima.
--
-- A correção é de ordem, e não de regra:
--
--   1. trava todas as posições da vaga, por id, antes de ler qualquer estado. A
--      candidatura em curso termina antes (a trava espera o commit dela); a que chega
--      depois pula a linha travada (`skip locked`) e recebe `posicao_ja_preenchida`;
--   2. relê a vaga depois da trava: o estado lido antes dela pode ter mudado;
--   3. cancela as abertas **antes** das confirmadas. Cada comando lê um snapshot novo,
--      e o laço das confirmadas, rodando por último, vê a confirmação que o passo das
--      abertas esperou terminar;
--   4. só então cancela a vaga.
--
-- A ordem de aquisição continua posição e depois vaga, a mesma de `candidatar`,
-- `cancelar_posicao` e `reabrir_por_atraso`: nenhuma espera em ciclo. A vaga não é
-- travada antes das abertas de propósito — `candidatar` segura a posição e espera a
-- vaga, e travar a vaga antes seria o impasse.
--
-- Não entra gatilho em `vaga` recusando "cancelada com confirmada": `excluir_conta`
-- cancela a vaga preenchida e deixa o turno em andamento seguir até o fim, por decisão
-- de produto registrada lá. A garantia é do caminho de `cancelar_vaga`, e é ele que muda.

create or replace function public.cancelar_vaga(vaga_id uuid, motivo text)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_motivo text := btrim(cancelar_vaga.motivo);
  v        public.vaga%rowtype;
  v_pos    uuid;
  v_abertas int := 0;
  v_confirmadas int := 0;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
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

  -- A permissão vem antes da trava: quem não é da casa não segura linha de ninguém.
  if not privado.eh_membro(v.estabelecimento_id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- (1) A trava das posições, sempre na mesma ordem.
  perform 1 from public.posicao p
   where p.vaga_id = cancelar_vaga.vaga_id
   order by p.id
     for update;

  -- (2) O estado que vale é o de depois da trava. Duas casas cancelando juntas: a
  -- segunda espera a primeira e recebe `vaga_encerrada`, e não um segundo sucesso.
  select * into v from public.vaga g where g.id = cancelar_vaga.vaga_id;

  if v.estado in ('cancelada', 'encerrada') then
    perform public.erro(409, 'vaga_encerrada');
  end if;

  -- (3) As abertas primeiro. As confirmadas passam pelo mesmo caminho do cancelamento
  -- avulso, e **sem** reabrir: a vaga inteira está saindo do ar. Cancelamento pelo
  -- contratante não gera falta para ninguém, e é o autor que decide isso lá dentro.
  update public.posicao p
     set estado = 'cancelada'
   where p.vaga_id = cancelar_vaga.vaga_id and p.estado = 'aberta';
  get diagnostics v_abertas = row_count;

  for v_pos in select p.id from public.posicao p
                where p.vaga_id = cancelar_vaga.vaga_id and p.estado = 'confirmada'
                order by p.id
  loop
    perform privado.cancelar_uma_posicao(v_pos, v_uid, v_motivo, false);
    v_confirmadas := v_confirmadas + 1;
  end loop;

  -- (4) A vaga por último.
  update public.vaga g set estado = 'cancelada' where g.id = cancelar_vaga.vaga_id;

  -- Os três campos do contrato, e só eles.
  return jsonb_build_object(
    'vaga_id',             v.id,
    'estado',              'cancelada',
    'posicoes_canceladas', v_abertas + v_confirmadas);
end $$;

comment on function public.cancelar_vaga(uuid, text) is
  'Cancela a vaga inteira, com motivo (RF14, RN12). Só o contratante membro da casa; as posições confirmadas são canceladas sem reabrir, e sem gerar falta para ninguém. Trava as posições antes de ler o estado: a candidatura simultânea termina antes e é cancelada junto, ou chega depois e é recusada (RNF14, nspP9YDU).';

revoke execute on function public.cancelar_vaga(uuid, text) from public, anon;
grant execute on function public.cancelar_vaga(uuid, text) to authenticated;
