-- A guarda de LGPD do check-in por código (contrato 0.2.68; PR3 do plano).
-- Regras da Bússola (08/11), na Modelagem do frila-docs #198, "Check-in por código" → "A guarda".
--
-- Três caminhos de saída, nenhum por cópia nem por log:
--   1. 90 dias depois do mais tarde entre o fim do turno e o fim da contestação, a linha de
--      privado.checkin_codigo sai, e as tentativas vão junto em cascata. Contestação aberta
--      segura; depois que ela fecha (ocorrencia.resolvido_em), ainda contam 90 dias. Do caminho
--      do código, o turno fica os 5 anos só com checkin_tipo e checkin_confirmado_em.
--   2. O valor do código vale só durante a validade e sai do banco em até 1 minuto depois dela
--      (job a cada minuto), além de sair ao validar e ao gerar outro. Quem valida recusa pelo
--      expira_em, nunca pela presença do valor (PR6), para o minuto da limpeza não esticar a
--      validade.
--   3. Na anonimização da conta do profissional, sai o estado dos turnos dele, com as tentativas.
--
-- O que conta como contestação do turno: a ocorrencia de tipo 'contestacao' com aquele turno_id.
-- Até ela existir, a contestação de suspensão do profissional do turno, que hoje é a única e
-- grava só usuario_id (20261001100000_suspensao_da_conta.sql:555-569). As duas contam juntas, e
-- vale a mais tarde: a que tem turno_id ainda não é gravada por nenhuma RPC.

select set_config('lock_timeout', '2s', true);

-- ── 1. Os 90 dias ─────────────────────────────────────────────────────────────

create function privado.limpar_checkin_por_codigo(p_dias integer default 90, p_limite integer default 500)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_total integer;
begin
  -- Piso de 90 dias, que nenhum parâmetro encurta: a contestação precisa dos dados até lá.
  if p_dias is null or p_dias < 90 then p_dias := 90; end if;
  if p_limite is null or p_limite < 1 then p_limite := 500; end if;

  with vencidos as (
    select c.turno_id
      from privado.checkin_codigo c
      join public.turno t on t.id = c.turno_id
      join public.posicao p on p.id = t.posicao_id
      left join public.profissional pr on pr.id = p.profissional_id
      cross join lateral (
        select bool_or(o.resolvido_em is null) as aberta,
               max(o.resolvido_em)             as fechada_em
          from public.ocorrencia o
         where o.tipo = 'contestacao'
           and (o.turno_id = t.id
                or (o.turno_id is null and o.usuario_id = pr.usuario_id))
      ) k
     where not coalesce(k.aberta, false)
       and greatest(p.fim_em, k.fechada_em) + make_interval(days => p_dias) <= privado.agora()
     order by c.turno_id
     limit p_limite
  )
  delete from privado.checkin_codigo c using vencidos v where c.turno_id = v.turno_id;

  get diagnostics v_total = row_count;
  return v_total;
end $$;
comment on function privado.limpar_checkin_por_codigo(integer, integer) is
  'LGPD (regra da Bússola, 08/11): apaga o estado do check-in por código (código exigido, confiança baixa e, em cascata, as tentativas) 90 dias depois do mais tarde entre o fim do turno e o fim da contestação. Contestação aberta segura. Conta a contestação com o turno_id e a de suspensão do profissional. Piso de 90 dias. Devolve quantos turnos saíram.';
revoke all on function privado.limpar_checkin_por_codigo(integer, integer) from public, anon, authenticated;
grant execute on function privado.limpar_checkin_por_codigo(integer, integer) to service_role;

-- ── 2. O valor vencido, a cada minuto ─────────────────────────────────────────

create index checkin_codigo_em_vigor on privado.checkin_codigo (expira_em) where codigo is not null;

create function privado.apagar_codigos_checkin_vencidos() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_total integer;
begin
  update privado.checkin_codigo c
     set codigo = null
   where c.codigo is not null
     and c.expira_em <= privado.agora();
  get diagnostics v_total = row_count;
  return v_total;
end $$;
comment on function privado.apagar_codigos_checkin_vencidos() is
  'Apaga o valor dos códigos de check-in vencidos (LGPD, regra da Bússola, 08/11): o código vale só durante a validade e sai do banco em até 1 minuto depois dela. Roda no pg_cron a cada minuto. A hora da geração e da validade ficam; o valor não sai em log.';
revoke all on function privado.apagar_codigos_checkin_vencidos() from public, anon, authenticated;
grant execute on function privado.apagar_codigos_checkin_vencidos() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('apagar_codigos_checkin_vencidos')
      where exists (select 1 from cron.job where jobname = 'apagar_codigos_checkin_vencidos');
    perform cron.schedule(
      'apagar_codigos_checkin_vencidos',
      '* * * * *',
      'select privado.apagar_codigos_checkin_vencidos()'
    );
  end if;
