-- Busca de profissionais, PR 2 (B-027.e; contrato 0.2.88 do frila-documentacao #259 d933885).
--
-- O PR 1 (20261116210000) criou a busca e o "Aceito chamadas diretas". Este fecha o caminho de quem foi
-- achado na busca: chamar, ler o perfil e não revelar o sobrenome.
--
--   1. public.vaga ganha regiao_id (a vaga direta guarda a região com que nasceu; a 2ª e a 3ª chamada pelo
--      vaga_id usam a mesma).
--   2. chamar_profissional aceita também quem está na busca, sem vínculo de trabalho com a casa, e ganha
--      regiao_id opcional (fora do catálogo, inativo ou de nome diferente do regiao_administrativa:
--      422 campo_invalido, regiao_id). Troca de assinatura com drop e create (duas versões com default
--      deixariam a chamada ambígua, PGRST203). O caminho do vínculo fica igual.
--   3. O perfil rico: quem ligou "Aceito chamadas diretas" conta como vínculo de leitura para qualquer
--      contratante, com ou sem pausa (privado.contratante_com_vinculo_leitura). A foto NÃO: ela segue o
--      vínculo próprio da 0.2.54 (privado.foto_de_perfil_projecao), que esta migração não toca.
--   4. O nome curto ("Maria L.", privado.nome_curto, do PR 1) vale em TODA leitura de PerfilPublico para todo
--      leitor que não seja o próprio profissional nem contratante com candidatura, turno ou equipe de
--      confiança com ele (inclusive outro profissional): perfil_publico,
--      ChamadaResumo.outra_parte (minhas_chamadas), detalhe_chamada, candidatos_da_vaga e os turnos
--      passam todos por privado.perfil_publico_profissional, que é onde a regra mora (privado.leitor_ve_nome_completo).
--      Muda leitoras que já existiam: a casa que só chamou o profissional (sem candidatura, turno nem
--      equipe) passa a ver o nome curto, que hoje vê inteiro, e outro profissional também. listar_bloqueios (ItemBloqueio.nome) idem.

select set_config('lock_timeout', '2s', true);

-- ── 1. A região da vaga direta ────────────────────────────────────────────────

alter table public.vaga add column regiao_id smallint references public.regiao_administrativa (id);
comment on column public.vaga.regiao_id is
  'Id da região do trabalho (catálogo RN44), copiado da busca por chamar_profissional (contrato 0.2.88). Só a vaga direta o guarda: a 2ª e a 3ª chamada pelo vaga_id usam o mesmo. Nulo nas outras vagas e nas diretas anteriores à 0.2.88 (a região delas é o nome em regiao_administrativa).';

-- ── 2. Quem lê o nome inteiro ─────────────────────────────────────────────────

-- Nome inteiro SÓ para o próprio profissional e para o contratante com candidatura em vaga da casa, turno com
-- a casa ou equipe de confiança com ele (0.2.88). Qualquer outro leitor lê o nome curto: contratante sem
-- vínculo (chamada direta e busca não contam: é justamente o caso da casa que só chamou), contratante sem
-- casa, outro profissional e leitura sem sessão. Decide pelo perfil da conta do leitor. O vínculo vale se
-- QUALQUER casa de que o leitor é membro o tem (RN25). Só conta o vínculo VIGENTE na hora da leitura: candidatura
-- pendente ou aceita (retirada, recusada e expirada não), turno e equipe de confiança (desfeita, já não existe).
create function privado.leitor_ve_nome_completo(p_profissional uuid, p_leitor uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    exists (select 1 from public.profissional p where p.id = p_profissional and p.usuario_id = p_leitor)
    or (
      (select u.perfil from public.usuario u where u.id = p_leitor) = 'contratante'
      and exists (
        select 1
          from public.membro_estabelecimento me
         where me.usuario_id = p_leitor
           and (
             exists (select 1 from public.equipe_confianca ec
                      where ec.estabelecimento_id = me.estabelecimento_id and ec.profissional_id = p_profissional)
             or exists (select 1 from public.candidatura c
                          join public.posicao pos on pos.id = c.posicao_id
                          join public.vaga v on v.id = pos.vaga_id
                         where v.estabelecimento_id = me.estabelecimento_id and c.profissional_id = p_profissional
                           and c.estado in ('pendente', 'aceita'))
             or exists (select 1 from public.posicao pos
                          join public.vaga v on v.id = pos.vaga_id
                         where v.estabelecimento_id = me.estabelecimento_id and pos.profissional_id = p_profissional)
           ))), false)
$$;
comment on function privado.leitor_ve_nome_completo(uuid, uuid) is
  'Se o leitor vê o nome inteiro do profissional (contrato 0.2.88): só o próprio profissional e o contratante com candidatura, turno ou equipe de confiança com ele em QUALQUER casa de que é membro. Todo outro leitor, inclusive outro profissional e contratante sem casa, lê o nome curto (privado.nome_curto). Chamada direta e busca não contam como vínculo.';
revoke all on function privado.leitor_ve_nome_completo(uuid, uuid) from public, anon, authenticated;
grant execute on function privado.leitor_ve_nome_completo(uuid, uuid) to service_role;

-- ── 3. O vínculo de leitura do perfil rico passa a incluir a busca ─────────────
-- Corpo de 20261107360000 com o 5º caso. Só o perfil rico o usa; a foto tem o vínculo dela.

create or replace function privado.contratante_com_vinculo_leitura(
  p_prof uuid,
  p_uid  uuid
) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from public.membro_estabelecimento me
     where me.usuario_id = p_uid
       and (
         -- 1. Equipe de confiança da casa
         exists (
           select 1 from public.equipe_confianca ec
            where ec.estabelecimento_id = me.estabelecimento_id
              and ec.profissional_id = p_prof
         )
         -- 2. Candidatura em vaga da casa
         or exists (
           select 1 from public.candidatura c
             join public.posicao pos on pos.id = c.posicao_id
             join public.vaga v on v.id = pos.vaga_id
            where v.estabelecimento_id = me.estabelecimento_id
              and c.profissional_id = p_prof
         )
         -- 3. Turno confirmado/realizado com a casa
         or exists (
           select 1 from public.posicao pos
             join public.vaga v on v.id = pos.vaga_id
            where v.estabelecimento_id = me.estabelecimento_id
              and pos.profissional_id = p_prof
         )
         -- 4. Chamada direta entre a casa e o profissional
         or exists (
           select 1 from public.chamada ch
            where ch.estabelecimento_id = me.estabelecimento_id
              and ch.profissional_id = p_prof
         )
         -- 5. 0.2.88: quem ligou "Aceito chamadas diretas" está na busca de qualquer casa. A pausa não
         --    muda isso (o perfil não revela quando ele pausou), e a demonstração não vaza para a
         --    população real nem o contrário (a mesma regra do chamar_profissional pela busca).
         or (privado.recurso_ligado('busca_profissionais')
             and privado.recurso_ligado('chamada_direta')
             and exists (select 1 from public.profissional_preferencia_chamada pc
                           join public.profissional pr on pr.id = pc.profissional_id
                           join public.usuario u on u.id = pr.usuario_id
                          where pc.profissional_id = p_prof and pc.aceita_chamadas
                            and u.estado = 'ativa')
             and privado.mesma_populacao(privado.usuario_do_profissional(p_prof)))
       )
  );
