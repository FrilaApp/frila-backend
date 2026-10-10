-- supabase/operacao/fechar-chamado-sem-email.sql
--
-- Fecha chamado de suporte manualmente pela Equipe Frila.
-- Caso padrão: chamado aberto no app cujo e-mail nunca foi enviado pelo usuário
-- dentro do prazo regulamentar de 5 dias úteis (D16, SU-RN10).
--
-- Atualiza public.ocorrencia definindo resolvido_em = now() e resultado = 'sem_email_recebido'.
--
-- Uso no psql:
--   psql -v ocorrencia_id="<uuid>" -f supabase/operacao/fechar-chamado-sem-email.sql
--   psql -v protocolo_curto="<8-hex>" -f supabase/operacao/fechar-chamado-sem-email.sql
--
-- Com resultado customizado (opcional):
--   psql -v ocorrencia_id="<uuid>" -v resultado="atendido_direto" -f supabase/operacao/fechar-chamado-sem-email.sql

\if :{?ocorrencia_id}
\elif :{?protocolo_curto}
\else
  \echo 'Erro: informe ocorrencia_id="<uuid>" ou protocolo_curto="<8-hex>".'
  \echo 'Uso: psql -v ocorrencia_id="<uuid>" -f supabase/operacao/fechar-chamado-sem-email.sql'
  \echo '  ou psql -v protocolo_curto="<8-hex>" -f supabase/operacao/fechar-chamado-sem-email.sql'
  \q
\endif

\if :{?resultado}
\else
  \set resultado 'sem_email_recebido'
\endif

begin;

\if :{?ocorrencia_id}
update public.ocorrencia
   set resolvido_em = now(),
       resultado    = :'resultado'
 where id = :'ocorrencia_id'::uuid
   and tipo = 'suporte'
   and resolvido_em is null
returning id as ocorrencia_id,
          upper(substring(replace(id::text, '-', '') from 1 for 8)) as protocolo_curto,
          tipo,
          origem,
          motivo as categoria,
          turno_id,
          autor_id,
          criada_em,
          resolvido_em,
          resultado;
\else
update public.ocorrencia
   set resolvido_em = now(),
       resultado    = :'resultado'
 where upper(substring(replace(id::text, '-', '') from 1 for 8)) = upper(:'protocolo_curto')
   and tipo = 'suporte'
   and resolvido_em is null
returning id as ocorrencia_id,
          upper(substring(replace(id::text, '-', '') from 1 for 8)) as protocolo_curto,
          tipo,
          origem,
          motivo as categoria,
          turno_id,
          autor_id,
          criada_em,
          resolvido_em,
          resultado;
\endif

commit;
