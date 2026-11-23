-- Os três interruptores chegam ao app (ConfiguracaoDoApp.recursos, contrato 0.2.54/0.2.60).
--
-- Achado do Prisma (08/11/2026): configuracao_do_app só devolvia `recursos.foto_de_perfil`,
-- e só quando ligada. `chamada_direta` (privado.recurso, 20261107300000) nunca chegava ao app
-- e `perfil_rico` (0.2.60) nem existia no backend. Ligar as chaves no Prod não mudaria nada
-- no app: ele trata ausente como false (RecursosDoApp) e mostraria a experiência da 1.0.
--
-- O que muda:
--   · `perfil_rico` entra em privado.recurso, DESLIGADA, como `chamada_direta`.
--   · configuracao_do_app devolve sempre os três, lidos das chaves reais:
--     `foto_de_perfil` de privado.configuracao_app (por plataforma, como já era) e
--     `chamada_direta` e `perfil_rico` de privado.recurso. Desligado é `false` explícito, o
--     que o contrato aceita ("ausente, ou campo ausente, vale false").
--
-- Não muda: nenhuma assinatura; as quatro operações da F2 ainda não conferem `perfil_rico`
-- (lacuna registrada à parte, ver o PR).

select set_config('lock_timeout', '2s', true);

insert into privado.recurso (chave, ligado) values ('perfil_rico', false)
on conflict (chave) do nothing;

-- contrato: corpo-sem-mudanca-de-superficie public.configuracao_do_app 0.2.62

create or replace function public.configuracao_do_app(plataforma text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_config privado.configuracao_app;
begin
  if plataforma is null or btrim(plataforma) = '' then perform public.erro(422,'campo_obrigatorio','plataforma'); end if;
  if not plataforma = any(enum_range(null::public.plataforma)::text[]) then
    perform public.erro(422,'campo_invalido','plataforma');
  end if;
  select c.* into v_config from privado.configuracao_app c where c.plataforma::text = configuracao_do_app.plataforma;
  if not found then perform public.erro(404,'nao_encontrado','plataforma'); end if;
  return jsonb_build_object('plataforma',v_config.plataforma,'versao_minima',v_config.versao_minima,
    'versao_recomendada',v_config.versao_recomendada,'url_da_loja',v_config.url_da_loja,'mensagem',v_config.mensagem,
    'recursos', jsonb_build_object(
      'foto_de_perfil', coalesce(v_config.foto_de_perfil, false),
      'chamada_direta', coalesce((select r.ligado from privado.recurso r where r.chave = 'chamada_direta'), false),
      'perfil_rico',    coalesce((select r.ligado from privado.recurso r where r.chave = 'perfil_rico'), false)));
end $$;
