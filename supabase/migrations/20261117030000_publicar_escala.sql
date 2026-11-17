-- Escala de evento em lote: public.publicar_escala (contrato 0.2.96, RF19; cartão 6mi66YDp, B-031).
-- Desenho: orquestracao/retornos/P-028-parecer-juiz.md, "Para a Forja" (itens 1 a 9) e rodada 2.
--
--   1. public.evento guarda a chave da escala (única por estabelecimento: reenvio e envio simultâneo)
--      e as vagas na ordem dos itens (o reenvio devolve na mesma ordem).
--   2. privado.validar_nova_vaga: a conferência do corpo de publicar_vaga, tirada dela para valer igual
--      nas duas operações. Mesmas recusas e mesma ordem; mudam só o lugar para onde o erro aponta
--      (details) e o teto de posições (200 em publicar_vaga, 100 por item da escala).
--   3. publicar_vaga passa a chamar a função acima e responde igual.
--   4. public.publicar_escala: quem pode, a chave (antes do corpo), o evento, os limites e os itens; só
--      então grava evento, vagas e posições e enfileira um despacho por vaga, tudo numa transação.
--   5. O evento segue as vagas na exclusão de conta, na limpeza de 15 dias e no expurgo de 5 anos
--      (decisão da Bússola de 16/11/2026; ROPA, linha 16): o nome sai como os textos livres da vaga, e
--      o local como o local da vaga, no mesmo momento e com o mesmo marcador. A data fica, como o
--      horário da vaga. O evento não guarda ponto nem região (ficam nas vagas) e segue fora da
--      exportação: é agenda da casa, e não do titular (supabase/tests/440).
--
-- Não há gatilho de despacho na vaga: o despacho é o pgmq.send de cada publicação, como em publicar_vaga.
-- republicar_vaga e republicar_posicoes_restantes não copiam o evento_id: as duas publicam por
-- publicar_vaga, que não o recebe.

-- contrato: corpo-sem-mudanca-de-superficie public.publicar_vaga 0.2.91

select set_config('lock_timeout', '2s', true);

-- ── 1. A chave da escala e a ordem das vagas ─────────────────────────────────

alter table public.evento
  add column chave uuid,
  add column vagas uuid[];

-- Duas escalas com a mesma chave na mesma casa não existem: o segundo envio simultâneo bate aqui,
-- e publicar_escala devolve a escala do primeiro.
alter table public.evento
  add constraint evento_chave_unica unique (estabelecimento_id, chave);

comment on column public.evento.chave is
  'Chave de idempotência da escala (publicar_escala, 0.2.96), gerada pelo cliente uma vez por publicação. Única por estabelecimento. Nula no evento gravado fora de publicar_escala.';
comment on column public.evento.vagas is
  'As vagas da escala na ordem dos itens de NovaEscala.vagas (publicar_escala, 0.2.96). Gravada uma vez, na publicação: é a ordem em que o reenvio devolve as vagas.';

-- ── 2. A conferência do corpo de uma vaga ─────────────────────────────────────
--
-- As recusas de publicar_vaga, na mesma ordem, para a vaga avulsa e para cada item da escala.
-- p_onde é para onde o erro aponta: nulo em publicar_vaga (details é o nome do campo, e a recusa que
-- não é de um campo só sai sem details); 'vagas[<i>]' na escala (details 'vagas[<i>].<campo>' e,
-- para horario_invalido e selecao_sem_antecedencia, 'vagas[<i>]').
--
-- Na escala, local, região e ponto chegam do evento, já conferidos, e passam de novo aqui sem recusa
-- possível; a chave é a da escala, já conferida. O que sai é a linha pronta para o insert, com os
-- textos aparados e a região pelo nome oficial do catálogo.
create function privado.validar_nova_vaga(
  p_onde                    text,
  p_max_posicoes            integer,
  p_estabelecimento_id      uuid,
  p_eh_demo                 boolean,
  p_funcao_id               uuid,
  p_inicio_em               timestamptz,
  p_fim_em                  timestamptz,
  p_local                   text,
  p_ponto                   jsonb,
  p_valor_centavos          bigint,
  p_posicoes                integer,
  p_inclui_refeicao         boolean,
  p_inclui_transporte       boolean,
  p_exige_material_proprio  boolean,
  p_responsavel_local       text,
  p_modo                    public.modo_preenchimento,
  p_chave                   uuid,
  p_traje                   text,
  p_participa_rateio        boolean,
  p_observacoes             text,
  p_alerta_antecedencia_min integer,
  p_regiao_administrativa   text
)
returns public.vaga
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pre    text := coalesce(p_onde || '.', '');
  v_local  text := btrim(p_local);
  v_resp   text := btrim(p_responsavel_local);
  v_traje  text := btrim(p_traje);
  v_obs    text := btrim(p_observacoes);
  v_regiao text;
  v_agora  timestamptz;
  v_vaga   public.vaga;
