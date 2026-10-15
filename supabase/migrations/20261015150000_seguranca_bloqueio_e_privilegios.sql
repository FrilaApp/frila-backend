-- Correções de segurança da auditoria de 15/10/2026:
--
-- Achado 1 (Alta): `candidatos_da_vaga` e `escolher_candidato` passam a filtrar bloqueio mútuo
-- (`privado.bloqueado_com_estabelecimento`), impedindo vazamento de contato telefônico e
-- contorno da garantia de bloqueio (RF26, RN10, LGPD). A recusa em `escolher_candidato` responde
-- `403 sem_permissao`, idêntica a candidatura inexistente ou de outra casa, sem revelar a existência do bloqueio.
--
-- Achado 3 (Baixa): Revoga permissão desnecessária de `EXECUTE` em `privado.taxa_aceite_notificacoes_7d()`
-- para `authenticated` e `anon`, mantendo apenas para `service_role`.
--
-- Achado 4 (Baixa): Revoga `ALL` em `public.pedido_de_exclusao` explicitamente de `public`,
-- fechando a assimetria com a intenção documentada na criação da tabela.

-- ── 1. candidatos_da_vaga ─────────────────────────────────────────────────────

create or replace function public.candidatos_da_vaga(vaga_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_estab uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('contratante');

  if candidatos_da_vaga.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  select g.estabelecimento_id into v_estab
    from public.vaga g where g.id = candidatos_da_vaga.vaga_id;
  if v_estab is null then
    perform public.erro(404, 'nao_encontrado');
  end if;
  if not privado.eh_membro(v_estab) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- Ordem de chegada, e nenhuma outra: a reputação vai no card para a casa ler (RN08),
  -- não na ordem da lista (RN06). Candidatos com bloqueio mútuo com o estabelecimento
  -- são ocultados (achado 1 da auditoria de segurança, RF26, RN10).
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'candidatura_id', c.id,
             'profissional',   privado.perfil_publico_profissional(c.profissional_id),
             'criada_em',      c.criada_em)
           order by c.criada_em, c.id)
      from public.candidatura c
      join public.posicao x on x.id = c.posicao_id
     where x.vaga_id = candidatos_da_vaga.vaga_id
       and c.estado = 'pendente'
       and not privado.bloqueado_com_estabelecimento(
             privado.usuario_do_profissional(c.profissional_id),
             v_estab)), '[]'::jsonb);
end $$;

comment on function public.candidatos_da_vaga(uuid) is
  'Modo seleção: lista os candidatos pendentes na ordem de chegada (RN06), ocultando profissionais com bloqueio mútuo com o estabelecimento.';

revoke execute on function public.candidatos_da_vaga(uuid) from public, anon;
grant  execute on function public.candidatos_da_vaga(uuid) to authenticated;

-- ── 2. escolher_candidato ─────────────────────────────────────────────────────

