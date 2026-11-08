-- Chamada direta: dois bloqueios do Lince Codex antes de ligar `chamada_direta`
-- (orquestracao/retornos/gates-ativacao-A-lince-fb89.md). Nenhuma assinatura muda.
--
-- 1. Conta excluída continuava lendo a chamada e, se aceita, o endereço da casa.
--    `minhas_chamadas` e `detalhe_chamada` (20261107370000) recusavam só `suspensa`. A
--    anonimização preserva o profissional e o histórico, e o JWT pode seguir válido depois
--    da exclusão no Auth. As duas passam a usar `privado.exigir_conta_ativa()`, como as
--    outras RPCs: anonimizada é 401 `nao_autenticado`, suspensa continua 403 `conta_suspensa`.
--
-- 2. A exclusão (ou o cancelamento) do profissional chamado reabria a vaga direta e a
--    mandava ao motor, que a oferecia a terceiro. RN35: vaga direta reabre sem despacho.
--    `cancelar_uma_posicao` e `reabrir_por_atraso` deixam de enfileirar despacho de vaga
--    direta, e `despachar_vaga` recusa vaga direta, para cobrir também os outros caminhos
--    que enfileiram. A posição continua reabrindo: "Publicar para todos" segue valendo.
--
-- Corpos copiados das versões vigentes, com só as mudanças acima:
--   privado.cancelar_uma_posicao, public.reabrir_por_atraso (20261007110000),
--   privado.despachar_vaga (20261104100000), public.minhas_chamadas e
--   public.detalhe_chamada (20261107370000).

select set_config('lock_timeout', '2s', true);

-- ── 1. Leituras da chamada exigem conta ativa ─────────────────────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.minhas_chamadas 0.2.62

