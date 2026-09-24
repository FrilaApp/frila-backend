-- As tabelas da v1 existem, com os nomes de coluna da Modelagem.
--
-- Este arquivo não testa comportamento: testa que o contrato entre a Modelagem e o
-- esquema não se desfez em silêncio. Renomear uma coluna "para ficar melhor" quebra os
-- três clientes, e é o tipo de mudança que passa numa revisão apressada.

begin;
select plan(37);

-- ── As dezoito tabelas marcadas v1, mais `evento` ──────────────────────────────
--
-- `evento` está como "Depois" na tabela v1/v2 da Modelagem: só a escala em lote (RF19)
-- agrupa vagas, e isso é pós-MVP. A tabela entra agora porque `vaga.evento_id` aponta
-- para ela, e uma chave estrangeira pendurada no ar seria pior que uma tabela vazia.
select has_table('public', 'usuario',                'usuario existe');
select has_table('public', 'profissional',           'profissional existe');
select has_table('public', 'estabelecimento',        'estabelecimento existe');
select has_table('public', 'membro_estabelecimento', 'membro_estabelecimento existe');
select has_table('public', 'equipe_confianca',       'equipe_confianca existe');
select has_table('public', 'funcao',                 'funcao existe');
select has_table('public', 'profissional_funcao',    'profissional_funcao existe');
select has_table('public', 'disponibilidade',        'disponibilidade existe');
select has_table('public', 'evento',                 'evento existe');
select has_table('public', 'vaga',                   'vaga existe');
select has_table('public', 'posicao',                'posicao existe');
select has_table('public', 'dispositivo',            'dispositivo existe');
select has_table('public', 'notificacao',            'notificacao existe');
select has_table('public', 'despacho',               'despacho existe');
select has_table('public', 'candidatura',            'candidatura existe');
select has_table('public', 'turno',                  'turno existe');
select has_table('public', 'avaliacao',              'avaliacao existe');
select has_table('public', 'bloqueio',               'bloqueio existe');
select has_table('public', 'ocorrencia',             'ocorrencia existe');

-- ── Colunas cujo nome o contrato promete ao cliente ────────────────────────────
-- `publicado_por` não está na Modelagem: nasceu com `publicar_vaga`, porque um
-- estabelecimento tem vários membros e RF04 pergunta quem publicou. Divergência
-- registrada em docs/ESTADO.md.
select columns_are('public', 'vaga', array[
  'id','estabelecimento_id','evento_id','funcao_id','inicio_em','fim_em','local','ponto',
  'valor_centavos','posicoes','inclui_refeicao','inclui_transporte','exige_material_proprio',
  'responsavel_local','traje','participa_rateio','observacoes','modo','alerta_antecedencia',
  'estado','publicado_em','chave_cliente','publicado_por'
], 'vaga tem exatamente as colunas da Modelagem, mais quem publicou');

select columns_are('public', 'turno', array[
  'id','posicao_id','checkin_em','checkin_tipo','checkin_distancia_m','checkin_confirmado_em',
  'checkout_em','checkout_distancia_m','verificacao','valor_acordado_centavos'
], 'turno tem exatamente as colunas da Modelagem');

select columns_are('public', 'posicao', array[
  'id','vaga_id','estado','profissional_id','confirmado_em','falta','inicio_em','fim_em'
], 'posicao tem exatamente as colunas da Modelagem');

-- `termos_versao` e `termos_aceite_em` não estão na Modelagem: vieram do cartão da
-- entrada por código, que manda gravar o aceite. Guardar "aceitou" como booleano não
-- responde a pergunta que a LGPD e a App Store fazem, que é *o que* e *quando*.
-- `demonstracao` também não está na Modelagem: é a marca da conta de revisão da App
-- Store (diretrizes 2.1 e 4.2), e existe para que as duas populações dividam o banco
-- sem se enxergar. Divergência registrada em docs/ESTADO.md.
select columns_are('public', 'usuario', array[
  'id','perfil','nome','telefone','email','nascimento','estado','criado_em','anonimizado_em',
  'termos_versao','termos_aceite_em','demonstracao'
], 'usuario tem exatamente as colunas da Modelagem, mais o aceite dos termos e a marca de demonstração');

-- `perfil` repetido aqui é RN25: a coluna existe para a chave estrangeira composta
-- apontar para o par (id, perfil) de usuario. Remover "porque é redundante" desliga a
-- última linha de defesa da regra.
select columns_are('public', 'profissional', array[
  'id','usuario_id','perfil','ponto_base','taxa_comparecimento','turnos_realizados',
  'aval_positivas','aval_total'
], 'profissional tem exatamente as colunas da Modelagem');

select columns_are('public', 'candidatura', array[
  'id','posicao_id','profissional_id','criada_em','estado'
], 'candidatura tem exatamente as colunas da Modelagem');

select columns_are('public', 'avaliacao', array[
  'id','turno_id','autor_id','alvo_tipo','alvo_id','resposta','criada_em'
], 'avaliacao tem exatamente as colunas da Modelagem');

select columns_are('public', 'estabelecimento', array[
  'id','nome','documento','tipo','endereco','ponto','criado_em','aval_positivas','aval_total'
], 'estabelecimento tem exatamente as colunas da Modelagem');

-- ── O que NÃO pode existir ─────────────────────────────────────────────────────
--
-- A ausência é decisão, não lacuna. Um marketplace normalmente teria estas tabelas; a
-- ausência delas é o que honra RN01, RN07, RN09 e RN10 no lugar onde a regra não se
-- perde: não há onde representar o proibido.
select hasnt_table('public', 'pagamento',  'RN09: o Frila registra o valor, não custodia dinheiro');
select hasnt_table('public', 'carteira',   'RN09: sem carteira');
select hasnt_table('public', 'comissao',   'RN01: não há onde descontar do valor do turno');
select hasnt_table('public', 'mensagem',   'RN10: o contato é por WhatsApp ou e-mail, não por chat interno');
select hasnt_table('public', 'nota',       'RN07: avaliação é binária, nunca nota de 1 a 5');
select hasnt_table('public', 'comentario', 'RN07: sem comentário aberto');

-- Rastreamento contínuo está no escopo não contemplado, com a marca mais dura do
-- documento. O check-in guarda a distância do toque, e nada mais.
select hasnt_column('public', 'turno', 'checkin_latitude',
  'RN22: a coordenada do profissional não trafega e não é gravada');
select hasnt_column('public', 'turno', 'checkin_longitude',
  'RN22: a coordenada do profissional não trafega e não é gravada');

-- RN06: notificação e posição na lista não podem ser compradas. O jeito de garantir é
-- não existir coluna onde guardar o que foi comprado.
select hasnt_column('public', 'vaga', 'patrocinada',
  'RN06: não há coluna de patrocínio');
select hasnt_column('public', 'vaga', 'prioridade',
  'RN06: não há coluna de prioridade');

select * from finish();
rollback;
