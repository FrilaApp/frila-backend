-- 430_elegiveis_ordem_de_filtro.sql
-- privado.elegiveis parte do filtro mais seletivo, e não da grade semanal (RNF11, RNF03).
-- Cartão zptkprHt.
--
-- Por que este arquivo existe: a versão de 26/09 deixava o planejador escolher a ordem de
-- avaliação, e com o volume do Distrito Federal ele escolhia começar por
-- `public.disponibilidade`. Medido em 28/09, com a carga de `supabase/tests/carga/gerar_df.sql`:
-- 200 mil janelas varridas (`Seq Scan on disponibilidade`, 185.732 linhas descartadas) para
-- chegar a 14.286 candidatos que a função da vaga cortava para 894 — e
-- `privado.bloqueado_com_estabelecimento`, que é função e custa por linha, rodava 894 vezes.
-- Somadas 36 chamadas: 1.003 a 1.320 ms. Com a ordem fixada: 553 ms, p95 de 85,8 para 17,8 ms.
--
-- O plano com volume é assunto de `./scripts/planos-com-carga.sh`, e não deste arquivo:
-- plano depende de estatística, estatística depende de volume, e esta suíte roda sobre os
-- cenários. Medir plano aqui exigiria `enable_seqscan = off`, que foi justamente o que
-- deixou a regressão passar. O que se prova aqui é o que sobrevive sem volume: a forma da
-- consulta, e que nenhum dos seis filtros se perdeu na reescrita.

begin;
select plan(20);

-- Mesmo isolamento do 260_motor_despacho: a CI roda a suíte duas vezes, e a segunda é
-- depois dos scripts HTTP, que gravam de verdade. Contagem absoluta sem isolar quebra lá.
create temp table ids as select
  'd0000000-0000-4000-8000-000000000001'::uuid as vaga_ref,
  'e0000000-0000-4000-8000-000000000001'::uuid as ana,
  'e0000000-0000-4000-8000-000000000003'::uuid as carla,
  'e0000000-0000-4000-8000-000000000004'::uuid as diego,
  'e0000000-0000-4000-8000-000000000005'::uuid as elisa,
  'e0000000-0000-4000-8000-000000000006'::uuid as felipe,
  'e0000000-0000-4000-8000-000000000007'::uuid as gabi,
  'e0000000-0000-4000-8000-000000000009'::uuid as iara;

update public.usuario
   set estado = 'suspensa'
 where id not in (
   select usuario_id from public.profissional where id::text like 'e0000000-0000-4000-8000-%'
 )
 and id <> 'de000000-0000-4000-8000-000000000002';

-- ── 1. A forma: a ordem de avaliação é fixada, e parte do filtro mais seletivo ───
-- `as materialized` é o que impede o planejador de achatar a CTE e reordenar. Sem a
-- palavra, a regressão volta sem ninguém notar.

select ok(
  pg_get_functiondef('privado.elegiveis(uuid,uuid)'::regprocedure) ~* 'with\s+candidatos\s+as\s+materialized',
  'RNF11: privado.elegiveis fixa a ordem com uma CTE materializada'
);

select ok(
  substring(pg_get_functiondef('privado.elegiveis(uuid,uuid)'::regprocedure)
            from 'with\s+candidatos\s+as\s+materialized\s*\((.*?)\n\s*\)\s*select')
    ~* 'from\s+public\.profissional_funcao',
  'RNF11: a CTE parte de public.profissional_funcao, o filtro mais seletivo da vaga'
);

select ok(
  substring(pg_get_functiondef('privado.elegiveis(uuid,uuid)'::regprocedure)
            from 'with\s+candidatos\s+as\s+materialized\s*\((.*?)\n\s*\)\s*select')
    !~* 'public\.disponibilidade',
  'RNF11: a grade semanal é filtrada depois da CTE, não dentro dela'
);

select ok(
  substring(pg_get_functiondef('privado.elegiveis(uuid,uuid)'::regprocedure)
            from 'with\s+candidatos\s+as\s+materialized\s*\((.*?)\n\s*\)\s*select')
    !~* 'bloqueado_com_estabelecimento',
  'RNF11: bloqueado_com_estabelecimento roda depois da CTE, sobre o conjunto pequeno'
);

-- ── 2. Nenhum dos seis filtros se perdeu ────────────────────────────────────────
-- Cada asserção nomeia o profissional do cenário e a razão. Se a reescrita esquecesse um
-- filtro, exatamente uma destas fica vermelha, e o nome diz qual.

select is(
  (select count(*)::int from privado.elegiveis((select vaga_ref from ids))),
  5,
  'A reescrita devolve os mesmos 5 elegíveis que o 260_motor_despacho espera'
);

select ok(
  exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select ana from ids)),
  'Filtro 0 intacto: Ana, elegível por todos os critérios, continua na lista'
);

select ok(
  not exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select carla from ids)),
  'Filtro da grade intacto: Carla, fora do horário, não entra'
);

