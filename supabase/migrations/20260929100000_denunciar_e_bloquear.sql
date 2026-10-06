-- `denunciar` e `bloquear` (cartão JWJOPAOL · RF26, RN13, RN15, UC17 · contrato 0.2.20).
--
-- Exigência da diretriz 1.2 da App Store. A denúncia chega à Equipe Frila por e-mail
-- com protocolo; o bloqueio é imediato e automático, e vale nos dois sentidos.
--
-- O que já existia: `privado.bloqueado_com_estabelecimento` filtra `vagas_abertas`,
-- `detalhe_vaga`, `candidatar`, `contato_do_turno`, a elegibilidade do despacho e as
-- políticas de `vaga` e `candidatura`. O que faltava, além das duas RPCs, eram os dois
-- caminhos por onde uma vaga ainda chegava depois do bloqueio:
--
--   1. o despacho que esperava o teto da RN23 (`liberar_teto_do_profissional`), criado
--      antes do bloqueio e liberado depois dele;
--   2. o aviso de vaga já enfileirado para o push (`notificacao_expirada`), que o
--      `enviar-push` consulta antes de mandar.
--
-- O e-mail em si é do cartão 7yq1flLG (fila `email` e Edge Function `enviar-email`):
-- aqui a denúncia só deixa o pedido na fila, com o id da ocorrência e nada mais (RN15).

-- ── 1. A ocorrência de denúncia ───────────────────────────────────────────────

-- O relato é texto livre de quem denunciou e pode trazer dado pessoal de qualquer das
-- partes. Fica em coluna própria, e não concatenado a `motivo`, para que a retenção o
-- apague sem perder a categoria da denúncia.
alter table public.ocorrencia add column relato text;

-- O alvo de uma denúncia pode ser um estabelecimento, e o estabelecimento não é uma
-- conta: escolher um membro para `usuario_id` apagaria qual das casas dele foi
-- denunciada. `usuario_id` fica para quando o alvo é uma pessoa.
alter table public.ocorrencia
  add column estabelecimento_id uuid references public.estabelecimento(id);

create index ocorrencia_por_estabelecimento
  on public.ocorrencia (estabelecimento_id) where estabelecimento_id is not null;

comment on column public.ocorrencia.relato is
  'Relato de quem abriu a denúncia (RF26). Pode conter dado pessoal: só a Equipe Frila lê, pela chave de serviço, e a retenção o apaga 15 dias depois da exclusão da conta autora (RF25, RN15). Nunca vai para log nem para a fila de e-mail.';
comment on column public.ocorrencia.estabelecimento_id is
  'Alvo da ocorrência quando é um estabelecimento (denúncia contra a casa). Quando o alvo é uma pessoa, é `usuario_id`.';

-- ── 2. A fila `email` ─────────────────────────────────────────────────────────
--
-- Nasce aqui porque a denúncia é a primeira a escrever nela; o consumidor é a
-- `enviar-email` do cartão 7yq1flLG. Condicional porque aquele cartão também a cria, e
-- a ordem entre os dois não é garantida.
do $$
begin
  if not exists (select 1 from pgmq.meta where queue_name = 'email') then
    perform pgmq.create('email');
  end if;
end $$;

-- O mesmo raciocínio da fila de despacho: o `ensure_rls` só alcança `public`. Com RLS
-- ligada e sem política, só quem tem `bypassrls` lê — as RPCs e o consumidor.
alter table pgmq.q_email enable row level security;

comment on table pgmq.q_email is
  'Pedidos de e-mail transacional (7yq1flLG). Cada mensagem leva o tipo e ids, nunca o corpo nem dado pessoal (RN15): o consumidor monta o e-mail no envio. RLS ligada e sem política.';

