-- Cenários de desenvolvimento: as contas, as casas e os turnos do Frila no DF.
--
-- ── Por que este arquivo não é o seed.sql ──────────────────────────────────────
--
-- O cartão manda pôr os cenários em `supabase/seed.sql`. Não dá, e o próprio critério
-- de aceite do cartão diz por quê: *"o pipeline do frila-prod nunca aplica o
-- seed.sql"*. Acontece que `scripts/aplicar-remoto.sh` aplica — o `seed.sql` é o único
-- arquivo que ele executa contra um projeto remoto, porque lá ele é o catálogo de
-- funções, que é dado de produto e precisa existir em todo ambiente.
--
-- Cenário no `seed.sql` seria, portanto, estabelecimento fantasma no `frila-dev` na
-- próxima vez que alguém aplicasse migração. Então os dois se separam:
--
--   seed.sql       catálogo de funções · local, CI **e** remoto
--   cenarios.sql   dados de teste      · só local e CI, por `config.toml → sql_paths`
--
-- O conflito está comentado no cartão Cc2XYCi0.
--
-- ── O que **não** entra aqui ───────────────────────────────────────────────────
--
-- Uma linha em `privado.ambiente`. Ela torna `privado.agora()` sobreponível, e com ele
-- todo prazo do produto vira decoração: os 7 dias do contato (RN10), as 24 h do modo
-- seleção (RN24), o fim previsto que libera a avaliação (RN07). O marcador é escrito
-- pelo teste, dentro da transação, e desfeito no rollback — por isso não mora em
-- arquivo nenhum do repositório, e este é exatamente o arquivo onde alguém o colocaria
-- "só para facilitar". `supabase/tests/090_cenarios.sql` confere que continua fora.
--
-- ── O que está escrito aqui e o que é medido ───────────────────────────────────
--
-- As contagens desnormalizadas (`taxa_comparecimento`, `turnos_realizados`,
-- `aval_positivas`, `aval_total`) são **escritas à mão**, coerentes com os turnos e as
-- avaliações abaixo. Não há trigger que as calcule: o job de reconciliação é do
-- Sprint 2. A aritmética usada aqui é `cumpridas / (cumpridas + faltas)`; a definição
-- canônica está na Modelagem de Banco de Dados, e quando o job existir é ele quem
-- manda. Até lá, mudar um turno aqui obriga a mexer no número correspondente.
--
-- O mapa dos cenários, com para que serve cada um, está em `supabase/README.md`.

-- ── A âncora de tempo ──────────────────────────────────────────────────────────
--
-- Tudo o que tem hora aqui pende da próxima sexta-feira às 18:00 em São Paulo, que é
-- o começo do turno mais comum do setor.
--
-- Sexta, e não "daqui a três dias", porque a grade de disponibilidade é por dia da
-- semana: com uma data relativa a `now()`, o dia da semana da vaga mudaria conforme o
-- dia em que o `db reset` rodasse, e metade dos cenários de elegibilidade viraria
-- outra coisa às segundas-feiras.
--
-- O `+ 7 dias` no fim garante que a âncora esteja sempre entre 7 e 13 dias no futuro,
-- mesmo rodando numa sexta — a vaga em modo seleção precisa de mais de 24 h de
-- antecedência (RN24), e "a próxima sexta" pode ser hoje à noite.

drop table if exists _quando;
create temp table _quando as
select ((date_trunc('day', now() at time zone 'America/Sao_Paulo')
         + (((5 - extract(dow from now() at time zone 'America/Sao_Paulo')::int + 7) % 7) + 7)
             * interval '1 day'
         + interval '18 hours') at time zone 'America/Sao_Paulo') as sexta_18h;

-- ── As contas ──────────────────────────────────────────────────────────────────
--
-- Credencial em `auth.users` e conta no produto em `public.usuario`, nas duas pontas:
-- sem a primeira ninguém entra (o código do e-mail não tem onde chegar), sem a segunda
-- o app manda para o cadastro quem já está cadastrado.
--
-- No local, a entrada é a de sempre: pedir o código para o e-mail conhecido e ler o
-- código na caixa do `supabase start`, em http://127.0.0.1:54324. Não há senha.

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', c.id, 'authenticated', 'authenticated',
       c.email, now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
       now(), now(), false, false
  from (values
    ('a0000000-0000-4000-8000-000000000001'::uuid, 'ana@frila.test'),
    ('a0000000-0000-4000-8000-000000000002'::uuid, 'bruno@frila.test'),
    ('a0000000-0000-4000-8000-000000000003'::uuid, 'carla@frila.test'),
    ('a0000000-0000-4000-8000-000000000004'::uuid, 'diego@frila.test'),
    ('a0000000-0000-4000-8000-000000000005'::uuid, 'elisa@frila.test'),
    ('a0000000-0000-4000-8000-000000000006'::uuid, 'felipe@frila.test'),
    ('a0000000-0000-4000-8000-000000000007'::uuid, 'gabi@frila.test'),
    ('a0000000-0000-4000-8000-000000000008'::uuid, 'heitor@frila.test'),
    ('a0000000-0000-4000-8000-000000000009'::uuid, 'iara@frila.test'),
    ('a0000000-0000-4000-8000-000000000010'::uuid, 'joao@frila.test'),
    ('a0000000-0000-4000-8000-000000000011'::uuid, 'karen@frila.test'),
    ('a0000000-0000-4000-8000-000000000012'::uuid, 'leo@frila.test'),
    ('b0000000-0000-4000-8000-000000000001'::uuid, 'zelia@frila.test'),
    ('b0000000-0000-4000-8000-000000000002'::uuid, 'ricardo@frila.test'),
    ('b0000000-0000-4000-8000-000000000003'::uuid, 'marta@frila.test'),
    ('b0000000-0000-4000-8000-000000000004'::uuid, 'paulo@frila.test')
  ) as c(id, email)
