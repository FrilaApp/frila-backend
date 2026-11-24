-- 899_ip_real_da_web_hmac_no_registro_de_acesso.sql · B-116 (migração 20261124180000).
-- O pre-request grava o IP que o Worker da web recebeu (x-frila-ip-visitante), conferido por HMAC-SHA256 sobre o TEXTO CRU
-- (v1|<ip>|<carimbo>|<uid>), com janela de 60 s no relógio real do banco; sem assinatura válida grava o cf-connecting-ip,
-- como antes. A falha do cabeçalho sai amostrada (1 de 20). Dados sintéticos: 203.0.113.0/24 e 198.51.100.0/24 (RFC 5737),
-- 2001:db8::/32 (RFC 3849). O segredo entra no Vault DENTRO da transação (o rollback desfaz).
begin;
-- O slot de teste nasce antes de qualquer escrita (o Postgres exige) e é TEMPORÁRIO, com o nome real.
select 1 from pg_create_logical_replication_slot('frila_registro_acesso', 'test_decoding', true);
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select plan(60);

delete from privado.registro_acesso;
delete from privado.registro_acesso_recente;
delete from vault.secrets where starts_with(name, 'ip_visitante_hmac_');
select vault.create_secret('chave-sintetica-de-teste', 'ip_visitante_hmac_a1');
select vault.create_secret('segredo-sintetico-chave-b2', 'ip_visitante_hmac_b2');

-- ── Auxiliares ──────────────────────────────────────────────────────────────
create function pg_temp.agora_s() returns bigint language sql as $$
  select floor(extract(epoch from clock_timestamp()))::bigint
$$;
-- A assinatura que o Worker faria: v1;k=<id>;<hex do HMAC-SHA256 de v1|ip|carimbo|uid>.
create function pg_temp.assin(p_id text, p_segredo text, p_ip text, p_car bigint, p_uid text) returns text language sql as $$
  select 'v1;k=' || p_id || ';' || encode(extensions.hmac(convert_to('v1|' || p_ip || '|' || p_car || '|' || p_uid, 'UTF8'),
                                                        convert_to(p_segredo, 'UTF8'), 'sha256'), 'hex')
$$;
-- Os cabeçalhos como o PostgREST os entrega (chaves em minúsculas). Argumento nulo = cabeçalho ausente.
create function pg_temp.cab(p_ip text, p_car text, p_ass text, p_cf text default '198.51.100.9') returns json language sql as $$
  select json_strip_nulls(json_build_object('cf-connecting-ip', p_cf, 'x-frila-ip-visitante', p_ip,
                                            'x-frila-ip-carimbo', p_car, 'x-frila-ip-assinatura', p_ass))
$$;
-- 'IP|motivo' da avaliação pura ('-' = sem motivo).
create function pg_temp.res(p_cab json, p_uid text default '11111111-1111-4111-8111-111111111111') returns text language sql as $$
  select coalesce(a.p_ip, 'nulo') || '|' || coalesce(a.p_motivo, '-') from privado.avaliar_ip_do_acesso(p_cab, p_uid::uuid) a
$$;
-- Cabeçalhos assinados com a chave a1 para (ip, carimbo) da conta do teste.
create function pg_temp.valido(p_ip text, p_desvio int default 0) returns json language sql as $$
  select pg_temp.cab(p_ip, (pg_temp.agora_s() + p_desvio)::text,
    pg_temp.assin('a1', 'chave-sintetica-de-teste', p_ip, pg_temp.agora_s() + p_desvio, '11111111-1111-4111-8111-111111111111'))
$$;
-- Uma requisição do PostgREST, como o pre-request a vê.
create function pg_temp.requisicao(p_conta text, p_cabecalhos json) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_conta, 'role', 'authenticated')::text, true);
  perform set_config('request.headers', p_cabecalhos::text, true);
  perform set_config('request.method', 'GET', true);
  perform requisicao.conferir_limite();
end $$;
-- Consome o slot para a tabela temporária (prefixo, conteúdo) e a deixa para as perguntas.
create temp table msgs (prefixo text, conteudo text);
create function pg_temp.drenar() returns void language plpgsql as $$
begin
  perform pg_logical_emit_message(false, 'zz_899_flush', 'x', true);
  delete from pg_temp.msgs;
  insert into pg_temp.msgs
    select m[1], m[2]
      from pg_logical_slot_get_changes('frila_registro_acesso', null, null) d,
           lateral regexp_match(d.data, '^message: transactional: 0 prefix: (frila_registro_acesso[a-z_]*), sz: [0-9]+ content:(.*)$') m
     where m is not null;
