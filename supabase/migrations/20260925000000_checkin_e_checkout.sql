-- `fazer_checkin`, `fazer_checkout` e `confirmar_checkin_manual`: a prova de presença.
--
-- O app lê a localização **só no toque**, calcula a distância no aparelho e envia só
-- ela — nunca a coordenada (RN22, minimização da LGPD). O banco não tem onde guardar
-- coordenada de profissional, e é assim que a decisão se sustenta sozinha.
--
-- Três desfechos, e o de baixo é o que o produto mais teme:
--
--   até 200 m          `geolocalizado`, presença `verificado` na hora
--   acima, ou sem GPS  `manual`, presença `pendente` até o contratante confirmar
--   ninguém confirma   o turno aconteceu e não tem prova: `nao_verificado`
--
-- O terceiro não conta a favor nem contra na taxa de comparecimento. Punir quem ficou
-- sem sinal seria punir o aparelho, não o comportamento.

-- ── A hora do toque e a hora da chegada ───────────────────────────────────────
--
-- `checkin_em` é a hora do **toque**; `checkin_recebido_em`, a hora em que o servidor
-- recebeu. O check-in feito sem rede entra na fila do app e sai depois: sem as duas
-- colunas, um turno registrado às 18:00 e sincronizado às 23:00 ficaria indistinguível
-- de um registrado às 23:00 — e é a diferença entre presença e alegação de presença.
alter table public.turno
  add column if not exists checkin_recebido_em  timestamptz,
  add column if not exists checkout_recebido_em timestamptz;

comment on column public.turno.checkin_recebido_em is
  'Hora em que o servidor recebeu o check-in. `checkin_em` é a hora do toque: o registro feito sem rede sai da fila do app depois, e a diferença entre as duas é o que permite auditar.';
comment on column public.turno.checkout_recebido_em is
  'Hora em que o servidor recebeu o check-out. Ver checkin_recebido_em.';

