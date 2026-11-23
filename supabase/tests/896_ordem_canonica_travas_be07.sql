-- 896_ordem_canonica_travas_be07.sql · BE-07 (portão V1)
--
-- Regra executável de catálogo que guarda a ordem canônica de travas documentada em
-- docs/OrdemCanonicaDeTravas.md:
--   estabelecimento -> vaga (ORDER BY id) -> posicao | chamada (ORDER BY id) -> usuario
--
-- Este teste não substitui as provas multi-conexão em scripts/corrida-*.sh; ele atua como
-- portão rápido e permanente em toda execução de `supabase test db` na CI para impedir que
-- uma migração futura inverta silenciosamente a ordem de travas ou remova a pré-trava
-- ordenada por id antes de UPDATE multi-linha.
begin;
set local search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(8);

create temp table fontes as
select p.oid,
       p.pronamespace::regnamespace::text || '.' || p.proname as nome,
       regexp_replace(lower(p.prosrc), '\s+', ' ', 'g') as src
  from pg_proc p
 where (p.pronamespace = 'privado'::regnamespace and p.proname in (
          'excluir_conta',
          'expirar_chamadas',
          'lembrar_chamadas',
          'fechar_turnos_e_vagas',
          'limpar_contas_anonimizadas'))
    or (p.pronamespace = 'public'::regnamespace and p.proname in (
          'chamar_profissional',
          'publicar_a_partir_da_chamada',
          'cancelar_vaga'));

-- 1. privado.excluir_conta: vaga (ORDER BY id) -> chamada (ORDER BY id) -> usuario
select ok(
  (select strpos(src, 'order by g.id for update') > 0
      and strpos(src, 'order by c.id for update') > strpos(src, 'order by g.id for update')
      and strpos(src, 'from public.usuario u where u.id = v_uid for update') > strpos(src, 'order by c.id for update')
     from fontes where nome = 'privado.excluir_conta'),
  '1. privado.excluir_conta segue a ordem vaga (id) -> chamada (id) -> usuario'
);

-- 2. public.chamar_profissional: estabelecimento -> profissional -> vaga (quando vaga_id IS NOT NULL)
select ok(
  (select strpos(src, 'from public.estabelecimento e where e.id = v_estab for update') > 0
      and strpos(src, 'from public.profissional p where p.id = v_prof for update')
            > strpos(src, 'from public.estabelecimento e where e.id = v_estab for update')
      and strpos(src, 'from public.vaga g where g.id = v_vaga.id for update')
            > strpos(src, 'from public.profissional p where p.id = v_prof for update')
     from fontes where nome = 'public.chamar_profissional'),
  '2. public.chamar_profissional segue a ordem estabelecimento -> profissional -> vaga'
);

-- 3. public.publicar_a_partir_da_chamada: estabelecimento -> vaga (id) -> chamada (id) -> update chamada
select ok(
  (select strpos(src, 'from public.estabelecimento e where e.id = v_estab for update') > 0
      and strpos(src, 'order by g.id for update')
            > strpos(src, 'from public.estabelecimento e where e.id = v_estab for update')
      and strpos(src, 'order by c.id for update') > strpos(src, 'order by g.id for update')
      and strpos(src, 'update public.chamada set estado = ''encerrada''') > strpos(src, 'order by c.id for update')
     from fontes where nome = 'public.publicar_a_partir_da_chamada'),
  '3. public.publicar_a_partir_da_chamada segue estabelecimento -> vaga (id) -> chamada (id) -> update'
);

-- 4. privado.expirar_chamadas: vaga (id, FOR NO KEY UPDATE) -> chamada (id, FOR UPDATE OF c)
select ok(
  (select strpos(src, 'order by g.id for no key update') > 0
      and strpos(src, 'order by c.id for update of c') > strpos(src, 'order by g.id for no key update')
     from fontes where nome = 'privado.expirar_chamadas'),
  '4. privado.expirar_chamadas segue vaga (id) -> chamada (id)'
);

-- 5. privado.lembrar_chamadas: chamada ordenada por id (não por lembrete_em)
select ok(
  (select strpos(src, 'order by c.id for update of c') > 0
      and strpos(src, 'lembrete_em for update') = 0
     from fontes where nome = 'privado.lembrar_chamadas'),
  '5. privado.lembrar_chamadas trava chamadas em order by c.id'
);

-- 6. privado.fechar_turnos_e_vagas: pré-trava vaga (id) antes de update posicao e update vaga
select ok(
  (select strpos(src, 'order by v.id for no key update of v') > 0
      and strpos(src, 'order by v.id for no key update of v') < strpos(src, 'update public.posicao p set estado = ''cancelada''')
      and strpos(src, 'order by v.id for no key update of v') < strpos(src, 'update public.vaga v set estado = ''encerrada''')
     from fontes where nome = 'privado.fechar_turnos_e_vagas'),
  '6. privado.fechar_turnos_e_vagas pré-trava vagas por id antes de atualizar posições e vagas'
);

-- 7. privado.limpar_contas_anonimizadas: pré-trava vaga (id) antes de sanitizar public.vaga
select ok(
  (select strpos(src, 'order by g.id for no key update of g') > 0
      and strpos(src, 'order by g.id for no key update of g') < strpos(src, 'update public.vaga g set responsavel_local')
     from fontes where nome = 'privado.limpar_contas_anonimizadas'),
  '7. privado.limpar_contas_anonimizadas pré-trava vagas por id antes de atualizar public.vaga'
);

-- 8. public.cancelar_vaga: trava a vaga (FOR NO KEY UPDATE) antes de cancelar posições abertas
select ok(
  (select strpos(src, 'for no key update') > 0
      and strpos(src, 'for no key update') < strpos(src, 'update public.posicao')
     from fontes where nome = 'public.cancelar_vaga'),
  '8. public.cancelar_vaga trava a vaga (FOR NO KEY UPDATE) antes de atualizar posições abertas'
);

select * from finish();
rollback;
