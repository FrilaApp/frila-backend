-- Avaliação binária e perfil público com denominador (RF15, RF16, RN07, RN08).
--
-- `avaliar` é a escrita; `perfil_publico` é a leitura que a outra parte faz antes de
-- confirmar ou de aceitar. A regra de quando a avaliação abre mora em dois lugares de
-- propósito: a RPC a confere para devolver o código do contrato, e o gatilho de
-- `avaliacao` a confere de novo para que nenhum caminho de escrita escape.
--
-- O que já existia e continua valendo, sem cópia aqui:
--   `privado.agora()` no gatilho de RN07              (20260924220000_meus_turnos)
--   `privado.recalcular_comparecimento`, que mantém   (20260925000000_checkin_e_checkout,
--     `turnos_realizados` e `taxa_comparecimento`      chamada também pelos cancelamentos)
--   `privado.estabelecimento_publico`                 (20260924180000_vagas_abertas_e_detalhe)
--
-- O que muda:
--   1. o gatilho de RN07 confere também que autor e alvo são as duas partes do turno;
--   2. um voto por lado em cada turno: dois membros do mesmo estabelecimento não somam
--      duas avaliações sobre o mesmo turno do profissional — e `pode_avaliar` passa a
--      perguntar "sem avaliação deste lado", como o contrato diz em `Turno.pode_avaliar`;
--   3. positivas e total da parte avaliada somam num gatilho AFTER INSERT, com
--      `x = x + 1`, sem ler-e-escrever: duas avaliações simultâneas não perdem incremento;
--   4. conta anonimizada aparece no perfil público como "Conta encerrada" (RF25).

-- ── RN07 no gatilho: as duas partes, pelo relógio do produto ──────────────────

create or replace function privado.avaliacao_permitida()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fim         timestamptz;
  v_verificacao public.verificacao_turno;
  v_prof        uuid;
  v_prof_conta  uuid;
  v_estab       uuid;
begin
  select p.fim_em, t.verificacao, p.profissional_id, pr.usuario_id, v.estabelecimento_id
    into v_fim, v_verificacao, v_prof, v_prof_conta, v_estab
    from public.turno t
    join public.posicao p   on p.id = t.posicao_id
    join public.vaga v      on v.id = p.vaga_id
    left join public.profissional pr on pr.id = p.profissional_id
   where t.id = new.turno_id;

  if v_fim is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- As duas partes, e só elas: o profissional avalia o estabelecimento, um membro do
  -- estabelecimento avalia o profissional. A RPC calcula o alvo; aqui é a trava para
  -- quem escrever direto na tabela. O tipo do alvo fora dos dois conhecidos é recusado
  -- pela CHECK `avaliacao_alvo_tipo_check`, e é ela que tem de responder por isso: se o
  -- gatilho o recusasse antes, a CHECK viraria enfeite que nenhum teste mede.
  if new.alvo_tipo in ('profissional', 'estabelecimento') and not (
       (new.alvo_tipo = 'estabelecimento' and new.alvo_id = v_estab
          and new.autor_id = v_prof_conta)
    or (new.alvo_tipo = 'profissional' and new.alvo_id = v_prof
          and exists (select 1 from public.membro_estabelecimento m
                       where m.estabelecimento_id = v_estab
                         and m.usuario_id = new.autor_id))
  ) then
    raise exception 'autor e alvo da avaliação têm de ser as duas partes do turno (RN07)'
      using errcode = 'check_violation';
  end if;

  if privado.agora() < v_fim then
    perform public.erro(422, 'avaliacao_indisponivel', 'antes_do_fim');
  end if;

  if v_verificacao is distinct from 'verificado' then
    perform public.erro(422, 'avaliacao_indisponivel', 'sem_presenca_verificada');
  end if;

  return new;
end $$;

-- ── Um voto por lado ───────────────────────────────────────────────────────────
--
-- `unique (turno_id, autor_id)` impede o mesmo autor de votar duas vezes, mas o lado do
-- estabelecimento tem vários autores possíveis — o administrador e cada operador. Sem
-- esta chave, o turno de uma noite viraria "3 de 3" com três pessoas do mesmo bar, e o
-- denominador de RN08 deixaria de contar turnos.
alter table public.avaliacao
  add constraint um_voto_por_lado unique (turno_id, alvo_tipo);

