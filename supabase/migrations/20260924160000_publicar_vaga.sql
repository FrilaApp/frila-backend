-- `publicar_vaga`: a vaga entra no ar, e o despacho fica para depois.
--
-- A RPC faz três coisas e só três: grava a vaga, cria uma posição por unidade pedida
-- e deixa uma mensagem na fila. Quem decide **quem** é notificado é o motor do
-- Sprint 2, que lê a fila — decisão B15 e D6, registradas no Diagrama de Arquitetura.
--
-- Por que o despacho não roda aqui dentro: a elegibilidade de RN05 varre profissionais
-- por distância, função e disponibilidade, e o tempo dessa varredura é proporcional à
-- base. Publicar é um toque na tela de quem está com o salão cheio; amarrar a resposta
-- a uma varredura faz a publicação ficar mais lenta à medida que o produto cresce, e
-- faz uma falha de rede no envio da notificação derrubar a gravação da vaga.
--
-- ── O que fica de fora, e por quê ─────────────────────────────────────────────
--
-- O cartão pede também `net.http_post` para "disparar o despacho na hora". Não entra
-- aqui: a Edge Function `despachar` é do Sprint 2 e ainda não existe, então a chamada
-- apontaria para o nada — e `pg_net` numa transação de escrita falha em silêncio, que
-- é o modo de falha mais caro de descobrir depois. A fila é durável; quando o motor
-- existir, ele passa a consumir o que já estiver enfileirado, sem migração de dados.
-- Registrado no cartão wtITHAPo.

-- ── A fila ────────────────────────────────────────────────────────────────────
--
-- `pgmq` em vez de tabela própria: ela já traz visibility timeout, tentativa e
-- arquivo morto, que é o que separa uma fila de uma tabela com coluna `processado`.
-- `pg_cron` continua fora — agendador sem job é superfície sem uso, e o job nasce com
-- o motor.

create extension if not exists pgmq;

select pgmq.create('despacho');

-- O event trigger `ensure_rls` só alcança `public`. A tabela da fila carrega o id da
-- vaga e, no Sprint 2, carregará o critério de despacho — que é justamente o que o
-- estabelecimento não pode ler (a política de `despacho` existe por isso). Sem
-- política nenhuma e com RLS ligada, só quem tem `bypassrls` lê: o motor e as RPCs
-- `security definer`.
alter table pgmq.q_despacho enable row level security;

comment on table pgmq.q_despacho is
  'Fila de despacho. publicar_vaga enfileira; o motor do Sprint 2 consome. RLS ligada e sem política: ninguém com sessão lê daqui.';

-- ── Quem publicou ─────────────────────────────────────────────────────────────
--
-- A Modelagem traz `estabelecimento_id` e para por aí, e enquanto a vaga só nascia em
-- `cenarios.sql` isso bastou. Com a RPC no ar, um estabelecimento com três gerentes
-- publicando não tem como responder "quem publicou esta" — que é o que RF04 pede, o
-- que o painel mostra e o que o cancelamento (RN12) vai precisar auditar.
--
-- Em duas fases, e não com um `alter table ... not null` direto: o `frila-dev` já tem
-- o esquema aplicado, e uma coluna obrigatória sem preenchimento derruba a migração lá
-- se houver vaga gravada. O preenchimento escolhe o administrador do estabelecimento,
-- que é o responsável por construção (RF21).

alter table public.vaga add column if not exists publicado_por uuid references public.usuario(id);

update public.vaga g
   set publicado_por = (
     select m.usuario_id from public.membro_estabelecimento m
      where m.estabelecimento_id = g.estabelecimento_id
      order by (m.papel = 'administrador') desc, m.usuario_id
      limit 1)
 where g.publicado_por is null;

alter table public.vaga alter column publicado_por set not null;

create index if not exists vaga_por_quem_publicou on public.vaga (publicado_por);

comment on column public.vaga.publicado_por is
  'Conta que publicou a vaga (RF04). Um estabelecimento tem vários membros; sem esta coluna o painel não sabe de quem foi a publicação, e o cancelamento não tem o que auditar.';

