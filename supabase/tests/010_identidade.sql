-- RN20, RN25 e as restrições de contato da conta.

begin;
select plan(13);

-- Fixture mínima. Vive em pg_temp para não sobrar nada fora da transação do teste.
create function pg_temp.conta(p_id uuid, p_perfil public.perfil_conta,
                              p_nasc date default '1990-01-01',
                              p_email text default null)
returns uuid language sql as $$
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento)
  values (p_id, p_perfil, 'Fulano', '+5561999990000',
          coalesce(p_email, p_id::text || '@exemplo.test'), p_nasc)
  returning id;
$$;

-- ── RN20: maioridade verificada na escrita ─────────────────────────────────────
select lives_ok(
  $$ select pg_temp.conta('00000000-0000-0000-0000-000000000001', 'profissional',
                          (current_date - interval '18 years')::date) $$,
  'RN20: exatamente 18 anos entra');

select throws_ok(
  $$ select pg_temp.conta('00000000-0000-0000-0000-000000000002', 'profissional',
                          (current_date - interval '18 years' + interval '1 day')::date) $$,
  '23514',
  null,
  'RN20: um dia a menos de 18 anos é recusado pelo banco, não pela tela');

-- ── RN25: uma conta, um perfil, para sempre ────────────────────────────────────
select pg_temp.conta('00000000-0000-0000-0000-000000000010', 'profissional');

select throws_ok(
  $$ update public.usuario set perfil = 'contratante'
      where id = '00000000-0000-0000-0000-000000000010' $$,
  '23514',
  null,
  'RN25: trocar o perfil da conta é recusado pelo trigger');

-- A chave estrangeira composta é a última linha de defesa: nem um bug de função
-- consegue dar perfil de profissional a uma conta de contratante.
select pg_temp.conta('00000000-0000-0000-0000-000000000011', 'contratante');

select throws_ok(
  $$ insert into public.profissional (usuario_id, ponto_base)
     values ('00000000-0000-0000-0000-000000000011',
             'POINT(-47.8822 -15.7942)'::extensions.geography) $$,
  '23503',
  null,
  'RN25: conta de contratante não ganha linha em profissional');

select throws_ok(
  $$ insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
     values ('Bar do Zé', '12345678000190', 'food_service', 'SCLN 000',
             'POINT(-47.88 -15.79)'::extensions.geography);
     insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
     select '00000000-0000-0000-0000-000000000010', id, 'administrador'
       from public.estabelecimento where documento = '12345678000190' $$,
  '23503',
  null,
  'RN25: conta de profissional não entra em estabelecimento');

-- ── Contato e e-mail ───────────────────────────────────────────────────────────
select throws_ok(
  $$ insert into public.usuario (id, perfil, nome, telefone, email, nascimento)
     values ('00000000-0000-0000-0000-000000000020', 'profissional', 'Fulano',
             '61999990000', 'a@b.test', '1990-01-01') $$,
  '23514',
  null,
  'telefone fora do formato E.164 é recusado');

select lives_ok(
  $$ insert into public.usuario (id, perfil, nome, telefone, email, nascimento)
     values ('00000000-0000-0000-0000-000000000021', 'contratante', 'Fulana',
             '+5561999990000', 'outra@b.test', '1990-01-01') $$,
  'RN25: o mesmo telefone pode estar nas duas contas da mesma pessoa');

select pg_temp.conta('00000000-0000-0000-0000-000000000030', 'profissional', '1990-01-01', 'igual@b.test');

select throws_ok(
  $$ select pg_temp.conta('00000000-0000-0000-0000-000000000031', 'profissional',
                          '1990-01-01', 'igual@b.test') $$,
  '23505',
  null,
  'e-mail é único entre contas ativas');

-- RF25 manda anonimizar em vez de apagar. Se a unicidade fosse total, o e-mail de uma
-- conta encerrada bloquearia para sempre quem quisesse voltar com o mesmo endereço.
update public.usuario
   set estado = 'anonimizada', anonimizado_em = now(),
       nome = 'Conta encerrada', telefone = null, email = null
 where id = '00000000-0000-0000-0000-000000000030';

select lives_ok(
  $$ select pg_temp.conta('00000000-0000-0000-0000-000000000032', 'profissional',
                          '1990-01-01', 'igual@b.test') $$,
  'RF25: o e-mail de uma conta anonimizada é reutilizável');

select throws_ok(
  $$ update public.usuario set estado = 'anonimizada'
      where id = '00000000-0000-0000-0000-000000000032' $$,
  '23514',
  null,
  'anonimizar sem carimbar a data é recusado');

-- ── Reputação ──────────────────────────────────────────────────────────────────
select pg_temp.conta('00000000-0000-0000-0000-000000000040', 'profissional');
insert into public.profissional (usuario_id, ponto_base)
values ('00000000-0000-0000-0000-000000000040', 'POINT(-47.88 -15.79)'::extensions.geography);

select is(
  (select taxa_comparecimento from public.profissional
    where usuario_id = '00000000-0000-0000-0000-000000000040'),
  null::numeric,
  'RF16: perfil novo tem taxa nula, não zero — "sem histórico" e "nunca apareceu" são coisas diferentes');

select throws_ok(
  $$ update public.profissional set aval_positivas = 3, aval_total = 2
      where usuario_id = '00000000-0000-0000-0000-000000000040' $$,
  '23514',
  null,
  'RN08: não há como haver mais avaliações positivas que o total');

select throws_ok(
  $$ update public.profissional set taxa_comparecimento = 1.5
      where usuario_id = '00000000-0000-0000-0000-000000000040' $$,
  '23514',
  null,
  'taxa de comparecimento fica entre 0 e 1');

select * from finish();
rollback;
