# Runbook · O WAL do frila-prod e o slot do registro de acessos

Conferência diária e resposta a incidente do slot lógico `frila_registro_acesso` (registro de acessos, Marco Civil art. 15; migração `20261108110000`) e da pasta do WAL do Prod. Vale enquanto a coleta estiver ligada.

## 1. Por que isto importa: o disco é pequeno e o WAL anda sozinho

Medido no frila-prod em 08/11/2026, só leitura (Management API `config/disk` e `config/disk/util`, `pg_settings`, `pg_ls_waldir()` e duas amostras de `pg_current_wal_lsn()` com 10 min de intervalo):

| Medida | Valor |
|---|---|
| Plano e disco | plano free; gp3 de **2 GB**, com 336 MB usados e 1,74 GB livres |
| Bancos | 55 MB no total; a pasta do WAL tinha 8 arquivos e 96 MB |
| `archive_timeout` | **2 min**: fecha um segmento de 16 MB a cada 2 min, mesmo sem escrita |
| Ritmo do WAL | **~474 MB/h** (80 MB em 10,1 min); é o que um slot parado retém |
| `max_slot_wal_keep_size` | **1 GB** (override desde 08/11, 19:31; a plataforma não aceita menos) |
| `min_wal_size` / `max_wal_size` | 1 GB / 4 GB. O `max_wal_size` é maior que o disco: um risco da plataforma, anterior ao slot |

Um slot lógico segura todo o WAL desde o `restart_lsn` dele. Parado, ele retém ~480 MB/h.

**Três defesas, em ordem:**
1. **Autoproteção:** o job `consumir_registro_acesso`, a cada minuto, derruba o slot com atraso acima de `teto_wal_mb` (128 MB, ~16 min de WAL) e registra o buraco (`registro_acesso_buraco` em `privado.falha_execucao`, motivo `slot_acima_do_teto`).
2. **Alertas:** a `verificar_saude`, a cada 5 min, emite `registro_acesso_wal_atrasado` (atraso acima da metade do teto) e `registro_acesso_parado` (sem consumo há mais de 15 min).
3. **O servidor:** acima de 1 GB retido, o Postgres invalida o slot (`wal_status = lost`). Leva ~2 h a partir do slot parado.

As defesas 1 e 2 rodam no `pg_cron`. **Se o `pg_cron` parar, só a 3 protege o disco, e nada avisa ninguém** (desenho do alerta externo: `docs/desenho-alerta-pg-cron-parado.md`).

## 2. A pasta do WAL não encolhe depois de uma invalidação

Medido em 08/11/2026 pelo revisor da A3 v4, num banco descartável:
- depois de reter ~1,1 GB e de o servidor marcar o slot `lost`, a pasta do WAL ficou em **1024 MB (64 arquivos)**, mesmo depois de 2 checkpoints sem slot;
- o Postgres **recicla** os segmentos até o `min_wal_size` em vez de apagá-los.

No Prod, com `min_wal_size = 1GB`:
- depois de um evento desses, o disco livre fica em **~0,7 GB de forma permanente** e não volta a 1,74 GB;
- um segundo evento reaproveita os mesmos arquivos e não soma.

**Inferência:** a pasta perto de 1 GB, com o slot saudável, é o rastro de um evento antigo, não um incidente novo. Confira a data do último `registro_acesso_buraco` em `privado.falha_execucao` (consulta 4 da seção 3).

## 3. Conferência diária (piloto) e depois de qualquer incidente do `pg_cron`

Uma vez por dia, junto da `docs/ChecagemDiariaProd.md`. Também logo depois de qualquer incidente do agendador (`docs/RUNBOOK-INCIDENTES.md`, seção 3) e antes e depois de manutenção da plataforma. Só leitura:

```sql
begin read only;
-- 1. A coleta e o slot. O atraso é medido pelo restart_lsn, que é o que retém o WAL.
select c.ligada, c.teto_wal_mb, c.consumido_em,
       round(extract(epoch from now() - c.consumido_em) / 60) as minutos_sem_consumo,
       s.slot_name, s.active, s.wal_status,
       round(pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn) / 1048576.0) as atraso_mb,
       round(s.safe_wal_size / 1048576.0) as folga_ate_invalidar_mb
  from privado.registro_acesso_coleta c
  left join pg_replication_slots s on s.slot_name = privado.slot_registro_acesso()
 where c.unica;
-- 2. A pasta do WAL e os tetos.
select count(*) as arquivos_wal, round(sum(size) / 1048576.0) as pasta_wal_mb from pg_ls_waldir();
select name, setting, unit from pg_settings
 where name in ('max_slot_wal_keep_size', 'min_wal_size', 'max_wal_size', 'archive_timeout') order by name;
-- 3. O agendador: a última rodada boa dos jobs que protegem e vigiam o slot.
select j.jobname, j.active, max(d.end_time) filter (where d.status = 'succeeded') as ultima_rodada_ok
  from cron.job j
  left join cron.job_run_details d on d.jobid = j.jobid and d.start_time > now() - interval '1 day'
 where j.jobname in ('consumir_registro_acesso', 'verificar_saude')
 group by 1, 2 order by 1;
-- 4. Falhas e buracos do registro (sem dado pessoal). O buraco traz o motivo e o intervalo perdido.
select codigo, count(*), max(criada_em) from privado.falha_execucao
 where codigo like 'registro_acesso_%' and criada_em > now() - interval '1 day' group by 1 order by 1;
select criada_em, detalhes ->> 'motivo' as motivo, detalhes ->> 'desde' as desde, detalhes ->> 'ate' as ate,
       detalhes ->> 'recriado' as recriado
  from privado.falha_execucao where codigo = 'registro_acesso_buraco' and criada_em > now() - interval '7 days'
 order by criada_em desc;
select codigo, ultimo_em, suprimidos from privado.alerta_emitido where codigo like 'registro_acesso_%' order by 2 desc;
rollback;
```

