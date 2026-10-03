-- As restrições de unicidade que sobreviviam à própria remoção.
--
-- Escrito a partir de uma medição do portão de mutação: `scripts/mutacao.sh` varria
-- `CHECK`, `EXCLUDE`, trigger e política de RLS, mas o filtro de restrições era
-- `contype in ('c','x')` e 'u' não aparecia em nenhuma linha do arquivo. Dezesseis
-- restrições de unicidade e três índices únicos estavam fora do portão — nove delas são
-- o que torna uma RPC idempotente, e `usuario_id_perfil` é RN25 inteira.
--
-- Com os dezenove no portão, treze morreram e seis sobreviveram à suíte inteira. Este
-- arquivo cobre os seis. Cada asserção foi provada por mutação: derrubada a restrição,
-- ela fica vermelha; de pé, verde.
--
-- Quatro das seis são `throws_ok` com 23505, no padrão do resto da suíte. As outras duas
-- não são violáveis por dado nenhum, e isso é medição, não desculpa:
--
--   · `usuario_id_perfil` é `unique (id, perfil)` sobre uma tabela cuja chave primária é
--     `id`. Duas linhas com o mesmo `id` não existem, logo não existe insert que a
--     viole. Ela não está ali para recusar dado: está ali para ser o alvo das chaves
--     estrangeiras compostas de RN25, e é isso que a asserção afirma.
--   · `avaliacao_turno_id_autor_id_key` é `unique (turno_id, autor_id)`, e o gatilho
--     `avaliacao_rn07` já amarra o autor ao lado: quem é o profissional do turno só
--     escreve `alvo_tipo = 'estabelecimento'`, e quem é membro da casa só escreve
--     'profissional'. Como RN25 proíbe a mesma conta ser as duas coisas, (turno, autor)
--     determina o lado, e `um_voto_por_lado` recusa antes. Toda violação alcançável de
--     uma passa pela outra, e a única asserção honesta sobre ela é a de catálogo.

begin;
select plan(8);

create function pg_temp.conta(p_id uuid, p_perfil public.perfil_conta)
returns uuid language sql as $$
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                              termos_versao, termos_aceite_em)
  values (p_id, p_perfil, 'Fulano', '+5561999990000', p_id::text || '@u.test',
          '1990-01-01', '2026-09-22', now())
  returning id;
$$;

select pg_temp.conta('dddddddd-0000-4000-8000-000000000001', 'profissional');
select pg_temp.conta('dddddddd-0000-4000-8000-000000000002', 'contratante');
select pg_temp.conta('dddddddd-0000-4000-8000-000000000003', 'profissional');

-- Id fixo, e não busca por documento ou por usuario_id: com a chave sob medição
-- derrubada o subselect devolveria duas linhas e a asserção 1 levaria cinco fixtures
-- atrás de si. Cada alvo tem de matar uma asserção só, senão o relatório de mutação não
-- diz qual é qual.
insert into public.profissional (id, usuario_id, ponto_base)
values ('dddddddd-0000-4000-8000-0000000000f1', 'dddddddd-0000-4000-8000-000000000001',
        'POINT(-47.88 -15.79)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ('dddddddd-0000-4000-8000-0000000000e1', 'Bar do Zé', '11222333000181',
        'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('dddddddd-0000-4000-8000-000000000002',
        'dddddddd-0000-4000-8000-0000000000e1', 'administrador');

-- ── estabelecimento: o documento é a chave de idempotência ─────────────────────
--
-- `cadastrar_estabelecimento` lê por documento antes de inserir e devolve 409
-- `documento_ja_cadastrado` sem encostar na chave, então o teste da RPC passa com a
-- restrição fora. O bloco `exception` que de fato depende dela só dispara com dois
-- pedidos simultâneos do mesmo dono, e pgTAP roda numa sessão só. Sem esta asserção, o
-- CNPJ duplicado entra por escrita direta e o mesmo bar vira dois.
select throws_ok(
  $$ insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
     values ('Outro Bar', '11222333000181', 'food_service', 'CLN 202',
             'POINT(-47.88 -15.79)'::extensions.geography) $$,
  '23505',
  null,
  'estabelecimento_documento_key: o mesmo documento não vira dois estabelecimentos');

-- ── membro_estabelecimento: uma filiação por par ───────────────────────────────
--
-- RF21 e o painel contam o papel de quem chama. Duas linhas do mesmo par deixariam o
-- mesmo usuário administrador e operador da mesma casa, e qual dos dois responde passa a
-- depender da ordem da leitura.
select throws_ok(
  $$ insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
     values ('dddddddd-0000-4000-8000-000000000002',
             'dddddddd-0000-4000-8000-0000000000e1', 'operador') $$,
  '23505',
  null,
  'membro_estabelecimento_usuario_id_estabelecimento_id_key: uma filiação por par');

-- ── profissional: um perfil por conta ──────────────────────────────────────────
--
-- `criar_perfil_profissional` recusa com 409 `perfil_ja_existe` por um `if exists` antes
-- do insert, e é desse `if` que vive a asserção da RPC. Pela escrita direta a conta
-- ganharia dois perfis, cada um com a sua grade e a sua reputação, e RN08 passaria a
-- somar em qual dos dois o `join` achar primeiro.
select throws_ok(
  $$ insert into public.profissional (usuario_id, ponto_base)
     values ('dddddddd-0000-4000-8000-000000000001',
             'POINT(-47.90 -15.80)'::extensions.geography) $$,
  '23505',
  null,
  'profissional_usuario_id_key: uma conta não tem dois perfis de profissional');

