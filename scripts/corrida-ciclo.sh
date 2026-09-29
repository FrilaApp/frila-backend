#!/usr/bin/env bash
# As corridas do ciclo além da RN19 (cartão nspP9YDU, RNF14).
#
# O pgTAP roda numa sessão só: ele vê a segunda chamada depois do commit da primeira, e
# nunca as duas com a transação aberta ao mesmo tempo. Aqui cada lado é uma conexão de
# verdade, e cada cenário roda RODADAS vezes seguidas (50 por padrão, o critério do
# cartão). As rodadas alternam quem chega primeiro e quem segura o commit, para a
# corrida não ser sempre a mesma:
#
#   rodada % 4 = 0   o primeiro lado age e segura o commit 0,3 s; os outros chegam depois
#   rodada % 4 = 1   o inverso: o segundo lado age e segura, o primeiro chega depois
#   rodada % 4 = 2   todos ao mesmo tempo, segurando 0,05 s
#   rodada % 4 = 3   todos ao mesmo tempo, sem segurar
#
# Os três cenários:
#
#   1. reabrir_por_atraso × fazer_checkin — a casa declara a falta aos 15 minutos no
#      mesmo instante em que o profissional toca no check-in. Termina com check-in e
#      posição confirmada, ou com posição cancelada com falta e sem check-in; nunca os
#      dois, e nunca nenhum.
#   2. cancelar_vaga × candidatar — a casa cancela a vaga enquanto dois profissionais
#      aceitam a única posição. Nenhuma posição fica confirmada em vaga cancelada.
#   3. dois executores do despacho × teto (RN23) — duas vagas não urgentes despachadas
#      ao mesmo tempo para os mesmos elegíveis, e o agendador do teto rodando junto.
#      Nenhum profissional recebe duas notificações no teto em 30 minutos.
#   4. cancelar_vaga × cancelar_posicao (cartão xJ53t3tX) — a casa cancela a vaga no
#      mesmo instante em que o profissional confirmado desiste dela. Nenhuma posição
#      aberta ou confirmada sobra na vaga cancelada, a posição dele tem um cancelamento
#      só, e a falta (RN12) fica com quem de fato cancelou.
#   5. cancelar_vaga × candidatar × cancelar_posicao (impasse) — a corrida a três da
#      revisão do #62: a candidatura confirma no meio do `cancelar_vaga`, e o mesmo
#      profissional desiste antes de o gatilho da vaga cancelada rodar. Os três lados
#      saem com tempos sorteados em milissegundos. Nenhum lado termina em impasse
#      (40P01), e a vaga termina cancelada sem posição viva.
#   6. a mesma corrida com a janela alargada (janela) — duas conexões de serviço seguram
#      a posição confirmada de outro profissional e o turno do desistente, para pôr cada
#      lado no ponto em que o impasse acontecia na ordem antiga. Nenhum 40P01 e nenhuma
#      posição viva em vaga cancelada.
#   7. quem segura a posição desfaz (rollback) — a desistência leva statement_timeout e
#      desfaz no meio do cancelamento da vaga (revisão do #63). Nenhuma posição viva em
#      vaga cancelada.
#
# Os de candidatura (vinte para duas posições, profissional em dobro) seguem em
# `corrida-candidatar.sh`.
#
# Uso:  ./scripts/corrida-ciclo.sh
#       RODADAS=10 ./scripts/corrida-ciclo.sh
#       CENARIOS="checkin cancelar teto posicao impasse janela rollback" ./scripts/corrida-ciclo.sh
#       MANTER=1 ./scripts/corrida-ciclo.sh     # não limpa: o placar fica em corrida_ciclo
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}
RODADAS=${RODADAS:-50}
CENARIOS=${CENARIOS:-checkin cancelar teto posicao impasse janela rollback}

psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

falha=0
MARCA=$(python3 -c 'import uuid; print(uuid.uuid4())')
TMP=$(mktemp -d)

# A vaga de referência do seed (sexta 18h) e as duas vagas do teto, com ids próprios.
REF="d0000000-0000-4000-8000-000000000001"
TETO_A="d0000000-0000-4000-8000-0000000c1c0a"
TETO_B="d0000000-0000-4000-8000-0000000c1c0b"

limpar_teto() {
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: a limpeza do teto falhou" >&2
set session_replication_role = 'replica';
delete from public.despacho where vaga_id in ('$TETO_A', '$TETO_B');
delete from public.notificacao where referencia_id in ('$TETO_A', '$TETO_B');
delete from public.vaga where id in ('$TETO_A', '$TETO_B');
set session_replication_role = 'origin';
SQL
}

limpar() {
  limpar_teto
  # A réplica desliga os gatilhos de imutabilidade (despacho, ocorrência): o que se apaga
  # aqui é só o que esta corrida criou, marcado pelo endereço e pelo e-mail.
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: a limpeza falhou; sobrou o schema corrida_ciclo" >&2
set session_replication_role = 'replica';
create temp table vagas as select id from public.vaga where local = 'corrida-ciclo-$MARCA';
create temp table contas as select id from public.usuario where email like 'corrida-ciclo-$MARCA-%';
create temp table posicoes as select id from public.posicao where vaga_id in (select id from vagas);
-- A reabertura por atraso enfileira despacho, e o agendador pode tê-lo consumido e
-- notificado gente do seed: sai tudo que aponta para uma vaga ou posição da corrida.
delete from public.notificacao
 where usuario_id in (select id from contas)
    or referencia_id in (select id from vagas union all select id from posicoes);
delete from pgmq.q_despacho where (message->>'vaga_id')::uuid in (select id from vagas);
delete from public.despacho    where vaga_id in (select id from vagas);
delete from public.ocorrencia  where posicao_id in (select id from public.posicao where vaga_id in (select id from vagas));
delete from public.turno       where posicao_id in (select id from public.posicao where vaga_id in (select id from vagas));
delete from public.candidatura where posicao_id in (select id from public.posicao where vaga_id in (select id from vagas));
delete from public.posicao     where vaga_id in (select id from vagas);
delete from public.vaga        where id in (select id from vagas);
delete from public.membro_estabelecimento where estabelecimento_id in (select id from public.estabelecimento where endereco = 'corrida-ciclo-$MARCA');
delete from public.estabelecimento where endereco = 'corrida-ciclo-$MARCA';
delete from public.profissional_funcao where profissional_id in (select id from public.profissional where usuario_id in (select id from contas));
delete from public.profissional where usuario_id in (select id from contas);
delete from public.usuario  where id in (select id from contas);
delete from auth.users      where email like 'corrida-ciclo-$MARCA-%';
set session_replication_role = 'origin';
drop schema if exists corrida_ciclo cascade;
SQL
  rm -rf "$TMP"
}
[ -n "${MANTER:-}" ] || trap limpar EXIT

