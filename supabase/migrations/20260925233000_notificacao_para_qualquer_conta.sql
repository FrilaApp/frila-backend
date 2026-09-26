-- Notificação para qualquer conta, marca de envio e payload do destino do toque.
--
-- `notificacao` só sabia falar com profissional, e metade dos avisos do produto vai
-- para a casa (confirmação, check-in, cancelamento) ou é do turno (lembrete, atraso).
-- O destinatário passa a ser a **conta**; o profissional só existe nas notificações de
-- vaga, que são as que o teto da RN23 conta.
--
-- Esta migração é só a fila e a marca. O envio pelo FCM, para todos os aparelhos da
-- conta, é o cartão em paralelo: ele lê `estado_entrega = 'pendente'` e escreve
-- `tentativas` e `aceita_em`.

create type public.tipo_notificacao as enum (
  'vaga', 'vagas_agrupadas', 'vaga_sem_elegiveis',
  'confirmacao', 'lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
  'fim_sem_checkout', 'vaga_vazia', 'checkin', 'checkin_manual_pendente',
  'cancelamento', 'avaliacao_disponivel', 'suspensao', 'reativacao');

comment on type public.tipo_notificacao is
  'Os dezesseis avisos do produto. `vaga` e `vagas_agrupadas` vão ao profissional e contam no teto da RN23; os demais vão à conta que precisa agir ou saber.';

alter table public.notificacao
  add column usuario_id    uuid references public.usuario(id) on delete cascade,
  add column tipo          public.tipo_notificacao,
  add column referencia_id uuid,
  add column payload       jsonb not null default '{}'::jsonb,
  add column tentativas    int not null default 0 check (tentativas >= 0),
  add column aceita_em     timestamptz;

-- O que já existia era de vaga, para um profissional. A referência de uma linha antiga é
-- a vaga do primeiro despacho e, sem despacho, a própria linha: só precisa ser não nula.
update public.notificacao n
   set usuario_id    = p.usuario_id,
       tipo          = 'vaga',
       referencia_id = coalesce((select d.vaga_id from public.despacho d
                                  where d.notificacao_id = n.id limit 1), n.id)
  from public.profissional p
 where p.id = n.profissional_id;

alter table public.notificacao
  alter column usuario_id    set not null,
  alter column tipo          set not null,
  alter column referencia_id set not null,
  alter column profissional_id drop not null;

-- Profissional se e somente se o tipo é de vaga: o teto da RN23 lê `profissional_id`, e
-- um aviso de contratante com profissional preenchido entraria na conta dele sem ser
-- vaga.
alter table public.notificacao
  add constraint notificacao_profissional_so_de_vaga
  check ((tipo in ('vaga', 'vagas_agrupadas')) = (profissional_id is not null));

-- ── Os índices ────────────────────────────────────────────────────────────────

-- O teto (RN23) pergunta quando saiu a última notificação **de vaga** da pessoa. Com
-- os avisos de turno na mesma tabela, um índice sobre todas responderia com o lembrete
-- das três da tarde, e o teto seguraria vaga por causa de um aviso que não é vaga.
drop index public.notificacao_teto;
create index notificacao_teto on public.notificacao (profissional_id, enviada_em desc)
  where tipo in ('vaga', 'vagas_agrupadas');

-- A marca de envio: o que substitui "lembrete enviado" e "alerta enviado". O agendador
-- roda a cada minuto e chama `notificar` de novo; o índice é o que faz a segunda
-- chamada não ser um segundo push. Só os tipos agendados: uma confirmação e o
-- cancelamento de outra posição da mesma vaga são avisos diferentes, e um cancelamento
-- repetido é só um cancelamento que a conta precisa ver.
create unique index notificacao_marca_de_envio
  on public.notificacao (tipo, referencia_id, usuario_id)
  where tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                 'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel');

create index notificacao_da_conta on public.notificacao (usuario_id, enviada_em desc);

