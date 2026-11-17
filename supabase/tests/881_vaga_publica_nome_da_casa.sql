-- 881_vaga_publica_nome_da_casa.sql
--
-- vaga_publica mostra o nome do estabelecimento (migração 20261117090000, contrato 0.2.101):
--   só de casa com CNPJ (documento com 14 dígitos) e só com a vaga aberta (publicada e ainda não começada).
--   CNPJ + aberta → o nome · CPF + aberta → null · CNPJ + cancelada → null · CNPJ + preenchida → null
--   CNPJ + publicada mas já começada → null · documento fora do formato → null (falha fechada)
-- Os mesmos valores para anon e para quem está logado. Nada de endereço, ponto ou documento no corpo.
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-17 12:00:00+00', true);
select plan(9);

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  if conta is null then
    execute 'set local role anon';
    execute 'set local request.jwt.claims = ''{"role":"anon"}''';
  else
    execute 'set local role authenticated';
    execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  end if;
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;
create function pg_temp.id(n int) returns uuid language sql immutable as $$
  select ('c8810000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.nome(conta uuid, n int) returns text language sql as $$
  select pg_temp.como(conta, format('select public.vaga_publica(%L)', pg_temp.id(n)))->>'estabelecimento_nome' $$;

-- 1 contratante real (dono das casas) · 3 profissional real (só para ler logado)
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data,
                        raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', pg_temp.id(n), 'authenticated', 'authenticated',
       'conta' || n || '.881@teste.invalid', '2026-11-01 12:00:00+00', '{"provider":"email"}', '{}',
       '2026-11-01 12:00:00+00', '2026-11-01 12:00:00+00', false, false
  from unnest(array[1, 3]) n;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
values (pg_temp.id(1), 'contratante',  'Contratante 881',  '+5561988100001', 'conta1.881@teste.invalid', '1980-01-01', '2026-09-22', '2026-11-01 12:00:00+00', false),
       (pg_temp.id(3), 'profissional', 'Profissional 881', '+5561988100003', 'conta3.881@teste.invalid', '1995-01-01', '2026-09-22', '2026-11-01 12:00:00+00', false);
insert into public.profissional (id, usuario_id, ponto_base)
values (pg_temp.id(13), pg_temp.id(3), 'POINT(-47.8820 -15.7940)'::extensions.geography);
-- 21 com CNPJ · 22 com CPF · 23 com documento fora do formato (pontuado)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values (pg_temp.id(21), 'Bar Com CNPJ 881', '94827988100199', 'food_service', 'EnderecoSigiloso881',
        'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto'),
       (pg_temp.id(22), 'Casa da Pessoa 881', '94827988101', 'food_service', 'EnderecoSigiloso881b',
        'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto'),
       (pg_temp.id(23), 'Casa Formato 881', '94.827.988/1001-99', 'food_service', 'EnderecoSigiloso881c',
        'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select pg_temp.id(1), pg_temp.id(n), 'administrador' from unnest(array[21, 22, 23]) n;

-- 31 CNPJ aberta · 32 CPF aberta · 33 CNPJ cancelada · 34 CNPJ preenchida · 35 CNPJ publicada já começada
-- 36 documento fora do formato, aberta
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos,
                         posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
                         modo, estado, chave_cliente, publicado_por, publicado_em, regiao_administrativa, origem)
select pg_temp.id(n),
       case n when 32 then pg_temp.id(22) when 36 then pg_temp.id(23) else pg_temp.id(21) end,
       (select id from public.funcao where nome = 'garçom'),
       case n when 35 then '2026-11-17 11:00:00+00'::timestamptz else '2026-11-20 21:00:00+00'::timestamptz end,
       case n when 35 then '2026-11-17 16:00:00+00'::timestamptz else '2026-11-21 02:00:00+00'::timestamptz end,
       'LocalSigiloso881', 'POINT(-47.88 -15.79)'::extensions.geography, 18000, 1, true, false, false, 'Resp881',
       'urgencia', (case n when 33 then 'cancelada' when 34 then 'preenchida' else 'publicada' end)::public.estado_vaga,
       gen_random_uuid(), pg_temp.id(1), '2026-11-16 15:00:00+00', 'Plano Piloto', 'publicacao'
  from generate_series(31, 36) n;

select is(pg_temp.nome(null, 31), 'Bar Com CNPJ 881', 'CNPJ e vaga aberta: anon recebe o nome do estabelecimento');
select is(pg_temp.nome(pg_temp.id(3), 31), 'Bar Com CNPJ 881', 'CNPJ e vaga aberta: logado recebe o mesmo nome');
select is(pg_temp.nome(null, 32), null, 'CPF: o nome vem null (pode ser o nome de uma pessoa)');
select is(pg_temp.nome(null, 33), null, 'vaga cancelada: o nome vem null');
select is(pg_temp.nome(null, 34), null, 'vaga preenchida: o nome vem null');
select is(pg_temp.nome(null, 35), null, 'vaga publicada mas já começada: o nome vem null');
select is(pg_temp.nome(null, 36), null, 'documento fora do formato de 14 dígitos: null (falha fechada)');
select ok(pg_temp.como(null, format('select public.vaga_publica(%L)', pg_temp.id(32))) ? 'estabelecimento_nome',
          'a chave estabelecimento_nome existe mesmo quando vem null');
select ok(pg_temp.como(null, format('select public.vaga_publica(%L)', pg_temp.id(31)))::text !~ '(EnderecoSigiloso|94827988|LocalSigiloso|Resp881)',
          'com o nome, nada de endereço, documento, local ou responsável no corpo');

select * from finish();
rollback;
