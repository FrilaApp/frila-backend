-- F2 · contrato 0.2.53 · RN26/RN38/RN39/RN25 (CD-S08). "Sobre mim" do profissional e o filtro de
-- contato e Pix. Enums e tamanhos seguem o contrato (ExperienciaFaixa, Idioma, ApresentacaoDoProfissional).
-- `atende_todo_df` já existe desde a migração de serviços e regiões; esta não o recria.

set lock_timeout = '2s';

-- CHECK não aceita subconsulta: a regra das listas vive numa função imutável, e o CHECK só a chama.
create or replace function privado.cursos_validos(cursos text[]) returns boolean
language sql immutable set search_path = '' as $$
 select cursos is null or (coalesce(cardinality(cursos), 0) <= 5
  and not exists (select 1 from unnest(cursos) c where c is null or length(c) > 80))
$$;
comment on function privado.cursos_validos(text[]) is
 'Até 5 cursos, cada um com até 80 caracteres e sem item nulo (RN26). Usada só pelo CHECK profissional_cursos_check.';
revoke execute on function privado.cursos_validos(text[]) from public, anon, authenticated;

alter table public.profissional
 add column if not exists apresentacao text,
 add column if not exists onde_trabalhei text,
 add column if not exists experiencia_faixa text,
 add column if not exists cursos text[],
 add column if not exists idiomas text[];

-- Adiciona constraints com NOT VALID para evitar segurar AccessExclusiveLock por tempo excessivo.
-- A validação ocorre na migração 20261107330001 subsequente.
alter table public.profissional
 add constraint profissional_apresentacao_check
  check (apresentacao is null or length(apresentacao) <= 600) not valid,
 add constraint profissional_onde_trabalhei_check
  check (onde_trabalhei is null or length(onde_trabalhei) <= 400) not valid,
 add constraint profissional_experiencia_faixa_check
  check (experiencia_faixa is null or experiencia_faixa in
   ('menos_de_1_ano','de_1_a_3_anos','de_3_a_5_anos','de_5_a_10_anos','mais_de_10_anos')) not valid,
 add constraint profissional_cursos_check
  check (privado.cursos_validos(cursos)) not valid,
 add constraint profissional_idiomas_check
  check (idiomas is null or idiomas <@ array['portugues','ingles','espanhol','libras','outro']::text[]) not valid;

comment on column public.profissional.apresentacao is
 '"Sobre mim" em texto livre, até 600 caracteres. Passa pelo filtro de termos e de contato/Pix (RN38). Visível só a contratante com vínculo de leitura (RN39).';
comment on column public.profissional.onde_trabalhei is
 'Onde o profissional já trabalhou, texto livre de até 400 caracteres, com o mesmo filtro de apresentacao (RN38).';
comment on column public.profissional.experiencia_faixa is 'Faixa de tempo de experiência declarada, do catálogo fechado do contrato.';
comment on column public.profissional.cursos is 'Até 5 cursos ou certificados de até 80 caracteres, declarados pelo próprio profissional.';
comment on column public.profissional.idiomas is 'Idiomas declarados, de lista fechada (português, inglês, espanhol, Libras, outro).';

-- RN38: filtro de contato e Pix blindado com mapeamento Unicode Nd e TLDs comuns.
create or replace function privado.texto_sem_contato_ou_pix(texto text) returns boolean
language plpgsql immutable security definer set search_path = '' as $$
declare
  v_norm text;
  v_de_digitos text;
  v_para_digitos text;
