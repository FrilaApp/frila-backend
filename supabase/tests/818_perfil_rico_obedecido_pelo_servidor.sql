-- 818_perfil_rico_obedecido_pelo_servidor.sql
--
-- O servidor obedece à chave perfil_rico (contrato 0.2.60, RecursosDoApp.perfil_rico; RN46).
-- Com a chave desligada: as quatro operações da F2 recusam com 403 sem_permissao
-- (recurso_desligado), o 401 vem antes do 403, a conta de outro perfil recebe o 403 do recurso
-- e não o 422 do perfil, e PerfilPublico vem só com a base. Com a chave ligada, tudo volta.
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente values (true, true) on conflict (id) do update set eh_teste = true;
set local frila.agora = '2027-01-11 09:00:00+00';
select plan(26);

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  if conta is null then
    execute 'set local role anon';
    perform set_config('request.jwt.claims', '{}', true);
  else
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', jsonb_build_object('sub', conta, 'role', 'authenticated')::text, true);
  end if;
  execute sql into r;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return r;
end $$;

-- A recusa como "status code motivo", ou null quando a chamada passa.
create function pg_temp.recusa(conta uuid, sql text) returns text language plpgsql as $$
declare msg text; det text;
begin
  perform pg_temp.como(conta, sql);
  return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return concat_ws(' ', det::jsonb ->> 'status', msg::jsonb ->> 'code', msg::jsonb ->> 'details');
end $$;

create function pg_temp.chave(ligada boolean) returns void language sql as $$
  update privado.recurso set ligado = ligada where chave = 'perfil_rico' $$;

-- ── Massa ─────────────────────────────────────────────────────────────────────
insert into auth.users (id, aud, role, email) values
 ('c8180000-0000-4000-8000-000000000001','authenticated','authenticated','prof818@t.test'),
 ('c8180000-0000-4000-8000-000000000002','authenticated','authenticated','casa818@t.test');
select pg_temp.como('c8180000-0000-4000-8000-000000000001',
 $$select public.criar_conta('profissional','Prof 818','+5561955558181','1992-05-10','2026-09-22')$$);
select pg_temp.como('c8180000-0000-4000-8000-000000000002',
 $$select public.criar_conta('contratante','Casa 818','+5561955558182','1985-03-20','2026-09-22')$$);
select pg_temp.como('c8180000-0000-4000-8000-000000000002',
 $$select public.cadastrar_estabelecimento('Bar 818','04252011000110','food_service','CLS 405 Bloco A','{"latitude":-15.79,"longitude":-47.88}'::jsonb,'Plano Piloto')$$);
insert into public.profissional (id, usuario_id, ponto_base) values
 ('c8180000-0000-4000-8000-000000000011', 'c8180000-0000-4000-8000-000000000001', 'POINT(-47.88 -15.79)');
insert into public.profissional_funcao (profissional_id, funcao_id)
 select 'c8180000-0000-4000-8000-000000000011'::uuid, id from public.funcao where nome = 'garçom';
-- Vínculo legítimo de leitura: a casa tem o profissional na equipe de confiança.
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
 values ((select id from public.estabelecimento where nome = 'Bar 818'), 'c8180000-0000-4000-8000-000000000011');

create temp table rpc (nome text, sql text);
insert into rpc values
 ('atualizar_apresentacao_profissional', $$select public.atualizar_apresentacao_profissional('{"apresentacao":"Garçom há seis anos"}')$$),
 ('definir_servicos', format($$select public.definir_servicos(%L::jsonb)$$, jsonb_build_array(jsonb_build_object(
   'funcao_id', (select id from public.funcao where nome = 'garçom'), 'unidade', 'diaria',
   'valor_centavos', 20000, 'horas_incluidas', 8, 'leva_material', 'nao', 'especialidade_ids', jsonb_build_array())))),
 ('definir_regioes_atendidas', $$select public.definir_regioes_atendidas(array[(select id from public.regiao_administrativa where nome = 'Plano Piloto')], false)$$),
 ('meu_perfil_detalhado', $$select public.meu_perfil_detalhado()$$);
