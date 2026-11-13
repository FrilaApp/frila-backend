-- Recusa própria para fora do raio e sem localização em validar_codigo_checkin (0.2.76, RF13, RN22, RN46).
-- Decisão JP (12/11/2026, achado A2):
--   - A distância é conferida ANTES de comparar o código digitado.
--   - Sem posição (distancia_m nulo): recusa própria 422 sem_localizacao (app orienta confirmação manual).
--   - Acima de raio_validacao_m (50 m provisório): recusa própria 422 fora_do_raio (app orienta aproximar-se).
--   - Nenhuma das duas olha o código nem avança o contador de erros 3/6 nem aciona bloqueio.
--   - Bloqueio vigente (409 codigo_bloqueado) continua vencendo antes de tudo.
--   - Grava em privado.checkin_codigo_tentativa com resultado 'recusada_sem_conferir' e a respectiva faixa.
--   - Teto contra inundação: no máximo uma linha 'recusada_sem_conferir' a cada 60 s por turno
--     (mantendo a resposta 422 em todas as chamadas).

-- ── 1. Restrições e comentários de privado.checkin_codigo_tentativa ───────────

alter table privado.checkin_codigo_tentativa
  drop constraint tentativa_resultado,
  add constraint tentativa_resultado check (resultado in ('aceita', 'recusada', 'recusada_sem_conferir'));

alter table privado.checkin_codigo_tentativa
  drop constraint aceita_com_codigo_e_perto,
  add constraint aceita_com_codigo_e_perto check (
    resultado <> 'aceita' or (codigo_gerado_em is not null and faixa <> 'acima_de_100_m'));

comment on table privado.checkin_codigo_tentativa is
  'Cada leitura do código de check-in registrada no turno. O resultado distingue as que contaram como tentativa errada (recusada) daquelas recusadas previamente por falta de posição ou fora do raio (recusada_sem_conferir), que não contam para bloqueio 3/6. Sai com a linha de privado.checkin_codigo, em cascata. Sai na exportação do profissional (MeusDados).';

comment on column privado.checkin_codigo_tentativa.resultado is
  'aceita, recusada (código incorreto/expirado dentro do raio) ou recusada_sem_conferir (recusa prévia por sem_posicao ou distância > raio).';

-- ── 2. Função public.validar_codigo_checkin ───────────────────────────────────

create or replace function public.validar_codigo_checkin(turno_id uuid, codigo text, distancia_m integer)
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
  v_em_vigor      boolean;
  v_raio          integer;
  v_resultado     text;
  v_estado        text;
  v_sqlstate      text;
  v_mensagem      text;
  v_ultima_recusa timestamptz;
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

  -- Bloqueio vigente vence antes de qualquer checagem de código ou distância (409 codigo_bloqueado)
  v_estado := privado.estado_do_codigo(v_t.id);
  if v_estado in ('temporario', 'encerrado') then
    perform public.erro(409, 'codigo_bloqueado', v_estado);
  end if;

  select * into v_c from privado.checkin_codigo c where c.turno_id = v_t.id for update;

  v_em_vigor := v_c.codigo is not null and v_c.expira_em > v_agora;
  v_raio     := coalesce((select r.raio_validacao_m from privado.regra_checkin_codigo r), 50);

  -- CONFERÊNCIA PRÉVIA DE LOCALIZAÇÃO (Decisão JP 12/11/2026, achado A2):
  -- A distância é conferida ANTES de comparar o código digitado.
  -- Sem localização (null) ou acima de raio_validacao_m (50 m): recusa própria 422,
  -- SEM comparar o código, SEM contar tentativa errada no contador 3/6 e SEM acionar bloqueio.
  if validar_codigo_checkin.distancia_m is null or validar_codigo_checkin.distancia_m > v_raio then
    -- Teto contra inundação: grava no máximo uma linha 'recusada_sem_conferir' a cada 60 s por turno.
    select max(ct.em) into v_ultima_recusa
      from privado.checkin_codigo_tentativa ct
     where ct.turno_id = v_t.id
       and ct.resultado = 'recusada_sem_conferir';

    if v_ultima_recusa is null or v_ultima_recusa <= v_agora - interval '60 seconds' then
      begin
        insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa, codigo_gerado_em)
        values (v_t.id, v_agora, 'recusada_sem_conferir', privado.faixa_da_leitura(validar_codigo_checkin.distancia_m),
                case when v_em_vigor then v_c.gerado_em end);
      exception when integrity_constraint_violation then
        get stacked diagnostics v_sqlstate = returned_sqlstate, v_mensagem = message_text;
        raise exception using errcode = v_sqlstate, message = v_mensagem;
      end;
    end if;

    perform set_config('response.status', '422', true);
    if validar_codigo_checkin.distancia_m is null then
      return jsonb_build_object('code', 'sem_localizacao', 'message', 'sem_localizacao', 'details', null, 'hint', null);
    else
      return jsonb_build_object('code', 'fora_do_raio', 'message', 'fora_do_raio', 'details', null, 'hint', null);
    end if;
  end if;

  -- Checagem com posição válida a até raio_validacao_m (50 m):
  if v_em_vigor and v_c.codigo = validar_codigo_checkin.codigo then
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

  -- Tentativa recusada dentro do raio: código errado, vencido ou de outro turno.
  -- Conta como erro no contador 3/6, grava em checkin_codigo_tentativa e responde 422 ou 409 (bloqueio).
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
  'Validação de código de check-in pelo profissional (0.2.76, RN22, RN46). Raio de validação provisório de 50 m (regra_checkin_codigo.raio_validacao_m). Distância conferida antes do código: sem localização (distancia_m nulo) recusa 422 sem_localizacao e distância > 50 m recusa 422 fora_do_raio, ambas sem contar tentativa errada no 3/6 nem bloquear, com teto de gravação a cada 60 s. Dentro do raio, código divergente/vencido conta erro (422 codigo_invalido ou 409 codigo_bloqueado). Trava for update no turno.';

revoke execute on function public.validar_codigo_checkin(uuid, text, integer) from public, anon;
grant  execute on function public.validar_codigo_checkin(uuid, text, integer) to authenticated;
