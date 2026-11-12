-- 832_gerar_codigo_checkin.sql
--
-- gerar_codigo_checkin (contrato 0.2.68, `gerarCodigoCheckin`; migração 20261111200000). Cobre:
--   · as recusas do contrato, na ordem do molde: 401 (sem sessão e conta que não existe mais),
--     403 conta_suspensa, 422 campo_obrigatorio, 404 (turno inexistente e bloqueio), 403 para quem
--     não é membro (o profissional inclusive) e 403 recurso_desligado sem escrever nada;
--   · o estado: 409 checkin_pendente, 409 checkin_ja_confirmado, 409 codigo_bloqueado (encerrado)
--     e 422 fora_da_janela, que a conta de demonstração atravessa (D9);
--   · o código: 6 dígitos, o mesmo dentro da validade, outro depois dela, segundos_restantes pelo
--     relógio do servidor, sem zerar os erros, no bloqueio temporário e sem push (critérios 4, 5, 6);
--   · a regra ausente vale 300 s (R1) e a validade da regra vale quando há linha;
--   · o código nunca sai num erro de restrição, nem na classe 23 inteira (R2).
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-01-11 21:30:00+00', true);
select plan(34);

-- A casa 832 (dono), outra casa (outro contratante) e um membro suspenso da casa 832.
create temp table ids as
select 'c8320000-0000-4000-8000-000000000001'::uuid as dono,
       'c8320000-0000-4000-8000-000000000002'::uuid as outro,
       'c8320000-0000-4000-8000-000000000003'::uuid as suspenso,
       'c8320000-0000-4000-8000-000000000021'::uuid as casa,
       'c8320000-0000-4000-8000-000000000022'::uuid as outra_casa;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select u, 'contratante'::public.perfil_conta, 'Casa 832 ' || n, '+556199999832' || n, 'casa832-' || n || '@test.invalid',
       '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids, lateral (values (dono, 1), (outro, 2), (suspenso, 3)) v (u, n);
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select c, 'Bar 832 ' || n, '8000000000083' || n, 'food_service'::public.tipo_estabelecimento, 'Endereço de teste',
       'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids, lateral (values (casa, 1), (outra_casa, 2)) v (c, n);
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select u, c, 'administrador' from ids, lateral (values (dono, casa), (outro, outra_casa), (suspenso, casa)) v (u, c);
update public.usuario set estado = 'suspensa' where id = (select suspenso from ids);

-- Um profissional com um turno confirmado de hoje, das 21h às 2h, ainda sem check-in.
create temp table turnos (nome text primary key, turno uuid, usuario uuid);
create function pg_temp.novo(nome text, inicio timestamptz default '2027-01-11 21:00:00+00') returns uuid
language plpgsql as $$
declare
  v_user uuid := gen_random_uuid(); v_prof uuid := gen_random_uuid();
  v_vaga uuid := gen_random_uuid(); v_pos  uuid := gen_random_uuid(); v_t uuid := gen_random_uuid();
begin
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_user, 'profissional', 'Prof 832 ' || nome, '+5561999998320', nome || '@t832.invalid',
          '1992-01-01', '1.0', '2026-09-20 12:00:00-03');
  insert into public.profissional (id, usuario_id, ponto_base) values (v_prof, v_user, 'POINT(-47.8800 -15.7700)');
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por)
  values (v_vaga, 'c8320000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
          inicio, inicio + interval '5 hours', 'Local 832', 'POINT(-47.8800 -15.7700)',
          15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada', inicio - interval '33 hours',
          gen_random_uuid(), 'c8320000-0000-4000-8000-000000000001');
  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_pos, v_vaga, 'confirmada', v_prof, inicio - interval '32 hours', inicio, inicio + interval '5 hours');
  insert into public.turno (id, posicao_id, valor_acordado_centavos) values (v_t, v_pos, 15000);
  insert into turnos values (nome, v_t, v_user);
  return v_t;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', conta, 'role', 'authenticated')::text, true);
  execute sql into r;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return r;
