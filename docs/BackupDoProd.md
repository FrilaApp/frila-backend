# Backup lógico cifrado

`scripts/backup-logico.sh` gera um pacote v2 com `banco.dump` (pg_dump custom),
`extensoes.sql` (suplemento de dados de extensão) e `formato.txt`. Cifra o pacote
com chave pública, publica apenas `.tar.age`/`.tar.cms` e remove todos os claros.
Não usa Docker nem Supabase CLI. Complementa o ensaio local existente em
`scripts/ensaio-restauracao.sh`, que depende de Docker.

## Configuração e execução manual

Use Bash, `tar` padrão (GNU tar no Linux ou bsdtar no macOS), Git, `psql` e `pg_dump` compatível com o servidor.
O script consulta `server_version_num` em transação **READ ONLY**, compara a versão
principal do `pg_dump` e recusa cliente mais antigo antes de criar pasta/dump.
Use a mesma instalação de `psql`/`pg_dump` no PATH. Para o dev PostgreSQL 17, use
`/opt/homebrew/opt/postgresql@17/bin`. Conforme a [documentação do pg_dump](https://www.postgresql.org/docs/17/app-pgdump.html),
cliente mais antigo não exporta servidor mais novo; a comparação é de versão
principal (17.11 atende servidor 17.6), sem exigir igualdade de patch.
Precisa de conexão PostgreSQL com permissão
para exportar todos os objetos; token da API Supabase não substitui essa conexão.

| Variável | Valor |
| --- | --- |
| `BACKUP_DB_URL` | Conexão PostgreSQL percent-encoded, somente no ambiente |
| `BACKUP_DIR` | Pasta absoluta dedicada, fora de qualquer Git, inclusive por symlink |
| `BACKUP_PUBLIC_KEY` | Destinatário público age, ou caminho de certificado público PEM RSA no fallback |
| `BACKUP_KEEP` | Quantidade a manter nessa pasta; padrão `14` |
| `BACKUP_CIPHER` | `auto` (padrão), `age` ou `openssl` |

Em `auto`, usa age quando instalado; caso contrário, OpenSSL **3**, CMS com
AES-256-GCM e RSA-OAEP. Certificado PEM e destinatário age são formatos diferentes:
ao mudar o modo, configure também a chave pública correspondente. O script nunca
precisa da chave privada.

Guarde a identidade privada age (gerada por `age-keygen`) ou a chave RSA privada
fora do Git, com permissão `0600` e cópia separada protegida. Uma pasta sugerida é
`~/.config/frila/backup/` (`0700`). Distribua apenas a chave pública ao operador de
backup. No fallback, Cauê provisiona um certificado público RSA correspondente à
chave privada; OpenSSL do macOS sem suporte a CMS/GCM não serve.

Depois de Cauê carregar a conexão no ambiente por seu mecanismo seguro, sem
imprimir ou colocar a conexão no histórico:

```bash
set +x
export PATH="/opt/homebrew/opt/postgresql@17/bin:/opt/homebrew/bin:$PATH"
export BACKUP_DIR="$HOME/Backups/frila-dev"
export BACKUP_CIPHER=age
export BACKUP_PUBLIC_KEY="$(cat "$HOME/.config/frila/backup/destinatario.age")"
export BACKUP_KEEP=14
./scripts/backup-logico.sh
unset BACKUP_DB_URL
```

`destinatario.age` contém somente o destinatário público produzido por `age-keygen -y`.
Para o fallback, selecione `BACKUP_CIPHER=openssl` e defina `BACKUP_PUBLIC_KEY` como
o caminho do certificado público PEM RSA. O script exige a conexão em `BACKUP_DB_URL`; não lê arquivos
de credenciais. SSL é exigido por padrão; configure validação de certificado na
conexão para o ambiente remoto. Apenas o ensaio descartável usou `sslmode=disable`.

Use uma pasta por ambiente. A retenção considera mtime, mantém o backup recém
gerado e só remove nomes próprios `frila-backup-*.tar.age`/`.tar.cms` e legados
`.dump.age`/`.dump.cms`, com formato validado. Só roda após dump, suplemento,
cifra e remoção dos claros bem-sucedidos. Arquivo cifrado
com permissão `0600`, pasta `0700`. Falha retorna código não zero; saída sensível dos
subprocessos é suprimida. Não rode com rastreamento/depuração de ambiente.

Uma trava impede duas execuções na mesma pasta. Após queda abrupta, confira se
nenhuma execução está viva antes de remover `.backup-logico.lock` e eventuais
`.backup-logico.*` residuais. Interrupções tratáveis limpam esses temporários;
desligamento forçado/SIGKILL exige essa conferência manual.

## Decifrar e restaurar em destino descartável

Provisionar primeiro um **banco/projeto descartável vazio**, com extensões e roles
compatíveis. Nunca apontar a restauração ao frila-dev usado pelo time nem ao prod.
Cauê deve conferir também os privilégios padrão do destino antes de restaurar ACLs.
`ARQUIVO_CIFRADO`, `CHAVE_PRIVADA` e `CERTIFICADO_PUBLICO` abaixo são caminhos locais;
`RESTORE_DB_URL` é a conexão do destino descartável carregada somente no ambiente.

Execute em Bash. Decifre para temporário restrito e valide o código de saída antes
de chamar `pg_restore`: uma cifra autenticada pode produzir bytes antes de detectar
adulteração, por isso não use pipe direto para o banco.

```bash
set +x
set -euo pipefail
umask 077
tmp_restore=$(mktemp -d)
trap 'rm -rf -- "$tmp_restore"' EXIT

# Escolha UM comando, conforme a extensão da cifra:
age --decrypt --identity "$CHAVE_PRIVADA" \
  --output "$tmp_restore/pacote" "$ARQUIVO_CIFRADO" >/dev/null 2>&1
# Ou, para .cms, em vez do comando age:
# openssl cms -decrypt -binary -inform DER -in "$ARQUIVO_CIFRADO" \
#   -recip "$CERTIFICADO_PUBLICO" -inkey "$CHAVE_PRIVADA" \
#   -out "$tmp_restore/pacote" >/dev/null 2>&1

case "$ARQUIVO_CIFRADO" in
  *.tar.age|*.tar.cms)
    tar -xf "$tmp_restore/pacote" -C "$tmp_restore" formato.txt banco.dump extensoes.sql
    [[ "$(cat "$tmp_restore/formato.txt")" == frila-backup-v2 ]]
    ;;
  *.dump.age|*.dump.cms) mv "$tmp_restore/pacote" "$tmp_restore/banco.dump" ;;
  *) exit 1 ;;
esac

pg_restore --exit-on-error --single-transaction --no-owner \
  --dbname "$RESTORE_DB_URL" "$tmp_restore/banco.dump" >/dev/null 2>&1
if [[ -f "$tmp_restore/extensoes.sql" ]]; then
  psql -X --no-password --set ON_ERROR_STOP=1 --single-transaction \
    --dbname "$RESTORE_DB_URL" --file "$tmp_restore/extensoes.sql" >/dev/null 2>&1
fi
unset RESTORE_DB_URL
```

Se algum comando falhar, encerre a sessão de ensaio e investigue sem publicar saída
crua, que pode conter conexão ou conteúdo de linhas. Depois confira contagens,
hashes dos dados, constraints, índices, políticas RLS, sequências e permissões com
consultas que não exponham dados pessoais. Remova o destino descartável ao concluir.

O suplemento consulta `pg_depend`, `pg_extension.extconfig`, `pg_class` e
`pg_attribute`: seleciona tabelas ordinárias pertencentes a extensões, fora de
`extconfig`, com linhas, sem lista fixa de tabelas de filas. Usa `COPY TO STDOUT`
com colunas explícitas, sem colunas geradas, e gera `COPY FROM stdin` para restaurar.
O dump e o suplemento compartilham o snapshot de uma transação READ ONLY mantida
pela sessão psql; o pg_dump filho recebe `--snapshot`. `row_security=off` evita
exportação silenciosamente filtrada por políticas. Qualquer erro de leitura/COPY/dump
impede publicar o pacote. O suplemento limpa com `TRUNCATE ONLY` cada tabela que
reporá; rode só no destino descartável após o dump. Se constraints impedirem o
suplemento, descarte o destino e investigue; não considere restauração parcial aprovada.

**Perda aceita por Nick Fury em 20/10 às 23h:** `net._http_response` é log transitório
de respostas HTTP do pg_net e fica fora do dump e do suplemento. Sua divergência de linhas
é esperada; não é dado necessário para reconstruir as filas. Backups legados
`.dump.*` não possuem suplemento e não recuperam `pgmq.meta`.

O archive guarda ACLs e definições de RLS, mas `pg_dump` não exporta roles globais,
senhas de roles, configuração do projeto, chaves do Vault, Edge Functions ou arquivos
binários do Storage. Metadata de Storage não substitui os arquivos. A restauração
de ownership é omitida no exemplo; as roles citadas em ACLs precisam existir. No
Supabase gerenciado, permissões, extensões e objetos de sistema ainda precisam do
ensaio real. Não exclua esquemas silenciosamente para contornar erro de permissão.

## Ensaios sintético e no dev real

Em 20/10/2026, Postgres **16.13 Homebrew**, porta alta livre, escuta exclusivamente
em `127.0.0.1`, dados sintéticos: 10.000 clientes e 50.000 turnos. OpenSSL **3.6.4**,
certificado/chave de ensaio RSA 3072, CMS AES-256-GCM + RSA-OAEP.

| Etapa | Tempo medido | Tamanho |
| --- | ---: | ---: |
| `pg_dump` custom | 0,0657 s | 297.028 bytes |
| Cifrar | 0,0068 s | 304.697 bytes |
| Decifrar | 0,0090 s | Pacote v2 |
| `pg_restore` em banco vazio | 0,0538 s | 60.000 linhas |

Backup completo com validação do destinatário e limpeza: **0,3769 s**. Medições por
relógio monotônico externo ao script; a saída operacional do script usa segundos
inteiros. Hashes e estrutura restaurados conferidos, adulteração da cifra recusada,
retenção 14/2, falhas de dump/cifra e limpeza conferidas. Cluster desligado e
diretório temporário, dumps e chaves de ensaio apagados. Esses números medem apenas
a base sintética; não estimam duração nem recuperabilidade do Supabase real.

**Ensaio real com PostgreSQL 17 e age — 20/10/2026.** A conexão do session
pooler foi carregada em memória/ambiente a partir de `~/.config/frila/dev-db-url`,
com autorização de Cauê, sem imprimir ou registrar seu conteúdo. A origem foi
usada apenas para SELECTs em transação `REPEATABLE READ READ ONLY` e `pg_dump`.
O script exporta o snapshot dessa transação para o pg_dump filho. O medidor
importa esse mesmo snapshot para conferir as contagens, sem substituí-lo; o
suplemento é extraído pela sessão que mantém o snapshot vivo.

O destino usa PostgreSQL **17.11 Homebrew**, com cópia temporária dos binários,
headers, bibliotecas e arquivos de extensão. A árvore de diretórios preserva o
layout relativo do brew para que `pg_config` e o servidor resolvam os arquivos
**na cópia**, sem instalar extensões na instalação do PostgreSQL do Mac.
`initdb` cria um cluster novo; `pg_ctl` usa porta alta livre, escuta somente em
`127.0.0.1` e socket Unix desativado. Nenhum serviço brew é iniciado ou alterado.
Logs de SQL/erros do servidor não são gravados; saídas de ferramentas ficam
capturadas em memória, sem publicar conteúdo de linhas ou credenciais.

Foram criadas **15 roles auxiliares NOLOGIN**, sem senhas, para resolver as ACLs
do archive. A restauração usa `--no-owner --single-transaction --exit-on-error`.
Isso não reproduz atributos globais, membership, autenticação ou ownership de
produção. Nenhuma role do dev foi criada ou alterada.

**Correção das extensões, aceita para ensaio em 20/10 às 23h.** O pacote v2
acrescenta o suplemento dinâmico. Medições finais com age **1.3.2** (relógio
monotônico externo ao script):

| Etapa real | Tempo medido | Tamanho |
| --- | ---: | ---: |
| `pg_dump` 17 custom | 53,2899 s | 2.820.466 bytes |
| Suplemento descoberto pelo catálogo | Incluído no backup | 277 bytes, 1 tabela |
| Pacote v2 antes da cifra | Incluído no backup | 2.827.264 bytes |
| Cifrar pacote com age | 0,0086 s | 2.828.152 bytes |
| Decifrar pacote com age | 0,0096 s | 2.827.264 bytes |
| `pg_restore` transacional | 1,2700 s | Código 0 |
| Restaurar suplemento com psql | 0,0212 s | Código 0 |
| `initdb` isolado | 0,4122 s | Cluster novo |

Backup completo com preflight, contagens da instrumentação, suplemento e limpeza:
**55,5415 s**. Dump/cifra/decifra/restaurações terminaram com código zero.
O TOC contém **81 itens TABLE DATA**, incluindo **2 tabelas de filas do pgmq**.
As 81 tabelas identificadas no TOC tiveram contagens iguais. As extensões também
criam tabelas; por isso a comparação integral cobre **85 tabelas** em cada lado,
sem ausentes ou extras: **84 contagens iguais**, com uma diferença aceita abaixo.
Total: **77.342 linhas no snapshot do dev**, **76.970 no restaurado**.
Em `public`: **22 tabelas, 137 linhas em cada lado, zero divergências**.

| Prova das filas e exceção aceita | Dev | Restaurado |
| --- | ---: | ---: |
| `pgmq.meta` | 2 linhas | 0 após dump; **2 após suplemento** |
| Tabelas das filas incluídas no archive | 2 | 2 presentes após restauração |
| `pgmq.list_queues()` no destino | Não altera origem | **2 filas retornadas** |
| `net._http_response` (log transitório, perda aceita) | 372 linhas | 0 |

**Bloqueio das extensões fechado:** dados de `pgmq.meta` vêm do suplemento
cifrado, descoberto pelo catálogo, e as filas são listadas no destino. Nenhum
metadado foi fabricado. A única divergência é o log transitório autorizado;
`--exclude-table-data=net._http_response` também o exclui explicitamente do dump.
Os números são do snapshot deste ensaio e não estimam duração do prod.

Cluster desligado com `pg_ctl stop`; diretório temporário, cópia do servidor,
dumps claros/cifrados e chave age temporária apagados. GEOS, PROJ, pkgconf e
libxml2, instalados só para o build, também removidos. PostgreSQL 16/17 e age
provisionados por Cauê permanecem disponíveis. Prod não foi acessado.

| Extensão adicional no destino | Tratamento executado |
| --- | --- |
| `supabase_vault` 0.3.1 | Compilada da tag oficial v0.3.1, somente na cópia temporária; sem ler chave mestre do dev |
| `pg_net` 0.20.4 | Compilada da tag oficial v0.20.4; worker configurado para banco inexistente, sem enviar requisições restauradas |
| `pgmq` 1.5.1 | SQL oficial da tag v1.5.1 instalado como extensão real |
| `pg_cron` release v1.6.4 | Compilado da tag oficial; versão SQL local `1.6`, origem informa `1.6.4`; jobs desativados por `cron.launch_active_jobs=off` |
| `postgis` 3.3.7 | Compilado da distribuição oficial 3.3.7; sem raster/topology/SFCGAL, extensões que o dev não utiliza |

`plpgsql`, `pg_stat_statements`, `uuid-ossp`, `pgcrypto`, `btree_gist` e `citext`
usaram os arquivos do PostgreSQL 17 copiado. Não houve stubs, exclusão de schemas
nem filtragem do archive para contornar incompatibilidades. Os ajustes de build
no macOS foram caminho do SDK do Xcode, headers/libs gettext/libsodium e helper
`install-sh`; nenhuma definição SQL de aplicação foi alterada.

Fontes das extensões: [Vault](https://github.com/supabase/vault/tree/v0.3.1),
[pg_net](https://github.com/supabase/pg_net/tree/v0.20.4),
[pgmq](https://github.com/pgmq/pgmq/tree/v1.5.1),
[pg_cron](https://github.com/citusdata/pg_cron/tree/v1.6.4),
[PostGIS](https://postgis.net/docs/manual-3.3/postgis_installation.html).

A versão anterior do cliente (16.13) foi recusada pelo novo preflight contra o
servidor 17.6, antes de criar pasta de saída. O caminho OpenSSL foi testado
novamente com dados sintéticos e passou; age **1.3.2** foi usado no ensaio real.

**Cobertura e limites:** o pg_dump omite dados de tabelas pertencentes a extensões
fora de `extconfig`, conforme a [documentação do PostgreSQL](https://www.postgresql.org/docs/17/extend-extensions.html#EXTEND-EXTENSIONS-CONFIG-TABLES).
O pacote v2 cobre essas tabelas ordinárias com linhas pelo suplemento; neste dev,
a única selecionada foi `pgmq.meta`. O log `net._http_response` é excluído de forma
explícita e aceita. Chaves do Vault, roles globais, autenticação do projeto,
ownership e arquivos binários do Storage continuam fora do escopo validado.
As ACLs são aplicadas com roles auxiliares; não equivalem à configuração de segurança
do ambiente gerenciado. A compatibilidade deve ser reavaliada ao mudar extensões.

Além do ensaio real, uma extensão sintética instalada apenas na cópia temporária
provou descoberta sem lista fixa, cópia de quatro linhas com aspas, barra,
quebra de linha, NULL e Unicode, valores de identity e coluna gerada, com hash igual.
Um usuário sujeito a RLS foi recusado sem publicar backup. A regressão OpenSSL
com pacote v2 passou, incluindo falha SQL do suplemento e retenção entre formatos
novos e legados. O empacotamento com `tar` portátil (usando `COPYFILE_DISABLE=1` no macOS) empacota só os três arquivos (`formato.txt`, `banco.dump`, `extensoes.sql`), compatível tanto com GNU tar no Linux quanto com bsdtar no macOS.

Com as dependências resolvidas, um operador autorizado pode carregar a conexão
sem colocá-la no histórico e executar o comando da seção inicial:

```bash
set +x
export BACKUP_DB_URL="$(cat "$HOME/.config/frila/dev-db-url")"
./scripts/backup-logico.sh
unset BACKUP_DB_URL
```

Depois, decifrar e restaurar conforme a seção anterior, exclusivamente no destino
descartável. Medir e conferir os dados antes de considerar o ensaio aprovado.

## Configuração do prod e agendamento diário (.github/workflows/backup-prod.yml)

O backup diário do `frila-prod` (issue #352, RNF12) é automatizado pelo workflow
`.github/workflows/backup-prod.yml`. O workflow executa diariamente às **07:00 UTC**
(04:00 BRT, horário de menor movimento) e sob demanda via `workflow_dispatch`.

O fluxo executa `scripts/backup-logico.sh` num diretório temporário isolado do runner
fora do checkout (`BACKUP_DIR="${RUNNER_TEMP}/frila-backup-prod"`), empacota o dump
lógico v2 (`banco.dump`, `extensoes.sql` e `formato.txt`), cifra com `age` utilizando
a chave pública configurada, e transfere o pacote `.tar.age` diretamente para um bucket
de armazenamento S3-compatível (Cloudflare R2 ou Backblaze B2) utilizando `aws-cli` com
`--endpoint-url`. O repositório é público: nenhum dump é publicado como artefato do
GitHub Actions (`upload-artifact` desativado), e todo dado claro em disco é apagado
pelo próprio script antes da publicação do arquivo cifrado.

### Environment `frila-backup` e segredos necessários

O job utiliza o Environment **`frila-backup`** no GitHub Actions.
Esse Environment é deliberadamente separado de `frila-prod`: o Environment `frila-prod`
possui (ou possuirá) revisores humanos obrigatórios para deploys e ações administrativas,
o que travaria qualquer agendamento automatizado na madrugada exigindo aprovação manual.
O Environment `frila-backup` isola as credenciais necessárias exclusivamente para a
rotina de backup, sem revisores impeditivos.

Segredos configurados no Environment `frila-backup` (sem valores reais no repositório):

| Segredo | Finalidade e Requisitos |
| --- | --- |
| `BACKUP_DB_URL` | Conexão PostgreSQL com `sslmode=require` apontando para o banco de produção `frila-prod`. Precisa de permissão para leitura de catálogo e exportação de dados via `pg_dump` e transação `READ ONLY`. |
| `BACKUP_PUBLIC_KEY` | Destinatário público `age` (`age1...`). Apenas a chave pública é necessária para cifrar. A chave privada correspondente **nunca** entra no repositório nem no GitHub Actions, devendo permanecer sob custódia offline segura dos administradores. |
| `BACKUP_S3_ENDPOINT` | URL do endpoint da API S3-compatível (ex.: `https://<account_id>.r2.cloudflarestorage.com` no Cloudflare R2 ou `https://s3.<region>.backblazeb2.com` no Backblaze B2). |
| `BACKUP_S3_BUCKET` | Nome do bucket dedicado no storage S3. |
| `BACKUP_S3_ACCESS_KEY_ID` | Chave de acesso (Access Key ID) com permissão mínima para gravação (`PutObject`). |
| `BACKUP_S3_SECRET_ACCESS_KEY` | Chave secreta de acesso (Secret Access Key) correspondente. |

Variável opcional (Action Variables):
- `BACKUP_S3_REGION`: Região S3 (padrão: `auto`).
- `BACKUP_LIMITE_GB`: Limite de armazenamento para projeção de custos e alertas em GB (padrão: `10`, alinhado à cota gratuita de 10 GB da Cloudflare R2 e Backblaze B2). **Variável de Environment (NÃO segredo)**.

### Política de Retenção de 14 dias

A política de retenção dos backups é implementada em duas camadas:

1. **No bucket S3 (Primária / Princípio do Menor Privilégio):** Deve ser configurada
   uma regra de ciclo de vida (Lifecycle Rule) no bucket (R2 ou B2) com expiração e
   exclusão automática de objetos após 14 dias (`Delete after 14 days`). Dessa forma,
   a credencial fornecida ao GitHub Actions precisa apenas da permissão `s3:PutObject`,
   **sem** permissão destrutiva de `s3:DeleteObject`. Isso protege os backups existentes
   contra deleção acidental ou intencional em caso de comprometimento da esteira de CI.
2. **No runner local:** O script `scripts/backup-logico.sh` define `BACKUP_KEEP=14`
   durante sua execução local, e o job limpa completamente o diretório temporário no
   runner ao final (`if: always()`).

### Monitoramento e limites de armazenamento do backup (Storage R2 / B2)

O backup diário inclui uma verificação automatizada de consumo de armazenamento (`scripts/verifica-limite-backup.sh`), garantindo que o volume total de backups nunca se aproxime silenciosamente do teto do plano gratuito do storage externo (**10 GB** no Cloudflare R2 e no Backblaze B2).

#### Contexto e fatos medidos

- **Volumetria do banco:** O banco de produção `frila-prod` foi medido em 04/11/2026 totalizando **37 MB** em disco (com aproximadamente 2 MB de dados de aplicação nos esquemas `public` e `privado`, e o restante composto pelo catálogo do PostgreSQL e extensões gerenciadas do Supabase como PostGIS e Vault).
- **Consumo projetado:** Com o empacotamento v2 e cifra `age`, cada dump gera um arquivo compacto (~2.8 a 3.5 MB compactado/cifrado). Com a política de retenção de **14 dias** (`BACKUP_KEEP=14`), o volume cumulativo mantido no storage é de aproximadamente **500 MB a 600 MB**, correspondendo a cerca de **5% a 6%** da cota gratuita de 10 GB.

#### Restrição arquitetural: Projeção linear determinística (não é inventário nem medição)

A credencial de acesso S3 configurada no GitHub Actions possui privilégio estritamente restrito a gravação (`s3:PutObject`), sem permissão de `s3:ListBucket` ou `s3:ListObjects`. Essa restrição é mandatória por segurança para evitar que o runner possa inspecionar outros objetos ou receber permissões destrutivas.

Por não poder listar o bucket remotamente, a verificação adota **projeção linear determinística**: logo após o upload, o passo `Verificar limite de armazenamento do backup` no workflow lê o tamanho exato do arquivo `.tar.age` recém-enviado, multiplica pela retenção configurada (`BACKUP_KEEP=14`), e compara o resultado contra o limite em `BACKUP_LIMITE_GB`.

> [!IMPORTANT]
> **Distinção conceitual mandatória:**
> - **Projeção linear determinística (no runner):** Multiplicação direta do tamanho do artefato do dia pela retenção ($\text{tamanho} \times 14$). Avalia se a taxa diária atual comprometeria a cota se mantida durante o ciclo. **NÃO é medição do bucket e NÃO é inventário remoto.**
> - **Regra de Ciclo de Vida / Lifecycle Rule (no bucket):** É estritamente uma **política assíncrona de expurgo** (`Delete after 14 days`). **Lifecycle NÃO é inventário e NÃO é medição**: ele remove objetos antigos em segundo plano, sem emitir relatórios de volumetria e sem alertar sobre consumo de cota.
> - **Mecanismo de métricas do Cloudflare R2:** O R2 não oferece relatório diário de inventário em lote (como o S3 Inventory da AWS). As métricas de uso no R2 são agregadas pelo plano de controle da Cloudflare (dashboard e GraphQL Analytics `r2StorageAdaptiveGroups`), com defasagem típica de 24 h a 48 h. No plano gratuito do R2, não há alertas nativos de percentual de cota pré-configurados sem vinculação de faturamento ou Workers. Por isso, a projeção preventiva imediata pós-dump no runner garante observabilidade determinística no momento exato de cada execução.

#### Portões e alertas operacionais no GitHub Actions

O script `scripts/verifica-limite-backup.sh` opera sob três faixas de controle:

1. **Abaixo de 50% (< 5 GB):** Status seguro (`OK`), conclui com exit code 0 e registra a volumetria e porcentagem no `GITHUB_STEP_SUMMARY`.
2. **Entre 50% e 80% (5 GB a 8 GB):** Faixa de aviso. Emite anotação `::warning::` no log da Action e destaca o alerta no Step Summary, concluindo com exit code 0 para permitir acompanhamento preventivo sem interromper o serviço.
3. **A partir de 80% (>= 8 GB):** Limiar crítico de risco. Emite anotação `::error::` e **falha o job com exit code 1**. Essa falha intencional dispara os alertas de execução com falha monitorados pelo Vigia / equipe, garantindo ação imediata antes do esgotamento da cota gratuita.

#### Como alterar o limite (`BACKUP_LIMITE_GB`)

O limite de armazenamento é parametrizável via variável de ambiente do GitHub Actions:

1. Acesse o repositório no GitHub: **Settings** → **Environments** → **`frila-backup`**.
2. Na seção **Environment variables** (atenção: variável, **NÃO** segredo), adicione ou edite `BACKUP_LIMITE_GB`.
3. Defina o valor desejado em GB (ex.: `10` para 10 GB, `20` para plano pago de 20 GB, ou `5` para um teto mais restrito). O valor padrão caso a variável não seja configurada é `10`.

#### Observabilidade externa e defesa em profundidade

Para complementar a projeção determinística da esteira sem conceder permissões extras ao runner:

- **Backblaze B2:** Permite configurar em *Caps & Alerts* limites de faturamento e alertas diários por e-mail quando o uso se aproxima do teto.
- **Cloudflare R2:** Acompanhamento periódico da volumetria real via dashboard Cloudflare (R2 → Overview / Analytics) ou consultas analíticas GraphQL, ciente da defasagem de processamento do plano de controle.

## Restauração real de 17/11/2026

Cartão `U3RlsJF7` (pedido 16-28, item 7). Um backup real do `frila-prod` foi decifrado e restaurado num
Postgres descartável, e as contagens de linhas foram conferidas. Roteiro: `scripts/restauracao-real.sh`.

### De onde veio o arquivo: cópia local, não o bucket

**O arquivo restaurado veio da cópia local do Mac do Cauê (`~/Backups/frila-prod`), e não do bucket R2.**
Nenhuma credencial guardada no Mac lê o bucket: o `cloudflare-token` e o `cloudflare-pages-token` recebem
`Authentication error` (10000) em `GET /accounts/<id>/r2/buckets`, e a conta do login do wrangler não tem R2
ligado (10042). A credencial do GitHub Actions só grava (`PutObject`). A credencial de leitura foi pedida ao
Cauê no painel.

- Arquivo: `frila-backup-20261117T003409Z-jK1Mho.tar.age`, com 5.165.480 bytes. Gerado às 00:34:09 UTC de
  17/11 (21:34:09 em Brasília, 16/11). É o backup que o roteiro do Prod "ligar a busca" tira antes de aplicar,
  pelo `scripts/backup-logico.sh` da árvore do corte, e o mais novo da pasta local.
- Formato: o mesmo do bucket. O pacote decifrado trouxe `formato.txt` = `frila-backup-v2`, `banco.dump`
  (5.156.906 bytes) e `extensoes.sql` (375 bytes).
- Chave: o roteiro cifra para `~/.config/frila/backup/destinatario.age`, e a decifra usou a identidade
  privada desse destinatário. Que o `BACKUP_PUBLIC_KEY` do GitHub é esse mesmo destinatário só se prova decifrando um
  arquivo do bucket, e essa prova fica pendente junto com o download.

**PENDENTES (falta a credencial de leitura do R2):**

1. Baixar do bucket o `.tar.age` do dia anterior e medir o tempo de download.
2. Conferir no R2 a regra de ciclo de vida de 14 dias. O `backup-prod.yml` e esta página dizem que ela
   existe, mas ninguém do time a viu com prova.

### Destino descartável

- Imagem `public.ecr.aws/supabase/postgres:17.6.1.075`, num contêiner do Colima com `--network none`: sem
  porta publicada e sem saída para a rede. O acesso foi só por `docker exec`, de modo que nada pôde apontar
  ao dev nem ao Prod.
- O banco `ensaio` foi criado antes do restore, com `cron.database_name = 'ensaio'` e
  `cron.launch_active_jobs = off`. Os 26 jobs restaurados não rodaram.
- Os papéis `supabase_functions_admin` e `supabase_realtime_admin` foram criados sem login, porque a imagem
  não os traz.
- Restore: `pg_restore --exit-on-error --single-transaction --no-owner`, mais o suplemento
  `extensoes.sql` (`psql --single-transaction`, `ON_ERROR_STOP`). Os dois terminaram com código 0.
- Logo depois do restore, `privado.chave_cursor_busca` ganhou chave nova, para a cópia não cunhar link de foto
  válido no Prod.
- Limpeza (pelo `trap`, que roda também na falha): a pasta temporária do decifrado ficou vazia (`ls -A` → `[]`)
  e foi removida, e o contêiner foi apagado (0 contêineres `frila-restauracao-*` no `docker ps -a`).

### Tempos medidos (RTO)

Relógio de alta resolução (`Time::HiRes`), em segundos. A rodada 1 (03:31 UTC) teve o restore perfeito, mas
parou na comparação por um defeito do contador do roteiro, já corrigido. A rodada 2 (03:34 UTC) passou
inteira.

| Etapa | Rodada 1 | Rodada 2 |
| --- | ---: | ---: |
| Baixar do bucket | pendente | pendente |
| Subir o contêiner, criar o banco e reiniciar | 7,756 | 4,000 |
| Decifrar com age | 0,047 | 0,024 |
| Extrair o pacote | 0,030 | 0,019 |
| Copiar para o contêiner | 0,218 | 0,097 |
| `pg_restore` | 1,908 | 0,972 |
| Suplemento `extensoes.sql` | 0,155 | 0,058 |
| **Total, sem o download** | **10,910** | **5,843** |

**RTO do banco, medido: cerca de 11 s** com o arquivo já no disco. Esse número vale só para o banco num
Postgres descartável. Uma volta de verdade, num projeto Supabase novo, soma etapas que não foram medidas:
o download (5 MB), a criação do projeto, a configuração do Auth, as Edge Functions, os segredos e o Vault,
e os arquivos do Storage, que ficam fora do backup (ver "Decifrar e restaurar em destino descartável").

### Contagens de linhas

O pacote não grava contagem. O roteiro conta as linhas de cada `COPY` do `banco.dump` e do suplemento,
sem mostrar nenhuma linha, e compara com `count(*)` no restaurado. Depois compara com o Prod, numa transação
`REPEATABLE READ READ ONLY` com `row_security = off`, aberta às 03:34:50 UTC, 3 h 01 depois do snapshot.

As 5 tabelas `privado.registro_acesso*` foram restauradas, mas ficaram fora de toda contagem: decisão do
Cauê de 08/11/2026 (só se leem com ordem dele). O TOC tem 122 itens `TABLE DATA`, e foram comparadas
**120 tabelas**:

- **116 iguais** entre o pacote e o restaurado.
- **1 igual pelo suplemento:** `pgmq.meta`, com 4 linhas.
- **1 com linhas da própria extensão:** `extensions.spatial_ref_sys`. O pacote traz 0 linhas, porque o
  `pg_dump` só exporta o que o usuário acrescenta; o `CREATE EXTENSION postgis` cria 8.500, o mesmo que o Prod.
- **2 vazias e sem dados no pacote:** `net._http_response`, excluída de propósito (perda aceita em 20/10),
  e `net.http_request_queue`.
- **Nenhuma diferente.**

Total: **134.172 linhas no pacote** e **142.672 no restaurado** (134.172 + as 8.500 do PostGIS).

| Esquema | Tabelas | Pacote | Restaurado | Prod às 03:34:50 UTC |
| --- | ---: | ---: | ---: | ---: |
| `public` | 31 | 1.091 | 1.091 | 1.091 |
| `privado` (sem `registro_acesso*`) | 34 | 553 | 553 | 554 |
| `auth` | 27 | 296 | 296 | 296 |
| `storage` (só metadados) | 10 | 83 | 83 | 83 |
| `pgmq` | 9 | 446 | 446 | 446 |
| `cron` | 2 | 131.386 | 131.386 | 133.571 |
| `supabase_migrations` | 1 | 213 | 213 | 213 |
| `realtime` | 2 | 96 | 96 | 96 |
| `vault` (texto cifrado, sem a chave) | 1 | 8 | 8 | 8 |
| `extensions` | 1 | 0 | 8.500 | 8.500 |
| `net` | 2 | 0 | 0 | 366 |

Nas tabelas principais de `public`, restaurado = Prod: `evento_app` 501, `notificacao` 119,
`profissional_funcao` 79, `disponibilidade` 67, `funcao` e `posicao` 38 cada, `usuario` 33 e `vaga` 25.
`auth.users` tem 22.

Só 3 tabelas do Prod diferem do restaurado, e as três diferenças vêm do tempo:

| Tabela | Restaurado | Prod | Por quê |
| --- | ---: | ---: | --- |
| `cron.job_run_details` | 131.360 | 133.545 | São 2.185 execuções do pg_cron em 3 h 01 (Inferência: ~12 por minuto, 26 jobs) |
| `net._http_response` | 0 | 366 | Log transitório do pg_net, excluído do dump (perda aceita em 20/10) |
| `privado.recurso_versao_minima` | 4 | 5 | O "ligar a busca" rodou às 21:34:16 de Brasília, 7 s depois do backup, e o SQL dele insere a linha `busca_profissionais`/`ios` (o Android ficou desligado). A linha não foi lida |

### Horário real dos backups e RPO

O cron pede 07:00 UTC, mas o GitHub atrasou todas as execuções agendadas. Fonte: `gh run list --workflow
backup-prod.yml` e `gh api .../actions/runs/<id>/attempts/<n>`, lidos em 17/11/2026 às 03:2x UTC.

| Dia | Início (UTC) | Fim (UTC) |
| --- | --- | --- |
| 05/11 | 15:15:06 | 15:18:36 |
| 06/11 | 14:50:25 | 14:54:06 |
| 07/11 | 13:47:34 | 13:52:55 |
| 08/11 | 14:07:59 | 14:13:31 |
| 09/11 | 17:15:45 | 17:19:49 |
| 10/11 | 15:26:59 | 15:32:14 |
| 11/11 | 14:57:43 | 18:25:32 (2ª tentativa) |
| 12/11 | 15:50:41 | 15:55:01 |
| 13/11 | 15:10:41 | 15:15:00 |
| 14/11 | 13:58:44 | 14:04:30 |
| 15/11 | 14:34:38 | 14:39:39 |
| 16/11 | 16:50:12 | 16:54:50 |

**Achado de 11/11 (3,5 h):** a 1ª tentativa falhou em "Instalar postgresql-client-17 e age" (das 14:57:48
às 15:02:37 UTC). Uma reexecução manual, às 18:20:18 UTC, gerou o backup do dia às 18:25:31 UTC. O
`gh run list` mostra só a última tentativa (`success`): para ver a falha, consulte `attempts/1`. O passo
que falhou instala pacotes pelo apt, antes de qualquer acesso ao banco.

**Achado da cópia local:** o lançador do Mac falhou em 16/11 às 04:06 ("falha ao gerar dump e suplemento de
extensões no mesmo snapshot", no `~/.config/frila/backup/log/backup.log`). As cópias locais seguintes são
as duas que os roteiros do Prod tiraram, às 00:27 e às 00:34 UTC de 17/11.

**RPO medido: até ~27 h.** O maior intervalo entre o fim de dois backups bons seguidos foi de 27,1 h (de
08/11 14:13 a 09/11 17:19 UTC). Os outros ficaram entre 21,4 h e 26,8 h. Isso confirma o ~28 h da
[D03](decisoes/D03-plano-do-supabase.md). Um dia que falhe sem reexecução leva o RPO a ~48 h ou mais.

### Em aberto

- **"2 pessoas com a chave": EM ABERTO**, por decisão do Cauê. Este ensaio não muda isso.
- O download do bucket e a regra de 14 dias no R2 seguem pendentes, como descrito acima.
