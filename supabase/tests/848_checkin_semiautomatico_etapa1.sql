-- 848_checkin_semiautomatico_etapa1.sql
--
-- Check-in semiautomático com código — Etapa 1 (Direção de João Paulo, 10/11/2026; migração 20261111210000).
-- Cobre:
--   1. Parâmetros configuráveis: raio_proximidade_m (50 m provisório), raio_validacao_m (50 m), validade_proximidade_s (900 s);
--   2. Preservação de legados: casa fora do piloto segue geolocalizado <= 200 m e verificado na hora;
--   3. Cliente legado em casa do piloto: sinais nil jamais auto-verificam (fica manual e pendente);
--   4. Fim da auto-verificação no fluxo novo: com checkin_por_codigo ligado, chegada <= 50 m fica manual e pendente;
--   5. Renovação de proximidade: toque inicial longe (120 m) pode ser atualizado por novo toque a 25 m,
--      preservando o instante inicial checkin_em e atualizando checkin_recebido_em e checkin_distancia_m;
--   6. Elegibilidade de proximidade para geração: chegada <= 50 m libera código (codigo_disponivel = true);
--      chegada > 50 m, sem posição ou sem chegada responde canonicamente 409 checkin_pendente (aguardandoChegada);
--   7. Frescor da aproximação pelo servidor: toque recebido há mais de 15 min expira elegibilidade (409 checkin_pendente);
--   8. Validação do código: código em vigor a <= 50 m confirma presença (tipo: codigo, verificado);
--      leitura acima de 50 m recusa com 422 codigo_invalido;
--      leitura SEM LOCALIZAÇÃO (null) com código correto JAMAIS confirma presença no novo fluxo (recusa com 422 codigo_invalido);
--   9. Bloqueio por tentativas erradas: erros gerados garantidamente sem colisão matemática com o código sorteado;
--      3 erros ativam bloqueio temporário (409 codigo_bloqueado: temporario);
--   10. Alternativa humana: confirmar_checkin_manual pela casa permanece 100% disponível para contingência.
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-01-11 21:30:00+00', true);
select plan(38);

-- Massa: Casa 844 (piloto) e Casa Legado 844 (sem a chave).
create temp table ids as
select 'c8440000-0000-4000-8000-000000000001'::uuid as dono_piloto,
       'c8440000-0000-4000-8000-000000000002'::uuid as dono_legado,
       'c8440000-0000-4000-8000-000000000021'::uuid as casa_piloto,
       'c8440000-0000-4000-8000-000000000022'::uuid as casa_legado;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select u, 'contratante'::public.perfil_conta, 'Casa 844 ' || n, '+556199999844' || n, 'casa844-' || n || '@test.invalid',
       '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids, lateral (values (dono_piloto, 1), (dono_legado, 2)) v (u, n);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select c, 'Bar 844 ' || n, '8000000000084' || n, 'food_service'::public.tipo_estabelecimento, 'Endereço 844',
       'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids, lateral (values (casa_piloto, 1), (casa_legado, 2)) v (c, n);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select u, c, 'administrador' from ids, lateral (values (dono_piloto, casa_piloto), (dono_legado, casa_legado)) v (u, c);

-- Turnos de teste
create temp table turnos (nome text primary key, turno uuid, usuario uuid, prof uuid);
create function pg_temp.novo_turno(nome text, casa uuid, inicio timestamptz default '2027-01-11 21:00:00+00') returns uuid
language plpgsql as $$
declare
  v_user uuid := gen_random_uuid(); v_prof uuid := gen_random_uuid();
  v_vaga uuid := gen_random_uuid(); v_pos  uuid := gen_random_uuid(); v_t uuid := gen_random_uuid();
begin
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_user, 'profissional', 'Prof 844 ' || nome, '+5561999998440', nome || '@t844.invalid',
          '1992-01-01', '1.0', '2026-09-20 12:00:00-03');
  insert into public.profissional (id, usuario_id, ponto_base) values (v_prof, v_user, 'POINT(-47.8800 -15.7700)');
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por)
  values (v_vaga, casa, (select id from public.funcao limit 1),
          inicio, inicio + interval '5 hours', 'Local 844', 'POINT(-47.8800 -15.7700)',
          15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada', inicio - interval '33 hours',
          gen_random_uuid(), 'c8440000-0000-4000-8000-000000000001');
  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_pos, v_vaga, 'confirmada', v_prof, inicio - interval '32 hours', inicio, inicio + interval '5 hours');
  insert into public.turno (id, posicao_id, valor_acordado_centavos) values (v_t, v_pos, 15000);
  insert into turnos values (nome, v_t, v_user, v_prof);
  return v_t;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', conta, 'role', 'authenticated')::text, true);
  execute sql into r;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return r;