end $$;

-- ── Privilégios ─────────────────────────────────────────────────────────────
select ok(not has_function_privilege('anon', 'privado.ip_do_acesso(json, uuid)', 'execute')
      and not has_function_privilege('authenticated', 'privado.ip_do_acesso(json, uuid)', 'execute')
      and not has_function_privilege('anon', 'privado.avaliar_ip_do_acesso(json, uuid)', 'execute')
      and not has_function_privilege('authenticated', 'privado.avaliar_ip_do_acesso(json, uuid)', 'execute'),
  'anon e authenticated não executam a avaliação do IP (só o pre-request, que é security definer)');
select ok(has_function_privilege('anon', 'requisicao.conferir_limite()', 'execute'),
  'o pre-request segue chamável pelo PostgREST');

-- ── Avaliação pura: o desenho caso a caso ───────────────────────────────────
select is(pg_temp.res(pg_temp.valido('203.0.113.7')), '203.0.113.7|-',
  'assinatura válida: o IP do cabeçalho vence o cf-connecting-ip');
select is(pg_temp.res(pg_temp.cab('203.0.113.7', pg_temp.agora_s()::text,
    'v1;k=a1;' || repeat('0', 64))), '198.51.100.9|assinatura_invalida',
  'assinatura inválida: usa o cf-connecting-ip');
select is(pg_temp.res(pg_temp.valido('203.0.113.7', -61)), '198.51.100.9|carimbo_vencido',
  'carimbo vencido (61 s no passado): recusa');
select is(pg_temp.res(pg_temp.valido('203.0.113.7', -55)), '203.0.113.7|-',
  'carimbo de 55 s atrás: ainda vale');
select is(pg_temp.res(pg_temp.valido('203.0.113.7', 61)), '198.51.100.9|carimbo_vencido',
  'carimbo futuro (+61 s): recusa (a janela vale nos dois sentidos)');
select is(pg_temp.res(pg_temp.valido('203.0.113.7', 55)), '203.0.113.7|-',
  'carimbo 55 s no futuro: ainda vale');
select is(pg_temp.res(pg_temp.cab('203.0.113.7', null, null)), '198.51.100.9|formato',
  'ausente parcial: só o IP');
select is(pg_temp.res(pg_temp.cab('203.0.113.7', pg_temp.agora_s()::text, null)), '198.51.100.9|formato',
  'ausente parcial: IP e carimbo, sem assinatura');
select is(pg_temp.res(pg_temp.cab(null, null, pg_temp.assin('a1', 'chave-sintetica-de-teste', '203.0.113.7', pg_temp.agora_s(),
    '11111111-1111-4111-8111-111111111111'))), '198.51.100.9|formato',
  'ausente parcial: só a assinatura');
select is(pg_temp.res(pg_temp.cab('203.0.113.7', 'ontem', 'v1;k=a1;' || repeat('0', 64))), '198.51.100.9|formato',
  'carimbo que não é inteiro: formato');
select is(pg_temp.res(pg_temp.cab('203.0.113.7', pg_temp.agora_s()::text, 'v2;k=a1;' || repeat('0', 64))),
  '198.51.100.9|formato', 'versão de formato desconhecida (v2): formato');
