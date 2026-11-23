select set_config('lock_timeout', '2s', true);

-- ── fazer_checkout com recusa de toque recebido após fim + 60 min ─────────────
-- contrato: corpo-sem-mudanca-de-superficie public.fazer_checkout 0.2.82
-- Decisão do JP (14/11/2026): tolerância zero no check-out. O toque de check-out
-- que chegar ao servidor após fim_em + 60 min é recusado com 422 fora_da_janela,
-- mesmo que o aparelho informe registrado_em dentro da janela. Conta de demonstração
-- continua atravessando a janela.

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
  v_uid   uuid := (select auth.uid());
  v_agora timestamptz := privado.agora();
  v_pos   public.posicao%rowtype;
  v_t     public.turno%rowtype;
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

  -- Trava de concorrência com FOR UPDATE para serializar execuções e evitar corridas
  select * into v_t from public.turno t where t.id = fazer_checkout.turno_id for update;

  -- Encerrar um turno que nunca começou não é registro de saída, é engano. O código
  -- diz qual é o passo que falta, para a tela poder levar a pessoa até ele.
  if v_t.checkin_em is null then
    perform public.erro(409, 'checkin_pendente');
  end if;

  perform privado.exigir_janela_checkout(fazer_checkout.registrado_em,
                                         v_pos.inicio_em, v_pos.fim_em);

  -- Decisão do JP (14/11/2026): tolerância zero no check-out. O toque que chega ao servidor
  -- após fim_em + 60 min é recusado com 422 fora_da_janela, mesmo que o celular informe
  -- registrado_em dentro da janela. Usa o mesmo intervalo de 60 minutos de exigir_janela_checkout.
  if not privado.conta_de_demonstracao() and v_agora > (v_pos.fim_em + interval '60 minutes') then
    perform public.erro(422, 'fora_da_janela');
  end if;

  -- Idempotência: reenvio dentro da janela devolve o registro já gravado
  if v_t.checkout_em is not null then
    return jsonb_build_object(
      'turno_id',      v_t.id,
      'tipo',          coalesce(v_t.checkin_tipo, 'manual'),
      'verificacao',   v_t.verificacao,
      'registrado_em', v_t.checkout_em,
      'distancia_m',   v_t.checkout_distancia_m);
  end if;

  if fazer_checkout.distancia_m is not null and fazer_checkout.distancia_m < 0 then
    perform public.erro(422, 'campo_invalido', 'distancia_m');
  end if;

  update public.turno t
     set checkout_em          = fazer_checkout.registrado_em,
         checkout_recebido_em = v_agora,
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
  'Registra a saída do profissional no turno. A localização é lida só no toque e só a distância é gravada. Toque recebido após 60 minutos do término previsto do turno (fim_em + 60 min) é recusado com 422 fora_da_janela (tolerância zero, 0.2.83); conta de demonstração atravessa.';

revoke execute on function public.fazer_checkout(uuid, int, timestamptz) from public, anon;
grant  execute on function public.fazer_checkout(uuid, int, timestamptz) to authenticated;
