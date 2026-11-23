-- Migração: 20261111201000_validar_codigo_checkin.sql
-- Escopo: B-CHECKIN-BACK, PR6 (contrato 0.2.68, `validarCodigoCheckin`; plano em
-- orquestracao/retornos/B-CHECKIN-BACK-plano.md, seção 2, PR6).
--
-- O profissional valida o código que a casa mostra, depois de um fazer_checkin que ficou pendente.
-- Código em vigor, deste turno, lido a até raio_validacao_m (100 m), ou sem posição: o turno vira
-- `codigo` e `verificado`, com checkin_confirmado_em igual à hora da validação, e os membros da casa
-- recebem o aviso `checkin`. Qualquer outro caso conta como tentativa errada.
--
-- Decisões que valem aqui (plano e Forja, 08/11/2026):
--   · D2: as três recusas que gravam (422 codigo_invalido; 409 codigo_bloqueado na 3ª e na 6ª) não dão
--     raise, porque o raise desfaria a tentativa, o contador e o bloqueio. Gravam, põem response.status
--     (GUC da PostgREST) e devolvem o envelope {code, message, details, hint} de public.erro. A S0 mediu
--     na PostgREST v14.3: HTTP 422 e 409, o mesmo corpo e a linha gravada;
--   · as recusas que não gravam (401, 403, 404, 409 e 422 de formato, estado e janela) seguem por
--     public.erro, sem tocar no contador;
--   · `for update` no turno antes de ler o estado: duas leituras do mesmo código não validam as duas;
--   · a validade vale pelo expira_em, e nunca pela presença do valor, que vive até 1 minuto depois de
--     vencer (D4);
--   · raio_validacao_m com coalesce(…, 100), como a validade no gerar (R1 do Lince no #458);
--   · o código nunca sai num erro (R2 do Lince no #458): as escritas em privado.checkin_codigo capturam a
--     classe 23 inteira e reerguem o mesmo SQLSTATE com a mesma mensagem, sem o DETAIL, que traria a
--     linha com os 6 dígitos;
--   · a janela é a do check-in, pelo relógio do servidor; a conta de demonstração a atravessa (D9).
--
-- A vigia do contrato (VIGIADAS e os cenários do harness) fica para o PR7: o harness vê a recusa pela
-- exceção, e esta função recusa por response.status. Até lá, validarCodigoCheckin segue em PENDENTES.

create function public.validar_codigo_checkin(turno_id uuid, codigo text, distancia_m integer)
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

  -- Conta anonimizada (RF25): 401. Suspensa: 403 conta_suspensa. Contratante: 422 perfil_incompativel.
  perform privado.exigir_perfil('profissional');

  if validar_codigo_checkin.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  -- O formato não conta como tentativa: quem digita 5 dígitos não errou o código.
  if validar_codigo_checkin.codigo is null then
    perform public.erro(422, 'campo_obrigatorio', 'codigo');
  end if;
  if validar_codigo_checkin.codigo !~ '^[0-9]{6}$' then
    perform public.erro(422, 'campo_invalido', 'codigo');
  end if;
  if validar_codigo_checkin.distancia_m < 0 then
    perform public.erro(422, 'campo_invalido', 'distancia_m');
  end if;

  -- O turno que não existe e o de outro profissional respondem igual: um 403 diria que ele existe.
  v_pos := privado.turno_do_profissional(validar_codigo_checkin.turno_id);
  if v_pos.id is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  v_estab := privado.estabelecimento_da_vaga(v_pos.vaga_id);

  -- Bloqueio entre o profissional e a casa (RF26): o turno some para os dois lados.
  if privado.bloqueado_com_estabelecimento(v_uid, v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- RN46: com a chave desligada para a casa, nada é escrito e o contador não anda.
  perform privado.exigir_recurso_para('checkin_por_codigo', v_estab);

  select * into v_t from public.turno t where t.id = validar_codigo_checkin.turno_id for update;

  if v_t.checkin_em is null then
    perform public.erro(409, 'checkin_pendente');
  end if;

  -- Presença já verificada por qualquer caminho, o código já usado inclusive (leitura 7).
  if v_t.verificacao = 'verificado' then
    perform public.erro(409, 'checkin_ja_confirmado');
  end if;

  perform privado.exigir_janela(v_agora, v_pos.inicio_em, v_pos.fim_em);

  -- Durante o bloqueio e depois de encerrado, a leitura não conta e nada é gravado.
  v_estado := privado.estado_do_codigo(v_t.id);
  if v_estado in ('temporario', 'encerrado') then
    perform public.erro(409, 'codigo_bloqueado', v_estado);
  end if;

  select * into v_c from privado.checkin_codigo c where c.turno_id = v_t.id for update;

  -- Vale pelo expira_em: o valor vencido fica no banco até o job de cada minuto (D4).
  v_em_vigor := v_c.codigo is not null and v_c.expira_em > v_agora;
  v_raio     := coalesce((select r.raio_validacao_m from privado.regra_checkin_codigo r), 100);

  if v_em_vigor and v_c.codigo = validar_codigo_checkin.codigo
     and (validar_codigo_checkin.distancia_m is null or validar_codigo_checkin.distancia_m <= v_raio) then
    begin
      -- O código não serve de novo. A hora da geração e da validade ficam, como no job (PR3).
      update privado.checkin_codigo c
         set codigo          = null,
             confianca_baixa = validar_codigo_checkin.distancia_m is null
       where c.turno_id = v_t.id;
      insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa, codigo_gerado_em)
      values (v_t.id, v_agora, 'aceita', privado.faixa_da_leitura(validar_codigo_checkin.distancia_m), v_c.gerado_em);
    exception when integrity_constraint_violation then
      -- Sem o DETAIL, que traria a linha e o código. A mensagem só nomeia a tabela e a restrição.
      get stacked diagnostics v_sqlstate = returned_sqlstate, v_mensagem = message_text;
      raise exception using errcode = v_sqlstate, message = v_mensagem;
    end;

    -- RN22: o código validado é a terceira prova. A distância da leitura não é gravada.
    update public.turno t
       set checkin_tipo          = 'codigo',
           verificacao           = 'verificado',
           checkin_confirmado_em = v_agora
     where t.id = v_t.id
    returning * into v_t;

    perform privado.recalcular_comparecimento(v_pos.profissional_id);

    perform privado.notificar_membros(v_estab, 'checkin'::public.tipo_notificacao, v_t.id,
      jsonb_build_object('turno_id', v_t.id, 'vaga_id', v_pos.vaga_id));

    -- ResultadoRegistro, sem codigo_exigido e codigo_disponivel, que só saem no fazer_checkin.
    return privado.resposta_do_checkin(v_t, false);
  end if;

  -- Errado, vencido, sem código gerado ou lido além do raio: conta, grava e responde sem raise (D2).
  begin
    v_resultado := privado.registrar_erro_codigo(v_t.id);
    insert into privado.checkin_codigo_tentativa (turno_id, em, resultado, faixa, codigo_gerado_em)
    values (v_t.id, v_agora, 'recusada', privado.faixa_da_leitura(validar_codigo_checkin.distancia_m),
            case when v_em_vigor then v_c.gerado_em end);
  exception when integrity_constraint_violation then
    get stacked diagnostics v_sqlstate = returned_sqlstate, v_mensagem = message_text;
    raise exception using errcode = v_sqlstate, message = v_mensagem;
  end;

  -- O envelope é o de public.erro. Um código só no 422, sem dizer o motivo a quem tenta.
  if v_resultado = 'invalido' then
    perform set_config('response.status', '422', true);
    return jsonb_build_object('code', 'codigo_invalido', 'message', 'codigo_invalido', 'details', null, 'hint', null);
  end if;
  perform set_config('response.status', '409', true);
  return jsonb_build_object('code', 'codigo_bloqueado', 'message', 'codigo_bloqueado', 'details', v_resultado, 'hint', null);
end $$;

comment on function public.validar_codigo_checkin(uuid, text, integer) is
  'Check-in por código (contrato 0.2.68, RN22, RN46): o profissional valida o código que a casa mostra, depois de um fazer_checkin pendente. Código em vigor (pelo expira_em), deste turno, lido a até privado.regra_checkin_codigo.raio_validacao_m (padrão 100 m) ou sem posição: o turno vira codigo e verificado, com checkin_confirmado_em igual à hora da validação, o valor sai do banco, a tentativa é aceita, e os membros recebem o aviso checkin; sem posição, o turno fica de confiança baixa (só na exportação do profissional). Qualquer outro caso conta como tentativa errada: 422 codigo_invalido, 409 codigo_bloqueado (temporario) na 3ª ou (encerrado) na 6ª. Essas três recusas gravam e respondem por response.status, sem raise, e por isso não geram linha de erro no log do Postgres: o registro delas é privado.checkin_codigo_tentativa (hora, resultado e faixa), a fonte da medição do piloto, e um alerta que conte erros pelo log não as vê. As demais recusas não gravam nem contam. Trava o turno (for update). Um erro de restrição na escrita sai sem o DETAIL que traria o código. Janela: a do check-in, pelo relógio do servidor; a conta de demonstração a atravessa, e para a revisão da loja falta ligar a chave para a casa de demonstração (D9).';

revoke execute on function public.validar_codigo_checkin(uuid, text, integer) from public, anon;
grant  execute on function public.validar_codigo_checkin(uuid, text, integer) to authenticated;
