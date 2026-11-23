-- fazer_checkin aceita os sinais do aparelho e devolve codigo_exigido e codigo_disponivel
-- (contrato 0.2.68, RegistroDeCheckin, SinaisDoCheckin e ResultadoRegistro; PR4 do plano).
-- Desenho: frila-docs, arquitetura/desenho-checkin-por-codigo-v1.2.md, seção 5 (proteção por risco).
--
-- Com a chave checkin_por_codigo ligada para a casa do turno e um sinal suspeito, a distância de
-- até 200 m não verifica pelo GPS: o check-in fica manual e pendente, codigo_exigido é gravado
-- (sem dizer qual sinal), e a casa recebe o checkin_manual_pendente de sempre. A casa atesta pelo
-- código ou pela confirmação manual (leitura 8, confirmada pelo JP).
--
-- O que não muda (critério 9 e leitura 4):
--   · sem sinais, como mandam o app 1.0 e o 1.1, o check-in segue igual, faixa de 150 a 200 m
--     inclusive;
--   · com a chave desligada para a casa, os sinais são ignorados e a resposta é a de hoje, sem os
--     dois campos novos (ausente vale false no contrato).
-- Os sinais nunca são gravados (regras da Bússola, 08/11): só codigo_exigido, em privado.checkin_codigo.
--
-- Fica FORA até o JP decidir: a política do servidor para exigir o código sem sinal (opção a do
-- parecer), o "sem sinais vira não verificado" (opção h) e a versão mínima 1.2.

select set_config('lock_timeout', '2s', true);

-- ── 1. Os sinais ──────────────────────────────────────────────────────────────

