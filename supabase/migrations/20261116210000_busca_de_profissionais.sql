-- Busca de profissionais (B-027, contrato 0.2.88 do frila-documentacao #259; pedido do Cauê 2026-11-16-03).
--
-- O contratante procura por serviço (obrigatório), região e horário e recebe cartões de quem a chamada
-- aceitaria. Spec: historico/produto/contratacao-direta/01-especificacao.md, CD-B01 a CD-B11, e
-- 02-modelo-de-perfil.md, CD-P09, CD-P10 e CD-P14.
--
-- O que esta migração faz:
--   1. profissional_preferencia_chamada ganha "Aceito chamadas diretas" (aceita_chamadas, padrão false
--      para todos, inclusive quem já tem linha: é opt-in, CD-P10), o instante e a versão do texto que o
--      profissional viu na última vez que ligou; privado.registro_aceita_chamadas guarda CADA vez que
--      liga (registro do pedido do titular, LGPD art. 7º, V, parecer J1).
--   2. A chave busca_profissionais nasce DESLIGADA em privado.recurso e pode ter versão mínima por
--      plataforma; configuracao_do_app passa a devolvê-la, e ela só vem true com chamada_direta true.
--   3. definir_preferencia_chamadas aceita aceita_chamadas e versao_texto_busca e responde
--      pendencias_para_busca (o que ainda falta para aparecer).
--   4. Helpers no privado, sem grant a anon/authenticated: grade_cobre (a regra da grade do despacho,
--      privado.elegiveis em 20261104030000:172-202, num lugar só), pendencias_para_busca,
--      profissionais_na_busca (quem entra, só pela função exata, com a faixa de distância e o selo; o
--      chamar_profissional do próximo PR reusa com p_profissional), nome_curto e reputacao_profissional.
--   5. public.buscar_profissionais: volátil e por POST, porque conta a busca (o PostgREST roda GET em
--      transação só-leitura, e o contador é escrita). Ordem: selo da grade, faixa de distância,
--      embaralho estável por contratante e por dia. A reputação não ordena (RN06, D2).
--   6. privado.contador_busca (só o contador; os filtros não ficam gravados, CD-B09) e
--      privado.chave_cursor_busca (chave aleatória do HMAC do cursor, gerada aqui, nunca no repo).
--   7. privado.cartao_profissional monta o cartão (CD-B07) por lista explícita de campos, sem contato,
--      ponto base, nascimento nem foto. O cursor é assinado e vale 15 min.
--   8. Job pg_cron limpar_contador_busca, às 08:13 UTC (05:13 em Brasília): apaga as horas com mais de
--      um dia.
--   9. privado.meus_dados exporta registros_aceita_chamadas, e a limpeza da conta excluída (15 dias)
--      apaga o registro e a preferência da busca (decisão da Bússola, 16/11/2026).
--
-- Fica para o PR seguinte (contrato 0.2.88): chamar_profissional aceitar quem está na busca, e
-- perfil_publico contar a busca como vínculo de leitura do perfil rico. A foto não entra no cartão.

select set_config('lock_timeout', '2s', true);

-- ── 1. "Aceito chamadas diretas" ──────────────────────────────────────────────

alter table public.profissional_preferencia_chamada
  add column aceita_chamadas    boolean not null default false,
  add column aceita_chamadas_em timestamptz,
  add column versao_texto_busca text;

comment on column public.profissional_preferencia_chamada.aceita_chamadas is
  'Aceito chamadas diretas (CD-P10, contrato 0.2.88): põe o profissional na busca. Opt-in: nasce false, inclusive para as linhas que já existiam.';
comment on column public.profissional_preferencia_chamada.aceita_chamadas_em is
  'Instante da última vez que o profissional ligou aceita_chamadas (registro do pedido do titular, LGPD art. 7º, V; parecer J1). Desligar não apaga.';
comment on column public.profissional_preferencia_chamada.versao_texto_busca is
  'Versão do texto da tela que o profissional viu na última vez que ligou aceita_chamadas (CD-P11). Desligar não apaga.';

-- Cada vez que o profissional liga, uma linha: o registro do pedido do titular (contrato 0.2.88:
-- "guarda a versão e o instante de cada vez que liga"; LGPD art. 7º, V, parecer J1). O estado atual
-- fica nas colunas acima; aqui só o histórico mínimo, sem grant a ninguém do app.
create table privado.registro_aceita_chamadas (
  profissional_id    uuid        not null references public.profissional(id) on delete cascade,
  versao_texto_busca text        not null,
  em                 timestamptz not null
);
create index registro_aceita_chamadas_por_profissional on privado.registro_aceita_chamadas (profissional_id, em);
comment on table privado.registro_aceita_chamadas is
  'Cada vez que o profissional ligou "Aceito chamadas diretas": quando e com qual versão do texto (CD-P11, CD-S01; LGPD art. 7º, V, parecer J1). Só o servidor lê; sem grant a anon nem authenticated.';
alter table privado.registro_aceita_chamadas enable row level security;
revoke all on table privado.registro_aceita_chamadas from public, anon, authenticated;

-- Só quem ligou entra na busca: o índice parcial é o ponto de partida dela.
create index profissional_preferencia_chamada_na_busca
  on public.profissional_preferencia_chamada (profissional_id) where aceita_chamadas;

-- Os outros dois filtros da busca, pela função e pela região (as chaves primárias começam pelo profissional).
create index profissional_servico_por_funcao on public.profissional_servico (funcao_id, profissional_id);
create index profissional_regiao_por_regiao on public.profissional_regiao (regiao_id, profissional_id);

-- ── 2. A chave busca_profissionais ────────────────────────────────────────────

insert into privado.recurso (chave, ligado) values ('busca_profissionais', false)
on conflict (chave) do nothing;

alter table privado.recurso_versao_minima drop constraint recurso_versao_minima_recurso;
alter table privado.recurso_versao_minima add constraint recurso_versao_minima_recurso
  check (recurso in ('foto_de_perfil', 'chamada_direta', 'perfil_rico', 'checkin_por_codigo', 'busca_profissionais'));

-- Corpo de 20261111203000 com busca_profissionais. A busca chama quem está nela, então só vale com a
-- chamada direta: o campo vem true só quando os dois vêm true (0.2.88).
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
      'perfil_rico',    privado.recurso_na_versao('perfil_rico',    configuracao_do_app.plataforma, v_versao),
      -- 0.2.68: a chave global e o mínimo por plataforma, como os outros. A lista de casas do piloto
      -- (privado.recurso_estabelecimento) não entra aqui: ela vale por turno, nas duas operações.
      'checkin_por_codigo', privado.recurso_na_versao('checkin_por_codigo', configuracao_do_app.plataforma, v_versao),
      -- 0.2.88: a busca e o "Aceito chamadas diretas", só com a chamada direta também ligada.
      'busca_profissionais', privado.recurso_na_versao('busca_profissionais', configuracao_do_app.plataforma, v_versao)
                             and privado.recurso_na_versao('chamada_direta', configuracao_do_app.plataforma, v_versao)));
