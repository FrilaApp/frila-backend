# Canal do titular (LGPD art. 18): o atendimento passo a passo

Como a Equipe Frila atende o pedido de um titular sobre os próprios dados: acesso, exclusão e as conferências depois da exclusão. O modelo da resposta é o **Modelo D** de [`equipe-frila.md`](equipe-frila.md), seção 7. O texto jurídico do canal fica em `frila-docs/juridico/canal-do-titular.md`.

---

## 1. Regras de uso

- Só responde se o pedido veio do e-mail cadastrado na conta. Se veio de outro endereço, pede que a pessoa escreva do e-mail da conta, e não manda nenhum dado.
- **Prazos:** triagem em até 5 dias úteis. O acesso completo sai em até 15 dias corridos, contados do pedido (LGPD, art. 19, II). Correção e exclusão também saem em até 15 dias corridos, pelo SLA do Frila.
- O anexo de acesso é gerado pela `exportar-meus-dados` da própria conta. Nunca copiar dado à mão para o corpo do e-mail.
- Não citar dado de outra pessoa. Também não citar quem denunciou, quem bloqueou nem o motivo de suspensão (RN15).
- Guardar o pedido e a resposta, que vão na mesma conversa, por 5 anos (`canal-do-titular.md`, 2.9). **Se a pessoa excluir a conta**, vale o 2.9: os e-mails dela saem 15 dias depois da anonimização, e fica só o pedido de exclusão, com a resposta, por 5 anos (decisão da Bússola, 17/11/2026: o 2.9 prevalece sobre esta regra geral).

> **Divergência aberta:** a regra geral dos 5 anos acima conflita com a seção 6 de `equipe-frila.md`: o item 2 manda apagar o e-mail ao fechar o chamado, e o item 3 manda purgar tudo o que for da conta excluída (o 2.9 guarda o pedido de exclusão e a resposta). O caso da conta excluída já está decidido no item acima. Até a decisão da regra geral, o pedido do titular e a resposta ficam guardados.

---

## 2. O pedido chega ao `suporte@frilabr.com`

1. Ache a conta pelo e-mail do remetente (só leitura):
   ```bash
   psql -v email="<e-mail do remetente>" <<'SQL'
   begin read only;
   select id, estado, demonstracao from public.usuario where email = :'email';
   rollback;
   SQL
   ```
   - Nenhuma linha: o remetente não é o e-mail de nenhuma conta. Responda pedindo que escreva do e-mail cadastrado, sem dado nenhum.
   - `demonstracao = t`: é conta da revisão da Apple. Não atenda por aqui; avise os sócios.
2. Anote o protocolo (`[PROTOCOLO]` do Modelo D) e a data do pedido. O prazo corre dessa data.

## 3. Acesso (cópia dos dados)

- **Pelo app** (o caminho normal): o titular toca em "Perfil → Exportar meus dados". A Edge Function `exportar-meus-dados` devolve o arquivo no corpo da resposta, com `Cache-Control: no-store`, e não guarda cópia.
- **Pelo e-mail:** o anexo é o mesmo JSON. Ele sai de `privado.meus_dados(<uuid>)`, a função que a `exportar-meus-dados` chama (`supabase/functions/exportar-meus-dados/index.ts`):
  ```bash
  psql -q -At -v uid="<uuid da conta>" > "<pasta fora do repositório>/frila-dados-<protocolo>.json" <<'SQL'
  begin read only;
  select privado.meus_dados(:'uid'::uuid);
  rollback;
  SQL
  ```
  Anexe o arquivo à resposta (Modelo D, bloco "Acesso") e apague o arquivo local depois do envio.

## 4. Exclusão

