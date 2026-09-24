-- Os cenários de desenvolvimento, conferidos como fixture.
--
-- Os outros nove arquivos de teste criam os próprios dados dentro da transação e a
-- desfazem no fim. Este é o contrário: ele não cria nada, e mede o que
-- `supabase/cenarios.sql` deixou no banco depois do `db reset`.
--
-- Existe porque fixture sem teste apodrece em silêncio. Uma migração nova muda o
-- esquema, o arquivo de cenários deixa de bater, e quem descobre é a próxima pessoa
-- que for demonstrar o produto — ou pior, o teste de outra coisa, por um motivo que
-- não tem nada a ver com o que ele estava medindo.
--
-- O critério de aceite do cartão que este arquivo cobre:
--
--   "Existe pelo menos um profissional elegível e um inelegível por cada critério
--    da RN05 (função, horário, distância, perfil suspenso, bloqueio, turno sobreposto)."
--
-- Note o que isto **não** é: não é o teste da RPC de elegibilidade. Ela não existe —
-- é Sprint 2, `criterios_de_notificacao` e o despacho. O que está escrito aqui é a
-- regra aplicada ao conjunto de dados, para garantir que quando a RPC for escrita ela
-- tenha contra o que ser medida. Quando ela existir, este arquivo passa a chamá-la, e
-- a divergência entre as duas leituras é o achado.

begin;
select plan(36);

-- ── As identidades do cenário ──────────────────────────────────────────────────
--
-- Os mesmos uuid que o README de supabase/ documenta. Ficam aqui por extenso, e não
-- por busca de nome, porque um teste que procura 'Ana Ribeiro' passa a medir o nome.

create temp table ids as select
  'd0000000-0000-4000-8000-000000000001'::uuid as vaga_referencia,
  'e0000000-0000-4000-8000-000000000001'::uuid as ana,      -- elegível em tudo
  'e0000000-0000-4000-8000-000000000002'::uuid as bruno,    -- sem a função
  'e0000000-0000-4000-8000-000000000003'::uuid as carla,    -- fora do horário
  'e0000000-0000-4000-8000-000000000004'::uuid as diego,    -- além dos 15 km
  'e0000000-0000-4000-8000-000000000005'::uuid as elisa,    -- conta suspensa
  'e0000000-0000-4000-8000-000000000006'::uuid as felipe,   -- bloqueio com a casa
  'e0000000-0000-4000-8000-000000000007'::uuid as gabi,     -- turno sobreposto
  'e0000000-0000-4000-8000-000000000009'::uuid as iara,     -- longe, mas da equipe
  'c0000000-0000-4000-8000-000000000001'::uuid as bar,
  'a0000000-0000-4000-8000-000000000006'::uuid as conta_felipe;

-- ── RN05, critério a critério ──────────────────────────────────────────────────
--
-- Seis perguntas independentes, cada uma respondida em separado. Uma função que
-- devolvesse só `elegível: sim/não` não deixaria conferir o que o cartão pede: que
-- cada critério tenha os dois lados representados nos dados. Com `sim/não`, um
-- conjunto em que ninguém é barrado por distância passaria igual.
--
-- `distancia` carrega a exceção de RF18 de propósito: a equipe de confiança não é um
-- sétimo critério, é a única forma de passar pelo de distância estando longe.

create function pg_temp.rn05(v uuid, prof uuid)
returns table (criterio text, ok boolean)
language sql stable as $$
  with vg as (select * from public.vaga where id = v),
       pr as (select * from public.profissional where id = prof)
  select 'funcao'::text, exists (
           select 1 from public.profissional_funcao pf, vg
            where pf.profissional_id = prof and pf.funcao_id = vg.funcao_id)
  union all
  -- A grade é semanal e em hora local; a vaga é um instante absoluto. A conversão é
  -- onde mora o erro clássico: comparar `timestamptz` com `time` sem fuso dá certo em
  -- UTC−3 e erra no horário de verão de quem escreveu o teste.
  --
  -- A janela que atravessa a meia-noite (18:00–02:00, a mais comum do setor) é a razão
  -- de a duração ser calculada com `+ 24 horas` quando `hora_fim < hora_inicio`, em vez
  -- de comparar as duas horas direto.
  select 'horario'::text, exists (
           select 1 from public.disponibilidade d, vg
            where d.profissional_id = prof
              and d.dia_semana =
                    extract(dow from vg.inicio_em at time zone 'America/Sao_Paulo')::int
              and tstzrange(
                    (date_trunc('day', vg.inicio_em at time zone 'America/Sao_Paulo')
                       + d.hora_inicio) at time zone 'America/Sao_Paulo',
                    (date_trunc('day', vg.inicio_em at time zone 'America/Sao_Paulo')
                       + d.hora_inicio
                       + case when d.hora_fim > d.hora_inicio
                              then  d.hora_fim - d.hora_inicio
                              else (d.hora_fim - d.hora_inicio) + interval '24 hours'
                         end) at time zone 'America/Sao_Paulo'
                  ) @> tstzrange(vg.inicio_em, vg.fim_em))
  union all
  select 'distancia'::text, (
           select extensions.ST_DWithin(pr.ponto_base, vg.ponto, 15000)
                  or exists (select 1 from public.equipe_confianca e
                              where e.profissional_id = prof
                                and e.estabelecimento_id = vg.estabelecimento_id)
             from pr, vg)
  union all
  select 'perfil_ativo'::text, (
           select u.estado = 'ativa' from public.usuario u, pr where u.id = pr.usuario_id)
  union all
  -- Chama o auxiliar de produção, não uma cópia da regra: RF26 vale para o
  -- estabelecimento inteiro, e reescrever isso aqui deixaria o teste verde sobre uma
  -- versão da regra que não é a que o app usa.
  select 'sem_bloqueio'::text, (
           select not privado.bloqueado_com_estabelecimento(pr.usuario_id, vg.estabelecimento_id)
             from pr, vg)
  union all
  select 'sem_sobreposicao'::text, (
           select not exists (
             select 1 from public.posicao p, vg
              where p.profissional_id = prof
                and p.estado in ('confirmada','cumprida')
                and p.vaga_id <> vg.id
                and tstzrange(p.inicio_em, p.fim_em) && tstzrange(vg.inicio_em, vg.fim_em)))