end $$;
create function pg_temp.t(nome text) returns uuid language sql as $$ select turno from turnos where turnos.nome = t.nome $$;
create function pg_temp.gerar(conta uuid, turno uuid) returns jsonb language sql as $$
  select pg_temp.como(conta, format('select public.gerar_codigo_checkin(%L::uuid)', turno))
$$;
create function pg_temp.sql_gerar(conta uuid, turno uuid) returns text language sql as $$
  select format('select pg_temp.gerar(%L::uuid, %L::uuid)', conta, turno)
$$;
-- A recusa como sai para a PostgREST: o code do envelope e o details.
create function pg_temp.recusa(conta uuid, turno uuid) returns text language plpgsql as $$
begin
  perform pg_temp.gerar(conta, turno);
  return 'ok';
exception when sqlstate 'PGRST' then
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return (sqlerrm::jsonb->>'code') || coalesce(':' || (sqlerrm::jsonb->>'details'), '');
end $$;
create function pg_temp.checkin(nome text, distancia integer) returns jsonb language sql as $$
  select pg_temp.como((select usuario from turnos where turnos.nome = checkin.nome),
                      format('select public.fazer_checkin(%L::uuid, %s, %L::timestamptz)', pg_temp.t(nome),
                             distancia, privado.agora()))
$$;
create function pg_temp.ligar() returns void language sql as $$
  update privado.recurso set ligado = true where chave = 'checkin_por_codigo';
  insert into privado.recurso_estabelecimento (chave, estabelecimento_id)
  values ('checkin_por_codigo', 'c8320000-0000-4000-8000-000000000021') on conflict do nothing;
$$;

select pg_temp.novo('a');                       -- o caminho feliz
select pg_temp.novo('sem_checkin');             -- sem check-in ainda
select pg_temp.novo('verificado');              -- geolocalizado, já verificado
select pg_temp.novo('encerrado');               -- caminho do código encerrado
select pg_temp.novo('bloqueado');               -- bloqueio entre o profissional e a casa
select pg_temp.novo('fora', '2027-01-12 08:00:00+00');   -- começa amanhã de manhã: fora da janela
select pg_temp.checkin('a', 500);               -- manual e pendente
select pg_temp.checkin('verificado', 50);       -- geolocalizado e verificado
select pg_temp.checkin('encerrado', 500);
select pg_temp.checkin('bloqueado', 500);
-- O check-in do turno de amanhã, gravado à mão: a janela do check-in também o recusaria.
update public.turno set checkin_em = '2027-01-11 21:30:00+00', checkin_tipo = 'manual', checkin_distancia_m = 500
 where id = pg_temp.t('fora');
insert into public.bloqueio (autor_id, bloqueado_id)
select dono, (select usuario from turnos where nome = 'bloqueado') from ids;

-- ── As recusas antes de tocar em dado ────────────────────────────────────────
select is(pg_temp.recusa(null, pg_temp.t('a')), 'nao_autenticado', 'sem sessão: 401');
select is(pg_temp.recusa('c8320000-0000-4000-8000-0000000000ff', pg_temp.t('a')), 'nao_autenticado',
  'conta que não existe mais (anonimizada e apagada): 401');
select is(pg_temp.recusa((select suspenso from ids), pg_temp.t('a')), 'sem_permissao:conta_suspensa',
  'conta suspensa: 403 conta_suspensa');
select is(pg_temp.recusa((select dono from ids), null), 'campo_obrigatorio:turno_id', 'sem turno_id: 422');
select is(pg_temp.recusa((select dono from ids), 'c8320000-0000-4000-8000-0000000000ee'), 'nao_encontrado',
  'turno que não existe: 404');
select is(pg_temp.recusa((select dono from ids), pg_temp.t('bloqueado')), 'nao_encontrado',
  'bloqueio entre o profissional e a casa: 404');
select is(pg_temp.recusa((select usuario from turnos where nome = 'a'), pg_temp.t('a')), 'sem_permissao',
  'o profissional do turno não gera o próprio código: 403');
