-- Peças 0.2.62 · Backend · Contestação do despacho em criterios_de_notificacao (RF27)
-- Adiciona o campo 'contestacao' (Protocolo | null) no retorno de public.criterios_de_notificacao()
-- conforme contrato 0.2.62 (linhas 6172-6179 de openapi.yaml).

-- contrato: corpo-sem-mudanca-de-superficie public.criterios_de_notificacao 0.2.62
create or replace function public.criterios_de_notificacao()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid         uuid := (select auth.uid());
  v_prof        public.profissional%rowtype;
  v_contestacao jsonb;
  v_res         jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('profissional');

  select * into v_prof
    from public.profissional p
   where p.usuario_id = v_uid;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Busca contestação de despacho existente do titular (0.2.62 / RF27).
  -- Protocolo quer em análise ou já respondida pela Equipe Frila; nulo se ainda não contestou.
  select jsonb_build_object(
           'ocorrencia_id',      o.id,
           'tipo',               o.tipo,
           'criada_em',          o.criada_em,
           'prazo_resposta_ate', privado.prazo_de_resposta(o.criada_em)
         )
    into v_contestacao
    from public.ocorrencia o
   where o.autor_id = v_uid
     and o.tipo = 'revisao_despacho'
   order by o.criada_em desc
   limit 1;

  select jsonb_build_object(
    'funcoes', coalesce(
      (select jsonb_agg(jsonb_build_object('id', f.id, 'nome', f.nome, 'categoria', f.categoria)
                        order by f.nome)
         from public.profissional_funcao pf
         join public.funcao f on f.id = pf.funcao_id
        where pf.profissional_id = v_prof.id
          and f.ativo is true),
      '[]'::jsonb),
    'disponibilidades', coalesce(
      (select jsonb_agg(jsonb_build_object(
                'dia_semana',  d.dia_semana,
                'hora_inicio', to_char(d.hora_inicio, 'HH24:MI'),
                'hora_fim',    to_char(d.hora_fim,    'HH24:MI'))
                order by d.dia_semana, d.hora_inicio)
         from public.disponibilidade d
        where d.profissional_id = v_prof.id),
      '[]'::jsonb),
    'distancia_maxima_km', 15,
    'equipes_de_confianca', coalesce(
      (select jsonb_agg(jsonb_build_object(
                'estabelecimento_id', ec.estabelecimento_id,
                'nome',               e.nome)
                order by e.nome)
         from public.equipe_confianca ec
         join public.estabelecimento e on e.id = ec.estabelecimento_id
        where ec.profissional_id = v_prof.id),
      '[]'::jsonb),
    'notificacoes_no_maximo_a_cada_min', 30,
    'contestacao', v_contestacao
  ) into v_res;

  return v_res;
end $$;

comment on function public.criterios_de_notificacao() is
  'Critérios em vigor que decidem se o profissional recebe notificações de vagas (RF27, RN05, RN06, RN23, LGPD art. 20, 0.2.62). Devolve protocolo da contestação do despacho se existente.';

revoke execute on function public.criterios_de_notificacao() from public, anon;
grant  execute on function public.criterios_de_notificacao() to authenticated;
