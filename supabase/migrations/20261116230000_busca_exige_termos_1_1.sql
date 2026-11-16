-- A busca só para contratante que aceitou os Termos 1.1 (B-027.g, PR 3; I6 do pedido 2026-11-16-12 do Cauê).
--
-- Decisão do Cauê (16/11/2026): conta que ainda não aceitou os Termos 1.1 não usa a busca de profissionais
-- ("o app ainda não está em produção, ninguém usa seriamente: faça o que deve ser feito").
--
-- Onde o aceite mora (lido em 16/11/2026): `public.usuario.termos_versao`, um texto com a DATA da publicação
-- que a tela exibiu, gravado por `criar_conta` (20260923000000 e as reescritas até 20261018190000) junto com
-- `termos_aceite_em`. Não há RPC de novo aceite nem tabela de histórico: cada conta guarda UMA versão.
-- O app 1.2 grava `2026-11-13` (frila-frontend #758; `CadastroViewModel.swift:144`), a data em que os Termos 1.1
-- e a Política 1.2 foram publicados (frila-docs, `juridico/termos-de-uso-v1.0.1.md`, cabeçalho: "o valor fica
-- e passa a querer dizer Termos 1.1 + Política 1.2"). Antes: `2026-10-15` (1.0) e `2026-11-12` (Termos 1.0.1).
-- Logo, "aceitou a 1.1" = `termos_versao` em formato AAAA-MM-DD e >= `2026-11-13` (a data compara como texto).
--
--   1. privado.termos_minimos_da_busca() e privado.aceitou_termos(usuario, versao_minima): o fato num lugar só;
--      privado.termos_publicadas(): a lista de versões que aceitar_termos aceita.
--      A conta de demonstração conta como tendo aceitado: é nossa, isolada da população real, e é o login
--      que a revisão da Apple usa (hoje com `2026-09-22`; as funções de renovação da demonstração a recriam
--      com esse valor, então atualizar o dado não duraria).
--   2. buscar_profissionais recusa quem não aceitou: 403 sem_permissao, details termos_pendentes, depois de
--      conta e perfil e antes de qualquer filtro (e do contador de buscas por hora).
--   3. chamar_profissional pelo caminho da BUSCA (sem turno cumprido nem equipe de confiança com a casa)
--      recusa do mesmo jeito. O caminho do vínculo NÃO muda. A recusa olha só quem chama, não o profissional.
--   4. O perfil rico: estar na busca só vale como vínculo de leitura para contratante que aceitou a 1.1
--      (privado.contratante_com_vinculo_leitura, caso 5; contrato 0.2.90).
--   5. public.aceitar_termos(termos_versao): quem já tem conta aceita uma versão PUBLICADA (AAAA-MM-DD, na lista
--      privado.termos_publicadas(); hoje 2026-11-13), com o instante do servidor. Idempotente; o aceite não volta
--      atrás. O histórico (privado.termos_aceite, chave única conta+versão, preenchido por gatilho em public.usuario
--      e com os aceites de hoje copiados) guarda o aceite do cadastro ao lado do novo, fora da anonimização.
--   6. public.conta_em_json (o Usuario de minha_conta e criar_conta) devolve termos_versao.
--
-- Só muda o trecho da trava: os dois corpos são os do #518 (20261116210000 e 20261116220000), com `create or
-- replace` (mesma assinatura). Contrato 0.2.90 (frila-documentacao #262): `403 sem_permissao` com `termos_pendentes`.

select set_config('lock_timeout', '2s', true);

-- ── 1. O fato ─────────────────────────────────────────────────────────────────

create function privado.termos_minimos_da_busca()
returns text
language sql
immutable
set search_path = ''
as $$ select '2026-11-13'::text $$;
comment on function privado.termos_minimos_da_busca() is
  'A versão mínima dos Termos e da Política (data da publicação, AAAA-MM-DD) para usar a busca de profissionais: 2026-11-13, os Termos 1.1 e a Política 1.2 (I6, 16/11/2026). Não sobe sozinha quando sai versão nova: subir a barra é decisão e migração próprias.';
revoke all on function privado.termos_minimos_da_busca() from public, anon, authenticated;
grant execute on function privado.termos_minimos_da_busca() to service_role;

create function privado.aceitou_termos(p_usuario uuid, p_versao_minima text)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select coalesce((select u.demonstracao
                       or (u.termos_versao ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                           and u.termos_versao collate "C" >= p_versao_minima collate "C")
                     from public.usuario u
                    where u.id = p_usuario), false)
$$;
comment on function privado.aceitou_termos(uuid, text) is
  'A conta aceitou os Termos na versão mínima ou numa mais nova? termos_versao é a data da publicação (AAAA-MM-DD, texto); valor fora desse formato (ex.: "1.0") não conta. Conta de demonstração conta como aceito. Conta inexistente: falso (I6, 16/11/2026).';
revoke all on function privado.aceitou_termos(uuid, text) from public, anon, authenticated;
grant execute on function privado.aceitou_termos(uuid, text) to service_role;

-- Versões PUBLICADAS dos Termos e da Política (data da publicação). aceitar_termos só aceita uma delas
-- (contrato 0.2.90). Publicar versão nova é uma migração que acrescenta a data aqui.
create function privado.termos_publicadas()
returns text[]
language sql
immutable
set search_path = ''
as $$ select array['2026-11-13']::text[] $$;
comment on function privado.termos_publicadas() is
  'As versões dos Termos e da Política publicadas que aceitar_termos aceita (contrato 0.2.90): hoje só 2026-11-13. As anteriores (2026-10-15, 2026-11-12) foram aceitas no cadastro e ficam no histórico, mas não se aceitam mais.';
revoke all on function privado.termos_publicadas() from public, anon, authenticated;
grant execute on function privado.termos_publicadas() to service_role;

-- O histórico dos aceites: um por conta e versão. usuario.termos_versao e termos_aceite_em seguem sendo o
-- ÚLTIMO aceite (é o que criar_conta grava e o que Usuario devolve); cada aceite novo, do cadastro ou de
-- aceitar_termos, cai aqui por gatilho, então aceitar a 1.1 nunca apaga o aceite do cadastro: ele continua
-- consultável. Fica FORA da anonimização e da limpeza dos 15 dias: é prova de obrigação legal, como as colunas
-- de usuario (a anonimização atualiza a linha de usuario, não a apaga, e ninguém mexe nesta tabela).
create table privado.termos_aceite (
  usuario_id uuid        not null references public.usuario (id) on delete cascade,
  versao     text        not null check (btrim(versao) <> ''),
  aceito_em  timestamptz not null,
  primary key (usuario_id, versao)
);
comment on table privado.termos_aceite is
  'Histórico dos aceites dos Termos e da Política: um por conta e versão (chave única), com o instante do servidor. Alimentado por gatilho em public.usuario (cadastro e aceitar_termos). Não é apagado na anonimização nem na limpeza de 15 dias (prova de obrigação legal; a linha não identifica a pessoa sozinha). Contrato 0.2.90.';
alter table privado.termos_aceite enable row level security;
revoke all on privado.termos_aceite from public, anon, authenticated;

-- Quem já tem conta: o aceite que está em usuario hoje vira a primeira linha do histórico.
insert into privado.termos_aceite (usuario_id, versao, aceito_em)
select u.id, u.termos_versao, u.termos_aceite_em from public.usuario u
on conflict (usuario_id, versao) do nothing;

create function privado.registrar_aceite_termos()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into privado.termos_aceite (usuario_id, versao, aceito_em)
  values (new.id, new.termos_versao, new.termos_aceite_em)
  on conflict (usuario_id, versao) do nothing;
  return new;
end $$;
revoke all on function privado.registrar_aceite_termos() from public, anon, authenticated;

create trigger registrar_aceite_termos
  after insert or update of termos_versao on public.usuario
  for each row execute function privado.registrar_aceite_termos();

-- ── 2. A busca ────────────────────────────────────────────────────────────────

create or replace function public.buscar_profissionais(
  estabelecimento_id uuid default null,
  funcao_id          uuid default null,
  regiao_id          int default null,
  inicio_em          timestamptz default null,
  fim_em             timestamptz default null,
  cursor             text default null,
  limite             int default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_agora    timestamptz := privado.agora();
  v_dia      text := to_char(privado.agora() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD');
  v_estab    uuid := buscar_profissionais.estabelecimento_id;
  v_funcao   uuid := buscar_profissionais.funcao_id;
  v_regiao   smallint;
  v_inicio   timestamptz := buscar_profissionais.inicio_em;
  v_fim      timestamptz := buscar_profissionais.fim_em;
  v_cursor   text := buscar_profissionais.cursor;
  v_limite   int := coalesce(buscar_profissionais.limite, 20);
  v_demo     boolean;
  v_chave    bytea;
  v_filtros  text;
  v_payload  jsonb;
  v_texto    text;
  v_assin    text;
  v_entregue int := 0;
  v_c_grupo  int;
  v_c_faixa  int;
  v_c_ordem  text;
  v_c_prof   uuid;
  v_total    int;
  v_pagina   int;
  v_linhas   jsonb;
  v_itens    jsonb;
  v_ultimo   jsonb;
  v_proximo  text;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  -- A busca chama quem está nela: só vale com a chamada direta também ligada (0.2.88).
  if not (privado.recurso_ligado('busca_profissionais') and privado.recurso_ligado('chamada_direta')) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
  -- Conta anonimizada ou inexistente: 401; suspensa: 403 conta_suspensa (RN13).
  perform privado.exigir_conta_ativa();
  -- CD-B01: só contratante busca; profissional não busca profissional.
  if privado.perfil_da_conta() is distinct from 'contratante' then
    perform public.erro(403, 'sem_permissao');
  end if;
  -- I6 (pedido 2026-11-16-12 do Cauê): a busca só vale para quem aceitou os Termos 1.1. Vem depois de conta e
  -- perfil e antes de qualquer filtro (e do contador de 60 por hora: a recusa não gasta busca).
  if not privado.aceitou_termos(v_uid, privado.termos_minimos_da_busca()) then
    perform public.erro(403, 'sem_permissao', 'termos_pendentes');
  end if;
  if v_estab is null then perform public.erro(422, 'campo_obrigatorio', 'estabelecimento_id'); end if;
  if v_funcao is null then perform public.erro(422, 'campo_obrigatorio', 'funcao_id'); end if;
  -- CD-B01: membro da casa que busca (a casa dá o local da distância e a região padrão).
  if not privado.eh_membro(v_estab) then perform public.erro(403, 'sem_permissao'); end if;

  if not exists (select 1 from public.funcao f where f.id = v_funcao and f.ativo) then
    perform public.erro(422, 'campo_invalido', 'funcao_id');
  end if;

  if buscar_profissionais.regiao_id is not null then
    select r.id into v_regiao from public.regiao_administrativa r
     where r.id = buscar_profissionais.regiao_id and r.ativo;
    if v_regiao is null then perform public.erro(422, 'campo_invalido', 'regiao_id'); end if;
  else
    -- Sem regiao_id, vale a da casa; casa sem região do catálogo não tem padrão.
    select r.id into v_regiao from public.estabelecimento e
      join public.regiao_administrativa r on r.nome = e.regiao_administrativa and r.ativo
     where e.id = v_estab;
    if v_regiao is null then perform public.erro(422, 'campo_obrigatorio', 'regiao_id'); end if;
  end if;

  if v_inicio is null and v_fim is not null then perform public.erro(422, 'campo_invalido', 'inicio_em'); end if;
  if v_fim is null and v_inicio is not null then perform public.erro(422, 'campo_invalido', 'fim_em'); end if;
  if v_inicio is not null then
    if v_inicio <= v_agora then perform public.erro(422, 'campo_invalido', 'inicio_em'); end if;
    if v_fim <= v_inicio then perform public.erro(422, 'campo_invalido', 'fim_em'); end if;
  end if;

  if v_limite < 1 or v_limite > 20 then perform public.erro(422, 'campo_invalido', 'limite'); end if;

  select k.chave into v_chave from privado.chave_cursor_busca k limit 1;
  -- O cursor vale só para a mesma conta, os mesmos filtros e o mesmo dia (America/Sao_Paulo).
  v_filtros := md5(concat_ws('|', v_uid, v_estab, v_funcao, v_regiao, v_inicio, v_fim));

  if v_cursor is not null then
    begin
      v_texto   := translate(split_part(v_cursor, '.', 1), '-_', '+/');
      v_assin   := split_part(v_cursor, '.', 2);
      v_texto   := rpad(v_texto, ((length(v_texto) + 3) / 4) * 4, '=');
      v_payload := convert_from(decode(v_texto, 'base64'), 'UTF8')::jsonb;
      if v_assin is distinct from encode(extensions.hmac(convert_to(v_payload::text, 'UTF8'), v_chave, 'sha256'), 'hex') then
        raise exception 'cursor sem assinatura válida';
      end if;
      v_c_grupo  := (v_payload->>'g')::int;
      v_c_faixa  := (v_payload->>'x')::int;
      v_c_ordem  := v_payload->>'k';
      v_c_prof   := (v_payload->>'p')::uuid;
      v_entregue := (v_payload->>'n')::int;
      -- I3: o cursor vale 15 min; vencido, a página seguinte exige busca nova (que conta no limite).
      if (v_payload->>'e')::timestamptz <= v_agora or (v_payload->>'e') is null
         or v_payload->>'d' is distinct from v_dia or v_payload->>'f' is distinct from v_filtros
         or v_c_grupo is null or v_c_faixa is null or v_c_ordem is null or v_c_prof is null
         or v_entregue is null or v_entregue < 1 or v_entregue >= 200 then
        raise exception 'cursor de outro dia, de outra busca ou malformado';
      end if;
    exception when others then
      perform public.erro(422, 'cursor_invalido');
    end;
  else
    -- CD-B08: só a primeira página conta como busca. Janela FIXA por hora cheia (date_trunc): até 60
    -- de 10:00 a 10:59, e zera às 11:00; na virada, a conta pode fazer até 120 em poucos minutos, o que
    -- o teto de 200 por busca e o cursor de 15 min limitam (escolha da proposta, aprovada pela Forja).
    -- O upsert trava a linha da hora, então duas buscas ao mesmo tempo não passam juntas do 60; acima
    -- dele, o erro desfaz o +1.
    insert into privado.contador_busca as cb (usuario_id, hora, total)
    values (v_uid, date_trunc('hour', v_agora), 1)
    on conflict on constraint contador_busca_pkey do update set total = cb.total + 1
    returning cb.total into v_total;
    if v_total > 60 then perform public.erro(429, 'limite_excedido'); end if;
  end if;

  select u.demonstracao into v_demo from public.usuario u where u.id = v_uid;
  v_pagina := least(v_limite, 200 - v_entregue);

  -- Ordem (CD-B03): (1) a grade cobre o horário; (2) faixa de distância; (3) embaralho por contratante
  -- e por dia, estável no dia. Keyset sobre essa tupla, nunca offset; uma linha a mais diz se há outra
  -- página. A reputação não entra (RN06, D2).
  select coalesce(jsonb_agg(jsonb_build_object('p', q.profissional_id, 'x', q.faixa,
                                               'c', q.cobre, 'g', q.grupo, 'k', q.ordem)
                            order by q.grupo, q.faixa, q.ordem, q.profissional_id), '[]'::jsonb)
    into v_linhas
    from (select t.*
            from (select b.profissional_id, b.faixa, b.cobre,
                         case when b.cobre then 0 else 1 end as grupo,
                         md5(v_uid::text || '|' || v_dia || '|' || b.profissional_id::text) collate "C" as ordem
                    from privado.profissionais_na_busca(v_estab, v_funcao, v_regiao, v_inicio, v_fim,
                                                        coalesce(v_demo, false)) b) t
           where v_cursor is null
              or (t.grupo, t.faixa, t.ordem, t.profissional_id) > (v_c_grupo, v_c_faixa, v_c_ordem collate "C", v_c_prof)
           order by t.grupo, t.faixa, t.ordem, t.profissional_id
           limit v_pagina + 1) q;

  select coalesce(jsonb_agg(privado.cartao_profissional((l.v->>'p')::uuid, v_funcao, (l.v->>'x')::smallint,
                                                        (l.v->>'c')::boolean, v_inicio is not null) order by l.i), '[]'::jsonb)
    into v_itens
    from jsonb_array_elements(v_linhas) with ordinality l(v, i)
   where l.i <= v_pagina;

  -- Próxima página só se sobrou alguém e o teto de 200 por busca não chegou (CD-B08).
  if jsonb_array_length(v_linhas) > v_pagina and v_entregue + v_pagina < 200 then
    v_ultimo  := v_linhas -> (v_pagina - 1);
    v_payload := jsonb_build_object('d', v_dia, 'e', v_agora + interval '15 minutes', 'f', v_filtros,
                                    'g', v_ultimo->'g', 'x', v_ultimo->'x',
                                    'k', v_ultimo->'k', 'p', v_ultimo->'p', 'n', v_entregue + v_pagina);
    v_proximo := translate(encode(convert_to(v_payload::text, 'UTF8'), 'base64'), E'+/=\n', '-_')
                 || '.' || encode(extensions.hmac(convert_to(v_payload::text, 'UTF8'), v_chave, 'sha256'), 'hex');
  end if;

  return jsonb_build_object('itens', v_itens, 'proximo_cursor', v_proximo);
end $$;

comment on function public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int) is
  '0.2.88 e 0.2.90. Busca de profissionais para chamar direto (CD-B01 a CD-B10): serviço obrigatório, região (padrão: a da casa) e horário. Só para quem aceitou os Termos 1.1 (403 sem_permissao, termos_pendentes). Ordem: a grade cobre o horário, faixa de distância, embaralho estável por contratante e dia; a reputação não ordena (RN06). 20 por página por cursor assinado, no máximo 200 por busca e 60 buscas por hora por conta (429 limite_excedido). Os filtros não ficam gravados (CD-B09). POST: a busca grava o contador.';
revoke all on function public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int) from public, anon;
grant execute on function public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int) to authenticated;

-- ── 3. Chamar pela busca ──────────────────────────────────────────────────────

create or replace function public.chamar_profissional(
  chave uuid default null, profissional_id uuid default null, estabelecimento_id uuid default null,
  vaga_id uuid default null, funcao_id uuid default null, inicio_em timestamptz default null,
  fim_em timestamptz default null, local text default null, regiao_administrativa text default null,
  ponto jsonb default null, valor_centavos bigint default null, inclui_refeicao boolean default null,
  inclui_transporte boolean default null, exige_material_proprio boolean default null,
  responsavel_local text default null, recado text default null, confirmo_recorrencia boolean default false,
  regiao_id int default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid            uuid := (select auth.uid());
  v_agora          timestamptz := privado.agora();
  v_estab          uuid := chamar_profissional.estabelecimento_id;
  v_prof           uuid := chamar_profissional.profissional_id;
  v_recado         text := nullif(btrim(chamar_profissional.recado), '');
  v_conta          public.usuario%rowtype;
  v_vaga           public.vaga%rowtype;
  v_c              public.chamada%rowtype;
  v_falta          text;
  v_veterana       boolean;
  v_tem_pref       boolean;
  v_so_cnpj        boolean;
  v_sem_versao     boolean;
  v_sem_vinculo    boolean;
  v_na_busca       boolean;
  v_funcao_busca   uuid;
  v_regiao_busca   smallint;
  v_nao_aceita     boolean;
  v_pref           public.profissional_preferencia_chamada%rowtype;
  v_ant_min_h      int := 6;
  v_casa_doc       text;
  v_turnos_casa    int;
  v_hora_sp        int;
  v_inicio_prazo   timestamptz;
  v_expira_em      timestamptz;
  v_lembrete_em    timestamptz;
  v_janela_efetiva interval;
  v_ultimas_recusas int;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
  perform privado.exigir_perfil('contratante');
  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;
  if chamar_profissional.chave is null then perform public.erro(422, 'campo_obrigatorio', 'chave'); end if;
  if v_prof is null then perform public.erro(422, 'campo_obrigatorio', 'profissional_id'); end if;
  if v_estab is null then perform public.erro(422, 'campo_obrigatorio', 'estabelecimento_id'); end if;
  if not privado.eh_membro(v_estab) then perform public.erro(403, 'sem_permissao'); end if;

  -- Idempotência: reenviar a mesma chave devolve a mesma chamada e não gasta cota.
  select * into v_c from public.chamada c where c.estabelecimento_id = v_estab and c.chave = chamar_profissional.chave;
  if found then return to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em']; end if;

  -- Profissional inexistente, fora do ar ou com bloqueio: o mesmo 404 (RF26).
  select u.* into v_conta from public.profissional p join public.usuario u on u.id = p.usuario_id where p.id = v_prof;
  if not found or v_conta.estado <> 'ativa'
     or privado.bloqueado_com_estabelecimento(v_conta.id, v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- I6 (contrato 0.2.90): com a busca ligada e quem chama sem os Termos 1.1, a busca não conta como caminho.
  -- Sem turno cumprido com presença verificada nem equipe de confiança (fatos que a casa já conhece, e não a
  -- preferência do profissional), a recusa é termos_pendentes. Vem depois do bloqueio (404) e ANTES de qualquer
  -- conferência sobre o profissional, então não revela quem está na busca. Com turno ou equipe vale só o
  -- caminho do vínculo, com as recusas de sempre. Busca desligada: nunca sai.
  if privado.recurso_ligado('busca_profissionais')
     and not privado.aceitou_termos(v_uid, privado.termos_minimos_da_busca())
     and not exists (select 1 from public.turno t join public.posicao p on p.id = t.posicao_id
                       join public.vaga g on g.id = p.vaga_id
                      where g.estabelecimento_id = v_estab and p.profissional_id = v_prof
                        and p.estado = 'cumprida' and t.verificacao = 'verificado')
     and not exists (select 1 from public.equipe_confianca q
                      where q.estabelecimento_id = v_estab and q.profissional_id = v_prof) then
    perform public.erro(403, 'sem_permissao', 'termos_pendentes');
  end if;

  -- 0.2.88: regiao_id é o id do catálogo (ativo) e o nome dele é o regiao_administrativa do corpo. Não
  -- depende do profissional, então a recusa sai antes de qualquer conta dele e não revela nada. Vem
  -- depois do 404 do bloqueio, que tem precedência sobre qualquer outra recusa (CD-C03, RF26). Com
  -- vaga_id, a região é a da vaga e o regiao_id do corpo é ignorado, como o regiao_administrativa.
  if chamar_profissional.vaga_id is null and chamar_profissional.regiao_id is not null
     and not exists (select 1 from public.regiao_administrativa r
                      where r.id = chamar_profissional.regiao_id and r.ativo
                        and (nullif(btrim(chamar_profissional.regiao_administrativa), '') is null
                             or r.nome = btrim(chamar_profissional.regiao_administrativa))) then
    perform public.erro(422, 'campo_invalido', 'regiao_id');
  end if;

  -- Serializa as chamadas da casa: os limites somam os membros (RN34).
  perform 1 from public.estabelecimento e where e.id = v_estab for update;
  -- Serializa também pelo profissional para atomicidade da cota de abertas entre casas distintas (CD-C14)
  perform 1 from public.profissional p where p.id = v_prof for update;
  if exists (select 1 from public.chamada c where c.estabelecimento_id = v_estab
                and c.profissional_id = v_prof and c.estado = 'aberta') then
    perform public.erro(409, 'chamada_ja_aberta');
  end if;

  -- Lê documento da casa
  select documento into v_casa_doc from public.estabelecimento where id = v_estab;

  -- Preferências do profissional (B5e)
  select * into v_pref from public.profissional_preferencia_chamada where profissional_id = v_prof;
  v_tem_pref := found;

  -- As três recusas genéricas (0.2.66): preferência só-CNPJ, versão do app e vínculo (RN28). As três
  -- são calculadas sempre, cada uma na sua variável, e o erro sai uma vez só, antes da validação do
  -- corpo. Assim nem a ordem nem o tempo de resposta denunciam qual delas valeu (revisão do Lince AG
  -- no frila-documentacao #193 e no #451).
  v_so_cnpj := coalesce(v_tem_pref and v_pref.aceita_de = 'so_cnpj' and length(v_casa_doc) = 11, false);
  -- Preferência "aceitar chamadas de quem já trabalhou comigo" desligada (definir_preferencia_chamadas,
  -- 20261107370000): toda chamada direta é de quem já trabalhou com o profissional, então desligar
  -- é não receber chamada. Entra no mesmo bloco genérico (B-019; LGPD art. 6º, VI).
  v_nao_aceita := coalesce(v_tem_pref and not v_pref.aceita_de_quem_ja_trabalhou, false);
  -- Versão: só chama quem tem algum aparelho cuja versao_app alcança o mínimo de chamada_direta da
  -- plataforma; a chamada nunca nasce para quem não receberia o aviso. Sem permissão de notificação o
  -- app não registra aparelho, então esse profissional não pode ser chamado.
  v_sem_versao := not exists (select 1 from public.dispositivo d
                               where d.usuario_id = v_conta.id
                                 and privado.recurso_na_versao('chamada_direta', d.plataforma::text, d.versao_app));
  -- Vínculo (RN28 na v1.1): turno cumprido com presença verificada na casa, ou equipe de confiança.
  -- É daqui que vem o isolamento da demonstração nesta RPC: conta de demonstração não tem turno nem
  -- equipe com a população real.
  v_veterana := exists (select 1 from public.turno t join public.posicao p on p.id = t.posicao_id
                          join public.vaga g on g.id = p.vaga_id
                         where g.estabelecimento_id = v_estab and p.profissional_id = v_prof
                           and p.estado = 'cumprida' and t.verificacao = 'verificado');
  -- 0.2.88: o segundo caminho é estar na busca, sem vínculo de trabalho. Só entra o que a busca decide
  -- sozinho e que esta função não confere adiante: a chave, "Aceito chamadas diretas" sem pausa, o
  -- serviço da função exata, a região do trabalho e a mesma população (a demonstração não chama o
  -- real: o caminho do vínculo isola por vínculo, e este não tem vínculo). O resto do que a busca
  -- exige (só-CNPJ, versão, bloqueio, 5 abertas, chamada aberta, pausa do par, prazo) já é conferido
  -- por esta função para os dois caminhos, cada um com o seu código.
  -- A função e a região são as da vaga direta quando vem vaga_id (2ª e 3ª chamadas), senão as do corpo.
  v_funcao_busca := case when chamar_profissional.vaga_id is not null
                         then (select g.funcao_id from public.vaga g
                                where g.id = chamar_profissional.vaga_id and g.estabelecimento_id = v_estab)
                         else chamar_profissional.funcao_id end;
  -- Com vaga_id vale a região da vaga (o regiao_id do corpo é ignorado); sem ele, o regiao_id ou o nome da região.
  v_regiao_busca := case
    when chamar_profissional.vaga_id is not null
      then (select coalesce(g.regiao_id,
                            (select r.id from public.regiao_administrativa r where r.nome = g.regiao_administrativa and r.ativo))
              from public.vaga g where g.id = chamar_profissional.vaga_id and g.estabelecimento_id = v_estab)
    when chamar_profissional.regiao_id is not null
      then (select r.id from public.regiao_administrativa r where r.id = chamar_profissional.regiao_id and r.ativo)
    else (select r.id from public.regiao_administrativa r
           where r.nome = btrim(chamar_profissional.regiao_administrativa) and r.ativo)
  end;
  v_na_busca := coalesce(
    privado.recurso_ligado('busca_profissionais')
    and v_tem_pref and v_pref.aceita_chamadas
    and (v_pref.pausado_ate is null or v_pref.pausado_ate < (v_agora at time zone 'America/Sao_Paulo')::date)
    and privado.mesma_populacao(v_conta.id)
    and v_funcao_busca is not null
    and exists (select 1 from public.profissional_servico s
                 where s.profissional_id = v_prof and s.funcao_id = v_funcao_busca)
    and v_regiao_busca is not null
    and exists (select 1 from public.profissional pr
                 where pr.id = v_prof
                   and (pr.atende_todo_df
                        or exists (select 1 from public.profissional_regiao pg
                                    where pg.profissional_id = pr.id and pg.regiao_id = v_regiao_busca))), false);
  -- "Aceitar de quem já trabalhou comigo" desligado só vale no caminho do VÍNCULO (contrato 0.2.88): quem
  -- ligou "Aceito chamadas diretas" aceitou qualquer contratante, então esta preferência não o barra.
  v_sem_vinculo := not v_na_busca
                   and (not (v_veterana or exists (select 1 from public.equipe_confianca q
                                                    where q.estabelecimento_id = v_estab and q.profissional_id = v_prof))
                        or v_nao_aceita);
  if v_so_cnpj or v_sem_versao or v_sem_vinculo then
    perform public.erro(422, 'profissional_indisponivel', 'nao_aceita_chamadas');
  end if;

  if v_tem_pref then
    v_ant_min_h := v_pref.antecedencia_minima_h;
    -- Pausa de chamadas: depois do bloco genérico (0.2.66), para só quem passa por ele ver "pausado".
    -- Antes, uma casa sem vínculo descobria que o profissional estava pausado.
    if v_pref.pausado_ate is not null and v_pref.pausado_ate >= (v_agora at time zone 'America/Sao_Paulo')::date then
      perform public.erro(422, 'profissional_indisponivel', 'pausado');
    end if;
  end if;

  -- Limites de par CD-C13 (B5d):
  -- 1. Se houve recusa há menos de 24h, o par está em pausa de 24h.
  if exists (
    select 1 from public.chamada c
     where c.estabelecimento_id = v_estab
       and c.profissional_id = v_prof
       and c.estado = 'recusada'
       and c.respondida_em > v_agora - interval '24 hours'
  ) then
    perform public.erro(422, 'profissional_indisponivel', 'par_em_pausa');
  end if;

  -- 2. Três recusadas/expiradas consecutivas em 30 dias bloqueiam o par por 30 dias
  select count(*) into v_ultimas_recusas
    from (
      select c.estado
        from public.chamada c
       where c.estabelecimento_id = v_estab
         and c.profissional_id = v_prof
         and c.criada_em > v_agora - interval '30 days'
         and c.estado in ('aceita', 'recusada', 'expirada')
       order by c.criada_em desc
       limit 3
    ) u
   where u.estado in ('recusada', 'expirada');

  if v_ultimas_recusas = 3 and not exists (
    select 1 from public.chamada c
     where c.estabelecimento_id = v_estab
       and c.profissional_id = v_prof
       and c.criada_em > v_agora - interval '30 days'
       and c.estado = 'aceita'
  ) then
    perform public.erro(422, 'profissional_indisponivel', 'par_bloqueado_temporariamente');
  end if;

  if chamar_profissional.vaga_id is not null then
    if num_nonnulls(chamar_profissional.funcao_id, chamar_profissional.inicio_em, chamar_profissional.fim_em,
                    chamar_profissional.local, chamar_profissional.ponto, chamar_profissional.valor_centavos) > 0 then
      perform public.erro(422, 'campo_invalido', 'vaga_id');
    end if;
    select * into v_vaga from public.vaga g where g.id = chamar_profissional.vaga_id and g.estabelecimento_id = v_estab;
    if not found then perform public.erro(404, 'nao_encontrado'); end if;
    if v_vaga.origem <> 'chamada_direta' or v_vaga.estado <> 'publicada' or v_vaga.inicio_em <= v_agora
       or not exists (select 1 from public.posicao p where p.vaga_id = v_vaga.id and p.estado = 'aberta') then
      perform public.erro(409, 'vaga_encerrada');
    end if;
    if (select count(*) from public.chamada c where c.vaga_id = v_vaga.id and c.estado = 'aberta') >= 3 then
      perform public.erro(422, 'limite_de_chamadas', 'por_vaga');
    end if;
  else
    -- RN02 com os nomes de NovaVaga: o primeiro campo que falta vai em details.
    select k into v_falta
      from jsonb_each(jsonb_build_object(
             'funcao_id', chamar_profissional.funcao_id, 'inicio_em', chamar_profissional.inicio_em,
             'fim_em', chamar_profissional.fim_em, 'local', nullif(btrim(chamar_profissional.local), ''),
             'regiao_administrativa', nullif(btrim(chamar_profissional.regiao_administrativa), ''),
             'ponto', chamar_profissional.ponto, 'valor_centavos', chamar_profissional.valor_centavos,
             'inclui_refeicao', chamar_profissional.inclui_refeicao,
             'inclui_transporte', chamar_profissional.inclui_transporte,
             'exige_material_proprio', chamar_profissional.exige_material_proprio,
             'responsavel_local', nullif(btrim(chamar_profissional.responsavel_local), ''))) e(k, val)
     where val = 'null'::jsonb order by k limit 1;
    if v_falta is not null then perform public.erro(422, 'campo_obrigatorio', v_falta); end if;
    if chamar_profissional.valor_centavos <= 0 then perform public.erro(422, 'campo_invalido', 'valor_centavos'); end if;
    if not exists (select 1 from public.funcao f where f.id = chamar_profissional.funcao_id) then
      perform public.erro(422, 'campo_invalido', 'funcao_id');
    end if;
    if chamar_profissional.fim_em <= chamar_profissional.inicio_em or chamar_profissional.inicio_em <= v_agora then
      perform public.erro(422, 'horario_invalido');
    end if;
    perform privado.exigir_texto_aceitavel(jsonb_build_object(
      'local', btrim(chamar_profissional.local), 'regiao_administrativa', btrim(chamar_profissional.regiao_administrativa),
      'responsavel_local', btrim(chamar_profissional.responsavel_local)));
    v_vaga.funcao_id := chamar_profissional.funcao_id;
    v_vaga.inicio_em := chamar_profissional.inicio_em;
  end if;

  if not exists (select 1 from public.profissional_funcao pf
                  where pf.profissional_id = v_prof and pf.funcao_id = v_vaga.funcao_id) then
    perform public.erro(422, 'inelegivel', 'funcao_incompativel');
  end if;

  -- Antecedência mínima respeitando a escolha do profissional (mínimo 2h)
  if v_vaga.inicio_em < v_agora + (v_ant_min_h || ' hours')::interval then
    perform public.erro(422, 'profissional_indisponivel', 'antecedencia_insuficiente');
  end if;

  -- Limite do profissional: máximo 5 abertas
  if (select count(*) from public.chamada c where c.profissional_id = v_prof and c.estado = 'aberta') >= 5 then
    perform public.erro(422, 'profissional_indisponivel', 'agenda_cheia');
  end if;

  -- Turnos verificados da casa (CD-C14)
  select count(*) into v_turnos_casa
    from public.turno t
    join public.posicao pos on pos.id = t.posicao_id
    join public.vaga vg on vg.id = pos.vaga_id
   where vg.estabelecimento_id = v_estab
     and pos.estado = 'cumprida'
     and t.verificacao = 'verificado';

  if v_turnos_casa = 0 then
    -- Casa sem turno cumprido: máximo 3 abertas e máximo 5 em 7 dias
    if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab and c.estado = 'aberta') >= 3 then
      perform public.erro(422, 'limite_de_chamadas', 'abertas');
    end if;
    if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab
           and c.criada_em > v_agora - interval '7 days') >= 5 then
      perform public.erro(422, 'limite_de_chamadas', 'por_semana');
    end if;
  else
    -- Casa com turnos: máximo 10 abertas e 20 por dia civil de SP
    if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab and c.estado = 'aberta') >= 10 then
      perform public.erro(422, 'limite_de_chamadas', 'abertas');
    end if;
    if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab
           and (c.criada_em at time zone 'America/Sao_Paulo')::date = (v_agora at time zone 'America/Sao_Paulo')::date) >= 20 then
      perform public.erro(422, 'limite_de_chamadas', 'por_dia');
    end if;
  end if;

  if v_recado is not null then
    if length(v_recado) > 300 then perform public.erro(422, 'campo_invalido', 'recado'); end if;
    perform privado.exigir_texto_aceitavel(jsonb_build_object('recado', v_recado));
  end if;

  -- J7, RN45: a 3ª chamada de casa CPF ao mesmo profissional em 7 dias pede confirmação explícita.
  if length(v_casa_doc) = 11
     and not coalesce(chamar_profissional.confirmo_recorrencia, false)
     and (select count(*) from public.chamada c where c.estabelecimento_id = v_estab
             and c.profissional_id = v_prof and c.criada_em > v_agora - interval '7 days') >= 2 then
    perform public.erro(409, 'recorrencia_nao_confirmada');
  end if;

  -- Cálculo de prazos e lembretes respeitando horário de silêncio em America/Sao_Paulo (B5c)
  v_hora_sp := extract(hour from (v_agora at time zone 'America/Sao_Paulo'))::int;
  if v_hora_sp >= 22 or v_hora_sp < 7 then
    -- No silêncio (22h às 7h): conta a partir das 7h
    v_inicio_prazo := ((v_agora at time zone 'America/Sao_Paulo')::date +
                       (case when v_hora_sp >= 22 then interval '1 day 7 hours' else interval '7 hours' end))
                      at time zone 'America/Sao_Paulo';
    -- Salvo se início da vaga for antes das 10h em SP
    if v_vaga.inicio_em < (v_inicio_prazo + interval '3 hours') then
      v_expira_em := v_vaga.inicio_em - interval '1 hour';
    else
      v_expira_em := least(v_inicio_prazo + interval '12 hours', v_vaga.inicio_em - interval '1 hour');
    end if;
  else
    -- Fora do silêncio
    v_inicio_prazo := v_agora;
    v_expira_em := least(v_agora + interval '12 hours', v_vaga.inicio_em - interval '1 hour');
  end if;

  -- Lembrete: se janela efetiva de resposta for maior que 2h, agenda no ponto médio
  v_janela_efetiva := v_expira_em - v_inicio_prazo;
  if v_janela_efetiva > interval '2 hours' then
    v_lembrete_em := v_inicio_prazo + (v_janela_efetiva / 2);
    -- Se cair no silêncio (22h às 7h), ajusta para fora do silêncio
    if extract(hour from (v_lembrete_em at time zone 'America/Sao_Paulo'))::int >= 22 then
      v_lembrete_em := least(
        ((v_lembrete_em at time zone 'America/Sao_Paulo')::date + interval '21 hours 30 minutes') at time zone 'America/Sao_Paulo',
        v_expira_em - interval '30 minutes'
      );
      if v_lembrete_em <= v_inicio_prazo then
        v_lembrete_em := ((v_lembrete_em at time zone 'America/Sao_Paulo')::date + interval '1 day 7 hours') at time zone 'America/Sao_Paulo';
      end if;
    elsif extract(hour from (v_lembrete_em at time zone 'America/Sao_Paulo'))::int < 7 then
      v_lembrete_em := ((v_lembrete_em at time zone 'America/Sao_Paulo')::date + interval '7 hours') at time zone 'America/Sao_Paulo';
    end if;
    if v_lembrete_em >= v_expira_em then
      v_lembrete_em := null;
    end if;
  else
    v_lembrete_em := null;
  end if;

  if chamar_profissional.vaga_id is null then
    insert into public.vaga (
      estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa, ponto,
      valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
      responsavel_local, modo, publicado_por, publicado_em, chave_cliente, origem, regiao_id)
    values (
      v_estab, chamar_profissional.funcao_id, chamar_profissional.inicio_em, chamar_profissional.fim_em,
      btrim(chamar_profissional.local), btrim(chamar_profissional.regiao_administrativa),
      privado.ponto_do_json(chamar_profissional.ponto, 'ponto'), chamar_profissional.valor_centavos, 1,
      chamar_profissional.inclui_refeicao, chamar_profissional.inclui_transporte,
      chamar_profissional.exige_material_proprio, btrim(chamar_profissional.responsavel_local),
      'urgencia', v_uid, v_agora, chamar_profissional.chave, 'chamada_direta',
      chamar_profissional.regiao_id)
    returning * into v_vaga;
    insert into public.posicao (vaga_id, inicio_em, fim_em) values (v_vaga.id, v_vaga.inicio_em, v_vaga.fim_em);
  end if;

  begin
    insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, recado,
                                expira_em, lembrete_em, criada_em, chave)
    values (v_vaga.id, v_prof, v_estab, v_uid, v_recado,
            v_expira_em, v_lembrete_em, v_agora, chamar_profissional.chave)
    returning * into v_c;
  exception when unique_violation then
    perform public.erro(409, 'chamada_ja_aberta');
  end;

  -- Notificação chamada_recebida (B5c)
  insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
  values (v_conta.id, 'chamada_recebida', v_c.id, jsonb_build_object('chamada_id', v_c.id, 'vaga_id', v_vaga.id))
  on conflict do nothing;

  return to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em'];
end $$;

comment on function public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int) is
  '0.2.56, 0.2.88 e 0.2.90. Chama um profissional direto (RN28, RN34, CD-C13): quem tem vínculo de trabalho com a casa ou, com a chave busca_profissionais ligada, quem está na busca ("Aceito chamadas diretas", sem pausa, com o serviço da função e a região do trabalho). Pelo caminho da busca (sem vínculo), só quem aceitou os Termos 1.1: 403 sem_permissao, termos_pendentes. regiao_id opcional, que a vaga direta guarda. As demais regras valem igual para os dois caminhos; quem não cumpre nenhum recebe a mesma recusa genérica (nao_aceita_chamadas).';
revoke execute on function public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int) from public, anon;
grant  execute on function public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int) to authenticated;

-- ── 4. O perfil rico: a busca só é vínculo de leitura para quem aceitou a 1.1 ─────
-- Corpo de 20261116220000 com uma condição a mais no caso 5. Sem ela, quem não aceitou a 1.1 leria o
-- perfil de quem está na busca pelo id, que é o que a recusa da busca existe para evitar.

create or replace function privado.contratante_com_vinculo_leitura(
  p_prof uuid,
  p_uid  uuid
) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from public.membro_estabelecimento me
     where me.usuario_id = p_uid
       and (
         -- 1. Equipe de confiança da casa
         exists (
           select 1 from public.equipe_confianca ec
            where ec.estabelecimento_id = me.estabelecimento_id
              and ec.profissional_id = p_prof
         )
         -- 2. Candidatura em vaga da casa
         or exists (
           select 1 from public.candidatura c
             join public.posicao pos on pos.id = c.posicao_id
             join public.vaga v on v.id = pos.vaga_id
            where v.estabelecimento_id = me.estabelecimento_id
              and c.profissional_id = p_prof
         )
         -- 3. Turno confirmado/realizado com a casa
         or exists (
           select 1 from public.posicao pos
             join public.vaga v on v.id = pos.vaga_id
            where v.estabelecimento_id = me.estabelecimento_id
              and pos.profissional_id = p_prof
         )
         -- 4. Chamada direta entre a casa e o profissional
         or exists (
           select 1 from public.chamada ch
            where ch.estabelecimento_id = me.estabelecimento_id
              and ch.profissional_id = p_prof
         )
         -- 5. 0.2.88 e 0.2.90: quem ligou "Aceito chamadas diretas" está na busca de qualquer casa. A pausa não
         --    muda isso (o perfil não revela quando ele pausou), e a demonstração não vaza para a
         --    população real nem o contrário (a mesma regra do chamar_profissional pela busca).
         or (privado.recurso_ligado('busca_profissionais')
             and privado.recurso_ligado('chamada_direta')
             -- 0.2.90 (I6): a busca só vale como vínculo de leitura para quem aceitou os Termos 1.1.
             and privado.aceitou_termos(p_uid, privado.termos_minimos_da_busca())
             and exists (select 1 from public.profissional_preferencia_chamada pc
                           join public.profissional pr on pr.id = pc.profissional_id
                           join public.usuario u on u.id = pr.usuario_id
                          where pc.profissional_id = p_prof and pc.aceita_chamadas
                            and u.estado = 'ativa')
             and privado.mesma_populacao(privado.usuario_do_profissional(p_prof)))
       )
  );
$$;

comment on function privado.contratante_com_vinculo_leitura(uuid, uuid) is
  'Verifica se o usuário é contratante com vínculo legítimo de leitura com o profissional: equipe de confiança, candidatura em vaga da casa, turno, chamada direta ou, desde a 0.2.88, o profissional estar na busca ("Aceito chamadas diretas" ligado, com ou sem pausa) e, desde a 0.2.90, só para quem aceitou os Termos 1.1. Não vale para a foto (0.2.54).';

-- ── 5. aceitar_termos ─────────────────────────────────────────────────────────

create function public.aceitar_termos(termos_versao text default null)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_versao text := nullif(btrim(aceitar_termos.termos_versao), '');
  v_conta  public.usuario%rowtype;
  v_agora  timestamptz := privado.agora();
  v_em     timestamptz;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  -- Trava a linha da conta: dois aceites ao mesmo tempo viram um só.
  select * into v_conta from public.usuario u where u.id = v_uid for update;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;
  -- Anonimizada: 401. Suspensa pode aceitar: o contrato 0.2.90 não promete 403 aqui, aceitar os Termos não
  -- é o que a suspensão (RN13) barra, e a busca já recusa a conta suspensa por conta própria.
  if v_conta.estado = 'anonimizada' then perform public.erro(401, 'nao_autenticado'); end if;
  if v_versao is null then perform public.erro(422, 'campo_obrigatorio', 'termos_versao'); end if;
  -- Só uma versão PUBLICADA, no formato AAAA-MM-DD: o app não aceita pela pessoa uma versão que o servidor
  -- não conhece (a lista é privado.termos_publicadas(); hoje só 2026-11-13).
  if v_versao !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or not (v_versao = any (privado.termos_publicadas())) then
    perform public.erro(422, 'campo_invalido', 'termos_versao');
  end if;
  -- O aceite não volta atrás: conta que já aceitou versão mais nova (data maior) não troca por esta.
  if v_conta.termos_versao ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
     and v_conta.termos_versao collate "C" > v_versao collate "C" then
    perform public.erro(422, 'campo_invalido', 'termos_versao');
  end if;
  -- Repetir a mesma versão devolve o aceite que já existe no histórico, sem gravar de novo (o instante não anda).
  select a.aceito_em into v_em from privado.termos_aceite a where a.usuario_id = v_uid and a.versao = v_versao;
  if found then
    return jsonb_build_object('termos_versao', v_versao, 'aceito_em', v_em);
  end if;
  -- O aceite anterior (o do cadastro) já está no histórico: o gatilho guarda este ao lado dele. usuario passa a
  -- mostrar o último.
  update public.usuario u set termos_versao = v_versao, termos_aceite_em = v_agora where u.id = v_uid;
  return jsonb_build_object('termos_versao', v_versao, 'aceito_em', v_agora);
end $$;

comment on function public.aceitar_termos(text) is
  '0.2.90. Quem já tem conta aceita uma versão PUBLICADA dos Termos e da Política (AAAA-MM-DD, privado.termos_publicadas(); hoje 2026-11-13). Grava o aceite no histórico (privado.termos_aceite, um por conta e versão) e atualiza o último aceite em usuario.termos_versao e termos_aceite_em, com o instante do servidor; o aceite do cadastro continua no histórico. Idempotente: a mesma versão devolve o aceite existente. Versão vazia: 422 campo_obrigatorio; fora do formato, não publicada ou mais antiga que a já aceita: 422 campo_invalido (termos_versao). Sessão sem conta: 404. POST: grava.';
revoke execute on function public.aceitar_termos(text) from public, anon;
grant  execute on function public.aceitar_termos(text) to authenticated;

-- ── 6. Usuario.termos_versao ──────────────────────────────────────────────────
-- A leitura do usuário (minha_conta e a resposta de criar_conta, que usam esta função) devolve a última
-- versão aceita, para o app saber se precisa pedir o aceite. O instante não sai (contrato 0.2.90).

create or replace function public.conta_em_json(u public.usuario)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'id',            u.id,
    'perfil',        u.perfil,
    'nome',          u.nome,
    'telefone',      u.telefone,
    'email',         u.email,
    'nascimento',    u.nascimento,
    'estado',        u.estado,
    'termos_versao', u.termos_versao)
$$;
revoke execute on function public.conta_em_json(public.usuario) from public, anon, authenticated;