select is(pg_temp.recusa((select outro from ids), pg_temp.t('a')), 'sem_permissao',
  'membro de outra casa: 403');
select is(pg_temp.recusa((select dono from ids), pg_temp.t('a')), 'sem_permissao:recurso_desligado',
  'chave desligada no global: 403 recurso_desligado');
update privado.recurso set ligado = true where chave = 'checkin_por_codigo';
select is(pg_temp.recusa((select dono from ids), pg_temp.t('a')), 'sem_permissao:recurso_desligado',
  'chave ligada, mas a casa fora da lista: 403 recurso_desligado');
select is((select count(*)::int from privado.checkin_codigo c where c.turno_id = pg_temp.t('a') and c.codigo is not null), 0,
  'chave desligada para a casa: nenhum código foi escrito');
select pg_temp.ligar();

-- ── As recusas do estado ─────────────────────────────────────────────────────
select is(pg_temp.recusa((select dono from ids), pg_temp.t('sem_checkin')), 'checkin_pendente',
  'sem check-in: 409 checkin_pendente');
select is(pg_temp.recusa((select dono from ids), pg_temp.t('verificado')), 'checkin_ja_confirmado',
  'presença já verificada: 409 checkin_ja_confirmado');
insert into privado.checkin_codigo (turno_id, erros, encerrado_em) values (pg_temp.t('encerrado'), 6, privado.agora())
    on conflict (turno_id) do update set erros = 6, encerrado_em = excluded.encerrado_em;
select is(pg_temp.recusa((select dono from ids), pg_temp.t('encerrado')), 'codigo_bloqueado:encerrado',
  'caminho encerrado (6ª errada): 409 codigo_bloqueado (encerrado)');
select is(pg_temp.recusa((select dono from ids), pg_temp.t('fora')), 'fora_da_janela',
  'fora da janela do check-in: 422 fora_da_janela');

-- ── O código ─────────────────────────────────────────────────────────────────
create temp table g1 as select pg_temp.gerar((select dono from ids), pg_temp.t('a')) as j;
select ok((select j->>'codigo' ~ '^[0-9]{6}$' from g1), 'o código tem 6 dígitos');
select results_eq($$ select (j->>'turno_id')::uuid, (j->>'expira_em')::timestamptz, (j->>'segundos_restantes')::int from g1 $$,
  $$ values (pg_temp.t('a'), privado.agora() + interval '300 seconds', 300) $$,
  'a resposta traz o turno, a validade de 300 s da regra e os segundos pelo relógio do servidor');
select is((select array_agg(k order by k) from g1, jsonb_object_keys(j) k), array['codigo', 'expira_em', 'segundos_restantes', 'turno_id'],
  'a resposta só tem os campos do contrato');
select is((select codigo from privado.checkin_codigo where turno_id = pg_temp.t('a')), (select j->>'codigo' from g1),
  'o código gravado é o que a resposta mostra');

select set_config('frila.agora', '2027-01-11 21:31:40.6+00', true);
create temp table g2 as select pg_temp.gerar((select dono from ids), pg_temp.t('a')) as j;
select is((select j->>'codigo' from g2), (select j->>'codigo' from g1), 'dentro da validade, o mesmo código');
select is((select (j->>'segundos_restantes')::int from g2), 199, 'segundos_restantes desce com o relógio, para baixo (199,4 → 199)');

-- Erros e bloqueio: código novo não devolve tentativas, e gera no bloqueio temporário.
update privado.checkin_codigo set erros = 3, bloqueado_ate = '2027-01-11 21:36:00+00'
 where turno_id = pg_temp.t('a');
select set_config('frila.agora', '2027-01-11 21:35:00+00', true);
create temp table g3 as select pg_temp.gerar((select dono from ids), pg_temp.t('a')) as j;
select is((select (j->>'expira_em')::timestamptz from g3), privado.agora() + interval '300 seconds',
  'vencido, um código novo, com validade nova');