on conflict (id) do nothing;

-- RN25: o perfil nasce aqui e não muda mais. Os telefones são do prefixo 61 e não
-- pertencem a ninguém: a faixa 6199999xxxx é a que o contrato usa nos exemplos.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado,
                            termos_versao, termos_aceite_em)
values
  ('a0000000-0000-4000-8000-000000000001','profissional','Ana Ribeiro',    '+5561999990001','ana@frila.test',    '1994-03-11','ativa',   '2026-09-22', now() - interval '60 days'),
  ('a0000000-0000-4000-8000-000000000002','profissional','Bruno Sales',    '+5561999990002','bruno@frila.test',  '1991-07-02','ativa',   '2026-09-22', now() - interval '58 days'),
  ('a0000000-0000-4000-8000-000000000003','profissional','Carla Nunes',    '+5561999990003','carla@frila.test',  '1999-11-23','ativa',   '2026-09-22', now() - interval '55 days'),
  ('a0000000-0000-4000-8000-000000000004','profissional','Diego Matos',    '+5561999990004','diego@frila.test',  '1988-01-30','ativa',   '2026-09-22', now() - interval '50 days'),
  -- RN13: a conta suspensa continua existindo e continua lendo o próprio histórico.
  ('a0000000-0000-4000-8000-000000000005','profissional','Elisa Prado',    '+5561999990005','elisa@frila.test',  '1996-05-19','suspensa','2026-09-22', now() - interval '48 days'),
  ('a0000000-0000-4000-8000-000000000006','profissional','Felipe Rocha',   '+5561999990006','felipe@frila.test', '1993-09-08','ativa',   '2026-09-22', now() - interval '45 days'),
  ('a0000000-0000-4000-8000-000000000007','profissional','Gabi Teles',     '+5561999990007','gabi@frila.test',   '2001-02-14','ativa',   '2026-09-22', now() - interval '40 days'),
  ('a0000000-0000-4000-8000-000000000008','profissional','Heitor Lima',    '+5561999990008','heitor@frila.test', '1985-12-01','ativa',   '2026-09-22', now() - interval '38 days'),
  ('a0000000-0000-4000-8000-000000000009','profissional','Iara Souza',     '+5561999990009','iara@frila.test',   '1997-06-27','ativa',   '2026-09-22', now() - interval '35 days'),
  ('a0000000-0000-4000-8000-000000000010','profissional','João Vitor Sá',  '+5561999990010','joao@frila.test',   '2000-08-05','ativa',   '2026-09-22', now() - interval '30 days'),
  -- Cadastrou-se ontem: é o perfil sem histórico, que RF16 manda mostrar como sem
  -- histórico e não como nota zero.
  ('a0000000-0000-4000-8000-000000000011','profissional','Karen Dias',     '+5561999990011','karen@frila.test',  '1998-04-17','ativa',   '2026-09-22', now() - interval '1 day'),
  ('a0000000-0000-4000-8000-000000000012','profissional','Léo Franco',     '+5561999990012','leo@frila.test',    '1992-10-09','ativa',   '2026-09-22', now() - interval '25 days'),

  ('b0000000-0000-4000-8000-000000000001','contratante', 'Zélia Martins',  '+5561999990101','zelia@frila.test',  '1979-02-21','ativa',   '2026-09-22', now() - interval '61 days'),
  ('b0000000-0000-4000-8000-000000000002','contratante', 'Ricardo Aguiar', '+5561999990102','ricardo@frila.test','1983-06-13','ativa',   '2026-09-22', now() - interval '61 days'),
  ('b0000000-0000-4000-8000-000000000003','contratante', 'Marta Bezerra',  '+5561999990103','marta@frila.test',  '1975-09-30','ativa',   '2026-09-22', now() - interval '59 days'),
  ('b0000000-0000-4000-8000-000000000004','contratante', 'Paulo Freitas',  '+5561999990104','paulo@frila.test',  '1990-12-04','ativa',   '2026-09-22', now() - interval '20 days')
on conflict (id) do nothing;

-- ── Os profissionais ───────────────────────────────────────────────────────────
--
-- O ponto base decide a distância de RN05, e só ela: não existe rastreamento, e o
-- ponto não é mostrado a ninguém. Três regiões do DF, escolhidas pela distância entre
-- elas — Asa Norte e Lago Sul se alcançam dentro dos 15 km, Águas Claras não alcança
-- nenhuma das duas.
--
-- As contagens abaixo são coerentes com os turnos mais adiante; ver o cabeçalho.

