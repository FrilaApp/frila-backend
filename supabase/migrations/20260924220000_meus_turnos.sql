-- `meus_turnos`: o que o profissional e a casa acompanham depois da confirmação.
--
-- É a mesma operação para os dois lados, e a diferença é quem aparece como
-- `contraparte`: para o profissional, o estabelecimento; para quem opera a casa, o
-- profissional. Um par de RPCs separadas diria a mesma coisa duas vezes e divergiria
-- na primeira mudança de campo.
--
-- O que ela **não** traz é telefone. O contato sai só por `contato_do_turno`, que
-- confere o prazo de RN10 — uma lista que já trouxesse o contato tornaria o prazo
-- decorativo.

-- ── O relógio do produto também na avaliação ──────────────────────────────────
--
-- O gatilho de RN07 nasceu com `now()` direto, e era o único lugar do esquema que não
-- passava por `privado.agora()`. Consequência prática: um teste que sobrepõe o relógio
-- para depois do fim do turno continuava recebendo `antes_do_fim`, e a regra de
-- avaliação só era testável esperando o turno acontecer de verdade.
create or replace function privado.avaliacao_permitida()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fim         timestamptz;
  v_verificacao public.verificacao_turno;
begin
  select p.fim_em, t.verificacao
    into v_fim, v_verificacao
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = new.turno_id;

  if v_fim is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if privado.agora() < v_fim then
    perform public.erro(422, 'avaliacao_indisponivel', 'antes_do_fim');
  end if;

  if v_verificacao is distinct from 'verificado' then
    perform public.erro(422, 'avaliacao_indisponivel', 'sem_presenca_verificada');
  end if;

  return new;
end $$;

-- ── pode_avaliar ──────────────────────────────────────────────────────────────
--
-- As três condições de RN07, na mesma ordem em que o gatilho as cobra. A tela usa isto
-- para decidir se mostra o botão; o gatilho é quem de fato recusa. Os dois precisam
-- concordar, e é por isso que ficam no mesmo arquivo.
create or replace function privado.pode_avaliar(turno uuid, autor uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select t.verificacao = 'verificado'
     and privado.agora() >= p.fim_em
     and not exists (select 1 from public.avaliacao a
                      where a.turno_id = t.id and a.autor_id = autor)
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = turno
$$;

comment on function privado.pode_avaliar(uuid, uuid) is
  'As três condições de RN07 — depois do fim previsto, com presença verificada e sem avaliação deste autor. A tela decide o botão por aqui; quem recusa de fato é o gatilho.';

-- ── O turno no schema do contrato ─────────────────────────────────────────────

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
      'id',             v.id,
      'funcao',         f.nome,
      'local',          v.local,
      'inicio_em',      v.inicio_em,
      'fim_em',         v.fim_em,
      'valor_centavos', v.valor_centavos),
    -- Quem é a contraparte depende de quem pergunta. O profissional vê a casa; quem
    -- opera a casa vê o profissional.
    'contraparte', case
      when privado.usuario_do_profissional(p.profissional_id) = autor
        then privado.estabelecimento_publico(v.estabelecimento_id)
        else privado.perfil_publico_profissional(p.profissional_id) end,
    -- RN10. Aparece aqui, e não só em `contato_do_turno`, para que a tela saiba **antes**
    -- se pode oferecer o botão: sem isso o profissional toca em "falar com o
    -- contratante" e recebe um erro que não tinha como prever.
    'contato_visivel_ate',     p.fim_em + interval '7 days',
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
  'Turno no schema do contrato, do ponto de vista de `autor`. Sem telefone: o contato sai por contato_do_turno, que confere o prazo de RN10.';

-- ── meus_turnos ───────────────────────────────────────────────────────────────

create or replace function public.meus_turnos(
  de                 timestamptz default null,
  ate                timestamptz default null,
  estabelecimento_id uuid        default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_prof  uuid;
  v_agora timestamptz;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- Com `estabelecimento_id`, são os turnos da casa, e quem pergunta tem de ser membro
  -- dela. Sem ele, são os turnos de quem chama como profissional.
  if meus_turnos.estabelecimento_id is not null then
    if not privado.eh_membro(meus_turnos.estabelecimento_id) then
      perform public.erro(403, 'sem_permissao');
    end if;
  else
    select p.id into v_prof from public.profissional p where p.usuario_id = v_uid;
    if v_prof is null then
      -- Conta de contratante sem `estabelecimento_id` não tem turno nenhum como
      -- profissional. Lista vazia, e não erro: a pergunta é válida e a resposta é
      -- "nenhum".
      return '[]'::jsonb;
    end if;
  end if;

  v_agora := privado.agora();

  return coalesce((
    select jsonb_agg(item order by ordem)
      from (
        select privado.turno_em_json(t.id, v_uid) as item,
               -- Hoje e os próximos primeiro, do mais próximo para o mais distante; os
               -- anteriores depois, do mais recente para o mais antigo. É a ordem da
               -- tela: o turno de hoje é o que a pessoa abre o app para ver.
               row_number() over (
                 order by (p.fim_em < v_agora),
                          case when p.fim_em < v_agora
                               then -extract(epoch from p.inicio_em)
                               else  extract(epoch from p.inicio_em) end) as ordem
          from public.turno t
          join public.posicao p on p.id = t.posicao_id
          join public.vaga g    on g.id = p.vaga_id
         where (meus_turnos.estabelecimento_id is not null
                  and g.estabelecimento_id = meus_turnos.estabelecimento_id
                or meus_turnos.estabelecimento_id is null
                  and p.profissional_id = v_prof)
           and (meus_turnos.de  is null or p.inicio_em >= meus_turnos.de)
           and (meus_turnos.ate is null or p.inicio_em <= meus_turnos.ate)
      ) x
  ), '[]'::jsonb);
end $$;

comment on function public.meus_turnos(timestamptz, timestamptz, uuid) is
  'Turnos do chamador como profissional, ou da casa quando vem estabelecimento_id (RF13, UC13). Hoje e os próximos primeiro. Sem telefone: o contato sai por contato_do_turno.';

revoke execute on function public.meus_turnos(timestamptz, timestamptz, uuid) from public, anon;
grant execute on function public.meus_turnos(timestamptz, timestamptz, uuid) to authenticated;