-- ── 3. O prazo de resposta ────────────────────────────────────────────────────
--
-- A Equipe Frila responde em até 5 dias úteis. Conta a partir do dia de Brasília
-- seguinte ao registro e pula sábado e domingo. Feriado não entra: não há calendário
-- de feriados no banco, e inventar um aqui seria decidir quais valem.
create or replace function privado.prazo_de_resposta(instante timestamptz)
returns date
language sql
stable
set search_path = ''
as $$
  select d::date
    from generate_series((instante at time zone 'America/Sao_Paulo')::date + 1,
                         (instante at time zone 'America/Sao_Paulo')::date + 14,
                         interval '1 day') d
   where extract(isodow from d) < 6
   order by d
  offset 4
   limit 1
$$;

comment on function privado.prazo_de_resposta(timestamptz) is
  'Data-limite da resposta da Equipe Frila: 5 dias úteis (segunda a sexta) contados do dia seguinte ao registro, no fuso de Brasília. Sem feriados.';

revoke execute on function privado.prazo_de_resposta(timestamptz) from public, anon, authenticated;
grant  execute on function privado.prazo_de_resposta(timestamptz) to service_role;

-- ── 4. bloquear ───────────────────────────────────────────────────────────────
--
-- O alvo chega como o app o tem na tela: o par `alvo_tipo` + `alvo_id` do
-- `PerfilPublico`. O servidor resolve as contas:
--
--   · estabelecimento → todos os membros. Um bloqueio por membro, porque o membro que
--     entrar depois também não pode alcançar quem bloqueou a casa pela conta dele;
--   · profissional → a conta dele.
--
-- Quem bloqueia é a conta de quem chama. Um membro que bloqueia um profissional
-- bloqueia pela casa inteira sem precisar de uma linha por colega: a auxiliar
-- `bloqueado_com_estabelecimento` junta o bloqueio com `membro_estabelecimento`.
--
-- As partes que se cruzam no produto são a pessoa e a casa. Profissional bloqueando
-- profissional, ou membro bloqueando estabelecimento, não teria efeito em leitura
-- nenhuma — e um bloqueio que não bloqueia nada seria mentir para quem pediu.
create or replace function public.bloquear(alvo_tipo text, alvo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_tipo   text := bloquear.alvo_tipo;
  v_alvo   uuid := bloquear.alvo_id;
  v_perfil public.perfil_conta;
  v_contas uuid[];
  v_criado timestamptz;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  if v_tipo is null then
    perform public.erro(422, 'campo_obrigatorio', 'alvo_tipo');
  end if;
  if v_alvo is null then
    perform public.erro(422, 'campo_obrigatorio', 'alvo_id');
  end if;
  if v_tipo not in ('profissional', 'estabelecimento') then
    perform public.erro(422, 'campo_invalido', 'alvo_tipo');
  end if;

  v_perfil := privado.perfil_da_conta();
  if (v_perfil = 'profissional') is distinct from (v_tipo = 'estabelecimento') then
    perform public.erro(422, 'campo_invalido', 'alvo_tipo');
  end if;

  if v_tipo = 'estabelecimento' then
    select array_agg(m.usuario_id) into v_contas
      from public.membro_estabelecimento m
     where m.estabelecimento_id = v_alvo;
  else
    select array_agg(p.usuario_id) into v_contas
      from public.profissional p
     where p.id = v_alvo;
  end if;

  if v_contas is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Idempotente pelo par: o reenvio não cria linha, e o `criado_em` devolvido é o do
  -- primeiro bloqueio.
  insert into public.bloqueio (autor_id, bloqueado_id, criado_em)
  select v_uid, c, privado.agora() from unnest(v_contas) c
  on conflict (autor_id, bloqueado_id) do nothing;

  select min(b.criado_em) into v_criado
    from public.bloqueio b
   where b.autor_id = v_uid and b.bloqueado_id = any (v_contas);

  return jsonb_build_object('alvo_tipo', v_tipo, 'alvo_id', v_alvo, 'criado_em', v_criado);
end $$;

comment on function public.bloquear(text, uuid) is
  'Bloqueia a outra parte pelo par alvo_tipo + alvo_id do PerfilPublico (RF26, UC17). Estabelecimento: todos os membros; profissional: a conta dele. Imediato, nos dois sentidos, idempotente por par. Devolve o par recebido, nunca o id de conta (RN10).';

revoke execute on function public.bloquear(text, uuid) from public, anon;
grant  execute on function public.bloquear(text, uuid) to authenticated;

-- ── 5. denunciar ──────────────────────────────────────────────────────────────
--
-- Grava a `ocorrencia` de denúncia e deixa o pedido de e-mail na fila. Idempotente pela
-- `chave` do app: o reenvio devolve o mesmo protocolo e não enfileira outro e-mail.
--
-- Denúncia não depende de bloqueio nem de relação ativa: quem se sentiu ameaçado
-- costuma bloquear primeiro e denunciar depois, e as duas coisas têm de funcionar nessa
-- ordem. O `turno_id`, quando vem, tem de ser um turno entre as duas partes; qualquer
-- outro responde 404, como o turno alheio em `contato_do_turno`.
create or replace function public.denunciar(
  alvo_tipo text,
  alvo_id   uuid,
  motivo    text,
  relato    text,
  chave     uuid,
  turno_id  uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_tipo    text := denunciar.alvo_tipo;
  v_alvo    uuid := denunciar.alvo_id;
  v_motivo  text := btrim(denunciar.motivo);
  v_relato  text := btrim(denunciar.relato);
  v_chave   uuid := denunciar.chave;
  v_turno   uuid := denunciar.turno_id;
  v_usuario uuid;
  v_estab   uuid;
  v_t_prof  uuid;
  v_t_estab uuid;
  v_oc      public.ocorrencia%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  if v_chave is null then
    perform public.erro(422, 'campo_obrigatorio', 'chave');
  end if;

  -- O reenvio devolve o que já foi gravado, antes de qualquer conferência: a rede que
  -- caiu depois do commit não pode transformar a mesma denúncia em recusa.
  select * into v_oc from public.ocorrencia o
   where o.autor_id = v_uid and o.chave_cliente = v_chave and o.tipo = 'denuncia';
  if found then
    return jsonb_build_object('ocorrencia_id', v_oc.id, 'tipo', 'denuncia',
                              'criada_em', v_oc.criada_em,
                              'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em));
  end if;

  if v_tipo is null then
    perform public.erro(422, 'campo_obrigatorio', 'alvo_tipo');
  end if;
  if v_alvo is null then
    perform public.erro(422, 'campo_obrigatorio', 'alvo_id');
  end if;
  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;
  if v_relato is null or v_relato = '' then
    perform public.erro(422, 'campo_obrigatorio', 'relato');
  end if;
  if v_tipo not in ('profissional', 'estabelecimento') then
    perform public.erro(422, 'campo_invalido', 'alvo_tipo');
  end if;
  if not (v_motivo = any (enum_range(null::public.motivo_denuncia)::text[])) then
    perform public.erro(422, 'campo_invalido', 'motivo');
  end if;
  if char_length(v_relato) < 10 then
    perform public.erro(422, 'campo_invalido', 'relato');
  end if;

  if v_tipo = 'estabelecimento' then
    select e.id into v_estab from public.estabelecimento e where e.id = v_alvo;
    if v_estab is null then
      perform public.erro(404, 'nao_encontrado');
    end if;
    if exists (select 1 from public.membro_estabelecimento m
                where m.estabelecimento_id = v_estab and m.usuario_id = v_uid) then
      perform public.erro(422, 'campo_invalido', 'alvo_id');
    end if;
  else
    select p.usuario_id into v_usuario from public.profissional p where p.id = v_alvo;
    if v_usuario is null then
      perform public.erro(404, 'nao_encontrado');
    end if;
    if v_usuario = v_uid then
      perform public.erro(422, 'campo_invalido', 'alvo_id');
    end if;
  end if;

  if v_turno is not null then
    select p.profissional_id, v.estabelecimento_id into v_t_prof, v_t_estab
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga v    on v.id = p.vaga_id
     where t.id = v_turno;

    -- As duas pontas do turno têm de ser quem denuncia e quem é denunciado.
    if not found
       or not (
         (v_estab is not null
            and v_t_estab = v_estab
            and exists (select 1 from public.profissional p
                         where p.id = v_t_prof and p.usuario_id = v_uid))
         or
         (v_usuario is not null
            and exists (select 1 from public.profissional p
                         where p.id = v_t_prof and p.usuario_id = v_usuario)
            and exists (select 1 from public.membro_estabelecimento m
                         where m.estabelecimento_id = v_t_estab and m.usuario_id = v_uid))
       ) then
      perform public.erro(404, 'nao_encontrado');
    end if;
  end if;

  insert into public.ocorrencia (tipo, turno_id, usuario_id, estabelecimento_id, autor_id,
                                 motivo, relato, chave_cliente, criada_em)
  values ('denuncia', v_turno, v_usuario, v_estab, v_uid,
          v_motivo, v_relato, v_chave, privado.agora())
  on conflict (autor_id, chave_cliente) do nothing
  returning * into v_oc;

  if v_oc.id is null then
    -- Dois reenvios simultâneos: o outro gravou primeiro, e o e-mail é dele.
    select * into v_oc from public.ocorrencia o
     where o.autor_id = v_uid and o.chave_cliente = v_chave;
  else
    -- Só o id: o consumidor lê motivo e relato da ocorrência no envio, e o relato
    -- nunca passa pela fila (RN15).
    perform pgmq.send('email', jsonb_build_object('tipo', 'denuncia', 'ocorrencia_id', v_oc.id));
  end if;

  return jsonb_build_object('ocorrencia_id', v_oc.id, 'tipo', 'denuncia',
                            'criada_em', v_oc.criada_em,
                            'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em));
end $$;

comment on function public.denunciar(text, uuid, text, text, uuid, uuid) is
  'Registra denúncia contra a outra parte (RF26, RN13, UC17) e enfileira o e-mail à Equipe Frila na fila email, só com o id (RN15). Idempotente pela chave do app. Devolve o Protocolo com prazo de 5 dias úteis.';

revoke execute on function public.denunciar(text, uuid, text, text, uuid, uuid) from public, anon;
grant  execute on function public.denunciar(text, uuid, text, text, uuid, uuid) to authenticated;

-- ── 6. O despacho que esperava o teto ─────────────────────────────────────────
--
-- Idêntica à de 20260928210000, mais a linha do bloqueio. O despacho criado antes do
-- bloqueio fica sem notificação para sempre, e isso é o certo: ele é o registro de que a
-- vaga foi oferecida, e não pode ser apagado (despacho é imutável).
create or replace function privado.liberar_teto_do_profissional(p_profissional uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_usuario uuid;
  v_ultima  timestamptz;
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
     and v.estado = 'publicada'
     and v.inicio_em > v_agora
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
    -- A referência é a vaga que começa por último: a agrupada só expira (não é mais
    -- enviada) quando todas as vagas dela já começaram. O toque abre a aba de vagas, e o
    -- payload leva só o tipo.
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

comment on function privado.liberar_teto_do_profissional(uuid) is
  'RN23: se a janela do teto do profissional fechou, transforma os despachos que esperavam numa notificação (vaga, ou vagas_agrupadas com dois ou mais). Sob trava por profissional. Vaga de estabelecimento com bloqueio entre as partes não sai (RF26).';

-- ── 7. O aviso de vaga já enfileirado ─────────────────────────────────────────
--
-- `enviar-push` pergunta a `notificacao_expirada` antes de mandar. A regra do relógio
-- continua inteira na função de antes, que só muda de nome; esta confere o bloqueio e
-- delega. Só os avisos de oferta de vaga: os do turno já confirmado (lembrete,
-- check-in) seguem saindo, porque o turno sobrevive ao bloqueio e sem o lembrete o
-- profissional ganharia uma falta que não escolheu. O que fazer com o turno confirmado
-- entre partes que se bloquearam é decisão de produto em aberto.
alter function privado.notificacao_expirada(uuid) rename to notificacao_expirada_pelo_relogio;

comment on function privado.notificacao_expirada_pelo_relogio(uuid) is
  'A regra de tempo de privado.notificacao_expirada: expira no início do turno ou da vaga; inicio_sem_checkin e atraso_15min valem até o fim; reabertura por atraso até fim − 1 h (8zLfn0mt item 5).';

revoke execute on function privado.notificacao_expirada_pelo_relogio(uuid) from public, anon, authenticated;
grant  execute on function privado.notificacao_expirada_pelo_relogio(uuid) to service_role;

create or replace function privado.notificacao_expirada(p_notificacao_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_notif public.notificacao%rowtype;
begin
  select * into v_notif from public.notificacao where id = p_notificacao_id;
  if not found then
    return true;
  end if;

  if v_notif.tipo = 'vaga'
     and exists (select 1 from public.vaga v
                  where v.id = v_notif.referencia_id
                    and privado.bloqueado_com_estabelecimento(v_notif.usuario_id, v.estabelecimento_id)) then
    return true;
  end if;

  -- A agrupada só deixa de servir quando todas as vagas dela são de casas bloqueadas.
  if v_notif.tipo = 'vagas_agrupadas'
     and exists (select 1 from public.despacho d where d.notificacao_id = v_notif.id)
     and not exists (select 1 from public.despacho d
                       join public.vaga v on v.id = d.vaga_id
                      where d.notificacao_id = v_notif.id
                        and not privado.bloqueado_com_estabelecimento(v_notif.usuario_id, v.estabelecimento_id)) then
    return true;
  end if;

  return privado.notificacao_expirada_pelo_relogio(p_notificacao_id);
end $$;

comment on function privado.notificacao_expirada(uuid) is
  'Verifica se o aviso ainda serve. O aviso de vaga de estabelecimento com bloqueio entre as partes não serve mais (RF26); o resto é a regra de tempo de notificacao_expirada_pelo_relogio.';

revoke execute on function privado.notificacao_expirada(uuid) from public, anon, authenticated;
grant  execute on function privado.notificacao_expirada(uuid) to service_role;

-- ── 8. A retenção apaga o relato ──────────────────────────────────────────────
--
-- Idêntica à de 20260927010000, mais `relato`: a conta anonimizada perde o relato das
-- ocorrências que abriu, como já perdia o texto do motivo.
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
         or exists (select 1 from public.disponibilidade d where d.profissional_id = p.id)
         or exists (select 1 from public.profissional_funcao pf where pf.profissional_id = p.id)
         or exists (select 1 from public.dispositivo disp where disp.usuario_id = u.id)
         or exists (select 1 from public.ocorrencia o
                     where o.autor_id = u.id
                       and (o.motivo <> '[removido por exclusão de conta]' or o.relato is not null))
       )
  loop
    -- Ativa sinal de sessão para permitir substituição do relato na ocorrência imutável
    perform set_config('privado.retencao', 'on', true);

    -- 1. Apaga disponibilidade semanal, funções e ponto base do profissional
    if v_candidato.profissional_id is not null then
      delete from public.disponibilidade where profissional_id = v_candidato.profissional_id;
      delete from public.profissional_funcao where profissional_id = v_candidato.profissional_id;
      update public.profissional
         set ponto_base = null
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

    perform set_config('privado.retencao', 'off', true);
    v_total := v_total + 1;
  end loop;

  return v_total;
end $$;

comment on function privado.limpar_contas_anonimizadas(integer) is
  'Apaga disponibilidade, funções, aparelhos, zera nascimento e ponto base, e substitui o motivo e apaga o relato das ocorrências para contas anonimizadas após p_dias dias (RF25, RN15).';

revoke execute on function privado.limpar_contas_anonimizadas(integer) from public, anon, authenticated;
grant  execute on function privado.limpar_contas_anonimizadas(integer) to service_role;
