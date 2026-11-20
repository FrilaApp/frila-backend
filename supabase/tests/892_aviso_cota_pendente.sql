-- 892_aviso_cota_pendente.sql
--
-- Prova a entrega durável do aviso de cota mensal da moderação com mecanismo de lease e retentativa (B-080):
-- 1. As colunas tentativa_em e emitido_em existem em privado.moderacao_aviso_cota;
-- 2. Reserva que cruza o limiar devolve true e deixa emitido_em nulo (marca pendente);
-- 3. Segunda reserva dentro de 5 min NÃO avisa;
-- 4. Com tentativa_em recuado 6 minutos no teste, a próxima reserva devolve true de novo e atualiza tentativa_em;
-- 5. Depois de confirmar_aviso_cota_moderacao (devolve true; segunda chamada devolve false) nenhuma reserva avisa mais,
--    nem com tentativa_em antigo;
-- 6. Confirmar marca inexistente devolve false;
-- 7. Privilégios: service_role executa a confirmação, authenticated/anon não; security definer e search_path="";
-- 8. Limiar 0, 101 e -1 lançam 22023 / limiar_invalido sem gravar marca nem consumo.
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
select plan(24);

create temp table ids as
select 'c8920000-0000-4000-8000-000000000001'::uuid as usuario;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select usuario, 'profissional'::public.perfil_conta, 'Conta 892', '+556199998920', 'c892@test.invalid',
       '1990-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids;