create or replace function public.escolher_candidato(candidatura_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid     uuid := (select auth.uid());
  v_vaga_id uuid;
  v_agora   timestamptz;
  v         public.vaga%rowtype;
  c         public.candidatura%rowtype;
  v_pos     uuid;
  v_turno   uuid;
  v_outra   record;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('contratante');

  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  if escolher_candidato.candidatura_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'candidatura_id');
  end if;

  -- Candidatura que não existe e candidatura de outra casa respondem igual, como em
  -- `publicar_vaga`: um código diferente confirmaria a quem não é da casa que o id existe.
  -- Bloqueio mútuo responde com o mesmo código sem revelar o bloqueio (achado 1, RF26, RN10).
  select x.vaga_id into v_vaga_id
    from public.candidatura k
    join public.posicao x on x.id = k.posicao_id
   where k.id = escolher_candidato.candidatura_id;

  if v_vaga_id is null
     or not privado.eh_membro(privado.estabelecimento_da_vaga(v_vaga_id)) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- A vaga antes de qualquer posição (CPD2c74A). É esta trava que serializa duas
  -- escolhas para a mesma vaga: a segunda espera o commit da primeira e relê tudo.
  select * into v from public.vaga g where g.id = v_vaga_id for update;
  select * into c from public.candidatura k
   where k.id = escolher_candidato.candidatura_id for update;

  if c.id is null
     or privado.bloqueado_com_estabelecimento(
          privado.usuario_do_profissional(c.profissional_id),
          v.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- A ordem das recusas é a da tela. A escolhida é `candidatura_indisponivel`. Com a vaga
  -- cheia, `posicao_ja_preenchida` vem antes do estado da candidatura: na corrida de duas
  -- escolhas, a que perde encontra a própria candidatura já recusada pela que ganhou, e o
  -- que a casa precisa ouvir é que a posição foi preenchida (RN19).
  if v.modo <> 'selecao' or c.estado = 'aceita' then
    perform public.erro(409, 'candidatura_indisponivel');
  end if;

  -- Ocultada pela moderação da Equipe Frila (contrato 0.2.23): a escolha é recusada e a
  -- candidatura segue pendente; volta a valer se a Equipe reexibir a vaga.
  if privado.vaga_oculta(v.id) then
    perform public.erro(422, 'vaga_oculta');
  end if;

  v_agora := privado.agora();

  if v.estado = 'preenchida' then
    perform public.erro(409, 'posicao_ja_preenchida');
  end if;
  if v.estado <> 'publicada' or v_agora >= v.inicio_em - interval '24 hours' then
    perform public.erro(409, 'vaga_encerrada');
  end if;
  if c.estado <> 'pendente' then
    perform public.erro(409, 'candidatura_indisponivel');
  end if;

  -- RN13: suspenso depois de se candidatar não assume turno, como em `candidatar`.
  if exists (select 1 from public.profissional p
               join public.usuario u on u.id = p.usuario_id
              where p.id = c.profissional_id and u.estado <> 'ativa') then
    perform public.erro(422, 'inelegivel', 'perfil_suspenso');
  end if;

  -- RN19: a mesma escrita condicional do modo urgência. RN21 pelo `EXCLUDE` de `posicao`.
  begin
    update public.posicao p
       set estado = 'confirmada',
           profissional_id = c.profissional_id,
           confirmado_em = v_agora
     where p.id = (select x.id from public.posicao x
                    where x.vaga_id = v.id and x.estado = 'aberta'
                    order by x.id
                    for update
                    limit 1)
    returning p.id into v_pos;
  exception
    when exclusion_violation then
      perform public.erro(422, 'inelegivel', 'turno_sobreposto');
  end;

  if v_pos is null then
    perform public.erro(409, 'posicao_ja_preenchida');
  end if;

  -- A candidatura vai para a posição que de fato confirmou.
  update public.candidatura k
     set estado = 'aceita', posicao_id = v_pos
   where k.id = c.id;

  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_pos, v.valor_centavos)
  returning id into v_turno;

  -- A última posição escolhida fecha a vaga e libera quem sobrou, com aviso.
  if not exists (select 1 from public.posicao p
                  where p.vaga_id = v.id and p.estado = 'aberta') then
    update public.vaga g set estado = 'preenchida' where g.id = v.id;

    for v_outra in
      select k.id, pr.usuario_id
        from public.candidatura k
        join public.posicao x      on x.id = k.posicao_id
        join public.profissional pr on pr.id = k.profissional_id
       where x.vaga_id = v.id and k.estado = 'pendente'
    loop
      update public.candidatura k set estado = 'recusada' where k.id = v_outra.id;
      perform privado.notificar(v_outra.usuario_id, 'candidatura_recusada', v.id,
        jsonb_build_object('vaga_id', v.id));
    end loop;
  end if;

  -- RF10: o escolhido é avisado. A casa não: foi ela quem escolheu.
  perform privado.notificar(privado.usuario_do_profissional(c.profissional_id),
    'confirmacao', v_turno, jsonb_build_object('turno_id', v_turno, 'vaga_id', v.id));

  return jsonb_build_object(
    'estado',     'confirmada',
    'posicao_id', v_pos,
    'turno_id',   v_turno,
    'contato',    privado.contato_do_profissional(v_pos));
end $$;

comment on function public.escolher_candidato(uuid) is
  'Modo seleção: a casa confirma um candidato pendente numa posição aberta (RN19, RN21, contrato 0.2.24). Vaga ocultada pela Equipe Frila: 422 vaga_oculta (0.2.23). Bloqueio mútuo: 403 sem_permissao (achado 1 da auditoria de segurança). A última escolha fecha a vaga e recusa os pendentes com aviso candidatura_recusada. O escolhido recebe confirmacao.';

revoke execute on function public.escolher_candidato(uuid) from public, anon;
grant  execute on function public.escolher_candidato(uuid) to authenticated;

-- ── 3. Achado 3: privado.taxa_aceite_notificacoes_7d ──────────────────────────

revoke execute on function privado.taxa_aceite_notificacoes_7d() from public, anon, authenticated;
grant  execute on function privado.taxa_aceite_notificacoes_7d() to service_role;

-- ── 4. Achado 4: public.pedido_de_exclusao ────────────────────────────────────

revoke all on table public.pedido_de_exclusao from public, anon, authenticated;