select is(pg_temp.res(pg_temp.cab('não-é-ip', pg_temp.agora_s()::text,
    pg_temp.assin('a1', 'chave-sintetica-de-teste', 'não-é-ip', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|formato', 'IP malformado, mesmo assinado de verdade: formato');
select is(pg_temp.res(pg_temp.cab('203.0.113.7/24', pg_temp.agora_s()::text,
    pg_temp.assin('a1', 'chave-sintetica-de-teste', '203.0.113.7/24', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|formato', 'IP com máscara (rede, não endereço): formato');
select is(pg_temp.res(pg_temp.valido('203.0.113.7'), '22222222-2222-4222-8222-222222222222'),
  '198.51.100.9|assinatura_invalida', 'uid trocado: a assinatura de uma conta não vale em outra');
select is(pg_temp.res(pg_temp.cab('203.0.113.8', pg_temp.agora_s()::text,
    pg_temp.assin('a1', 'chave-sintetica-de-teste', '203.0.113.7', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|assinatura_invalida', 'IP trocado depois de assinar: recusa');
select is(pg_temp.res(pg_temp.cab('203.0.113.7', (pg_temp.agora_s() + 1)::text,
    pg_temp.assin('a1', 'chave-sintetica-de-teste', '203.0.113.7', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|assinatura_invalida', 'carimbo trocado depois de assinar (dentro da janela): recusa');

-- Duas chaves no Vault: cada uma vale pelo próprio id.
select is(pg_temp.res(pg_temp.cab('203.0.113.7', pg_temp.agora_s()::text,
    pg_temp.assin('b2', 'segredo-sintetico-chave-b2', '203.0.113.7', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '203.0.113.7|-', 'segredo anterior/novo: a chave b2 vale pelo id b2');
select is(pg_temp.res(pg_temp.cab('203.0.113.7', pg_temp.agora_s()::text,
    pg_temp.assin('b2', 'chave-sintetica-de-teste', '203.0.113.7', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|assinatura_invalida', 'id b2 assinado com o segredo da a1: recusa (id e segredo andam juntos)');
select is(pg_temp.res(pg_temp.cab('203.0.113.7', pg_temp.agora_s()::text,
    pg_temp.assin('c3', 'chave-sintetica-de-teste', '203.0.113.7', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|chave_desconhecida', 'id que não existe no Vault: chave_desconhecida');
delete from vault.secrets where name = 'ip_visitante_hmac_b2';
select is(pg_temp.res(pg_temp.cab('203.0.113.7', pg_temp.agora_s()::text,
    pg_temp.assin('b2', 'segredo-sintetico-chave-b2', '203.0.113.7', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|chave_desconhecida', 'chave retirada do Vault (apagar a entrada): chave_desconhecida');
select is(pg_temp.res(pg_temp.valido('203.0.113.7')), '203.0.113.7|-', 'a chave que ficou (a1) segue valendo');

-- IPv6: o HMAC é sobre o texto CRU, antes de virar inet (inet::text reescreve).
select is(pg_temp.res(pg_temp.valido('2001:db8:0:0:0:0:0:1')), '2001:db8:0:0:0:0:0:1|-',
  'IPv6 sem compressão, assinado sobre o texto cru: vale');
select is(pg_temp.res(pg_temp.cab('2001:db8:0:0:0:0:0:1', pg_temp.agora_s()::text,
    pg_temp.assin('a1', 'chave-sintetica-de-teste', '2001:db8::1', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|assinatura_invalida', 'IPv6 assinado sobre a forma comprimida enquanto o cabeçalho vai sem compressão: não confere');
select is(pg_temp.res(pg_temp.valido('2001:DB8::A')), '2001:DB8::A|-', 'IPv6 em maiúsculas, assinado sobre o texto cru: vale');
select is(pg_temp.res(pg_temp.cab('2001:DB8::A', pg_temp.agora_s()::text,
    pg_temp.assin('a1', 'chave-sintetica-de-teste', '2001:db8::a', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|assinatura_invalida', 'IPv6 assinado sobre a forma normalizada (minúsculas): não confere');
select is(pg_temp.res(pg_temp.valido('::ffff:203.0.113.9')), '::ffff:203.0.113.9|-',
  'IPv4 mapeado em IPv6 (::ffff:) público, assinado sobre o texto cru: vale');

-- Vetor comum com o Worker (conferido com openssl): chave 'chave-sintetica-de-teste', uid 00000000-0000-4000-8000-000000000001,
-- carimbo 1764000000. Prova que banco e Worker assinam igual (chave = bytes UTF-8 do TEXTO, não os decodificados).
select is(encode(extensions.hmac('v1|203.0.113.7|1764000000|00000000-0000-4000-8000-000000000001', 'chave-sintetica-de-teste', 'sha256'), 'hex'),
  '92f88c71111a679549dbc95ed494f70cd334afba29f4a3671afbf2f05450f8cf', 'vetor comum: IPv4 203.0.113.7');
select is(encode(extensions.hmac('v1|2001:db8::1|1764000000|00000000-0000-4000-8000-000000000001', 'chave-sintetica-de-teste', 'sha256'), 'hex'),
  '2b867312419c3f6da5ca307ef1309b9e5afc82aeba681ab20bc44a070057ac25', 'vetor comum: IPv6 curto 2001:db8::1');
select is(encode(extensions.hmac('v1|2001:0db8:0000:0000:0000:0000:0000:0001|1764000000|00000000-0000-4000-8000-000000000001', 'chave-sintetica-de-teste', 'sha256'), 'hex'),
  'bc9810ddf2fc4b945a3337c88cfedf0ef02121217b511107a390b243124be90b', 'vetor comum: o mesmo IPv6 em texto longo (outro hex)');
-- O fluxo completo, com a MESMA chave (a1) e o relógio real: o HMAC é sobre o texto CRU.
select is(pg_temp.res(pg_temp.valido('2001:db8::1')), '2001:db8::1|-', 'IPv6 curto, assinado sobre o texto curto: vale');
select is(pg_temp.res(pg_temp.cab('2001:db8::1', pg_temp.agora_s()::text,
    pg_temp.assin('a1', 'chave-sintetica-de-teste', '2001:0db8:0000:0000:0000:0000:0000:0001', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|assinatura_invalida', 'cabeçalho curto com assinatura sobre a forma longa (mesmo endereço): não vale');
-- Valor do Vault com quebra de linha no fim (colado à mão): a função aplica btrim, como o Worker.
select vault.create_secret('chave-sintetica-de-teste' || E'\n', 'ip_visitante_hmac_n1');
select is(pg_temp.res(pg_temp.cab('203.0.113.7', pg_temp.agora_s()::text,
    pg_temp.assin('n1', 'chave-sintetica-de-teste', '203.0.113.7', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '203.0.113.7|-', 'segredo do Vault com quebra de linha no fim: o btrim da função o iguala ao do Worker');

-- Chave vazia ou só de espaços/quebras no Vault NÃO é chave: um HMAC com chave vazia qualquer um calcula (Lince AG, B-116).
select vault.create_secret('', 'ip_visitante_hmac_vz');
select vault.create_secret('   ' || E'\n', 'ip_visitante_hmac_es');
select is(pg_temp.res(pg_temp.cab('203.0.113.77', pg_temp.agora_s()::text,
    pg_temp.assin('vz', '', '203.0.113.77', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|chave_desconhecida', 'chave VAZIA no Vault, HMAC calculado com chave vazia: recusa e grava o IP da conexão');
select is(pg_temp.res(pg_temp.cab('203.0.113.77', pg_temp.agora_s()::text,
    pg_temp.assin('es', '', '203.0.113.77', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|chave_desconhecida', 'chave só de espaços e quebra de linha, HMAC com chave vazia: recusa');
select is(pg_temp.res(pg_temp.cab('203.0.113.77', pg_temp.agora_s()::text,
    pg_temp.assin('es', E'   \n', '203.0.113.77', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|chave_desconhecida', 'chave só de espaços e quebra de linha, HMAC com o texto cru dela: recusa');
delete from vault.secrets where name in ('ip_visitante_hmac_vz', 'ip_visitante_hmac_es');

-- IP reservado: recusa mesmo com assinatura válida.
select is((select count(*)::int from unnest(array['127.0.0.1', '10.1.2.3', '172.16.5.5', '172.31.255.255', '192.168.0.1',
    '169.254.1.1', '0.0.0.0', '240.0.0.1', '255.255.255.255', '::1', '::', 'fe80::1', 'fd00::1', '::ffff:10.0.0.1',
    '::ffff:127.0.0.1']) ip where pg_temp.res(pg_temp.valido(ip)) = '198.51.100.9|ip_reservado'), 15,
  'IP loopback, privado, link-local, não especificado, 240.0.0.0/4 e IPv6 reservado (inclui ::ffff: de IPv4 privado): ip_reservado');
select is((select count(*)::int from unnest(array['172.32.0.1', '11.0.0.1', '223.255.255.255', '203.0.113.7', '2001:db8::1',
    '2606:4700::1111']) ip where pg_temp.res(pg_temp.valido(ip)) = ip || '|-'), 6,
  'IP público na beira das faixas reservadas (172.32, 11.x, IPv6 global) segue valendo');

-- Sem cabeçalho nenhum: igual a hoje.
select is(pg_temp.res('{"cf-connecting-ip":"198.51.100.9"}'::json), '198.51.100.9|-', 'sem x-frila-ip-*: cf-connecting-ip, sem motivo');
select is(pg_temp.res('{}'::json), 'nulo|-', 'sem cf-connecting-ip nem x-frila-ip-*: nada (como hoje)');
select is(pg_temp.res(pg_temp.cab('203.0.113.7', pg_temp.agora_s()::text,
    pg_temp.assin('a1', 'chave-sintetica-de-teste', '203.0.113.7', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'), null)),
  '203.0.113.7|-', 'assinatura válida sem cf-connecting-ip: grava o IP do cabeçalho');

-- ── O pre-request, de ponta a ponta (coleta ligada) ─────────────────────────
select is((privado.definir_coleta_registro_acesso(true) ->> 'slot')::boolean, true, 'ligar a coleta exige o slot');
select pg_temp.drenar();

-- Com o cabeçalho válido, a mensagem leva o IP da web, e só ele (nunca o do Worker).
select pg_temp.requisicao('11111111-1111-4111-8111-111111111111', pg_temp.valido('203.0.113.7'));
select pg_temp.drenar();
select is((select string_agg(conteudo, ';') from pg_temp.msgs where prefixo = 'frila_registro_acesso')
          ~ '^11111111-1111-4111-8111-111111111111 203\.0\.113\.7 ', true,
  'pre-request com assinatura válida: registra o IP do cabeçalho');
select is((select count(*)::int from pg_temp.msgs where prefixo = 'frila_registro_acesso_falha'), 0,
  'assinatura válida: nenhuma falha emitida');

-- IPv6 sem compressão: o registro grava a forma do host(inet).
select pg_temp.requisicao('11111111-1111-4111-8111-111111111111', pg_temp.valido('2001:db8:0:0:0:0:0:1'));
select pg_temp.drenar();
select is((select string_agg(conteudo, ';') from pg_temp.msgs where prefixo = 'frila_registro_acesso')
          ~ '^11111111-1111-4111-8111-111111111111 2001:db8::1 ', true,
  'IPv6 válido: o registro grava host(inet), a forma normalizada');

-- Sem cabeçalho x-frila: o IP do cf-connecting-ip, exatamente como antes.
select pg_temp.requisicao('11111111-1111-4111-8111-111111111111', '{"cf-connecting-ip":"198.51.100.9"}'::json);
select pg_temp.drenar();
select is((select string_agg(conteudo, ';') from pg_temp.msgs where prefixo = 'frila_registro_acesso')
          ~ '^11111111-1111-4111-8111-111111111111 198\.51\.100\.9 ', true,
  'sem cabeçalho x-frila-ip-*: registra o cf-connecting-ip, como hoje');

-- O texto "x-frila-ip-" só dentro do valor de outro cabeçalho não muda nada e não gera falha.
select pg_temp.requisicao('11111111-1111-4111-8111-111111111111',
  '{"cf-connecting-ip":"198.51.100.9","user-agent":"x-frila-ip-teste"}'::json);
select pg_temp.drenar();
select is((select count(*)::int from pg_temp.msgs where prefixo = 'frila_registro_acesso' and conteudo ~ ' 198\.51\.100\.9 '), 1,
  'texto x-frila-ip- só dentro do valor de outro cabeçalho: registra o cf-connecting-ip');
select is((select count(*)::int from pg_temp.msgs where prefixo = 'frila_registro_acesso_falha'), 0,
  'texto x-frila-ip- só dentro do valor de outro cabeçalho: não emite falha');

-- Cabeçalho inválido: o IP gravado é SEMPRE o da conexão; a falha sai amostrada (1 de 20), só com o motivo.
select pg_temp.drenar();
select pg_temp.requisicao('11111111-1111-4111-8111-111111111111',
  pg_temp.cab('203.0.113.7', pg_temp.agora_s()::text, 'v1;k=a1;' || repeat('0', 64)))
  from generate_series(1, 400);
select pg_temp.drenar();
select is((select count(*)::int from pg_temp.msgs where prefixo = 'frila_registro_acesso' and conteudo ~ ' 198\.51\.100\.9 '), 400,
  '400 requisições com assinatura inválida: o IP usado foi sempre o da conexão');
select is((select count(*)::int from pg_temp.msgs where prefixo = 'frila_registro_acesso' and conteudo ~ ' 203\.0\.113\.7 '), 0,
  '400 requisições com assinatura inválida: o IP forjado nunca entra');
select ok((select count(*) from pg_temp.msgs where prefixo = 'frila_registro_acesso_falha') between 1 and 100,
  'falha amostrada: de 400 requisições inválidas saem entre 1 e 100 mensagens de falha (esperado ~20)');
select is((select string_agg(distinct conteudo, ',') from pg_temp.msgs where prefixo = 'frila_registro_acesso_falha'),
  'assinatura_invalida', 'a mensagem de falha leva só o motivo (sem IP, sem cabeçalho)');

-- Carimbo vencido e formato também passam pela amostragem.
select pg_temp.requisicao('11111111-1111-4111-8111-111111111111', pg_temp.valido('203.0.113.7', -300)) from generate_series(1, 400);
select pg_temp.drenar();
select ok((select count(*) from pg_temp.msgs where prefixo = 'frila_registro_acesso_falha') between 1 and 100
      and (select count(*) from pg_temp.msgs where prefixo = 'frila_registro_acesso' and conteudo ~ ' 198\.51\.100\.9 ') = 400,
  'carimbo vencido, 400 requisições: IP da conexão sempre e falha amostrada (1 a 100)');
select pg_temp.requisicao('11111111-1111-4111-8111-111111111111', pg_temp.cab('203.0.113.7', null, null)) from generate_series(1, 400);
select pg_temp.drenar();
select ok((select count(*) from pg_temp.msgs where prefixo = 'frila_registro_acesso_falha') between 1 and 100
      and (select string_agg(distinct conteudo, ',') from pg_temp.msgs where prefixo = 'frila_registro_acesso_falha') = 'formato',
  'cabeçalho incompleto, 400 requisições: motivo formato, amostrado (1 a 100)');

-- Sem segredo no Vault: usa o cf-connecting-ip e a falha sem_segredo, também amostrada.
delete from vault.secrets where starts_with(name, 'ip_visitante_hmac_');
select pg_temp.requisicao('11111111-1111-4111-8111-111111111111', pg_temp.valido('203.0.113.7')) from generate_series(1, 400);
select pg_temp.drenar();
select is((select count(*)::int from pg_temp.msgs where prefixo = 'frila_registro_acesso' and conteudo ~ ' 198\.51\.100\.9 '), 400,
  'sem segredo no Vault, 400 requisições: o IP usado foi sempre o da conexão');
select ok((select count(*) from pg_temp.msgs where prefixo = 'frila_registro_acesso_falha') between 1 and 100
      and (select string_agg(distinct conteudo, ',') from pg_temp.msgs where prefixo = 'frila_registro_acesso_falha') = 'sem_segredo',
  'sem segredo: falha sem_segredo amostrada (1 a 100 de 400)');
select is(pg_temp.res(pg_temp.valido('203.0.113.7')), '198.51.100.9|sem_segredo', 'sem segredo no Vault: cf-connecting-ip e motivo sem_segredo');
-- Só existem entradas vazias: tampouco é chave (sem_segredo, não chave_desconhecida).
select vault.create_secret('', 'ip_visitante_hmac_vz');
select is(pg_temp.res(pg_temp.cab('203.0.113.77', pg_temp.agora_s()::text,
    pg_temp.assin('vz', '', '203.0.113.77', pg_temp.agora_s(), '11111111-1111-4111-8111-111111111111'))),
  '198.51.100.9|sem_segredo', 'só há entrada vazia no Vault: conta como sem segredo, e o HMAC com chave vazia é recusado');

-- privado.ip_do_acesso devolve o mesmo IP da avaliação pura.
select is(privado.ip_do_acesso(pg_temp.valido('203.0.113.7'), '11111111-1111-4111-8111-111111111111'), '198.51.100.9',
  'privado.ip_do_acesso devolve o IP da avaliação (aqui sem segredo: o da conexão)');

select * from finish();
rollback;
