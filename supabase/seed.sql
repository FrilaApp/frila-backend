-- Semente: o catálogo de funções, e nada mais.
--
-- Dado de teste não entra aqui. Vive em supabase/tests/, para que um seed acidental
-- em produção não crie estabelecimento fantasma.
--
-- As 32 funções em 7 categorias saem dos setores mapeados no Documento de Visão e em
-- 02-O-NEGOCIO. São dado de partida [H]: precisam ser conferidas em campo, e a lista
-- muda por migração, não à mão no painel.

insert into public.funcao (nome, categoria) values
  -- Salão
  ('garçom',                    'Salão'),
  ('garçonete',                 'Salão'),
  ('maître',                    'Salão'),
  ('hostess',                   'Salão'),
  ('runner',                    'Salão'),
  ('cumim',                     'Salão'),
  -- Bar
  ('bartender',                 'Bar'),
  ('barista',                   'Bar'),
  ('auxiliar de bar',           'Bar'),
  -- Cozinha
  ('chapeiro',                  'Cozinha'),
  ('pizzaiolo',                 'Cozinha'),
  ('auxiliar de cozinha',       'Cozinha'),
  ('copeiro',                   'Cozinha'),
  ('confeiteiro',               'Cozinha'),
  -- Evento
  ('montador',                  'Evento'),
  ('desmontador',               'Evento'),
  ('recepcionista',             'Evento'),
  ('credenciamento',            'Evento'),
  ('segurança de sala',         'Evento'),
  -- Apoio
  ('limpeza pós-evento',        'Apoio'),
  ('carregador',                'Apoio'),
  ('manobrista',                'Apoio'),
  ('estoquista',                'Apoio'),
  -- Varejo
  ('vendedor extra',            'Varejo'),
  ('promotor de degustação',    'Varejo'),
  ('empacotador',               'Varejo'),
  ('repositor de gôndola',      'Varejo'),
  ('inventariante',             'Varejo'),
  -- Logística
  ('chapa (carga e descarga)',  'Logística'),
  ('separador de pedidos',      'Logística'),
  ('etiquetador',               'Logística'),
  ('conferente auxiliar',       'Logística')
on conflict (nome) do update set categoria = excluded.categoria;

-- ── A lista de termos bloqueados (diretriz 1.2 da App Store) ─────────────────
--
-- Dado de produto, como o catálogo acima: precisa existir em todo ambiente, e muda por
-- arquivo, nunca à mão no painel. Guardado já normalizado — o CHECK da tabela recusa
-- termo com acento ou maiúscula, porque um termo mal gravado não casa com nada e o
-- filtro passa a parecer instalado sem estar.
--
-- **Lista de partida [H].** Precisa da revisão da Júlia antes de valer como pronta: uma
-- lista de bloqueio é decisão de produto e de jurídico, não de quem escreve o SQL.
--
-- ── O que está deliberadamente FORA ──────────────────────────────────────────
--
-- Termos que também são sobrenome, topônimo ou palavra comum no português do DF. A
-- comparação é por palavra inteira, o que já resolve `cu` dentro de Cunha — mas não
-- resolve o termo que **é** o sobrenome de alguém.
--
--   pinto     sobrenome comuníssimo, e nome de rua
--   pau       "pau de arara", "meio-pau", e sobrenome
--   rola      verbo de uso diário: "a fila rola"
--   boceta    grafia de uso regional para caixinha, em contexto de artesanato
--
-- Recusar esses quatro custaria cadastro de gente real todo dia, e o que eles deixam
-- passar tem denúncia e bloqueio atrás (RF26). Se algum entrar depois, que entre com o
-- caso que justificou.

insert into privado.termo_bloqueado (termo, categoria) values
  -- Palavrão explícito, no nome ou no texto da vaga
  ('caralho',      'palavrao'),
  ('porra',        'palavrao'),
  ('buceta',       'palavrao'),
  ('foda se',      'palavrao'),
  ('vai se foder', 'palavrao'),
  ('filho da puta','palavrao'),
  ('puta que pariu','palavrao'),
  ('cu',           'palavrao'),
  ('cuzao',        'palavrao'),
  ('merda',        'palavrao'),
  ('bosta',        'palavrao'),
  ('punheta',      'palavrao'),

  -- Insulto direto a pessoa. O produto existe para gente se contratar; xingamento no
  -- campo que a contraparte lê é o começo do problema que RF26 fecha depois.
  ('otario',       'insulto'),
  ('babaca',       'insulto'),
  ('imbecil',      'insulto'),
  ('escroto',      'insulto'),
  ('vagabunda',    'insulto'),
  ('corno',        'insulto'),

  -- Discriminação. Estes não são palavrão: são o motivo de a diretriz 1.2 existir, e
  -- saem da lista só com decisão registrada.
  ('viado',        'odio'),
  ('bicha',        'odio'),
  ('sapatao',      'odio'),
  ('traveco',      'odio'),
  ('macaco',       'odio'),
  ('crioulo',      'odio'),
  ('preto imundo', 'odio'),
  ('favelado',     'odio'),
  ('retardado',    'odio'),
  ('mongoloide',   'odio'),
  ('aleijado',     'odio'),
  ('nordestino burro', 'odio'),

  -- Fora do escopo do trabalho anunciado. A vaga é de turno avulso em serviço; texto
  -- oferecendo outra coisa não é um mal-entendido, é outro produto.
  ('acompanhante de luxo', 'fora_de_escopo'),
  ('programa sexual',      'fora_de_escopo'),
  ('garota de programa',   'fora_de_escopo')