insert into public.profissional (id, usuario_id, ponto_base, taxa_comparecimento,
                                 turnos_realizados, aval_positivas, aval_total)
values
  ('e0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001','POINT(-47.8830 -15.7650)'::extensions.geography, 1.000, 1, 1, 1),
  ('e0000000-0000-4000-8000-000000000002','a0000000-0000-4000-8000-000000000002','POINT(-47.8795 -15.7590)'::extensions.geography, 1.000, 1, 0, 0),
  ('e0000000-0000-4000-8000-000000000003','a0000000-0000-4000-8000-000000000003','POINT(-47.8910 -15.7710)'::extensions.geography, 1.000, 1, 0, 0),
  ('e0000000-0000-4000-8000-000000000004','a0000000-0000-4000-8000-000000000004','POINT(-48.0300 -15.8360)'::extensions.geography, null,  0, 0, 0),
  ('e0000000-0000-4000-8000-000000000005','a0000000-0000-4000-8000-000000000005','POINT(-47.8840 -15.7680)'::extensions.geography, null,  0, 0, 0),
  ('e0000000-0000-4000-8000-000000000006','a0000000-0000-4000-8000-000000000006','POINT(-47.8860 -15.7600)'::extensions.geography, null,  0, 0, 0),
  ('e0000000-0000-4000-8000-000000000007','a0000000-0000-4000-8000-000000000007','POINT(-47.8880 -15.7640)'::extensions.geography, null,  0, 0, 0),
  ('e0000000-0000-4000-8000-000000000008','a0000000-0000-4000-8000-000000000008','POINT(-47.8450 -15.8280)'::extensions.geography, 1.000, 1, 0, 1),
  ('e0000000-0000-4000-8000-000000000009','a0000000-0000-4000-8000-000000000009','POINT(-48.0270 -15.8320)'::extensions.geography, null,  0, 0, 0),
  ('e0000000-0000-4000-8000-000000000010','a0000000-0000-4000-8000-000000000010','POINT(-47.8905 -15.7585)'::extensions.geography, 1.000, 1, 1, 1),
  -- Sem histórico: `taxa_comparecimento` nula, e não 0.000. As duas contam histórias
  -- opostas sobre quem acabou de chegar, e a tela precisa saber a diferença (RF16).
  ('e0000000-0000-4000-8000-000000000011','a0000000-0000-4000-8000-000000000011','POINT(-47.8820 -15.7625)'::extensions.geography, null,  0, 0, 0),
  -- Faltou ao único turno que tinha: 0 de 1.
  ('e0000000-0000-4000-8000-000000000012','a0000000-0000-4000-8000-000000000012','POINT(-47.8850 -15.7665)'::extensions.geography, 0.000, 0, 0, 0)
on conflict (id) do nothing;

insert into public.profissional_funcao (profissional_id, funcao_id)
select p.id, f.id
  from (values
    ('e0000000-0000-4000-8000-000000000001','garçom'),
    ('e0000000-0000-4000-8000-000000000001','bartender'),
    ('e0000000-0000-4000-8000-000000000002','chapeiro'),
    ('e0000000-0000-4000-8000-000000000002','limpeza pós-evento'),
    ('e0000000-0000-4000-8000-000000000003','garçom'),
    ('e0000000-0000-4000-8000-000000000003','limpeza pós-evento'),
    ('e0000000-0000-4000-8000-000000000004','garçom'),
    ('e0000000-0000-4000-8000-000000000005','garçom'),
    ('e0000000-0000-4000-8000-000000000006','garçom'),
    ('e0000000-0000-4000-8000-000000000007','garçom'),
    ('e0000000-0000-4000-8000-000000000008','garçom'),
    ('e0000000-0000-4000-8000-000000000008','maître'),
    ('e0000000-0000-4000-8000-000000000008','limpeza pós-evento'),
    ('e0000000-0000-4000-8000-000000000009','garçom'),
    ('e0000000-0000-4000-8000-000000000010','limpeza pós-evento'),
    ('e0000000-0000-4000-8000-000000000010','carregador'),
    ('e0000000-0000-4000-8000-000000000011','garçom'),
    ('e0000000-0000-4000-8000-000000000011','vendedor extra'),
    ('e0000000-0000-4000-8000-000000000012','garçom'),
    ('e0000000-0000-4000-8000-000000000012','limpeza pós-evento')
  ) as x(prof, funcao)
  join public.profissional p on p.id = x.prof::uuid
  join public.funcao f       on f.nome = x.funcao
on conflict do nothing;

