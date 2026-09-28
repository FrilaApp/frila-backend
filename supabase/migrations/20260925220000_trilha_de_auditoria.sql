-- A trilha de auditoria do ciclo do turno (RNF13).
--
-- Cartão `6mdX80SC`. Publicação, candidatura, confirmação, check-in, cancelamento e
-- avaliação passam a deixar registro com data, hora, autor e estado anterior.
--
-- ── O que ela NÃO guarda, e por quê ───────────────────────────────────────────────────
--
-- RN15 proíbe dado pessoal em log, e isso não é preferência de estilo: um gatilho de
-- auditoria que copia `to_jsonb(NEW)` de `usuario` guardaria nome, telefone, e-mail e
-- nascimento numa tabela que a exclusão de conta (RF25) não alcança — a anonimização
-- limparia a linha original e o histórico continuaria com a cópia.
--
-- Por isso a trilha guarda **referência e transição**: qual entidade, qual id, o que
-- mudou de quê para quê, e quem fez. Nunca o conteúdo. `usuario`, `profissional` e
-- `estabelecimento` ficam **de fora dos gatilhos**, de propósito — o que muda de relevante
-- neles é estado de conta, e isso já vira `ocorrencia`.
--
-- ── Por que em `privado` ──────────────────────────────────────────────────────────────
--
-- O cartão pede "sem leitura para clientes". Em `public`, isso seria RLS ligada e nenhuma
-- política — desenho que já existe aqui e funciona. Em `privado` é mais forte: o schema
-- não está em `api.schemas` do `config.toml`, então o PostgREST nem enxerga a tabela. Não
-- há política para alguém afrouxar por engano num cartão futuro.

create table privado.auditoria_ciclo (
  id              bigint generated always as identity primary key,
  entidade        text        not null,
  entidade_id     uuid        not null,
  acao            text        not null check (acao in ('criou', 'mudou_estado')),
  estado_anterior text,
  estado_novo     text,
  autor_id        uuid,
  em              timestamptz not null default privado.agora()
);

comment on table privado.auditoria_ciclo is
  'Trilha do ciclo do turno (RNF13): uma linha por transição, com estado anterior, estado novo e autor. Guarda referência e transição, nunca conteúdo — RN15 proíbe dado pessoal em log.';

comment on column privado.auditoria_ciclo.autor_id is
  'Conta que provocou a transição, ou NULL quando foi o agendador. Referência a usuario.id, e não cópia de nada dele.';

comment on column privado.auditoria_ciclo.em is
  'Relógio do produto (privado.agora()), e não now(): a trilha tem de contar a mesma história que o resto do banco dentro de um teste com relógio controlado.';

create index auditoria_ciclo_entidade on privado.auditoria_ciclo (entidade, entidade_id, em desc);
create index auditoria_ciclo_periodo  on privado.auditoria_ciclo (em desc);

-- ── O gatilho ─────────────────────────────────────────────────────────────────────────
--
-- Um só, genérico, pendurado em seis tabelas. O nome da coluna de estado vem como
-- argumento porque `avaliacao` e `ocorrencia` não têm estado nenhum — delas interessa só
-- o nascimento, e é o que `TG_ARGV[1] is null` significa.
create or replace function privado.audita_ciclo()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_entidade text := TG_ARGV[0];
  v_coluna   text := TG_ARGV[1];
  v_antes    text;
  v_depois   text;
begin
  if v_coluna is not null then
    execute format('select ($1).%I::text', v_coluna) into v_depois using NEW;
    if TG_OP = 'UPDATE' then
      execute format('select ($1).%I::text', v_coluna) into v_antes using OLD;
      -- Só transição interessa. Sem esta linha, todo UPDATE de coluna vizinha viraria
      -- uma linha de trilha dizendo que nada mudou, e a trilha deixaria de ser legível
      -- exatamente quando alguém precisasse dela.
      if v_antes is not distinct from v_depois then
        return null;
      end if;
    end if;
  end if;

  insert into privado.auditoria_ciclo (entidade, entidade_id, acao, estado_anterior, estado_novo, autor_id)
  values (v_entidade, NEW.id,
          case when TG_OP = 'INSERT' then 'criou' else 'mudou_estado' end,
          v_antes, v_depois, (select auth.uid()));

  return null;
end $$;

comment on function privado.audita_ciclo() is
  'Gatilho AFTER de auditoria (RNF13). TG_ARGV[0] é o nome da entidade; TG_ARGV[1] é a coluna de estado, ou NULL quando a entidade não tem estado e só o nascimento importa.';

