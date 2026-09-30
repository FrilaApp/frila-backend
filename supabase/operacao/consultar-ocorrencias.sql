-- supabase/operacao/consultar-ocorrencias.sql
--
-- Consulta a fila de ocorrências da Equipe Frila ordenadas por prioridade:
-- denúncias (< 24h para moderação da Diretriz 1.2) e chamados pelo prazo legal (5 dias úteis).
--
-- Uso no psql:
--   psql -f supabase/operacao/consultar-ocorrencias.sql
--
-- Ou no Supabase Studio SQL Editor (com perfil service_role).

select o.id as ocorrencia_id,
       o.tipo,
       o.motivo,
       o.criada_em,
       privado.prazo_de_resposta(o.criada_em) as prazo_limite,
       case
         when o.tipo = 'denuncia' and o.criada_em + interval '24 hours' < now() then 'URGENTE: prazo 24h vencido'
         when o.tipo = 'denuncia' then 'Moderação 24h (Diretriz 1.2)'
         else 'Atendimento 5 dias úteis (RF27/LGPD)'
       end as prioridade_sla,
       u_autor.nome as autor_nome,
       u_autor.telefone as autor_telefone,
       u_autor.perfil as autor_perfil,
       u_alvo.nome as alvo_nome,
       u_alvo.id as alvo_usuario_id,
       e.nome as estabelecimento_alvo,
       o.relato
  from public.ocorrencia o
  join public.usuario u_autor on u_autor.id = o.autor_id
  left join public.usuario u_alvo on u_alvo.id = o.usuario_id
  left join public.estabelecimento e on e.id = o.estabelecimento_id
 where o.resolvido_em is null
 order by
   case when o.tipo = 'denuncia' then 0 else 1 end,
   o.criada_em asc;
