-- 911_perfil_detalhado_preferencia_chamadas.sql
--
-- TcZoKK7i: `privado.perfil_com_servicos` monta `preferencia_chamadas` com `aceita_chamadas` e, quando ligado, `pendencias_para_busca` (contrato
-- `PreferenciaChamadas`, 0.2.88). Antes só o `definir_preferencia_chamadas` devolvia os dois campos; o `meu_perfil_detalhado` trazia 4 chaves, então quem
-- ligava "Aceito chamadas diretas" reabria a tela e a via desligada.
--   A  ligar, reler o perfil: aceita_chamadas = true e pendencias_para_busca (a mesma lista da função e do `definir`)
--   B  desligar, reler: aceita_chamadas = false e sem a chave pendencias_para_busca
--   C  o objeto do perfil é igual ao que o `definir_preferencia_chamadas` devolveu na mesma hora
--   D  os outros RPCs que devolvem o perfil e a exportação (`meus_dados`) trazem o mesmo; sem linha de preferência o objeto continua ausente
--   E  o outro profissional não é afetado
-- Cenário (`cenarios.sql`): Ana (a…01 / e…01) e Bruno (a…02 / e…02), profissionais, sem linha de preferência. Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-27 15:00:00+00', true);
-- 20261113220000 liga foto, chamada direta e perfil rico para todos; este teste liga só o que a preferência exige.
update privado.recurso set ligado = true where chave in ('chamada_direta', 'busca_profissionais');
select plan(22);

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

create temp table ids as select
  'a0000000-0000-4000-8000-000000000001'::uuid as ana,
  'e0000000-0000-4000-8000-000000000001'::uuid as ana_prof,
  'a0000000-0000-4000-8000-000000000002'::uuid as bruno;

create function pg_temp.pref_do_perfil(conta uuid) returns jsonb language sql as
  $$ select pg_temp.como(conta, 'select public.meu_perfil_detalhado()') -> 'preferencia_chamadas' $$;

-- ── D0. Sem linha de preferência o objeto continua ausente ───────────────────────────────────────────────────────

select is((select count(*) from public.profissional_preferencia_chamada where profissional_id = (select ana_prof from ids)), 0::bigint,
  '0 cenário: a Ana não tem linha de preferência');
select is(pg_temp.pref_do_perfil((select ana from ids)), null::jsonb, 'D0 sem linha, o perfil não traz preferencia_chamadas (como antes)');

-- ── A. Ligar e reler ──────────────────────────────────────────────────────────────────────────────────────────

create temp table ligou as
  select pg_temp.como((select ana from ids),
    $$ select public.definir_preferencia_chamadas(aceita_chamadas => true, versao_texto_busca => '2026-11-16') $$) as j;
select ok((select j->>'aceita_chamadas' = 'true' from ligou), '0b o definir devolveu aceita_chamadas = true (a base já fazia)');

select is(pg_temp.pref_do_perfil((select ana from ids))->>'aceita_chamadas', 'true', 'A1 reler o perfil traz aceita_chamadas = true');
select is(jsonb_typeof(pg_temp.pref_do_perfil((select ana from ids))->'pendencias_para_busca'), 'array', 'A2 e pendencias_para_busca como lista');
select is(
  pg_temp.pref_do_perfil((select ana from ids))->'pendencias_para_busca',
  privado.pendencias_para_busca((select ana_prof from ids)),
  'A3 a lista é a que privado.pendencias_para_busca calcula');
select ok(jsonb_array_length(pg_temp.pref_do_perfil((select ana from ids))->'pendencias_para_busca') > 0,
  'A4 a Ana ainda tem pendências para a busca (a lista não passa vazia)');

-- ── C. Igual ao que o definir devolveu ───────────────────────────────────────────────────────────────────────

select is(pg_temp.pref_do_perfil((select ana from ids)), (select j from ligou),
  'C1 o objeto do perfil é exatamente o que o definir devolveu ao ligar');

-- ── B. Desligar e reler ───────────────────────────────────────────────────────────────────────────────────────

