-- 20261111210000_checkin_semiautomatico_etapa1.sql
-- Check-in semiautomático com código — Etapa 1 (Direção de João Paulo, 10/11/2026).
--
-- Alinhamento com coordenação técnica (Codex) e frontend (Brasa):
-- 1. Fim da auto-verificação automática no fluxo com código: com `checkin_por_codigo` ligado,
--    o toque em `fazer_checkin` NUNCA marca `verificado` automaticamente, mesmo que sinais venham nil
--    (como em apps legados) ou a distância seja <= 50 m. O check-in fica manual e pendente.
-- 2. Renovação de proximidade e preservação de auditoria: se o profissional tocou Cheguei longe ou sem GPS,
--    ele pode tocar novamente para atualizar sua proximidade e o instante de recebimento no servidor
--    (`checkin_recebido_em`), preservando o instante inicial (`checkin_em`) e sem duplicar notificações (RF13).
-- 3. Trava de concorrência: `fazer_checkin` passa a travar a linha do turno com `FOR UPDATE`,
--    eliminando risco de corrida com validação ou confirmação manual.
-- 4. Elegibilidade de geração pelo relógio do servidor: a casa só gera o código se o profissional
--    registrou chegada recente (<= 15 min / 900 s por `checkin_recebido_em` do servidor) a até `raio_proximidade_m`
--    (50 m provisório). Se não houver chegada elegível, recusa canonicamente com `409 checkin_pendente`
--    (mapeado para `aguardandoChegada` no frontend, sem vazar localização do profissional para a casa).
-- 5. Validação rigorosa: `validar_codigo_checkin` exige que a distância informada na validação
--    seja NOT NULL e <= 50 m provisório (`raio_validacao_m`). Sem localização (distancia_m nula) JAMAIS
--    confirma presença neste fluxo.
-- 6. Preservação de legados: chave desligada mantém comportamento histórico. A confirmação manual
--    pela casa (`confirmar_checkin_manual`) permanece como alternativa disponível (decisão aberta de JP).

select set_config('lock_timeout', '2s', true);

-- ── 1. Parâmetros configuráveis de proximidade e frescor ───────────────────────

alter table privado.regra_checkin_codigo
  add column if not exists raio_proximidade_m integer not null default 50
    constraint raio_proximidade_entre_20_e_100 check (raio_proximidade_m between 20 and 100),
  add column if not exists validade_proximidade_s integer not null default 900
    constraint validade_proximidade_entre_1_e_60_min check (validade_proximidade_s between 60 and 3600);

comment on column privado.regra_checkin_codigo.raio_proximidade_m is
  'Raio máximo de proximidade em metros para a casa poder gerar/exibir o código do turno. Hipótese inicial provisória de 50 m (faixa configurável de 20 a 100 m, decisão de JP pendente).';
comment on column privado.regra_checkin_codigo.validade_proximidade_s is
  'Janela máxima de frescor da aproximação no servidor em segundos (hipótese provisória de 15 min / 900 s). Evita que um toque antigo libere a geração de código indefinidamente.';

-- Ajusta o raio de validação padrão de 100 para 50 m provisório
alter table privado.regra_checkin_codigo alter column raio_validacao_m set default 50;
update privado.regra_checkin_codigo
   set raio_validacao_m   = 50,
       raio_proximidade_m = 50
 where unica = true;

-- ── 2. Resposta do check-in com elegibilidade de proximidade e frescor ─────────

create or replace function privado.resposta_do_checkin(p_turno public.turno, p_codigo boolean) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
           'turno_id',      p_turno.id,
           'tipo',          p_turno.checkin_tipo,
           'verificacao',   p_turno.verificacao,
           'registrado_em', p_turno.checkin_em,
           'distancia_m',   p_turno.checkin_distancia_m)
      || case when p_codigo then jsonb_build_object(
           'codigo_exigido',    coalesce((select c.codigo_exigido from privado.checkin_codigo c
                                           where c.turno_id = p_turno.id), false),
           'codigo_disponivel', p_turno.verificacao = 'pendente'
                                and privado.estado_do_codigo(p_turno.id) <> 'encerrado'
                                and p_turno.checkin_distancia_m is not null
                                and p_turno.checkin_distancia_m <= coalesce((select r.raio_proximidade_m from privado.regra_checkin_codigo r), 50)
                                and p_turno.checkin_recebido_em is not null
                                and (privado.agora() - p_turno.checkin_recebido_em) <= make_interval(secs => coalesce((select r.validade_proximidade_s from privado.regra_checkin_codigo r), 900)))
         else '{}'::jsonb end
