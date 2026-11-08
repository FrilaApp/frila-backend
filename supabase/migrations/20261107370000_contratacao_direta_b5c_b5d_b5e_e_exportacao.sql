-- 20261107370000_contratacao_direta_b5c_b5d_b5e_e_exportacao.sql
--
-- Contratação Direta (Fatia F4, DOC5a, DOC5b, OpenAPI 0.2.56, 0.2.58, 0.2.59, RN30 a RN36, RN43, RN45, RN46).
--   * B5e: public.profissional_preferencia_chamada e public.definir_preferencia_chamadas; versao_app em public.dispositivo.
--   * B5c: Prazos e lembretes respeitando horário de silêncio (America/Sao_Paulo); privado.expirar_chamadas e privado.lembrar_chamadas; notificações de chamada.
--   * B5d: Limites atômicos de par (CD-C13), casa sem turnos (CD-C14) e aviso J7; public.minhas_chamadas, public.detalhe_chamada e public.publicar_a_partir_da_chamada.
--   * Exportação LGPD: consolidação de privado.meus_dados com PerfilProfissionalDetalhado (0.2.58), chamadas (0.2.59) e mídias (0.2.59).

-- ── 1. Preferências de chamada do profissional (B5e, RN30, RN43) ───────────────
create table if not exists public.profissional_preferencia_chamada (
  profissional_id              uuid primary key references public.profissional(id) on delete cascade,
  aceita_de_quem_ja_trabalhou  boolean not null default true,
  pausado_ate                  date check (pausado_ate is null or pausado_ate >= current_date),
  antecedencia_minima_h        int not null default 6 check (antecedencia_minima_h in (2, 6, 24, 48)),
  aceita_de                    text not null default 'todos' check (aceita_de in ('todos', 'so_cnpj')),
  atualizado_em                timestamptz not null default now()
);

alter table public.profissional_preferencia_chamada enable row level security;
revoke all on table public.profissional_preferencia_chamada from public, anon, authenticated;

comment on table public.profissional_preferencia_chamada is
  'Preferências configuradas pelo profissional para recebimento de chamadas diretas (RN30, RN43, DOC5b).';

-- Coluna versao_app em public.dispositivo (B5e, CD-RF13)
alter table public.dispositivo
  add column if not exists versao_app text check (versao_app is null or length(versao_app) <= 32);

comment on column public.dispositivo.versao_app is
  'Versão declarada do app no momento do registro. Usada para filtrar envio de pushes de recursos novos como chamada direta.';

-- Coluna vaga_origem_id em public.vaga (B5d, contrato 0.2.56, RN35)
alter table public.vaga
  add column if not exists vaga_origem_id uuid references public.vaga(id) on delete set null;

comment on column public.vaga.vaga_origem_id is
  'Vaga direta original a partir da qual esta vaga pública foi convertida (0.2.56, RN35).';

-- Atualiza public.registrar_dispositivo para persistir versao_app (dropa versões antigas)
drop function if exists public.registrar_dispositivo(text, text);
drop function if exists public.registrar_dispositivo(text, text, text);

create or replace function public.registrar_dispositivo(
  token_fcm text default null,
  plataforma text default null,
  versao_app text default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid         uuid := (select auth.uid());
  v_agora       timestamptz := privado.agora();
  v_token       text := pg_catalog.btrim(registrar_dispositivo.token_fcm);
  v_plataforma  public.plataforma;
  v_versao      text := nullif(pg_catalog.btrim(registrar_dispositivo.versao_app), '');
  v_disp        public.dispositivo%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  if v_token is null or v_token = '' then
    perform public.erro(422, 'campo_obrigatorio', 'token_fcm');
  end if;

  if pg_catalog.length(v_token) < 20 or pg_catalog.length(v_token) > 4096 then
    perform public.erro(422, 'campo_invalido', 'token_fcm');
  end if;

  if registrar_dispositivo.plataforma is null
     or pg_catalog.btrim(registrar_dispositivo.plataforma) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'plataforma');
  end if;

  if not registrar_dispositivo.plataforma
         = any (pg_catalog.enum_range(null::public.plataforma)::text[]) then
    perform public.erro(422, 'campo_invalido', 'plataforma');
  end if;

  v_plataforma := registrar_dispositivo.plataforma::public.plataforma;

  if v_versao is not null and pg_catalog.length(v_versao) > 32 then
    perform public.erro(422, 'campo_invalido', 'versao_app');
  end if;

  insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app, atualizado_em, vinculo_id)
  values (v_uid, v_token, v_plataforma, v_versao, v_agora, gen_random_uuid())
  on conflict (token_fcm) do update
    set usuario_id    = excluded.usuario_id,
        plataforma    = excluded.plataforma,
        versao_app    = coalesce(excluded.versao_app, public.dispositivo.versao_app),
        atualizado_em = excluded.atualizado_em,
        vinculo_id    = case
          when public.dispositivo.usuario_id = excluded.usuario_id then public.dispositivo.vinculo_id
          else gen_random_uuid()
        end
  returning * into v_disp;

  return pg_catalog.jsonb_build_object(
    'plataforma',    v_disp.plataforma,
    'atualizado_em', v_disp.atualizado_em,
    'vinculo_id',    v_disp.vinculo_id
  );
end $$;

comment on function public.registrar_dispositivo(text, text, text) is
  'Registra ou atualiza o token de push do aparelho vinculado à conta com versão do app opcional (0.2.30, 0.2.56, RN15).';
revoke execute on function public.registrar_dispositivo(text, text, text) from public, anon;
grant  execute on function public.registrar_dispositivo(text, text, text) to authenticated;

