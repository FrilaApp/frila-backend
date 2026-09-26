-- Exigência explícita de conta ativa em RPCs de escrita (RF25, RN15).
--
-- Garante que chamadores com token JWT emitido antes da exclusão de conta
-- sejam recusados com 403 sem_permissao (conta_encerrada) em todas as RPCs de escrita
-- que não passam por privado.exigir_perfil.

create or replace function
  public.registrar_dispositivo(
  token_fcm  text default null,
  plataforma text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid        uuid := (select auth.uid());
  v_agora      timestamptz := privado.agora();
  v_plataforma public.plataforma;
  v_token      text;
  v_disp       public.dispositivo%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  if registrar_dispositivo.token_fcm is null
     or pg_catalog.btrim(registrar_dispositivo.token_fcm) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'token_fcm');
  end if;

  v_token := pg_catalog.btrim(registrar_dispositivo.token_fcm);

  if pg_catalog.length(v_token) < 20 then
    perform public.erro(422, 'campo_invalido', 'token_fcm');
  end if;

  if registrar_dispositivo.plataforma is null
     or pg_catalog.btrim(registrar_dispositivo.plataforma) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'plataforma');
  end if;

  if not registrar_dispositivo.plataforma
         = any (pg_catalog.enum_range(null::public.plataforma)::text[]) then
    perform public.erro(422, 'campo_invalido', 'plataforma');
  end if;

  v_plataforma := registrar_dispositivo.plataforma::public.plataforma;

  -- Grava ou atualiza mantendo unicidade pelo token_fcm.
  -- Se o aparelho já estava registrado para outra conta, troca o dono (RN25 / ciclo de vida do token).
  insert into public.dispositivo (usuario_id, token_fcm, plataforma, atualizado_em)
  values (v_uid, v_token, v_plataforma, v_agora)
  on conflict (token_fcm) do update
    set usuario_id    = excluded.usuario_id,
        plataforma    = excluded.plataforma,
        atualizado_em = excluded.atualizado_em
  returning * into v_disp;

  return pg_catalog.jsonb_build_object(
    'plataforma',    v_disp.plataforma,
    'atualizado_em', v_disp.atualizado_em
  );
end $$;

comment on function public.registrar_dispositivo(text, text) is
  'Registra ou atualiza o token de push do aparelho (RF06, RNF02). Idempotente: mesmo token atualiza a data e transfere de conta em caso de troca de dono no mesmo aparelho. Retorna {plataforma, atualizado_em} conforme o contrato Dispositivo. Exige conta ativa.';

revoke execute on function public.registrar_dispositivo(text, text) from public, anon;
grant  execute on function public.registrar_dispositivo(text, text) to authenticated;

