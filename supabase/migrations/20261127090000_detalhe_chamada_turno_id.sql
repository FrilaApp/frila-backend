-- lWuOxMAQ: `public.detalhe_chamada` passa a devolver `turno_id` na chamada aceita (`ChamadaDetalhe.turno_id`, contrato 0.2.56).
--
-- O contrato declara `turno_id` em `ChamadaDetalhe`, mas o ramo `estado = 'aceita'` da definição vigente (20261109150000) só acrescentava
-- `local`, `ponto` e `responsavel_local`. Quem abre a chamada aceita (o "Ver turno" do app) ficava sem o turno que o aceite criou.
--
-- Corpo de 20261109150000 com uma consulta e uma chave a mais no ramo `aceita`: o turno da posição da vaga ocupada pelo profissional da
-- chamada, a mesma busca que `responder_chamada` faz ao devolver `turno_id`. Sem turno achado a chave não sai. Nos outros estados (aberta,
-- recusada, expirada, cancelada, encerrada) nada muda. Assinatura, `security definer set search_path = ''`, recusas e grants não mudam.
--
-- Não muda a superfície: o contrato já declara o campo.
-- contrato: corpo-sem-mudanca-de-superficie public.detalhe_chamada 0.2.118

create or replace function public.detalhe_chamada(chamada_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid         uuid := (select auth.uid());
  v_c           public.chamada%rowtype;
  v_v           public.vaga%rowtype;
  v_f           public.funcao%rowtype;
  v_e           public.estabelecimento%rowtype;
  v_prof        public.profissional%rowtype;
  v_eh_prof     boolean := false;
  v_eh_membro   boolean := false;
  v_dist_m      double precision;
  v_faixa       text := null;
  v_conta_nova  boolean;
  v_outra_parte jsonb;
  v_res         jsonb;
  v_turno_id    uuid;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
  -- Conta anonimizada (excluída) é 401 e suspensa é 403, pela mesma porta das outras RPCs (RF25,
  -- RN13). O JWT pode seguir válido depois da exclusão: a recusa tem de vir do banco.
  perform privado.exigir_conta_ativa();
  if detalhe_chamada.chamada_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'chamada_id');
  end if;

  select * into v_c from public.chamada where id = detalhe_chamada.chamada_id;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;

  select * into v_v from public.vaga where id = v_c.vaga_id;
  select * into v_f from public.funcao where id = v_v.funcao_id;
  select * into v_e from public.estabelecimento where id = v_c.estabelecimento_id;
  select * into v_prof from public.profissional where id = v_c.profissional_id;

  if v_prof.usuario_id = v_uid then v_eh_prof := true; end if;
  if privado.eh_membro(v_c.estabelecimento_id) then v_eh_membro := true; end if;

  -- Apenas as partes autorizadas e sem bloqueio mútuo (RF26)
  if (not v_eh_prof and not v_eh_membro)
     or privado.bloqueado_com_estabelecimento(v_prof.usuario_id, v_c.estabelecimento_id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Conta nova se estabelecimento não tem turnos cumpridos/verificados
  v_conta_nova := not exists (
    select 1 from public.turno t
      join public.posicao pos on pos.id = t.posicao_id
      join public.vaga vg on vg.id = pos.vaga_id
     where vg.estabelecimento_id = v_c.estabelecimento_id
       and pos.estado = 'cumprida'
       and t.verificacao = 'verificado'
  );

  if v_eh_prof then
    v_outra_parte := privado.estabelecimento_publico(v_c.estabelecimento_id)
                     || privado.foto_de_perfil_projecao(null, v_c.estabelecimento_id, v_uid);
    if v_prof.ponto_base is not null and v_v.ponto is not null then
      v_dist_m := extensions.st_distance(v_prof.ponto_base, v_v.ponto);
      if v_dist_m <= 5000 then v_faixa := 'ate_5_km';
      elsif v_dist_m <= 15000 then v_faixa := 'de_5_a_15_km';
      else v_faixa := 'mais_de_15_km'; end if;
    end if;
  else
    v_outra_parte := privado.perfil_publico_profissional(v_c.profissional_id)
                     || privado.foto_de_perfil_projecao(v_c.profissional_id, null, v_uid);
  end if;

  v_res := jsonb_build_object(
    'id',                     v_c.id,
    'vaga_id',                v_c.vaga_id,
    'profissional_id',        v_c.profissional_id,
    'estabelecimento_id',     v_c.estabelecimento_id,
    'estado',                 v_c.estado,
    'recado',                 v_c.recado,
    'motivo_recusa',          v_c.motivo_recusa,
    'expira_em',              v_c.expira_em,
    'respondida_em',          v_c.respondida_em,
    'criada_em',              v_c.criada_em,
    'funcao',                 jsonb_build_object('id', v_f.id, 'nome', v_f.nome, 'categoria', v_f.categoria),
    'inicio_em',              v_v.inicio_em,
    'fim_em',                 v_v.fim_em,
    'valor_centavos',         v_v.valor_centavos,
    'outra_parte',            v_outra_parte,
    'tipo_estabelecimento',   v_e.tipo,
    'conta_nova',             v_conta_nova,
    'regiao_administrativa',  v_v.regiao_administrativa,
    'distancia_faixa',        v_faixa,
    'inclui_refeicao',        v_v.inclui_refeicao,
    'inclui_transporte',      v_v.inclui_transporte,
    'exige_material_proprio', v_v.exige_material_proprio
  );

  -- Endereço e ponto só liberados com estado = 'aceita' (RN36). Nunca telefone.
  if v_c.estado = 'aceita' then
    -- O turno que o aceite criou na posição da vaga (o mesmo `turno_id` que `responder_chamada` devolveu, 0.2.56).
    select t.id into v_turno_id
      from public.turno t
      join public.posicao pos on pos.id = t.posicao_id
     where pos.vaga_id = v_c.vaga_id and pos.profissional_id = v_c.profissional_id
     limit 1;
    v_res := v_res || jsonb_build_object(
      'local',             v_v.local,
      'ponto',             privado.ponto_em_json(v_v.ponto),
      'responsavel_local', v_v.responsavel_local
    ) || case when v_turno_id is not null then jsonb_build_object('turno_id', v_turno_id) else '{}'::jsonb end;
  end if;

  return v_res;
end $$;

comment on function public.detalhe_chamada(uuid) is
  'A chamada por inteiro (0.2.56), para as duas partes. A outra parte vem com foto_url/foto_id (0.2.54) quando as condições de perfil_publico valem. Na chamada aceita traz local, ponto, responsavel_local e turno_id.';
