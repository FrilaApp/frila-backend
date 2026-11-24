-- B-113d: o alerta 'moderacao_vencida' respeita o prazo de cada tipo de denúncia (regra do Cauê, 24/11/2026).
--
--   * denúncia com foto (midia_id) ou de motivo risco_seguranca, assedio, discriminacao: vence em 24 h;
--   * denúncia de motivo 'outro' SEM foto: vence depois de 5 dias úteis (privado.prazo_de_resposta);
--   * motivo que não é nenhum dos quatro valores do enum: falha fechada, 24 h;
--   * denúncia resolvida nunca dispara.
--
-- Cada caso roda SOZINHO (pg_temp.vence insere a denúncia, roda verificar_saude, lê o `valor` do alerta na fila
-- e desfaz tudo): um caso que passa por acaso, somado a outro, não esconde uma regra quebrada. O relógio é
-- congelado em frila.agora, com datas de 2026-11 (quarta 25, sexta 27, segunda 30) para provar o fim de semana.

begin;

select plan(24);

insert into privado.ambiente (id, eh_teste) values (true, true)
  on conflict (id) do update set eh_teste = true;

-- Fixture mínima: um autor, um estabelecimento (alvo) e uma foto de perfil para as denúncias com foto.
insert into auth.users (instance_id, id, aud, role, email)
values ('00000000-0000-0000-0000-000000000000', 'b1130000-0000-4000-8000-000000000001',
        'authenticated', 'authenticated', 'autor898@frila.test'),
       ('00000000-0000-0000-0000-000000000000', 'b1130000-0000-4000-8000-000000000002',
        'authenticated', 'authenticated', 'dono898@frila.test');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
values ('b1130000-0000-4000-8000-000000000001', 'profissional', 'Autor 898', '+5561977780001',
        'autor898@frila.test', '1995-01-01', 'ativa', '2026-09-22', now()),
       ('b1130000-0000-4000-8000-000000000002', 'contratante', 'Dono 898', '+5561977780002',
        'dono898@frila.test', '1990-01-01', 'ativa', '2026-09-22', now());

insert into public.estabelecimento (id, nome, documento, tipo, regiao_administrativa, endereco, ponto)
values ('b1130000-0000-4000-8000-0000000000e1', 'Estab 898', '12345678000898', 'food_service',
        'Plano Piloto', 'SCS Quadra 1', 'POINT(-47.88 -15.79)'::extensions.geography);

