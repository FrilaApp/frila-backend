#!/usr/bin/env bash
# `candidatar` com vinte pessoas aceitando a mesma vaga ao mesmo tempo.
#
# É a única prova possível de RN19. O pgTAP roda numa sessão só: ele vê o segundo
# candidato receber `posicao_ja_preenchida` porque o primeiro já comitou, o que não diz
# nada sobre o caso real — vinte transações abertas ao mesmo tempo, disputando as mesmas
# linhas antes de qualquer commit.
#
# O desenho: uma vaga com DUAS posições e VINTE profissionais, cada um numa conexão.
# No fim tem de haver exatamente 2 confirmações e 18 recusas `posicao_ja_preenchida`.
#
#   2 confirmações  ninguém ficou com uma posição que já era de outro (RN19)
#   18 recusas      e a recusa é `posicao_ja_preenchida`, não um erro qualquer
#
# Defesa contra passar por motivo errado: um `posicao_ja_preenchida` também sairia se a
# função recusasse todo mundo por engano. Por isso o script exige o número **exato** dos
# dois lados, confere que as duas posições têm profissionais **diferentes**, e confere
# que a vaga terminou `preenchida`.
#
# Uso:  ./scripts/corrida-candidatar.sh
#       CLIENTES=20 POSICOES=2 ./scripts/corrida-candidatar.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}
CLIENTES=${CLIENTES:-20}
POSICOES=${POSICOES:-2}

psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

ok()    { printf '  ✓ %s\n' "$1"; }
falhou(){ printf '  ✗ %s\n' "$1" >&2; falha=1; }

falha=0
MARCA=$(python3 -c 'import uuid; print(uuid.uuid4())')

limpar() {
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: a limpeza falhou; sobrou o schema corrida_$(echo "$MARCA" | tr -d -)" >&2
drop schema if exists corrida cascade;
delete from public.turno       where posicao_id in (select id from public.posicao where vaga_id in (select id from public.vaga where local = 'corrida-$MARCA'));
delete from public.candidatura where posicao_id in (select id from public.posicao where vaga_id in (select id from public.vaga where local = 'corrida-$MARCA'));
delete from public.posicao     where vaga_id in (select id from public.vaga where local = 'corrida-$MARCA');
delete from public.vaga        where local = 'corrida-$MARCA';
delete from public.membro_estabelecimento where estabelecimento_id in (select id from public.estabelecimento where endereco = 'corrida-$MARCA');
delete from public.estabelecimento where endereco = 'corrida-$MARCA';
delete from public.profissional_funcao where profissional_id in (select id from public.profissional where usuario_id in (select id from public.usuario where email like 'corrida-$MARCA-%'));
delete from public.profissional where usuario_id in (select id from public.usuario where email like 'corrida-$MARCA-%');
delete from public.usuario  where email like 'corrida-$MARCA-%';
delete from auth.users      where email like 'corrida-$MARCA-%';
SQL
}
trap limpar EXIT

echo "▸ Montando a corrida: $CLIENTES candidatos para $POSICOES posições"

# A vaga e os candidatos nascem pelas RPCs, como o app cria — e não por INSERT direto.
# Um cenário montado à mão testaria um caminho que o produto não percorre.
psql >/dev/null <<SQL
do \$corrida\$
declare
  v_dona  uuid := gen_random_uuid();
  v_estab uuid;
  v_funcao uuid;
  v_conta uuid;
  i int;
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', v_dona, 'authenticated', 'authenticated',
          'corrida-$MARCA-dona@frila.test', now(), '{"provider":"email"}', '{}', now(), now(), false, false);

  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_dona, 'contratante', 'Dona da Corrida', '+5561977770000',
          'corrida-$MARCA-dona@frila.test', '1980-01-01', '2026-09-22', now());

  insert into public.estabelecimento (nome, documento, tipo, endereco, ponto)
  values ('Casa da Corrida', lpad((floor(random() * 1e13))::bigint::text, 14, '7'),
          'food_service', 'corrida-$MARCA',
          'POINT(-47.8860 -15.7910)'::extensions.geography)
  returning id into v_estab;

  insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
  values (v_dona, v_estab, 'administrador');

  select id into v_funcao from public.funcao where nome = 'garçom';

  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente,
                           publicado_por)
  values (v_estab, v_funcao, now() + interval '3 days', now() + interval '3 days 6 hours',
          'corrida-$MARCA', 'POINT(-47.8860 -15.7910)'::extensions.geography,
          18000, $POSICOES, true, true, false, 'Seu Zé', 'urgencia', gen_random_uuid(), v_dona);

  insert into public.posicao (vaga_id, inicio_em, fim_em)
  select v.id, v.inicio_em, v.fim_em
    from public.vaga v, generate_series(1, $POSICOES)
   where v.local = 'corrida-$MARCA';

  for i in 1..$CLIENTES loop
    v_conta := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            is_sso_user, is_anonymous)
    values ('00000000-0000-0000-0000-000000000000', v_conta, 'authenticated', 'authenticated',
            'corrida-$MARCA-' || i || '@frila.test', now(), '{"provider":"email"}', '{}',
            now(), now(), false, false);

    insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
    values (v_conta, 'profissional', 'Candidato ' || i,
            '+55619' || lpad(i::text, 8, '0'), 'corrida-$MARCA-' || i || '@frila.test',
            '1995-01-01', '2026-09-22', now());

    insert into public.profissional (usuario_id, ponto_base)
    values (v_conta, 'POINT(-47.8850 -15.7900)'::extensions.geography);

    insert into public.profissional_funcao (profissional_id, funcao_id)
    select p.id, v_funcao from public.profissional p where p.usuario_id = v_conta;
  end loop;
