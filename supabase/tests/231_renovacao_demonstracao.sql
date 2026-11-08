-- Renovação dos dados de demonstração (cartão RzllRo3o, item 6):
--
-- Assegura que:
--   1. A renovação cria/atualiza as vagas e turnos de demonstração com datas sempre à frente do relógio.
--   2. Vagas e turnos ficam visíveis e operáveis pelas contas de revisão (vagas_abertas, meus_turnos, contato_do_turno).
--   3. A renovação é estritamente idempotente e restaura um turno consumido de volta para o estado virgem (pendente de check-in).
--   4. A renovação aceita data futura parametrizada, reposicionando vagas e turnos sem acoplamento a datas literais.
--   5. Tomada de conta (B-DEMO, Lince Codex B1/B2 e Lince AG 2): conta avulsa no endereço antigo ou
--      no novo nunca é adotada como conta de demonstração; sem o canônico, a conta avulsa faz falhar fechado.

begin;
select plan(41);

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

-- ── 1. Primeira Execução da Renovação ─────────────────────────────────────────

select lives_ok(
  $$ select privado.renovar_dados_demonstracao() $$,
  'primeira execução da renovação completa sem erro'
);

-- Vaga Aberta (20)
select is(
  (select estado::text from public.vaga where id = 'de000000-0000-4000-8000-000000000020'),
  'publicada',
  'vaga aberta nasce em estado publicada'
);

select ok(
  (select inicio_em > privado.agora() from public.vaga where id = 'de000000-0000-4000-8000-000000000020'),
  'vaga aberta tem inicio_em à frente de privado.agora()'
);

select ok(
  (select fim_em = inicio_em + interval '6 hours' from public.vaga where id = 'de000000-0000-4000-8000-000000000020'),
  'vaga aberta tem duração prevista de 6 horas'
);

-- Posição da Vaga Aberta (30)
select is(
  (select estado::text from public.posicao where id = 'de000000-0000-4000-8000-000000000030'),
  'aberta',
  'posição da vaga aberta nasce em estado aberta'
);

select is(
  (select profissional_id from public.posicao where id = 'de000000-0000-4000-8000-000000000030'),
  null,
  'posição da vaga aberta nasce sem profissional associado'
);

select ok(
  (select inicio_em > privado.agora() from public.posicao where id = 'de000000-0000-4000-8000-000000000030'),
  'posição da vaga aberta tem inicio_em à frente de privado.agora()'
);

-- Vaga Preenchida (21)
select is(
  (select estado::text from public.vaga where id = 'de000000-0000-4000-8000-000000000021'),
  'preenchida',
  'vaga preenchida nasce em estado preenchida'
);

select ok(
  (select inicio_em > privado.agora() from public.vaga where id = 'de000000-0000-4000-8000-000000000021'),
  'vaga preenchida tem inicio_em à frente de privado.agora()'
);

-- Posição Confirmada (31)
select is(
  (select estado::text from public.posicao where id = 'de000000-0000-4000-8000-000000000031'),
  'confirmada',
  'posição do turno nasce em estado confirmada'
);

select is(
  (select profissional_id from public.posicao where id = 'de000000-0000-4000-8000-000000000031'),
  (select id from public.profissional where usuario_id = 'de000000-0000-4000-8000-000000000002'),
  'posição confirmada vinculada ao profissional de revisão'
);

select ok(
  (select inicio_em > privado.agora() from public.posicao where id = 'de000000-0000-4000-8000-000000000031'),
  'posição confirmada tem inicio_em à frente de privado.agora()'
);

-- Turno Confirmado (31)
select is(
  (select verificacao::text from public.turno where posicao_id = 'de000000-0000-4000-8000-000000000031'),
  'pendente',
  'turno nasce em estado pendente de presença'
);

select is(
  (select checkin_em from public.turno where posicao_id = 'de000000-0000-4000-8000-000000000031'),
  null,
  'turno nasce sem checkin_em registrado'
);

select is(
  (select checkout_em from public.turno where posicao_id = 'de000000-0000-4000-8000-000000000031'),
  null,
  'turno nasce sem checkout_em registrado'
);

-- Visibilidade pelas Contas de Revisão via RPCs
select ok(
  ((pg_temp.como('de000000-0000-4000-8000-000000000002',
                 $$ select public.vagas_abertas() $$))->0->>'id')::uuid = 'de000000-0000-4000-8000-000000000020',
  'vagas_abertas retorna a vaga de demonstração aberta'
);

select ok(
  ((pg_temp.como('de000000-0000-4000-8000-000000000002',
                 $$ select public.meus_turnos() $$))->0->>'posicao_id')::uuid = 'de000000-0000-4000-8000-000000000031',
  'meus_turnos retorna o turno confirmado do profissional de revisão'
);

