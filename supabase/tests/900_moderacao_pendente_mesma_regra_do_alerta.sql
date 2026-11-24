-- B-113e: privado.moderacao_pendente (fila de plantão) usa a MESMA regra do alerta 'moderacao_vencida'
-- (privado.denuncia_prazo_ate, regra do Cauê de 24/11/2026), e os dois nunca divergem.
--
--   * foto (midia_id) ou motivo risco_seguranca, assedio, discriminacao: 24 h;
--   * motivo 'outro' SEM foto: 5 dias úteis, até o último microssegundo do dia de Brasília do prazo;
--   * motivo fora do enum: falha fechada, 24 h;
--   * denúncia resolvida não aparece na fila.
--
-- Os casos espelham o 898 (alerta). Cada um roda sozinho num sub-bloco que termina em exceção própria (ocorrencia
-- é imutável: nem delete). O teste de consistência põe um conjunto fixo de denúncias e compara, em vários instantes
-- (inclusive a virada do dia em Brasília), a contagem do alerta com a contagem de vencidas da fila.

begin;

select plan(32);

insert into privado.ambiente (id, eh_teste) values (true, true)
  on conflict (id) do update set eh_teste = true;

insert into auth.users (instance_id, id, aud, role, email)
values ('00000000-0000-0000-0000-000000000000', 'b1130000-0000-4000-8000-000000000e01',
        'authenticated', 'authenticated', 'autor900@frila.test'),
       ('00000000-0000-0000-0000-000000000000', 'b1130000-0000-4000-8000-000000000e02',
        'authenticated', 'authenticated', 'dono900@frila.test');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
values ('b1130000-0000-4000-8000-000000000e01', 'profissional', 'Autor 900', '+5561977790001',
        'autor900@frila.test', '1995-01-01', 'ativa', '2026-09-22', now()),
       ('b1130000-0000-4000-8000-000000000e02', 'contratante', 'Dono 900', '+5561977790002',
        'dono900@frila.test', '1990-01-01', 'ativa', '2026-09-22', now());

insert into public.estabelecimento (id, nome, documento, tipo, regiao_administrativa, endereco, ponto)
values ('b1130000-0000-4000-8000-000000000ee1', 'Estab 900', '12345678000900', 'food_service',
        'Plano Piloto', 'SCS Quadra 1', 'POINT(-47.88 -15.79)'::extensions.geography);

