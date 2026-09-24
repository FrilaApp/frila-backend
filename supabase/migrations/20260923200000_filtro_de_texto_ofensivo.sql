-- Filtro de texto ofensivo nos campos livres (diretriz 1.2 da App Store).
--
-- A diretriz 1.2 pede, para conteúdo gerado por usuário, um filtro do que é publicado,
-- além de denunciar e bloquear — que já existem. A vaga tem texto livre visto por todo
-- o DF, e o nome da conta aparece para a contraparte no turno.
--
-- ── O que este filtro é, e o que ele não é ────────────────────────────────────
--
-- É uma lista de termos conferida na escrita, com palavra inteira. Não é moderação, não
-- detecta contexto e não tenta vencer quem quer burlar: quem escreve `m3rda` passa, e
-- passar é o desenho. Um filtro que persegue variação de grafia vira um filtro que
-- recusa nome de gente, e o custo dos dois erros não é o mesmo — texto ofensivo que
-- escapa tem denúncia e bloqueio atrás dele (RF26), enquanto quem não consegue se
-- cadastrar simplesmente vai embora.
--
-- O alvo é o que a diretriz pede: impedir que o óbvio seja publicado sem ninguém olhar.
--
-- ── Por que palavra inteira, e não `like '%termo%'` ──────────────────────────
--
-- Porque `cu` está dentro de Cunha, Cuiabá, curso e cuidado. Um filtro por substring
-- recusaria "Ana Cunha" no cadastro, e o teste `100_filtro_de_texto.sql` fixa esse caso
-- para que ninguém o reintroduza achando que está apertando a segurança.

-- ── Normalização ──────────────────────────────────────────────────────────────
--
-- Minúsculas, sem acento, e tudo o que não é letra ou dígito vira espaço.
--
-- `translate` e não a extensão `unaccent`: 24 caracteres resolvem o português, e
-- `unaccent` traria uma extensão, um dicionário e uma função que só é `IMMUTABLE` na
-- forma de dois argumentos — detalhe que já rendeu rótulo de volatilidade mentiroso
-- neste repositório e foi pego pelo lint.
--
-- A troca de pontuação por espaço, e não por vazio, é o que impede `abc.def` de virar
-- `abcdef` e casar com um termo que nenhuma das duas palavras contém.

create or replace function privado.normalizar(t text) returns text
language sql
immutable
strict
set search_path = ''
as $$
  select pg_catalog.btrim(
           pg_catalog.regexp_replace(
             pg_catalog.translate(
               pg_catalog.lower(t),
               'áàâãäéèêëíìîïóòôõöúùûüçñ',
               'aaaaaeeeeiiiiooooouuuucn'),
             '[^a-z0-9]+', ' ', 'g'))
$$;

comment on function privado.normalizar(text) is
  'Minúsculas, sem acento, pontuação virando espaço. A forma em que o texto e os termos da lista são comparados.';

create table privado.termo_bloqueado (
  -- Guardado já normalizado, e o CHECK garante isso. Termo com acento ou maiúscula na
  -- tabela nunca casaria com nada: a comparação acontece sobre o texto normalizado dos
  -- dois lados, e um termo mal gravado falharia em silêncio — que é o pior defeito
  -- possível num filtro, porque ele parece instalado.
  termo         text primary key,
  categoria     text not null,
  adicionado_em timestamptz not null default now(),

  constraint termo_normalizado check (termo = privado.normalizar(termo)),
  constraint termo_nao_vazio    check (length(termo) >= 2)
);

comment on table privado.termo_bloqueado is
  'Lista de termos recusados nos campos livres (diretriz 1.2 da App Store). Comparação por palavra inteira sobre o texto normalizado. Fora da API: o schema privado não é exposto pelo PostgREST.';
comment on column privado.termo_bloqueado.categoria is
  'Para que a lista possa ser revista por grupo, e para que a remoção de um termo seja uma decisão com contexto.';

-- ── O filtro ──────────────────────────────────────────────────────────────────
--
-- Cerca o texto e o termo com espaços antes de comparar. É o que torna a comparação de
-- palavra inteira sem depender de expressão regular — e sem depender de que nenhum
-- termo da lista contenha um metacaractere, que seria mais uma coisa para alguém
-- lembrar de conferir ao acrescentar um termo.
--
-- Texto nulo ou vazio é aceitável: campo obrigatório é assunto de `campo_obrigatorio`,
-- e um filtro que também recusa ausência devolveria o código errado.

create or replace function privado.texto_aceitavel(t text) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
    select 1
      from privado.termo_bloqueado b
     where (' ' || privado.normalizar(coalesce(t, '')) || ' ')
           like ('% ' || b.termo || ' %')
  )
