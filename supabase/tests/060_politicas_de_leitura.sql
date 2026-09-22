-- As dezenove políticas de leitura, lidas como três identidades diferentes.
--
-- Uma política escrita não é uma política em vigor. Estes testes entram como o
-- profissional, como o contratante de outro estabelecimento e como uma conta
-- bloqueada, e conferem o que cada um alcança — que é a única forma de saber se o
-- telefone de alguém sai por engano.

begin;
select plan(53);

-- Executa `sql` com a identidade de uma conta, como o PostgREST faria: role
-- `authenticated` e o `sub` do JWT apontando para a conta. `auth.uid()` lê daí.
create function pg_temp.contar_como(conta uuid, sql text) returns integer
language plpgsql as $$
declare n integer;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into n;
  reset role;
  execute 'reset request.jwt.claims';
  return n;
end $$;

-- ── O cenário ──────────────────────────────────────────────────────────────────
--
-- Dois estabelecimentos, três profissionais. O Bar do Zé publica duas vagas, uma
-- aberta e uma já encerrada. A Ana se candidata à aberta. O Bar bloqueia o Caio.

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('11111111-0000-0000-0000-000000000001','profissional','Ana',  '+5561999990001','ana@t.test','1995-01-01', '2026-09-22', now()),
  ('11111111-0000-0000-0000-000000000002','profissional','Beto', '+5561999990002','beto@t.test','1995-01-01', '2026-09-22', now()),
  ('11111111-0000-0000-0000-000000000003','profissional','Caio', '+5561999990003','caio@t.test','1995-01-01', '2026-09-22', now()),
  ('22222222-0000-0000-0000-000000000001','contratante', 'Zé',   '+5561999990011','ze@t.test','1980-01-01', '2026-09-22', now()),
  ('22222222-0000-0000-0000-000000000002','contratante', 'Rita', '+5561999990012','rita@t.test','1980-01-01', '2026-09-22', now());

insert into public.profissional (usuario_id, ponto_base) values
  ('11111111-0000-0000-0000-000000000001','POINT(-47.88 -15.79)'::extensions.geography),
  ('11111111-0000-0000-0000-000000000002','POINT(-47.88 -15.79)'::extensions.geography),
  ('11111111-0000-0000-0000-000000000003','POINT(-47.88 -15.79)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('33333333-0000-0000-0000-000000000001','Bar do Zé','11222333000181','food_service','CLN 201',
   'POINT(-47.8822 -15.7942)'::extensions.geography),
  ('33333333-0000-0000-0000-000000000002','Buffet da Rita','44555666000199','evento','SIA',
   'POINT(-47.9 -15.8)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('22222222-0000-0000-0000-000000000001','33333333-0000-0000-0000-000000000001','administrador'),
  ('22222222-0000-0000-0000-000000000002','33333333-0000-0000-0000-000000000002','administrador');

create function pg_temp.vaga(estab uuid, estado public.estado_vaga) returns uuid
language sql as $$
  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, estado, chave_cliente)
  select estab, (select id from public.funcao where nome = 'garçom'),
         now() + interval '4 h', now() + interval '12 h', 'CLN 201',
         'POINT(-47.8822 -15.7942)'::extensions.geography,
         12000, 1, true, false, false, 'Maître Zé', 'urgencia', estado, gen_random_uuid()
  returning id;
$$;

create temp table v as
  select pg_temp.vaga('33333333-0000-0000-0000-000000000001','publicada') as aberta,
         pg_temp.vaga('33333333-0000-0000-0000-000000000001','encerrada') as fechada,
         pg_temp.vaga('33333333-0000-0000-0000-000000000002','publicada') as da_rita;

insert into public.posicao (vaga_id, inicio_em, fim_em)
select aberta, now() + interval '4 h', now() + interval '12 h' from v;

insert into public.candidatura (posicao_id, profissional_id)
select p.id, (select id from public.profissional where usuario_id = '11111111-0000-0000-0000-000000000001')
  from public.posicao p, v where p.vaga_id = v.aberta;

-- RF26: o Zé bloqueia o Caio. Vale nos dois sentidos e para as vagas do bar inteiro.
insert into public.bloqueio (autor_id, bloqueado_id)
values ('22222222-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000003');

