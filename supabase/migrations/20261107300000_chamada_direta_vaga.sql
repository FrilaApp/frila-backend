-- F4, parte A (contrato 0.2.55, ADR-001, RN28 a RN34, RN38, RN45, RN46): a chamada é uma vaga
-- endereçada. Cria `vaga.origem`, `chamada`, o interruptor `chamada_direta` (desligado) e
-- `chamar_profissional`. Responder, cancelar e as leituras da chamada vêm nas partes seguintes.

-- ── 1. De onde a vaga nasceu ──────────────────────────────────────────────────
alter table public.vaga
  add column origem text not null default 'publicacao'
    check (origem in ('publicacao', 'chamada_direta'));

comment on column public.vaga.origem is
  'publicacao: vaga do DF, despachada e listada. chamada_direta: uma posição endereçada a um profissional pela chamar_profissional; nunca despachada nem listada (0.2.55).';

-- ── 2. O interruptor do servidor (RN46) ──────────────────────────────────────
-- Nasce desligado em todo ambiente: no Prod, só liga depois do jurídico e do ROPA. Mudar
-- é um `update` por migração, nunca pelo painel.
create table privado.recurso (
  chave  text primary key,
  ligado boolean not null default false
);
alter table privado.recurso enable row level security;
revoke all on table privado.recurso from public, anon, authenticated;
comment on table privado.recurso is
  'Interruptores de recurso do servidor (ConfiguracaoDoApp.recursos, 0.2.54). Recurso desligado: as operações dele respondem 403 sem_permissao, recurso_desligado. Não guarda dado pessoal.';
insert into privado.recurso (chave, ligado) values ('chamada_direta', false);

-- ── 3. A chamada ──────────────────────────────────────────────────────────────
create table public.chamada (
  id                 uuid primary key default gen_random_uuid(),
  vaga_id            uuid not null references public.vaga(id) on delete cascade,
  profissional_id    uuid not null references public.profissional(id),
  estabelecimento_id uuid not null references public.estabelecimento(id),
  criada_por         uuid not null references public.usuario(id),
  estado             text not null default 'aberta'
    check (estado in ('aberta', 'aceita', 'recusada', 'expirada', 'cancelada', 'encerrada')),
  recado             text check (recado is null or length(recado) <= 300),
  motivo_recusa      text
    check (motivo_recusa is null or motivo_recusa in ('agenda', 'distancia', 'valor', 'tipo_de_servico', 'outro')),
  expira_em          timestamptz not null,
  lembrete_em        timestamptz,
  respondida_em      timestamptz,
  criada_em          timestamptz not null default now(),
  chave              uuid not null,
  constraint chamada_uma_por_vaga_e_profissional unique (vaga_id, profissional_id),
  constraint chamada_chave_unica unique (estabelecimento_id, chave)
);

-- RN34: o par estabelecimento e profissional tem no máximo uma chamada aberta por vez.
create unique index chamada_uma_aberta_por_par
  on public.chamada (estabelecimento_id, profissional_id) where estado = 'aberta';
create index chamada_por_profissional on public.chamada (profissional_id, criada_em desc);

-- Sem política: lê-se só pelas RPCs (minhas_chamadas, detalhe_chamada), que aplicam o
-- bloqueio (RF26). Nenhuma tabela tem política de escrita.
alter table public.chamada enable row level security;
revoke all on table public.chamada from public, anon, authenticated;

comment on table public.chamada is
  'Chamada direta de um estabelecimento a um profissional que já trabalhou com ele (RN28). Valor, horário e local moram na vaga. Sobrevive à exclusão de conta, como o turno: pertence também à contraparte.';
comment on column public.chamada.recado is
  'Texto curto opcional ao profissional, filtrado por termos e contato (RN38). Finalidade: contexto do trabalho; nunca telefone.';
comment on column public.chamada.criada_por is
  'O membro que chamou. Finalidade: limite por estabelecimento e encerramento se ele for suspenso.';

