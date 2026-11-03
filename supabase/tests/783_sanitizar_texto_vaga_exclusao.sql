-- 783_sanitizar_texto_vaga_exclusao.sql
-- Cobertura pgTAP da sanitização de texto livre da vaga na exclusão de conta
-- (K-001, K-001f, K-001h, princípio da necessidade - LGPD art. 6º, III, eliminação - art. 18, IV,
--  execução de contrato - art. 7º, V, e exercício regular de direitos - art. 7º, VI, RF25).
--
-- Afere:
--   1. Vaga cancelada na exclusão de contratante solo (sem turno ativo):
--      - responsavel_local = '[removido por exclusão de conta]';
--      - traje = null;
--      - observacoes = null;
--      - local = '[removido por exclusão de conta]'.
--   2. Vaga com turno em andamento no momento da exclusão:
--      - estado passa a 'cancelada', mas texto livre é PRESERVADO até o término do turno (execução de contrato - LGPD art. 7º, V);
--   3. Rotina de retenção de 15 dias (privado.limpar_contas_anonimizadas):
--      - responsavel_local, traje e observacoes são sanitizados conjuntamente para vagas passadas/canceladas/turnos encerrados
--        mesmo em estabelecimento compartilhado (LGPD art. 6º, III e art. 18, IV);
--      - vaga futura publicada preserva texto operacional (LGPD art. 7º, V);
--      - turno sem checkout há mais de 7 dias é considerado abandonado e sanitizado; há até 7 dias é preservado;
--      - local é PRESERVADO nas vagas com turnos cumpridos/verificados para exercício regular de direitos e auditoria da contraparte (LGPD art. 7º, VI);
--      - local é redigido nas vagas sem turnos verificados.

begin;

set local timezone = 'UTC';
select plan(37);

insert into privado.ambiente (eh_teste) values (true);

-- Fixa o relógio
select set_config('frila.agora', '2026-10-31 12:00:00+00', true);

