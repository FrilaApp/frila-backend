-- Ciclo de vida do token de push: troca de conta, saída e reinstalação (RN25, RF06, RN15).
-- Cartão wpNabtCO.
--
-- O token é do aparelho, não da pessoa. Com um perfil por conta (RN25), a mesma pessoa
-- pode ter duas contas no mesmo iPhone; sem regra, o push da conta A chega com a conta B
-- aberta, e o aparelho que saiu da conta continua recebendo vagas — vazamento de dado
-- pessoal por notificação, que RN15 proíbe.
--
-- Os quatro caminhos pelos quais um token deixa de valer para uma conta:
--
--   troca de conta   `registrar_dispositivo` já transfere o token para quem chamou
--                    (`on conflict (token_fcm) do update`, migração 20260926020000).
--   saída            `remover_dispositivo`, abaixo, chamado antes do `signOut`.
--   token morto      o FCM responde UNREGISTERED e a Edge Function `enviar-push` apaga
--                    o aparelho por `privado.remover_token_fcm` (20260926020000).
--   reinstalação     o app apagado não chama nada; o token antigo sai na limpeza diária
--                    de quem não foi atualizado há mais de 60 dias, abaixo.

-- ── 1. RPC remover_dispositivo ────────────────────────────────────────────────

create or replace function public.remover_dispositivo(token_fcm text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_token     text;
  v_removidos int;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- O contrato só declara 200 e 401. Token nulo, em branco ou curto demais nunca foi
  -- registrado (o registro recusa), então a saída "deu no mesmo": removido false, e o
  -- logout do app não falha por isso.
  v_token := pg_catalog.btrim(coalesce(remover_dispositivo.token_fcm, ''));

  if pg_catalog.length(v_token) < 20 then
    return pg_catalog.jsonb_build_object('removido', false);
  end if;

  -- Só o token da própria conta. Se o aparelho já passou para outra conta, a saída
  -- atrasada da anterior não pode tirar o push de quem está logado nele agora.
  delete from public.dispositivo d
   where d.token_fcm  = v_token
     and d.usuario_id = v_uid;
  get diagnostics v_removidos = row_count;

  return pg_catalog.jsonb_build_object('removido', v_removidos > 0);
end $$;

comment on function public.remover_dispositivo(text) is
  'Tira o token de push do aparelho da conta que chamou (RF06, RN15). Chamada antes do signOut e na troca de conta. Idempotente: token nulo, em branco, curto demais ou que não está registrado para esta conta devolve {removido: false}. Nunca tira o token de outra conta.';

revoke execute on function public.remover_dispositivo(text) from public, anon;
grant  execute on function public.remover_dispositivo(text) to authenticated;

-- ── 2. Limpeza do token sem atualização há mais de 60 dias ───────────────────
--
-- O app reenvia o token a cada abertura, e o reenvio renova `atualizado_em`. Um token
-- parado há mais de 60 dias é de app apagado, de aparelho trocado ou de conta que não
-- abre mais o Frila: guardá-lo é guardar dado do aparelho sem finalidade.

create or replace function privado.limpar_dispositivos_inativos()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_removidos int;
begin
  delete from public.dispositivo d
   where d.atualizado_em < privado.agora() - interval '60 days';
  get diagnostics v_removidos = row_count;
  return v_removidos;
end $$;

comment on function privado.limpar_dispositivos_inativos() is
  'Apaga o token de push sem atualização há mais de 60 dias (reinstalação, aparelho trocado, app parado). Devolve quantos saíram. Privada, rodada uma vez por dia pelo pg_cron.';

revoke execute on function privado.limpar_dispositivos_inativos() from public, anon, authenticated;
grant  execute on function privado.limpar_dispositivos_inativos() to service_role;

-- Uma vez por dia, às 06:17 UTC (03:17 em Brasília), fora da janela que RNF12 protege.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('limpar_dispositivos_inativos')
      where exists (select 1 from cron.job where jobname = 'limpar_dispositivos_inativos');
    perform cron.schedule(
      'limpar_dispositivos_inativos',
      '17 6 * * *',
      'select privado.limpar_dispositivos_inativos()'
    );
  end if;
end $$;
