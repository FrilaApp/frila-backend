-- Finalidade declarada por tabela e por coluna sensível (RNF08, RN15).
--
-- Não é documentação: é o registro de por que cada dado pessoal existe. Coluna sem
-- finalidade declarada é coluna que ninguém sabe se pode apagar.

comment on table public.usuario is
  'Conta de acesso. Um perfil por conta, fixo no cadastro (RN25). A exclusão anonimiza em vez de apagar (RF25), porque turno e avaliação pertencem também à contraparte.';
comment on column public.usuario.id is
  'Id da conta no Supabase Auth. Sem FK para auth.users: a exclusão apaga o registro de autenticação e mantém esta linha anonimizada.';
comment on column public.usuario.telefone is
  'Contato do turno. Sai apenas pela RPC contato_do_turno, depois da confirmação e até 7 dias após o fim (RN10). Base legal: execução do contrato, LGPD art. 7º, V.';
comment on column public.usuario.email is
  'Identifica a conta na entrada por código. Único entre contas não anonimizadas.';
comment on column public.usuario.nascimento is
  'Verifica a maioridade na escrita (RN20). Substitui um booleano enviado pela tela, que não verifica nada.';

comment on table public.profissional is
  'Perfil de quem trabalha. As colunas de reputação são cache; a verdade está em posicao, turno e avaliacao.';
comment on column public.profissional.ponto_base is
  'Existe só para calcular a distância de elegibilidade (RN05). Nenhuma leitura o mostra a outra pessoa. Não há tabela de posições sucessivas, e não deve haver.';
comment on column public.profissional.taxa_comparecimento is
  'Nula até existir histórico: RF16 exige que perfil sem histórico apareça como sem histórico, não como nota zero.';
comment on column public.profissional.aval_total is
  'O denominador de RN08. Guardar só o percentual tornaria "7 de 7" irrecuperável.';

comment on table public.estabelecimento is
  'Quem contrata. Tem reputação própria porque RN07 manda avaliar nos dois sentidos.';
comment on column public.estabelecimento.documento is
  'CNPJ ou CPF, só dígitos. Aceita CPF porque serviço doméstico também contrata pelo Frila. Não sai em nenhuma leitura pública.';
comment on column public.estabelecimento.tipo is
  'Serve para leitura e filtro, nunca para barrar ninguém: a plataforma é horizontal.';

comment on table public.membro_estabelecimento is
  'Liga a conta de contratante ao estabelecimento. Separado de usuario para o histórico do estabelecimento sobreviver à troca de responsável (RF21).';
comment on table public.equipe_confianca is
  'O profissional da equipe recebe as vagas do estabelecimento mesmo além de 15 km (RF18). Não muda ordem — não existe ordem (RN06).';

comment on table public.funcao is
  'Catálogo fechado. Função nunca é texto livre, para a elegibilidade de RN05 não virar busca por aproximação.';
comment on table public.disponibilidade is
  'Grade semanal, única fonte de disponibilidade. hora_fim pode ser menor que hora_inicio: 18:00–02:00 é a janela mais comum do setor.';

comment on table public.vaga is
  'O turno publicado. As colunas NOT NULL são RN02 escrita em SQL: vaga sem função, horário, endereço, valor, o que está incluso ou quem recebe no local não existe.';
comment on column public.vaga.valor_centavos is
  'Centavos inteiros (RN18). É o valor integral que o profissional recebe: o Frila não desconta comissão (RN01).';
comment on column public.vaga.alerta_antecedencia is
  'Janela crítica: com a posição ainda vaga a esta distância do início, o contratante é alertado (RF20). Padrão de 3 horas, ajustável na publicação.';
comment on column public.vaga.chave_cliente is
  'Idempotência da publicação: o reenvio com a mesma chave devolve a vaga já gravada.';

comment on table public.posicao is
  'Uma unidade de trabalho da vaga. Quatro estados e nenhum a mais: cada estado extra é um caminho a mais pelo qual RN19 pode falhar.';
comment on column public.posicao.profissional_id is
  'Mantido depois do cancelamento: diz de quem foi a falta e quem cancelou (RN12).';
comment on column public.posicao.falta is
  'Marcada quando o profissional cancela com menos de 24 h do início, ou quando o contratante reabre por atraso. Cancelamento com mais de 24 h não marca nada.';

comment on table public.turno is
  'A execução. Guarda a distância medida no toque, nunca a coordenada (RN22).';
comment on column public.turno.checkin_distancia_m is
  'Distância até o endereço da vaga, calculada no aparelho no momento do toque. A coordenada não trafega e não é gravada.';
comment on column public.turno.verificacao is
  'Libera a avaliação e entra na taxa de comparecimento. Só vira verificado com prova; nenhuma tela consegue marcá-la sem ela.';
comment on column public.turno.valor_acordado_centavos is
  'Copiado da vaga na confirmação. Registro que muda sozinho não vale nada (RN11).';

comment on table public.avaliacao is
  'Binária e bidirecional (RN07). Não existe caminho no esquema que aceite nota de 1 a 5.';
comment on table public.bloqueio is
  'Vale nos dois sentidos e é imediato, sem depender da Equipe Frila (RF26). Só quem bloqueou lê: saber quem o bloqueou pode pôr alguém em risco.';
comment on table public.ocorrencia is
  'Cancelamento, suspensão, contestação, suporte, denúncia e revisão de despacho. Guarda referência e motivo, nunca cópia da linha do titular (RN15).';

comment on table public.despacho is
  'Quem foi considerado para qual vaga. Não é lido pelo estabelecimento: saber quem foi notificado revelaria quem está perto e disponível naquele horário.';
comment on table public.notificacao is
  'Qual push saiu, quando e se chegou. É a unidade que RNF02 mede.';
comment on table public.dispositivo is
  'Token de push por aparelho. Vai junto na exclusão de conta (RN15).';
