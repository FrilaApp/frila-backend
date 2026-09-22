-- O portão de RN07 e os índices do caminho quente.

-- ── RN07: quando a avaliação é aceita ──────────────────────────────────────────
--
-- Só depois do fim previsto do turno, e só para turno com presença verificada —
-- check-in geolocalizado, ou manual confirmado pelo contratante. Quem faltou não é
-- avaliado: a falta já pesa na taxa de comparecimento, e não deve pesar duas vezes.
--
-- A regra atravessa tabelas (o fim previsto está em `posicao`, a presença em `turno`),
-- então não cabe num CHECK. Vive aqui, e a RPC `avaliar` a repete para devolver o
-- código de erro certo em vez de uma exceção crua.

create or replace function privado.avaliacao_permitida()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  v_fim         timestamptz;
  v_verificacao public.verificacao_turno;
begin
  select p.fim_em, t.verificacao
    into v_fim, v_verificacao
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = new.turno_id;

  if v_fim is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if now() < v_fim then
    perform public.erro(422, 'avaliacao_indisponivel', 'antes_do_fim');
  end if;

  if v_verificacao is distinct from 'verificado' then
    perform public.erro(422, 'avaliacao_indisponivel', 'sem_presenca_verificada');
  end if;

  return new;
end $$;

create trigger avaliacao_rn07
  before insert on public.avaliacao
  for each row execute function privado.avaliacao_permitida();

-- ── Índices ────────────────────────────────────────────────────────────────────
--
-- A consulta de elegibilidade tem que responder em 30 segundos (RNF03), e toda a
-- tese do produto passa por ela.

-- Elegibilidade por distância: com 15 km fixos, ST_DWithin usa o GIST direto.
create index profissional_ponto    on public.profissional using gist (ponto_base);

-- A lista de vagas do DF ordena por distância até o ponto de referência. Parcial
-- porque só vaga publicada entra na lista.
create index vaga_ponto_publicada  on public.vaga using gist (ponto) where estado = 'publicada';

create index disponibilidade_busca on public.disponibilidade (profissional_id, dia_semana);
create index profissional_funcao_funcao on public.profissional_funcao (funcao_id);
create index despacho_vaga         on public.despacho (vaga_id);

-- A pergunta que o teto de RN23 faz a cada envio: quando foi a última notificação
-- desta pessoa?
create index notificacao_teto      on public.notificacao (profissional_id, enviada_em desc);

create index posicao_abertas       on public.posicao (vaga_id) where estado = 'aberta';
create index posicao_do_profissional on public.posicao (profissional_id)
  where estado in ('confirmada','cumprida');

-- O agendador varre as vagas ainda publicadas cujo início, menos a antecedência do
-- alerta, já chegou (RF20). O índice parcial mantém pequeno o conjunto que interessa.
create index vaga_janela_critica   on public.vaga (inicio_em) where estado = 'publicada';

create index candidatura_pendente  on public.candidatura (posicao_id) where estado = 'pendente';
create index bloqueio_bloqueado    on public.bloqueio (bloqueado_id);
create index membro_por_usuario    on public.membro_estabelecimento (usuario_id);
create index equipe_por_profissional on public.equipe_confianca (profissional_id);
create index ocorrencia_alvo       on public.ocorrencia (usuario_id, tipo);
create index dispositivo_usuario   on public.dispositivo (usuario_id);
