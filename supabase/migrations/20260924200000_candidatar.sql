-- `candidatar`: onde o produto quebra se errar.
--
-- No modo urgência o primeiro elegível que aceita é confirmado; quem chega depois
-- recebe `409 posicao_ja_preenchida`, que é **funcionamento normal** e não erro — a
-- tela diz "que pena, foi rápido", não "algo deu errado".
--
-- A confirmação é um `UPDATE` condicional dentro da função, e não um `SELECT` seguido
-- de `UPDATE`: entre ler e escrever cabe outra transação inteira, e é exatamente aí
-- que duas pessoas ficariam com a mesma posição. `FOR UPDATE SKIP LOCKED` faz cada
-- candidato pegar uma posição **diferente** em vez de todos esperarem a mesma.
--
-- `UPDATE … LIMIT 1` não existe no Postgres; por isso o subselect.

-- ── A trava por par (vaga, profissional) ──────────────────────────────────────
--
-- Protege o caso do toque duplo: o mesmo profissional chamando duas vezes em paralelo
-- na mesma vaga. Sem ela, as duas transações passariam pela conferência de "já tenho
-- posição aqui?" antes de qualquer uma escrever, e a pessoa sairia com dois turnos da
-- mesma vaga. A trava é de transação: solta sozinha no commit ou no rollback.
--
-- Duas chaves de 32 bits em vez de uma de 64: `pg_advisory_xact_lock(int, int)` deixa
-- o par legível em `pg_locks` quando alguém for investigar um travamento.
create or replace function privado.travar_candidatura(vaga uuid, prof uuid)
returns void
language sql
set search_path = ''
as $$
  select pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(vaga::text), pg_catalog.hashtext(prof::text))
$$;

comment on function privado.travar_candidatura(uuid, uuid) is
  'Trava de transação por par (vaga, profissional). Impede que o mesmo profissional tome duas posições da mesma vaga com duas chamadas em paralelo.';

-- ── O contato, que só existe depois da confirmação ────────────────────────────
--
-- RN10: telefone e WhatsApp saem só depois de confirmar, e com prazo — o fim previsto
-- do turno mais 7 dias. O `wa.me` não aceita o `+` do E.164, e tirar isso no cliente
-- seria repetir a mesma regra em três apps.
create or replace function privado.contato_do_estabelecimento(vaga uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'nome',         e.nome,
    'telefone',     u.telefone,
    'whatsapp_url', 'https://wa.me/' || replace(u.telefone, '+', ''),
    'visivel_ate',  v.fim_em + interval '7 days')
    from public.vaga v
    join public.estabelecimento e on e.id = v.estabelecimento_id
    join public.usuario u         on u.id = v.publicado_por
   where v.id = vaga
$$;

comment on function privado.contato_do_estabelecimento(uuid) is
  'Contato da casa para quem já confirmou (RN10). O prazo é o fim previsto do turno mais 7 dias; o link do WhatsApp sai sem o + do E.164, que o wa.me não aceita.';

-- ── candidatar ────────────────────────────────────────────────────────────────

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

  return jsonb_build_object(
    'estado',         'confirmada',
    'candidatura_id', v_cand,
    'posicao_id',     v_pos,
    'turno_id',       v_turno,
    'contato',        privado.contato_do_estabelecimento(candidatar.vaga_id));
end $$;

comment on function public.candidatar(uuid) is
  'Candidatura no modo urgência: confirma a primeira posição aberta por UPDATE condicional (RN19), cria o turno com o valor copiado (RN11) e devolve o contato (RN10). Reenviar devolve o mesmo resultado.';

revoke execute on function public.candidatar(uuid) from public, anon;
grant execute on function public.candidatar(uuid) to authenticated;
