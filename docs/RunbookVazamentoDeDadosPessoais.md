# Runbook: vazamento de dado pessoal e comunicação à ANPD e ao titular

O que fazer quando dado pessoal de usuários do Frila (profissionais e estabelecimentos) pode ter sido exposto, acessado ou alterado por quem não devia. O Frila trata dado pessoal em produção; a LGPD (Lei 13.709/2018, art. 48) exige comunicação de incidente de segurança. Este runbook organiza a **resposta técnica** e deixa explícito o que depende de **parecer jurídico**.

> **Este documento não é parecer jurídico.** Todo prazo e conteúdo de comunicação abaixo vem marcado com a fonte ou com **A CONFIRMAR com advogado**. Não use este texto como única base para decidir se comunica ou não.

Convenção (a mesma de `docs/RunbookRotacaoDeSegredos.md`): **LIDO** é texto do repositório; **DEDUZIDO** é raciocínio; **EXECUTADO** marca o SQL rodado em banco local descartável, com data e base; **NAO EXECUTAVEL AQUI** marca o que depende de Prod ou de credencial; **A DEFINIR (Caue)** é fato que só o Cauê sabe.

**Execução do SQL (25/11/2026).** Os 10 blocos SQL deste documento foram executados em 25/11/2026 num Postgres local descartável (`supabase db start` sobre a `develop` em `6225a77`: migrações do zero, `seed.sql` e `cenarios.sql`), cada um dentro de `begin read only`; os 10 rodam sem erro (os três que usam `:'de'` e `:'ate'` rodam com `psql -v`). **Não executável fora do Prod:** a contagem real de contas e de acessos, `auth.users` real, `privado.registro_acesso` real e `public.pedido_de_exclusao` real. O banco local devolve dado sintético da semente ou vazio.

---

## 1. Sintoma

Abra este runbook ao saber ou suspeitar de qualquer um destes:

- Segredo exposto em commit, log, PR, print ou conversa (`service_role`, chave FCM, SMTP, `agendador_secret`; `AGENTS.md`, "Nunca"). O repositório é **público**.
- Acesso ou alteração suspeita no banco, no Auth ou no Storage; conta de sócio comprometida; máquina com credencial de Prod perdida ou roubada.
- Dado pessoal em lugar errado: relato de usuário em print fora do ambiente seguro (vedado por `supabase/operacao/equipe-frila.md`, seção 2), e-mail ou aviso com dado pessoal enviado a destinatário errado, dado pessoal em log ou fixture (`AGENTS.md`).
- Foto ou mídia acessível por link indevido (a leitura de foto passa pela Edge Function `ler-midia`, que devolve link temporário: `supabase/migrations/20261114003000_foto_leitura_por_link_temporario.sql`).
- Aviso de terceiro (usuário, pesquisador, imprensa) dizendo que viu dado que não devia.

Na dúvida se é incidente: **trate como incidente até alguém decidir que não é**. Abrir o runbook não obriga a comunicar à ANPD; deixar de abri-lo pode custar prazo.

### O relógio

| O quê | Prazo | Fonte |
|---|---|---|
| Comunicar o incidente à ANPD | **3 dias úteis**, contados do conhecimento pelo controlador de que o incidente afetou dados pessoais (art. 6º e § 1º da Resolução CD/ANPD nº 15, de 24/04/2024) | Página oficial da ANPD, "Comunicação de incidente de segurança": <https://www.gov.br/anpd/pt-br/canais_atendimento/agente-de-tratamento/comunicado-de-incidente-de-seguranca-cis> |
| Comunicar o(s) titular(es) | **3 dias úteis**, mesmo critério (art. 9º da mesma Resolução) | idem |
| Complementar as informações à ANPD | até 20 dias úteis da comunicação inicial (art. 6º, § 3º) | idem |