end $$;

-- ── 3. Helpers (só no privado, sem grant a anon nem authenticated) ────────────

-- A grade semanal cobre o horário inteiro? A mesma regra do despacho (privado.elegiveis,
-- 20261104030000:172-202): fuso America/Sao_Paulo, janela que vira a noite e janela da véspera que
-- cobre a madrugada.
create function privado.grade_cobre(p_profissional uuid, p_inicio timestamptz, p_fim timestamptz)
returns boolean
language sql stable security definer set search_path = ''
as $$
  with h as (
    select (p_inicio at time zone 'America/Sao_Paulo') as ini_sp,
           extract(dow from (p_inicio at time zone 'America/Sao_Paulo'))::int as dow
  )
  select exists (
    select 1 from public.disponibilidade d, h
     where d.profissional_id = p_profissional
       and (
         (d.dia_semana = h.dow
          and ((d.hora_inicio < d.hora_fim
                and tstzrange((date_trunc('day', h.ini_sp) + d.hora_inicio) at time zone 'America/Sao_Paulo',
                              (date_trunc('day', h.ini_sp) + d.hora_fim) at time zone 'America/Sao_Paulo')
                    @> tstzrange(p_inicio, p_fim))
               or (d.hora_inicio > d.hora_fim
                   and tstzrange((date_trunc('day', h.ini_sp) + d.hora_inicio) at time zone 'America/Sao_Paulo',
                                 (date_trunc('day', h.ini_sp) + interval '1 day' + d.hora_fim) at time zone 'America/Sao_Paulo')
                       @> tstzrange(p_inicio, p_fim))))
         or (d.dia_semana = (h.dow + 6) % 7
             and d.hora_inicio > d.hora_fim
             and tstzrange((date_trunc('day', h.ini_sp) - interval '1 day' + d.hora_inicio) at time zone 'America/Sao_Paulo',
                           (date_trunc('day', h.ini_sp) + d.hora_fim) at time zone 'America/Sao_Paulo')
                 @> tstzrange(p_inicio, p_fim))
       ))
$$;
comment on function privado.grade_cobre(uuid, timestamptz, timestamptz) is
  'Se alguma janela da grade semanal do profissional cobre [inicio, fim) inteiro, em America/Sao_Paulo, inclusive janela que vira a noite. A regra é a de privado.elegiveis (RN05); a busca a usa para o selo "disponível nesse horário" (CD-B03).';
revoke all on function privado.grade_cobre(uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function privado.grade_cobre(uuid, timestamptz, timestamptz) to service_role;

-- O que ainda impede o profissional de aparecer na busca (PreferenciaChamadas.pendencias_para_busca,
-- 0.2.88). Não fala de bloqueio nem de chamadas abertas: isso depende de cada casa e muda sozinho.
create function privado.pendencias_para_busca(p_profissional uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x.pendencia order by x.ordem), '[]'::jsonb)
    from (
      select 1 as ordem, 'sem_servico_com_preco' as pendencia
       where not exists (select 1 from public.profissional_servico s where s.profissional_id = p_profissional)
      union all
      select 2, 'sem_regiao'
       where not coalesce((select p.atende_todo_df from public.profissional p where p.id = p_profissional), false)
         and not exists (select 1 from public.profissional_regiao r where r.profissional_id = p_profissional)
      union all
      select 3, 'pausado'
       where exists (select 1 from public.profissional_preferencia_chamada pc
                      where pc.profissional_id = p_profissional
                        and pc.pausado_ate >= (privado.agora() at time zone 'America/Sao_Paulo')::date)
      union all
      select 4, 'sem_aparelho_atualizado'
       where not exists (select 1 from public.profissional p join public.dispositivo d on d.usuario_id = p.usuario_id
                          where p.id = p_profissional
                            and privado.recurso_na_versao('chamada_direta', d.plataforma::text, d.versao_app))
    ) x
$$;
comment on function privado.pendencias_para_busca(uuid) is
  'O que falta para o profissional aparecer na busca (CD-P10, contrato 0.2.88): sem_servico_com_preco, sem_regiao, pausado, sem_aparelho_atualizado. Lista vazia: aparece.';
revoke all on function privado.pendencias_para_busca(uuid) from public, anon, authenticated;
grant execute on function privado.pendencias_para_busca(uuid) to service_role;