# ── O palco ───────────────────────────────────────────────────────────────────
#
# Uma casa com uma dona, e contas de profissional novas para cada rodada: a mesma conta
# em duas rodadas bateria na RN21 (turno sobreposto) e a corrida mediria outra coisa.

echo "▸ Montando o palco: $RODADAS rodadas por cenário"

psql >/dev/null <<SQL
create schema corrida_ciclo;

create table corrida_ciclo.placar (
  cenario  text not null,
  rodada   int  not null,
  lado     text not null,
  code     text not null,
  resposta jsonb
);

-- Cada lado entra pelo caminho do app: role \`authenticated\` e a claim \`sub\`. O erro é
-- guardado pelo \`code\` do envelope, e não pela mensagem crua: o placar conta regra, não
-- texto. Um erro que não é envelope (impasse, por exemplo) entra pelo sqlstate e reprova.
create function corrida_ciclo.agir(p_cenario text, p_rodada int, p_lado text,
                                   p_conta uuid, p_sql text)
returns void
language plpgsql as \$agir\$
declare
  r jsonb;
begin
  if p_conta is not null then
    execute 'set local role authenticated';
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', p_conta, 'role', 'authenticated')::text);
  end if;
  begin
    execute p_sql into r;
    execute 'reset role';
    execute 'reset request.jwt.claims';
    insert into corrida_ciclo.placar values (p_cenario, p_rodada, p_lado, 'ok', r);
  exception when query_canceled then
    -- \`others\` não pega o cancelamento (statement_timeout, cenário 7): ele tem de ser
    -- nomeado. A subtransação desfaz o que o lado fez, como o rollback do app.
    execute 'reset role';
    execute 'reset request.jwt.claims';
    insert into corrida_ciclo.placar values (p_cenario, p_rodada, p_lado,
      'sqlstate:' || sqlstate, jsonb_build_object('mensagem', sqlerrm));
  when others then
    execute 'reset role';
    execute 'reset request.jwt.claims';
    insert into corrida_ciclo.placar values (p_cenario, p_rodada, p_lado,
      case when sqlerrm like '{%' then coalesce((sqlerrm::jsonb)->>'code', 'sem_code')
           else 'sqlstate:' || sqlstate end,
      jsonb_build_object('mensagem', sqlerrm));
  end;
end
\$agir\$;

create table corrida_ciclo.contas (papel text not null, n int not null, conta uuid not null);

do \$palco\$
declare
  v_dona   uuid := gen_random_uuid();
  v_estab  uuid;
  v_funcao uuid;
  v_conta  uuid;
  v_seq    int := 0;
  r        record;
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', v_dona, 'authenticated', 'authenticated',
          'corrida-ciclo-$MARCA-dona@frila.test', now(), '{"provider":"email"}', '{}',
          now(), now(), false, false);

  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_dona, 'contratante', 'Dona da Corrida do Ciclo', '+5561866660000',
          'corrida-ciclo-$MARCA-dona@frila.test', '1980-01-01', '2026-09-22', now());

  insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
  values ('Casa da Corrida do Ciclo', lpad((floor(random() * 1e13))::bigint::text, 14, '8'),
          'food_service', 'corrida-ciclo-$MARCA',
          'POINT(-47.8860 -15.7910)'::extensions.geography)
  returning id into v_estab;

  insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
  values (v_dona, v_estab, 'administrador');

  insert into corrida_ciclo.contas values ('dona', 0, v_dona);

  select id into v_funcao from public.funcao where nome = 'garçom';

  -- Um profissional por rodada no check-in, dois por rodada no cancelamento da vaga,
  -- um por rodada na desistência, um no impasse, dois na janela alargada e dois no
  -- rollback.
  for r in select 'atrasado' as papel, n from generate_series(1, $RODADAS) n
           union all
           select 'candidato', n from generate_series(1, 2 * $RODADAS) n
           union all
           select 'desistente', n from generate_series(1, $RODADAS) n
           union all
           select 'impasse', n from generate_series(1, $RODADAS) n
           union all
           select 'janela', n from generate_series(1, 2 * $RODADAS) n
           union all
           select 'rollback', n from generate_series(1, 2 * $RODADAS) n
  loop
    v_seq := v_seq + 1;
    v_conta := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            is_sso_user, is_anonymous)
    values ('00000000-0000-0000-0000-000000000000', v_conta, 'authenticated', 'authenticated',
            'corrida-ciclo-$MARCA-' || v_seq || '@frila.test', now(), '{"provider":"email"}', '{}',
            now(), now(), false, false);

    insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
    values (v_conta, 'profissional', 'Profissional ' || v_seq,
            '+55618' || lpad(v_seq::text, 8, '0'), 'corrida-ciclo-$MARCA-' || v_seq || '@frila.test',
            '1995-01-01', '2026-09-22', now());

    insert into public.profissional (usuario_id, ponto_base)
    values (v_conta, 'POINT(-47.8850 -15.7900)'::extensions.geography);

    insert into public.profissional_funcao (profissional_id, funcao_id)
    select p.id, v_funcao from public.profissional p where p.usuario_id = v_conta;

    insert into corrida_ciclo.contas values (r.papel, r.n, v_conta);
  end loop;
end
\$palco\$;
SQL
[ $? -eq 0 ] || { echo "não consegui montar o palco" >&2; exit 1; }

DONA=$(psql -tAc "select conta from corrida_ciclo.contas where papel = 'dona'")

# Os tempos de cada lado numa rodada: "espera_antes segura_depois".
tempos() { # rodada lado(1|2|3)
  case $(( $1 % 4 )):$2 in
    0:1) echo "0 0.3" ;;    0:*) echo "0.1 0" ;;
    1:1) echo "0.1 0" ;;    1:2) echo "0 0.3" ;;  1:*) echo "0.15 0" ;;
    2:*) echo "0 0.05" ;;
    3:*) echo "0 0" ;;
  esac
}

# Um lado da corrida numa conexão própria, em segundo plano. Os tempos saem de
# `tempos`, a não ser que o cenário os dê ("espera_antes segura_depois"). O sétimo
# argumento é o statement_timeout da chamada, em ms (0 = sem limite).
lado() { # cenario rodada lado conta sql [tempos] [timeout_ms]
  local ant dep conta
  read -r ant dep < <([ -n "${6:-}" ] && echo "$6" || tempos "$2" "$3")
  conta=$([ -n "$4" ] && echo "'$4'::uuid" || echo "null")
  psql -tA >/dev/null 2>"$TMP/$1-$2-$3.err" <<SQL &
set application_name = 'corrida_ciclo_$1_$3';
set statement_timeout = ${7:-0};
-- O despacho pós-commit (\`privado.disparar_despacho\`) exige o segredo do agendador. A
-- CI grava um efêmero no banco; fora dela, depois de um \`db reset\`, não há nenhum, e a
-- sessão da corrida usa um valor de teste, como o pgTAP faz com \`set local\`.
select set_config('frila.agendador_secret', 'segredo-da-corrida', false)
 where nullif(current_setting('frila.agendador_secret', true), '') is null;
begin;
set local statement_timeout = 0;
select pg_sleep($ant);
set local statement_timeout = ${7:-0};
select corrida_ciclo.agir('$1', $2, '$3', $conta, \$sql\$$5\$sql\$);
set local statement_timeout = 0;
select pg_sleep($dep);
commit;
SQL
}

# ── 1. reabrir_por_atraso × fazer_checkin ─────────────────────────────────────
cenario_checkin() {
  echo
  echo "▸ Cenário 1: reabrir_por_atraso × fazer_checkin ($RODADAS rodadas)"

  # Cada rodada tem o seu turno: começou há 20 minutos, sem check-in, confirmado ontem.
  # A confirmação entra direto na tabela porque \`candidatar\` recusa, com razão, vaga já
  # começada — e o que se mede aqui é o que acontece depois dela.
  psql >/dev/null <<SQL || { falhou "não consegui montar os turnos atrasados"; return; }
create table corrida_ciclo.atraso (n int, vaga uuid, posicao uuid, turno uuid, conta uuid);

do \$atraso\$
declare
  c        record;
  v_estab  uuid := (select id from public.estabelecimento where endereco = 'corrida-ciclo-$MARCA');
  v_funcao uuid := (select id from public.funcao where nome = 'garçom');
  v_vaga   uuid;
  v_pos    uuid;
  v_turno  uuid;
begin
  for c in select n, conta from corrida_ciclo.contas where papel = 'atrasado' order by n loop
    insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                             valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                             exige_material_proprio, responsavel_local, modo, estado,
                             chave_cliente, publicado_por)
    values (v_estab, v_funcao, now() - interval '20 minutes', now() + interval '4 hours',
            'corrida-ciclo-$MARCA', 'POINT(-47.8860 -15.7910)'::extensions.geography,
            18000, 1, true, true, false, 'Seu Zé', 'urgencia', 'preenchida',
            gen_random_uuid(), '$DONA')
    returning id into v_vaga;

    insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
    select v_vaga, 'confirmada', p.id, now() - interval '1 day',
           now() - interval '20 minutes', now() + interval '4 hours'
      from public.profissional p where p.usuario_id = c.conta
    returning id into v_pos;

    insert into public.turno (posicao_id, valor_acordado_centavos)
    values (v_pos, 18000)
    returning id into v_turno;

    insert into corrida_ciclo.atraso values (c.n, v_vaga, v_pos, v_turno, c.conta);
  end loop;
end
\$atraso\$;
SQL

  psql -tA -F' ' -c "select n, posicao, turno, conta from corrida_ciclo.atraso order by n" \
    >"$TMP/atraso"
  while read -r n pos turno conta; do
    lado checkin "$n" 1 "$DONA"  "select public.reabrir_por_atraso('$pos')"
    lado checkin "$n" 2 "$conta" "select public.fazer_checkin('$turno', 40, now())"
    wait
  done <"$TMP/atraso"

  # Por rodada: quem venceu, e o estado final do turno e da posição.
  psql -tA -F' ' >"$TMP/checkin.res" <<'SQL'
select a.n,
       coalesce((select code from corrida_ciclo.placar p
                  where p.cenario = 'checkin' and p.rodada = a.n and p.lado = '1'), 'nada'),
       coalesce((select code from corrida_ciclo.placar p
                  where p.cenario = 'checkin' and p.rodada = a.n and p.lado = '2'), 'nada'),
       case when t.checkin_em is not null and o.estado = 'confirmada' and not o.falta
              then 'checkin'
            when t.checkin_em is null and o.estado = 'cancelada' and o.falta
              then 'reaberta'
            when t.checkin_em is not null and o.estado = 'cancelada'
              then 'OS_DOIS'
            else 'NENHUM' end
  from corrida_ciclo.atraso a
  join public.turno t   on t.id = a.turno
  join public.posicao o on o.id = a.posicao
 order by a.n;
SQL

  local ruins
  ruins=$(awk '
    # O final tem de ser um dos dois, e cada lado tem de ter a resposta que casa com ele.
    $4 == "checkin"  && $2 == "posicao_nao_cancelavel" && $3 == "ok" { next }
    $4 == "reaberta" && $2 == "ok" && ($3 == "vaga_encerrada" || $3 == "nao_encontrado") { next }
    { print }' "$TMP/checkin.res")
  local n_checkin n_reaberta
  n_checkin=$(awk '$4 == "checkin"' "$TMP/checkin.res" | grep -c . || true)
  n_reaberta=$(awk '$4 == "reaberta"' "$TMP/checkin.res" | grep -c . || true)

  if [ -z "$ruins" ] && [ "$((n_checkin + n_reaberta))" -eq "$RODADAS" ]; then
    ok "$RODADAS rodadas: $n_checkin com check-in e posição mantida, $n_reaberta reabertas sem check-in; nenhuma com os dois"
  else
    falhou "rodadas fora da regra (rodada, reabrir, checkin, final):"
    printf '%s\n' "$ruins" | sed 's/^/      /' >&2
  fi
}

# ── 2. cancelar_vaga × candidatar ─────────────────────────────────────────────
cenario_cancelar() {
  echo
  echo "▸ Cenário 2: cancelar_vaga × candidatar, dois candidatos por rodada ($RODADAS rodadas)"

  psql >/dev/null <<SQL || { falhou "não consegui montar as vagas a cancelar"; return; }
create table corrida_ciclo.cancelar (n int, vaga uuid, c1 uuid, c2 uuid);

insert into corrida_ciclo.cancelar
select r.n,
       gen_random_uuid(),
       (select conta from corrida_ciclo.contas where papel = 'candidato' and n = 2 * r.n - 1),
       (select conta from corrida_ciclo.contas where papel = 'candidato' and n = 2 * r.n)
  from generate_series(1, $RODADAS) r(n);

insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, chave_cliente,
                         publicado_por)
select c.vaga, e.id, (select id from public.funcao where nome = 'garçom'),
       now() + interval '3 days', now() + interval '3 days 6 hours',
       'corrida-ciclo-$MARCA', 'POINT(-47.8860 -15.7910)'::extensions.geography,
       18000, 1, true, true, false, 'Seu Zé', 'urgencia', gen_random_uuid(), '$DONA'
  from corrida_ciclo.cancelar c, public.estabelecimento e
 where e.endereco = 'corrida-ciclo-$MARCA';

insert into public.posicao (vaga_id, inicio_em, fim_em)
select v.id, v.inicio_em, v.fim_em
  from public.vaga v join corrida_ciclo.cancelar c on c.vaga = v.id;
SQL

  psql -tA -F' ' -c "select n, vaga, c1, c2 from corrida_ciclo.cancelar order by n" >"$TMP/cancelar"
  while read -r n vaga c1 c2; do
    lado cancelar "$n" 1 "$DONA" "select public.cancelar_vaga('$vaga', 'a casa fechou mais cedo')"
    lado cancelar "$n" 2 "$c1"   "select public.candidatar('$vaga')"
    lado cancelar "$n" 3 "$c2"   "select public.candidatar('$vaga')"
    wait
  done <"$TMP/cancelar"

  psql -tA -F' ' >"$TMP/cancelar.res" <<'SQL'
select c.n,
       coalesce((select code from corrida_ciclo.placar p
                  where p.cenario = 'cancelar' and p.rodada = c.n and p.lado = '1'), 'nada'),
       (select count(*) from corrida_ciclo.placar p
         where p.cenario = 'cancelar' and p.rodada = c.n and p.lado <> '1' and p.code = 'ok'),
       coalesce((select string_agg(distinct p.code, ',') from corrida_ciclo.placar p
                  where p.cenario = 'cancelar' and p.rodada = c.n and p.lado <> '1'
                    and p.code not in ('ok', 'posicao_ja_preenchida', 'vaga_encerrada')), '-'),
       v.estado,
       (select count(*) from public.posicao o where o.vaga_id = c.vaga and o.estado = 'confirmada')
  from corrida_ciclo.cancelar c
  join public.vaga v on v.id = c.vaga
 order by c.n;
SQL

  local ruins confirmou
  ruins=$(awk '!($2 == "ok" && $3 <= 1 && $4 == "-" && $5 == "cancelada" && $6 == 0)' "$TMP/cancelar.res")
  confirmou=$(awk '$3 == 1' "$TMP/cancelar.res" | grep -c . || true)

  if [ -z "$ruins" ]; then
    ok "$RODADAS rodadas: toda vaga terminou cancelada e sem posição confirmada ($confirmou com a candidatura confirmada antes e desfeita pelo cancelamento)"
  else
    falhou "rodadas fora da regra (rodada, cancelar, confirmações, outros códigos, vaga, posições confirmadas):"
    printf '%s\n' "$ruins" | sed 's/^/      /' >&2
  fi
}

# ── 3. dois executores do despacho × teto (RN23) ──────────────────────────────
cenario_teto() {
  echo
  echo "▸ Cenário 3: dois despachos e o agendador do teto ao mesmo tempo ($RODADAS rodadas)"

  local r ruins="" total=0
  for r in $(seq 1 "$RODADAS"); do
    limpar_teto
    psql >/dev/null <<SQL || { falhou "rodada $r: não consegui montar as vagas"; continue; }
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, publicado_por, modo, estado, chave_cliente)
select x.id, r.estabelecimento_id, r.funcao_id, r.inicio_em, r.fim_em, r.local, r.ponto,
       r.valor_centavos, 1, false, false, false, r.responsavel_local, r.publicado_por,
       r.modo, 'publicada', gen_random_uuid()
  from public.vaga r,
       (values ('$TETO_A'::uuid), ('$TETO_B'::uuid)) as x(id)
 where r.id = '$REF';
SQL

    if [ "$r" -eq 1 ]; then
      urgente=$(psql -tAc "
        select (inicio_em - privado.agora()) < privado.parametro_de_notificacao('urgente_antecedencia')
          from public.vaga where id = '$TETO_A'")
      # A vaga urgente fura o teto por decisão (RN23), e aí duas em 30 minutos é o certo.
      [ "$urgente" = "f" ] || { falhou "a vaga de referência começa em menos de 2 h: o teto não se aplica"; return; }
    fi

    # Os livres: elegíveis sem notificação no teto dentro da janela. Os outros esperariam
    # de qualquer jeito e não provam nada.
    psql -tAc "
      select e.profissional_id
        from privado.elegiveis('$TETO_A') e
        join public.profissional p on p.id = e.profissional_id
       where coalesce(privado.ultima_no_teto(p.usuario_id), '-infinity')
             <= privado.agora() - privado.parametro_de_notificacao('teto_janela')
       order by 1" >"$TMP/livres"
    local n_livres livres
    n_livres=$(grep -c . "$TMP/livres" || true)
    [ "$n_livres" -gt 0 ] || { falhou "rodada $r: nenhum elegível livre do teto"; continue; }
    livres=$(sed "s/.*/'&'::uuid/" "$TMP/livres" | paste -sd, -)

    # O terceiro executor é o agendador do teto (\`liberar_teto\`), restrito aos livres
    # desta corrida para não liberar a fila de ninguém de fora dela.
    lado teto "$r" 1 "" "select to_jsonb(privado.despachar_vaga('$TETO_A'))"
    lado teto "$r" 2 "" "select to_jsonb(privado.despachar_vaga('$TETO_B'))"
    lado teto "$r" 3 "" "select to_jsonb(count(privado.liberar_teto_do_profissional(x))) from unnest(array[$livres]) x"
    wait

    local erros duas esperando
    erros=$(psql -tAc "select coalesce(string_agg(lado || ':' || code, ','), '')
                         from corrida_ciclo.placar
                        where cenario = 'teto' and rodada = $r and code <> 'ok'")
    # Por profissional livre, as notificações no teto que ele tem dentro de 30 minutos.
    duas=$(psql -tAc "
      select count(*) from (
        select p.id
          from public.profissional p
          left join public.notificacao n
            on n.usuario_id = p.usuario_id
           and n.tipo in (select t.tipo from privado.tipo_no_teto t)
           and n.enviada_em > privado.agora() - privado.parametro_de_notificacao('teto_janela')
         where p.id in ($livres)
         group by p.id
        having count(n.id) <> 1) x")
    esperando=$(psql -tAc "
      select count(*) from public.despacho d
       where d.vaga_id in ('$TETO_A', '$TETO_B')
         and d.profissional_id in ($livres)
         and d.notificacao_id is null")

    total=$((total + n_livres))
    if [ -n "$erros" ] || [ "$duas" -ne 0 ] || [ "$esperando" -ne "$n_livres" ]; then
      ruins="$ruins
rodada $r: erros=[$erros] fora_de_uma=$duas esperando=$esperando/$n_livres"
    fi
  done
  limpar_teto

  if [ -z "$ruins" ]; then
    ok "$RODADAS rodadas, $total decisões de teto: cada livre recebeu exatamente uma notificação em 30 minutos, e a outra vaga esperou"
  else
    falhou "rodadas fora da regra:$ruins"
  fi
}

# ── 4. cancelar_vaga × cancelar_posicao ───────────────────────────────────────
cenario_posicao() {
  echo
  echo "▸ Cenário 4: cancelar_vaga × cancelar_posicao ($RODADAS rodadas)"

  # Cada rodada tem a sua vaga, com uma posição confirmada que começa daqui a 12 horas:
  # dentro das 24 h, a desistência do profissional é falta (RN12), e o cancelamento
  # pela casa não é. É o que mostra quem cancelou de fato. A confirmação entra direto na
  # tabela porque o que se mede é o que acontece depois dela.
  psql >/dev/null <<SQL || { falhou "não consegui montar as posições confirmadas"; return; }
create table corrida_ciclo.desistencia (n int, vaga uuid, posicao uuid, conta uuid);

do \$desistencia\$
declare
  c        record;
  v_estab  uuid := (select id from public.estabelecimento where endereco = 'corrida-ciclo-$MARCA');
  v_funcao uuid := (select id from public.funcao where nome = 'garçom');
  v_vaga   uuid;
  v_pos    uuid;
begin
  for c in select n, conta from corrida_ciclo.contas where papel = 'desistente' order by n loop
    insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                             valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                             exige_material_proprio, responsavel_local, modo, estado,
                             chave_cliente, publicado_por)
    values (v_estab, v_funcao, now() + interval '12 hours', now() + interval '18 hours',
            'corrida-ciclo-$MARCA', 'POINT(-47.8860 -15.7910)'::extensions.geography,
            18000, 1, true, true, false, 'Seu Zé', 'urgencia', 'preenchida',
            gen_random_uuid(), '$DONA')
    returning id into v_vaga;

    insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
    select v_vaga, 'confirmada', p.id, now() - interval '1 day',
           now() + interval '12 hours', now() + interval '18 hours'
      from public.profissional p where p.usuario_id = c.conta
    returning id into v_pos;

    insert into public.turno (posicao_id, valor_acordado_centavos) values (v_pos, 18000);

    insert into corrida_ciclo.desistencia values (c.n, v_vaga, v_pos, c.conta);
  end loop;
end
\$desistencia\$;
SQL

  psql -tA -F' ' -c "select n, vaga, posicao, conta from corrida_ciclo.desistencia order by n" \
    >"$TMP/desistencia"
  while read -r n vaga pos conta; do
    lado posicao "$n" 1 "$DONA"  "select public.cancelar_vaga('$vaga', 'a casa fechou mais cedo')"
    lado posicao "$n" 2 "$conta" "select public.cancelar_posicao('$pos', 'imprevisto de família')"
    wait
  done <"$TMP/desistencia"

  # Por rodada: o código de cada lado, a vaga, as posições vivas nela, e da posição do
  # profissional as ocorrências de cancelamento e a falta.
  psql -tA -F' ' >"$TMP/posicao.res" <<'SQL'
select d.n,
       coalesce((select code from corrida_ciclo.placar p
                  where p.cenario = 'posicao' and p.rodada = d.n and p.lado = '1'), 'nada'),
       coalesce((select code from corrida_ciclo.placar p
                  where p.cenario = 'posicao' and p.rodada = d.n and p.lado = '2'), 'nada'),
       v.estado,
       (select count(*) from public.posicao o
         where o.vaga_id = d.vaga and o.estado in ('aberta', 'confirmada')),
       (select count(*) from public.ocorrencia oc
         where oc.posicao_id = d.posicao and oc.tipo = 'cancelamento'),
       o.falta
  from corrida_ciclo.desistencia d
  join public.vaga v    on v.id = d.vaga
  join public.posicao o on o.id = d.posicao
 order by d.n;
SQL

  # Dois desfechos certos. O profissional desistiu antes: a falta é dele, e a posição
  # que ele reabriu cai junto com a vaga. A casa cancelou antes: não há falta, e quem
  # chega depois recebe posicao_nao_cancelavel. Nos dois, a vaga fica sem posição viva
  # e a posição dele tem um cancelamento só.
  local ruins n_prof n_casa
  ruins=$(awk '
    $2 == "ok" && $4 == "cancelada" && $5 == 0 && $6 == 1 &&
      (($3 == "ok" && $7 == "t") || ($3 == "posicao_nao_cancelavel" && $7 == "f")) { next }
    { print }' "$TMP/posicao.res")
  n_prof=$(awk '$3 == "ok"' "$TMP/posicao.res" | grep -c . || true)
  n_casa=$(awk '$3 == "posicao_nao_cancelavel"' "$TMP/posicao.res" | grep -c . || true)

  if [ -z "$ruins" ] && [ "$((n_prof + n_casa))" -eq "$RODADAS" ]; then
    ok "$RODADAS rodadas: $n_prof com a desistência antes (falta dele), $n_casa com a casa antes (posicao_nao_cancelavel); nenhuma posição viva em vaga cancelada, um cancelamento por posição"
  else
    falhou "rodadas fora da regra (rodada, cancelar_vaga, cancelar_posicao, vaga, posições vivas, cancelamentos da posição, falta):"
    printf '%s\n' "$ruins" | sed 's/^/      /' >&2
  fi
}

# ── 5. cancelar_vaga × candidatar × cancelar_posicao (impasse) ────────────────
#
# A corrida a três da revisão do #62. O impasse precisa de uma ordem exata:
#
#   cancelar_vaga (casa)       candidatar (prof)      cancelar_posicao (o mesmo prof)
#   ────────────────────       ─────────────────      ───────────────────────────────
#   laço das confirmadas:
#   não vê P (aberta)
#                              confirma P, commit
#   update das abertas:
#   não vê P (confirmada)
#                                                     trava P, cancela, abre P'
#   update da vaga (trava V)
#   gatilho: espera P
#                                                     update de V: espera V → 40P01
#
# Os três lados saem juntos, com a espera de cada um sorteada em milissegundos. A
# rodada certa não tem impasse nem posição viva na vaga cancelada. A desistência que
# chega antes da confirmação recebe 404 (a posição ainda não é dela), a que chega
# depois do cancelamento, 409 `posicao_nao_cancelavel`.
cenario_impasse() {
  echo
  echo "▸ Cenário 5: cancelar_vaga × candidatar × cancelar_posicao, tempos sorteados ($RODADAS rodadas)"

  psql >/dev/null <<SQL || { falhou "não consegui montar as vagas do impasse"; return; }
create table corrida_ciclo.impasse (n int, vaga uuid, posicao uuid, conta uuid);

insert into corrida_ciclo.impasse
select c.n, gen_random_uuid(), gen_random_uuid(), c.conta
  from corrida_ciclo.contas c where c.papel = 'impasse';

-- Uma posição aberta por vaga, que começa em 12 horas: a desistência depois da
-- confirmação é falta (RN12), e a vaga fica preenchida quando o candidato a pega, que
-- é o que faz a reabertura esperar a linha da vaga.
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, chave_cliente,
                         publicado_por)
select i.vaga, e.id, (select id from public.funcao where nome = 'garçom'),
       now() + interval '12 hours', now() + interval '18 hours',
       'corrida-ciclo-$MARCA', 'POINT(-47.8860 -15.7910)'::extensions.geography,
       18000, 1, true, true, false, 'Seu Zé', 'urgencia', gen_random_uuid(), '$DONA'
  from corrida_ciclo.impasse i, public.estabelecimento e
 where e.endereco = 'corrida-ciclo-$MARCA';

insert into public.posicao (id, vaga_id, inicio_em, fim_em)
select i.posicao, v.id, v.inicio_em, v.fim_em
  from public.vaga v join corrida_ciclo.impasse i on i.vaga = v.id;
SQL

  psql -tA -F' ' -c "select n, vaga, posicao, conta from corrida_ciclo.impasse order by n" \
    >"$TMP/impasse"
  # A desistência sai um pouco depois dos outros dois: ela só age sobre a posição que a
  # candidatura já confirmou.
  local ms
  ms() { printf '0.%03d 0' "$(( ${2:-0} + RANDOM % $1 ))"; }
  while read -r n vaga pos conta; do
    lado impasse "$n" 1 "$DONA"  "select public.cancelar_vaga('$vaga', 'a casa fechou mais cedo')" "$(ms 30)"
    lado impasse "$n" 2 "$conta" "select public.candidatar('$vaga')" "$(ms 30)"
    lado impasse "$n" 3 "$conta" "select public.cancelar_posicao('$pos', 'imprevisto de família')" "$(ms 50 15)"
    wait
  done <"$TMP/impasse"

  # Por rodada: o código de cada lado, a vaga, as posições vivas nela e os cancelamentos
  # da posição do candidato.
  psql -tA -F' ' >"$TMP/impasse.res" <<'SQL'
select i.n,
       coalesce((select code from corrida_ciclo.placar p
                  where p.cenario = 'impasse' and p.rodada = i.n and p.lado = '1'), 'nada'),
       coalesce((select code from corrida_ciclo.placar p
                  where p.cenario = 'impasse' and p.rodada = i.n and p.lado = '2'), 'nada'),
       coalesce((select code from corrida_ciclo.placar p
                  where p.cenario = 'impasse' and p.rodada = i.n and p.lado = '3'), 'nada'),
       v.estado,
       (select count(*) from public.posicao o
         where o.vaga_id = i.vaga and o.estado in ('aberta', 'confirmada')),
       (select count(*) from public.ocorrencia oc
         where oc.posicao_id = i.posicao and oc.tipo = 'cancelamento')
  from corrida_ciclo.impasse i
  join public.vaga v on v.id = i.vaga
 order by i.n;
SQL

  local ruins impasses tres
  ruins=$(awk '
    $2 == "ok" &&
    ($3 == "ok" || $3 == "vaga_encerrada" || $3 == "posicao_ja_preenchida") &&
    ($4 == "ok" || $4 == "posicao_nao_cancelavel" || $4 == "nao_encontrado") &&
    $5 == "cancelada" && $6 == 0 && $7 <= 1 { next }
    { print }' "$TMP/impasse.res")
  impasses=$(grep -c 'sqlstate:40P01' "$TMP/impasse.res" || true)
  # As rodadas em que os três agiram: a candidatura confirmou e a desistência pegou a
  # posição confirmada. É só nelas que o impasse pode acontecer.
  tres=$(awk '$3 == "ok" && $4 == "ok"' "$TMP/impasse.res" | grep -c . || true)

  if [ -z "$ruins" ]; then
    ok "$RODADAS rodadas, $tres com os três lados agindo: nenhum impasse (40P01), nenhuma posição viva em vaga cancelada"
  else
    falhou "rodadas fora da regra, $impasses com impasse 40P01 (rodada, cancelar_vaga, candidatar, cancelar_posicao, vaga, posições vivas, cancelamentos da posição):"
    printf '%s\n' "$ruins" | sed 's/^/      /' >&2
  fi
}

# ── 6. a mesma corrida com a janela alargada (janela) ─────────────────────────
#
# A janela do cenário 5 é de microssegundos, e o sorteio quase nunca cai nela. Aqui
# duas conexões de serviço seguram linhas para pôr cada lado no ponto exato. A vaga
# tem duas posições: Q, confirmada por outro profissional, e P, aberta.
#
#   t     lado
#   0     trava 1 segura Q (até 1,0 s)
#   0,2   cancelar_vaga: o laço das confirmadas lê Q (P ainda aberta) e espera Q
#   0,4   candidatar P
#   0,6   trava 2 segura o turno de P, se ele já existir (até 1,3 s)
#   0,8   cancelar_posicao de P
#   1,0   trava 1 solta Q
#
# Na ordem antiga (posição → vaga, com o gatilho como exceção), a candidatura confirma
# P no meio do cancelamento, a desistência segura P e espera o turno, o gatilho segura
# a vaga e espera P, a desistência pede a vaga: impasse em toda rodada. Na ordem vaga →
# posição (CPD2c74A), o laço da casa trava a vaga antes de Q, e a candidatura espera a
# casa: a corrida vira fila, e a candidatura lê a vaga cancelada.
#
# As travas seguram as linhas como qualquer transação de escrita seguraria — um
# cancelamento lento de Q, um fechamento no turno de P. O que elas mudam é só a
# duração da janela.

# O palco dos cenários 6 e 7: uma vaga por rodada, com Q confirmada (e o turno dela)
# e P aberta.
montar_janela() { # tabela papel
  psql >/dev/null <<SQL
create table corrida_ciclo.$1 (n int, vaga uuid, p uuid, q uuid, conta uuid, outra uuid);

insert into corrida_ciclo.$1
select r.n, gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
       (select conta from corrida_ciclo.contas where papel = '$2' and n = 2 * r.n - 1),
       (select conta from corrida_ciclo.contas where papel = '$2' and n = 2 * r.n)
  from generate_series(1, $RODADAS) r(n);

insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, chave_cliente,
                         publicado_por)
select j.vaga, e.id, (select id from public.funcao where nome = 'garçom'),
       now() + interval '12 hours', now() + interval '18 hours',
       'corrida-ciclo-$MARCA', 'POINT(-47.8860 -15.7910)'::extensions.geography,
       18000, 2, true, true, false, 'Seu Zé', 'urgencia', gen_random_uuid(), '$DONA'
  from corrida_ciclo.$1 j, public.estabelecimento e
 where e.endereco = 'corrida-ciclo-$MARCA';

insert into public.posicao (id, vaga_id, inicio_em, fim_em)
select j.p, v.id, v.inicio_em, v.fim_em
  from public.vaga v join corrida_ciclo.$1 j on j.vaga = v.id;

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em)
select j.q, v.id, v.inicio_em, v.fim_em, 'confirmada', pr.id, now() - interval '1 day'
  from public.vaga v
  join corrida_ciclo.$1 j on j.vaga = v.id
  join public.profissional pr on pr.usuario_id = j.outra;

insert into public.turno (posicao_id, valor_acordado_centavos)
select j.q, 18000 from corrida_ciclo.$1 j;
SQL
}

# Por rodada: o código de cada lado (casa, candidatura, desistência), a vaga, as
# posições vivas nela, os cancelamentos de P e de Q, e os erros das travas.
placar_janela() { # tabela cenario lado_casa lado_cand lado_desist
  psql -tA -F' ' <<SQL
select j.n,
       coalesce((select code from corrida_ciclo.placar p
                  where p.cenario = '$2' and p.rodada = j.n and p.lado = '$3'), '-'),
       coalesce((select code from corrida_ciclo.placar p
                  where p.cenario = '$2' and p.rodada = j.n and p.lado = '$4'), '-'),
       coalesce((select code from corrida_ciclo.placar p
                  where p.cenario = '$2' and p.rodada = j.n and p.lado = '$5'), '-'),
       v.estado,
       (select count(*) from public.posicao o
         where o.vaga_id = j.vaga and o.estado in ('aberta', 'confirmada')),
       (select count(*) from public.ocorrencia oc
         where oc.posicao_id = j.p and oc.tipo = 'cancelamento'),
       (select count(*) from public.ocorrencia oc
         where oc.posicao_id = j.q and oc.tipo = 'cancelamento'),
       coalesce((select string_agg(p.lado || ':' || p.code, ',') from corrida_ciclo.placar p
                  where p.cenario = '$2' and p.rodada = j.n
                    and p.lado not in ('$3', '$4', '$5') and p.code <> 'ok'), '-')
  from corrida_ciclo.$1 j
  join public.vaga v on v.id = j.vaga
 order by j.n;
SQL
}

# A regra dos cenários 6 e 7: a casa cancela, nenhum lado em impasse, nenhuma posição
# viva na vaga cancelada, Q com um cancelamento e P com no máximo um, cada lado com um
# código que casa com a ordem em que chegou. O 57014 é o statement_timeout do cenário 7.
fora_da_regra_janela() { # arquivo
  awk '
    $2 == "ok" &&
    ($3 == "-" || $3 == "ok" || $3 == "vaga_encerrada" || $3 == "posicao_ja_preenchida") &&
    ($4 == "ok" || $4 == "posicao_nao_cancelavel" || $4 == "nao_encontrado" ||
     $4 == "sqlstate:57014") &&
    $5 == "cancelada" && $6 == 0 && $7 <= 1 && $8 == 1 && $9 == "-" { next }
    { print }' "$1"
}

cenario_janela() {
  echo
  echo "▸ Cenário 6: o impasse com a janela alargada por travas ($RODADAS rodadas)"

  montar_janela janela janela || { falhou "não consegui montar as vagas da janela"; return; }

  psql -tA -F' ' -c "select n, vaga, p, q, conta from corrida_ciclo.janela order by n" \
    >"$TMP/janela"
  while read -r n vaga p q conta; do
    lado janela "$n" 1 ""       "select to_jsonb(count(*)) from (select 1 from public.posicao where id = '$q' for update) x" "0 1.0"
    lado janela "$n" 2 "$DONA"  "select public.cancelar_vaga('$vaga', 'a casa fechou mais cedo')" "0.2 0"
    lado janela "$n" 3 "$conta" "select public.candidatar('$vaga')" "0.4 0"
    lado janela "$n" 4 ""       "select to_jsonb(count(*)) from (select 1 from public.turno where posicao_id = '$p' for update) x" "0.6 0.7"
    lado janela "$n" 5 "$conta" "select public.cancelar_posicao('$p', 'imprevisto de família')" "0.8 0"
    wait
  done <"$TMP/janela"

  placar_janela janela janela 2 3 5 >"$TMP/janela.res"

  local ruins impasses abertas fila
  ruins=$(fora_da_regra_janela "$TMP/janela.res")
  impasses=$(grep -c 'sqlstate:40P01' "$TMP/janela.res" || true)
  # A janela abre quando a candidatura confirma P no meio do cancelamento; ela vira
  # fila quando a candidatura espera a casa e lê a vaga cancelada.
  abertas=$(awk '$3 == "ok"' "$TMP/janela.res" | grep -c . || true)
  fila=$(awk '$3 == "vaga_encerrada"' "$TMP/janela.res" | grep -c . || true)

  if [ -z "$ruins" ]; then
    ok "$RODADAS rodadas: nenhum impasse, nenhuma posição viva na vaga cancelada ($fila com a candidatura na fila atrás da casa, $abertas com a janela aberta)"
  else
    falhou "rodadas fora da regra: $impasses com impasse 40P01, $abertas com a janela aberta (rodada, cancelar_vaga, candidatar, cancelar_posicao, vaga, posições vivas, cancelamentos de P, de Q, travas):"
    printf '%s\n' "$ruins" | sed 's/^/      /' >&2
  fi
}

# ── 7. quem segura a posição desfaz (rollback) ────────────────────────────────
#
# O cenário da revisão do #63. A versão com `skip locked` do gatilho pulava a posição
# que outra transação segurava; se essa transação desfizesse depois, a posição voltava
# a `confirmada` numa vaga que já tinha comitado `cancelada`. Aqui a desistência leva
# statement_timeout de 1,5 s e fica presa no turno de P por 2 s: ela sempre desfaz.
#
#   rodada ímpar — a janela do cenário 6, com a trava do turno segurando até 2,6 s:
#     0     trava 1 segura Q (até 1,0 s)
#     0,2   cancelar_vaga
#     0,4   candidatar P
#     0,6   trava 2 segura o turno de P (até 2,6 s)
#     0,8   cancelar_posicao de P, statement_timeout 1,5 s → desfaz em 2,3 s
#   rodada par — a desistência chega antes da casa, segura a vaga e Q, e desfaz:
#     0     trava 2 segura o turno de Q (até 2,0 s)
#     0,1   cancelar_posicao de Q pelo outro profissional, statement_timeout 1,5 s
#     0,3   cancelar_vaga: espera a desistência, e depois dela cancela Q
#
# Em nenhuma das duas sobra posição viva na vaga cancelada.
cenario_rollback() {
  echo
  echo "▸ Cenário 7: quem segura a posição desfaz no meio do cancelamento ($RODADAS rodadas)"

  montar_janela rollback rollback || { falhou "não consegui montar as vagas do rollback"; return; }

  psql -tA -F' ' -c "select n, vaga, p, q, conta, outra from corrida_ciclo.rollback order by n" \
    >"$TMP/rollback"
  while read -r n vaga p q conta outra; do
    if [ $((n % 2)) -eq 1 ]; then
      lado rollback "$n" 1 ""       "select to_jsonb(count(*)) from (select 1 from public.posicao where id = '$q' for update) x" "0 1.0"
      lado rollback "$n" 2 "$DONA"  "select public.cancelar_vaga('$vaga', 'a casa fechou mais cedo')" "0.2 0"
      lado rollback "$n" 3 "$conta" "select public.candidatar('$vaga')" "0.4 0"
      lado rollback "$n" 4 ""       "select to_jsonb(count(*)) from (select 1 from public.turno where posicao_id = '$p' for update) x" "0.6 2.0"
      lado rollback "$n" 5 "$conta" "select public.cancelar_posicao('$p', 'imprevisto de família')" "0.8 0" 1500
    else
      lado rollback "$n" 4 ""       "select to_jsonb(count(*)) from (select 1 from public.turno where posicao_id = '$q' for update) x" "0 2.0"
      lado rollback "$n" 5 "$outra" "select public.cancelar_posicao('$q', 'imprevisto de família')" "0.1 0" 1500
      lado rollback "$n" 2 "$DONA"  "select public.cancelar_vaga('$vaga', 'a casa fechou mais cedo')" "0.3 0"
    fi
    wait
  done <"$TMP/rollback"

  placar_janela rollback rollback 2 3 5 >"$TMP/rollback.res"

  local ruins desfeitas
  ruins=$(fora_da_regra_janela "$TMP/rollback.res")
  desfeitas=$(grep -c 'sqlstate:57014' "$TMP/rollback.res" || true)

  if [ -z "$ruins" ]; then
    ok "$RODADAS rodadas, $desfeitas desistências desfeitas por timeout: nenhuma posição viva na vaga cancelada, nenhum impasse"
  else
    falhou "rodadas fora da regra, $desfeitas desistências desfeitas (rodada, cancelar_vaga, candidatar, cancelar_posicao, vaga, posições vivas, cancelamentos de P, de Q, travas):"
    printf '%s\n' "$ruins" | sed 's/^/      /' >&2
  fi
}

for c in $CENARIOS; do "cenario_$c"; done

# Um erro que não passou pelo placar (a conexão caiu, o psql não subiu) também reprova.
if cat "$TMP"/*.err 2>/dev/null | grep -q .; then
  falhou "houve erro fora do placar:"
  cat "$TMP"/*.err | sort | uniq -c | head -5 >&2
fi

echo
[ "$falha" -eq 0 ] && echo "Corridas do ciclo: ok" || echo "Corridas do ciclo: FALHOU" >&2
exit "$falha"