grant select on rpc to authenticated, anon;

create function pg_temp.perfil() returns jsonb language sql as $$
  select pg_temp.como('c8180000-0000-4000-8000-000000000002',
    $q$select public.perfil_publico('c8180000-0000-4000-8000-000000000011'::uuid)$q$) $$;

-- ── 1. A chave nasce desligada (#437) ─────────────────────────────────────────
select is((select ligado from privado.recurso where chave = 'perfil_rico'), false, 'perfil_rico nasce desligada');

-- ── 2. Chave desligada: as quatro recusam com 403 recurso_desligado ───────────
select is(pg_temp.recusa('c8180000-0000-4000-8000-000000000001', sql), '403 sem_permissao recurso_desligado',
  nome || ': profissional com a chave desligada recebe 403 recurso_desligado')
  from rpc order by nome;

-- ── 3. 401 vem antes do 403 do recurso ────────────────────────────────────────
select is(pg_temp.recusa(null, sql), '401 nao_autenticado',
  nome || ': sem sessão, 401 antes do 403 do recurso')
  from rpc order by nome;

-- ── 4. Outro perfil com a chave desligada: 403 do recurso, e não 422 do perfil ─
select is(pg_temp.recusa('c8180000-0000-4000-8000-000000000002', sql), '403 sem_permissao recurso_desligado',
  nome || ': contratante com a chave desligada recebe 403, e não 422 perfil_incompativel')
  from rpc order by nome;

-- ── 5. Chave ligada: as quatro passam e gravam ────────────────────────────────
select pg_temp.chave(true);
select is(pg_temp.recusa('c8180000-0000-4000-8000-000000000001', sql), null,
  nome || ': com a chave ligada, o profissional passa')
  from rpc order by nome;
select is(pg_temp.como('c8180000-0000-4000-8000-000000000001', $$select public.meu_perfil_detalhado()$$) ->> 'apresentacao',
  'Garçom há seis anos', 'chave ligada: meu_perfil_detalhado devolve a apresentação gravada');
-- Ligada, o perfil continua valendo: o contratante cai no 422 do perfil.
select is(pg_temp.recusa('c8180000-0000-4000-8000-000000000002', $$select public.meu_perfil_detalhado()$$),
  '422 perfil_incompativel', 'chave ligada: o contratante volta a receber 422 perfil_incompativel');

-- ── 6. PerfilPublico com a chave ligada traz os campos ricos ──────────────────
select is(pg_temp.perfil() ->> 'apresentacao', 'Garçom há seis anos', 'chave ligada: PerfilPublico traz a apresentação');
select is(jsonb_array_length(pg_temp.perfil() -> 'servicos'), 1, 'chave ligada: PerfilPublico traz os serviços');
select is(jsonb_array_length(pg_temp.perfil() -> 'regioes'), 1, 'chave ligada: PerfilPublico traz as regiões');

-- ── 7. Desligada de novo: PerfilPublico só com a base, e os dados ficam guardados ─
select pg_temp.chave(false);
select ok(not (pg_temp.perfil() ?| array['apresentacao','onde_trabalhei','experiencia_faixa','cursos','idiomas',
  'atende_todo_df','no_frila_desde','regioes','servicos']), 'chave desligada: PerfilPublico vem sem nenhum campo rico');
select is(pg_temp.perfil() ->> 'nome', 'Prof 818', 'chave desligada: PerfilPublico mantém a base (nome)');
select ok(pg_temp.perfil() ? 'reputacao', 'chave desligada: PerfilPublico mantém a base (reputação)');
select is((select apresentacao from public.profissional where id = 'c8180000-0000-4000-8000-000000000011'),
  'Garçom há seis anos', 'desligar não apaga o que o profissional gravou');

select * from finish();
rollback;
