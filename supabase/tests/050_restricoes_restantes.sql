-- As restrições que a primeira rodada de testes deixou sem cobertura.
--
-- Escrito a partir de um achado de revisão: onze dos trinta e um `CHECK` podiam ser
-- derrubados com a suíte inteira seguindo verde. Um `CHECK` sem teste é um `CHECK` que
-- alguém remove numa refatoração sem nada avisar.

begin;
select plan(13);

create function pg_temp.conta(p_id uuid, p_perfil public.perfil_conta)
returns uuid language sql as $$
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento)
  values (p_id, p_perfil, 'Fulano', '+5561999990000', p_id::text || '@t.test', '1990-01-01')
  returning id;
$$;

select pg_temp.conta('eeeeeeee-0000-0000-0000-000000000001', 'profissional');
select pg_temp.conta('eeeeeeee-0000-0000-0000-000000000002', 'contratante');

-- ── usuario: o contato existe enquanto a conta existe ──────────────────────────
--
-- RN10 depende do telefone, e a entrada depende do e-mail. Os dois só podem sumir na
-- anonimização (RF25) — apagá-los numa conta ativa deixaria a contraparte de um turno
-- confirmado sem como falar com quem vai aparecer.
select throws_ok(
  $$ update public.usuario set telefone = null
      where id = 'eeeeeeee-0000-0000-0000-000000000001' $$,
  '23514',
  null,
  'telefone_ate_anonimizar: conta ativa sem telefone deixaria o turno sem contato (RN10)');

select throws_ok(
  $$ update public.usuario set email = null
      where id = 'eeeeeeee-0000-0000-0000-000000000001' $$,
  '23514',
  null,
  'email_ate_anonimizar: conta ativa sem e-mail não teria como entrar');

-- ── RN25: o CHECK de perfil, separado da chave estrangeira ─────────────────────
--
-- São duas defesas para a mesma regra, e testá-las juntas esconde a perda de uma. O
-- `CHECK` de coluna é avaliado antes do gatilho da chave estrangeira.
select throws_ok(
  $$ insert into public.profissional (usuario_id, perfil, ponto_base)
     values ('eeeeeeee-0000-0000-0000-000000000001', 'contratante',
             'POINT(-47.88 -15.79)'::extensions.geography) $$,
  '23514',
  null,
  'RN25: a coluna perfil de profissional só aceita ''profissional''');

select throws_ok(
  $$ insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
     values ('Bar', '11222333000181', 'food_service', 'CLN 201',
             'POINT(-47.88 -15.79)'::extensions.geography);
     insert into public.membro_estabelecimento (usuario_id, perfil, estabelecimento_id, papel)
     select 'eeeeeeee-0000-0000-0000-000000000002', 'profissional', id, 'administrador'
       from public.estabelecimento where documento = '11222333000181' $$,
  '23514',
  null,
  'RN25: a coluna perfil de membro_estabelecimento só aceita ''contratante''');

-- ── estabelecimento ────────────────────────────────────────────────────────────
insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
values ('Bar do Zé', '11222333000181', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography);

select throws_ok(
  $$ update public.estabelecimento set aval_positivas = 5, aval_total = 2 $$,
  '23514',
  null,
  'RN08: o estabelecimento também guarda o denominador, e ele não pode ser menor que o numerador');

-- CPF (11) ou CNPJ (14), só dígitos. Serviço doméstico contrata pelo Frila, então CPF
-- entra; o que não entra é documento com pontuação ou com contagem errada.
select throws_ok(
  $$ insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
     values ('Outro', '11.222.333/0001-81', 'food_service', 'x',
             'POINT(0 0)'::extensions.geography) $$,
  '23514',
  null,
  'o documento é só dígitos: CNPJ pontuado não entra e não vira um segundo cadastro do mesmo CNPJ');

select lives_ok(
  $$ insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
     values ('Dona Maria', '12345678901', 'servico_domestico', 'x',
             'POINT(0 0)'::extensions.geography) $$,
  'CPF de 11 dígitos entra: serviço doméstico também contrata pelo Frila');

-- ── vaga ───────────────────────────────────────────────────────────────────────
create function pg_temp.vaga(p_posicoes smallint default 1,
                             p_alerta interval default '3 hours')
returns uuid language sql as $$
  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo,
                           alerta_antecedencia, chave_cliente)
  select (select id from public.estabelecimento where documento = '11222333000181'),
         (select id from public.funcao where nome = 'garçom'),
         now() + interval '4 h', now() + interval '12 h', 'CLN 201',
         'POINT(-47.8822 -15.7942)'::extensions.geography,
         12000, p_posicoes, true, false, false, 'Maître Zé', 'urgencia',
         p_alerta, gen_random_uuid()
  returning id;
$$;

select throws_ok(
  $$ select pg_temp.vaga(1::smallint, interval '0') $$,
  '23514',
  null,
  'alerta_positivo: janela crítica de zero nunca dispararia o alerta de vaga vazia (RF20)');

select throws_ok(
  $$ select pg_temp.vaga(0::smallint) $$,
  '23514',
  null,
  'vaga com zero posições não é vaga');

-- O teto de 200 não está na Modelagem; vem do contrato (NovaVaga.posicoes, maximum 200).
-- Existe para que um erro de digitação não gere duzentas mil posições e, com elas,
-- duzentas mil notificações.
select throws_ok(
  $$ select pg_temp.vaga(201::smallint) $$,
  '23514',
  null,
  'o teto de 200 posições do contrato vale no banco');

-- ── turno ──────────────────────────────────────────────────────────────────────
create temp table pos as
  select p.id from public.posicao p limit 0;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento)
values ('eeeeeeee-0000-0000-0000-000000000003','profissional','Ana','+5561999990003','ana@t.test','1995-01-01');
insert into public.profissional (usuario_id, ponto_base)
values ('eeeeeeee-0000-0000-0000-000000000003','POINT(-47.88 -15.79)'::extensions.geography);

insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select pg_temp.vaga(), 'confirmada',
       (select id from public.profissional where usuario_id = 'eeeeeeee-0000-0000-0000-000000000003'),
       now(), now() + interval '4 h', now() + interval '12 h';

create temp table p1 as select id from public.posicao limit 1;

select throws_ok(
  $$ insert into public.turno (posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
                               valor_acordado_centavos)
     select id, now(), 'manual', -5, 12000 from p1 $$,
  '23514',
  null,
  'distância de check-in negativa não existe');

select throws_ok(
  $$ insert into public.turno (posicao_id, checkout_em, checkout_distancia_m,
                               valor_acordado_centavos)
     select id, now(), -5, 12000 from p1 $$,
  '23514',
  null,
  'distância de check-out negativa não existe');

-- RN18. O valor é copiado da vaga na confirmação e é o que o profissional recebe
-- integralmente (RN01); zero ou negativo não é um turno.
select throws_ok(
  $$ insert into public.turno (posicao_id, valor_acordado_centavos)
     select id, 0 from p1 $$,
  '23514',
  null,
  'RN18: turno com valor acordado zero não existe');

select * from finish();
rollback;