begin
  -- RN02: vaga incompleta não existe
  if p_funcao_id is null then
    perform public.erro(422, 'campo_obrigatorio', v_pre || 'funcao_id');
  end if;
  if p_inicio_em is null then
    perform public.erro(422, 'campo_obrigatorio', v_pre || 'inicio_em');
  end if;
  if p_fim_em is null then
    perform public.erro(422, 'campo_obrigatorio', v_pre || 'fim_em');
  end if;
  if v_local is null or v_local = '' then
    perform public.erro(422, 'campo_obrigatorio', v_pre || 'local');
  end if;
  if v_resp is null or v_resp = '' then
    perform public.erro(422, 'campo_obrigatorio', v_pre || 'responsavel_local');
  end if;
  if p_valor_centavos is null then
    perform public.erro(422, 'campo_obrigatorio', v_pre || 'valor_centavos');
  end if;
  if p_posicoes is null then
    perform public.erro(422, 'campo_obrigatorio', v_pre || 'posicoes');
  end if;
  if p_inclui_refeicao is null then
    perform public.erro(422, 'campo_obrigatorio', v_pre || 'inclui_refeicao');
  end if;
  if p_inclui_transporte is null then
    perform public.erro(422, 'campo_obrigatorio', v_pre || 'inclui_transporte');
  end if;
  if p_exige_material_proprio is null then
    perform public.erro(422, 'campo_obrigatorio', v_pre || 'exige_material_proprio');
  end if;
  if p_modo is null then
    perform public.erro(422, 'campo_obrigatorio', v_pre || 'modo');
  end if;
  if p_chave is null then
    perform public.erro(422, 'campo_obrigatorio', v_pre || 'chave');
  end if;

  -- Região administrativa: informada na publicação ou herdada do estabelecimento
  if p_regiao_administrativa is not null then
    v_regiao := btrim(p_regiao_administrativa);
    if v_regiao = '' then
      if p_eh_demo then
        v_regiao := 'Plano Piloto';
      else
        perform public.erro(422, 'campo_obrigatorio', v_pre || 'regiao_administrativa');
      end if;
    end if;
  else
    select e.regiao_administrativa into v_regiao
      from public.estabelecimento e
     where e.id = p_estabelecimento_id;
    if v_regiao is null or btrim(v_regiao) = '' then
      if p_eh_demo then
        v_regiao := 'Plano Piloto';
      else
        perform public.erro(422, 'campo_obrigatorio', v_pre || 'regiao_administrativa');
      end if;
    end if;
  end if;

  -- Resolve variações e apelidos do catálogo aceitos pelo app legado (ex: 'SCIA / Estrutural' -> 'SCIA')
  v_regiao := coalesce(privado.resolver_regiao_administrativa(v_regiao), v_regiao);

  -- RN44: a região é uma das do catálogo oficial e está ativa. Texto livre não entra mais.
  if not exists (select 1 from public.regiao_administrativa r
                  where r.nome = v_regiao and r.ativo) then
    perform public.erro(422, 'campo_invalido', v_pre || 'regiao_administrativa');
  end if;

  if p_valor_centavos <= 0 then
    perform public.erro(422, 'campo_invalido', v_pre || 'valor_centavos');
  end if;
  if p_posicoes < 1 or p_posicoes > p_max_posicoes then
    perform public.erro(422, 'campo_invalido', v_pre || 'posicoes');
  end if;
  if p_alerta_antecedencia_min is null or p_alerta_antecedencia_min < 1 then
    perform public.erro(422, 'campo_invalido', v_pre || 'alerta_antecedencia_min');
  end if;

  if not exists (select 1 from public.funcao f where f.id = p_funcao_id) then
    perform public.erro(422, 'campo_invalido', v_pre || 'funcao_id');
  end if;

  v_agora := privado.agora();

  if p_fim_em <= p_inicio_em then
    perform public.erro(422, 'horario_invalido', p_onde);
  end if;
  if p_inicio_em <= v_agora then
    perform public.erro(422, 'horario_invalido', p_onde);
  end if;

  -- RN24: o modo seleção fecha sozinho 24 horas antes do início
  if p_modo = 'selecao'
     and p_inicio_em <= v_agora + interval '24 hours' then
    perform public.erro(422, 'selecao_sem_antecedencia', p_onde);
  end if;

  -- Diretriz 1.2 da App Store nos textos livres
  perform privado.exigir_texto_aceitavel(jsonb_build_object(
    v_pre || 'local',                 v_local,
    v_pre || 'responsavel_local',     v_resp,
    v_pre || 'traje',                 v_traje,
    v_pre || 'observacoes',           v_obs,
    v_pre || 'regiao_administrativa', v_regiao));

  v_vaga.ponto                  := privado.ponto_do_json(p_ponto, v_pre || 'ponto');
  v_vaga.estabelecimento_id     := p_estabelecimento_id;
  v_vaga.funcao_id              := p_funcao_id;
  v_vaga.inicio_em              := p_inicio_em;
  v_vaga.fim_em                 := p_fim_em;
  v_vaga.local                  := v_local;
  v_vaga.regiao_administrativa  := v_regiao;
  v_vaga.valor_centavos         := p_valor_centavos;
  v_vaga.posicoes               := p_posicoes::smallint;
  v_vaga.inclui_refeicao        := p_inclui_refeicao;
  v_vaga.inclui_transporte      := p_inclui_transporte;
  v_vaga.exige_material_proprio := p_exige_material_proprio;
  v_vaga.responsavel_local      := v_resp;
  v_vaga.traje                  := nullif(v_traje, '');
  v_vaga.participa_rateio       := p_participa_rateio;
  v_vaga.observacoes            := nullif(v_obs, '');
  v_vaga.modo                   := p_modo;
  v_vaga.alerta_antecedencia    := make_interval(mins => p_alerta_antecedencia_min);
  v_vaga.chave_cliente          := p_chave;
  return v_vaga;
