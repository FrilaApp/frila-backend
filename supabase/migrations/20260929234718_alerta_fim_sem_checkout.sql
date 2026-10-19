-- Aviso de hora excedida quando o fim previsto passa sem check-out (cartão qcVimM84 ·
-- US15, RN11, UC05).
--
-- O tipo `fim_sem_checkout` existe desde a 20260925233000: está no `tipo_notificacao`,
-- está na chave de unicidade que garante um aviso por conta, e o `enviar-push` já tem o
-- texto dele. O que nunca existiu foi **quem cria a notificação** — nenhuma migração da
-- `develop` chama `privado.notificar(..., 'fim_sem_checkout', ...)`. O tipo estava no ar
-- sem produtor, que é o jeito mais discreto de uma regra não acontecer.
--
-- ── Uma vez por conta, e quem garante isso já existe ─────────────────────────
--
-- `privado.notificar` tem `on conflict (tipo, referencia_id, usuario_id) do nothing` para
-- a lista de tipos que inclui `fim_sem_checkout`. O job roda a cada cinco minutos e
-- chama a notificação toda vez; a segunda chamada não cria linha nova. O "uma vez" do
-- critério 1 é essa chave, e não um `if` no meio deste arquivo.
--
-- ── Por que a janela, e por que ela é parâmetro ──────────────────────────────
--
-- Sem limite de tempo, a primeira execução depois do deploy avisaria sobre todo turno
-- histórico que ficou sem check-out — e cada um desses avisos é um push real no aparelho
-- de alguém, sobre um turno de semanas atrás. A janela fecha isso.
--
-- Ela mora em `privado.parametro_notificacao`, junto com as duas da RN23, porque é a
-- mesma natureza de decisão: muda sem migração de código, e o agendador lê a cada
-- execução. Seis horas é o que cobre o agendador parado por uma manhã sem transformar o
-- aviso em lembrança de ontem.
--
-- ── O que este aviso não diz ─────────────────────────────────────────────────
--
-- Hora extra. O cartão é explícito, e o app não calcula: só registra. O payload leva o
-- `turno_id` e nada mais — e não é disciplina, é estrutura: `privado.notificar` recusa
-- com `22023` qualquer chave fora de `vaga_id`, `posicao_id`, `turno_id`,
-- `estabelecimento_id` e `reaberta`. Uma chave `minutos_excedidos` não tem como existir
-- nesta tabela.

-- ── 1. A janela ───────────────────────────────────────────────────────────────

insert into privado.parametro_notificacao (chave, valor, finalidade) values
  ('fim_sem_checkout_janela', interval '6 hours',
   'RN11: até quando depois do fim previsto o aviso de check-out pendente ainda vale. Impede que o agendador, ao voltar de uma parada, avise sobre turnos antigos.')
on conflict (chave) do nothing;

-- ── 2. O job ──────────────────────────────────────────────────────────────────
--
-- A condição é do **turno**, e não da posição. O `fechar_turnos_e_vagas` roda a cada
-- cinco minutos e marca `posicao.estado = 'cumprida'` assim que o fim passa: filtrar por
-- `confirmada`, como o `alertar_atrasos` faz, deixaria este aviso sair só na janela entre
-- o fim do turno e o próximo fechamento — ou nunca, se os dois jobs caíssem no mesmo
-- minuto. Quem responde "o fim passou e ninguém registrou a saída" é `t.checkout_em`.
--
-- Posição cancelada fica de fora: o turno não aconteceu, e pedir check-out de um turno
-- cancelado é pedir que a pessoa registre a saída de onde ela não entrou. O check-in
-- existir e a posição estar cancelada é o caso do `reabrir_por_atraso` perdendo a corrida
-- para o `fazer_checkin`.
create or replace function privado.alertar_fim_sem_checkout()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora  timestamptz := privado.agora();
  v_janela interval    := privado.parametro_de_notificacao('fim_sem_checkout_janela');
  v_turno  record;
  v_n      integer := 0;
begin
  for v_turno in
    select t.id as turno_id,
           p.profissional_id,
           g.estabelecimento_id
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga g    on g.id = p.vaga_id
     where t.checkin_em  is not null
       and t.checkout_em is null
       and p.fim_em <= v_agora
       and p.fim_em >  v_agora - v_janela
       and p.estado <> 'cancelada'
  loop
    -- Os dois lados (RN11): quem trabalhou registra a saída, e a casa precisa saber que
    -- o turno dela está aberto sem ninguém ter fechado.
    perform privado.notificar(
      privado.usuario_do_profissional(v_turno.profissional_id),
      'fim_sem_checkout', v_turno.turno_id,
      jsonb_build_object('turno_id', v_turno.turno_id));

    perform privado.notificar_membros(
      v_turno.estabelecimento_id, 'fim_sem_checkout', v_turno.turno_id,
      jsonb_build_object('turno_id', v_turno.turno_id));

    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;

comment on function privado.alertar_fim_sem_checkout() is
  'Avisa os dois lados quando o fim previsto passou com check-in e sem check-out (qcVimM84, US15, RN11, UC05). Uma vez por conta, pela chave (tipo, referência, conta) de privado.notificar. Só dentro da janela fim_sem_checkout_janela, e nunca em posição cancelada. Não calcula hora extra: o payload leva só o turno.';

revoke execute on function privado.alertar_fim_sem_checkout() from public, anon, authenticated;
grant  execute on function privado.alertar_fim_sem_checkout() to service_role;

-- ── 3. O agendamento ──────────────────────────────────────────────────────────
--
-- Cinco minutos, como os outros avisos de turno. Um minuto não compraria nada: o aviso é
-- sobre um horário que já passou, e o custo de cinco minutos de atraso num pedido de
-- check-out é zero.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('alertar_fim_sem_checkout')
      where exists (select 1 from cron.job where jobname = 'alertar_fim_sem_checkout');
    perform cron.schedule(
      'alertar_fim_sem_checkout',
      '*/5 * * * *',
      'select privado.alertar_fim_sem_checkout()'
    );
  end if;
end $$;
