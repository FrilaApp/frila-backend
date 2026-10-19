# Procedimento operacional: Revisão de despacho ("Por que recebo vagas")

Quando um profissional contesta o recebimento (ou a falta de recebimento) de vagas pelo app na tela "Por que recebo vagas" (RF27, LGPD art. 20).

A chamada a `public.pedir_revisao_despacho(relato)` registra uma ocorrência com `tipo = 'revisao_despacho'`, gera protocolo oficial e enfileira notificação na fila interna `email` do `pgmq`.

O prazo regulamentar para resposta ao profissional é de **até 5 dias úteis** contados a partir da data de criação do pedido (`prazo_resposta_ate`, calculado via `privado.prazo_de_resposta`).

---

## 1. Localizar pedidos pendentes

Pelo painel do Supabase ou via chave de serviço (`service_role`):

```sql
select o.id as ocorrencia_id,
       o.criada_em,
       privado.prazo_de_resposta(o.criada_em) as prazo_limite,
       u.nome as profissional_nome,
       u.telefone as profissional_telefone,
       o.relato
  from public.ocorrencia o
  join public.usuario u on u.id = o.autor_id
 where o.tipo = 'revisao_despacho'
   and o.resolvido_em is null
 order by o.criada_em asc;
```

> **Atenção:** A coluna `relato` contém dados pessoais do profissional (LGPD / Diretriz 1.2 da App Store) e só deve ser acessada por operadores autorizados pela chave de serviço.

---

## 2. Roteiro de diagnóstico

Para o profissional reclamante (`autor_id`), verifique os cinco critérios do motor de despacho:

1. **Funções cadastradas:**
   ```sql
   select f.nome
     from public.profissional_funcao pf
     join public.funcao f on f.id = pf.funcao_id
    where pf.profissional_id = (select id from public.profissional where usuario_id = '<autor_id>');
   ```
   *Verificar se as funções batem com as vagas abertas na região.*

2. **Disponibilidade semanal:**
   ```sql
   select dia_semana, hora_inicio, hora_fim
     from public.disponibilidade
    where profissional_id = (select id from public.profissional where usuario_id = '<autor_id>')
    order by dia_semana, hora_inicio;
   ```
   *Vagas fora da grade cadastrada não geram despacho.*

3. **Raio e Ponto Base (15 km - RN05):**
   ```sql
   select ponto_base,
          st_astext(ponto_base) as ponto_wkt
     from public.profissional
    where usuario_id = '<autor_id>';
   ```
   *O despacho padrão alcança vagas num raio de até 15 km do ponto base cadastrado.*

4. **Equipes de Confiança:**
   ```sql
   select e.nome as estabelecimento, e.id as estabelecimento_id
     from public.equipe_confianca ec
     join public.estabelecimento e on e.id = ec.estabelecimento_id
    where ec.profissional_id = (select id from public.profissional where usuario_id = '<autor_id>');
   ```
   *Membros de equipe de confiança recebem vagas do estabelecimento mesmo além do raio de 15 km.*

5. **Cadência de notificações (RN23):**
   ```sql
   select id, enviada_em
     from public.notificacao
    where usuario_id = '<autor_id>'
    order by enviada_em desc
    limit 10;
   ```
   *O sistema aplica o teto de no máximo 1 notificação a cada 30 minutos.*

6. **Bloqueios mútuos (RN13):**
   ```sql
   select *
     from public.bloqueio
    where autor_id = '<autor_id>' or bloqueado_id = '<autor_id>';
   ```
   *Bloqueios ativos impedem qualquer visibilidade mútua de vagas.*

---

## 3. Resposta e Conclusão

1. Responda ao profissional pelo e-mail/canal cadastrado informando o diagnóstico técnico de forma transparente e amigável (conforme LGPD art. 20).
2. Registre o encerramento do chamado na ocorrência com o parecer:

```sql
update public.ocorrencia
   set resolvido_em = now(),
       resultado    = 'Explicado ao profissional os critérios de disponibilidade e raio vigentes.'
 where id = '<ocorrencia_id>'
   and resolvido_em is null;
```
