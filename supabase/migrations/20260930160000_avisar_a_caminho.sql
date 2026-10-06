-- "Estou a caminho" (cartão h53CJVP7, US14 cenário 1, RF12, contrato 0.2.25).
--
-- O profissional confirmado avisa, pela notificação de 3 h ou pelo botão em Meu turno,
-- que saiu para o turno. A casa vê o aviso no acompanhamento (`painel_estabelecimento`)
-- e o profissional o vê de volta em `meus_turnos`.
--
-- ── O que o aviso NÃO é ───────────────────────────────────────────────────────
--
-- Não é presença e não é taxa. Presença continua sendo o check-in, com a distância
-- medida no toque (RN22); a taxa continua sendo a de comparecimento, que lê
-- `turno.verificacao` e `posicao.falta`. O aviso escreve só `a_caminho_em`, que nenhum
-- gatilho de verificação nem a trilha de auditoria olham: a trilha de `turno` registra
-- transição de `verificacao`, e esta coluna não é estado do ciclo.
--
-- Também não guarda onde o profissional está. É um instante, e só: uma coordenada aqui
-- seria o rastreamento contínuo entrando pela porta que o check-in fechou.
--
-- ── A janela ──────────────────────────────────────────────────────────────────
--
-- De 3 h antes até 15 min depois do início da posição, com as duas bordas dentro. As
-- 3 h são o lembrete que carrega a ação; os 15 min são a tolerância de atraso (D06), a
-- partir da qual o painel já mostra `em_atraso` e o aviso deixa de ser notícia.
--
-- ── Idempotência ──────────────────────────────────────────────────────────────
--
-- A chave natural é o turno. O aviso já gravado volta como está, antes da conferência
-- da janela: um reenvio que a rede atrasou para depois dos 15 min é a mesma chamada, e
-- recusar o que já foi aceito faria o app mostrar erro para uma ação que deu certo. O
-- `coalesce` na escrita cobre duas chamadas simultâneas: a segunda espera a trava da
-- linha e encontra o instante da primeira.

-- ── 1. A coluna ───────────────────────────────────────────────────────────────

alter table public.turno add column a_caminho_em timestamptz;

comment on column public.turno.a_caminho_em is
  'Instante, pelo relógio do servidor, em que o profissional avisou que está a caminho (US14, RF12). Sinal operacional para a casa: não é presença nem entra na taxa de comparecimento. Não guarda localização.';

-- ── 2. A RPC ──────────────────────────────────────────────────────────────────