create or replace function public.minhas_chamadas(
  estado text default null,
  cursor text default null,
  limite int default 20
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_perfil    text;
  v_prof_id   uuid;
  v_limite    int := coalesce(minhas_chamadas.limite, 20);
  v_cursor_ts timestamptz;
  v_cursor_id uuid;
  v_itens     jsonb := '[]'::jsonb;
  v_prox      text := null;
  r           record;
  v_cont      int := 0;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
  -- Conta anonimizada (excluída) é 401 e suspensa é 403, pela mesma porta das outras RPCs (RF25,
  -- RN13). O JWT pode seguir válido depois da exclusão: a recusa tem de vir do banco.
  perform privado.exigir_conta_ativa();

  select perfil into v_perfil from public.usuario where id = v_uid;
  if v_perfil is null then perform public.erro(404, 'nao_encontrado'); end if;

  if v_limite < 1 or v_limite > 20 then
    perform public.erro(422, 'campo_invalido', 'limite');
  end if;

  if minhas_chamadas.estado is not null
     and minhas_chamadas.estado not in ('aberta', 'aceita', 'recusada', 'expirada', 'cancelada', 'encerrada') then
    perform public.erro(422, 'campo_invalido', 'estado');
  end if;

  if minhas_chamadas.cursor is not null then
    begin
      v_cursor_ts := (split_part(convert_from(decode(minhas_chamadas.cursor, 'base64'), 'UTF8'), '#', 1))::timestamptz;
      v_cursor_id := (split_part(convert_from(decode(minhas_chamadas.cursor, 'base64'), 'UTF8'), '#', 2))::uuid;
    exception when others then
      perform public.erro(422, 'cursor_invalido');
    end;
    if v_cursor_ts is null or v_cursor_id is null then
      perform public.erro(422, 'cursor_invalido');
    end if;
  end if;

  if v_perfil = 'profissional' then
    select id into v_prof_id from public.profissional where usuario_id = v_uid;
    for r in
      select c.*, v.funcao_id, v.inicio_em, v.fim_em, v.valor_centavos, f.nome as funcao_nome, f.categoria as funcao_categoria
        from public.chamada c
        join public.vaga v on v.id = c.vaga_id
        join public.funcao f on f.id = v.funcao_id
       where c.profissional_id = v_prof_id
         and (minhas_chamadas.estado is null or c.estado = minhas_chamadas.estado)
         and not privado.bloqueado_com_estabelecimento(v_uid, c.estabelecimento_id)
         and (v_cursor_ts is null or (c.criada_em, c.id) < (v_cursor_ts, v_cursor_id))
       order by c.criada_em desc, c.id desc
       limit (v_limite + 1)
    loop
      v_cont := v_cont + 1;
      if v_cont <= v_limite then
        v_itens := v_itens || jsonb_build_array(
          jsonb_build_object(
            'id',                 r.id,
            'vaga_id',            r.vaga_id,
            'profissional_id',    r.profissional_id,
            'estabelecimento_id', r.estabelecimento_id,
            'estado',             r.estado,
            'recado',             r.recado,
            'motivo_recusa',      r.motivo_recusa,
            'expira_em',          r.expira_em,
            'respondida_em',      r.respondida_em,
            'criada_em',          r.criada_em,
            'funcao',             jsonb_build_object('id', r.funcao_id, 'nome', r.funcao_nome, 'categoria', r.funcao_categoria),
            'inicio_em',          r.inicio_em,
            'fim_em',             r.fim_em,
            'valor_centavos',     r.valor_centavos,
            'outra_parte',        privado.estabelecimento_publico(r.estabelecimento_id)
          )
        );
      else
        v_prox := encode(convert_to(r.criada_em::text || '#' || r.id::text, 'UTF8'), 'base64');
      end if;
    end loop;
  else
    -- Contratante: chamadas das casas de que é membro
    for r in
      select c.*, v.funcao_id, v.inicio_em, v.fim_em, v.valor_centavos, f.nome as funcao_nome, f.categoria as funcao_categoria
        from public.chamada c
        join public.vaga v on v.id = c.vaga_id
        join public.funcao f on f.id = v.funcao_id
        join public.membro_estabelecimento me on me.estabelecimento_id = c.estabelecimento_id
       where me.usuario_id = v_uid
         and (minhas_chamadas.estado is null or c.estado = minhas_chamadas.estado)
         and not privado.bloqueado_com_estabelecimento(privado.usuario_do_profissional(c.profissional_id), c.estabelecimento_id)
         and (v_cursor_ts is null or (c.criada_em, c.id) < (v_cursor_ts, v_cursor_id))
       order by c.criada_em desc, c.id desc
       limit (v_limite + 1)
    loop
      v_cont := v_cont + 1;
      if v_cont <= v_limite then
        v_itens := v_itens || jsonb_build_array(
          jsonb_build_object(
            'id',                 r.id,
            'vaga_id',            r.vaga_id,
            'profissional_id',    r.profissional_id,
            'estabelecimento_id', r.estabelecimento_id,
            'estado',             r.estado,
            'recado',             r.recado,
            'motivo_recusa',      r.motivo_recusa,
            'expira_em',          r.expira_em,
            'respondida_em',      r.respondida_em,
            'criada_em',          r.criada_em,
            'funcao',             jsonb_build_object('id', r.funcao_id, 'nome', r.funcao_nome, 'categoria', r.funcao_categoria),
            'inicio_em',          r.inicio_em,
            'fim_em',             r.fim_em,
            'valor_centavos',     r.valor_centavos,
            'outra_parte',        privado.perfil_publico_profissional(r.profissional_id)
          )
        );
      else
        v_prox := encode(convert_to(r.criada_em::text || '#' || r.id::text, 'UTF8'), 'base64');
      end if;
    end loop;
  end if;

  return jsonb_build_object('itens', v_itens, 'proximo_cursor', v_prox);
end $$;


-- contrato: corpo-sem-mudanca-de-superficie public.detalhe_chamada 0.2.62

create or replace function public.detalhe_chamada(chamada_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid         uuid := (select auth.uid());
  v_c           public.chamada%rowtype;
  v_v           public.vaga%rowtype;
  v_f           public.funcao%rowtype;
  v_e           public.estabelecimento%rowtype;
  v_prof        public.profissional%rowtype;
  v_eh_prof     boolean := false;
  v_eh_membro   boolean := false;
  v_dist_m      double precision;
  v_faixa       text := null;
  v_conta_nova  boolean;
  v_outra_parte jsonb;
  v_res         jsonb;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
  -- Conta anonimizada (excluída) é 401 e suspensa é 403, pela mesma porta das outras RPCs (RF25,
  -- RN13). O JWT pode seguir válido depois da exclusão: a recusa tem de vir do banco.
  perform privado.exigir_conta_ativa();
  if detalhe_chamada.chamada_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'chamada_id');
  end if;

  select * into v_c from public.chamada where id = detalhe_chamada.chamada_id;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;

  select * into v_v from public.vaga where id = v_c.vaga_id;
  select * into v_f from public.funcao where id = v_v.funcao_id;
  select * into v_e from public.estabelecimento where id = v_c.estabelecimento_id;
  select * into v_prof from public.profissional where id = v_c.profissional_id;

  if v_prof.usuario_id = v_uid then v_eh_prof := true; end if;
  if privado.eh_membro(v_c.estabelecimento_id) then v_eh_membro := true; end if;

  -- Apenas as partes autorizadas e sem bloqueio mútuo (RF26)
  if (not v_eh_prof and not v_eh_membro)
     or privado.bloqueado_com_estabelecimento(v_prof.usuario_id, v_c.estabelecimento_id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Conta nova se estabelecimento não tem turnos cumpridos/verificados
  v_conta_nova := not exists (
    select 1 from public.turno t
      join public.posicao pos on pos.id = t.posicao_id
      join public.vaga vg on vg.id = pos.vaga_id
     where vg.estabelecimento_id = v_c.estabelecimento_id
       and pos.estado = 'cumprida'
       and t.verificacao = 'verificado'
  );

  if v_eh_prof then
    v_outra_parte := privado.estabelecimento_publico(v_c.estabelecimento_id);
    if v_prof.ponto_base is not null and v_v.ponto is not null then
      v_dist_m := extensions.st_distance(v_prof.ponto_base, v_v.ponto);
      if v_dist_m <= 5000 then v_faixa := 'ate_5_km';
      elsif v_dist_m <= 15000 then v_faixa := 'de_5_a_15_km';
      else v_faixa := 'mais_de_15_km'; end if;
    end if;
  else
    v_outra_parte := privado.perfil_publico_profissional(v_c.profissional_id);
  end if;

  v_res := jsonb_build_object(
    'id',                     v_c.id,
    'vaga_id',                v_c.vaga_id,
    'profissional_id',        v_c.profissional_id,
    'estabelecimento_id',     v_c.estabelecimento_id,
    'estado',                 v_c.estado,
    'recado',                 v_c.recado,
    'motivo_recusa',          v_c.motivo_recusa,
    'expira_em',              v_c.expira_em,
    'respondida_em',          v_c.respondida_em,
    'criada_em',              v_c.criada_em,
    'funcao',                 jsonb_build_object('id', v_f.id, 'nome', v_f.nome, 'categoria', v_f.categoria),
    'inicio_em',              v_v.inicio_em,
    'fim_em',                 v_v.fim_em,
    'valor_centavos',         v_v.valor_centavos,
    'outra_parte',            v_outra_parte,
    'tipo_estabelecimento',   v_e.tipo,
    'conta_nova',             v_conta_nova,
    'regiao_administrativa',  v_v.regiao_administrativa,
    'distancia_faixa',        v_faixa,
    'inclui_refeicao',        v_v.inclui_refeicao,
    'inclui_transporte',      v_v.inclui_transporte,
    'exige_material_proprio', v_v.exige_material_proprio
  );

  -- Endereço e ponto só liberados com estado = 'aceita' (RN36). Nunca telefone.
  if v_c.estado = 'aceita' then
    v_res := v_res || jsonb_build_object(
      'local',             v_v.local,
      'ponto',             privado.ponto_em_json(v_v.ponto),
      'responsavel_local', v_v.responsavel_local
    );
  end if;

  return v_res;
end $$;


-- ── 2. Vaga direta reabre sem despacho ────────────────────────────────────────

create or replace function privado.cancelar_uma_posicao(
  posicao uuid,
  autor   uuid,
  motivo  text,
  reabrir boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pos   public.posicao%rowtype;
  v_agora timestamptz := privado.agora();
  v_falta boolean := false;
  v_nova  uuid;
  v_eh_prof boolean;
  v_vaga  uuid;
  v_inicio timestamptz;
  v_estado_vaga public.estado_vaga;
begin
  perform privado.exigir_conta_ativa();

  -- A ordem das travas (CPD2c74A): a vaga antes da posição, quando o turno não começou.
  -- A vaga e o início de uma posição não mudam depois de ela existir, então a leitura
  -- sem trava basta para saber qual vaga travar. O turno começado fica na ordem antiga
  -- (posição → vaga), a de `reabrir_por_atraso`; ali não se reabre e o gatilho não
  -- entra.
  select p.vaga_id, p.inicio_em into v_vaga, v_inicio
    from public.posicao p where p.id = posicao;

  if v_inicio > v_agora then
    select g.estado into v_estado_vaga
      from public.vaga g where g.id = v_vaga for no key update;
  end if;

  -- A trava e a reconferência (xJ53t3tX). Quem chama já conferiu que a posição estava
  -- confirmada, mas num snapshot sem trava: com o outro lado cancelando no mesmo
  -- instante, a linha que chega aqui depois da espera pode já estar cancelada. A trava
  -- espera o commit dele e devolve a linha como ficou. `no key update`: só estado e
  -- falta mudam, e esse modo não espera quem insere uma linha que aponta para a posição.
  select * into v_pos from public.posicao p where p.id = posicao for no key update;

  if v_pos.estado is distinct from 'confirmada' then
    -- A desistência do profissional (`cancelar_posicao`, que reabre fora da exclusão de
    -- conta) recebe o que receberia chegando depois do commit: não há o que cancelar.
    if reabrir and coalesce(current_setting('frila.exclusao_de_conta', true), 'off') <> 'on' then
      perform public.erro(409, 'posicao_nao_cancelavel');
    end if;
    -- Os laços (`cancelar_vaga`, o gatilho da vaga cancelada, `excluir_conta`) seguem:
    -- a posição já saiu por outro caminho, com a ocorrência e o aviso dele. Recancelá-la
    -- dobraria a ocorrência, avisaria de um cancelamento que não aconteceu e apagaria a
    -- falta de quem desistiu de fato.
    return null;
  end if;

  v_eh_prof := v_pos.profissional_id is not null
               and privado.usuario_do_profissional(v_pos.profissional_id) = autor;

  -- RN12. A falta é do profissional que desiste em cima da hora, e só dele: o
  -- contratante que cancela não gera falta para ninguém, e a posição que nunca foi
  -- confirmada não tem de quem ser falta. Na exclusão de conta (sinalizada via
  -- frila.exclusao_de_conta), não há falta.
  if v_eh_prof and v_pos.estado = 'confirmada'
     and v_pos.inicio_em - v_agora < interval '24 hours'
     and coalesce(current_setting('frila.exclusao_de_conta', true), 'off') <> 'on' then
    v_falta := true;
  end if;

  update public.posicao p
     set estado = 'cancelada',
         falta  = v_falta
   where p.id = posicao;

  -- O turno cancelado sai junto. Ele não é apagado: o registro do que foi combinado
  -- sobrevive ao cancelamento, e é o que a auditoria lê.
  update public.turno t
     set verificacao = 'nao_verificado'
   where t.posicao_id = posicao and t.verificacao = 'pendente';

  insert into public.ocorrencia (tipo, posicao_id, usuario_id, autor_id, motivo)
  values ('cancelamento', posicao,
          privado.usuario_do_profissional(v_pos.profissional_id), autor, motivo);

  -- Antes do início, a vaga ganha uma posição nova e o despacho sai de novo. Depois do
  -- início não há o que reabrir: o turno ficou descoberto, e quem precisa saber disso é
  -- o contratante. A vaga já está travada desde o começo, e o estado dela é o que ficou
  -- depois da espera: cancelada ou encerrada, não se reabre numa vaga que não existe
  -- mais.
  if reabrir and v_pos.inicio_em > v_agora
     and v_estado_vaga in ('publicada', 'preenchida') then
    insert into public.posicao (vaga_id, inicio_em, fim_em)
    values (v_pos.vaga_id, v_pos.inicio_em, v_pos.fim_em)
    returning id into v_nova;

    -- A vaga estava preenchida e volta a ter posição aberta.
    update public.vaga g set estado = 'publicada'
     where g.id = v_pos.vaga_id and g.estado = 'preenchida';

    -- D4=C: a menos de 24 h do início, a reposição passa para urgência (RN24).
    -- O primeiro candidato elegível confirma na hora e o fechar_selecoes não cancela a vaga.
    if v_pos.inicio_em - interval '24 hours' <= v_agora then
      update public.vaga g set modo = 'urgencia'
       where g.id = v_pos.vaga_id and g.modo = 'selecao';
    end if;

    -- RN35: vaga direta reabre sem despacho. Ela nasceu de uma chamada a uma pessoa só, e
    -- oferecê-la a terceiro levaria o endereço da casa a quem nunca foi chamado. "Publicar
    -- para todos" é a única porta para fora.
    if not exists (select 1 from public.vaga g where g.id = v_pos.vaga_id and g.origem = 'chamada_direta') then
      perform pgmq.send('despacho', jsonb_build_object(
        'vaga_id',        v_pos.vaga_id,
        'posicao_id',     v_nova,
        'motivo',         'reabertura',
        -- Quem cancelou não é notificado de novo da própria vaga. Receber a notificação
        -- da vaga que se acabou de largar é o tipo de detalhe que faz desinstalar o app.
        'excluir_conta',  autor));
    end if;
  end if;

  if v_falta then
    perform privado.recalcular_comparecimento(v_pos.profissional_id);
  end if;

  -- Avisa a **outra parte**, e só ela: quem cancelou sabe. O profissional cancelou, a
  -- casa toda é avisada; a casa cancelou, o profissional é. `reaberta = false` é o turno
  -- descoberto — vaga inteira cancelada, ou início já passado —, que a casa precisa
  -- distinguir da posição que voltou para a fila.
  if v_eh_prof then
    perform privado.notificar_membros(
      privado.estabelecimento_da_vaga(v_pos.vaga_id), 'cancelamento', posicao,
      jsonb_build_object('posicao_id', posicao, 'vaga_id', v_pos.vaga_id,
                         'reaberta', v_nova is not null));
  elsif v_pos.profissional_id is not null then
    perform privado.notificar(privado.usuario_do_profissional(v_pos.profissional_id),
      'cancelamento', posicao,
      jsonb_build_object('posicao_id', posicao, 'vaga_id', v_pos.vaga_id,
                         'reaberta', v_nova is not null));
  end if;

  return jsonb_build_object(
    'posicao_id',      posicao,
    'falta',           v_falta,
    'reaberta',        v_nova is not null,
    'nova_posicao_id', v_nova);
end $$;


-- contrato: corpo-sem-mudanca-de-superficie public.reabrir_por_atraso 0.2.62

create or replace function public.reabrir_por_atraso(posicao_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid     uuid := (select auth.uid());
  v_agora   timestamptz;
  v_pos     public.posicao%rowtype;
  v_t       public.turno%rowtype;
  v_usr     uuid;
  v_nova    uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('contratante');

  if reabrir_por_atraso.posicao_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'posicao_id');
  end if;

  -- A trava vem antes de qualquer leitura de estado: posição e depois turno, a mesma
  -- ordem para toda chamada. O check-in simultâneo espera aqui ou é esperado.
  select * into v_pos from public.posicao p
   where p.id = reabrir_por_atraso.posicao_id
     for update;

  -- Posição que não existe e posição de outra casa respondem igual: um 404 diria a
  -- quem não é da casa que aquela posição existe.
  if not found or not privado.eh_membro(privado.estabelecimento_da_vaga(v_pos.vaga_id)) then
    perform public.erro(403, 'sem_permissao');
  end if;

  select * into v_t from public.turno t where t.posicao_id = v_pos.id for update;

  -- Reenvio: a rede caiu depois do commit. A falta já foi marcada; devolve o que a
  -- primeira chamada devolveu, sem segunda posição nem segundo aviso.
  if v_pos.estado = 'cancelada'
     and exists (select 1 from public.ocorrencia o
                  where o.posicao_id = v_pos.id and o.tipo = 'cancelamento'
                    and o.motivo = 'reabertura_por_atraso') then
    select p.id into v_nova from public.posicao p where p.reaberta_por_atraso_de = v_pos.id;
    return jsonb_build_object(
      'posicao_id',      v_pos.id,
      'falta',           v_pos.falta,
      'reaberta',        v_nova is not null,
      'nova_posicao_id', v_nova);
  end if;

  if v_pos.estado <> 'confirmada' then
    perform public.erro(409, 'posicao_nao_cancelavel');
  end if;

  if v_t.checkin_em is not null then
    perform public.erro(409, 'posicao_nao_cancelavel', 'checkin_registrado');
  end if;

  v_agora := privado.agora();

  -- D06: a tolerância é de 15 minutos a partir do início previsto. O substituto que
  -- confirmou uma posição reaberta com o turno já em andamento ganha os mesmos 15
  -- minutos, contados da confirmação: sem isso a casa poderia declarar falta de quem
  -- acabou de aceitar.
  if v_agora < greatest(v_pos.inicio_em, v_pos.confirmado_em) + interval '15 minutes' then
    perform public.erro(422, 'reabertura_antes_da_tolerancia');
  end if;

  v_usr := privado.usuario_do_profissional(v_pos.profissional_id);

  -- RN12: reabrir por atraso é declarar que o profissional não veio. Conta como falta,
  -- com a mesma posição guardando de quem ela era.
  update public.posicao p
     set estado = 'cancelada',
         falta  = true
   where p.id = v_pos.id;

  update public.turno t
     set verificacao = 'nao_verificado'
   where t.posicao_id = v_pos.id and t.verificacao = 'pendente';

  -- Motivo estável, e não texto da casa: é o que distingue esta falta das outras na
  -- auditoria e no texto do aviso ao profissional.
  insert into public.ocorrencia (tipo, posicao_id, turno_id, usuario_id, autor_id, motivo)
  values ('cancelamento', v_pos.id, v_t.id, v_usr, v_uid, 'reabertura_por_atraso');

  -- 8zLfn0mt item 5: a posição reaberta aceita candidato até 1 h antes do fim. Depois
  -- disso ninguém chega a tempo, e reabrir seria só um despacho inútil.
  if v_agora < v_pos.fim_em - interval '1 hour' then
    insert into public.posicao (vaga_id, inicio_em, fim_em, reaberta_por_atraso_de)
    values (v_pos.vaga_id, v_pos.inicio_em, v_pos.fim_em, v_pos.id)
    returning id into v_nova;

    update public.vaga g set estado = 'publicada'
     where g.id = v_pos.vaga_id and g.estado = 'preenchida';

    -- D5=A: reabertura por atraso acontece após o início (portanto a menos de 24 h).
    -- Em vaga de seleção, a reposição passa para urgência para que o primeiro elegível confirme na hora.
    update public.vaga g set modo = 'urgencia'
     where g.id = v_pos.vaga_id and g.modo = 'selecao';

    -- O mesmo despacho da reabertura por cancelamento. Quem faltou não é notificado da
    -- vaga que deixou de cumprir.
    -- RN35: vaga direta reabre por atraso sem despacho (ver cancelar_uma_posicao).
    if not exists (select 1 from public.vaga g where g.id = v_pos.vaga_id and g.origem = 'chamada_direta') then
      perform pgmq.send('despacho', jsonb_build_object(
        'vaga_id',       v_pos.vaga_id,
        'posicao_id',    v_nova,
        'motivo',        'reabertura',
        'excluir_conta', v_usr));
    end if;
  end if;

  perform privado.recalcular_comparecimento(v_pos.profissional_id);

  -- O profissional é avisado; a casa, que decidiu, não.
  perform privado.notificar(v_usr, 'cancelamento', v_pos.id,
    jsonb_build_object('posicao_id', v_pos.id, 'vaga_id', v_pos.vaga_id,
                       'reaberta', v_nova is not null));

  return jsonb_build_object(
    'posicao_id',      v_pos.id,
    'falta',           true,
    'reaberta',        v_nova is not null,
    'nova_posicao_id', v_nova);
end $$;


-- ── 3. O motor nunca despacha vaga direta ─────────────────────────────────────

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
  -- Vaga direta nunca é despachada (RN28, RN35): a guarda fica no motor, e não só em quem
  -- enfileira, porque há mais de dez caminhos que mandam mensagem à fila de despacho.
  if not found or v.estado <> 'publicada' or privado.vaga_oculta(v.id)
     or v.origem = 'chamada_direta' then
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