$$;

comment on function privado.contratante_com_vinculo_leitura(uuid, uuid) is
  'Verifica se o usuário é contratante com vínculo legítimo de leitura com o profissional: equipe de confiança, candidatura em vaga da casa, turno, chamada direta ou, desde a 0.2.88, o profissional estar na busca ("Aceito chamadas diretas" ligado, com ou sem pausa). Não vale para a foto (0.2.54).';

-- ── 3b. O nome do profissional para um leitor (a regra num lugar só) ──────────
create function privado.nome_do_profissional_para(p_profissional uuid, p_leitor uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select case when u.estado = 'anonimizada' then 'Conta encerrada'
              when privado.leitor_ve_nome_completo(p.id, p_leitor) then u.nome
              else coalesce(privado.nome_curto(u.nome), u.nome) end
    from public.profissional p
    join public.usuario u on u.id = p.usuario_id
   where p.id = p_profissional
$$;
comment on function privado.nome_do_profissional_para(uuid, uuid) is
  'O nome do profissional como o leitor o vê (contrato 0.2.89): inteiro para o próprio profissional e para o contratante com vínculo vigente (candidatura, turno ou equipe); "Maria L." para todo outro leitor; "Conta encerrada" para conta anonimizada. perfil_publico_profissional o usa com auth.uid(). Quem lê sem sessão (a exportação, privado.meus_dados, pela Edge Function) recebe o nome curto até o ajuste do turno_em_json, que o JP reescreve nos PRs #513 e #516.';
revoke all on function privado.nome_do_profissional_para(uuid, uuid) from public, anon, authenticated;
grant execute on function privado.nome_do_profissional_para(uuid, uuid) to service_role;

-- ── 4. perfil_publico_profissional com o nome curto ───────────────────────────
-- Corpo de 20261109180000 com só a linha do nome trocada. É a leitora de todos os PerfilPublico de
-- profissional (perfil_publico, minhas_chamadas, detalhe_chamada, candidatos_da_vaga, turnos).

create or replace function privado.perfil_publico_profissional(prof uuid)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid         uuid := (select auth.uid());
  v_res         jsonb;
  p             public.profissional%rowtype;
  u             public.usuario%rowtype;
  v_tem_f2      boolean;
  v_bloqueado   boolean;
begin
  select * into p from public.profissional where id = prof;
  if not found then return null; end if;
  select * into u from public.usuario where id = p.usuario_id;

  v_res := jsonb_build_object(
    'id',   p.id,
    'tipo', 'profissional',
    -- 0.2.89: nome inteiro só para o próprio profissional e para o contratante com vínculo vigente; todo
    -- outro leitor lê "Maria L." (privado.nome_do_profissional_para, a regra num lugar só).
    'nome', privado.nome_do_profissional_para(p.id, v_uid),
    'funcoes', coalesce((select jsonb_agg(f.nome order by f.nome)
                           from public.profissional_funcao pf
                           join public.funcao f on f.id = pf.funcao_id
                          where pf.profissional_id = p.id), '[]'::jsonb),
    -- A mesma conta do cartão da busca, num lugar só (privado.reputacao_profissional, do PR 1).
    'reputacao', privado.reputacao_profissional(p.id)
  );

  -- Bloqueio mútuo em qualquer direção com o leitor ou estabelecimentos do leitor:
  if v_uid is not null then
    v_bloqueado := exists (
      select 1 from public.bloqueio b
       where (b.autor_id = v_uid and b.bloqueado_id = p.usuario_id)
          or (b.autor_id = p.usuario_id and b.bloqueado_id = v_uid)
    ) or exists (
      select 1 from public.membro_estabelecimento me
       where me.usuario_id = v_uid
         and privado.bloqueado_com_estabelecimento(p.usuario_id, me.estabelecimento_id)
    );
  else
    v_bloqueado := false;
  end if;

  -- Se o alvo NÃO está anonimizado/encerrado, o leitor está autenticado,
  -- NÃO há bloqueio mútuo, o leitor possui vínculo legítimo e o profissional preencheu dados F2:
  -- Perfil rico desligado (contrato 0.2.60): PerfilPublico só com a base, sem os campos da F2.
  if u.estado <> 'anonimizada'
     and privado.recurso_ligado('perfil_rico')
     and v_uid is not null
     and not v_bloqueado
     and privado.contratante_com_vinculo_leitura(p.id, v_uid) then

    v_tem_f2 := (
      p.apresentacao is not null
      or p.onde_trabalhei is not null
      or p.experiencia_faixa is not null
      or (p.cursos is not null and cardinality(p.cursos) > 0)
      or (p.idiomas is not null and cardinality(p.idiomas) > 0)
      or p.atende_todo_df
      or exists (select 1 from public.profissional_servico where profissional_id = p.id)
      or exists (select 1 from public.profissional_regiao where profissional_id = p.id)
    );

    if v_tem_f2 then
      v_res := v_res || jsonb_build_object(
        'apresentacao', p.apresentacao,
        'onde_trabalhei', p.onde_trabalhei,
        'experiencia_faixa', p.experiencia_faixa,
        'cursos', to_jsonb(coalesce(p.cursos, '{}'::text[])),
        'idiomas', to_jsonb(coalesce(p.idiomas, '{}'::text[])),
        'atende_todo_df', p.atende_todo_df,
        'no_frila_desde', to_char(u.criado_em, 'YYYY-MM'),
        'regioes', coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
                               from public.profissional_regiao pr
                               join public.regiao_administrativa r on r.id = pr.regiao_id
                              where pr.profissional_id = p.id), '[]'::jsonb),
        'servicos', coalesce((select jsonb_agg(jsonb_strip_nulls(to_jsonb(s) - array['profissional_id','funcao_id','extras','atualizado_em']) ||
                             jsonb_build_object('funcao', to_jsonb(f) - 'ativo', 'especialidades', coalesce((select jsonb_agg(to_jsonb(e) order by e.nome)
                               from public.profissional_servico_especialidade se join public.especialidade e on e.id = se.especialidade_id
                               where se.profissional_id = s.profissional_id and se.funcao_id = s.funcao_id), '[]'::jsonb)) order by f.nome)
                             from public.profissional_servico s join public.funcao f on f.id = s.funcao_id
                            where s.profissional_id = p.id), '[]'::jsonb)
      );
    end if;
  end if;

  return v_res;