-- ── usuario: ninguém lê a linha de ninguém ─────────────────────────────────────
--
-- RLS filtra linha, não coluna, e `usuario` mistura o nome (que a contraparte pode
-- ver), o e-mail e o nascimento (só do dono) e o telefone (que tem prazo, RN10).
-- Por isso a política não abre a linha para outra pessoa: o que a contraparte vê sai
-- por função, com as colunas escolhidas.
select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.usuario'),
  1,
  'a conta lê a própria linha de usuario');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    $$ select count(*)::int from public.usuario
        where id = '11111111-0000-0000-0000-000000000002' $$),
  0,
  'RN10: um profissional não alcança o telefone de outro pela tabela');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    $$ select count(*)::int from public.usuario
        where id = '11111111-0000-0000-0000-000000000001' $$),
  0,
  'nem o contratante lê a linha de usuario de quem se candidatou à vaga dele');

-- ── profissional: o ponto base é quase o endereço de alguém ────────────────────
select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.profissional'),
  1,
  'o profissional lê o próprio perfil');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    'select count(*)::int from public.profissional'),
  0,
  'o contratante não lê ponto_base de ninguém');

-- ── estabelecimento e equipe ───────────────────────────────────────────────────
select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    'select count(*)::int from public.estabelecimento'),
  1,
  'o membro lê o próprio estabelecimento, e só ele');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.estabelecimento'),
  0,
  'o profissional não lê a tabela de estabelecimento direto — o que ele vê da casa sai pela função de vaga');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000002',
    'select count(*)::int from public.membro_estabelecimento'),
  1,
  'a Rita vê os membros do buffet dela, não os do bar do Zé');

-- ── catálogo e grade ───────────────────────────────────────────────────────────
select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.funcao'),
  32,
  'o catálogo de funções é aberto a quem está logado');

insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
select id, 5, '18:00', '02:00' from public.profissional
 where usuario_id = '11111111-0000-0000-0000-000000000001';

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    'select count(*)::int from public.disponibilidade'),
  0,
  'a grade semanal de um profissional não é visível para outro');

-- ── vaga: o coração das políticas ──────────────────────────────────────────────
select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    'select count(*)::int from public.vaga'),
  2,
  'o membro vê todas as vagas do estabelecimento, inclusive as encerradas');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000002',
    $$ select count(*)::int from public.vaga
        where estabelecimento_id = '33333333-0000-0000-0000-000000000001' $$),
  0,
  'o contratante de outro estabelecimento não vê vaga nenhuma da casa do vizinho');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    'select count(*)::int from public.vaga'),
  2,
  'o profissional vê as vagas publicadas — as duas casas — e não a encerrada');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    $$ select count(*)::int from public.vaga where estado = 'encerrada' $$),
  0,
  'vaga encerrada some para quem não é da casa');

-- RF26: o bloqueio tira as vagas do estabelecimento inteiro da frente do bloqueado.
select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000003',
    $$ select count(*)::int from public.vaga
        where estabelecimento_id = '33333333-0000-0000-0000-000000000001' $$),
  0,
  'RF26: quem foi bloqueado pelo Zé não enxerga vaga alguma do bar');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000003',
    $$ select count(*)::int from public.vaga
        where estabelecimento_id = '33333333-0000-0000-0000-000000000002' $$),
  1,
  'e continua enxergando as vagas do buffet, que não tem nada com isso');

-- ── candidatura ────────────────────────────────────────────────────────────────
select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.candidatura'),
  1,
  'o profissional lê a própria candidatura');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    'select count(*)::int from public.candidatura'),
  0,
  'e não lê a de outro');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    'select count(*)::int from public.candidatura'),
  1,
  'o membro lê as candidaturas das vagas do estabelecimento');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000002',
    'select count(*)::int from public.candidatura'),
  0,
  'e não as do vizinho');

-- ── avaliação, bloqueio e despacho: só quem escreveu, e só o dono ──────────────
--
-- A resposta individual à vista convidaria à retaliação, e a pergunta binária só
-- funciona se a pessoa responde sem medo. Quem foi bloqueado não sabe por quem, e
-- saber quem foi notificado de uma vaga revelaria quem está perto e disponível.
select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000003',
    'select count(*)::int from public.bloqueio'),
  0,
  'quem foi bloqueado não descobre por quem');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    'select count(*)::int from public.bloqueio'),
  1,
  'quem bloqueou lê o próprio bloqueio');

