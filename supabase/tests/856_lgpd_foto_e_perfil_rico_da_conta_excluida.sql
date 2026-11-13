-- 856_lgpd_foto_e_perfil_rico_da_conta_excluida.sql
--
-- A limpeza dos 15 dias da conta excluída leva também a foto (as mídias da pessoa) e o perfil rico
-- (migração 20261113210000; Bússola, condição para ligar a foto; LGPD art. 16 e 18, VI; B-019).
-- Cobre:
--   1. A função existe, só o service_role executa, e a rotina diária a chama (chave própria, sem falha);
--   2. Conta anonimizada há 16 dias: a foto aprovada e a em análise viram 'removida' e entram na fila
--      expurgo_midia com o original e a miniatura; a já expurgada sem pedido na fila sai da tabela;
--      regiões, serviços e atende_todo_df saem;
--   3. Não toca: a foto da casa (estabelecimento_id), nem a conta anonimizada há 10 dias, nem a ativa;
--   4. Idempotente; depois que a Edge Function confirma o expurgo e tira o pedido da fila, a linha sai.
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-02-10 12:00:00+00', true);
select plan(24);

select pgmq.purge_queue('expurgo_midia');

create temp table ids as
select 'c8560000-0000-4000-8000-000000000001'::uuid as u_prof,    -- profissional que exclui a conta
       'c8560000-0000-4000-8000-000000000002'::uuid as u_casa,    -- contratante que exclui a conta
       'c8560000-0000-4000-8000-000000000003'::uuid as u_recente, -- excluiu há 10 dias
       'c8560000-0000-4000-8000-000000000004'::uuid as u_ativa,   -- conta ativa
       'c8560000-0000-4000-8000-000000000011'::uuid as p_prof,
       'c8560000-0000-4000-8000-000000000013'::uuid as p_recente,
       'c8560000-0000-4000-8000-000000000014'::uuid as p_ativa,
       'c8560000-0000-4000-8000-000000000021'::uuid as casa,
       'c8560000-0000-4000-8000-0000000000a1'::uuid as m_aprovada,
       'c8560000-0000-4000-8000-0000000000a2'::uuid as m_analise,
       'c8560000-0000-4000-8000-0000000000a3'::uuid as m_expurgada,
       'c8560000-0000-4000-8000-0000000000a4'::uuid as m_casa,
       'c8560000-0000-4000-8000-0000000000a5'::uuid as m_recente,
       'c8560000-0000-4000-8000-0000000000a6'::uuid as m_ativa;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select u, pf::public.perfil_conta, 'Conta 856 ' || n, '+55619999985' || n || '0', 'c856-' || n || '@test.invalid',
       '1990-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids, lateral (values (u_prof, 'profissional', 1), (u_casa, 'contratante', 2),
                            (u_recente, 'profissional', 3), (u_ativa, 'profissional', 4)) v (u, pf, n);

insert into public.profissional (id, usuario_id, ponto_base, atende_todo_df)
select p, u, 'POINT(-47.8800 -15.7700)', true
  from ids, lateral (values (p_prof, u_prof), (p_recente, u_recente), (p_ativa, u_ativa)) v (p, u);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select casa, 'Bar 856', '80000000008561', 'food_service'::public.tipo_estabelecimento, 'Endereço 856',
       'POINT(-47.8800 -15.7700)'::extensions.geography from ids;
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select u_casa, casa, 'administrador' from ids;

-- Perfil rico dos três profissionais: região, serviço com preço e "atende todo o DF"
insert into public.profissional_regiao (profissional_id, regiao_id)
select p, (select r.id from public.regiao_administrativa r order by r.id limit 1)
  from ids, lateral (values (p_prof), (p_recente), (p_ativa)) v (p);
insert into public.profissional_funcao (profissional_id, funcao_id)
select p, (select f.id from public.funcao f order by f.id limit 1)
  from ids, lateral (values (p_prof), (p_recente), (p_ativa)) v (p);
insert into public.profissional_servico (profissional_id, funcao_id, unidade, valor_centavos)
select p, (select f.id from public.funcao f order by f.id limit 1), 'hora', 5000
  from ids, lateral (values (p_prof), (p_recente), (p_ativa)) v (p);