-- ── A coordenada, agora dizendo qual campo recusou ────────────────────────────
--
-- Nasceu no perfil profissional, onde o campo se chama `ponto_base`; em `NovaVaga` ele
-- se chama `ponto`. O nome do campo em `details` é o que a tela usa para destacar o
-- campo certo, então ele não pode ficar fixo na auxiliar.
drop function if exists privado.ponto_do_json(jsonb);

create or replace function privado.ponto_do_json(p jsonb, campo text default 'ponto_base')
returns extensions.geography
language plpgsql
-- Sem rótulo de volatilidade, e portanto VOLATILE: levanta exceção por `public.erro` e
-- o texto que vira `geography` passa por um cast STABLE.
set search_path = ''
as $$
declare
  v_lat numeric;
  v_lon numeric;
begin
  if p is null or p->'latitude' is null or p->'longitude' is null then
    perform public.erro(422, 'campo_obrigatorio', campo);
  end if;

  begin
    v_lat := (p->>'latitude')::numeric;
    v_lon := (p->>'longitude')::numeric;
  exception when others then
    perform public.erro(422, 'campo_invalido', campo);
  end;

  -- Conferido aqui para devolver o código do contrato. Sem isto, uma latitude de 120
  -- chegaria ao PostGIS e voltaria como erro de biblioteca, que o app não sabe ler.
  if v_lat < -90 or v_lat > 90 or v_lon < -180 or v_lon > 180 then
    perform public.erro(422, 'campo_invalido', campo);
  end if;

  return ('SRID=4326;POINT(' || v_lon || ' ' || v_lat || ')')::extensions.geography;
end $$;

comment on function privado.ponto_do_json(jsonb, text) is
  'Coordenada do contrato (latitude/longitude) para geography. A conversão mora no banco para que o formato WKT não vaze para o cliente. `campo` é o nome que vai em details quando recusa.';

