-- 914_midia_enviada_em.sql
--
-- Z8V10ATg: `privado.midia_em_json` devolve `enviada_em` (`Midia.enviada_em`, contrato 0.2.54) = `privado.midia.criado_em`. Antes nenhuma leitura de mídia o
-- trazia, e o iOS ordena as fotos do dono por esse campo. Só `enviada_em`: `decidida_em` fica para uma decisão (ver o corpo do PR).
--   A  minhas_midias: enviada_em = criado_em de cada foto (e não o atualizado_em, nem o relógio de agora), na ordem de criado_em
--   B  o instante do envio não muda quando o estado muda ou a nova análise é pedida
--   C  a foto da casa, para o membro; a de outra conta não aparece
--   D  as outras respostas de mídia e a exportação do titular trazem o mesmo; o resto do objeto não mudou
-- Ids próprios (`91400000`). Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
set local "frila.agora" = '2026-11-20 12:00:00+00';
update privado.configuracao_app set foto_de_perfil = true;
select plan(22);

create function pg_temp.sessao(conta uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    case when conta is null then '' else json_build_object('sub', conta, 'role', 'authenticated')::text end, true);
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

insert into auth.users (id, email) values
  ('91400000-0000-4000-8000-000000000001', 'um@914.test'),
  ('91400000-0000-4000-8000-000000000002', 'dois@914.test');
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em)
select id, 'profissional', 'Pessoa sintética', email, '+55619555091' || row_number() over (order by email), '1995-01-01', '1.0', now()
  from auth.users where email like '%@914.test';

-- A (recusada, enviada em 10/11, decidida há 1 h) · B (enviando, enviada em 15/11) · F (alheia, da conta 2).
insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado, motivo_recusa, motivo_codigo, criado_em, atualizado_em) values
  ('91400000-0000-4000-8000-0000000000a1', '91400000-0000-4000-8000-000000000001', 'profissional', 'foto_perfil', 'perfil/a1.jpg', 'image/jpeg', 1024,
   'recusada', 'texto_ou_dado_pessoal', 'interno_sintetico', '2026-11-10 09:00:00+00', '2026-11-20 11:00:00+00'),
  ('91400000-0000-4000-8000-0000000000b1', '91400000-0000-4000-8000-000000000001', 'profissional', 'foto_perfil', 'perfil/b1.jpg', 'image/jpeg', 1024,
   'enviando', null, null, '2026-11-15 10:00:00+00', '2026-11-15 10:00:00+00'),
  ('91400000-0000-4000-8000-0000000000f1', '91400000-0000-4000-8000-000000000002', 'profissional', 'foto_perfil', 'perfil/f1.jpg', 'image/jpeg', 1024,
   'enviando', null, null, '2026-11-05 08:00:00+00', '2026-11-05 08:00:00+00');
-- A foto da casa (Bar do Cerrado, c…01), da Zélia (b…01).
insert into privado.midia (id, dono_usuario_id, estabelecimento_id, dono_tipo, tipo, storage_path, mime, bytes, estado, criado_em, atualizado_em) values
  ('91400000-0000-4000-8000-0000000000c1', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'estabelecimento', 'foto_perfil',
   'perfil/c1.jpg', 'image/jpeg', 1024, 'enviando', '2026-11-12 14:00:00+00', '2026-11-12 14:00:00+00');

-- ── A. minhas_midias ──────────────────────────────────────────────────────────

select pg_temp.sessao('91400000-0000-4000-8000-000000000001');
create temp table lista as select public.minhas_midias() as j;
select is((select jsonb_array_length(j) from lista), 2, '0 a conta 1 lista as duas fotos dela (não passa vazio)');
select is((select array_agg(e->>'id' order by o) from lista, jsonb_array_elements(j) with ordinality t(e, o)),
  array['91400000-0000-4000-8000-0000000000a1', '91400000-0000-4000-8000-0000000000b1'], '0b na ordem do envio (A de 10/11, depois B de 15/11)');