-- RPC public.definir_preferencia_chamadas (B5e, contrato 0.2.56)
create or replace function public.definir_preferencia_chamadas(
  aceita_de_quem_ja_trabalhou boolean default null,
  pausado_ate date default null,
  antecedencia_minima_h int default null,
  aceita_de text default null,
  remover_pausa boolean default false
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_prof_id   uuid;
  v_agora_sp  date := (privado.agora() at time zone 'America/Sao_Paulo')::date;
  v_pref      public.profissional_preferencia_chamada%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;

  perform privado.exigir_perfil('profissional');

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  select id into v_prof_id from public.profissional where usuario_id = v_uid;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if aceita_de_quem_ja_trabalhou is null
     and pausado_ate is null
     and antecedencia_minima_h is null
     and aceita_de is null
     and not remover_pausa then
    perform public.erro(422, 'campo_obrigatorio', 'nenhum_campo');
  end if;

  if pausado_ate is not null and pausado_ate < v_agora_sp then
    perform public.erro(422, 'campo_invalido', 'pausado_ate');
  end if;

  if antecedencia_minima_h is not null and antecedencia_minima_h not in (2, 6, 24, 48) then
    perform public.erro(422, 'campo_invalido', 'antecedencia_minima_h');
  end if;

  if aceita_de is not null and aceita_de not in ('todos', 'so_cnpj') then
    perform public.erro(422, 'campo_invalido', 'aceita_de');
  end if;

  insert into public.profissional_preferencia_chamada (
    profissional_id, aceita_de_quem_ja_trabalhou, pausado_ate, antecedencia_minima_h, aceita_de, atualizado_em
  )
  values (
    v_prof_id,
    coalesce(aceita_de_quem_ja_trabalhou, true),
    case when remover_pausa then null else pausado_ate end,
    coalesce(antecedencia_minima_h, 6),
    coalesce(aceita_de, 'todos'),
    now()
  )
  on conflict (profissional_id) do update
    set aceita_de_quem_ja_trabalhou = coalesce(definir_preferencia_chamadas.aceita_de_quem_ja_trabalhou, public.profissional_preferencia_chamada.aceita_de_quem_ja_trabalhou),
        pausado_ate                 = case when remover_pausa then null
                                           when definir_preferencia_chamadas.pausado_ate is not null then definir_preferencia_chamadas.pausado_ate
                                           else public.profissional_preferencia_chamada.pausado_ate end,
        antecedencia_minima_h       = coalesce(definir_preferencia_chamadas.antecedencia_minima_h, public.profissional_preferencia_chamada.antecedencia_minima_h),
        aceita_de                   = coalesce(definir_preferencia_chamadas.aceita_de, public.profissional_preferencia_chamada.aceita_de),
        atualizado_em               = now()
  returning * into v_pref;

  return jsonb_build_object(
    'aceita_de_quem_ja_trabalhou', v_pref.aceita_de_quem_ja_trabalhou,
    'pausado_ate',                 v_pref.pausado_ate,
    'antecedencia_minima_h',       v_pref.antecedencia_minima_h,
    'aceita_de',                   v_pref.aceita_de
  );
end $$;

comment on function public.definir_preferencia_chamadas(boolean, date, int, text, boolean) is
  '0.2.56. Preferências do profissional para receber chamadas diretas (RN30, RN43, RN46).';
revoke execute on function public.definir_preferencia_chamadas(boolean, date, int, text, boolean) from public, anon;
grant  execute on function public.definir_preferencia_chamadas(boolean, date, int, text, boolean) to authenticated;

-- ── 2. Função chamar_profissional ampliada com B5c, B5d e B5e ─────────────────
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
  v_uid            uuid := (select auth.uid());
  v_agora          timestamptz := privado.agora();
  v_estab          uuid := chamar_profissional.estabelecimento_id;
  v_prof           uuid := chamar_profissional.profissional_id;
  v_recado         text := nullif(btrim(chamar_profissional.recado), '');
  v_conta          public.usuario%rowtype;
  v_vaga           public.vaga%rowtype;
  v_c              public.chamada%rowtype;
  v_falta          text;
  v_veterana       boolean;
  v_pref           public.profissional_preferencia_chamada%rowtype;
  v_ant_min_h      int := 6;
  v_casa_doc       text;
  v_turnos_casa    int;
  v_hora_sp        int;
  v_inicio_prazo   timestamptz;
  v_expira_em      timestamptz;
  v_lembrete_em    timestamptz;
  v_janela_efetiva interval;
  v_ultimas_recusas int;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
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
  -- Serializa também pelo profissional para atomicidade da cota de abertas entre casas distintas (CD-C14)
  perform 1 from public.profissional p where p.id = v_prof for update;
  if exists (select 1 from public.chamada c where c.estabelecimento_id = v_estab
                and c.profissional_id = v_prof and c.estado = 'aberta') then
    perform public.erro(409, 'chamada_ja_aberta');
  end if;

  -- Lê documento da casa
  select documento into v_casa_doc from public.estabelecimento where id = v_estab;

  -- Preferências do profissional (B5e)
  select * into v_pref from public.profissional_preferencia_chamada where profissional_id = v_prof;
  if found then
    v_ant_min_h := v_pref.antecedencia_minima_h;
    -- Pausa de chamadas
    if v_pref.pausado_ate is not null and v_pref.pausado_ate >= (v_agora at time zone 'America/Sao_Paulo')::date then
      perform public.erro(422, 'profissional_indisponivel', 'pausado');
    end if;
    -- Aceita somente de CNPJ
    if v_pref.aceita_de = 'so_cnpj' and length(v_casa_doc) = 11 then
      perform public.erro(422, 'profissional_indisponivel', 'nao_aceita_chamadas');
    end if;
  end if;

  -- Limites de par CD-C13 (B5d):
  -- 1. Se houve recusa há menos de 24h, o par está em pausa de 24h.
  if exists (
    select 1 from public.chamada c
     where c.estabelecimento_id = v_estab
       and c.profissional_id = v_prof
       and c.estado = 'recusada'
       and c.respondida_em > v_agora - interval '24 hours'
  ) then
    perform public.erro(422, 'profissional_indisponivel', 'par_em_pausa');
  end if;

  -- 2. Três recusadas/expiradas consecutivas em 30 dias bloqueiam o par por 30 dias
  select count(*) into v_ultimas_recusas
    from (
      select c.estado
        from public.chamada c
       where c.estabelecimento_id = v_estab
         and c.profissional_id = v_prof
         and c.criada_em > v_agora - interval '30 days'
         and c.estado in ('aceita', 'recusada', 'expirada')
       order by c.criada_em desc
       limit 3
    ) u
   where u.estado in ('recusada', 'expirada');

  if v_ultimas_recusas = 3 and not exists (
    select 1 from public.chamada c
     where c.estabelecimento_id = v_estab
       and c.profissional_id = v_prof
       and c.criada_em > v_agora - interval '30 days'
       and c.estado = 'aceita'
  ) then
    perform public.erro(422, 'profissional_indisponivel', 'par_bloqueado_temporariamente');
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

  -- RN28 na v1.1: só quem já cumpriu turno com presença verificada na casa, ou está na equipe de confiança.
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

  -- Antecedência mínima respeitando a escolha do profissional (mínimo 2h)
  if v_vaga.inicio_em < v_agora + (v_ant_min_h || ' hours')::interval then
    perform public.erro(422, 'profissional_indisponivel', 'antecedencia_insuficiente');
  end if;

  -- Limite do profissional: máximo 5 abertas
  if (select count(*) from public.chamada c where c.profissional_id = v_prof and c.estado = 'aberta') >= 5 then
    perform public.erro(422, 'profissional_indisponivel', 'agenda_cheia');
  end if;

  -- Turnos verificados da casa (CD-C14)
  select count(*) into v_turnos_casa
    from public.turno t
    join public.posicao pos on pos.id = t.posicao_id
    join public.vaga vg on vg.id = pos.vaga_id
   where vg.estabelecimento_id = v_estab
     and pos.estado = 'cumprida'
     and t.verificacao = 'verificado';

  if v_turnos_casa = 0 then
    -- Casa sem turno cumprido: máximo 3 abertas e máximo 5 em 7 dias
    if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab and c.estado = 'aberta') >= 3 then
      perform public.erro(422, 'limite_de_chamadas', 'abertas');
    end if;
    if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab
           and c.criada_em > v_agora - interval '7 days') >= 5 then
      perform public.erro(422, 'limite_de_chamadas', 'por_semana');
    end if;
  else
    -- Casa com turnos: máximo 10 abertas e 20 por dia civil de SP
    if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab and c.estado = 'aberta') >= 10 then
      perform public.erro(422, 'limite_de_chamadas', 'abertas');
    end if;
    if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab
           and (c.criada_em at time zone 'America/Sao_Paulo')::date = (v_agora at time zone 'America/Sao_Paulo')::date) >= 20 then
      perform public.erro(422, 'limite_de_chamadas', 'por_dia');
    end if;
  end if;

  if v_recado is not null then
    if length(v_recado) > 300 then perform public.erro(422, 'campo_invalido', 'recado'); end if;
    perform privado.exigir_texto_aceitavel(jsonb_build_object('recado', v_recado));
  end if;

  -- J7, RN45: a 3ª chamada de casa CPF ao mesmo profissional em 7 dias pede confirmação explícita.
  if length(v_casa_doc) = 11
     and not coalesce(chamar_profissional.confirmo_recorrencia, false)
     and (select count(*) from public.chamada c where c.estabelecimento_id = v_estab
             and c.profissional_id = v_prof and c.criada_em > v_agora - interval '7 days') >= 2 then
    perform public.erro(409, 'recorrencia_nao_confirmada');
  end if;

  -- Cálculo de prazos e lembretes respeitando horário de silêncio em America/Sao_Paulo (B5c)
  v_hora_sp := extract(hour from (v_agora at time zone 'America/Sao_Paulo'))::int;
  if v_hora_sp >= 22 or v_hora_sp < 7 then
    -- No silêncio (22h às 7h): conta a partir das 7h
    v_inicio_prazo := ((v_agora at time zone 'America/Sao_Paulo')::date +
                       (case when v_hora_sp >= 22 then interval '1 day 7 hours' else interval '7 hours' end))
                      at time zone 'America/Sao_Paulo';
    -- Salvo se início da vaga for antes das 10h em SP
    if v_vaga.inicio_em < (v_inicio_prazo + interval '3 hours') then
      v_expira_em := v_vaga.inicio_em - interval '1 hour';
    else
      v_expira_em := least(v_inicio_prazo + interval '12 hours', v_vaga.inicio_em - interval '1 hour');
    end if;
  else
    -- Fora do silêncio
    v_inicio_prazo := v_agora;
    v_expira_em := least(v_agora + interval '12 hours', v_vaga.inicio_em - interval '1 hour');
  end if;

  -- Lembrete: se janela efetiva de resposta for maior que 2h, agenda no ponto médio
  v_janela_efetiva := v_expira_em - v_inicio_prazo;
  if v_janela_efetiva > interval '2 hours' then
    v_lembrete_em := v_inicio_prazo + (v_janela_efetiva / 2);
    -- Se cair no silêncio (22h às 7h), ajusta para fora do silêncio
    if extract(hour from (v_lembrete_em at time zone 'America/Sao_Paulo'))::int >= 22 then
      v_lembrete_em := least(
        ((v_lembrete_em at time zone 'America/Sao_Paulo')::date + interval '21 hours 30 minutes') at time zone 'America/Sao_Paulo',
        v_expira_em - interval '30 minutes'
      );
      if v_lembrete_em <= v_inicio_prazo then
        v_lembrete_em := ((v_lembrete_em at time zone 'America/Sao_Paulo')::date + interval '1 day 7 hours') at time zone 'America/Sao_Paulo';
      end if;
    elsif extract(hour from (v_lembrete_em at time zone 'America/Sao_Paulo'))::int < 7 then
      v_lembrete_em := ((v_lembrete_em at time zone 'America/Sao_Paulo')::date + interval '7 hours') at time zone 'America/Sao_Paulo';
    end if;
    if v_lembrete_em >= v_expira_em then
      v_lembrete_em := null;
    end if;
  else
    v_lembrete_em := null;
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
                                expira_em, lembrete_em, criada_em, chave)
    values (v_vaga.id, v_prof, v_estab, v_uid, v_recado,
            v_expira_em, v_lembrete_em, v_agora, chamar_profissional.chave)
    returning * into v_c;
  exception when unique_violation then
    perform public.erro(409, 'chamada_ja_aberta');
  end;

  -- Notificação chamada_recebida (B5c)
  insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
  values (v_conta.id, 'chamada_recebida', v_c.id, jsonb_build_object('chamada_id', v_c.id, 'vaga_id', v_vaga.id))
  on conflict do nothing;

  return to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em'];