begin
  if texto is null or texto = '' then return true; end if;

  -- 1. Normalização Unicode NFKC (decompõe e recompõe para forma canônica de compatibilidade)
  v_norm := normalize(texto, NFKC);

  -- 2. Remoção de caracteres invisíveis e de formatação (U+200B-U+200F, U+2028-U+202F, U+2060-U+206F, U+FE00-U+FE0F, U+FEFF, U+00AD, U+180E)
  v_norm := regexp_replace(v_norm, '[\u200B-\u200F\u2028-\u202F\u2060-\u206F\uFE00-\uFE0F\uFEFF\u00AD\u180E]', '', 'g');

  -- 3. Minúsculas
  v_norm := lower(v_norm);

  -- 4. Mapear TODO dígito Unicode (blocos Nd comuns) para ASCII 0-9
  v_de_digitos := '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹०१२३४५६७८९০১২৩৪৫৬৭৮৯੦੧੨੩੪੫੬੭੮੯૦૧૨૩૪૫૬૭૮૯୦୧୨୩୪୫୬୭୮୯௦௧௨௩௪௫௬௭௮௯౦౧౨౩౪౫౬౭౮౯೦೧೨೩೪೫೬೭೮೯൦൧൨൩൪൫൬൭൮൯๐๑๒๓๔๕๖๗๘๙';
  v_para_digitos := repeat('0123456789', 12);
  v_norm := translate(v_norm, v_de_digitos, v_para_digitos);

  -- 5. Transliteração de homóglifos cirílicos comuns em domínios/e-mails
  v_norm := translate(v_norm, 'асеорху', 'aceopxy');

  -- 6. Tratamento de variantes de arroba e ponto em texto (sem converter preposição 'at' em inglês)
  v_norm := regexp_replace(v_norm, '(\(at\)|\[at\]|\s+arroba\s+|[＠﹫])', '@', 'g');
  v_norm := regexp_replace(v_norm, '\s+ponto\s+', '.', 'g');

  -- 7. @ é proibido (handles de redes sociais e e-mails)
  if position('@' in v_norm) > 0 then return false; end if;

  -- 8. Chave aleatória Pix (UUID de 32 hexadecimais com ou sem hífens)
  if v_norm ~ '[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}' then return false; end if;
  if v_norm ~ '\y[0-9a-f]{32}\y' then return false; end if;

  -- 9. URLs e domínios com TLDs comuns (com ou sem esquema)
  if v_norm ~ '(https?://|www\.)[^\s]+'
     or v_norm ~ '\y(wa\.me|bit\.ly|t\.me|linktr\.ee)\y'
     or v_norm ~ '\y[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.(com\.br|com|br|net|org|site|xyz|app|link|me|io|co|tv|ly|gl|bio|shop|online|store|info|dev|cc|page)\M' then
    return false;
  end if;

  -- 10. Sequências de 10 ou mais dígitos com separadores (espaço, ponto, hífen, parênteses, barra, +, _):
  -- REJEITADA SEMPRE, sem exceção por palavra vizinha (reais, R$, etc.)
  if v_norm ~ '([0-9][[:space:].\-/()+_]*){10,}' then
    return false;
  end if;

  -- 11. De 8 a 9 dígitos com palavra de contato a até 20 caracteres
  if v_norm ~ '(\y(zap|whats|whatsapp|wpp|tel|cel|celular|fone|telefone|ligue|chama|contato|pix)\y[^0-9]{0,20}([0-9][[:space:].\-/()+_]*){8,9})|(([0-9][[:space:].\-/()+_]*){8,9}[^0-9]{0,20}\y(zap|whats|whatsapp|wpp|tel|cel|celular|fone|telefone|ligue|chama|contato|pix)\y)' then
    return false;
  end if;

  -- 12. Números por extenso (zero, um, dois... sequências de 8+)
  if v_norm ~ '((\y(zero|um|uma|dois|duas|tr[eê]s|quatro|cinco|seis|sete|oito|nove)\y)[^[:alnum:]]*){8,}' then
    return false;
  end if;

  return true;
end $$;
comment on function privado.texto_sem_contato_ou_pix(text) is
 'Verdadeiro quando o texto não traz telefone, e-mail, link, @ nem chave Pix (RN38). Mapeia todo dígito Unicode Nd para ASCII e normaliza em NFKC antes de validar. Nunca grava nem registra o texto recebido (RN15).';
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
create or replace function public.atualizar_apresentacao_profissional(jsonb) returns jsonb
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
comment on function public.atualizar_apresentacao_profissional(jsonb) is
 '"Sobre mim", onde trabalhou, experiência, cursos e idiomas do próprio profissional (RN26, RN38). Campo enviado substitui, omitido fica, null limpa. Devolve PerfilProfissionalDetalhado.';