end $$;

create function pg_temp.t(nome text) returns uuid language sql as $$ select turno from turnos where turnos.nome = t.nome $$;
create function pg_temp.u(nome text) returns uuid language sql as $$ select usuario from turnos where turnos.nome = u.nome $$;

create function pg_temp.checkin(nome text, distancia integer, em timestamptz default privado.agora(), sinais jsonb default null) returns jsonb language sql as $$
  select pg_temp.como(pg_temp.u(nome),
                      format('select public.fazer_checkin(%L::uuid, %s, %L::timestamptz, %L::jsonb)',
                             pg_temp.t(nome), coalesce(distancia::text, 'null'), em, sinais))
$$;

create function pg_temp.gerar(dono uuid, turno uuid) returns jsonb language sql as $$
  select pg_temp.como(dono, format('select public.gerar_codigo_checkin(%L::uuid)', turno))
$$;

create function pg_temp.recusa_gerar(dono uuid, turno uuid) returns text language plpgsql as $$
begin
  perform pg_temp.gerar(dono, turno);
  return 'ok';
exception when sqlstate 'PGRST' then
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return (sqlerrm::jsonb->>'code');
end $$;

create function pg_temp.validar(nome text, codigo text, distancia integer) returns jsonb language sql as $$
  select pg_temp.como(pg_temp.u(nome),
                      format('select public.validar_codigo_checkin(%L::uuid, %L, %s)',
                             pg_temp.t(nome), codigo, coalesce(distancia::text, 'null')))
$$;

create function pg_temp.confirmar_manual(dono uuid, turno uuid) returns jsonb language sql as $$
  select pg_temp.como(dono, format('select public.confirmar_checkin_manual(%L::uuid)', turno))
$$;

-- A chave checkin_por_codigo vale para todas as casas (20261112230000); nenhuma casa entra na lista por casa.
update privado.recurso set ligado = true where chave = 'checkin_por_codigo';

-- ── 1. Parâmetros configuráveis ───────────────────────────────────────────────

select is(raio_proximidade_m, 50, '1.1 regra: raio_proximidade_m configurado com 50 m provisório')
  from privado.regra_checkin_codigo;
select is(raio_validacao_m, 50, '1.2 regra: raio_validacao_m configurado com 50 m provisório')
  from privado.regra_checkin_codigo;
select is(validade_proximidade_s, 900, '1.3 regra: validade_proximidade_s configurado com 900 s (15 min)')
  from privado.regra_checkin_codigo;
select throws_ok($$update privado.regra_checkin_codigo set raio_proximidade_m = 19$$,
  '23514', null, '1.4 regra: raio_proximidade_entre_20_e_100: menos de 20 m é recusado');
select throws_ok($$update privado.regra_checkin_codigo set raio_proximidade_m = 101$$,
  '23514', null, '1.5 regra: raio_proximidade_entre_20_e_100: mais de 100 m é recusado');
select throws_ok($$update privado.regra_checkin_codigo set validade_proximidade_s = 59$$,
  '23514', null, '1.6 regra: validade_proximidade_entre_1_e_60_min: menos de 60 s é recusado');
select throws_ok($$update privado.regra_checkin_codigo set validade_proximidade_s = 3601$$,
  '23514', null, '1.7 regra: validade_proximidade_entre_1_e_60_min: mais de 3600 s é recusado');

-- ── 2. Fluxo Legado (chave desligada) ─────────────────────────────────────────
-- Desde 20261112230000 não há casa "fora do piloto": o fluxo legado só existe com a chave desligada (a volta).
update privado.recurso set ligado = false where chave = 'checkin_por_codigo';

select pg_temp.novo_turno('legado_200m', (select casa_legado from ids));
select is((pg_temp.checkin('legado_200m', 45))->>'tipo', 'geolocalizado',
          '2.1 legado: toque a 45 m com a chave desligada é geolocalizado');
select is((pg_temp.checkin('legado_200m', 45))->>'verificacao', 'verificado',
          '2.2 legado: presença verificada na hora (sem intervenção de código)');
select is((pg_temp.checkin('legado_200m', 45))->>'codigo_exigido', null,
          '2.3 legado: resposta não traz campos de código com a chave desligada');