Como estes números chegaram aqui: busca na web em 16/11/2026 que citou a página da ANPD e o texto da Resolução; a leitura direta da página da ANPD deu timeout nesta revisão, então **o texto literal da Resolução não foi conferido por mim na fonte primária**. A mesma busca mostrou fontes públicas que descrevem o ponto de partida da contagem de forma diferente (conhecimento de que o incidente "possa acarretar risco ou dano relevante" contra "afetou dados pessoais"). **A CONFIRMAR com advogado**: o prazo, o ponto de partida da contagem, se o incidente concreto exige comunicação (risco ou dano relevante aos titulares), o conteúdo mínimo da comunicação, e se o Frila é controlador de todos os dados envolvidos. A premissa do repositório é que a controladora é a empresa (`supabase/migrations/20261108110000_lgpd_registro_acessos_borda.sql`, comentário de `privado.registro_acesso`).

**Anote a hora em que o primeiro sócio soube.** Essa hora decide a contagem.

---

## 2. Diagnóstico (somente leitura)

Objetivo: descobrir **quais dados**, **de quantos titulares** e **em que janela**, sem ler dado pessoal. Todos os SQL abaixo contam; nenhum devolve nome, e-mail, telefone, IP, token ou identificador de usuário (RN15; `docs/NotificacaoDaEquipe.md` proíbe dado pessoal em aviso para as caixas dos sócios). Rode em sessão com `default_transaction_read_only = on`, **em Prod por humano autorizado** (`docs/ChecagemDiariaProd.md`, seção 1).

Todos os SQL abaixo: **EXECUTADO em 25/11/2026 no banco local descartável** (resultado em cada bloco). As colunas vêm das migrações citadas.

**2.1 Quantas contas existem, por perfil e estado (universo máximo).**
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 3 linhas (dado da semente). `public.usuario`: `20260922150100_identidade.sql:17-29`; `estado` em `ativa`, `suspensa`, `anonimizada`.

```sql
select perfil,
       estado,
       count(*) as contas
  from public.usuario
 group by perfil, estado
 order by perfil, estado;
```

**2.2 Quais categorias de dado pessoal cadastral estão preenchidas (contagem por campo).**
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 1 linha (18 contas sintéticas, todas com nome, e-mail, telefone e nascimento).

```sql
select count(*) as contas,
       count(*) filter (where nome is not null) as com_nome,
       count(*) filter (where email is not null) as com_email,
       count(*) filter (where telefone is not null) as com_telefone,
       count(*) filter (where nascimento is not null) as com_nascimento
  from public.usuario
 where estado <> 'anonimizada';
```

Conta `anonimizada` tem nome `Conta encerrada` e e-mail e telefone nulos (`docs/RUNBOOK-INCIDENTES.md`, seção 4): **não dá para avisar essa pessoa por e-mail**. Registre isso na comunicação à ANPD.

**2.3 Contas criadas ou autenticadas na janela suspeita.** Troque `:'de'` e `:'ate'` pelos limites da janela (psql: `-v de="2026-11-01 00:00+00" -v ate="2026-11-05 00:00+00"`).
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): os dois blocos rodam com `-v de="2026-11-01 00:00:00+00" -v ate="2026-11-25 00:00:00+00"`; cada um devolve 1 linha com 0. `auth.users.last_sign_in_at` é coluna do Supabase Auth, não das migrações do repositório, e existe.

```sql
select count(*) as contas_com_login_na_janela
  from auth.users a
 where a.last_sign_in_at >= :'de'::timestamptz
   and a.last_sign_in_at <  :'ate'::timestamptz;
```

```sql
select count(*) as contas_criadas_ate_o_fim_da_janela
  from public.usuario u
 where u.criado_em < :'ate'::timestamptz
   and u.estado <> 'anonimizada';
```

**2.4 Aparelhos registrados (o token FCM é dado do aparelho, não é lido aqui).**
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 2 linhas (`ios` 2, `android` 2). `public.dispositivo`: `20260922150500_despacho_turno_ocorrencia.sql:14-20`.

```sql
select plataforma,
       count(*) as aparelhos
  from public.dispositivo
 group by plataforma
 order by plataforma;
```

**2.5 A coleta de registro de acessos está ligada? (quem acessou, de que IP, quando).** O registro de acessos (Marco Civil) guarda conta, IP e hora do primeiro uso por hora, só para `service_role`, por 6 meses, e **nasce desligado** (`20261108110000_lgpd_registro_acessos_borda.sql`, comentários de `privado.registro_acesso` e `privado.registro_acesso_coleta`). Se estava desligado na janela do incidente, não há esse rastro.
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 1 linha (`ligada` = f, a coleta vem desligada no banco local).