-- Quem a busca mostra a uma casa: só quem a chamada direta aceitaria pelas regras do profissional
-- (contrato 0.2.88, frila-documentacao #259 d933885; CD-B03, CD-B06, CD-B10). As recusas do par
-- (chamada_ja_aberta, par_em_pausa, par_bloqueado_temporariamente) e o limite de 5 abertas são os
-- mesmos de chamar_profissional (20261113212000:83-87, :139-176 e :224). p_profissional restringe a um só,
-- para o chamar_profissional do próximo PR perguntar "este está na busca?" com a mesma regra.
-- A reputação não entra em nenhum filtro nem na ordem (RN06, D2).
create function privado.profissionais_na_busca(
  p_estabelecimento uuid,
  p_funcao          uuid,
  p_regiao          smallint,
  p_inicio          timestamptz default null,
  p_fim             timestamptz default null,
  p_demonstracao    boolean default false,
  p_profissional    uuid default null
)
returns table (profissional_id uuid, faixa smallint, cobre boolean)
language sql stable security definer set search_path = ''
as $$
  with param as (
    select privado.agora() as agora,
           (privado.agora() at time zone 'America/Sao_Paulo')::date as hoje,
           e.ponto, length(e.documento) = 11 as casa_pf
      from public.estabelecimento e
     where e.id = p_estabelecimento
  ),
  candidatos as materialized (
    select p.id, p.usuario_id, p.ponto_base, pc.aceita_de, pc.antecedencia_minima_h
      from public.profissional_preferencia_chamada pc
      join public.profissional p on p.id = pc.profissional_id
      join public.usuario u on u.id = p.usuario_id
      cross join param
     where pc.aceita_chamadas
       and (pc.pausado_ate is null or pc.pausado_ate < param.hoje)
       and (p_profissional is null or p.id = p_profissional)
       and u.estado = 'ativa'
       and u.demonstracao = coalesce(p_demonstracao, false)
       -- CD-P09: serviço com unidade de preço para a função buscada, só a exata (a_combinar também é
       -- unidade). Sem expandir pelo grupo_busca: o chamar_profissional confere a função exata, e a
       -- busca só mostra quem ele aceitaria (decisão da Forja sobre o parecer do Lince, I2).
       and exists (select 1 from public.profissional_servico s
                    where s.profissional_id = p.id and s.funcao_id = p_funcao)
       -- CD-P14: a região pedida marcada, ou "todo o DF"; sem nenhuma, não entra.
       and (p.atende_todo_df
            or exists (select 1 from public.profissional_regiao r
                        where r.profissional_id = p.id and r.regiao_id = p_regiao))
  )
  select c.id,
         (case when extensions.ST_DWithin(c.ponto_base, param.ponto, 5000) then 1
               when extensions.ST_DWithin(c.ponto_base, param.ponto, 15000) then 2
               else 3 end)::smallint,
         p_inicio is not null and privado.grade_cobre(c.id, p_inicio, p_fim)
    from candidatos c
   cross join param
   -- Só-CNPJ tira a casa de pessoa física (CD-P13).
   where not (c.aceita_de = 'so_cnpj' and param.casa_pf)
     -- Aparelho na versão mínima da chamada direta: a chamada nunca nasce para quem não a receberia.
     and exists (select 1 from public.dispositivo d
                  where d.usuario_id = c.usuario_id
                    and privado.recurso_na_versao('chamada_direta', d.plataforma::text, d.versao_app))
     -- CD-B10: teto de volume, o mesmo predicado do agenda_cheia de chamar_profissional.
     and (select count(*) from public.chamada ch
           where ch.profissional_id = c.id and ch.estado = 'aberta') < 5
     -- CD-C13: recusou chamada desta casa há menos de 24 h.
     and not exists (select 1 from public.chamada ch
                      where ch.estabelecimento_id = p_estabelecimento and ch.profissional_id = c.id
                        and ch.estado = 'recusada' and ch.respondida_em > param.agora - interval '24 hours')
     -- CD-C13: as três últimas desta casa em 30 dias recusadas ou expiradas, sem aceite no período.
     and not (
       (select count(*) from (select ch.estado from public.chamada ch
                               where ch.estabelecimento_id = p_estabelecimento and ch.profissional_id = c.id
                                 and ch.criada_em > param.agora - interval '30 days'
                                 and ch.estado in ('aceita', 'recusada', 'expirada')
                               order by ch.criada_em desc limit 3) u
         where u.estado in ('recusada', 'expirada')) = 3
       and not exists (select 1 from public.chamada ch
                        where ch.estabelecimento_id = p_estabelecimento and ch.profissional_id = c.id
                          and ch.criada_em > param.agora - interval '30 days' and ch.estado = 'aceita'))
     -- RN34: já tem chamada aberta desta casa (o mesmo predicado do 409 chamada_ja_aberta).
     and not exists (select 1 from public.chamada ch
                      where ch.estabelecimento_id = p_estabelecimento and ch.profissional_id = c.id
                        and ch.estado = 'aberta')
     -- Com horário: o prazo que a chamada exige (RN31). Turno confirmado no horário NÃO tira nem muda o
     -- selo, para a busca não revelar a agenda de trabalho; quem barra é o responder_chamada (RN21).
     -- Os limites da casa (422 limite_de_chamadas) também não filtram (contrato 0.2.88).
     and (p_inicio is null
          or p_inicio >= param.agora + make_interval(hours => greatest(2, c.antecedencia_minima_h)))
     -- RF26 por último, porque é função e custa por linha: bloqueio com qualquer membro, nos dois sentidos.
     and not privado.bloqueado_com_estabelecimento(c.usuario_id, p_estabelecimento)
$$;
comment on function privado.profissionais_na_busca(uuid, uuid, smallint, timestamptz, timestamptz, boolean, uuid) is
  'Quem a busca mostra a uma casa (contrato 0.2.88; CD-B03, CD-B06, CD-B10, CD-P09, CD-P10, CD-P14): aceita_chamadas sem pausa, serviço na função exata, região ou todo o DF, conta ativa da mesma população, sem bloqueio, menos de 5 chamadas abertas, nenhuma aberta desta casa, aceita a casa, sem pausa do par, aparelho na versão mínima e, com horário, o prazo da antecedência. Turno confirmado no horário não tira (contrato 0.2.88). Devolve a faixa de distância (1: até 5 km, 2: até 15 km, 3: mais) e se a grade cobre o horário. A reputação não entra (RN06).';
revoke all on function privado.profissionais_na_busca(uuid, uuid, smallint, timestamptz, timestamptz, boolean, uuid)
  from public, anon, authenticated;
grant execute on function privado.profissionais_na_busca(uuid, uuid, smallint, timestamptz, timestamptz, boolean, uuid)
  to service_role;

-- ── 4. definir_preferencia_chamadas com "Aceito chamadas diretas" ─────────────
-- Troca de assinatura com drop e create: duas versões com default deixariam a chamada ambígua
-- (PGRST203). Quem chama sem os campos novos recebe o mesmo de antes, mais aceita_chamadas.

drop function public.definir_preferencia_chamadas(boolean, date, int, text, boolean);

create function public.definir_preferencia_chamadas(
  aceita_de_quem_ja_trabalhou boolean default null,
  pausado_ate date default null,
  antecedencia_minima_h int default null,
  aceita_de text default null,
  remover_pausa boolean default false,
  aceita_chamadas boolean default null,
  versao_texto_busca text default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_prof_id   uuid;
  v_agora     timestamptz := privado.agora();
  v_agora_sp  date := (v_agora at time zone 'America/Sao_Paulo')::date;
  v_versao    text := nullif(btrim(definir_preferencia_chamadas.versao_texto_busca), '');
  v_pref      public.profissional_preferencia_chamada%rowtype;
  v_res       jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;

  perform privado.exigir_perfil('profissional');

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  select id into v_prof_id from public.profissional where usuario_id = v_uid;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if definir_preferencia_chamadas.aceita_de_quem_ja_trabalhou is null
     and definir_preferencia_chamadas.pausado_ate is null
     and definir_preferencia_chamadas.antecedencia_minima_h is null
     and definir_preferencia_chamadas.aceita_de is null
     and definir_preferencia_chamadas.aceita_chamadas is null
     and not definir_preferencia_chamadas.remover_pausa then
    perform public.erro(422, 'campo_obrigatorio', 'nenhum_campo');
  end if;

  -- 0.2.88: com a busca desligada, mandar aceita_chamadas (ligar ou desligar) é recusado.
  if definir_preferencia_chamadas.aceita_chamadas is not null
     and not privado.recurso_ligado('busca_profissionais') then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;

  if definir_preferencia_chamadas.pausado_ate is not null and definir_preferencia_chamadas.pausado_ate < v_agora_sp then
    perform public.erro(422, 'campo_invalido', 'pausado_ate');
  end if;

  if definir_preferencia_chamadas.antecedencia_minima_h is not null
     and definir_preferencia_chamadas.antecedencia_minima_h not in (2, 6, 24, 48) then
    perform public.erro(422, 'campo_invalido', 'antecedencia_minima_h');
  end if;

  if definir_preferencia_chamadas.aceita_de is not null and definir_preferencia_chamadas.aceita_de not in ('todos', 'so_cnpj') then
    perform public.erro(422, 'campo_invalido', 'aceita_de');
  end if;

  -- Ligar exige a versão do texto da tela (CD-P11); nos outros casos ela é ignorada.
  if definir_preferencia_chamadas.aceita_chamadas then
    if v_versao is null then
      perform public.erro(422, 'campo_obrigatorio', 'versao_texto_busca');
    end if;
    if length(v_versao) > 20 then
      perform public.erro(422, 'campo_invalido', 'versao_texto_busca');
    end if;
  else
    v_versao := null;
  end if;

  insert into public.profissional_preferencia_chamada (
    profissional_id, aceita_de_quem_ja_trabalhou, pausado_ate, antecedencia_minima_h, aceita_de, atualizado_em,
    aceita_chamadas, aceita_chamadas_em, versao_texto_busca
  )
  values (
    v_prof_id,
    coalesce(definir_preferencia_chamadas.aceita_de_quem_ja_trabalhou, true),
    case when definir_preferencia_chamadas.remover_pausa then null else definir_preferencia_chamadas.pausado_ate end,
    coalesce(definir_preferencia_chamadas.antecedencia_minima_h, 6),
    coalesce(definir_preferencia_chamadas.aceita_de, 'todos'),
    v_agora,
    coalesce(definir_preferencia_chamadas.aceita_chamadas, false),
    case when definir_preferencia_chamadas.aceita_chamadas then v_agora end,
    v_versao
  )
  on conflict (profissional_id) do update
    set aceita_de_quem_ja_trabalhou = coalesce(definir_preferencia_chamadas.aceita_de_quem_ja_trabalhou, public.profissional_preferencia_chamada.aceita_de_quem_ja_trabalhou),
        pausado_ate                 = case when definir_preferencia_chamadas.remover_pausa then null
                                           when definir_preferencia_chamadas.pausado_ate is not null then definir_preferencia_chamadas.pausado_ate
                                           else public.profissional_preferencia_chamada.pausado_ate end,
        antecedencia_minima_h       = coalesce(definir_preferencia_chamadas.antecedencia_minima_h, public.profissional_preferencia_chamada.antecedencia_minima_h),
        aceita_de                   = coalesce(definir_preferencia_chamadas.aceita_de, public.profissional_preferencia_chamada.aceita_de),
        aceita_chamadas             = coalesce(definir_preferencia_chamadas.aceita_chamadas, public.profissional_preferencia_chamada.aceita_chamadas),
        -- Cada vez que liga, guarda o instante e a versão do texto; desligar não apaga o registro.
        aceita_chamadas_em          = case when definir_preferencia_chamadas.aceita_chamadas then v_agora
                                           else public.profissional_preferencia_chamada.aceita_chamadas_em end,
        versao_texto_busca          = case when definir_preferencia_chamadas.aceita_chamadas then v_versao
                                           else public.profissional_preferencia_chamada.versao_texto_busca end,
        atualizado_em               = v_agora
  returning * into v_pref;

  -- Cada vez que liga, uma linha no histórico (o registro do pedido do titular).
  if definir_preferencia_chamadas.aceita_chamadas then
    insert into privado.registro_aceita_chamadas (profissional_id, versao_texto_busca, em)
    values (v_prof_id, v_versao, v_agora);
  end if;

  v_res := jsonb_build_object(
    'aceita_de_quem_ja_trabalhou', v_pref.aceita_de_quem_ja_trabalhou,
    'pausado_ate',                 v_pref.pausado_ate,
    'antecedencia_minima_h',       v_pref.antecedencia_minima_h,
    'aceita_de',                   v_pref.aceita_de,
    'aceita_chamadas',             v_pref.aceita_chamadas
  );
  -- pendencias_para_busca só vem com aceita_chamadas true (0.2.88).
  if v_pref.aceita_chamadas then
    v_res := v_res || jsonb_build_object('pendencias_para_busca', privado.pendencias_para_busca(v_prof_id));
  end if;
  return v_res;
end $$;

comment on function public.definir_preferencia_chamadas(boolean, date, int, text, boolean, boolean, text) is
  '0.2.56 e 0.2.88. Preferências do profissional para receber chamadas diretas (RN30, RN43, RN46) e "Aceito chamadas diretas" (CD-P10 a CD-P12), com o registro do pedido do titular e as pendências para aparecer na busca.';
revoke execute on function public.definir_preferencia_chamadas(boolean, date, int, text, boolean, boolean, text) from public, anon;
grant  execute on function public.definir_preferencia_chamadas(boolean, date, int, text, boolean, boolean, text) to authenticated;

-- ── 5. O contador do limite e a chave do cursor (privado, sem grant) ──────────

-- CD-B08 e CD-B09: só o contador por conta e hora. Nenhum filtro, nenhum profissional visto.
create table privado.contador_busca (
  usuario_id uuid        not null,
  hora       timestamptz not null,
  total      int         not null,
  primary key (usuario_id, hora)
);
comment on table privado.contador_busca is
  'Buscas de profissionais por conta e por hora (CD-B08: 60 por hora). Só o contador: os filtros e quem apareceu não ficam gravados (CD-B09, CD-S02). O job limpar_contador_busca apaga as horas com mais de um dia.';
alter table privado.contador_busca enable row level security;
revoke all on table privado.contador_busca from public, anon, authenticated;

-- A chave do HMAC que assina o cursor (o cursor adulterado não passa, e o teto de 200 não se fura).
-- Gerada aqui, no banco; não existe no repositório nem sai em resposta nenhuma.
create table privado.chave_cursor_busca (
  chave bytea not null
);
comment on table privado.chave_cursor_busca is
  'Chave aleatória (32 bytes) do HMAC-SHA256 do cursor de buscar_profissionais. Uma linha, gerada pela migração. Não é segredo de serviço externo: trocá-la só invalida os cursores do dia.';
alter table privado.chave_cursor_busca enable row level security;
revoke all on table privado.chave_cursor_busca from public, anon, authenticated;
insert into privado.chave_cursor_busca (chave) values (extensions.gen_random_bytes(32));

create function privado.limpar_contador_busca()
returns void
language sql security definer set search_path = ''
as $$
  delete from privado.contador_busca c where c.hora < privado.agora() - interval '1 day';
$$;
comment on function privado.limpar_contador_busca() is
  'Apaga as horas do contador de buscas com mais de um dia (contrato 0.2.88: o contador é apagado no dia seguinte). Job limpar_contador_busca.';
revoke all on function privado.limpar_contador_busca() from public, anon, authenticated;
grant execute on function privado.limpar_contador_busca() to service_role;

-- 08:13 UTC (05:13 em Brasília): fora do minuto 00 e das janelas dos outros jobs diários.
select cron.schedule('limpar_contador_busca', '13 8 * * *', 'select privado.limpar_contador_busca()');

-- ── 6. O cartão (CD-B07) ──────────────────────────────────────────────────────

-- O ÚNICO lugar do nome curto ("Maria L."): o cartão da busca e as leituras do PR 2 usam este helper.
-- Contrato 0.2.88: "primeiro nome e inicial do sobrenome". Sobrenome = o último (o de família, no
-- Brasil): ele nunca é partícula e, em prenome composto, não expõe o segundo prenome ("Ana Maria
-- Souza" → "Ana S."). Partículas (da, de, do, das, dos, e, d') e sufixos de geração (Filho, Filha,
-- Júnior, Junior, Jr, Neto, Neta, Sobrinho, Sobrinha) não contam ("João Silva Filho" → "João S.").
-- Nome de uma palavra só, ou só com partículas e sufixos depois, sai sem inicial. Vazio ou nulo: nulo.
create function privado.nome_curto(p_nome text)
returns text
language sql immutable set search_path = ''
as $$
  select case when n.partes is null or n.partes[1] is null or n.partes[1] = '' then null
              else n.partes[1]
                   || coalesce(' ' || upper(left((select t.x from unnest(n.partes[2:]) with ordinality t(x, i)
                                                  where lower(t.x) not in ('da', 'de', 'do', 'das', 'dos', 'e', 'd''',
                                                                           'filho', 'filha', 'júnior', 'junior', 'jr', 'jr.',
                                                                           'neto', 'neta', 'sobrinho', 'sobrinha')
                                                  order by t.i desc limit 1), 1)) || '.', '')
         end
    from (select regexp_split_to_array(btrim(p_nome), '\s+') as partes) n
$$;
comment on function privado.nome_curto(text) is
  'Nome curto do contrato 0.2.88 (CD-B07, CD-S03): primeiro nome e a inicial do último sobrenome, sem contar partículas nem sufixos como Filho e Júnior ("Maria Souza Lima" → "Maria L.", "João dos Santos" → "João S.", "João Silva Filho" → "João S.", "Maria" → "Maria"). O único lugar dessa regra. Nunca o sobrenome completo.';
revoke all on function privado.nome_curto(text) from public, anon, authenticated;
grant execute on function privado.nome_curto(text) to service_role;

-- A reputação com o denominador (Reputacao, RN08), a mesma conta de privado.perfil_publico_profissional
-- (20261109180000:411-421: histórico vivo e base expurgada). Mostra, mas não ordena (RN06).
create function privado.reputacao_profissional(p_profissional uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'positivas',           p.aval_positivas,
    'total',               p.aval_total,
    'taxa_comparecimento', p.taxa_comparecimento,
    'turnos_realizados',   p.turnos_realizados,
    'turnos_considerados', p.turnos_realizados
                           + (select count(*) from public.posicao x where x.profissional_id = p.id and x.falta)
                           + coalesce((select h.faltas from privado.profissional_reputacao_expurgada h
                                        where h.profissional_id = p.id), 0))
    from public.profissional p
   where p.id = p_profissional
$$;
comment on function privado.reputacao_profissional(uuid) is
  'Reputacao do profissional com o denominador (RN08): positivas/total, taxa de comparecimento, turnos realizados e considerados (somando a base expurgada, R9). A mesma conta de perfil_publico_profissional. Não ordena nada (RN06).';
revoke all on function privado.reputacao_profissional(uuid) from public, anon, authenticated;
grant execute on function privado.reputacao_profissional(uuid) to service_role;

-- Só o que ajuda a escolher quem chamar, campo por campo (lista explícita: campo novo numa tabela não
-- vaza para o cartão). Nunca telefone, e-mail, sobrenome completo, ponto base, grade ou data de
-- nascimento (CD-S03), e sem foto (contrato 0.2.88: a foto segue a regra da 0.2.54).
create function privado.cartao_profissional(
  p_profissional uuid, p_funcao uuid, p_faixa smallint, p_cobre boolean, p_com_horario boolean
)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'id', p.id,
    'nome', privado.nome_curto(u.nome),
    -- O serviço da função buscada (ServicoNoPerfil).
    'servico', (select jsonb_strip_nulls(jsonb_build_object(
                         'unidade',            s.unidade,
                         'valor_centavos',     s.valor_centavos,
                         'valor_max_centavos', s.valor_max_centavos,
                         'horas_incluidas',    s.horas_incluidas,
                         'minimo_horas',       s.minimo_horas,
                         'minimo_pessoas',     s.minimo_pessoas,
                         'ate_pessoas',        s.ate_pessoas,
                         'duracao_tipica_h',   s.duracao_tipica_h,
                         'descricao_pacote',   s.descricao_pacote,
                         'inclui',             s.inclui,
                         'leva_material',      s.leva_material))
                       || jsonb_build_object(
                            'funcao', jsonb_build_object(
                              'id', f.id, 'nome', f.nome, 'categoria', f.categoria,
                              'formato_padrao', f.formato_padrao, 'grupo_busca', f.grupo_busca,
                              'dica_perfil', f.dica_perfil, 'exemplo_perfil', f.exemplo_perfil),
                            'especialidades', coalesce((select jsonb_agg(jsonb_build_object(
                                                                 'id', e.id, 'funcao_id', e.funcao_id,
                                                                 'nome', e.nome, 'ativo', e.ativo) order by e.nome)
                                                          from public.profissional_servico_especialidade se
                                                          join public.especialidade e on e.id = se.especialidade_id
                                                         where se.profissional_id = s.profissional_id
                                                           and se.funcao_id = s.funcao_id), '[]'::jsonb))
                  from public.profissional_servico s join public.funcao f on f.id = s.funcao_id
                 where s.profissional_id = p.id and s.funcao_id = p_funcao),
    'regioes', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'numero', r.numero,
                                                             'nome', r.nome, 'ativo', r.ativo) order by r.id)
                           from public.profissional_regiao pr
                           join public.regiao_administrativa r on r.id = pr.regiao_id
                          where pr.profissional_id = p.id), '[]'::jsonb),
    'atende_todo_df', p.atende_todo_df,
    'distancia_faixa', case p_faixa when 1 then 'ate_5_km' when 2 then 'de_5_a_15_km' else 'mais_de_15_km' end,
    'reputacao', privado.reputacao_profissional(p.id)
  ) || case when p_com_horario then jsonb_build_object('disponivel_no_horario', p_cobre) else '{}'::jsonb end
    from public.profissional p
    join public.usuario u on u.id = p.usuario_id
   where p.id = p_profissional