$$;

create function pg_temp.elegivel(v uuid, prof uuid) returns boolean
language sql stable as $$
  select bool_and(r.ok) from pg_temp.rn05(v, prof) r
$$;

-- O primeiro critério reprovado, em ordem alfabética. Serve para os sete arquétipos,
-- que foram desenhados para reprovar em exatamente um — quem reprova em dois não
-- documenta critério nenhum.
create function pg_temp.motivo(v uuid, prof uuid) returns text
language sql stable as $$
  select r.criterio from pg_temp.rn05(v, prof) r where not r.ok order by 1 limit 1
$$;

create function pg_temp.quantos(crit text, valor boolean) returns int
language sql stable as $$
  select count(*)::int
    from public.profissional p
    cross join (select vaga_referencia from ids) i
    join lateral pg_temp.rn05(i.vaga_referencia, p.id) r on r.criterio = quantos.crit
   where r.ok is not distinct from valor
$$;

-- ── O que o cartão pede, medido ────────────────────────────────────────────────
--
-- Os dois lados de cada um dos seis critérios, sobre a vaga de referência.

select cmp_ok(pg_temp.quantos('funcao', true),  '>', 0,
  'RN05/função: há profissional com a função da vaga de referência');
select cmp_ok(pg_temp.quantos('funcao', false), '>', 0,
  'RN05/função: e há quem não a tenha');

select cmp_ok(pg_temp.quantos('horario', true),  '>', 0,
  'RN05/horário: há profissional cuja grade cobre a janela da vaga');
select cmp_ok(pg_temp.quantos('horario', false), '>', 0,
  'RN05/horário: e há quem esteja fora dela');

select cmp_ok(pg_temp.quantos('distancia', true),  '>', 0,
  'RN05/distância: há profissional dentro dos 15 km');
select cmp_ok(pg_temp.quantos('distancia', false), '>', 0,
  'RN05/distância: e há quem esteja além deles, sem equipe de confiança que o alcance');

select cmp_ok(pg_temp.quantos('perfil_ativo', true),  '>', 0,
  'RN05/perfil: há profissional com a conta ativa');
select cmp_ok(pg_temp.quantos('perfil_ativo', false), '>', 0,
  'RN05/perfil: e há uma conta suspensa');

select cmp_ok(pg_temp.quantos('sem_bloqueio', true),  '>', 0,
  'RN05/bloqueio: há profissional sem bloqueio com a casa');
select cmp_ok(pg_temp.quantos('sem_bloqueio', false), '>', 0,
  'RF26: e há um bloqueado, que some da casa inteira');

select cmp_ok(pg_temp.quantos('sem_sobreposicao', true),  '>', 0,
  'RN05/sobreposição: há profissional livre na janela');
select cmp_ok(pg_temp.quantos('sem_sobreposicao', false), '>', 0,
  'RN21: e há um já confirmado em turno que se cruza com ela');

-- ── Os arquétipos, nominalmente ────────────────────────────────────────────────
--
-- O bloco acima garante que os dois lados existem; este garante que existem **pelos
-- motivos certos**. Sem ele, um erro de coordenada que jogasse metade do cenário para
-- fora dos 15 km manteria as doze asserções anteriores verdes.

select ok((select pg_temp.elegivel(vaga_referencia, ana) from ids),
  'a Ana passa nos seis critérios: é o controle positivo do cenário');

select is((select pg_temp.motivo(vaga_referencia, bruno)   from ids), 'funcao',
  'o Bruno é barrado só pela função');
select is((select pg_temp.motivo(vaga_referencia, carla)   from ids), 'horario',
  'a Carla, só pela grade — ela tem a função');
