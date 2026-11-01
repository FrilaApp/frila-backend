# Painel de Métricas do Piloto

Documentação dos scripts de medição de requisitos não-funcionais de despacho e push (RNF02 e RNF03) e do gerador da página estática para a leitura semanal do piloto do Frila.

Cartões: `6ab26a53` (Brief B-005, T-0017, T-0020).

---

## 1. Como rodar os scripts

### 1.1 Medição dos Requisitos Não-Funcionais (`scripts/medir-rnf.sh`)

O script `scripts/medir-rnf.sh` afere o comportamento dos despachos no banco local:
- **tempo de despachar_vaga (parcial)**: mede só o tempo de `despachar_vaga`; pula a fila, o cron e o FCM; NÃO é o RNF03 de ponta a ponta (meta: $p95 \le 30\text{ s}$).
- **RNF02**: Do despacho até o aceite da notificação pelo provedor de push (meta: $p95 \le 60\text{ s}$). **Não é mensurável localmente**, pois depende de envio real aos provedores externos (Google FCM / Apple APNs) e aparelhos físicos.

#### Execução:
Caso esteja trabalhando com a orquestração compartilhada do time, obtenha a vaga da fila de banco antes de executar e solte-a ao terminar:
```bash
# Obter vaga do banco local (se aplicável)
fila.sh pegar banco <seu-nome>

# Executa 5 repetições (padrão)
./scripts/medir-rnf.sh

# Executa N repetições personalizadas
./scripts/medir-rnf.sh 10
./scripts/medir-rnf.sh -n 20

# Personalizar limite de tempo parcial via variável de ambiente (padrão: 30.0 s)
META_RNF03=30.0 ./scripts/medir-rnf.sh

# Liberar vaga do banco local ao terminar
fila.sh soltar banco <seu-nome>
```

#### Comportamento e Saída:
1. Valida a âncora de referência em `public.vaga` gerada por `supabase/cenarios.sql`. Se ausente ou se estiver no passado, aborta solicitando resemeio com `cenarios.sql`.
2. Cria vagas de teste isoladas (com prefixo `e0000000-0000-4000-8000-`) no banco de teste, utilizando a âncora de função e horário de `supabase/cenarios.sql` para garantir elegibilidade. Se $N < 5$, exibe aviso no terminal de que $p95$ aproxima-se do valor máximo observado.
3. Dispara `privado.despachar_vaga` diretamente para cada vaga e afere o tempo de execução da função. Importante: mede só o tempo de `despachar_vaga`; pula a fila, o cron e o FCM; NÃO é o RNF03 de ponta a ponta.
4. Imprime tabela das amostras coletadas, consulta consolidada de `supabase/consultas/rnf02_rnf03_push.sql` (filtrando fora as notificações temporárias de teste) e percentis $p50$ e $p95$.
5. Exibe o requisito RNF02 com status informativo `NÃO MENSURÁVEL LOCALMENTE / NÃO EXECUTADO`.
6. Sai com código `0` se a medição parcial de despacho cumprir a meta ($p95 \le \text{META\_RNF03}$), ou código `1` se $p95$ exceder a meta ou se nenhuma amostra for encontrada.
7. Limpa automaticamente todos os dados de teste (incluindo `privado.auditoria_ciclo` e `privado.texto_da_vaga_ocultado`) no `trap EXIT`. Nunca realiza `db reset`.
8. Contém trava de segurança fail-closed: conexões a hosts remotos via `DATABASE_URL` são rejeitadas a menos que `EU_SEI_QUE_E_PRODUCAO=1` seja explicitamente fornecida.

---

### 1.2 Gerador do Painel Semanal (`scripts/gerar-painel.sh`)

O script `scripts/gerar-painel.sh` lê as 7 views do schema `metrica.*` via `psql` e gera um documento HTML único, moderno e totalmente autocontido (CSS embutido, zero JavaScript externo).

#### Execução:
```bash
# Imprime o HTML na saída padrão
./scripts/gerar-painel.sh

# Salva diretamente em arquivo temporário
./scripts/gerar-painel.sh -o /tmp/painel-piloto.html

# Validação contratual de schema e colunas (usado na CI)
./scripts/gerar-painel.sh --teste -o /tmp/painel-piloto.html
```

> **Atenção:** Arquivos HTML gerados para inspeção ou teste devem ser salvos em diretórios efêmeros como `/tmp/painel-piloto.html`, nunca comitados na pasta `docs/`.

O script respeita a variável de ambiente `DATABASE_URL` se estiver definida; caso contrário, conecta-se automaticamente ao contêiner local `supabase_db_frila-backend` ou à porta padrão `54322`.

---

### 1.3 Consulta Rápida no Terminal (`scripts/funil.sh`)

Para visualização rápida textual ou estruturada em JSON no terminal:
```bash
./scripts/funil.sh                    # Visão geral, por estabelecimento e por dia
./scripts/funil.sh --geral            # Resumo global
./scripts/funil.sh --estabelecimento  # Segmentado por estabelecimento
./scripts/funil.sh --dia              # Segmentado por dia
./scripts/funil.sh --json             # Objeto JSON estruturado
```

