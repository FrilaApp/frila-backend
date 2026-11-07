-- Catálogo de Casa e Festa, regiões administrativas, especialidades e resolver_servico.
-- Contratação direta, fatia F1 · contrato 0.2.52 · RN44 · decisão D9 do Cauê (06/11/2026).
--
-- O que muda, e o que de propósito não muda:
--   · Quatro tabelas de catálogo, todas com leitura para `authenticated` e nenhuma política
--     de escrita (o catálogo muda por migração, nunca pelo app): `regiao_administrativa`,
--     `categoria`, `especialidade` e `funcao_sinonimo`.
--   · `funcao` ganha quatro colunas e seis funções novas. O despacho continua por
--     `funcao_id` (RN05): nada aqui toca `privado.elegiveis`. Uma faxina residencial é uma
--     vaga normal, publicada e despachada como qualquer outra.
--   · `resolver_servico` só ajuda a pessoa a achar a função. Texto desconhecido devolve
--     lista vazia, nunca cria função e nunca decide elegibilidade.
--
-- Onde cada dado mora:
--   · Esta migração leva as regiões, as categorias, as seis funções novas e o que depende só
--     delas (especialidades e sinônimos).
--   · `seed.sql` leva o que depende das funções antigas (`grupo_busca` de garçom e
--     garçonete, especialidades do bartender), porque num banco novo a migração roda antes
--     do seed e essas funções ainda não existem. O seed também repete as seis novas, para
--     manter o catálogo inteiro num só lugar; tudo é idempotente.
--
-- O número de regiões segue o brief B1 (37, até a RA XXXVII Ponte Alta). O texto do
-- contrato 0.2.52 ainda diz 35 (até a RA XXXV): divergência registrada no retorno da
-- tarefa, a corrigir no frila-docs.

-- ── 1. regiao_administrativa ──────────────────────────────────────────────────

create table public.regiao_administrativa (
  id     smallint primary key check (id > 0),
  numero text     not null check (btrim(numero) <> ''),
  nome   text     not null unique check (btrim(nome) <> ''),
  ativo  boolean  not null default true
);

comment on table public.regiao_administrativa is
  'Catálogo fechado das regiões administrativas do DF (RN44). Dado público, sem dado pessoal. Muda por migração. O perfil do profissional marca onde atende por id, nunca por texto.';
comment on column public.regiao_administrativa.id is
  'O número da região em arábico (RA I = 1). Estável: o perfil guarda este id.';
comment on column public.regiao_administrativa.numero is
  'Número romano oficial da região (I, II, ... XXXVII).';

alter table public.regiao_administrativa enable row level security;

create policy "regiao_administrativa_select" on public.regiao_administrativa
  for select to authenticated using (true);

revoke all on public.regiao_administrativa from anon;
grant select on public.regiao_administrativa to authenticated;

insert into public.regiao_administrativa (id, numero, nome) values
  (1,  'I',      'Plano Piloto'),
  (2,  'II',     'Gama'),
  (3,  'III',    'Taguatinga'),
  (4,  'IV',     'Brazlândia'),
  (5,  'V',      'Sobradinho'),
  (6,  'VI',     'Planaltina'),
  (7,  'VII',    'Paranoá'),
  (8,  'VIII',   'Núcleo Bandeirante'),
  (9,  'IX',     'Ceilândia'),
  (10, 'X',      'Guará'),
  (11, 'XI',     'Cruzeiro'),
  (12, 'XII',    'Samambaia'),
  (13, 'XIII',   'Santa Maria'),
  (14, 'XIV',    'São Sebastião'),
  (15, 'XV',     'Recanto das Emas'),
  (16, 'XVI',    'Lago Sul'),
  (17, 'XVII',   'Riacho Fundo'),
  (18, 'XVIII',  'Lago Norte'),
  (19, 'XIX',    'Candangolândia'),
  (20, 'XX',     'Águas Claras'),
  (21, 'XXI',    'Riacho Fundo II'),
  (22, 'XXII',   'Sudoeste/Octogonal'),
  (23, 'XXIII',  'Varjão'),
  (24, 'XXIV',   'Park Way'),
  (25, 'XXV',    'SCIA'),
  (26, 'XXVI',   'Sobradinho II'),
  (27, 'XXVII',  'Jardim Botânico'),
  (28, 'XXVIII', 'Itapoã'),
  (29, 'XXIX',   'SIA'),
  (30, 'XXX',    'Vicente Pires'),
  (31, 'XXXI',   'Fercal'),
  (32, 'XXXII',  'Sol Nascente/Pôr do Sol'),
  (33, 'XXXIII', 'Arniqueira'),
  (34, 'XXXIV',  'Arapoanga'),
  (35, 'XXXV',   'Água Quente'),
  (36, 'XXXVI',  '26 de Setembro'),
  (37, 'XXXVII', 'Ponte Alta')
