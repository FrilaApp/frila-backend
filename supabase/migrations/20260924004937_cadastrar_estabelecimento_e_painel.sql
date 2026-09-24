-- O estabelecimento: o cadastro e o painel de quem contrata.
--
-- `cadastrar_estabelecimento` é a primeira escrita do lado de quem publica: sem ela, a
-- conta de contratante existe e não tem por quem contratar. `painel_estabelecimento` é a
-- leitura que o gestor abre na sexta às 20h — e, como não existe operador do Frila
-- olhando esta tela (D01), os alertas que ela mostra são calculados na leitura, pelo
-- relógio do produto, e não guardados numa coluna que alguém esqueça de atualizar.
--
-- Fica para depois, e por quê:
--   `meus_estabelecimentos`  só existe no contrato 0.2.2, ainda não mergeado
--   filtro de texto no nome  depende da auxiliar do cartão de filtro, ainda em revisão

-- ── O documento ────────────────────────────────────────────────────────────────
--
-- CPF (11) ou CNPJ (14), só dígitos, com os dois dígitos verificadores conferidos. A
-- sequência repetida é recusada à parte: 111.111.111-11 e 00.000.000/0000-00 fecham a
-- conta do dígito e são o primeiro número que alguém digita para "ver se passa".
--
-- Não consulta a Receita. O dígito pega o erro de digitação, que é o caso comum; o
-- documento de outra pessoa é problema de verificação de identidade (RN14), não daqui.

create or replace function privado.documento_valido(doc text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  d      int[];
  n      int;
  soma   int;
  resto  int;
  dv1    int;
  dv2    int;
  pesos1 int[] := array[5,4,3,2,9,8,7,6,5,4,3,2];
  pesos2 int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2];
begin
  if doc is null or doc !~ '^([0-9]{11}|[0-9]{14})$' then
    return false;
  end if;
  -- Todos os dígitos iguais.
  if doc ~ '^(.)\1*$' then
    return false;
  end if;

  n := length(doc);
  d := array(select substr(doc, i, 1)::int from generate_series(1, n) i);

  if n = 11 then
    soma := 0;
    for i in 1..9 loop soma := soma + d[i] * (11 - i); end loop;
    resto := soma % 11;
    dv1 := case when resto < 2 then 0 else 11 - resto end;
    soma := 0;
    for i in 1..10 loop soma := soma + d[i] * (12 - i); end loop;
    resto := soma % 11;
    dv2 := case when resto < 2 then 0 else 11 - resto end;
    return d[10] = dv1 and d[11] = dv2;
  end if;

  soma := 0;
  for i in 1..12 loop soma := soma + d[i] * pesos1[i]; end loop;
  resto := soma % 11;
  dv1 := case when resto < 2 then 0 else 11 - resto end;
  soma := 0;
  for i in 1..13 loop soma := soma + d[i] * pesos2[i]; end loop;
  resto := soma % 11;
  dv2 := case when resto < 2 then 0 else 11 - resto end;
  return d[13] = dv1 and d[14] = dv2;
end $$;

comment on function privado.documento_valido(text) is
  'CPF ou CNPJ, só dígitos, com os dois dígitos verificadores certos e sem sequência repetida (RF02).';

-- ── A resposta no schema `Estabelecimento` ─────────────────────────────────────
--
-- Sete campos, e o documento entre eles: esta resposta só vai para quem administra ou
-- opera o estabelecimento. A reputação crua e a data de criação ficam de fora.

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
    'id',       e.id,
    'nome',     e.nome,
    'documento', e.documento,
    'tipo',     e.tipo,
    'endereco', e.endereco,
    'ponto',    jsonb_build_object(
                  'latitude',  extensions.st_y(e.ponto::extensions.geometry),
                  'longitude', extensions.st_x(e.ponto::extensions.geometry)),
    'papel',    estabelecimento_em_json.papel)
$$;

-- ── cadastrar_estabelecimento ──────────────────────────────────────────────────

