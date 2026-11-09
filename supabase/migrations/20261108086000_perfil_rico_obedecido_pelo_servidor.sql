-- O servidor obedece à chave perfil_rico (contrato 0.2.60, RecursosDoApp.perfil_rico; RN46).
--
-- Com a chave desligada, o contrato manda que as quatro operações da F2 respondam
-- `403 sem_permissao` (`recurso_desligado`) e que PerfilPublico venha sem os campos ricos.
-- Até aqui nenhuma operação conferia a chave (isenção "trava ainda não ativa" no portão de
-- contrato): só a tela do app obedecia. A chave nasce desligada no #437 (20261108085000).
--
-- Antes de travar, conferido que nenhum app em uso chama essas operações com a chave desligada:
-- iOS 1.0 da loja (ea009618, build 20261104.141059) não conhece as quatro RPCs; iOS 1.1 (main
-- df3bc77c e PR #712 d0e13931) só as chama atrás de suportaPerfilRico, que nasce false e vem do
-- servidor; Android não as chama. O PerfilPublico do iOS 1.0, do 1.1 e do Android decodifica sem
-- os campos ricos (todos opcionais ou desconhecidos). Detalhe no PR.
--
-- Ordem das recusas, como nas RPCs de chamada: 401, 403 recurso_desligado, 422 perfil, 403 suspensa.
-- Corpos copiados das versões vigentes (20261107330000, 20261107100000, 20261107360000), com só a
-- linha da trava e a condição do perfil público acrescentadas. Nenhuma assinatura muda.

select set_config('lock_timeout', '2s', true);

-- ── 1. Os auxiliares do interruptor ───────────────────────────────────────────

create or replace function privado.recurso_ligado(p_chave text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select r.ligado from privado.recurso r where r.chave = p_chave), false)
$$;
comment on function privado.recurso_ligado(text) is
  'Se o interruptor de recurso do servidor está ligado (privado.recurso). Chave ausente é desligada.';
revoke all on function privado.recurso_ligado(text) from public, anon, authenticated;
grant execute on function privado.recurso_ligado(text) to service_role;

create or replace function privado.exigir_recurso(p_chave text) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not privado.recurso_ligado(p_chave) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
end $$;
comment on function privado.exigir_recurso(text) is
  'Recusa com 403 sem_permissao (recurso_desligado) quando o interruptor está desligado (RN46).';
revoke all on function privado.exigir_recurso(text) from public, anon, authenticated;
grant execute on function privado.exigir_recurso(text) to service_role;

-- ── 2. As quatro operações da F2 ──────────────────────────────────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.atualizar_apresentacao_profissional 0.2.63

