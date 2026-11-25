-- Regra 4 proposta: limites e transições, com dados inteiramente sintéticos.
begin;
insert into privado.ambiente(eh_teste) values(true) on conflict do nothing;
set local frila.agendador_secret='segredo-de-teste';
select set_config('frila.agora','2026-11-16 12:00:00Z',true);
select plan(27);
create temp table ids(chave text primary key,id uuid not null);
grant select on ids to authenticated;
do $$ declare u uuid:=gen_random_uuid();e uuid; begin
 insert into public.usuario(id,perfil,nome,telefone,email,nascimento,termos_versao,termos_aceite_em)
 values(u,'contratante','Casa Regra4','+5561999998680',u||'@test.invalid','1980-01-01','teste',privado.agora());
 insert into public.estabelecimento(nome,documento,tipo,endereco,regiao_administrativa,ponto)
 values('Casa Regra4','86886886000186','food_service','Local sintético','Plano Piloto','POINT(-47.88 -15.77)'::extensions.geography) returning id into e;
 insert into public.membro_estabelecimento(estabelecimento_id,usuario_id,papel) values(e,u,'administrador');
 insert into ids values('casa',e),('dona',u);
end $$;
create function pg_temp.como(conta uuid,consulta text) returns jsonb language plpgsql as $$
 declare r jsonb; begin
 execute 'set local role authenticated';
 perform set_config('request.jwt.claims',json_build_object('sub',conta,'role','authenticated')::text,true);
 execute consulta into r;
 reset role; perform set_config('request.jwt.claims','',true); return r;
end $$;
create function pg_temp.novo(delta interval,duracao interval) returns uuid language plpgsql as $$
 declare u uuid:=gen_random_uuid(); prof uuid; v uuid; p uuid; conf timestamptz:='2026-11-16 12:00:00Z'::timestamptz+delta; begin
 insert into public.usuario(id,perfil,nome,telefone,email,nascimento,termos_versao,termos_aceite_em)
 values(u,'profissional','Profissional sintético','+5561'||lpad((random()*999999999)::bigint::text,9,'0'),u||'@test.invalid','1990-01-01','teste',conf);
 insert into public.profissional(usuario_id,ponto_base) values(u,'POINT(-47.88 -15.77)'::extensions.geography) returning id into prof;
 insert into public.vaga(estabelecimento_id,funcao_id,inicio_em,fim_em,local,ponto,valor_centavos,posicoes,inclui_refeicao,inclui_transporte,exige_material_proprio,responsavel_local,modo,estado,chave_cliente,publicado_por)
 values((select id from ids where chave='casa'),(select id from public.funcao limit 1),'2026-11-16 12:00:00Z',conf+duracao,'Local sintético','POINT(-47.88 -15.77)'::extensions.geography,15000,1,false,false,false,'Responsável sintético','urgencia','preenchida',gen_random_uuid(),(select id from ids where chave='dona')) returning id into v;
 insert into public.posicao(vaga_id,profissional_id,inicio_em,fim_em,estado,confirmado_em)
 values(v,prof,'2026-11-16 12:00:00Z',conf+duracao,'confirmada',conf) returning id into p;
 insert into public.turno(posicao_id,valor_acordado_centavos) values(p,15000);
 return p;
end $$;
create function pg_temp.desistir(minutos int,delta interval default interval '30 minutes') returns boolean language plpgsql as $$
 declare p uuid;u uuid;conf timestamptz;r jsonb; begin
 p:=pg_temp.novo(delta,interval '4 hours');
 select privado.usuario_do_profissional(x.profissional_id),x.confirmado_em into u,conf from public.posicao x where x.id=p;
 perform set_config('frila.agora',(conf+minutos*interval '1 minute')::text,true);
 r:=pg_temp.como(u,format('select public.cancelar_posicao(%L::uuid,%L)',p,'Imprevisto sintético'));
 return (r->>'falta')::boolean;
end $$;
create function pg_temp.noshow(minutos int,delta interval default interval '30 minutes',atraso interval default interval '0') returns uuid language plpgsql as $$
 declare p uuid;fim timestamptz; begin
 p:=pg_temp.novo(delta,minutos*interval '1 minute');
 select fim_em into fim from public.posicao where id=p;
 perform set_config('frila.agora',(fim+atraso)::text,true);
 perform privado.fechar_turnos_passados();return p;
