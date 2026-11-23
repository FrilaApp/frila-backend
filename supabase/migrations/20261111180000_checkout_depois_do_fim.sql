-- contrato: corpo-sem-mudanca-de-superficie public.fazer_checkout 0.2.73

-- ── Janela estendida do check-out (tolerância de até 60 minutos pós-fim) ──────
--
-- Corrige o bug em que privado.exigir_janela impunha teto rígido em v_pos.fim_em,
-- recusando com 422 fora_da_janela qualquer check-out registrado após o fim nominal
-- do turno.
--
-- Regras mantidas:
-- 1. Check-in continua usando privado.exigir_janela (rejeita após o fim nominal).
-- 2. Check-out antecipado continua aceito desde 60 minutos antes do início (mesmo piso).
-- 3. registro_no_futuro (+2 min em relação ao relógio do servidor) continua estritamente ativo.
-- 4. Contas de demonstração da App Store continuam atravessando a janela.

create or replace function privado.exigir_janela_checkout(
  registrado_em timestamptz,
  inicio        timestamptz,
  fim           timestamptz
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if registrado_em is null then
    perform public.erro(422, 'campo_obrigatorio', 'registrado_em');
  end if;

  -- Dois minutos de folga para o relógio do aparelho adiantado
  if registrado_em > privado.agora() + interval '2 minutes' then
    perform public.erro(422, 'registro_no_futuro');
  end if;

  -- A conta de revisão da App Store atravessa a janela
  if privado.conta_de_demonstracao() then
    return;
  end if;

  -- Janela do check-out: de 60 min antes do início previsto até 60 min após o fim previsto.
  if registrado_em < (inicio - interval '60 minutes') or registrado_em > (fim + interval '60 minutes') then
    perform public.erro(422, 'fora_da_janela');
  end if;
end $$;

comment on function privado.exigir_janela_checkout(timestamptz, timestamptz, timestamptz) is
  'A janela do registro de saída (check-out): de 60 min antes do início até 60 min após o fim previsto, com 2 min de folga para relógio adiantado. Conta de demonstração atravessa.';

revoke execute on function privado.exigir_janela_checkout(timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function privado.exigir_janela_checkout(timestamptz, timestamptz, timestamptz) to service_role;

-- ── Atualiza fazer_checkout para usar privado.exigir_janela_checkout ───────────

create or replace function public.fazer_checkout(
  turno_id      uuid,
  distancia_m   int         default null,
  registrado_em timestamptz default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
  v_pos public.posicao%rowtype;
  v_t   public.turno%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if fazer_checkout.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  v_pos := privado.turno_do_profissional(fazer_checkout.turno_id);
  if v_pos.id is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  select * into v_t from public.turno t where t.id = fazer_checkout.turno_id;

  if v_t.checkout_em is not null then
    return jsonb_build_object(
      'turno_id',      v_t.id,
      'tipo',          coalesce(v_t.checkin_tipo, 'manual'),
      'verificacao',   v_t.verificacao,
      'registrado_em', v_t.checkout_em,
      'distancia_m',   v_t.checkout_distancia_m);
  end if;

  -- Encerrar um turno que nunca começou não é registro de saída, é engano. O código
  -- diz qual é o passo que falta, para a tela poder levar a pessoa até ele.
  if v_t.checkin_em is null then
    perform public.erro(409, 'checkin_pendente');
  end if;

  perform privado.exigir_janela_checkout(fazer_checkout.registrado_em,
                                         v_pos.inicio_em, v_pos.fim_em);

  if fazer_checkout.distancia_m is not null and fazer_checkout.distancia_m < 0 then
    perform public.erro(422, 'campo_invalido', 'distancia_m');
  end if;

  update public.turno t
     set checkout_em          = fazer_checkout.registrado_em,
         checkout_recebido_em = privado.agora(),
         checkout_distancia_m = fazer_checkout.distancia_m
   where t.id = fazer_checkout.turno_id
  returning * into v_t;

  return jsonb_build_object(
    'turno_id',      v_t.id,
    'tipo',          v_t.checkin_tipo,
    'verificacao',   v_t.verificacao,
    'registrado_em', v_t.checkout_em,
    'distancia_m',   v_t.checkout_distancia_m);
end $$;

comment on function public.fazer_checkout(uuid, int, timestamptz) is
  'Registra a saída do profissional no turno. A localização é lida só no toque e só a distância é gravada. Aceita registros até 60 minutos após o fim previsto do turno.';

revoke execute on function public.fazer_checkout(uuid, int, timestamptz) from public, anon;
grant execute on function public.fazer_checkout(uuid, int, timestamptz) to authenticated;
