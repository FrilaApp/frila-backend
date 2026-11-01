-- 20261031150000_purga_notificacoes_60_dias.sql
--
-- Higiene e conformidade LGPD (K-001, K-001d, K-001g, PR #614 do frila-frontend, E11):
-- Purga periódica de notificações com mais de 60 dias (public.notificacao).
--
-- 1. Contexto e Justificativa de Negócio / LGPD:
--    A tabela public.notificacao armazena histórico de despachos, confirmações, lembretes
--    e avisos operacionais com metadados de entrega e identificadores de destinatário.
--    O Registro de Tratamento de Dados (ROPA / LGPD art. 37) prevê política de retenção
--    máxima de 60 dias para notificações da conta.
--
-- 2. Compatibilidade com Regras de Negócio e RN23:
--    - A cadência de notificações (RN23) estabelece intervalo de teto (teto_janela = 30 minutos)
--      e antecedência de urgência (urgente_antecedencia = 2 horas).
--    - A janela de retenção de 60 dias é ordens de grandeza superior a qualquer janela de teto
--      ou agrupamento da RN23, preservando a integridade das decisões de push e métricas.
--    - Para evitar que a purga de notificações de vagas futuras faça o despacho voltar a ser
--      tratado como pendente (K-001d), public.despacho ganha a coluna 'expurgado_em'.
--      liberar_teto_do_profissional ignora despachos expurgados, e privado.marca_notificacao
--      garante que a marca durável de envio não dependa de linha expurgável.
--
-- 3. Integridade Referencial e Bloqueio (public.despacho):
--    - A tabela privado.marca_notificacao, seu gatilho e o backfill histórico rodam previamente
--      na migração 20261031145000_marca_notificacao_duravel.sql em transação dedicada que não toca
--      em public.despacho, garantindo que o backfill não segure AccessExclusiveLock em despacho (K-001l / D1).
--    - A coluna expurgado_em é adicionada com default NULL (operação metadata-only).
--    - A chave estrangeira despacho_notificacao_id_fkey é recriada com ON DELETE SET NULL e
--      marcada como NOT VALID, exigindo apenas um lock curto com lock_timeout de 2s.
--    - A validação de linhas existentes roda em transação separada na migração
--      20261031150100_validar_fk_despacho_notificacao.sql (ShareUpdateExclusiveLock),
--      sem segurar AccessExclusiveLock em despacho durante a varredura da tabela.
--    - A purga opera em lotes de até 5000 linhas por chamada/transação (sem medição prévia
--      de volume acumulado em produção). Se houver mais linhas pendentes além do lote,
--      a função agenda automaticamente uma continuação no pg_cron para o minuto seguinte.
--
-- 4. Agendamento Automático:
--    - Agendado no pg_cron com o nome 'limpar_notificacoes_antigas' às 06:19 UTC ('19 6 * * *'),
--      fora da janela de tráfego quente (RNF12), no mesmo padrão de limpar_dispositivos_inativos.

-- 1. Coluna expurgado_em em public.despacho para diferenciar notificação expurgada de pendente (K-001d)
-- Adição de coluna anulável sem valor padrão exige apenas lock curto de metadados.
do $$
begin
  execute 'set local lock_timeout = ''2s''';
  alter table public.despacho
    add column if not exists expurgado_em timestamptz default null;
end $$;

comment on column public.despacho.expurgado_em is
  'Instante em que a notificação deste despacho foi expurgada (60 dias). Impede reenvios indevidos por liberar_teto_do_profissional.';

-- 2. Ajusta chave estrangeira com lock_timeout e NOT VALID (K-001d, K-001g, K-001l)
-- A validação da constraint é postergada para a migração 20261031150100 em transação separada.
do $$
begin
  execute 'set local lock_timeout = ''2s''';
  alter table public.despacho drop constraint if exists despacho_notificacao_id_fkey;
  alter table public.despacho
    add constraint despacho_notificacao_id_fkey
      foreign key (notificacao_id)
      references public.notificacao(id)
      on delete set null
      not valid;
end $$;

-- 3. Atualiza privado.notificar com marca como autoridade atômica do envio (K-001d, K-001l / N1)
create or replace function privado.notificar(
  p_usuario    uuid,
  p_tipo       public.tipo_notificacao,
  p_referencia uuid,
  p_payload    jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prof          uuid;
  v_id            uuid;
  v_par           record;
  v_rodada        integer := 1;
  v_marca_criada  integer;
begin
  -- RN15: o payload é estrutura, não texto livre.
  for v_par in select key, value from jsonb_each(coalesce(p_payload, '{}'::jsonb)) loop
    if not (
      (v_par.key = 'reaberta' and jsonb_typeof(v_par.value) = 'boolean')
      or (v_par.key in ('vaga_id', 'posicao_id', 'turno_id', 'estabelecimento_id')
          and jsonb_typeof(v_par.value) = 'string'
          and (v_par.value #>> '{}') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    ) then
      raise exception 'payload_invalido' using errcode = '22023', detail = v_par.key;
    end if;
  end loop;

  if p_tipo in ('vaga', 'vagas_agrupadas') then
    select p.id into v_prof from public.profissional p where p.usuario_id = p_usuario;
  end if;

  if p_tipo = 'vaga' then
    select g.rodada_despacho into v_rodada from public.vaga g where g.id = p_referencia;
    v_rodada := coalesce(v_rodada, 1);
  end if;

  -- Deduplicação atômica via marca_notificacao (K-001d, K-001l / N1):
  -- A marca durável em privado.marca_notificacao é a autoridade atômica do envio.
  -- Tentamos registrar a marca antes de qualquer inserção em public.notificacao.
  -- Se a marca já existia (v_marca_criada is null), o aviso já foi enviado no passado:
  -- NUNCA reinserimos em public.notificacao (mesmo que a notificação tenha sido expurgada
  -- pela purga de 60 dias ou esteja sendo expurgada concorrentemente).
  if p_tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis',
                'vaga') then
    insert into privado.marca_notificacao (tipo, referencia_id, usuario_id, rodada, criada_em)
    values (p_tipo, p_referencia, p_usuario, v_rodada, privado.agora())
    on conflict (tipo, referencia_id, usuario_id, rodada) do nothing
    returning 1 into v_marca_criada;

    if v_marca_criada is null then
      -- Marca já existia: se a notificação ainda está na tabela (ativa), retorna seu id.
      -- Se já foi expurgada pela purga de 60 dias, retorna null sem recriar.
      select n.id into v_id
        from public.notificacao n
       where n.tipo = p_tipo
         and n.referencia_id = p_referencia
         and n.usuario_id = p_usuario
         and n.rodada = v_rodada;

      return v_id;
    end if;
  end if;

  insert into public.notificacao (usuario_id, profissional_id, tipo, referencia_id, payload,
                                  enviada_em, rodada)
  values (p_usuario, v_prof, p_tipo, p_referencia,
          coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('tipo', p_tipo),
          privado.agora(), v_rodada)
  on conflict (tipo, referencia_id, usuario_id, rodada)
    where tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                   'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis',
                   'vaga')
    do nothing
  returning id into v_id;

  if v_id is null then
    select n.id into v_id from public.notificacao n
     where n.tipo = p_tipo and n.referencia_id = p_referencia and n.usuario_id = p_usuario
       and n.rodada = v_rodada;
  end if;

  return v_id;
end $$;

-- 4. Atualiza privado.liberar_teto_do_profissional para ignorar despachos expurgados (K-001d)
create or replace function privado.liberar_teto_do_profissional(p_profissional uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_usuario uuid;
  v_ultima  timestamptz;
  v_agora   timestamptz := privado.agora();
  v_ids     uuid[];
  v_vagas   uuid[];
  v_ref     uuid;
  v_reab    boolean;
  v_esperou boolean;
  v_payload jsonb;
  v_notif   uuid;
begin
  perform privado.travar_teto(p_profissional);

  select p.usuario_id into v_usuario from public.profissional p where p.id = p_profissional;
  if v_usuario is null then
    return null;
  end if;

  v_ultima := privado.ultima_no_teto(v_usuario);
  if v_ultima is not null
     and v_ultima > v_agora - privado.parametro_de_notificacao('teto_janela') then
    return null;
  end if;

  select array_agg(d.id order by d.criado_em, d.id),
         array_agg(d.vaga_id order by d.criado_em, d.id),
         bool_or(d.reaberta),
         bool_or(d.criado_em < v_agora)
    into v_ids, v_vagas, v_reab, v_esperou
    from public.despacho d
    join public.vaga v on v.id = d.vaga_id
   where d.profissional_id = p_profissional
     and d.notificacao_id is null
     and d.expurgado_em is null
     and v.estado = 'publicada'
     and v.inicio_em > v_agora
     -- Ocultada pela Equipe Frila: o despacho espera; se ela for reexibida, sai.
     and not privado.vaga_oculta(v.id)
     -- RF26: o bloqueio que veio enquanto o despacho esperava o teto.
     and not privado.bloqueado_com_estabelecimento(v_usuario, v.estabelecimento_id);

  if v_ids is null then
    return null;
  end if;

  if cardinality(v_ids) = 1 then
    v_payload := jsonb_build_object('vaga_id', v_vagas[1]);
    if v_reab then
      v_payload := v_payload || jsonb_build_object('reaberta', true);
    end if;
    v_notif := privado.notificar(v_usuario, 'vaga', v_vagas[1], v_payload);
  else
    select v.id into v_ref from public.vaga v
     where v.id = any (v_vagas)
     order by v.inicio_em desc, v.id
     limit 1;
    v_notif := privado.notificar(v_usuario, 'vagas_agrupadas', v_ref, '{}'::jsonb);
  end if;

  update public.notificacao n
     set esperou_teto = v_esperou or cardinality(v_ids) > 1
   where n.id = v_notif;

  update public.despacho d
     set notificacao_id = v_notif
   where d.id = any (v_ids)
     and d.notificacao_id is null;

  return v_notif;
end $$;

-- 5. Função de purga em lote único por chamada/transação com continuação reagendada (K-001g)
drop function if exists privado.limpar_notificacoes_antigas(integer);

create or replace function privado.limpar_notificacoes_antigas(
  p_dias   integer default 60,
  p_limite integer default 5000
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limite timestamptz;
  v_agora timestamptz := privado.agora();
  v_lote_ids uuid[];
  v_removidos integer := 0;
  v_tem_mais boolean := false;
begin
  if p_dias is null or p_dias < 1 then
    p_dias := 60;
  end if;
  if p_limite is null or p_limite < 1 then
    p_limite := 5000;
  end if;

  v_limite := v_agora - (p_dias || ' days')::interval;

  -- 1. Seleciona até um lote (p_limite) de notificações vencidas
  select array_agg(sub.id) into v_lote_ids
    from (
      select n.id
        from public.notificacao n
       where n.enviada_em < v_limite
       order by n.enviada_em, n.id
       limit p_limite
    ) sub;

  if v_lote_ids is not null and cardinality(v_lote_ids) > 0 then
    -- Sinaliza retenção autorizada para que desvinculação em despacho passe pelo gatilho despacho_imutavel (RF25)
    perform set_config('privado.retencao', 'on', true);

    -- 2. Marca despacho como expurgado e desvincula a FK da notificação que será apagada
    update public.despacho
       set notificacao_id = null,
           expurgado_em = v_agora
     where notificacao_id = any (v_lote_ids);

    -- 3. Purga o lote de notificações com mais de p_dias
    delete from public.notificacao
     where id = any (v_lote_ids);

    perform set_config('privado.retencao', 'off', true);

    v_removidos := cardinality(v_lote_ids);
  end if;

  -- 4. Verifica se ainda restam notificações vencidas após este lote
  select exists (
    select 1
      from public.notificacao n
     where n.enviada_em < v_limite
  ) into v_tem_mais;

  -- 5. Reagendamento da continuação via pg_cron (se houver mais linhas pendentes)
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if v_tem_mais then
      perform cron.schedule(
        'limpar_notificacoes_antigas_continua',
        '* * * * *',
        'select privado.limpar_notificacoes_antigas(' || p_dias || ', ' || p_limite || ')'
      );
    else
      perform cron.unschedule('limpar_notificacoes_antigas_continua')
        where exists (
          select 1 from cron.job
           where jobname = 'limpar_notificacoes_antigas_continua'
        );
    end if;
  end if;

  return v_removidos;
end $$;

comment on function privado.limpar_notificacoes_antigas(integer, integer) is
  'Purga notificações enviadas há mais de p_dias (padrão 60 dias, ROPA da LGPD art. 37) em um lote de até p_limite registros por transação, marcando despachos como expurgados sob sinal privado.retencao=on (RF25, RN23, K-001g). Caso restem linhas pendentes (sem medição prévia de volume), reagenda a continuação minuto a minuto via pg_cron até a conclusão.';

revoke execute on function privado.limpar_notificacoes_antigas(integer, integer) from public, anon, authenticated;
grant  execute on function privado.limpar_notificacoes_antigas(integer, integer) to service_role;

-- 6. Agendamento diário às 06:19 UTC (03:19 BRT), fora da janela protegida por RNF12
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('limpar_notificacoes_antigas')
      where exists (select 1 from cron.job where jobname = 'limpar_notificacoes_antigas');
    perform cron.schedule(
      'limpar_notificacoes_antigas',
      '19 6 * * *',
      'select privado.limpar_notificacoes_antigas()'
    );
  end if;
end $$;
