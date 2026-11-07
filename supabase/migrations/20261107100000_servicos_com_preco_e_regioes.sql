-- F2 · contrato 0.2.53 · RN26/RN27/RN38/RN44. Não altera a elegibilidade RN05.
alter table public.profissional add column if not exists atende_todo_df boolean not null default false;
comment on column public.profissional.atende_todo_df is
 'Indica se o profissional atende todo o Distrito Federal (RN26). Se true, regiões específicas são dispensadas.';
create table public.profissional_servico (
 profissional_id uuid not null references public.profissional(id) on delete cascade,
 funcao_id uuid not null references public.funcao(id) on delete cascade,
 primary key (profissional_id, funcao_id),
 foreign key (profissional_id, funcao_id) references public.profissional_funcao on delete cascade,
 unidade text not null check (unidade in ('hora','diaria','evento','pacote','por_pessoa','a_combinar')),
 valor_centavos integer check (valor_centavos is null or valor_centavos between 1000 and 1000000),
 valor_max_centavos integer constraint profissional_servico_valor_max_centavos_check check (valor_max_centavos is null or (valor_max_centavos between 1000 and 1000000 and valor_max_centavos >= valor_centavos)),
 horas_incluidas smallint check (horas_incluidas is null or horas_incluidas between 4 and 12),
 minimo_horas smallint check (minimo_horas is null or minimo_horas between 1 and 12),
 minimo_pessoas smallint check (minimo_pessoas is null or minimo_pessoas >= 1),
 ate_pessoas smallint check (ate_pessoas is null or ate_pessoas >= 1),
 duracao_tipica_h smallint check (duracao_tipica_h is null or duracao_tipica_h between 1 and 24),
 descricao_pacote text check (descricao_pacote is null or length(descricao_pacote) <= 120),
 inclui text check (inclui is null or length(inclui) <= 300),
 leva_material text check (leva_material is null or leva_material in ('sim','nao','depende')),
 extras jsonb,
 atualizado_em timestamptz not null default privado.agora()
);
create table public.profissional_servico_especialidade (
 profissional_id uuid not null, funcao_id uuid not null,
 especialidade_id uuid not null references public.especialidade(id) on delete cascade,
 primary key (profissional_id, funcao_id, especialidade_id),
 foreign key (profissional_id, funcao_id) references public.profissional_servico on delete cascade
);
create table public.profissional_regiao (
 profissional_id uuid not null references public.profissional(id) on delete cascade,
 regiao_id smallint not null references public.regiao_administrativa(id) on delete cascade,
 primary key (profissional_id, regiao_id)
);
comment on table public.profissional_servico is 'Serviços e preços públicos de referência oferecidos pelo profissional (RN27). Sem custódia ou desconto.';
comment on table public.profissional_servico_especialidade is 'Especialidades do catálogo escolhidas pelo profissional para apresentar seus serviços (RN44).';
comment on table public.profissional_regiao is 'Regiões públicas de atendimento declaradas pelo profissional (RN26), sem rastrear localização.';
alter table public.profissional_servico enable row level security;
alter table public.profissional_servico_especialidade enable row level security;
alter table public.profissional_regiao enable row level security;
create policy profissional_servico_select on public.profissional_servico for select to authenticated using (profissional_id = (select privado.meu_profissional_id()));
create policy profissional_servico_especialidade_select on public.profissional_servico_especialidade for select to authenticated using (profissional_id = (select privado.meu_profissional_id()));
create policy profissional_regiao_select on public.profissional_regiao for select to authenticated using (profissional_id = (select privado.meu_profissional_id()));
revoke all on public.profissional_servico, public.profissional_servico_especialidade, public.profissional_regiao from anon, authenticated;
grant select on public.profissional_servico, public.profissional_servico_especialidade, public.profissional_regiao to authenticated;