end $$;

-- ── 3. Funções de automação de prazos e lembretes (B5c) ────────────────────────
create or replace function privado.expirar_chamadas()
returns int
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_count   int := 0;
  r         record;
  v_membro  uuid;
begin
  for r in
    select c.id, c.vaga_id, c.estabelecimento_id, p.usuario_id as prof_usuario_id
      from public.chamada c
      join public.profissional p on p.id = c.profissional_id
     where c.estado = 'aberta'
       and c.expira_em <= v_agora
     order by c.expira_em
     for update of c
  loop
    update public.chamada
       set estado = 'expirada',
           respondida_em = v_agora
     where id = r.id;

    -- Notifica o profissional
    insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
    values (r.prof_usuario_id, 'chamada_expirada', r.id, jsonb_build_object('chamada_id', r.id, 'vaga_id', r.vaga_id))
    on conflict do nothing;

    -- Notifica os membros do estabelecimento
    for v_membro in
      select me.usuario_id from public.membro_estabelecimento me where me.estabelecimento_id = r.estabelecimento_id
    loop
      insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
      values (v_membro, 'chamada_expirada', r.id, jsonb_build_object('chamada_id', r.id, 'vaga_id', r.vaga_id))
      on conflict do nothing;
    end loop;

    -- Encerra vaga direta se não houver mais chamadas abertas nem turnos
    if not exists (select 1 from public.chamada x where x.vaga_id = r.vaga_id and x.estado = 'aberta')
       and not exists (select 1 from public.turno t join public.posicao pos on pos.id = t.posicao_id where pos.vaga_id = r.vaga_id) then
      update public.vaga set estado = 'encerrada' where id = r.vaga_id and estado = 'publicada' and origem = 'chamada_direta';
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end $$;

