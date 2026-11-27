-- Z0HbaZ0P (acréscimo): `public.detalhe_vaga` passa a devolver `origem` e `vaga_origem_id` (`Vaga.origem` e `Vaga.vaga_origem_id`, contrato
-- 0.2.55 e 0.2.56, ambos opcionais). A definição vigente (20261107300000_chamada_direta_vaga.sql) não os incluía: o app lia a vaga direta
-- e a vaga republicada a partir dela como publicação comum. Irmã de 20261127070000 (painel_estabelecimento, mesma família).
--
-- Corpo de 20261107300000 com duas chaves a mais no fim do objeto. Assinatura, `security definer set search_path = ''`, as recusas e os
-- grants não mudam. `vaga_origem_id` sai nulo na vaga que não nasceu de uma direta, e o schema aceita nulo.
--
-- Não muda a superfície: o contrato já declara os dois campos.
-- contrato: corpo-sem-mudanca-de-superficie public.detalhe_vaga 0.2.118

create or replace function public.detalhe_vaga(vaga_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid  uuid := (select auth.uid());
  v_ref  extensions.geography;
  v_demo boolean;
  v      public.vaga%rowtype;
  v_f    public.funcao%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if detalhe_vaga.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  v_demo := privado.conta_de_demonstracao();

  select * into v from public.vaga g where g.id = detalhe_vaga.vaga_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Vaga direta (0.2.55): 404 indistinguível de inexistente para quem não é da casa nem
  -- ocupa a posição. O profissional chamado, antes do aceite, lê só por detalhe_chamada.
  if v.origem = 'chamada_direta'
     and not privado.eh_membro(v.estabelecimento_id)
     and not privado.ocupa_posicao_na_vaga(v.id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if not exists (select 1 from public.usuario u
                  where u.id = v.publicado_por and u.demonstracao = v_demo) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if privado.bloqueado_com_estabelecimento(v_uid, v.estabelecimento_id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Ocultada pela Equipe Frila: some para quem procura turno. Quem já está nela (o
  -- confirmado segue confirmado, a candidatura segue pendente) ainda a abre, com
  -- `oculta: true` (contrato 0.2.23).
  if privado.vaga_oculta(v.id)
     and not privado.ocupa_posicao_na_vaga(v.id)
     and not privado.candidatou_na_vaga(v.id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  select * into v_f from public.funcao f where f.id = v.funcao_id;

  select p.ponto_base into v_ref from public.profissional p where p.usuario_id = v_uid;

  return jsonb_build_object(
    'id',                    v.id,
    'estabelecimento',       privado.estabelecimento_publico(v.estabelecimento_id),
    'funcao',                privado.funcao_em_json(v_f.*),
    'inicio_em',             v.inicio_em,
    'fim_em',                v.fim_em,
    'local',                 v.local,
    'regiao_administrativa', v.regiao_administrativa,
    'ponto',                 privado.ponto_em_json(v.ponto),
    'distancia_km',          case when v_ref is null then null
                                  else round((extensions.st_distance(v.ponto, v_ref) / 1000)::numeric, 2) end,
    'valor_centavos',        v.valor_centavos,
    'posicoes',              v.posicoes,
    'posicoes_abertas',      privado.posicoes_candidataveis(v.id, privado.agora()),
    'inclusos',              privado.inclusos_em_json(v.*),
    'responsavel_local',     v.responsavel_local,
    'traje',                 v.traje,
    'participa_rateio',      v.participa_rateio,
    'observacoes',           v.observacoes,
    'modo',                  v.modo,
    'estado',                v.estado,
    'oculta',                privado.vaga_oculta(v.id),
    'publicado_em',          v.publicado_em,
    -- 0.2.55 / 0.2.56 (Vaga.origem, Vaga.vaga_origem_id): de onde a vaga nasceu e, na vaga normal criada a partir de uma direta, o id da direta.
    'origem',                v.origem,
    'vaga_origem_id',        v.vaga_origem_id);
end $$;

comment on function public.detalhe_vaga(uuid) is
  'Detalhe da vaga para quem ainda não se candidatou (RF04, UC03). Sem documento e sem contato (RN10). Vaga escondida por bloqueio ou por demonstração responde 404, e não 403: o 403 confirmaria que ela existe. Depois do início, posicoes_abertas conta só as reabertas por atraso dentro do prazo (contrato 0.2.19). Expõe regiao_administrativa no schema Vaga / VagaDetalhe. Vaga direta (origem chamada_direta, 0.2.55): 404 a quem não é da casa nem ocupa a posição. Desde 0.2.55 traz origem e vaga_origem_id.';

revoke execute on function public.detalhe_vaga(uuid) from public, anon;
grant  execute on function public.detalhe_vaga(uuid) to authenticated;