end $$;

comment on function privado.validar_nova_vaga(
  text, integer, uuid, boolean, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid, text, boolean, text, integer, text
) is
  'Confere o corpo de uma vaga nova (RN02, RN18, RN24, RN44, diretriz 1.2) e devolve a linha pronta para o insert. Usada por publicar_vaga (p_onde nulo, até 200 posições) e por cada item de publicar_escala (p_onde vagas[<i>], até 100 posições), com as mesmas recusas na mesma ordem (0.2.96).';

revoke all on function privado.validar_nova_vaga(
  text, integer, uuid, boolean, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid, text, boolean, text, integer, text
) from public, anon, authenticated;

-- ── 3. publicar_vaga confere pela função acima ────────────────────────────────

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
  v_estab_id  uuid;
  v_nova      public.vaga;
  v_vaga      public.vaga%rowtype;
  v_posicoes  uuid[];
  v_eh_demo   boolean;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('contratante');

  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  v_eh_demo := privado.conta_de_demonstracao();

  -- Resolução resiliente do estabelecimento para demonstração
  if publicar_vaga.estabelecimento_id is null and v_eh_demo then
    select m.estabelecimento_id into v_estab_id
      from public.membro_estabelecimento m
     where m.usuario_id = v_uid
     limit 1;
    if v_estab_id is null then
      v_estab_id := 'de000000-0000-4000-8000-000000000010'::uuid;
    end if;
  else
    v_estab_id := publicar_vaga.estabelecimento_id;
  end if;

  if v_eh_demo and not privado.eh_membro(v_estab_id) then
    insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
    values (v_uid, v_estab_id, 'administrador')
    on conflict do nothing;
  end if;

  if not privado.eh_membro(v_estab_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- O corpo: RN02, região, valores, horário, RN24, diretriz 1.2 e ponto, na ordem de sempre.
  v_nova := privado.validar_nova_vaga(
    null, 200, v_estab_id, v_eh_demo,
    publicar_vaga.funcao_id, publicar_vaga.inicio_em, publicar_vaga.fim_em,
    publicar_vaga.local, publicar_vaga.ponto, publicar_vaga.valor_centavos, publicar_vaga.posicoes,
    publicar_vaga.inclui_refeicao, publicar_vaga.inclui_transporte,
    publicar_vaga.exige_material_proprio, publicar_vaga.responsavel_local, publicar_vaga.modo,
    publicar_vaga.chave, publicar_vaga.traje, publicar_vaga.participa_rateio,
    publicar_vaga.observacoes, publicar_vaga.alerta_antecedencia_min,
    publicar_vaga.regiao_administrativa);

  -- RF04: chave de idempotência do cliente
  select * into v_vaga
    from public.vaga g
   where g.estabelecimento_id = v_estab_id
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
      v_nova.estabelecimento_id, v_nova.funcao_id, v_nova.inicio_em, v_nova.fim_em,
      v_nova.local, v_nova.regiao_administrativa, v_nova.ponto,
      v_nova.valor_centavos, v_nova.posicoes, v_nova.inclui_refeicao, v_nova.inclui_transporte,
      v_nova.exige_material_proprio, v_nova.responsavel_local, v_nova.traje,
      v_nova.participa_rateio, v_nova.observacoes, v_nova.modo, v_nova.alerta_antecedencia,
      v_uid, v_nova.chave_cliente)
    returning * into v_vaga;
  exception
    when unique_violation then
      select * into v_vaga
        from public.vaga g
       where g.estabelecimento_id = v_estab_id
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

  -- Isolamento de demonstração: contas de demonstração não entram na fila de despacho
  if not v_eh_demo then
    perform pgmq.send('despacho', jsonb_build_object(
      'vaga_id',      v_vaga.id,
      'publicada_em', v_vaga.publicado_em));
  end if;

  return jsonb_build_object('vaga_id', v_vaga.id, 'posicoes', to_jsonb(v_posicoes));
