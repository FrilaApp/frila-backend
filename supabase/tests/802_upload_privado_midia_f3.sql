-- RN37/CD-M01: bucket privado, upload, isolamento e ciclo de vida; somente dados sintéticos.
begin;
select no_plan();
create function pg_temp.erro(sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  execute sql; return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  return msg::jsonb || det::jsonb;
end $$;
create function pg_temp.como(papel text, sql text) returns bigint language plpgsql as $$
declare n bigint;
begin
  execute format('set local role %I', papel);
  execute sql into n; reset role; return n;
end $$;
insert into auth.users(id, email) values
 ('80200000-0000-4000-8000-000000000001', 'um@802.test'),
 ('80200000-0000-4000-8000-000000000002', 'dois@802.test');
insert into public.usuario(id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em)
select id, 'profissional', 'Pessoa sintética', email, '+556195550802' || row_number() over (),
 '1995-01-01', '1.0', now() from auth.users where email like '%@802.test';
select vault.create_secret('jwt-sintetico-802-sem-valor-real-32-caracteres', 'storage_jwt_secret');
select is((select public from storage.buckets where id = 'midia-perfil'), false, 'CD-M04: bucket privado');
select is(pg_temp.erro($$select public.minhas_midias()$$)->>'status', '401', 'sem sessão: 401');
set local request.jwt.claims = '{"sub":"80200000-0000-4000-8000-000000000001","role":"authenticated"}';
select is(pg_temp.erro($$select public.solicitar_upload_midia('foto_perfil','image/jpeg',1)$$)->>'details',
 'recurso_desligado', 'RN46: nasce desligado');
update privado.configuracao_app set foto_de_perfil = true;
-- Desde 0.2.65 o recurso só chega ao app com a versão e um mínimo para a plataforma (819).
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('foto_de_perfil', 'ios', '1.2.0');
select is(public.configuracao_do_app('ios', '1.2.0')#>>'{recursos,foto_de_perfil}', 'true', 'interruptor exposto ao app');
select is(pg_temp.erro($$select public.solicitar_upload_midia('foto_local','image/jpeg',1)$$)->>'details',
 'tipo_indisponivel', 'v1.1 só aceita foto de perfil');
select is(pg_temp.erro(format('select public.solicitar_upload_midia(''foto_perfil'',%L,1)', formato)),
 '{"status":422,"code":"midia_invalida","message":"midia_invalida","details":"formato","hint":null,"headers":{}}'::jsonb,
 'CD-M01 recusa ' || coalesce(formato, 'NULL')) from unnest(array['image/png','image/webp','image/gif',null]) formato;
select is(pg_temp.erro(format('select public.solicitar_upload_midia(''foto_perfil'',''image/jpeg'',%L)', tamanho))->>'details',
 'tamanho', 'CD-M01 recusa bytes ' || coalesce(tamanho::text,'NULL')) from unnest(array[-1,0,5242881,null]::bigint[]) tamanho;
create temp table upload as select public.solicitar_upload_midia('foto_perfil','image/jpeg',5242880) resposta;
select ok((resposta->>'upload_url') like '%/object/upload/sign/midia-perfil/perfil/%.jpg?token=%', 'URL de upload assinada') from upload;
select ok(position('80200000-0000-4000-8000-000000000001' in resposta->>'upload_url') = 0, 'URL sem id do dono') from upload;
select is((resposta->>'expira_em')::timestamptz, privado.agora() + interval '2 hours', 'URL válida por 2 horas') from upload;
select ok(not (resposta ? 'upload_url_miniatura'), 'cliente não envia miniatura') from upload;
set local request.jwt.claims = '{"sub":"80200000-0000-4000-8000-000000000002","role":"authenticated"}';
select is(public.minhas_midias(), '[]'::jsonb, 'outra conta não lista mídia enviando');
set local request.jwt.claims = '{"sub":"80200000-0000-4000-8000-000000000001","role":"authenticated"}';
select is(pg_temp.erro(format('select public.confirmar_upload_midia(%L)', resposta->>'midia_id'))->>'code',
 'evidencia_incompleta', 'sem objeto não confirma') from upload;
-- Cada CHECK tem violação comportamental: remover a restrição faz throws_ok falhar.
select throws_ok($$update privado.midia set dono_tipo = 'outro'$$, '23514', null, 'CHECK midia_dono_tipo');
select throws_ok($$update privado.midia set tipo = 'outro'$$, '23514', null, 'CHECK midia_tipo');
select throws_ok($$update privado.midia set storage_path = ' ' $$, '23514', null, 'CHECK midia_storage_path');
select throws_ok($$update privado.midia set mime = 'image/png'$$, '23514', null, 'CHECK midia_mime');
select throws_ok($$update privado.midia set bytes = 0$$, '23514', null, 'CHECK midia_bytes inferior');
select throws_ok($$update privado.midia set bytes = 5242881$$, '23514', null, 'CHECK midia_bytes superior');
select throws_ok($$update privado.midia set estado = 'outro'$$, '23514', null, 'CHECK midia_estado');
select throws_ok($$insert into privado.midia select (jsonb_populate_record(null::privado.midia,
 to_jsonb(m) || jsonb_build_object('id',gen_random_uuid()))).* from privado.midia m$$,
 '23505', null, 'caminho de objeto único');
insert into storage.objects(bucket_id, name) select 'midia-perfil', storage_path from privado.midia;
select is(pg_temp.como('anon', $$select count(*) from storage.objects where bucket_id='midia-perfil'$$),
 0::bigint, 'anônimo não lê bytes');
select is(pg_temp.como('authenticated', $$select count(*) from storage.objects where bucket_id='midia-perfil'$$),
 0::bigint, 'enviando: sem leitura direta de bytes');
select is(public.confirmar_upload_midia((resposta->>'midia_id')::uuid)->>'estado', 'em_analise', 'enfileira análise') from upload;
select is(public.confirmar_upload_midia((resposta->>'midia_id')::uuid)->>'estado', 'em_analise', 'confirmação idempotente') from upload;
select is((select count(*) from pgmq.q_moderacao_midia), 1::bigint, 'repetição não duplica análise');
select throws_ok($$insert into privado.midia select (jsonb_populate_record(null::privado.midia,
 to_jsonb(m) || jsonb_build_object('id',gen_random_uuid(),'storage_path','outro.jpg'))).* from privado.midia m$$,
 '23505', null, 'uma foto em análise por dono');
update privado.midia set estado = 'aprovada';
select throws_ok($$insert into privado.midia select (jsonb_populate_record(null::privado.midia,
 to_jsonb(m) || jsonb_build_object('id',gen_random_uuid(),'storage_path','outra.jpg'))).* from privado.midia m$$,
 '23505', null, 'uma foto aprovada por dono');
update privado.midia set estado = 'em_analise';
set local request.jwt.claims = '{"sub":"80200000-0000-4000-8000-000000000002","role":"authenticated"}';
select is(public.minhas_midias(), '[]'::jsonb, 'outra conta não lista mídia em análise');
select is(pg_temp.como('authenticated', $$select count(*) from storage.objects where bucket_id='midia-perfil'$$),
 0::bigint, 'outra conta não lê bytes em análise');
select is(pg_temp.erro(format('select public.%I(%L)', operacao, resposta->>'midia_id'))->>'code',
 'nao_encontrado', 'outra conta recebe 404 em ' || operacao) from upload cross join
 unnest(array['confirmar_upload_midia','remover_midia']) operacao;
select throws_ok($$select pg_temp.como('authenticated','select count(*) from privado.midia')$$,
 '42501', null, 'sem leitura direta da tabela privada');
set local request.jwt.claims = '{"sub":"80200000-0000-4000-8000-000000000001","role":"authenticated"}';
update privado.configuracao_app set foto_de_perfil = false;
select is(jsonb_array_length(public.minhas_midias()), 1, 'lista mesmo com recurso desligado');
select is(public.remover_midia((resposta->>'midia_id')::uuid)->>'estado', 'removida', 'remove mesmo desligado') from upload;
select is(public.remover_midia((resposta->>'midia_id')::uuid)->>'estado', 'removida', 'remoção idempotente') from upload;
select ok(not (public.minhas_midias()->0 ?| array['storage_path','motivo_codigo','dono_usuario_id']), 'API não vaza campos internos');
update privado.configuracao_app set foto_de_perfil = true;
select is(public.confirmar_upload_midia((resposta->>'midia_id')::uuid)->>'estado', 'removida', 'confirmar não reabre removida') from upload;
insert into auth.users(id,email) values
 ('80200000-0000-4000-8000-000000000003','casa@802.test'),
 ('80200000-0000-4000-8000-000000000004','membro@802.test');
insert into public.usuario(id,perfil,nome,email,telefone,nascimento,termos_versao,termos_aceite_em)
select id,'contratante','Casa sintética',email,'+556195550802' || (row_number() over () + 2),
 '1995-01-01','1.0',now() from auth.users where email in ('casa@802.test','membro@802.test');
insert into public.estabelecimento(id,nome,documento,tipo,endereco,ponto,regiao_administrativa)
values ('80200000-0000-4000-8000-000000000010','Casa sintética','80200000000010','outro','Endereço sintético',
 'POINT(-47.8822 -15.7942)'::extensions.geography,'Plano Piloto');
insert into public.membro_estabelecimento(usuario_id,estabelecimento_id,papel) values
 ('80200000-0000-4000-8000-000000000003','80200000-0000-4000-8000-000000000010','administrador'),
 ('80200000-0000-4000-8000-000000000004','80200000-0000-4000-8000-000000000010','operador');
select is(pg_temp.erro($$select public.solicitar_upload_midia('foto_perfil','image/jpeg',1,
 '80200000-0000-4000-8000-000000000010')$$)->>'status','403','profissional não envia pela casa');
set local request.jwt.claims = '{"sub":"80200000-0000-4000-8000-000000000003","role":"authenticated"}';
create temp table upload_casa as select public.solicitar_upload_midia('foto_perfil','image/jpeg',1,
 '80200000-0000-4000-8000-000000000010') resposta;
insert into storage.objects(bucket_id,name) select 'midia-perfil',storage_path from privado.midia
 where estabelecimento_id='80200000-0000-4000-8000-000000000010';
set local request.jwt.claims = '{"sub":"80200000-0000-4000-8000-000000000004","role":"authenticated"}';
select is(public.confirmar_upload_midia((resposta->>'midia_id')::uuid)->>'estabelecimento_id',
 '80200000-0000-4000-8000-000000000010','outro membro confirma pela mesma casa') from upload_casa;
select is(jsonb_array_length(public.minhas_midias()),1,'outro membro lista a foto da casa');
update public.usuario set estado='suspensa' where id='80200000-0000-4000-8000-000000000004';
select is(pg_temp.erro($$select public.minhas_midias()$$)->>'details','conta_suspensa','suspensa recebe 403');
reset request.jwt.claims;
select is(pg_temp.erro(sql)->>'status','401','sem sessão: ' || sql) from unnest(array[
 $$select public.solicitar_upload_midia('foto_perfil','image/jpeg',1)$$,
 $$select public.confirmar_upload_midia('80200000-0000-4000-8000-000000000099')$$,
 $$select public.remover_midia('80200000-0000-4000-8000-000000000099')$$]) sql;
select * from finish();
rollback;
