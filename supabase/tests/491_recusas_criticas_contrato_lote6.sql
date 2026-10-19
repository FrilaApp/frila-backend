-- 15 recusas criticas do contrato lote 6 (06/10/2026).
--
-- Blindagem do perímetro de autenticação (401 nao_autenticado) nas 15 operações centrais:
-- 1.  publicarVaga (401 nao_autenticado)
-- 2.  cancelarVaga (401 nao_autenticado)
-- 3.  cancelarPosicao (401 nao_autenticado)
-- 4.  candidatar (401 nao_autenticado)
-- 5.  retirarCandidatura (401 nao_autenticado)
-- 6.  fazerCheckin (401 nao_autenticado)
-- 7.  fazerCheckout (401 nao_autenticado)
-- 8.  confirmarCheckinManual (401 nao_autenticado)
-- 9.  reabrirPorAtraso (401 nao_autenticado)
-- 10. avaliar (401 nao_autenticado)
-- 11. bloquear (401 nao_autenticado)
-- 12. denunciar (401 nao_autenticado)
-- 13. contestarSuspensao (401 nao_autenticado)
-- 14. pedirRevisaoDespacho (401 nao_autenticado)
-- 15. candidatosDaVaga (401 nao_autenticado)
--
-- Ids próprios começando em `c4910000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(15);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

-- 1. publicarVaga: 401 nao_autenticado
select throws_ok(
  $$ select public.publicar_vaga(
       'c4910000-0000-4000-8000-000000000001'::uuid,
       'c4910000-0000-4000-8000-000000000002'::uuid,
       '2027-01-18 21:00:00+00'::timestamptz,
       '2027-01-19 03:00:00+00'::timestamptz,
       'CLN 108',
       '{"latitude":-15.7905,"longitude":-47.8855}'::jsonb,
       16000::bigint,
       1,
       true,
       false,
       false,
       'Gerente',
       'urgencia'::public.modo_preenchimento,
       gen_random_uuid(),
       'camisa preta',
       true,
       'porta dos fundos',
       180
     ) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '1. publicarVaga sem sessão recusa 401 nao_autenticado'
);

-- 2. cancelarVaga: 401 nao_autenticado
select throws_ok(
  $$ select public.cancelar_vaga('c4910000-0000-4000-8000-000000000001'::uuid, 'motivo teste') $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '2. cancelarVaga sem sessão recusa 401 nao_autenticado'
);

-- 3. cancelarPosicao: 401 nao_autenticado
select throws_ok(
  $$ select public.cancelar_posicao('c4910000-0000-4000-8000-000000000001'::uuid, 'motivo teste') $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '3. cancelarPosicao sem sessão recusa 401 nao_autenticado'
);

-- 4. candidatar: 401 nao_autenticado
select throws_ok(
  $$ select public.candidatar('c4910000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '4. candidatar sem sessão recusa 401 nao_autenticado'
);

-- 5. retirarCandidatura: 401 nao_autenticado
select throws_ok(
  $$ select public.retirar_candidatura('c4910000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '5. retirarCandidatura sem sessão recusa 401 nao_autenticado'
);

-- 6. fazerCheckin: 401 nao_autenticado
select throws_ok(
  $$ select public.fazer_checkin('c4910000-0000-4000-8000-000000000001'::uuid, 50, now()) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '6. fazerCheckin sem sessão recusa 401 nao_autenticado'
);

-- 7. fazerCheckout: 401 nao_autenticado
select throws_ok(
  $$ select public.fazer_checkout('c4910000-0000-4000-8000-000000000001'::uuid, 50, now()) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '7. fazerCheckout sem sessão recusa 401 nao_autenticado'
);

-- 8. confirmarCheckinManual: 401 nao_autenticado
select throws_ok(
  $$ select public.confirmar_checkin_manual('c4910000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '8. confirmarCheckinManual sem sessão recusa 401 nao_autenticado'
);

-- 9. reabrirPorAtraso: 401 nao_autenticado
select throws_ok(
  $$ select public.reabrir_por_atraso('c4910000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '9. reabrirPorAtraso sem sessão recusa 401 nao_autenticado'
);

-- 10. avaliar: 401 nao_autenticado
select throws_ok(
  $$ select public.avaliar('c4910000-0000-4000-8000-000000000001'::uuid, true) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '10. avaliar sem sessão recusa 401 nao_autenticado'
);

-- 11. bloquear: 401 nao_autenticado
select throws_ok(
  $$ select public.bloquear('profissional', 'c4910000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '11. bloquear sem sessão recusa 401 nao_autenticado'
);

-- 12. denunciar: 401 nao_autenticado
select throws_ok(
  $$ select public.denunciar('profissional', 'c4910000-0000-4000-8000-000000000001'::uuid, 'outro', 'relato teste de denuncia com tamanho suficiente', gen_random_uuid()) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '12. denunciar sem sessão recusa 401 nao_autenticado'
);

-- 13. contestarSuspensao: 401 nao_autenticado
select throws_ok(
  $$ select public.contestar_suspensao('relato teste') $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '13. contestarSuspensao sem sessão recusa 401 nao_autenticado'
);

-- 14. pedirRevisaoDespacho: 401 nao_autenticado
select throws_ok(
  $$ select public.pedir_revisao_despacho('relato teste de revisao de despacho com tamanho suficiente.') $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '14. pedirRevisaoDespacho sem sessão recusa 401 nao_autenticado'
);

-- 15. candidatosDaVaga: 401 nao_autenticado
select throws_ok(
  $$ select public.candidatos_da_vaga('c4910000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '15. candidatosDaVaga sem sessão recusa 401 nao_autenticado'
);

rollback;