end $$;

comment on function public.publicar_vaga(
  uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int, text
) is
  'Publica uma vaga e enfileira o despacho no pgmq. Idempotente pela chave gerada pelo app. regiao_administrativa obrigatória (0.2.20) e validada contra o catálogo ativo (RN44). O corpo é conferido por privado.validar_nova_vaga, a mesma conferência de cada item de publicar_escala (0.2.96).';

revoke execute on function public.publicar_vaga(
  uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int, text
) from public, anon;
grant  execute on function public.publicar_vaga(
  uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int, text
) to authenticated;

-- ── 4. publicar_escala ────────────────────────────────────────────────────────

-- O valor de um campo do corpo em JSON, como texto, depois de conferido o tipo. Ausente ou null do
-- JSON volta nulo (quem chama decide se é campo_obrigatorio); tipo errado, ou texto que não converte
-- (uuid malformado, instante inválido, modo que não existe), é 422 campo_invalido com p_campo em
-- details. Os tipos: texto, booleano, inteiro, centavos, uuid, instante e modo.
create function privado.valor_json(p_valor jsonb, p_tipo text, p_campo text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_texto text := p_valor #>> '{}';
begin
  if p_valor is null or jsonb_typeof(p_valor) = 'null' then
    return null;
  end if;

  if not coalesce(case p_tipo
                    when 'texto'    then jsonb_typeof(p_valor) = 'string'
                    when 'booleano' then jsonb_typeof(p_valor) = 'boolean'
                    when 'inteiro'  then jsonb_typeof(p_valor) = 'number'
                                         and pg_input_is_valid(v_texto, 'integer')
                    when 'centavos' then jsonb_typeof(p_valor) = 'number'
                                         and pg_input_is_valid(v_texto, 'bigint')
                    when 'uuid'     then jsonb_typeof(p_valor) = 'string'
                                         and pg_input_is_valid(v_texto, 'uuid')
                    when 'instante' then jsonb_typeof(p_valor) = 'string'
                                         and pg_input_is_valid(v_texto, 'timestamptz')
                    when 'modo'     then jsonb_typeof(p_valor) = 'string'
                                         and pg_input_is_valid(v_texto, 'public.modo_preenchimento')
                  end, false) then
    perform public.erro(422, 'campo_invalido', p_campo);
  end if;

  return v_texto;
end $$;

comment on function privado.valor_json(jsonb, text, text) is
  'Texto de um campo JSON do corpo de publicar_escala depois de conferido o tipo (texto, booleano, inteiro, centavos, uuid, instante, modo). Ausente ou null: NULL. Tipo errado: 422 campo_invalido com o caminho do campo em details (0.2.96).';

revoke all on function privado.valor_json(jsonb, text, text) from public, anon, authenticated;

-- A EscalaPublicada de um evento: as vagas na ordem dos itens, cada uma com as posições.
create function privado.escala_publicada(p_evento uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'evento_id', e.id,
    'vagas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'vaga_id',  u.vaga_id,
               'posicoes', coalesce((select jsonb_agg(p.id order by p.id)
                                       from public.posicao p
                                      where p.vaga_id = u.vaga_id), '[]'::jsonb))
             order by u.ordem)
        from unnest(e.vagas) with ordinality as u(vaga_id, ordem)), '[]'::jsonb))
    from public.evento e
   where e.id = p_evento
