-- 20261116130000_probe_saude_cron.sql
-- Probe operacional do estado e idade do último sucesso dos jobs pg_cron (Cartão bB0tV5R8).
--
-- Desacopla o monitoramento da dependência circular do pg_cron e da fila de e-mail:
-- 1. Cria a função privada privado.consultar_saude_cron() para aferir a idade do último
--    sucesso de reprocessar_despacho e de verificar_saude em cron.job_run_details.
-- 2. Não expõe nomes de tabelas nem identificadores de usuário ou conteúdo (RN15).
-- 3. Acesso estrito a service_role; sem grant para anon ou authenticated.

create or replace function privado.consultar_saude_cron(
  p_tolerancia_despacho_s numeric default 300,
  p_tolerancia_vigia_s    numeric default 900
)
returns table (
  saudavel                boolean,
  status                  text,
  despacho_idade_segundos numeric,
  vigia_idade_segundos    numeric,
  despacho_ativo          boolean,
  vigia_ativo             boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_d_idade numeric;
  v_v_idade numeric;
  v_d_ativo boolean;
  v_v_ativo boolean;
  v_ok      boolean;
  v_status  text;
begin
  select
    round(extract(epoch from (v_agora - max(d.end_time) filter (where j.jobname = 'reprocessar_despacho' and d.status = 'succeeded' and d.end_time <= v_agora)))::numeric, 2),
    round(extract(epoch from (v_agora - max(d.end_time) filter (where j.jobname = 'verificar_saude' and d.status = 'succeeded' and d.end_time <= v_agora)))::numeric, 2),
    coalesce(bool_or(j.jobname = 'reprocessar_despacho' and j.active), false),
    coalesce(bool_or(j.jobname = 'verificar_saude' and j.active), false)
  into v_d_idade, v_v_idade, v_d_ativo, v_v_ativo
  from cron.job j
  left join cron.job_run_details d on d.jobid = j.jobid
  where j.jobname in ('reprocessar_despacho', 'verificar_saude');

  -- Critério de saúde operacional:
  -- Ambos os jobs devem estar ativos, com histórico de sucesso não-nulo e idade dentro da tolerância.
  if not v_d_ativo or not v_v_ativo or v_d_idade is null or v_v_idade is null or v_d_idade > p_tolerancia_despacho_s or v_v_idade > p_tolerancia_vigia_s then
    v_ok := false;
    v_status := 'atrasado';
  else
    v_ok := true;
    v_status := 'saudavel';
  end if;

  return query select v_ok, v_status, v_d_idade, v_v_idade, v_d_ativo, v_v_ativo;
end;
$$;

comment on function privado.consultar_saude_cron(numeric, numeric) is
  'Retorna a idade do último sucesso e o estado dos jobs pg_cron de despacho e vigia para probe operacional sem vazar dados pessoais ou nomes internos (cartão bB0tV5R8, RNF12, RN15).';

revoke execute on function privado.consultar_saude_cron(numeric, numeric) from public, anon, authenticated;
grant  execute on function privado.consultar_saude_cron(numeric, numeric) to service_role;