end $$;
select results_eq('select * from privado.parametros_aceite_tardio()', $$values(interval '15 minutes',interval '10 minutes',interval '45 minutes')$$,'parâmetros únicos15/10/45');
select is(privado.aceite_tardio('2026-11-16 12:00Z','2026-11-16 11:44Z'),false,'-16min mantém legado');
select is(privado.aceite_tardio('2026-11-16 12:00Z','2026-11-16 11:45Z'),true,'-15min é borda tardia incluída');
select is(privado.aceite_tardio('2026-11-16 12:00Z','2026-11-16 11:46Z'),true,'-14min é tardio');
select is(privado.aceite_tardio('2026-11-16 12:00Z',null),false,'confirmado nulo não inventa carência');
select is(pg_temp.desistir(9),false,'desistir aos9min sem falta');
select is(pg_temp.desistir(10),false,'desistir aos10min inclusive sem falta');
select is(pg_temp.desistir(11),true,'desistir aos11min conta falta');
select is(pg_temp.desistir(9,interval '-16 minutes'),true,'-16min não ganha carência');
select is(pg_temp.desistir(9,interval '-15 minutes'),false,'-15min ganha carência');
select is(pg_temp.desistir(9,interval '-14 minutes'),false,'-14min ganha carência');
insert into ids values('reabrir',pg_temp.novo(interval '30 minutes',interval '4 hours'));
select set_config('frila.agora','2026-11-16 12:44:00Z',true);
select throws_ok($$select pg_temp.como((select id from ids where chave='dona'),format('select public.reabrir_por_atraso(%L::uuid)',(select id from ids where chave='reabrir')))$$,'PGRST',null,'casa não reabre antes dos15min');
select set_config('frila.agora','2026-11-16 12:45:00Z',true);
create temp table abertura as select pg_temp.como((select id from ids where chave='dona'),format('select public.reabrir_por_atraso(%L::uuid)',(select id from ids where chave='reabrir'))) as r;
select is((select (r->>'falta')::boolean from abertura),false,'casa livre após15min encerra tardio sem falta');
select is(pg_temp.como((select id from ids where chave='dona'),format('select public.reabrir_por_atraso(%L::uuid)',(select id from ids where chave='reabrir'))),(select r from abertura),'reabertura idempotente conserva isenção e nova posição');
select is((select count(*)::int from public.ocorrencia where posicao_id=(select id from ids where chave='reabrir') and tipo='cancelamento'),1,'reenvio não duplica ocorrência');
insert into ids values('reabrir_legado',pg_temp.novo(interval '-16 minutes',interval '4 hours'));
select set_config('frila.agora','2026-11-16 12:15:00Z',true);
select is((pg_temp.como((select id from ids where chave='dona'),format('select public.reabrir_por_atraso(%L::uuid)',(select id from ids where chave='reabrir_legado')))->>'falta')::boolean,true,'reabertura de confirmado antes-15 mantém falta');
insert into ids values('noshow44',pg_temp.noshow(44));
select is((select falta from public.posicao where id=(select id from ids where chave='noshow44')),false,'fim aos44min não concede tempo hábil');
select is((select estado::text from public.posicao where id=(select id from ids where chave='noshow44')),'cancelada','sem tempo hábil encerra posição, não fica pendente');
create temp table n45 as select pg_temp.noshow(45) as id;
select is((select falta from public.posicao where id=(select id from n45)),true,'45min inclusive responsabiliza no-show');
create temp table n46 as select pg_temp.noshow(46) as id;
select is((select falta from public.posicao where id=(select id from n46)),true,'46min responsabiliza no-show');
create temp table n_atraso as select pg_temp.noshow(44,interval '30 minutes',interval '3 hours') as id;
select is((select falta from public.posicao where id=(select id from n_atraso)),false,'atraso do cron não cria tempo hábil');
create temp table n_legado as select pg_temp.noshow(44,interval '-16 minutes') as id;
select is((select falta from public.posicao where id=(select id from n_legado)),true,'no-show do legado antes-15 permanece falta');
create temp table n_borda as select pg_temp.noshow(44,interval '-15 minutes') as id;
select is((select falta from public.posicao where id=(select id from n_borda)),false,'no-show da borda-15 usa tempo hábil');
create temp table n_tardio as select pg_temp.noshow(44,interval '-14 minutes') as id;
select is((select falta from public.posicao where id=(select id from n_tardio)),false,'no-show a-14 usa tempo hábil');
select is((select verificacao::text from public.turno where posicao_id=(select id from ids where chave='noshow44')),'nao_verificado','encerramento sem falta não finge presença');
select is((select taxa_comparecimento from public.profissional where id=(select profissional_id from public.posicao where id=(select id from ids where chave='noshow44'))),null::numeric,'isenção não vira presença na taxa');
select ok(not has_function_privilege('authenticated','privado.parametros_aceite_tardio()','execute'),'parâmetros seguem privados');
select * from finish();rollback;
