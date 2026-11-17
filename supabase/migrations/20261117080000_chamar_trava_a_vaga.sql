-- chamar_profissional trava a vaga direta antes de conferir o estado dela (B-040, issue #543).
--
-- Com vaga_id (a 2ª e a 3ª chamada de um trabalho), a função lia a vaga sem trava. Junto de
-- cancelar_vaga, ela via a vaga "publicada" com posição aberta, esperava só na chave estrangeira do
-- insert da chamada e, solto o cancelamento, inseria a chamada: chamada ABERTA numa vaga CANCELADA,
-- que o gatilho vaga_cancelada_fecha_chamadas (20261117050000, #540) não alcança, porque ele só fecha
-- as chamadas que já existem. O par casa × profissional ficava preso (RN34) até ela vencer. Medido:
-- scripts/corrida-chamada.sh, cenário 7a, 4 de 4 rodadas antes desta migração.
--
-- Conserto: depois da conferência de sempre (sem trava), a vaga direta é relida FOR UPDATE e o estado
-- é conferido de novo. Vaga cancelada, encerrada, preenchida ou já começada recebe o 409 vaga_encerrada
-- que o contrato já define para o vaga_id (0.2.95: "vaga normal, preenchida ou encerrada é 409
-- vaga_encerrada"; a tabela de erros: "a vaga fechou, já começou ou foi cancelada"). Nenhum código novo.
--   - O cancelamento chegou antes: a chamada espera a vaga, relê a versão cancelada e recebe 409.
--   - A chamada chegou antes: o cancelamento espera a vaga, e o gatilho dele já enxerga a chamada nova
--     e a encerra.
--   - A conferência sem trava continua na frente: a vaga que já está fechada responde na hora, sem
--     esperar quem a segura. Só a vaga que parece aberta é travada.
--
-- Ordem de travas de chamar_profissional, com este conserto:
--   estabelecimento -> profissional -> vaga (FOR UPDATE, só a direta que parece aberta) -> [insert]
--   chamada -> usuario (chave estrangeira do aviso)
-- Por que não fecha ciclo com quem trava a vaga (lido nas versões vigentes, medido nos cenários 1 a 7):
--   - cancelar_vaga (20261117050000): vaga -> posições -> chamadas -> usuario. Não pega casa nem
--     profissional.
--   - responder_chamada (20261107350000): vaga -> chamada -> posição -> usuario, e a chave estrangeira
--     do profissional que confirma. Esse profissional tem chamada aberta na vaga, então a chamada
--     para ele recebe 409 chamada_ja_aberta antes de chegar à vaga.
--   - publicar_a_partir_da_chamada (20261117020000): casa -> vaga, a mesma direção, e serializada
--     pela trava da casa.
--   - excluir_conta (#525, 20261117010000): vagas -> chamadas -> usuario.
--   - cancelar_uma_posicao (20261108070000): vaga -> posição -> profissional (recalcular_comparecimento).
--     Ela só pega a vaga direta com posição confirmada, que a conferência sem trava já recusa; por isso
--     a trava fica depois dela e não no lugar dela.
--   Antes deste conserto a função já esperava a vaga com casa e profissional travados (a chave
--   estrangeira do insert pega FOR KEY SHARE), então a ordem casa -> profissional -> vaga não é nova;
--   muda o modo, que agora também espera quem atualiza a vaga.
--
-- Corpo copiado de 20261117020000 (a vigente: develop e PRs abertos, conferido com git grep), com só o
-- bloco "B-040" a mais e o comment on function. Assinatura, grants e resposta iguais.

select set_config('lock_timeout', '2s', true);

-- contrato: corpo-sem-mudanca-de-superficie public.chamar_profissional 0.2.95
create or replace function public.chamar_profissional(
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
  v_trab_funcao    uuid;
  v_trab_inicio    timestamptz;
  v_trab_fim       timestamptz;
  v_trab_aberto    uuid;
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

  -- I6 (contrato 0.2.90): com a busca ligada e quem chama sem os Termos 1.1, a busca não conta como caminho.
  -- Sem turno cumprido com presença verificada nem equipe de confiança (fatos que a casa já conhece, e não a
  -- preferência do profissional), a recusa é termos_pendentes. Vem depois do bloqueio (404) e ANTES de qualquer
  -- conferência sobre o profissional, então não revela quem está na busca. Com turno ou equipe vale só o
  -- caminho do vínculo, com as recusas de sempre. Busca desligada: nunca sai.
  if privado.recurso_ligado('busca_profissionais')
     and not privado.aceitou_termos(v_uid, privado.termos_minimos_da_busca())
     and not exists (select 1 from public.turno t join public.posicao p on p.id = t.posicao_id
                       join public.vaga g on g.id = p.vaga_id
                      where g.estabelecimento_id = v_estab and p.profissional_id = v_prof
                        and p.estado = 'cumprida' and t.verificacao = 'verificado')
     and not exists (select 1 from public.equipe_confianca q
                      where q.estabelecimento_id = v_estab and q.profissional_id = v_prof) then
    perform public.erro(403, 'sem_permissao', 'termos_pendentes');
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
  -- 0.2.95: a chave de novo, agora sob a trava da casa. Um envio simultâneo da mesma chave esperou a
  -- trava e enxerga a chamada que o outro criou: devolve a mesma, e não 409 chamada_ja_aberta.
  select * into v_c from public.chamada c where c.estabelecimento_id = v_estab and c.chave = chamar_profissional.chave;
  if found then return to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em']; end if;
  if exists (select 1 from public.chamada c where c.estabelecimento_id = v_estab
                and c.profissional_id = v_prof and c.estado = 'aberta') then
    perform public.erro(409, 'chamada_ja_aberta');
  end if;

  -- 0.2.95: um trabalho, uma vaga direta. Sob a trava da casa (acima), então a 2ª chamada simultânea
  -- para o mesmo trabalho já enxerga a vaga e a chamada da 1ª. Depende só das vagas e chamadas da
  -- casa e vem antes de qualquer conferência sobre o profissional: não revela nada dele. Sem a
  -- função e o horário (campo faltando, vaga de outra casa ou vaga normal), seguem as recusas de
  -- sempre, mais abaixo.
  if chamar_profissional.vaga_id is not null then
    select g.funcao_id, g.inicio_em, g.fim_em into v_trab_funcao, v_trab_inicio, v_trab_fim
      from public.vaga g
     where g.id = chamar_profissional.vaga_id and g.estabelecimento_id = v_estab and g.origem = 'chamada_direta';
  else
    v_trab_funcao := chamar_profissional.funcao_id;
    v_trab_inicio := chamar_profissional.inicio_em;
    v_trab_fim    := chamar_profissional.fim_em;
  end if;
  if num_nulls(v_trab_funcao, v_trab_inicio, v_trab_fim) = 0 then
    select g.id into v_trab_aberto
      from public.vaga g
     where g.estabelecimento_id = v_estab
       and g.origem = 'chamada_direta' and g.estado = 'publicada'
       and g.funcao_id = v_trab_funcao
       and date_trunc('minute', g.inicio_em) = date_trunc('minute', v_trab_inicio)
       and date_trunc('minute', g.fim_em) = date_trunc('minute', v_trab_fim)
       and g.inicio_em > v_agora
       and exists (select 1 from public.posicao p where p.vaga_id = g.id and p.estado = 'aberta')
       and exists (select 1 from public.chamada c
                    where c.vaga_id = g.id and c.estado = 'aberta' and c.expira_em > v_agora)
     order by g.publicado_em, g.id
     limit 1;
    -- Sem vaga_id, ou com o de outra vaga do mesmo trabalho (inclusive já preenchida ou encerrada:
    -- vem antes de 409 vaga_encerrada), a chamada só pode entrar no trabalho aberto.
    if v_trab_aberto is not null and v_trab_aberto is distinct from chamar_profissional.vaga_id then
      perform public.erro(409, 'trabalho_ja_aberto', v_trab_aberto::text);
    end if;
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
    -- B-040 (#543): a vaga que parece aberta é relida travada e conferida de novo. Um cancelamento
    -- (ou um aceite) que a segurava terminou antes: vale o estado que ele deixou. Depois das travas
    -- da casa e do profissional, a ordem do cabeçalho da migração 20261117080000.
    select * into v_vaga from public.vaga g where g.id = v_vaga.id for update;
    if v_vaga.estado <> 'publicada' or v_vaga.inicio_em <= v_agora
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
  '0.2.56, 0.2.88 e 0.2.90. Chama um profissional direto (RN28, RN34, CD-C13): quem tem vínculo de trabalho com a casa ou, com a chave busca_profissionais ligada, quem está na busca ("Aceito chamadas diretas", sem pausa, com o serviço da função e a região do trabalho). Pelo caminho da busca (sem vínculo), só quem aceitou os Termos 1.1: 403 sem_permissao, termos_pendentes. regiao_id opcional, que a vaga direta guarda. As demais regras valem igual para os dois caminhos; quem não cumpre nenhum recebe a mesma recusa genérica (nao_aceita_chamadas). 0.2.95: com trabalho aberto igual na casa (mesma função, início e fim até o minuto, vaga direta com chamada aberta e no prazo), a chamada sem vaga_id ou com o de outra vaga do mesmo trabalho recebe 409 trabalho_ja_aberto com o vaga_id dele em details; a chave é conferida de novo sob a trava da casa. B-040: com vaga_id, a vaga direta é relida FOR UPDATE e o estado conferido depois da trava (vaga cancelada no meio: 409 vaga_encerrada).';
revoke execute on function public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int) from public, anon;
grant  execute on function public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int) to authenticated;
