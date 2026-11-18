-- 889_residuos_ordem_de_travas.sql
--
-- B-069 (#565): três updates de várias linhas sem ordem própria passam a travar antes as mesmas linhas
-- em ordem de id, a ordem dos jobs (privado.expirar_chamadas e privado.lembrar_chamadas, 20261117170000).
--
-- O ciclo só aparece com várias conexões: scripts/corrida-chamada.sh, cenários 25 a 27 (40P01 em 10 de
-- 10 rodadas da ordem forçada antes, nos três). Numa sessão só fica o catálogo, que falha com os corpos
-- anteriores (fechar_turnos_e_vagas da 20261015140000, publicar_a_partir_da_chamada da 20261117180000 e
-- limpar_contas_anonimizadas da 20261107350000, todos sem a pré-trava):
--   1-2. fechar_turnos_e_vagas trava por id as vagas que vai encerrar antes de cancelar as posições e de
--        encerrar as vagas, e segue SECURITY DEFINER, search_path vazio, só para service_role;
--   3-4. a conversão trava por id as chamadas abertas que encerra, depois da trava das vagas e antes do
--        update delas, e segue SECURITY DEFINER, search_path vazio, só para authenticated;
--   5-6. limpar_contas_anonimizadas trava por id as vagas que sanitiza antes do update do passo 6, e segue
--        SECURITY DEFINER, search_path vazio, só para service_role.
begin;
set local search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(6);

create temp table fonte as
select p.oid, regexp_replace(p.prosrc, '\s+', ' ', 'g') as src
  from pg_proc p
 where p.oid in ('privado.fechar_turnos_e_vagas()'::regprocedure,
                 'public.publicar_a_partir_da_chamada(uuid, uuid, text)'::regprocedure,
                 'privado.limpar_contas_anonimizadas(integer)'::regprocedure);

-- 1. O fechamento: a pré-trava das vagas vem antes do cancelamento das posições e do update das vagas.
select ok((select strpos(src, 'order by v.id for no key update of v') > 0
                  and strpos(src, 'order by v.id for no key update of v') < strpos(src, 'update public.posicao p set estado = ''cancelada''')
                  and strpos(src, 'order by v.id for no key update of v') < strpos(src, 'update public.vaga v set estado = ''encerrada''')
                  and strpos(src, 'where v.estado in (''publicada'', ''preenchida'') and v.fim_em <= v_agora and not exists ( select 1 from public.posicao p where p.vaga_id = v.id and (p.estado = ''confirmada'' or (p.estado = ''aberta'' and p.fim_em > v_agora))) order by v.id') > 0
             from fonte where oid = 'privado.fechar_turnos_e_vagas()'::regprocedure),
  'fechar_turnos_e_vagas trava por id as vagas que vai encerrar, antes das posições e do update');
select ok((select p.prosecdef and p.proconfig @> array['search_path=""']
                  and has_function_privilege('service_role', p.oid, 'execute')
                  and not has_function_privilege('authenticated', p.oid, 'execute')
                  and not has_function_privilege('anon', p.oid, 'execute')
             from pg_proc p where p.oid = 'privado.fechar_turnos_e_vagas()'::regprocedure),
  'fechar_turnos_e_vagas segue SECURITY DEFINER, search_path vazio, só para service_role');

-- 3. A conversão: vagas por id, depois as chamadas abertas por id, depois o update das chamadas.
select ok((select strpos(src, 'where c.vaga_id = any(array[v_orig.id] || v_irmas) and c.estado = ''aberta'' order by c.id for update') > 0
                  and strpos(src, 'order by g.id for update') < strpos(src, 'order by c.id for update')
                  and strpos(src, 'order by c.id for update') < strpos(src, 'update public.chamada set estado = ''encerrada''')
             from fonte where oid = 'public.publicar_a_partir_da_chamada(uuid, uuid, text)'::regprocedure),
  'a conversão trava por id as chamadas abertas da origem e das irmãs, depois das vagas e antes do update');
select ok((select p.prosecdef and p.proconfig @> array['search_path=""']
                  and has_function_privilege('authenticated', p.oid, 'execute')
                  and not has_function_privilege('anon', p.oid, 'execute')
             from pg_proc p where p.oid = 'public.publicar_a_partir_da_chamada(uuid, uuid, text)'::regprocedure),
  'publicar_a_partir_da_chamada segue SECURITY DEFINER, search_path vazio, só para authenticated');

-- 5. A limpeza: a pré-trava das vagas da conta, com o filtro do update, vem antes dele.
select ok((select strpos(src, 'from public.vaga g where g.publicado_por = v_candidato.id') > 0
                  and strpos(src, 'order by g.id for no key update of g') > strpos(src, 'from public.vaga g where g.publicado_por = v_candidato.id')
                  and strpos(src, 'order by g.id for no key update of g') < strpos(src, 'update public.vaga g set responsavel_local')
             from fonte where oid = 'privado.limpar_contas_anonimizadas(integer)'::regprocedure),
  'limpar_contas_anonimizadas trava por id as vagas que sanitiza, antes do update do passo 6');
select ok((select p.prosecdef and p.proconfig @> array['search_path=""']
                  and has_function_privilege('service_role', p.oid, 'execute')
                  and not has_function_privilege('authenticated', p.oid, 'execute')
                  and not has_function_privilege('anon', p.oid, 'execute')
             from pg_proc p where p.oid = 'privado.limpar_contas_anonimizadas(integer)'::regprocedure),
  'limpar_contas_anonimizadas segue SECURITY DEFINER, search_path vazio, só para service_role');

select * from finish();
rollback;
