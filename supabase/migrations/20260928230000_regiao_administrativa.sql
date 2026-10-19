-- Região administrativa do DF em estabelecimento, vaga e RPCs.
--
-- Requisito: x0jkygj0 (S2 · Backend · Região administrativa do local da vaga e interpolação nos pushes).
-- Contrato: 0.2.20 (NovoEstabelecimento, Estabelecimento, NovaVaga, VagaResumo, Vaga, VagaNaLista).
-- Requisitos / Regras: US07, US10, US14, US16 · RF06, RF10, RF12, RN10, RN15 · Decisões VyY2SGsX e 8zLfn0mt.
--
-- 1. Estabelecimentos e vagas passam a carregar a Região Administrativa (DF) estruturada.
-- 2. cadastrar_estabelecimento valida regiao_administrativa (obrigatória, sem termos ofensivos).
-- 3. publicar_vaga aceita regiao_administrativa e herda da casa se omitida.
-- 4. republicar_vaga propaga a regiao_administrativa da vaga de origem.
-- 5. Leitoras (vagas_abertas, detalhe_vaga, painel_estabelecimento, privado.turno_em_json,
--    privado.estabelecimento_em_json) passam a expor regiao_administrativa conforme o contrato 0.2.20.

-- ── 1. Colunas nas tabelas ─────────────────────────────────────────────────────

alter table public.estabelecimento
  add column if not exists regiao_administrativa text not null default 'Plano Piloto';

alter table public.estabelecimento
  drop constraint if exists estabelecimento_regiao_administrativa_check;

alter table public.estabelecimento
  add constraint estabelecimento_regiao_administrativa_check
  check (btrim(regiao_administrativa) <> '');

comment on column public.estabelecimento.regiao_administrativa is
  'Região Administrativa do Distrito Federal onde o estabelecimento fica (ex.: Plano Piloto, Taguatinga, Águas Claras).';

alter table public.vaga
  add column if not exists regiao_administrativa text not null default 'Plano Piloto';

update public.vaga v
   set regiao_administrativa = coalesce(
         (select e.regiao_administrativa from public.estabelecimento e where e.id = v.estabelecimento_id),
         'Plano Piloto'
       )
 where v.regiao_administrativa is null or btrim(v.regiao_administrativa) = '';

alter table public.vaga
  drop constraint if exists vaga_regiao_administrativa_check;

alter table public.vaga
  add constraint vaga_regiao_administrativa_check
  check (btrim(regiao_administrativa) <> '');

comment on column public.vaga.regiao_administrativa is
  'Região Administrativa do Distrito Federal onde o turno será executado. Vem preenchida com a do estabelecimento.';

-- ── 2. privado.estabelecimento_em_json ─────────────────────────────────────────

create or replace function privado.estabelecimento_em_json(
  e     public.estabelecimento,
  papel public.papel_membro
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'id',                    e.id,
    'nome',                  e.nome,
    'documento',             e.documento,
    'tipo',                  e.tipo,
    'endereco',              e.endereco,
    'regiao_administrativa', e.regiao_administrativa,
    'ponto',                 jsonb_build_object(
                               'latitude',  extensions.st_y(e.ponto::extensions.geometry),
                               'longitude', extensions.st_x(e.ponto::extensions.geometry)),
    'papel',                 estabelecimento_em_json.papel)
$$;

revoke execute on function privado.estabelecimento_em_json(public.estabelecimento, public.papel_membro) from public, anon, authenticated;
grant  execute on function privado.estabelecimento_em_json(public.estabelecimento, public.papel_membro) to service_role;

-- ── 3. cadastrar_estabelecimento ───────────────────────────────────────────────

drop function if exists public.cadastrar_estabelecimento(text, text, public.tipo_estabelecimento, text, jsonb);