-- As mídias
insert into privado.midia (id, dono_usuario_id, estabelecimento_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
select m, u, e, dt, 'foto_perfil', 'perfil/' || m || '.jpg', 'image/jpeg', 1000, st
  from ids, lateral (values
    (m_aprovada,  u_prof,    null::uuid, 'profissional',    'aprovada'),
    (m_analise,   u_prof,    null::uuid, 'profissional',    'em_analise'),
    (m_expurgada, u_prof,    null::uuid, 'profissional',    'expurgada'),
    (m_casa,      u_casa,    casa,       'estabelecimento', 'aprovada'),
    (m_recente,   u_recente, null::uuid, 'profissional',    'aprovada'),
    (m_ativa,     u_ativa,   null::uuid, 'profissional',    'aprovada')) v (m, u, e, dt, st);

-- Exclusões: três contas; duas há 16 dias, uma há 10
select privado.excluir_conta(u_prof) from ids;
select privado.excluir_conta(u_casa) from ids;
select privado.excluir_conta(u_recente) from ids;
update public.usuario set anonimizado_em = privado.agora() - interval '16 days'
 where id in (select u_prof from ids union all select u_casa from ids);
update public.usuario set anonimizado_em = privado.agora() - interval '10 days'
 where id = (select u_recente from ids);

create function pg_temp.estado(m uuid) returns text language sql as $$
  select coalesce((select estado from privado.midia where id = m), 'apagada')
$$;
create function pg_temp.na_fila(m uuid) returns int language sql as $$
  select count(*)::int from pgmq.q_expurgo_midia q where q.message ->> 'verificacao_id' = m::text
$$;

-- ── 1. A função e a rotina ────────────────────────────────────────────────────

select is(has_function_privilege('authenticated', 'privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(integer)', 'execute'),
          false, 'authenticated não executa');
select is(has_function_privilege('service_role', 'privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(integer)', 'execute'),
          true, 'service_role executa');

create temp table r1 as select privado.executar_retencao_diaria() as r;
select is((select r -> 'falhas' from r1), '[]'::jsonb, 'a rotina diária roda sem falha');
select is((select r -> 'foto_e_perfil_rico_de_contas_excluidas' ->> 'midias_enfileiradas' from r1), '2',
          'a rotina diária chama a limpeza: 2 mídias da conta excluída na fila');
select is((select r -> 'foto_e_perfil_rico_de_contas_excluidas' ->> 'midias_apagadas' from r1), '1',
          'a já expurgada, sem pedido na fila, sai da tabela');

-- ── 2. A conta excluída há 16 dias ────────────────────────────────────────────

select is(pg_temp.estado((select m_aprovada from ids)), 'removida', 'a foto aprovada vira removida');
select is(pg_temp.estado((select m_analise from ids)), 'removida', 'a foto em análise vira removida');
select is(pg_temp.estado((select m_expurgada from ids)), 'apagada', 'a linha já expurgada some');
select is((select q.message from pgmq.q_expurgo_midia q, ids
            where q.message ->> 'verificacao_id' = ids.m_aprovada::text),
          (select jsonb_build_object('verificacao_id', m_aprovada::text, 'bucket', 'midia-perfil',
                    'caminhos', jsonb_build_array('perfil/' || m_aprovada || '.jpg', 'perfil/' || m_aprovada || '_thumb.jpg'),
                    'origem', 'foto_perfil') from ids),
          'o pedido de expurgo leva o original e a miniatura, no bucket midia-perfil');
select is((select privado.validar_expurgo_midia_perfil(m_aprovada, 'midia-perfil',
             jsonb_build_array('perfil/' || m_aprovada || '.jpg', 'perfil/' || m_aprovada || '_thumb.jpg')) from ids),
          true, 'a Edge Function aceita o pedido (validar_expurgo_midia_perfil)');
select is((select count(*)::int from public.profissional_regiao where profissional_id = (select p_prof from ids)), 0, 'regiões apagadas');
select is((select count(*)::int from public.profissional_servico where profissional_id = (select p_prof from ids)), 0, 'serviços apagados');
select is((select atende_todo_df from public.profissional where id = (select p_prof from ids)), false, 'atende_todo_df desligado');

-- ── 3. O que fica ─────────────────────────────────────────────────────────────

select is(pg_temp.estado((select m_casa from ids)), 'aprovada', 'a foto da casa é da casa: fica');
select is(pg_temp.estado((select m_recente from ids)), 'aprovada', 'conta excluída há 10 dias: a foto fica até os 15');
select is((select count(*)::int from public.profissional_regiao where profissional_id = (select p_recente from ids)), 1, 'conta de 10 dias: as regiões ficam');
select is(pg_temp.estado((select m_ativa from ids)), 'aprovada', 'conta ativa: a foto fica');
select is((select atende_todo_df from public.profissional where id = (select p_ativa from ids)), true, 'conta ativa: o perfil rico fica');
select is(pg_temp.na_fila((select m_casa from ids)) + pg_temp.na_fila((select m_recente from ids)) + pg_temp.na_fila((select m_ativa from ids)),
          0, 'nenhum pedido de expurgo para o que fica');

-- ── 4. Idempotência e o fim do ciclo ──────────────────────────────────────────

select is(privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(15) ->> 'midias_enfileiradas', '0', 'a 2ª rodada não enfileira de novo');
select is(pg_temp.estado((select m_aprovada from ids)), 'removida', 'com o pedido ainda na fila, a linha fica');

-- A Edge Function apaga os arquivos, confirma e tira o pedido da fila
select privado.confirmar_expurgo_midia_perfil(m) from ids, lateral (values (m_aprovada), (m_analise)) v (m);
select pgmq.delete('expurgo_midia', q.msg_id) from pgmq.q_expurgo_midia q;

select is(privado.limpar_foto_e_perfil_rico_de_contas_anonimizadas(15) ->> 'midias_apagadas', '2', 'depois do expurgo confirmado, as 2 linhas saem');
select is(pg_temp.estado((select m_aprovada from ids)) || ',' || pg_temp.estado((select m_analise from ids)), 'apagada,apagada', 'nenhuma linha da conta excluída fica');
select is(pg_temp.estado((select m_casa from ids)), 'aprovada', 'a foto da casa segue');

select * from finish();
rollback;