select results_eq($$ select erros, bloqueado_ate from privado.checkin_codigo where turno_id = pg_temp.t('a') $$,
  $$ values (3, '2027-01-11 21:36:00+00'::timestamptz) $$, 'o código novo não zera os erros nem o bloqueio');
select is((select codigo from privado.checkin_codigo where turno_id = pg_temp.t('a')), (select j->>'codigo' from g3),
  'no bloqueio temporário, a casa gera, e o gravado é o novo');
select is((select count(*)::int from public.notificacao n where n.referencia_id = pg_temp.t('a')
            and n.tipo::text not in ('checkin_manual_pendente')), 0, 'gerar não manda push');

-- A regra: a validade dela vale; sem a linha, 300 s.
update privado.regra_checkin_codigo set validade_s = 120;
select set_config('frila.agora', '2027-01-11 21:41:00+00', true);
select is((pg_temp.gerar((select dono from ids), pg_temp.t('a'))->>'segundos_restantes')::int, 120,
  'a validade sai da regra (120 s)');
delete from privado.regra_checkin_codigo;
select set_config('frila.agora', '2027-01-11 21:44:00+00', true);
select is((pg_temp.gerar((select dono from ids), pg_temp.t('a'))->>'segundos_restantes')::int, 300,
  'sem a linha da regra, a validade é 300 s (coalesce, R1)');

-- A conta de demonstração atravessa a janela (D9).
update public.usuario set demonstracao = true where id = (select dono from ids);
select ok(pg_temp.gerar((select dono from ids), pg_temp.t('fora'))->>'codigo' ~ '^[0-9]{6}$',
  'a conta de demonstração gera fora da janela');
update public.usuario set demonstracao = false where id = (select dono from ids);

-- ── O código nunca sai num erro de restrição (R2) ────────────────────────────
-- O erro como o Postgres o entrega: SQLSTATE, mensagem e DETAIL.
create function pg_temp.erro_cru(turno uuid) returns text[] language plpgsql as $$
declare v_estado text; v_msg text; v_det text;
begin
  perform pg_temp.gerar('c8320000-0000-4000-8000-000000000001', turno);
  return array['ok'];
exception when others then
  get stacked diagnostics v_estado = returned_sqlstate, v_msg = message_text, v_det = pg_exception_detail;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return array[v_estado, v_msg, coalesce(v_det, '')];
end $$;
select set_config('frila.agora', '2027-01-11 21:50:00+00', true);
-- check_violation na escrita do código novo: o DETAIL do Postgres traria a linha com os 6 dígitos.
alter table privado.checkin_codigo add constraint zz_832_sem_codigo check (codigo is null) not valid;
create temp table e1 as select pg_temp.erro_cru(pg_temp.t('a')) as e;
select is((select e[1] from e1), '23514', 'check_violation na escrita: o mesmo SQLSTATE');
select is((select e[3] from e1), '', 'check_violation na escrita: sai sem o DETAIL');
select ok((select e[2] !~ '[0-9]{6}' and e[2] ~ 'zz_832_sem_codigo' from e1),
  'check_violation na escrita: a mensagem nomeia a restrição e não traz o código');
alter table privado.checkin_codigo drop constraint zz_832_sem_codigo;
-- not_null_violation, também da classe 23: um gatilho anula uma coluna obrigatória na linha que já tem o código.
create function privado.zz_832_anula() returns trigger language plpgsql as $$ begin new.erros := null; return new; end $$;
create trigger zz_832_anula before update on privado.checkin_codigo for each row execute function privado.zz_832_anula();
create temp table e2 as select pg_temp.erro_cru(pg_temp.t('a')) as e;
select is((select e[1] from e2), '23502', 'not_null_violation na escrita: o mesmo SQLSTATE');
select is((select e[3] from e2), '', 'not_null_violation na escrita: sai sem o DETAIL, que traria a linha com o código');
drop trigger zz_832_anula on privado.checkin_codigo;
select ok((select e[2] !~ '[0-9]{6}' from e2), 'not_null_violation na escrita: a mensagem não traz o código');

select * from finish();
rollback;