select isnt(
  (pg_temp.como('de000000-0000-4000-8000-000000000002',
                $$ select public.contato_do_turno((select id from public.turno where posicao_id = 'de000000-0000-4000-8000-000000000031')) $$))->>'telefone',
  null,
  'contato_do_turno está liberado e não expirado (fim_em futuro)'
);

-- ── 2. Simulação de Uso e Consumo do Turno ─────────────────────────────────────

-- Consome o turno com check-in e check-out (geolocalizado com distância para verificacao_coerente)
update public.turno
   set checkin_em          = now(),
       checkin_tipo        = 'geolocalizado',
       checkin_distancia_m = 50,
       checkin_recebido_em = now(),
       verificacao         = 'verificado',
       checkout_em         = now(),
       checkout_recebido_em= now()
 where posicao_id = 'de000000-0000-4000-8000-000000000031';

-- Candidatura na vaga aberta
insert into public.candidatura (posicao_id, profissional_id)
values ('de000000-0000-4000-8000-000000000030',
        (select id from public.profissional where usuario_id = 'de000000-0000-4000-8000-000000000002'));

-- Tentativa gasta na porta
insert into public.entrada_demonstracao (email, aceita)
values ('revisao-profissional@frilabr.com', false);

-- Vaga aberta alterada
update public.vaga set estado = 'cancelada' where id = 'de000000-0000-4000-8000-000000000020';

-- ── 3. Segunda Execução da Renovação (Idempotência e Restauração) ─────────────

select lives_ok(
  $$ select privado.renovar_dados_demonstracao() $$,
  'segunda execução da renovação roda com sucesso (idempotente)'
);

select is(
  (select estado::text from public.vaga where id = 'de000000-0000-4000-8000-000000000020'),
  'publicada',
  'vaga aberta restaurada para publicada'
);

select is(
  (select count(*)::int from public.candidatura where posicao_id = 'de000000-0000-4000-8000-000000000030'),
  0,
  'candidaturas na vaga aberta foram expurgadas'
);

select is(
  (select verificacao::text from public.turno where posicao_id = 'de000000-0000-4000-8000-000000000031'),
  'pendente',
  'turno consumido restaurado para pendente de check-in'
);

select is(
  (select checkin_em from public.turno where posicao_id = 'de000000-0000-4000-8000-000000000031'),
  null,
  'checkin_em limpo para null'
);

select is(
  (select checkout_em from public.turno where posicao_id = 'de000000-0000-4000-8000-000000000031'),
  null,
  'checkout_em limpo para null'
);

select is(
  (select count(*)::int from public.entrada_demonstracao where email = 'revisao-profissional@frilabr.com'),
  0,
  'tentativas gastas em entrada_demonstracao foram zeradas'
);

-- ── 4. Terceira Execução com Data Futura (Parametrização do Tempo) ────────────

do $$
declare
  v_futuro timestamptz := privado.agora() + interval '60 days';
begin
  perform privado.renovar_dados_demonstracao(v_futuro);
end $$;

select ok(
  (select inicio_em >= privado.agora() + interval '64 days' from public.vaga where id = 'de000000-0000-4000-8000-000000000020'),
  'vaga aberta reposicionada 5 dias à frente da data futura parametrizada (+60 dias)'
);

select ok(
  (select inicio_em >= privado.agora() + interval '61 days' from public.vaga where id = 'de000000-0000-4000-8000-000000000021'),
  'vaga preenchida reposicionada 2 dias à frente da data futura parametrizada (+60 dias)'
);

select ok(
  (select inicio_em >= privado.agora() + interval '61 days' from public.posicao where id = 'de000000-0000-4000-8000-000000000031'),
  'posição do turno confirmada reposicionada 2 dias à frente da data futura parametrizada (+60 dias)'
);

-- ── 5. Tomada de conta (B-DEMO) ────────────────────────────────────────────────
--
-- Os endereços das contas de demonstração são públicos neste repositório. Quem criar conta com
-- eles (um /otp anônimo, um generate_link, um app que não reconhece o endereço) não pode virar
-- conta de demonstração nem administradora do Bar da Revisão.

-- 5.1 Depois da troca: as canônicas em @frilabr.com e alguém cria conta no endereço antigo
-- (Lince Codex, B1: com a função antiga, essa conta virava administradora).
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'a2310000-0000-4000-8000-0000000000b1', 'authenticated',
        'authenticated', 'revisao-contratante@frila.app', now(), now(), false, false);

select lives_ok($$ select privado.renovar_dados_demonstracao() $$,
  'tomada 1: a renovação roda com uma conta avulsa no endereço antigo');
select is((select count(*)::int from public.usuario where id = 'a2310000-0000-4000-8000-0000000000b1'),
  0, 'tomada 1: a conta no endereço antigo não é adotada como conta de demonstração');