create temp table desligou as
  select pg_temp.como((select ana from ids), $$ select public.definir_preferencia_chamadas(aceita_chamadas => false) $$) as j;
select is(pg_temp.pref_do_perfil((select ana from ids))->>'aceita_chamadas', 'false', 'B1 depois de desligar, o perfil traz aceita_chamadas = false');
select ok(not (pg_temp.pref_do_perfil((select ana from ids)) ? 'pendencias_para_busca'), 'B2 e sem a chave pendencias_para_busca');
select is(pg_temp.pref_do_perfil((select ana from ids)), (select j from desligou), 'C2 o objeto do perfil é o que o definir devolveu ao desligar');

-- ── Uma linha criada sem mexer em "Aceito chamadas diretas": o padrão é false ─────────────────────────────────────────

delete from public.profissional_preferencia_chamada where profissional_id = (select ana_prof from ids);
select pg_temp.como((select ana from ids), $$ select public.definir_preferencia_chamadas(antecedencia_minima_h => 24) $$);
select is(pg_temp.pref_do_perfil((select ana from ids))->>'aceita_chamadas', 'false', 'B3 linha criada sem aceita_chamadas: o perfil traz false (padrão)');
select is(pg_temp.pref_do_perfil((select ana from ids))->>'antecedencia_minima_h', '24', 'B4 e as 4 chaves de antes continuam');
select is((select array_agg(k order by k) from jsonb_object_keys(pg_temp.pref_do_perfil((select ana from ids))) k),
  array['aceita_chamadas', 'aceita_de', 'aceita_de_quem_ja_trabalhou', 'antecedencia_minima_h', 'pausado_ate'],
  'B5 sem aceitar chamadas o objeto tem as 4 chaves de antes mais aceita_chamadas');

-- ── D. Outros RPCs que devolvem o perfil, e a exportação ───────────────────────────────────────────────────────────

select pg_temp.como((select ana from ids),
  $$ select public.definir_preferencia_chamadas(aceita_chamadas => true, versao_texto_busca => '2026-11-16') $$);
select is(
  (pg_temp.como((select ana from ids), $$ select public.atualizar_apresentacao_profissional('{"apresentacao":"Texto sintético de teste"}'::jsonb) $$))
    -> 'preferencia_chamadas' ->> 'aceita_chamadas',
  'true', 'D1 atualizar_apresentacao_profissional devolve o perfil com aceita_chamadas = true');
select is(
  (pg_temp.como((select ana from ids), $$ select public.definir_regioes_atendidas(array[]::int[], true) $$))
    -> 'preferencia_chamadas' ->> 'aceita_chamadas',
  'true', 'D2 definir_regioes_atendidas também');
select is(jsonb_typeof((pg_temp.como((select ana from ids), $$ select public.definir_regioes_atendidas(array[]::int[], true) $$))
    -> 'preferencia_chamadas' -> 'pendencias_para_busca'),
  'array', 'D3 e com pendencias_para_busca');
select is(privado.meus_dados((select ana from ids)) -> 'perfil_profissional' -> 'preferencia_chamadas' ->> 'aceita_chamadas', 'true',
  'D4 a exportação (meus_dados) traz aceita_chamadas = true');
select is(jsonb_typeof(privado.meus_dados((select ana from ids)) -> 'perfil_profissional' -> 'preferencia_chamadas' -> 'pendencias_para_busca'), 'array',
  'D5 e pendencias_para_busca');
select is(
  privado.meus_dados((select ana from ids)) -> 'perfil_profissional' -> 'preferencia_chamadas',
  pg_temp.pref_do_perfil((select ana from ids)),
  'D6 a exportação e o perfil trazem o mesmo objeto');

-- ── E. O outro profissional não é afetado ─────────────────────────────────────────────────────────────────────────

select is(pg_temp.pref_do_perfil((select bruno from ids)), null::jsonb, 'E1 o Bruno, sem linha, continua sem preferencia_chamadas');
select is(privado.meus_dados((select bruno from ids)) -> 'perfil_profissional' -> 'preferencia_chamadas', null::jsonb,
  'E2 e na exportação também');

select * from finish();
rollback;
