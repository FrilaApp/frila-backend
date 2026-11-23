-- 805_foto_perfil_denuncia_e_expurgo.sql
--
-- B4b: Estreitamento da foto de perfil, remoção de colunas mortas,
-- ocultação por 2 denúncias distintas e expurgo em 24 h (RN37, CA4).
-- Atualizado com sanções dos achados do Lince Codex:
-- 1. midia_id opcional em public.denunciar; denúncia sem midia_id não afeta foto.
-- 2. Autores suspensos ou bloqueados não entram no limiar de 2 denúncias.
-- 3. Expurgo em 24 h cobre recusada e nao_publicada; ocultada é preservada.
-- 4. confirmar_expurgo_midia_perfil idempotente e falha fechada com false para aprovada.

begin;
select plan(38);

-- 1. Setup e ambiente de teste
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local "frila.agora" = '2026-11-20 12:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste';
select vault.create_secret('jwt-sintetico-805-sem-valor-real-32-caracteres', 'storage_jwt_secret');

create function pg_temp.erro(sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  execute sql; return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  return msg::jsonb || det::jsonb;
end $$;

-- 2. Fixtures
insert into auth.users (id, email) values
  ('80500000-0000-4000-8000-000000000001', 'prof@805.test'),
  ('80500000-0000-4000-8000-000000000002', 'contratante1@805.test'),
  ('80500000-0000-4000-8000-000000000003', 'contratante2@805.test'),
  ('80500000-0000-4000-8000-000000000004', 'bloqueado@805.test'),
  ('80500000-0000-4000-8000-000000000005', 'suspenso@805.test');

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em, estado) values
  ('80500000-0000-4000-8000-000000000001', 'profissional', 'Profissional Foto', 'prof@805.test', '+5561955508051', '1995-01-01', '1.0', now(), 'ativa'),
  ('80500000-0000-4000-8000-000000000002', 'contratante', 'Contratante Um', 'contratante1@805.test', '+5561955508052', '1990-01-01', '1.0', now(), 'ativa'),
  ('80500000-0000-4000-8000-000000000003', 'contratante', 'Contratante Dois', 'contratante2@805.test', '+5561955508053', '1992-01-01', '1.0', now(), 'ativa'),
  ('80500000-0000-4000-8000-000000000004', 'contratante', 'Contratante Bloqueado', 'bloqueado@805.test', '+5561955508054', '1988-01-01', '1.0', now(), 'ativa'),
  ('80500000-0000-4000-8000-000000000005', 'contratante', 'Contratante Suspenso', 'suspenso@805.test', '+5561955508055', '1985-01-01', '1.0', now(), 'suspensa');

insert into public.profissional (id, usuario_id, ponto_base) values
  ('80500000-0000-4000-8000-000000000010', '80500000-0000-4000-8000-000000000001', 'POINT(-47.8822 -15.7942)'::extensions.geography);

-- Bloqueio entre profissional e o contratante 4
insert into public.bloqueio (autor_id, bloqueado_id) values
  ('80500000-0000-4000-8000-000000000001', '80500000-0000-4000-8000-000000000004');

-- PARTE 1: Estreitamento de CHECK midia_tipo e colunas removidas
select throws_ok(
  $$insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
    values (gen_random_uuid(), '80500000-0000-4000-8000-000000000001', 'profissional', 'foto_trabalho', 'perfil/err1.jpg', 'image/jpeg', 100, 'enviando')$$,
  '23514', null, 'midia_tipo recusa foto_trabalho'
);

select throws_ok(
  $$insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
    values (gen_random_uuid(), '80500000-0000-4000-8000-000000000001', 'profissional', 'curriculo', 'perfil/err2.jpg', 'image/jpeg', 100, 'enviando')$$,
  '23514', null, 'midia_tipo recusa curriculo'
);

select throws_ok(
  $$select legenda from privado.midia limit 1$$,
  '42703', null, 'coluna legenda foi removida de privado.midia'
);

select throws_ok(
  $$select funcao_id from privado.midia limit 1$$,
  '42703', null, 'coluna funcao_id foi removida de privado.midia'
);

