-- `configuracao_do_app`: versão mínima do app e aviso de atualização obrigatória.
--
-- Cartão CvopSHh6, metade Backend. Contrato 0.2.2 em diante: `GET /rpc/configuracao_do_app`
-- com `plataforma` na query, resposta `ConfiguracaoDoApp`.
--
-- A v1.1 sai com o piloto rodando e o app antigo continua nos aparelhos. Sem este canal,
-- um app com defeito grave não sai de circulação e o backend fica preso à compatibilidade
-- com ele. O canal só funciona se o build 1.0 já souber perguntar — por isso é S0.
--
-- ── A única exceção a "anon não lê nada" ──────────────────────────────────────
--
-- A Modelagem diz que `anon` não lê nem escreve nada. Esta função é a exceção, e é de
-- propósito: o app abaixo da versão mínima precisa descobrir isso **antes** de entrar,
-- e pode nem conseguir entrar. A chave publicável basta.
--
-- A exceção é estreita: `anon` executa a função e não enxerga a tabela. A tabela mora
-- em `privado`, que o PostgREST não expõe, e a função devolve só os cinco campos do
-- contrato. `tests/230_configuracao_do_app.sql` confere, por nome, que ela continua
-- sendo a única função de `public` que `anon` executa.
--
-- ── Por que colunas, e não (chave, valor) ─────────────────────────────────────
--
-- O cartão sugere `configuracao_app (chave, valor)`. O contrato, que é posterior ao
-- cartão, fez a configuração **por plataforma** e com quatro campos de tipo e forma
-- conhecidos. Com colunas, o banco recusa o erro de digitação que derrubaria o app de
-- todo mundo: versão que não é versão, recomendada abaixo da mínima, loja sem TLS.
-- Com (chave, valor), tudo isso seria texto aceito.

-- ── A versão como o app a compara ─────────────────────────────────────────────
--
-- Números separados por ponto, até quatro partes, cada uma com até seis dígitos: é o
-- que o app sabe comparar (`1.2.10` > `1.2.9`) e o que cabe em inteiro dos dois lados.
-- Fora do formato, devolve null em vez de estourar: a restrição de ordem abaixo só
-- compara o que já tem forma, e quem recusa o formato são as restrições de formato —
-- medido no primeiro teste, com o cast direto `v1.0` saía `22P02` pela restrição de
-- ordem, e as de formato ficavam sem ninguém que dependesse delas.
create or replace function privado.versao_em_partes(versao text) returns int[]
language sql
immutable
set search_path = ''
as $$
  select case
           when versao ~ '^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$'
           then pg_catalog.string_to_array(versao, '.')::int[]
         end
$$;

comment on function privado.versao_em_partes(text) is
  'Versão de build como int[] para comparar por ordem natural (1.2.10 > 1.2.9). Null fora do formato.';

revoke execute on function privado.versao_em_partes(text) from public, anon, authenticated;

create table privado.configuracao_app (
  plataforma         public.plataforma primary key,
  versao_minima      text not null,
  versao_recomendada text not null,
  url_da_loja        text not null,
  mensagem           text,
  atualizado_em      timestamptz not null default now(),

  constraint versao_minima_formato
    check (privado.versao_em_partes(versao_minima) is not null),
  constraint versao_recomendada_formato
    check (privado.versao_em_partes(versao_recomendada) is not null),

  -- Ordem natural, parte a parte, como número. Comparar como texto poria `1.2.9` acima
  -- de `1.2.10`, e o aviso dispensável passaria a aparecer abaixo do bloqueio.
  -- Numa linha só também por outro motivo: `scripts/mutacao.sh` lê a definição de cada
  -- restrição linha a linha, e um `case` em várias linhas não se restaura.
  constraint recomendada_nao_abaixo_da_minima
    check (privado.versao_em_partes(versao_recomendada) >= privado.versao_em_partes(versao_minima)),

  constraint url_da_loja_https
    check (url_da_loja ~ '^https://[^[:space:]]+$'),

  -- Ausência é `null`, e o app mostra o texto padrão. Texto em branco seria uma tela de
  -- bloqueio sem texto nenhum.
  constraint mensagem_nao_vazia
    check (mensagem is null or pg_catalog.btrim(mensagem) <> '')
);