$$;
comment on function privado.resposta_do_checkin(public.turno, boolean) is
  'ResultadoRegistro do check-in. Com a chave do código ligada para a casa, acrescenta codigo_exigido (gravado) e codigo_disponivel (presença pendente, caminho não encerrado, proximidade elegível <= raio_proximidade_m e toque dentro da janela de frescor medida pelo relógio do servidor).';
revoke all on function privado.resposta_do_checkin(public.turno, boolean) from public, anon, authenticated;
grant execute on function privado.resposta_do_checkin(public.turno, boolean) to service_role;

-- ── 3. fazer_checkin com trava for update e renovação de proximidade ───────────
-- contrato: corpo-sem-mudanca-de-superficie public.fazer_checkin 0.2.73

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
  'Check-in do profissional (RF13, RN22). No fluxo semiautomático com código (chave checkin_por_codigo ligada), sinais nil jamais auto-verificam: presença fica sempre manual e pendente, gravando a distância para aferição de proximidade da casa (50 m provisório). Enquanto pendente, novo toque permite renovar a proximidade ao se aproximar. Trava for update no turno. Sem a chave (legado), até 200 m é geolocalizado e verificado na hora.';

revoke execute on function public.fazer_checkin(uuid, int, timestamptz, jsonb) from public, anon;
grant  execute on function public.fazer_checkin(uuid, int, timestamptz, jsonb) to authenticated;

-- ── 4. gerar_codigo_checkin alinhado ao contrato e sem vazar posição ───────────
-- contrato: corpo-sem-mudanca-de-superficie public.gerar_codigo_checkin 0.2.73