on conflict (id) do nothing;

-- ── 2. categoria ──────────────────────────────────────────────────────────────
--
-- `funcao.categoria` continua texto, como sempre foi. Esta tabela dá às categorias um lugar
-- para a dica e o exemplo de perfil; ligar `funcao.categoria` a ela por chave estrangeira é
-- mudança própria, fora desta fatia.

create table public.categoria (
  nome           text     primary key check (btrim(nome) <> ''),
  dica_perfil    text,
  exemplo_perfil text,
  ordem          smallint not null default 0
);

comment on table public.categoria is
  'Categorias do catálogo de funções (RN44), com a dica e o exemplo que ajudam a descrever o serviço no perfil. Texto editorial da Equipe Frila, sem dado pessoal. Muda por migração.';
comment on column public.categoria.dica_perfil is
  'Dica para o profissional descrever os serviços desta categoria no perfil. Nula quando não há.';
comment on column public.categoria.exemplo_perfil is
  'Exemplo de "Sobre mim" para esta categoria. Texto fictício, nunca de pessoa real.';

alter table public.categoria enable row level security;

create policy "categoria_select" on public.categoria
  for select to authenticated using (true);

revoke all on public.categoria from anon;
grant select on public.categoria to authenticated;

insert into public.categoria (nome, dica_perfil, exemplo_perfil, ordem) values
  ('Salão',      null, null, 1),
  ('Bar',        null, null, 2),
  ('Cozinha',    null, null, 3),
  ('Evento',     null, null, 4),
  ('Apoio',      null, null, 5),
  ('Varejo',     null, null, 6),
  ('Logística',  null, null, 7),
  ('Casa',
   'Conte o que você faz em casa de família ou escritório: tipo de limpeza, tempo de experiência e se leva material próprio. Diga também em quais regiões atende.',
   'Faço faxina residencial há 6 anos, com limpeza pesada e pós-obra. Levo meu material quando a casa pede. Atendo Águas Claras, Taguatinga e Guará.',
   8),
  ('Festa e eventos sociais',
   'Conte que tipo de festa você atende (aniversário, casamento, churrasco), quantas pessoas costuma servir e o que você faz sozinho ou em equipe.',
   'Cuido do churrasco de aniversários e confraternizações de 30 a 120 pessoas, com cortes nobres e acompanhamentos. Levo minha equipe quando o evento é grande.',
   9)
on conflict (nome) do nothing;

-- ── 3. funcao: formato, grupo de busca, dica e exemplo ────────────────────────

alter table public.funcao
  add column formato_padrao text not null default 'turno'
    check (formato_padrao in ('turno', 'servico')),
  add column grupo_busca    text,
  add column dica_perfil    text,
  add column exemplo_perfil text;

comment on column public.funcao.formato_padrao is
  'Só muda o que a tela sugere: turno (horário fechado) ou servico (resultado contratado, fim previsto). Não muda regra: todo trabalho tem início e fim (RN44).';
comment on column public.funcao.grupo_busca is
  'Funções com o mesmo valor aparecem juntas na busca (garçom e garçonete). Nulo quando a função não tem par. Não entra na elegibilidade, que é por funcao_id (RN05).';
comment on column public.funcao.dica_perfil is
  'Dica para o profissional descrever este serviço no perfil. Nula quando não há.';
