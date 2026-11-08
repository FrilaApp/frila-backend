-- 817_recursos_do_app.sql
--
-- ConfiguracaoDoApp.recursos (contrato 0.2.54/0.2.60): cada interruptor do servidor chega ao app
-- lido da chave real, e desligado responde false. Achado do Prisma em 08/11/2026: antes só
-- `foto_de_perfil` chegava, e só quando ligada.

begin;
select plan(14);

create function pg_temp.recursos() returns jsonb language sql as $$
  select public.configuracao_do_app('ios')->'recursos' $$;

-- 1. A chave nova existe e nasce desligada.
select is((select ligado from privado.recurso where chave = 'perfil_rico'), false, 'perfil_rico nasce desligada');
select is((select ligado from privado.recurso where chave = 'chamada_direta'), false, 'chamada_direta segue desligada');

-- 2. Tudo desligado: os três chegam, e chegam false.
update privado.configuracao_app set foto_de_perfil = false;
select is(pg_temp.recursos(), '{"foto_de_perfil": false, "chamada_direta": false, "perfil_rico": false}'::jsonb,
  'tudo desligado: os três vêm false');

-- 3. Cada chave, sozinha, chega ao app; as outras continuam false.
update privado.recurso set ligado = true where chave = 'perfil_rico';
select is(pg_temp.recursos()->>'perfil_rico', 'true', 'perfil_rico ligado chega ao app');
select is(pg_temp.recursos()->>'chamada_direta', 'false', 'com perfil_rico ligado, chamada_direta continua false');
select is(pg_temp.recursos()->>'foto_de_perfil', 'false', 'com perfil_rico ligado, foto_de_perfil continua false');
update privado.recurso set ligado = false where chave = 'perfil_rico';

update privado.recurso set ligado = true where chave = 'chamada_direta';
select is(pg_temp.recursos()->>'chamada_direta', 'true', 'chamada_direta ligada chega ao app');
select is(pg_temp.recursos()->>'perfil_rico', 'false', 'com chamada_direta ligada, perfil_rico continua false');
update privado.recurso set ligado = false where chave = 'chamada_direta';

insert into privado.configuracao_app (plataforma, versao_minima, versao_recomendada, url_da_loja)
values ('android', '0.1.0', '0.1.0', 'https://play.google.com/store/apps/details?id=br.com.frila')
on conflict (plataforma) do nothing;
update privado.configuracao_app set foto_de_perfil = true where plataforma = 'ios';
select is(pg_temp.recursos()->>'foto_de_perfil', 'true', 'foto_de_perfil ligada no iOS chega ao app iOS');
select is(public.configuracao_do_app('android')#>>'{recursos,foto_de_perfil}', 'false',
  'foto_de_perfil segue por plataforma: o Android continua false');
update privado.configuracao_app set foto_de_perfil = false;

-- 4. Desligar de novo volta a false (nada fica em cache).
update privado.recurso set ligado = true where chave in ('perfil_rico', 'chamada_direta');
update privado.recurso set ligado = false where chave in ('perfil_rico', 'chamada_direta');
select is(pg_temp.recursos(), '{"foto_de_perfil": false, "chamada_direta": false, "perfil_rico": false}'::jsonb,
  'religar e desligar volta a false');

-- 5. Sem a linha da chave, o app recebe false, e não erro.
delete from privado.recurso where chave = 'perfil_rico';
select is(pg_temp.recursos()->>'perfil_rico', 'false', 'chave ausente no banco: false');

-- 6. A leitura continua aberta ao app antes do login e a tabela continua fechada.
select ok(has_function_privilege('anon', 'public.configuracao_do_app(text)', 'EXECUTE'), 'anon lê a configuração do app');
select ok(not has_table_privilege('authenticated', 'privado.recurso', 'SELECT,UPDATE'), 'privado.recurso fechada ao cliente');

select * from finish();
rollback;