-- ── A leitura é da conta ──────────────────────────────────────────────────────
drop policy notificacao_leitura on public.notificacao;
create policy notificacao_leitura on public.notificacao for select to authenticated
  using (usuario_id = (select auth.uid()));

-- ── Comentários (RNF08) ───────────────────────────────────────────────────────
comment on table public.notificacao is
  'Fila e registro de push: qual aviso saiu, para qual conta, quando e se chegou. Uma linha por conta e aviso, e o envio vai a todos os aparelhos da conta. Conta no teto de RN23 só o que é de vaga. O corpo do push é montado no envio; aqui há só tipo e ids.';
comment on column public.notificacao.usuario_id is
  'Conta destinatária. Profissional ou contratante: metade dos avisos do produto vai para a casa.';
comment on column public.notificacao.profissional_id is
  'Só nas notificações de vaga (`vaga`, `vagas_agrupadas`), para o teto da RN23. Nulo em todas as demais, por CHECK.';
comment on column public.notificacao.tipo is
  'Qual dos avisos do produto. Decide o destinatário, o texto e se a linha conta no teto.';
comment on column public.notificacao.referencia_id is
  'A coisa de que o aviso trata (vaga, posição ou turno, conforme o tipo). Com o tipo e a conta, é a marca de envio dos tipos agendados.';
comment on column public.notificacao.payload is
  'O destino do toque: o tipo e ids, nada mais (RN15). Sem telefone, e-mail, nome ou coordenada; `privado.notificar` recusa qualquer outra chave e qualquer valor que não seja uuid ou booleano.';
comment on column public.notificacao.tentativas is
  'Quantas vezes o envio ao FCM foi tentado. Escrito pelo agendador, nunca pelo app.';
comment on column public.notificacao.aceita_em is
  'Quando o FCM aceitou a mensagem. Aceitar não é entregar: `entregue_em` continua sendo a confirmação do aparelho.';

-- ── privado.notificar ─────────────────────────────────────────────────────────

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
  v_prof  uuid;
  v_id    uuid;
  v_par   record;
begin
  -- RN15: o payload é estrutura, não texto livre. Chave fora do vocabulário ou valor
  -- que não seja uuid ou booleano é recusado aqui, e não em revisão: o dia em que
  -- alguém puser o nome da casa "só para o push ficar bonito" o dado pessoal vai parar
  -- em log do FCM.
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

  insert into public.notificacao (usuario_id, profissional_id, tipo, referencia_id, payload)
  values (p_usuario, v_prof, p_tipo, p_referencia,
          coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('tipo', p_tipo))
  on conflict (tipo, referencia_id, usuario_id)
    where tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                   'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel')
    do nothing
  returning id into v_id;

  -- Marca já existente: devolve a linha que a ocupa, para o chamador não tratar o
  -- reenvio como erro nem como novidade.
  if v_id is null then
    select n.id into v_id from public.notificacao n
     where n.tipo = p_tipo and n.referencia_id = p_referencia and n.usuario_id = p_usuario;
  end if;

  return v_id;
end $$;

comment on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb) is
  'Enfileira um aviso para uma conta (estado pendente; o envio a todos os aparelhos é do agendador). Nos tipos agendados, chamar de novo com o mesmo tipo, referência e conta não cria segunda linha. O payload só aceita ids e o booleano `reaberta` (RN15).';

-- Toda a casa, sem ordem e sem prioridade (RN06): cada membro recebe o seu.
create or replace function privado.notificar_membros(
  p_estabelecimento uuid,
  p_tipo            public.tipo_notificacao,
  p_referencia      uuid,
  p_payload         jsonb default '{}'::jsonb
)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membro uuid;
  v_n      int := 0;
begin
  for v_membro in select m.usuario_id from public.membro_estabelecimento m
                   where m.estabelecimento_id = p_estabelecimento
  loop
    perform privado.notificar(v_membro, p_tipo, p_referencia, p_payload);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