-- A grade semanal. `dia_semana`: 0 = domingo … 5 = sexta, 6 = sábado.
--
-- Metade das janelas atravessa a meia-noite (18:00–02:00). Não é exceção: é o turno
-- que o produto existe para preencher, e é a forma mais rápida de descobrir se algum
-- código novo comparou `hora_fim > hora_inicio` por reflexo.
insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
values
  ('e0000000-0000-4000-8000-000000000001', 5, '18:00', '02:00'),
  ('e0000000-0000-4000-8000-000000000001', 6, '18:00', '02:00'),
  ('e0000000-0000-4000-8000-000000000002', 5, '18:00', '02:00'),
  ('e0000000-0000-4000-8000-000000000002', 6, '06:00', '14:00'),
  -- Só de manhã, no meio da semana: a grade que não cobre turno de bar nenhum.
  ('e0000000-0000-4000-8000-000000000003', 1, '08:00', '12:00'),
  ('e0000000-0000-4000-8000-000000000003', 6, '06:00', '14:00'),
  ('e0000000-0000-4000-8000-000000000004', 5, '18:00', '02:00'),
  ('e0000000-0000-4000-8000-000000000005', 5, '18:00', '02:00'),
  ('e0000000-0000-4000-8000-000000000006', 5, '18:00', '02:00'),
  ('e0000000-0000-4000-8000-000000000007', 5, '18:00', '02:00'),
  ('e0000000-0000-4000-8000-000000000008', 5, '18:00', '02:00'),
  ('e0000000-0000-4000-8000-000000000008', 6, '06:00', '14:00'),
  ('e0000000-0000-4000-8000-000000000009', 5, '18:00', '02:00'),
  ('e0000000-0000-4000-8000-000000000010', 6, '06:00', '14:00'),
  -- Uma janela só, longa, que cobre tanto a vaga de referência quanto a do modo
  -- seleção. Serve para testar que a cobertura é por contenção, e não por igualdade.
  ('e0000000-0000-4000-8000-000000000011', 5, '12:00', '02:00'),
  ('e0000000-0000-4000-8000-000000000011', 3, '18:00', '23:00'),
  ('e0000000-0000-4000-8000-000000000012', 5, '18:00', '02:00'),
  ('e0000000-0000-4000-8000-000000000012', 6, '06:00', '14:00')
on conflict do nothing;

-- ── As casas ───────────────────────────────────────────────────────────────────
--
-- Três regiões, três tipos, e um CPF entre os documentos: serviço doméstico e MEI
-- também contratam pelo Frila, e um `check` que só aceitasse 14 dígitos os deixaria
-- de fora. Os documentos são de formato válido e não pertencem a ninguém.

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto,
                                    aval_positivas, aval_total)
values
  ('c0000000-0000-4000-8000-000000000001','Bar do Cerrado','09123456000178','food_service',
   'CLN 208, Bloco B, Asa Norte, Brasília-DF',
   'POINT(-47.8869 -15.7620)'::extensions.geography, 1, 1),
  ('c0000000-0000-4000-8000-000000000002','Buffet Águas Claras','09123456000259','evento',
   'Rua das Pitangueiras, Águas Claras, Brasília-DF',
   'POINT(-48.0286 -15.8345)'::extensions.geography, 2, 2),
  ('c0000000-0000-4000-8000-000000000003','Empório Lago Sul','52998224725','varejo',
   'SHIS QI 11, Bloco C, Lago Sul, Brasília-DF',
   'POINT(-47.8400 -15.8300)'::extensions.geography, 0, 0)
on conflict (id) do nothing;

-- O Paulo é operador do bar, não administrador: é com ele que se testa o que um papel
-- sem poder de administração alcança.
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values
  ('b0000000-0000-4000-8000-000000000001','c0000000-0000-4000-8000-000000000001','administrador'),
  ('b0000000-0000-4000-8000-000000000004','c0000000-0000-4000-8000-000000000001','operador'),
  ('b0000000-0000-4000-8000-000000000002','c0000000-0000-4000-8000-000000000002','administrador'),
  ('b0000000-0000-4000-8000-000000000003','c0000000-0000-4000-8000-000000000003','administrador')
on conflict (usuario_id, estabelecimento_id) do nothing;

-- RF18. A Iara mora em Águas Claras, a mais de 15 km do bar, e é a única diferença
-- entre ela e o Diego: sem esta linha, os dois seriam o mesmo cenário.
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
values ('c0000000-0000-4000-8000-000000000001','e0000000-0000-4000-8000-000000000009')
on conflict do nothing;

-- ── As vagas ───────────────────────────────────────────────────────────────────
--
--   d…01  publicada   Bar     · garçom          · sexta 18:00–02:00   ← referência da RN05
--   d…02  preenchida  Bar     · bartender       · sábado 18:00–02:00
--   d…03  encerrada   Buffet  · limpeza         · um sábado passado 06:00–14:00
--   d…04  cancelada   Empório · repositor       · domingo 10:00–16:00
--   d…05  publicada   Empório · vendedor extra  · sexta seguinte 14:00–20:00 (seleção)
--   d…06  preenchida  Buffet  · garçom          · sexta 18:00–02:00  ← cruza com a d…01
--   d…07  encerrada   Bar     · garçom          · uma sexta passada 18:00–02:00

insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, traje, participa_rateio,
                         observacoes, modo, estado, publicado_em, chave_cliente, publicado_por)