comment on column public.funcao.exemplo_perfil is
  'Exemplo de "Sobre mim" para este serviço. Texto fictício, nunca de pessoa real. Nulo quando não há.';

-- Num banco que já tem o catálogo (frila-dev, frila-prod) isto marca o par; num banco novo
-- a função ainda não existe e o `seed.sql` faz o mesmo logo depois.
update public.funcao
   set grupo_busca = 'garcom_garconete'
 where nome in ('garçom', 'garçonete');

insert into public.funcao (nome, categoria, formato_padrao) values
  ('faxina residencial',  'Casa',                    'servico'),
  ('passadeira',          'Casa',                    'servico'),
  ('faxina comercial',    'Casa',                    'servico'),
  ('churrasqueiro',       'Festa e eventos sociais', 'servico'),
  ('cozinheiro de festa', 'Festa e eventos sociais', 'servico'),
  ('auxiliar de festa',   'Festa e eventos sociais', 'servico')
on conflict (nome) do update
  set categoria      = excluded.categoria,
      formato_padrao = excluded.formato_padrao;

-- ── 4. especialidade ──────────────────────────────────────────────────────────

create table public.especialidade (
  id        uuid    primary key default gen_random_uuid(),
  funcao_id uuid    not null references public.funcao(id) on delete cascade,
  nome      text    not null check (btrim(nome) <> ''),
  ativo     boolean not null default true,
  constraint especialidade_funcao_nome_unique unique (funcao_id, nome)
);

comment on table public.especialidade is
  'Especialidade fechada de uma função, curada pela Equipe Frila (RN44). Sempre pertence a uma função canônica e nunca vira função para o despacho: texto livre nunca decide elegibilidade, filtro nem ordem.';

alter table public.especialidade enable row level security;

create policy "especialidade_select" on public.especialidade
  for select to authenticated using (true);

revoke all on public.especialidade from anon;
grant select on public.especialidade to authenticated;

insert into public.especialidade (funcao_id, nome)
select f.id, e.nome
  from (values
    ('faxina residencial', 'pós-obra'),
    ('faxina residencial', 'organização de armários'),
    ('faxina residencial', 'vidros e janelas'),
    ('faxina residencial', 'limpeza pesada'),
    ('faxina residencial', 'passar roupa'),
    ('passadeira',         'roupa social'),
    ('passadeira',         'cama e banho'),
    ('passadeira',         'tecido delicado'),
    ('churrasqueiro',      'cortes nobres'),
    ('churrasqueiro',      'parrilla'),
    ('churrasqueiro',      'churrasco fogo de chão'),
    ('churrasqueiro',      'guarnições e acompanhamentos')
  ) as e (funcao, nome)
  join public.funcao f on f.nome = e.funcao
on conflict (funcao_id, nome) do nothing;

-- ── 5. funcao_sinonimo ────────────────────────────────────────────────────────

create table public.funcao_sinonimo (
  -- Guardado já normalizado (minúsculo, sem acento), e o CHECK garante isso: um termo mal
  -- gravado não casa com nada e a busca passa a parecer instalada sem estar. É a mesma
  -- regra de `privado.termo_bloqueado`.
  termo     text not null check (btrim(termo) <> '' and termo = privado.normalizar(termo)),
  funcao_id uuid not null references public.funcao(id) on delete cascade,
  primary key (termo, funcao_id)
);

comment on table public.funcao_sinonimo is
  'Como as pessoas chamam uma função (diarista, faxineira). Termo normalizado, sempre apontando para uma função canônica (RN44). Serve só à busca de resolver_servico; não decide elegibilidade.';

alter table public.funcao_sinonimo enable row level security;

create policy "funcao_sinonimo_select" on public.funcao_sinonimo
  for select to authenticated using (true);

revoke all on public.funcao_sinonimo from anon;
grant select on public.funcao_sinonimo to authenticated;

insert into public.funcao_sinonimo (termo, funcao_id)
select s.termo, f.id
  from (values
    ('diarista',            'faxina residencial'),
    ('faxineira',           'faxina residencial'),
    ('limpeza residencial', 'faxina residencial'),
    ('churrasqueira',       'churrasqueiro'),
    ('passadeira de roupas','passadeira'),
    ('copeira de festa',    'auxiliar de festa')
  ) as s (termo, funcao)
  join public.funcao f on f.nome = s.funcao