on conflict (termo) do update set categoria = excluded.categoria;


-- ── As contas de revisão da App Store ─────────────────────────────────────────────────
--
-- Cartão `7gpPBgTH`. O revisor da Apple precisa entrar e ver o produto funcionando, e o
-- Frila entra por código no e-mail — ele não tem a caixa de entrada de ninguém. A porta é
-- a Edge Function `entrar-demonstracao`; o que está aqui é o outro lado dela: as contas
-- que ela aceita e os dados que elas enxergam.
--
-- **Isto entra em produção de propósito**, e é a única exceção do `seed.sql`, que fora
-- daqui só tem catálogo. Vive isolado: `usuario.demonstracao` separa as duas populações
-- em `vagas_abertas`, `detalhe_vaga`, `candidatar` e, desde 25/09, na própria política de
-- leitura de `vaga`. Vaga publicada pelo revisor não notifica nem aparece para
-- profissional de verdade, e o contrário também não.
--
-- São **duas** contas porque RN25 dá um perfil por conta e a revisão precisa dos dois
-- lados. O contrato fala em uma; a divergência está registrada no cartão e no
-- `docs/ESTADO.md`.

-- As colunas de token do GoTrue vão como string vazia, e não NULL. Medido em 25/09: com
-- NULL, `POST /auth/v1/admin/generate_link` responde 500 "Database error finding user" —
-- o GoTrue lê essas colunas em campos que não aceitam nulo. É o que hoje impede as contas
-- do `cenarios.sql` de usarem qualquer fluxo administrativo do Auth.
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous,
                        confirmation_token, recovery_token, email_change,
                        email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
select '00000000-0000-0000-0000-000000000000', c.id, 'authenticated', 'authenticated',
       c.email, privado.agora(), '{"provider":"email","providers":["email"]}'::jsonb,
       '{}'::jsonb, privado.agora(), privado.agora(), false, false,
       '', '', '', '', '', '', '', ''
  from (values
    ('de000000-0000-4000-8000-000000000001'::uuid, 'revisao-contratante@frila.app'),
    ('de000000-0000-4000-8000-000000000002'::uuid, 'revisao-profissional@frila.app')
  ) as c(id, email)
on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                            termos_versao, termos_aceite_em, demonstracao)
values
  ('de000000-0000-4000-8000-000000000001','contratante','Casa de Demonstração',
   '+5561999990901','revisao-contratante@frila.app','1985-01-01','2026-09-22', privado.agora(), true),
  ('de000000-0000-4000-8000-000000000002','profissional','Perfil de Demonstração',
   '+5561999990902','revisao-profissional@frila.app','1995-01-01','2026-09-22', privado.agora(), true)
on conflict (id) do nothing;

insert into public.profissional (usuario_id, ponto_base)
values ('de000000-0000-4000-8000-000000000002',
        'POINT(-47.8825 -15.7940)'::extensions.geography)
on conflict (usuario_id) do nothing;

insert into public.profissional_funcao (profissional_id, funcao_id)
select p.id, f.id
  from public.profissional p, public.funcao f
 where p.usuario_id = 'de000000-0000-4000-8000-000000000002'
   and f.nome in ('garçom','bartender')
on conflict do nothing;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ('de000000-0000-4000-8000-000000000010','Bar da Revisão','19131243000197',
        'food_service','CLS 405, Asa Sul, Brasília',
        'POINT(-47.8880 -15.8020)'::extensions.geography)
on conflict (id) do nothing;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('de000000-0000-4000-8000-000000000001',
        'de000000-0000-4000-8000-000000000010','administrador')
on conflict do nothing;

-- Uma vaga aberta, para a lista não nascer vazia (diretriz 4.2), e uma vaga já preenchida
-- que vira o turno confirmado — é nele que o revisor vê o contato liberado e o check-in.
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, estado,
                         chave_cliente, publicado_por)
select v.id, 'de000000-0000-4000-8000-000000000010',
       (select id from public.funcao where nome = 'garçom'),
       privado.agora() + v.daqui, privado.agora() + v.daqui + interval '6 h',
       'CLS 405, Asa Sul', 'POINT(-47.8880 -15.8020)'::extensions.geography,
       18000, 1, true, true, false, 'Gerente da Revisão', 'urgencia', v.estado,
       v.id, 'de000000-0000-4000-8000-000000000001'
  from (values
    ('de000000-0000-4000-8000-000000000020'::uuid, interval '5 days',  'publicada'::public.estado_vaga),
    ('de000000-0000-4000-8000-000000000021'::uuid, interval '2 days',  'preenchida'::public.estado_vaga)
  ) as v(id, daqui, estado)
on conflict (id) do nothing;

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select 'de000000-0000-4000-8000-000000000030', 'de000000-0000-4000-8000-000000000020',
       'aberta', null, null, v.inicio_em, v.fim_em
  from public.vaga v where v.id = 'de000000-0000-4000-8000-000000000020'
on conflict (id) do nothing;

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select 'de000000-0000-4000-8000-000000000031', 'de000000-0000-4000-8000-000000000021',
       'confirmada',
       (select id from public.profissional
         where usuario_id = 'de000000-0000-4000-8000-000000000002'),
       privado.agora(), v.inicio_em, v.fim_em
  from public.vaga v where v.id = 'de000000-0000-4000-8000-000000000021'
on conflict (id) do nothing;

insert into public.turno (posicao_id, valor_acordado_centavos)
values ('de000000-0000-4000-8000-000000000031', 18000)
on conflict (posicao_id) do nothing;