delete from auth.users where id = 'a2310000-0000-4000-8000-0000000000b1';

-- 5.2 Antes da troca (cenário x443 do Lince AG 2): as canônicas ainda em @frila.app e uma linha
-- avulsa com o endereço novo, como o Auth cria quando alguém pede código para ele.
update public.usuario set email = replace(email, '@frilabr.com', '@frila.app')
 where id in ('de000000-0000-4000-8000-000000000001', 'de000000-0000-4000-8000-000000000002');
update auth.users set email = replace(email, '@frilabr.com', '@frila.app')
 where id in ('de000000-0000-4000-8000-000000000001', 'de000000-0000-4000-8000-000000000002');
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'a2310000-0000-4000-8000-0000000000b2', 'authenticated',
        'authenticated', 'revisao-contratante@frilabr.com', now(), now(), false, false);

select lives_ok($$ select privado.renovar_dados_demonstracao() $$,
  'tomada 2: a renovação roda com uma linha avulsa no endereço novo');
select is((select count(*)::int from public.usuario where id = 'a2310000-0000-4000-8000-0000000000b2'),
  0, 'tomada 2: a linha avulsa com o endereço novo não é adotada');
select is((select count(*)::int from public.membro_estabelecimento
            where estabelecimento_id = 'de000000-0000-4000-8000-000000000010' and papel = 'administrador'),
  1, 'tomada 2: o Bar da Revisão tem uma administradora só, a canônica');
select is((select count(*)::int from public.usuario where demonstracao and perfil = 'contratante'),
  1, 'tomada 2: uma conta contratante de demonstração, sem duplicata');
select is(privado.resolver_conta_demonstracao('de000000-0000-4000-8000-000000000001'::uuid,
                                              'revisao-contratante@frilabr.com'),
  'de000000-0000-4000-8000-000000000001'::uuid,
  'tomada 2: com o canônico no banco, ele vence a linha avulsa que tem o endereço novo');
select lives_ok($$ select privado.semear_vagas_demonstracao(1, null, 1) $$,
  'tomada 2: a semeadura roda com a linha avulsa no endereço novo');
select is((select count(*)::int from public.usuario where id = 'a2310000-0000-4000-8000-0000000000b2'),
  0, 'tomada 2: a semeadura também não adota a linha avulsa');
select throws_ok(
  $$ update auth.users set email = 'revisao-contratante@frilabr.com' where id = 'de000000-0000-4000-8000-000000000001' $$,
  '23505', null,
  'pré-teste da troca: com a linha avulsa no endereço novo, trocar o e-mail da canônica bate no índice único');

-- 5.3 Sem o canônico (ambiente em que ele não existe): a conta com o endereço só é aceita se já for
-- de demonstração; uma avulsa faz falhar fechado; sem conta nenhuma, vale o canônico.
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'a2310000-0000-4000-8000-0000000000b3', 'authenticated',
        'authenticated', 'avulsa-231@frilabr.com', now(), now(), false, false),
       ('00000000-0000-0000-0000-000000000000', 'a2310000-0000-4000-8000-0000000000b4', 'authenticated',
        'authenticated', 'demonstracao-231@frilabr.com', now(), now(), false, false);
-- A avulsa tem public.usuario, mas com demonstracao = false: ter usuário não basta para ser adotada.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
values ('a2310000-0000-4000-8000-0000000000b3', 'contratante', 'Avulsa 231', '+5561999982311',
        'avulsa-231@frilabr.com', '1985-01-01', '2026-09-22', privado.agora(), false),
       ('a2310000-0000-4000-8000-0000000000b4', 'contratante', 'Demonstração 231', '+5561999982310',
        'demonstracao-231@frilabr.com', '1985-01-01', '2026-09-22', privado.agora(), true);

select throws_like(
  $$ select privado.resolver_conta_demonstracao('a2310000-0000-4000-8000-0000000000c0'::uuid, 'avulsa-231@frilabr.com') $$,
  '%conta_de_demonstracao_nao_canonica%',
  'sem o canônico: a conta avulsa com o endereço (com usuário, mas demonstracao = false) faz falhar fechado (409), sem adotar');
select is(privado.resolver_conta_demonstracao('a2310000-0000-4000-8000-0000000000c0'::uuid, 'demonstracao-231@frilabr.com'),
  'a2310000-0000-4000-8000-0000000000b4'::uuid,
  'sem o canônico: a conta com o endereço que já é de demonstração é aceita');
select is(privado.resolver_conta_demonstracao('a2310000-0000-4000-8000-0000000000c1'::uuid, 'ninguem-231@frilabr.com'),
  'a2310000-0000-4000-8000-0000000000c1'::uuid,
  'sem conta nenhuma com o endereço: vale o canônico, que a renovação cria');

select * from finish();
rollback;