insert into public.despacho (vaga_id, profissional_id)
select aberta, (select id from public.profissional where usuario_id = '11111111-0000-0000-0000-000000000001')
  from v;

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    'select count(*)::int from public.despacho'),
  0,
  'o estabelecimento não vê o despacho: isso revelaria quem está perto e livre naquele horário');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.despacho'),
  1,
  'o profissional vê o que foi despachado para ele');

-- ── As políticas que só a afirmação negativa não prova ─────────────────────────
--
-- Derrubar uma política de leitura **fecha** dados, não abre. Uma suíte só com
-- asserções do tipo "fulano não lê" continua verde com a política removida: o mutante
-- mediu dez políticas nessa situação. Cada uma precisa de ao menos um "fulano lê",
-- e é o que vem abaixo.

create temp table ids as select
  (select id from public.profissional where usuario_id = '11111111-0000-0000-0000-000000000001') as ana,
  (select id from public.posicao p, v where p.vaga_id = v.aberta limit 1)                        as posicao;

insert into public.profissional_funcao (profissional_id, funcao_id)
select ana, (select id from public.funcao where nome = 'garçom') from ids;

insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select '33333333-0000-0000-0000-000000000001', ana from ids;

insert into public.evento (estabelecimento_id, nome, data, local)
values ('33333333-0000-0000-0000-000000000001','Formatura','2026-12-05','Clube');

insert into public.dispositivo (usuario_id, token_fcm, plataforma)
values ('11111111-0000-0000-0000-000000000001', repeat('t', 40), 'ios');

insert into public.notificacao (profissional_id) select ana from ids;

insert into public.ocorrencia (tipo, autor_id, usuario_id, motivo)
values ('suspensao','22222222-0000-0000-0000-000000000001',
        '11111111-0000-0000-0000-000000000002','Denúncia grave confirmada');

-- A posição confirmada vira turno, que os dois lados leem, e o turno vira avaliação.
update public.posicao set estado = 'confirmada', confirmado_em = now(),
       profissional_id = (select ana from ids),
       inicio_em = now() - interval '10 h', fim_em = now() - interval '2 h'
 where id = (select posicao from ids);

insert into public.turno (posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
                          verificacao, valor_acordado_centavos)
select posicao, now() - interval '10 h', 'geolocalizado', 50, 'verificado', 12000 from ids;

insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
select t.id, '11111111-0000-0000-0000-000000000001', 'estabelecimento',
       '33333333-0000-0000-0000-000000000001', true
  from public.turno t;

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.disponibilidade'),
  1,
  'o profissional lê a própria grade semanal');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.profissional_funcao'),
  1,
  'e as próprias funções declaradas');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.equipe_confianca'),
  1,
  'RF18: o profissional sabe de que equipes de confiança faz parte');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    'select count(*)::int from public.equipe_confianca'),
  1,
  'e o estabelecimento lê a própria equipe');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    'select count(*)::int from public.evento'),
  1,
  'o membro lê os eventos do estabelecimento');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000002',
    'select count(*)::int from public.evento'),
  0,
  'e o vizinho não');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.dispositivo'),
  1,
  'cada um lê os próprios aparelhos');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.notificacao'),
  1,
  'e as próprias notificações');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.posicao'),
  1,
  'o profissional lê a posição que ocupa');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    'select count(*)::int from public.posicao'),
  1,
  'e o membro lê as posições das vagas da casa');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.turno'),
  1,
  'o turno fica para os dois lados: o profissional lê o dele');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    'select count(*)::int from public.turno'),
  1,
  'e o contratante lê o mesmo turno');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000001',
    'select count(*)::int from public.avaliacao'),
  1,
  'quem avaliou lê a própria resposta');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    'select count(*)::int from public.avaliacao'),
  0,
  'RN07: quem foi avaliado não vê quem respondeu o quê — vê o agregado, com o denominador');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000001',
    'select count(*)::int from public.ocorrencia'),
  1,
  'quem abriu a ocorrência a lê');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    'select count(*)::int from public.ocorrencia'),
  1,
  'RN13: e o suspenso lê a própria suspensão, com o motivo e o caminho para contestar');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000003',
    'select count(*)::int from public.ocorrencia'),
  0,
  'mas a ocorrência de outra pessoa não aparece');

