-- 719_rls_dispositivo.sql
--
-- Cobertura de Row Level Security (RLS) para public.dispositivo (politica dispositivo_leitura):
--   Predicado:
--     using (usuario_id = (select auth.uid()))
--
-- Casos cobertos:
--   1. Catalogo & RLS:
--      - RLS ativo em public.dispositivo;
--      - Papel anon recebe 42501 em SELECT direto e nao possui grant.
--   2. Cada usuario le apenas os seus proprios aparelhos:
--      - Profissional Ana le seu dispositivo registrado (token FCM / plataforma);
--      - Contratante Ze le seu dispositivo registrado;
--      - Cada usuario le apenas os seus proprios dispositivos.
--   3. Lacuna Top 7 - Contratante NAO le tokens FCM de profissionais:
--      - Contratante Ze recebe 0 linhas no dispositivo de Ana
--        (protege credencial de entrega contra envio abusivo de push, spoofing e sequestro de sessao);
--      - Ze le 0 dispositivos alheios.
--   4. Isolamento entre profissionais:
--      - Profissional Beto recebe 0 linhas no dispositivo de Ana;
--      - Beto le apenas o seu proprio aparelho.
--   5. Isolamento de terceiros:
--      - Profissional sem aparelho cadastrado le 0 dispositivos;
--      - Sessao sem claims (auth.uid() nulo) le 0 dispositivos.
--   6. Provas de mutacao real do predicado USING:
--      - Mutante sem politica: donos legitimos deixam de ler seus aparelhos;
--      - Mutante com vazamento aberto (true): detecta se contratante conseguisse ler token de profissional;
--      - Mutante com perfil enviesado (apenas contratante le): profissional perde e contratante vaza;
--      - Restauracao da politica canonica e revalidacao completa.

begin;
select plan(23);

insert into privado.ambiente (id, eh_teste) values (true, true)
  on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-25 12:00:00+00';
set local frila.agendador_secret = 'teste-segredo-719';

-- ── 1. Auxiliares ──────────────────────────────────────────────────────────────

create function pg_temp.contar_como(conta uuid, sql text) returns integer
language plpgsql as $$
declare n integer;
begin
  execute 'set local role authenticated';
  if conta is not null then
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', conta, 'role', 'authenticated')::text);
  else
    execute 'set local request.jwt.claims = ''{"role":"authenticated"}''';
  end if;
  execute sql into n;
  reset role;
  execute 'reset request.jwt.claims';
  return n;
end $$;

create function pg_temp.como(papel text, sql text) returns void
language plpgsql as $$
begin
  execute format('set local role %I', papel);
  execute sql;
  reset role;
end $$;

-- ── 2. Cenario Hermetico ───────────────────────────────────────────────────────

create temp table ids as select
  '71900000-0000-4000-8000-000000000001'::uuid as c_ze,                -- contratante Bar do Ze
  '71900000-0000-4000-8000-000000000002'::uuid as c_rita,              -- contratante Buffet da Rita
  '71900000-0000-4000-8000-000000000003'::uuid as p_ana,               -- profissional Ana
  '71900000-0000-4000-8000-000000000004'::uuid as p_beto,              -- profissional Beto
  '71900000-0000-4000-8000-000000000005'::uuid as p_clara,             -- profissional Clara (sem aparelho)
  '71900000-0000-4000-8000-000000000091'::uuid as disp_ze,             -- aparelho do Ze
  '71900000-0000-4000-8000-000000000092'::uuid as disp_ana,            -- aparelho da Ana
  '71900000-0000-4000-8000-000000000093'::uuid as disp_beto;           -- aparelho do Beto

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', id_val, 'authenticated', 'authenticated',
       email_val, '2026-10-25 12:00:00+00', '{"provider":"email"}', '{}',
       '2026-10-25 12:00:00+00', '2026-10-25 12:00:00+00', false, false
from (values
  ((select c_ze from ids),    'ze.719@test.com'),
  ((select c_rita from ids),  'rita.719@test.com'),
  ((select p_ana from ids),   'ana.719@test.com'),
  ((select p_beto from ids),  'beto.719@test.com'),
  ((select p_clara from ids), 'clara.719@test.com')
) as u(id_val, email_val);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values
  ((select c_ze from ids),    'contratante',  'Ze Bar 719',         '+5561997190001', 'ze.719@test.com',    '1980-01-01', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select c_rita from ids),  'contratante',  'Rita Buffet 719',    '+5561997190002', 'rita.719@test.com',  '1982-02-02', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_ana from ids),   'profissional', 'Ana Garconete 719',  '+5561997190003', 'ana.719@test.com',   '1995-03-03', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_beto from ids),  'profissional', 'Beto Garcom 719',    '+5561997190004', 'beto.719@test.com',  '1996-04-04', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_clara from ids), 'profissional', 'Clara Terceira 719', '+5561997190005', 'clara.719@test.com', '1997-05-05', '2026-09-22', '2026-10-25 12:00:00+00');