comment on function privado.notificar_membros(uuid, public.tipo_notificacao, uuid, jsonb) is
  'Um aviso para cada membro do estabelecimento (RF10). Sem filtro de papel: administrador e operador precisam saber igual.';

revoke execute on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function privado.notificar_membros(uuid, public.tipo_notificacao, uuid, jsonb)
  from public, anon, authenticated;

-- ── Ligadas aos avisos do Sprint 1 ────────────────────────────────────────────

-- candidatar: `confirmacao` ao profissional e à casa (RF10).
create or replace function public.candidatar(vaga_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_prof  uuid;
  v_agora timestamptz;
  v       public.vaga%rowtype;
  v_pos   uuid;
  v_turno uuid;
  v_cand  uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if candidatar.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  -- RN13. A conta suspensa continua enxergando a lista, e é recusada aqui: a recusa
  -- tem motivo em `details` para a tela poder explicar em vez de só negar.
  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(422, 'inelegivel', 'perfil_suspenso');
  end if;

  select p.id into v_prof from public.profissional p where p.usuario_id = v_uid;
  if v_prof is null then
    -- Sem perfil não há função cadastrada, e sem função nenhuma vaga serve. O código é
    -- o mesmo da função incompatível de propósito: para o profissional, os dois casos
    -- terminam na mesma tela — a de completar o perfil.
    perform public.erro(422, 'inelegivel', 'funcao_incompativel');
  end if;

  perform privado.travar_candidatura(candidatar.vaga_id, v_prof);

  select * into v from public.vaga g where g.id = candidatar.vaga_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- O mesmo 404 das leituras, e pelo mesmo motivo: um 403 confirmaria que a vaga
  -- existe a quem bloqueou a casa ou a quem está do outro lado da demonstração.
  if privado.bloqueado_com_estabelecimento(v_uid, v.estabelecimento_id)
     or not exists (select 1 from public.usuario u
                     where u.id = v.publicado_por
                       and u.demonstracao = privado.conta_de_demonstracao()) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Idempotência pela chave natural (vaga, profissional). A rede cai depois do commit
  -- e o app reenvia: a segunda chamada devolve o mesmo turno em vez de tomar uma
  -- segunda posição. Vem **antes** da conferência de estado da vaga, senão o reenvio
  -- que chega depois de a vaga encher receberia `vaga_encerrada` em vez do próprio
  -- resultado.
  select p.id into v_pos
    from public.posicao p
   where p.vaga_id = candidatar.vaga_id
     and p.profissional_id = v_prof
     and p.estado in ('confirmada', 'cumprida');
  if found then
    select t.id into v_turno from public.turno t where t.posicao_id = v_pos;
    select c.id into v_cand from public.candidatura c
     where c.posicao_id = v_pos and c.profissional_id = v_prof;
    return jsonb_build_object(
      'estado',         'confirmada',
      'candidatura_id', v_cand,
      'posicao_id',     v_pos,
      'turno_id',       v_turno,
      'contato',        privado.contato_do_estabelecimento(candidatar.vaga_id));
  end if;

  v_agora := privado.agora();

  -- Dois 409 diferentes, e a diferença importa para a tela. `vaga_encerrada` é "esta
  -- vaga não existe mais"; `posicao_ja_preenchida` é "alguém chegou antes", que o
  -- produto trata como funcionamento normal — "que pena, foi rápido". Vaga
  -- **preenchida** é o segundo caso, e não o primeiro: ela fechou porque encheu.
  if v.estado = 'preenchida' then
    perform public.erro(409, 'posicao_ja_preenchida');
  end if;

  -- Início já passado conta como encerrada: candidatar-se a um turno que começou não é
  -- corrida perdida, é vaga que não existe mais.
  if v.estado <> 'publicada' or v.inicio_em <= v_agora then
    perform public.erro(409, 'vaga_encerrada');
  end if;

  -- RN05: a função é o primeiro critério de elegibilidade, e o único que o profissional
  -- controla. Distância e disponibilidade valem para a **notificação** (B07), não para
  -- a candidatura: quem viu a vaga e quer o turno pode aceitá-lo.
  if not exists (select 1 from public.profissional_funcao pf
                  where pf.profissional_id = v_prof and pf.funcao_id = v.funcao_id) then
    perform public.erro(422, 'inelegivel', 'funcao_incompativel');
  end if;

  -- ── RN19: a confirmação ─────────────────────────────────────────────────────
  --
  -- `SKIP LOCKED` é o que separa vinte candidatos disputando a mesma linha de vinte
  -- candidatos pegando linhas diferentes. Sem ele, dezenove esperariam o commit do
  -- primeiro para só então descobrir que perderam.
  begin
    update public.posicao p
       set estado = 'confirmada',
           profissional_id = v_prof,
           confirmado_em = v_agora
     where p.id = (select x.id from public.posicao x
                    where x.vaga_id = candidatar.vaga_id and x.estado = 'aberta'
                    order by x.id
                    for update skip locked
                    limit 1)
    returning p.id into v_pos;
  exception
    when exclusion_violation then
      -- RN21, pelo `EXCLUDE USING gist` de `posicao`. A recusa sai com o código do
      -- contrato em vez do 23P01 cru, que o app não sabe ler.
      perform public.erro(422, 'inelegivel', 'turno_sobreposto');
  end;

  if v_pos is null then
    perform public.erro(409, 'posicao_ja_preenchida');
  end if;

  insert into public.candidatura (posicao_id, profissional_id, estado)
  values (v_pos, v_prof, 'aceita')
  on conflict (posicao_id, profissional_id)
    do update set estado = 'aceita'
  returning id into v_cand;

  -- RN11: o valor viaja para o turno. Se a casa republicar com outro valor, o turno
  -- executado continua dizendo quanto foi combinado — registro que muda sozinho não
  -- vale nada.
  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_pos, v.valor_centavos)
  returning id into v_turno;

  -- A vaga fecha quando não sobra posição aberta. O `for update` na linha da vaga não é
  -- zelo: sem ele, as duas últimas confirmações simultâneas contam as posições abertas
  -- cada uma no próprio snapshot, nenhuma enxerga a escrita da outra, e a vaga fica
  -- `publicada` com zero posições livres. Medido na CI em 24/09, com vinte conexões —
  -- a máquina de desenvolvimento não reproduzia, porque o intervalo entre os dois
  -- commits era grande demais.
  --
  -- A ordem de aquisição é sempre posição e depois vaga, em todas as transações, o que
  -- mantém o caminho livre de impasse. O `skip locked` continua fazendo o seu trabalho
  -- antes disto: a serialização é só do fechamento, não da disputa.
  perform 1 from public.vaga g where g.id = candidatar.vaga_id for update;

  if not exists (select 1 from public.posicao p
                  where p.vaga_id = candidatar.vaga_id and p.estado = 'aberta') then
    update public.vaga g set estado = 'preenchida'
     where g.id = candidatar.vaga_id and g.estado = 'publicada';
  end if;

  -- RF10: a confirmação avisa o profissional e cada membro da casa. Só chega aqui a
  -- candidatura que de fato confirmou: o reenvio devolveu o turno lá em cima, antes de
  -- qualquer escrita, e por isso não enfileira aviso de novo.
  perform privado.notificar(v_uid, 'confirmacao', v_turno,
    jsonb_build_object('turno_id', v_turno, 'vaga_id', candidatar.vaga_id));
  perform privado.notificar_membros(v.estabelecimento_id, 'confirmacao', v_turno,
    jsonb_build_object('turno_id', v_turno, 'vaga_id', candidatar.vaga_id));

  return jsonb_build_object(
    'estado',         'confirmada',
    'candidatura_id', v_cand,
    'posicao_id',     v_pos,
    'turno_id',       v_turno,
    'contato',        privado.contato_do_estabelecimento(candidatar.vaga_id));
