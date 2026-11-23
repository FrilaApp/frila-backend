-- Recursos do app por versão (contrato 0.2.65; desenho em frila-documentacao,
-- arquitetura/desenho-recursos-por-versao-do-app-v1.2.md).
--
-- As chaves do servidor não conhecem a versão do app. Ligar uma para a Apple revisar a 1.2
-- ligaria o recurso também na 1.1, que foi revisada com os três desligados. Agora
-- configuracao_do_app recebe `versao_app` (opcional), e cada recurso só vem true com dois atos:
-- a chave ligada e uma versão mínima configurada para o recurso na plataforma, com a versão do
-- app maior ou igual a ela. Sem versão, malformada, abaixo do mínimo ou sem mínimo: false.
--
-- Esta migração é só o corte, o PR (A). O portão (c) do desenho (o push chamada_* e
-- chamar_profissional com o mesmo mínimo) vem num PR próprio, o (B). Ligar qualquer chave no
-- Prod exige o (A) e o (B) aplicados.

select set_config('lock_timeout', '2s', true);

-- ── 1. Comparador que completa com zeros ──────────────────────────────────────
-- privado.versao_em_partes não completa: no Postgres '{1,2}'::int[] < '{1,2,0}'::int[], e "1.2"
-- não alcançaria o mínimo "1.2.0". Ele sustenta os CHECKs de privado.configuracao_app e fica
-- como está; este aceita até 4 partes, como registrar_dispositivo.versao_app.

create function privado.versao_em_quatro(versao text) returns int[]
language sql immutable set search_path = '' as $$
  select case when versao ~ '^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$' then
    (select array_agg(coalesce(p[i], 0) order by i)
       from (select pg_catalog.string_to_array(versao, '.')::int[] as p) x,
            pg_catalog.generate_series(1, 4) as i)
  end
$$;
comment on function privado.versao_em_quatro(text) is
  'Versão de 1 a 4 partes como int[4], completando com zeros ("1.2" = {1,2,0,0}), para comparar por ordem natural. Null fora do formato.';
revoke all on function privado.versao_em_quatro(text) from public, anon, authenticated;
grant execute on function privado.versao_em_quatro(text) to service_role;

-- ── 2. O mínimo por recurso e plataforma ──────────────────────────────────────

create table privado.recurso_versao_minima (
  recurso       text not null constraint recurso_versao_minima_recurso
                check (recurso in ('foto_de_perfil', 'chamada_direta', 'perfil_rico')),
  plataforma    public.plataforma not null,
  versao_minima text not null constraint recurso_versao_minima_formato
                check (versao_minima ~ '^[0-9]{1,6}(\.[0-9]{1,6}){0,2}$'),
  atualizado_em timestamptz not null default privado.agora(),
  primary key (recurso, plataforma)
);
comment on table privado.recurso_versao_minima is
  'Versão mínima do app a partir da qual cada recurso liga, por plataforma (contrato 0.2.65). Sem linha, o recurso fica desligado na plataforma (fechado por padrão): ligar exige a chave e o mínimo. Não guarda dado pessoal.';
comment on column privado.recurso_versao_minima.versao_minima is
  'De 1 a 3 partes numéricas, como versao_app em configuracao_do_app; a parte que falta vale 0.';
alter table privado.recurso_versao_minima enable row level security;
revoke all on privado.recurso_versao_minima from public, anon, authenticated;

-- ── 3. O recurso vale para esta versão? ───────────────────────────────────────

create function privado.recurso_na_versao(p_recurso text, p_plataforma text, p_versao text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(
           case p_recurso
             when 'foto_de_perfil' then (select c.foto_de_perfil from privado.configuracao_app c
                                          where c.plataforma::text = p_plataforma)
             else (select r.ligado from privado.recurso r where r.chave = p_recurso)
           end, false)
     and coalesce((select privado.versao_em_quatro(p_versao) >= privado.versao_em_quatro(m.versao_minima)
                     from privado.recurso_versao_minima m
                    where m.recurso = p_recurso and m.plataforma::text = p_plataforma), false)
$$;
comment on function privado.recurso_na_versao(text, text, text) is
  'Se o recurso liga para esta versão do app nesta plataforma: a chave ligada e a versão maior ou igual ao mínimo configurado. Sem mínimo, versão nula ou malformada: false (RN46, contrato 0.2.65).';
revoke all on function privado.recurso_na_versao(text, text, text) from public, anon, authenticated;
grant execute on function privado.recurso_na_versao(text, text, text) to service_role;

-- ── 4. configuracao_do_app com versao_app ─────────────────────────────────────
-- Troca de assinatura com drop e create: duas versões com default deixariam a chamada só com
-- `plataforma` ambígua (PGRST203). O app 1.0, o 1.1 e o Android seguem chamando só com
-- `plataforma` e recebem os três recursos false. O corpo do resto não muda.

drop function public.configuracao_do_app(text);

create function public.configuracao_do_app(plataforma text default null, versao_app text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_config privado.configuracao_app;
  -- De 1 a 3 partes; fora disso vale como ausente, sem erro, porque é a chamada da abertura.
  v_versao text := case when versao_app ~ '^[0-9]{1,6}(\.[0-9]{1,6}){0,2}$' then versao_app end;
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

comment on function public.configuracao_do_app(text, text) is
  'Versão mínima, versão recomendada, URL da loja e mensagem opcional da plataforma (contrato: ConfiguracaoDoApp). Única função de public liberada para anon: o app abaixo da mínima precisa saber disso antes de ter sessão. 422 para plataforma ausente ou fora do enum; 404 para plataforma sem configuração. Desde 0.2.65, os recursos dependem de versao_app (privado.recurso_na_versao).';

revoke execute on function public.configuracao_do_app(text, text) from public;
grant  execute on function public.configuracao_do_app(text, text) to anon, authenticated;