-- A chave volta a ligar: vale para as duas casas, nenhuma está na lista por casa.
update privado.recurso set ligado = true where chave = 'checkin_por_codigo';
select pg_temp.novo_turno('casa_fora_da_lista', (select casa_legado from ids));
select is((pg_temp.checkin('casa_fora_da_lista', 45))->>'verificacao', 'pendente',
          '2.4 chave ligada: casa fora da lista por casa também fica manual e pendente (vale para todos)');

-- ── 3. Cliente legado em casa do piloto (sinais nil jamais auto-verificam) ────

select pg_temp.novo_turno('piloto_sinais_nil', (select casa_piloto from ids));
select is((pg_temp.checkin('piloto_sinais_nil', 30, privado.agora(), null))->>'tipo', 'manual',
          '3.1 sinais nil no piloto: toque a 30 m sem sinais vira manual (nunca auto-verifica)');
select is((pg_temp.checkin('piloto_sinais_nil', 30, privado.agora(), null))->>'verificacao', 'pendente',
          '3.2 sinais nil no piloto: presença permanece pendente');

-- ── 4. Fim da auto-verificação no fluxo com código ────────────────────────────

select pg_temp.novo_turno('piloto_chegada', (select casa_piloto from ids));
select is((pg_temp.checkin('piloto_chegada', 30))->>'tipo', 'manual',
          '4.1 novo fluxo: toque a 30 m vira manual (sem auto-verificação pelo GPS)');
select is((pg_temp.checkin('piloto_chegada', 30))->>'verificacao', 'pendente',
          '4.2 novo fluxo: presença permanece pendente aguardando código');
select is((pg_temp.checkin('piloto_chegada', 30))->>'distancia_m', '30',
          '4.3 novo fluxo: distancia_m é preservada para aferição de proximidade da casa');
select is((pg_temp.checkin('piloto_chegada', 30))->>'codigo_exigido', 'true',
          '4.4 novo fluxo: codigo_exigido é true');
select is((pg_temp.checkin('piloto_chegada', 30))->>'codigo_disponivel', 'true',
          '4.5 novo fluxo: codigo_disponivel é true quando dentro do raio elegível');

-- ── 5. Renovação de proximidade (toque longe seguido de toque perto) ──────────

select pg_temp.novo_turno('piloto_renova', (select casa_piloto from ids));
-- 1º toque a 120 m (fora do raio):
select is((pg_temp.checkin('piloto_renova', 120, '2027-01-11 21:10:00+00'))->>'codigo_disponivel', 'false',
          '5.1 renovação: 1º toque a 120 m resulta em codigo_disponivel = false');
select is(pg_temp.recusa_gerar((select dono_piloto from ids), pg_temp.t('piloto_renova')),
          'checkin_pendente',
          '5.2 renovação: casa recebe 409 checkin_pendente (aguardandoChegada)');
-- 2º toque a 25 m (aproximação da porta):
select is((pg_temp.checkin('piloto_renova', 25, '2027-01-11 21:15:00+00'))->>'codigo_disponivel', 'true',
          '5.3 renovação: 2º toque a 25 m atualiza proximidade e libera codigo_disponivel = true');
select is((select checkin_em from public.turno where id = pg_temp.t('piloto_renova')),
          '2027-01-11 21:10:00+00'::timestamptz,
          '5.4 renovação: checkin_em preserva o instante inicial de chegada para auditoria');
select is(pg_temp.recusa_gerar((select dono_piloto from ids), pg_temp.t('piloto_renova')),
          'ok',
          '5.5 renovação: casa agora consegue gerar código com sucesso após aproximação');

-- ── 6. Elegibilidade de proximidade e geração do código ───────────────────────

select is(pg_temp.recusa_gerar((select dono_piloto from ids), pg_temp.t('piloto_chegada')), 'ok',
          '6.1 geração: casa gera código com sucesso quando proximidade elegível <= 50 m');
select matches((pg_temp.gerar((select dono_piloto from ids), pg_temp.t('piloto_chegada')))->>'codigo',
               '^[0-9]{6}$', '6.2 geração: código gerado tem exatamente 6 dígitos');

-- Sem check-in registrado
select pg_temp.novo_turno('piloto_sem_toque', (select casa_piloto from ids));
select is(pg_temp.recusa_gerar((select dono_piloto from ids), pg_temp.t('piloto_sem_toque')),
          'checkin_pendente',
          '6.3 sem chegada: casa recebe 409 checkin_pendente (aguardandoChegada)');

-- ── 7. Frescor da aproximação pelo relógio do servidor ────────────────────────

select pg_temp.novo_turno('piloto_antigo', (select casa_piloto from ids));
select pg_temp.checkin('piloto_antigo', 25);
-- Simula passagem de 20 minutos no relógio do servidor (privado.agora())
select set_config('frila.agora', '2027-01-11 21:55:00+00', true);

