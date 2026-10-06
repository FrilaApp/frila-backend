-- Revoga REFERENCES, TRIGGER e MAINTAIN concedidos por padrão a authenticated e anon
-- nas tabelas dos schemas expostos (public e graphql_public).
-- Deixa apenas o que a aplicação precisa (SELECT sob RLS para authenticated em public).

revoke references, trigger, maintain on all tables in schema public from authenticated, anon;
alter default privileges for role postgres in schema public revoke references, trigger, maintain on tables from authenticated, anon;

revoke references, trigger, maintain on all tables in schema graphql_public from authenticated, anon;
alter default privileges for role postgres in schema graphql_public revoke references, trigger, maintain on tables from authenticated, anon;