end
\$corrida\$;

-- O placar e o disparador. Ficam num schema próprio, apagado na saída: a função precisa
-- existir para todas as conexões do pgbench, e por isso não pode ser \`pg_temp\`.
create schema corrida;

create table corrida.placar (
  conta   uuid not null,
  code    text,
  turno   uuid
);

create table corrida.candidatos as
  select row_number() over (order by u.email) as n, u.id as conta
    from public.usuario u
   where u.email like 'corrida-$MARCA-%' and u.perfil = 'profissional';

create function corrida.tentar(n int) returns void
language plpgsql as \$tentar\$
declare
  v_conta uuid;
  v_vaga  uuid;
  r       jsonb;
begin
  select conta into v_conta from corrida.candidatos c where c.n = tentar.n;
  select id    into v_vaga  from public.vaga where local = 'corrida-$MARCA';

  -- A chamada entra pelo mesmo caminho do app: role \`authenticated\` e a claim \`sub\`.
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', v_conta, 'role', 'authenticated')::text);

  begin
    r := public.candidatar(v_vaga);
    execute 'reset role';
    execute 'reset request.jwt.claims';
    insert into corrida.placar (conta, code, turno)
    values (v_conta, 'ok', (r->>'turno_id')::uuid);
  exception when others then
    execute 'reset role';
    execute 'reset request.jwt.claims';
    -- O envelope do erro é JSON: o código estável está em \`code\`. Guardar a mensagem
    -- crua deixaria o placar contando "erro" em vez de contar RN19.
    insert into corrida.placar (conta, code, turno)
    values (v_conta,
            coalesce((sqlerrm::jsonb)->>'code', 'sqlstate:' || sqlstate), null);
  end;
end
\$tentar\$;
SQL

[ $? -eq 0 ] || { echo "não consegui montar a corrida" >&2; exit 1; }

cat > /tmp/corrida-candidatar.pgbench <<'BENCH'
\set n :client_id + 1
BEGIN;
SELECT corrida.tentar(:n);
END;
BENCH
docker cp /tmp/corrida-candidatar.pgbench "$DB":/tmp/corrida.pgbench >/dev/null
rm -f /tmp/corrida-candidatar.pgbench

echo "▸ $CLIENTES conexões simultâneas"
docker exec -i "$DB" pgbench -U postgres -d postgres \
  -c "$CLIENTES" -j 4 -t 1 -n -f /tmp/corrida.pgbench 2>&1 | tail -3

# ── O placar ──────────────────────────────────────────────────────────────────
confirmadas=$(psql -tAc "select count(*) from corrida.placar where code = 'ok'")
recusadas=$(psql -tAc "select count(*) from corrida.placar where code = 'posicao_ja_preenchida'")
outros=$(psql -tAc "select coalesce(string_agg(distinct code, ', '), '') from corrida.placar
                     where code not in ('ok', 'posicao_ja_preenchida')")
distintos=$(psql -tAc "select count(distinct profissional_id) from public.posicao
                        where vaga_id in (select id from public.vaga where local = 'corrida-$MARCA')
                          and estado = 'confirmada'")
turnos=$(psql -tAc "select count(*) from public.turno t join public.posicao p on p.id = t.posicao_id
                     where p.vaga_id in (select id from public.vaga where local = 'corrida-$MARCA')")
estado=$(psql -tAc "select estado from public.vaga where local = 'corrida-$MARCA'")

echo
[ "$confirmadas" = "$POSICOES" ] \
  && ok "RN19: exatamente $POSICOES confirmações para $POSICOES posições" \
  || falhou "RN19: $confirmadas confirmações para $POSICOES posições"

[ "$recusadas" = "$((CLIENTES - POSICOES))" ] \
  && ok "e $recusadas recusas posicao_ja_preenchida, que é funcionamento normal" \
  || falhou "$recusadas recusas posicao_ja_preenchida, esperado $((CLIENTES - POSICOES))"

[ -z "$outros" ] \
  && ok "nenhuma recusa por outro motivo" \
  || falhou "houve recusa por outro motivo: $outros"

[ "$distintos" = "$POSICOES" ] \
  && ok "as $POSICOES posições ficaram com profissionais diferentes" \
  || falhou "as posições confirmadas têm $distintos profissionais distintos"

[ "$turnos" = "$POSICOES" ] \
  && ok "e nasceram $turnos turnos, um por confirmação" \
  || falhou "$turnos turnos para $POSICOES confirmações"

[ "$estado" = "preenchida" ] \
  && ok "a vaga terminou preenchida" \
  || falhou "a vaga terminou '$estado', esperado preenchida"

echo
[ "$falha" -eq 0 ] && echo "Corrida da candidatura: ok" || echo "Corrida da candidatura: FALHOU" >&2
exit "$falha"
