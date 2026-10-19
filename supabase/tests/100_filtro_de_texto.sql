-- 100_filtro_de_texto.sql
--
-- O filtro de texto ofensivo (diretriz 1.2 da App Store).
-- Revisão ggEzge6h de 13/10/2026: 81 termos bloqueados,
-- remoção dos 3 falsos positivos (retardado, crioulo, corno),
-- e cobertura exaustiva do corpus de 88 casos (69 passam, 19 recusam).

begin;
select plan(110);

-- ── Normalização ──────────────────────────────────────────────────────────────

select is(privado.normalizar('Ana Ribeiro'), 'ana ribeiro',
  'minúsculas');
select is(privado.normalizar('JOÃO ÁVILA'), 'joao avila',
  'sem acento, e em minúsculas');
select is(privado.normalizar('Conceição'), 'conceicao',
  'o cedilha vira c');
select is(privado.normalizar('  Ana   Maria  '), 'ana maria',
  'espaço repetido colapsa, e as pontas somem');
select is(privado.normalizar('e-mail@teste.com'), 'e mail teste com',
  'pontuação vira espaço');
select is(privado.normalizar('abc.def'), 'abc def',
  'pontuação separa, não junta: abc.def não pode virar abcdef');
select is(privado.normalizar(null), null,
  'nulo entra, nulo sai');

-- ── A lista existe e está gravada na forma que o filtro compara ──────────────

select is((select count(*)::int from privado.termo_bloqueado), 81,
  'a lista tem exatamente 81 termos (revisão ggEzge6h)');

select is((select count(*)::int from privado.termo_bloqueado where termo in ('retardado', 'crioulo', 'corno')), 0,
  'os 3 termos tirados na revisão estão ausentes');

select is(
  (select count(*)::int from privado.termo_bloqueado
    where termo <> privado.normalizar(termo)),
  0,
  'todo termo está gravado já normalizado');

select throws_ok(
  $$ insert into privado.termo_bloqueado (termo, categoria) values ('Porra', 'palavrao') $$,
  '23514',
  null,
  'a tabela recusa termo fora da forma normalizada');

select throws_ok(
  $$ insert into privado.termo_bloqueado (termo, categoria) values ('a', 'palavrao') $$,
  '23514',
  null,
  'e recusa termo de uma letra só');

-- ── O filtro recusa (termos originais e compostos) ──────────────────────────

select ok(not privado.texto_aceitavel('caralho'),
  'recusa o termo sozinho');
select ok(not privado.texto_aceitavel('Ana Caralho Silva'),
  'recusa o termo no meio de um texto');
select ok(not privado.texto_aceitavel('CARALHO'),
  'recusa em maiúsculas');
select ok(not privado.texto_aceitavel('Você é um Otário!'),
  'recusa com acento e pontuação em volta');
select ok(not privado.texto_aceitavel('procura-se garota de programa'),
  'recusa termo composto de mais de uma palavra');

-- ── Nulo e vazio ─────────────────────────────────────────────────────────────

select ok(privado.texto_aceitavel(null),
  'nulo é aceitável: ausência é assunto de campo_obrigatorio, não deste filtro');
select ok(privado.texto_aceitavel(''),
  'vazio também');

-- ── Corpus da Seção 7: Falsos positivos que devem PASSAR ─────────────────────
-- Nomes e sobrenomes
select ok(privado.texto_aceitavel('Ana Cunha'), 'Ana Cunha: Cunha é sobrenome e contém um termo da lista');
select ok(privado.texto_aceitavel('Rodrigo Pinto'), 'Rodrigo Pinto: Pinto é sobrenome comuníssimo fora da lista por decisão');
select ok(privado.texto_aceitavel('Maria Conceição'), 'Maria Conceição: acentuação e cedilha legítimos');
select ok(privado.texto_aceitavel('João D''Ávila'), 'João D''Ávila: apóstrofo legítimo');
select ok(privado.texto_aceitavel('Pedro Rola'), 'Pedro Rola: Rola fora da lista por decisão');
select ok(privado.texto_aceitavel('Carlos Pau Brasil'), 'Carlos Pau Brasil: Pau fora da lista por decisão');
select ok(privado.texto_aceitavel('Roberto Bicharra'), 'Roberto Bicharra: palavra que contém termo');
select ok(privado.texto_aceitavel('João Macacari'), 'João Macacari: sobrenome que contém termo');

