-- 902_aceitar_convite_confere_email.sql
--
-- B-123 (ROPA, convites de membros, item 1; migração 20261125140000): public.aceitar_convite_membro
-- confere o e-mail do convidado. Depois de validar o token, o e-mail da conta que aceita
-- (auth.users.email do auth.uid()) tem de ser igual ao do convite, em lower(btrim()) dos dois lados,
-- e a conta tem de ter o e-mail CONFIRMADO. Se não: 403 convite_de_outro_email, sem details e sem
-- revelar o e-mail do convite nem o da conta; e a recusa NÃO consome o convite.
--
--   1. aceite certo (e-mail igual, confirmado) vira membro e consome o convite
--   2. e-mail diferente: 403 convite_de_outro_email, convite NÃO consumido, e a conta certa aceita depois
--   3. recusa sem details e sem e-mail do convite nem da conta
--   4. maiúsculas e espaços: conta com caixa mista e espaços · convite em maiúsculas
--   5. e-mail NÃO confirmado · conta sem e-mail: mesma recusa, convite intacto
--   6. ordem das recusas: 401 → perfil_incompativel → convite_invalido (token inexistente, usado, vencido,
--      vazio) → 403; token inexistente não vaza
--   7. convite sem e-mail não existe: NOT NULL e CHECK da tabela recusam
--   8. quem já é membro: troca de papel com o e-mail certo; recusado com o errado; ultimo_administrador
--      continua valendo (e-mail certo) e o 403 vem antes (e-mail errado)
-- Só dados sintéticos.
begin;
select plan(34);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local "frila.agora" = '2026-11-25 15:00:00+00';

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

-- A recusa por inteiro: o envelope de public.erro (message) mais o status (detail).
create function pg_temp.erro(conta uuid, sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  if conta is null then
    execute 'set local role authenticated';
    execute 'set local request.jwt.claims = ''{"role":"authenticated"}''';
    execute sql;
  else
    perform pg_temp.como(conta, sql);
  end if;
  return null;
exception when others then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return msg::jsonb || det::jsonb;
end $$;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
-- ...01 administrador único · ...02 contratante certa · ...03 contratante de outro e-mail
-- ...04 e-mail em caixa mista e com espaços · ...05 e-mail não confirmado · ...06 sem e-mail
-- ...07 profissional · ...08 operador já membro · ...09 segundo administrador

insert into auth.users (id, email, email_confirmed_at) values
  ('90200000-0000-4000-8000-000000000001', 'admin.902@teste.invalid',     now()),
  ('90200000-0000-4000-8000-000000000002', 'certa.902@teste.invalid',     now()),
  ('90200000-0000-4000-8000-000000000003', 'outra.902@teste.invalid',     now()),
  ('90200000-0000-4000-8000-000000000004', '  Mixed.902@Teste.INVALID  ', now()),
  ('90200000-0000-4000-8000-000000000005', 'naoconf.902@teste.invalid',   null),
  ('90200000-0000-4000-8000-000000000006', null,                          now()),
  ('90200000-0000-4000-8000-000000000007', 'prof.902@teste.invalid',      now()),
  ('90200000-0000-4000-8000-000000000008', 'membro.902@teste.invalid',    now()),
  ('90200000-0000-4000-8000-000000000009', 'admin2.902@teste.invalid',    now());

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em, estado) values
  ('90200000-0000-4000-8000-000000000001', 'contratante',  'Admin 902',    'admin.902@teste.invalid',   '+5561955509021', '1985-01-01', '1.0', now(), 'ativa'),
  ('90200000-0000-4000-8000-000000000002', 'contratante',  'Certa 902',    'certa.902@teste.invalid',   '+5561955509022', '1990-02-02', '1.0', now(), 'ativa'),
  ('90200000-0000-4000-8000-000000000003', 'contratante',  'Outra 902',    'outra.902@teste.invalid',   '+5561955509023', '1991-03-03', '1.0', now(), 'ativa'),
  ('90200000-0000-4000-8000-000000000004', 'contratante',  'Mixed 902',    'mixed.902@teste.invalid',   '+5561955509024', '1992-04-04', '1.0', now(), 'ativa'),
  ('90200000-0000-4000-8000-000000000005', 'contratante',  'NaoConf 902',  'naoconf.902@teste.invalid', '+5561955509025', '1993-05-05', '1.0', now(), 'ativa'),
  ('90200000-0000-4000-8000-000000000006', 'contratante',  'SemEmail 902', 'sememail.902@teste.invalid','+5561955509026', '1994-06-06', '1.0', now(), 'ativa'),
  ('90200000-0000-4000-8000-000000000007', 'profissional', 'Prof 902',     'prof.902@teste.invalid',    '+5561955509027', '1995-07-07', '1.0', now(), 'ativa'),
  ('90200000-0000-4000-8000-000000000008', 'contratante',  'Membro 902',   'membro.902@teste.invalid',  '+5561955509028', '1996-08-08', '1.0', now(), 'ativa'),
  ('90200000-0000-4000-8000-000000000009', 'contratante',  'Admin2 902',   'admin2.902@teste.invalid',  '+5561955509029', '1997-09-09', '1.0', now(), 'ativa');

