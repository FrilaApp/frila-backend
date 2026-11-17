-- vaga_publica: a vaga pelo link, sem login (contrato 0.2.100, web B5, pedido 2026-11-16-31).
--
-- A página pública de uma vaga (frilabr.com/app) chama esta função só com a chave publicável. É a
-- segunda rotina de `public` executável por `anon` (a primeira é configuracao_do_app), e por isso o
-- corpo é uma lista fechada:
--   - sai só o esquema VagaPublica: função, região (o nome do catálogo, ou null), início, fim, valor,
--     publicado_em, inclusos, modo, posições abertas e estado. Nunca o estabelecimento, o local, o
--     ponto, quem recebe, o traje, as observações, quem publicou nem dado de candidato;
--   - só a vaga normal (origem `publicacao`), visível no app e de conta real. Vaga direta, vaga
--     ocultada pela Equipe Frila, vaga de conta de demonstração, id que não é uuid e vaga que não
--     existe respondem o MESMO 404 nao_encontrado, sem `details`: nada no corpo diz qual foi o caso;
--   - o parâmetro é `text`, para o que não for uuid cair nesse 404 em vez do 400 22P02 do PostgREST;
--   - `stable`: é GET no contrato, e o PostgREST roda o GET em transação só de leitura;
--   - fora dos 404, responde 200 com o estado real (preenchida, encerrada, cancelada ou já passada):
--     o link antigo diz que a vaga fechou em vez de parecer quebrado.
-- Sem bloqueio (RF26): sem sessão não há quem bloquear, e com sessão a resposta é a mesma (decisão
-- do jurídico do time, 16/11/2026, na descrição da operação).

create function public.vaga_publica(vaga_id text)
returns jsonb
language plpgsql
stable
security definer set search_path = ''
as $$
declare
  v_id uuid;
  v    public.vaga%rowtype;
  v_f  public.funcao%rowtype;
begin
  -- Qualquer forma que o Postgres aceita como uuid vale; o resto é o 404 de vaga inexistente.
  begin
    v_id := vaga_publica.vaga_id::uuid;
  exception when invalid_text_representation then
    v_id := null;
  end;
  if v_id is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  select * into v from public.vaga g where g.id = v_id;

  -- Lista de permissão, e não de proibição: uma origem nova nasce fora da página pública. A conta
  -- que publicou tem de existir e ser real (a vaga herda a marca de demonstração dela).
  if not found
     or v.origem <> 'publicacao'
     or privado.vaga_oculta(v.id)
     or not exists (select 1 from public.usuario u
                     where u.id = v.publicado_por and not u.demonstracao) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  select * into v_f from public.funcao f where f.id = v.funcao_id;

  return jsonb_build_object(
    'id',                    v.id,
    'funcao',                privado.funcao_em_json(v_f.*),
    'regiao_administrativa', (select r.nome from public.regiao_administrativa r
                               where r.nome = v.regiao_administrativa and r.ativo),
    'inicio_em',             v.inicio_em,
    'fim_em',                v.fim_em,
    'valor_centavos',        v.valor_centavos,
    'publicado_em',          v.publicado_em,
    'inclusos',              privado.inclusos_em_json(v.*),
    'modo',                  v.modo,
    'posicoes_abertas',      privado.posicoes_candidataveis(v.id, privado.agora()),
    'estado',                v.estado);
end $$;

comment on function public.vaga_publica(text) is
  'Vaga pelo link, sem login (contrato 0.2.100). Só os campos de VagaPublica: sem estabelecimento, endereço, ponto, texto livre nem dado de pessoa. Vaga direta, oculta, de conta de demonstração, id que não é uuid e vaga inexistente: o mesmo 404 nao_encontrado. Fora disso, 200 com o estado real.';

revoke execute on function public.vaga_publica(text) from public;
grant  execute on function public.vaga_publica(text) to anon, authenticated;