comment on function privado.expirar_chamadas() is
  'Expira chamadas cujo prazo venceu (expira_em <= now()), emitindo notificações chamada_expirada (RN31, RN33, B5c).';
revoke all on function privado.expirar_chamadas() from public, anon, authenticated;
grant execute on function privado.expirar_chamadas() to service_role;

create or replace function privado.lembrar_chamadas()
returns int
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_hora_sp int         := extract(hour from (v_agora at time zone 'America/Sao_Paulo'))::int;
  v_count   int         := 0;
  r         record;
begin
  -- Não dispara lembretes durante o horário de silêncio (22h às 7h horário de Brasília)
  if v_hora_sp >= 22 or v_hora_sp < 7 then
    return 0;
  end if;

  for r in
    select c.id, c.vaga_id, c.expira_em, p.usuario_id as prof_usuario_id
      from public.chamada c
      join public.profissional p on p.id = c.profissional_id
     where c.estado = 'aberta'
       and c.lembrete_em is not null
       and c.lembrete_em <= v_agora
     order by c.lembrete_em
     for update of c
  loop
    update public.chamada
       set lembrete_em = null
     where id = r.id;

    -- Só notifica se a chamada ainda não tiver expirado
    if r.expira_em > v_agora then
      insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
      values (r.prof_usuario_id, 'chamada_lembrete', r.id, jsonb_build_object('chamada_id', r.id, 'vaga_id', r.vaga_id))
      on conflict do nothing;

      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end $$;

comment on function privado.lembrar_chamadas() is
  'Dispara lembrete único para chamadas com lembrete_em atingido (RN31, CD-RF11, B5c).';
revoke all on function privado.lembrar_chamadas() from public, anon, authenticated;
grant execute on function privado.lembrar_chamadas() to service_role;