$$;
comment on function privado.cartao_profissional(uuid, uuid, smallint, boolean, boolean) is
  'CartaoProfissional de buscar_profissionais (contrato 0.2.88, CD-B07), por lista explícita de campos: id, nome curto, o serviço da função, regiões, todo o DF, faixa de distância, reputação com denominador e, com horário, o selo da grade. Nunca contato, ponto base, nascimento nem foto (CD-S03).';
revoke all on function privado.cartao_profissional(uuid, uuid, smallint, boolean, boolean) from public, anon, authenticated;
grant execute on function privado.cartao_profissional(uuid, uuid, smallint, boolean, boolean) to service_role;

-- ── 7. A busca ────────────────────────────────────────────────────────────────

create function public.buscar_profissionais(
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
  '0.2.88. Busca de profissionais para chamar direto (CD-B01 a CD-B10): serviço obrigatório, região (padrão: a da casa) e horário. Ordem: a grade cobre o horário, faixa de distância, embaralho estável por contratante e dia; a reputação não ordena (RN06). 20 por página por cursor assinado, no máximo 200 por busca e 60 buscas por hora por conta (429 limite_excedido). Os filtros não ficam gravados (CD-B09). POST: a busca grava o contador.';
revoke all on function public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int) from public, anon;
grant execute on function public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int) to authenticated;