- **Pelo app** (o caminho normal): "Perfil → Excluir conta". A Edge Function `excluir-conta` registra o pedido (`privado.registrar_pedido_de_exclusao`), anonimiza (`privado.excluir_conta`) e apaga a credencial no Auth.
- **Pelo e-mail:** a equipe faz os mesmos três passos, na mesma ordem, depois de conferir no passo 2 que a conta não é de demonstração:
  ```bash
  # 1 e 2, cada um na sua transação (como a Edge Function): o registro do pedido fica mesmo se a exclusão falhar,
  # e o ON_ERROR_STOP para tudo se o registro falhar (a exclusão não roda sem o registro).
  psql -v ON_ERROR_STOP=1 -v uid="<uuid da conta>" <<'SQL'
  select privado.registrar_pedido_de_exclusao(:'uid'::uuid);
  select privado.excluir_conta(:'uid'::uuid);
  SQL
  # 3. Apagar a credencial: DELETE /auth/v1/admin/users/<uuid> com a chave de serviço (nunca na linha de comando nem no log).
  ```
  O retorno de `excluir_conta` traz `perfil_removido_em` e `dados_apagados_ate`. Use a data de `perfil_removido_em` em `[DATA]` no bloco "Exclusão" do Modelo D.

## 5. Conferir a anonimização (só leitura)

```bash
psql -v uid="<uuid da conta>" <<'SQL'
begin read only;
select u.estado, u.nome = 'Conta encerrada' as nome_trocado, u.email is null as email_apagado,
         u.telefone is null as telefone_apagado, u.anonimizado_em,
         exists (select 1 from auth.users a where a.id = u.id) as credencial_no_auth,
         (select e.estado from public.pedido_de_exclusao e where e.usuario_id = u.id order by e.pedido_em desc limit 1) as pedido
  from public.usuario u where u.id = :'uid'::uuid;
rollback;
SQL
```

Esperado: `anonimizada | t | t | t | <data> | f | concluido`.

## 6. Conferir a limpeza dos 15 dias (consulta de retenção, só leitura)

A exclusão apaga na hora o nome, o e-mail, o telefone e os aparelhos. O resto (nascimento, ponto base, disponibilidade, funções, regiões, serviços, fotos e outras mídias da pessoa) sai na rotina diária `retencao_e_limpeza_diaria` (pg_cron, `30 6 * * *`, UTC), quando `anonimizado_em` fica 15 dias para trás. A primeira rodada que limpa é a primeira execução do job em ou depois de `anonimizado_em + 15 dias`.

```bash
psql -v uid="<uuid da conta>" <<'SQL'
begin read only;
select u.anonimizado_em, u.anonimizado_em::date + 15 as dados_apagados_ate,
         u.anonimizado_em + interval '15 days' as limpeza_liberada_em,
         (u.nascimento is not null) as nascimento_presente,
         (select count(*) from public.disponibilidade d join public.profissional p on p.id = d.profissional_id
           where p.usuario_id = u.id) as disponibilidades,
         (select count(*) from public.profissional_funcao f join public.profissional p on p.id = f.profissional_id
           where p.usuario_id = u.id) as funcoes,
         (select j.schedule from cron.job j where j.jobname = 'retencao_e_limpeza_diaria') as agenda_utc
  from public.usuario u where u.id = :'uid'::uuid;
rollback;
SQL
```

- Antes da data: `nascimento_presente = t` e as contagens acima de zero (quando a pessoa tinha perfil).
- Depois da primeira rodada que limpa: `nascimento_presente = f` e as contagens em `0`.

## 7. Se a limpeza falhar: os alertas

Os alertas já existem; não há alerta novo para o canal do titular.

- Um passo da retenção que falha vai para `privado.falha_execucao` (origem `executar_retencao_diaria`, código `retencao_passo_falhou`, com o passo e o SQLSTATE). Os outros passos rodam mesmo assim.
- O job `verificar_saude` (a cada 5 min) conta essas falhas dos últimos 15 min e manda o alerta `falha_execucao_edge_function` à equipe por e-mail (no máximo 1 por hora por tipo).
- Se o job inteiro falha, o alerta é `job_cron_falhou` (pelo `cron.job_run_details`).
- Diagnóstico e conserto: `docs/RUNBOOK-INCIDENTES.md`, seção 3.

## 8. Fechar o atendimento

1. Responda pelo Modelo D, do `suporte@frilabr.com`, só ao e-mail cadastrado.
2. Guarde o pedido e a resposta (seção 1).
3. Na exclusão, volte à seção 6 depois da data e confira que a limpeza rodou.
