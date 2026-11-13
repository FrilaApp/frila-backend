select set_config('lock_timeout', '2s', true);

-- ── fazer_checkin com recusa de toque recebido após o fim do turno ───────────
-- contrato: corpo-sem-mudanca-de-superficie public.fazer_checkin 0.2.82
-- Decisão do JP (13/11/2026): tolerância zero. O toque de check-in que chegar ao
-- servidor após o fim previsto do turno (fim_em) é recusado com 422 fora_da_janela,
-- mesmo que o aparelho informe registrado_em dentro da janela. Conta de demonstração
-- continua atravessando a janela.

create or replace function public.fazer_checkin(
  turno_id      uuid,
  distancia_m   int         default null,
  registrado_em timestamptz default null,
  sinais        jsonb       default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid          uuid := (select auth.uid());
  v_agora        timestamptz := privado.agora();
  v_pos          public.posicao%rowtype;
  v_t            public.turno%rowtype;
  v_tipo         public.tipo_registro;
  v_ver          public.verificacao_turno;
  v_codigo       boolean;           -- a chave do código vale para a casa do turno
  v_exigido      boolean := false;
  v_ja_registrou boolean := false;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if fazer_checkin.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  v_pos := privado.turno_do_profissional(fazer_checkin.turno_id);
  if v_pos.id is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Trava de concorrência com FOR UPDATE para serializar execuções e evitar corridas
  select * into v_t from public.turno t where t.id = fazer_checkin.turno_id for update;
  v_codigo := privado.recurso_ligado_para('checkin_por_codigo',
                                          privado.estabelecimento_da_vaga(v_pos.vaga_id));

  -- Se já estiver verificado por qualquer caminho, o registro é imutável: devolve imediatamente
  if v_t.verificacao = 'verificado' then
    return privado.resposta_do_checkin(v_t, v_codigo);
  end if;

  -- Para fluxo legado (chave desligada), idempotência clássica: reenviar devolve o gravado
  if not v_codigo and v_t.checkin_em is not null then
    return privado.resposta_do_checkin(v_t, v_codigo);
  end if;

  perform privado.exigir_janela(fazer_checkin.registrado_em, v_pos.inicio_em, v_pos.fim_em);

  -- Decisão do JP (13/11/2026): tolerância zero. O toque que chega ao servidor após o fim previsto
  -- do turno é recusado com 422 fora_da_janela, mesmo que o celular diga que foi feito dentro da janela.
  if not privado.conta_de_demonstracao() and v_agora > v_pos.fim_em then
    perform public.erro(422, 'fora_da_janela');
  end if;

  if fazer_checkin.distancia_m is not null and fazer_checkin.distancia_m < 0 then
    perform public.erro(422, 'campo_invalido', 'distancia_m');
  end if;

  if v_codigo and fazer_checkin.sinais is not null
     and not privado.sinais_validos(fazer_checkin.sinais) then
    perform public.erro(422, 'campo_invalido', 'sinais');
  end if;

  v_ja_registrou := (v_t.checkin_em is not null);

  -- NOVO FLUXO SEMIAUTOMÁTICO (Direção JP 10/11/2026):
  -- Quando checkin_por_codigo está ligado, sinais nil JAMAIS auto-verificam.
  -- A presença NUNCA é verificada automaticamente pelo toque no app: fica sempre
  -- manual e pendente com codigo_exigido = true.
  -- Se o profissional já tinha tocado longe ou sem GPS, este novo toque renova a proximidade
  -- e o timestamp de recepção do servidor (checkin_recebido_em), preservando o instante inicial (checkin_em).
  if v_codigo then
    v_tipo    := 'manual';
    v_ver     := 'pendente';
    v_exigido := true;
  else
    if fazer_checkin.distancia_m is not null and fazer_checkin.distancia_m <= 200 then
      v_tipo := 'geolocalizado';
      v_ver  := 'verificado';
    else
      v_tipo := 'manual';
      v_ver  := 'pendente';
    end if;
    v_exigido := false;
  end if;

  update public.turno t
     set -- Preserva o instante original da 1ª chegada se já registrado; caso contrário usa o informado ou servidor
         checkin_em          = coalesce(v_t.checkin_em, fazer_checkin.registrado_em, v_agora),
         -- checkin_recebido_em atualiza para v_agora no servidor (renovando a janela de frescor de elegibilidade):
         checkin_recebido_em = v_agora,
         checkin_tipo        = v_tipo,
         checkin_distancia_m = case when v_tipo = 'geolocalizado' or v_codigo
                                    then fazer_checkin.distancia_m else null end,
         verificacao         = v_ver
   where t.id = fazer_checkin.turno_id
  returning * into v_t;

  if v_exigido then
    insert into privado.checkin_codigo (turno_id, codigo_exigido) values (v_t.id, true)
      on conflict (turno_id) do update set codigo_exigido = true;
  end if;

  if v_ver = 'verificado' then
    perform privado.recalcular_comparecimento(v_pos.profissional_id);
  end if;

  -- RF13: Notifica membros do estabelecimento apenas no primeiro registro (sem duplicar notificações em reenvios)
  if not v_ja_registrou then
    perform privado.notificar_membros(
      privado.estabelecimento_da_vaga(v_pos.vaga_id),
      case when v_ver = 'verificado' then 'checkin'
           else 'checkin_manual_pendente' end::public.tipo_notificacao,
      v_t.id,
      jsonb_build_object('turno_id', v_t.id, 'vaga_id', v_pos.vaga_id));
  end if;

  return privado.resposta_do_checkin(v_t, v_codigo);
end $$;

comment on function public.fazer_checkin(uuid, int, timestamptz, jsonb) is
  'Check-in do profissional (RF13, RN22). Toque recebido após o término previsto do turno é recusado com 422 fora_da_janela (tolerância zero, 0.2.80); conta de demonstração atravessa. No fluxo semiautomático com código (chave checkin_por_codigo ligada), sinais nil jamais auto-verificam: presença fica sempre manual e pendente, gravando a distância para aferição de proximidade da casa (50 m provisório). Enquanto pendente, novo toque permite renovar a proximidade ao se aproximar. Trava for update no turno. Sem a chave (legado), até 200 m é geolocalizado e verificado na hora.';

revoke execute on function public.fazer_checkin(uuid, int, timestamptz, jsonb) from public, anon;
grant  execute on function public.fazer_checkin(uuid, int, timestamptz, jsonb) to authenticated;