-- ── 4. RPCs de Leitura de Chamada (B5d, contrato 0.2.56) ───────────────────────
create or replace function public.minhas_chamadas(
  estado text default null,
  cursor text default null,
  limite int default 20
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_perfil    text;
  v_prof_id   uuid;
  v_limite    int := coalesce(minhas_chamadas.limite, 20);
  v_cursor_ts timestamptz;
  v_cursor_id uuid;
  v_itens     jsonb := '[]'::jsonb;
  v_prox      text := null;
  r           record;
  v_cont      int := 0;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  select perfil into v_perfil from public.usuario where id = v_uid;
  if v_perfil is null then perform public.erro(404, 'nao_encontrado'); end if;

  if v_limite < 1 or v_limite > 20 then
    perform public.erro(422, 'campo_invalido', 'limite');
  end if;

  if minhas_chamadas.estado is not null
     and minhas_chamadas.estado not in ('aberta', 'aceita', 'recusada', 'expirada', 'cancelada', 'encerrada') then
    perform public.erro(422, 'campo_invalido', 'estado');
  end if;

  if minhas_chamadas.cursor is not null then
    begin
      v_cursor_ts := (split_part(convert_from(decode(minhas_chamadas.cursor, 'base64'), 'UTF8'), '#', 1))::timestamptz;
      v_cursor_id := (split_part(convert_from(decode(minhas_chamadas.cursor, 'base64'), 'UTF8'), '#', 2))::uuid;
    exception when others then
      perform public.erro(422, 'cursor_invalido');
    end;
    if v_cursor_ts is null or v_cursor_id is null then
      perform public.erro(422, 'cursor_invalido');
    end if;
  end if;

  if v_perfil = 'profissional' then
    select id into v_prof_id from public.profissional where usuario_id = v_uid;
    for r in
      select c.*, v.funcao_id, v.inicio_em, v.fim_em, v.valor_centavos, f.nome as funcao_nome, f.categoria as funcao_categoria
        from public.chamada c
        join public.vaga v on v.id = c.vaga_id
        join public.funcao f on f.id = v.funcao_id
       where c.profissional_id = v_prof_id
         and (minhas_chamadas.estado is null or c.estado = minhas_chamadas.estado)
         and not privado.bloqueado_com_estabelecimento(v_uid, c.estabelecimento_id)
         and (v_cursor_ts is null or (c.criada_em, c.id) < (v_cursor_ts, v_cursor_id))
       order by c.criada_em desc, c.id desc
       limit (v_limite + 1)
    loop
      v_cont := v_cont + 1;
      if v_cont <= v_limite then
        v_itens := v_itens || jsonb_build_array(
          jsonb_build_object(
            'id',                 r.id,
            'vaga_id',            r.vaga_id,
            'profissional_id',    r.profissional_id,
            'estabelecimento_id', r.estabelecimento_id,
            'estado',             r.estado,
            'recado',             r.recado,
            'motivo_recusa',      r.motivo_recusa,
            'expira_em',          r.expira_em,
            'respondida_em',      r.respondida_em,
            'criada_em',          r.criada_em,
            'funcao',             jsonb_build_object('id', r.funcao_id, 'nome', r.funcao_nome, 'categoria', r.funcao_categoria),
            'inicio_em',          r.inicio_em,
            'fim_em',             r.fim_em,
            'valor_centavos',     r.valor_centavos,
            'outra_parte',        privado.estabelecimento_publico(r.estabelecimento_id)
          )
        );
      else
        v_prox := encode(convert_to(r.criada_em::text || '#' || r.id::text, 'UTF8'), 'base64');
      end if;
    end loop;
  else
    -- Contratante: chamadas das casas de que é membro
    for r in
      select c.*, v.funcao_id, v.inicio_em, v.fim_em, v.valor_centavos, f.nome as funcao_nome, f.categoria as funcao_categoria
        from public.chamada c
        join public.vaga v on v.id = c.vaga_id
        join public.funcao f on f.id = v.funcao_id
        join public.membro_estabelecimento me on me.estabelecimento_id = c.estabelecimento_id
       where me.usuario_id = v_uid
         and (minhas_chamadas.estado is null or c.estado = minhas_chamadas.estado)
         and not privado.bloqueado_com_estabelecimento(privado.usuario_do_profissional(c.profissional_id), c.estabelecimento_id)
         and (v_cursor_ts is null or (c.criada_em, c.id) < (v_cursor_ts, v_cursor_id))
       order by c.criada_em desc, c.id desc
       limit (v_limite + 1)
    loop
      v_cont := v_cont + 1;
      if v_cont <= v_limite then
        v_itens := v_itens || jsonb_build_array(
          jsonb_build_object(
            'id',                 r.id,
            'vaga_id',            r.vaga_id,
            'profissional_id',    r.profissional_id,
            'estabelecimento_id', r.estabelecimento_id,
            'estado',             r.estado,
            'recado',             r.recado,
            'motivo_recusa',      r.motivo_recusa,
            'expira_em',          r.expira_em,
            'respondida_em',      r.respondida_em,
            'criada_em',          r.criada_em,
            'funcao',             jsonb_build_object('id', r.funcao_id, 'nome', r.funcao_nome, 'categoria', r.funcao_categoria),
            'inicio_em',          r.inicio_em,
            'fim_em',             r.fim_em,
            'valor_centavos',     r.valor_centavos,
            'outra_parte',        privado.perfil_publico_profissional(r.profissional_id)
          )
        );
      else
        v_prox := encode(convert_to(r.criada_em::text || '#' || r.id::text, 'UTF8'), 'base64');
      end if;
    end loop;
  end if;

  return jsonb_build_object('itens', v_itens, 'proximo_cursor', v_prox);
end $$;

comment on function public.minhas_chamadas(text, text, int) is
  '0.2.56. Lista as chamadas recebidas (profissional) ou enviadas (contratante) paginadas por cursor opaco (RN46).';
revoke execute on function public.minhas_chamadas(text, text, int) from public, anon;
grant  execute on function public.minhas_chamadas(text, text, int) to authenticated;

create or replace function public.detalhe_chamada(chamada_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid         uuid := (select auth.uid());
  v_c           public.chamada%rowtype;
  v_v           public.vaga%rowtype;
  v_f           public.funcao%rowtype;
  v_e           public.estabelecimento%rowtype;
  v_prof        public.profissional%rowtype;
  v_eh_prof     boolean := false;
  v_eh_membro   boolean := false;
  v_dist_m      double precision;
  v_faixa       text := null;
  v_conta_nova  boolean;
  v_outra_parte jsonb;
  v_res         jsonb;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;
  if detalhe_chamada.chamada_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'chamada_id');
  end if;

  select * into v_c from public.chamada where id = detalhe_chamada.chamada_id;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;

  select * into v_v from public.vaga where id = v_c.vaga_id;
  select * into v_f from public.funcao where id = v_v.funcao_id;
  select * into v_e from public.estabelecimento where id = v_c.estabelecimento_id;
  select * into v_prof from public.profissional where id = v_c.profissional_id;

  if v_prof.usuario_id = v_uid then v_eh_prof := true; end if;
  if privado.eh_membro(v_c.estabelecimento_id) then v_eh_membro := true; end if;

  -- Apenas as partes autorizadas e sem bloqueio mútuo (RF26)
  if (not v_eh_prof and not v_eh_membro)
     or privado.bloqueado_com_estabelecimento(v_prof.usuario_id, v_c.estabelecimento_id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Conta nova se estabelecimento não tem turnos cumpridos/verificados
  v_conta_nova := not exists (
    select 1 from public.turno t
      join public.posicao pos on pos.id = t.posicao_id
      join public.vaga vg on vg.id = pos.vaga_id
     where vg.estabelecimento_id = v_c.estabelecimento_id
       and pos.estado = 'cumprida'
       and t.verificacao = 'verificado'
  );

  if v_eh_prof then
    v_outra_parte := privado.estabelecimento_publico(v_c.estabelecimento_id);
    if v_prof.ponto_base is not null and v_v.ponto is not null then
      v_dist_m := extensions.st_distance(v_prof.ponto_base, v_v.ponto);
      if v_dist_m <= 5000 then v_faixa := 'ate_5_km';
      elsif v_dist_m <= 15000 then v_faixa := 'de_5_a_15_km';
      else v_faixa := 'mais_de_15_km'; end if;
    end if;
  else
    v_outra_parte := privado.perfil_publico_profissional(v_c.profissional_id);
  end if;

  v_res := jsonb_build_object(
    'id',                     v_c.id,
    'vaga_id',                v_c.vaga_id,
    'profissional_id',        v_c.profissional_id,
    'estabelecimento_id',     v_c.estabelecimento_id,
    'estado',                 v_c.estado,
    'recado',                 v_c.recado,
    'motivo_recusa',          v_c.motivo_recusa,
    'expira_em',              v_c.expira_em,
    'respondida_em',          v_c.respondida_em,
    'criada_em',              v_c.criada_em,
    'funcao',                 jsonb_build_object('id', v_f.id, 'nome', v_f.nome, 'categoria', v_f.categoria),
    'inicio_em',              v_v.inicio_em,
    'fim_em',                 v_v.fim_em,
    'valor_centavos',         v_v.valor_centavos,
    'outra_parte',            v_outra_parte,
    'tipo_estabelecimento',   v_e.tipo,
    'conta_nova',             v_conta_nova,
    'regiao_administrativa',  v_v.regiao_administrativa,
    'distancia_faixa',        v_faixa,
    'inclui_refeicao',        v_v.inclui_refeicao,
    'inclui_transporte',      v_v.inclui_transporte,
    'exige_material_proprio', v_v.exige_material_proprio
  );

  -- Endereço e ponto só liberados com estado = 'aceita' (RN36). Nunca telefone.
  if v_c.estado = 'aceita' then
    v_res := v_res || jsonb_build_object(
      'local',             v_v.local,
      'ponto',             privado.ponto_em_json(v_v.ponto),
      'responsavel_local', v_v.responsavel_local
    );
  end if;

  return v_res;
end $$;

comment on function public.detalhe_chamada(uuid) is
  '0.2.56. Detalhe completo da chamada direta. Oculta endereço/local antes do aceite (RN36). Nunca telefone (RN10).';
revoke execute on function public.detalhe_chamada(uuid) from public, anon;
grant  execute on function public.detalhe_chamada(uuid) to authenticated;

-- ── 5. RPC public.publicar_a_partir_da_chamada (B5d, contrato 0.2.56) ──────────
create or replace function public.publicar_a_partir_da_chamada(
  vaga_id uuid default null,
  chave uuid default null,
  modo text default 'urgencia'
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_agora     timestamptz := privado.agora();
  v_orig      public.vaga%rowtype;
  v_nova      public.vaga%rowtype;
  v_pos_id    uuid;
  v_posicoes  uuid[];
  v_c         record;
  v_modo      public.modo_preenchimento := coalesce(publicar_a_partir_da_chamada.modo::public.modo_preenchimento, 'urgencia'::public.modo_preenchimento);
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
  perform privado.exigir_perfil('contratante');
  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;
  if publicar_a_partir_da_chamada.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;
  if publicar_a_partir_da_chamada.chave is null then
    perform public.erro(422, 'campo_obrigatorio', 'chave');
  end if;

  select * into v_orig from public.vaga where id = publicar_a_partir_da_chamada.vaga_id;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;
  if not privado.eh_membro(v_orig.estabelecimento_id) then perform public.erro(403, 'sem_permissao'); end if;

  -- Idempotência: reenviar a mesma chave devolve a vaga nova já convertida
  select * into v_nova from public.vaga
   where estabelecimento_id = v_orig.estabelecimento_id
     and chave_cliente = publicar_a_partir_da_chamada.chave;
  if found then
    select array_agg(p.id order by p.id) into v_posicoes from public.posicao p where p.vaga_id = v_nova.id;
    return jsonb_build_object('vaga_id', v_nova.id, 'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[])));
  end if;

  -- Se a vaga direta já foi convertida anteriormente
  select * into v_nova from public.vaga where vaga_origem_id = v_orig.id;
  if found then
    select array_agg(p.id order by p.id) into v_posicoes from public.posicao p where p.vaga_id = v_nova.id;
    return jsonb_build_object('vaga_id', v_nova.id, 'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[])));
  end if;

  if v_orig.origem <> 'chamada_direta' then
    perform public.erro(422, 'campo_invalido', 'vaga_id');
  end if;

  -- Janela de conversão: antes do início OU reaberta por atraso até fim_em - 1h (RN35)
  if v_orig.estado in ('cancelada', 'encerrada')
     or (v_orig.inicio_em <= v_agora and not exists (
           select 1 from public.posicao pos where pos.vaga_id = v_orig.id and pos.estado = 'aberta' and pos.falta
        ))
     or (v_orig.inicio_em <= v_agora and v_agora >= v_orig.fim_em - interval '1 hour') then
    perform public.erro(409, 'vaga_encerrada');
  end if;

  -- RN24: modo selecao exige antecedência de 24h
  if v_modo = 'selecao' and v_orig.inicio_em < v_agora + interval '24 hours' then
    perform public.erro(422, 'selecao_sem_antecedencia');
  end if;

  -- Cria vaga normal pública apontando para a vaga direta original
  insert into public.vaga (
    estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
    responsavel_local, modo, publicado_por, publicado_em, chave_cliente, origem, vaga_origem_id
  )
  values (
    v_orig.estabelecimento_id, v_orig.funcao_id, v_orig.inicio_em, v_orig.fim_em, v_orig.local,
    v_orig.regiao_administrativa, v_orig.ponto, v_orig.valor_centavos, 1, v_orig.inclui_refeicao,
    v_orig.inclui_transporte, v_orig.exige_material_proprio, v_orig.responsavel_local,
    v_modo, v_uid, v_agora, publicar_a_partir_da_chamada.chave, 'publicacao', v_orig.id
  )
  returning * into v_nova;

  insert into public.posicao (vaga_id, inicio_em, fim_em)
  values (v_nova.id, v_nova.inicio_em, v_nova.fim_em)
  returning id into v_pos_id;
  v_posicoes := array[v_pos_id];

  -- Encerra a vaga direta e suas chamadas abertas
  update public.vaga set estado = 'encerrada' where id = v_orig.id;

  for v_c in
    update public.chamada
       set estado = 'encerrada',
           respondida_em = v_agora
     where vaga_id = v_orig.id and estado = 'aberta'
    returning id, profissional_id
  loop
    insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
    values (
      privado.usuario_do_profissional(v_c.profissional_id),
      'chamada_encerrada',
      v_c.id,
      jsonb_build_object('chamada_id', v_c.id, 'vaga_id', v_orig.id)
    )
    on conflict do nothing;
  end loop;

  -- Enfileira despacho para a vaga nova convertida
  perform pgmq.send('despacho', jsonb_build_object(
    'vaga_id',      v_nova.id,
    'publicada_em', v_nova.publicado_em
  ));

  return jsonb_build_object('vaga_id', v_nova.id, 'posicoes', to_jsonb(v_posicoes));
end $$;

comment on function public.publicar_a_partir_da_chamada(uuid, uuid, text) is
  '0.2.56. Converte vaga direta em vaga aberta ao público com vaga_origem_id, encerrando a direta e chamadas abertas (RN35, RN46).';
revoke execute on function public.publicar_a_partir_da_chamada(uuid, uuid, text) from public, anon;
grant  execute on function public.publicar_a_partir_da_chamada(uuid, uuid, text) to authenticated;

-- ── 6. Consolidação de privado.meus_dados (0.2.58 e 0.2.59) ────────────────────
create or replace function privado.meus_dados(p_usuario uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with conta as (
    select * from public.usuario u where u.id = p_usuario
  ),
  prof as (
    select p.* from public.profissional p where p.usuario_id = p_usuario
  ),
  casas as (
    select m.estabelecimento_id, m.papel, e.nome, e.tipo
      from public.membro_estabelecimento m
      join public.estabelecimento e on e.id = m.estabelecimento_id
     where m.usuario_id = p_usuario
  )
  select jsonb_build_object(
    'gerado_em', privado.agora(),

    'conta', jsonb_build_object(
      'id',         c.id,
      'perfil',     c.perfil,
      'nome',       c.nome,
      'telefone',   c.telefone,
      'email',      c.email,
      'nascimento', c.nascimento,
      'estado',     c.estado),

    -- 0.2.58: PerfilProfissionalDetalhado completo via privado.perfil_com_servicos
    'perfil_profissional',
      (select privado.perfil_com_servicos(p) from prof p),

    'estabelecimentos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',        k.estabelecimento_id,
               'nome',      k.nome,
               'tipo',      k.tipo,
               'papel',     k.papel,
               'reputacao', privado.estabelecimento_publico(k.estabelecimento_id)->'reputacao')
             order by k.nome)
        from casas k), '[]'::jsonb),

    'disponibilidade', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dia_semana',  d.dia_semana,
               'hora_inicio', to_char(d.hora_inicio, 'HH24:MI'),
               'hora_fim',    to_char(d.hora_fim,    'HH24:MI'))
             order by d.dia_semana, d.hora_inicio)
        from public.disponibilidade d
        join prof p on p.id = d.profissional_id), '[]'::jsonb),

    'turnos', coalesce((
      select jsonb_agg(privado.turno_em_json(t.id, p_usuario) order by pos.inicio_em desc)
        from public.turno t
        join public.posicao pos on pos.id = t.posicao_id
        join public.vaga vg     on vg.id = pos.vaga_id
       where (c.perfil = 'profissional' and pos.profissional_id in (select p.id from prof p))
          or (c.perfil = 'contratante' and vg.estabelecimento_id in (select k.estabelecimento_id from casas k))), '[]'::jsonb),

    'avaliacoes_dadas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'turno_id',  a.turno_id,
               'resposta',  a.resposta,
               'criada_em', a.criada_em)
             order by a.criada_em desc)
        from public.avaliacao a
       where a.autor_id = p_usuario), '[]'::jsonb),

    'avaliacoes_recebidas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'turno_id',  a.turno_id,
               'resposta',  a.resposta,
               'criada_em', a.criada_em)
             order by a.criada_em desc)
        from public.avaliacao a
        join public.turno t on t.id = a.turno_id
        join public.posicao pos on pos.id = t.posicao_id
        join public.vaga vg on vg.id = pos.vaga_id
       where (c.perfil = 'profissional' and pos.profissional_id in (select p.id from prof p) and a.alvo_tipo = 'profissional')
          or (c.perfil = 'contratante' and vg.estabelecimento_id in (select k.estabelecimento_id from casas k) and a.alvo_tipo = 'estabelecimento')), '[]'::jsonb),

    'dispositivos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'plataforma',    dp.plataforma,
               'atualizado_em', dp.atualizado_em)
             order by dp.atualizado_em desc)
        from public.dispositivo dp
       where dp.usuario_id = p_usuario), '[]'::jsonb),

    'candidaturas', coalesce((
      select jsonb_agg(privado.candidatura_em_json(cd.id)
             order by cd.criada_em desc)
        from public.candidatura cd
       where cd.profissional_id in (select p.id from prof p)), '[]'::jsonb),

    'ocorrencias', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',           o.id,
               'tipo',         o.tipo,
               'papel',        case when o.autor_id = p_usuario then 'autor' else 'alvo' end,
               'criada_em',    o.criada_em,
               'resolvido_em', o.resolvido_em,
               'motivo',       case when o.autor_id = p_usuario or o.tipo = 'suspensao' then o.motivo else null end)
             order by o.criada_em desc)
        from public.ocorrencia o
       where o.autor_id = p_usuario or o.usuario_id = p_usuario), '[]'::jsonb),

    'bloqueios', coalesce((
      select jsonb_agg(x.o order by x.criado_em desc)
        from (
          select distinct jsonb_build_object(
                   'alvo_tipo', 'profissional',
                   'alvo_id',   pb.id,
                   'criado_em', b.criado_em) as o,
                 b.criado_em
            from public.bloqueio b
            join public.profissional pb on pb.usuario_id = b.bloqueado_id
           where b.autor_id = p_usuario
          union
          select distinct jsonb_build_object(
                   'alvo_tipo', 'estabelecimento',
                   'alvo_id',   mb.estabelecimento_id,
                   'criado_em', b.criado_em) as o,
                 b.criado_em
            from public.bloqueio b
            join public.usuario ub on ub.id = b.bloqueado_id and ub.perfil = 'contratante'
            join public.membro_estabelecimento mb on mb.usuario_id = b.bloqueado_id
           where b.autor_id = p_usuario
        ) x), '[]'::jsonb),

    'notificacoes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tipo',          n.tipo,
               'referencia_id', n.referencia_id,
               'payload',       n.payload,
               'enviada_em',    n.enviada_em,
               'entregue_em',   n.entregue_em)
             order by n.enviada_em desc nulls last)
        from public.notificacao n
       where n.usuario_id = p_usuario), '[]'::jsonb),

    'despachos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'vaga_id',   ds.vaga_id,
               'criado_em', ds.criado_em,
               'reaberta',  ds.reaberta)
             order by ds.criado_em desc)
        from public.despacho ds
       where ds.profissional_id in (select p.id from prof p)), '[]'::jsonb),

    'equipe_confianca', coalesce((
      select jsonb_agg(jsonb_build_object(
               'estabelecimento_id', ec.estabelecimento_id,
               'nome',               es.nome,
               'adicionado_em',      ec.adicionado_em)
             order by ec.adicionado_em desc)
        from public.equipe_confianca ec
        join public.estabelecimento es on es.id = ec.estabelecimento_id
       where ec.profissional_id in (select p.id from prof p)), '[]'::jsonb),

    'pedido_de_exclusao', (
      select jsonb_build_object(
               'pedido_em',    pe.pedido_em,
               'estado',       pe.estado,
               'tentativas',   pe.tentativas,
               'concluido_em', pe.concluido_em)
        from public.pedido_de_exclusao pe
       where pe.usuario_id = p_usuario
       order by pe.pedido_em desc
       limit 1),

    'eventos_app', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',          ea.id,
               'evento',      ea.evento,
               'vaga_id',     ea.vaga_id,
               'turno_id',    ea.turno_id,
               'ocorrido_em', ea.ocorrido_em,
               'criado_em',   ea.criado_em)
             order by ea.ocorrido_em desc, ea.criado_em desc, ea.id desc)
        from public.evento_app ea
       where ea.usuario_id = p_usuario), '[]'::jsonb),

    -- 0.2.59: mídias ativas do titular
    'midias', coalesce((
      select jsonb_agg(privado.midia_em_json(m)
             order by m.criado_em desc)
        from privado.midia m
       where (m.estabelecimento_id is null and m.dono_usuario_id = p_usuario
              or m.estabelecimento_id in (select k.estabelecimento_id from casas k))), '[]'::jsonb),

    -- 0.2.59: chamadas do titular (como profissional chamado ou membro da casa)
    'chamadas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',                 ch.id,
               'vaga_id',            ch.vaga_id,
               'profissional_id',    ch.profissional_id,
               'estabelecimento_id', ch.estabelecimento_id,
               'estado',             ch.estado,
               'recado',             ch.recado,
               'motivo_recusa',      ch.motivo_recusa,
               'expira_em',          ch.expira_em,
               'respondida_em',      ch.respondida_em,
               'criada_em',          ch.criada_em)
             order by ch.criada_em desc)
        from public.chamada ch
       where (c.perfil = 'profissional' and ch.profissional_id in (select p.id from prof p))
          or (c.perfil = 'contratante' and ch.estabelecimento_id in (select k.estabelecimento_id from casas k))), '[]'::jsonb)
  )
  from conta c
$$;

comment on function privado.meus_dados(uuid) is
  'Portabilidade LGPD (art. 18): consolidação de dados do titular com PerfilProfissionalDetalhado (0.2.58), midias (0.2.59) e chamadas (0.2.59).';
revoke execute on function privado.meus_dados(uuid) from public, anon, authenticated;
grant  execute on function privado.meus_dados(uuid) to service_role;