end $$;

-- fazer_checkin: `checkin` (geolocalizado) ou `checkin_manual_pendente` (RF13).
create or replace function public.fazer_checkin(
  turno_id      uuid,
  distancia_m   int         default null,
  registrado_em timestamptz default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid  uuid := (select auth.uid());
  v_pos  public.posicao%rowtype;
  v_t    public.turno%rowtype;
  v_tipo public.tipo_registro;
  v_ver  public.verificacao_turno;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if fazer_checkin.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  v_pos := privado.turno_do_profissional(fazer_checkin.turno_id);
  if v_pos.id is null then
    -- O turno não existe, ou não é de quem chama. Os dois casos respondem igual: um 403
    -- diria a alguém de fora que aquele turno existe.
    perform public.erro(404, 'nao_encontrado');
  end if;

  select * into v_t from public.turno t where t.id = fazer_checkin.turno_id;

  -- Reenviar devolve o registro já gravado. O check-in é uma das operações que mais
  -- chegam duplicadas: ele acontece na porta do estabelecimento, com a rede ruim.
  if v_t.checkin_em is not null then
    return jsonb_build_object(
      'turno_id',      v_t.id,
      'tipo',          v_t.checkin_tipo,
      'verificacao',   v_t.verificacao,
      'registrado_em', v_t.checkin_em,
      'distancia_m',   v_t.checkin_distancia_m);
  end if;

  perform privado.exigir_janela(fazer_checkin.registrado_em, v_pos.inicio_em, v_pos.fim_em);

  if fazer_checkin.distancia_m is not null and fazer_checkin.distancia_m < 0 then
    perform public.erro(422, 'campo_invalido', 'distancia_m');
  end if;

  -- RN22: quem decide o tipo é o servidor, a partir da distância. Deixar o app declarar
  -- "sou geolocalizado" seria deixar o app declarar a própria presença.
  if fazer_checkin.distancia_m is not null and fazer_checkin.distancia_m <= 200 then
    v_tipo := 'geolocalizado';
    v_ver  := 'verificado';
  else
    v_tipo := 'manual';
    v_ver  := 'pendente';
  end if;

  update public.turno t
     set checkin_em          = fazer_checkin.registrado_em,
         checkin_recebido_em = privado.agora(),
         checkin_tipo        = v_tipo,
         checkin_distancia_m = case when v_tipo = 'geolocalizado'
                                    then fazer_checkin.distancia_m else null end,
         verificacao         = v_ver
   where t.id = fazer_checkin.turno_id
  returning * into v_t;

  if v_ver = 'verificado' then
    perform privado.recalcular_comparecimento(v_pos.profissional_id);
  end if;

  -- RF13. Geolocalizado é presença verificada: a casa é avisada de que chegou. Manual
  -- fica pendente, e o aviso é o pedido para a casa confirmar (`confirmar_checkin_manual`).
  -- O reenvio devolveu o registro lá em cima, antes da escrita, e não passa por aqui.
  perform privado.notificar_membros(
    privado.estabelecimento_da_vaga(v_pos.vaga_id),
    case when v_ver = 'verificado' then 'checkin'
         else 'checkin_manual_pendente' end::public.tipo_notificacao,
    v_t.id,
    jsonb_build_object('turno_id', v_t.id, 'vaga_id', v_pos.vaga_id));

  return jsonb_build_object(
    'turno_id',      v_t.id,
    'tipo',          v_t.checkin_tipo,
    'verificacao',   v_t.verificacao,
    'registrado_em', v_t.checkin_em,
    'distancia_m',   v_t.checkin_distancia_m);
end $$;

-- cancelar_uma_posicao é o caminho de `cancelar_posicao` e de `cancelar_vaga`.
create or replace function privado.cancelar_uma_posicao(
  posicao uuid,
  autor   uuid,
  motivo  text,
  reabrir boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pos   public.posicao%rowtype;
  v_agora timestamptz := privado.agora();
  v_falta boolean := false;
  v_nova  uuid;
  v_eh_prof boolean;
begin
  select * into v_pos from public.posicao p where p.id = posicao;

  v_eh_prof := v_pos.profissional_id is not null
               and privado.usuario_do_profissional(v_pos.profissional_id) = autor;

  -- RN12. A falta é do profissional que desiste em cima da hora, e só dele: o
  -- contratante que cancela não gera falta para ninguém, e a posição que nunca foi
  -- confirmada não tem de quem ser falta.
  if v_eh_prof and v_pos.estado = 'confirmada'
     and v_pos.inicio_em - v_agora < interval '24 hours' then
    v_falta := true;
  end if;

  update public.posicao p
     set estado = 'cancelada',
         falta  = v_falta
   where p.id = posicao;

  -- O turno cancelado sai junto. Ele não é apagado: o registro do que foi combinado
  -- sobrevive ao cancelamento, e é o que a auditoria lê.
  update public.turno t
     set verificacao = 'nao_verificado'
   where t.posicao_id = posicao and t.verificacao = 'pendente';

  insert into public.ocorrencia (tipo, posicao_id, usuario_id, autor_id, motivo)
  values ('cancelamento', posicao,
          privado.usuario_do_profissional(v_pos.profissional_id), autor, motivo);

  -- Antes do início, a vaga ganha uma posição nova e o despacho sai de novo. Depois do
  -- início não há o que reabrir: o turno ficou descoberto, e quem precisa saber disso é
  -- o contratante.
  if reabrir and v_pos.inicio_em > v_agora then
    insert into public.posicao (vaga_id, inicio_em, fim_em)
    values (v_pos.vaga_id, v_pos.inicio_em, v_pos.fim_em)
    returning id into v_nova;

    -- A vaga estava `preenchida` e volta a ter posição aberta.
    update public.vaga g set estado = 'publicada'
     where g.id = v_pos.vaga_id and g.estado = 'preenchida';

    perform pgmq.send('despacho', jsonb_build_object(
      'vaga_id',        v_pos.vaga_id,
      'posicao_id',     v_nova,
      'motivo',         'reabertura',
      -- Quem cancelou não é notificado de novo da própria vaga. Receber a notificação
      -- da vaga que se acabou de largar é o tipo de detalhe que faz desinstalar o app.
      'excluir_conta',  autor));
  end if;

  if v_falta then
    perform privado.recalcular_comparecimento(v_pos.profissional_id);
  end if;

  -- Avisa a **outra parte**, e só ela: quem cancelou sabe. O profissional cancelou, a
  -- casa toda é avisada; a casa cancelou, o profissional é. `reaberta = false` é o turno
  -- descoberto — vaga inteira cancelada, ou início já passado —, que a casa precisa
  -- distinguir da posição que voltou para a fila.
  if v_eh_prof then
    perform privado.notificar_membros(
      privado.estabelecimento_da_vaga(v_pos.vaga_id), 'cancelamento', posicao,
      jsonb_build_object('posicao_id', posicao, 'vaga_id', v_pos.vaga_id,
                         'reaberta', v_nova is not null));
  elsif v_pos.profissional_id is not null then
    perform privado.notificar(privado.usuario_do_profissional(v_pos.profissional_id),
      'cancelamento', posicao,
      jsonb_build_object('posicao_id', posicao, 'vaga_id', v_pos.vaga_id,
                         'reaberta', v_nova is not null));
  end if;

  return jsonb_build_object(
    'posicao_id',      posicao,
    'falta',           v_falta,
    'reaberta',        v_nova is not null,
    'nova_posicao_id', v_nova);
end $$;

comment on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean) is
  'Desiste de uma posição com motivo (RF14, RN12). Quando é do profissional e a menos de 24 h do início, marca falta e recalcula a taxa. Se pedido e antes do início, reabre a posição criando outra e redisparando o despacho. Notifica a outra parte.';

revoke execute on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean)
  to service_role;

