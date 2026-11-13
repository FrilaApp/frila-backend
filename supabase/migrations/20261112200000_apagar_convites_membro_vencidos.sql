-- Retenção do convite de membro (achado da Bússola, 12/11/2026; ROPA, linha 31).
-- privado.convite_membro guarda o e-mail de um terceiro que ainda não é usuário. O convite vence em 7
-- dias, mas nenhuma rotina o apagava. Agora sai 30 dias depois de aceito (usado_em) ou, se não foi
-- aceito, 30 dias depois de vencer (expira_em). O convite válido, ainda não vencido, fica.
--
-- Volta: select cron.unschedule('apagar_convites_membro_vencidos') e drop function da função.
-- A limpeza só apaga dado vencido; não há volta de dado.

select set_config('lock_timeout', '2s', true);

create function privado.apagar_convites_membro_vencidos() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_total integer;
begin
  delete from privado.convite_membro c
   where coalesce(c.usado_em, c.expira_em) <= privado.agora() - interval '30 days';
  get diagnostics v_total = row_count;
  return v_total;
end $$;
comment on function privado.apagar_convites_membro_vencidos() is
  'LGPD (Bússola, 12/11): apaga o convite de membro 30 dias depois de aceito (usado_em) ou, se não aceito, 30 dias depois de vencer (expira_em). O convite guarda o e-mail de um terceiro ainda não usuário. Roda no pg_cron, uma vez por dia. Devolve quantos convites saíram.';
revoke all on function privado.apagar_convites_membro_vencidos() from public, anon, authenticated;
grant execute on function privado.apagar_convites_membro_vencidos() to service_role;

-- Diária às 05:41 UTC, fora das faixas que já existem (04:23, 06:00, 06:17, 06:19, 06:30, 06:45, 07:00).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('apagar_convites_membro_vencidos')
      where exists (select 1 from cron.job where jobname = 'apagar_convites_membro_vencidos');
    perform cron.schedule(
      'apagar_convites_membro_vencidos',
      '41 5 * * *',
      'select privado.apagar_convites_membro_vencidos()'
    );
  end if;
end $$;

comment on table privado.convite_membro is
  'Convites de membros para estabelecimentos, com token opaco e expiração (RF21). Finalidade: convidar um membro pelo e-mail, que é de um terceiro ainda não usuário. Retenção: o convite é apagado 30 dias depois de vencer ou de ser aceito (privado.apagar_convites_membro_vencidos, diária no pg_cron).';