create or replace function public.gerar_codigo_checkin(turno_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid           uuid := (select auth.uid());
  v_agora         timestamptz := privado.agora();
  v_pos           public.posicao%rowtype;
  v_estab         uuid;
  v_t             public.turno%rowtype;
  v_c             privado.checkin_codigo%rowtype;
  v_validade      integer;
  v_sorteio       bigint;
  v_raio_prox     integer;
  v_validade_prox integer;
  v_estado        text;
  v_mensagem      text;
  c_teto_sem_vies constant bigint := 4294000000;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  if gerar_codigo_checkin.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  select p.* into v_pos
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = gerar_codigo_checkin.turno_id;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  v_estab := privado.estabelecimento_da_vaga(v_pos.vaga_id);

  if privado.bloqueado_com_estabelecimento(privado.usuario_do_profissional(v_pos.profissional_id), v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if not privado.eh_membro(v_estab) then
    perform public.erro(403, 'sem_permissao');
  end if;

  perform privado.exigir_recurso_para('checkin_por_codigo', v_estab);

  select * into v_t from public.turno t where t.id = gerar_codigo_checkin.turno_id for update;

  if v_t.verificacao = 'verificado' then
    perform public.erro(409, 'checkin_ja_confirmado');
  end if;

  if privado.estado_do_codigo(v_t.id) = 'encerrado' then
    perform public.erro(409, 'codigo_bloqueado', 'encerrado');
  end if;

  perform privado.exigir_janela(v_agora, v_pos.inicio_em, v_pos.fim_em);

  -- ELEGIBILIDADE DE PROXIMIDADE E FRESCOR (Servidor):
  -- Avalia checkin_recebido_em pelo relógio do servidor (v_agora).
  -- Se o profissional não tocou, tocou longe (> 50 m provisório), tocou sem posição ou a aproximação
  -- no servidor expirou (> validade_proximidade_s):
  -- responde canonicamente 409 checkin_pendente (mapeado para aguardandoChegada no frontend iOS de Brasa,
  -- sem vazar para a casa a distância ou localização do profissional).
  select r.raio_proximidade_m, r.validade_proximidade_s
    into v_raio_prox, v_validade_prox
    from privado.regra_checkin_codigo r;
  v_raio_prox     := coalesce(v_raio_prox, 50);
  v_validade_prox := coalesce(v_validade_prox, 900);

  if v_t.checkin_em is null
     or v_t.checkin_distancia_m is null
     or v_t.checkin_distancia_m > v_raio_prox
     or v_t.checkin_recebido_em is null
     or (v_agora - v_t.checkin_recebido_em) > make_interval(secs => v_validade_prox) then
    perform public.erro(409, 'checkin_pendente');
  end if;

  begin
    insert into privado.checkin_codigo (turno_id) values (v_t.id) on conflict (turno_id) do nothing;
    select * into v_c from privado.checkin_codigo c where c.turno_id = v_t.id for update;

    if v_c.codigo is null or v_c.expira_em <= v_agora then
      v_validade := coalesce((select r.validade_s from privado.regra_checkin_codigo r), 300);
      loop
        v_sorteio := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;
        exit when v_sorteio < c_teto_sem_vies;
      end loop;

      update privado.checkin_codigo c
         set codigo    = lpad((v_sorteio % 1000000)::text, 6, '0'),
             gerado_em = v_agora,
             expira_em = v_agora + make_interval(secs => v_validade)
       where c.turno_id = v_t.id
      returning * into v_c;
    end if;
  exception when integrity_constraint_violation then
    get stacked diagnostics v_estado = returned_sqlstate, v_mensagem = message_text;
    raise exception using errcode = v_estado, message = v_mensagem;
  end;

  return jsonb_build_object(
    'turno_id',           v_t.id,
    'codigo',             v_c.codigo,
    'expira_em',          v_c.expira_em,
    'segundos_restantes', greatest(0, least(300, floor(extract(epoch from (v_c.expira_em - v_agora))))::integer));
end $$;

comment on function public.gerar_codigo_checkin(uuid) is
  'Casa gera ou revê o código de check-in de 6 dígitos do turno (fluxo semiautomático 0.2.68+). Exige chegada elegível do profissional a até 50 m provisório e nos últimos 15 min pelo servidor. Sem chegada elegível: 409 checkin_pendente (aguardandoChegada). Trava for update no turno.';

revoke execute on function public.gerar_codigo_checkin(uuid) from public, anon;
grant  execute on function public.gerar_codigo_checkin(uuid) to authenticated;

-- ── 5. validar_codigo_checkin: sem confirmação sem localização ─────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.validar_codigo_checkin 0.2.73

create or replace function public.validar_codigo_checkin(turno_id uuid, codigo text, distancia_m integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_agora     timestamptz := privado.agora();
  v_pos       public.posicao%rowtype;
  v_estab     uuid;
  v_t         public.turno%rowtype;
  v_c         privado.checkin_codigo%rowtype;
  v_em_vigor  boolean;
  v_raio      integer;
  v_resultado text;
  v_estado    text;
  v_sqlstate  text;
  v_mensagem  text;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('profissional');

  if validar_codigo_checkin.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  if validar_codigo_checkin.codigo is null then
    perform public.erro(422, 'campo_obrigatorio', 'codigo');
  end if;
  if validar_codigo_checkin.codigo !~ '^[0-9]{6}$' then
    perform public.erro(422, 'campo_invalido', 'codigo');
  end if;
  if validar_codigo_checkin.distancia_m < 0 then
    perform public.erro(422, 'campo_invalido', 'distancia_m');
  end if;

  v_pos := privado.turno_do_profissional(validar_codigo_checkin.turno_id);
  if v_pos.id is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  v_estab := privado.estabelecimento_da_vaga(v_pos.vaga_id);

  if privado.bloqueado_com_estabelecimento(v_uid, v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  perform privado.exigir_recurso_para('checkin_por_codigo', v_estab);

  select * into v_t from public.turno t where t.id = validar_codigo_checkin.turno_id for update;

  if v_t.checkin_em is null then
    perform public.erro(409, 'checkin_pendente');
  end if;

  if v_t.verificacao = 'verificado' then
    perform public.erro(409, 'checkin_ja_confirmado');
  end if;

  perform privado.exigir_janela(v_agora, v_pos.inicio_em, v_pos.fim_em);

  v_estado := privado.estado_do_codigo(v_t.id);
  if v_estado in ('temporario', 'encerrado') then
    perform public.erro(409, 'codigo_bloqueado', v_estado);
  end if;

  select * into v_c from privado.checkin_codigo c where c.turno_id = v_t.id for update;

  v_em_vigor := v_c.codigo is not null and v_c.expira_em > v_agora;
  v_raio     := coalesce((select r.raio_validacao_m from privado.regra_checkin_codigo r), 50);

  -- NOVO FLUXO SEMIAUTOMÁTICO (Direção JP / Codex 10/11/2026):
  -- Somente validação com código em vigor e distância INFORMADA (not null) a até raio_validacao_m (50 m provisório)
  -- confirma presença. Sem localização (distancia_m nula) JAMAIS confirma presença no novo fluxo.
  if v_em_vigor
     and v_c.codigo = validar_codigo_checkin.codigo
     and validar_codigo_checkin.distancia_m is not null
     and validar_codigo_checkin.distancia_m <= v_raio then
    begin
      update privado.checkin_codigo c
         set codigo          = null,
             confianca_baixa = false
       where c.turno_id = v_t.id;
      insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa, codigo_gerado_em)
      values (v_t.id, v_agora, 'aceita', privado.faixa_da_leitura(validar_codigo_checkin.distancia_m), v_c.gerado_em);
    exception when integrity_constraint_violation then
      get stacked diagnostics v_sqlstate = returned_sqlstate, v_mensagem = message_text;
      raise exception using errcode = v_sqlstate, message = v_mensagem;
    end;

    update public.turno t
       set checkin_tipo          = 'codigo',
           verificacao           = 'verificado',
           checkin_confirmado_em = v_agora
     where t.id = v_t.id
    returning * into v_t;

    perform privado.recalcular_comparecimento(v_pos.profissional_id);

    perform privado.notificar_membros(v_estab, 'checkin'::public.tipo_notificacao, v_t.id,
      jsonb_build_object('turno_id', v_t.id, 'vaga_id', v_pos.vaga_id));

    return privado.resposta_do_checkin(v_t, false);
  end if;

  -- Tentativa recusada: código errado, vencido, sem localização (null) ou distância > 50 m.
  -- Conta como erro, grava em checkin_codigo_tentativa e responde 422 ou 409 (bloqueio).
  begin
    v_resultado := privado.registrar_erro_codigo(v_t.id);
    insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa, codigo_gerado_em)
    values (v_t.id, v_agora, 'recusada', privado.faixa_da_leitura(validar_codigo_checkin.distancia_m),
            case when v_em_vigor then v_c.gerado_em end);
  exception when integrity_constraint_violation then
    get stacked diagnostics v_sqlstate = returned_sqlstate, v_mensagem = message_text;
    raise exception using errcode = v_sqlstate, message = v_mensagem;
  end;

  if v_resultado = 'invalido' then
    perform set_config('response.status', '422', true);
    return jsonb_build_object('code', 'codigo_invalido', 'message', 'codigo_invalido', 'details', null, 'hint', null);
  end if;
  perform set_config('response.status', '409', true);
  return jsonb_build_object('code', 'codigo_bloqueado', 'message', 'codigo_bloqueado', 'details', v_resultado, 'hint', null);
end $$;

comment on function public.validar_codigo_checkin(uuid, text, integer) is
  'Validação de código de check-in pelo profissional (0.2.68+, RN22, RN46). Raio de validação provisório de 50 m (regra_checkin_codigo.raio_validacao_m). Sem localização (distancia_m nulo) ou distância excessiva não confirma presença (recusado com 422 codigo_invalido). Trava for update no turno.';

revoke execute on function public.validar_codigo_checkin(uuid, text, integer) from public, anon;
grant  execute on function public.validar_codigo_checkin(uuid, text, integer) to authenticated;