select x.id::uuid, x.estab::uuid, f.id, x.inicio, x.fim, x.local, x.ponto::extensions.geography,
       x.valor, x.posicoes, x.refeicao, x.transporte, x.material, x.responsavel, x.traje,
       x.rateio, x.obs, x.modo::public.modo_preenchimento, x.estado::public.estado_vaga,
       x.publicado, x.chave::uuid,
       -- Quem publicou é o administrador do estabelecimento (RF21). A coluna nasceu com
       -- `publicar_vaga`, e sem ela o cenário teria vaga sem autor — que é justamente o
       -- estado que a coluna existe para impedir.
       (select m.usuario_id from public.membro_estabelecimento m
         where m.estabelecimento_id = x.estab::uuid and m.papel = 'administrador'
         limit 1)
  from _quando q,
  lateral (values
    ('d0000000-0000-4000-8000-000000000001','c0000000-0000-4000-8000-000000000001','garçom',
     q.sexta_18h, q.sexta_18h + interval '8 hours',
     'CLN 208, Bloco B, Asa Norte', 'POINT(-47.8869 -15.7620)',
     16000::bigint, 2::smallint, true, false, false, 'Zélia, no caixa',
     'Camisa preta e calça preta', true,
     'Casa cheia de sexta. Entrada pelos fundos.',
     'urgencia', 'publicada', now() - interval '2 days',
     '11110000-0000-4000-8000-000000000001'),

    ('d0000000-0000-4000-8000-000000000002','c0000000-0000-4000-8000-000000000001','bartender',
     q.sexta_18h + interval '1 day', q.sexta_18h + interval '1 day 8 hours',
     'CLN 208, Bloco B, Asa Norte', 'POINT(-47.8869 -15.7620)',
     22000::bigint, 1::smallint, true, true, false, 'Zélia, no caixa',
     'Camisa preta', true, null,
     'urgencia', 'preenchida', now() - interval '5 days',
     '11110000-0000-4000-8000-000000000002'),

    -- As duas vagas do passado descontam **14** dias da âncora, não 7: a âncora está
    -- entre 7 e 13 dias no futuro, então `- 7 dias` cairia no futuro em metade das
    -- execuções — e o trigger de RN07 recusaria as avaliações com
    -- `avaliacao_indisponivel / antes_do_fim`. Com 14, o passado é passado em
    -- qualquer dia da semana em que o `db reset` rodar.
    ('d0000000-0000-4000-8000-000000000003','c0000000-0000-4000-8000-000000000002','limpeza pós-evento',
     q.sexta_18h - interval '14 days' + interval '12 hours',
     q.sexta_18h - interval '14 days' + interval '20 hours',
     'Salão de festas, Águas Claras', 'POINT(-48.0286 -15.8345)',
     14000::bigint, 5::smallint, true, true, true, 'Ricardo, na portaria',
     null, false, 'Casamento de 200 pessoas. Material fornecido pelo buffet.',
     'selecao', 'encerrada', now() - interval '20 days',
     '11110000-0000-4000-8000-000000000003'),

    ('d0000000-0000-4000-8000-000000000004','c0000000-0000-4000-8000-000000000003','repositor de gôndola',
     q.sexta_18h + interval '2 days' - interval '8 hours',
     q.sexta_18h + interval '2 days' - interval '2 hours',
     'SHIS QI 11, Lago Sul', 'POINT(-47.8400 -15.8300)',
     11000::bigint, 2::smallint, false, false, false, 'Marta, no estoque',
     'Camiseta da loja, fornecida', null, null,
     'urgencia', 'cancelada', now() - interval '6 days',
     '11110000-0000-4000-8000-000000000004'),

    ('d0000000-0000-4000-8000-000000000005','c0000000-0000-4000-8000-000000000003','vendedor extra',
     q.sexta_18h + interval '7 days' - interval '4 hours',
     q.sexta_18h + interval '7 days' + interval '2 hours',
     'SHIS QI 11, Lago Sul', 'POINT(-47.8400 -15.8300)',
     13000::bigint, 3::smallint, false, true, false, 'Marta, no estoque',
     null, null, 'Semana de liquidação.',
     'selecao', 'publicada', now() - interval '1 day',
     '11110000-0000-4000-8000-000000000005'),

    ('d0000000-0000-4000-8000-000000000006','c0000000-0000-4000-8000-000000000002','garçom',
     q.sexta_18h, q.sexta_18h + interval '8 hours',
     'Salão de festas, Águas Claras', 'POINT(-48.0286 -15.8345)',
     18000::bigint, 1::smallint, true, true, false, 'Ricardo, na portaria',
     'Social completo', true, null,
     'urgencia', 'preenchida', now() - interval '4 days',
     '11110000-0000-4000-8000-000000000006'),

    ('d0000000-0000-4000-8000-000000000007','c0000000-0000-4000-8000-000000000001','garçom',
     q.sexta_18h - interval '14 days', q.sexta_18h - interval '14 days' + interval '8 hours',
     'CLN 208, Bloco B, Asa Norte', 'POINT(-47.8869 -15.7620)',
     16000::bigint, 2::smallint, true, false, false, 'Zélia, no caixa',
     'Camisa preta e calça preta', true, null,
     'urgencia', 'encerrada', now() - interval '12 days',
     '11110000-0000-4000-8000-000000000007')
  ) as x(id, estab, funcao, inicio, fim, local, ponto, valor, posicoes, refeicao, transporte,
         material, responsavel, traje, rateio, obs, modo, estado, publicado, chave)
  join public.funcao f on f.nome = x.funcao