select is((select pg_temp.motivo(vaga_referencia, diego)   from ids), 'distancia',
  'o Diego, só pela distância: Águas Claras está a mais de 15 km da Asa Norte');
select is((select pg_temp.motivo(vaga_referencia, elisa)   from ids), 'perfil_ativo',
  'a Elisa, só pela conta suspensa');
select is((select pg_temp.motivo(vaga_referencia, felipe)  from ids), 'sem_bloqueio',
  'o Felipe, só pelo bloqueio com o bar');
select is((select pg_temp.motivo(vaga_referencia, gabi)    from ids), 'sem_sobreposicao',
  'a Gabi, só pelo turno já confirmado na mesma janela');

-- RF18. A Iara mora tão longe quanto o Diego e passa, e é a única diferença entre os
-- dois: sem uma linha em `equipe_confianca`, esta asserção e a do Diego seriam iguais.
select ok((select pg_temp.elegivel(vaga_referencia, iara) from ids),
  'RF18: a Iara está além dos 15 km e é alcançada assim mesmo, por ser da equipe do bar');

-- ── O cenário está inteiro ─────────────────────────────────────────────────────

select is((select count(*)::int from public.estabelecimento), 3,
  'três estabelecimentos: Asa Norte, Águas Claras e Lago Sul');

select is((select count(*)::int from public.profissional), 12,
  'doze profissionais');

select is((select count(*)::int from public.funcao), 32,
  'e o catálogo continua com as 32 funções do seed — o cenário não inventa função');

select is((select count(distinct estado)::int from public.vaga), 4,
  'vagas nos quatro estados: publicada, preenchida, encerrada e cancelada');

select cmp_ok((select count(*)::int from public.vaga where modo = 'selecao'), '>', 0,
  'RN24: e pelo menos uma no modo seleção, publicada com mais de 24 h de antecedência');

-- ── Os três caminhos do check-in ───────────────────────────────────────────────
--
-- RN22 tem três desfechos, e o de baixo é o que o produto mais teme: o turno que
-- aconteceu e não tem prova. Os três precisam existir nos dados, senão a tela do
-- contratante só é vista no caminho feliz.

select cmp_ok((select count(*)::int from public.turno
                where checkin_tipo = 'geolocalizado' and verificacao = 'verificado'),
  '>', 0, 'há turno com check-in geolocalizado, verificado');

select cmp_ok((select count(*)::int from public.turno
                where checkin_tipo = 'manual' and checkin_confirmado_em is not null
                  and verificacao = 'verificado'),
  '>', 0, 'há turno com check-in manual confirmado pelo contratante');

select cmp_ok((select count(*)::int from public.turno
                where checkin_tipo = 'manual' and checkin_confirmado_em is null
                  and verificacao = 'pendente'),
  '>', 0, 'há turno com check-in manual esperando confirmação');

select cmp_ok((select count(*)::int from public.turno where verificacao = 'nao_verificado'),
  '>', 0, 'e há turno que terminou sem prova nenhuma de presença');

-- ── Avaliação, falta e bloqueio ────────────────────────────────────────────────

select cmp_ok((select count(*)::int from public.avaliacao where alvo_tipo = 'profissional'),
  '>', 0, 'RN07: o contratante avaliou o profissional');
select cmp_ok((select count(*)::int from public.avaliacao where alvo_tipo = 'estabelecimento'),
  '>', 0, 'e o profissional avaliou a casa — a avaliação vale nos dois sentidos');
select cmp_ok((select count(*)::int from public.avaliacao where not resposta),
  '>', 0, 'e há ao menos uma resposta negativa: cenário só com "sim" não exercita a tela');

select cmp_ok((select count(*)::int from public.posicao where falta), '>', 0,
  'RN12: há uma falta registrada, com a posição cancelada que a guarda');

select ok((select privado.bloqueado_com_estabelecimento(conta_felipe, bar) from ids),
  'o bloqueio do cenário vale para o estabelecimento inteiro, pelo auxiliar de produção');

-- ── As duas guardas ────────────────────────────────────────────────────────────

-- O marcador de ambiente de teste não mora em arquivo nenhum do repositório, e o
-- arquivo de cenários é justamente o tipo de arquivo onde alguém o colocaria "só para
-- facilitar". Com ele gravado, `privado.agora()` vira sobreponível e todo prazo do
-- produto (RN07, RN10, RN24) vira decoração.
select is((select count(*)::int from privado.ambiente), 0,
  'o arquivo de cenários não marca o ambiente como de teste');

-- Sem credencial em auth.users, a conta existe no produto e ninguém consegue entrar
-- nela: o código do e-mail não tem onde chegar.
select is(
  (select count(*)::int from public.usuario u
    where not exists (select 1 from auth.users a where a.id = u.id)),
  0,
  'toda conta do cenário tem credencial em auth.users, e portanto dá para entrar nela');

select * from finish();
rollback;