end $$;

-- ── 3. A anonimização da conta do profissional ────────────────────────────────
-- No padrão do trg_usuario_anonimizacao_chamada: qualquer caminho que anonimize a conta leva o
-- estado do código junto, e não só a excluir_conta de hoje. O profissional continua existindo
-- nesse momento (a limpeza dele é 15 dias depois), e é por ele que se acham os turnos.

create function privado.apagar_checkin_codigo_da_conta() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from privado.checkin_codigo c
   using public.turno t, public.posicao p, public.profissional pr
   where c.turno_id = t.id
     and p.id = t.posicao_id
     and pr.id = p.profissional_id
     and pr.usuario_id = new.id;
  return new;
end $$;
comment on function privado.apagar_checkin_codigo_da_conta() is
  'Na anonimização da conta (RF25), apaga o estado do check-in por código dos turnos do profissional, com as tentativas em cascata (LGPD, regra da Bússola, 08/11). Os turnos ficam, porque são também da casa.';
revoke all on function privado.apagar_checkin_codigo_da_conta() from public, anon, authenticated;

create trigger trg_usuario_anonimizacao_checkin_codigo
after update of estado on public.usuario
for each row
when (new.estado = 'anonimizada' and old.estado <> 'anonimizada')
execute function privado.apagar_checkin_codigo_da_conta();

-- ── 4. Na rotina diária ───────────────────────────────────────────────────────
-- Corpo copiado da vigente (20261108100000), com só a linha do check-in por código e a chave dela
-- no retorno acrescentadas.

create or replace function privado.executar_retencao_diaria()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anonimizadas      integer;
  v_higiene           jsonb;
  v_eventos_app       integer;
  v_expurgo_ident     jsonb;
  v_expurgo_perfil    integer;
  v_expurgo_chamada   integer;
  v_expurgo_checkin   integer;
  v_expurgo_turnos    integer;
  v_expurgo_vagas     integer;
  v_ocorrencias       integer;
  v_marcas            integer;
  v_expurgo_acessos   integer;
begin
  v_anonimizadas    := privado.limpar_contas_anonimizadas(15);
  v_higiene         := privado.higienizar_tabelas();
  v_eventos_app     := privado.limpar_eventos_app(90);
  v_expurgo_ident   := privado.expurgar_midias_verificacao_identidade();
  v_expurgo_perfil  := privado.expurgar_midias_recusadas();
  v_expurgo_chamada := privado.limpar_chamadas_expurgadas(90);
  v_expurgo_checkin := privado.limpar_checkin_por_codigo(90, 500);
  v_expurgo_turnos  := privado.expurgar_turnos_antigos(5, 500);
  v_expurgo_vagas   := privado.expurgar_vagas_antigas(5, 500);
  v_ocorrencias     := privado.anonimizar_ocorrencias_antigas(5, 500);
  v_marcas          := privado.limpar_marcas_notificacao(5, 1000);
  v_expurgo_acessos := privado.limpar_registros_acesso(6, 1000);

  return jsonb_build_object(
    'executado_em',                     privado.agora(),
    'contas_anonimizadas_limpas',       v_anonimizadas,
    'higiene',                          v_higiene,
    'eventos_app_limpos',               v_eventos_app,
    'expurgo_midia_identidade',         v_expurgo_ident,
    'expurgo_midia_perfil',             v_expurgo_perfil,
    'expurgo_chamadas_nao_aceitas',     v_expurgo_chamada,
    'expurgo_checkin_por_codigo',       v_expurgo_checkin,
    'expurgo_turnos_antigos',           v_expurgo_turnos,
    'expurgo_vagas_antigas',            v_expurgo_vagas,
    'anonimizacao_ocorrencias_antigas', v_ocorrencias,
    'expurgo_marcas_notificacao',       v_marcas,
    'expurgo_registros_acesso',         v_expurgo_acessos
  );
end $$;

comment on function privado.executar_retencao_diaria() is
  'Rotina diária consolidada de retenção e limpeza: contas anonimizadas (15 dias), higiene de tabelas, eventos do app (90 dias), expurgo de mídias de identidade e fotos recusadas (24 h), chamadas não aceitas (90 dias), o estado do check-in por código (90 dias depois do fim do turno ou da contestação, 0.2.68), turnos com mais de 5 anos e o contexto deles (vaga, chamada, despacho, posição sem turno, ocorrência de denúncia e cancelamento, marcas de notificação e trilha; LGPD-J6 fases 1 e 2) e registros de acesso à aplicação com mais de 6 meses (Marco Civil art. 15).';

revoke execute on function privado.executar_retencao_diaria() from public, anon, authenticated;
grant  execute on function privado.executar_retencao_diaria() to service_role;
