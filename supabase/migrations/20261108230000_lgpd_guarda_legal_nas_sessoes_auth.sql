-- Migração: 20261108230000_lgpd_guarda_legal_nas_sessoes_auth.sql
-- Escopo: LGPD-J6, brief B-GUARDA (nasce do B-T2, aceito pela Central em 08/11/2026). Empilhada no #442.
--
-- A guarda legal (Marco Civil, Lei 12.965/2014, art. 15, § 2º) passa a valer também para a etapa (c) de
-- privado.limpar_trilha_e_sessoes_auth (20261108120000): a sessão parada há mais de 6 meses de uma conta em guarda
-- vigente em privado.registro_acesso_guarda FICA, com os refresh_tokens e os mfa_amr_claims dela. A sessão guarda o
-- último IP e o user_agent da conta; sem a exceção, a limpeza apagaria o que a ordem cautelar manda guardar.
--
-- O predicado é o mesmo de privado.limpar_registros_acesso (20261108110000_lgpd_registro_acessos_borda.sql:490-493):
-- a guarda vale de desde (inclusive) até ate (exclusive), lidos no privado.agora() da execução.
--
-- O resto do corpo é igual ao de 20261108120000: as etapas (a) e (b), da trilha do Auth, não mudam. Se a trilha
-- também for registro de acesso do art. 15, a pergunta está no PR; aqui não se implementa.
-- O agendamento (pg_cron limpar_trilha_e_sessoes_auth, 04:23 UTC), o dono e os privilégios da função não mudam:
-- create or replace os preserva.

