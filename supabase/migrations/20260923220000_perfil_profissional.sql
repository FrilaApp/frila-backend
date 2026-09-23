-- As três RPCs do perfil profissional: criar, ler e atualizar (US02, RF03).
--
-- É aqui que o profissional declara o que decide se ele recebe cada vaga: as funções, o
-- ponto base e a grade semanal. Os três juntos são a RN05, e o motor de despacho do
-- Sprint 2 lê exatamente o que estas funções gravam.
--
-- ── O que não existe, por decisão ────────────────────────────────────────────
--
-- **Não há raio configurável.** Saiu do produto em 21/09 (B07): a distância que decide a
-- notificação é do sistema, 15 km do ponto base até o local da vaga, e a lista mostra
-- todas as vagas do DF ordenadas por distância. Um raio declarado pelo profissional
-- parece autonomia e é armadilha — quem põe 3 km some do produto e culpa o produto.
--
-- **Não há "disponível agora".** Saiu em 22/09. A grade semanal é a única fonte de
-- disponibilidade, e é o que permite ao despacho decidir sem perguntar nada a ninguém.
--
-- ── O molde das três ─────────────────────────────────────────────────────────
--
-- `security definer`, `search_path = ''`, `auth.uid()` na primeira linha e
-- `privado.exigir_perfil('profissional')` na segunda. A recusa de perfil vem **antes**
-- de qualquer escrita: com ela no fim, uma validação posterior que falhasse deixaria
-- linha órfã de uma conta que nem podia ter perfil.

-- ── Auxiliares de validação ───────────────────────────────────────────────────
--
-- Três funções pequenas em vez de um bloco grande repetido nas duas RPCs de escrita.
-- `criar` e `atualizar` validam a mesma coisa, e duas cópias divergem — foi assim que
-- `publicar_vaga` e `republicar_vaga` divergiram em outros projetos.

-- O ponto chega do cliente como `{"latitude": …, "longitude": …}`, que é o schema
-- `Coordenada` do contrato. Vira `geography(Point,4326)` aqui, e não no cliente: o
-- formato WKT é detalhe do banco, e trocá-lo não deve pedir release de app.
create or replace function privado.ponto_do_json(p jsonb) returns extensions.geography
language plpgsql
-- Sem rótulo de volatilidade, e portanto VOLATILE. Ela levanta exceção por
-- `public.erro`, e o texto que vira `geography` passa por um cast STABLE — o lint
-- reprovou as duas coisas quando ela nasceu `IMMUTABLE`, e reprovou com razão. Rótulo
-- de volatilidade mentiroso é o defeito que este repositório já pagou duas vezes:
-- o planejador acredita no rótulo, não no corpo.
set search_path = ''
as $$
declare
  v_lat numeric;
  v_lon numeric;
begin
  if p is null or p->'latitude' is null or p->'longitude' is null then
    perform public.erro(422, 'campo_obrigatorio', 'ponto_base');
  end if;

  begin
    v_lat := (p->>'latitude')::numeric;
    v_lon := (p->>'longitude')::numeric;
  exception when others then
    perform public.erro(422, 'campo_invalido', 'ponto_base');
  end;

  -- Conferido aqui para devolver o código do contrato. Sem isto, uma latitude de 120
  -- chegaria ao PostGIS e voltaria como erro de biblioteca, que o app não sabe ler.
  if v_lat < -90 or v_lat > 90 or v_lon < -180 or v_lon > 180 then
    perform public.erro(422, 'campo_invalido', 'ponto_base');
  end if;

  return ('SRID=4326;POINT(' || v_lon || ' ' || v_lat || ')')::extensions.geography;
end $$;

comment on function privado.ponto_do_json(jsonb) is
  'Coordenada do contrato (latitude/longitude) para geography. A conversão mora no banco para que o formato WKT não vaze para o cliente.';

create or replace function privado.ponto_em_json(g extensions.geography) returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'latitude',  round(extensions.ST_Y(g::extensions.geometry)::numeric, 6),
    'longitude', round(extensions.ST_X(g::extensions.geometry)::numeric, 6))
$$;

-- Seis casas decimais são cerca de 11 cm no equador. Mais que isso é ruído de ponto
-- flutuante devolvido como se fosse precisão, e o ponto base não precisa de 11 cm.
comment on function privado.ponto_em_json(extensions.geography) is
  'geography para a Coordenada do contrato, com seis casas — cerca de 11 cm, que é mais precisão do que o ponto base precisa.';

-- Troca a grade inteira pela lista enviada. Substituição, e não acréscimo: é o que o
-- contrato promete em `atualizar_perfil_profissional`, e é o que permite limpar a grade
-- mandando `[]`.
create or replace function privado.gravar_disponibilidade(prof uuid, janelas jsonb)
returns void
language plpgsql
security definer set search_path = ''
as $$
declare
  v_janela jsonb;
  v_dia    int;
  v_ini    time;
  v_fim    time;