end $$;

comment on function privado.perfil_publico_profissional(uuid) is
  'Gera o json de perfil público de profissional, somando histórico vivo e base histórica expurgada (R9). Inclui campos F2 se recurso perfil_rico estiver ligado e houver vínculo legítimo (inclusive a busca, 0.2.88). O nome vem curto para o contratante sem candidatura, turno nem equipe com o profissional (0.2.88).';

-- ── 5. listar_bloqueios com o nome curto ──────────────────────────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.listar_bloqueios 0.2.88

create or replace function public.listar_bloqueios()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_perfil public.perfil_conta;
  v_itens  jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  v_perfil := privado.perfil_da_conta();

  if v_perfil = 'profissional' then
    -- Do lado do profissional, N linhas (uma por membro) são UM bloqueio de casa. O
    -- `min(criado_em)` é o instante em que ele bloqueou, e não o da última linha gravada
    -- quando a casa ganhou membro novo depois.
    select coalesce(jsonb_agg(item order by (item->>'criado_em') desc), '[]'::jsonb)
      into v_itens
      from (
        select jsonb_build_object(
                 'alvo_tipo', 'estabelecimento',
                 'alvo_id',   e.id,
                 'nome',      e.nome,
                 'criado_em', min(b.criado_em)
               ) as item
          from public.bloqueio b
          join public.membro_estabelecimento m on m.usuario_id = b.bloqueado_id
          join public.estabelecimento e       on e.id = m.estabelecimento_id
         where b.autor_id = v_uid
         group by e.id, e.nome
      ) q;
  else
    -- Conta encerrada continua na lista, com o nome público que o resto do produto usa
    -- (RF25): esconder o item deixaria um bloqueio ativo sem nenhuma forma de desfazer.
    select coalesce(jsonb_agg(item order by (item->>'criado_em') desc), '[]'::jsonb)
      into v_itens
      from (
        select jsonb_build_object(
                 'alvo_tipo', 'profissional',
                 'alvo_id',   p.id,
                 -- 0.2.88: nome curto para a casa sem candidatura, turno nem equipe com o profissional
                 -- (o bloqueio tira da equipe, mas candidatura e turno antigos seguem valendo).
                 'nome',      case when u.estado = 'anonimizada' then 'Conta encerrada'
                                   when privado.leitor_ve_nome_completo(p.id, v_uid) then u.nome
                                   else coalesce(privado.nome_curto(u.nome), u.nome) end,
                 'criado_em', b.criado_em
               ) as item
          from public.bloqueio b
          join public.profissional p on p.usuario_id = b.bloqueado_id
          join public.usuario u      on u.id = p.usuario_id
         where b.autor_id = v_uid
      ) q;
  end if;

  return coalesce(v_itens, '[]'::jsonb);
