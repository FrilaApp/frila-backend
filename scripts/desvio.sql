-- A impressão digital do banco: uma linha por objeto que uma migração cria e que alguém
-- consegue mudar pelo painel. `scripts/desvio.sh` roda esta consulta no banco descartável
-- (migrações do repositório aplicadas do zero) e no projeto remoto, e compara as duas.
--
-- Fica de fora o que é dado e não estrutura (linhas de tabela, a semente, o
-- `frila.agendador_secret`) e o que o Supabase gerencia sozinho em cada projeto
-- (extensões, schemas `auth`, `storage`, `realtime`, `pgmq`, `vault`). Corpo de função e de
-- visão entra como md5: o texto inteiro não cabe numa linha legível, e a diferença que
-- importa é "mudou", que o md5 responde.
with esquemas(nome) as (
  values ('public'), ('privado'), ('metrica'), ('requisicao')
),
papeis(nome) as (
  values ('anon'), ('authenticated'), ('service_role')
),
linhas(linha) as (
  -- Tabelas, visões e o RLS de cada uma.
  select format('relacao %s.%s tipo=%s rls=%s forcado=%s',
                n.nspname, c.relname, c.relkind, c.relrowsecurity, c.relforcerowsecurity)
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in (select nome from esquemas)
     and c.relkind in ('r', 'p', 'v', 'm')

  union all
  -- Colunas.
  select format('coluna %s.%s.%s %s notnull=%s default=%s',
                n.nspname, c.relname, a.attname, format_type(a.atttypid, a.atttypmod),
                a.attnotnull, coalesce(pg_get_expr(d.adbin, d.adrelid), '-'))
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
   where n.nspname in (select nome from esquemas)
     and c.relkind in ('r', 'p', 'v', 'm')
     and a.attnum > 0 and not a.attisdropped

  union all
  -- Restrições: chave, unicidade, check, chave estrangeira.
  select format('restricao %s.%s %s %s',
                n.nspname, c.relname, co.conname, pg_get_constraintdef(co.oid))
    from pg_constraint co
    join pg_class c on c.oid = co.conrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in (select nome from esquemas)

  union all
  -- Índices.
  select format('indice %s', pg_get_indexdef(i.indexrelid))
    from pg_index i
    join pg_class c on c.oid = i.indrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in (select nome from esquemas)

  union all
  -- Funções: assinatura, retorno, corpo, segurança e search_path.
  select format('funcao %s.%s(%s) retorna=%s md5=%s definer=%s volatil=%s config=%s',
                n.nspname, p.proname, pg_get_function_identity_arguments(p.oid),
                pg_get_function_result(p.oid), md5(p.prosrc), p.prosecdef, p.provolatile,
                coalesce(array_to_string(p.proconfig, ','), '-'))
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in (select nome from esquemas)

  union all
  -- Quem pode chamar cada função. É a mudança de painel mais perigosa: um `grant` a
  -- `anon` abre a função para a internet.
  select format('execucao %s.%s(%s) %s=%s',
                n.nspname, p.proname, pg_get_function_identity_arguments(p.oid), r.nome,
                has_function_privilege(r.nome, p.oid, 'execute'))
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   cross join papeis r
   where n.nspname in (select nome from esquemas)

  union all
  -- Privilégios de tabela dos três papéis da API.
  select format('privilegio %s.%s %s %s',
                g.table_schema, g.table_name, g.grantee, g.privilege_type)
    from information_schema.role_table_grants g
   where g.table_schema in (select nome from esquemas)
     and g.grantee in (select nome from papeis)

  union all
  -- Políticas de RLS.
  select format('politica %s.%s %s cmd=%s permissiva=%s papeis=%s using=%s check=%s',
                pol.schemaname, pol.tablename, pol.policyname, pol.cmd, pol.permissive,
                array_to_string(pol.roles, ','),
                coalesce(md5(pol.qual), '-'), coalesce(md5(pol.with_check), '-'))
    from pg_policies pol
   where pol.schemaname in (select nome from esquemas)

  union all
  -- Gatilhos, inclusive os que moram em tabelas de outros schemas e chamam os nossos.
  select format('gatilho %s', pg_get_triggerdef(t.oid))
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_proc p on p.oid = t.tgfoid
    join pg_namespace pn on pn.oid = p.pronamespace
   where not t.tgisinternal
     and (n.nspname in (select nome from esquemas) or pn.nspname in (select nome from esquemas))

  union all
  -- Corpo das visões.
  select format('visao %s.%s md5=%s', n.nspname, c.relname, md5(pg_get_viewdef(c.oid)))
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in (select nome from esquemas)
     and c.relkind in ('v', 'm')
)
select linha from linhas
union all
-- Os jobs do pg_cron. Um job criado ou pausado pelo painel muda o produto sem migração.
-- A consulta é montada em texto porque `cron.job` só existe depois da migração que liga a
-- extensão; citada direto, ela derrubaria a comparação num banco que ainda não chegou lá.
-- Sem a extensão, a linha diz isso, e a diferença aparece no relatório como qualquer outra.
select coalesce(
         (xpath('/row/linha/text()', x))[1]::text,
         'cron sem a extensão pg_cron')
  from unnest(xpath('/table/row', query_to_xml(
         case when to_regclass('cron.job') is not null
              then $q$select format('cron %s agenda=%s ativo=%s comando=%s',
                                   jobname, schedule, active, command) as linha
                        from cron.job$q$
              else $q$select null::text as linha$q$
         end, true, false, ''))) as x
order by 1;
