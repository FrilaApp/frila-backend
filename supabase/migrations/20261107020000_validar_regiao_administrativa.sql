-- Validar e migrar regiao_administrativa (RN44). Contratação direta, fatia F1 · brief B2.
--
-- O que muda:
--   · `estabelecimento.regiao_administrativa` e `vaga.regiao_administrativa` deixam de ser
--     texto livre: passam a apontar (chave estrangeira) para `public.regiao_administrativa (nome)`,
--     o catálogo das 37 regiões criado no B1.
--   · O dado legado é migrado antes da chave: variação conhecida (sem acento, caixa, apelido)
--     vira o nome oficial; o que não casa com nenhuma região vai para `Plano Piloto` (RA I) e o
--     texto original fica guardado em `privado.pendencia_regiao_administrativa`, para conciliação
--     manual. Nenhum outro campo da linha é tocado.
--   · `cadastrar_estabelecimento` e `publicar_vaga` recusam região fora do catálogo ativo com
--     `422 campo_invalido: regiao_administrativa`. Na vaga, a região omitida continua herdada da
--     casa (e, herdada ou não, tem de estar ativa).
--   · `republicar_vaga` não muda: já repassa a região da vaga de origem a `publicar_vaga`.
--
-- Nenhuma assinatura de RPC muda; o contrato (`info.version` 0.2.52) já descreve a região como
-- texto obrigatório e `campo_invalido` como código possível. As duas RPCs levam a marca
-- `corpo-sem-mudanca-de-superficie` do portão de contrato.

-- ── 1. A correspondência: texto legado → região oficial ───────────────────────
--
-- A chave é o texto normalizado (`privado.normalizar`: minúsculas, sem acento, pontuação virando
-- espaço), e o CHECK garante isso, como na lista de termos: chave mal gravada nunca casaria.
-- Os 37 nomes oficiais entram pelo próprio catálogo; abaixo deles, só os apelidos conhecidos.

create table privado.regiao_administrativa_apelido (
  chave text primary key check (chave = privado.normalizar(chave)),
  nome  text not null references public.regiao_administrativa (nome) on update cascade
);

comment on table privado.regiao_administrativa_apelido is
  'Correspondência entre o texto legado de regiao_administrativa (normalizado) e o nome oficial do catálogo (RN44). Serviu à migração do dado antigo e fica para a conciliação das pendências. Dado público, sem dado pessoal. Fora da API: o schema privado não é exposto pelo PostgREST.';
comment on column privado.regiao_administrativa_apelido.chave is
  'Texto legado já normalizado por privado.normalizar (minúsculas, sem acento, pontuação como espaço).';

alter table privado.regiao_administrativa_apelido enable row level security;
revoke all on table privado.regiao_administrativa_apelido from public, anon, authenticated;

insert into privado.regiao_administrativa_apelido (chave, nome)
select privado.normalizar(r.nome), r.nome
  from public.regiao_administrativa r;

insert into privado.regiao_administrativa_apelido (chave, nome) values
  ('brasilia',                  'Plano Piloto'),
  ('asa norte',                 'Plano Piloto'),
  ('asa sul',                   'Plano Piloto'),
  ('noroeste',                  'Plano Piloto'),
  ('sudoeste',                  'Sudoeste/Octogonal'),
  ('octogonal',                 'Sudoeste/Octogonal'),
  ('sudoeste e octogonal',      'Sudoeste/Octogonal'),
  ('riacho fundo 1',            'Riacho Fundo'),
  ('riacho fundo i',            'Riacho Fundo'),
  ('riacho fundo 2',            'Riacho Fundo II'),
  ('sobradinho 2',              'Sobradinho II'),
  ('sol nascente',              'Sol Nascente/Pôr do Sol'),
  ('por do sol',                'Sol Nascente/Pôr do Sol'),
  ('estrutural',                'SCIA'),
  ('cidade estrutural',         'SCIA'),
  ('parkway',                   'Park Way');