select is((select (j->0)->'enviada_em' from lista), to_jsonb('2026-11-10 09:00:00+00'::timestamptz), 'A1 a foto A traz enviada_em = o criado_em dela');
select is((select (j->1)->'enviada_em' from lista), to_jsonb('2026-11-15 10:00:00+00'::timestamptz), 'A2 a foto B também');
select isnt((select (j->0)->'enviada_em' from lista), to_jsonb('2026-11-20 11:00:00+00'::timestamptz), 'A3 enviada_em não é o atualizado_em (a decisão)');
select isnt((select (j->0)->'enviada_em' from lista), to_jsonb('2026-11-20 12:00:00+00'::timestamptz), 'A4 nem o relógio de agora');
select ok((select (select count(*) from jsonb_array_elements(j) e where e ? 'enviada_em') = 2 from lista), 'A5 toda foto da lista traz a chave');
select is((select (j->0)->>'estado' from lista), 'recusada', 'A6 o resto do objeto é o de antes: estado');
select is((select (j->0)->>'motivo_recusa' from lista), 'texto_ou_dado_pessoal', 'A7 motivo_recusa');
select ok((select (j->0) @> '{"pode_pedir_nova_analise": true}'::jsonb and not ((j->0) ? 'url') from lista), 'A8 pode_pedir_nova_analise e sem url (não aprovada)');
select ok((select array(select jsonb_object_keys(j->0) order by 1) @> array['enviada_em', 'estabelecimento_id', 'estado', 'id', 'motivo_recusa', 'pode_pedir_nova_analise', 'tipo'] from lista),
  'A9 as chaves de antes mais enviada_em');

-- ── B. O instante do envio não muda ───────────────────────────────────────────

update privado.midia set estado = 'nao_publicada', atualizado_em = '2026-11-20 11:30:00+00' where id = '91400000-0000-4000-8000-0000000000b1';
select is((select e->'enviada_em' from jsonb_array_elements(public.minhas_midias()) e where e->>'id' = '91400000-0000-4000-8000-0000000000b1'),
  to_jsonb('2026-11-15 10:00:00+00'::timestamptz), 'B1 mudar o estado e o atualizado_em não muda a enviada_em');

create temp table nova_analise as select public.pedir_nova_analise_midia('91400000-0000-4000-8000-0000000000a1') as j;
select is((select j->>'estado' from nova_analise), 'em_analise', '0c o pedido de nova análise da foto A foi aceito');
select is((select j->'enviada_em' from nova_analise), to_jsonb('2026-11-10 09:00:00+00'::timestamptz), 'B2 o retorno do pedido de nova análise traz a enviada_em original');
select is((select e->'enviada_em' from jsonb_array_elements(public.minhas_midias()) e where e->>'id' = '91400000-0000-4000-8000-0000000000a1'),
  to_jsonb('2026-11-10 09:00:00+00'::timestamptz), 'B3 e a lista segue com ela depois do pedido');

-- ── C. Casa e isolamento ──────────────────────────────────────────────────────

select pg_temp.sessao('b0000000-0000-4000-8000-000000000001');
create temp table da_casa as select public.minhas_midias() as j;
select is((select e->'enviada_em' from da_casa, jsonb_array_elements(j) e where e->>'id' = '91400000-0000-4000-8000-0000000000c1'),
  to_jsonb('2026-11-12 14:00:00+00'::timestamptz), 'C1 o membro da casa vê a foto da casa com a enviada_em dela');
select pg_temp.sessao('91400000-0000-4000-8000-000000000001');
select is((select count(*)::int from jsonb_array_elements(public.minhas_midias()) e where e->>'id' in ('91400000-0000-4000-8000-0000000000f1', '91400000-0000-4000-8000-0000000000c1')),
  0, 'C2 a conta 1 não vê a foto da conta 2 nem a da casa');
select pg_temp.sessao(null);

-- ── D. Exportação do titular ──────────────────────────────────────────────────

select is((select e->'enviada_em' from jsonb_array_elements(privado.meus_dados('91400000-0000-4000-8000-000000000001') -> 'midias') e
            where e->>'id' = '91400000-0000-4000-8000-0000000000a1'),
  to_jsonb('2026-11-10 09:00:00+00'::timestamptz), 'D1 a exportação do titular traz enviada_em');
select is((select count(*)::int from jsonb_array_elements(privado.meus_dados('91400000-0000-4000-8000-000000000001') -> 'midias') e where not (e ? 'enviada_em')),
  0, 'D2 em toda mídia exportada');
select is(privado.midia_em_json((select m from privado.midia m where m.id = '91400000-0000-4000-8000-0000000000f1')) -> 'enviada_em',
  to_jsonb('2026-11-05 08:00:00+00'::timestamptz), 'D3 e direto na função, sem sessão');
select ok((select prosecdef and 'search_path=""' = any(proconfig) from pg_proc where oid = 'privado.midia_em_json(privado.midia)'::regprocedure),
  'D4 a função segue security definer com search_path vazio');
select ok(not has_function_privilege('authenticated', 'privado.midia_em_json(privado.midia)', 'execute'), 'D5 e fechada a authenticated');

select * from finish();
rollback;
