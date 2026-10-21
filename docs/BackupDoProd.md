# Backup lógico cifrado

`scripts/backup-logico.sh` gera um arquivo custom do `pg_dump` com esquema e dados,
cifra com chave pública, publica apenas o arquivo cifrado e remove o dump em claro.
Não usa Docker nem Supabase CLI. Complementa o ensaio local existente em
`scripts/ensaio-restauracao.sh`, que depende de Docker.

## Configuração e execução manual

Use Bash do macOS, Git e `pg_dump` compatível com a versão do servidor (cliente mais
antigo não exporta servidor mais novo). No brew, o cliente 16 fica em
`/opt/homebrew/opt/postgresql@16/bin`. Precisa de conexão PostgreSQL com permissão
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
export PATH="/opt/homebrew/opt/postgresql@16/bin:/opt/homebrew/bin:$PATH"
export BACKUP_DIR="$HOME/Backups/frila-dev"
export BACKUP_CIPHER=openssl
export BACKUP_PUBLIC_KEY="$HOME/.config/frila/backup/publica.pem"
export BACKUP_KEEP=14
./scripts/backup-logico.sh
unset BACKUP_DB_URL
```

Para age, selecione `BACKUP_CIPHER=age` e carregue o destinatário público em
`BACKUP_PUBLIC_KEY`. O script exige a conexão em `BACKUP_DB_URL`; não lê arquivos
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

## Ensaio sintético e tentativa no dev real

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

**TENTADO E BLOQUEADO: frila-dev real, em 20/10/2026.** Após autorização de Cauê,
a conexão do session pooler foi carregada de `~/.config/frila/dev-db-url` somente
para uso em memória/ambiente, sem imprimir ou registrar seu conteúdo. Executados
apenas SELECTs de metadados e uma tentativa do script com `pg_dump`; nenhuma
escrita no dev e nenhum acesso ao prod.

O servidor informou **PostgreSQL 17.6**; o cliente instalado é **16.13 Homebrew**.
O `pg_dump` recusou o servidor por incompatibilidade de versão, com código **1**:

| Etapa no dev real | Tempo medido | Resultado |
| --- | ---: | --- |
| Tentativa de `pg_dump` custom | 0,3665 s | Código 1; 0 bytes |
| Script completo, incluindo preflight da cifra e limpeza | 1,0238 s | Código 1; pasta de saída vazia |
| Cifrar/decifrar dump real | Não executado | Nenhum dump gerado |
| Restaurar dados reais em destino descartável | Não executado | Depende do dump |

Preflight OpenSSL executado com certificado temporário. Temporários, certificado
e chave de ensaio removidos; nenhum cluster adicional foi iniciado nesta tentativa.
A limpeza e a saída sem credencial foram conferidas. O ensaio sintético acima é
a única restauração concluída; seus tempos não representam o dev real.

Para retomar, provisionar **pg_dump 17 ou superior compatível com o servidor** e
um destino descartável compatível. O Postgres 16 puro do brew não comprova essa
compatibilidade: o dev tem `supabase_vault` 0.3.1, `postgis` 3.3.7, `pg_net` 0.20.4,
`pgmq` 1.5.1 e `pg_cron` 1.6.4, além das extensões comuns. É necessário validar
essas extensões e as roles/ACLs no destino isolado; não foi feita tentativa de
restauração nem afirmada uma falha específica dessas extensões. Não filtrar o
archive nem criar substitutos silenciosamente para declarar restauração completa.

Com as dependências resolvidas, Cauê ou um operador autorizado pode carregar a
conexão sem colocá-la no histórico e executar o comando da seção inicial:

```bash
set +x
export BACKUP_DB_URL="$(cat "$HOME/.config/frila/dev-db-url")"
# Ajuste PATH para o cliente compatível, pasta externa e certificado público.
./scripts/backup-logico.sh
unset BACKUP_DB_URL
```

Depois, decifrar e restaurar conforme a seção anterior, exclusivamente no destino
descartável. Medir e conferir os dados antes de considerar o ensaio aprovado.
O caminho age também não foi executado, pois age não está instalado.

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