end $$;

-- ── 6. chamar_profissional pela busca ─────────────────────────────────────────

drop function public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean);

create function public.chamar_profissional(
  chave uuid default null, profissional_id uuid default null, estabelecimento_id uuid default null,
  vaga_id uuid default null, funcao_id uuid default null, inicio_em timestamptz default null,
  fim_em timestamptz default null, local text default null, regiao_administrativa text default null,
  ponto jsonb default null, valor_centavos bigint default null, inclui_refeicao boolean default null,
  inclui_transporte boolean default null, exige_material_proprio boolean default null,
  responsavel_local text default null, recado text default null, confirmo_recorrencia boolean default false,
  regiao_id int default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid            uuid := (select auth.uid());
  v_agora          timestamptz := privado.agora();
  v_estab          uuid := chamar_profissional.estabelecimento_id;
  v_prof           uuid := chamar_profissional.profissional_id;
  v_recado         text := nullif(btrim(chamar_profissional.recado), '');
  v_conta          public.usuario%rowtype;
  v_vaga           public.vaga%rowtype;
  v_c              public.chamada%rowtype;
  v_falta          text;
  v_veterana       boolean;
  v_tem_pref       boolean;
  v_so_cnpj        boolean;
  v_sem_versao     boolean;
  v_sem_vinculo    boolean;
  v_na_busca       boolean;
  v_funcao_busca   uuid;
  v_regiao_busca   smallint;
  v_nao_aceita     boolean;
  v_pref           public.profissional_preferencia_chamada%rowtype;
  v_ant_min_h      int := 6;
  v_casa_doc       text;
  v_turnos_casa    int;
  v_hora_sp        int;
  v_inicio_prazo   timestamptz;
  v_expira_em      timestamptz;
  v_lembrete_em    timestamptz;
  v_janela_efetiva interval;
  v_ultimas_recusas int;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
  perform privado.exigir_perfil('contratante');
  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;
  if chamar_profissional.chave is null then perform public.erro(422, 'campo_obrigatorio', 'chave'); end if;
  if v_prof is null then perform public.erro(422, 'campo_obrigatorio', 'profissional_id'); end if;
  if v_estab is null then perform public.erro(422, 'campo_obrigatorio', 'estabelecimento_id'); end if;
  if not privado.eh_membro(v_estab) then perform public.erro(403, 'sem_permissao'); end if;

  -- Idempotência: reenviar a mesma chave devolve a mesma chamada e não gasta cota.
  select * into v_c from public.chamada c where c.estabelecimento_id = v_estab and c.chave = chamar_profissional.chave;
  if found then return to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em']; end if;

  -- Profissional inexistente, fora do ar ou com bloqueio: o mesmo 404 (RF26).
  select u.* into v_conta from public.profissional p join public.usuario u on u.id = p.usuario_id where p.id = v_prof;
  if not found or v_conta.estado <> 'ativa'
     or privado.bloqueado_com_estabelecimento(v_conta.id, v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- 0.2.88: regiao_id é o id do catálogo (ativo) e o nome dele é o regiao_administrativa do corpo. Não
  -- depende do profissional, então a recusa sai antes de qualquer conta dele e não revela nada. Vem
  -- depois do 404 do bloqueio, que tem precedência sobre qualquer outra recusa (CD-C03, RF26). Com
  -- vaga_id, a região é a da vaga e o regiao_id do corpo é ignorado, como o regiao_administrativa.
  if chamar_profissional.vaga_id is null and chamar_profissional.regiao_id is not null
     and not exists (select 1 from public.regiao_administrativa r
                      where r.id = chamar_profissional.regiao_id and r.ativo
                        and (nullif(btrim(chamar_profissional.regiao_administrativa), '') is null
                             or r.nome = btrim(chamar_profissional.regiao_administrativa))) then
    perform public.erro(422, 'campo_invalido', 'regiao_id');
  end if;

  -- Serializa as chamadas da casa: os limites somam os membros (RN34).
  perform 1 from public.estabelecimento e where e.id = v_estab for update;
  -- Serializa também pelo profissional para atomicidade da cota de abertas entre casas distintas (CD-C14)
  perform 1 from public.profissional p where p.id = v_prof for update;
  if exists (select 1 from public.chamada c where c.estabelecimento_id = v_estab
                and c.profissional_id = v_prof and c.estado = 'aberta') then
    perform public.erro(409, 'chamada_ja_aberta');
  end if;

  -- Lê documento da casa
  select documento into v_casa_doc from public.estabelecimento where id = v_estab;

  -- Preferências do profissional (B5e)
  select * into v_pref from public.profissional_preferencia_chamada where profissional_id = v_prof;
  v_tem_pref := found;

  -- As três recusas genéricas (0.2.66): preferência só-CNPJ, versão do app e vínculo (RN28). As três
  -- são calculadas sempre, cada uma na sua variável, e o erro sai uma vez só, antes da validação do
  -- corpo. Assim nem a ordem nem o tempo de resposta denunciam qual delas valeu (revisão do Lince AG
  -- no frila-documentacao #193 e no #451).
  v_so_cnpj := coalesce(v_tem_pref and v_pref.aceita_de = 'so_cnpj' and length(v_casa_doc) = 11, false);
  -- Preferência "aceitar chamadas de quem já trabalhou comigo" desligada (definir_preferencia_chamadas,
  -- 20261107370000): toda chamada direta é de quem já trabalhou com o profissional, então desligar
  -- é não receber chamada. Entra no mesmo bloco genérico (B-019; LGPD art. 6º, VI).
  v_nao_aceita := coalesce(v_tem_pref and not v_pref.aceita_de_quem_ja_trabalhou, false);
  -- Versão: só chama quem tem algum aparelho cuja versao_app alcança o mínimo de chamada_direta da
  -- plataforma; a chamada nunca nasce para quem não receberia o aviso. Sem permissão de notificação o
  -- app não registra aparelho, então esse profissional não pode ser chamado.
  v_sem_versao := not exists (select 1 from public.dispositivo d
                               where d.usuario_id = v_conta.id
                                 and privado.recurso_na_versao('chamada_direta', d.plataforma::text, d.versao_app));
  -- Vínculo (RN28 na v1.1): turno cumprido com presença verificada na casa, ou equipe de confiança.
  -- É daqui que vem o isolamento da demonstração nesta RPC: conta de demonstração não tem turno nem
  -- equipe com a população real.
  v_veterana := exists (select 1 from public.turno t join public.posicao p on p.id = t.posicao_id
                          join public.vaga g on g.id = p.vaga_id
                         where g.estabelecimento_id = v_estab and p.profissional_id = v_prof
                           and p.estado = 'cumprida' and t.verificacao = 'verificado');
  -- 0.2.88: o segundo caminho é estar na busca, sem vínculo de trabalho. Só entra o que a busca decide
  -- sozinho e que esta função não confere adiante: a chave, "Aceito chamadas diretas" sem pausa, o
  -- serviço da função exata, a região do trabalho e a mesma população (a demonstração não chama o
  -- real: o caminho do vínculo isola por vínculo, e este não tem vínculo). O resto do que a busca
  -- exige (só-CNPJ, versão, bloqueio, 5 abertas, chamada aberta, pausa do par, prazo) já é conferido
  -- por esta função para os dois caminhos, cada um com o seu código.
  -- A função e a região são as da vaga direta quando vem vaga_id (2ª e 3ª chamadas), senão as do corpo.
  v_funcao_busca := case when chamar_profissional.vaga_id is not null
                         then (select g.funcao_id from public.vaga g
                                where g.id = chamar_profissional.vaga_id and g.estabelecimento_id = v_estab)
                         else chamar_profissional.funcao_id end;
  -- Com vaga_id vale a região da vaga (o regiao_id do corpo é ignorado); sem ele, o regiao_id ou o nome da região.
  v_regiao_busca := case
    when chamar_profissional.vaga_id is not null
      then (select coalesce(g.regiao_id,
                            (select r.id from public.regiao_administrativa r where r.nome = g.regiao_administrativa and r.ativo))
              from public.vaga g where g.id = chamar_profissional.vaga_id and g.estabelecimento_id = v_estab)
    when chamar_profissional.regiao_id is not null
      then (select r.id from public.regiao_administrativa r where r.id = chamar_profissional.regiao_id and r.ativo)
    else (select r.id from public.regiao_administrativa r
           where r.nome = btrim(chamar_profissional.regiao_administrativa) and r.ativo)
  end;
  v_na_busca := coalesce(
    privado.recurso_ligado('busca_profissionais')
    and v_tem_pref and v_pref.aceita_chamadas
    and (v_pref.pausado_ate is null or v_pref.pausado_ate < (v_agora at time zone 'America/Sao_Paulo')::date)
    and privado.mesma_populacao(v_conta.id)
    and v_funcao_busca is not null
    and exists (select 1 from public.profissional_servico s
                 where s.profissional_id = v_prof and s.funcao_id = v_funcao_busca)
    and v_regiao_busca is not null
    and exists (select 1 from public.profissional pr
                 where pr.id = v_prof
                   and (pr.atende_todo_df
                        or exists (select 1 from public.profissional_regiao pg
                                    where pg.profissional_id = pr.id and pg.regiao_id = v_regiao_busca))), false);
  -- "Aceitar de quem já trabalhou comigo" desligado só vale no caminho do VÍNCULO (contrato 0.2.88): quem
  -- ligou "Aceito chamadas diretas" aceitou qualquer contratante, então esta preferência não o barra.
  v_sem_vinculo := not v_na_busca
                   and (not (v_veterana or exists (select 1 from public.equipe_confianca q
                                                    where q.estabelecimento_id = v_estab and q.profissional_id = v_prof))
                        or v_nao_aceita);
  if v_so_cnpj or v_sem_versao or v_sem_vinculo then
    perform public.erro(422, 'profissional_indisponivel', 'nao_aceita_chamadas');
  end if;

  if v_tem_pref then
    v_ant_min_h := v_pref.antecedencia_minima_h;
    -- Pausa de chamadas: depois do bloco genérico (0.2.66), para só quem passa por ele ver "pausado".
    -- Antes, uma casa sem vínculo descobria que o profissional estava pausado.
    if v_pref.pausado_ate is not null and v_pref.pausado_ate >= (v_agora at time zone 'America/Sao_Paulo')::date then
      perform public.erro(422, 'profissional_indisponivel', 'pausado');
    end if;
  end if;

  -- Limites de par CD-C13 (B5d):
  -- 1. Se houve recusa há menos de 24h, o par está em pausa de 24h.
  if exists (
    select 1 from public.chamada c
     where c.estabelecimento_id = v_estab
       and c.profissional_id = v_prof
       and c.estado = 'recusada'
       and c.respondida_em > v_agora - interval '24 hours'
  ) then
    perform public.erro(422, 'profissional_indisponivel', 'par_em_pausa');
  end if;

  -- 2. Três recusadas/expiradas consecutivas em 30 dias bloqueiam o par por 30 dias
  select count(*) into v_ultimas_recusas
    from (
      select c.estado
        from public.chamada c
       where c.estabelecimento_id = v_estab
         and c.profissional_id = v_prof
         and c.criada_em > v_agora - interval '30 days'
         and c.estado in ('aceita', 'recusada', 'expirada')
       order by c.criada_em desc
       limit 3
    ) u
   where u.estado in ('recusada', 'expirada');

  if v_ultimas_recusas = 3 and not exists (
    select 1 from public.chamada c
     where c.estabelecimento_id = v_estab
       and c.profissional_id = v_prof
       and c.criada_em > v_agora - interval '30 days'
       and c.estado = 'aceita'
  ) then
    perform public.erro(422, 'profissional_indisponivel', 'par_bloqueado_temporariamente');
  end if;

  if chamar_profissional.vaga_id is not null then
    if num_nonnulls(chamar_profissional.funcao_id, chamar_profissional.inicio_em, chamar_profissional.fim_em,
                    chamar_profissional.local, chamar_profissional.ponto, chamar_profissional.valor_centavos) > 0 then
      perform public.erro(422, 'campo_invalido', 'vaga_id');
    end if;
    select * into v_vaga from public.vaga g where g.id = chamar_profissional.vaga_id and g.estabelecimento_id = v_estab;
    if not found then perform public.erro(404, 'nao_encontrado'); end if;
    if v_vaga.origem <> 'chamada_direta' or v_vaga.estado <> 'publicada' or v_vaga.inicio_em <= v_agora
       or not exists (select 1 from public.posicao p where p.vaga_id = v_vaga.id and p.estado = 'aberta') then
      perform public.erro(409, 'vaga_encerrada');
    end if;
    if (select count(*) from public.chamada c where c.vaga_id = v_vaga.id and c.estado = 'aberta') >= 3 then
      perform public.erro(422, 'limite_de_chamadas', 'por_vaga');
    end if;
  else
    -- RN02 com os nomes de NovaVaga: o primeiro campo que falta vai em details.
    select k into v_falta
      from jsonb_each(jsonb_build_object(
             'funcao_id', chamar_profissional.funcao_id, 'inicio_em', chamar_profissional.inicio_em,
             'fim_em', chamar_profissional.fim_em, 'local', nullif(btrim(chamar_profissional.local), ''),
             'regiao_administrativa', nullif(btrim(chamar_profissional.regiao_administrativa), ''),
             'ponto', chamar_profissional.ponto, 'valor_centavos', chamar_profissional.valor_centavos,
             'inclui_refeicao', chamar_profissional.inclui_refeicao,
             'inclui_transporte', chamar_profissional.inclui_transporte,
             'exige_material_proprio', chamar_profissional.exige_material_proprio,
             'responsavel_local', nullif(btrim(chamar_profissional.responsavel_local), ''))) e(k, val)
     where val = 'null'::jsonb order by k limit 1;
    if v_falta is not null then perform public.erro(422, 'campo_obrigatorio', v_falta); end if;
    if chamar_profissional.valor_centavos <= 0 then perform public.erro(422, 'campo_invalido', 'valor_centavos'); end if;
    if not exists (select 1 from public.funcao f where f.id = chamar_profissional.funcao_id) then
      perform public.erro(422, 'campo_invalido', 'funcao_id');
    end if;
    if chamar_profissional.fim_em <= chamar_profissional.inicio_em or chamar_profissional.inicio_em <= v_agora then
      perform public.erro(422, 'horario_invalido');
    end if;
    perform privado.exigir_texto_aceitavel(jsonb_build_object(
      'local', btrim(chamar_profissional.local), 'regiao_administrativa', btrim(chamar_profissional.regiao_administrativa),
      'responsavel_local', btrim(chamar_profissional.responsavel_local)));
    v_vaga.funcao_id := chamar_profissional.funcao_id;
    v_vaga.inicio_em := chamar_profissional.inicio_em;
  end if;

  if not exists (select 1 from public.profissional_funcao pf
                  where pf.profissional_id = v_prof and pf.funcao_id = v_vaga.funcao_id) then
    perform public.erro(422, 'inelegivel', 'funcao_incompativel');
  end if;

  -- Antecedência mínima respeitando a escolha do profissional (mínimo 2h)
  if v_vaga.inicio_em < v_agora + (v_ant_min_h || ' hours')::interval then
    perform public.erro(422, 'profissional_indisponivel', 'antecedencia_insuficiente');
  end if;

  -- Limite do profissional: máximo 5 abertas
  if (select count(*) from public.chamada c where c.profissional_id = v_prof and c.estado = 'aberta') >= 5 then
    perform public.erro(422, 'profissional_indisponivel', 'agenda_cheia');
  end if;

  -- Turnos verificados da casa (CD-C14)
  select count(*) into v_turnos_casa
    from public.turno t
    join public.posicao pos on pos.id = t.posicao_id
    join public.vaga vg on vg.id = pos.vaga_id
   where vg.estabelecimento_id = v_estab
     and pos.estado = 'cumprida'
     and t.verificacao = 'verificado';

  if v_turnos_casa = 0 then
    -- Casa sem turno cumprido: máximo 3 abertas e máximo 5 em 7 dias
    if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab and c.estado = 'aberta') >= 3 then
      perform public.erro(422, 'limite_de_chamadas', 'abertas');
    end if;
    if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab
           and c.criada_em > v_agora - interval '7 days') >= 5 then
      perform public.erro(422, 'limite_de_chamadas', 'por_semana');
    end if;
  else
    -- Casa com turnos: máximo 10 abertas e 20 por dia civil de SP
    if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab and c.estado = 'aberta') >= 10 then
      perform public.erro(422, 'limite_de_chamadas', 'abertas');
    end if;
    if (select count(*) from public.chamada c where c.estabelecimento_id = v_estab
           and (c.criada_em at time zone 'America/Sao_Paulo')::date = (v_agora at time zone 'America/Sao_Paulo')::date) >= 20 then
      perform public.erro(422, 'limite_de_chamadas', 'por_dia');
    end if;
  end if;

  if v_recado is not null then
    if length(v_recado) > 300 then perform public.erro(422, 'campo_invalido', 'recado'); end if;
    perform privado.exigir_texto_aceitavel(jsonb_build_object('recado', v_recado));
  end if;

  -- J7, RN45: a 3ª chamada de casa CPF ao mesmo profissional em 7 dias pede confirmação explícita.
  if length(v_casa_doc) = 11
     and not coalesce(chamar_profissional.confirmo_recorrencia, false)
     and (select count(*) from public.chamada c where c.estabelecimento_id = v_estab
             and c.profissional_id = v_prof and c.criada_em > v_agora - interval '7 days') >= 2 then
    perform public.erro(409, 'recorrencia_nao_confirmada');
  end if;

  -- Cálculo de prazos e lembretes respeitando horário de silêncio em America/Sao_Paulo (B5c)
  v_hora_sp := extract(hour from (v_agora at time zone 'America/Sao_Paulo'))::int;
  if v_hora_sp >= 22 or v_hora_sp < 7 then
    -- No silêncio (22h às 7h): conta a partir das 7h
    v_inicio_prazo := ((v_agora at time zone 'America/Sao_Paulo')::date +
                       (case when v_hora_sp >= 22 then interval '1 day 7 hours' else interval '7 hours' end))
                      at time zone 'America/Sao_Paulo';
    -- Salvo se início da vaga for antes das 10h em SP
    if v_vaga.inicio_em < (v_inicio_prazo + interval '3 hours') then
      v_expira_em := v_vaga.inicio_em - interval '1 hour';
    else
      v_expira_em := least(v_inicio_prazo + interval '12 hours', v_vaga.inicio_em - interval '1 hour');
    end if;
  else
    -- Fora do silêncio
    v_inicio_prazo := v_agora;
    v_expira_em := least(v_agora + interval '12 hours', v_vaga.inicio_em - interval '1 hour');
  end if;

  -- Lembrete: se janela efetiva de resposta for maior que 2h, agenda no ponto médio
  v_janela_efetiva := v_expira_em - v_inicio_prazo;
  if v_janela_efetiva > interval '2 hours' then
    v_lembrete_em := v_inicio_prazo + (v_janela_efetiva / 2);
    -- Se cair no silêncio (22h às 7h), ajusta para fora do silêncio
    if extract(hour from (v_lembrete_em at time zone 'America/Sao_Paulo'))::int >= 22 then
      v_lembrete_em := least(
        ((v_lembrete_em at time zone 'America/Sao_Paulo')::date + interval '21 hours 30 minutes') at time zone 'America/Sao_Paulo',
        v_expira_em - interval '30 minutes'
      );
      if v_lembrete_em <= v_inicio_prazo then
        v_lembrete_em := ((v_lembrete_em at time zone 'America/Sao_Paulo')::date + interval '1 day 7 hours') at time zone 'America/Sao_Paulo';
      end if;
    elsif extract(hour from (v_lembrete_em at time zone 'America/Sao_Paulo'))::int < 7 then
      v_lembrete_em := ((v_lembrete_em at time zone 'America/Sao_Paulo')::date + interval '7 hours') at time zone 'America/Sao_Paulo';
    end if;
    if v_lembrete_em >= v_expira_em then
      v_lembrete_em := null;
    end if;
  else
    v_lembrete_em := null;
  end if;

  if chamar_profissional.vaga_id is null then
    insert into public.vaga (
      estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa, ponto,
      valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
      responsavel_local, modo, publicado_por, publicado_em, chave_cliente, origem, regiao_id)
    values (
      v_estab, chamar_profissional.funcao_id, chamar_profissional.inicio_em, chamar_profissional.fim_em,
      btrim(chamar_profissional.local), btrim(chamar_profissional.regiao_administrativa),
      privado.ponto_do_json(chamar_profissional.ponto, 'ponto'), chamar_profissional.valor_centavos, 1,
      chamar_profissional.inclui_refeicao, chamar_profissional.inclui_transporte,
      chamar_profissional.exige_material_proprio, btrim(chamar_profissional.responsavel_local),
      'urgencia', v_uid, v_agora, chamar_profissional.chave, 'chamada_direta',
      chamar_profissional.regiao_id)
    returning * into v_vaga;
    insert into public.posicao (vaga_id, inicio_em, fim_em) values (v_vaga.id, v_vaga.inicio_em, v_vaga.fim_em);
  end if;

  begin
    insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, recado,
                                expira_em, lembrete_em, criada_em, chave)
    values (v_vaga.id, v_prof, v_estab, v_uid, v_recado,
            v_expira_em, v_lembrete_em, v_agora, chamar_profissional.chave)
    returning * into v_c;
  exception when unique_violation then
    perform public.erro(409, 'chamada_ja_aberta');
  end;

  -- Notificação chamada_recebida (B5c)
  insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
  values (v_conta.id, 'chamada_recebida', v_c.id, jsonb_build_object('chamada_id', v_c.id, 'vaga_id', v_vaga.id))
  on conflict do nothing;

  return to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em'];
end $$;

comment on function public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int) is
  '0.2.56 e 0.2.88. Chama um profissional direto (RN28, RN34, CD-C13): quem tem vínculo de trabalho com a casa ou, com a chave busca_profissionais ligada, quem está na busca ("Aceito chamadas diretas", sem pausa, com o serviço da função e a região do trabalho). regiao_id opcional, que a vaga direta guarda. As demais regras valem igual para os dois caminhos; quem não cumpre nenhum recebe a mesma recusa genérica (nao_aceita_chamadas).';
revoke execute on function public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int) from public, anon;
grant  execute on function public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int) to authenticated;