-- Cria usuários
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
values
  ('78300000-0000-4000-8000-000000000001', 'contratante', 'Contratante Solo 783', '+5561978300001', 'solo783@teste.frila', '1985-05-10', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('78300000-0000-4000-8000-000000000002', 'profissional', 'Profissional A 783', '+5561978300002', 'profa783@teste.frila', '1990-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('78300000-0000-4000-8000-000000000003', 'profissional', 'Profissional B 783', '+5561978300003', 'profb783@teste.frila', '1992-06-15', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00')
on conflict (id) do nothing;

insert into public.profissional (id, usuario_id, ponto_base)
values
  ('78300000-0000-4000-8000-000000000012', '78300000-0000-4000-8000-000000000002', extensions.st_setsrid(extensions.st_makepoint(-47.9, -15.8), 4326)::extensions.geography),
  ('78300000-0000-4000-8000-000000000013', '78300000-0000-4000-8000-000000000003', extensions.st_setsrid(extensions.st_makepoint(-47.9, -15.8), 4326)::extensions.geography)
on conflict (id) do nothing;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values (
  '78300000-0000-4000-8000-000000000020',
  'Restaurante Solo 783',
  '78312345000100',
  'food_service',
  'SCLS 405 Bloco C Loja 10',
  extensions.st_setsrid(extensions.st_makepoint(-47.9, -15.8), 4326)::extensions.geography
) on conflict (id) do nothing;

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('78300000-0000-4000-8000-000000000020', '78300000-0000-4000-8000-000000000001', 'administrador');

insert into public.funcao (id, nome, categoria)
values ('78300000-0000-4000-8000-000000000030', 'Cozinheiro 783', 'cozinha')
on conflict (id) do nothing;

-- Usuário extra para estabelecimento compartilhado (Item 2a)
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
values ('78300000-0000-4000-8000-000000000004', 'contratante', 'Sócio Ativo 783', '+5561978300004', 'socio783@teste.frila', '1988-02-20', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00')
on conflict (id) do nothing;

-- Estabelecimento compartilhado (Item 2a)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values (
  '78300000-0000-4000-8000-000000000021',
  'Bar Compartilhado 783',
  '78312345000200',
  'food_service',
  'CLN 201 Bloco A',
  extensions.st_setsrid(extensions.st_makepoint(-47.88, -15.78), 4326)::extensions.geography
) on conflict (id) do nothing;

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values
  ('78300000-0000-4000-8000-000000000021', '78300000-0000-4000-8000-000000000001', 'administrador'),
  ('78300000-0000-4000-8000-000000000021', '78300000-0000-4000-8000-000000000004', 'administrador');

-- Vaga em estabelecimento compartilhado (Item 2a)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, traje, observacoes, modo, estado, chave_cliente
) values (
  '78300000-0000-4000-8000-000000000054',
  '78300000-0000-4000-8000-000000000021',
  '78300000-0000-4000-8000-000000000030',
  '78300000-0000-4000-8000-000000000001',
  '2026-11-20 18:00:00+00',
  '2026-11-20 23:00:00+00',
  'Bar Compartilhado - Deck Norte',
  extensions.st_setsrid(extensions.st_makepoint(-47.88, -15.78), 4326)::extensions.geography,
  16000, 1, true, false, false,
  'Sócio que Saiu', 'Uniforme do Bar', 'Entrar pela recepção', 'urgencia', 'publicada', gen_random_uuid()
);

-- Vaga com turno verificado e checkout concluído ANTES da exclusão imediata (Item 3)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, traje, observacoes, modo, estado, chave_cliente
) values (
  '78300000-0000-4000-8000-000000000055',
  '78300000-0000-4000-8000-000000000020',
  '78300000-0000-4000-8000-000000000030',
  '78300000-0000-4000-8000-000000000001',
  '2026-10-30 18:00:00+00',
  '2026-10-30 23:00:00+00',
  'Endereço Verificado Antes da Exclusão',
  extensions.st_setsrid(extensions.st_makepoint(-47.9, -15.8), 4326)::extensions.geography,
  17000, 1, true, false, false,
  'Gerente Concluído', 'Roupa preta', 'Turno já verificado com checkout', 'urgencia', 'preenchida', gen_random_uuid()
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values (
  '78300000-0000-4000-8000-000000000065',
  '78300000-0000-4000-8000-000000000055',
  'confirmada',
  '78300000-0000-4000-8000-000000000012',
  '2026-10-29 18:00:00+00',
  '2026-10-30 18:00:00+00',
  '2026-10-30 23:00:00+00'
);

insert into public.turno (id, posicao_id, checkin_em, checkout_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values (
  '78300000-0000-4000-8000-000000000075',
  '78300000-0000-4000-8000-000000000065',
  '2026-10-30 18:05:00+00',
  '2026-10-30 23:05:00+00',
  'geolocalizado',
  30,
  'verificado',
  17000
);

-- Ocorrência em estado parcialmente limpo (Item 1)
insert into public.ocorrencia (id, autor_id, usuario_id, tipo, motivo, relato)
values (
  '78300000-0000-4000-8000-000000000081',
  '78300000-0000-4000-8000-000000000001',
  '78300000-0000-4000-8000-000000000002',
  'denuncia',
  '[removido por exclusão de conta]',
  'Relato confidencial que deve ser anulado aos 15 dias'
);

-- ── 1. Cenário 1: Vaga sem turno (publicada) ───────────────────────────────────

insert into public.vaga (
  id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, traje, observacoes, modo, estado, chave_cliente
) values (
  '78300000-0000-4000-8000-000000000051',
  '78300000-0000-4000-8000-000000000020',
  '78300000-0000-4000-8000-000000000030',
  '78300000-0000-4000-8000-000000000001',
  '2026-11-01 18:00:00+00',
  '2026-11-01 23:00:00+00',
  'Rua das Palmeiras 100, Cozinha Central',
  extensions.st_setsrid(extensions.st_makepoint(-47.9, -15.8), 4326)::extensions.geography,
  18000, 1, true, false, false,
  'Chef Mariana (61 98888-7777)', 'Dólmã branca e sapato antiderrapante',
  'Entrada pelos fundos, procurar por Mariana', 'urgencia', 'publicada', gen_random_uuid()
);

insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em)
values (
  '78300000-0000-4000-8000-000000000061',
  '78300000-0000-4000-8000-000000000051',
  'aberta',
  '2026-11-01 18:00:00+00',
  '2026-11-01 23:00:00+00'
);

-- ── 2. Cenário 2: Vaga com turno em andamento ─────────────────────────────────

insert into public.vaga (
  id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, traje, observacoes, modo, estado, chave_cliente
) values (
  '78300000-0000-4000-8000-000000000052',
  '78300000-0000-4000-8000-000000000020',
  '78300000-0000-4000-8000-000000000030',
  '78300000-0000-4000-8000-000000000001',
  '2026-10-31 10:00:00+00',
  '2026-10-31 16:00:00+00',
  'Cozinha Operacional - Loja 10',
  extensions.st_setsrid(extensions.st_makepoint(-47.9, -15.8), 4326)::extensions.geography,
  20000, 1, true, false, false,
  'Subchefe Pedro', 'Avental preto', 'Turno em andamento', 'urgencia', 'preenchida', gen_random_uuid()
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values (
  '78300000-0000-4000-8000-000000000062',
  '78300000-0000-4000-8000-000000000052',
  'confirmada',
  '78300000-0000-4000-8000-000000000012',
  '2026-10-30 18:00:00+00',
  '2026-10-31 10:00:00+00',
  '2026-10-31 16:00:00+00'
);

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values (
  '78300000-0000-4000-8000-000000000072',
  '78300000-0000-4000-8000-000000000062',
  '2026-10-31 10:02:00+00',
  'geolocalizado',
  50,
  'verificado',
  20000
);

-- Executa excluir_conta
select lives_ok(
  $$ select privado.excluir_conta('78300000-0000-4000-8000-000000000001') $$,
  'Excluir conta de contratante solo executa sem erro'
);

-- Asserções do Cenário 1 (vaga sem turno em andamento -> sanitizada imediatamente)
select is(
  (select estado from public.vaga where id = '78300000-0000-4000-8000-000000000051'),
  'cancelada'::public.estado_vaga,
  'Vaga publicada sem turno ativo passa para estado cancelada'
);

select is(
  (select responsavel_local from public.vaga where id = '78300000-0000-4000-8000-000000000051'),
  '[removido por exclusão de conta]',
  'responsavel_local da vaga cancelada sem turno ativo é redigido para marcador neutro'
);

select is(
  (select traje from public.vaga where id = '78300000-0000-4000-8000-000000000051'),
  null,
  'traje da vaga cancelada sem turno ativo é anulado'
);

select is(
  (select observacoes from public.vaga where id = '78300000-0000-4000-8000-000000000051'),
  null,
  'observacoes da vaga cancelada sem turno ativo é anulado'
);

select is(
  (select local from public.vaga where id = '78300000-0000-4000-8000-000000000051'),
  '[removido por exclusão de conta]',
  'local da vaga cancelada sem turno ativo é redigido para marcador neutro'
);

-- Asserções do Cenário 2 (vaga com turno em andamento -> texto preservado para auditoria/suporte)
select is(
  (select estado from public.vaga where id = '78300000-0000-4000-8000-000000000052'),
  'cancelada'::public.estado_vaga,
  'Vaga com turno em andamento passa para cancelada'
);

select is(
  (select responsavel_local from public.vaga where id = '78300000-0000-4000-8000-000000000052'),
  'Subchefe Pedro',
  'responsavel_local da vaga com turno em andamento é temporariamente preservado'
);

select is(
  (select local from public.vaga where id = '78300000-0000-4000-8000-000000000052'),
  'Cozinha Operacional - Loja 10',
  'local da vaga com turno em andamento é preservado'
);

-- Asserção do Item 3 (vaga com turno verificado e checkout feito antes de excluir -> local preservado)
select is(
  (select local from public.vaga where id = '78300000-0000-4000-8000-000000000055'),
  'Endereço Verificado Antes da Exclusão',
  'local de turno verificado com checkout concluído é PRESERVADO na exclusão imediata (Item 3)'
);

-- ── 3. Cenário 3: Retenção de 15 dias (limpar_contas_anonimizadas) ─────────────

-- Conclui o turno do cenário 2
update public.turno
   set checkout_em = '2026-10-31 16:01:00+00',
       checkout_distancia_m = 30
 where id = '78300000-0000-4000-8000-000000000072';

-- Cria uma terceira vaga encerrada no passado que teve turno verificado
insert into public.vaga (
  id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, traje, observacoes, modo, estado, chave_cliente
) values (
  '78300000-0000-4000-8000-000000000053',
  '78300000-0000-4000-8000-000000000020',
  '78300000-0000-4000-8000-000000000030',
  '78300000-0000-4000-8000-000000000001',
  '2026-10-10 18:00:00+00',
  '2026-10-10 23:00:00+00',
  'Restaurante Loja 10 - Endereço Histórico',
  extensions.st_setsrid(extensions.st_makepoint(-47.9, -15.8), 4326)::extensions.geography,
  15000, 1, true, false, false,
  'Gerente Antigo', 'Roupa padrão', 'Observação antiga', 'urgencia', 'encerrada', gen_random_uuid()
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values (
  '78300000-0000-4000-8000-000000000063',
  '78300000-0000-4000-8000-000000000053',
  'cumprida',
  '78300000-0000-4000-8000-000000000013',
  '2026-10-09 18:00:00+00',
  '2026-10-10 18:00:00+00',
  '2026-10-10 23:00:00+00'
);

insert into public.turno (id, posicao_id, checkin_em, checkout_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values (
  '78300000-0000-4000-8000-000000000073',
  '78300000-0000-4000-8000-000000000063',
  '2026-10-10 18:05:00+00',
  '2026-10-10 23:02:00+00',
  'geolocalizado',
  20,
  'verificado',
  15000
);

-- Avança o relógio para 16 dias após a exclusão
select set_config('frila.agora', '2026-11-16 12:00:00+00', true);

-- Cria vaga e turno em andamento no dia da retenção aos 15 dias (Item 2b)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, traje, observacoes, modo, estado, chave_cliente
) values (
  '78300000-0000-4000-8000-000000000056',
  '78300000-0000-4000-8000-000000000021',
  '78300000-0000-4000-8000-000000000030',
  '78300000-0000-4000-8000-000000000001',
  '2026-11-16 10:00:00+00',
  '2026-11-16 18:00:00+00',
  'Bar Compartilhado - Bar Principal',
  extensions.st_setsrid(extensions.st_makepoint(-47.88, -15.78), 4326)::extensions.geography,
  19000, 1, true, false, false,
  'Gerente em Turno 783', 'Traje Bar Especial', 'Turno ativo na data da retenção', 'urgencia', 'publicada', gen_random_uuid()
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values (
  '78300000-0000-4000-8000-000000000066',
  '78300000-0000-4000-8000-000000000056',
  'confirmada',
  '78300000-0000-4000-8000-000000000013',
  '2026-11-15 18:00:00+00',
  '2026-11-16 10:00:00+00',
  '2026-11-16 18:00:00+00'
);

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values (
  '78300000-0000-4000-8000-000000000076',
  '78300000-0000-4000-8000-000000000066',
  '2026-11-16 10:01:00+00',
  'geolocalizado',
  25,
  'verificado',
  19000
);

-- Vaga 57: Vaga passada em estabelecimento compartilhado com PII do titular (caso do Lince / A1)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, traje, observacoes, modo, estado, chave_cliente
) values (
  '78300000-0000-4000-8000-000000000057',
  '78300000-0000-4000-8000-000000000021',
  '78300000-0000-4000-8000-000000000030',
  '78300000-0000-4000-8000-000000000001',
  '2026-10-20 18:00:00+00',
  '2026-10-20 23:00:00+00',
  'Bar Compartilhado - Salão Sul',
  extensions.st_setsrid(extensions.st_makepoint(-47.88, -15.78), 4326)::extensions.geography,
  15000, 1, true, false, false,
  'Titular Excluido (61 98888-0001)', 'Camisa do Titular', 'Falar com titular no tel 61 98888-0001', 'urgencia', 'encerrada', gen_random_uuid()
);

-- Vaga 58: Turno sem checkout com fim_em há 8 dias (abandonado/encerrado, A2)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, traje, observacoes, modo, estado, chave_cliente
) values (
  '78300000-0000-4000-8000-000000000058',
  '78300000-0000-4000-8000-000000000020',
  '78300000-0000-4000-8000-000000000030',
  '78300000-0000-4000-8000-000000000001',
  '2026-11-08 10:00:00+00',
  '2026-11-08 18:00:00+00',
  'Galpão 8 - Endereço Solo',
  extensions.st_setsrid(extensions.st_makepoint(-47.9, -15.8), 4326)::extensions.geography,
  16000, 1, true, false, false,
  'Encarregado 8 Dias', 'Bota e Colete', 'Instruções de 8 dias atrás', 'urgencia', 'preenchida', gen_random_uuid()
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values (
  '78300000-0000-4000-8000-000000000068',
  '78300000-0000-4000-8000-000000000058',
  'confirmada',
  '78300000-0000-4000-8000-000000000012',
  '2026-11-07 18:00:00+00',
  '2026-11-08 10:00:00+00',
  '2026-11-08 18:00:00+00'
);

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values (
  '78300000-0000-4000-8000-000000000078',
  '78300000-0000-4000-8000-000000000068',
  '2026-11-08 10:05:00+00',
  'geolocalizado',
  20,
  'verificado',
  16000
);

-- Vaga 59: Turno sem checkout com fim_em há 3 dias (em andamento dentro da janela de 7 dias, A2)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, traje, observacoes, modo, estado, chave_cliente
) values (
  '78300000-0000-4000-8000-000000000059',
  '78300000-0000-4000-8000-000000000020',
  '78300000-0000-4000-8000-000000000030',
  '78300000-0000-4000-8000-000000000001',
  '2026-11-13 10:00:00+00',
  '2026-11-13 18:00:00+00',
  'Galpão 3 - Endereço Solo',
  extensions.st_setsrid(extensions.st_makepoint(-47.9, -15.8), 4326)::extensions.geography,
  16000, 1, true, false, false,
  'Supervisor 3 Dias', 'Camisa Polo', 'Instruções recentes de 3 dias', 'urgencia', 'preenchida', gen_random_uuid()
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values (
  '78300000-0000-4000-8000-000000000069',
  '78300000-0000-4000-8000-000000000059',
  'confirmada',
  '78300000-0000-4000-8000-000000000013',
  '2026-11-12 18:00:00+00',
  '2026-11-13 10:00:00+00',
  '2026-11-13 18:00:00+00'
);

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values (
  '78300000-0000-4000-8000-000000000079',
  '78300000-0000-4000-8000-000000000069',
  '2026-11-13 10:05:00+00',
  'geolocalizado',
  20,
  'verificado',
  16000
);

-- Executa a retenção de 15 dias
select is(
  privado.limpar_contas_anonimizadas(15),
  1,
  'limpar_contas_anonimizadas(15) limpa a conta anonimizada de 16 dias'
);

-- Confere vaga 52 (turno já finalizado)
select is(
  (select responsavel_local from public.vaga where id = '78300000-0000-4000-8000-000000000052'),
  '[removido por exclusão de conta]',
  'responsavel_local da vaga 52 é redigido aos 15 dias pós-término'
);

select is(
  (select observacoes from public.vaga where id = '78300000-0000-4000-8000-000000000052'),
  null,
  'observacoes da vaga 52 é anulado aos 15 dias'
);

-- Confere vaga 53 (turno histórico cumprido/verificado)
select is(
  (select responsavel_local from public.vaga where id = '78300000-0000-4000-8000-000000000053'),
  '[removido por exclusão de conta]',
  'responsavel_local da vaga histórica cumprida é redigido aos 15 dias'
);

select is(
  (select observacoes from public.vaga where id = '78300000-0000-4000-8000-000000000053'),
  null,
  'observacoes da vaga histórica cumprida é anulado aos 15 dias'
);

select is(
  (select local from public.vaga where id = '78300000-0000-4000-8000-000000000053'),
  'Restaurante Loja 10 - Endereço Histórico',
  'local da vaga histórica cumprida é PRESERVADO para exercício regular de direitos e auditoria mútua (LGPD art. 7º, VI)'
);

-- Confere Item 1 (ocorrência parcialmente limpa tem relato anulado)
select is(
  (select relato from public.ocorrencia where id = '78300000-0000-4000-8000-000000000081'),
  null,
  'ocorrência parcialmente limpa tem relato anulado aos 15 dias (Item 1)'
);

-- Confere Vaga 54 (vaga futura e publicada em estabelecimento compartilhado: todos os textos preservados, LGPD art. 7º, V)
select is(
  (select local from public.vaga where id = '78300000-0000-4000-8000-000000000054'),
  'Bar Compartilhado - Deck Norte',
  'local de vaga futura publicada é PRESERVADO (LGPD art. 7º, V)'
);

select is(
  (select traje from public.vaga where id = '78300000-0000-4000-8000-000000000054'),
  'Uniforme do Bar',
  'traje de vaga futura publicada é PRESERVADO (LGPD art. 7º, V)'
);

select is(
  (select observacoes from public.vaga where id = '78300000-0000-4000-8000-000000000054'),
  'Entrar pela recepção',
  'observacoes de vaga futura publicada é PRESERVADO (LGPD art. 7º, V)'
);

select is(
  (select responsavel_local from public.vaga where id = '78300000-0000-4000-8000-000000000054'),
  'Sócio que Saiu',
  'responsavel_local de vaga futura publicada é PRESERVADO para operação (LGPD art. 7º, V)'
);

-- Confere Vaga 56 (turno em andamento no dia da retenção: textos preservados para apoio ao profissional, LGPD art. 7º, V)
select is(
  (select responsavel_local from public.vaga where id = '78300000-0000-4000-8000-000000000056'),
  'Gerente em Turno 783',
  'responsavel_local de turno em andamento aos 15 dias é PRESERVADO (LGPD art. 7º, V)'
);

select is(
  (select traje from public.vaga where id = '78300000-0000-4000-8000-000000000056'),
  'Traje Bar Especial',
  'traje de turno em andamento aos 15 dias é PRESERVADO (LGPD art. 7º, V)'
);

select is(
  (select observacoes from public.vaga where id = '78300000-0000-4000-8000-000000000056'),
  'Turno ativo na data da retenção',
  'observacoes de turno em andamento aos 15 dias é PRESERVADO (LGPD art. 7º, V)'
);

select is(
  (select local from public.vaga where id = '78300000-0000-4000-8000-000000000056'),
  'Bar Compartilhado - Bar Principal',
  'local de turno em andamento aos 15 dias é PRESERVADO (LGPD art. 7º, V)'
);

-- Confere Vaga 57 (vaga passada em compartilhado com PII do titular - caso do Lince / A1: sanitizada, LGPD art. 6º, III e art. 18, IV)
select is(
  (select responsavel_local from public.vaga where id = '78300000-0000-4000-8000-000000000057'),
  '[removido por exclusão de conta]',
  'responsavel_local em compartilhado passado é redigido mesmo com outro membro (LGPD art. 6º, III e art. 18, IV)'
);

select is(
  (select traje from public.vaga where id = '78300000-0000-4000-8000-000000000057'),
  null,
  'traje com PII do titular em compartilhado passado é anulado mesmo com outro membro (LGPD art. 6º, III e art. 18, IV)'
);

select is(
  (select observacoes from public.vaga where id = '78300000-0000-4000-8000-000000000057'),
  null,
  'observacoes com PII do titular em compartilhado passado é anulado mesmo com outro membro (LGPD art. 6º, III e art. 18, IV)'
);

select is(
  (select local from public.vaga where id = '78300000-0000-4000-8000-000000000057'),
  '[removido por exclusão de conta]',
  'local em compartilhado passado sem turno verificado é redigido mesmo com outro membro (LGPD art. 6º, III e art. 18, IV)'
);

-- Confere Vaga 58 (turno sem checkout com fim_em há 8 dias - abandonado/encerrado, A2: sanitizado)
select is(
  (select responsavel_local from public.vaga where id = '78300000-0000-4000-8000-000000000058'),
  '[removido por exclusão de conta]',
  'responsavel_local de turno sem checkout há 8 dias (abandonado) é redigido (LGPD art. 6º, III e art. 18, IV)'
);

select is(
  (select traje from public.vaga where id = '78300000-0000-4000-8000-000000000058'),
  null,
  'traje de turno sem checkout há 8 dias (abandonado) é anulado (LGPD art. 6º, III e art. 18, IV)'
);

select is(
  (select observacoes from public.vaga where id = '78300000-0000-4000-8000-000000000058'),
  null,
  'observacoes de turno sem checkout há 8 dias (abandonado) é anulado (LGPD art. 6º, III e art. 18, IV)'
);

select is(
  (select local from public.vaga where id = '78300000-0000-4000-8000-000000000058'),
  'Galpão 8 - Endereço Solo',
  'local de turno verificado mesmo sem checkout há 8 dias é PRESERVADO (LGPD art. 7º, VI)'
);

-- Confere Vaga 59 (turno sem checkout com fim_em há 3 dias - em andamento <= 7 dias, A2: preservado)
select is(
  (select responsavel_local from public.vaga where id = '78300000-0000-4000-8000-000000000059'),
  'Supervisor 3 Dias',
  'responsavel_local de turno sem checkout há 3 dias (em andamento) é PRESERVADO (LGPD art. 7º, V)'
);

select is(
  (select traje from public.vaga where id = '78300000-0000-4000-8000-000000000059'),
  'Camisa Polo',
  'traje de turno sem checkout há 3 dias (em andamento) é PRESERVADO (LGPD art. 7º, V)'
);

select is(
  (select observacoes from public.vaga where id = '78300000-0000-4000-8000-000000000059'),
  'Instruções recentes de 3 dias',
  'observacoes de turno sem checkout há 3 dias (em andamento) é PRESERVADO (LGPD art. 7º, V)'
);

select is(
  (select local from public.vaga where id = '78300000-0000-4000-8000-000000000059'),
  'Galpão 3 - Endereço Solo',
  'local de turno sem checkout há 3 dias (em andamento) é PRESERVADO (LGPD art. 7º, V)'
);

select * from finish();
rollback;