on conflict (id) do nothing;

-- ── As posições ────────────────────────────────────────────────────────────────
--
-- `inicio_em` e `fim_em` são copiados da vaga: é a desnormalização que torna possível
-- o `EXCLUDE` de RN21, porque índice GIST não atravessa junção.

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, falta,
                            inicio_em, fim_em)
select x.id::uuid, x.vaga::uuid, x.estado::public.estado_posicao, x.prof::uuid,
       case when x.confirmado_ha is null then null else now() - x.confirmado_ha end,
       x.falta, v.inicio_em, v.fim_em
  from (values
    -- d…01, a vaga de referência: as duas posições continuam abertas.
    ('f1000000-0000-4000-8000-000000000101','d0000000-0000-4000-8000-000000000001','aberta',     null,                                   null,                    false),
    ('f1000000-0000-4000-8000-000000000102','d0000000-0000-4000-8000-000000000001','aberta',     null,                                   null,                    false),
    -- d…02: a Ana confirmada no sábado. Não cruza com a sexta da vaga de referência.
    ('f1000000-0000-4000-8000-000000000201','d0000000-0000-4000-8000-000000000002','confirmada','e0000000-0000-4000-8000-000000000001',  interval '3 days',       false),
    -- d…03: os quatro desfechos do check-in, mais a falta.
    ('f1000000-0000-4000-8000-000000000301','d0000000-0000-4000-8000-000000000003','cumprida',  'e0000000-0000-4000-8000-000000000010',  interval '15 days',      false),
    ('f1000000-0000-4000-8000-000000000302','d0000000-0000-4000-8000-000000000003','cumprida',  'e0000000-0000-4000-8000-000000000008',  interval '15 days',      false),
    ('f1000000-0000-4000-8000-000000000303','d0000000-0000-4000-8000-000000000003','cumprida',  'e0000000-0000-4000-8000-000000000003',  interval '15 days',      false),
    ('f1000000-0000-4000-8000-000000000304','d0000000-0000-4000-8000-000000000003','cumprida',  'e0000000-0000-4000-8000-000000000002',  interval '15 days',      false),
    -- RN12: a posição cancelada guarda de quem foi a falta. Por isso `profissional_id`
    -- sobrevive ao cancelamento — sem ele não há de quem cobrar nem o que contar.
    ('f1000000-0000-4000-8000-000000000305','d0000000-0000-4000-8000-000000000003','cancelada', 'e0000000-0000-4000-8000-000000000012',  interval '15 days',      true),
    -- d…04: a casa cancelou a vaga inteira antes de confirmar ninguém.
    ('f1000000-0000-4000-8000-000000000401','d0000000-0000-4000-8000-000000000004','cancelada',  null,                                   null,                    false),
    ('f1000000-0000-4000-8000-000000000402','d0000000-0000-4000-8000-000000000004','cancelada',  null,                                   null,                    false),
    -- d…05, modo seleção: três abertas, esperando o fechamento 24 h antes.
    ('f1000000-0000-4000-8000-000000000501','d0000000-0000-4000-8000-000000000005','aberta',     null,                                   null,                    false),
    ('f1000000-0000-4000-8000-000000000502','d0000000-0000-4000-8000-000000000005','aberta',     null,                                   null,                    false),
    ('f1000000-0000-4000-8000-000000000503','d0000000-0000-4000-8000-000000000005','aberta',     null,                                   null,                    false),
    -- d…06: a Gabi confirmada na MESMA janela da vaga de referência. É este registro,
    -- e não um campo de "indisponível", que a torna inelegível para a d…01 (RN21).
    ('f1000000-0000-4000-8000-000000000601','d0000000-0000-4000-8000-000000000006','confirmada','e0000000-0000-4000-8000-000000000007',  interval '2 days',       false),
    -- d…07: a Ana cumpriu; a segunda posição nunca foi preenchida e fechou com a vaga.
    ('f1000000-0000-4000-8000-000000000701','d0000000-0000-4000-8000-000000000007','cumprida',  'e0000000-0000-4000-8000-000000000001',  interval '14 days',      false),
    ('f1000000-0000-4000-8000-000000000702','d0000000-0000-4000-8000-000000000007','cancelada',  null,                                   null,                    false)
  ) as x(id, vaga, estado, prof, confirmado_ha, falta)
  join public.vaga v on v.id = x.vaga::uuid
on conflict (id) do nothing;

-- ── As candidaturas ────────────────────────────────────────────────────────────
--
-- Pendentes na vaga de referência e na de seleção, para a tela do contratante ter o
-- que listar antes de existir a RPC `candidatar` (Sprint 1).