create or replace function public.avaliar(turno_id uuid, resposta boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid         uuid := (select auth.uid());
  v_turno       uuid := avaliar.turno_id;
  v_resposta    boolean := avaliar.resposta;
  v_prof        uuid;
  v_estab       uuid;
  v_fim         timestamptz;
  v_verificacao public.verificacao_turno;
  v_alvo_tipo   text;
  v_alvo_id     uuid;
  v_linha       public.avaliacao%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  -- RN13, com o mesmo código e o mesmo `details` de `publicar_vaga`: a conta suspensa
  -- não avalia ninguém. Vem antes de tudo o que fala sobre o turno, para a recusa não
  -- depender de o turno existir.
  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  -- `turno_id` ausente é campo faltando, e não turno alheio. `fazer_checkin` já trata
  -- assim; sem esta linha o nulo cairia no `select` vazio e sairia como
  -- `403 sem_permissao`, mandando o app pedir permissão para consertar um campo.
  if v_turno is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  select p.profissional_id, v.estabelecimento_id, p.fim_em, t.verificacao
    into v_prof, v_estab, v_fim, v_verificacao
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v    on v.id = p.vaga_id
   where t.id = v_turno;

  -- O lado de quem chama decide o alvo. Turno inexistente e turno alheio recebem a
  -- mesma recusa: a diferença diria a um estranho que o turno existe.
  if found and v_prof is not null and v_prof = privado.meu_profissional_id() then
    v_alvo_tipo := 'estabelecimento';
    v_alvo_id   := v_estab;
  elsif found and privado.eh_membro(v_estab) then
    v_alvo_tipo := 'profissional';
    v_alvo_id   := v_prof;
  else
    perform public.erro(403, 'sem_permissao');
  end if;

  if v_resposta is null then
    perform public.erro(422, 'campo_obrigatorio', 'resposta');
  end if;

  -- Idempotência antes do prazo: o reenvio devolve o que já foi gravado, sempre. Pela
  -- chave do lado, e não só do autor — o operador que reenvia o que o administrador já
  -- respondeu recebe a avaliação do seu lado.
  select * into v_linha from public.avaliacao a
   where a.turno_id = v_turno and a.alvo_tipo = v_alvo_tipo;
  if not found then
    if privado.agora() < v_fim then
      perform public.erro(422, 'avaliacao_indisponivel', 'antes_do_fim');
    end if;
    if v_verificacao is distinct from 'verificado' then
      perform public.erro(422, 'avaliacao_indisponivel', 'sem_presenca_verificada');
    end if;

    -- O `do update` que não muda nada existe para a inserção **sempre** devolver uma
    -- linha, inclusive quando outra chamada do mesmo lado ganhou a corrida. Com
    -- `do nothing` o `returning` volta vazio, e aí a decisão de 409 passaria a depender
    -- de um segundo `select` e do que a outra transação fez — commit ou rollback. Não é
    -- corrida que a máquina reproduza, e o custo de raciocinar sobre ela toda vez é
    -- maior do que o custo desta linha.
    insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
    values (v_turno, v_uid, v_alvo_tipo, v_alvo_id, v_resposta)
    on conflict (turno_id, alvo_tipo)
      do update set resposta = public.avaliacao.resposta
    returning * into v_linha;
  end if;

  if v_linha.resposta is distinct from v_resposta then
    perform public.erro(409, 'avaliacao_ja_registrada');
  end if;

  return jsonb_build_object(
    'turno_id',  v_linha.turno_id,
    'resposta',  v_linha.resposta,
    'criada_em', v_linha.criada_em);
end $$;

comment on function public.avaliar(uuid, boolean) is
  'Avaliação binária de uma parte do turno sobre a outra (RF15, RN07): só depois do fim previsto, pelo relógio do produto, e só com presença verificada. Um voto por lado; reenvio com a mesma resposta devolve a gravada, com outra resposta dá 409 avaliacao_ja_registrada. Exige conta ativa.';

revoke execute on function public.avaliar(uuid, boolean) from public, anon;
grant  execute on function public.avaliar(uuid, boolean) to authenticated;

create or replace function public.confirmar_checkin_manual(turno_id uuid)
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

  perform privado.exigir_conta_ativa();

  if confirmar_checkin_manual.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  select p.* into v_pos
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = confirmar_checkin_manual.turno_id;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- RF20: quem confirma é a casa. O profissional que tentasse confirmar o próprio
  -- check-in manual estaria declarando a própria presença, que é exatamente o que o
  -- manual existe para evitar. Aqui é 403, e não 404: ele é parte do turno e sabe que
  -- ele existe — esconder não protegeria nada e confundiria a tela.
  if not privado.eh_membro(privado.estabelecimento_da_vaga(v_pos.vaga_id)) then
    perform public.erro(403, 'sem_permissao');
  end if;

  select * into v_t from public.turno t where t.id = confirmar_checkin_manual.turno_id;

  if v_t.checkin_em is null then
    perform public.erro(409, 'checkin_pendente');
  end if;

  if v_t.checkin_tipo <> 'manual' then
    -- Check-in geolocalizado já nasceu verificado: não há o que confirmar.
    perform public.erro(409, 'checkin_ja_confirmado');
  end if;

  if v_t.checkin_confirmado_em is not null then
    return jsonb_build_object(
      'turno_id',      v_t.id,
      'tipo',          v_t.checkin_tipo,
      'verificacao',   v_t.verificacao,
      'registrado_em', v_t.checkin_em,
      'distancia_m',   v_t.checkin_distancia_m);
  end if;

  update public.turno t
     set checkin_confirmado_em = privado.agora(),
         verificacao           = 'verificado'
   where t.id = confirmar_checkin_manual.turno_id
  returning * into v_t;

  perform privado.recalcular_comparecimento(v_pos.profissional_id);

  return jsonb_build_object(
    'turno_id',      v_t.id,
    'tipo',          v_t.checkin_tipo,
    'verificacao',   v_t.verificacao,
    'registrado_em', v_t.checkin_em,
    'distancia_m',   v_t.checkin_distancia_m);
end $$;

comment on function public.confirmar_checkin_manual(uuid) is
  'Contratante confirma check-in manual do profissional (RF20). Torna o turno verificado para fins de pagamento e avaliação. Exige conta ativa.';

revoke execute on function public.confirmar_checkin_manual(uuid) from public, anon;
grant  execute on function public.confirmar_checkin_manual(uuid) to authenticated;

create or replace function public.cancelar_posicao(posicao_id uuid, motivo text)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_motivo text := btrim(cancelar_posicao.motivo);
  v_pos    public.posicao%rowtype;
  v_estab  uuid;
  v_eh_prof boolean;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  if cancelar_posicao.posicao_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'posicao_id');
  end if;

  -- O motivo não é burocracia: ele é o que a outra parte lê, e o que a auditoria tem
  -- para distinguir o imprevisto do descaso. O contrato pede pelo menos três letras.
  if v_motivo is null or length(v_motivo) < 3 then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  if not privado.texto_aceitavel(v_motivo) then
    perform public.erro(422, 'campo_invalido', 'motivo');
  end if;

  select * into v_pos from public.posicao p where p.id = cancelar_posicao.posicao_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  v_estab := privado.estabelecimento_da_vaga(v_pos.vaga_id);
  v_eh_prof := v_pos.profissional_id is not null
               and privado.usuario_do_profissional(v_pos.profissional_id) = v_uid;

  if not v_eh_prof and not privado.eh_membro(v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_pos.estado <> 'confirmada' then
    -- Posição aberta não tem o que cancelar, e cumprida ou já cancelada não volta atrás.
    perform public.erro(409, 'posicao_nao_cancelavel');
  end if;

  return privado.cancelar_uma_posicao(cancelar_posicao.posicao_id, v_uid, v_motivo, true);
end $$;

comment on function public.cancelar_posicao(uuid, text) is
  'Cancela uma posição confirmada, de qualquer um dos dois lados, com motivo (RF14, RN12). Antes do início, a vaga ganha posição nova e o despacho sai de novo. Nenhum cancelamento muda o estado da conta (RN13). Exige conta ativa.';

revoke execute on function public.cancelar_posicao(uuid, text) from public, anon;
grant  execute on function public.cancelar_posicao(uuid, text) to authenticated;
