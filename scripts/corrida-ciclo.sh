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
#
# Os de candidatura (vinte para duas posições, profissional em dobro) seguem em
# `corrida-candidatar.sh`.
#
# Uso:  ./scripts/corrida-ciclo.sh
#       RODADAS=10 ./scripts/corrida-ciclo.sh
#       CENARIOS="checkin cancelar teto" ./scripts/corrida-ciclo.sh
#       MANTER=1 ./scripts/corrida-ciclo.sh     # não limpa: o placar fica em corrida_ciclo
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}
RODADAS=${RODADAS:-50}
CENARIOS=${CENARIOS:-checkin cancelar teto}

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
  exception when others then
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

  -- Um profissional por rodada no check-in, dois por rodada no cancelamento.
  for r in select 'atrasado' as papel, n from generate_series(1, $RODADAS) n
           union all
           select 'candidato', n from generate_series(1, 2 * $RODADAS) n
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

# Um lado da corrida numa conexão própria, em segundo plano.
lado() { # cenario rodada lado conta sql
  local ant dep conta
  read -r ant dep < <(tempos "$2" "$3")
  conta=$([ -n "$4" ] && echo "'$4'::uuid" || echo "null")
  psql -tA >/dev/null 2>"$TMP/$1-$2-$3.err" <<SQL &
set application_name = 'corrida_ciclo_$1_$3';
-- O despacho pós-commit (\`privado.disparar_despacho\`) exige o segredo do agendador. A
-- CI grava um efêmero no banco; fora dela, depois de um \`db reset\`, não há nenhum, e a
-- sessão da corrida usa um valor de teste, como o pgTAP faz com \`set local\`.
select set_config('frila.agendador_secret', 'segredo-da-corrida', false)
 where nullif(current_setting('frila.agendador_secret', true), '') is null;
begin;
select pg_sleep($ant);
select corrida_ciclo.agir('$1', $2, '$3', $conta, \$sql\$$5\$sql\$);
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

for c in $CENARIOS; do "cenario_$c"; done

# Um erro que não passou pelo placar (a conexão caiu, o psql não subiu) também reprova.
if cat "$TMP"/*.err 2>/dev/null | grep -q .; then
  falhou "houve erro fora do placar:"
  cat "$TMP"/*.err | sort | uniq -c | head -5 >&2
fi

echo
[ "$falha" -eq 0 ] && echo "Corridas do ciclo: ok" || echo "Corridas do ciclo: FALHOU" >&2
exit "$falha"