begin
  if janelas is null then
    return;
  end if;

  if jsonb_typeof(janelas) <> 'array' then
    perform public.erro(422, 'campo_invalido', 'disponibilidades');
  end if;

  delete from public.disponibilidade d where d.profissional_id = prof;

  for v_janela in select * from jsonb_array_elements(janelas) loop
    begin
      v_dia := (v_janela->>'dia_semana')::int;
      v_ini := (v_janela->>'hora_inicio')::time;
      v_fim := (v_janela->>'hora_fim')::time;
    exception when others then
      perform public.erro(422, 'campo_invalido', 'disponibilidades');
    end;

    if v_dia is null or v_ini is null or v_fim is null then
      perform public.erro(422, 'campo_obrigatorio', 'disponibilidades');
    end if;

    if v_dia < 0 or v_dia > 6 then
      perform public.erro(422, 'campo_invalido', 'disponibilidades');
    end if;

    -- A comparação é de desigualdade, e **não** `hora_fim > hora_inicio`. 18:00–02:00
    -- atravessa a meia-noite e é a janela mais comum do setor; recusá-la excluiria do
    -- produto justamente o turno que ele existe para preencher. O que não vale é
    -- duração zero.
    if v_ini = v_fim then
      perform public.erro(422, 'campo_invalido', 'disponibilidades');
    end if;

    insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
    values (prof, v_dia, v_ini, v_fim)
    on conflict (profissional_id, dia_semana, hora_inicio, hora_fim) do nothing;
  end loop;
end $$;

comment on function privado.gravar_disponibilidade(uuid, jsonb) is
  'Substitui a grade semanal inteira. Aceita janela que atravessa a meia-noite; recusa duração zero.';

create or replace function privado.gravar_funcoes(prof uuid, funcoes uuid[])
returns void
language plpgsql
security definer set search_path = ''
as $$
declare
  v_validas int;
begin
  if funcoes is null then
    return;
  end if;

  if array_length(funcoes, 1) is null then
    perform public.erro(422, 'campo_obrigatorio', 'funcoes');
  end if;

  -- O catálogo é fechado de propósito (RN05): se a função fosse texto livre, a
  -- elegibilidade viraria busca por aproximação, e notificar quem não é elegível é o
  -- erro que mata o canal de notificação — que é o produto.
  select count(distinct f.id) into v_validas
    from public.funcao f
   where f.id = any (funcoes) and f.ativo;

  if v_validas is distinct from (select count(distinct x) from unnest(funcoes) x) then
    perform public.erro(422, 'campo_invalido', 'funcoes');
  end if;

  delete from public.profissional_funcao pf where pf.profissional_id = prof;
  insert into public.profissional_funcao (profissional_id, funcao_id)
  select prof, x from unnest(funcoes) x
  on conflict do nothing;
end $$;

comment on function privado.gravar_funcoes(uuid, uuid[]) is
  'Substitui as funções declaradas. Id fora do catálogo é campo_invalido — função nunca é texto livre (RN05).';

-- ── A resposta ────────────────────────────────────────────────────────────────
--
-- Molda o schema `PerfilProfissional` do contrato. Separada porque as três RPCs
-- devolvem a mesma coisa, e três cópias divergem na primeira mudança de campo.
--
-- A reputação sai com os dois números que RN08 exige juntos — a resposta e o
-- denominador —, e `taxa_comparecimento` nula quando não há histórico: 0.0 e nulo
-- contam histórias opostas sobre quem acabou de chegar (RF16).

create or replace function public.perfil_profissional_em_json(prof public.profissional)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id',         prof.id,
    'usuario_id', prof.usuario_id,
    'ponto_base', privado.ponto_em_json(prof.ponto_base),
    'funcoes', coalesce(
      (select jsonb_agg(jsonb_build_object('id', f.id, 'nome', f.nome, 'categoria', f.categoria)
                        order by f.nome)
         from public.profissional_funcao pf
         join public.funcao f on f.id = pf.funcao_id
        where pf.profissional_id = prof.id), '[]'::jsonb),
    'disponibilidades', coalesce(
      (select jsonb_agg(jsonb_build_object(
                'dia_semana',  d.dia_semana,
                'hora_inicio', to_char(d.hora_inicio, 'HH24:MI'),
                'hora_fim',    to_char(d.hora_fim,    'HH24:MI'))
                order by d.dia_semana, d.hora_inicio)
         from public.disponibilidade d
        where d.profissional_id = prof.id), '[]'::jsonb),
    'reputacao', jsonb_build_object(
      'positivas',           prof.aval_positivas,
      'total',               prof.aval_total,
      'taxa_comparecimento', prof.taxa_comparecimento,
      'turnos_considerados', prof.turnos_realizados
                             + (select count(*) from public.posicao p
                                 where p.profissional_id = prof.id and p.falta),
      'turnos_realizados',   prof.turnos_realizados))
$$;

revoke execute on function public.perfil_profissional_em_json(public.profissional)
  from public, anon, authenticated;

-- ── criar_perfil_profissional ─────────────────────────────────────────────────