create or replace function public.cadastrar_estabelecimento(
  nome                  text,
  documento             text,
  tipo                  public.tipo_estabelecimento,
  endereco              text,
  ponto                 jsonb,
  regiao_administrativa text default 'Plano Piloto'
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_nome   text := btrim(cadastrar_estabelecimento.nome);
  v_doc    text := btrim(cadastrar_estabelecimento.documento);
  v_end    text := btrim(cadastrar_estabelecimento.endereco);
  v_regiao text := btrim(coalesce(cadastrar_estabelecimento.regiao_administrativa, ''));
  v_ponto  jsonb := cadastrar_estabelecimento.ponto;
  v_lat    double precision;
  v_lon    double precision;
  v_linha  public.estabelecimento%rowtype;
  v_papel  public.papel_membro;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('contratante');

  if v_nome is null or v_nome = '' then
    perform public.erro(422, 'campo_obrigatorio', 'nome');
  end if;

  if v_doc is null or v_doc = '' then
    perform public.erro(422, 'campo_obrigatorio', 'documento');
  end if;

  if cadastrar_estabelecimento.tipo is null then
    perform public.erro(422, 'campo_obrigatorio', 'tipo');
  end if;

  if v_end is null or v_end = '' then
    perform public.erro(422, 'campo_obrigatorio', 'endereco');
  end if;

  if v_regiao = '' then
    perform public.erro(422, 'campo_obrigatorio', 'regiao_administrativa');
  end if;

  -- Diretriz 1.2 da App Store nos textos livres
  perform privado.exigir_texto_aceitavel(jsonb_build_object(
    'nome',                  v_nome,
    'endereco',              v_end,
    'regiao_administrativa', v_regiao));

  if v_ponto is null
     or jsonb_typeof(v_ponto -> 'latitude')  is distinct from 'number'
     or jsonb_typeof(v_ponto -> 'longitude') is distinct from 'number' then
    perform public.erro(422, 'campo_obrigatorio', 'ponto');
  end if;
  v_lat := (v_ponto ->> 'latitude')::double precision;
  v_lon := (v_ponto ->> 'longitude')::double precision;
  if v_lat not between -90 and 90 or v_lon not between -180 and 180 then
    perform public.erro(422, 'campo_obrigatorio', 'ponto');
  end if;

  if not privado.documento_valido(v_doc) then
    perform public.erro(422, 'campo_obrigatorio', 'documento');
  end if;

  select * into v_linha from public.estabelecimento e where e.documento = v_doc;
  if found then
    select m.papel into v_papel
      from public.membro_estabelecimento m
     where m.estabelecimento_id = v_linha.id and m.usuario_id = v_uid;
    if found then
      return privado.estabelecimento_em_json(v_linha, v_papel);
    end if;
    perform public.erro(409, 'documento_ja_cadastrado');
  end if;

  begin
    insert into public.estabelecimento (nome, documento, tipo, endereco, regiao_administrativa, ponto)
    values (v_nome, v_doc, cadastrar_estabelecimento.tipo, v_end, v_regiao,
            extensions.st_setsrid(extensions.st_makepoint(v_lon, v_lat), 4326)::extensions.geography)
    returning * into v_linha;
  exception
    when unique_violation then
      select e.* into v_linha from public.estabelecimento e where e.documento = v_doc;
      if found then
        select m.papel into v_papel
          from public.membro_estabelecimento m
         where m.estabelecimento_id = v_linha.id and m.usuario_id = v_uid;
        if found then
          return privado.estabelecimento_em_json(v_linha, v_papel);
        end if;
      end if;
      perform public.erro(409, 'documento_ja_cadastrado');
  end;

  insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
  values (v_uid, v_linha.id, 'administrador');

  return privado.estabelecimento_em_json(v_linha, 'administrador');
end $$;

comment on function public.cadastrar_estabelecimento(text, text, public.tipo_estabelecimento, text, jsonb, text) is
  'Cria o estabelecimento com quem chama como administrador (RF02, RF21). Só conta de contratante (RN25). CPF ou CNPJ conferido pelo dígito verificador; regiao_administrativa obrigatória (0.2.20).';

revoke execute on function public.cadastrar_estabelecimento(text, text, public.tipo_estabelecimento, text, jsonb, text)
  from public, anon;
grant  execute on function public.cadastrar_estabelecimento(text, text, public.tipo_estabelecimento, text, jsonb, text)
  to authenticated;

-- ── 4. publicar_vaga ──────────────────────────────────────────────────────────

drop function if exists public.publicar_vaga(
  uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int
);

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

  if publicar_vaga.modo <> 'urgencia' then
    perform public.erro(422, 'campo_invalido', 'modo');
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
  'Publica vaga e cria as posições pedidas (RN02, RN03). Enfileira o despacho em pgmq (B15). Reenvio seguro por chave_cliente (RF04). regiao_administrativa gravada na vaga (0.2.20).';

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

-- ── 5. republicar_vaga ────────────────────────────────────────────────────────

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

-- ── 6. vagas_abertas ──────────────────────────────────────────────────────────

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
  'Vagas abertas ordenadas por distância até o ponto informado, ou até o ponto base (RF07, RN05). A ordem não pode ser comprada (RN06); vaga de estabelecimento com bloqueio some (RF26). Vaga já começada some, salvo a com posição reaberta por atraso antes de fim − 1 h (contrato 0.2.19). Expõe regiao_administrativa no schema VagaNaLista.';

revoke execute on function public.vagas_abertas(numeric, numeric, uuid, date, numeric, int, int) from public, anon;
grant  execute on function public.vagas_abertas(numeric, numeric, uuid, date, numeric, int, int) to authenticated;

-- ── 7. detalhe_vaga ───────────────────────────────────────────────────────────

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
    'publicado_em',          v.publicado_em);
end $$;

comment on function public.detalhe_vaga(uuid) is
  'Detalhe da vaga para quem ainda não se candidatou (RF04, UC03). Sem documento e sem contato (RN10). Vaga escondida por bloqueio ou por demonstração responde 404, e não 403: o 403 confirmaria que ela existe. Depois do início, posicoes_abertas conta só as reabertas por atraso dentro do prazo (contrato 0.2.19). Expõe regiao_administrativa no schema Vaga / VagaDetalhe.';

revoke execute on function public.detalhe_vaga(uuid) from public, anon;
grant  execute on function public.detalhe_vaga(uuid) to authenticated;

