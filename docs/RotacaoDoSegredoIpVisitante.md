# Segredo do IP do visitante da web (HMAC): contrato, ativação e rotação

O Worker da web (`frila-web`) passa ao banco o IP que ele recebeu do visitante, assinado, para o registro de acesso (Marco Civil, art. 15; ADR-002 "Acesso pela versão web"). Sem assinatura válida o banco grava o `cf-connecting-ip` (o IP do Worker), como antes: um IP forjado nunca entra. Código: `privado.ip_do_acesso` e `privado.avaliar_ip_do_acesso` (migração `20261124180000`), chamadas por `requisicao.conferir_limite()` só quando existe um cabeçalho `x-frila-ip-*`.

## Contrato Worker ↔ banco

Três cabeçalhos, sempre juntos, na subrequest do Worker ao Supabase (nunca na resposta ao navegador):

| Cabeçalho | Valor |
|---|---|
| `x-frila-ip-visitante` | o texto CRU do `CF-Connecting-IP` recebido, sem normalizar (IPv4 ou IPv6 literal, sem máscara) |
| `x-frila-ip-carimbo` | segundos Unix UTC, inteiro |
| `x-frila-ip-assinatura` | `v1;k=<id>;<hex>` |

- `v1` é a versão do formato. `<id>` é o identificador da chave (`[a-z0-9]{1,16}`, por exemplo `a1`). `<hex>` é o HMAC-SHA256 em hex minúsculo (64 caracteres).
- Mensagem assinada (bytes UTF-8): `v1|<ip cru>|<carimbo>|<uid>`, com `uid` = `sub` (UUID, minúsculas) do token que vai NAQUELA chamada.
- Chave do HMAC: os bytes UTF-8 do TEXTO do segredo, exatamente como guardado no Vault (o hex gerado, sem decodificar).
- O banco confere sobre o texto cru, antes de converter para `inet` (o `inet::text` reescreve IPv6). Aceita o carimbo até 60 s para trás ou para frente do relógio real do banco.
- Recusa (e grava o `cf-connecting-ip`): formato ruim, IP com máscara, carimbo fora da janela, IP reservado (loopback, privado, link-local, não especificado, `240.0.0.0/4`, IPv6 `::1`, `fc00::/7`, `fe80::/10`; para `::ffff:a.b.c.d` vale o IPv4 embutido), chave desconhecida, assinatura que não confere.
- A zona `frilabr.com` precisa estar com Pseudo IPv4 "Off" ou "Add header", nunca "Overwrite Headers" (ele reescreve o IPv6 do visitante para `240.0.0.0/4`).

## Falhas: contagem AMOSTRADA

Cada cabeçalho que não valeu emite `frila_registro_acesso_falha` com só o motivo (`formato`, `carimbo_vencido`, `ip_reservado`, `chave_desconhecida`, `sem_segredo`, `assinatura_invalida`, `erro_interno`): sem IP e sem cabeçalho. A emissão é amostrada em 1 de 20 (`random() < 0.05`), porque o pre-request não escreve e uma conta autenticada poderia inflar o WAL do slot. **O alerta `registro_acesso_falhou` conta ~20 vezes menos eventos do que aconteceram**: leia o limiar com essa conta (50 falhas em uma rodada = ~1.000 requisições). O teto do slot (1 GB, `proteger_slot_registro_acesso`) segue como última defesa. Quem vê o alerta subir logo depois de uma ativação ou rotação suspeita de ordem errada (secção abaixo).

## Ativação (primeira vez) e ordem obrigatória

`migração → segredo no Vault → secret e id no Worker → deploy da web`. Se a web assinar antes de o banco ter a chave, o alerta sobe à toa; por isso o Worker não manda cabeçalho nenhum quando o secret não existe (local, testes).

1. Gere o segredo sem mostrá-lo: `openssl rand -hex 32` para um arquivo ignorado pelo git ou direto em uma variável do shell. Nunca em commit, PR, log ou conversa.
2. Grave no Vault do ambiente (SQL como `postgres`, com o valor vindo de variável do psql, por heredoc ou `-f`; `psql -c` não interpola `:var`):
   ```sql
   select vault.create_secret(:'valor', 'ip_visitante_hmac_a1');
   ```
3. No Worker: `secret put` do mesmo valor e o id (`a1`) como `var`, e publique (pelo `orquestracao/scripts/wrangler-frila`, sem `wrangler login`).
4. Prova no `frila-web-dev` publicado (local o `CF-Connecting-IP` falta ou é loopback): um acesso pela web grava o IP real em `privado.registro_acesso`, e o gateway do Supabase repassa os `x-frila-*` ao `request.headers`.

## Rotação sem queda

1. Gere outro segredo e grave como NOVO id: `select vault.create_secret(:'valor', 'ip_visitante_hmac_b2');`. O banco aceita qualquer id que exista no Vault, então agora aceita a1 e b2.
2. No Worker: `secret put` do valor novo e troca do `var` do id para `b2`; publique. Daqui em diante o Worker assina com b2.
3. Espere 24 h (cobre Worker em cache e requisições em voo; o carimbo vale 60 s, então o risco real é bem menor).
4. Retire a chave velha: `delete from vault.secrets where name = 'ip_visitante_hmac_a1';`. Uma assinatura com `k=a1` passa a cair em `chave_desconhecida`.

Vazou o segredo: pule a espera. Faça os passos 1 e 2 e apague a chave velha na hora (as requisições com `k=a1` caem no IP do Worker, sem perder acesso); depois avise os sócios. Sem nenhuma chave no Vault o motivo é `sem_segredo`; com outras chaves e id fora delas, `chave_desconhecida`.

## Prova no banco

`supabase/tests/899_ip_real_da_web_hmac_no_registro_de_acesso.sql` cobre: assinatura válida, inválida, vencida e futura, cabeçalho ausente em parte, IP malformado e com máscara, `uid`, IP e carimbo trocados, duas chaves e id desconhecido, chave retirada, IPv6 sobre o texto cru, IP reservado, sem segredo, sem cabeçalho (igual a antes) e a amostragem das falhas.
