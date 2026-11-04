# Verificação de Identidade: tabela, HMAC e expurgo de mídia

Guia operacional do que a migração `20261104110000_verificacao_identidade.sql` criou.
Cartão `aEqry9vB` · RN14, RN13 · requisitos em
`frila-docs/requisitos/verificacao-progressiva-rn14.md`.

> **O que existe e o que não existe.** Existem a tabela, o enum, o selo, a função de HMAC,
> a fila e as duas funções do expurgo. **Não existem** RPC de upload, política de `INSERT`
> no bucket, Edge Function de remoção, telas nem fluxo. Nenhuma conta tem exigência aberta:
> ausência de linha significa `nao_exigida`, e a migração não insere linha para ninguém.

---

## 1. Antes de qualquer envio real: o segredo

```bash
# Uma vez por ambiente, e nunca em migração nem em arquivo versionado.
psql "$SUPABASE_DB_URL" -c "select vault.create_secret('<pepper-longo-e-aleatorio>', 'documento_pepper')"
```

Sem o segredo `documento_pepper` no Vault, `privado.documento_hmac` levanta `pepper_ausente`
(`P0002`) e a verificação não grava linha. **É intencional:** gravar sem hash seria
deduplicação que não acontece, e ninguém descobriria até o segundo cadastro com o mesmo RG
ser aprovado.

**Trocar o pepper invalida todos os hashes anteriores** e, com eles, a deduplicação. Não há
como recalcular: o Frila não guarda o número do documento. Trate a rotação como migração de
dados, não como ajuste operacional.

## 2. A tabela

`privado.verificacao_identidade`, no schema `privado`: RLS ligado, sem política, sem grant
para `anon` e `authenticated`. `service_role` lê, insere e atualiza — **não apaga**, porque
a linha é registro de apuração (RNF13). O que sai é a mídia.

| Nível | Quem dispara | Precisa de motivo | Observação |
|---:|---|---|---|
| 2 | Moderação, após denúncia grave apurada (RN13) | Sim, `check` recusa em branco | `ocorrencia_id` aponta a denúncia |
| 3 | O próprio profissional | Não | Voluntário; resulta no selo |

O nível 1 (onboarding leve) não registra nada, e o nível 4 é do contratante e não entra
aqui. O `check` recusa qualquer outro valor.

Índices que são regra, não desempenho:

- `verificacao_identidade_aberta_unica` — uma exigência aberta por conta e nível. Duas
  linhas `pendente` seriam duas contagens de prazo para o mesmo pedido.
- `verificacao_identidade_documento_aprovado_unico` — o mesmo documento não é **aprovado**
  em duas contas. Duas análises com o mesmo documento convivem de propósito: barrar no
  envio diria a um fraudador qual documento já está em uso.

## 3. O expurgo é em duas fases, e a razão importa

**Apagar a linha de `storage.objects` não apaga o byte no Storage.** O arquivo vive no
backend de objetos e quem o remove é a API do Storage. Uma rotina que fizesse
`delete from storage.objects` e devolvesse "expurgado: 12" entregaria o pior resultado
possível em LGPD: o registro de que a foto foi apagada, com a foto no bucket — e, pior, sem
o índice que permitiria achá-la depois.

```
privado.expurgar_midias_verificacao_identidade(p_limite integer default 200)
   │  seleciona expurgo_midia_em <= agora() com caminho de mídia
   │  envia para a fila pgmq `expurgo_midia`
   │  marca expurgo_pedido_em e incrementa expurgo_tentativas
   ↓
Edge Function (a escrever, cartão próprio) com service_role
   │  lê a fila, apaga os objetos no bucket documentos-identidade
   ↓
privado.confirmar_expurgo_midia(p_id uuid)
      anula os três caminhos e grava expurgo_feito_em (idempotente)
```

O passo entra na rotina diária que já existe (`privado.executar_retencao_diaria()`, job
`retencao_e_limpeza_diaria`, 06:30 UTC). **Não há cron novo**, de propósito: um job próprio
seria um segundo lugar para olhar quando a mídia não sai.

### O silêncio, e como ele é quebrado

Se a Edge Function nunca confirmar, a linha fica com caminho e sem `expurgo_feito_em` — foto
vencida no bucket, sem ninguém sabendo. Por isso:

- o pedido é **reenfileirado** a cada 24 h sem confirmação;
- da **quinta** tentativa em diante, cada rodada registra em `privado.falha_execucao` com
  `codigo = 'expurgo_midia_nao_confirmado'`, que é o que o monitoramento já lê.

```sql
-- O que está vencido e ainda não saiu do bucket
select id, usuario_id, expurgo_midia_em, expurgo_tentativas
  from privado.verificacao_identidade
 where expurgo_feito_em is null
   and expurgo_midia_em <= privado.agora()
 order by expurgo_midia_em;

-- Atrasos já registrados
select criada_em, detalhes
  from privado.falha_execucao
 where codigo = 'expurgo_midia_nao_confirmado'
 order by criada_em desc;
```

## 4. Prazos

| Mídia | Prazo | Quem grava `expurgo_midia_em` |
|---|---|---|
| Documento com desfecho (aprovada ou rejeitada) | 30 dias do desfecho | Quem registra o desfecho |
| Documento sem desfecho de análise | 15 dias da solicitação, teto preventivo | Quem cria a linha |
| Selfie do nível 3 | Não persiste | — |

O `check verificacao_midia_tem_prazo` recusa linha com caminho de mídia e sem prazo: prazo
que depende de alguém lembrar não acontece.

## 5. Testes

```bash
supabase test db   # ou: a suíte 793 isolada
```

`supabase/tests/793_verificacao_identidade.sql`, 56 asserções: catálogo, invariantes de RLS
do schema `privado`, as constraints de coerência, a deduplicação, o HMAC (pepper ausente,
pontuação, tamanho do digest, ausência de coluna com número em claro) e o expurgo em duas
fases, incluindo a prova de que **enfileirar não anula o caminho**.

## 6. O que falta, e em que ordem

1. Parecer jurídico sobre conservar `documento_hmac` após pedido de eliminação (LGPD art. 18, VI) — **antes** de qualquer envio real.
2. RPCs do contrato (`minha_identidade_status`, `iniciar_verificacao_identidade`, `confirmar_envio_verificacao`), que nascem no `frila-docs`.
3. Política de `INSERT` no bucket por `auth.uid()`, junto com a RPC de upload.
4. Edge Function de remoção no Storage, que fecha o ciclo do expurgo.
5. Telas de captura e selo no iOS e Android.

Enquanto 4 não existir, **nenhuma mídia deve ser enviada ao bucket**: a fila acumularia
pedidos que ninguém executa, e o prazo de 30 dias venceria sem expurgo.