select ok(
  not exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select diego from ids)),
  'Filtro do raio intacto: Diego, a 16.9 km, não entra (RN05)'
);

select ok(
  not exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select elisa from ids)),
  'Filtro da conta ativa intacto: Elisa, suspensa, não entra'
);

select ok(
  not exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select felipe from ids)),
  'Filtro do bloqueio intacto: Felipe, bloqueado pelo bar, não entra (RF26)'
);

select ok(
  not exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select gabi from ids)),
  'Filtro do turno sobreposto intacto: Gabi não entra (RN21)'
);

select ok(
  exists (select 1 from privado.elegiveis((select vaga_ref from ids)) where profissional_id = (select iara from ids)),
  'Isenção de raio intacta: Iara, a 17.4 km, entra pela equipe de confiança (RF18)'
);

-- ── 3. A janela que atravessa a meia-noite, que é o caso delicado da reescrita ───
-- Mover a grade para fora da CTE muda onde as três alternativas de janela são avaliadas.
-- Vaga de sábado 00:30–02:00 coberta pela grade de sexta 18:00–02:00.
do $$
declare v_ini timestamptz; v_fim timestamptz; v_vg uuid := 'd0000000-0000-4000-8000-000000000001';
begin
  select inicio_em + interval '6 hours 30 minutes' into v_ini from public.vaga where id = v_vg;
  v_fim := v_ini + interval '1 hour 30 minutes';
  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, publicado_por, modo, estado, chave_cliente)
  values ('d0000000-0000-4000-8000-000000000330',
          'c0000000-0000-4000-8000-000000000001',
          (select id from public.funcao where nome = 'garçom'),
          v_ini, v_fim, 'CLN 208', 'POINT(-47.8869 -15.7620)'::extensions.geography,
          10000, 1, false, false, false, 'Gerente',
          (select publicado_por from public.vaga where id = v_vg), 'urgencia', 'publicada', gen_random_uuid());
end $$;

select ok(
  exists (select 1 from privado.elegiveis('d0000000-0000-4000-8000-000000000330')
           where profissional_id = (select ana from ids)),
  'A janela de sexta 18:00–02:00 continua cobrindo a vaga de sábado 00:30 depois da reescrita'
);

-- ── 4. A grade é filtro, e não enfeite ──────────────────────────────────────────
-- Apagada a grade de Ana, ela sai. Sem esta asserção, uma reescrita que esquecesse o
-- `exists` da disponibilidade passaria verde nas de cima.
savepoint sem_grade;
  delete from public.disponibilidade
   where profissional_id = (select ana from ids);
  select is(
    (select count(*)::int from privado.elegiveis((select vaga_ref from ids))),
    4,
    'Apagada a grade de Ana, ela sai da lista: a disponibilidade ainda filtra'
  );
rollback to savepoint sem_grade;

-- ── 5. Vaga que não existe e vaga não publicada não devolvem linha ──────────────
select is(
  (select count(*)::int from privado.elegiveis('00000000-0000-4000-8000-000000000000')),
  0,
  'Vaga inexistente devolve zero linhas, sem erro'
);

-- ── 6. O índice do filtro de presença na vaga (RN12) ────────────────────────────
-- Este índice nasceu porque o filtro de RN12 varria public.posicao inteira: 20.019 linhas
-- descartadas por vaga despachada, medido em 29/09 com a carga do DF. Ele é parcial e
-- minúsculo — 10 linhas indexadas de 20.019 naquela carga —, e é exatamente o tipo de
-- índice que a próxima consolidação vai achar redundante. Foi assim que o
-- disponibilidade_dia_horario sumiu. Esta asserção existe para que sumir dê vermelho.

select ok(
  exists (select 1 from pg_indexes
           where schemaname = 'public' and tablename = 'posicao'
             and indexname = 'posicao_presenca_na_vaga'),
  'RNF11: o índice posicao_presenca_na_vaga existe'
);

select ok(
  (select indexdef from pg_indexes
    where schemaname = 'public' and indexname = 'posicao_presenca_na_vaga')
    ~* 'vaga_id, *profissional_id.*WHERE.*falta',
  'RNF11: posicao_presenca_na_vaga é (vaga_id, profissional_id) e parcial em falta ou presença'
);

select ok(
  obj_description('public.posicao_presenca_na_vaga'::regclass, 'pg_class') is not null,
  'RNF11: posicao_presenca_na_vaga tem comment on dizendo para que serve'
);

-- ── 7. Volatilidade e privilégio, que o molde do repositório exige ──────────────
select is(
  (select p.provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'elegiveis'),
  's'::"char",
  'privado.elegiveis continua STABLE'
);

select ok(
  not has_function_privilege('authenticated', 'privado.elegiveis(uuid,uuid)', 'execute')
  and not has_function_privilege('anon', 'privado.elegiveis(uuid,uuid)', 'execute'),
  'RN06: privado.elegiveis continua fora do alcance de anon e authenticated'
);

select * from finish();
rollback;
