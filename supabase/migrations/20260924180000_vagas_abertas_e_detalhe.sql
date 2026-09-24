-- `vagas_abertas` e `detalhe_vaga`: a tela de quem procura turno.
--
-- São as duas primeiras leituras do lado do profissional, e nelas o que **não** aparece
-- é o que importa: a ordem não pode ser comprada (RN06), vaga de estabelecimento com
-- bloqueio some (RF26), documento e telefone não saem daqui (RN10), e conta de
-- demonstração e conta real não se enxergam (diretriz 2.1 da App Store).
--
-- As duas são `security definer` porque montam o `PerfilPublico` do estabelecimento, e
-- a política `estabelecimento_leitura` só deixa membro ler a linha da casa. Sem a
-- função, o profissional não teria como saber o nome do lugar para onde vai trabalhar.

-- ── A marca de demonstração ───────────────────────────────────────────────────
--
-- O revisor da App Store entra por uma conta que não recebe e-mail, e precisa ver
-- lista cheia (4.2). Mas uma vaga publicada por ele em produção não pode notificar
-- profissional de verdade, nem aparecer para ninguém: as duas populações vivem lado a
-- lado no mesmo banco e não se enxergam.
--
-- A marca fica na **conta**, e a vaga herda dela por `publicado_por`. Uma coluna em
-- `vaga` seria uma segunda fonte da mesma verdade, e a primeira vaga publicada sem
-- ela já quebraria o isolamento.
--
-- A Edge Function `entrar-demonstracao`, o código fixo em segredo, o seed das contas e
-- as notas da revisão continuam no cartão 7gpPBgTH. Aqui entra só o que as leituras
-- deste cartão precisam para cumprir o critério de aceite.

alter table public.usuario
  add column if not exists demonstracao boolean not null default false;

comment on column public.usuario.demonstracao is
  'Conta de revisão da App Store (diretrizes 2.1 e 4.2). Vaga de conta de demonstração só aparece para conta de demonstração, e vice-versa: as duas populações dividem o banco e não se enxergam.';

create index if not exists usuario_demonstracao on public.usuario (demonstracao)
  where demonstracao;

create or replace function privado.conta_de_demonstracao()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select u.demonstracao from public.usuario u where u.id = (select auth.uid())), false)
$$;

comment on function privado.conta_de_demonstracao() is
  'Verdadeiro quando a conta da sessão é de revisão da App Store. Conta sem linha em usuario é tratada como real.';

-- ── PerfilPublico do estabelecimento ──────────────────────────────────────────
--
-- O mesmo schema do profissional, do outro lado: id, tipo, nome e reputação com
-- denominador (RN08). Sem documento, sem endereço e sem quem administra — esta
-- resposta vai para quem ainda não se candidatou.
--
-- `taxa_comparecimento` é nula e os dois contadores são zero por definição: a taxa é do
-- profissional (é ele que comparece ou falta), e o contrato já diz isso no schema. Zero
-- aqui não é "nunca trabalhou": é "este campo não se aplica a esta ponta".
create or replace function privado.estabelecimento_publico(estab uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id',   e.id,
    'tipo', 'estabelecimento',
    'nome', e.nome,
    'reputacao', jsonb_build_object(
      'positivas',           e.aval_positivas,
      'total',               e.aval_total,
      'taxa_comparecimento', null,
      'turnos_considerados', 0,
      'turnos_realizados',   0))
    from public.estabelecimento e
   where e.id = estab
$$;

comment on function privado.estabelecimento_publico(uuid) is
  'PerfilPublico do estabelecimento (RN08). Sem documento e sem endereço: vai para quem ainda não se candidatou.';

