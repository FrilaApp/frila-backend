-- `republicar_vaga`: o bar que chama freela toda sexta não redigita a vaga.
--
-- RF05, US05, cartão `RTmRTHbo`. Copia todos os campos da vaga de origem e muda só início
-- e fim.
--
-- ── Por que ela delega, e não repete ──────────────────────────────────────────────────
--
-- O contrato é literal: *"Copia todos os campos da vaga de origem e muda só início e fim
-- (RF05). **Mesmas recusas de `publicar_vaga`**"* (`openapi.yaml:1058`).
--
-- "Mesmas recusas" escrito à mão é promessa que envelhece. `publicar_vaga` tem quinze
-- conferências de campo obrigatório, quatro de campo inválido, o filtro de texto da
-- diretriz 1.2, o relógio do produto e a corrida da chave. Copiar esse bloco para cá
-- criaria duas listas que começam iguais e divergem no primeiro cartão que mexer numa
-- delas — e a divergência só apareceria no aparelho de alguém.
--
-- Então esta função faz três coisas e entrega o resto: acha a vaga de origem, confere se
-- quem chama é da casa, e chama `public.publicar_vaga` com os campos copiados e as datas
-- novas. Recusa nova em `publicar_vaga` passa a valer aqui no mesmo commit, de graça.
--
-- ── O que ela confere antes de delegar ────────────────────────────────────────────────
--
-- A ordem importa, e é a mesma lógica das outras leituras do produto: vaga que não existe
-- é `404`, vaga que existe e não é sua é `403`. O cartão pede o 403 por escrito, e o 404
-- não vaza existência para quem nem é contratante — quem não tem perfil de contratante é
-- barrado antes, pela própria `publicar_vaga`... exceto que aqui precisamos ler a vaga
-- primeiro. Por isso o perfil é conferido **antes** da leitura: um profissional não
-- descobre, pelo código de erro, se aquela vaga existe.

create or replace function public.republicar_vaga(
  vaga_id   uuid,
  inicio_em timestamptz,
  fim_em    timestamptz,
  chave     uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_origem public.vaga%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- Antes da leitura, de propósito: assim o profissional recebe `perfil_incompativel`
  -- em vez de um 404 ou 403 que diria se a vaga existe.
  perform privado.exigir_perfil('contratante');

  if republicar_vaga.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  select * into v_origem from public.vaga g where g.id = republicar_vaga.vaga_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- A vaga existe e não é da casa de quem chama. O cartão pede 403 aqui, e faz sentido:
  -- quem republica veio da própria lista de vagas, então a existência já não é segredo
  -- para ele — e um 404 mandaria a tela dizer "essa vaga sumiu" quando o problema é
  -- outro.
  if not privado.eh_membro(v_origem.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- O `ponto` volta para JSON porque é assim que `publicar_vaga` o recebe, e é ela quem
  -- valida a faixa de latitude e longitude. A ida e volta é exata: `geography` guarda as
  -- duas coordenadas que entraram.
  --
  -- `alerta_antecedencia` é `interval` na tabela e minutos na RPC, e a conversão é aqui
  -- pelo mesmo motivo.
  --
  -- `evento_id` **não** é copiado: `publicar_vaga` não o recebe, então nenhuma vaga
  -- publicada pelo app tem evento hoje. Está registrado como divergência no
  -- `docs/ESTADO.md` para não parecer esquecimento quando o evento existir.
  return public.publicar_vaga(
    estabelecimento_id     => v_origem.estabelecimento_id,
    funcao_id              => v_origem.funcao_id,
    inicio_em              => republicar_vaga.inicio_em,
    fim_em                 => republicar_vaga.fim_em,
    local                  => v_origem.local,
    ponto                  => jsonb_build_object(
                                'latitude',  extensions.ST_Y(v_origem.ponto::extensions.geometry),
                                'longitude', extensions.ST_X(v_origem.ponto::extensions.geometry)),
    valor_centavos         => v_origem.valor_centavos,
    posicoes               => v_origem.posicoes,
    inclui_refeicao        => v_origem.inclui_refeicao,
    inclui_transporte      => v_origem.inclui_transporte,
    exige_material_proprio => v_origem.exige_material_proprio,
    responsavel_local      => v_origem.responsavel_local,
    modo                   => v_origem.modo,
    chave                  => republicar_vaga.chave,
    traje                  => v_origem.traje,
    participa_rateio       => v_origem.participa_rateio,
    observacoes            => v_origem.observacoes,
    alerta_antecedencia_min => (extract(epoch from v_origem.alerta_antecedencia) / 60)::int);
end $$;

comment on function public.republicar_vaga(uuid, timestamptz, timestamptz, uuid) is
  'Republica uma vaga anterior com data e horário novos, copiando o resto (RF05, US05). Só membro do estabelecimento da vaga de origem. Delega a public.publicar_vaga, e por isso tem exatamente as mesmas recusas.';

revoke execute on function public.republicar_vaga(uuid, timestamptz, timestamptz, uuid)
  from public, anon;
grant  execute on function public.republicar_vaga(uuid, timestamptz, timestamptz, uuid)
  to authenticated;