E o disco, fora do banco, pela Management API: `GET /v1/projects/hbjkkcenbudiezmamiak/config/disk/util` devolve `fs_size_bytes`, `fs_used_bytes` e `fs_avail_bytes`.
- Em 08/11 funcionou com o token de 24 h da janela (permissões FGA de Edge Functions, segredos, chaves e `database_config`). A permissão exata dessa rota não foi isolada.
- **Não conferido:** onde o painel mostra o mesmo número.

| Veredito | Critério |
|---|---|
| 🟢 VERDE | coleta `ligada`; slot `active` ou entre rodadas, com `wal_status = reserved`; atraso abaixo de 64 MB (metade do teto); sem consumo há menos de 15 min; os 2 jobs `active`, com rodada boa nos últimos 10 min; disco com mais de 0,6 GB livres |
| 🟡 AMARELO | atraso entre 64 e 128 MB; ou pasta do WAL perto de 1 GB com o slot saudável (rastro de evento antigo, seção 2); ou disco entre 0,3 e 0,6 GB livres |
| 🔴 VERMELHO | `wal_status` `unreserved` ou `lost`; coleta ligada **sem** slot; sem consumo há mais de 15 min; um dos 2 jobs inativo ou sem rodada boa há mais de 15 min; disco abaixo de 0,3 GB livres |

**Sobre o `wal_status` neste Prod:** como o `max_wal_size` (4 GB) é maior que o teto do slot (1 GB), o `extended` não deve aparecer. O caminho é `reserved` → `unreserved` (passou de 1 GB; o próximo checkpoint apaga) → `lost` (inferência pela documentação do PostgreSQL 17, não medida no Prod).

## 4. O que fazer

- **Atraso subindo com o job rodando** (🟡): a autoproteção derruba em 128 MB e registra o buraco. Conferir em `cron.job_run_details` se o `consumir_registro_acesso` está `succeeded`, e ler a `return_message` das falhas.
- **`pg_cron` parado ou job inativo** (🔴): seguir a seção 3 do `docs/RUNBOOK-INCIDENTES.md`. Com o job parado, o slot cresce ~480 MB/h e chega a 1 GB em ~2 h.
  - **Se o agendador não volta logo, desligar a coleta.** É o que libera o disco: a chave vira, o slot cai, e nada mais retém WAL.
    - Comando: `select privado.definir_coleta_registro_acesso(false);`, pelo `service_role`.
    - Rodar entre os segundos :15 e :45 do minuto. A função não protege o `drop`: com o slot em uso, a transação inteira volta e a coleta segue ligada ("is active"). Nesse caso, repetir depois de 15 s.
  - Religar só com a causa resolvida e o teto conferido (o `ligar` exige o `max_slot_wal_keep_size` de 1 GB lido de volta).
- **Slot `lost` ou buraco registrado** (`registro_acesso_buraco`, com motivo `slot_invalidado`, `slot_acima_do_teto` ou `slot_ausente`): o intervalo de `desde` a `ate` não foi registrado.
  - A autoproteção recria o slot na rodada seguinte.
  - Anotar o intervalo no log de plantão, porque é um buraco no registro do Marco Civil. Avisar o dono.
- **Nunca chamar `privado.consumir_registro_acesso()` à mão com o job ativo.** A disputa pelo slot dá `55006`, vira `registro_acesso_consumo_falhou` e alerta a equipe.
- **Antes de qualquer upgrade do Postgres pelo painel, desligar a coleta.** Um slot lógico atrasado barra o `pg_upgrade` (inferência; não executado).
- **Voltar o teto** (só com a coleta desligada e com decisão do dono): `supabase --experimental postgres-config delete --config max_slot_wal_keep_size --no-restart`. Ele volta ao padrão de 2 GB, que no disco de 2 GB enche antes de o teto agir.

## 5. Quem decide e quem age

- **Age:** o plantonista do dia roda a conferência e, no 🔴, desliga a coleta e segue o runbook do `pg_cron`.
- **Decide:** o Cauê decide religar a coleta, apagar ou anotar um buraco, mudar o teto e subir de plano ou de disco. O que for mudança de banco vira migração nova (`docs/RunbookHotfixERollback.md`).
