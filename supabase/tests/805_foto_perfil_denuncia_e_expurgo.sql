-- 805_foto_perfil_denuncia_e_expurgo.sql
--
-- B4b: Estreitamento da foto de perfil, remoção de colunas mortas,
-- ocultação por 2 denúncias distintas e expurgo em 24 h (RN37, CA4).

begin;
select plan(24);

-- 1. Setup e ambiente de teste
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local "frila.agora" = '2026-11-20 12:00:00+00';
set local "frila.agendador_secret" = 'segredo_teste_agendador_123';
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
  ('80500000-0000-4000-8000-000000000003', 'contratante2@805.test');

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em) values
  ('80500000-0000-4000-8000-000000000001', 'profissional', 'Profissional Foto', 'prof@805.test', '+5561955508051', '1995-01-01', '1.0', now()),
  ('80500000-0000-4000-8000-000000000002', 'contratante', 'Contratante Um', 'contratante1@805.test', '+5561955508052', '1990-01-01', '1.0', now()),
  ('80500000-0000-4000-8000-000000000003', 'contratante', 'Contratante Dois', 'contratante2@805.test', '+5561955508053', '1992-01-01', '1.0', now());

insert into public.profissional (id, usuario_id, ponto_base) values
  ('80500000-0000-4000-8000-000000000010', '80500000-0000-4000-8000-000000000001', 'POINT(-47.8822 -15.7942)'::extensions.geography);

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

-- PARTE 2: Duas denúncias de contas distintas ocultam a foto (CD-M07 / CA4)
-- Denúncia 1: feita por contratante 1
set local request.jwt.claims = '{"sub":"80500000-0000-4000-8000-000000000002","role":"authenticated"}';
select is(
  (public.denunciar('profissional', '80500000-0000-4000-8000-000000000010', 'outro', 'relato de teste com mais de dez caracteres', gen_random_uuid()))->>'tipo',
  'denuncia',
  'denuncia 1 registrada'
);

select is(
  (select denuncias_distintas from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  1::smallint,
  'primeira denuncia incrementa denuncias_distintas para 1'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  'aprovada',
  'foto continua aprovada com 1 denuncia'
);

-- Denúncia repetida pela mesma conta (contratante 1): não deve somar conta distinta
select is(
  (public.denunciar('profissional', '80500000-0000-4000-8000-000000000010', 'outro', 'outro relato valido com mais de dez caracteres', gen_random_uuid()))->>'tipo',
  'denuncia',
  'denuncia repetida registrada'
);

select is(
  (select denuncias_distintas from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  1::smallint,
  'denuncia da mesma conta mantem denuncias_distintas em 1'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000100'),
  'aprovada',
  'foto continua aprovada apos denuncia repetida da mesma conta'
);

-- Denúncia 2: feita por conta distinta (contratante 2) -> atinge o limiar de 2 e oculta
set local request.jwt.claims = '{"sub":"80500000-0000-4000-8000-000000000003","role":"authenticated"}';
select is(
  (public.denunciar('profissional', '80500000-0000-4000-8000-000000000010', 'outro', 'relato do segundo contratante com dez caracteres', gen_random_uuid()))->>'tipo',
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

-- PARTE 3: Expurgo em 24 h de fotos recusadas
-- Foto recusada há 23 h (não deve ser expurgada)
insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado, criado_em, atualizado_em)
values ('80500000-0000-4000-8000-000000000201', '80500000-0000-4000-8000-000000000001', 'profissional', 'foto_perfil', 'perfil/recusada_recente.jpg', 'image/jpeg', 100, 'recusada',
        privado.agora() - interval '23 hours', privado.agora() - interval '23 hours');

-- Foto recusada há 25 h (deve ser expurgada)
insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado, criado_em, atualizado_em)
values ('80500000-0000-4000-8000-000000000202', '80500000-0000-4000-8000-000000000001', 'profissional', 'foto_perfil', 'perfil/recusada_antiga.jpg', 'image/jpeg', 100, 'recusada',
        privado.agora() - interval '25 hours', privado.agora() - interval '25 hours');

select is(
  privado.expurgar_midias_recusadas(),
  1,
  'expurgar_midias_recusadas processa exatamente a foto com mais de 24h'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000201'),
  'recusada',
  'foto recusada ha 23h permanece como recusada'
);

select is(
  (select estado from privado.midia where id = '80500000-0000-4000-8000-000000000202'::uuid),
  'expurgada',
  'foto recusada ha 25h transiciona para expurgada'
);

select is(
  (select count(*) from pgmq.q_expurgo_midia where message->>'verificacao_id' = '80500000-0000-4000-8000-000000000202'),
  1::bigint,
  'mensagem enfileirada em expurgo_midia com bucket midia-perfil'
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

-- PARTE 5: Confirmar expurgo de mídia de perfil
select is(
  privado.confirmar_expurgo_midia_perfil('80500000-0000-4000-8000-000000000300'),
  true,
  'confirmar_expurgo_midia_perfil confirma com sucesso'
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

rollback;
