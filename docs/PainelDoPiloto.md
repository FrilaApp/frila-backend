# Painel de Métricas do Piloto

Documentação dos scripts de medição de requisitos não-funcionais de despacho e push (RNF02 e RNF03) e do gerador da página estática para a leitura semanal do piloto do Frila.

Cartões: `6ab26a53` (Brief B-005, T-0017, T-0020).

---

## 1. Como rodar os scripts

### 1.1 Medição dos Requisitos Não-Funcionais (`scripts/medir-rnf.sh`)

O script `scripts/medir-rnf.sh` afere o cumprimento das metas estabelecidas na arquitetura:
- **RNF03**: Da publicação da vaga até a criação dos despachos pelo motor (meta: $p95 \le 30\text{ s}$).
- **RNF02**: Do despacho até o aceite da notificação pelo provedor de push (meta: $p95 \le 60\text{ s}$, utilizando o mock em ambiente local).

#### Execução:
Antes de rodar contra o Supabase local, obtenha a vaga da fila compartilhada:
```bash
/Users/cauecarneiro/Documents/Projetos/Frila/orquestracao/scripts/fila.sh pegar banco <seu-nome>
```

Em seguida, execute o script:
```bash
# Executa 5 repetições (padrão)
./scripts/medir-rnf.sh

# Executa N repetições personalizadas
./scripts/medir-rnf.sh 10
./scripts/medir-rnf.sh -n 20
```

Ao concluir a medição, solte a vaga:
```bash
/Users/cauecarneiro/Documents/Projetos/Frila/orquestracao/scripts/fila.sh soltar banco <seu-nome>
```

#### Comportamento e Saída:
1. Cria vagas de teste isoladas (com prefixo `e0000000-0000-4000-8000-`) no banco local.
2. Dispara `privado.despachar_vaga` para cada uma e mede a latência de despacho (RNF03).
3. Simula a confirmação pelo provedor FCM via `privado.gravar_aceite_push` e afere a latência de aceite (RNF02).
4. Imprime tabela das amostras coletadas, consulta consolidada de `supabase/consultas/rnf02_rnf03_push.sql` e percentis $p50$ e $p95$.
5. Sai com código `0` se os requisitos forem cumpridos, ou código diferente de zero se $p95$ exceder os limites.
6. Limpa automaticamente todos os dados de teste no `trap EXIT`. Nunca realiza `db reset`.

---

### 1.2 Gerador do Painel Semanal (`scripts/gerar-painel.sh`)

O script `scripts/gerar-painel.sh` lê as 7 views do schema `metrica.*` via `psql` e gera um documento HTML único, moderno e totalmente autocontido (CSS embutido, zero JavaScript externo).

#### Execução:
```bash
# Imprime o HTML na saída padrão
./scripts/gerar-painel.sh

# Salva diretamente em arquivo
./scripts/gerar-painel.sh -o docs/painel-piloto.html

# Validação contratual de schema e colunas (usado na CI)
./scripts/gerar-painel.sh --teste -o /tmp/painel-piloto.html
```

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

1. **Aceite real e tempo de trânsito externo no Google FCM e Apple APNs:**
   - Em ambiente local e na integração contínua (CI), não há conexão com os servidores de produção do FCM/APNs nem envio para aparelhos físicos com tokens reais.
   - O requisito RNF02 foi testado localmente simulando o retorno de aceite através da função privada `privado.gravar_aceite_push`. A taxa de entrega e o $p95$ com rede pública real dependem do monitoramento contínuo em `frila-prod`.
2. **Dados de funil e telemetria com comportamento de usuários reais:**
   - O painel local foi gerado sobre dados de teste e sementes controladas (`seed.sql`). A leitura com volume orgânico de contratantes e profissionais de Brasília ocorre na rotina semanal com a base de produção.
3. **Execução ininterrupta de 24 horas dos jobs do `pg_cron`:**
   - Ambientes de teste locais e runners de CI são efêmeros. O teste de estabilidade contínua de 24 horas sem erros do job `reprocessar_despacho` requer o projeto remoto `frila-dev` / `frila-prod` ativo durante toda a janela (aferido via `scripts/medir-despacho-remoto.sh`).