-- `pode_avaliar` acompanha: o contrato (`Turno.pode_avaliar`) diz "sem avaliação deste
-- lado ainda". Com a pergunta por autor, a operadora veria o botão depois de o
-- administrador já ter avaliado, e o toque devolveria a avaliação dele.
create or replace function privado.pode_avaliar(turno uuid, autor uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select t.verificacao = 'verificado'
     and privado.agora() >= p.fim_em
     and not exists (
       select 1 from public.avaliacao a
        where a.turno_id = t.id
          and a.alvo_tipo = case when pr.usuario_id = autor then 'estabelecimento'
                                 else 'profissional' end)
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    left join public.profissional pr on pr.id = p.profissional_id
   where t.id = turno
$$;

comment on function privado.pode_avaliar(uuid, uuid) is
  'As três condições de RN07 — depois do fim previsto, com presença verificada e sem avaliação deste lado do turno. A tela decide o botão por aqui; quem recusa de fato é o gatilho.';

-- ── Positivas e total da parte avaliada ────────────────────────────────────────
--
-- Incremento, e não recálculo como na taxa de comparecimento: aqui a avaliação é
-- imutável (não há update nem delete por RPC), então o contador só pode subir, e
-- `x = x + 1` é o que não perde soma quando dois lados avaliam no mesmo instante.

create or replace function privado.somar_avaliacao()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.alvo_tipo = 'profissional' then
    update public.profissional
       set aval_total     = aval_total + 1,
           aval_positivas = aval_positivas + case when new.resposta then 1 else 0 end
     where id = new.alvo_id;
  elsif new.alvo_tipo = 'estabelecimento' then
    update public.estabelecimento
       set aval_total     = aval_total + 1,
           aval_positivas = aval_positivas + case when new.resposta then 1 else 0 end
     where id = new.alvo_id;
  end if;
  return null;
end $$;

comment on function privado.somar_avaliacao() is
  'Soma a avaliação em aval_positivas e aval_total da parte avaliada (RN08), por incremento atômico.';

create trigger avaliacao_soma_na_reputacao
  after insert on public.avaliacao
  for each row execute function privado.somar_avaliacao();

-- ── O profissional como PerfilPublico ──────────────────────────────────────────
--
-- A mesma de 20260924180000, com uma diferença: a conta anonimizada aparece como
-- "Conta encerrada" (RF25). O turno e a avaliação sobrevivem à exclusão porque são
-- também da contraparte; o nome, não. Nenhum contato (RN10), nenhum ponto base.

create or replace function privado.perfil_publico_profissional(prof uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id',   p.id,
    'tipo', 'profissional',
    'nome', case when u.estado = 'anonimizada' then 'Conta encerrada' else u.nome end,
    'funcoes', coalesce((select jsonb_agg(f.nome order by f.nome)
                           from public.profissional_funcao pf
                           join public.funcao f on f.id = pf.funcao_id
                          where pf.profissional_id = p.id), '[]'::jsonb),
    'reputacao', jsonb_build_object(
      'positivas',           p.aval_positivas,
      'total',               p.aval_total,
      'taxa_comparecimento', p.taxa_comparecimento,
      'turnos_realizados',   p.turnos_realizados,
      'turnos_considerados', p.turnos_realizados
                             + (select count(*) from public.posicao x
                                 where x.profissional_id = p.id and x.falta)))
    from public.profissional p
    join public.usuario u on u.id = p.usuario_id
   where p.id = prof
$$;

-- ── perfil_publico ─────────────────────────────────────────────────────────────
--
-- GET no contrato. Sem rótulo de volatilidade porque chama `public.erro`; não escreve,
-- e por isso responde na transação só de leitura do PostgREST.

create or replace function public.perfil_publico(id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_perfil jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  v_perfil := privado.perfil_publico_profissional(perfil_publico.id);
  if v_perfil is null then
    v_perfil := privado.estabelecimento_publico(perfil_publico.id);
  end if;
  if v_perfil is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  return v_perfil;
end $$;

comment on function public.perfil_publico(uuid) is
  'Perfil público de profissional ou estabelecimento: nome, funções, positivas e total, taxa de comparecimento, turnos realizados e considerados (RF16, RN08). Nunca telefone, e-mail, nascimento, documento ou ponto base (RN10). Conta anonimizada aparece como "Conta encerrada" (RF25).';

revoke execute on function public.perfil_publico(uuid) from public, anon;
grant  execute on function public.perfil_publico(uuid) to authenticated;

-- ── avaliar ────────────────────────────────────────────────────────────────────

create or replace function public.avaliar(turno_id uuid, resposta boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid         uuid := (select auth.uid());
  v_turno       uuid := avaliar.turno_id;
  v_resposta    boolean := avaliar.resposta;
  v_prof        uuid;
  v_estab       uuid;
  v_fim         timestamptz;
  v_verificacao public.verificacao_turno;
  v_alvo_tipo   text;
  v_alvo_id     uuid;
  v_linha       public.avaliacao%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- RN13, com o mesmo código e o mesmo `details` de `publicar_vaga`: a conta suspensa
  -- não avalia ninguém. Vem antes de tudo o que fala sobre o turno, para a recusa não
  -- depender de o turno existir.
  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  -- `turno_id` ausente é campo faltando, e não turno alheio. `fazer_checkin` já trata
  -- assim; sem esta linha o nulo cairia no `select` vazio e sairia como
  -- `403 sem_permissao`, mandando o app pedir permissão para consertar um campo.
  if v_turno is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  select p.profissional_id, v.estabelecimento_id, p.fim_em, t.verificacao
    into v_prof, v_estab, v_fim, v_verificacao
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v    on v.id = p.vaga_id
   where t.id = v_turno;

  -- O lado de quem chama decide o alvo. Turno inexistente e turno alheio recebem a
  -- mesma recusa: a diferença diria a um estranho que o turno existe.
  if found and v_prof is not null and v_prof = privado.meu_profissional_id() then
    v_alvo_tipo := 'estabelecimento';
    v_alvo_id   := v_estab;
  elsif found and privado.eh_membro(v_estab) then
    v_alvo_tipo := 'profissional';
    v_alvo_id   := v_prof;
  else
    perform public.erro(403, 'sem_permissao');
  end if;

  if v_resposta is null then
    perform public.erro(422, 'campo_obrigatorio', 'resposta');
  end if;

  -- Idempotência antes do prazo: o reenvio devolve o que já foi gravado, sempre. Pela
  -- chave do lado, e não só do autor — o operador que reenvia o que o administrador já
  -- respondeu recebe a avaliação do seu lado.
  select * into v_linha from public.avaliacao a
   where a.turno_id = v_turno and a.alvo_tipo = v_alvo_tipo;
  if not found then
    if privado.agora() < v_fim then
      perform public.erro(422, 'avaliacao_indisponivel', 'antes_do_fim');
    end if;
    if v_verificacao is distinct from 'verificado' then
      perform public.erro(422, 'avaliacao_indisponivel', 'sem_presenca_verificada');
    end if;

    -- O `do update` que não muda nada existe para a inserção **sempre** devolver uma
    -- linha, inclusive quando outra chamada do mesmo lado ganhou a corrida. Com
    -- `do nothing` o `returning` volta vazio, e aí a decisão de 409 passaria a depender
    -- de um segundo `select` e do que a outra transação fez — commit ou rollback. Não é
    -- corrida que a máquina reproduza, e o custo de raciocinar sobre ela toda vez é
    -- maior do que o custo desta linha.
    insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
    values (v_turno, v_uid, v_alvo_tipo, v_alvo_id, v_resposta)
    on conflict (turno_id, alvo_tipo)
      do update set resposta = public.avaliacao.resposta
    returning * into v_linha;
  end if;

  if v_linha.resposta is distinct from v_resposta then
    perform public.erro(409, 'avaliacao_ja_registrada');
  end if;

  return jsonb_build_object(
    'turno_id',  v_linha.turno_id,
    'resposta',  v_linha.resposta,
    'criada_em', v_linha.criada_em);
end $$;

comment on function public.avaliar(uuid, boolean) is
  'Avaliação binária de uma parte do turno sobre a outra (RF15, RN07): só depois do fim previsto, pelo relógio do produto, e só com presença verificada. Um voto por lado; reenvio com a mesma resposta devolve a gravada, com outra resposta dá 409 avaliacao_ja_registrada.';

revoke execute on function public.avaliar(uuid, boolean) from public, anon;
grant  execute on function public.avaliar(uuid, boolean) to authenticated;

-- As auxiliares do schema privado: fora da API, e anon não executa nada.
revoke execute on function privado.somar_avaliacao() from public, anon;