-- Aparelhos cadastrados
insert into public.dispositivo (id, usuario_id, token_fcm, plataforma, atualizado_em, vinculo_id)
values
  ((select disp_ze from ids),   (select c_ze from ids),   'token-fcm-ze-719',   'android', '2026-10-25 12:00:00+00', gen_random_uuid()),
  ((select disp_ana from ids),  (select p_ana from ids),  'token-fcm-ana-719',  'ios',     '2026-10-25 12:05:00+00', gen_random_uuid()),
  ((select disp_beto from ids), (select p_beto from ids), 'token-fcm-beto-719', 'android', '2026-10-25 12:10:00+00', gen_random_uuid());

grant select on ids to authenticated;

-- ── 3. Catalogo e anon ─────────────────────────────────────────────────────────

select has_table('public', 'dispositivo', 'tabela public.dispositivo existe');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.dispositivo'::regclass),
  'RLS ativo em public.dispositivo'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.dispositivo') $$,
  '42501',
  null,
  'papel anon recebe 42501 em SELECT direto em public.dispositivo'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public' and table_name = 'dispositivo'),
  0,
  'anon nao possui grant em public.dispositivo'
);

-- ── 4. Cada usuario le apenas os seus proprios aparelhos ───────────────────────

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.dispositivo where id = %L', (select disp_ana from ids))
  ),
  1,
  'profissional Ana le o seu proprio dispositivo registrado'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    'select count(*)::int from public.dispositivo'
  ),
  1,
  'Ana le apenas o seu proprio aparelho (1 linha)'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.dispositivo where id = %L', (select disp_ze from ids))
  ),
  1,
  'contratante Ze le o seu proprio dispositivo registrado'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    'select count(*)::int from public.dispositivo'
  ),
  1,
  'Ze le apenas o seu proprio aparelho (1 linha)'
);

-- ── 5. Lacuna Top 7: Contratante NAO le tokens FCM de profissionais ────────────

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.dispositivo where id = %L', (select disp_ana from ids))
  ),
  0,
  'contratante recebe 0 linhas no token FCM de profissional (lacuna Top 7)'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.dispositivo where usuario_id = %L', (select p_beto from ids))
  ),
  0,
  'contratante recebe 0 linhas no aparelho de qualquer profissional'
);

-- ── 6. Isolamento entre profissionais ──────────────────────────────────────────

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.dispositivo where id = %L', (select disp_ana from ids))
  ),
  0,
  'profissional Beto recebe 0 linhas no aparelho de Ana'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    'select count(*)::int from public.dispositivo'
  ),
  1,
  'Beto le apenas o seu proprio aparelho'
);

-- ── 7. Isolamento de Terceiros ─────────────────────────────────────────────────

select is(
  pg_temp.contar_como(
    (select p_clara from ids),
    'select count(*)::int from public.dispositivo'
  ),
  0,
  'profissional sem aparelho cadastrado le 0 dispositivos'
);

select is(
  pg_temp.contar_como(
    (select c_rita from ids),
    'select count(*)::int from public.dispositivo'
  ),
  0,
  'contratante sem aparelho cadastrado le 0 dispositivos'
);

select is(
  pg_temp.contar_como(
    null,
    'select count(*)::int from public.dispositivo'
  ),
  0,
  'sessao sem claims (auth.uid() nulo) le 0 dispositivos'
);

-- ── 8. Provas de Mutacao Real do Predicado USING ──────────────────────────────

-- Mutacao 1: Remocao total da politica fecha o acesso legitimo dos donos
drop policy dispositivo_leitura on public.dispositivo;

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.dispositivo where id = %L', (select disp_ana from ids))
  ),
  0,
  'mutante sem politica: Ana deixa de ler seu aparelho'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.dispositivo where id = %L', (select disp_ze from ids))
  ),
  0,
  'mutante sem politica: Ze deixa de ler seu aparelho'
);

-- Mutacao 2: Vazamento irrestrito (using true)
create policy dispositivo_leitura on public.dispositivo for select to authenticated
  using (true);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.dispositivo where id = %L', (select disp_ana from ids))
  ),
  1,
  'mutante com vazamento aberto: contratante passaria a ler token FCM de profissional'
);

-- Mutacao 3: Inversao enviesada por perfil (apenas contratante le)
drop policy dispositivo_leitura on public.dispositivo;
create policy dispositivo_leitura on public.dispositivo for select to authenticated
  using (
    (select perfil from public.usuario where id = (select auth.uid())) = 'contratante'
  );

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.dispositivo where id = %L', (select disp_ana from ids))
  ),
  0,
  'mutante enviesado por perfil: profissional deixa de ler seu proprio aparelho'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.dispositivo where id = %L', (select disp_ana from ids))
  ),
  1,
  'mutante enviesado por perfil: contratante le indevidamente aparelho alheio'
);

-- Restauracao da politica canonica e revalidacao final
drop policy dispositivo_leitura on public.dispositivo;
create policy dispositivo_leitura on public.dispositivo for select to authenticated
  using (usuario_id = (select auth.uid()));

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.dispositivo where id = %L', (select disp_ana from ids))
  ),
  1,
  'politica restaurada: Ana le novamente seu aparelho'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.dispositivo where id = %L', (select disp_ze from ids))
  ),
  1,
  'politica restaurada: Ze le novamente seu aparelho'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.dispositivo where id = %L', (select disp_ana from ids))
  ),
  0,
  'politica restaurada: Ze volta a receber 0 no aparelho de Ana'
);

select * from finish();
rollback;