-- ── 4. Chamar ─────────────────────────────────────────────────────────────────
create or replace function public.chamar_profissional(
  chave uuid default null, profissional_id uuid default null, estabelecimento_id uuid default null,
  vaga_id uuid default null, funcao_id uuid default null, inicio_em timestamptz default null,
  fim_em timestamptz default null, local text default null, regiao_administrativa text default null,
  ponto jsonb default null, valor_centavos bigint default null, inclui_refeicao boolean default null,
  inclui_transporte boolean default null, exige_material_proprio boolean default null,
  responsavel_local text default null, recado text default null, confirmo_recorrencia boolean default false
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_agora  timestamptz := privado.agora();
  v_estab  uuid := chamar_profissional.estabelecimento_id;
  v_prof   uuid := chamar_profissional.profissional_id;
  v_recado text := nullif(btrim(chamar_profissional.recado), '');
  v_conta  public.usuario%rowtype;
  v_vaga   public.vaga%rowtype;
  v_c      public.chamada%rowtype;
  v_falta  text;
  v_veterana boolean;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  if not coalesce((select r.ligado from privado.recurso r where r.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
  perform privado.exigir_perfil('contratante');
  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;
  if chamar_profissional.chave is null then perform public.erro(422, 'campo_obrigatorio', 'chave'); end if;
  if v_prof is null then perform public.erro(422, 'campo_obrigatorio', 'profissional_id'); end if;
  if v_estab is null then perform public.erro(422, 'campo_obrigatorio', 'estabelecimento_id'); end if;
  if not privado.eh_membro(v_estab) then perform public.erro(403, 'sem_permissao'); end if;

  -- Idempotência: reenviar a mesma chave devolve a mesma chamada e não gasta cota.
  select * into v_c from public.chamada c where c.estabelecimento_id = v_estab and c.chave = chamar_profissional.chave;
  if found then return to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em']; end if;

  -- Profissional inexistente, fora do ar ou com bloqueio: o mesmo 404 (RF26).
  select u.* into v_conta from public.profissional p join public.usuario u on u.id = p.usuario_id where p.id = v_prof;
  if not found or v_conta.estado <> 'ativa'
     or privado.bloqueado_com_estabelecimento(v_conta.id, v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Serializa as chamadas da casa: os limites somam os membros (RN34).
  perform 1 from public.estabelecimento e where e.id = v_estab for update;
  if exists (select 1 from public.chamada c where c.estabelecimento_id = v_estab
                and c.profissional_id = v_prof and c.estado = 'aberta') then
    perform public.erro(409, 'chamada_ja_aberta');
  end if;

  if chamar_profissional.vaga_id is not null then
    if num_nonnulls(chamar_profissional.funcao_id, chamar_profissional.inicio_em, chamar_profissional.fim_em,
                    chamar_profissional.local, chamar_profissional.ponto, chamar_profissional.valor_centavos) > 0 then
      perform public.erro(422, 'campo_invalido', 'vaga_id');
    end if;
    select * into v_vaga from public.vaga g where g.id = chamar_profissional.vaga_id and g.estabelecimento_id = v_estab;
    if not found then perform public.erro(404, 'nao_encontrado'); end if;
    if v_vaga.origem <> 'chamada_direta' or v_vaga.estado <> 'publicada' or v_vaga.inicio_em <= v_agora
       or not exists (select 1 from public.posicao p where p.vaga_id = v_vaga.id and p.estado = 'aberta') then
      perform public.erro(409, 'vaga_encerrada');
    end if;
    if (select count(*) from public.chamada c where c.vaga_id = v_vaga.id and c.estado = 'aberta') >= 3 then
      perform public.erro(422, 'limite_de_chamadas', 'por_vaga');
    end if;
  else
    -- RN02 com os nomes de NovaVaga: o primeiro campo que falta vai em details.
    select k into v_falta
      from jsonb_each(jsonb_build_object(
             'funcao_id', chamar_profissional.funcao_id, 'inicio_em', chamar_profissional.inicio_em,
             'fim_em', chamar_profissional.fim_em, 'local', nullif(btrim(chamar_profissional.local), ''),
             'regiao_administrativa', nullif(btrim(chamar_profissional.regiao_administrativa), ''),
             'ponto', chamar_profissional.ponto, 'valor_centavos', chamar_profissional.valor_centavos,
             'inclui_refeicao', chamar_profissional.inclui_refeicao,
             'inclui_transporte', chamar_profissional.inclui_transporte,
             'exige_material_proprio', chamar_profissional.exige_material_proprio,
             'responsavel_local', nullif(btrim(chamar_profissional.responsavel_local), ''))) e(k, val)
     where val = 'null'::jsonb order by k limit 1;
    if v_falta is not null then perform public.erro(422, 'campo_obrigatorio', v_falta); end if;
    if chamar_profissional.valor_centavos <= 0 then perform public.erro(422, 'campo_invalido', 'valor_centavos'); end if;
    if not exists (select 1 from public.funcao f where f.id = chamar_profissional.funcao_id) then
      perform public.erro(422, 'campo_invalido', 'funcao_id');
    end if;
    if chamar_profissional.fim_em <= chamar_profissional.inicio_em or chamar_profissional.inicio_em <= v_agora then
      perform public.erro(422, 'horario_invalido');
    end if;
    perform privado.exigir_texto_aceitavel(jsonb_build_object(
      'local', btrim(chamar_profissional.local), 'regiao_administrativa', btrim(chamar_profissional.regiao_administrativa),
      'responsavel_local', btrim(chamar_profissional.responsavel_local)));
    v_vaga.funcao_id := chamar_profissional.funcao_id;
    v_vaga.inicio_em := chamar_profissional.inicio_em;
  end if;

  -- RN28 na v1.1: só quem já cumpriu turno com presença verificada na casa, ou está na
  -- equipe de confiança. Sem vínculo, a mesma recusa genérica, sem revelar o motivo.
  v_veterana := exists (select 1 from public.turno t join public.posicao p on p.id = t.posicao_id
                          join public.vaga g on g.id = p.vaga_id
                         where g.estabelecimento_id = v_estab and p.profissional_id = v_prof
                           and p.estado = 'cumprida' and t.verificacao = 'verificado');
  if not v_veterana and not exists (select 1 from public.equipe_confianca q
                                      where q.estabelecimento_id = v_estab and q.profissional_id = v_prof) then
    perform public.erro(422, 'profissional_indisponivel', 'nao_aceita_chamadas');
  end if;
  if not exists (select 1 from public.profissional_funcao pf
                  where pf.profissional_id = v_prof and pf.funcao_id = v_vaga.funcao_id) then
    perform public.erro(422, 'inelegivel', 'funcao_incompativel');
  end if;
  if v_vaga.inicio_em < v_agora + interval '2 hours' then
    perform public.erro(422, 'profissional_indisponivel', 'antecedencia_insuficiente');
  end if;
  if (select count(*) from public.chamada c where c.profissional_id = v_prof and c.estado = 'aberta') >= 5 then
    perform public.erro(422, 'profissional_indisponivel', 'agenda_cheia');
  end if;

  -- RN34, por estabelecimento somando os membros. Cancelar não devolve cota.
  if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab and c.estado = 'aberta') >= 10 then
    perform public.erro(422, 'limite_de_chamadas', 'abertas');
  end if;
  if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab
         and (c.criada_em at time zone 'America/Sao_Paulo')::date = (v_agora at time zone 'America/Sao_Paulo')::date) >= 20 then
    perform public.erro(422, 'limite_de_chamadas', 'por_dia');
  end if;

  if v_recado is not null then
    if length(v_recado) > 300 then perform public.erro(422, 'campo_invalido', 'recado'); end if;
    perform privado.exigir_texto_aceitavel(jsonb_build_object('recado', v_recado));
  end if;

  -- J7, RN45: a 3ª chamada de casa CPF ao mesmo profissional em 7 dias pede confirmação.
  if length((select e.documento from public.estabelecimento e where e.id = v_estab)) = 11
     and not coalesce(chamar_profissional.confirmo_recorrencia, false)
     and (select count(*) from public.chamada c where c.estabelecimento_id = v_estab
             and c.profissional_id = v_prof and c.criada_em > v_agora - interval '7 days') >= 2 then
    perform public.erro(409, 'recorrencia_nao_confirmada');
  end if;

  if chamar_profissional.vaga_id is null then
    insert into public.vaga (
      estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa, ponto,
      valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
      responsavel_local, modo, publicado_por, publicado_em, chave_cliente, origem)
    values (
      v_estab, chamar_profissional.funcao_id, chamar_profissional.inicio_em, chamar_profissional.fim_em,
      btrim(chamar_profissional.local), btrim(chamar_profissional.regiao_administrativa),
      privado.ponto_do_json(chamar_profissional.ponto, 'ponto'), chamar_profissional.valor_centavos, 1,
      chamar_profissional.inclui_refeicao, chamar_profissional.inclui_transporte,
      chamar_profissional.exige_material_proprio, btrim(chamar_profissional.responsavel_local),
      'urgencia', v_uid, v_agora, chamar_profissional.chave, 'chamada_direta')
    returning * into v_vaga;
    insert into public.posicao (vaga_id, inicio_em, fim_em) values (v_vaga.id, v_vaga.inicio_em, v_vaga.fim_em);
  end if;

  begin
    insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, recado,
                                expira_em, criada_em, chave)
    values (v_vaga.id, v_prof, v_estab, v_uid, v_recado,
            least(v_agora + interval '12 hours', v_vaga.inicio_em - interval '1 hour'), v_agora,
            chamar_profissional.chave)
    returning * into v_c;
  exception when unique_violation then
    perform public.erro(409, 'chamada_ja_aberta');
  end;
  return to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em'];
end $$;

comment on function public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean) is
  'Chamada direta (0.2.55, RN28 a RN34, RN38, RN45, RN46). Cria vaga de uma posição com origem chamada_direta, nunca despachada nem listada, ou chama mais alguém para uma vaga direta aberta. Idempotente pela chave. Desligada por privado.recurso.';