-- Montador restrito às RPCs: os campos ricos ainda sem persistência ficam vazios.
create function privado.perfil_com_servicos(prof public.profissional) returns jsonb
language sql stable set search_path = '' as $$
 select public.perfil_profissional_em_json(prof) || jsonb_build_object(
  'cursos', '[]'::jsonb, 'idiomas', '[]'::jsonb, 'atende_todo_df', prof.atende_todo_df,
  'regioes', coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from public.profissional_regiao pr
    join public.regiao_administrativa r on r.id = pr.regiao_id where pr.profissional_id = prof.id), '[]'::jsonb),
  'servicos', coalesce((select jsonb_agg(jsonb_strip_nulls(to_jsonb(s) - array['profissional_id','funcao_id','extras','atualizado_em']) ||
    jsonb_build_object('funcao', to_jsonb(f) - 'ativo', 'especialidades', coalesce((select jsonb_agg(to_jsonb(e) order by e.nome)
      from public.profissional_servico_especialidade se join public.especialidade e on e.id = se.especialidade_id
      where se.profissional_id = s.profissional_id and se.funcao_id = s.funcao_id), '[]'::jsonb)) order by f.nome)
    from public.profissional_servico s join public.funcao f on f.id = s.funcao_id
    where s.profissional_id = prof.id), '[]'::jsonb))
$$;
revoke all on function privado.perfil_com_servicos(public.profissional) from public, anon, authenticated;

