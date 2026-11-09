-- Migração: 20261108230000_lgpd_guarda_legal_nas_sessoes_auth.sql
-- Escopo: LGPD-J6, brief B-GUARDA (nasce do B-T2, aceito pela Central em 08/11/2026). Empilhada no #442.
--
-- A guarda legal (Marco Civil, Lei 12.965/2014, art. 15, § 2º) passa a valer nas três etapas de
-- privado.limpar_trilha_e_sessoes_auth (20261108120000): nada da conta em guarda vigente em
-- privado.registro_acesso_guarda sai enquanto a guarda vale.
--   · (c) a sessão parada há mais de 6 meses FICA, com os refresh_tokens e os mfa_amr_claims dela: guarda o último IP
--     e o user_agent da conta;
--   · (a) e (b) a trilha do Auth da conta FICA, pelo actor_id ou pelo traits.user_id, inclusive a de conta excluída
--     (a guarda não tem FK). A trilha guarda a hora e o IP de cada login: é registro de acesso a aplicação (MCI,
--     art. 5º, VIII), e a ordem do art. 15, § 2º alcança todo registro da conta (Bússola, 08/11/2026,
--     orquestracao/retornos/J-pr460-lgpd-bussola.md). Vencida a guarda, a trilha volta a sair.
--
-- O predicado é o mesmo de privado.limpar_registros_acesso (20261108110000_lgpd_registro_acessos_borda.sql:490-493):
-- a guarda vale de desde (inclusive) até ate (exclusive), lidos no privado.agora() da execução. Na trilha, a conta sai
-- do payload pelo mesmo CASE da etapa (b): só um uuid válido vira uuid.
--
-- A guarda entra na autoconferência de RLS (Forja, 08/11/2026): a tabela tem RLS ligado e nenhuma política, e um dono
-- sem BYPASSRLS que não é o dono dela não enxerga linha nenhuma. Aí o not exists da guarda não acharia nada, e a etapa
-- apagaria, sem erro, o que a ordem manda guardar. Com a guarda invisível, nenhuma das três etapas roda; cada uma vira
-- falha_execucao (rls_sem_bypass), como já acontecia com as tabelas do Auth, e a falha passa a dizer quais tabelas o
-- dono não enxerga (tabelas). A regra de visibilidade das quatro tabelas deixa de ser feita à mão e passa a ser a do
-- Postgres, row_security_active(oid) no contexto do dono: a feita à mão barrava o membro do papel dono, que o
-- Postgres deixa passar (Lince no #460; errava para o lado seguro).
--
-- O resto do corpo é igual ao de 20261108120000.
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
  v_rls_guarda            boolean;
  v_bloqueio_trilha       text[];
  v_bloqueio_excluida     text[];
  v_bloqueio_sessoes      text[];
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
  --     A regra é a do próprio Postgres: row_security_active, que dentro do security definer responde pelo dono
  --     (dono da tabela ou membro do papel dono, sem FORCE; BYPASSRLS; superusuário). Lince no #460, FYI.
  select coalesce(bool_or(c.relname = 'audit_log_entries' and row_security_active(c.oid)), true),
         coalesce(bool_or(c.relname = 'users' and row_security_active(c.oid)), true),
         coalesce(bool_or(c.relname = 'sessions' and row_security_active(c.oid)), true)
    into v_rls_trilha, v_rls_usuarios, v_rls_sessoes
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'auth'
   where c.relname in ('audit_log_entries', 'users', 'sessions');

  -- As três etapas também dependem de enxergar a guarda legal: invisível, o not exists da guarda não acharia linha e a
  -- etapa apagaria, sem erro, o que a ordem manda guardar. Mesma regra, pelo catálogo (sem a tabela, bloqueia). Cada
  -- etapa guarda a lista do que o dono não enxerga: só a lista vazia deixa a etapa rodar.
  select coalesce(bool_or(row_security_active(c.oid)), true)
    into v_rls_guarda
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'privado'
   where c.relname = 'registro_acesso_guarda';
  v_bloqueio_trilha := array_remove(array[case when v_rls_trilha then 'auth.audit_log_entries' end,
                                          case when v_rls_guarda then 'privado.registro_acesso_guarda' end], null);
  v_bloqueio_excluida := array_remove(array[case when v_rls_trilha then 'auth.audit_log_entries' end,
                                            case when v_rls_usuarios then 'auth.users' end,
                                            case when v_rls_guarda then 'privado.registro_acesso_guarda' end], null);
  v_bloqueio_sessoes := array_remove(array[case when v_rls_sessoes then 'auth.sessions' end,
                                           case when v_rls_guarda then 'privado.registro_acesso_guarda' end], null);

  -- Cada lote roda num bloco próprio: o erro (privilégio no esquema auth do hospedado, trava, statement_timeout)
  -- desfaz só aquele lote, fica registrado e encerra a etapa; os lotes anteriores e as outras etapas ficam.
  -- Todos rodam na transação da chamada (o pg_cron confirma no fim), como no #430.

  -- (a) Trilha do Auth com mais de 6 meses. Sem FOR UPDATE: o Auth só insere na trilha, ninguém trava linha
  --     dela, e assim a etapa pede só SELECT e DELETE (Lince no #442, R-1).
  --     Fica a trilha da conta em guarda vigente, pelo actor_id ou pelo traits.user_id.
  v_lotes := 0;
  if cardinality(v_bloqueio_trilha) > 0 then
    v_falhas := v_falhas || jsonb_build_object('etapa', 'trilha_antiga', 'codigo', 'rls_sem_bypass',
                                               'tabelas', to_jsonb(v_bloqueio_trilha));
  end if;
  loop
    exit when cardinality(v_bloqueio_trilha) > 0;
    begin
      delete from auth.audit_log_entries a
       where a.id in (select x.id from auth.audit_log_entries x
                       where x.created_at <= v_limite_data
                         -- Guarda legal (MCI art. 15, § 2º): a trilha da conta em guarda vigente fica. Mesmo predicado
                         -- de privado.limpar_registros_acesso (20261108110000_lgpd_registro_acessos_borda.sql:490-493).
                         and not exists (select 1 from privado.registro_acesso_guarda g
                                          where g.usuario_id in (case when x.payload->>'actor_id' ~* c_uuid
                                                                      then (x.payload->>'actor_id')::uuid end,
                                                                 case when x.payload->'traits'->>'user_id' ~* c_uuid
                                                                      then (x.payload->'traits'->>'user_id')::uuid end)
                                            and g.desde <= v_agora and v_agora < g.ate)
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
  --     Fica a trilha da conta em guarda vigente, mesmo excluída (a guarda não tem FK), pelo mesmo predicado de (a).
  v_lotes := 0;
  if cardinality(v_bloqueio_excluida) > 0 then
    v_falhas := v_falhas || jsonb_build_object('etapa', 'trilha_conta_excluida', 'codigo', 'rls_sem_bypass',
                                               'tabelas', to_jsonb(v_bloqueio_excluida));
  end if;
  loop
    exit when cardinality(v_bloqueio_excluida) > 0;
    begin
      delete from auth.audit_log_entries a
       where a.id in (
         select x.id
           from auth.audit_log_entries x
          where ((x.payload->>'actor_id' ~* c_uuid
                  and x.payload->>'actor_id' <> c_conta_nula
                  and not exists (select 1 from auth.users u
                                   where u.id = case when x.payload->>'actor_id' ~* c_uuid
                                                     then (x.payload->>'actor_id')::uuid end))
              or (x.payload->'traits'->>'user_id' ~* c_uuid
                  and not exists (select 1 from auth.users u
                                   where u.id = case when x.payload->'traits'->>'user_id' ~* c_uuid
                                                     then (x.payload->'traits'->>'user_id')::uuid end)))
            -- Guarda legal (MCI art. 15, § 2º): a trilha da conta em guarda vigente fica, mesmo excluída.
            and not exists (select 1 from privado.registro_acesso_guarda g
                             where g.usuario_id in (case when x.payload->>'actor_id' ~* c_uuid
                                                         then (x.payload->>'actor_id')::uuid end,
                                                    case when x.payload->'traits'->>'user_id' ~* c_uuid
                                                         then (x.payload->'traits'->>'user_id')::uuid end)
                               and g.desde <= v_agora and v_agora < g.ate)
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
  --     Bloqueada se o dono não enxerga as sessões ou a guarda legal; tabelas diz qual.
  v_lotes := 0;
  if cardinality(v_bloqueio_sessoes) > 0 then
    v_falhas := v_falhas || jsonb_build_object('etapa', 'sessoes_paradas', 'codigo', 'rls_sem_bypass',
                                               'tabelas', to_jsonb(v_bloqueio_sessoes));
  end if;
  loop
    exit when cardinality(v_bloqueio_sessoes) > 0;
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
  'Rotina diária própria (pg_cron limpar_trilha_e_sessoes_auth): apaga a trilha do Auth com mais de 6 meses, a trilha de conta excluída (actor_id ou traits.user_id de conta que não existe mais) de qualquer idade, e só as sessões sem atividade há mais de 6 meses (com refresh_tokens e mfa_amr_claims em cascata). Guarda legal: a sessão de conta em guarda vigente em privado.registro_acesso_guarda (de desde, inclusive, até ate, exclusive) fica, porque guarda o último IP e o user_agent da conta e a autoridade pode requerer, cautelarmente, que os registros fiquem além dos 6 meses (Marco Civil, Lei 12.965/2014, art. 15, § 2º; conservação por obrigação legal, LGPD art. 16, I); vencida a guarda, a sessão volta a sair. A guarda também segura a trilha do Auth da conta (etapas a e b), pelo actor_id ou pelo traits.user_id, inclusive a de conta excluída; vencida a guarda, a trilha também volta a sair. Piso de 6 meses que nenhum parâmetro encurta; lote de até 10 mil e teto de 100 lotes por etapa; FOR UPDATE SKIP LOCKED só nas sessões. Erro de um lote (privilégio no esquema auth do hospedado, trava, statement_timeout) encerra só aquela etapa e vira registro em privado.falha_execucao, só com etapa e SQLSTATE. Privilégios do dono: SELECT e DELETE em auth.audit_log_entries, SELECT, UPDATE e DELETE em auth.sessions, SELECT em auth.users e em privado.registro_acesso_guarda, e BYPASSRLS (ou ser dono das tabelas): sem isso, a etapa que depende da tabela não roda e registra rls_sem_bypass, com a lista das tabelas que o dono não enxerga (tabelas); as três etapas dependem também da guarda legal. Base: LGPD art. 16 e ROPA linha 2 (e-mail apagado na exclusão), jurídico em frila-docs #182.';

comment on table privado.registro_acesso_guarda is
  'Guarda legal de registros de acesso (Marco Civil, Lei 12.965/2014, art. 15, § 2º): a autoridade policial, administrativa ou o Ministério Público pode requerer, cautelarmente, que os registros de uma conta sejam guardados além dos 6 meses. Entre desde e ate, privado.limpar_registros_acesso não apaga os registros da conta, e privado.limpar_trilha_e_sessoes_auth não apaga as sessões dela (auth.sessions, com os refresh_tokens), nem a trilha do Auth dela. A ordem cautelar perde a eficácia se a autoridade não pedir ao juiz a autorização de acesso em 60 dias, contados do requerimento, ou se o juiz a negar (Marco Civil, art. 15, § 2º, com o art. 13, §§ 3º e 4º): o ate acompanha isso. Só o service_role escreve. NENHUM dado da ordem fica aqui: só a conta, o período e uma referência.';