revoke execute on function public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean) from public, anon;
grant  execute on function public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean) to authenticated;

-- ── 5. Fora da lista e fora da tabela para terceiros (0.2.55) ────────────────
-- Profissional só lê pela tabela a vaga direta em que ocupa posição; membro da casa, como antes.
drop policy vaga_leitura on public.vaga;
create policy vaga_leitura on public.vaga for select to authenticated
  using (
    privado.mesma_populacao(publicado_por)
    and (
          privado.eh_membro(estabelecimento_id)
       or ((select privado.perfil_da_conta()) = 'profissional'
           and (   privado.ocupa_posicao_na_vaga(id)
                or (origem = 'publicacao'
                    and not privado.bloqueado_com_estabelecimento((select auth.uid()), estabelecimento_id)
                    and ((estado = 'publicada' and not privado.vaga_oculta(id))
                         or privado.candidatou_na_vaga(id)))))));

-- Igual à de 20260929230000, mais `v.origem = 'publicacao'`: vaga direta nunca é listada.
create or replace function public.vagas_abertas(
  latitude numeric default null, longitude numeric default null, funcao_id uuid default null,
  data date default null, distancia_max_km numeric default null,
  limite int default 30, deslocamento int default 0
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
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  perform privado.exigir_perfil('profissional');
  if vagas_abertas.limite is null or vagas_abertas.limite < 1 or vagas_abertas.limite > 100 then
    perform public.erro(422, 'campo_invalido', 'limite');
  end if;
  if vagas_abertas.deslocamento is null or vagas_abertas.deslocamento < 0 then
    perform public.erro(422, 'campo_invalido', 'deslocamento');
  end if;
  if vagas_abertas.latitude is not null or vagas_abertas.longitude is not null then
    v_ref := privado.ponto_do_json(
      jsonb_build_object('latitude', vagas_abertas.latitude, 'longitude', vagas_abertas.longitude), 'latitude');
  else
    select p.ponto_base into v_ref from public.profissional p where p.usuario_id = v_uid;
    if v_ref is null then perform public.erro(422, 'campo_obrigatorio', 'latitude'); end if;
  end if;
  v_demo := privado.conta_de_demonstracao();
  v_raio := case when vagas_abertas.distancia_max_km is null then null else vagas_abertas.distancia_max_km * 1000 end;

  return coalesce((
    select jsonb_agg(item order by ordem)
      from (
        select jsonb_build_object(
                 'id', v.id, 'funcao', privado.funcao_em_json(f.*),
                 'estabelecimento', privado.estabelecimento_publico(v.estabelecimento_id),
                 'inicio_em', v.inicio_em, 'fim_em', v.fim_em, 'local', v.local,
                 'regiao_administrativa', v.regiao_administrativa,
                 'distancia_km', round((extensions.st_distance(v.ponto, v_ref) / 1000)::numeric, 2),
                 'valor_centavos', v.valor_centavos,
                 'posicoes_abertas', privado.posicoes_candidataveis(v.id, v_agora),
                 'inclusos', privado.inclusos_em_json(v.*), 'modo', v.modo) as item,
               row_number() over (order by v.ponto operator(extensions.<->) v_ref, v.id) as ordem
          from public.vaga v
          join public.funcao f  on f.id = v.funcao_id
          join public.usuario u on u.id = v.publicado_por
         where v.estado = 'publicada'
           and v.origem = 'publicacao'
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
  'Vagas abertas ordenadas por distância até o ponto informado, ou até o ponto base (RF07, RN05). A ordem não pode ser comprada (RN06); vaga de estabelecimento com bloqueio some (RF26), a ocultada pela Equipe Frila também (Diretriz 1.2), e a vaga direta (origem chamada_direta, 0.2.55) nunca entra. Vaga já começada some, salvo a com posição reaberta por atraso antes de fim − 1 h (contrato 0.2.19).';
