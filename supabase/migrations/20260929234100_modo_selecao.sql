-- Modo seleção: escolher candidato e fechamento automático (cartão d3A1WjG3, US12, RF09,
-- RN19, RN21, RN24, UC04; contrato 0.2.24).
--
-- Para vaga que começa em mais de 24 h, o contratante escolhe entre os candidatos. Sem
-- escolha até 24 h antes, a vaga fecha sozinha e os candidatos são avisados e liberados. A
-- candidatura vale até a vaga fechar e pode ser retirada sem penalidade.
--
-- ── O modelo não muda ─────────────────────────────────────────────────────────
--
-- A candidatura continua presa a uma posição (Modelagem, `candidatura.posicao_id NOT
-- NULL`), e a posição continua com quatro estados, sem `reservada`: no modo seleção ela
-- fica `aberta` até a escolha. A candidatura pendente se prende à primeira posição aberta
-- da vaga, só para ter onde morar; a resposta não a mostra (`posicao_id` nulo no contrato),
-- porque não é ela que o profissional vai ocupar. Quem decide a posição é a escolha, que
-- move a candidatura para a posição que confirmou.
--
-- ── Travas ────────────────────────────────────────────────────────────────────
--
-- A vaga antes da posição, em todo caminho novo (CPD2c74A, #63): `candidatar` já trava a
-- vaga no começo (`privado.travar_candidatura`); `escolher_candidato`,
-- `retirar_candidatura` e o fechamento travam a vaga e só então tocam posição e
-- candidatura. Duas escolhas simultâneas para a última posição se enfileiram na trava da
-- vaga: a segunda relê a vaga já `preenchida` e recebe `409 posicao_ja_preenchida` (RN19).
-- A corrida está em `scripts/corrida-ciclo.sh`.
--
-- ── Estados da candidatura ────────────────────────────────────────────────────
--
--   pendente   candidatou-se e espera a escolha
--   aceita     foi escolhida (e, no modo urgência, confirmada na hora)
--   recusada   a vaga encheu com outros escolhidos
--   retirada   o profissional desistiu antes da escolha, sem penalidade (RN24)
--   expirada   a vaga fechou (24 h antes, cancelada ou encerrada) sem escolhê-la

-- ── 1. publicar_vaga aceita o modo seleção (RN24) ─────────────────────────────

create or replace function public.publicar_vaga(
  estabelecimento_id      uuid,
  funcao_id               uuid,
  inicio_em               timestamptz,
  fim_em                  timestamptz,
  local                   text,
  ponto                   jsonb,
  valor_centavos          bigint,
  posicoes                integer,
  inclui_refeicao         boolean,
  inclui_transporte       boolean,
  exige_material_proprio  boolean,
  responsavel_local       text,
  modo                    public.modo_preenchimento,
  chave                   uuid,
  traje                   text    default null,
  participa_rateio        boolean default null,
  observacoes             text    default null,
  alerta_antecedencia_min int     default 180,
  regiao_administrativa   text    default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_local     text := btrim(publicar_vaga.local);
  v_resp      text := btrim(publicar_vaga.responsavel_local);
  v_traje     text := btrim(publicar_vaga.traje);
  v_obs       text := btrim(publicar_vaga.observacoes);
  v_regiao    text;
  v_agora     timestamptz;
  v_ponto     extensions.geography;
  v_vaga      public.vaga%rowtype;
  v_posicoes  uuid[];
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('contratante');

  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  if not privado.eh_membro(publicar_vaga.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- RN02: vaga incompleta não existe
  if publicar_vaga.funcao_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'funcao_id');
  end if;
  if publicar_vaga.inicio_em is null then
    perform public.erro(422, 'campo_obrigatorio', 'inicio_em');
  end if;
  if publicar_vaga.fim_em is null then
    perform public.erro(422, 'campo_obrigatorio', 'fim_em');
  end if;
  if v_local is null or v_local = '' then
    perform public.erro(422, 'campo_obrigatorio', 'local');
  end if;
  if v_resp is null or v_resp = '' then
    perform public.erro(422, 'campo_obrigatorio', 'responsavel_local');
  end if;
  if publicar_vaga.valor_centavos is null then
    perform public.erro(422, 'campo_obrigatorio', 'valor_centavos');
  end if;
  if publicar_vaga.posicoes is null then
    perform public.erro(422, 'campo_obrigatorio', 'posicoes');
  end if;
  if publicar_vaga.inclui_refeicao is null then
    perform public.erro(422, 'campo_obrigatorio', 'inclui_refeicao');
  end if;
  if publicar_vaga.inclui_transporte is null then
    perform public.erro(422, 'campo_obrigatorio', 'inclui_transporte');
  end if;
  if publicar_vaga.exige_material_proprio is null then
    perform public.erro(422, 'campo_obrigatorio', 'exige_material_proprio');
  end if;
  if publicar_vaga.modo is null then
    perform public.erro(422, 'campo_obrigatorio', 'modo');
  end if;
  if publicar_vaga.chave is null then
    perform public.erro(422, 'campo_obrigatorio', 'chave');
  end if;

  -- Região administrativa: informada na publicação ou herdada do estabelecimento
  if publicar_vaga.regiao_administrativa is not null then
    v_regiao := btrim(publicar_vaga.regiao_administrativa);
    if v_regiao = '' then
      perform public.erro(422, 'campo_obrigatorio', 'regiao_administrativa');
    end if;
  else
    select e.regiao_administrativa into v_regiao
      from public.estabelecimento e
     where e.id = publicar_vaga.estabelecimento_id;
    if v_regiao is null or btrim(v_regiao) = '' then
      perform public.erro(422, 'campo_obrigatorio', 'regiao_administrativa');
    end if;
  end if;

  if publicar_vaga.valor_centavos <= 0 then
    perform public.erro(422, 'campo_invalido', 'valor_centavos');
  end if;
  if publicar_vaga.posicoes < 1 or publicar_vaga.posicoes > 200 then
    perform public.erro(422, 'campo_invalido', 'posicoes');
  end if;
  if publicar_vaga.alerta_antecedencia_min is null
     or publicar_vaga.alerta_antecedencia_min < 1 then
    perform public.erro(422, 'campo_invalido', 'alerta_antecedencia_min');
  end if;

  if not exists (select 1 from public.funcao f where f.id = publicar_vaga.funcao_id) then
    perform public.erro(422, 'campo_invalido', 'funcao_id');
  end if;

  v_agora := privado.agora();

  if publicar_vaga.fim_em <= publicar_vaga.inicio_em then
    perform public.erro(422, 'horario_invalido');
  end if;
  if publicar_vaga.inicio_em <= v_agora then
    perform public.erro(422, 'horario_invalido');
  end if;

  -- RN24: o modo seleção fecha sozinho 24 horas antes do início. Uma vaga de seleção
  -- que começa em 24 horas ou menos nasceria fechada — então ela nem entra. Até a 0.2.23
  -- o modo seleção era recusado com `campo_invalido` (escopo do MVP); desde a 0.2.24 ele
  -- existe, e a recusa é a regra das 24 horas.
  if publicar_vaga.modo = 'selecao'
     and publicar_vaga.inicio_em <= v_agora + interval '24 hours' then
    perform public.erro(422, 'selecao_sem_antecedencia');
  end if;

  -- Diretriz 1.2 da App Store nos campos livres da vaga
  perform privado.exigir_texto_aceitavel(jsonb_build_object(
    'local',                 v_local,
    'regiao_administrativa', v_regiao,
    'responsavel_local',     v_resp,
    'traje',                 v_traje,
    'observacoes',           v_obs));

  v_ponto := privado.ponto_do_json(publicar_vaga.ponto, 'ponto');

  -- RF04: chave de idempotência do cliente
  select * into v_vaga
    from public.vaga g
   where g.estabelecimento_id = publicar_vaga.estabelecimento_id
     and g.chave_cliente = publicar_vaga.chave;

  if found then
    select array_agg(p.id order by p.id) into v_posicoes
      from public.posicao p where p.vaga_id = v_vaga.id;
    return jsonb_build_object('vaga_id', v_vaga.id,
                              'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[])));
  end if;

  begin
    insert into public.vaga (
      estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa, ponto,
      valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
      exige_material_proprio, responsavel_local, traje, participa_rateio,
      observacoes, modo, alerta_antecedencia, publicado_por, chave_cliente)
    values (
      publicar_vaga.estabelecimento_id, publicar_vaga.funcao_id,
      publicar_vaga.inicio_em, publicar_vaga.fim_em, v_local, v_regiao, v_ponto,
      publicar_vaga.valor_centavos, publicar_vaga.posicoes,
      publicar_vaga.inclui_refeicao, publicar_vaga.inclui_transporte,
      publicar_vaga.exige_material_proprio, v_resp,
      nullif(v_traje, ''), publicar_vaga.participa_rateio, nullif(v_obs, ''),
      publicar_vaga.modo,
      make_interval(mins => publicar_vaga.alerta_antecedencia_min),
      v_uid, publicar_vaga.chave)
    returning * into v_vaga;
  exception
    when unique_violation then
      select * into v_vaga
        from public.vaga g
       where g.estabelecimento_id = publicar_vaga.estabelecimento_id
         and g.chave_cliente = publicar_vaga.chave;
      select array_agg(p.id order by p.id) into v_posicoes
        from public.posicao p where p.vaga_id = v_vaga.id;
      return jsonb_build_object('vaga_id', v_vaga.id,
                                'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[])));
  end;

  insert into public.posicao (vaga_id, inicio_em, fim_em)
  select v_vaga.id, v_vaga.inicio_em, v_vaga.fim_em
    from generate_series(1, publicar_vaga.posicoes);

  select array_agg(p.id order by p.id) into v_posicoes
    from public.posicao p where p.vaga_id = v_vaga.id;

  perform pgmq.send('despacho', jsonb_build_object(
    'vaga_id',      v_vaga.id,
    'publicada_em', v_vaga.publicado_em));

  return jsonb_build_object('vaga_id', v_vaga.id, 'posicoes', to_jsonb(v_posicoes));
end $$;

comment on function public.publicar_vaga(
  uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int, text
) is
  'Publica vaga e cria as posições pedidas (RN02, RN03). Enfileira o despacho em pgmq (B15). Reenvio seguro por chave_cliente (RF04). regiao_administrativa gravada na vaga (0.2.20). Modo seleção só com mais de 24 h (RN24, 0.2.24).';

revoke execute on function public.publicar_vaga(
  uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int, text
) from public, anon;

grant execute on function public.publicar_vaga(
  uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int, text
) to authenticated;

-- ── 2. candidatar: o ramo do modo seleção ─────────────────────────────────────

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

  -- Modo seleção (contrato 0.2.24): a candidatura fica pendente até a casa escolher, e a
  -- posição só é decidida na escolha. Nada de RN19 aqui — é `escolher_candidato` quem
  -- confirma, com a mesma escrita condicional.
  if v.modo = 'selecao' then
    return privado.candidatar_na_selecao(v, v_prof, v_agora);
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
  'Candidatura com confirmação sem duplicidade (RN19, RN21). Antes do início, qualquer posição aberta; depois, só a reaberta por atraso até fim − 1 h (contrato 0.2.19). Avisa o profissional e cada membro da casa (RF10). No modo seleção, a candidatura fica pendente até a escolha (contrato 0.2.24).';

revoke execute on function public.candidatar(uuid) from public, anon;
grant execute on function public.candidatar(uuid) to authenticated;

-- ── 3. A candidatura em JSON (Candidatura do contrato) ──────────────────────

create or replace function privado.candidatura_em_json(candidatura uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id',     c.id,
    'vaga',   jsonb_build_object(
                'id',                    v.id,
                'funcao',                f.nome,
                'local',                 v.local,
                'regiao_administrativa', v.regiao_administrativa,
                'inicio_em',             v.inicio_em,
                'fim_em',                v.fim_em,
                'valor_centavos',        v.valor_centavos),
    'estado',    c.estado,
    'criada_em', c.criada_em)
    from public.candidatura c
    join public.posicao x on x.id = c.posicao_id
    join public.vaga v    on v.id = x.vaga_id
    join public.funcao f  on f.id = v.funcao_id
   where c.id = candidatura
$$;

comment on function privado.candidatura_em_json(uuid) is
  'Candidatura no formato do contrato: id, vaga (VagaResumo), estado e criada_em.';

revoke execute on function privado.candidatura_em_json(uuid) from public, anon, authenticated;
grant  execute on function privado.candidatura_em_json(uuid) to service_role;

-- ── 4. candidatar numa vaga de seleção ────────────────────────────────────────
--
-- Chamada por `candidatar` depois das conferências comuns aos dois modos (vaga visível,
-- publicada, não começada, função compatível) e com a vaga já travada por
-- `privado.travar_candidatura`.

create or replace function privado.candidatar_na_selecao(
  v      public.vaga,
  prof   uuid,
  agora  timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cand   uuid;
  v_estado public.estado_candidatura;
  v_pos    uuid;
begin
  -- RN24: a 24 horas do início a vaga de seleção está fechada, tenha o agendador passado
  -- por ela ou não. A regra não pode depender de o job ter rodado neste minuto.
  if agora >= v.inicio_em - interval '24 hours' then
    perform public.erro(409, 'vaga_encerrada');
  end if;

  select c.id, c.estado into v_cand, v_estado
    from public.candidatura c
    join public.posicao x on x.id = c.posicao_id
   where x.vaga_id = v.id and c.profissional_id = prof;

  -- Idempotência pela chave natural (vaga, profissional): o reenvio devolve a mesma
  -- candidatura pendente, sem escrever nada.
  if v_estado = 'pendente' then
    return jsonb_build_object('estado', 'pendente', 'candidatura_id', v_cand,
                              'posicao_id', null, 'turno_id', null, 'contato', null);
  end if;

  -- RN21 já na candidatura: quem tem turno confirmado no mesmo horário não pode ser
  -- escolhido, e a tela diz isso agora em vez de deixar a casa descobrir na escolha. A
  -- garantia continua sendo o `EXCLUDE` de `posicao`, na escolha.
  if exists (select 1 from public.posicao x
              where x.profissional_id = prof
                and x.estado in ('confirmada', 'cumprida')
                and tstzrange(x.inicio_em, x.fim_em) && tstzrange(v.inicio_em, v.fim_em)) then
    perform public.erro(422, 'inelegivel', 'turno_sobreposto');
  end if;

  if v_cand is not null then
    -- A retirada (ou a recusada de uma vaga que reabriu) volta a valer: candidatar-se de
    -- novo é o caminho para desfazer a retirada, e sem penalidade.
    update public.candidatura c
       set estado = 'pendente', criada_em = agora
     where c.id = v_cand;
  else
    select x.id into v_pos
      from public.posicao x
     where x.vaga_id = v.id and x.estado = 'aberta'
     order by x.id
     limit 1;
    if v_pos is null then
      perform public.erro(409, 'posicao_ja_preenchida');
    end if;

    insert into public.candidatura (posicao_id, profissional_id, estado, criada_em)
    values (v_pos, prof, 'pendente', agora)
    returning id into v_cand;
  end if;

  return jsonb_build_object('estado', 'pendente', 'candidatura_id', v_cand,
                            'posicao_id', null, 'turno_id', null, 'contato', null);
end $$;

comment on function privado.candidatar_na_selecao(public.vaga, uuid, timestamptz) is
  'Ramo do modo seleção de candidatar: candidatura pendente, sem posição, turno nem contato na resposta (contrato 0.2.24). Recusa a partir de 24 h antes do início (RN24) e turno sobreposto (RN21). Reenvio devolve a mesma; retirada volta a pendente.';

revoke execute on function privado.candidatar_na_selecao(public.vaga, uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function privado.candidatar_na_selecao(public.vaga, uuid, timestamptz)
  to service_role;

-- ── 5. escolher_candidato ─────────────────────────────────────────────────────

create or replace function public.escolher_candidato(candidatura_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid     uuid := (select auth.uid());
  v_vaga_id uuid;
  v_agora   timestamptz;
  v         public.vaga%rowtype;
  c         public.candidatura%rowtype;
  v_pos     uuid;
  v_turno   uuid;
  v_outra   record;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('contratante');

  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  if escolher_candidato.candidatura_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'candidatura_id');
  end if;

  -- Candidatura que não existe e candidatura de outra casa respondem igual, como em
  -- `publicar_vaga`: um código diferente confirmaria a quem não é da casa que o id existe.
  select x.vaga_id into v_vaga_id
    from public.candidatura k
    join public.posicao x on x.id = k.posicao_id
   where k.id = escolher_candidato.candidatura_id;

  if v_vaga_id is null
     or not privado.eh_membro(privado.estabelecimento_da_vaga(v_vaga_id)) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- A vaga antes de qualquer posição (CPD2c74A). É esta trava que serializa duas
  -- escolhas para a mesma vaga: a segunda espera o commit da primeira e relê tudo.
  select * into v from public.vaga g where g.id = v_vaga_id for update;
  select * into c from public.candidatura k
   where k.id = escolher_candidato.candidatura_id for update;

  -- A ordem das recusas é a da tela. A escolhida é `candidatura_indisponivel`. Com a vaga
  -- cheia, `posicao_ja_preenchida` vem antes do estado da candidatura: na corrida de duas
  -- escolhas, a que perde encontra a própria candidatura já recusada pela que ganhou, e o
  -- que a casa precisa ouvir é que a posição foi preenchida (RN19).
  if v.modo <> 'selecao' or c.estado = 'aceita' then
    perform public.erro(409, 'candidatura_indisponivel');
  end if;

  -- Ocultada pela moderação da Equipe Frila (contrato 0.2.23): a escolha é recusada e a
  -- candidatura segue pendente; volta a valer se a Equipe reexibir a vaga.
  if privado.vaga_oculta(v.id) then
    perform public.erro(422, 'vaga_oculta');
  end if;

  v_agora := privado.agora();

  if v.estado = 'preenchida' then
    perform public.erro(409, 'posicao_ja_preenchida');
  end if;
  if v.estado <> 'publicada' or v_agora >= v.inicio_em - interval '24 hours' then
    perform public.erro(409, 'vaga_encerrada');
  end if;
  if c.estado <> 'pendente' then
    perform public.erro(409, 'candidatura_indisponivel');
  end if;

  -- RN13: suspenso depois de se candidatar não assume turno, como em `candidatar`.
  if exists (select 1 from public.profissional p
               join public.usuario u on u.id = p.usuario_id
              where p.id = c.profissional_id and u.estado <> 'ativa') then
    perform public.erro(422, 'inelegivel', 'perfil_suspenso');
  end if;

  -- RN19: a mesma escrita condicional do modo urgência. RN21 pelo `EXCLUDE` de `posicao`.
  begin
    update public.posicao p
       set estado = 'confirmada',
           profissional_id = c.profissional_id,
           confirmado_em = v_agora
     where p.id = (select x.id from public.posicao x
                    where x.vaga_id = v.id and x.estado = 'aberta'
                    order by x.id
                    for update
                    limit 1)
    returning p.id into v_pos;
  exception
    when exclusion_violation then
      perform public.erro(422, 'inelegivel', 'turno_sobreposto');
  end;

  if v_pos is null then
    perform public.erro(409, 'posicao_ja_preenchida');
  end if;

  -- A candidatura vai para a posição que de fato confirmou.
  update public.candidatura k
     set estado = 'aceita', posicao_id = v_pos
   where k.id = c.id;

  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_pos, v.valor_centavos)
  returning id into v_turno;

  -- A última posição escolhida fecha a vaga e libera quem sobrou, com aviso.
  if not exists (select 1 from public.posicao p
                  where p.vaga_id = v.id and p.estado = 'aberta') then
    update public.vaga g set estado = 'preenchida' where g.id = v.id;

    for v_outra in
      select k.id, pr.usuario_id
        from public.candidatura k
        join public.posicao x      on x.id = k.posicao_id
        join public.profissional pr on pr.id = k.profissional_id
       where x.vaga_id = v.id and k.estado = 'pendente'
    loop
      update public.candidatura k set estado = 'recusada' where k.id = v_outra.id;
      perform privado.notificar(v_outra.usuario_id, 'candidatura_recusada', v.id,
        jsonb_build_object('vaga_id', v.id));
    end loop;
  end if;

  -- RF10: o escolhido é avisado. A casa não: foi ela quem escolheu.
  perform privado.notificar(privado.usuario_do_profissional(c.profissional_id),
    'confirmacao', v_turno, jsonb_build_object('turno_id', v_turno, 'vaga_id', v.id));

  return jsonb_build_object(
    'estado',     'confirmada',
    'posicao_id', v_pos,
    'turno_id',   v_turno,
    'contato',    privado.contato_do_profissional(v_pos));
end $$;

comment on function public.escolher_candidato(uuid) is
  'Modo seleção: a casa confirma um candidato pendente numa posição aberta (RN19, RN21, contrato 0.2.24). Vaga ocultada pela Equipe Frila: 422 vaga_oculta (0.2.23). A última escolha fecha a vaga e recusa os pendentes com aviso candidatura_recusada. O escolhido recebe confirmacao.';

revoke execute on function public.escolher_candidato(uuid) from public, anon;
grant  execute on function public.escolher_candidato(uuid) to authenticated;

-- ── 6. candidatos_da_vaga ─────────────────────────────────────────────────────

create or replace function public.candidatos_da_vaga(vaga_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_estab uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('contratante');

  if candidatos_da_vaga.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  select g.estabelecimento_id into v_estab
    from public.vaga g where g.id = candidatos_da_vaga.vaga_id;
  if v_estab is null then
    perform public.erro(404, 'nao_encontrado');
  end if;
  if not privado.eh_membro(v_estab) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- Ordem de chegada, e nenhuma outra: a reputação vai no card para a casa ler (RN08),
  -- não na ordem da lista (RN06).
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'candidatura_id', c.id,
             'profissional',   privado.perfil_publico_profissional(c.profissional_id),
             'criada_em',      c.criada_em)
           order by c.criada_em, c.id)
      from public.candidatura c
      join public.posicao x on x.id = c.posicao_id
     where x.vaga_id = candidatos_da_vaga.vaga_id
       and c.estado = 'pendente'), '[]'::jsonb);
end $$;

comment on function public.candidatos_da_vaga(uuid) is
  'Candidatos pendentes de uma vaga, por ordem de chegada, com o PerfilPublico e a reputação de cada um (RN08, UC04). Só para membro da casa.';

revoke execute on function public.candidatos_da_vaga(uuid) from public, anon;
grant  execute on function public.candidatos_da_vaga(uuid) to authenticated;

-- ── 7. retirar_candidatura ────────────────────────────────────────────────────

create or replace function public.retirar_candidatura(candidatura_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid     uuid := (select auth.uid());
  v_prof    uuid;
  v_vaga_id uuid;
  v_estado  public.estado_candidatura;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if retirar_candidatura.candidatura_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'candidatura_id');
  end if;

  v_prof := privado.meu_profissional_id();

  select x.vaga_id into v_vaga_id
    from public.candidatura k
    join public.posicao x on x.id = k.posicao_id
   where k.id = retirar_candidatura.candidatura_id
     and k.profissional_id = v_prof;
  if v_vaga_id is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- A vaga antes da candidatura, a mesma ordem da escolha: retirar e ser escolhido ao
  -- mesmo tempo terminam em um dos dois, nunca nos dois.
  perform 1 from public.vaga g where g.id = v_vaga_id for update;
  select k.estado into v_estado from public.candidatura k
   where k.id = retirar_candidatura.candidatura_id for update;

  if v_estado = 'pendente' then
    update public.candidatura k set estado = 'retirada'
     where k.id = retirar_candidatura.candidatura_id;
  elsif v_estado <> 'retirada' then
    -- Escolhida não se retira: vira cancelamento (`cancelar_posicao`). Recusada e
    -- expirada já não estão valendo.
    perform public.erro(409, 'candidatura_indisponivel');
  end if;

  return privado.candidatura_em_json(retirar_candidatura.candidatura_id);
end $$;

comment on function public.retirar_candidatura(uuid) is
  'Retira a candidatura pendente, sem penalidade (RN24). Retirar de novo devolve a mesma; escolhida, recusada ou expirada responde 409 candidatura_indisponivel.';

revoke execute on function public.retirar_candidatura(uuid) from public, anon;
grant  execute on function public.retirar_candidatura(uuid) to authenticated;

-- ── 8. minhas_candidaturas ────────────────────────────────────────────────────

create or replace function public.minhas_candidaturas(estado public.estado_candidatura default null)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_prof uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  v_prof := privado.meu_profissional_id();

  return coalesce((
    select jsonb_agg(privado.candidatura_em_json(c.id) order by c.criada_em desc, c.id)
      from public.candidatura c
     where c.profissional_id = v_prof
       and (minhas_candidaturas.estado is null or c.estado = minhas_candidaturas.estado)),
    '[]'::jsonb);
end $$;

comment on function public.minhas_candidaturas(public.estado_candidatura) is
  'Candidaturas do profissional, da mais nova para a mais antiga, com filtro opcional por estado (RF08, UC04).';

revoke execute on function public.minhas_candidaturas(public.estado_candidatura) from public, anon;
grant  execute on function public.minhas_candidaturas(public.estado_candidatura) to authenticated;

-- ── 9. Vaga que fecha expira as candidaturas pendentes ────────────────────────
--
-- Cancelada pela casa ou encerrada pelo fechamento: a candidatura pendente não vale mais
-- (D3: vale até a vaga fechar). O fechamento das 24 h expira e avisa por conta própria,
-- antes de mudar a vaga; o gatilho cobre `cancelar_vaga` e qualquer outro caminho.

create or replace function privado.vaga_fechada_expira_candidaturas()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.candidatura c
     set estado = 'expirada'
    from public.posicao x
   where x.id = c.posicao_id
     and x.vaga_id = new.id
     and c.estado = 'pendente';
  return null;
end $$;

comment on function privado.vaga_fechada_expira_candidaturas() is
  'Gatilho: vaga cancelada ou encerrada expira as candidaturas pendentes dela (D3, RN24).';

revoke execute on function privado.vaga_fechada_expira_candidaturas() from public, anon, authenticated;
grant  execute on function privado.vaga_fechada_expira_candidaturas() to service_role;

drop trigger if exists vaga_fechada_expira_candidaturas on public.vaga;
create trigger vaga_fechada_expira_candidaturas
  after update of estado on public.vaga
  for each row
  when (new.estado in ('cancelada', 'encerrada') and old.estado is distinct from new.estado)
  execute function privado.vaga_fechada_expira_candidaturas();

-- ── 10. O fechamento automático, 24 h antes (RN24) ────────────────────────────

create or replace function privado.fechar_selecoes()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v         record;
  v_cand    record;
  v_fechadas integer := 0;
begin
  -- `skip locked`: a vaga que uma escolha está segurando fica para o minuto seguinte, em
  -- vez de o job esperar por ela. A escolha que comita primeiro vale; a que chega depois
  -- do fechamento relê a vaga e recebe `vaga_encerrada`.
  for v in
    select g.id, g.estabelecimento_id
      from public.vaga g
     where g.modo = 'selecao'
       and g.estado = 'publicada'
       and g.inicio_em - interval '24 hours' <= v_agora
     order by g.id
       for update skip locked
  loop
    for v_cand in
      select c.id, pr.usuario_id
        from public.candidatura c
        join public.posicao x       on x.id = c.posicao_id
        join public.profissional pr on pr.id = c.profissional_id
       where x.vaga_id = v.id and c.estado = 'pendente'
    loop
      update public.candidatura c set estado = 'expirada' where c.id = v_cand.id;
      perform privado.notificar(v_cand.usuario_id, 'selecao_encerrada', v.id,
        jsonb_build_object('vaga_id', v.id));
    end loop;

    -- Modelagem, estados da posição: `aberta` → `cancelada` quando o modo seleção fecha
    -- 24 horas antes sem escolha. Encerra o despacho e libera os candidatos.
    update public.posicao p
       set estado = 'cancelada'
     where p.vaga_id = v.id and p.estado = 'aberta';

    -- Com alguma escolha feita, os turnos escolhidos seguem: a vaga fecha como preenchida.
    update public.vaga g
       set estado = case when exists (select 1 from public.posicao p
                                        where p.vaga_id = v.id
                                          and p.estado in ('confirmada', 'cumprida'))
                         then 'preenchida'::public.estado_vaga
                         else 'encerrada'::public.estado_vaga end
     where g.id = v.id;

    perform privado.notificar_membros(v.estabelecimento_id, 'selecao_encerrada', v.id,
      jsonb_build_object('vaga_id', v.id));

    v_fechadas := v_fechadas + 1;
  end loop;

  return v_fechadas;
end $$;

comment on function privado.fechar_selecoes() is
  'Job a cada minuto (RN24): a 24 h do início, fecha a vaga de seleção. Posições abertas → cancelada, pendentes → expirada com aviso selecao_encerrada, a casa avisada, e a vaga vai a encerrada (sem escolha) ou preenchida (com alguma).';

revoke execute on function privado.fechar_selecoes() from public, anon, authenticated;
grant  execute on function privado.fechar_selecoes() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobname) from cron.job where jobname = 'fechar_selecoes';
    perform cron.schedule('fechar_selecoes', '* * * * *', 'select privado.fechar_selecoes()');
  end if;
end $$;