create or replace function public.cadastrar_estabelecimento(
  nome      text,
  documento text,
  tipo      public.tipo_estabelecimento,
  endereco  text,
  ponto     jsonb
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_nome  text := btrim(cadastrar_estabelecimento.nome);
  v_end   text := btrim(cadastrar_estabelecimento.endereco);
  v_doc   text := cadastrar_estabelecimento.documento;
  v_ponto jsonb := cadastrar_estabelecimento.ponto;
  v_lat   double precision;
  v_lon   double precision;
  v_linha public.estabelecimento%rowtype;
  v_papel public.papel_membro;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  -- RN25: quem trabalha e quem contrata são contas diferentes.
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

  -- A Coordenada do contrato: dois números, cada um no seu intervalo.
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

  -- RF02. O cartão pede `campo_invalido`, que só existe a partir do contrato 0.2.2; o
  -- catálogo da 0.2.1 tem `campo_obrigatorio` com `details`, e é o que `criar_conta` já
  -- usa para o telefone fora do E.164. Quando o 0.2.2 entrar, muda esta linha.
  if not privado.documento_valido(v_doc) then
    perform public.erro(422, 'campo_obrigatorio', 'documento');
  end if;

  -- Idempotência pela chave natural, o documento. O mesmo membro reenviando recebe o
  -- estabelecimento que já existe; outra conta recebe o conflito, e só o conflito —
  -- nem o nome, nem quem administra.
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
    insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
    values (v_nome, v_doc, cadastrar_estabelecimento.tipo, v_end,
            extensions.st_setsrid(extensions.st_makepoint(v_lon, v_lat), 4326)::extensions.geography)
    returning * into v_linha;
  exception
    when unique_violation then
      -- Duas contas cadastrando o mesmo documento ao mesmo tempo: a segunda perde aqui.
      perform public.erro(409, 'documento_ja_cadastrado');
  end;

  -- RF21: o estabelecimento nasce com responsável. A chave estrangeira composta de
  -- `membro_estabelecimento` é a segunda trava de RN25, caso a primeira falhe.
  insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
  values (v_uid, v_linha.id, 'administrador');

  return privado.estabelecimento_em_json(v_linha, 'administrador');
end $$;

comment on function public.cadastrar_estabelecimento(text, text, public.tipo_estabelecimento, text, jsonb) is
  'Cria o estabelecimento com quem chama como administrador (RF02, RF21). Só conta de contratante (RN25). CPF ou CNPJ conferido pelo dígito verificador; o documento é a chave de idempotência.';

revoke execute on function public.cadastrar_estabelecimento(text, text, public.tipo_estabelecimento, text, jsonb)
  from public, anon;
grant  execute on function public.cadastrar_estabelecimento(text, text, public.tipo_estabelecimento, text, jsonb)
  to authenticated;

-- ── O profissional como PerfilPublico ──────────────────────────────────────────
--
-- Nome, funções e reputação com denominador (RN08). Nenhum contato (RN10) e nenhum
-- ponto base. `turnos_considerados` é o denominador da taxa: presenças mais faltas.

create or replace function privado.perfil_publico_profissional(prof uuid)
returns jsonb
language sql
stable
security definer set search_path = ''
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
      'turnos_considerados', p.turnos_realizados
                             + (select count(*) from public.posicao x
                                 where x.profissional_id = p.id and x.falta)))
    from public.profissional p
    join public.usuario u on u.id = p.usuario_id
   where p.id = prof
$$;

-- ── painel_estabelecimento ─────────────────────────────────────────────────────
--
-- Sem rótulo de volatilidade: chama `public.erro`, que é volátil por levantar exceção.
--
-- A regra de cada alerta, pelo relógio do produto (`privado.agora()`):
--
--   alerta_vaga_vazia  vaga publicada, com posição aberta, dentro da janela crítica —
--                      de `inicio_em - alerta_antecedencia` até o início. Depois do
--                      início ninguém mais se candidata, e o alerta não tem o que pedir.
--   em_atraso          posição confirmada, sem check-in, de 15 minutos depois do início
--                      (D06) até o fim. Depois do fim não há o que esperar nem reabrir.
--
-- Nenhuma ordem por reputação (RN06): vagas pelo início, posições pelo id.

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

  -- Quem não é membro recebe 403 sem distinção entre "não existe" e "não é seu": a
  -- diferença diria a um estranho que o estabelecimento existe. Profissional nunca é
  -- membro (RN25), então cai aqui também.
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
              'id',             v.id,
              'funcao',         f.nome,
              'local',          v.local,
              'inicio_em',      v.inicio_em,
              'fim_em',         v.fim_em,
              'valor_centavos', v.valor_centavos),
           'modo',   v.modo,
           'estado', v.estado,
           'alerta_vaga_vazia',
              v.estado = 'publicada'
              and v_agora >= v.inicio_em - v.alerta_antecedencia
              and v_agora <  v.inicio_em
              and exists (select 1 from public.posicao pa
                           where pa.vaga_id = v.id and pa.estado = 'aberta'),
           -- RF26: quem tem bloqueio com a casa some da contagem, como some da lista.
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

  -- Check-in manual esperando o toque do contratante: é ele quem torna o turno
  -- verificado (RN22), e sem o toque a presença não conta a favor de ninguém.
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
  'Vagas, posições, alertas e check-ins pendentes do estabelecimento no intervalo (RF20, RF13, UC07). Só para membro. Alertas calculados na leitura, pelo relógio do produto. Não traz documento nem contato.';

revoke execute on function public.painel_estabelecimento(uuid, timestamptz, timestamptz)
  from public, anon;
grant  execute on function public.painel_estabelecimento(uuid, timestamptz, timestamptz)
  to authenticated;

-- As auxiliares novas do schema privado seguem a regra das antigas: fora da API, e
-- anon não executa nada.
revoke execute on function privado.documento_valido(text) from public, anon;
revoke execute on function privado.estabelecimento_em_json(public.estabelecimento, public.papel_membro)
  from public, anon;
revoke execute on function privado.perfil_publico_profissional(uuid) from public, anon;