---

## 2. Métricas Geradas e Views Existentes

Todas as métricas são lidas estritamente do schema isolado `metrica.*` (com privilégio de leitura concedido exclusivamente a `service_role`, excluindo contas marcadas como demonstração e contas da equipe interna):

| View | Descrição | Colunas |
|---|---|---|
| `metrica.north_star_semanal` | Turnos concluídos (`posicao.estado = 'cumprida'`) com presença verificada (`turno.verificacao = 'verificado'`) agrupados por semana (início na segunda-feira). | `semana_inicio`, `turnos_concluidos_com_presenca_verificada` |
| `metrica.funil_geral` | Resumo consolidado do piloto com o ciclo completo `publicar → notificar → candidatar → confirmar → check-in → avaliar` e tempo mediano de confirmação. | `vagas_publicadas`, `notificacoes_enviadas`, `candidaturas`, `confirmacoes`, `checkins`, `avaliacoes`, `tempo_mediano_confirmacao`, `tempo_mediano_confirmacao_segundos` |
| `metrica.funil_por_dia` | Volume diário de vagas, notificações, candidaturas, confirmações, check-ins, avaliações e tempo mediano agrupados pela data da publicação. | `dia`, `vagas_publicadas`, `notificacoes_enviadas`, `candidaturas`, `confirmacoes`, `checkins`, `avaliacoes`, `tempo_mediano_confirmacao`, `tempo_mediano_confirmacao_segundos` |
| `metrica.funil_por_estabelecimento` | Conversão e tempos medianos segmentados por cada estabelecimento parceiro do piloto. | `estabelecimento_id`, `estabelecimento_nome`, `vagas_publicadas`, `notificacoes_enviadas`, `candidaturas`, `confirmacoes`, `checkins`, `avaliacoes`, `tempo_mediano_confirmacao`, `tempo_mediano_confirmacao_segundos` |
| `metrica.funil_por_vaga` | Detalhamento no nível de vaga individual, com posições ofertadas e contagens em cada estágio do funil. | `vaga_id`, `estabelecimento_id`, `estabelecimento_nome`, `dia`, `publicado_em`, `posicoes_ofertadas`, `notificacoes_enviadas`, `candidaturas`, `confirmacoes`, `checkins`, `avaliacoes` |
| `metrica.funil_confirmacoes` | Registros de posições confirmadas com a duração exata em segundos entre publicação e confirmação. | `posicao_id`, `vaga_id`, `estabelecimento_id`, `dia`, `publicado_em`, `confirmado_em`, `duracao_confirmacao_segundos` |
| `metrica.eventos_app_por_dia` | Agrupamento diário da telemetria de eventos operacionais emitidos pelos clientes do aplicativo. | `dia`, `evento`, `total` |

---

## 3. O que NÃO foi medido localmente (dependência de produção real)

Em conformidade com os princípios operacionais do Frila (*"Executado é o que você rodou e viu; o resto vai como não executado"*), declaram-se os seguintes itens que só podem ser validados com ambiente e tráfego reais de produção:

1. **Requisito RNF02 (Aceite e trânsito externo no Google FCM e Apple APNs):**
   - Em ambiente local e na integração contínua (CI), não há conexão com os servidores de produção do FCM/APNs nem aparelhos físicos com tokens push válidos.
   - O requisito RNF02 ($p95 \le 60\text{ s}$) afere o intervalo `aceita_em - enviada_em`. Como a confirmação de aceite só é gravada pelo retorno HTTP 200 real do provedor, ele é reportado localmente como `NÃO MENSURÁVEL LOCALMENTE / NÃO EXECUTADO`. A taxa real de aceite e a latência ponta-a-ponta dependem de produção (`frila-prod`).
2. **Requisito RNF03 de ponta a ponta:**
   - O script `scripts/medir-rnf.sh` afere o **tempo de despachar_vaga (parcial)**: mede só o tempo de execução direta da função interna `privado.despachar_vaga`, pulando a fila de mensagens assíncronas, o cron scheduler e a entrega FCM. O RNF03 de ponta a ponta (desde a publicação da vaga via API até a gravação e despacho de todos os candidatos) só pode ser aferido com o fluxo completo e tráfego de produção. Adicionalmente, quando executado com $N$ reduzido ($N < 5$), o cálculo de $p95$ aproxima-se do valor máximo observado.
3. **Dados de funil e telemetria com comportamento de usuários reais:**
   - As âncoras e os dados do ambiente de teste vêm de `supabase/cenarios.sql` (que popula cenários de teste ricos, e não de `seed.sql`, que contém apenas catálogos e termos bloqueados). A leitura semanal com volume orgânico de contratantes e profissionais de Brasília ocorre na rotina semanal sobre a base de produção.
4. **Execução ininterrupta de 24 horas dos jobs do `pg_cron`:**
   - Ambientes de teste locais e runners de CI são efêmeros. O teste de estabilidade contínua de 24 horas sem erros do job `reprocessar_despacho` requer o projeto remoto `frila-dev` / `frila-prod` ativo durante toda a janela (aferido via `scripts/medir-despacho-remoto.sh`).