-- ── O perfil público do profissional ganha o campo que faltava ────────────────
--
-- O contrato exige `turnos_realizados` em `Reputacao` desde a 0.2.1, e a função nasceu
-- sem ele. Quem lê o perfil de um profissional recebia um objeto que não valida contra
-- o schema, e o cliente gerado a partir do contrato quebraria ao desserializar.
create or replace function privado.perfil_publico_profissional(prof uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id',   p.id,
    'tipo', 'profissional',
    'nome', u.nome,
    'funcoes', coalesce((select jsonb_agg(f.nome order by f.nome)
                           from public.profissional_funcao pf
                           join public.funcao f on f.id = pf.funcao_id
                          where pf.profissional_id = p.id), '[]'::jsonb),
    'reputacao', jsonb_build_object(
      'positivas',           p.aval_positivas,
      'total',               p.aval_total,
      'taxa_comparecimento', p.taxa_comparecimento,
      'turnos_realizados',   p.turnos_realizados,
      'turnos_considerados', p.turnos_realizados
                             + (select count(*) from public.posicao x
                                 where x.profissional_id = p.id and x.falta)))
    from public.profissional p
    join public.usuario u on u.id = p.usuario_id
   where p.id = prof
$$;

-- ── Dois moldes pequenos ──────────────────────────────────────────────────────

create or replace function privado.funcao_em_json(f public.funcao)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('id', f.id, 'nome', f.nome, 'categoria', f.categoria)
$$;

create or replace function privado.inclusos_em_json(v public.vaga)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'inclui_refeicao',        v.inclui_refeicao,
    'inclui_transporte',      v.inclui_transporte,
    'exige_material_proprio', v.exige_material_proprio)
$$;

-- ── vagas_abertas ─────────────────────────────────────────────────────────────

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
-- Não é `stable`: recusa por `public.erro`, que é volátil. O PostgREST a executa numa
-- transação só de leitura e responde ao GET do contrato assim mesmo — o mesmo caminho
-- que `painel_estabelecimento` já usa.
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_ref   extensions.geography;
  v_demo  boolean;
  v_raio  double precision;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- A lista é a tela de quem procura turno. A política `vaga_leitura` já diz o mesmo em
  -- SQL; aqui a recusa sai com o código que o app compara, em vez de uma lista vazia
  -- que o contratante leria como "não há vagas".
  perform privado.exigir_perfil('profissional');

  if vagas_abertas.limite is null or vagas_abertas.limite < 1 or vagas_abertas.limite > 100 then
    perform public.erro(422, 'campo_invalido', 'limite');
  end if;
  if vagas_abertas.deslocamento is null or vagas_abertas.deslocamento < 0 then
    perform public.erro(422, 'campo_invalido', 'deslocamento');
  end if;

  -- O ponto de referência: a coordenada enviada manda mais que o ponto base, porque
  -- quem abre o app longe de casa quer ver o que há em volta de onde está.
  if vagas_abertas.latitude is not null or vagas_abertas.longitude is not null then
    v_ref := privado.ponto_do_json(
      jsonb_build_object('latitude', vagas_abertas.latitude, 'longitude', vagas_abertas.longitude),
      'latitude');
  else
    select p.ponto_base into v_ref
      from public.profissional p where p.usuario_id = v_uid;
    if v_ref is null then
      -- Sem perfil não há ponto base, e sem ponto de referência não há ordem. Recusar é
      -- melhor do que ordenar por um ponto inventado: a lista sairia plausível e errada.
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
                 'id',               v.id,
                 'funcao',           privado.funcao_em_json(f.*),
                 'estabelecimento',  privado.estabelecimento_publico(v.estabelecimento_id),
                 'inicio_em',        v.inicio_em,
                 'fim_em',           v.fim_em,
                 'local',            v.local,
                 'distancia_km',     round((extensions.st_distance(v.ponto, v_ref) / 1000)::numeric, 2),
                 'valor_centavos',   v.valor_centavos,
                 'posicoes_abertas', (select count(*) from public.posicao p
                                       where p.vaga_id = v.id and p.estado = 'aberta'),
                 'inclusos',         privado.inclusos_em_json(v.*),
                 'modo',             v.modo) as item,
               row_number() over (order by v.ponto operator(extensions.<->) v_ref, v.id) as ordem
          from public.vaga v
          join public.funcao f  on f.id = v.funcao_id
          join public.usuario u on u.id = v.publicado_por
         where v.estado = 'publicada'
           -- Diretriz 2.1: as duas populações dividem o banco e não se enxergam.
           and u.demonstracao = v_demo
           -- RF26. O bloqueio é com a pessoa, e alcança todas as casas dela.
           and not privado.bloqueado_com_estabelecimento(v_uid, v.estabelecimento_id)
           and (vagas_abertas.funcao_id is null or v.funcao_id = vagas_abertas.funcao_id)
           -- O dia é o de São Paulo. Às 23:30 de uma sexta em Brasília já é sábado em
           -- UTC, e comparar em UTC esconderia o turno de sexta à noite de quem
           -- filtrasse por sexta — que é o turno mais comum do produto.
           and (vagas_abertas.data is null
                or (v.inicio_em at time zone 'America/Sao_Paulo')::date = vagas_abertas.data)
           -- A distância **ordena** sempre; ela só filtra quando o profissional pede
           -- (B07: o limite de 15 km é da notificação, não da busca).
           and (v_raio is null or extensions.st_dwithin(v.ponto, v_ref, v_raio))
         order by v.ponto operator(extensions.<->) v_ref, v.id
         limit vagas_abertas.limite offset vagas_abertas.deslocamento
      ) t
  ), '[]'::jsonb);