revoke all on function public.atualizar_apresentacao_profissional(jsonb) from public, anon;
grant execute on function public.atualizar_apresentacao_profissional(jsonb) to authenticated;

-- P1-2: Ciclo de exclusão e expurgo. Atualiza privado.limpar_contas_anonimizadas para incluir
-- os campos novos da F2 (apresentacao, onde_trabalhei, experiencia_faixa, cursos, idiomas).
create or replace function privado.limpar_contas_anonimizadas(p_dias integer default 15)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_candidato record;
  v_total     integer := 0;
begin
  for v_candidato in
    select u.id, p.id as profissional_id
      from public.usuario u
      left join public.profissional p on p.usuario_id = u.id
     where u.estado = 'anonimizada'
       and u.anonimizado_em <= privado.agora() - (p_dias || ' days')::interval
       and (
         u.nascimento is not null
         or p.ponto_base is not null
         or p.apresentacao is not null
         or p.onde_trabalhei is not null
         or p.experiencia_faixa is not null
         or p.cursos is not null
         or p.idiomas is not null
         or exists (select 1 from public.disponibilidade d where d.profissional_id = p.id)
         or exists (select 1 from public.profissional_funcao pf where pf.profissional_id = p.id)
         or exists (select 1 from public.dispositivo disp where disp.usuario_id = u.id)
         or exists (select 1 from public.ocorrencia o
                     where o.autor_id = u.id
                       and (o.motivo <> '[removido por exclusão de conta]' or o.relato is not null))
         or exists (
           select 1 from public.vaga g
            where g.publicado_por = u.id
              and (
                (
                  not (
                    (g.estado = 'publicada' and g.inicio_em > privado.agora())
                    or exists (
                      select 1 from public.posicao po
                       join public.turno tu on tu.posicao_id = po.id
                      where po.vaga_id = g.id
                        and po.estado <> 'cancelada'
                        and tu.checkout_em is null
                        and po.fim_em + interval '7 days' >= privado.agora()
                    )
                  )
                  and (
                    g.responsavel_local <> '[removido por exclusão de conta]'
                    or g.traje is not null
                    or g.observacoes is not null
                  )
                )
                or (
                  g.local <> '[removido por exclusão de conta]'
                  and not (
                    (g.estado = 'publicada' and g.inicio_em > privado.agora())
                    or exists (
                      select 1 from public.posicao po
                       join public.turno tu on tu.posicao_id = po.id
                      where po.vaga_id = g.id
                        and (
                          (po.estado <> 'cancelada'
                           and tu.checkout_em is null
                           and po.fim_em + interval '7 days' >= privado.agora())
                          or tu.verificacao = 'verificado'
                        )
                    )
                  )
                )
              )
         )
       )
  loop
    -- Ativa sinal de sessão para permitir substituição de dados imutáveis sob retenção
    perform set_config('privado.retencao', 'on', true);

    -- 1. Apaga disponibilidade semanal, funções, ponto base e os campos de perfil do profissional
    if v_candidato.profissional_id is not null then
      delete from public.disponibilidade where profissional_id = v_candidato.profissional_id;
      delete from public.profissional_funcao where profissional_id = v_candidato.profissional_id;
      update public.profissional
         set ponto_base = null,
             apresentacao = null,
             onde_trabalhei = null,
             experiencia_faixa = null,
             cursos = null,
             idiomas = null
       where id = v_candidato.profissional_id;
    end if;

    -- 2. Apaga aparelhos registrados
    delete from public.dispositivo where usuario_id = v_candidato.id;

    -- 3. Substitui o motivo das ocorrências de autoria dela pelo marcador neutro e
    --    apaga o relato da denúncia
    update public.ocorrencia
       set motivo = '[removido por exclusão de conta]',
           relato = null
     where autor_id = v_candidato.id
       and (motivo <> '[removido por exclusão de conta]' or relato is not null);

    -- 4. Zera data de nascimento
    update public.usuario
       set nascimento = null
     where id = v_candidato.id;

    -- 5. Sanitiza texto livre das vagas publicadas pelo titular excluído (K-001, K-001f, K-001h)
    update public.vaga g
       set responsavel_local = case
                                 when exists (
                                   select 1 from public.posicao po
                                    join public.turno tu on tu.posicao_id = po.id
                                   where po.vaga_id = g.id
                                     and po.estado <> 'cancelada'
                                     and tu.checkout_em is null
                                     and po.fim_em + interval '7 days' >= privado.agora()
                                 ) then g.responsavel_local
                                 else '[removido por exclusão de conta]'
                               end,
           traje             = case
                                 when exists (
                                   select 1 from public.posicao po
                                    join public.turno tu on tu.posicao_id = po.id
                                   where po.vaga_id = g.id
                                     and po.estado <> 'cancelada'
                                     and tu.checkout_em is null
                                     and po.fim_em + interval '7 days' >= privado.agora()
                                 ) then g.traje
                                 else null
                               end,
           observacoes       = case
                                 when exists (
                                   select 1 from public.posicao po
                                    join public.turno tu on tu.posicao_id = po.id
                                   where po.vaga_id = g.id
                                     and po.estado <> 'cancelada'
                                     and tu.checkout_em is null
                                     and po.fim_em + interval '7 days' >= privado.agora()
                                 ) then g.observacoes
                                 else null
                               end,
           local             = case
                                 when exists (
                                   select 1 from public.posicao po
                                    join public.turno tu on tu.posicao_id = po.id
                                   where po.vaga_id = g.id
                                     and (
                                       (po.estado <> 'cancelada'
                                        and tu.checkout_em is null
                                        and po.fim_em + interval '7 days' >= privado.agora())
                                       or tu.verificacao = 'verificado'
                                     )
                                 ) then g.local
                                 else '[removido por exclusão de conta]'
                               end
     where g.publicado_por = v_candidato.id
       and (
         (
           not (
             (g.estado = 'publicada' and g.inicio_em > privado.agora())
             or exists (
               select 1 from public.posicao po
                join public.turno tu on tu.posicao_id = po.id
               where po.vaga_id = g.id
                 and po.estado <> 'cancelada'
                 and tu.checkout_em is null
                 and po.fim_em + interval '7 days' >= privado.agora()
             )
           )
           and (
             g.responsavel_local <> '[removido por exclusão de conta]'
             or g.traje is not null
             or g.observacoes is not null
           )
         )
         or (
           g.local <> '[removido por exclusão de conta]'
           and not (
             (g.estado = 'publicada' and g.inicio_em > privado.agora())
             or exists (
               select 1 from public.posicao po
                join public.turno tu on tu.posicao_id = po.id
               where po.vaga_id = g.id
                 and (
                   (po.estado <> 'cancelada'
                    and tu.checkout_em is null
                    and po.fim_em + interval '7 days' >= privado.agora())
                   or tu.verificacao = 'verificado'
                 )
             )
           )
         )
       );

    perform set_config('privado.retencao', 'off', true);
    v_total := v_total + 1;
  end loop;

  return v_total;
end $$;
comment on function privado.limpar_contas_anonimizadas(integer) is
 'Apaga disponibilidade, funções, aparelhos, zera nascimento, ponto base, apresentacao, onde_trabalhei, experiencia_faixa, cursos e idiomas, substitui motivo e apaga relato de ocorrências e sanitiza texto livre de vagas após p_dias dias (LGPD art. 6º, III e art. 18, IV).';
revoke execute on function privado.limpar_contas_anonimizadas(integer) from public, anon, authenticated;
grant execute on function privado.limpar_contas_anonimizadas(integer) to service_role;