create or replace function privado.resolver_regiao_administrativa(p_texto text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select a.nome
    from privado.regiao_administrativa_apelido a
   where a.chave = privado.normalizar(p_texto)
$$;

comment on function privado.resolver_regiao_administrativa(text) is
  'Devolve o nome oficial da região para um texto legado, ou NULL se nenhuma região casa. Usada na migração de regiao_administrativa (RN44).';

revoke execute on function privado.resolver_regiao_administrativa(text) from public, anon, authenticated;

-- ── 2. As pendências: o texto original do que não casou ───────────────────────

create table privado.pendencia_regiao_administrativa (
  id              bigint generated always as identity primary key,
  origem          text not null check (origem in ('estabelecimento', 'vaga')),
  registro_id     uuid not null,
  texto_original  text not null,
  regiao_aplicada text not null references public.regiao_administrativa (nome) on update cascade,
  criado_em       timestamptz not null default privado.agora(),
  resolvido_em    timestamptz,

  constraint pendencia_regiao_unica unique (origem, registro_id)
);

comment on table privado.pendencia_regiao_administrativa is
  'Texto legado de regiao_administrativa que não casou com nenhuma das 37 regiões (RN44). A linha de origem recebeu a região de regiao_aplicada (fallback Plano Piloto) e o texto original fica aqui, sem perda, para conciliação manual. Guarda referência (origem, registro_id) e o texto da região, nunca cópia da linha (RN15). Apagar as linhas resolvidas quando a conciliação terminar (LGPD: fim da finalidade). Fora da API.';
comment on column privado.pendencia_regiao_administrativa.texto_original is
  'O valor que estava em regiao_administrativa antes da migração, exatamente como estava.';
comment on column privado.pendencia_regiao_administrativa.resolvido_em is
  'Quando alguém conciliou o registro com a região correta. NULL enquanto pendente.';

alter table privado.pendencia_regiao_administrativa enable row level security;
revoke all on table privado.pendencia_regiao_administrativa from public, anon, authenticated;

-- ── 3. A migração do dado legado, e só então a chave estrangeira ──────────────
--
-- Dois passos por tabela: primeiro guarda o texto de quem não casa com nada; depois corrige
-- todos. Quem já tem o nome oficial exato não entra em nenhum dos dois. Só a coluna da região
-- muda; nome, documento, endereço, ponto e o resto da linha ficam como estavam.
--
-- Mora numa função para que o teste (`800_validar_regiao_administrativa_f1.sql`) rode exatamente
-- o mesmo código sobre linhas legadas fabricadas, sem copiar o SQL.

create or replace function privado.conciliar_regiao_administrativa_legada()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into privado.pendencia_regiao_administrativa (origem, registro_id, texto_original, regiao_aplicada)
  select 'estabelecimento', e.id, e.regiao_administrativa, 'Plano Piloto'
    from public.estabelecimento e
   where not exists (select 1 from public.regiao_administrativa r
                      where r.nome = e.regiao_administrativa)
     and privado.resolver_regiao_administrativa(e.regiao_administrativa) is null
  on conflict (origem, registro_id) do nothing;

  update public.estabelecimento e
     set regiao_administrativa =
           coalesce(privado.resolver_regiao_administrativa(e.regiao_administrativa), 'Plano Piloto')
   where not exists (select 1 from public.regiao_administrativa r
                      where r.nome = e.regiao_administrativa);

  insert into privado.pendencia_regiao_administrativa (origem, registro_id, texto_original, regiao_aplicada)
  select 'vaga', v.id, v.regiao_administrativa, 'Plano Piloto'
    from public.vaga v
   where not exists (select 1 from public.regiao_administrativa r
                      where r.nome = v.regiao_administrativa)
     and privado.resolver_regiao_administrativa(v.regiao_administrativa) is null
  on conflict (origem, registro_id) do nothing;

  update public.vaga v
     set regiao_administrativa =
           coalesce(privado.resolver_regiao_administrativa(v.regiao_administrativa), 'Plano Piloto')
   where not exists (select 1 from public.regiao_administrativa r
                      where r.nome = v.regiao_administrativa);
end $$;

comment on function privado.conciliar_regiao_administrativa_legada() is
  'Normaliza regiao_administrativa legada em estabelecimento e vaga para o nome oficial do catálogo (RN44). O que não casa com nenhuma região vira Plano Piloto, com o texto original guardado em privado.pendencia_regiao_administrativa. Idempotente. Rodou uma vez na migração 20261107020000.';

revoke execute on function privado.conciliar_regiao_administrativa_legada() from public, anon, authenticated;

select privado.conciliar_regiao_administrativa_legada();

alter table public.estabelecimento
  add constraint estabelecimento_regiao_administrativa_fkey
  foreign key (regiao_administrativa) references public.regiao_administrativa (nome)
  on update cascade;

alter table public.vaga
  add constraint vaga_regiao_administrativa_fkey
  foreign key (regiao_administrativa) references public.regiao_administrativa (nome)
  on update cascade;

comment on column public.estabelecimento.regiao_administrativa is
  'Região administrativa do DF onde o estabelecimento fica. Nome oficial do catálogo public.regiao_administrativa (RN44), garantido por chave estrangeira.';
comment on column public.vaga.regiao_administrativa is
  'Região administrativa do DF onde a vaga acontece. Nome oficial do catálogo public.regiao_administrativa (RN44), garantido por chave estrangeira. Herda a do estabelecimento se omitida na publicação.';

-- ── 4. cadastrar_estabelecimento valida a região contra o catálogo ────────────
-- contrato: corpo-sem-mudanca-de-superficie public.cadastrar_estabelecimento 0.2.52

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

  -- RN44: a região é uma das do catálogo oficial e está ativa. Texto livre não entra mais.
  if not exists (select 1 from public.regiao_administrativa r
                  where r.nome = v_regiao and r.ativo) then
    perform public.erro(422, 'campo_invalido', 'regiao_administrativa');
  end if;

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
  'Cria o estabelecimento com quem chama como administrador (RF02, RF21). Só conta de contratante (RN25). CPF ou CNPJ conferido pelo dígito verificador; regiao_administrativa obrigatória (0.2.20) e conferida contra o catálogo ativo (RN44).';

revoke execute on function public.cadastrar_estabelecimento(text, text, public.tipo_estabelecimento, text, jsonb, text)
  from public, anon;
grant  execute on function public.cadastrar_estabelecimento(text, text, public.tipo_estabelecimento, text, jsonb, text)
  to authenticated;

-- ── 5. publicar_vaga valida a região contra o catálogo ────────────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.publicar_vaga 0.2.52

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
  v_local     text := btrim(publicar_vaga.local);
  v_resp      text := btrim(publicar_vaga.responsavel_local);
  v_traje     text := btrim(publicar_vaga.traje);
  v_obs       text := btrim(publicar_vaga.observacoes);
  v_regiao    text;
  v_agora     timestamptz;
  v_ponto     extensions.geography;
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
      if v_eh_demo then
        v_regiao := 'Plano Piloto';
      else
        perform public.erro(422, 'campo_obrigatorio', 'regiao_administrativa');
      end if;
    end if;
  else
    select e.regiao_administrativa into v_regiao
      from public.estabelecimento e
     where e.id = v_estab_id;
    if v_regiao is null or btrim(v_regiao) = '' then
      if v_eh_demo then
        v_regiao := 'Plano Piloto';
      else
        perform public.erro(422, 'campo_obrigatorio', 'regiao_administrativa');
      end if;
    end if;
  end if;

  -- RN44: seja a informada, seja a herdada da casa, a região existe no catálogo e está ativa.
  if not exists (select 1 from public.regiao_administrativa r
                  where r.nome = v_regiao and r.ativo) then
    perform public.erro(422, 'campo_invalido', 'regiao_administrativa');
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

  -- RN24: o modo seleção fecha sozinho 24 horas antes do início
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
      v_estab_id, publicar_vaga.funcao_id,
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

  -- Isolamento de demonstração: contas de demonstração não entram na fila de despacho,
  -- protegendo a revisão contra falhas externas de transporte/segredo e sem notificar terceiros.
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
  'Publica vaga e cria as posições pedidas (RN02, RN03). Enfileira o despacho em pgmq para contas reais (B15). Isolamento para conta de demonstração (5boVdM0t). Região conferida contra o catálogo ativo (RN44). Reenvio seguro por chave_cliente (RF04).';

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