```sql
select ligada,
       alterada_em,
       consumido_em
  from privado.registro_acesso_coleta;
```

Se ligada, a contagem de contas distintas com registro na janela (sem listar conta nem IP):
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda com `-v de=... -v ate=...`; 1 linha (0 registros, com a coleta desligada).

```sql
select count(distinct r.usuario_id) as contas_com_acesso_registrado,
       count(*) as registros,
       min(r.acessado_em) as primeiro,
       max(r.acessado_em) as ultimo
  from privado.registro_acesso r
 where r.acessado_em >= :'de'::timestamptz
   and r.acessado_em <  :'ate'::timestamptz;
```

Estado da coleta em Prod: **NAO MEDIDO**.

**2.6 Falhas e alertas recentes (pode mostrar o início do problema).**
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 0 linhas, por falta de dado. `privado.falha_execucao`: `20260930230000_monitoramento_e_alertas.sql:20-28`. `privado.alerta_emitido` é citada em `docs/ChecagemDiariaProd.md`, bloco 1; as colunas **não foram conferidas** nas migrações por esta revisão, então este runbook não consulta essa tabela.

```sql
select origem,
       codigo,
       date_trunc('day', criada_em) as dia,
       count(*) as total
  from privado.falha_execucao
 where criada_em > now() - interval '30 days'
 group by origem, codigo, date_trunc('day', criada_em)
 order by dia desc, total desc;
```

**2.7 Pedidos de exclusão já concluídos (esses titulares já estão anonimizados).**
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 0 linhas, por falta de dado (nenhum pedido de exclusão). `public.pedido_de_exclusao`: `20260930090000_rastro_do_pedido_de_exclusao.sql:35-49`.

```sql
select estado,
       count(*) as pedidos,
       min(pedido_em) as primeiro,
       max(pedido_em) as ultimo
  from public.pedido_de_exclusao
 group by estado
 order by estado;
```

**2.8 Há verificação de identidade (documento) em risco?** A RN14 ainda não é chamada pelo app (`docs/ESTADO.md`, 08/11/2026: "0 verificações de identidade em toda a história"). Confirme que continua zero:
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 1 linha (`verificacoes` = 0). `privado.verificacao_identidade`: `docs/VerificacaoDeIdentidade.md`, seção 2.

```sql
select count(*) as verificacoes
  from privado.verificacao_identidade;
```

Foto de perfil: a chave de recurso `foto_de_perfil` estava **desligada** no Prod em 08/11/2026 (`docs/ESTADO.md`); depois disso, NAO MEDIDO.

**O que o diagnóstico não mostra:** o que o invasor **leu**. O banco não tem registro de leitura por linha. A resposta de "quais dados foram vistos" vem do que o segredo ou a conta comprometida **podia** acessar (DEDUZIDO), dos logs do Supabase (retenção e acesso no painel: NAO MEDIDO) e do registro de acessos, se estava ligado. Em dúvida, o universo da seção 2.1 é o limite superior.

---

## 3. Mitigação

Ordem. O relógio da seção 1 corre durante todos estes passos.

1. **Abra o canal do incidente e registre a hora zero.** Quem atende está em `docs/RunbookPlantao.md`. O aviso aos sócios **não leva dado pessoal** (`docs/NotificacaoDaEquipe.md`, seção 4: "Nada de dado pessoal no corpo").
2. **Contenha.**
   - Segredo exposto: **troque a chave antes de limpar o histórico** (`AGENTS.md`). Passo a passo por segredo: `docs/RunbookRotacaoDeSegredos.md`.
   - Conta de usuário usada para abuso: suspensão com `supabase/operacao/suspender-conta.sql` (RN13; assina a ocorrência um operador da equipe).
   - Recurso que vaza (por exemplo foto): desligue a chave de recurso correspondente, se existir para o app em produção (`configuracao_do_app`). Como desligar em Prod hoje: **NAO MEDIDO** (os arquivos de operação citam migração e `update`; confirme o procedimento antes). Para exigir app novo: `supabase/operacao/subir-versao-minima.md`.
   - Não apague nada que sirva de prova (logs, e-mails, o commit com o segredo) antes de copiar. Limpeza de histórico do Git vem depois e é decisão registrada.
