-- A janela do registro de presença não se aplica à conta de revisão da App Store.
--
-- Cartão `7gpPBgTH`, diretriz 2.1.
--
-- ── O que estava quebrado ─────────────────────────────────────────────────────────────
--
-- O `seed.sql` semeia para a revisão um turno confirmado que começa em
-- `privado.agora() + 2 days` e termina seis horas depois. A `privado.exigir_janela`
-- aceita registro de 60 minutos antes do início até o fim previsto. Somando: o turno da
-- revisão tem uma janela de sete horas que abre 47 horas depois de o seed rodar, e
-- depois fecha para sempre.
--
-- Em produção o seed entra uma vez. Na Beta App Review, a partir de 20/10, e na revisão
-- da loja, em 06/11, essa janela já estará fechada. Medido em 25/09 contra o banco
-- local, com a sessão de `revisao-profissional@frila.app`:
--
--   POST /rest/v1/rpc/fazer_checkin
--   422 {"code":"fora_da_janela","details":null,"hint":null,"message":"fora_da_janela"}
--
-- O revisor entraria, veria a vaga, veria o turno e o contato liberado, e pararia ali:
-- check-in, confirmação manual e check-out ficariam inalcançáveis. É metade do que o app
-- faz, e é a diretriz 2.1 — a mesma que obrigou a existir a porta `entrar-demonstracao`.
--
-- ── Por que aqui, e não no seed ───────────────────────────────────────────────────────
--
-- Um seed que semeasse o turno dentro da janela corrente resolveria no dia em que
-- rodasse e voltaria a quebrar no dia seguinte: o problema não é onde o turno começa, é
-- que ele envelhece e a revisão não tem data marcada. Reposicionar o turno por job
-- resolveria de verdade, mas depende de `pg_cron`, que entra com o motor de despacho do
-- Sprint 2. A isenção vive no backend, não depende de agendador, e as duas contas que
-- ela alcança já estão isoladas da população real desde o contrato 0.2.12.
--
-- ── O que a isenção não afrouxa ───────────────────────────────────────────────────────
--
-- Só a janela relativa ao turno. `registrado_em` nulo continua `campo_obrigatorio`, e
-- registro no futuro continua `registro_no_futuro` — inclusive para a revisão. Registro
-- no futuro é o caminho mais curto para fabricar presença, e abrir essa porta para duas
-- contas seria abri-la de verdade: a marca `usuario.demonstracao` é uma coluna, e coluna
-- se escreve.
--
-- A verificação também não é afrouxada. O check-in sem distância continua nascendo
-- `manual` e `pendente`, e continua precisando do toque da casa em
-- `confirmar_checkin_manual` para virar `verificado`. O revisor percorre o caminho do
-- RF20, e não um atalho que não existe no produto.
--
-- A condição é `privado.conta_de_demonstracao()`, que é a mesma que isola as duas
-- populações em `vagas_abertas`, `detalhe_vaga`, `candidatar` e na política de leitura de
-- `vaga`. Uma segunda fonte da mesma verdade aqui seria a primeira a divergir.

create or replace function privado.exigir_janela(registrado_em timestamptz,
                                                inicio timestamptz, fim timestamptz)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if registrado_em is null then
    perform public.erro(422, 'campo_obrigatorio', 'registrado_em');
  end if;

  -- Dois minutos de folga para o relógio do aparelho, que adianta. Mais do que isso é
  -- registro no futuro, e registro no futuro é o caminho mais curto para fabricar
  -- presença. Vale para a revisão também: é a única parte da função que a conta de
  -- demonstração não atravessa.
  if registrado_em > privado.agora() + interval '2 minutes' then
    perform public.erro(422, 'registro_no_futuro');
  end if;

  -- A conta de revisão da App Store atravessa a janela. O turno semeado para ela
  -- envelhece, e a revisão não tem data marcada.
  if privado.conta_de_demonstracao() then
    return;
  end if;

  if registrado_em < inicio - interval '60 minutes' or registrado_em > fim then
    perform public.erro(422, 'fora_da_janela');
  end if;
end $$;

comment on function privado.exigir_janela(timestamptz, timestamptz, timestamptz) is
  'A janela do registro de presença: de 60 min antes do início até o fim previsto, com 2 min de folga para o relógio do aparelho adiantado. A conta de revisão da App Store (usuario.demonstracao) atravessa a janela, porque o turno semeado para ela envelhece e a revisão não tem data marcada; registro no futuro continua recusado para ela.';
