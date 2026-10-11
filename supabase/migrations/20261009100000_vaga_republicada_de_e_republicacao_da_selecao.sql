-- 20261009100000_vaga_republicada_de_e_republicacao_da_selecao.sql
--
-- Republicar as posições restantes em urgência (modo seleção, D1-C, RR-RN01 a RR-RN05, R1 a R4).
-- Passo P1 e P2 do plano (requisitos/republicar-posicoes-restantes-plano.md):
--   1. Coluna public.vaga.republicada_de uuid references public.vaga(id), nulo.
--   2. Índice único parcial em vaga(republicada_de) onde republicada_de is not null and estado in ('publicada','preenchida').
--   3. Função privado.republicacao_da_selecao(vaga_id uuid) returns table (restantes int, motivo text), stable.

-- ── 1. Coluna republicada_de em public.vaga ───────────────────────────────────
--
-- Guarda a vaga de origem quando uma vaga nasce da republicação das posições
-- restantes de uma vaga de seleção fechada (RR-RN05).
alter table public.vaga
  add column republicada_de uuid references public.vaga(id);

comment on column public.vaga.republicada_de is
  'Vaga de seleção de origem cujas posições restantes foram republicadas em urgência (D1-C, RR-RN05). Nulo para vagas criadas do zero ou por republicar_vaga comum.';

-- ── 2. Índice único parcial para "uma ativa por vez" (RR-RN05, R3=B) ──────────
--
-- Garante que uma mesma vaga de seleção só pode ter uma republicação de sobras
-- ativa (publicada ou preenchida) por vez. Se a vaga nova for cancelada, o índice
-- libera a criação de uma nova republicação.
create unique index vaga_uma_republicacao_ativa_idx
  on public.vaga (republicada_de)
  where republicada_de is not null and estado in ('publicada', 'preenchida');

-- ── 3. Função privado.republicacao_da_selecao ─────────────────────────────────
--
-- Fonte única de cálculo para a RPC public.republicar_posicoes_restantes e para o
-- campo republicavel_em_urgencia em public.painel_estabelecimento.
-- Aplica as regras RR-RN01, RR-RN03 e RR-RN05.
-- Devolve (restantes int, motivo text):
--   - Se apta: restantes > 0 e motivo is null.
--   - Se inapta: restantes = 0 (ou null para o painel) e motivo preenchido com um dos 6 códigos:
--     * 'nao_e_selecao'
--     * 'selecao_em_curso'
--     * 'vaga_cancelada'
--     * 'ja_comecou'
--     * 'sem_posicoes_restantes'
--     * 'ja_republicada'
create or replace function privado.republicacao_da_selecao(vaga_id uuid)
returns table (restantes int, motivo text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_vaga      public.vaga%rowtype;
  v_agora     timestamptz;
  v_ocupadas  int;
  v_sobras    int;
begin
  select * into v_vaga from public.vaga g where g.id = republicacao_da_selecao.vaga_id;
  if not found then
    return;
  end if;

  v_agora := privado.agora();

  -- 1. Apenas modo seleção (RR-RN01)
  if v_vaga.modo <> 'selecao' then
    return query select 0, 'nao_e_selecao'::text;
    return;
  end if;

  -- 2. Seleção ainda publicada / em curso (RR-RN01)
  if v_vaga.estado = 'publicada' then
    return query select 0, 'selecao_em_curso'::text;
    return;
  end if;

  -- 3. Vaga cancelada pela casa (RR-RN01)
  if v_vaga.estado = 'cancelada' then
    return query select 0, 'vaga_cancelada'::text;
    return;
  end if;

  -- 4. Início já passou (RR-RN01)
  if v_vaga.inicio_em <= v_agora then
    return query select 0, 'ja_comecou'::text;
    return;
  end if;

  -- 5. Posições restantes: posicoes nominais da vaga menos as confirmadas ou cumpridas (RR-RN03).
  -- Sob a migração de reposição #161, a tabela posicao pode conter posições canceladas
  -- que foram reabertas; portanto contamos apenas posições ativas confirmada/cumprida.
  select count(*)::int into v_ocupadas
    from public.posicao p
   where p.vaga_id = v_vaga.id
     and p.estado in ('confirmada', 'cumprida');

  v_sobras := v_vaga.posicoes - v_ocupadas;

  if v_sobras <= 0 then
    return query select 0, 'sem_posicoes_restantes'::text;
    return;
  end if;

  -- 6. Já republicada ativamente (RR-RN05, R3=B)
  if exists (
    select 1 from public.vaga r
     where r.republicada_de = v_vaga.id
       and r.estado in ('publicada', 'preenchida')
  ) then
    return query select 0, 'ja_republicada'::text;
    return;
  end if;

  -- Apta: devolve a quantidade de sobras e motivo nulo
  return query select v_sobras, null::text;
end $$;

comment on function privado.republicacao_da_selecao(uuid) is
  'Calcula se uma vaga de seleção fechada é republicável em urgência e quantas posições restam (D1-C, RR-RN01, RR-RN03, RR-RN05). Fonte única da RPC e do painel.';

revoke execute on function privado.republicacao_da_selecao(uuid) from public, anon, authenticated;
grant  execute on function privado.republicacao_da_selecao(uuid) to service_role;