insert into public.candidatura (posicao_id, profissional_id, estado, criada_em)
values
  ('f1000000-0000-4000-8000-000000000101','e0000000-0000-4000-8000-000000000001','pendente', now() - interval '2 days'),
  ('f1000000-0000-4000-8000-000000000101','e0000000-0000-4000-8000-000000000008','pendente', now() - interval '1 day'),
  ('f1000000-0000-4000-8000-000000000102','e0000000-0000-4000-8000-000000000011','pendente', now() - interval '6 hours'),
  ('f1000000-0000-4000-8000-000000000501','e0000000-0000-4000-8000-000000000011','pendente', now() - interval '3 hours'),
  -- Uma retirada, para a lista do contratante não ser só de pendentes.
  ('f1000000-0000-4000-8000-000000000502','e0000000-0000-4000-8000-000000000012','retirada', now() - interval '20 hours')
on conflict (posicao_id, profissional_id) do nothing;

-- ── Os turnos ──────────────────────────────────────────────────────────────────
--
-- O turno nasce na confirmação, com o valor copiado da vaga: se a casa republicar por
-- outro preço, o turno executado continua dizendo quanto foi combinado (RN11).
--
-- RN22 tem três desfechos, e os três estão aqui. O de baixo — turno que aconteceu e
-- não tem prova — é o que o produto mais teme, e o que costuma faltar num cenário
-- montado às pressas.

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
                          checkin_confirmado_em, checkout_em, checkout_distancia_m,
                          verificacao, valor_acordado_centavos)
select x.id::uuid, x.posicao::uuid,
       case when x.checkin_offset is null then null else p.inicio_em + x.checkin_offset end,
       x.tipo::public.tipo_registro, x.dist,
       case when x.confirmado_offset is null then null else p.inicio_em + x.confirmado_offset end,
       case when x.checkout_offset is null then null else p.inicio_em + x.checkout_offset end,
       x.dist_out, x.verificacao::public.verificacao_turno, x.valor::bigint
  from (values
    -- Caminho feliz: chegou perto, o app mediu a distância e mais nada (RN22 proíbe
    -- guardar a coordenada).
    ('f2000000-0000-4000-8000-000000000701','f1000000-0000-4000-8000-000000000701',
     interval '-5 minutes','geolocalizado',45,  null,                interval '8 hours 10 minutes',  30,  'verificado',    16000),
    ('f2000000-0000-4000-8000-000000000301','f1000000-0000-4000-8000-000000000301',
     interval '2 minutes','geolocalizado',80,  null,                interval '8 hours 5 minutes',  120, 'verificado',    14000),
    -- Manual confirmado pelo contratante: vale como presença verificada.
    ('f2000000-0000-4000-8000-000000000302','f1000000-0000-4000-8000-000000000302',
     interval '10 minutes','manual',      null, interval '35 minutes', interval '8 hours',           null,'verificado',    14000),
    -- Manual sem confirmação: o contratante não respondeu. Fica pendente, e não vira
    -- presença por decurso de prazo — quem avalia precisa de prova, não de silêncio.
    ('f2000000-0000-4000-8000-000000000303','f1000000-0000-4000-8000-000000000303',
     interval '25 minutes','manual',      null, null,                interval '8 hours',           null,'pendente',      14000),
    -- Sem check-in nenhum: o turno terminou e não há prova de que alguém esteve lá.
    ('f2000000-0000-4000-8000-000000000304','f1000000-0000-4000-8000-000000000304',
     null,                  null,         null, null,                null,                         null,'nao_verificado',14000),
    -- Os dois do futuro: confirmados, sem check-in porque ainda não começaram.
    ('f2000000-0000-4000-8000-000000000201','f1000000-0000-4000-8000-000000000201',
     null,                  null,         null, null,                null,                         null,'pendente',      22000),
    ('f2000000-0000-4000-8000-000000000601','f1000000-0000-4000-8000-000000000601',
     null,                  null,         null, null,                null,                         null,'pendente',      18000)
  ) as x(id, posicao, checkin_offset, tipo, dist, confirmado_offset, checkout_offset,
         dist_out, verificacao, valor)
  join public.posicao p on p.id = x.posicao::uuid
on conflict (id) do nothing;

-- ── As avaliações ──────────────────────────────────────────────────────────────
--
-- Binária, nos dois sentidos, e só sobre turno com presença verificada depois do fim
-- previsto — o trigger `avaliacao_rn07` recusa qualquer outra coisa, e é de propósito
-- que este bloco não tenta contorná-lo.
--
-- Uma resposta negativa entre elas. Um cenário em que todo mundo responde "sim" não
-- exercita a tela que mostra o denominador, que é a tela onde RN08 vive.

-- `criada_em` sai do fim do próprio turno, e não de `now() - N dias`: a âncora move as
-- datas conforme o dia do `db reset`, e uma avaliação com data anterior ao turno que
-- ela avalia é o tipo de incoerência que ninguém olha até depender dela.

insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta, criada_em)
select x.turno::uuid, x.autor::uuid, x.alvo_tipo, x.alvo::uuid, x.resposta,
       p.fim_em + x.depois
  from (values
    -- Turno da Ana no bar.
    ('f2000000-0000-4000-8000-000000000701','a0000000-0000-4000-8000-000000000001','estabelecimento','c0000000-0000-4000-8000-000000000001', true,  interval '30 minutes'),
    ('f2000000-0000-4000-8000-000000000701','b0000000-0000-4000-8000-000000000001','profissional',   'e0000000-0000-4000-8000-000000000001', true,  interval '9 hours'),
    -- Turno do João no buffet.
    ('f2000000-0000-4000-8000-000000000301','a0000000-0000-4000-8000-000000000010','estabelecimento','c0000000-0000-4000-8000-000000000002', true,  interval '20 minutes'),
    ('f2000000-0000-4000-8000-000000000301','b0000000-0000-4000-8000-000000000002','profissional',   'e0000000-0000-4000-8000-000000000010', true,  interval '4 hours'),
    -- Turno do Heitor no mesmo evento: ele gostou da casa, a casa não o chamaria de novo.
    ('f2000000-0000-4000-8000-000000000302','a0000000-0000-4000-8000-000000000008','estabelecimento','c0000000-0000-4000-8000-000000000002', true,  interval '2 hours'),
    ('f2000000-0000-4000-8000-000000000302','b0000000-0000-4000-8000-000000000002','profissional',   'e0000000-0000-4000-8000-000000000008', false, interval '4 hours')
  ) as x(turno, autor, alvo_tipo, alvo, resposta, depois)
  join public.turno t   on t.id = x.turno::uuid
  join public.posicao p on p.id = t.posicao_id
on conflict (turno_id, autor_id) do nothing;

-- ── O bloqueio ─────────────────────────────────────────────────────────────────
--
-- RF26: vale nos dois sentidos e alcança o estabelecimento inteiro. A Zélia bloqueou o
-- Felipe; o efeito é que nenhuma vaga do Bar do Cerrado chega a ele, nem pela lista
-- nem pela notificação — e o Paulo, que é operador da mesma casa, também não o alcança.

insert into public.bloqueio (autor_id, bloqueado_id, criado_em)
values ('b0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000006',
        now() - interval '18 days')
on conflict (autor_id, bloqueado_id) do nothing;

-- ── As ocorrências ─────────────────────────────────────────────────────────────
--
-- Uma denúncia, que é a história por trás do bloqueio, e o cancelamento da d…04.
--
-- Falta aqui a ocorrência de suspensão da Elisa, e é uma lacuna do modelo, não do
-- cenário: `ocorrencia.autor_id` é `not null` e referencia `usuario`, e não existe
-- conta de plataforma para assinar uma suspensão decidida pela Equipe Frila. Está
-- comentado no cartão Cc2XYCi0.

-- Com `id` explícito, e não `on conflict do nothing` sobre a chave natural: a única
-- unicidade de `ocorrencia` é `(autor_id, chave_cliente)`, e `chave_cliente` é nulo
-- aqui — dois nulos nunca conflitam, então rodar este arquivo duas vezes gravaria as
-- duas ocorrências de novo. Medido.
insert into public.ocorrencia (id, tipo, posicao_id, usuario_id, autor_id, motivo, criada_em,
                               resultado, resolvido_em)
values
  ('f3000000-0000-4000-8000-000000000001',
   'denuncia', null, 'a0000000-0000-4000-8000-000000000006',
   'b0000000-0000-4000-8000-000000000001',
   'Tratamento agressivo com a equipe de salão durante o turno.',
   now() - interval '18 days', 'Bloqueio aplicado entre as partes.', now() - interval '17 days'),
  ('f3000000-0000-4000-8000-000000000002',
   'cancelamento', 'f1000000-0000-4000-8000-000000000401', null,
   'b0000000-0000-4000-8000-000000000003',
   'Liquidação adiada pela matriz; a loja não abre no domingo.',
   now() - interval '5 days', null, null)
on conflict (id) do nothing;

-- ── Os aparelhos ───────────────────────────────────────────────────────────────
--
-- Quem negou a permissão de notificação não tem linha aqui e, para o despacho, não é
-- alcançável. O Felipe e a Karen estão nessa situação de propósito: o Sprint 2 precisa
-- de um profissional elegível que mesmo assim não recebe push, senão o teto de RN23
-- nunca é medido contra o caso em que não há para onde enviar.

insert into public.dispositivo (usuario_id, token_fcm, plataforma)
values
  ('a0000000-0000-4000-8000-000000000001','fcm-cenario-ana-'    || repeat('0', 24), 'ios'),
  ('a0000000-0000-4000-8000-000000000008','fcm-cenario-heitor-' || repeat('0', 24), 'android'),
  ('a0000000-0000-4000-8000-000000000010','fcm-cenario-joao-'   || repeat('0', 24), 'android'),
  ('b0000000-0000-4000-8000-000000000001','fcm-cenario-zelia-'  || repeat('0', 24), 'ios')
on conflict (token_fcm) do nothing;

drop table _quando;