-- ── A taxa de comparecimento ──────────────────────────────────────────────────
--
-- Numerador: turnos com presença verificada. Denominador: esses mais as faltas. O turno
-- `nao_verificado` fica fora dos dois — ele não prova presença nem prova ausência.
--
-- Recalculada inteira em vez de incrementada: um contador que só sobe diverge em
-- silêncio na primeira correção manual, e este número aparece no perfil de quem procura
-- trabalho.
create or replace function privado.recalcular_comparecimento(prof uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_verificados int;
  v_faltas      int;
begin
  select count(*) into v_verificados
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where p.profissional_id = prof and t.verificacao = 'verificado';

  select count(*) into v_faltas
    from public.posicao p
   where p.profissional_id = prof and p.falta;

  update public.profissional
     set turnos_realizados = v_verificados,
         -- Nula enquanto não há denominador: RF16 exige que perfil sem histórico
         -- apareça como sem histórico, e não como nota zero.
         taxa_comparecimento = case when v_verificados + v_faltas = 0 then null
                                    else round(v_verificados::numeric
                                               / (v_verificados + v_faltas), 3) end
   where id = prof;
end $$;

comment on function privado.recalcular_comparecimento(uuid) is
  'Recalcula turnos_realizados e taxa_comparecimento a partir dos turnos verificados e das faltas (RN22). Turno não verificado fica fora do numerador e do denominador.';

-- ── O turno do chamador, e nada além ──────────────────────────────────────────

create or replace function privado.turno_do_profissional(turno uuid)
returns public.posicao
language sql
stable
security definer
set search_path = ''
as $$
  select p.* from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = turno
     and privado.usuario_do_profissional(p.profissional_id) = (select auth.uid())
$$;

-- ── A janela do registro ──────────────────────────────────────────────────────
--
-- De 60 minutos antes do início até o fim previsto. Antes disso é engano ou tentativa;
-- depois, o turno já acabou e o registro não é mais presença.
create or replace function privado.exigir_janela(registrado_em timestamptz,
                                                 inicio timestamptz, fim timestamptz)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if registrado_em is null then
    perform public.erro(422, 'campo_obrigatorio', 'registrado_em');
  end if;

  -- Dois minutos de folga para o relógio do aparelho, que adianta. Mais do que isso é
  -- registro no futuro, e registro no futuro é o caminho mais curto para fabricar
  -- presença.
  if registrado_em > privado.agora() + interval '2 minutes' then
    perform public.erro(422, 'registro_no_futuro');
  end if;

  if registrado_em < inicio - interval '60 minutes' or registrado_em > fim then
    perform public.erro(422, 'fora_da_janela');
  end if;
end $$;

comment on function privado.exigir_janela(timestamptz, timestamptz, timestamptz) is
  'A janela do registro de presença: de 60 min antes do início até o fim previsto, com 2 min de folga para o relógio do aparelho adiantado.';

-- ── fazer_checkin ─────────────────────────────────────────────────────────────

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

  return jsonb_build_object(
    'turno_id',      v_t.id,
    'tipo',          v_t.checkin_tipo,
    'verificacao',   v_t.verificacao,
    'registrado_em', v_t.checkin_em,
    'distancia_m',   v_t.checkin_distancia_m);
end $$;

comment on function public.fazer_checkin(uuid, int, timestamptz) is
  'Check-in do profissional (RF13, RN22). Até 200 m é geolocalizado e verifica a presença na hora; acima disso ou sem localização vira manual e fica pendente. Reenviar devolve o registro já gravado.';

-- ── fazer_checkout ────────────────────────────────────────────────────────────
--
-- A distância do check-out **não** tem teto, ao contrário da do check-in. Um teto aqui
-- recusaria a escrita de quem se afastou do local e tenta encerrar, e o turno ficaria
-- sem check-out em vez de com um check-out distante — pior para os dois lados e para a
-- auditoria. A distância entra como medida; quem classifica é a regra.

create or replace function public.fazer_checkout(
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
  v_uid uuid := (select auth.uid());
  v_pos public.posicao%rowtype;
  v_t   public.turno%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if fazer_checkout.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  v_pos := privado.turno_do_profissional(fazer_checkout.turno_id);
  if v_pos.id is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  select * into v_t from public.turno t where t.id = fazer_checkout.turno_id;

  if v_t.checkout_em is not null then
    return jsonb_build_object(
      'turno_id',      v_t.id,
      'tipo',          coalesce(v_t.checkin_tipo, 'manual'),
      'verificacao',   v_t.verificacao,
      'registrado_em', v_t.checkout_em,
      'distancia_m',   v_t.checkout_distancia_m);
  end if;

  -- Encerrar um turno que nunca começou não é registro de saída, é engano. O código
  -- diz qual é o passo que falta, para a tela poder levar a pessoa até ele.
  if v_t.checkin_em is null then
    perform public.erro(409, 'checkin_pendente');
  end if;

  perform privado.exigir_janela(fazer_checkout.registrado_em,
                                v_pos.inicio_em, v_pos.fim_em);

  if fazer_checkout.distancia_m is not null and fazer_checkout.distancia_m < 0 then
    perform public.erro(422, 'campo_invalido', 'distancia_m');
  end if;

  update public.turno t
     set checkout_em          = fazer_checkout.registrado_em,
         checkout_recebido_em = privado.agora(),
         checkout_distancia_m = fazer_checkout.distancia_m
   where t.id = fazer_checkout.turno_id
  returning * into v_t;

  return jsonb_build_object(
    'turno_id',      v_t.id,
    'tipo',          v_t.checkin_tipo,
    'verificacao',   v_t.verificacao,
    'registrado_em', v_t.checkout_em,
    'distancia_m',   v_t.checkout_distancia_m);
end $$;

comment on function public.fazer_checkout(uuid, int, timestamptz) is
  'Check-out do profissional (RF13, RN22). A distância não tem teto: recusar a escrita de quem se afastou deixaria o turno sem check-out em vez de com um check-out distante.';

-- ── confirmar_checkin_manual ──────────────────────────────────────────────────
--
-- Um toque de quem opera a casa, e é só então que o check-in manual conta como
-- presença. É a porta que faz o manual não ser auto-declaração.

create or replace function public.confirmar_checkin_manual(turno_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
  v_pos public.posicao%rowtype;
  v_t   public.turno%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if confirmar_checkin_manual.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  select p.* into v_pos
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = confirmar_checkin_manual.turno_id;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- RF20: quem confirma é a casa. O profissional que tentasse confirmar o próprio
  -- check-in manual estaria declarando a própria presença, que é exatamente o que o
  -- manual existe para evitar. Aqui é 403, e não 404: ele é parte do turno e sabe que
  -- ele existe — esconder não protegeria nada e confundiria a tela.
  if not privado.eh_membro(privado.estabelecimento_da_vaga(v_pos.vaga_id)) then
    perform public.erro(403, 'sem_permissao');
  end if;

  select * into v_t from public.turno t where t.id = confirmar_checkin_manual.turno_id;

  if v_t.checkin_em is null then
    perform public.erro(409, 'checkin_pendente');
  end if;

  if v_t.checkin_tipo <> 'manual' then
    -- Check-in geolocalizado já nasceu verificado: não há o que confirmar.
    perform public.erro(409, 'checkin_ja_confirmado');
  end if;

  if v_t.checkin_confirmado_em is not null then
    return jsonb_build_object(
      'turno_id',      v_t.id,
      'tipo',          v_t.checkin_tipo,
      'verificacao',   v_t.verificacao,
      'registrado_em', v_t.checkin_em,
      'distancia_m',   v_t.checkin_distancia_m);
  end if;

  update public.turno t
     set checkin_confirmado_em = privado.agora(),
         verificacao           = 'verificado'
   where t.id = confirmar_checkin_manual.turno_id
  returning * into v_t;

  perform privado.recalcular_comparecimento(v_pos.profissional_id);

  return jsonb_build_object(
    'turno_id',      v_t.id,
    'tipo',          v_t.checkin_tipo,
    'verificacao',   v_t.verificacao,
    'registrado_em', v_t.checkin_em,
    'distancia_m',   v_t.checkin_distancia_m);
end $$;

comment on function public.confirmar_checkin_manual(uuid) is
  'A casa confirma o check-in manual, e só então ele conta como presença (RF20, RN22). O profissional recebe 403: confirmar o próprio check-in seria declarar a própria presença.';

revoke execute on function public.fazer_checkin(uuid, int, timestamptz) from public, anon;
revoke execute on function public.fazer_checkout(uuid, int, timestamptz) from public, anon;
revoke execute on function public.confirmar_checkin_manual(uuid) from public, anon;
grant execute on function public.fazer_checkin(uuid, int, timestamptz) to authenticated;
grant execute on function public.fazer_checkout(uuid, int, timestamptz) to authenticated;
grant execute on function public.confirmar_checkin_manual(uuid) to authenticated;
