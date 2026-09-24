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