create or replace function public.atualizar_apresentacao_profissional(jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
 v_c alias for $1;
 v_uid uuid := (select auth.uid()); v_prof public.profissional; v_campo text; v_valor jsonb; v_txt text;
 v_cursos text[]; v_idiomas text[];
begin
 if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
 perform privado.exigir_recurso('perfil_rico');   -- RN46, contrato 0.2.60
 perform privado.exigir_perfil('profissional');
 if exists (select 1 from public.usuario where id = v_uid and estado = 'suspensa') then
  perform public.erro(403, 'sem_permissao', 'conta_suspensa'); end if;
 if v_c is null or jsonb_typeof(v_c) <> 'object' or v_c = '{}'::jsonb then
  perform public.erro(422, 'campo_obrigatorio', 'nenhum_campo'); end if;
 for v_campo in select jsonb_object_keys(v_c) loop
  if v_campo <> all (array['apresentacao','onde_trabalhei','experiencia_faixa','cursos','idiomas']) then
   perform public.erro(422, 'campo_invalido', 'campo_desconhecido'); end if;
 end loop;
 select * into v_prof from public.profissional where usuario_id = v_uid for update;
 if not found then perform public.erro(404, 'nao_encontrado'); end if;

 foreach v_campo in array array['apresentacao','onde_trabalhei','experiencia_faixa'] loop
  v_valor := v_c -> v_campo;
  if v_valor is not null and jsonb_typeof(v_valor) not in ('string','null') then
   perform public.erro(422, 'campo_invalido', v_campo); end if;
  v_txt := v_c ->> v_campo;
  if v_campo <> 'experiencia_faixa' and not (privado.texto_aceitavel(v_txt) and privado.texto_sem_contato_ou_pix(v_txt)) then
   perform public.erro(422, 'campo_invalido', v_campo); end if;
 end loop;
 foreach v_campo in array array['cursos','idiomas'] loop
  v_valor := v_c -> v_campo;
  if v_valor is not null and (jsonb_typeof(v_valor) not in ('array','null')
     or exists (select 1 from jsonb_array_elements(case when jsonb_typeof(v_valor) = 'array' then v_valor else '[]' end) e
                where jsonb_typeof(e) <> 'string')) then
   perform public.erro(422, 'campo_invalido', v_campo); end if;
 end loop;
 if jsonb_typeof(v_c -> 'cursos') = 'array' then
  select array_agg(x) into v_cursos from jsonb_array_elements_text(v_c -> 'cursos') x;
  if exists (select 1 from unnest(v_cursos) c where not (privado.texto_aceitavel(c) and privado.texto_sem_contato_ou_pix(c))) then
   perform public.erro(422, 'campo_invalido', 'cursos'); end if;
 end if;
 if jsonb_typeof(v_c -> 'idiomas') = 'array' then
  select array_agg(x) into v_idiomas from jsonb_array_elements_text(v_c -> 'idiomas') x;
  if cardinality(v_idiomas) <> (select count(distinct x) from unnest(v_idiomas) x) then
   perform public.erro(422, 'campo_invalido', 'idiomas'); end if;
 end if;

 -- Cada CHECK vira recusa contratual com o campo responsável (tamanho, faixa, lista fechada).
 begin
  update public.profissional p set
   apresentacao = case when v_c ? 'apresentacao' then v_c ->> 'apresentacao' else p.apresentacao end,
   onde_trabalhei = case when v_c ? 'onde_trabalhei' then v_c ->> 'onde_trabalhei' else p.onde_trabalhei end,
   experiencia_faixa = case when v_c ? 'experiencia_faixa' then v_c ->> 'experiencia_faixa' else p.experiencia_faixa end,
   cursos = case when v_c ? 'cursos' then v_cursos else p.cursos end,
   idiomas = case when v_c ? 'idiomas' then v_idiomas else p.idiomas end
  where p.id = v_prof.id returning * into v_prof;
 exception when check_violation then
  get stacked diagnostics v_campo = constraint_name;
  perform public.erro(422, 'campo_invalido', regexp_replace(v_campo, '^profissional_|_check$', '', 'g'));
 end;
 return privado.perfil_com_servicos(v_prof);
end $$;


-- contrato: corpo-sem-mudanca-de-superficie public.definir_servicos 0.2.63

create or replace function public.definir_servicos(servicos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
 v_uid uuid := (select auth.uid()); v_prof public.profissional; v_item jsonb; v_s public.profissional_servico;
 v_campo text; v_unidade text; v_permitidos text[]; v_exigidos text[]; v_ids uuid[]; v_vistos uuid[] := '{}'::uuid[];
begin
 if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
 perform privado.exigir_recurso('perfil_rico');   -- RN46, contrato 0.2.60
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


-- contrato: corpo-sem-mudanca-de-superficie public.definir_regioes_atendidas 0.2.63

create or replace function public.definir_regioes_atendidas(regioes int[], atende_todo_df boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_prof public.profissional;
begin
 if v_uid is null then perform public.erro(401,'nao_autenticado'); end if;
 perform privado.exigir_recurso('perfil_rico');   -- RN46, contrato 0.2.60
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


-- contrato: corpo-sem-mudanca-de-superficie public.meu_perfil_detalhado 0.2.63

create or replace function public.meu_perfil_detalhado()
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_prof public.profissional%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'anonimizada') then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_recurso('perfil_rico');   -- RN46, contrato 0.2.60

  perform privado.exigir_perfil('profissional');

  select * into v_prof from public.profissional p where p.usuario_id = v_uid;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  return privado.perfil_com_servicos(v_prof);
end $$;


-- ── 3. PerfilPublico sem os campos ricos com a chave desligada ────────────────

create or replace function privado.perfil_publico_profissional(prof uuid)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid         uuid := (select auth.uid());
  v_res         jsonb;
  p             public.profissional%rowtype;
  u             public.usuario%rowtype;
  v_tem_f2      boolean;
  v_bloqueado   boolean;
begin
  select * into p from public.profissional where id = prof;
  if not found then return null; end if;
  select * into u from public.usuario where id = p.usuario_id;

  v_res := jsonb_build_object(
    'id',   p.id,
    'tipo', 'profissional',
    'nome', case when u.estado = 'anonimizada' then 'Conta encerrada' else u.nome end,
    'funcoes', coalesce((select jsonb_agg(f.nome order by f.nome)
                           from public.profissional_funcao pf
                           join public.funcao f on f.id = pf.funcao_id
                          where pf.profissional_id = p.id), '[]'::jsonb),
    'reputacao', jsonb_build_object(
      'positivas',           p.aval_positivas,
      'total',               p.aval_total,
      'taxa_comparecimento', p.taxa_comparecimento,
      'turnos_realizados',   p.turnos_realizados,
      'turnos_considerados', p.turnos_realizados
                             + (select count(*) from public.posicao x
                                 where x.profissional_id = p.id and x.falta))
  );

  -- Bloqueio mútuo em qualquer direção com o leitor ou estabelecimentos do leitor:
  if v_uid is not null then
    v_bloqueado := exists (
      select 1 from public.bloqueio b
       where (b.autor_id = v_uid and b.bloqueado_id = p.usuario_id)
          or (b.autor_id = p.usuario_id and b.bloqueado_id = v_uid)
    ) or exists (
      select 1 from public.membro_estabelecimento me
       where me.usuario_id = v_uid
         and privado.bloqueado_com_estabelecimento(p.usuario_id, me.estabelecimento_id)
    );
  else
    v_bloqueado := false;
  end if;

  -- Se o alvo NÃO está anonimizado/encerrado, o leitor está autenticado,
  -- NÃO há bloqueio mútuo, o leitor possui vínculo legítimo e o profissional preencheu dados F2:
  -- Perfil rico desligado (contrato 0.2.60): PerfilPublico só com a base, sem os campos da F2.
  if u.estado <> 'anonimizada'
     and privado.recurso_ligado('perfil_rico')
     and v_uid is not null
     and not v_bloqueado
     and privado.contratante_com_vinculo_leitura(p.id, v_uid) then

    v_tem_f2 := (
      p.apresentacao is not null
      or p.onde_trabalhei is not null
      or p.experiencia_faixa is not null
      or (p.cursos is not null and cardinality(p.cursos) > 0)
      or (p.idiomas is not null and cardinality(p.idiomas) > 0)
      or p.atende_todo_df
      or exists (select 1 from public.profissional_servico where profissional_id = p.id)
      or exists (select 1 from public.profissional_regiao where profissional_id = p.id)
    );

    if v_tem_f2 then
      v_res := v_res || jsonb_build_object(
        'apresentacao', p.apresentacao,
        'onde_trabalhei', p.onde_trabalhei,
        'experiencia_faixa', p.experiencia_faixa,
        'cursos', to_jsonb(coalesce(p.cursos, '{}'::text[])),
        'idiomas', to_jsonb(coalesce(p.idiomas, '{}'::text[])),
        'atende_todo_df', p.atende_todo_df,
        'no_frila_desde', to_char(u.criado_em, 'YYYY-MM'),
        'regioes', coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
                               from public.profissional_regiao pr
                               join public.regiao_administrativa r on r.id = pr.regiao_id
                              where pr.profissional_id = p.id), '[]'::jsonb),
        'servicos', coalesce((select jsonb_agg(jsonb_strip_nulls(to_jsonb(s) - array['profissional_id','funcao_id','extras','atualizado_em']) ||
                             jsonb_build_object('funcao', to_jsonb(f) - 'ativo', 'especialidades', coalesce((select jsonb_agg(to_jsonb(e) order by e.nome)
                               from public.profissional_servico_especialidade se join public.especialidade e on e.id = se.especialidade_id
                               where se.profissional_id = s.profissional_id and se.funcao_id = s.funcao_id), '[]'::jsonb)) order by f.nome)
                             from public.profissional_servico s join public.funcao f on f.id = s.funcao_id
                            where s.profissional_id = p.id), '[]'::jsonb)
      );
    end if;
  end if;

  return v_res;
end $$;