-- ── 9. LGPD do registro de "Aceito chamadas diretas" (decisão da Bússola, 16/11/2026) ──
-- O registro guarda enquanto a conta existir, entra na exportação (MeusDados.registros_aceita_chamadas)
-- e sai na limpeza da conta excluída, em até 15 dias (RF25), no passo que já limpa o perfil rico.

-- Corpo de 20261111203000 com só o campo registros_aceita_chamadas no fim.
create or replace function privado.meus_dados(p_usuario uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with conta as (
    select * from public.usuario u where u.id = p_usuario
  ),
  prof as (
    select p.* from public.profissional p where p.usuario_id = p_usuario
  ),
  casas as (
    select m.estabelecimento_id, m.papel, e.nome, e.tipo
      from public.membro_estabelecimento m
      join public.estabelecimento e on e.id = m.estabelecimento_id
     where m.usuario_id = p_usuario
  )
  select jsonb_build_object(
    'gerado_em', privado.agora(),

    'conta', jsonb_build_object(
      'id',         c.id,
      'perfil',     c.perfil,
      'nome',       c.nome,
      'telefone',   c.telefone,
      'email',      c.email,
      'nascimento', c.nascimento,
      'estado',     c.estado),

    -- 0.2.58: PerfilProfissionalDetalhado completo via privado.perfil_com_servicos
    'perfil_profissional',
      (select privado.perfil_com_servicos(p) from prof p),

    'estabelecimentos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',        k.estabelecimento_id,
               'nome',      k.nome,
               'tipo',      k.tipo,
               'papel',     k.papel,
               'reputacao', privado.estabelecimento_publico(k.estabelecimento_id)->'reputacao')
             order by k.nome)
        from casas k), '[]'::jsonb),

    'disponibilidade', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dia_semana',  d.dia_semana,
               'hora_inicio', to_char(d.hora_inicio, 'HH24:MI'),
               'hora_fim',    to_char(d.hora_fim,    'HH24:MI'))
             order by d.dia_semana, d.hora_inicio)
        from public.disponibilidade d
        join prof p on p.id = d.profissional_id), '[]'::jsonb),

    'turnos', coalesce((
      select jsonb_agg(privado.turno_em_json(t.id, p_usuario) order by pos.inicio_em desc)
        from public.turno t
        join public.posicao pos on pos.id = t.posicao_id
        join public.vaga vg     on vg.id = pos.vaga_id
       where (c.perfil = 'profissional' and pos.profissional_id in (select p.id from prof p))
          or (c.perfil = 'contratante' and vg.estabelecimento_id in (select k.estabelecimento_id from casas k))), '[]'::jsonb),

    'avaliacoes_dadas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'turno_id',  a.turno_id,
               'resposta',  a.resposta,
               'criada_em', a.criada_em)
             order by a.criada_em desc)
        from public.avaliacao a
       where a.autor_id = p_usuario), '[]'::jsonb),

    'avaliacoes_recebidas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'turno_id',  a.turno_id,
               'resposta',  a.resposta,
               'criada_em', a.criada_em)
             order by a.criada_em desc)
        from public.avaliacao a
        join public.turno t on t.id = a.turno_id
        join public.posicao pos on pos.id = t.posicao_id
        join public.vaga vg on vg.id = pos.vaga_id
       where (c.perfil = 'profissional' and pos.profissional_id in (select p.id from prof p) and a.alvo_tipo = 'profissional')
          or (c.perfil = 'contratante' and vg.estabelecimento_id in (select k.estabelecimento_id from casas k) and a.alvo_tipo = 'estabelecimento')), '[]'::jsonb),

    'dispositivos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'plataforma',    dp.plataforma,
               'atualizado_em', dp.atualizado_em)
             order by dp.atualizado_em desc)
        from public.dispositivo dp
       where dp.usuario_id = p_usuario), '[]'::jsonb),

    'candidaturas', coalesce((
      select jsonb_agg(privado.candidatura_em_json(cd.id)
             order by cd.criada_em desc)
        from public.candidatura cd
       where cd.profissional_id in (select p.id from prof p)), '[]'::jsonb),

    'ocorrencias', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',           o.id,
               'tipo',         o.tipo,
               'papel',        case when o.autor_id = p_usuario then 'autor' else 'alvo' end,
               'criada_em',    o.criada_em,
               'resolvido_em', o.resolvido_em,
               'motivo',       case when o.autor_id = p_usuario or o.tipo = 'suspensao' then o.motivo else null end)
             order by o.criada_em desc)
        from public.ocorrencia o
       where o.autor_id = p_usuario or o.usuario_id = p_usuario), '[]'::jsonb),

    'bloqueios', coalesce((
      select jsonb_agg(x.o order by x.criado_em desc)
        from (
          select distinct jsonb_build_object(
                   'alvo_tipo', 'profissional',
                   'alvo_id',   pb.id,
                   'criado_em', b.criado_em) as o,
                 b.criado_em
            from public.bloqueio b
            join public.profissional pb on pb.usuario_id = b.bloqueado_id
           where b.autor_id = p_usuario
          union
          select distinct jsonb_build_object(
                   'alvo_tipo', 'estabelecimento',
                   'alvo_id',   mb.estabelecimento_id,
                   'criado_em', b.criado_em) as o,
                 b.criado_em
            from public.bloqueio b
            join public.usuario ub on ub.id = b.bloqueado_id and ub.perfil = 'contratante'
            join public.membro_estabelecimento mb on mb.usuario_id = b.bloqueado_id
           where b.autor_id = p_usuario
        ) x), '[]'::jsonb),

    'notificacoes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tipo',          n.tipo,
               'referencia_id', n.referencia_id,
               'payload',       n.payload,
               'enviada_em',    n.enviada_em,
               'entregue_em',   n.entregue_em)
             order by n.enviada_em desc nulls last)
        from public.notificacao n
       where n.usuario_id = p_usuario), '[]'::jsonb),

    'despachos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'vaga_id',   ds.vaga_id,
               'criado_em', ds.criado_em,
               'reaberta',  ds.reaberta)
             order by ds.criado_em desc)
        from public.despacho ds
       where ds.profissional_id in (select p.id from prof p)), '[]'::jsonb),

    'equipe_confianca', coalesce((
      select jsonb_agg(jsonb_build_object(
               'estabelecimento_id', ec.estabelecimento_id,
               'nome',               es.nome,
               'adicionado_em',      ec.adicionado_em)
             order by ec.adicionado_em desc)
        from public.equipe_confianca ec
        join public.estabelecimento es on es.id = ec.estabelecimento_id
       where ec.profissional_id in (select p.id from prof p)), '[]'::jsonb),

    'pedido_de_exclusao', (
      select jsonb_build_object(
               'pedido_em',    pe.pedido_em,
               'estado',       pe.estado,
               'tentativas',   pe.tentativas,
               'concluido_em', pe.concluido_em)
        from public.pedido_de_exclusao pe
       where pe.usuario_id = p_usuario
       order by pe.pedido_em desc
       limit 1),

    'eventos_app', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',          ea.id,
               'evento',      ea.evento,
               'vaga_id',     ea.vaga_id,
               'turno_id',    ea.turno_id,
               'ocorrido_em', ea.ocorrido_em,
               'criado_em',   ea.criado_em)
             order by ea.ocorrido_em desc, ea.criado_em desc, ea.id desc)
        from public.evento_app ea
       where ea.usuario_id = p_usuario), '[]'::jsonb),

    -- 0.2.59: mídias ativas do titular
    'midias', coalesce((
      select jsonb_agg(privado.midia_em_json(m)
             order by m.criado_em desc)
        from privado.midia m
       where (m.estabelecimento_id is null and m.dono_usuario_id = p_usuario
              or m.estabelecimento_id in (select k.estabelecimento_id from casas k))), '[]'::jsonb),

    -- 0.2.59: chamadas do titular (como profissional chamado ou membro da casa)
    'chamadas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',                 ch.id,
               'vaga_id',            ch.vaga_id,
               'profissional_id',    ch.profissional_id,
               'estabelecimento_id', ch.estabelecimento_id,
               'estado',             ch.estado,
               'recado',             ch.recado,
               'motivo_recusa',      ch.motivo_recusa,
               'expira_em',          ch.expira_em,
               'respondida_em',      ch.respondida_em,
               'criada_em',          ch.criada_em)
             order by ch.criada_em desc)
        from public.chamada ch
       where (c.perfil = 'profissional' and ch.profissional_id in (select p.id from prof p))
          or (c.perfil = 'contratante' and ch.estabelecimento_id in (select k.estabelecimento_id from casas k))), '[]'::jsonb),

    -- 0.2.68 (revisto na 0.2.70): o check-in por código do titular como profissional (LGPD, art. 18,
    -- II, e art. 19). Só o turno com algum dos três registros, e só enquanto existem (a guarda é a do
    -- PR3). Nunca o valor do código, o contador, o bloqueio nem quem gerou: o contrato não os declara.
    -- Na exportação de quem opera a casa vem [] (regra (d) da Bússola), por isso o perfil explícito.
    'checkins_por_codigo', coalesce((
      select jsonb_agg(jsonb_build_object(
               'turno_id',        cc.turno_id,
               'codigo_exigido',  cc.codigo_exigido,
               'confianca_baixa', cc.confianca_baixa,
               'tentativas', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'em',               ct.em,
                          'resultado',        ct.resultado,
                          'faixa',            ct.faixa,
                          'codigo_gerado_em', ct.codigo_gerado_em)
                        order by ct.em, ct.id)
                   from privado.checkin_codigo_tentativa ct
                  where ct.turno_id = cc.turno_id), '[]'::jsonb))
             order by pos.inicio_em desc, cc.turno_id)
        from privado.checkin_codigo cc
        join public.turno t     on t.id = cc.turno_id
        join public.posicao pos on pos.id = t.posicao_id
       where c.perfil = 'profissional'
         and pos.profissional_id in (select p.id from prof p)
         and (cc.codigo_exigido or cc.confianca_baixa
              or exists (select 1 from privado.checkin_codigo_tentativa x where x.turno_id = cc.turno_id))), '[]'::jsonb),

    -- 0.2.88: cada vez que o titular ligou "Aceito chamadas diretas" (decisão da Bússola, 16/11/2026:
    -- guarda enquanto a conta existir e entra na exportação). Só a versão do texto e o instante; na
    -- exportação de quem opera a casa vem [].
    'registros_aceita_chamadas', coalesce((
      select jsonb_agg(jsonb_build_object('versao_texto_busca', ra.versao_texto_busca, 'em', ra.em)
                       order by ra.em, ra.versao_texto_busca)
        from privado.registro_aceita_chamadas ra
       where c.perfil = 'profissional'
         and ra.profissional_id in (select p.id from prof p)), '[]'::jsonb)
  )
  from conta c
