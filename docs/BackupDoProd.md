# Backup lógico cifrado

`scripts/backup-logico.sh` gera um pacote v2 com `banco.dump` (pg_dump custom),
`extensoes.sql` (suplemento de dados de extensão) e `formato.txt`. Cifra o pacote
com chave pública, publica apenas `.tar.age`/`.tar.cms` e remove todos os claros.
Não usa Docker nem Supabase CLI. Complementa o ensaio local existente em
`scripts/ensaio-restauracao.sh`, que depende de Docker.

## Configuração e execução manual

Use Bash e bsdtar do macOS, Git, `psql` e `pg_dump` compatível com o servidor.
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
novos e legados. O bsdtar usa `--no-mac-metadata` para empacotar só os três arquivos.

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

## Configuração futura do prod e agendamento sugerido

Somente Cauê/Nick Fury configuram o prod: conexão no ambiente seguro, destinatário
público, pasta externa própria, custódia da chave privada e cópia dos arquivos
cifrados para armazenamento fora da máquina. Pasta fora do Git não garante cópia
fora da máquina. Validar antes no dev e medir restauração em destino isolado.

Sugestão **não ativada**: LaunchAgent `app.frila.backup-logico`, diariamente às
04:00, com `StartCalendarInterval` (`Hour=4`, `Minute=0`), `RunAtLoad=false` e
`ProgramArguments` apontando para um lançador local fora do Git. O lançador deve
definir PATH absoluto, obter a conexão pelo mecanismo seguro de Cauê e exportar as
variáveis acima antes de executar o script por caminho absoluto. Não colocar URL,
senha ou chave privada no plist/argumentos, nem usar `set -x`. Guardar stdout/stderr
somente do script em pasta restrita; monitorar código de saída e ausência de backup.
Não foi criado/carregado plist nem configurado serviço ou segredo do prod.