-- ── 8. painel_estabelecimento ─────────────────────────────────────────────────

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

-- ── 9. privado.turno_em_json ──────────────────────────────────────────────────

create or replace function privado.turno_em_json(turno uuid, autor uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id',         t.id,
    'posicao_id', t.posicao_id,
    'vaga', jsonb_build_object(
      'id',                    v.id,
      'funcao',                f.nome,
      'local',                 v.local,
      'regiao_administrativa', v.regiao_administrativa,
      'inicio_em',             v.inicio_em,
      'fim_em',                v.fim_em,
      'valor_centavos',        v.valor_centavos),
    'contraparte', case
      when privado.usuario_do_profissional(p.profissional_id) = autor
        then privado.estabelecimento_publico(v.estabelecimento_id)
        else privado.perfil_publico_profissional(p.profissional_id) end,
    'contato_visivel_ate',     p.fim_em + interval '7 days',
    'checkin_em',              t.checkin_em,
    'checkin_tipo',            t.checkin_tipo,
    'checkin_distancia_m',     t.checkin_distancia_m,
    'checkin_confirmado_em',   t.checkin_confirmado_em,
    'checkout_em',             t.checkout_em,
    'checkout_distancia_m',    t.checkout_distancia_m,
    'verificacao',             t.verificacao,
    'valor_acordado_centavos', t.valor_acordado_centavos,
    'pode_avaliar',            privado.pode_avaliar(t.id, autor))
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v    on v.id = p.vaga_id
    join public.funcao f  on f.id = v.funcao_id
   where t.id = turno
$$;

comment on function privado.turno_em_json(uuid, uuid) is
  'Turno no schema do contrato (RF09, RF10). Expõe regiao_administrativa no VagaResumo.';

revoke execute on function privado.turno_em_json(uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.turno_em_json(uuid, uuid) to service_role;

-- ── 10. privado.obter_conteudo_push_lembrete ──────────────────────────────────
-- x0jkygj0: pushes 09 e 11 interpolam local como {estabelecimento} ({regiao}).
create or replace function privado.obter_conteudo_push_lembrete(
  p_turno_id   uuid,
  p_usuario_id uuid,
  p_tipo       text
)
returns jsonb
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  v_turno     record;
  v_eh_prof   boolean;
  v_funcao    text;
  v_estab     text;
  v_local     text;
  v_horario   text;
  v_title     text;
  v_body      text;
begin
  select t.id,
         p.inicio_em,
         p.profissional_id,
         v.estabelecimento_id,
         v.regiao_administrativa,
         f.nome as funcao_nome,
         e.nome as estab_nome
    into v_turno
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v on v.id = p.vaga_id
    join public.funcao f on f.id = v.funcao_id
    join public.estabelecimento e on e.id = v.estabelecimento_id
   where t.id = p_turno_id;

  if not found then
    return null;
  end if;

  v_eh_prof := (privado.usuario_do_profissional(v_turno.profissional_id) = p_usuario_id);
  v_funcao  := concat(upper(substring(v_turno.funcao_nome from 1 for 1)), substring(v_turno.funcao_nome from 2));
  v_estab   := v_turno.estab_nome;
  v_local   := case when v_turno.regiao_administrativa is not null and btrim(v_turno.regiao_administrativa) <> ''
                    then format('%s (%s)', v_estab, v_turno.regiao_administrativa)
                    else v_estab end;
  v_horario := to_char(v_turno.inicio_em at time zone 'America/Sao_Paulo', 'HH24:MI');

  if v_eh_prof then
    if p_tipo = 'lembrete_24h' then
      v_title := 'Lembrete de turno amanhã';
      v_body  := format('%s em %s amanhã às %s.', v_funcao, v_local, v_horario);
    elsif p_tipo = 'lembrete_3h' then
      v_title := 'Seu turno começa em 3 horas';
      v_body  := format('%s em %s às %s. Planeje seu trajeto.', v_funcao, v_local, v_horario);
    end if;
  else
    if p_tipo = 'lembrete_24h' then
      v_title := 'Turno agendado para amanhã';
      v_body  := format('Turno de %s confirmado para amanhã às %s.', v_turno.funcao_nome, v_horario);
    elsif p_tipo = 'lembrete_3h' then
      v_title := 'Turno em 3 horas';
      v_body  := format('Turno de %s começa às %s. O profissional foi lembrado.', v_turno.funcao_nome, v_horario);
    end if;
  end if;

  return jsonb_build_object('title', v_title, 'body', v_body);
end $$;

comment on function privado.obter_conteudo_push_lembrete(uuid, uuid, text) is
  'Monta título e corpo dos lembretes de 24h e 3h segundo a Opção A homologada (proposta-textos.md). Local utiliza {estabelecimento} ({regiao}) per x0jkygj0 e RN10.';

revoke execute on function privado.obter_conteudo_push_lembrete(uuid, uuid, text) from public, anon, authenticated;
grant execute on function privado.obter_conteudo_push_lembrete(uuid, uuid, text) to service_role;