-- Profissões legítimas
select ok(privado.texto_aceitavel('garçom'), 'profissão legítima: garçom');
select ok(privado.texto_aceitavel('garçonete'), 'profissão legítima: garçonete');
select ok(privado.texto_aceitavel('bartender'), 'profissão legítima: bartender');
select ok(privado.texto_aceitavel('churrasqueiro'), 'profissão legítima: churrasqueiro');
select ok(privado.texto_aceitavel('copeiro'), 'profissão legítima: copeiro');
select ok(privado.texto_aceitavel('auxiliar de cozinha'), 'profissão legítima: auxiliar de cozinha');
select ok(privado.texto_aceitavel('recepcionista'), 'profissão legítima: recepcionista');
select ok(privado.texto_aceitavel('segurança'), 'profissão legítima: segurança');
select ok(privado.texto_aceitavel('acompanhante de idosos'), 'profissão legítima: acompanhante de idosos');
select ok(privado.texto_aceitavel('cuidador de idosos'), 'profissão legítima: cuidador de idosos');
select ok(privado.texto_aceitavel('cozinheiro'), 'profissão legítima: cozinheiro');
select ok(privado.texto_aceitavel('chapeiro'), 'profissão legítima: chapeiro');
select ok(privado.texto_aceitavel('manobrista'), 'profissão legítima: manobrista');
select ok(privado.texto_aceitavel('promotor de vendas'), 'profissão legítima: promotor de vendas');
select ok(privado.texto_aceitavel('fotógrafo'), 'profissão legítima: fotógrafo');
select ok(privado.texto_aceitavel('modelo nude para pintura'), 'profissão legítima: modelo nude para pintura');

-- Topônimos do DF e região
select ok(privado.texto_aceitavel('Cuiabá'), 'topônimo legítimo: Cuiabá');
select ok(privado.texto_aceitavel('Taguatinga Sul'), 'topônimo legítimo: Taguatinga Sul');
select ok(privado.texto_aceitavel('Ceilândia Norte'), 'topônimo legítimo: Ceilândia Norte');
select ok(privado.texto_aceitavel('Riacho Fundo II'), 'topônimo legítimo: Riacho Fundo II');
select ok(privado.texto_aceitavel('Núcleo Bandeirante'), 'topônimo legítimo: Núcleo Bandeirante');
select ok(privado.texto_aceitavel('Lago Sul'), 'topônimo legítimo: Lago Sul');
select ok(privado.texto_aceitavel('Asa Norte'), 'topônimo legítimo: Asa Norte');
select ok(privado.texto_aceitavel('Plano Piloto'), 'topônimo legítimo: Plano Piloto');
select ok(privado.texto_aceitavel('Samambaia'), 'topônimo legítimo: Samambaia');
select ok(privado.texto_aceitavel('Sobradinho'), 'topônimo legítimo: Sobradinho');
select ok(privado.texto_aceitavel('Planaltina'), 'topônimo legítimo: Planaltina');
select ok(privado.texto_aceitavel('Paranoá'), 'topônimo legítimo: Paranoá');
select ok(privado.texto_aceitavel('Guará'), 'topônimo legítimo: Guará');
select ok(privado.texto_aceitavel('Gama'), 'topônimo legítimo: Gama');
select ok(privado.texto_aceitavel('São Sebastião'), 'topônimo legítimo: São Sebastião');
select ok(privado.texto_aceitavel('Santa Maria'), 'topônimo legítimo: Santa Maria');
select ok(privado.texto_aceitavel('Chapada dos Veadeiros'), 'topônimo legítimo: Chapada dos Veadeiros');

-- Palavras comuns que contêm termos da lista como substring
select ok(privado.texto_aceitavel('curso de bartender'), 'curso contém termo');
select ok(privado.texto_aceitavel('levar cuidado com o material'), 'cuidado contém termo');
select ok(privado.texto_aceitavel('açúcar e café'), 'açúcar contém termo');
select ok(privado.texto_aceitavel('computador novo'), 'palavra comum legítima');
select ok(privado.texto_aceitavel('disputa de vagas'), 'palavra comum legítima');
select ok(privado.texto_aceitavel('reputação da casa'), 'palavra comum legítima');
select ok(privado.texto_aceitavel('porrada de trabalho'), 'expressão informal legítima');
select ok(privado.texto_aceitavel('você é foda'), 'gíria elogiosa legítima: foda isolada fica fora');
select ok(privado.texto_aceitavel('uniforme: macacão preto'), 'macacão é outra palavra inteira');
select ok(privado.texto_aceitavel('veadeiro'), 'veadeiro é outra palavra inteira');

-- Textos de vaga e requisitos legítimos
select ok(privado.texto_aceitavel('pagamento retardado em 5 dias'), 'FALSO POSITIVO da lista antiga: retardado é particípio comum');
select ok(privado.texto_aceitavel('o evento foi retardado'), 'FALSO POSITIVO da lista antiga: retardado é particípio comum');
select ok(privado.texto_aceitavel('frango crioulo'), 'FALSO POSITIVO da lista antiga: crioulo é cardápio');
select ok(privado.texto_aceitavel('cavalo crioulo'), 'FALSO POSITIVO da lista antiga: crioulo é pecuária');
select ok(privado.texto_aceitavel('pix após o turno'), 'pix legítimo');
select ok(privado.texto_aceitavel('pagamento via pix no fim do turno'), 'pagamento pix legítimo');
select ok(privado.texto_aceitavel('sem custo de inscrição para o profissional'), 'sem custo legítimo');
select ok(privado.texto_aceitavel('apenas mulheres no camarim'), 'requisito legítimo de camarim');
select ok(privado.texto_aceitavel('camisa branca e calça preta'), 'traje legítimo');
select ok(privado.texto_aceitavel('sapato apenas brancos'), 'traje com sapato branco legítimo');
select ok(privado.texto_aceitavel('tênis só brancos'), 'traje legítimo');
select ok(privado.texto_aceitavel('cor branca da parede'), 'descrição de serviço legítima');
select ok(privado.texto_aceitavel('travesti é identidade'), 'identidade nunca bloqueada');
select ok(privado.texto_aceitavel('gay, lésbica e bi são identidades'), 'identidade nunca bloqueada');

