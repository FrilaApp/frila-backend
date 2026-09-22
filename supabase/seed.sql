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
