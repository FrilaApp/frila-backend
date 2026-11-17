-- A linha da web em privado.configuracao_app (pedido 16-31: a web foi retomada).
-- Sem ela, configuracao_do_app('web') responde 404 nao_encontrado e a página não sabe a versão mínima.
-- Nenhuma chave liga para a web: não há linha 'web' em privado.recurso_versao_minima, então
-- recurso_na_versao devolve falso para todas (foto, chamada direta, perfil rico, check-in por código, busca).
-- url_da_loja da web é o próprio site. Só dado: a superfície da RPC não muda.
insert into privado.configuracao_app (
  plataforma,
  versao_minima,
  versao_recomendada,
  url_da_loja,
  foto_de_perfil
)
values (
  'web',
  '0.1.0',
  '0.1.0',
  'https://frilabr.com',
  false
);
