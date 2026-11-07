-- F2 · contrato 0.2.53 · RN26/RN38/RN39/RN25 (CD-S08). "Sobre mim" do profissional e o filtro de
-- contato e Pix. Enums e tamanhos seguem o contrato (ExperienciaFaixa, Idioma, ApresentacaoDoProfissional).
-- `atende_todo_df` já existe desde a migração de serviços e regiões; esta não o recria.

-- CHECK não aceita subconsulta: a regra das listas vive numa função imutável, e o CHECK só a chama.
create function privado.cursos_validos(cursos text[]) returns boolean
language sql immutable set search_path = '' as $$
 select cursos is null or (coalesce(cardinality(cursos), 0) <= 5
  and not exists (select 1 from unnest(cursos) c where c is null or length(c) > 80))
$$;
comment on function privado.cursos_validos(text[]) is
 'Até 5 cursos, cada um com até 80 caracteres e sem item nulo (RN26). Usada só pelo CHECK profissional_cursos_check.';
revoke execute on function privado.cursos_validos(text[]) from public, anon, authenticated;

alter table public.profissional
 add column apresentacao text constraint profissional_apresentacao_check
  check (apresentacao is null or length(apresentacao) <= 600),
 add column onde_trabalhei text constraint profissional_onde_trabalhei_check
  check (onde_trabalhei is null or length(onde_trabalhei) <= 400),
 add column experiencia_faixa text constraint profissional_experiencia_faixa_check
  check (experiencia_faixa is null or experiencia_faixa in
   ('menos_de_1_ano','de_1_a_3_anos','de_3_a_5_anos','de_5_a_10_anos','mais_de_10_anos')),
 add column cursos text[] constraint profissional_cursos_check check (privado.cursos_validos(cursos)),
 add column idiomas text[] constraint profissional_idiomas_check
  check (idiomas is null or idiomas <@ array['portugues','ingles','espanhol','libras','outro']::text[]);
comment on column public.profissional.apresentacao is
 '"Sobre mim" em texto livre, até 600 caracteres. Passa pelo filtro de termos e de contato/Pix (RN38). Visível só a contratante com vínculo de leitura (RN39).';
comment on column public.profissional.onde_trabalhei is
 'Onde o profissional já trabalhou, texto livre de até 400 caracteres, com o mesmo filtro de apresentacao (RN38).';
comment on column public.profissional.experiencia_faixa is 'Faixa de tempo de experiência declarada, do catálogo fechado do contrato.';
comment on column public.profissional.cursos is 'Até 5 cursos ou certificados de até 80 caracteres, declarados pelo próprio profissional.';
comment on column public.profissional.idiomas is 'Idiomas declarados, de lista fechada (português, inglês, espanhol, Libras, outro).';

-- RN38: filtro de contato e Pix. Verdadeiro quando o texto está LIMPO. Reaproveita o detector de
-- telefone, e-mail e link da RN10 e acrescenta o que ele deixa passar: chave aleatória do Pix (UUID,
-- que o detector mascara de propósito), @ de perfil e telefone escrito por extenso. CPF/CNPJ e
-- telefone em dígitos já caem no detector (8 ou mais dígitos com separadores).
create function privado.texto_sem_contato_ou_pix(texto text) returns boolean
language plpgsql immutable security definer set search_path = '' as $$
declare
 v_min text := lower(coalesce(texto, ''));
 -- Intervalo de anos ("2019-2023", "2019 a 2023") não é telefone, a menos que venha colado a um DDD.
 v_sem_anos text := regexp_replace(coalesce(texto, ''),
  '(?<![0-9)+])(?<![0-9)+] )\y(19|20)\d{2}\s*(-|–|até|a)\s*(19|20)\d{2}\y', ' ', 'g');
begin
 if v_min = '' then return true; end if;
 if privado.contem_contato_ou_link(v_sem_anos) then return false; end if;
 if v_min ~ '[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}' then return false; end if;
 if position('@' in v_min) > 0 then return false; end if;
 if v_min ~ '((\y(zero|um|uma|dois|duas|tres|três|quatro|cinco|seis|sete|oito|nove)\y|[0-9])[^[:alnum:]]*){8,}' then
  return false; end if;
 return true;
end $$;
comment on function privado.texto_sem_contato_ou_pix(text) is
 'Verdadeiro quando o texto não traz telefone, e-mail, link, @ nem chave Pix (RN38). Nunca grava nem registra o texto recebido (RN15).';
revoke execute on function privado.texto_sem_contato_ou_pix(text) from public, anon, authenticated;
grant execute on function privado.texto_sem_contato_ou_pix(text) to service_role;

-- O montador do perfil passa a ler as colunas novas (antes devolvia cursos e idiomas vazios).
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
$$;

-- O corpo é o objeto do contrato (campos no topo), e o PostgREST o entrega inteiro a um parâmetro
-- jsonb sem nome. É a única forma de separar "omitido" (fica como está) de `null` (limpa o campo).
create function public.atualizar_apresentacao_profissional(jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
 v_c alias for $1;
 v_uid uuid := (select auth.uid()); v_prof public.profissional; v_campo text; v_valor jsonb; v_txt text;
 v_cursos text[]; v_idiomas text[];
begin
 if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
 perform privado.exigir_perfil('profissional');
 if exists (select 1 from public.usuario where id = v_uid and estado = 'suspensa') then
  perform public.erro(403, 'sem_permissao', 'conta_suspensa'); end if;
 if v_c is null or jsonb_typeof(v_c) <> 'object' or v_c = '{}'::jsonb then
  perform public.erro(422, 'campo_obrigatorio', 'nenhum_campo'); end if;
 for v_campo in select jsonb_object_keys(v_c) loop
  if v_campo <> all (array['apresentacao','onde_trabalhei','experiencia_faixa','cursos','idiomas']) then
   perform public.erro(422, 'campo_invalido', v_campo); end if;
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
comment on function public.atualizar_apresentacao_profissional(jsonb) is
 '"Sobre mim", onde trabalhou, experiência, cursos e idiomas do próprio profissional (RN26, RN38). Campo enviado substitui, omitido fica, null limpa. Devolve PerfilProfissionalDetalhado.';
revoke all on function public.atualizar_apresentacao_profissional(jsonb) from public, anon;
grant execute on function public.atualizar_apresentacao_profissional(jsonb) to authenticated;