select is((select privado.resposta_do_checkin(t.*, true)->>'codigo_disponivel'
             from public.turno t where t.id = pg_temp.t('piloto_antigo')),
          'false',
          '7.1 frescor: resposta_do_checkin marca codigo_disponivel = false após 25 min no servidor');
select is(pg_temp.recusa_gerar((select dono_piloto from ids), pg_temp.t('piloto_antigo')),
          'checkin_pendente',
          '7.2 frescor: casa recebe 409 checkin_pendente (aguardandoChegada) para toque antigo');

-- Restaura o relógio do servidor
select set_config('frila.agora', '2027-01-11 21:30:00+00', true);

-- ── 8. Validação do código: sem confirmação sem localização ───────────────────

create temp table codigo_piloto as
select (pg_temp.gerar((select dono_piloto from ids), pg_temp.t('piloto_chegada')))->>'codigo' as cod;

-- Tentativa de validar SEM LOCALIZAÇÃO (distancia_m nula) com código correto
select is((pg_temp.validar('piloto_chegada', (select cod from codigo_piloto), null))->>'code',
          'sem_localizacao',
          '8.1 validação sem posição: leitura com distancia_m nula é RECUSADA (422 sem_localizacao)');

-- Validação com distância excessiva (70 m > 50 m)
select is((pg_temp.validar('piloto_chegada', (select cod from codigo_piloto), 70))->>'code',
          'fora_do_raio',
          '8.2 validação longe: leitura a 70 m (> 50 m) é RECUSADA (422 fora_do_raio)');

-- Validação com sucesso a 30 m (<= 50 m)
select is((pg_temp.validar('piloto_chegada', (select cod from codigo_piloto), 30))->>'verificacao',
          'verificado',
          '8.3 validação perto: código lido a 30 m valida e confirma presença (verificado)');
select is((select checkin_tipo from public.turno where id = pg_temp.t('piloto_chegada')),
          'codigo',
          '8.4 validação: checkin_tipo vira codigo');
select is((select codigo from privado.checkin_codigo where turno_id = pg_temp.t('piloto_chegada')),
          null,
          '8.5 validação: código é consumido (null no banco após validação aceita)');

-- ── 9. Contador de tentativas e bloqueio (erros matematicamente distintos) ───

select pg_temp.novo_turno('piloto_erros', (select casa_piloto from ids));
select pg_temp.checkin('piloto_erros', 20);

create temp table codigos_teste as
select ((pg_temp.gerar((select dono_piloto from ids), pg_temp.t('piloto_erros')))->>'codigo') as cod_certo;

-- Gera código errado garantidamente diferente do sorteado:
create temp table codigos_errados as
select lpad((((cod_certo::bigint + 1) % 1000000)::text), 6, '0') as cod_errado_1,
       lpad((((cod_certo::bigint + 2) % 1000000)::text), 6, '0') as cod_errado_2,
       lpad((((cod_certo::bigint + 3) % 1000000)::text), 6, '0') as cod_errado_3
  from codigos_teste;

-- 1º e 2º erros: codigo_invalido
select is((pg_temp.validar('piloto_erros', (select cod_errado_1 from codigos_errados), 20))->>'code',
          'codigo_invalido',
          '9.1 erros: 1º código errado responde 422 codigo_invalido');
select is((pg_temp.validar('piloto_erros', (select cod_errado_2 from codigos_errados), 20))->>'code',
          'codigo_invalido',
          '9.2 erros: 2º código errado responde 422 codigo_invalido');

-- 3º erro: ativa bloqueio temporário (409 codigo_bloqueado: temporario)
create temp table terceiro_erro as
select pg_temp.validar('piloto_erros', (select cod_errado_3 from codigos_errados), 20) as resp;

select is((select resp->>'code' from terceiro_erro), 'codigo_bloqueado',
          '9.3 bloqueio: 3º código errado bloqueia o caminho (code: codigo_bloqueado)');
select is((select resp->>'details' from terceiro_erro), 'temporario',
          '9.4 bloqueio: detalhe do 3º erro é temporario');

-- ── 10. Alternativa humana: confirmação manual preservada ─────────────────────

select pg_temp.novo_turno('piloto_contingencia', (select casa_piloto from ids));
select pg_temp.checkin('piloto_contingencia', 20);
select is((pg_temp.confirmar_manual((select dono_piloto from ids), pg_temp.t('piloto_contingencia')))->>'verificacao',
          'verificado',
          '10.1 alternativa: confirmar_checkin_manual confirma presença em contingência');

rollback;
