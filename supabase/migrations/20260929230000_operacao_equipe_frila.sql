-- 20260929230000_operacao_equipe_frila.sql
--
-- Ferramentas e procedimentos operacionais da Equipe Frila (Cartão Oxh0AWE7, D01, D02, D03, RN13, UC14, UC15, UC17).
--
--   - privado.operacao_suspender_conta(usuario_id uuid, motivo text, operador_id uuid) -> jsonb
--   - privado.operacao_reativar_conta(usuario_id uuid, justificativa text, operador_id uuid) -> jsonb
--   - privado.operacao_moderar_conteudo(vaga_id uuid, acao text, motivo text, operador_id uuid) -> jsonb
--
-- Acesso estritamente restrito a service_role (fora do PostgREST / público).
-- Todas as ações são transacionais e registram ocorrência oficial.
--
-- O autor das ocorrências é `operador_id`, a conta do membro da Equipe Frila que agiu, e
-- nunca o alvo. Com o alvo como autor, `limpar_contas_anonimizadas` apagaria o motivo da
-- suspensão junto com a conta suspensa, e a exportação de dados atribuiria a ele o texto
-- interno da equipe.

-- ── 0. O operador ───────────────────────────────────────────────────────────────

create or replace function privado.operacao_exigir_operador(operador uuid, alvo uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if operador is null then
    perform public.erro(422, 'campo_obrigatorio', 'operador_id');
  end if;

  -- Conta ativa: a ocorrência aponta para ela (`autor_id not null references usuario`).
  if not exists (select 1 from public.usuario u
                  where u.id = operador and u.estado = 'ativa') then
    perform public.erro(422, 'campo_invalido', 'operador_id');
  end if;

  -- Quem age sobre a própria conta ou a própria vaga não é a Equipe Frila agindo.
  if operador = alvo then
    perform public.erro(422, 'campo_invalido', 'operador_id');
  end if;
end $$;

comment on function privado.operacao_exigir_operador(uuid, uuid) is
  'Confere o membro da Equipe Frila que assina uma ação operacional: obrigatório, conta ativa e diferente do alvo. Restrito a service_role.';

revoke execute on function privado.operacao_exigir_operador(uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_exigir_operador(uuid, uuid) to service_role;

-- ── 1. Suspender Conta ──────────────────────────────────────────────────────────

create or replace function privado.operacao_suspender_conta(
  usuario_id  uuid,
  motivo      text,
  operador_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid         uuid := operacao_suspender_conta.usuario_id;
  v_motivo      text := pg_catalog.btrim(operacao_suspender_conta.motivo);
  v_operador    uuid := operacao_suspender_conta.operador_id;
  v_usuario     public.usuario%rowtype;
  v_agora       timestamptz := privado.agora();
  v_pos         public.posicao%rowtype;
  v_cand        record;
  v_vagas       uuid[];
  v_cancelados  integer := 0;
  v_oc_id       uuid;
begin
  if v_uid is null then
    perform public.erro(422, 'campo_obrigatorio', 'usuario_id');
  end if;

  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_uid);

  select * into v_usuario
    from public.usuario u
   where u.id = v_uid
     for update;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_usuario.estado = 'anonimizada' then
    perform public.erro(409, 'conta_ja_anonimizada');
  end if;

  if v_usuario.estado = 'suspensa' then
    return jsonb_build_object(
      'usuario_id',         v_uid,
      'estado_anterior',    'suspensa',
      'estado_atual',       'suspensa',
      'ja_estava_suspensa', true,
      'turnos_cancelados',  0
    );
  end if;

  -- 1. Se for profissional: reabre cada turno futuro através de privado.cancelar_uma_posicao
  -- (RN13), sem falta (decisão de 29/09): quem cancela é a Equipe Frila, não ele. A
  -- sinalização é a da exclusão de conta, que também faz a posição que o outro lado
  -- cancelou no meio ser pulada em vez de abortar a suspensão com 409.
  if v_usuario.perfil = 'profissional' then
    perform set_config('frila.exclusao_de_conta', 'on', true);
    for v_pos in
      select p.*
        from public.posicao p
       where p.estado = 'confirmada'
         and p.inicio_em > v_agora
         and p.profissional_id = (select x.id from public.profissional x where x.usuario_id = v_uid)
    loop
      -- Motivo estável, sem o texto da equipe: o suspenso lê a ocorrência de cancelamento
      -- (política ocorrencia_leitura), e o motivo da suspensão fica na ocorrência dela.
      perform privado.cancelar_uma_posicao(v_pos.id, v_uid, 'suspensão de conta', true);
      v_cancelados := v_cancelados + 1;
    end loop;
    perform set_config('frila.exclusao_de_conta', 'off', true);
  end if;

  -- 2. Se for contratante: nas casas onde for o único membro, ninguém responde pelas vagas
  -- futuras, publicadas ou preenchidas. Elas saem como em `excluir_conta`: as confirmadas
  -- são canceladas sem reabrir, com aviso ao profissional e sem falta (quem cancela é a
  -- Equipe Frila, não ele); as candidaturas pendentes são retiradas e avisadas; as abertas
  -- e a vaga vão para cancelada.
  if v_usuario.perfil = 'contratante' then
    -- O gatilho `vaga_cancelada_recolhe_confirmadas` sai sem recolher as confirmadas
    -- quando `auth.uid()` é nulo, que é o caso da chave de serviço. O autor sinalizado na
    -- transação (o mesmo mecanismo de `excluir_conta`) faz ele recolher, em nome do
    -- operador, a posição que confirmar entre o laço abaixo e o `update` da vaga.
    perform set_config('frila.autor_da_exclusao', v_operador::text, true);

    -- Ordem das travas (CPD2c74A): as vagas antes das posições.
    select coalesce(array_agg(x.id order by x.id), '{}') into v_vagas
      from (select g.id
              from public.vaga g
             where g.inicio_em > v_agora
               and g.estado in ('publicada', 'preenchida')
               and g.estabelecimento_id in (
                 select m.estabelecimento_id from public.membro_estabelecimento m
                  where m.usuario_id = v_uid
                    and not exists (
                      select 1 from public.membro_estabelecimento x
                       where x.estabelecimento_id = m.estabelecimento_id
                         and x.usuario_id <> v_uid))
             order by g.id
               for update) x;

    for v_pos in
      select p.*
        from public.posicao p
       where p.vaga_id = any (v_vagas)
         and p.estado = 'confirmada'
         and p.inicio_em > v_agora
       order by p.id
    loop
      perform privado.cancelar_uma_posicao(v_pos.id, v_operador, 'suspensão de conta', false);
      v_cancelados := v_cancelados + 1;
    end loop;

    for v_cand in
      select c.id, c.profissional_id, p.vaga_id
        from public.candidatura c
        join public.posicao p on p.id = c.posicao_id
       where p.vaga_id = any (v_vagas)
         and c.estado = 'pendente'
    loop
      update public.candidatura set estado = 'retirada' where id = v_cand.id;
      perform privado.notificar(
        privado.usuario_do_profissional(v_cand.profissional_id),
        'cancelamento',
        v_cand.vaga_id,
        jsonb_build_object('vaga_id', v_cand.vaga_id, 'reaberta', false)
      );
    end loop;

    update public.posicao p
       set estado = 'cancelada'
     where p.vaga_id = any (v_vagas)
       and p.estado = 'aberta';

    update public.vaga g
       set estado = 'cancelada'
     where g.id = any (v_vagas);

    perform set_config('frila.autor_da_exclusao', '', true);
  end if;

  -- Atualiza o estado da conta para suspensa
  update public.usuario
     set estado = 'suspensa'
   where id = v_uid;

  -- Registra ocorrência de suspensão
  insert into public.ocorrencia (
    tipo,
    usuario_id,
    autor_id,
    motivo,
    criada_em,
    resolvido_em,
    resultado
  ) values (
    'suspensao',
    v_uid,
    v_operador,
    v_motivo,
    v_agora,
    v_agora,
    'Conta suspensa pela Equipe Frila via procedimento operacional.'
  ) returning id into v_oc_id;

  return jsonb_build_object(
    'usuario_id',        v_uid,
    'estado_anterior',   'ativa',
    'estado_atual',      'suspensa',
    'ocorrencia_id',     v_oc_id,
    'turnos_cancelados', v_cancelados,
    'suspenso_em',       v_agora
  );
end $$;

comment on function privado.operacao_suspender_conta(uuid, text, uuid) is
  'Suspende conta de usuário (RN13) com registro de ocorrência assinada pelo operador da Equipe Frila e cancelamento de turnos futuros. Profissional: reabre os turnos futuros sem falta (RN12), como na exclusão de conta. Contratante único membro: cancela as vagas futuras publicadas e preenchidas, com as confirmadas, sem falta, e retira as candidaturas pendentes, com aviso. Restrito a service_role.';

revoke execute on function privado.operacao_suspender_conta(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_suspender_conta(uuid, text, uuid) to service_role;

-- ── 2. Reativar Conta ──────────────────────────────────────────────────────────

create or replace function privado.operacao_reativar_conta(
  usuario_id    uuid,
  justificativa text,
  operador_id   uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid     uuid := operacao_reativar_conta.usuario_id;
  v_just    text := pg_catalog.btrim(operacao_reativar_conta.justificativa);
  v_operador uuid := operacao_reativar_conta.operador_id;
  v_usuario public.usuario%rowtype;
  v_agora   timestamptz := privado.agora();
  v_oc_id   uuid;
begin
  if v_uid is null then
    perform public.erro(422, 'campo_obrigatorio', 'usuario_id');
  end if;

  if v_just is null or v_just = '' then
    perform public.erro(422, 'campo_obrigatorio', 'justificativa');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_uid);

  select * into v_usuario
    from public.usuario u
   where u.id = v_uid
     for update;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_usuario.estado = 'anonimizada' then
    perform public.erro(409, 'conta_ja_anonimizada');
  end if;

  if v_usuario.estado = 'ativa' then
    return jsonb_build_object(
      'usuario_id',      v_uid,
      'estado_anterior', 'ativa',
      'estado_atual',    'ativa',
      'ja_estava_ativa', true
    );
  end if;

  update public.usuario
     set estado = 'ativa'
   where id = v_uid;

  insert into public.ocorrencia (
    tipo,
    usuario_id,
    autor_id,
    motivo,
    criada_em,
    resolvido_em,
    resultado
  ) values (
    'suporte',
    v_uid,
    v_operador,
    'Reativação de conta: ' || v_just,
    v_agora,
    v_agora,
    'Conta reativada pela Equipe Frila via procedimento operacional.'
  ) returning id into v_oc_id;

  return jsonb_build_object(
    'usuario_id',      v_uid,
    'estado_anterior', 'suspensa',
    'estado_atual',    'ativa',
    'ocorrencia_id',   v_oc_id,
    'reativado_em',    v_agora
  );
end $$;

comment on function privado.operacao_reativar_conta(uuid, text, uuid) is
  'Reativa conta suspensa com registro de ocorrência assinada pelo operador da Equipe Frila. Restrito a service_role.';

revoke execute on function privado.operacao_reativar_conta(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_reativar_conta(uuid, text, uuid) to service_role;

-- ── 3. Vaga ocultada pela Equipe Frila (decisão de 29/09, opção A) ──────────────
--
-- Ocultar tira a vaga da vitrine e do despacho sem cancelá-la: os confirmados seguem
-- confirmados, e o ciclo de vida (`estado`) não muda. A marca fica fora da API, em
-- `privado`, com a ocorrência de moderação que a criou; reexibir só tira a marca, e por
-- isso nunca republica uma vaga que a casa cancelou.
--
-- Cada ponto que oferece a vaga a quem procura turno passa a conferir a marca. As
-- funções abaixo são cópias das definições mais recentes na develop, com uma linha a
-- mais cada: `vagas_abertas`, `detalhe_vaga`, `painel_estabelecimento` e `republicar_vaga`
-- (20260928230000), `candidatar`
-- (20260928220000), `despachar_vaga` (20260929110000), `liberar_teto_do_profissional` e
-- `notificacao_expirada` (20260929100000) e a política `vaga_leitura` (20260925120000).
-- `privado.elegiveis` fica intocada: o filtro vive em `despachar_vaga`, que a chama.
--
-- Contrato 0.2.23: a candidatura pendente segue pendente e o detalhe abre para quem a
-- tem; `detalhe_vaga` e `painel_estabelecimento` trazem `oculta`; `republicar_vaga` a
-- partir da vaga ocultada é `422 vaga_oculta`. `escolher_candidato` ainda não existe
-- neste backend: quando existir, recusa a vaga ocultada com o mesmo `422 vaga_oculta`.

create table privado.vaga_ocultada (
  vaga_id       uuid primary key references public.vaga(id) on delete cascade,
  ocorrencia_id uuid not null references public.ocorrencia(id),
  oculta_em     timestamptz not null
);

comment on table privado.vaga_ocultada is
  'Vagas ocultadas pela Equipe Frila (moderação, Diretriz 1.2): fora da vitrine, do detalhe para quem não está nela, da candidatura e do despacho, sem cancelar. A linha some na reexibição.';

revoke all on table privado.vaga_ocultada from public, anon, authenticated;
grant  all on table privado.vaga_ocultada to service_role;

create or replace function privado.vaga_oculta(v uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from privado.vaga_ocultada o where o.vaga_id = v)
$$;

comment on function privado.vaga_oculta(uuid) is
  'Verdadeiro quando a Equipe Frila ocultou a vaga. Lida pela política vaga_leitura, por isso também executável por authenticated, como privado.mesma_populacao.';

revoke all on function privado.vaga_oculta(uuid) from public, anon;
grant  execute on function privado.vaga_oculta(uuid) to authenticated, service_role;

drop policy vaga_leitura on public.vaga;

create policy vaga_leitura on public.vaga for select to authenticated
  using (
    privado.mesma_populacao(publicado_por)
    and (
          privado.eh_membro(estabelecimento_id)
       or ((select privado.perfil_da_conta()) = 'profissional'
           and (   privado.ocupa_posicao_na_vaga(id)
                or (not privado.bloqueado_com_estabelecimento(
                          (select auth.uid()), estabelecimento_id)
                    and ((estado = 'publicada' and not privado.vaga_oculta(id))
                         or privado.candidatou_na_vaga(id)))))));

create or replace function public.vagas_abertas(
  latitude         numeric default null,
  longitude        numeric default null,
  funcao_id        uuid    default null,
  data             date    default null,
  distancia_max_km numeric default null,
  limite           int     default 30,
  deslocamento     int     default 0
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_ref   extensions.geography;
  v_demo  boolean;
  v_raio  double precision;
  v_agora timestamptz := privado.agora();
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('profissional');

  if vagas_abertas.limite is null or vagas_abertas.limite < 1 or vagas_abertas.limite > 100 then
    perform public.erro(422, 'campo_invalido', 'limite');
  end if;
  if vagas_abertas.deslocamento is null or vagas_abertas.deslocamento < 0 then
    perform public.erro(422, 'campo_invalido', 'deslocamento');
  end if;

  if vagas_abertas.latitude is not null or vagas_abertas.longitude is not null then
    v_ref := privado.ponto_do_json(
      jsonb_build_object('latitude', vagas_abertas.latitude, 'longitude', vagas_abertas.longitude),
      'latitude');
  else
    select p.ponto_base into v_ref
      from public.profissional p where p.usuario_id = v_uid;
    if v_ref is null then
      perform public.erro(422, 'campo_obrigatorio', 'latitude');
    end if;
  end if;

  v_demo := privado.conta_de_demonstracao();
  v_raio := case when vagas_abertas.distancia_max_km is null
                 then null else vagas_abertas.distancia_max_km * 1000 end;

  return coalesce((
    select jsonb_agg(item order by ordem)
      from (
        select jsonb_build_object(
                 'id',                    v.id,
                 'funcao',                privado.funcao_em_json(f.*),
                 'estabelecimento',       privado.estabelecimento_publico(v.estabelecimento_id),
                 'inicio_em',             v.inicio_em,
                 'fim_em',                v.fim_em,
                 'local',                 v.local,
                 'regiao_administrativa', v.regiao_administrativa,
                 'distancia_km',          round((extensions.st_distance(v.ponto, v_ref) / 1000)::numeric, 2),
                 'valor_centavos',        v.valor_centavos,
                 'posicoes_abertas',      privado.posicoes_candidataveis(v.id, v_agora),
                 'inclusos',              privado.inclusos_em_json(v.*),
                 'modo',                  v.modo) as item,
               row_number() over (order by v.ponto operator(extensions.<->) v_ref, v.id) as ordem
          from public.vaga v
          join public.funcao f  on f.id = v.funcao_id
          join public.usuario u on u.id = v.publicado_por
         where v.estado = 'publicada'
           and not privado.vaga_oculta(v.id)
           and (v.inicio_em > v_agora or privado.posicoes_candidataveis(v.id, v_agora) > 0)
           and u.demonstracao = v_demo
           and not privado.bloqueado_com_estabelecimento(v_uid, v.estabelecimento_id)
           and (vagas_abertas.funcao_id is null or v.funcao_id = vagas_abertas.funcao_id)
           and (vagas_abertas.data is null
                or (v.inicio_em at time zone 'America/Sao_Paulo')::date = vagas_abertas.data)
           and (v_raio is null or extensions.st_dwithin(v.ponto, v_ref, v_raio))
         order by v.ponto operator(extensions.<->) v_ref, v.id
         limit vagas_abertas.limite offset vagas_abertas.deslocamento
      ) t
  ), '[]'::jsonb);
end $$;

comment on function public.vagas_abertas(numeric, numeric, uuid, date, numeric, int, int) is
  'Vagas abertas ordenadas por distância até o ponto informado, ou até o ponto base (RF07, RN05). A ordem não pode ser comprada (RN06); vaga de estabelecimento com bloqueio some (RF26), e a ocultada pela Equipe Frila também (Diretriz 1.2). Vaga já começada some, salvo a com posição reaberta por atraso antes de fim − 1 h (contrato 0.2.19). Expõe regiao_administrativa no schema VagaNaLista.';

revoke execute on function public.vagas_abertas(numeric, numeric, uuid, date, numeric, int, int) from public, anon;
grant  execute on function public.vagas_abertas(numeric, numeric, uuid, date, numeric, int, int) to authenticated;

create or replace function public.detalhe_vaga(vaga_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid  uuid := (select auth.uid());
  v_ref  extensions.geography;
  v_demo boolean;
  v      public.vaga%rowtype;
  v_f    public.funcao%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if detalhe_vaga.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  v_demo := privado.conta_de_demonstracao();

  select * into v from public.vaga g where g.id = detalhe_vaga.vaga_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if not exists (select 1 from public.usuario u
                  where u.id = v.publicado_por and u.demonstracao = v_demo) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if privado.bloqueado_com_estabelecimento(v_uid, v.estabelecimento_id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Ocultada pela Equipe Frila: some para quem procura turno. Quem já está nela (o
  -- confirmado segue confirmado, a candidatura segue pendente) ainda a abre, com
  -- `oculta: true` (contrato 0.2.23).
  if privado.vaga_oculta(v.id)
     and not privado.ocupa_posicao_na_vaga(v.id)
     and not privado.candidatou_na_vaga(v.id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  select * into v_f from public.funcao f where f.id = v.funcao_id;

  select p.ponto_base into v_ref from public.profissional p where p.usuario_id = v_uid;

  return jsonb_build_object(
    'id',                    v.id,
    'estabelecimento',       privado.estabelecimento_publico(v.estabelecimento_id),
    'funcao',                privado.funcao_em_json(v_f.*),
    'inicio_em',             v.inicio_em,
    'fim_em',                v.fim_em,
    'local',                 v.local,
    'regiao_administrativa', v.regiao_administrativa,
    'ponto',                 privado.ponto_em_json(v.ponto),
    'distancia_km',          case when v_ref is null then null
                                  else round((extensions.st_distance(v.ponto, v_ref) / 1000)::numeric, 2) end,
    'valor_centavos',        v.valor_centavos,
    'posicoes',              v.posicoes,
    'posicoes_abertas',      privado.posicoes_candidataveis(v.id, privado.agora()),
    'inclusos',              privado.inclusos_em_json(v.*),
    'responsavel_local',     v.responsavel_local,
    'traje',                 v.traje,
    'participa_rateio',      v.participa_rateio,
    'observacoes',           v.observacoes,
    'modo',                  v.modo,
    'estado',                v.estado,
    'oculta',                privado.vaga_oculta(v.id),
    'publicado_em',          v.publicado_em);
end $$;

comment on function public.detalhe_vaga(uuid) is
  'Detalhe da vaga para quem ainda não se candidatou (RF04, UC03). Sem documento e sem contato (RN10). Vaga escondida por bloqueio ou por demonstração responde 404, e não 403: o 403 confirmaria que ela existe. Depois do início, posicoes_abertas conta só as reabertas por atraso dentro do prazo (contrato 0.2.19). Expõe regiao_administrativa no schema Vaga / VagaDetalhe.';

revoke execute on function public.detalhe_vaga(uuid) from public, anon;
grant  execute on function public.detalhe_vaga(uuid) to authenticated;

create or replace function public.candidatar(vaga_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_prof  uuid;
  v_agora timestamptz;
  v       public.vaga%rowtype;
  v_pos   uuid;
  v_turno uuid;
  v_cand  uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if candidatar.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  -- RN13. A conta suspensa continua enxergando a lista, e é recusada aqui: a recusa
  -- tem motivo em `details` para a tela poder explicar em vez de só negar.
  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(422, 'inelegivel', 'perfil_suspenso');
  end if;

  select p.id into v_prof from public.profissional p where p.usuario_id = v_uid;
  if v_prof is null then
    -- Sem perfil não há função cadastrada, e sem função nenhuma vaga serve. O código é
    -- o mesmo da função incompatível de propósito: para o profissional, os dois casos
    -- terminam na mesma tela — a de completar o perfil.
    perform public.erro(422, 'inelegivel', 'funcao_incompativel');
  end if;

  perform privado.travar_candidatura(candidatar.vaga_id, v_prof);

  select * into v from public.vaga g where g.id = candidatar.vaga_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- O mesmo 404 das leituras, e pelo mesmo motivo: um 403 confirmaria que a vaga
  -- existe a quem bloqueou a casa ou a quem está do outro lado da demonstração.
  if privado.bloqueado_com_estabelecimento(v_uid, v.estabelecimento_id)
     or not exists (select 1 from public.usuario u
                     where u.id = v.publicado_por
                       and u.demonstracao = privado.conta_de_demonstracao()) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Idempotência pela chave natural (vaga, profissional). A rede cai depois do commit
  -- e o app reenvia: a segunda chamada devolve o mesmo turno em vez de tomar uma
  -- segunda posição. Vem **antes** da conferência de estado da vaga, senão o reenvio
  -- que chega depois de a vaga encher receberia `vaga_encerrada` em vez do próprio
  -- resultado.
  select p.id into v_pos
    from public.posicao p
   where p.vaga_id = candidatar.vaga_id
     and p.profissional_id = v_prof
     and p.estado in ('confirmada', 'cumprida');
  if found then
    select t.id into v_turno from public.turno t where t.posicao_id = v_pos;
    select c.id into v_cand from public.candidatura c
     where c.posicao_id = v_pos and c.profissional_id = v_prof;
    return jsonb_build_object(
      'estado',         'confirmada',
      'candidatura_id', v_cand,
      'posicao_id',     v_pos,
      'turno_id',       v_turno,
      'contato',        privado.contato_do_estabelecimento(candidatar.vaga_id));
  end if;

  -- Ocultada pela Equipe Frila: o mesmo 404 das leituras. Depois da idempotência, para o
  -- reenvio de quem já confirmou devolver o próprio turno.
  if privado.vaga_oculta(v.id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  v_agora := privado.agora();

  -- Dois 409 diferentes, e a diferença importa para a tela. `vaga_encerrada` é "esta
  -- vaga não existe mais"; `posicao_ja_preenchida` é "alguém chegou antes", que o
  -- produto trata como funcionamento normal — "que pena, foi rápido". Vaga
  -- **preenchida** é o segundo caso, e não o primeiro: ela fechou porque encheu.
  if v.estado = 'preenchida' then
    perform public.erro(409, 'posicao_ja_preenchida');
  end if;

  if v.estado <> 'publicada' then
    perform public.erro(409, 'vaga_encerrada');
  end if;

  -- Início já passado conta como encerrada: candidatar-se a um turno que começou não é
  -- corrida perdida, é vaga que não existe mais. A exceção da 0.2.19 é da **posição**: a
  -- reaberta por atraso aceita candidato até 1 h antes do fim (8zLfn0mt, item 5). Sem
  -- nenhuma dessas dentro do prazo, a vaga está encerrada; havendo, perder a corrida por
  -- ela é `posicao_ja_preenchida`, lá embaixo, como antes do início.
  if v.inicio_em <= v_agora
     and not exists (select 1 from public.posicao x
                      where x.vaga_id = candidatar.vaga_id
                        and privado.posicao_candidatavel(x.*, v_agora)) then
    perform public.erro(409, 'vaga_encerrada');
  end if;

  -- RN05: a função é o primeiro critério de elegibilidade, e o único que o profissional
  -- controla. Distância e disponibilidade valem para a **notificação** (B07), não para
  -- a candidatura: quem viu a vaga e quer o turno pode aceitá-lo.
  if not exists (select 1 from public.profissional_funcao pf
                  where pf.profissional_id = v_prof and pf.funcao_id = v.funcao_id) then
    perform public.erro(422, 'inelegivel', 'funcao_incompativel');
  end if;

  -- ── RN19: a confirmação ─────────────────────────────────────────────────────
  --
  -- `SKIP LOCKED` é o que separa vinte candidatos disputando a mesma linha de vinte
  -- candidatos pegando linhas diferentes. Sem ele, dezenove esperariam o commit do
  -- primeiro para só então descobrir que perderam.
  begin
    update public.posicao p
       set estado = 'confirmada',
           profissional_id = v_prof,
           confirmado_em = v_agora
     where p.id = (select x.id from public.posicao x
                    where x.vaga_id = candidatar.vaga_id
                      and privado.posicao_candidatavel(x.*, v_agora)
                    order by x.id
                    for update skip locked
                    limit 1)
    returning p.id into v_pos;
  exception
    when exclusion_violation then
      -- RN21, pelo `EXCLUDE USING gist` de `posicao`. A recusa sai com o código do
      -- contrato em vez do 23P01 cru, que o app não sabe ler.
      perform public.erro(422, 'inelegivel', 'turno_sobreposto');
  end;

  if v_pos is null then
    perform public.erro(409, 'posicao_ja_preenchida');
  end if;

  insert into public.candidatura (posicao_id, profissional_id, estado)
  values (v_pos, v_prof, 'aceita')
  on conflict (posicao_id, profissional_id)
    do update set estado = 'aceita'
  returning id into v_cand;

  -- RN11: o valor viaja para o turno. Se a casa republicar com outro valor, o turno
  -- executado continua dizendo quanto foi combinado — registro que muda sozinho não
  -- vale nada.
  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_pos, v.valor_centavos)
  returning id into v_turno;

  -- A vaga fecha quando não sobra posição aberta. O `for update` na linha da vaga não é
  -- zelo: sem ele, as duas últimas confirmações simultâneas contam as posições abertas
  -- cada uma no próprio snapshot, nenhuma enxerga a escrita da outra, e a vaga fica
  -- `publicada` com zero posições livres. Medido na CI em 24/09, com vinte conexões —
  -- a máquina de desenvolvimento não reproduzia, porque o intervalo entre os dois
  -- commits era grande demais.
  --
  -- A ordem de aquisição é sempre posição e depois vaga, em todas as transações, o que
  -- mantém o caminho livre de impasse. O `skip locked` continua fazendo o seu trabalho
  -- antes disto: a serialização é só do fechamento, não da disputa.
  perform 1 from public.vaga g where g.id = candidatar.vaga_id for update;

  if not exists (select 1 from public.posicao p
                  where p.vaga_id = candidatar.vaga_id and p.estado = 'aberta') then
    update public.vaga g set estado = 'preenchida'
     where g.id = candidatar.vaga_id and g.estado = 'publicada';
  end if;

  -- RF10: a confirmação avisa o profissional e cada membro da casa. Só chega aqui a
  -- candidatura que de fato confirmou: o reenvio devolveu o turno lá em cima, antes de
  -- qualquer escrita, e por isso não enfileira aviso de novo.
  perform privado.notificar(v_uid, 'confirmacao', v_turno,
    jsonb_build_object('turno_id', v_turno, 'vaga_id', candidatar.vaga_id));
  perform privado.notificar_membros(v.estabelecimento_id, 'confirmacao', v_turno,
    jsonb_build_object('turno_id', v_turno, 'vaga_id', candidatar.vaga_id));

  return jsonb_build_object(
    'estado',         'confirmada',
    'candidatura_id', v_cand,
    'posicao_id',     v_pos,
    'turno_id',       v_turno,
    'contato',        privado.contato_do_estabelecimento(candidatar.vaga_id));
end $$;


comment on function public.candidatar(uuid) is
  'Candidatura com confirmação sem duplicidade (RN19, RN21). Antes do início, qualquer posição aberta; depois, só a reaberta por atraso até fim − 1 h (contrato 0.2.19). Avisa o profissional e cada membro da casa (RF10).';

revoke execute on function public.candidatar(uuid) from public, anon;
grant execute on function public.candidatar(uuid) to authenticated;

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
  if not found or v.estado <> 'publicada' or privado.vaga_oculta(v.id) then
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

comment on function privado.despachar_vaga(uuid, text, uuid) is
  'Cria o despacho de cada elegível da rodada corrente de uma vaga e passa pelo teto da RN23: sai na hora se a janela do profissional fechou ou se a vaga começa em menos de 2 h; senão espera o agendador (liberar_teto). Da rodada 2 em diante o push é o de vaga reaberta. Se não há elegível, envia vaga_sem_elegiveis.';

revoke execute on function privado.despachar_vaga(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function privado.despachar_vaga(uuid, text, uuid) to service_role;

create or replace function privado.liberar_teto_do_profissional(p_profissional uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_usuario uuid;
  v_ultima  timestamptz;
  v_ids     uuid[];
  v_vagas   uuid[];
  v_ref     uuid;
  v_reab    boolean;
  v_esperou boolean;
  v_payload jsonb;
  v_notif   uuid;
begin
  perform privado.travar_teto(p_profissional);

  select p.usuario_id into v_usuario from public.profissional p where p.id = p_profissional;
  if v_usuario is null then
    return null;
  end if;

  v_ultima := privado.ultima_no_teto(v_usuario);
  if v_ultima is not null
     and v_ultima > v_agora - privado.parametro_de_notificacao('teto_janela') then
    return null;
  end if;

  select array_agg(d.id order by d.criado_em, d.id),
         array_agg(d.vaga_id order by d.criado_em, d.id),
         bool_or(d.reaberta),
         bool_or(d.criado_em < v_agora)
    into v_ids, v_vagas, v_reab, v_esperou
    from public.despacho d
    join public.vaga v on v.id = d.vaga_id
   where d.profissional_id = p_profissional
     and d.notificacao_id is null
     and v.estado = 'publicada'
     and v.inicio_em > v_agora
     -- Ocultada pela Equipe Frila: o despacho espera; se ela for reexibida, sai.
     and not privado.vaga_oculta(v.id)
     -- RF26: o bloqueio que veio enquanto o despacho esperava o teto.
     and not privado.bloqueado_com_estabelecimento(v_usuario, v.estabelecimento_id);

  if v_ids is null then
    return null;
  end if;

  if cardinality(v_ids) = 1 then
    v_payload := jsonb_build_object('vaga_id', v_vagas[1]);
    if v_reab then
      v_payload := v_payload || jsonb_build_object('reaberta', true);
    end if;
    v_notif := privado.notificar(v_usuario, 'vaga', v_vagas[1], v_payload);
  else
    -- A referência é a vaga que começa por último: a agrupada só expira (não é mais
    -- enviada) quando todas as vagas dela já começaram. O toque abre a aba de vagas, e o
    -- payload leva só o tipo.
    select v.id into v_ref from public.vaga v
     where v.id = any (v_vagas)
     order by v.inicio_em desc, v.id
     limit 1;
    v_notif := privado.notificar(v_usuario, 'vagas_agrupadas', v_ref, '{}'::jsonb);
  end if;

  update public.notificacao n
     set esperou_teto = v_esperou or cardinality(v_ids) > 1
   where n.id = v_notif;

  update public.despacho d
     set notificacao_id = v_notif
   where d.id = any (v_ids)
     and d.notificacao_id is null;

  return v_notif;
end $$;

comment on function privado.liberar_teto_do_profissional(uuid) is
  'RN23: se a janela do teto do profissional fechou, transforma os despachos que esperavam numa notificação (vaga, ou vagas_agrupadas com dois ou mais). Sob trava por profissional. Vaga de estabelecimento com bloqueio entre as partes não sai (RF26), nem a ocultada pela Equipe Frila.';

revoke execute on function privado.liberar_teto_do_profissional(uuid) from public, anon, authenticated;
grant  execute on function privado.liberar_teto_do_profissional(uuid) to service_role;

create or replace function privado.notificacao_expirada(p_notificacao_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_notif public.notificacao%rowtype;
begin
  select * into v_notif from public.notificacao where id = p_notificacao_id;
  if not found then
    return true;
  end if;

  if v_notif.tipo = 'vaga'
     and exists (select 1 from public.vaga v
                  where v.id = v_notif.referencia_id
                    and (privado.bloqueado_com_estabelecimento(v_notif.usuario_id, v.estabelecimento_id)
                         or privado.vaga_oculta(v.id))) then
    return true;
  end if;

  -- A agrupada só deixa de servir quando todas as vagas dela são de casas bloqueadas.
  if v_notif.tipo = 'vagas_agrupadas'
     and exists (select 1 from public.despacho d where d.notificacao_id = v_notif.id)
     and not exists (select 1 from public.despacho d
                       join public.vaga v on v.id = d.vaga_id
                      where d.notificacao_id = v_notif.id
                        and not privado.bloqueado_com_estabelecimento(v_notif.usuario_id, v.estabelecimento_id)
                        and not privado.vaga_oculta(v.id)) then
    return true;
  end if;

  return privado.notificacao_expirada_pelo_relogio(p_notificacao_id);
end $$;

comment on function privado.notificacao_expirada(uuid) is
  'Verifica se o aviso ainda serve. O aviso de vaga de estabelecimento com bloqueio entre as partes não serve mais (RF26), nem o de vaga ocultada pela Equipe Frila; o resto é a regra de tempo de notificacao_expirada_pelo_relogio.';

revoke execute on function privado.notificacao_expirada(uuid) from public, anon, authenticated;
grant  execute on function privado.notificacao_expirada(uuid) to service_role;

create or replace function public.painel_estabelecimento(
  estabelecimento_id uuid,
  de                 timestamptz,
  ate                timestamptz
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_estab     uuid := painel_estabelecimento.estabelecimento_id;
  v_de        timestamptz := painel_estabelecimento.de;
  v_ate       timestamptz := painel_estabelecimento.ate;
  v_agora     timestamptz;
  v_vagas     jsonb;
  v_pendentes jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if v_estab is null or not privado.eh_membro(v_estab) then
    perform public.erro(403, 'sem_permissao');
  end if;

  if v_de is null then
    perform public.erro(422, 'campo_obrigatorio', 'de');
  end if;
  if v_ate is null then
    perform public.erro(422, 'campo_obrigatorio', 'ate');
  end if;

  v_agora := privado.agora();

  select coalesce(jsonb_agg(jsonb_build_object(
           'vaga', jsonb_build_object(
              'id',                    v.id,
              'funcao',                f.nome,
              'local',                 v.local,
              'regiao_administrativa', v.regiao_administrativa,
              'inicio_em',             v.inicio_em,
              'fim_em',                v.fim_em,
              'valor_centavos',        v.valor_centavos),
           'modo',   v.modo,
           'estado', v.estado,
           -- A casa vê "oculta pela Equipe"; o estado segue o do ciclo de vida (0.2.23).
           'oculta', privado.vaga_oculta(v.id),
           'alerta_vaga_vazia',
              v.estado = 'publicada'
              and v_agora >= v.inicio_em - v.alerta_antecedencia
              and v_agora <  v.inicio_em
              and exists (select 1 from public.posicao pa
                           where pa.vaga_id = v.id and pa.estado = 'aberta'),
           'candidatos_pendentes',
              (select count(distinct c.profissional_id)
                 from public.candidatura c
                 join public.posicao pc on pc.id = c.posicao_id
                where pc.vaga_id = v.id
                  and c.estado = 'pendente'
                  and not privado.bloqueado_com_estabelecimento(
                            privado.usuario_do_profissional(c.profissional_id), v_estab)),
           'posicoes',
              (select coalesce(jsonb_agg(jsonb_build_object(
                        'id',     p.id,
                        'estado', p.estado,
                        'profissional',
                           case when p.profissional_id is null then null
                                else privado.perfil_publico_profissional(p.profissional_id) end,
                        'turno_id',    t.id,
                        'verificacao', t.verificacao,
                        'em_atraso',
                           p.estado = 'confirmada'
                           and t.checkin_em is null
                           and v_agora >= p.inicio_em + interval '15 minutes'
                           and v_agora <  p.fim_em)
                      order by p.id), '[]'::jsonb)
                 from public.posicao p
                 left join public.turno t on t.posicao_id = p.id
                where p.vaga_id = v.id))
         order by v.inicio_em, v.id), '[]'::jsonb)
    into v_vagas
    from public.vaga v
    join public.funcao f on f.id = v.funcao_id
   where v.estabelecimento_id = v_estab
     and v.inicio_em < v_ate
     and v.fim_em    > v_de;

  select coalesce(jsonb_agg(t.id order by t.checkin_em, t.id), '[]'::jsonb)
    into v_pendentes
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v    on v.id = p.vaga_id
   where v.estabelecimento_id = v_estab
     and v.inicio_em < v_ate
     and v.fim_em    > v_de
     and p.estado in ('confirmada', 'cumprida')
     and t.checkin_tipo = 'manual'
     and t.checkin_confirmado_em is null;

  return jsonb_build_object(
    'estabelecimento_id', v_estab,
    'vagas',              v_vagas,
    'checkins_pendentes', v_pendentes);
end $$;

comment on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) is
  'Vagas, candidatos, contratados, check-ins e turnos do estabelecimento (RF20, RF13, UC07). Expõe regiao_administrativa em VagaResumo.';

revoke execute on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) from public, anon;
grant  execute on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) to authenticated;

create or replace function public.republicar_vaga(
  vaga_id   uuid,
  inicio_em timestamptz,
  fim_em    timestamptz,
  chave     uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_origem public.vaga%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('contratante');

  if republicar_vaga.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  select * into v_origem from public.vaga g where g.id = republicar_vaga.vaga_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if not privado.eh_membro(v_origem.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- A cópia levaria o conteúdo moderado de volta à vitrine como vaga nova (0.2.23).
  if privado.vaga_oculta(v_origem.id) then
    perform public.erro(422, 'vaga_oculta');
  end if;

  return public.publicar_vaga(
    estabelecimento_id     => v_origem.estabelecimento_id,
    funcao_id              => v_origem.funcao_id,
    inicio_em              => republicar_vaga.inicio_em,
    fim_em                 => republicar_vaga.fim_em,
    local                  => v_origem.local,
    ponto                  => jsonb_build_object(
                                'latitude',  extensions.ST_Y(v_origem.ponto::extensions.geometry),
                                'longitude', extensions.ST_X(v_origem.ponto::extensions.geometry)),
    valor_centavos         => v_origem.valor_centavos,
    posicoes               => v_origem.posicoes,
    inclui_refeicao        => v_origem.inclui_refeicao,
    inclui_transporte      => v_origem.inclui_transporte,
    exige_material_proprio => v_origem.exige_material_proprio,
    responsavel_local      => v_origem.responsavel_local,
    modo                   => v_origem.modo,
    chave                  => republicar_vaga.chave,
    traje                  => v_origem.traje,
    participa_rateio       => v_origem.participa_rateio,
    observacoes            => v_origem.observacoes,
    alerta_antecedencia_min => (extract(epoch from v_origem.alerta_antecedencia) / 60)::int,
    regiao_administrativa  => v_origem.regiao_administrativa);
end $$;

comment on function public.republicar_vaga(uuid, timestamptz, timestamptz, uuid) is
  'Copia os campos da vaga de origem mudando início, fim e chave (RF05, US05). Preserva regiao_administrativa.';

revoke execute on function public.republicar_vaga(uuid, timestamptz, timestamptz, uuid) from public, anon;
grant  execute on function public.republicar_vaga(uuid, timestamptz, timestamptz, uuid) to authenticated;

-- ── 4. Moderação de Conteúdo (Diretriz 1.2 da App Store) ─────────────────────────

create or replace function privado.operacao_moderar_conteudo(
  vaga_id     uuid,
  acao        text,
  motivo      text,
  operador_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_vaga_id  uuid := operacao_moderar_conteudo.vaga_id;
  v_acao     text := pg_catalog.btrim(operacao_moderar_conteudo.acao);
  v_motivo   text := pg_catalog.btrim(operacao_moderar_conteudo.motivo);
  v_operador uuid := operacao_moderar_conteudo.operador_id;
  v_vaga     public.vaga%rowtype;
  v_agora    timestamptz := privado.agora();
  v_oc_id    uuid;
begin
  if v_vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  select * into v_vaga
    from public.vaga g
   where g.id = v_vaga_id
     for update;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_vaga.publicado_por);

  if v_acao is null or v_acao not in ('ocultar', 'reexibir') then
    perform public.erro(422, 'campo_invalido', 'acao');
  end if;

  if v_acao = 'ocultar' then
    if privado.vaga_oculta(v_vaga_id) then
      return jsonb_build_object(
        'vaga_id',          v_vaga_id,
        'estado_atual',     v_vaga.estado,
        'oculta',           true,
        'ja_estava_oculta', true
      );
    end if;

    -- Só a vaga que ainda é oferecida tem o que ocultar.
    if v_vaga.estado not in ('publicada', 'preenchida') then
      perform public.erro(422, 'campo_invalido', 'estado_da_vaga');
    end if;

    -- `suporte`, não `denuncia`: a denúncia é de quem a abriu (`denunciar`), e esta
    -- ocorrência é a ação da Equipe Frila sobre ela.
    insert into public.ocorrencia (
      tipo, usuario_id, estabelecimento_id, autor_id, motivo, criada_em, resolvido_em, resultado
    ) values (
      'suporte',
      v_vaga.publicado_por,
      v_vaga.estabelecimento_id,
      v_operador,
      'Moderação Diretriz 1.2: ' || v_motivo,
      v_agora,
      v_agora,
      'Vaga ocultada em até 24h pela Equipe Frila, sem cancelar os turnos confirmados.'
    ) returning id into v_oc_id;

    insert into privado.vaga_ocultada (vaga_id, ocorrencia_id, oculta_em)
    values (v_vaga_id, v_oc_id, v_agora);

    return jsonb_build_object(
      'vaga_id',       v_vaga_id,
      'estado_atual',  v_vaga.estado,
      'oculta',        true,
      'ocorrencia_id', v_oc_id,
      'acao',          'ocultar',
      'moderado_em',   v_agora
    );

  else -- v_acao = 'reexibir'
    -- Só a vaga que a Equipe ocultou. Reexibir tira a marca e não mexe no `estado`: a
    -- vaga que a casa cancelou (antes ou depois de ocultada) segue cancelada.
    if not privado.vaga_oculta(v_vaga_id) then
      perform public.erro(422, 'campo_invalido', 'vaga_nao_ocultada');
    end if;

    delete from privado.vaga_ocultada o where o.vaga_id = v_vaga_id;

    insert into public.ocorrencia (
      tipo, usuario_id, estabelecimento_id, autor_id, motivo, criada_em, resolvido_em, resultado
    ) values (
      'suporte',
      v_vaga.publicado_por,
      v_vaga.estabelecimento_id,
      v_operador,
      'Moderação Reexibir: ' || v_motivo,
      v_agora,
      v_agora,
      'Vaga reexibida pela Equipe Frila após análise da moderação.'
    ) returning id into v_oc_id;

    -- O despacho que chegou enquanto ela estava oculta saiu sem ninguém; esta volta a
    -- oferecê-la a quem ainda não recebeu (despacho é único por vaga e profissional).
    if v_vaga.estado = 'publicada' and v_vaga.inicio_em > v_agora then
      perform pgmq.send('despacho', jsonb_build_object(
        'vaga_id', v_vaga_id,
        'motivo',  'reexibicao'));
    end if;

    return jsonb_build_object(
      'vaga_id',       v_vaga_id,
      'estado_atual',  v_vaga.estado,
      'oculta',        false,
      'ocorrencia_id', v_oc_id,
      'acao',          'reexibir',
      'reexibido_em',  v_agora
    );
  end if;
end $$;

comment on function privado.operacao_moderar_conteudo(uuid, text, text, uuid) is
  'Modera conteúdo denunciado em até 24h (Diretriz 1.2 da App Store). Ocultar tira a vaga da vitrine, do detalhe, da candidatura e do despacho sem cancelá-la (privado.vaga_ocultada); reexibir só vale para a vaga que a Equipe ocultou e não muda o estado. Ocorrência de suporte assinada pelo operador da Equipe Frila. Restrito a service_role.';

revoke execute on function privado.operacao_moderar_conteudo(uuid, text, text, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_moderar_conteudo(uuid, text, text, uuid) to service_role;