insert into privado.midia (id, dono_usuario_id, estabelecimento_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
values ('b1130000-0000-4000-8000-0000000000a1', 'b1130000-0000-4000-8000-000000000002', null,
        'profissional', 'foto_perfil', 'perfil/b1130000-0000-4000-8000-0000000000a1.jpg',
        'image/jpeg', 1000, 'aprovada');

-- Insere uma denúncia, roda o vigia e devolve quantas denúncias vencidas ele contou (0 = sem alerta).
-- ocorrencia é imutável (nem delete), então tudo roda num sub-bloco que termina em exceção própria: o Postgres
-- desfaz a denúncia, o alerta e a fila, e o caso seguinte começa com a tabela como estava.
create function pg_temp.vence(p_motivo text, p_foto boolean, p_criada timestamptz, p_resolvida boolean default false)
returns numeric
language plpgsql as $$
declare
  v_valor numeric;
begin
  begin
    delete from privado.alerta_emitido where codigo = 'moderacao_vencida';
    delete from pgmq.q_email where message ->> 'codigo' = 'moderacao_vencida';

    insert into public.ocorrencia (tipo, estabelecimento_id, autor_id, motivo, relato, midia_id, criada_em, resolvido_em)
    values ('denuncia', 'b1130000-0000-4000-8000-0000000000e1', 'b1130000-0000-4000-8000-000000000001',
            p_motivo, 'Relato sintético da denúncia 898',
            case when p_foto then 'b1130000-0000-4000-8000-0000000000a1'::uuid end,
            p_criada,
            case when p_resolvida then privado.agora() end);

    perform privado.verificar_saude();

    select (message ->> 'valor')::numeric into v_valor
      from pgmq.q_email
     where message ->> 'codigo' = 'moderacao_vencida'
     order by msg_id desc limit 1;

    raise exception 'desfazer o caso' using errcode = 'P0898';
  exception when sqlstate 'P0898' then
    null;
  end;
  return coalesce(v_valor, 0);
end $$;

-- ── Quarta 25/11/2026 15:00 (Brasília) ───────────────────────────────────────
set local frila.agora = '2026-11-25 18:00:00+00';

-- 24 h: foto e motivos graves
select is(pg_temp.vence('outro', true, '2026-11-24 13:00:00-03'), 1::numeric,
          'foto (motivo outro) criada há 26 h dispara');
select is(pg_temp.vence('outro', true, '2026-11-25 13:00:00-03'), 0::numeric,
          'foto criada há 2 h não dispara');
select is(pg_temp.vence('risco_seguranca', false, '2026-11-24 13:00:00-03'), 1::numeric,
          'risco_seguranca sem foto criada há 26 h dispara');
select is(pg_temp.vence('assedio', false, '2026-11-24 13:00:00-03'), 1::numeric,
          'assedio sem foto criada há 26 h dispara');
select is(pg_temp.vence('discriminacao', false, '2026-11-24 13:00:00-03'), 1::numeric,
          'discriminacao sem foto criada há 26 h dispara');
select is(pg_temp.vence('assedio', false, '2026-11-25 13:00:00-03'), 0::numeric,
          'motivo grave criado há 2 h não dispara');
select is(pg_temp.vence('assedio', false, '2026-11-24 15:00:00-03'), 0::numeric,
          'motivo grave com exatamente 24 h não dispara (o prazo é "mais de 24 h")');
select is(pg_temp.vence('assedio', false, '2026-11-24 14:59:00-03'), 1::numeric,
          'motivo grave com 24 h e 1 min dispara');

-- 'outro' sem foto: 5 dias úteis, não 24 h
select is(pg_temp.vence('outro', false, '2026-11-23 15:00:00-03'), 0::numeric,
          'outro sem foto criada há 2 dias NÃO dispara');
select is(pg_temp.vence('outro', false, '2026-11-24 13:00:00-03'), 0::numeric,
          'outro sem foto criada há 26 h NÃO dispara (a regra antiga disparava)');

-- falha fechada: motivo fora do enum conta como 24 h (ex.: o marcador da exclusão de conta)
select is(pg_temp.vence('[removido por exclusão de conta]', false, '2026-11-24 13:00:00-03'), 1::numeric,
          'motivo irreconhecível criado há 26 h dispara (falha fechada)');
select is(pg_temp.vence('[removido por exclusão de conta]', false, '2026-11-25 13:00:00-03'), 0::numeric,
          'motivo irreconhecível criado há 2 h não dispara');

-- resolvida nunca dispara
select is(pg_temp.vence('assedio', false, '2026-11-22 15:00:00-03', true), 0::numeric,
          'denúncia grave resolvida nunca dispara');
select is(pg_temp.vence('outro', true, '2026-11-22 15:00:00-03', true), 0::numeric,
          'denúncia com foto resolvida nunca dispara');

-- ── Sexta 27/11/2026 12:00: a denúncia de sexta 20/11 (7 dias corridos, 5 úteis) vence hoje, não antes ──
set local frila.agora = '2026-11-27 15:00:00+00';

select is(pg_temp.vence('outro', false, '2026-11-20 12:00:00-03'), 0::numeric,
          'outro sem foto de sexta 20/11 ainda não dispara na sexta 27/11 (último dia do prazo)');

-- ── Virada do dia em Brasília (UTC-3): o prazo da denúncia de sexta 20/11 é sexta 27/11 ─────────────────────
-- 02:59:59 UTC de 28/11 ainda é 27/11 em Brasília (último dia do prazo); 03:00:00 UTC já é 28/11 em Brasília.
-- Em UTC a data já seria 28/11 nos dois instantes: um mutante que compare com "hoje em UTC" dispara no primeiro.
set local frila.agora = '2026-11-28 02:59:59+00';

select is(pg_temp.vence('outro', false, '2026-11-20 12:00:00-03'), 0::numeric,
          'outro sem foto de sexta 20/11 NÃO dispara às 23:59:59 de 27/11 em Brasília (02:59:59 UTC de 28/11)');

set local frila.agora = '2026-11-28 03:00:00+00';

select is(pg_temp.vence('outro', false, '2026-11-20 12:00:00-03'), 1::numeric,
          'outro sem foto de sexta 20/11 dispara à 00:00:00 de 28/11 em Brasília (03:00:00 UTC)');

-- ── Segunda 30/11/2026 12:00: sábado e domingo não contam ─────────────────────
set local frila.agora = '2026-11-30 15:00:00+00';

select is(pg_temp.vence('outro', false, '2026-11-20 12:00:00-03'), 1::numeric,
          'outro sem foto de sexta 20/11 dispara na segunda 30/11 (passou do prazo de 5 dias úteis)');
select is(pg_temp.vence('outro', false, '2026-11-27 12:00:00-03'), 0::numeric,
          'outro sem foto de sexta 27/11 NÃO dispara na segunda 30/11 (sábado e domingo não contam)');
select is(pg_temp.vence('outro', false, '2026-11-20 12:00:00-03', true), 0::numeric,
          'outro sem foto vencido, mas resolvido, nunca dispara');

-- ── Contagem: o alerta traz só as vencidas ────────────────────────────────────
set local frila.agora = '2026-11-30 15:00:00+00';

delete from privado.alerta_emitido where codigo = 'moderacao_vencida';
delete from pgmq.q_email where message ->> 'codigo' = 'moderacao_vencida';

insert into public.ocorrencia (tipo, estabelecimento_id, autor_id, motivo, relato, midia_id, criada_em, resolvido_em)
select 'denuncia', 'b1130000-0000-4000-8000-0000000000e1', 'b1130000-0000-4000-8000-000000000001',
       v.motivo, 'Relato sintético da denúncia 898',
       case when v.foto then 'b1130000-0000-4000-8000-0000000000a1'::uuid end,
       v.criada, case when v.resolvida then privado.agora() end
  from (values
    ('outro',           true,  '2026-11-28 10:00:00-03'::timestamptz, false),  -- foto > 24 h: vencida
    ('risco_seguranca', false, '2026-11-28 10:00:00-03'::timestamptz, false),  -- grave > 24 h: vencida
    ('outro',           false, '2026-11-20 12:00:00-03'::timestamptz, false),  -- outro além de 5 dias úteis: vencida
    ('assedio',         false, '2026-11-30 11:00:00-03'::timestamptz, false),  -- grave < 24 h: não
    ('outro',           false, '2026-11-27 12:00:00-03'::timestamptz, false),  -- outro dentro do prazo: não
    ('discriminacao',   false, '2026-11-20 12:00:00-03'::timestamptz, true)    -- resolvida: não
  ) as v(motivo, foto, criada, resolvida);

select lives_ok($$ select privado.verificar_saude() $$,
                'verificar_saude roda com o conjunto de denúncias');

select is((select (message ->> 'valor')::numeric from pgmq.q_email
            where message ->> 'codigo' = 'moderacao_vencida' order by msg_id desc limit 1),
          3::numeric,
          'o alerta conta só as 3 denúncias vencidas das 6 abertas ou resolvidas');

-- ── A função continua security definer com search_path vazio ──────────────────
select is((select prosecdef from pg_proc where oid = 'privado.verificar_saude()'::regprocedure),
          true, 'privado.verificar_saude segue security definer');

select ok((select coalesce(proconfig, '{}') @> array['search_path=""']
             from pg_proc where oid = 'privado.verificar_saude()'::regprocedure),
          'privado.verificar_saude segue com search_path vazio');

select * from finish();
rollback;