insert into public.profissional (id, usuario_id, ponto_base) values
  ('90200000-0000-4000-8000-000000000070', '90200000-0000-4000-8000-000000000007', 'POINT(-47.8822 -15.7942)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('90200000-0000-4000-8000-0000000000e1', 'Bar Central 902', '90211222000199', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('90200000-0000-4000-8000-0000000000e1', '90200000-0000-4000-8000-000000000001', 'administrador'),
  ('90200000-0000-4000-8000-0000000000e1', '90200000-0000-4000-8000-000000000008', 'operador');

-- Convites inseridos direto (o e-mail do convite fica como o teste precisa; convidar_membro grava em minúsculas).
create function pg_temp.convite(tok text, email text, papel public.papel_membro, expira timestamptz default '2026-12-02 15:00:00+00')
returns void language sql as $$
  insert into privado.convite_membro (estabelecimento_id, email, papel, convidado_por, token_hash, expira_em)
  values ('90200000-0000-4000-8000-0000000000e1', email, papel, '90200000-0000-4000-8000-000000000001',
          encode(sha256(convert_to(tok, 'UTF8')), 'hex'), expira);
$$;

create function pg_temp.usado(tok text) returns boolean language sql as $$
  select usado_em is not null from privado.convite_membro
   where token_hash = encode(sha256(convert_to(tok, 'UTF8')), 'hex');
$$;

select pg_temp.convite('tok-certo-902',     'certa.902@teste.invalid',   'operador');
select pg_temp.convite('tok-caixa-902',     'MIXED.902@TESTE.INVALID',   'operador');
select pg_temp.convite('tok-naoconf-902',   'naoconf.902@teste.invalid', 'operador');
select pg_temp.convite('tok-sememail-902',  'sememail.902@teste.invalid','operador');
select pg_temp.convite('tok-prof-902',      'prof.902@teste.invalid',    'operador');
select pg_temp.convite('tok-vencido-902',   'certa.902@teste.invalid',   'operador', '2026-11-24 15:00:00+00');
select pg_temp.convite('tok-membro-902',    'membro.902@teste.invalid',  'administrador');
select pg_temp.convite('tok-ultimo-902',    'admin.902@teste.invalid',   'operador');

-- ── 1. Aceite certo ───────────────────────────────────────────────────────────

create temp table aceite as
  select pg_temp.como('90200000-0000-4000-8000-000000000002',
    $$ select public.aceitar_convite_membro('tok-certo-902') $$) as r;

select is(
  (select r->>'papel' from aceite) = 'operador'
    and (select r->>'estabelecimento_id' from aceite) = '90200000-0000-4000-8000-0000000000e1'
    and (select r->>'usuario_id' from aceite) = '90200000-0000-4000-8000-000000000002',
  true,
  '1. e-mail igual e confirmado: a contratante aceita e vira operador da casa'
);

select is(pg_temp.usado('tok-certo-902'), true, '1. o aceite certo consome o convite');

-- ── 2. E-mail diferente: recusa sem consumir, e a conta certa aceita depois ───

-- O convite abaixo é para a conta ...03, que ainda não é membro; a conta ...02 tenta primeiro.
select pg_temp.convite('tok-depois-902', 'outra.902@teste.invalid', 'operador');

select is(
  (pg_temp.erro('90200000-0000-4000-8000-000000000002',
    $$ select public.aceitar_convite_membro('tok-depois-902') $$))->>'code',
  'convite_de_outro_email',
  '2. e-mail diferente: 403 convite_de_outro_email'
);

select is(
  (pg_temp.erro('90200000-0000-4000-8000-000000000002',
    $$ select public.aceitar_convite_membro('tok-depois-902') $$))->>'status',
  '403',
  '2. o status da recusa é 403'
);

select is(pg_temp.usado('tok-depois-902'), false, '2. a recusa NÃO consome o convite (o update foi desfeito)');

select is(
  (select r->>'usuario_id' from (select pg_temp.como('90200000-0000-4000-8000-000000000003',
    $$ select public.aceitar_convite_membro('tok-depois-902') $$) as r) x),
  '90200000-0000-4000-8000-000000000003',
  '2. depois da recusa da conta errada, a conta certa aceita o mesmo convite'
);

select is(pg_temp.usado('tok-depois-902'), true, '2. e agora o convite está consumido');

-- ── 3. A recusa não vaza e-mail ───────────────────────────────────────────────

select pg_temp.convite('tok-vaza-902', 'vaza.902@teste.invalid', 'operador');

create temp table recusa as
  select pg_temp.erro('90200000-0000-4000-8000-000000000008',
    $$ select public.aceitar_convite_membro('tok-vaza-902') $$) as e;

select is(
  (select e->>'code' from recusa) = 'convite_de_outro_email'
    and (select e->>'details' from recusa) is null,
  true,
  '3. a recusa não leva details'
);

select is(
  (select e::text from recusa) !~* '(vaza|membro)\.902|teste\.invalid',
  true,
  '3. a recusa não cita o e-mail do convite nem o da conta'
);

-- ── 4. Maiúsculas e espaços ───────────────────────────────────────────────────

select is(
  (select r->>'usuario_id' from (select pg_temp.como('90200000-0000-4000-8000-000000000004',
    $$ select public.aceitar_convite_membro('tok-caixa-902') $$) as r) x),
  '90200000-0000-4000-8000-000000000004',
  '4. conta com e-mail em caixa mista e com espaços aceita convite em maiúsculas (lower(btrim) dos dois lados)'
);

-- ── 5. E-mail não confirmado e conta sem e-mail ───────────────────────────────

select is(
  (pg_temp.erro('90200000-0000-4000-8000-000000000005',
    $$ select public.aceitar_convite_membro('tok-naoconf-902') $$))->>'code',
  'convite_de_outro_email',
  '5. e-mail igual mas NÃO confirmado: a mesma recusa 403 convite_de_outro_email'
);

select is(pg_temp.usado('tok-naoconf-902'), false, '5. a recusa por e-mail não confirmado não consome o convite');

select is(
  (pg_temp.erro('90200000-0000-4000-8000-000000000006',
    $$ select public.aceitar_convite_membro('tok-sememail-902') $$))->>'code',
  'convite_de_outro_email',
  '5. conta sem e-mail: a mesma recusa 403 convite_de_outro_email'
);

select is(pg_temp.usado('tok-sememail-902'), false, '5. a recusa por conta sem e-mail não consome o convite');

-- Depois de confirmar o e-mail, a mesma conta aceita o mesmo convite.
update auth.users set email_confirmed_at = now() where id = '90200000-0000-4000-8000-000000000005';
select is(
  (select r->>'usuario_id' from (select pg_temp.como('90200000-0000-4000-8000-000000000005',
    $$ select public.aceitar_convite_membro('tok-naoconf-902') $$) as r) x),
  '90200000-0000-4000-8000-000000000005',
  '5. confirmado o e-mail, a conta aceita o convite que foi recusado antes'
);

-- ── 6. Ordem das recusas ──────────────────────────────────────────────────────

select is(
  (pg_temp.erro(null, $$ select public.aceitar_convite_membro('tok-certo-902') $$))->>'status',
  '401',
  '6. sem sessão: 401 (antes de qualquer outra recusa)'
);

select is(
  (pg_temp.erro('90200000-0000-4000-8000-000000000007',
    $$ select public.aceitar_convite_membro('tok-prof-902') $$))->>'code',
  'perfil_incompativel',
  '6. profissional com o e-mail do convite: 422 perfil_incompativel (antes do 403)'
);

select is(
  (pg_temp.erro('90200000-0000-4000-8000-000000000003',
    $$ select public.aceitar_convite_membro('token-que-nao-existe-902') $$))->>'code',
  'convite_invalido',
  '6. token inexistente continua 422 convite_invalido (não vaza nada)'
);

select is(
  (pg_temp.erro('90200000-0000-4000-8000-000000000003',
    $$ select public.aceitar_convite_membro('tok-certo-902') $$))->>'code',
  'convite_invalido',
  '6. token já usado, de conta de outro e-mail: 422 convite_invalido (antes do 403)'
);

select is(
  (pg_temp.erro('90200000-0000-4000-8000-000000000003',
    $$ select public.aceitar_convite_membro('tok-vencido-902') $$))->>'code',
  'convite_invalido',
  '6. token vencido, de conta de outro e-mail: 422 convite_invalido (antes do 403)'
);

select is(
  (pg_temp.erro('90200000-0000-4000-8000-000000000003',
    $$ select public.aceitar_convite_membro('   ') $$))->>'code',
  'convite_invalido',
  '6. token vazio: 422 convite_invalido'
);

-- ── 7. Convite sem e-mail não existe ──────────────────────────────────────────

select throws_ok(
  $$ insert into privado.convite_membro (estabelecimento_id, email, papel, convidado_por, token_hash, expira_em)
     values ('90200000-0000-4000-8000-0000000000e1', null, 'operador',
             '90200000-0000-4000-8000-000000000001', encode(sha256('tok-null-902'::bytea), 'hex'),
             '2026-12-02 15:00:00+00') $$,
  '23502',
  null,
  '7. convite sem e-mail: o NOT NULL da tabela recusa'
);

select throws_ok(
  $$ insert into privado.convite_membro (estabelecimento_id, email, papel, convidado_por, token_hash, expira_em)
     values ('90200000-0000-4000-8000-0000000000e1', '', 'operador',
             '90200000-0000-4000-8000-000000000001', encode(sha256('tok-vazio-902'::bytea), 'hex'),
             '2026-12-02 15:00:00+00') $$,
  '23514',
  null,
  '7. convite com e-mail vazio: o CHECK de formato da tabela recusa'
);

select throws_ok(
  $$ insert into privado.convite_membro (estabelecimento_id, email, papel, convidado_por, token_hash, expira_em)
     values ('90200000-0000-4000-8000-0000000000e1', 'com espaco@teste.invalid', 'operador',
             '90200000-0000-4000-8000-000000000001', encode(sha256('tok-esp-902'::bytea), 'hex'),
             '2026-12-02 15:00:00+00') $$,
  '23514',
  null,
  '7. convite com e-mail com espaço: o CHECK de formato da tabela recusa'
);

-- ── 8. Quem já é membro ───────────────────────────────────────────────────────

select is(
  (pg_temp.erro('90200000-0000-4000-8000-000000000003',
    $$ select public.aceitar_convite_membro('tok-membro-902') $$))->>'code',
  'convite_de_outro_email',
  '8. o convite de troca de papel é recusado para quem tem outro e-mail'
);

select is(
  (select papel from public.membro_estabelecimento
    where estabelecimento_id = '90200000-0000-4000-8000-0000000000e1'
      and usuario_id = '90200000-0000-4000-8000-000000000008'),
  'operador'::public.papel_membro,
  '8. e o membro (operador) continua operador depois da recusa'
);

-- ultimo_administrador (antes da troca de papel acima, que cria um segundo administrador): ...01 é o único administrador e aceita convite de operador para o próprio e-mail.
select is(
  (pg_temp.erro('90200000-0000-4000-8000-000000000001',
    $$ select public.aceitar_convite_membro('tok-ultimo-902') $$))->>'code',
  'ultimo_administrador',
  '8. único administrador com o e-mail certo: ultimo_administrador continua valendo'
);

select is(pg_temp.usado('tok-ultimo-902'), false, '8. a recusa ultimo_administrador não consome o convite');

-- Convite de operador para o e-mail do administrador, aceito por outra conta: o 403 vem antes.
select is(
  (pg_temp.erro('90200000-0000-4000-8000-000000000009',
    $$ select public.aceitar_convite_membro('tok-ultimo-902') $$))->>'code',
  'convite_de_outro_email',
  '8. e-mail errado no convite do administrador: 403, o convite do administrador não serve a outra conta'
);

select is(
  (select papel from public.membro_estabelecimento
    where estabelecimento_id = '90200000-0000-4000-8000-0000000000e1'
      and usuario_id = '90200000-0000-4000-8000-000000000001'),
  'administrador'::public.papel_membro,
  '8. o administrador continua administrador'
);

-- Troca de papel de quem já é membro (a casa passa a ter dois administradores).
select is(
  (select r->>'papel' from (select pg_temp.como('90200000-0000-4000-8000-000000000008',
    $$ select public.aceitar_convite_membro('tok-membro-902') $$) as r) x),
  'administrador',
  '8. já é membro e aceita com o e-mail certo: troca de papel para administrador'
);

-- ── Catálogo ──────────────────────────────────────────────────────────────────

select is(
  (select proargnames from pg_proc where oid = 'public.aceitar_convite_membro(text)'::regprocedure),
  array['token']::text[],
  'a assinatura não mudou: aceitar_convite_membro(token text)'
);

select is(
  has_function_privilege('anon', 'public.aceitar_convite_membro(text)', 'execute')
    or not has_function_privilege('authenticated', 'public.aceitar_convite_membro(text)', 'execute'),
  false,
  'os grants não mudaram: anon sem execute, authenticated com execute'
);

select matches(
  pg_get_functiondef('public.aceitar_convite_membro(text)'::regprocedure),
  'for no key update',
  'a trava do estabelecimento (FOR NO KEY UPDATE) continua na função'
);

rollback;
