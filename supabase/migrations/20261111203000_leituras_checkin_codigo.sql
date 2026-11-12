-- As leituras do check-in por código: RecursosDoApp e MeusDados (contrato 0.2.68, revisto na
-- 0.2.70; PR8 do plano B-CHECKIN-BACK).
--
-- 1. privado.recurso_versao_minima aceita checkin_por_codigo. Nenhuma linha entra aqui: o
--    calendário da versão mínima 1.2 é do JP (plano, seção 4). Sem linha, o recurso vem false em
--    toda versão e plataforma, mesmo com a chave global ligada (fechado por padrão, 0.2.65).
-- 2. configuracao_do_app devolve checkin_por_codigo por privado.recurso_na_versao. O corpo é o da
--    20261108220000 (0.2.67, frila-backend #456), com só a chave nova; a assinatura não muda, então
--    os grants e o comentário ficam.
-- 3. privado.meus_dados ganha checkins_por_codigo. O corpo é o da 20261107370000, com só a coleção
--    nova no fim; a assinatura não muda, então os grants ficam. Para a casa, [].
--
-- A superfície não muda: a chave nova de RecursosDoApp (0.2.68, revista na 0.2.70) já está no
-- espelho da base (0.2.73).
-- contrato: corpo-sem-mudanca-de-superficie public.configuracao_do_app 0.2.73
--
-- LGPD (regras da Bússola, 08/11; desenho, seção 8): (b) a marca de confiança baixa só alimenta a
-- medição, e só a validação e a exportação a leem (o expurgo apaga a linha inteira); (d) só a
-- exportação do próprio profissional traz as tentativas, a marca e o "código exigido". O 834 prova
-- as duas pelo catálogo.

select set_config('lock_timeout', '2s', true);

-- ── 1. O mínimo por versão aceita o check-in por código ───────────────────────

alter table privado.recurso_versao_minima drop constraint recurso_versao_minima_recurso;
alter table privado.recurso_versao_minima add constraint recurso_versao_minima_recurso
  check (recurso in ('foto_de_perfil', 'chamada_direta', 'perfil_rico', 'checkin_por_codigo'));

-- ── 2. configuracao_do_app devolve checkin_por_codigo ─────────────────────────

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
      'checkin_por_codigo', privado.recurso_na_versao('checkin_por_codigo', configuracao_do_app.plataforma, v_versao)));
end $$;


-- ── 3. privado.meus_dados devolve checkins_por_codigo ─────────────────────────

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
              or exists (select 1 from privado.checkin_codigo_tentativa x where x.turno_id = cc.turno_id))), '[]'::jsonb)
  )
  from conta c
$$;


comment on function privado.meus_dados(uuid) is
  'Portabilidade LGPD (art. 18): consolidação de dados do titular com PerfilProfissionalDetalhado (0.2.58), midias (0.2.59), chamadas (0.2.59) e, só na do profissional, checkins_por_codigo (0.2.68): o código exigido, a confiança baixa e as tentativas, sem o valor do código.';