create or replace function privado.limpar_trilha_e_sessoes_auth(
  p_meses integer default 6,
  p_limite integer default 1000
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '500ms'
as $$
declare
  v_agora                 timestamptz := privado.agora();
  v_limite_data           timestamptz;
  v_lote                  integer;
  v_lotes                 integer;
  v_trilha_antiga         integer := 0;
  v_trilha_conta_excluida integer := 0;
  v_sessoes_paradas       integer := 0;
  v_falhas                jsonb := '[]'::jsonb;
  v_rls_trilha            boolean;
  v_rls_usuarios          boolean;
  v_rls_sessoes           boolean;
  -- Teto por etapa e por execução: 100 lotes. O resto sai na rodada seguinte.
  c_teto_lotes constant integer := 100;
  c_teto_lote  constant integer := 10000;
  c_conta_nula constant text := '00000000-0000-0000-0000-000000000000';
  c_uuid       constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
begin
  -- Piso: 6 meses (Marco Civil art. 15, J6). Nenhum parâmetro encurta.
  if p_meses is null or p_meses < 6 then
    p_meses := 6;
  end if;
  if p_limite is null or p_limite < 1 then
    p_limite := 1000;
  end if;
  p_limite := least(p_limite, c_teto_lote);
  v_limite_data := v_agora - make_interval(months => p_meses);

  -- Autoconferência de RLS: as tabelas do Auth têm RLS ligado e nenhuma política. Um dono (current_user, dentro do
  -- security definer) sem BYPASSRLS, que não é o dono da tabela, não enxerga linha nenhuma. Sem esta conferência a
  -- limpeza não apagaria nada, calada. Pior: com auth.users invisível, a etapa (b) veria toda conta como excluída e
  -- apagaria a trilha inteira. Etapa bloqueada não roda e vira falha_execucao (codigo rls_sem_bypass). Só catálogo.
  select coalesce(bool_or(c.relname = 'audit_log_entries' and b.bloqueada), true),
         coalesce(bool_or(c.relname = 'users' and b.bloqueada), true),
         coalesce(bool_or(c.relname = 'sessions' and b.bloqueada), true)
    into v_rls_trilha, v_rls_usuarios, v_rls_sessoes
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'auth'
    join pg_roles r on r.rolname = current_user
    cross join lateral (select c.relrowsecurity and not (r.rolsuper or r.rolbypassrls)
                               and (c.relforcerowsecurity or c.relowner <> r.oid) as bloqueada) b
   where c.relname in ('audit_log_entries', 'users', 'sessions');

  -- Cada lote roda num bloco próprio: o erro (privilégio no esquema auth do hospedado, trava, statement_timeout)
  -- desfaz só aquele lote, fica registrado e encerra a etapa; os lotes anteriores e as outras etapas ficam.
  -- Todos rodam na transação da chamada (o pg_cron confirma no fim), como no #430.

  -- (a) Trilha do Auth com mais de 6 meses. Sem FOR UPDATE: o Auth só insere na trilha, ninguém trava linha
  --     dela, e assim a etapa pede só SELECT e DELETE (Lince no #442, R-1).
  v_lotes := 0;
  if v_rls_trilha then
    v_falhas := v_falhas || jsonb_build_object('etapa', 'trilha_antiga', 'codigo', 'rls_sem_bypass');
  end if;
  loop
    exit when v_rls_trilha;
    begin
      delete from auth.audit_log_entries a
       where a.id in (select x.id from auth.audit_log_entries x
                       where x.created_at <= v_limite_data
                       limit p_limite);
      get diagnostics v_lote = row_count;
    exception when others or query_canceled then
      v_falhas := v_falhas || jsonb_build_object('etapa', 'trilha_antiga', 'sqlstate', sqlstate);
      exit;
    end;
    v_trilha_antiga := v_trilha_antiga + v_lote;
    v_lotes := v_lotes + 1;
    exit when v_lote < p_limite or v_lotes >= c_teto_lotes;
  end loop;

  -- (b) Trilha de conta excluída, de qualquer idade: actor_id OU traits.user_id de conta que não existe mais.
  --     O CASE garante que só um uuid válido vira uuid. Sem FOR UPDATE, pelo mesmo motivo de (a).
  v_lotes := 0;
  if v_rls_trilha or v_rls_usuarios then
    v_falhas := v_falhas || jsonb_build_object('etapa', 'trilha_conta_excluida', 'codigo', 'rls_sem_bypass');
  end if;
  loop
    exit when v_rls_trilha or v_rls_usuarios;
    begin
      delete from auth.audit_log_entries a
       where a.id in (
         select x.id
           from auth.audit_log_entries x
          where (x.payload->>'actor_id' ~* c_uuid
                 and x.payload->>'actor_id' <> c_conta_nula
                 and not exists (select 1 from auth.users u
                                  where u.id = case when x.payload->>'actor_id' ~* c_uuid
                                                    then (x.payload->>'actor_id')::uuid end))
             or (x.payload->'traits'->>'user_id' ~* c_uuid
                 and not exists (select 1 from auth.users u
                                  where u.id = case when x.payload->'traits'->>'user_id' ~* c_uuid
                                                    then (x.payload->'traits'->>'user_id')::uuid end))
          limit p_limite);
      get diagnostics v_lote = row_count;
    exception when others or query_canceled then
      v_falhas := v_falhas || jsonb_build_object('etapa', 'trilha_conta_excluida', 'sqlstate', sqlstate);
      exit;
    end;
    v_trilha_conta_excluida := v_trilha_conta_excluida + v_lote;
    v_lotes := v_lotes + 1;
    exit when v_lote < p_limite or v_lotes >= c_teto_lotes;
  end loop;

  -- (c) Só as sessões sem atividade há mais de 6 meses. refreshed_at é timestamp sem fuso, em UTC.
  --     Sessão sem nenhuma das três datas fica (greatest de nulos é nulo). Aqui o FOR UPDATE SKIP LOCKED fica:
  --     o Auth atualiza a sessão na renovação, e a rotina não espera por ela. Pede UPDATE em auth.sessions.
  v_lotes := 0;
  if v_rls_sessoes then
    v_falhas := v_falhas || jsonb_build_object('etapa', 'sessoes_paradas', 'codigo', 'rls_sem_bypass');
  end if;
  loop
    exit when v_rls_sessoes;
    begin
      with alvo as (
        select s.id
          from auth.sessions s
         where greatest(s.refreshed_at at time zone 'UTC', s.updated_at, s.created_at) <= v_limite_data
           -- Guarda legal (MCI art. 15, § 2º): a sessão da conta em guarda vigente fica. Mesmo predicado de
           -- privado.limpar_registros_acesso (20261108110000_lgpd_registro_acessos_borda.sql:490-493).
           and not exists (select 1 from privado.registro_acesso_guarda g
                            where g.usuario_id = s.user_id
                              and g.desde <= v_agora and v_agora < g.ate)
         limit p_limite
         for update skip locked
      )
      delete from auth.sessions s using alvo where s.id = alvo.id;
      get diagnostics v_lote = row_count;
    exception when others or query_canceled then
      v_falhas := v_falhas || jsonb_build_object('etapa', 'sessoes_paradas', 'sqlstate', sqlstate);
      exit;
    end;
    v_sessoes_paradas := v_sessoes_paradas + v_lote;
    v_lotes := v_lotes + 1;
    exit when v_lote < p_limite or v_lotes >= c_teto_lotes;
  end loop;

  -- Falha registrada sem dado pessoal; o registro também não derruba a rotina.
  if jsonb_array_length(v_falhas) > 0 then
    begin
      perform privado.registrar_falha_execucao('limpar_trilha_e_sessoes_auth', 'limpeza_auth_falhou',
                                               jsonb_build_object('falhas', v_falhas));
    exception when others or query_canceled then
      null;
    end;
  end if;

  return jsonb_build_object(
    'executado_em',          privado.agora(),
    'trilha_antiga',         v_trilha_antiga,
    'trilha_conta_excluida', v_trilha_conta_excluida,
    'sessoes_paradas',       v_sessoes_paradas,
    'falhas',                v_falhas
  );
end $$;

comment on function privado.limpar_trilha_e_sessoes_auth(integer, integer) is
  'Rotina diária própria (pg_cron limpar_trilha_e_sessoes_auth): apaga a trilha do Auth com mais de 6 meses, a trilha de conta excluída (actor_id ou traits.user_id de conta que não existe mais) de qualquer idade, e só as sessões sem atividade há mais de 6 meses (com refresh_tokens e mfa_amr_claims em cascata). Guarda legal: a sessão de conta em guarda vigente em privado.registro_acesso_guarda (de desde, inclusive, até ate, exclusive) fica, porque guarda o último IP e o user_agent da conta e a autoridade pode requerer, cautelarmente, que os registros fiquem além dos 6 meses (Marco Civil, Lei 12.965/2014, art. 15, § 2º; conservação por obrigação legal, LGPD art. 16, I); vencida a guarda, a sessão volta a sair. A guarda não alcança a trilha do Auth. Piso de 6 meses que nenhum parâmetro encurta; lote de até 10 mil e teto de 100 lotes por etapa; FOR UPDATE SKIP LOCKED só nas sessões. Erro de um lote (privilégio no esquema auth do hospedado, trava, statement_timeout) encerra só aquela etapa e vira registro em privado.falha_execucao, só com etapa e SQLSTATE. Privilégios do dono: SELECT e DELETE em auth.audit_log_entries, SELECT, UPDATE e DELETE em auth.sessions, SELECT em auth.users e em privado.registro_acesso_guarda, e BYPASSRLS (ou ser dono das tabelas): sem isso nas tabelas do Auth a etapa não roda e registra rls_sem_bypass. Base: LGPD art. 16 e ROPA linha 2 (e-mail apagado na exclusão), jurídico em frila-docs #182.';

comment on table privado.registro_acesso_guarda is
  'Guarda legal de registros de acesso (Marco Civil, Lei 12.965/2014, art. 15, § 2º): a autoridade policial, administrativa ou o Ministério Público pode requerer, cautelarmente, que os registros de uma conta sejam guardados além dos 6 meses. Entre desde e ate, privado.limpar_registros_acesso não apaga os registros da conta, e privado.limpar_trilha_e_sessoes_auth não apaga as sessões dela (auth.sessions, com os refresh_tokens). Só o service_role escreve. NENHUM dado da ordem fica aqui: só a conta, o período e uma referência.';