insert into privado.midia (id, dono_usuario_id, estabelecimento_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
values ('b1130000-0000-4000-8000-000000000ea1', 'b1130000-0000-4000-8000-000000000e02', null,
        'profissional', 'foto_perfil', 'perfil/b1130000-0000-4000-8000-000000000ea1.jpg',
        'image/jpeg', 1000, 'aprovada');

-- Insere uma denúncia e devolve o que a fila de plantão diz dela: 'vencida' | 'no prazo' | 'fora da fila'.
-- p_prazo é o argumento da fila (vale só para a classe de 24 h).
create function pg_temp.fila(p_motivo text, p_foto boolean, p_criada timestamptz, p_resolvida boolean default false,
                             p_prazo interval default interval '24 hours')
returns text
language plpgsql as $$
declare
  v_id  uuid := gen_random_uuid();
  v_res text;
begin
  begin
    insert into public.ocorrencia (id, tipo, estabelecimento_id, autor_id, motivo, relato, midia_id, criada_em, resolvido_em)
    values (v_id, 'denuncia', 'b1130000-0000-4000-8000-000000000ee1', 'b1130000-0000-4000-8000-000000000e01',
            p_motivo, 'Relato sintético da denúncia 900',
            case when p_foto then 'b1130000-0000-4000-8000-000000000ea1'::uuid end,
            p_criada,
            case when p_resolvida then privado.agora() end);

    select case when f.vencida then 'vencida' else 'no prazo' end into v_res
      from privado.moderacao_pendente(p_prazo) f
     where f.ocorrencia_id = v_id;

    raise exception 'desfazer o caso' using errcode = 'P0900';
  exception when sqlstate 'P0900' then
    null;
  end;
  return coalesce(v_res, 'fora da fila');
end $$;

-- O fim do prazo que a fila mostra (tratar_ate), para a mesma denúncia.
create function pg_temp.tratar_ate(p_motivo text, p_foto boolean, p_criada timestamptz,
                                   p_prazo interval default interval '24 hours')
returns timestamptz
language plpgsql as $$
declare
  v_id  uuid := gen_random_uuid();
  v_res timestamptz;
begin
  begin
    insert into public.ocorrencia (id, tipo, estabelecimento_id, autor_id, motivo, relato, midia_id, criada_em)
    values (v_id, 'denuncia', 'b1130000-0000-4000-8000-000000000ee1', 'b1130000-0000-4000-8000-000000000e01',
            p_motivo, 'Relato sintético da denúncia 900',
            case when p_foto then 'b1130000-0000-4000-8000-000000000ea1'::uuid end,
            p_criada);

    select f.tratar_ate into v_res from privado.moderacao_pendente(p_prazo) f where f.ocorrencia_id = v_id;

    raise exception 'desfazer o caso' using errcode = 'P0900';
  exception when sqlstate 'P0900' then
    null;
  end;
  return v_res;
end $$;

-- ── Quarta 25/11/2026 15:00 (Brasília) ───────────────────────────────────────
set local frila.agora = '2026-11-25 18:00:00+00';

select is(pg_temp.fila('outro', true, '2026-11-24 13:00:00-03'), 'vencida',
          'fila: foto (motivo outro) criada há 26 h está vencida');
select is(pg_temp.fila('outro', true, '2026-11-25 13:00:00-03'), 'no prazo',
          'fila: foto criada há 2 h está no prazo');
select is(pg_temp.fila('risco_seguranca', false, '2026-11-24 13:00:00-03'), 'vencida',
          'fila: risco_seguranca criada há 26 h está vencida');
select is(pg_temp.fila('assedio', false, '2026-11-24 13:00:00-03'), 'vencida',
          'fila: assedio criada há 26 h está vencida');
select is(pg_temp.fila('discriminacao', false, '2026-11-24 13:00:00-03'), 'vencida',
          'fila: discriminacao criada há 26 h está vencida');
select is(pg_temp.fila('assedio', false, '2026-11-25 13:00:00-03'), 'no prazo',
          'fila: motivo grave criado há 2 h está no prazo');
select is(pg_temp.fila('assedio', false, '2026-11-24 15:00:00-03'), 'no prazo',
          'fila: motivo grave com exatamente 24 h ainda está no prazo');
select is(pg_temp.fila('assedio', false, '2026-11-24 14:59:00-03'), 'vencida',
          'fila: motivo grave com 24 h e 1 min está vencida');

select is(pg_temp.fila('outro', false, '2026-11-23 15:00:00-03'), 'no prazo',
          'fila: outro sem foto criada há 2 dias NÃO está vencida');
select is(pg_temp.fila('outro', false, '2026-11-24 13:00:00-03'), 'no prazo',
          'fila: outro sem foto criada há 26 h NÃO está vencida (a regra antiga a vencia)');

select is(pg_temp.fila('[removido por exclusão de conta]', false, '2026-11-24 13:00:00-03'), 'vencida',
          'fila: motivo irreconhecível criado há 26 h está vencido (falha fechada)');
select is(pg_temp.fila('[removido por exclusão de conta]', false, '2026-11-25 13:00:00-03'), 'no prazo',
          'fila: motivo irreconhecível criado há 2 h está no prazo');

select is(pg_temp.fila('assedio', false, '2026-11-22 15:00:00-03', true), 'fora da fila',
          'fila: denúncia grave resolvida não aparece');
select is(pg_temp.fila('outro', false, '2026-11-01 15:00:00-03', true), 'fora da fila',
          'fila: denúncia outro resolvida não aparece');

-- p_prazo vale para a classe de 24 h e não encurta os 5 dias úteis do outro sem foto
select is(pg_temp.fila('assedio', false, '2026-11-25 01:00:00-03', false, interval '12 hours'), 'vencida',
          'fila(12 h): motivo grave com 14 h já está vencido para o plantão que pediu 12 h');
select is(pg_temp.fila('outro', false, '2026-11-25 01:00:00-03', false, interval '12 hours'), 'no prazo',
          'fila(12 h): outro sem foto não é encurtado pelo p_prazo');

-- tratar_ate: o fim de cada prazo
select is(pg_temp.tratar_ate('assedio', false, '2026-11-24 13:00:00-03'), '2026-11-25 13:00:00-03'::timestamptz,
          'tratar_ate de motivo grave = criada_em + 24 h');
select is(pg_temp.tratar_ate('outro', false, '2026-11-20 12:00:00-03'), '2026-11-27 23:59:59.999999-03'::timestamptz,
          'tratar_ate de outro sem foto = fim do dia de Brasília do prazo de 5 dias úteis (sex 20/11 → sex 27/11)');

-- ── Fim de semana e virada do dia em Brasília ─────────────────────────────────
set local frila.agora = '2026-11-28 02:59:59+00';
select is(pg_temp.fila('outro', false, '2026-11-20 12:00:00-03'), 'no prazo',
          'fila: outro sem foto de sex 20/11 ainda no prazo às 23:59:59 de 27/11 em Brasília');

set local frila.agora = '2026-11-28 03:00:00+00';
select is(pg_temp.fila('outro', false, '2026-11-20 12:00:00-03'), 'vencida',
          'fila: outro sem foto de sex 20/11 vencida à 00:00:00 de 28/11 em Brasília');

set local frila.agora = '2026-11-30 15:00:00+00';
select is(pg_temp.fila('outro', false, '2026-11-20 12:00:00-03'), 'vencida',
          'fila: outro sem foto de sex 20/11 vencida na segunda 30/11');
select is(pg_temp.fila('outro', false, '2026-11-27 12:00:00-03'), 'no prazo',
          'fila: outro sem foto de sex 27/11 NÃO vencida na segunda 30/11 (sábado e domingo não contam)');

-- ── Consistência: o alerta e a fila contam as mesmas vencidas ─────────────────
-- Conjunto fixo (criadas antes de todos os instantes abaixo). R6 está resolvida: nunca conta.
insert into public.ocorrencia (tipo, estabelecimento_id, autor_id, motivo, relato, midia_id, criada_em, resolvido_em)
select 'denuncia', 'b1130000-0000-4000-8000-000000000ee1', 'b1130000-0000-4000-8000-000000000e01',
       v.motivo, 'Relato sintético da denúncia 900',
       case when v.foto then 'b1130000-0000-4000-8000-000000000ea1'::uuid end,
       v.criada, case when v.resolvida then v.criada + interval '1 hour' end
  from (values
    ('outro',                          false, '2026-11-20 12:00:00-03'::timestamptz, false),  -- R1: prazo 27/11
    ('outro',                          false, '2026-11-27 12:00:00-03'::timestamptz, false),  -- R2: prazo 04/12
    ('assedio',                        false, '2026-11-27 12:00:00-03'::timestamptz, false),  -- R3: 24 h
    ('outro',                          true,  '2026-11-26 12:00:00-03'::timestamptz, false),  -- R4: foto, 24 h
    ('[removido por exclusão de conta]', false, '2026-11-26 12:00:00-03'::timestamptz, false), -- R5: falha fechada, 24 h
    ('risco_seguranca',                false, '2026-11-01 12:00:00-03'::timestamptz, true)    -- R6: resolvida
  ) as v(motivo, foto, criada, resolvida);

-- Devolve 'alerta=<n> fila=<n>' no instante dado: n do alerta moderacao_vencida (0 se não disparou) e n de vencidas na fila.
create function pg_temp.concordam(p_agora text) returns text
language plpgsql as $$
declare
  v_alerta numeric;
  v_fila   bigint;
begin
  perform set_config('frila.agora', p_agora, true);
  begin
    delete from privado.alerta_emitido where codigo = 'moderacao_vencida';
    delete from pgmq.q_email where message ->> 'codigo' = 'moderacao_vencida';

    perform privado.verificar_saude();

    select (message ->> 'valor')::numeric into v_alerta
      from pgmq.q_email
     where message ->> 'codigo' = 'moderacao_vencida'
     order by msg_id desc limit 1;

    select count(*) into v_fila from privado.moderacao_pendente() where vencida;

    raise exception 'desfazer' using errcode = 'P0900';
  exception when sqlstate 'P0900' then
    null;
  end;
  return format('alerta=%s fila=%s', coalesce(v_alerta, 0), v_fila);
end $$;

select is(pg_temp.concordam('2026-11-27 18:00:00+00'), 'alerta=2 fila=2',
          'consistência 27/11 15:00: R4 e R5 vencidas (R1 ainda no último dia do prazo)');
select is(pg_temp.concordam('2026-11-28 02:59:59+00'), 'alerta=2 fila=2',
          'consistência 23:59:59 de 27/11 em Brasília: igual ao anterior');
select is(pg_temp.concordam('2026-11-28 03:00:00+00'), 'alerta=3 fila=3',
          'consistência 00:00:00 de 28/11 em Brasília: R1 vence nos dois');
select is(pg_temp.concordam('2026-11-28 15:00:01+00'), 'alerta=4 fila=4',
          'consistência 28/11 12:00:01: R3 passa de 24 h nos dois');
select is(pg_temp.concordam('2026-12-05 02:59:59+00'), 'alerta=4 fila=4',
          'consistência 23:59:59 de 04/12 em Brasília: R2 ainda no último dia do prazo');
select is(pg_temp.concordam('2026-12-05 03:00:00+00'), 'alerta=5 fila=5',
          'consistência 00:00:00 de 05/12 em Brasília: R2 vence nos dois (a resolvida nunca conta)');

-- ── A função e a fila seguem como as vizinhas ─────────────────────────────────
select ok((select coalesce(proconfig, '{}') @> array['search_path=""']
             from pg_proc where oid = 'privado.denuncia_prazo_ate(text,uuid,timestamptz,interval)'::regprocedure),
          'privado.denuncia_prazo_ate tem search_path vazio');
select ok(not has_function_privilege('authenticated', 'privado.denuncia_prazo_ate(text,uuid,timestamptz,interval)', 'execute')
          and not has_function_privilege('anon', 'privado.denuncia_prazo_ate(text,uuid,timestamptz,interval)', 'execute')
          and has_function_privilege('service_role', 'privado.denuncia_prazo_ate(text,uuid,timestamptz,interval)', 'execute'),
          'privado.denuncia_prazo_ate: sem execute para anon e authenticated, com execute para service_role');
select ok((select prosecdef from pg_proc where oid = 'privado.moderacao_pendente(interval)'::regprocedure)
          and (select coalesce(proconfig, '{}') @> array['search_path=""']
                 from pg_proc where oid = 'privado.moderacao_pendente(interval)'::regprocedure),
          'privado.moderacao_pendente segue security definer com search_path vazio');
select is((select proargnames[2:6] from pg_proc where oid = 'privado.moderacao_pendente(interval)'::regprocedure),
          array['ocorrencia_id', 'criada_em', 'tratar_ate', 'vencida', 'motivo'],
          'privado.moderacao_pendente mantém as mesmas colunas de saída');

select * from finish();
rollback;