create or replace function public.avisar_a_caminho(turno_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid     uuid := (select auth.uid());
  v_inicio  timestamptz;
  v_aviso   timestamptz;
  v_agora   timestamptz;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if avisar_a_caminho.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  -- Só o profissional **confirmado**. A posição cancelada guarda o profissional (RN12),
  -- e um aviso ali diria à casa que vem alguém que não vem. Turno inexistente, de outro
  -- ou de posição que não está confirmada respondem igual, como o contrato pede.
  select p.inicio_em, t.a_caminho_em
    into v_inicio, v_aviso
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = avisar_a_caminho.turno_id
     and p.estado = 'confirmada'
     and privado.usuario_do_profissional(p.profissional_id) = v_uid
     for update of t;

  if not found then
    perform public.erro(403, 'sem_permissao');
  end if;

  if v_aviso is null then
    v_agora := privado.agora();

    if v_agora < v_inicio - interval '3 hours'
       or v_agora > v_inicio + interval '15 minutes' then
      perform public.erro(422, 'a_caminho_fora_da_janela');
    end if;

    update public.turno t
       set a_caminho_em = coalesce(t.a_caminho_em, v_agora)
     where t.id = avisar_a_caminho.turno_id
    returning t.a_caminho_em into v_aviso;
  end if;

  return jsonb_build_object(
    'turno_id',     avisar_a_caminho.turno_id,
    'a_caminho_em', v_aviso);
end $$;

comment on function public.avisar_a_caminho(uuid) is
  'O profissional confirmado avisa que está a caminho do turno (US14, RF12), de 3 h antes até 15 min depois do início. Idempotente pelo turno. Não muda presença nem taxa.';

revoke execute on function public.avisar_a_caminho(uuid) from public, anon;
grant  execute on function public.avisar_a_caminho(uuid) to authenticated;

-- ── 3. painel_estabelecimento: a_caminho_em em PosicaoNoPainel ─────────────────
--
-- Corpo da 20260929230000_operacao_equipe_frila, com a chave nova na posição. Nulo na
-- posição aberta, que não tem turno, e na confirmada ainda sem aviso.

create or replace function public.painel_estabelecimento(
  estabelecimento_id uuid,
  de                 timestamptz,
  ate                timestamptz
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_estab     uuid := painel_estabelecimento.estabelecimento_id;
  v_de        timestamptz := painel_estabelecimento.de;
  v_ate       timestamptz := painel_estabelecimento.ate;
  v_agora     timestamptz;
  v_vagas     jsonb;
  v_pendentes jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if v_estab is null or not privado.eh_membro(v_estab) then
    perform public.erro(403, 'sem_permissao');
  end if;

  if v_de is null then
    perform public.erro(422, 'campo_obrigatorio', 'de');
  end if;
  if v_ate is null then
    perform public.erro(422, 'campo_obrigatorio', 'ate');
  end if;

  v_agora := privado.agora();

  select coalesce(jsonb_agg(jsonb_build_object(
           'vaga', jsonb_build_object(
              'id',                    v.id,
              'funcao',                f.nome,
              'local',                 v.local,
              'regiao_administrativa', v.regiao_administrativa,
              'inicio_em',             v.inicio_em,
              'fim_em',                v.fim_em,
              'valor_centavos',        v.valor_centavos),
           'modo',   v.modo,
           'estado', v.estado,
           -- A casa vê "oculta pela Equipe"; o estado segue o do ciclo de vida (0.2.23).
           'oculta', privado.vaga_oculta(v.id),
           'alerta_vaga_vazia',
              v.estado = 'publicada'
              and v_agora >= v.inicio_em - v.alerta_antecedencia
              and v_agora <  v.inicio_em
              and exists (select 1 from public.posicao pa
                           where pa.vaga_id = v.id and pa.estado = 'aberta'),
           'candidatos_pendentes',
              (select count(distinct c.profissional_id)
                 from public.candidatura c
                 join public.posicao pc on pc.id = c.posicao_id
                where pc.vaga_id = v.id
                  and c.estado = 'pendente'
                  and not privado.bloqueado_com_estabelecimento(
                            privado.usuario_do_profissional(c.profissional_id), v_estab)),
           'posicoes',
              (select coalesce(jsonb_agg(jsonb_build_object(
                        'id',     p.id,
                        'estado', p.estado,
                        'profissional',
                           case when p.profissional_id is null then null
                                else privado.perfil_publico_profissional(p.profissional_id) end,
                        'turno_id',    t.id,
                        'verificacao', t.verificacao,
                        'em_atraso',
                           p.estado = 'confirmada'
                           and t.checkin_em is null
                           and v_agora >= p.inicio_em + interval '15 minutes'
                           and v_agora <  p.fim_em,
                        'a_caminho_em', t.a_caminho_em)
                      order by p.id), '[]'::jsonb)
                 from public.posicao p
                 left join public.turno t on t.posicao_id = p.id
                where p.vaga_id = v.id))
         order by v.inicio_em, v.id), '[]'::jsonb)
    into v_vagas
    from public.vaga v
    join public.funcao f on f.id = v.funcao_id
   where v.estabelecimento_id = v_estab
     and v.inicio_em < v_ate
     and v.fim_em    > v_de;

  select coalesce(jsonb_agg(t.id order by t.checkin_em, t.id), '[]'::jsonb)
    into v_pendentes
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v    on v.id = p.vaga_id
   where v.estabelecimento_id = v_estab
     and v.inicio_em < v_ate
     and v.fim_em    > v_de
     and p.estado in ('confirmada', 'cumprida')
     and t.checkin_tipo = 'manual'
     and t.checkin_confirmado_em is null;

  return jsonb_build_object(
    'estabelecimento_id', v_estab,
    'vagas',              v_vagas,
    'checkins_pendentes', v_pendentes);
end $$;

comment on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) is
  'Vagas, candidatos, contratados, check-ins e turnos do estabelecimento (RF20, RF13, UC07). Expõe regiao_administrativa em VagaResumo e a_caminho_em em PosicaoNoPainel (US14).';

revoke execute on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) from public, anon;
grant  execute on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) to authenticated;

-- ── 4. privado.turno_em_json: a_caminho_em no Turno ───────────────────────────
--
-- Corpo da 20260928230000_regiao_administrativa, com a chave nova. É o que
-- `meus_turnos` devolve, para os dois lados.

create or replace function privado.turno_em_json(turno uuid, autor uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id',         t.id,
    'posicao_id', t.posicao_id,
    'vaga', jsonb_build_object(
      'id',                    v.id,
      'funcao',                f.nome,
      'local',                 v.local,
      'regiao_administrativa', v.regiao_administrativa,
      'inicio_em',             v.inicio_em,
      'fim_em',                v.fim_em,
      'valor_centavos',        v.valor_centavos),
    'contraparte', case
      when privado.usuario_do_profissional(p.profissional_id) = autor
        then privado.estabelecimento_publico(v.estabelecimento_id)
        else privado.perfil_publico_profissional(p.profissional_id) end,
    'contato_visivel_ate',     p.fim_em + interval '7 days',
    'a_caminho_em',            t.a_caminho_em,
    'checkin_em',              t.checkin_em,
    'checkin_tipo',            t.checkin_tipo,
    'checkin_distancia_m',     t.checkin_distancia_m,
    'checkin_confirmado_em',   t.checkin_confirmado_em,
    'checkout_em',             t.checkout_em,
    'checkout_distancia_m',    t.checkout_distancia_m,
    'verificacao',             t.verificacao,
    'valor_acordado_centavos', t.valor_acordado_centavos,
    'pode_avaliar',            privado.pode_avaliar(t.id, autor))
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v    on v.id = p.vaga_id
    join public.funcao f  on f.id = v.funcao_id
   where t.id = turno
$$;

comment on function privado.turno_em_json(uuid, uuid) is
  'Turno no schema do contrato (RF09, RF10). Expõe regiao_administrativa no VagaResumo e a_caminho_em (US14).';

revoke execute on function privado.turno_em_json(uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.turno_em_json(uuid, uuid) to service_role;