-- A tabela fica em `privado`, fora do PostgREST, mas a RLS vai ligada mesmo assim e sem
-- política nenhuma: se o schema um dia for exposto por engano, a porta continua fechada.
alter table privado.configuracao_app enable row level security;
revoke all on table privado.configuracao_app from public, anon, authenticated;

comment on table privado.configuracao_app is
  'Versão mínima e recomendada do app por plataforma, lida sem sessão por public.configuracao_do_app. Existe para tirar de circulação um app com defeito grave. Não guarda dado pessoal. Escrita só por migração (supabase/operacao/subir-versao-minima.md), nunca pelo painel.';
comment on column privado.configuracao_app.versao_minima is
  'Abaixo desta versão de build, o app bloqueia todas as telas e leva à loja.';
comment on column privado.configuracao_app.versao_recomendada is
  'A partir desta, o aviso de atualização é dispensável e aparece uma vez por versão.';
comment on column privado.configuracao_app.mensagem is
  'Texto opcional da tela de bloqueio. Nulo na maior parte do tempo: o app tem texto padrão.';

-- ── O valor inicial ───────────────────────────────────────────────────────────
--
-- Entra aqui, e não no `seed.sql`, por três motivos. É configuração do produto, não dado
-- de teste: tem de existir em todo ambiente onde a função existe, e a migração é o único
-- arquivo que chega a todos pelo mesmo caminho. Uma função sem a linha responderia 404
-- para o iOS em produção. E subir a versão depois é outra migração, com histórico: o
-- seed, reaplicado, poderia devolver a mínima para trás.
--
-- `0.1.0` é o MARKETING_VERSION de hoje em `FrilaApp/frila-frontend · iOS/project.yml`:
-- não bloqueia ninguém. A URL é `FRILA_APP_STORE_URL` de `iOS/Configurations/Shared.xcconfig`.
--
-- Android e web ficam sem linha: não têm loja, e inventar uma URL aqui seria dado de
-- produção sem fonte. A função responde 404 para eles até a linha existir.
insert into privado.configuracao_app (plataforma, versao_minima, versao_recomendada, url_da_loja)
values ('ios', '0.1.0', '0.1.0', 'https://apps.apple.com/app/id6815311991');

-- ── A função ──────────────────────────────────────────────────────────────────
--
-- `plataforma` é `text`, e não o enum: com o enum no parâmetro, o PostgREST recusaria
-- `?plataforma=windows` com `400 22P02` antes de a função rodar, e o contrato pede `422`.
--
-- Volátil, como `perfil_publico`: chama `public.erro`, que é volátil. Não escreve nada,
-- e por isso responde por GET.

create or replace function public.configuracao_do_app(plataforma text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plataforma public.plataforma;
  v_config     privado.configuracao_app;
begin
  if configuracao_do_app.plataforma is null
     or pg_catalog.btrim(configuracao_do_app.plataforma) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'plataforma');
  end if;

  if not configuracao_do_app.plataforma
         = any (pg_catalog.enum_range(null::public.plataforma)::text[]) then
    perform public.erro(422, 'campo_invalido', 'plataforma');
  end if;

  v_plataforma := configuracao_do_app.plataforma::public.plataforma;

  select c.* into v_config
    from privado.configuracao_app c
   where c.plataforma = v_plataforma;

  if not found then
    perform public.erro(404, 'nao_encontrado', 'plataforma');
  end if;

  return pg_catalog.jsonb_build_object(
    'plataforma',         v_config.plataforma,
    'versao_minima',      v_config.versao_minima,
    'versao_recomendada', v_config.versao_recomendada,
    'url_da_loja',        v_config.url_da_loja,
    'mensagem',           v_config.mensagem);
end $$;

comment on function public.configuracao_do_app(text) is
  'Versão mínima, versão recomendada, URL da loja e mensagem opcional da plataforma (contrato: ConfiguracaoDoApp). Única função de public liberada para anon: o app abaixo da mínima precisa saber disso antes de ter sessão. 422 para plataforma ausente ou fora do enum; 404 para plataforma sem configuração.';

revoke execute on function public.configuracao_do_app(text) from public;
grant  execute on function public.configuracao_do_app(text) to anon, authenticated;