$$;

comment on function privado.escala_publicada(uuid) is
  'Resposta de publicar_escala (EscalaPublicada, 0.2.96) para um evento: evento_id e as vagas na ordem de evento.vagas, cada uma com as posições.';

revoke all on function privado.escala_publicada(uuid) from public, anon, authenticated;

create function public.publicar_escala(
  estabelecimento_id uuid  default null,
  evento             jsonb default null,
  vagas              jsonb default null,
  chave              uuid  default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid        uuid := (select auth.uid());
  v_eh_demo    boolean;
  v_evento     public.evento%rowtype;
  v_nome       text;
  v_data       text;
  v_local      text;
  v_regiao     text;
  v_n          integer;
  v_soma       integer;
  v_item       jsonb;
  v_pre        text;
  v_funcao     uuid;
  v_inicio     timestamptz;
  v_fim        timestamptz;
  v_valor      bigint;
  v_posicoes   integer;
  v_refeicao   boolean;
  v_transporte boolean;
  v_material   boolean;
  v_resp       text;
  v_traje      text;
  v_rateio     boolean;
  v_obs        text;
  v_modo       public.modo_preenchimento;
  v_alerta     integer;
  v_itens      public.vaga[] := '{}'::public.vaga[];
  v_nova       public.vaga;
  v_ids        uuid[];
  v_vaga       public.vaga%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- Quem pode: as recusas de publicar_vaga, na mesma ordem. Sem estabelecimento_id, 403.
  perform privado.exigir_perfil('contratante');

  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  if not privado.eh_membro(publicar_escala.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  v_eh_demo := privado.conta_de_demonstracao();

  -- A chave, antes do corpo: o reenvio devolve a escala gravada sem conferir o corpo de novo (mesmo
  -- com o horário já passado) e sem despachar de novo.
  if publicar_escala.chave is null then
    perform public.erro(422, 'campo_obrigatorio', 'chave');
  end if;

  select e.* into v_evento
    from public.evento e
   where e.estabelecimento_id = publicar_escala.estabelecimento_id
     and e.chave = publicar_escala.chave;
  if found then
    return privado.escala_publicada(v_evento.id);
  end if;

  if publicar_escala.evento is null or jsonb_typeof(publicar_escala.evento) = 'null' then
    perform public.erro(422, 'campo_obrigatorio', 'evento');
  end if;
  if publicar_escala.vagas is null or jsonb_typeof(publicar_escala.vagas) = 'null' then
    perform public.erro(422, 'campo_obrigatorio', 'vagas');
  end if;

  -- O evento, campo a campo: ausente ou em branco, campo_obrigatorio; valor recusado, campo_invalido.
  if jsonb_typeof(publicar_escala.evento) <> 'object' then
    perform public.erro(422, 'campo_invalido', 'evento');
  end if;

  v_nome := btrim(privado.valor_json(publicar_escala.evento->'nome', 'texto', 'evento.nome'));
  if v_nome is null or v_nome = '' then
    perform public.erro(422, 'campo_obrigatorio', 'evento.nome');
  end if;
  if char_length(v_nome) < 3 or char_length(v_nome) > 100 then
    perform public.erro(422, 'campo_invalido', 'evento.nome');
  end if;
  perform privado.exigir_texto_aceitavel(jsonb_build_object('evento.nome', v_nome));

  v_data := btrim(privado.valor_json(publicar_escala.evento->'data', 'texto', 'evento.data'));
  if v_data is null or v_data = '' then
    perform public.erro(422, 'campo_obrigatorio', 'evento.data');
  end if;
  if v_data !~ '^\d{4}-\d{2}-\d{2}$' or not pg_input_is_valid(v_data, 'date') then
    perform public.erro(422, 'campo_invalido', 'evento.data');
  end if;

  v_local := btrim(privado.valor_json(publicar_escala.evento->'local', 'texto', 'evento.local'));
  if v_local is null or v_local = '' then
    perform public.erro(422, 'campo_obrigatorio', 'evento.local');
  end if;
  perform privado.exigir_texto_aceitavel(jsonb_build_object('evento.local', v_local));

  v_regiao := btrim(privado.valor_json(publicar_escala.evento->'regiao_administrativa', 'texto',
                                       'evento.regiao_administrativa'));
  if v_regiao is null or v_regiao = '' then
    perform public.erro(422, 'campo_obrigatorio', 'evento.regiao_administrativa');
  end if;
  v_regiao := coalesce(privado.resolver_regiao_administrativa(v_regiao), v_regiao);
  if not exists (select 1 from public.regiao_administrativa r
                  where r.nome = v_regiao and r.ativo) then
    perform public.erro(422, 'campo_invalido', 'evento.regiao_administrativa');
  end if;

  if jsonb_typeof(publicar_escala.evento->'ponto') not in ('object', 'null') then
    perform public.erro(422, 'campo_invalido', 'evento.ponto');
  end if;
  perform privado.ponto_do_json(publicar_escala.evento->'ponto', 'evento.ponto');

  -- Limites: de 1 a 10 itens e até 100 posições somadas. A soma só conta posicoes inteiro de 1 a 100;
  -- o item com posicoes ausente ou fora disso é recusado depois, nele mesmo.
  if jsonb_typeof(publicar_escala.vagas) <> 'array' then
    perform public.erro(422, 'campo_invalido', 'vagas');
  end if;
  v_n := jsonb_array_length(publicar_escala.vagas);
  if v_n < 1 or v_n > 10 then
    perform public.erro(422, 'campo_invalido', 'vagas');
  end if;

  select coalesce(sum(case
                        when jsonb_typeof(x.item->'posicoes') = 'number'
                         and pg_input_is_valid(x.item->>'posicoes', 'integer')
                        then case when (x.item->>'posicoes')::integer between 1 and 100
                                  then (x.item->>'posicoes')::integer else 0 end
                        else 0
                      end), 0)
    into v_soma
    from jsonb_array_elements(publicar_escala.vagas) as x(item);
  if v_soma > 100 then
    perform public.erro(422, 'campo_invalido', 'posicoes');
  end if;

  -- Os itens, do primeiro ao último. Primeiro o tipo de cada campo, depois as recusas de publicar_vaga.
  -- Local, região e ponto são os do evento; a vaga não tem chave própria.
  for i in 0 .. v_n - 1 loop
    v_item := publicar_escala.vagas->i;
    if jsonb_typeof(v_item) <> 'object' then
      perform public.erro(422, 'campo_invalido', format('vagas[%s]', i));
    end if;
    v_pre := format('vagas[%s].', i);

    v_funcao     := privado.valor_json(v_item->'funcao_id', 'uuid', v_pre || 'funcao_id')::uuid;
    v_inicio     := privado.valor_json(v_item->'inicio_em', 'instante', v_pre || 'inicio_em')::timestamptz;
    v_fim        := privado.valor_json(v_item->'fim_em', 'instante', v_pre || 'fim_em')::timestamptz;
    v_valor      := privado.valor_json(v_item->'valor_centavos', 'centavos', v_pre || 'valor_centavos')::bigint;
    v_posicoes   := privado.valor_json(v_item->'posicoes', 'inteiro', v_pre || 'posicoes')::integer;
    v_refeicao   := privado.valor_json(v_item->'inclui_refeicao', 'booleano', v_pre || 'inclui_refeicao')::boolean;
    v_transporte := privado.valor_json(v_item->'inclui_transporte', 'booleano', v_pre || 'inclui_transporte')::boolean;
    v_material   := privado.valor_json(v_item->'exige_material_proprio', 'booleano', v_pre || 'exige_material_proprio')::boolean;
    v_resp       := privado.valor_json(v_item->'responsavel_local', 'texto', v_pre || 'responsavel_local');
    v_traje      := privado.valor_json(v_item->'traje', 'texto', v_pre || 'traje');
    v_rateio     := privado.valor_json(v_item->'participa_rateio', 'booleano', v_pre || 'participa_rateio')::boolean;
    v_obs        := privado.valor_json(v_item->'observacoes', 'texto', v_pre || 'observacoes');
    v_modo       := privado.valor_json(v_item->'modo', 'modo', v_pre || 'modo')::public.modo_preenchimento;
    -- Ausente vale 180, como o default de publicar_vaga; null explícito é recusado lá.
    v_alerta     := case when v_item ? 'alerta_antecedencia_min'
                         then privado.valor_json(v_item->'alerta_antecedencia_min', 'inteiro',
                                                 v_pre || 'alerta_antecedencia_min')::integer
                         else 180 end;

    v_itens := v_itens || privado.validar_nova_vaga(
      format('vagas[%s]', i), 100, publicar_escala.estabelecimento_id, v_eh_demo,
      v_funcao, v_inicio, v_fim, v_local, publicar_escala.evento->'ponto', v_valor, v_posicoes,
      v_refeicao, v_transporte, v_material, v_resp, v_modo, publicar_escala.chave,
      v_traje, v_rateio, v_obs, v_alerta, v_regiao);
  end loop;

  -- Tudo conferido. Daqui em diante, qualquer erro também desfaz a escala inteira: é uma transação só.
  v_ids := array(select gen_random_uuid() from generate_series(1, v_n));

  begin
    insert into public.evento (estabelecimento_id, nome, data, local, chave, vagas)
    values (publicar_escala.estabelecimento_id, v_nome, v_data::date, v_local,
            publicar_escala.chave, v_ids)
    returning * into v_evento;
  exception
    -- Envio simultâneo com a mesma chave: o outro gravou primeiro, e este devolve a escala dele.
    when unique_violation then
      select e.* into v_evento
        from public.evento e
       where e.estabelecimento_id = publicar_escala.estabelecimento_id
         and e.chave = publicar_escala.chave;
      return privado.escala_publicada(v_evento.id);
  end;

  for i in 1 .. v_n loop
    v_nova := v_itens[i];

    -- A chave da vaga é do servidor: a da escala colidiria com um publicar_vaga de mesma chave.
    insert into public.vaga (
      id, estabelecimento_id, evento_id, funcao_id, inicio_em, fim_em, local,
      regiao_administrativa, ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
      exige_material_proprio, responsavel_local, traje, participa_rateio, observacoes, modo,
      alerta_antecedencia, publicado_por, chave_cliente)
    values (
      v_ids[i], v_nova.estabelecimento_id, v_evento.id, v_nova.funcao_id, v_nova.inicio_em,
      v_nova.fim_em, v_nova.local, v_nova.regiao_administrativa, v_nova.ponto,
      v_nova.valor_centavos, v_nova.posicoes, v_nova.inclui_refeicao, v_nova.inclui_transporte,
      v_nova.exige_material_proprio, v_nova.responsavel_local, v_nova.traje,
      v_nova.participa_rateio, v_nova.observacoes, v_nova.modo, v_nova.alerta_antecedencia,
      v_uid, gen_random_uuid())
    returning * into v_vaga;

    insert into public.posicao (vaga_id, inicio_em, fim_em)
    select v_vaga.id, v_vaga.inicio_em, v_vaga.fim_em
      from generate_series(1, v_vaga.posicoes);

    -- O despacho de sempre, um por vaga, na mesma transação (o rollback leva junto). A conta de
    -- demonstração não entra na fila: a revisão da Apple não avisa profissional real.
    if not v_eh_demo then
      perform pgmq.send('despacho', jsonb_build_object(
        'vaga_id',      v_vaga.id,
        'publicada_em', v_vaga.publicado_em));
    end if;
  end loop;

  return privado.escala_publicada(v_evento.id);
end $$;

comment on function public.publicar_escala(uuid, jsonb, jsonb, uuid) is
  'Publica um evento e as vagas dele numa transação só (RF19, contrato 0.2.96): de 1 a 10 itens, até 100 posições somadas e até 100 por item. Cada item vira uma vaga comum, com as recusas de publicar_vaga (privado.validar_nova_vaga) e o despacho de sempre; qualquer recusa desfaz tudo. Idempotente pela chave da escala, olhada antes do corpo; o envio simultâneo devolve a escala de quem gravou primeiro.';

revoke execute on function public.publicar_escala(uuid, jsonb, jsonb, uuid) from public, anon;
grant  execute on function public.publicar_escala(uuid, jsonb, jsonb, uuid) to authenticated;

-- ── 5. O evento segue as vagas ────────────────────────────────────────────────
--
-- Quem tira o texto da vaga é a exclusão de conta (privado.excluir_conta), a limpeza de 15 dias
-- (privado.limpar_contas_anonimizadas) e o expurgo de 5 anos (privado.anonimizar_contexto_das_vagas),
-- cada uma com a regra e o marcador dela. O evento acompanha, sem regra própria: o nome sai quando o
-- texto livre de todas as vagas dele saiu (responsavel_local com marcador; traje e observacoes saem
-- junto), e o local quando o local de todas saiu. Recebe o marcador da vaga que fechou a conta.
create function privado.evento_segue_as_vagas()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.evento e
     set nome  = case
                   when new.responsavel_local in ('Expurgado (LGPD)', '[removido por exclusão de conta]')
                    and not exists (
                      select 1 from public.vaga v
                       where v.id = any (e.vagas)
                         and v.responsavel_local not in ('Expurgado (LGPD)', '[removido por exclusão de conta]'))
                   then new.responsavel_local
                   else e.nome
                 end,
         local = case
                   when new.local in ('Expurgado (LGPD)', '[removido por exclusão de conta]')
                    and not exists (
                      select 1 from public.vaga v
                       where v.id = any (e.vagas)
                         and v.local not in ('Expurgado (LGPD)', '[removido por exclusão de conta]'))
                   then new.local
                   else e.local
                 end
   where e.id = new.evento_id;
  return null;
end $$;

comment on function privado.evento_segue_as_vagas() is
  'Gatilho da vaga de escala: quando o texto livre ou o local de todas as vagas do evento já saíram (exclusão de conta, limpeza de 15 dias ou expurgo de 5 anos), o nome ou o local do evento recebe o mesmo marcador (decisão da Bússola de 16/11/2026, ROPA linha 16). A data fica, como o horário da vaga.';

revoke all on function privado.evento_segue_as_vagas() from public, anon, authenticated;

create trigger vaga_texto_leva_o_evento
  after update of responsavel_local, local on public.vaga
  for each row
  when (new.evento_id is not null
        and (new.responsavel_local is distinct from old.responsavel_local
             or new.local is distinct from old.local))
  execute function privado.evento_segue_as_vagas();