-- Grafia burlada passa por desenho (F3)
select ok(privado.texto_aceitavel('m3rda'), 'grafia burlada passa por desenho (F3)');
select ok(privado.texto_aceitavel('v i a d o'), 'espaçamento burlado passa por desenho (F3)');
select ok(privado.texto_aceitavel('viaaado'), 'letra repetida passa por desenho (F3)');
select ok(privado.texto_aceitavel('p*ta'), 'caractere especial passa por desenho (F3)');

-- ── Corpus da Seção 7: Casos que devem ser RECUSADOS ────────────────────────
select ok(not privado.texto_aceitavel('Você é um VIADO!'), 'recusa termo de ódio');
select ok(not privado.texto_aceitavel('foda-se'), 'recusa variação com hífen');
select ok(not privado.texto_aceitavel('FILHO DA PUTA'), 'recusa em maiúsculas');
select ok(not privado.texto_aceitavel('Procura-se GAROTO de programa'), 'recusa fora de escopo masculino');
select ok(not privado.texto_aceitavel('sugar daddy procura'), 'recusa fora de escopo');
select ok(not privado.texto_aceitavel('Pix antecipado de R$ 50'), 'recusa golpe/fraude');
select ok(not privado.texto_aceitavel('taxa de inscrição de R$ 30'), 'recusa golpe/fraude');
select ok(not privado.texto_aceitavel('isso é veado'), 'recusa termo de ódio');
select ok(not privado.texto_aceitavel('macumbeiro'), 'recusa intolerância religiosa');
select ok(not privado.texto_aceitavel('fuck you'), 'recusa inglês');
select ok(not privado.texto_aceitavel('retardado mental'), 'o uso ofensivo continua recusado');
select ok(not privado.texto_aceitavel('olha o macaco'), 'recusa termo de ódio');
select ok(not privado.texto_aceitavel('Não aceitamos negros'), 'recusa exigência discriminatória racial');
select ok(not privado.texto_aceitavel('apenas pessoas brancas'), 'recusa exigência discriminatória racial');
select ok(not privado.texto_aceitavel('onlyfans e nudes'), 'recusa fora de escopo');

-- ── Falsos positivos conhecidos e aceitos (RECUSADOS) ────────────────────────
select ok(not privado.texto_aceitavel('macaco hidráulico'), 'FALSO POSITIVO CONHECIDO E ACEITO: macaco fica na lista');
select ok(not privado.texto_aceitavel('Córrego do Veado'), 'FALSO POSITIVO CONHECIDO E ACEITO: veado fica na lista');
select ok(not privado.texto_aceitavel('puta oportunidade'), 'FALSO POSITIVO CONHECIDO E ACEITO: puta fica na lista');
select ok(not privado.texto_aceitavel('sem taxa de inscrição'), 'FALSO POSITIVO CONHECIDO E ACEITO: taxa de inscricao fica na lista');

-- ── criar_conta: o primeiro ponto de uso ─────────────────────────────────────

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

select pg_temp.autenticar('c1000000-0000-4000-8000-000000000001','filtro-a@t.test');
select pg_temp.autenticar('c1000000-0000-4000-8000-000000000002','filtro-b@t.test');

select throws_ok(
  $$ select pg_temp.como('c1000000-0000-4000-8000-000000000001',
       $c$ select public.criar_conta('profissional','Ana Caralho','+5561999990301','1995-01-01','2026-09-22') $c$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "nome", "hint" : null}',
  'diretriz 1.2: nome com termo da lista sai como campo_invalido, com o campo no details');

select throws_ok(
  $$ select pg_temp.como('c1000000-0000-4000-8000-000000000001',
       $c$ select public.criar_conta('profissional',' ','+5561999990301','1995-01-01','2026-09-22') $c$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "nome", "hint" : null}',
  'nome ausente continua sendo campo_obrigatorio, e não campo_invalido');

select is(
  (select pg_temp.como('c1000000-0000-4000-8000-000000000002',
     $c$ select public.criar_conta('profissional','Ana Cunha','+5561999990302','1995-01-01','2026-09-22') $c$) ->> 'nome'),
  'Ana Cunha',
  'e o sobrenome que contém parte de um termo cadastra normalmente');

select * from finish();
rollback;