3. **Preserve evidência.** Exporte os logs relevantes das Edge Functions e do Auth antes que expirem (retenção: NAO MEDIDO). O registro de acessos dura 6 meses (`20261108110000...sql`). Guarde fora do repositório, em local de acesso restrito.
4. **Dimensione** com a seção 2: categorias de dado, número de titulares (limite superior e estimativa), janela, se há dado de menor (o banco guarda `nascimento`; consulta de menores de idade fora deste runbook: **A DEFINIR (Caue)**, junto do advogado).
5. **Avalie o risco ao titular** com o advogado (**A DEFINIR (Caue)**: quem). A decisão "comunica ou não à ANPD e aos titulares" é do Cauê com o parecer; registre por escrito a decisão **e o motivo**, inclusive se for "não comunicar".
6. **Comunique, se a decisão for comunicar.**
   - **À ANPD:** pelo canal oficial da página indicada na seção 1. Preencha com os números das seções 2.1 a 2.7. Quem assina como controlador e quem é o encarregado: **A DEFINIR (Caue)**.
   - **Aos titulares:** por e-mail (`suporte@frilabr.com` é o canal do titular: `supabase/operacao/equipe-frila.md`, seção 1). **Push não leva conteúdo de incidente** (RN15: nada de dado pessoal em aviso). Contas `anonimizada` não têm e-mail (seção 2.2). O conteúdo mínimo exigido pela Resolução: **A CONFIRMAR com advogado**. Roteiro de texto, para o advogado revisar: o que aconteceu e quando; quais categorias de dado; qual o risco; o que o Frila já fez; o que o titular pode fazer; como falar com o encarregado. Não invente número nem causa no texto: use só o que está no registro do incidente.
   - Nome do encarregado e canal: o modelo de resposta ao titular assina "Encarregado de Dados (DPO) / Equipe Frila" (`supabase/operacao/equipe-frila.md`, Modelo D) sem nome de pessoa. **A DEFINIR (Caue)**: quem é o encarregado nomeado.
7. **Depois de resolvido:** registro do incidente (quem soube, quando, o que foi feito, quem decidiu); correção da causa (PR com teste); revisão de `AGENTS.md` e dos runbooks se o caminho falhou; avisar o iOS se a correção exigir versão mínima nova.

Não existe hoje, no repositório, modelo de registro de incidente nem formulário pré-preenchido para a ANPD (buscado em `docs/` e `supabase/operacao/`).

---

## 4. Quem age

- **Quem descobre:** avisa os sócios na hora, **sem esperar certeza**, e anota a hora (`AGENTS.md`: "avise os sócios e troque a chave").
- **Contenção técnica:** sócio de plantão com acesso ao Supabase e ao GitHub (`docs/RunbookPlantao.md`). **A DEFINIR (Caue)**: quem tem acesso a quê.
- **Consultas em Prod:** humano autorizado.
- **Agente de IA:** pode ajudar a redigir o registro e a ler logs que um humano forneça **sem dado pessoal**; não acessa Prod e não recebe segredo (`AGENTS.md`).
- **Comunicação à ANPD e aos titulares:** o encarregado. **A DEFINIR (Caue)**: nome e contato do encarregado.
- **Jurídico:** **A DEFINIR (Caue)**: quem é o advogado de referência e como acioná-lo fora do horário comercial.

## 5. Quem decide

- **Comunicar ou não, e o texto:** Cauê, com parecer jurídico. **A DEFINIR (Caue)**: o que acontece se o Cauê estiver indisponível dentro dos 3 dias úteis.
- **Desligar recurso ou tirar o produto do ar para conter:** Cauê, ou o sócio de plantão se não houver tempo de consultá-lo e o risco for imediato (**A DEFINIR (Caue)**: confirmar esta regra).
- **Rotação de segredo por incidente:** qualquer sócio inicia; `docs/RunbookRotacaoDeSegredos.md`, seção 5.
