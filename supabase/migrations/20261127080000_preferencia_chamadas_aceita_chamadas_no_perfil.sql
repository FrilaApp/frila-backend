-- TcZoKK7i: `privado.perfil_com_servicos` passa a montar `preferencia_chamadas` com `aceita_chamadas` e, quando ligado, `pendencias_para_busca`.
--
-- A definição vigente (20261107370000) montava `preferencia_chamadas` com 4 chaves. Só `definir_preferencia_chamadas` (20261116210000) mandava
-- `aceita_chamadas` e `pendencias_para_busca`, então quem ligava "Aceito chamadas diretas" reabria a tela (`meu_perfil_detalhado`) e a via
-- desligada, no iOS e no Android. O contrato `PreferenciaChamadas` declara os dois campos (`aceita_chamadas` ausente vale false).
--
-- Corpo de 20261107370000 com duas coisas a mais no objeto `preferencia_chamadas`: `'aceita_chamadas', coalesce(pref.aceita_chamadas, false)` e,
-- só com `aceita_chamadas` true, `pendencias_para_busca` (a mesma regra de `definir_preferencia_chamadas`). Assinatura, `language sql stable`,
-- `search_path` e permissões não mudam; sem linha de preferência o objeto continua ausente, como antes.
--
-- Quem chama a função: `meu_perfil_detalhado`, `atualizar_apresentacao_profissional`, `definir_servicos`, `definir_regioes_atendidas` (todas
-- devolvem o perfil do próprio profissional) e `privado.meus_dados` (a exportação do titular passa a trazer as duas chaves).
-- Função de `privado`: não toca a superfície pública do contrato.

create or replace function privado.perfil_com_servicos(prof public.profissional) returns jsonb
language sql stable set search_path = '' as $$
 select public.perfil_profissional_em_json(prof) || jsonb_build_object(
  'apresentacao', prof.apresentacao, 'onde_trabalhei', prof.onde_trabalhei, 'experiencia_faixa', prof.experiencia_faixa,
  'cursos', to_jsonb(coalesce(prof.cursos, '{}'::text[])), 'idiomas', to_jsonb(coalesce(prof.idiomas, '{}'::text[])),
  'atende_todo_df', prof.atende_todo_df,
  'regioes', coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from public.profissional_regiao pr
    join public.regiao_administrativa r on r.id = pr.regiao_id where pr.profissional_id = prof.id), '[]'::jsonb),
  'servicos', coalesce((select jsonb_agg(jsonb_strip_nulls(to_jsonb(s) - array['profissional_id','funcao_id','extras','atualizado_em']) ||
    jsonb_build_object('funcao', to_jsonb(f) - 'ativo', 'especialidades', coalesce((select jsonb_agg(to_jsonb(e) order by e.nome)
      from public.profissional_servico_especialidade se join public.especialidade e on e.id = se.especialidade_id
      where se.profissional_id = s.profissional_id and se.funcao_id = s.funcao_id), '[]'::jsonb)) order by f.nome)
    from public.profissional_servico s join public.funcao f on f.id = s.funcao_id
    where s.profissional_id = prof.id), '[]'::jsonb))
  || coalesce(
    (select jsonb_build_object('preferencia_chamadas', jsonb_build_object(
      'aceita_de_quem_ja_trabalhou', pref.aceita_de_quem_ja_trabalhou,
      'pausado_ate', pref.pausado_ate,
      'antecedencia_minima_h', pref.antecedencia_minima_h,
      'aceita_de', pref.aceita_de,
      -- "Aceito chamadas diretas" (0.2.88): a tela lê o que o `definir_preferencia_chamadas` gravou; ausente valeria false.
      'aceita_chamadas', coalesce(pref.aceita_chamadas, false)
    )
    -- `pendencias_para_busca` só vem com `aceita_chamadas` true: a mesma regra de `definir_preferencia_chamadas`.
    || case when coalesce(pref.aceita_chamadas, false)
         then jsonb_build_object('pendencias_para_busca', privado.pendencias_para_busca(pref.profissional_id))
         else '{}'::jsonb end)
    from public.profissional_preferencia_chamada pref
    where pref.profissional_id = prof.id),
    '{}'::jsonb
  )
$$;
