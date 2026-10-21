# Backup lógico cifrado

`scripts/backup-logico.sh` gera um arquivo custom do `pg_dump` com esquema e dados,
cifra com chave pública, publica apenas o arquivo cifrado e remove o dump em claro.
Não usa Docker nem Supabase CLI. Complementa o ensaio local existente em
`scripts/ensaio-restauracao.sh`, que depende de Docker.

## Configuração e execução manual

Use Bash do macOS, Git, `psql` e `pg_dump` compatível com a versão do servidor.
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
gerado e só remove nomes próprios `frila-backup-*.dump.age`/`.dump.cms` com formato
validado. Só roda após dump, cifra e remoção do claro bem-sucedidos. Arquivo cifrado
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

# Escolha UM comando, conforme a extensão do arquivo:
age --decrypt --identity "$CHAVE_PRIVADA" \
  --output "$tmp_restore/banco.dump" "$ARQUIVO_CIFRADO" >/dev/null 2>&1
# Ou, para .cms, em vez do comando age:
# openssl cms -decrypt -binary -inform DER -in "$ARQUIVO_CIFRADO" \
#   -recip "$CERTIFICADO_PUBLICO" -inkey "$CHAVE_PRIVADA" \
#   -out "$tmp_restore/banco.dump" >/dev/null 2>&1

pg_restore --exit-on-error --single-transaction --no-owner \
  --dbname "$RESTORE_DB_URL" "$tmp_restore/banco.dump" >/dev/null 2>&1
unset RESTORE_DB_URL
```

Se algum comando falhar, encerre a sessão de ensaio e investigue sem publicar saída
crua, que pode conter conexão ou conteúdo de linhas. Depois confira contagens,
hashes dos dados, constraints, índices, políticas RLS, sequências e permissões com
consultas que não exponham dados pessoais. Remova o destino descartável ao concluir.

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
| `pg_dump` custom | 0,0698 s | 297.028 bytes |
| Cifrar | 0,0074 s | 297.597 bytes |
| Decifrar | 0,0091 s | 297.028 bytes |
| `pg_restore` em banco vazio | 0,0572 s | 60.000 linhas |

Backup completo com validação do destinatário e limpeza: **0,6390 s**. Medições por
relógio monotônico externo ao script; a saída operacional do script usa segundos
inteiros. Hashes e estrutura restaurados conferidos, adulteração da cifra recusada,
retenção 14/2, falhas de dump/cifra e limpeza conferidas. Cluster desligado e
diretório temporário, dumps e chaves de ensaio apagados. Esses números medem apenas
a base sintética; não estimam duração nem recuperabilidade do Supabase real.

**Ensaio real com PostgreSQL 17 e age — 20/10/2026.** A conexão do session
pooler foi carregada em memória/ambiente a partir de `~/.config/frila/dev-db-url`,
com autorização de Cauê, sem imprimir ou registrar seu conteúdo. A origem foi
usada apenas para SELECTs em transação `REPEATABLE READ READ ONLY` e `pg_dump`.
As contagens e o dump compartilham um snapshot exportado dessa transação; o
wrapper de medição passa `--snapshot` ao cliente, sem alterar o script operacional.

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

Medições finais com age **1.3.2** (relógio monotônico externo ao script):

| Etapa real | Tempo medido | Tamanho |
| --- | ---: | ---: |
| `pg_dump` 17 custom | 50,8667 s | 2.818.278 bytes |
| Cifrar com age | 0,0097 s | 2.819.166 bytes |
| Decifrar com age | 0,0099 s | 2.818.278 bytes |
| `pg_restore` transacional | 1,7204 s | Código 0 |
| `initdb` isolado | 1,3239 s | Cluster novo |

Backup completo, incluindo preflight e limpeza: **52,0039 s**. Todos os
comandos de dump/cifra/decifra/restauração terminaram com código zero.
O TOC contém **81 itens TABLE DATA**; as extensões também criam tabelas.
Foram comparadas individualmente as **85 tabelas** do dev e do restaurado:
nenhuma ausente ou extra, **83 contagens iguais** e **2 divergentes**.
Total: **77.232 linhas no snapshot do dev**, **76.858 no restaurado**.
No schema `public`: **22 tabelas, 137 linhas em cada lado, zero divergências**.

| Divergência | Linhas no dev | Linhas restauradas | Causa |
| --- | ---: | ---: | --- |
| `net._http_response` | 372 | 0 | Tabela da extensão pg_net sem registro em `extconfig` |
| `pgmq.meta` | 2 | 0 | Tabela da extensão pgmq sem registro em `extconfig` |

**Resultado parcial:** restauração do archive executada e dados de `public`
conferidos; recuperação completa do banco/filas **não aprovada** devido às
omissões acima. Nenhum metadado foi fabricado nem reposto consultando linhas
reais da origem para mascarar a diferença. Um suplemento cifrado desses dados
ou outra estratégia validada precisa ser definido antes de usar como backup
completo. As contagens são do snapshot do ensaio, sem estimar duração do prod.

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

**Limite confirmado antes de adotar como backup completo:** tabelas pertencentes
a uma extensão só têm dados incluídos automaticamente se a extensão as registrar
como configuração, conforme a [documentação do PostgreSQL](https://www.postgresql.org/docs/17/extend-extensions.html#EXTEND-EXTENSIONS-CONFIG-TABLES).
No dev, `pgmq.meta` e as tabelas do `pg_net` não estão registradas assim. A prova de
restauração comparou todas as tabelas, inclusive essas, e encontrou as divergências acima;
não preencher metadados artificialmente para declarar recuperação completa.
Chaves do Vault e binários do Storage também continuam fora do dump lógico.

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