$$;

comment on function privado.meus_dados(uuid) is
  'Portabilidade LGPD (art. 18): consolidação de dados do titular com PerfilProfissionalDetalhado (0.2.58), midias (0.2.59), chamadas (0.2.59), só na do profissional checkins_por_codigo (0.2.68) e registros_aceita_chamadas (0.2.88): cada vez que ligou "Aceito chamadas diretas", com a versão do texto e o instante.';

-- Corpo de 20261113210000 com o passo 4 (o registro e a preferência da busca).
create or replace function privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(p_dias integer default 15)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_corte      timestamptz;
  r            record;
  v_enfileiradas integer := 0;
  v_reenfileiradas integer := 0;
  v_regioes    integer := 0;
  v_servicos   integer := 0;
  v_todo_df    integer := 0;
  v_registros  integer := 0;
  v_busca      integer := 0;
begin
  if p_dias is null or p_dias < 1 then
    raise exception 'p_dias inválido: %', p_dias;
  end if;
  v_corte := privado.agora() - make_interval(days => p_dias);
  perform set_config('privado.retencao', 'on', true);

  -- 1. As mídias da pessoa: removida + expurgo físico (original e miniatura)
  for r in
    select m.id, m.storage_path
      from privado.midia m
      join public.usuario u on u.id = m.dono_usuario_id
     where u.estado = 'anonimizada'
       and u.anonimizado_em <= v_corte
       and m.estabelecimento_id is null
       and m.estado not in ('removida', 'expurgada')
     for update of m skip locked
  loop
    update privado.midia set estado = 'removida', motivo_recusa = null, atualizado_em = privado.agora()
     where id = r.id;
    perform pgmq.send(
      'expurgo_midia',
      jsonb_build_object(
        'verificacao_id', r.id::text,
        'bucket', 'midia-perfil',
        'caminhos', jsonb_build_array(r.storage_path, replace(r.storage_path, '.jpg', '_thumb.jpg')),
        'origem', 'foto_perfil'
      )
    );
    v_enfileiradas := v_enfileiradas + 1;
  end loop;

  -- 2. A varredura que converge: arquivo ainda no Storage e sem pedido na fila volta à fila. A linha fica.
  for r in
    select m.id, m.storage_path
      from privado.midia m
      join public.usuario u on u.id = m.dono_usuario_id
     where u.estado = 'anonimizada'
       and u.anonimizado_em <= v_corte
       and m.estabelecimento_id is null
       and m.estado in ('removida', 'expurgada')
       and exists (select 1 from storage.objects o
                    where o.bucket_id = 'midia-perfil'
                      and o.name in (m.storage_path, replace(m.storage_path, '.jpg', '_thumb.jpg')))
       and not exists (select 1 from pgmq.q_expurgo_midia q where q.message ->> 'verificacao_id' = m.id::text)
     limit 500
  loop
    update privado.midia set motivo_recusa = null where id = r.id and motivo_recusa is not null;
    perform pgmq.send(
      'expurgo_midia',
      jsonb_build_object(
        'verificacao_id', r.id::text,
        'bucket', 'midia-perfil',
        'caminhos', jsonb_build_array(r.storage_path, replace(r.storage_path, '.jpg', '_thumb.jpg')),
        'origem', 'foto_perfil'
      )
    );
    v_reenfileiradas := v_reenfileiradas + 1;
  end loop;

  -- 3. O perfil rico
  delete from public.profissional_regiao pr
   using public.profissional p, public.usuario u
   where pr.profissional_id = p.id and p.usuario_id = u.id
     and u.estado = 'anonimizada' and u.anonimizado_em <= v_corte;
  get diagnostics v_regioes = row_count;

  delete from public.profissional_servico ps
   using public.profissional p, public.usuario u
   where ps.profissional_id = p.id and p.usuario_id = u.id
     and u.estado = 'anonimizada' and u.anonimizado_em <= v_corte;
  get diagnostics v_servicos = row_count;

  update public.profissional p
     set atende_todo_df = false
    from public.usuario u
   where p.usuario_id = u.id and p.atende_todo_df
     and u.estado = 'anonimizada' and u.anonimizado_em <= v_corte;
  get diagnostics v_todo_df = row_count;

  -- 4. A busca (0.2.88, decisão da Bússola de 16/11/2026): o registro de cada vez que ligou "Aceito
  --    chamadas diretas" sai, e a preferência perde o estado e o último registro.
  delete from privado.registro_aceita_chamadas ra
   using public.profissional p, public.usuario u
   where ra.profissional_id = p.id and p.usuario_id = u.id
     and u.estado = 'anonimizada' and u.anonimizado_em <= v_corte;
  get diagnostics v_registros = row_count;

  update public.profissional_preferencia_chamada pc
     set aceita_chamadas = false, aceita_chamadas_em = null, versao_texto_busca = null
    from public.profissional p, public.usuario u
   where pc.profissional_id = p.id and p.usuario_id = u.id
     and (pc.aceita_chamadas or pc.aceita_chamadas_em is not null or pc.versao_texto_busca is not null)
     and u.estado = 'anonimizada' and u.anonimizado_em <= v_corte;
  get diagnostics v_busca = row_count;

  return jsonb_build_object(
    'midias_enfileiradas', v_enfileiradas,
    'midias_reenfileiradas', v_reenfileiradas,
    'regioes_apagadas',    v_regioes,
    'servicos_apagados',   v_servicos,
    'atende_todo_df_desligado', v_todo_df,
    'registros_aceita_chamadas_apagados', v_registros,
    'preferencias_busca_limpas', v_busca);
end $$;

comment on function privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(integer) is
  'LGPD art. 16 e 18, VI (B-019): para conta anonimizada há p_dias (15) ou mais, põe cada mídia da pessoa (estabelecimento_id nulo) em removida, sem motivo de recusa, e na fila expurgo_midia (original e miniatura, bucket midia-perfil); põe de novo na fila a que ainda tem arquivo em storage.objects sem pedido (corrida com a moderar-midia); a linha fica como marca expurgada (a cota do mês em moderacao_chamada se preserva); apaga o perfil rico (profissional_regiao, profissional_servico) e desliga atende_todo_df; e (0.2.88) apaga privado.registro_aceita_chamadas e limpa aceita_chamadas, aceita_chamadas_em e versao_texto_busca. Idempotente. Passo da rotina diária.';