create trigger vaga_auditoria        after insert or update on public.vaga
  for each row execute function privado.audita_ciclo('vaga', 'estado');
create trigger posicao_auditoria     after insert or update on public.posicao
  for each row execute function privado.audita_ciclo('posicao', 'estado');
create trigger candidatura_auditoria after insert or update on public.candidatura
  for each row execute function privado.audita_ciclo('candidatura', 'estado');
create trigger turno_auditoria       after insert or update on public.turno
  for each row execute function privado.audita_ciclo('turno', 'verificacao');
create trigger avaliacao_auditoria   after insert on public.avaliacao
  for each row execute function privado.audita_ciclo('avaliacao');
create trigger ocorrencia_auditoria  after insert on public.ocorrencia
  for each row execute function privado.audita_ciclo('ocorrencia');

-- ── A imutabilidade de `despacho` e `ocorrencia` ──────────────────────────────────────
--
-- As duas são registro do que aconteceu, e registro que pode ser reescrito não é
-- registro. `despacho` não muda nunca. `ocorrencia` muda só em `resultado` e
-- `resolvido_em`, que são o desfecho — o `motivo` é o relato de quem abriu, e reescrevê-lo
-- apagaria a versão dela.
--
-- A exceção controlada existe por causa da retenção (RF25, cartão `yClUqOpU`): quando a
-- conta é anonimizada, o relato precisa sair. Ela é um sinal de sessão, não uma coluna, e
-- some com a transação — quem esquecer de desligar não deixa a porta aberta para a
-- próxima conexão.
create or replace function privado.registro_imutavel()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_permitidas text[] := coalesce(TG_ARGV, '{}'::text[]);
begin
  if current_setting('privado.retencao', true) = 'on' then
    return case when TG_OP = 'DELETE' then OLD else NEW end;
  end if;

  if TG_OP = 'DELETE' then
    raise exception 'registro de % nao pode ser apagado', TG_TABLE_NAME
      using errcode = 'restrict_violation';
  end if;

  -- Compara a linha inteira menos as colunas que podem mudar. Listar o que é proibido
  -- envelheceria mal: coluna nova nasceria editável sem ninguém decidir isso.
  if (to_jsonb(OLD) - v_permitidas) is distinct from (to_jsonb(NEW) - v_permitidas) then
    raise exception 'registro de % so muda em %', TG_TABLE_NAME,
      coalesce(array_to_string(v_permitidas, ', '), 'nenhuma coluna')
      using errcode = 'restrict_violation';
  end if;

  return NEW;
end $$;

comment on function privado.registro_imutavel() is
  'Gatilho BEFORE que recusa UPDATE fora das colunas passadas em TG_ARGV, e recusa DELETE sempre (RNF13). A sessão com privado.retencao = on passa, que é a exceção controlada da retenção (RF25).';

create trigger despacho_imutavel before update or delete on public.despacho
  for each row execute function privado.registro_imutavel();
create trigger ocorrencia_imutavel before update or delete on public.ocorrencia
  for each row execute function privado.registro_imutavel('resultado', 'resolvido_em');

-- ── A consulta por período ────────────────────────────────────────────────────────────
--
-- Pronta para a exportação de turnos da v1.1 (RF22). Fica em `privado` e sem concessão
-- para `authenticated`: hoje ninguém a chama pelo app, e abrir agora seria decidir por um
-- cartão que ainda não existe.
create or replace function privado.auditoria_do_periodo(de timestamptz, ate timestamptz)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'entidade',        a.entidade,
           'entidade_id',     a.entidade_id,
           'acao',            a.acao,
           'estado_anterior', a.estado_anterior,
           'estado_novo',     a.estado_novo,
           'autor_id',        a.autor_id,
           'em',              a.em) order by a.em, a.id), '[]'::jsonb)
    from privado.auditoria_ciclo a
   where a.em >= auditoria_do_periodo.de and a.em < auditoria_do_periodo.ate;
$$;

comment on function privado.auditoria_do_periodo(timestamptz, timestamptz) is
  'A trilha de um período, em ordem cronológica (RNF13). Intervalo fechado no início e aberto no fim, para dois períodos seguidos não contarem a mesma linha duas vezes.';

revoke all on function privado.auditoria_do_periodo(timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function privado.audita_ciclo() from public, anon;
revoke all on function privado.registro_imutavel() from public, anon;