$$;

comment on function privado.texto_aceitavel(text) is
  'Falso quando o texto contém, como palavra inteira, um termo de privado.termo_bloqueado. Nulo e vazio são aceitáveis: ausência é assunto de campo_obrigatorio.';

-- ── criar_conta passa a conferir o nome ───────────────────────────────────────
--
-- Recusa com `campo_invalido` e `details = nome`, e não com `campo_obrigatorio`: o
-- campo veio, o valor é que não serve. A tela destaca o mesmo campo e mostra texto
-- diferente, e o contrato 0.2.3 registra o código.
--
-- A conferência vem **depois** da de tamanho, para que um nome vazio continue saindo
-- como `campo_obrigatorio`. A ordem das recusas é parte do contrato: dois motivos
-- diferentes para o mesmo campo têm de sair estáveis.
--
-- `publicar_vaga` e `republicar_vaga` chamam o mesmo filtro em `traje`, `observacoes` e
-- `responsavel_local` quando forem escritas, no Sprint 1. `cadastrar_estabelecimento`
-- também não existe ainda. Este cartão entrega o mecanismo e o primeiro ponto de uso;
-- os outros nascem já chamando, e a recusa de cada um fica no critério de aceite do
-- cartão que o criar.

create or replace function public.criar_conta(
  perfil        public.perfil_conta,
  nome          text,
  telefone      text,
  nascimento    date,
  termos_versao text
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_email text;
  v_linha public.usuario%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  select * into v_linha from public.usuario u where u.id = v_uid;
  if found then
    if v_linha.perfil is distinct from criar_conta.perfil then
      perform public.erro(409, 'conta_existente', 'perfil_divergente');
    end if;
    return public.conta_em_json(v_linha);
  end if;

  if criar_conta.nome is null or length(btrim(criar_conta.nome)) < 2 then
    perform public.erro(422, 'campo_obrigatorio', 'nome');
  end if;

  -- Diretriz 1.2: o nome aparece para a contraparte no turno e no perfil público.
  if not privado.texto_aceitavel(criar_conta.nome) then
    perform public.erro(422, 'campo_invalido', 'nome');
  end if;

  if criar_conta.telefone is null then
    perform public.erro(422, 'campo_obrigatorio', 'telefone');
  end if;
  if criar_conta.nascimento is null then
    perform public.erro(422, 'campo_obrigatorio', 'nascimento');
  end if;
  if criar_conta.termos_versao is null or btrim(criar_conta.termos_versao) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'termos_versao');
  end if;

  if criar_conta.nascimento > (current_date - interval '18 years') then
    perform public.erro(422, 'menor_de_idade');
  end if;

  if criar_conta.telefone !~ '^\+[1-9][0-9]{7,14}$' then
    perform public.erro(422, 'campo_obrigatorio', 'telefone');
  end if;

  select u.email into v_email from auth.users u where u.id = v_uid;
  if v_email is null then
    perform public.erro(401, 'nao_autenticado', 'sem_email_confirmado');
  end if;

  begin
    insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                                termos_versao, termos_aceite_em)
    values (v_uid, criar_conta.perfil, btrim(criar_conta.nome), criar_conta.telefone,
            v_email, criar_conta.nascimento,
            btrim(criar_conta.termos_versao), privado.agora())
    returning * into v_linha;
  exception
    when unique_violation then
      perform public.erro(409, 'conta_existente', 'email_em_uso');
  end;

  return public.conta_em_json(v_linha);
end $$;

comment on function public.criar_conta(public.perfil_conta, text, text, date, text) is
  'Cria a conta do produto depois que o código do e-mail foi confirmado. Perfil fixo (RN25), maioridade verificada (RN20), aceite registrado, e o nome passa pelo filtro da diretriz 1.2.';

revoke execute on function public.criar_conta(public.perfil_conta, text, text, date, text)
  from public, anon;
grant  execute on function public.criar_conta(public.perfil_conta, text, text, date, text)
  to authenticated;

-- As auxiliares novas seguem a regra do schema: ninguém chama por /rpc, porque o
-- PostgREST só expõe `public`.
revoke execute on function privado.normalizar(text)      from public, anon;
revoke execute on function privado.texto_aceitavel(text) from public, anon;
grant  execute on function privado.normalizar(text)      to authenticated, service_role;
grant  execute on function privado.texto_aceitavel(text) to authenticated, service_role;

-- A tabela não tem política de leitura, e é deliberado: publicar a lista é publicar o
-- mapa de como contorná-la. O RLS fica ligado pelo event trigger só se a tabela fosse
-- de `public`; aqui o schema inteiro já está fora da API.