create or replace function public.criar_perfil_profissional(
  funcoes          uuid[],
  ponto_base       jsonb,
  disponibilidades jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_linha public.profissional%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if exists (select 1 from public.profissional p where p.usuario_id = v_uid) then
    -- Conflito, e não sobrescrita: sobrescrever aqui apagaria a grade de quem tocasse
    -- duas vezes no botão de cadastrar. Quem quer mudar chama `atualizar`.
    perform public.erro(409, 'perfil_ja_existe');
  end if;

  if funcoes is null or array_length(funcoes, 1) is null then
    perform public.erro(422, 'campo_obrigatorio', 'funcoes');
  end if;

  insert into public.profissional (usuario_id, ponto_base)
  values (v_uid, privado.ponto_do_json(criar_perfil_profissional.ponto_base))
  returning * into v_linha;

  perform privado.gravar_funcoes(v_linha.id, criar_perfil_profissional.funcoes);
  perform privado.gravar_disponibilidade(v_linha.id, criar_perfil_profissional.disponibilidades);

  return public.perfil_profissional_em_json(v_linha);
end $$;

comment on function public.criar_perfil_profissional(uuid[], jsonb, jsonb) is
  'Cria o perfil de profissional: funções, ponto base e grade semanal (RF03). Conta de contratante é recusada (RN25). Grade vazia é aceita — o app avisa que não haverá notificação.';

-- ── meu_perfil_profissional ───────────────────────────────────────────────────

create or replace function public.meu_perfil_profissional()
returns jsonb
language plpgsql
-- Sem `stable`: chama `public.erro`, que é volátil por levantar exceção. Rotular de
-- estável é mentir para o planejador, e o lint reprova.
security definer set search_path = ''
as $$
declare
  v_linha public.profissional%rowtype;
begin
  if (select auth.uid()) is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  select * into v_linha from public.profissional p where p.usuario_id = (select auth.uid());
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  return public.perfil_profissional_em_json(v_linha);
end $$;

comment on function public.meu_perfil_profissional() is
  'O próprio perfil de profissional, com funções, grade e reputação. 404 antes de o perfil existir — é como o app sabe que tem de mandar para o cadastro.';

-- ── atualizar_perfil_profissional ─────────────────────────────────────────────
--
-- Os campos enviados substituem os atuais; os omitidos ficam como estão. `null` é
-- "omitido", e é o que o contrato permite: nenhum campo de `AlteracaoDoPerfilProfissional`
-- é anulável, então não há ambiguidade entre "não mandei" e "mandei vazio".
--
-- `funcoes => '{}'` **não** é omissão: é uma lista vazia, e sai como `campo_obrigatorio`.
-- É a diferença que o critério de aceite do cartão cobra.

create or replace function public.atualizar_perfil_profissional(
  funcoes          uuid[] default null,
  ponto_base       jsonb  default null,
  disponibilidades jsonb  default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_linha public.profissional%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if atualizar_perfil_profissional.funcoes is null
     and atualizar_perfil_profissional.ponto_base is null
     and atualizar_perfil_profissional.disponibilidades is null then
    perform public.erro(422, 'campo_obrigatorio', 'nenhum_campo');
  end if;

  select * into v_linha from public.profissional p where p.usuario_id = v_uid;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if atualizar_perfil_profissional.ponto_base is not null then
    update public.profissional p
       set ponto_base = privado.ponto_do_json(atualizar_perfil_profissional.ponto_base)
     where p.id = v_linha.id
    returning * into v_linha;
  end if;

  perform privado.gravar_funcoes(v_linha.id, atualizar_perfil_profissional.funcoes);
  perform privado.gravar_disponibilidade(v_linha.id, atualizar_perfil_profissional.disponibilidades);

  return public.perfil_profissional_em_json(v_linha);
end $$;

comment on function public.atualizar_perfil_profissional(uuid[], jsonb, jsonb) is
  'Altera funções, ponto base ou grade. O enviado substitui; o omitido fica. A mudança vale na próxima notificação, sem novo login (RF03).';

-- ── Permissões ────────────────────────────────────────────────────────────────

revoke execute on function privado.ponto_do_json(jsonb)                       from public, anon;
revoke execute on function privado.ponto_em_json(extensions.geography)        from public, anon;
revoke execute on function privado.gravar_disponibilidade(uuid, jsonb)        from public, anon;
revoke execute on function privado.gravar_funcoes(uuid, uuid[])               from public, anon;
grant  execute on function privado.ponto_do_json(jsonb)                       to authenticated, service_role;
grant  execute on function privado.ponto_em_json(extensions.geography)        to authenticated, service_role;
grant  execute on function privado.gravar_disponibilidade(uuid, jsonb)        to authenticated, service_role;
grant  execute on function privado.gravar_funcoes(uuid, uuid[])               to authenticated, service_role;

revoke execute on function public.criar_perfil_profissional(uuid[], jsonb, jsonb)     from public, anon;
revoke execute on function public.meu_perfil_profissional()                           from public, anon;
revoke execute on function public.atualizar_perfil_profissional(uuid[], jsonb, jsonb) from public, anon;
grant  execute on function public.criar_perfil_profissional(uuid[], jsonb, jsonb)     to authenticated;
grant  execute on function public.meu_perfil_profissional()                           to authenticated;
grant  execute on function public.atualizar_perfil_profissional(uuid[], jsonb, jsonb) to authenticated;
