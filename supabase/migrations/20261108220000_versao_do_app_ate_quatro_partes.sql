-- Regra única de até quatro partes para a versão do app (contrato 0.2.67, frila-documentacao #195).
--
-- configuracao_do_app aceitava versao_app de até três partes, e o mínimo guardado
-- (privado.recurso_versao_minima) também. Mas registrar_dispositivo.versao_app aceita até quatro, e
-- privado.recurso_na_versao, que decide o push chamada_* e chamar_profissional, compara até quatro.
-- Com três de um lado e quatro do outro, um app 1.2.0.1 seria chamado e receberia o aviso de
-- chamada com a tela escondida (revisão do Lince no #450). Agora a regra é uma só: de 1 a 4 partes
-- numéricas, até 6 dígitos cada, a parte que falta vale 0.
--
-- O corpo de configuracao_do_app é o da 20261108150000, com só o padrão trocado; a assinatura não
-- muda, então os grants ficam. O CHECK do mínimo troca com drop e add, porque não há alter de CHECK.

select set_config('lock_timeout', '2s', true);

-- ── 1. O mínimo guardado aceita até quatro partes ─────────────────────────────

alter table privado.recurso_versao_minima drop constraint recurso_versao_minima_formato;
alter table privado.recurso_versao_minima add constraint recurso_versao_minima_formato
  check (versao_minima ~ '^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$');
comment on column privado.recurso_versao_minima.versao_minima is
  'De 1 a 4 partes numéricas (0.2.67), como versao_app em configuracao_do_app e em registrar_dispositivo; a parte que falta vale 0.';

-- ── 2. configuracao_do_app aceita versao_app de até quatro partes ─────────────

create or replace function public.configuracao_do_app(plataforma text default null, versao_app text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_config privado.configuracao_app;
  -- De 1 a 4 partes (0.2.67, a mesma regra de versao_minima e registrar_dispositivo.versao_app); fora
  -- disso vale como ausente, sem erro, porque é a chamada da abertura.
  v_versao text := case when versao_app ~ '^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$' then versao_app end;
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
      'foto_de_perfil', privado.recurso_na_versao('foto_de_perfil', configuracao_do_app.plataforma, v_versao),
      'chamada_direta', privado.recurso_na_versao('chamada_direta', configuracao_do_app.plataforma, v_versao),
      'perfil_rico',    privado.recurso_na_versao('perfil_rico',    configuracao_do_app.plataforma, v_versao)));
end $$;