create function privado.sinais_validos(p_sinais jsonb) returns boolean
language sql immutable set search_path = '' as $$
  -- SinaisDoCheckin: os três campos, dois booleanos e a precisão inteira de 0 em diante, ou nula.
  -- Inteira é o valor, e não a grafia (JSON Schema, type integer): 20 e 20.0 valem; 4.7 não (#464).
  select jsonb_typeof(p_sinais) = 'object'
     and jsonb_typeof(p_sinais -> 'localizacao_simulada') = 'boolean'
     and jsonb_typeof(p_sinais -> 'salto_de_posicao') = 'boolean'
     and p_sinais ? 'precisao_m'
     and (jsonb_typeof(p_sinais -> 'precisao_m') = 'null'
          or (jsonb_typeof(p_sinais -> 'precisao_m') = 'number'
              and (p_sinais ->> 'precisao_m')::numeric between 0 and 2147483647
              and (p_sinais ->> 'precisao_m')::numeric = trunc((p_sinais ->> 'precisao_m')::numeric)))
$$;
comment on function privado.sinais_validos(jsonb) is
  'Se os sinais do check-in seguem SinaisDoCheckin (0.2.68): localizacao_simulada e salto_de_posicao booleanos, precisao_m inteiro de 0 em diante ou nulo.';
revoke all on function privado.sinais_validos(jsonb) from public, anon, authenticated;
grant execute on function privado.sinais_validos(jsonb) to service_role;

-- PENDENTE do JP (D5, 08/11): com precisao_m nulo (o aparelho não informa), se a precisão conta como
-- ruim. Provisório até a decisão: nulo não conta. A decisão muda só esta função.
create function privado.precisao_ruim(p_precisao_m integer) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_precisao_m is not null
     and p_precisao_m >= coalesce((select r.precisao_ruim_m from privado.regra_checkin_codigo r), 100)
$$;
comment on function privado.precisao_ruim(integer) is
  'Precisão ruim: a imprecisão informada pelo aparelho a partir de regra_checkin_codigo.precisao_ruim_m (100 m, resposta do JP à leitura 5; sem a regra, 100). PENDENTE do JP (D5): o nulo, provisoriamente, não conta.';
revoke all on function privado.precisao_ruim(integer) from public, anon, authenticated;
grant execute on function privado.precisao_ruim(integer) to service_role;

-- O que pesa (seção 6 do texto aprovado): localização simulada, salto de posição, precisão ruim ou
-- a faixa de 150 a 200 m, que o servidor sabe pela distância. A faixa é decisão fechada, e por isso
-- constante aqui, e não na regra.
create function privado.sinal_suspeito(p_sinais jsonb, p_distancia_m integer) returns boolean
language sql stable security definer set search_path = '' as $$
  select (p_sinais ->> 'localizacao_simulada')::boolean
      or (p_sinais ->> 'salto_de_posicao')::boolean
      -- Por numeric: o jsonb guarda 20.0 com a escala, e o ::integer direto daria 22P02 cru (#464).
      or privado.precisao_ruim(((p_sinais ->> 'precisao_m')::numeric)::integer)
      or p_distancia_m between 150 and 200
$$;
comment on function privado.sinal_suspeito(jsonb, integer) is
  'A proteção por risco do check-in por código (0.2.68): localização simulada, salto de posição, precisão ruim ou distância de 150 a 200 m. Recebe sinais já validados. Não grava nada.';
revoke all on function privado.sinal_suspeito(jsonb, integer) from public, anon, authenticated;
grant execute on function privado.sinal_suspeito(jsonb, integer) to service_role;

-- ── 2. A resposta ─────────────────────────────────────────────────────────────
-- ResultadoRegistro. Os dois campos novos só saem com a chave ligada para a casa: desligada, a
-- resposta é a de hoje, e o app publicado não vê nada novo.

create function privado.resposta_do_checkin(p_turno public.turno, p_codigo boolean) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
           'turno_id',      p_turno.id,
           'tipo',          p_turno.checkin_tipo,
           'verificacao',   p_turno.verificacao,
           'registrado_em', p_turno.checkin_em,
           'distancia_m',   p_turno.checkin_distancia_m)
      || case when p_codigo then jsonb_build_object(
           'codigo_exigido',    coalesce((select c.codigo_exigido from privado.checkin_codigo c
                                           where c.turno_id = p_turno.id), false),
           'codigo_disponivel', p_turno.verificacao = 'pendente'
                                and privado.estado_do_codigo(p_turno.id) <> 'encerrado')
         else '{}'::jsonb end
$$;
comment on function privado.resposta_do_checkin(public.turno, boolean) is
  'ResultadoRegistro do check-in. Com a chave do código ligada para a casa, acrescenta codigo_exigido (gravado, sem o sinal) e codigo_disponivel (presença pendente e caminho do código não encerrado, no momento).';
revoke all on function privado.resposta_do_checkin(public.turno, boolean) from public, anon, authenticated;
grant execute on function privado.resposta_do_checkin(public.turno, boolean) to service_role;

-- ── 3. fazer_checkin com sinais ───────────────────────────────────────────────
-- A assinatura muda, então é drop e create: create or replace com outra lista de argumentos
-- criaria uma sobrecarga, e a PostgREST responderia PGRST203. O app 1.0, o 1.1 e o Android seguem
-- chamando com três argumentos; sinais tem default null. O corpo é o da 20260925233000, com só
-- as linhas da chave, dos sinais, do codigo_exigido e da resposta acrescentadas.

drop function public.fazer_checkin(uuid, integer, timestamptz);

create function public.fazer_checkin(
  turno_id      uuid,
  distancia_m   int         default null,
  registrado_em timestamptz default null,
  sinais        jsonb       default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid     uuid := (select auth.uid());
  v_pos     public.posicao%rowtype;
  v_t       public.turno%rowtype;
  v_tipo    public.tipo_registro;
  v_ver     public.verificacao_turno;
  v_codigo  boolean;           -- a chave do código vale para a casa do turno
  v_exigido boolean := false;  -- sinal suspeito: a casa precisa atestar
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
  v_codigo := privado.recurso_ligado_para('checkin_por_codigo',
                                          privado.estabelecimento_da_vaga(v_pos.vaga_id));

  -- Reenviar devolve o registro já gravado. O check-in é uma das operações que mais
  -- chegam duplicadas: ele acontece na porta do estabelecimento, com a rede ruim.
  -- codigo_exigido é o gravado; codigo_disponivel, o do momento.
  if v_t.checkin_em is not null then
    return privado.resposta_do_checkin(v_t, v_codigo);
  end if;

  perform privado.exigir_janela(fazer_checkin.registrado_em, v_pos.inicio_em, v_pos.fim_em);

  if fazer_checkin.distancia_m is not null and fazer_checkin.distancia_m < 0 then
    perform public.erro(422, 'campo_invalido', 'distancia_m');
  end if;

  -- Com a chave desligada, os sinais são ignorados, inclusive o formato: o check-in do app 1.2
  -- numa casa fora do piloto não falha por eles.
  if v_codigo and fazer_checkin.sinais is not null
     and not privado.sinais_validos(fazer_checkin.sinais) then
    perform public.erro(422, 'campo_invalido', 'sinais');
  end if;

  -- RN22: quem decide o tipo é o servidor, a partir da distância. Deixar o app declarar
  -- "sou geolocalizado" seria deixar o app declarar a própria presença. Desde a 0.2.68, com a
  -- chave ligada e um sinal suspeito, a distância de até 200 m não basta.
  if fazer_checkin.distancia_m is not null and fazer_checkin.distancia_m <= 200 then
    v_exigido := v_codigo and fazer_checkin.sinais is not null
                 and privado.sinal_suspeito(fazer_checkin.sinais, fazer_checkin.distancia_m);
  end if;

  if fazer_checkin.distancia_m is not null and fazer_checkin.distancia_m <= 200 and not v_exigido then
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

  -- Só o "sim", nunca o sinal que pesou (regras da Bússola, 08/11).
  if v_exigido then
    insert into privado.checkin_codigo (turno_id, codigo_exigido) values (v_t.id, true)
      on conflict (turno_id) do update set codigo_exigido = true;
  end if;

  if v_ver = 'verificado' then
    perform privado.recalcular_comparecimento(v_pos.profissional_id);
  end if;

  -- RF13. Geolocalizado é presença verificada: a casa é avisada de que chegou. Manual
  -- fica pendente, e o aviso é o pedido para a casa confirmar (`confirmar_checkin_manual`),
  -- ou, no app 1.2, para mostrar o código. O reenvio devolveu o registro lá em cima, antes da
  -- escrita, e não passa por aqui.
  perform privado.notificar_membros(
    privado.estabelecimento_da_vaga(v_pos.vaga_id),
    case when v_ver = 'verificado' then 'checkin'
         else 'checkin_manual_pendente' end::public.tipo_notificacao,
    v_t.id,
    jsonb_build_object('turno_id', v_t.id, 'vaga_id', v_pos.vaga_id));

  return privado.resposta_do_checkin(v_t, v_codigo);
end $$;

comment on function public.fazer_checkin(uuid, int, timestamptz, jsonb) is
  'Check-in do profissional (RF13, RN22). Até 200 m é geolocalizado e verifica a presença na hora; acima disso ou sem localização vira manual e fica pendente. Desde a 0.2.68, com a chave checkin_por_codigo ligada para a casa e um sinal suspeito em sinais, a distância de até 200 m não verifica: fica manual e pendente, com codigo_exigido, e a casa atesta pelo código ou pela confirmação manual. Sem sinais, ou com a chave desligada, nada muda. Os sinais não são gravados. Reenviar devolve o registro já gravado.';

revoke execute on function public.fazer_checkin(uuid, int, timestamptz, jsonb) from public, anon;
grant  execute on function public.fazer_checkin(uuid, int, timestamptz, jsonb) to authenticated;