-- ── turno: um turno por posição ────────────────────────────────────────────────
create function pg_temp.vaga()
returns uuid language sql as $$
  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente,
                           publicado_por)
  select 'dddddddd-0000-4000-8000-0000000000e1',
         (select id from public.funcao where nome = 'garçom'),
         now() + interval '4 h', now() + interval '12 h', 'CLN 201',
         'POINT(-47.8822 -15.7942)'::extensions.geography,
         12000, 1::smallint, true, false, false, 'Maître Zé', 'urgencia',
         gen_random_uuid(), 'dddddddd-0000-4000-8000-000000000002'
  returning id;
$$;

create temp table pos as
  with nova as (
    insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em,
                                inicio_em, fim_em)
    select pg_temp.vaga(), 'confirmada', 'dddddddd-0000-4000-8000-0000000000f1',
           now(), now() + interval '4 h', now() + interval '12 h'
    returning id)
  select id from nova;

insert into public.turno (posicao_id, valor_acordado_centavos)
select id, 12000 from pos;

-- RN19 é um `UPDATE` condicional dentro da RPC, e por isso a segunda confirmação nunca
-- chega ao insert do turno: nenhum teste da suíte alcançava esta chave. Ela é a trava de
-- última instância, e dois turnos na mesma posição seriam duas avaliações, dois
-- check-ins e dois valores acordados para um só trabalho.
select throws_ok(
  $$ insert into public.turno (posicao_id, valor_acordado_centavos)
     select id, 12000 from pos $$,
  '23505',
  null,
  'turno_posicao_id_key: uma posição confirmada gera um turno, nunca dois');

-- ── posicao: uma reabertura por falta ──────────────────────────────────────────
--
-- `reabrir_por_atraso` tem retorno antecipado por `ocorrencia` e não chega a inserir a
-- segunda posição, então a suíte não encostava neste índice. Ele é parcial — vale só
-- onde `reaberta_por_atraso_de` não é nulo — e é o que impede que a mesma falta gere
-- duas posições novas, cada uma despachando para a mesma lista de elegíveis.
create temp table faltou as
  with nova as (
    insert into public.posicao (vaga_id, estado, inicio_em, fim_em, falta)
    select pg_temp.vaga(), 'cancelada',
           now() + interval '4 h', now() + interval '12 h', true
    returning id)
  select id from nova;

insert into public.posicao (vaga_id, estado, inicio_em, fim_em, reaberta_por_atraso_de)
select (select vaga_id from public.posicao p, faltou where p.id = faltou.id),
       'aberta', now() + interval '4 h', now() + interval '12 h', id
  from faltou;

select throws_ok(
  $$ insert into public.posicao (vaga_id, estado, inicio_em, fim_em, reaberta_por_atraso_de)
     select (select vaga_id from public.posicao p, faltou where p.id = faltou.id),
            'aberta', now() + interval '4 h', now() + interval '12 h', id
       from faltou $$,
  '23505',
  null,
  'posicao_uma_reabertura_por_falta: uma falta reabre uma posição, não duas');

-- ── avaliacao: a chave por autor, que o lado já subsume ────────────────────────
--
-- A asserção é de catálogo porque não existe insert que viole (turno, autor) sem violar
-- (turno, lado) antes — ver o cabeçalho. A próxima asserção mede o motivo em vez de
-- afirmá-lo: é o gatilho de RN07 que amarra o autor ao lado.
select is(
  (select count(*)::int from pg_constraint c
    where c.conrelid = 'public.avaliacao'::regclass
      and c.contype = 'u'
      and pg_get_constraintdef(c.oid) = 'UNIQUE (turno_id, autor_id)'),
  1,
  'avaliacao_turno_id_autor_id_key: a chave por autor existe, ao lado da chave por lado');

select throws_ok(
  $$ insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
     select tu.id, 'dddddddd-0000-4000-8000-000000000001', 'profissional', po.profissional_id, true
       from public.turno tu join public.posicao po on po.id = tu.posicao_id, pos
      where tu.posicao_id = pos.id $$,
  '23514',
  null,
  'RN07: o profissional do turno não escreve do lado dele — é o gatilho que subsume a chave por autor');

-- ── usuario: RN25, a unicidade que sustenta as duas chaves estrangeiras ────────
--
-- `unique (id, perfil)` sobre uma tabela com `id` como chave primária nunca recusa um
-- insert. Ela existe para que `profissional` e `membro_estabelecimento` possam
-- referenciar o par, e é só isso que se pode afirmar sobre ela. Derrubá-la exige
-- `cascade` e leva as duas chaves estrangeiras junto — por isso o portão de mutação a
-- mata por 23503, nos testes 4 e 5 de `010_identidade.sql`, e não pela unicidade.
-- Mutação impura: esta asserção é a única que morre pela perda da própria chave.
select is(
  (select count(*)::int from pg_constraint f
    where f.contype = 'f'
      and f.conindid = (select c.conindid from pg_constraint c
                         where c.conname = 'usuario_id_perfil'
                           and c.conrelid = 'public.usuario'::regclass)),
  2,
  'usuario_id_perfil: RN25 existe e as duas chaves estrangeiras compostas apontam para ela');

select * from finish();
rollback;