create function pg_temp.m(n integer) returns uuid language sql immutable as
$$ select ('c8920000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;

insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
select pg_temp.m(n), (select usuario from ids), 'profissional', 'foto_perfil',
       'perfil/892-' || n || '.jpg', 'image/jpeg', 1000, 'removida'
  from generate_series(1, 40) n;

create function pg_temp.gastar(p_provedor text, p_mes text, p_quantas integer) returns void language sql as
$$ insert into privado.moderacao_chamada (midia_id, provedor, mes)
   select pg_temp.m(21 + (n % 20)), p_provedor, p_mes from generate_series(1, p_quantas) n $$;

create function pg_temp.reservar(p_midia integer, p_provedor text, p_mes text, p_teto integer, p_max integer default 1)
returns text language sql as
$$ select resultado || '/' || consumo_mes || '/' || avisar_cota
     from privado.reservar_chamada_moderacao(pg_temp.m(p_midia), p_provedor, p_mes, p_teto, p_max) $$;

-- 1. Estrutura das colunas novas
select has_column('privado', 'moderacao_aviso_cota', 'tentativa_em', 'a coluna tentativa_em existe');
select has_column('privado', 'moderacao_aviso_cota', 'emitido_em', 'a coluna emitido_em existe');

-- 7. Privilégios da confirmação
select ok(has_function_privilege('service_role',
  'privado.confirmar_aviso_cota_moderacao(text,text,integer)', 'execute'),
  'service_role executa confirmar_aviso_cota_moderacao');
select ok(not has_function_privilege('authenticated',
  'privado.confirmar_aviso_cota_moderacao(text,text,integer)', 'execute'),
  'authenticated não executa confirmar_aviso_cota_moderacao');
select ok(not has_function_privilege('anon',
  'privado.confirmar_aviso_cota_moderacao(text,text,integer)', 'execute'),
  'anon não executa confirmar_aviso_cota_moderacao');
select is((select prosecdef from pg_proc where oid = 'privado.confirmar_aviso_cota_moderacao(text,text,integer)'::regprocedure),
  true, 'a confirmação é security definer');
select ok((select proconfig from pg_proc where oid = 'privado.confirmar_aviso_cota_moderacao(text,text,integer)'::regprocedure)
  @> array['search_path=""'], 'a confirmação fixa search_path vazio');

-- 2. Reserva que cruza o limiar devolve true e deixa emitido_em nulo
select pg_temp.gastar('prov_lease', '2026-11', 7);
select is(pg_temp.reservar(1, 'prov_lease', '2026-11', 10), 'ok/8/true',
  'reserva que cruza o limiar 80% (8 de 10) devolve avisar_cota = true');
select is((select emitido_em from privado.moderacao_aviso_cota
            where provedor = 'prov_lease' and mes = '2026-11' and limiar_percentual = 80),
  null, 'marca pendente tem emitido_em nulo');
select ok((select tentativa_em from privado.moderacao_aviso_cota
            where provedor = 'prov_lease' and mes = '2026-11' and limiar_percentual = 80) is not null,
  'marca pendente tem tentativa_em preenchido');

-- 3. Segunda reserva dentro de 5 min NÃO avisa
select is(pg_temp.reservar(2, 'prov_lease', '2026-11', 10), 'ok/9/false',
  'segunda reserva dentro da janela de 5 min não repete o aviso');

-- 4. Com tentativa_em recuado 6 minutos, próxima reserva devolve true de novo e atualiza tentativa_em
update privado.moderacao_aviso_cota
   set tentativa_em = privado.agora() - interval '6 minutes'
 where provedor = 'prov_lease' and mes = '2026-11' and limiar_percentual = 80;

select is(pg_temp.reservar(3, 'prov_lease', '2026-11', 10), 'ok/10/true',
  'com lease expirado (> 5 min) e não confirmado, próxima reserva avisa novamente');
select ok((select tentativa_em from privado.moderacao_aviso_cota
            where provedor = 'prov_lease' and mes = '2026-11' and limiar_percentual = 80) >= privado.agora() - interval '1 minute',
  'tentativa_em foi renovada para o momento atual');
select is((select emitido_em from privado.moderacao_aviso_cota
            where provedor = 'prov_lease' and mes = '2026-11' and limiar_percentual = 80),
  null, 'emitido_em continua nulo até a confirmação explícita');

-- 5. Confirmação do aviso (primeira true, segunda false, nenhuma reserva posterior avisa)
select is(privado.confirmar_aviso_cota_moderacao('prov_lease', '2026-11', 80), true,
  'primeira confirmação devolve true');
select ok((select emitido_em from privado.moderacao_aviso_cota
            where provedor = 'prov_lease' and mes = '2026-11' and limiar_percentual = 80) is not null,
  'emitido_em foi preenchido pela confirmação');
select is(privado.confirmar_aviso_cota_moderacao('prov_lease', '2026-11', 80), false,
  'segunda confirmação com marca já confirmada devolve false');

-- Recua tentativa_em mesmo após confirmação: NÃO deve avisar
update privado.moderacao_aviso_cota
   set tentativa_em = privado.agora() - interval '10 minutes'
 where provedor = 'prov_lease' and mes = '2026-11' and limiar_percentual = 80;

select is(pg_temp.reservar(4, 'prov_lease', '2026-11', 20), 'ok/11/false',
  'marca confirmada nunca mais volta a avisar, mesmo com tentativa_em antigo');

-- 6. Confirmar marca inexistente devolve false
select is(privado.confirmar_aviso_cota_moderacao('inexistente', '2026-11', 80), false,
  'confirmar marca inexistente devolve false');

-- 8. Limiar fora de 1..100 lança 22023 / limiar_invalido sem gravar consumo nem marca
select throws_ok(
  $$ select * from privado.reservar_chamada_moderacao(pg_temp.m(5), 'inv_test', '2026-11', 10, 1, 0) $$,
  '22023', 'limiar_invalido', 'limiar 0% rejeitado na entrada com 22023');
select throws_ok(
  $$ select * from privado.reservar_chamada_moderacao(pg_temp.m(5), 'inv_test', '2026-11', 10, 1, 101) $$,
  '22023', 'limiar_invalido', 'limiar 101% rejeitado na entrada com 22023');
select throws_ok(
  $$ select * from privado.reservar_chamada_moderacao(pg_temp.m(5), 'inv_test', '2026-11', 10, 1, -1) $$,
  '22023', 'limiar_invalido', 'limiar -1% rejeitado na entrada com 22023');

select is((select count(*)::int from privado.moderacao_chamada where provedor = 'inv_test'),
  0, 'nenhuma chamada gravada para parâmetros de limiar inválidos');
select is((select count(*)::int from privado.moderacao_aviso_cota where provedor = 'inv_test'),
  0, 'nenhuma marca de aviso gravada para parâmetros de limiar inválidos');

select * from finish();
rollback;