on conflict (termo, funcao_id) do nothing;

-- ── 6. resolver_servico ───────────────────────────────────────────────────────
--
-- `stable` porque o contrato a expõe em GET (`/rpc/resolver_servico?termo=...`) e o
-- PostgREST só aceita GET em função não volátil.
--
-- Do mais exato para o menos exato:
--   0  o termo é o nome da função, um sinônimo ou o grupo de busca, por inteiro;
--   1  o nome ou o sinônimo começa pelo termo ("faxi" acha faxina);
--   2  alguma palavra do nome ou do sinônimo começa pelo termo ("residencial");
--   3  a função só entra porque divide `grupo_busca` com uma que casou (garçom → garçonete).
-- No empate, ordem alfabética: não existe ordem por reputação nem por dinheiro (RN06).

create or replace function public.resolver_servico(termo text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_termo text;
  v_itens jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  if resolver_servico.termo is null
     or length(btrim(resolver_servico.termo)) < 2
     or length(btrim(resolver_servico.termo)) > 60 then
    perform public.erro(422, 'campo_invalido', 'termo');
  end if;

  v_termo := privado.normalizar(resolver_servico.termo);

  -- Só pontuação ("!!"): normalizado fica vazio e casaria com tudo. Não é termo.
  if length(v_termo) < 2 then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id',             q.id,
             'nome',           q.nome,
             'categoria',      q.categoria,
             'formato_padrao', q.formato_padrao,
             'grupo_busca',    q.grupo_busca,
             'dica_perfil',    q.dica_perfil,
             'exemplo_perfil', q.exemplo_perfil
           ) order by q.rank, q.nome), '[]'::jsonb)
    into v_itens
    from (
      select f.id, f.nome, f.categoria, f.formato_padrao, f.grupo_busca,
             f.dica_perfil, f.exemplo_perfil, r.rank
        from (
          select id, min(rank) as rank
            from (
              -- 0 a 2: casa direto, pelo nome, por sinônimo ou pelo grupo de busca
              select f.id,
                     case when x.txt = v_termo                                  then 0
                          when starts_with(x.txt, v_termo)                      then 1
                          when position(' ' || v_termo in ' ' || x.txt) > 0     then 2
                     end as rank
                from public.funcao f
                cross join lateral (
                  select privado.normalizar(f.nome) as txt
                  union all
                  select s.termo from public.funcao_sinonimo s where s.funcao_id = f.id
                  union all
                  select privado.normalizar(f.grupo_busca) where f.grupo_busca is not null
                ) x
               where f.ativo
              union all
              -- 3: o par do grupo de busca de quem casou (garçom ↔ garçonete)
              select par.id, 3
                from public.funcao par
               where par.ativo
                 and par.grupo_busca is not null
                 and par.grupo_busca in (
                   select g.grupo_busca
                     from public.funcao g
                     cross join lateral (
                       select privado.normalizar(g.nome) as txt
                       union all
                       select s.termo from public.funcao_sinonimo s where s.funcao_id = g.id
                       union all
                       select privado.normalizar(g.grupo_busca)
                     ) y
                    where g.ativo and g.grupo_busca is not null
                      and (y.txt = v_termo
                           or starts_with(y.txt, v_termo)
                           or position(' ' || v_termo in ' ' || y.txt) > 0)
                 )
            ) c
           where rank is not null
           group by id
        ) r
        join public.funcao f on f.id = r.id
       order by r.rank, f.nome
       limit 5
    ) q;

  return v_itens;
end $$;

comment on function public.resolver_servico(text) is
  'Até 5 funções ativas para o que a pessoa digitou, por nome, sinônimo e grupo de busca, da mais exata para a menos (RN44). Termo curto: 422 campo_invalido. Sem correspondência: lista vazia. Não altera a elegibilidade, que é por funcao_id (RN05).';

revoke execute on function public.resolver_servico(text) from public, anon;
grant  execute on function public.resolver_servico(text) to authenticated;
