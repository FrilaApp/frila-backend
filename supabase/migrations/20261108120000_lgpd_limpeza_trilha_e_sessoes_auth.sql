-- Migração: 20261108120000_lgpd_limpeza_trilha_e_sessoes_auth.sql
-- Escopo: LGPD-J6 T2b (cartão HAWhzOJ4, achado lateral do desenho B-T2; jurídico em frila-docs #182, ROPA linhas 2 e 24).
--
-- O Auth do Supabase guarda dado pessoal sem prazo, e nada no Frila limpa (medido em 08/11/2026,
-- orquestracao/retornos/B-T2-registro-acessos-desenho.md, item e):
--   · auth.audit_log_entries guarda o e-mail (payload.actor_username e, nas ações de admin, traits.user_email)
--     a cada login e renovação, e a limpeza do próprio Auth (internal/models/cleanup.go) não toca a trilha;
--   · a exclusão de conta (DELETE /auth/v1/admin/users) apaga auth.users mas não a trilha: a tabela não tem
--     coluna de usuário nem FK. A linha user_deleted é gravada com actor_id nulo (000…0, o service_role) e leva
--     traits.user_id e traits.user_email da conta apagada (medido no local);
--   · auth.sessions guarda o último IP e o user_agent de cada sessão enquanto ela existir, e o Auth só apaga
--     sessão com not_after ou com timebox/inactivity_timeout, que o Frila não configura.
--
-- A rotina diária própria (agendamento novo; executar_retencao_diaria não muda) apaga, em lotes com SKIP LOCKED
-- e teto por execução, com piso de 6 meses que nenhum parâmetro encurta:
--   (a) a trilha com mais de 6 meses;
--   (b) a trilha de conta excluída, de qualquer idade: actor_id de conta que não existe mais, ou traits.user_id
--       de conta que não existe mais (a linha user_deleted, que guarda o e-mail apagado);
--   (c) SÓ as sessões sem atividade há mais de 6 meses: nenhuma renovação, atualização nem criação nesse
--       período. Equivale a sair da conta; caem junto, em cascata, auth.refresh_tokens e auth.mfa_amr_claims.
--
-- O esquema auth é do Supabase. No hospedado, um privilégio a menos não pode derrubar nada: cada etapa roda num
-- bloco próprio, o erro vira um registro em privado.falha_execucao (só etapa e SQLSTATE, RN15), que o
-- verificar_saude já transforma em alerta, e as outras etapas seguem.

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
  v_limite_data           timestamptz;
  v_lote                  integer;
  v_lotes                 integer;
  v_trilha_antiga         integer := 0;
  v_trilha_conta_excluida integer := 0;
  v_sessoes_paradas       integer := 0;
  v_falhas                jsonb := '[]'::jsonb;
  -- Teto por etapa e por execução: 100 lotes (100 mil linhas com o lote padrão). O resto sai na rodada seguinte.
  c_teto_lotes constant integer := 100;
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
  v_limite_data := privado.agora() - make_interval(months => p_meses);

  -- (a) Trilha do Auth com mais de 6 meses
  begin
    v_lotes := 0;
    loop
      with alvo as (
        select x.id
          from auth.audit_log_entries x
         where x.created_at <= v_limite_data
         limit p_limite
         for update skip locked
      )
      delete from auth.audit_log_entries a using alvo where a.id = alvo.id;
      get diagnostics v_lote = row_count;
      v_trilha_antiga := v_trilha_antiga + v_lote;
      v_lotes := v_lotes + 1;
      exit when v_lote < p_limite or v_lotes >= c_teto_lotes;
    end loop;
  exception when others then
    v_trilha_antiga := 0;
    v_falhas := v_falhas || jsonb_build_object('etapa', 'trilha_antiga', 'sqlstate', sqlstate);
  end;

  -- (b) Trilha de conta excluída, de qualquer idade. O CASE garante que só um uuid válido vira uuid.
  begin
    v_lotes := 0;
    loop
      with alvo as (
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
         limit p_limite
         for update skip locked
      )
      delete from auth.audit_log_entries a using alvo where a.id = alvo.id;
      get diagnostics v_lote = row_count;
      v_trilha_conta_excluida := v_trilha_conta_excluida + v_lote;
      v_lotes := v_lotes + 1;
      exit when v_lote < p_limite or v_lotes >= c_teto_lotes;
    end loop;
  exception when others then
    v_trilha_conta_excluida := 0;
    v_falhas := v_falhas || jsonb_build_object('etapa', 'trilha_conta_excluida', 'sqlstate', sqlstate);
  end;

  -- (c) Só as sessões sem atividade há mais de 6 meses. refreshed_at é timestamp sem fuso, em UTC.
  --     Sessão sem nenhuma das três datas fica (greatest de nulos é nulo).
  begin
    v_lotes := 0;
    loop
      with alvo as (
        select s.id
          from auth.sessions s
         where greatest(s.refreshed_at at time zone 'UTC', s.updated_at, s.created_at) <= v_limite_data
         limit p_limite
         for update skip locked
      )
      delete from auth.sessions s using alvo where s.id = alvo.id;
      get diagnostics v_lote = row_count;
      v_sessoes_paradas := v_sessoes_paradas + v_lote;
      v_lotes := v_lotes + 1;
      exit when v_lote < p_limite or v_lotes >= c_teto_lotes;
    end loop;
  exception when others then
    v_sessoes_paradas := 0;
    v_falhas := v_falhas || jsonb_build_object('etapa', 'sessoes_paradas', 'sqlstate', sqlstate);
  end;

  -- Falha registrada sem dado pessoal; o registro também não derruba a rotina.
  if jsonb_array_length(v_falhas) > 0 then
    begin
      perform privado.registrar_falha_execucao('limpar_trilha_e_sessoes_auth', 'limpeza_auth_falhou',
                                               jsonb_build_object('falhas', v_falhas));
    exception when others then
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
  'Rotina diária própria (pg_cron limpar_trilha_e_sessoes_auth): apaga a trilha do Auth com mais de 6 meses, a trilha de conta excluída (actor_id ou traits.user_id de conta que não existe mais) de qualquer idade, e só as sessões sem atividade há mais de 6 meses (com refresh_tokens e mfa_amr_claims em cascata). Piso de 6 meses que nenhum parâmetro encurta; lotes com SKIP LOCKED e teto de 100 por etapa. Erro de uma etapa (privilégio no esquema auth do hospedado, trava) não derruba as outras: vira registro em privado.falha_execucao, só com etapa e SQLSTATE. Base: LGPD art. 16 e ROPA linha 2 (e-mail apagado na exclusão), jurídico em frila-docs #182.';

revoke all on function privado.limpar_trilha_e_sessoes_auth(integer, integer) from public, anon, authenticated;
grant execute on function privado.limpar_trilha_e_sessoes_auth(integer, integer) to service_role;

-- Agendamento próprio às 04:23 UTC (01:23 em Brasília): longe dos diários das 06:00 às 07:00, fora do :00 do
-- horário e de todo múltiplo de 5 dos jobs de 5 em 5 minutos.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('limpar_trilha_e_sessoes_auth')
      where exists (select 1 from cron.job where jobname = 'limpar_trilha_e_sessoes_auth');
    perform cron.schedule(
      'limpar_trilha_e_sessoes_auth',
      '23 4 * * *',
      'select privado.limpar_trilha_e_sessoes_auth()'
    );
  end if;
end $$;