select throws_ok(
  $$select ordem from privado.midia limit 1$$,
  '42703', null, 'coluna ordem foi removida de privado.midia'
);

-- Inserção válida com foto_perfil
insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
values ('80500000-0000-4000-8000-000000000100', '80500000-0000-4000-8000-000000000001', 'profissional', 'foto_perfil', 'perfil/valida.jpg', 'image/jpeg', 1024, 'aprovada');

select is(
  (select tipo from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  'foto_perfil',
  'foto_perfil aceita com sucesso'
);

-- PARTE 2: Denúncia específica com midia_id (contrato 0.2.54, CD-M07 / CA4)
-- 2.1 Denúncia SEM midia_id é sobre o perfil e NÃO afeta a foto de perfil (achado 1 do Lince Codex)
set local request.jwt.claims = '{"sub":"80500000-0000-4000-8000-000000000002","role":"authenticated"}';
select is(
  (public.denunciar('profissional', '80500000-0000-4000-8000-000000000010', 'outro', 'relato de conduta geral sem apontar foto', gen_random_uuid()))->>'tipo',
  'denuncia',
  'denuncia sem midia_id registrada'
);

select is(
  (select denuncias_distintas from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  0::smallint,
  'denuncia de perfil nao incrementa denuncias_distintas da foto'
);

-- 2.2 Denúncia com midia_id inexistente ou alheio devolve 422 campo_invalido details: midia_id
select is(
  (pg_temp.erro($$select public.denunciar('profissional', '80500000-0000-4000-8000-000000000010', 'outro', 'relato com midia que nao existe', gen_random_uuid(), null, '80500000-0000-4000-8000-000000000999'::uuid)$$) ->> 'details'),
  'midia_id',
  'denuncia com midia inexistente devolve 422 campo_invalido midia_id'
);

-- 2.3 Denúncia 1 com midia_id correto da foto
select is(
  (public.denunciar('profissional', '80500000-0000-4000-8000-000000000010', 'outro', 'relato sobre a foto de perfil do profissional', gen_random_uuid(), null, '80500000-0000-4000-8000-000000000100'::uuid))->>'tipo',
  'denuncia',
  'denuncia 1 da foto registrada'
);

select is(
  (select denuncias_distintas from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  1::smallint,
  'primeira denuncia da foto incrementa denuncias_distintas para 1'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  'aprovada',
  'foto continua aprovada com 1 denuncia'
);

-- 2.4 Denúncia repetida pela mesma conta: não incrementa
select is(
  (public.denunciar('profissional', '80500000-0000-4000-8000-000000000010', 'outro', 'segundo relato da mesma conta sobre a mesma foto', gen_random_uuid(), null, '80500000-0000-4000-8000-000000000100'::uuid))->>'tipo',
  'denuncia',
  'denuncia repetida registrada'
);

select is(
  (select denuncias_distintas from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  1::smallint,
  'denuncia da mesma conta mantem denuncias_distintas em 1'
);

-- 2.5 Autor bloqueado NÃO entra no limiar (achado 2 do Lince Codex)
-- Insere diretamente na ocorrência para simular relato gravado
insert into public.ocorrencia (tipo, usuario_id, autor_id, motivo, relato, midia_id)
values ('denuncia', '80500000-0000-4000-8000-000000000001', '80500000-0000-4000-8000-000000000004', 'outro', 'relato de conta bloqueada pelo alvo', '80500000-0000-4000-8000-000000000100');

select is(
  (select denuncias_distintas from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  1::smallint,
  'denuncia de autor bloqueado pelo alvo e ignorada na contagem'
);

-- 2.6 Autor suspenso NÃO entra no limiar (achado 2 do Lince Codex)
insert into public.ocorrencia (tipo, usuario_id, autor_id, motivo, relato, midia_id)
values ('denuncia', '80500000-0000-4000-8000-000000000001', '80500000-0000-4000-8000-000000000005', 'outro', 'relato de conta suspensa', '80500000-0000-4000-8000-000000000100');

select is(
  (select denuncias_distintas from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  1::smallint,
  'denuncia de autor com conta suspensa e ignorada na contagem'
);

-- 2.7 Denúncia 2 por conta distinta elegível (contratante 2) -> atinge limiar 2 e oculta
set local request.jwt.claims = '{"sub":"80500000-0000-4000-8000-000000000003","role":"authenticated"}';
select is(
  (public.denunciar('profissional', '80500000-0000-4000-8000-000000000010', 'outro', 'relato do segundo contratante elegivel', gen_random_uuid(), null, '80500000-0000-4000-8000-000000000100'::uuid))->>'tipo',
  'denuncia',
  'denuncia 2 registrada de conta distinta'
);

select is(
  (select denuncias_distintas from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  2::smallint,
  'denuncias_distintas atinge 2'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  'ocultada',
  '2 denuncias de contas distintas ocultam a foto (estado=ocultada)'
);

select is(
  (select count(*) from pgmq.q_moderacao_midia where message->>'midia_id' = '80500000-0000-4000-8000-000000000100' and (message->>'reanalise')::boolean = true),
  1::bigint,
  'ocultacao por denuncia enfileira reanalise automatica em moderacao_midia'
);

-- PARTE 3: Expurgo em 24 h de fotos recusadas e nao_publicadas (achados 1 e 3 do Lince Codex)
-- Fronteiras: 23h59m59s (retida), 24h00m00s (expurgada), 24h29m59s (expurgada), 25h (expurgada)
-- Foto recusada há 23h59m59s (não deve ser expurgada ainda)
insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado, criado_em, atualizado_em)
values ('80500000-0000-4000-8000-000000000201', '80500000-0000-4000-8000-000000000001', 'profissional', 'foto_perfil', 'perfil/recusada_recente.jpg', 'image/jpeg', 100, 'recusada',
        privado.agora() - interval '23 hours 59 minutes 59 seconds', privado.agora() - interval '23 hours 59 minutes 59 seconds');

-- Foto recusada na fronteira exata de 24h00m00s (deve ser expurgada)
insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado, criado_em, atualizado_em)
values ('80500000-0000-4000-8000-000000000205', '80500000-0000-4000-8000-000000000001', 'profissional', 'foto_perfil', 'perfil/recusada_24h.jpg', 'image/jpeg', 100, 'recusada',
        privado.agora() - interval '24 hours', privado.agora() - interval '24 hours');

-- Foto recusada há 24h29m59s (deve ser expurgada)
insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado, criado_em, atualizado_em)
values ('80500000-0000-4000-8000-000000000206', '80500000-0000-4000-8000-000000000001', 'profissional', 'foto_perfil', 'perfil/recusada_24h30.jpg', 'image/jpeg', 100, 'recusada',
        privado.agora() - interval '24 hours 29 minutes 59 seconds', privado.agora() - interval '24 hours 29 minutes 59 seconds');

-- Foto recusada há 25 h (deve ser expurgada)
insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado, criado_em, atualizado_em)
values ('80500000-0000-4000-8000-000000000202', '80500000-0000-4000-8000-000000000001', 'profissional', 'foto_perfil', 'perfil/recusada_antiga.jpg', 'image/jpeg', 100, 'recusada',
        privado.agora() - interval '25 hours', privado.agora() - interval '25 hours');

-- Foto nao_publicada há 25 h (deve ser expurgada em 24h, CD-M11 / achado 3)
insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado, criado_em, atualizado_em)
values ('80500000-0000-4000-8000-000000000203', '80500000-0000-4000-8000-000000000001', 'profissional', 'foto_perfil', 'perfil/nao_publicada_antiga.jpg', 'image/jpeg', 100, 'nao_publicada',
        privado.agora() - interval '25 hours', privado.agora() - interval '25 hours');

-- Foto ocultada há 100 h (NÃO deve ser expurgada automaticamente sem decisão / achado 3)
insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado, criado_em, atualizado_em)
values ('80500000-0000-4000-8000-000000000204', '80500000-0000-4000-8000-000000000001', 'profissional', 'foto_perfil', 'perfil/ocultada_antiga.jpg', 'image/jpeg', 100, 'ocultada',
        privado.agora() - interval '100 hours', privado.agora() - interval '100 hours');

select is(
  privado.expurgar_midias_recusadas(),
  4,
  'expurgar_midias_recusadas processa fotos recusadas e nao_publicadas com 24h ou mais'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000201'),
  'recusada',
  'foto recusada ha 23h59m59s permanece como recusada'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000205'),
  'expurgada',
  'foto recusada ha 24h00m00s transiciona para expurgada'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000206'),
  'expurgada',
  'foto recusada ha 24h29m59s transiciona para expurgada'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000202'),
  'expurgada',
  'foto recusada ha 25h transiciona para expurgada'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000203'),
  'expurgada',
  'foto nao_publicada ha 25h transiciona para expurgada'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000204'),
  'ocultada',
  'foto ocultada nao e expurgada automaticamente'
);

select is(
  (select count(*) from pgmq.q_expurgo_midia where message->>'verificacao_id' in ('80500000-0000-4000-8000-000000000202', '80500000-0000-4000-8000-000000000203', '80500000-0000-4000-8000-000000000205', '80500000-0000-4000-8000-000000000206')),
  4::bigint,
  '4 mensagens enfileiradas em expurgo_midia com bucket midia-perfil'
);

-- PARTE 4: Remoção pelo dono enfileira expurgo imediatamente
set local request.jwt.claims = '{"sub":"80500000-0000-4000-8000-000000000001","role":"authenticated"}';
update privado.configuracao_app set foto_de_perfil = true;

insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
values ('80500000-0000-4000-8000-000000000300', '80500000-0000-4000-8000-000000000001', 'profissional', 'foto_perfil', 'perfil/remover.jpg', 'image/jpeg', 100, 'aprovada');

select is(
  (public.remover_midia('80500000-0000-4000-8000-000000000300'))->>'estado',
  'removida',
  'remover_midia marca como removida'
);

select is(
  (select count(*) from pgmq.q_expurgo_midia where message->>'verificacao_id' = '80500000-0000-4000-8000-000000000300'),
  1::bigint,
  'remover_midia enfileira expurgo fisico no storage'
);

-- PARTE 5: Confirmar expurgo de mídia de perfil (achado 5 do Lince Codex)
select is(
  privado.confirmar_expurgo_midia_perfil('80500000-0000-4000-8000-000000000300'),
  true,
  'confirmar_expurgo_midia_perfil confirma com sucesso para removida'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000300'),
  'expurgada',
  'confirmar_expurgo_midia_perfil transiciona para expurgada'
);

select is(
  privado.confirmar_expurgo_midia_perfil('80500000-0000-4000-8000-000000000300'),
  true,
  'confirmar_expurgo_midia_perfil idempotente'
);

-- Recusa de confirmação para mídia aprovada ou inexistente (retorna false)
select is(
  privado.confirmar_expurgo_midia_perfil('80500000-0000-4000-8000-000000000100'),
  false,
  'confirmar_expurgo_midia_perfil retorna false para foto nao elegivel (ocultada/aprovada)'
);

-- PARTE 5b: Validação prévia de elegibilidade de expurgo (achado 4 do Lince Codex)
select is(
  privado.validar_expurgo_midia_perfil('80500000-0000-4000-8000-000000000300', 'midia-perfil', '["perfil/remover.jpg"]'::jsonb),
  true,
  'validar_expurgo_midia_perfil aprova foto em estado expurgada/removida com bucket e caminho corretos'
);

select is(
  privado.validar_expurgo_midia_perfil('80500000-0000-4000-8000-000000000100', 'midia-perfil', '["perfil/valida.jpg"]'::jsonb),
  false,
  'validar_expurgo_midia_perfil recusa foto com estado aprovada'
);

select is(
  privado.validar_expurgo_midia_perfil('80500000-0000-4000-8000-000000000300', 'bucket-invalido', '["perfil/remover.jpg"]'::jsonb),
  false,
  'validar_expurgo_midia_perfil recusa bucket incorreto'
);

select is(
  privado.validar_expurgo_midia_perfil('80500000-0000-4000-8000-000000000300', 'midia-perfil', '["perfil/caminho_estranho.jpg"]'::jsonb),
  false,
  'validar_expurgo_midia_perfil recusa caminhos que nao pertencem a midia'
);

select * from finish();
rollback;
