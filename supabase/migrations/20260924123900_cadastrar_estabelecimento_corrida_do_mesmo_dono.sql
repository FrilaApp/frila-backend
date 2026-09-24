-- `cadastrar_estabelecimento`: o mesmo dono com dois pedidos no ar recebe o que criou.
--
-- A versão de 20260924004937 tratava toda `unique_violation` no insert como "outra
-- conta tomou o documento". Mas o caso mais comum de dois pedidos simultâneos com o
-- mesmo documento é o próprio dono: o app dá timeout e reenvia com o primeiro pedido
-- ainda no ar. O segundo passa pela leitura de idempotência antes de o primeiro
-- comitar, espera no índice único, e recebia 409 `documento_ja_cadastrado` — a mensagem
-- que diz ao dono que alguém tomou o CNPJ dele. Medido com duas conexões em
-- `scripts/corrida-cadastrar-estabelecimento.sh`.
--
-- A correção: depois da violação, ler a linha de novo. Em READ COMMITTED cada comando
-- tem snapshot novo, e a violação só acontece depois que o outro pedido comitou — então
-- a releitura enxerga o estabelecimento e o vínculo de membro, que entram no mesmo
-- commit. Quem chama e é membro recebe o estabelecimento, como no reenvio sequencial;
-- qualquer outro recebe o mesmo 409 de antes.
--
-- O insert em `membro_estabelecimento` não tem corrida própria: só chega nele quem
-- ganhou o índice único do documento, e o estabelecimento acabou de nascer — não há
-- segundo pedido que possa vincular alguém a ele antes deste commit.

create or replace function public.cadastrar_estabelecimento(
  nome      text,
  documento text,
  tipo      public.tipo_estabelecimento,
  endereco  text,
  ponto     jsonb
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_nome  text := btrim(cadastrar_estabelecimento.nome);
  v_end   text := btrim(cadastrar_estabelecimento.endereco);
  v_doc   text := cadastrar_estabelecimento.documento;
  v_ponto jsonb := cadastrar_estabelecimento.ponto;
  v_lat   double precision;
  v_lon   double precision;
  v_linha public.estabelecimento%rowtype;
  v_papel public.papel_membro;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  -- RN25: quem trabalha e quem contrata são contas diferentes.
  perform privado.exigir_perfil('contratante');

  if v_nome is null or v_nome = '' then
    perform public.erro(422, 'campo_obrigatorio', 'nome');
  end if;
  if v_doc is null or v_doc = '' then
    perform public.erro(422, 'campo_obrigatorio', 'documento');
  end if;
  if cadastrar_estabelecimento.tipo is null then
    perform public.erro(422, 'campo_obrigatorio', 'tipo');
  end if;
  if v_end is null or v_end = '' then
    perform public.erro(422, 'campo_obrigatorio', 'endereco');
  end if;

  -- A Coordenada do contrato: dois números, cada um no seu intervalo.
  if v_ponto is null
     or jsonb_typeof(v_ponto -> 'latitude')  is distinct from 'number'
     or jsonb_typeof(v_ponto -> 'longitude') is distinct from 'number' then
    perform public.erro(422, 'campo_obrigatorio', 'ponto');
  end if;
  v_lat := (v_ponto ->> 'latitude')::double precision;
  v_lon := (v_ponto ->> 'longitude')::double precision;
  if v_lat not between -90 and 90 or v_lon not between -180 and 180 then
    perform public.erro(422, 'campo_obrigatorio', 'ponto');
  end if;

  -- RF02. O cartão pede `campo_invalido`, que só existe a partir do contrato 0.2.2; o
  -- catálogo da 0.2.1 tem `campo_obrigatorio` com `details`, e é o que `criar_conta` já
  -- usa para o telefone fora do E.164. Quando o 0.2.2 entrar, muda esta linha.
  if not privado.documento_valido(v_doc) then
    perform public.erro(422, 'campo_obrigatorio', 'documento');
  end if;

  -- Idempotência pela chave natural, o documento. O mesmo membro reenviando recebe o
  -- estabelecimento que já existe; outra conta recebe o conflito, e só o conflito —
  -- nem o nome, nem quem administra.
  select * into v_linha from public.estabelecimento e where e.documento = v_doc;
  if found then
    select m.papel into v_papel
      from public.membro_estabelecimento m
     where m.estabelecimento_id = v_linha.id and m.usuario_id = v_uid;
    if found then
      return privado.estabelecimento_em_json(v_linha, v_papel);
    end if;
    perform public.erro(409, 'documento_ja_cadastrado');
  end if;

  begin
    insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
    values (v_nome, v_doc, cadastrar_estabelecimento.tipo, v_end,
            extensions.st_setsrid(extensions.st_makepoint(v_lon, v_lat), 4326)::extensions.geography)
    returning * into v_linha;
  exception
    when unique_violation then
      -- Outro pedido cadastrou o documento entre a leitura acima e este insert, e já
      -- comitou. Se foi o mesmo dono — o reenvio com o primeiro pedido ainda no ar —,
      -- a idempotência vale aqui também. Se foi outra conta, o conflito, e só ele.
      select e.* into v_linha from public.estabelecimento e where e.documento = v_doc;
      if found then
        select m.papel into v_papel
          from public.membro_estabelecimento m
         where m.estabelecimento_id = v_linha.id and m.usuario_id = v_uid;
        if found then
          return privado.estabelecimento_em_json(v_linha, v_papel);
        end if;
      end if;
      perform public.erro(409, 'documento_ja_cadastrado');
  end;

  -- RF21: o estabelecimento nasce com responsável. A chave estrangeira composta de
  -- `membro_estabelecimento` é a segunda trava de RN25, caso a primeira falhe.
  insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
  values (v_uid, v_linha.id, 'administrador');

  return privado.estabelecimento_em_json(v_linha, 'administrador');
end $$;

comment on function public.cadastrar_estabelecimento(text, text, public.tipo_estabelecimento, text, jsonb) is
  'Cria o estabelecimento com quem chama como administrador (RF02, RF21). Só conta de contratante (RN25). CPF ou CNPJ conferido pelo dígito verificador; o documento é a chave de idempotência, inclusive com dois pedidos simultâneos do mesmo dono.';

revoke execute on function public.cadastrar_estabelecimento(text, text, public.tipo_estabelecimento, text, jsonb)
  from public, anon;
grant  execute on function public.cadastrar_estabelecimento(text, text, public.tipo_estabelecimento, text, jsonb)
  to authenticated;