-- ── O que a mutação não enxerga: política frouxa demais ────────────────────────
--
-- Derrubar uma política de leitura **fecha** dado, então o verificador de mutação só
-- pega a ausência de uma asserção positiva. Ele não pega o contrário: um `using (true)`
-- posto por engano abriria a tabela inteira e a suíte seguiria verde, porque toda
-- asserção do tipo "fulano lê o próprio" continua verdadeira.
--
-- Uma revisão mediu isso: trocando o `using` de cada política por `true`, seis
-- sobreviveram. O que passaria despercebido era o token de push da Ana, a distância do
-- check-in dela, o valor acordado do turno, a posição confirmada, o histórico de
-- notificação, as funções declaradas e as equipes de que ela faz parte.
--
-- A defesa é a asserção simétrica: para cada "fulano lê o próprio", um "sicrano não lê
-- o de fulano". O Beto serve de contraparte — é profissional, ativo, e não tem relação
-- nenhuma com nada disto.

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    'select count(*)::int from public.dispositivo'),
  0,
  'o token de push de um aparelho não vaza para outro profissional');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    'select count(*)::int from public.notificacao'),
  0,
  'nem o histórico de notificação, que diria quando e quantas vezes alguém foi chamado');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    'select count(*)::int from public.profissional_funcao'),
  0,
  'nem as funções que outro profissional declarou');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    'select count(*)::int from public.equipe_confianca'),
  0,
  'RF18: de que equipes alguém faz parte é assunto entre ele e a casa');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    'select count(*)::int from public.posicao'),
  0,
  'a posição de um turno confirmado não aparece para quem não é das duas partes');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    'select count(*)::int from public.turno'),
  0,
  'RN22: nem o turno, que carrega a distância do check-in e o valor acordado');

-- ── O membro não fica bloqueado com o próprio estabelecimento ──────────────────
--
-- O Zé bloqueou o Caio. A auxiliar de bloqueio perguntava se a conta e algum membro
-- aparecem no mesmo bloqueio — e o Zé satisfazia as duas pontas sozinho.
select is(
  (select privado.bloqueado_com_estabelecimento(
            '22222222-0000-0000-0000-000000000001',
            '33333333-0000-0000-0000-000000000001')),
  false,
  'quem bloqueia alguém não fica bloqueado com a própria casa');

select is(
  (select privado.bloqueado_com_estabelecimento(
            '11111111-0000-0000-0000-000000000003',
            '33333333-0000-0000-0000-000000000001')),
  true,
  'e o bloqueado continua bloqueado');

-- ── O operador lê o mesmo que o administrador ─────────────────────────────────
--
-- Decisão da Modelagem: `eh_administrador` não aparece em nenhuma política de leitura.
-- O papel separa quem **faz** certas coisas, não quem enxerga. Sem um operador no
-- cenário, essa propriedade não era medida — e alguém "endureceria" as políticas por
-- reflexo, tirando o operador da leitura do próprio estabelecimento.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('22222222-0000-0000-0000-000000000003','contratante','Nina','+5561999990013','nina@t.test','1990-01-01', '2026-09-22', now());
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('22222222-0000-0000-0000-000000000003','33333333-0000-0000-0000-000000000001','operador');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000003',
    'select count(*)::int from public.vaga'),
  2,
  'o operador lê as mesmas vagas que o administrador: o papel separa quem faz, não quem vê');

select is(
  pg_temp.contar_como('22222222-0000-0000-0000-000000000003',
    'select count(*)::int from public.candidatura'),
  1,
  'e as mesmas candidaturas');

-- ── Conta suspensa ─────────────────────────────────────────────────────────────
--
-- Nenhuma política olha `usuario.estado`, e isso é deliberado: o contrato recusa no
-- momento da ação (`422 inelegivel` com `perfil_suspenso`), não na leitura. Quem está
-- suspenso precisa continuar lendo a própria conta para ver o motivo e contestar
-- (RN13, RF24) — fechar a leitura fecharia justamente o caminho do direito de defesa.
--
-- O teste existe para que a decisão seja decisão, e não descuido: se alguém fechar a
-- leitura por reflexo, ele fica vermelho e a conversa acontece.
update public.usuario set estado = 'suspensa'
 where id = '11111111-0000-0000-0000-000000000002';

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    'select count(*)::int from public.usuario'),
  1,
  'RN13: conta suspensa continua lendo a própria linha — é por ela que o motivo e a contestação chegam');

select is(
  pg_temp.contar_como('11111111-0000-0000-0000-000000000002',
    $$ select count(*)::int from public.vaga where estado = 'publicada' $$),
  2,
  'e continua vendo as vagas: a recusa é no ato de se candidatar, não na leitura');

select * from finish();
rollback;
