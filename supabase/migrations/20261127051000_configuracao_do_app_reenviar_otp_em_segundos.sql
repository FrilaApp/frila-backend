-- Expõe o campo opcional `reenviar_otp_em_segundos` (30 ou 60, fallback 60) em
-- `public.configuracao_do_app(plataforma, versao_app)`, lido de
-- `privado.config_auth.cooldown_reenvio_otp_segundos` (`unica = true`).
--
-- Invariante: descreve a política efetiva do backend (não prova sozinho `max_frequency`
-- do Auth; a virada para 30 segue condicionada à confirmação do operador por ambiente).
-- Preserva grants (`anon`, `authenticated`), `search_path = ''` e não expõe nenhuma
-- outra coluna privada de `privado.config_auth`.

create or replace function public.configuracao_do_app(plataforma text default null, versao_app text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_config   privado.configuracao_app;
  v_versao   text := case when versao_app ~ '^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$' then versao_app end;
  v_cooldown integer := 60;
begin
  if plataforma is null or btrim(plataforma) = '' then perform public.erro(422,'campo_obrigatorio','plataforma'); end if;
  if not plataforma = any(enum_range(null::public.plataforma)::text[]) then
    perform public.erro(422,'campo_invalido','plataforma');
  end if;
  select c.* into v_config from privado.configuracao_app c where c.plataforma::text = configuracao_do_app.plataforma;
  if not found then perform public.erro(404,'nao_encontrado','plataforma'); end if;

  select coalesce(a.cooldown_reenvio_otp_segundos, 60)
    into v_cooldown
    from privado.config_auth a
   where a.unica = true;

  v_cooldown := case when v_cooldown in (30, 60) then v_cooldown else 60 end;

  return jsonb_build_object(
    'plataforma', v_config.plataforma,
    'versao_minima', v_config.versao_minima,
    'versao_recomendada', v_config.versao_recomendada,
    'url_da_loja', v_config.url_da_loja,
    'mensagem', v_config.mensagem,
    'reenviar_otp_em_segundos', v_cooldown,
    'recursos', jsonb_build_object(
      'foto_de_perfil', privado.recurso_na_versao('foto_de_perfil', configuracao_do_app.plataforma, v_versao),
      'chamada_direta', privado.recurso_na_versao('chamada_direta', configuracao_do_app.plataforma, v_versao),
      'perfil_rico',    privado.recurso_na_versao('perfil_rico',    configuracao_do_app.plataforma, v_versao),
      'checkin_por_codigo', privado.recurso_na_versao('checkin_por_codigo', configuracao_do_app.plataforma, v_versao),
      'busca_profissionais', privado.recurso_na_versao('busca_profissionais', configuracao_do_app.plataforma, v_versao)
                             and privado.recurso_na_versao('chamada_direta', configuracao_do_app.plataforma, v_versao)));
end $$;

revoke execute on function public.configuracao_do_app(text, text) from public;
grant  execute on function public.configuracao_do_app(text, text) to anon, authenticated;