create function public.definir_servicos(servicos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
 v_uid uuid := (select auth.uid()); v_prof public.profissional; v_item jsonb; v_s public.profissional_servico;
 v_campo text; v_unidade text; v_permitidos text[]; v_exigidos text[]; v_ids uuid[]; v_vistos uuid[] := '{}'::uuid[];
begin
 if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
 perform privado.exigir_perfil('profissional');
 if exists (select 1 from public.usuario where id = v_uid and estado = 'suspensa') then
  perform public.erro(403, 'sem_permissao', 'conta_suspensa'); end if;
 select * into v_prof from public.profissional where usuario_id = v_uid for update;
 if not found then perform public.erro(404, 'nao_encontrado'); end if;
 if servicos is null or jsonb_typeof(servicos) <> 'array' then perform public.erro(422, 'campo_invalido', 'servicos'); end if;
 if jsonb_array_length(servicos) > 10 then perform public.erro(422, 'campo_invalido', 'servicos'); end if;
 delete from public.profissional_servico where profissional_id = v_prof.id;
 for v_item in select value from jsonb_array_elements(servicos) loop
  if jsonb_typeof(v_item) <> 'object' then perform public.erro(422, 'campo_invalido', 'servicos'); end if;
  begin v_s.funcao_id := (v_item->>'funcao_id')::uuid;
  exception when invalid_text_representation then perform public.erro(422, 'campo_invalido', 'funcao_id'); end;
  if not exists (select 1 from public.profissional_funcao where profissional_id = v_prof.id and funcao_id = v_s.funcao_id) then
   perform public.erro(422, 'funcao_nao_marcada', v_item->>'funcao_id'); end if;
  if v_s.funcao_id = any(v_vistos) then perform public.erro(422, 'campo_invalido', 'servicos'); end if;
  v_vistos := array_append(v_vistos, v_s.funcao_id); v_unidade := v_item->>'unidade';
  v_permitidos := case v_unidade
   when 'hora' then array['valor_max_centavos','minimo_horas'] when 'diaria' then array['valor_max_centavos','horas_incluidas']
   when 'evento' then array['duracao_tipica_h','ate_pessoas'] when 'pacote' then array['descricao_pacote','valor_max_centavos']
   when 'por_pessoa' then array['minimo_pessoas'] when 'a_combinar' then '{}'::text[] else null end;
  if v_permitidos is null then perform public.erro(422, 'campo_invalido', 'unidade'); end if;
  v_exigidos := case v_unidade when 'diaria' then array['valor_centavos','horas_incluidas']
   when 'pacote' then array['valor_centavos','descricao_pacote'] when 'por_pessoa' then array['valor_centavos','minimo_pessoas']
   when 'a_combinar' then '{}'::text[] else array['valor_centavos'] end;
  foreach v_campo in array v_exigidos loop
   if v_item->>v_campo is null then perform public.erro(422, 'campo_invalido', v_campo); end if;
  end loop;
  for v_campo in select jsonb_object_keys(v_item) loop
   if v_campo = 'valor_centavos' and v_unidade = 'a_combinar' and v_item->>v_campo is not null then
    perform public.erro(422, 'campo_invalido', v_campo); end if;
   if not (v_campo = any(v_permitidos || array['funcao_id','unidade','valor_centavos','inclui','leva_material','especialidade_ids'])) then
    perform public.erro(422, 'campo_invalido', v_campo); end if;
   if v_campo = any(array['valor_centavos','valor_max_centavos','horas_incluidas','minimo_horas','duracao_tipica_h','ate_pessoas','minimo_pessoas'])
      and v_item->>v_campo is not null then
    if jsonb_typeof(v_item->v_campo) <> 'number' or (v_item->>v_campo) !~ '^[0-9]+$' then
     perform public.erro(422, 'campo_invalido', v_campo); end if;
   end if;
   if v_campo = any(array['descricao_pacote','inclui','leva_material']) and jsonb_typeof(v_item->v_campo) <> 'string' then
    perform public.erro(422, 'campo_invalido', v_campo); end if;
  end loop;
  perform privado.exigir_texto_aceitavel(jsonb_build_object('descricao_pacote',v_item->>'descricao_pacote','inclui',v_item->>'inclui'));
  if v_item ? 'especialidade_ids' then
   if jsonb_typeof(v_item->'especialidade_ids') <> 'array' then perform public.erro(422,'campo_invalido','especialidade_ids'); end if;
   if jsonb_array_length(v_item->'especialidade_ids') > 8 then perform public.erro(422,'campo_invalido','especialidade_ids'); end if;
  end if;
  begin select coalesce(array_agg(value::uuid), '{}') into v_ids from jsonb_array_elements_text(v_item->'especialidade_ids');
  exception when invalid_text_representation then perform public.erro(422,'campo_invalido','especialidade_ids'); end;
  if exists (select 1 from unnest(v_ids) x where not exists (select 1 from public.especialidade e where e.id = x and e.funcao_id = v_s.funcao_id))
     or cardinality(v_ids) <> (select count(distinct x) from unnest(v_ids) x) then
   perform public.erro(422,'campo_invalido','especialidade_ids'); end if;
  -- Cada conversão e CHECK vira recusa contratual com o campo responsável.
  begin
   select * into v_s from jsonb_populate_record(null::public.profissional_servico, v_item || jsonb_build_object('profissional_id',v_prof.id,'atualizado_em',privado.agora()));
   if v_s.ate_pessoas > 2000 then perform public.erro(422,'campo_invalido','ate_pessoas'); end if;
   if v_s.minimo_pessoas > 2000 then perform public.erro(422,'campo_invalido','minimo_pessoas'); end if;
   insert into public.profissional_servico select v_s.*;
  exception when check_violation then
   get stacked diagnostics v_campo = constraint_name;
   perform public.erro(422,'campo_invalido', regexp_replace(v_campo, '^profissional_servico_|_check$', '', 'g'));
   when numeric_value_out_of_range then perform public.erro(422,'campo_invalido','servicos');
  end;
  insert into public.profissional_servico_especialidade select v_prof.id,v_s.funcao_id,x from unnest(v_ids) x;
 end loop;
 return privado.perfil_com_servicos(v_prof);
end $$;
revoke all on function public.definir_servicos(jsonb) from public, anon;
grant execute on function public.definir_servicos(jsonb) to authenticated;

create function public.definir_regioes_atendidas(regioes int[], atende_todo_df boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_prof public.profissional;
begin
 if v_uid is null then perform public.erro(401,'nao_autenticado'); end if;
 perform privado.exigir_perfil('profissional');
 if exists (select 1 from public.usuario where id = v_uid and estado = 'suspensa') then
  perform public.erro(403,'sem_permissao','conta_suspensa'); end if;
 select * into v_prof from public.profissional where usuario_id = v_uid for update;
 if not found then perform public.erro(404,'nao_encontrado'); end if;
 if not coalesce(atende_todo_df,false) and exists (select 1 from unnest(regioes) x
    where not exists (select 1 from public.regiao_administrativa r where r.id = x and r.ativo)) then
  perform public.erro(422,'campo_invalido','regioes'); end if;
 update public.profissional p set atende_todo_df = coalesce(definir_regioes_atendidas.atende_todo_df,false) where p.id = v_prof.id returning * into v_prof;
 delete from public.profissional_regiao where profissional_id = v_prof.id;
 if not v_prof.atende_todo_df then
  insert into public.profissional_regiao select distinct v_prof.id,x from unnest(regioes) x; end if;
 return privado.perfil_com_servicos(v_prof);
end $$;
revoke all on function public.definir_regioes_atendidas(int[],boolean) from public, anon;
grant execute on function public.definir_regioes_atendidas(int[],boolean) to authenticated;