end $$;

comment on function public.vagas_abertas(numeric, numeric, uuid, date, numeric, int, int) is
  'Vagas abertas ordenadas por distância até o ponto informado, ou até o ponto base (RF07, RN05). A ordem não pode ser comprada (RN06); vaga de estabelecimento com bloqueio some (RF26).';

revoke execute on function public.vagas_abertas(numeric, numeric, uuid, date, numeric, int, int)
  from public, anon;
grant execute on function public.vagas_abertas(numeric, numeric, uuid, date, numeric, int, int)
  to authenticated;

-- ── detalhe_vaga ──────────────────────────────────────────────────────────────
--
-- Tudo o que o profissional vê antes de se candidatar. O que ele **não** vê é o que
-- esta função existe para garantir: documento do estabelecimento, telefone de quem quer
-- que seja, e a existência de vaga que ele não deveria alcançar.
--
-- Vaga escondida por bloqueio ou por demonstração responde **404**, e não 403: um 403
-- confirmaria que aquela vaga existe, e quem bloqueou alguém não deve receber prova de
-- que a outra parte continua publicando.

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
    'id',                v.id,
    'estabelecimento',   privado.estabelecimento_publico(v.estabelecimento_id),
    'funcao',            privado.funcao_em_json(v_f.*),
    'inicio_em',         v.inicio_em,
    'fim_em',            v.fim_em,
    'local',             v.local,
    'ponto',             privado.ponto_em_json(v.ponto),
    'distancia_km',      case when v_ref is null then null
                              else round((extensions.st_distance(v.ponto, v_ref) / 1000)::numeric, 2) end,
    'valor_centavos',    v.valor_centavos,
    'posicoes',          v.posicoes,
    'posicoes_abertas',  (select count(*) from public.posicao p
                           where p.vaga_id = v.id and p.estado = 'aberta'),
    'inclusos',          privado.inclusos_em_json(v.*),
    'responsavel_local', v.responsavel_local,
    'traje',             v.traje,
    'participa_rateio',  v.participa_rateio,
    'observacoes',       v.observacoes,
    'modo',              v.modo,
    'estado',            v.estado,
    'publicado_em',      v.publicado_em);
end $$;

comment on function public.detalhe_vaga(uuid) is
  'Detalhe da vaga para quem ainda não se candidatou (RF04, UC03). Sem documento e sem contato (RN10). Vaga escondida por bloqueio ou por demonstração responde 404, e não 403: o 403 confirmaria que ela existe.';

revoke execute on function public.detalhe_vaga(uuid) from public, anon;
grant execute on function public.detalhe_vaga(uuid) to authenticated;