-- ── O texto livre da vaga ─────────────────────────────────────────────────────
--
-- Quatro campos da vaga são digitados à mão e vão para a tela de quem procura turno.
-- Um laço em vez de quatro `if` iguais: acrescentar campo livre à vaga passa a ser
-- acrescentar uma linha ao array, e esquecer o filtro deixa de ser possível por
-- omissão.
create or replace function privado.exigir_texto_aceitavel(campos jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  k text;
begin
  for k in select jsonb_object_keys(campos) loop
    if not privado.texto_aceitavel(campos->>k) then
      perform public.erro(422, 'campo_invalido', k);
    end if;
  end loop;
end $$;

comment on function privado.exigir_texto_aceitavel(jsonb) is
  'Recusa com 422 campo_invalido o primeiro campo cujo texto contenha termo bloqueado (diretriz 1.2). A chave do jsonb é o nome que vai em details.';

-- ── publicar_vaga ─────────────────────────────────────────────────────────────

create or replace function public.publicar_vaga(
  estabelecimento_id      uuid,
  funcao_id               uuid,
  inicio_em               timestamptz,
  fim_em                  timestamptz,
  local                   text,
  ponto                   jsonb,
  valor_centavos          bigint,
  posicoes                int,
  inclui_refeicao         boolean,
  inclui_transporte       boolean,
  exige_material_proprio  boolean,
  responsavel_local       text,
  modo                    public.modo_preenchimento,
  chave                   uuid,
  traje                   text    default null,
  participa_rateio        boolean default null,
  observacoes             text    default null,
  alerta_antecedencia_min int     default 180
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
  v_agora     timestamptz;
  v_ponto     extensions.geography;
  v_vaga      public.vaga%rowtype;
  v_posicoes  uuid[];
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- RN25: quem trabalha e quem contrata são contas diferentes.
  perform privado.exigir_perfil('contratante');

  -- RN13. Antes de qualquer conferência sobre a vaga: a conta suspensa não publica
  -- coisa nenhuma, e o motivo vai em `details` para a tela poder explicar em vez de
  -- só negar.
  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  -- RF21. Estabelecimento que não existe cai aqui também, e de propósito: responder
  -- 404 diria a quem não é membro que o estabelecimento existe.
  if not privado.eh_membro(publicar_vaga.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- ── RN02: vaga incompleta não existe ────────────────────────────────────────
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

  -- Recusa com o código do contrato, e não com a violação de `CHECK`: a constraint
  -- continua lá como última linha de defesa, mas quem responde ao app é esta.
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

  -- ── O relógio do produto ────────────────────────────────────────────────────
  --
  -- `privado.agora()` e não `now()`: todo prazo do produto passa por ele, e é o que
  -- deixa o teste de prazo existir sem esperar três dias.
  v_agora := privado.agora();

  if publicar_vaga.fim_em <= publicar_vaga.inicio_em then
    perform public.erro(422, 'horario_invalido');
  end if;
  if publicar_vaga.inicio_em <= v_agora then
    perform public.erro(422, 'horario_invalido');
  end if;

  -- RN24 é sobre as 24 horas de antecedência do modo seleção. Na v1.0 o modo não
  -- existe: o escopo do MVP tem só urgência. Por isso `campo_invalido` com o campo, e
  -- não `selecao_sem_antecedencia` — este último só faz sentido quando houver seleção
  -- para recusar, na v1.1.
  if publicar_vaga.modo <> 'urgencia' then
    perform public.erro(422, 'campo_invalido', 'modo');
  end if;

  -- Diretriz 1.2 da App Store, nos quatro campos livres da vaga.
  perform privado.exigir_texto_aceitavel(jsonb_build_object(
    'local',             v_local,
    'responsavel_local', v_resp,
    'traje',             v_traje,
    'observacoes',       v_obs));

  v_ponto := privado.ponto_do_json(publicar_vaga.ponto, 'ponto');

  -- ── RF04: a chave do cliente ────────────────────────────────────────────────
  --
  -- A rede cai depois do commit e o app reenvia. A chave é única por estabelecimento,
  -- e o reenvio devolve a vaga que já existe — com as posições que já existem, e sem
  -- enfileirar o despacho de novo.
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
      estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
      valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
      exige_material_proprio, responsavel_local, traje, participa_rateio,
      observacoes, modo, alerta_antecedencia, publicado_por, chave_cliente)
    values (
      publicar_vaga.estabelecimento_id, publicar_vaga.funcao_id,
      publicar_vaga.inicio_em, publicar_vaga.fim_em, v_local, v_ponto,
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
      -- Dois toques no botão ao mesmo tempo: a segunda transação perde a corrida da
      -- chave e devolve a vaga da primeira, em vez de um conflito que o app leria
      -- como falha.
      select * into v_vaga
        from public.vaga g
       where g.estabelecimento_id = publicar_vaga.estabelecimento_id
         and g.chave_cliente = publicar_vaga.chave;
      select array_agg(p.id order by p.id) into v_posicoes
        from public.posicao p where p.vaga_id = v_vaga.id;
      return jsonb_build_object('vaga_id', v_vaga.id,
                                'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[])));
  end;

  -- RN03: uma posição por unidade pedida. Início e fim são copiados da vaga porque o
  -- `EXCLUDE USING gist` de RN21 mora em `posicao` e um índice GIST não atravessa
  -- junção.
  insert into public.posicao (vaga_id, inicio_em, fim_em)
  select v_vaga.id, v_vaga.inicio_em, v_vaga.fim_em
    from generate_series(1, publicar_vaga.posicoes);

  select array_agg(p.id order by p.id) into v_posicoes
    from public.posicao p where p.vaga_id = v_vaga.id;

  -- B15: a publicação termina aqui. A mensagem é o mínimo que o motor precisa para
  -- refazer a varredura — o id da vaga. Copiar os critérios para dentro dela os
  -- congelaria no instante da publicação.
  perform pgmq.send('despacho', jsonb_build_object(
    'vaga_id',      v_vaga.id,
    'publicada_em', v_vaga.publicado_em));

  return jsonb_build_object('vaga_id', v_vaga.id, 'posicoes', to_jsonb(v_posicoes));
end $$;

comment on function public.publicar_vaga(uuid, uuid, timestamptz, timestamptz, text, jsonb,
  bigint, int, boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int) is
  'Grava a vaga e uma posição por unidade pedida, e enfileira o despacho (RF04, RN02, RN03, B15). Só contratante membro do estabelecimento. `chave` torna o reenvio seguro.';

revoke execute on function public.publicar_vaga(uuid, uuid, timestamptz, timestamptz, text, jsonb,
  bigint, int, boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int) from public, anon;
grant execute on function public.publicar_vaga(uuid, uuid, timestamptz, timestamptz, text, jsonb,
  bigint, int, boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int) to authenticated;
