#!/usr/bin/env bash
# Prepara o frila-dev (ou o banco local, no ensaio) para o teste de ponta a ponta da busca de profissionais
# (B-027.f; contrato 0.2.88): uma casa de TESTE e três profissionais de TESTE, todos sintéticos, que o iOS
# (Prisma) consegue buscar e chamar. Nada de pessoa real, nada no Prod.
#
# ── O que fica criado (ids fixos, então rodar de novo repara e não duplica) ───────────────────────────────
#
#   conta      e-mail                       id                                     perfil
#   casa       busca-casa@frila.test        b027f000-0000-4000-8000-000000000001   contratante (admin da casa)
#   prof 1     busca-prof-1@frila.test      b027f000-0000-4000-8000-000000000011   profissional
#   prof 2     busca-prof-2@frila.test      b027f000-0000-4000-8000-000000000012   profissional
#   prof 3     busca-prof-3@frila.test      b027f000-0000-4000-8000-000000000013   profissional
#   estabelecimento "Casa Teste Busca"      b027f000-0000-4000-8000-0000000000c1   (CNPJ sintético, Plano Piloto)
#   profissional.id: ...0021, ...0022, ...0023 (na mesma ordem dos prof 1, 2, 3)
#
#   prof 1  Ana Faxineira Teste     faxina residencial (diária)    TODO O DF         até 5 km    seg a sex 08h-18h
#   prof 2  Bruno Garçom Teste      garçom (hora), cozinheiro de   Plano Piloto +    5 a 15 km   qui a dom 18h-02h
#                                   festa (evento)                 Guará
#   prof 3  Clara Cozinheira Teste  cozinheiro de festa (por       Plano Piloto      mais de     sáb e dom 10h-22h
#                                   pessoa), garçom (a combinar)   (só ela)          15 km
#
# Todos com "Aceito chamadas diretas" ligado (pela RPC definir_preferencia_chamadas, como o profissional) e um
# aparelho iOS na versão mínima da chamada_direta. A casa e os profissionais são da MESMA população
# (usuario.demonstracao = false), que é o que a busca exige (privado.profissionais_na_busca).
#
# ── Como o Prisma entra (login por código de e-mail) ──────────────────────────────────────────────────────
#
# O e-mail @frila.test não recebe nada. O código vem de `codigo <e-mail>`, que pede ao Auth do projeto um
# código de uma vez só (a mesma chamada de e-mail+código que o app faz) e o escreve no terminal de quem rodou.
# Ele nunca vai para arquivo, log ou documento. Ordem certa, porque pedir um código novo no app invalida o
# anterior:
#   1. no app, digite o e-mail e toque em pedir código (a tela passa para o campo do código);
#   2. `./scripts/dev-busca-teste.sh --alvo dev codigo busca-casa@frila.test`;
#   3. digite o código na tela. Vale uma vez e por até 1 hora (o padrão do Auth).
# `codigo` só aceita os 4 e-mails acima, e só de conta que `montar` já criou: nunca cria conta nem gera código
# para e-mail de pessoa.
#
# ── Uso ───────────────────────────────────────────────────────────────────────────────────────────────────
#
#   ./scripts/dev-busca-teste.sh [--alvo local|dev] montar [--minimo-busca <versão>]
#   ./scripts/dev-busca-teste.sh [--alvo local|dev] conferir        # 4 buscas como a casa, transação desfeita
#   ./scripts/dev-busca-teste.sh [--alvo local|dev] http            # entra pelo Auth e busca pelo REST (4 logins)
#   ./scripts/dev-busca-teste.sh [--alvo local|dev] codigo <e-mail> # o código de entrada, para o Prisma
#   ./scripts/dev-busca-teste.sh [--alvo local|dev] estado          # chaves, versões mínimas e o resumo
#
# O alvo padrão é o banco LOCAL (o ensaio). `--alvo dev` lê a conexão de ~/.config/frila/dev-db-url sem
# imprimi-la. Não existe alvo prod: o script não sabe falar com ele.
#
# ── O que `montar` faz e o que NÃO faz com as chaves ──────────────────────────────────────────────────────
#
# Liga `busca_profissionais` e `chamada_direta` em privado.recurso (no dev; no Prod isso é ato do O2).
# A VERSÃO MÍNIMA do iOS é por chave em privado.recurso_versao_minima, e o app só vê
# `recursos.busca_profissionais = true` se existir a linha da busca (a migração não cria nenhuma). Decisão da
# Forja (16/11/2026): no dev, sem linha, o `montar` copia a mínima da chamada_direta (o Prisma testa com o
# build atual); linha que já existe não é tocada, e `--minimo-busca <versão>` sobrescreve. No Prod o script
# não roda: a chave fica desligada e a mínima se decide ao ligar.
#
# Aparelhos de teste: o token FCM é falso de propósito. Se alguma chamada de teste tentar mandar push a um
# deles, o FCM responde UNREGISTERED e o enviar-push APAGA a linha do aparelho (supabase/functions/enviar-push/
# index.ts); sem aparelho, o profissional some da busca. É só rodar `montar` de novo.
#
# Pelo banco compartilhado: no local, rode pela fila (orquestracao/scripts/fila.sh rodar banco <dono> -- ...).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ALVO=local
DB_CONTAINER=${DB_CONTAINER:-supabase_db_frila-backend}
PSQL=${PSQL:-/opt/homebrew/opt/postgresql@16/bin/psql}
MINIMO_BUSCA=""

CASA_USUARIO=b027f000-0000-4000-8000-000000000001
CASA_ESTAB=b027f000-0000-4000-8000-0000000000c1
EMAILS_DE_TESTE="busca-casa@frila.test busca-prof-1@frila.test busca-prof-2@frila.test busca-prof-3@frila.test"

ok()      { printf '  ✓ %s\n' "$1"; }
aviso()   { printf '  ! %s\n' "$1" >&2; }
falhou()  { printf '  ✗ %s\n' "$1" >&2; exit 1; }

# Nada que identifique o projeto ou carregue senha sai na tela, nem num erro do psql.
redigir() {
  sed -E 's#postgres(ql)?://[^[:space:]"]+#postgres://<oculto>#g; s#(host|at) "[^"]*"#\1 "<oculto>"#g; s#postgres\.[a-z0-9]{20}#postgres.<ref>#g; s#[a-z0-9]{20}\.(supabase|pooler\.supabase)\.(co|com)#<ref>.\1.\2#g'
}

# ── Argumentos (as opções valem antes ou depois do comando) ───────────────
COMANDO=""; ARG1=""
while [ $# -gt 0 ]; do
  case "$1" in
    --alvo)          ALVO="${2:-}"; shift 2 || break ;;
    --minimo-busca)  MINIMO_BUSCA="${2:-}"; shift 2 || break ;;
    -h|--ajuda)      sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)              falhou "opção desconhecida: $1 (veja --ajuda)" ;;
    *)               if [ -z "$COMANDO" ]; then COMANDO="$1"; elif [ -z "$ARG1" ]; then ARG1="$1"; else falhou "argumento a mais: $1"; fi; shift ;;
  esac
done
case "$ALVO" in local|dev) ;; *) falhou "--alvo vale local ou dev (recebi \"$ALVO\"). Prod não existe aqui." ;; esac
case "$COMANDO" in montar|conferir|http|codigo|estado) ;; *) falhou "uso: dev-busca-teste.sh [--alvo local|dev] montar|conferir|http|codigo <e-mail>|estado (veja --ajuda)" ;; esac
if [ -n "$MINIMO_BUSCA" ] && ! printf '%s' "$MINIMO_BUSCA" | grep -Eq '^[0-9]{1,6}(\.[0-9]{1,6}){0,2}$'; then
  falhou "--minimo-busca precisa ter de 1 a 3 partes numéricas (ex.: 1.2.0)"
fi

# ── Acesso ao banco ────────────────────────────────────────────────────────
PGURL=""
if [ "$ALVO" = dev ]; then
  [ -f "$HOME/.config/frila/dev-db-url" ] || falhou "não achei ~/.config/frila/dev-db-url"
  [ -x "$PSQL" ] || falhou "não achei o psql em $PSQL (defina PSQL)"
  PGURL="$(tr -d '\n' < "$HOME/.config/frila/dev-db-url" | sed 's/^[A-Za-z_]*=//')"
  [ -n "$PGURL" ] || falhou "o arquivo dev-db-url (em .config/frila) está vazio"
else
  docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER" \
    || falhou "o contêiner $DB_CONTAINER não está de pé (supabase start; ou defina DB_CONTAINER)"
fi

psql_() {
  if [ "$ALVO" = dev ]; then
    "$PSQL" "$PGURL" -X -q -t -A -v ON_ERROR_STOP=1 "$@" 2> >(redigir >&2)
  else
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 "$@"
  fi
}

# A busca precisa existir neste banco (a migração 20261116210000). A de chamar (20261116220000) é só informada.
checar_migracoes() {
  local presentes
  presentes=$(psql_ -c "select coalesce(string_agg(version, ' ' order by version), '') from supabase_migrations.schema_migrations
                         where version in ('20261116210000', '20261116220000');")
  case " $presentes " in
    *" 20261116210000 "*) ok "migração da busca (20261116210000) está neste banco" ;;
    *) falhou "a migração 20261116210000 NÃO está neste banco ($ALVO). Espere a Entrega aplicar depois da mescla do #517" ;;
  esac
  case " $presentes " in
    *" 20261116220000 "*) ok "migração de chamar e perfil (20261116220000) também está" ;;
    *) aviso "a migração 20261116220000 (chamar_profissional pela busca, perfil) ainda NÃO está: a busca roda, o chamar a partir dela não" ;;
  esac
}

# ── Resumo (chaves, versões mínimas, ids e o que cada um tem) ──────────────
recursos() {
  echo "▸ Chaves e versões mínimas ($ALVO)"
  psql_ <<'SQL' | sed 's/^/    /'
select 'chave   ' || r.chave || ' = ' || r.ligado
  from privado.recurso r where r.chave in ('busca_profissionais', 'chamada_direta', 'perfil_rico') order by r.chave;
select 'mínimo  ' || m.recurso || ' / ' || m.plataforma || ' >= ' || m.versao_minima
  from privado.recurso_versao_minima m where m.recurso in ('busca_profissionais', 'chamada_direta', 'perfil_rico') order by m.recurso, m.plataforma;
select 'SEM mínimo para ' || x.recurso || ' no iOS: o app NÃO verá o recurso (configuracao_do_app dá false sem a linha)'
  from (values ('busca_profissionais'), ('chamada_direta')) x(recurso)
 where not exists (select 1 from privado.recurso_versao_minima m where m.recurso = x.recurso and m.plataforma = 'ios');
SQL
}

resumo() {
  echo "▸ Quem existe ($ALVO)"
  psql_ <<'SQL' | sed 's/^/    /'
select 'casa   usuario_id=' || u.id || '  estabelecimento_id=' || e.id || '  ' || u.email || '  (' || e.nome || ', ' || e.regiao_administrativa || ')'
  from public.usuario u
  join public.membro_estabelecimento m on m.usuario_id = u.id
  join public.estabelecimento e on e.id = m.estabelecimento_id
 where u.id = 'b027f000-0000-4000-8000-000000000001';
select 'prof   usuario_id=' || u.id || '  profissional_id=' || p.id || '  ' || u.email
       || E'\n         nome curto: ' || privado.nome_curto(u.nome)
       || ' · faixa: ' || case when extensions.ST_DWithin(p.ponto_base, e.ponto, 5000) then 'até 5 km'
                               when extensions.ST_DWithin(p.ponto_base, e.ponto, 15000) then '5 a 15 km' else 'mais de 15 km' end
       || ' (' || round((extensions.ST_Distance(p.ponto_base, e.ponto) / 1000)::numeric, 1) || ' km)'
       || E'\n         serviços: ' || coalesce((select string_agg(f.nome || ' [' || s.unidade || coalesce(' ' || s.valor_centavos, '') || ']', ', ' order by f.nome)
                                                  from public.profissional_servico s join public.funcao f on f.id = s.funcao_id
                                                 where s.profissional_id = p.id), '-')
       || E'\n         regiões: ' || case when p.atende_todo_df then 'todo o DF'
                                          else coalesce((select string_agg(r.nome, ' + ' order by r.id)
                                                           from public.profissional_regiao pr join public.regiao_administrativa r on r.id = pr.regiao_id
                                                          where pr.profissional_id = p.id), '-') end
       || E'\n         grade: ' || coalesce((select string_agg(d.dia_semana || ' ' || to_char(d.hora_inicio, 'HH24:MI') || '-' || to_char(d.hora_fim, 'HH24:MI'),
                                                                 ', ' order by d.dia_semana, d.hora_inicio)
                                                from public.disponibilidade d where d.profissional_id = p.id), '-') || '  (0 = domingo)'
       || E'\n         chamadas: ' || coalesce((select pc.aceita_chamadas::text from public.profissional_preferencia_chamada pc where pc.profissional_id = p.id), 'sem linha')
       || ' · pendências p/ busca: ' || privado.pendencias_para_busca(p.id)::text
       || ' · aparelho: ' || coalesce((select string_agg(d.plataforma || ' ' || d.versao_app, ', ') from public.dispositivo d where d.usuario_id = u.id), 'NENHUM')
  from public.usuario u
  join public.profissional p on p.usuario_id = u.id
  cross join public.estabelecimento e
 where e.id = 'b027f000-0000-4000-8000-0000000000c1'
   and u.id in ('b027f000-0000-4000-8000-000000000011', 'b027f000-0000-4000-8000-000000000012', 'b027f000-0000-4000-8000-000000000013')
 order by u.email;
SQL
}

# ── montar ─────────────────────────────────────────────────────────────────
montar() {
  echo "▸ montar ($ALVO)"
  checar_migracoes
  recursos
  # Uma transação só: ou fica tudo, ou não fica nada.
  psql_ -v "minimo_busca=$MINIMO_BUSCA" <<'SQL' >/dev/null
begin;
set local statement_timeout = '60s';
set local lock_timeout = '5s';

-- 0. O que precisa existir neste banco.
do $$
begin
  if to_regprocedure('public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int)') is null then
    raise exception 'buscar_profissionais não existe neste banco: a migração 20261116210000 não foi aplicada';
  end if;
  if (select count(*) from public.funcao where nome in ('garçom', 'faxina residencial', 'cozinheiro de festa') and ativo) <> 3 then
    raise exception 'faltam funções do catálogo (garçom, faxina residencial, cozinheiro de festa)';
  end if;
  if (select count(*) from public.regiao_administrativa where id in (1, 3, 10) and ativo) <> 3 then
    raise exception 'faltam regiões do catálogo (1 Plano Piloto, 3 Taguatinga, 10 Guará)';
  end if;
  if not exists (select 1 from privado.recurso_versao_minima where recurso = 'chamada_direta' and plataforma = 'ios') then
    raise exception 'chamada_direta não tem versão mínima no iOS: sem ela nenhum aparelho de teste passa na busca (decisão do O2/Forja)';
  end if;
end $$;

-- 1. As chaves, só neste banco. A versão mínima da busca só entra com --minimo-busca.
update privado.recurso set ligado = true where chave in ('busca_profissionais', 'chamada_direta');
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
select 'busca_profissionais', 'ios', :'minimo_busca' where nullif(:'minimo_busca', '') is not null
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima, atualizado_em = privado.agora();
-- Sem --minimo-busca e sem linha da busca: a mesma mínima da chamada_direta (decisão da Forja, 16/11/2026, para o
-- Prisma testar com o build atual). Quem já tem linha não é tocado.
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
select 'busca_profissionais', 'ios', m.versao_minima
  from privado.recurso_versao_minima m
 where m.recurso = 'chamada_direta' and m.plataforma = 'ios'
on conflict (recurso, plataforma) do nothing;

-- 2. As contas. O Auth precisa da linha em auth.users (e em auth.identities) para o código de e-mail entrar;
--    public.usuario não tem chave para auth.users, então as duas são criadas aqui.
create temp table _contas on commit drop as
select * from (values
  ('b027f000-0000-4000-8000-000000000001'::uuid, 'contratante'::public.perfil_conta, 'Carla Casa Teste',         'busca-casa@frila.test',   '+5561990000001'),
  ('b027f000-0000-4000-8000-000000000011'::uuid, 'profissional'::public.perfil_conta, 'Ana Faxineira Teste',     'busca-prof-1@frila.test', '+5561990000011'),
  ('b027f000-0000-4000-8000-000000000012'::uuid, 'profissional'::public.perfil_conta, 'Bruno Garçom Teste',      'busca-prof-2@frila.test', '+5561990000012'),
  ('b027f000-0000-4000-8000-000000000013'::uuid, 'profissional'::public.perfil_conta, 'Clara Cozinheira Teste',  'busca-prof-3@frila.test', '+5561990000013')
) v(id, perfil, nome, email, telefone);

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, is_sso_user, is_anonymous,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000', c.id, 'authenticated', 'authenticated', c.email, now(),
       '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(), false, false, '', '', '', ''
  from _contas c
 where not exists (select 1 from auth.users x where x.id = c.id);

insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select c.id::text, c.id,
       jsonb_build_object('sub', c.id::text, 'email', c.email, 'email_verified', true, 'phone_verified', false),
       'email', now(), now(), now()
  from _contas c
 where not exists (select 1 from auth.identities i where i.user_id = c.id and i.provider = 'email');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select c.id, c.perfil, c.nome, c.telefone, c.email, date '1990-01-01', '1.0', now() from _contas c
on conflict (id) do update set nome = excluded.nome, estado = 'ativa', anonimizado_em = null;

-- 3. A casa: Plano Piloto, perto do ponto base do prof 1. CNPJ sintético (14 dígitos, sem dígito verificador).
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('b027f000-0000-4000-8000-0000000000c1', 'Casa Teste Busca', '99027000000100', 'outro',
        'CLN 201 Bloco A, Asa Norte (endereço de teste)', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto')
on conflict (id) do update set nome = excluded.nome, ponto = excluded.ponto, regiao_administrativa = excluded.regiao_administrativa;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('b027f000-0000-4000-8000-000000000001', 'b027f000-0000-4000-8000-0000000000c1', 'administrador')
on conflict (usuario_id, estabelecimento_id) do update set papel = 'administrador';

-- 4. Os três profissionais. Ponto base em faixas diferentes da casa (medidas no `estado`):
--    prof 1 a ~1,6 km (até 5 km) · prof 2 a ~10 km (5 a 15 km) · prof 3 a ~23 km (mais de 15 km).
insert into public.profissional (id, usuario_id, ponto_base, atende_todo_df) values
  ('b027f000-0000-4000-8000-000000000021', 'b027f000-0000-4000-8000-000000000011', 'POINT(-47.8822 -15.7800)'::extensions.geography, true),
  ('b027f000-0000-4000-8000-000000000022', 'b027f000-0000-4000-8000-000000000012', 'POINT(-47.9400 -15.8700)'::extensions.geography, false),
  ('b027f000-0000-4000-8000-000000000023', 'b027f000-0000-4000-8000-000000000013', 'POINT(-48.0800 -15.8700)'::extensions.geography, false)
on conflict (id) do update set ponto_base = excluded.ponto_base, atende_todo_df = excluded.atende_todo_df;

create temp table _servicos on commit drop as
select * from (values
  ('b027f000-0000-4000-8000-000000000021'::uuid, 'faxina residencial',  'diaria',     15000, 8,    null::int, null::int, null::int, null::int),
  ('b027f000-0000-4000-8000-000000000022'::uuid, 'garçom',              'hora',        4000, null, 4,         null,      null,      null),
  ('b027f000-0000-4000-8000-000000000022'::uuid, 'cozinheiro de festa', 'evento',     60000, null, null,      5,         50,        null),
  ('b027f000-0000-4000-8000-000000000023'::uuid, 'cozinheiro de festa', 'por_pessoa',  3500, null, null,      null,      null,      20),
  ('b027f000-0000-4000-8000-000000000023'::uuid, 'garçom',              'a_combinar', null,  null, null,      null,      null,      null)
) v(prof, funcao, unidade, valor, horas_incl, min_horas, duracao_h, ate_pessoas, min_pessoas);

insert into public.profissional_funcao (profissional_id, funcao_id)
select s.prof, f.id from _servicos s join public.funcao f on f.nome = s.funcao and f.ativo
on conflict do nothing;

delete from public.profissional_servico
 where profissional_id in ('b027f000-0000-4000-8000-000000000021', 'b027f000-0000-4000-8000-000000000022', 'b027f000-0000-4000-8000-000000000023');
insert into public.profissional_servico (profissional_id, funcao_id, unidade, valor_centavos, horas_incluidas, minimo_horas,
                                         duracao_tipica_h, ate_pessoas, minimo_pessoas, leva_material)
select s.prof, f.id, s.unidade, s.valor, s.horas_incl, s.min_horas, s.duracao_h, s.ate_pessoas, s.min_pessoas,
       case when s.unidade = 'diaria' then 'depende' end
  from _servicos s join public.funcao f on f.nome = s.funcao and f.ativo;

-- Regiões: prof 1 atende todo o DF (sem linha em profissional_regiao); prof 2 duas RAs; prof 3 uma só.
delete from public.profissional_regiao
 where profissional_id in ('b027f000-0000-4000-8000-000000000021', 'b027f000-0000-4000-8000-000000000022', 'b027f000-0000-4000-8000-000000000023');
insert into public.profissional_regiao (profissional_id, regiao_id) values
  ('b027f000-0000-4000-8000-000000000022', 1), ('b027f000-0000-4000-8000-000000000022', 10),
  ('b027f000-0000-4000-8000-000000000023', 1);

-- Grade semanal (0 = domingo). Prof 2 vira a noite (18h às 02h): é a janela mais comum do setor.
delete from public.disponibilidade
 where profissional_id in ('b027f000-0000-4000-8000-000000000021', 'b027f000-0000-4000-8000-000000000022', 'b027f000-0000-4000-8000-000000000023');
insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
select 'b027f000-0000-4000-8000-000000000021', d, time '08:00', time '18:00' from generate_series(1, 5) d
union all
select 'b027f000-0000-4000-8000-000000000022', d, time '18:00', time '02:00' from unnest(array[4, 5, 6, 0]) d
union all
select 'b027f000-0000-4000-8000-000000000023', d, time '10:00', time '22:00' from unnest(array[6, 0]) d;

-- 5. O aparelho iOS na versão mínima da chamada_direta. Token falso de propósito (ver o cabeçalho do script).
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select v.usuario, 'tok-busca-teste-b027-' || v.n || '-0000000000', 'ios',
       (select m.versao_minima from privado.recurso_versao_minima m where m.recurso = 'chamada_direta' and m.plataforma = 'ios')
  from (values ('b027f000-0000-4000-8000-000000000011'::uuid, 'p1'),
               ('b027f000-0000-4000-8000-000000000012'::uuid, 'p2'),
               ('b027f000-0000-4000-8000-000000000013'::uuid, 'p3')) v(usuario, n)
on conflict (token_fcm) do update set usuario_id = excluded.usuario_id, versao_app = excluded.versao_app, atualizado_em = now();

-- 6. "Aceito chamadas diretas", pela RPC, como o próprio profissional (grava também o registro do pedido do
--    titular). Só para quem ainda não ligou, para rodar de novo não empilhar registro.
do $$
declare r record;
begin
  for r in select p.usuario_id from public.profissional p
            where p.id in ('b027f000-0000-4000-8000-000000000021', 'b027f000-0000-4000-8000-000000000022', 'b027f000-0000-4000-8000-000000000023')
              and not coalesce((select pc.aceita_chamadas from public.profissional_preferencia_chamada pc where pc.profissional_id = p.id), false)
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.usuario_id, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.definir_preferencia_chamadas(aceita_chamadas => true, versao_texto_busca => 'teste-b027');
    execute 'reset role';
  end loop;
end $$;

commit;
SQL
  ok "contas, casa, profissionais, grade, aparelhos e preferência gravados"
  recursos
  resumo
}

# ── conferir: a busca como a casa, numa transação desfeita ─────────────────
conferir() {
  echo "▸ conferir ($ALVO): 4 buscas como a casa de teste (transação desfeita; o contador do limite não fica)"
  local linha sab_ini sab_fim seg_ini seg_fim f_garcom f_faxina
  # Horários futuros em America/Sao_Paulo, com folga de 2 dias (a antecedência padrão é 6 h): o próximo sábado
  # 11h-15h (a grade do prof 3 cobre, a do prof 2 não) e a próxima segunda 09h-13h (a grade do prof 1 cobre).
  linha=$(psql_ <<'SQL'
with sp as (select (privado.agora() at time zone 'America/Sao_Paulo')::date + 2 as d),
     dias as (select d + ((6 - extract(dow from d)::int + 7) % 7) as sab, d + ((1 - extract(dow from d)::int + 7) % 7) as seg from sp)
select to_char(((sab + time '11:00') at time zone 'America/Sao_Paulo') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
       to_char(((sab + time '15:00') at time zone 'America/Sao_Paulo') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
       to_char(((seg + time '09:00') at time zone 'America/Sao_Paulo') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
       to_char(((seg + time '13:00') at time zone 'America/Sao_Paulo') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
       (select id from public.funcao where nome = 'garçom' and ativo),
       (select id from public.funcao where nome = 'faxina residencial' and ativo)
  from dias;
SQL
  )
  IFS='|' read -r sab_ini sab_fim seg_ini seg_fim f_garcom f_faxina <<< "$linha"
  [ -n "$f_faxina" ] || falhou "não consegui montar os horários e as funções da conferência"
  echo "    sábado $sab_ini a $sab_fim · segunda $seg_ini a $seg_fim (UTC)"

  local saida
  saida=$(psql_ -v "casa=$CASA_USUARIO" -v "estab=$CASA_ESTAB" -v "sab_ini=$sab_ini" -v "sab_fim=$sab_fim" \
                -v "seg_ini=$seg_ini" -v "seg_fim=$seg_fim" -v "f_garcom=$f_garcom" -v "f_faxina=$f_faxina" <<'SQL'
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'casa', 'role', 'authenticated')::text, true) \gset
set local role authenticated;
with b(k, r) as (values
  ('B1', public.buscar_profissionais(estabelecimento_id => :'estab'::uuid, funcao_id => :'f_garcom'::uuid)),
  ('B2', public.buscar_profissionais(estabelecimento_id => :'estab'::uuid, funcao_id => :'f_garcom'::uuid,
                                     inicio_em => :'sab_ini'::timestamptz, fim_em => :'sab_fim'::timestamptz)),
  ('B3', public.buscar_profissionais(estabelecimento_id => :'estab'::uuid, funcao_id => :'f_faxina'::uuid, regiao_id => 3,
                                     inicio_em => :'seg_ini'::timestamptz, fim_em => :'seg_fim'::timestamptz)),
  ('B4', public.buscar_profissionais(estabelecimento_id => :'estab'::uuid, funcao_id => :'f_garcom'::uuid, regiao_id => 10)))
select b.k || '|' || coalesce(string_agg(i.item->>'nome' || ' (' || (i.item->>'distancia_faixa')
         || coalesce(case i.item->>'disponivel_no_horario' when 'true' then ', na grade' when 'false' then ', fora da grade' end, '')
         || ')', ' > ' order by i.ord), '(ninguém)')
  from b left join lateral jsonb_array_elements(b.r->'itens') with ordinality i(item, ord) on true
 group by b.k order by b.k;
rollback;
SQL
  )
  local falhas=0 k obtido esperado desc
  while IFS='|' read -r k obtido; do
    case "$k" in
      B1) esperado="Bruno T. (de_5_a_15_km) > Clara T. (mais_de_15_km)";                                  desc="garçom, Plano Piloto, sem horário" ;;
      B2) esperado="Clara T. (mais_de_15_km, na grade) > Bruno T. (de_5_a_15_km, fora da grade)";       desc="garçom, Plano Piloto, sábado 11h-15h" ;;
      B3) esperado="Ana T. (ate_5_km, na grade)";                                                          desc="faxina residencial, Taguatinga, segunda 09h-13h" ;;
      B4) esperado="Bruno T. (de_5_a_15_km)";                                                              desc="garçom, Guará, sem horário" ;;
      *) continue ;;
    esac
    if [ "$obtido" = "$esperado" ]; then ok "$k  $desc → $obtido"
    else printf '  ✗ %s  %s\n      esperado: %s\n      obtido:   %s\n' "$k" "$desc" "$esperado" "$obtido" >&2; falhas=$((falhas + 1)); fi
  done <<< "$saida"
  [ "$(printf '%s\n' "$saida" | grep -c '^B[1-4]|')" = 4 ] || { aviso "a conferência não devolveu as 4 linhas (saída: $(printf '%s' "$saida" | head -c 300))"; falhas=$((falhas + 1)); }
  [ "$falhas" = 0 ] || falhou "a conferência divergiu em $falhas ponto(s). Se apareceu gente a mais, há conta de outra origem com 'aceita chamadas' ligado neste banco; se faltou gente, rode montar (o aparelho de teste pode ter sido apagado por um push)."
  ok "as 4 buscas deram o resultado esperado"
}

# ── Chaves do Auth (só para codigo e http; nunca impressas) ────────────────
API_URL=""; ANON_KEY=""; SR_KEY=""
carregar_chaves() {
  if [ "$ALVO" = local ]; then
    local env_
    env_=$(supabase status -o env ${SUPABASE_WORKDIR:+--workdir "$SUPABASE_WORKDIR"} 2>/dev/null) \
      || falhou "o supabase status não respondeu (stack parada? defina SUPABASE_WORKDIR para a pasta do stack)"
    API_URL=$(printf '%s\n' "$env_" | sed -nE 's/^API_URL="?([^"]*)"?$/\1/p' | head -1)
    ANON_KEY=$(printf '%s\n' "$env_" | sed -nE 's/^(ANON_KEY|PUBLISHABLE_KEY)="?([^"]*)"?$/\2/p' | head -1)
    SR_KEY=$(printf '%s\n' "$env_" | sed -nE 's/^(SERVICE_ROLE_KEY|SECRET_KEY)="?([^"]*)"?$/\2/p' | head -1)
  else
    # O projeto sai da própria conexão do dev (nunca de uma variável solta, para não apontar sem querer ao Prod);
    # as chaves, da Management API, com o token de conta do dev.
    local ref token chaves
    ref=$(printf '%s' "$PGURL" | sed -nE 's#.*postgres\.([a-z0-9]{20}).*#\1#p; s#.*@db\.([a-z0-9]{20})\.supabase\.co.*#\1#p' | head -1)
    [ -n "$ref" ] || falhou "não consegui descobrir o projeto a partir de ~/.config/frila/dev-db-url"
    [ -f "$HOME/.config/frila/supabase-token" ] || falhou "não achei ~/.config/frila/supabase-token"
    token="$(tr -d '\n' < "$HOME/.config/frila/supabase-token" | sed 's/^[A-Za-z_]*=//')"
    chaves=$(curl -sS -K - <<EOF
url = "https://api.supabase.com/v1/projects/$ref/api-keys"
header = "Authorization: Bearer $token"
EOF
    ) || falhou "a Management API não respondeu"
    API_URL="https://$ref.supabase.co"
    ANON_KEY=$(printf '%s' "$chaves" | python3 -I -c 'import json,sys
try: print(next((k["api_key"] for k in json.load(sys.stdin) if k.get("name") == "anon"), ""))
except Exception: print("")')
    SR_KEY=$(printf '%s' "$chaves" | python3 -I -c 'import json,sys
try: print(next((k["api_key"] for k in json.load(sys.stdin) if k.get("name") == "service_role"), ""))
except Exception: print("")')
  fi
  [ -n "$API_URL" ] && [ -n "$ANON_KEY" ] && [ -n "$SR_KEY" ] || falhou "não consegui as chaves do Auth de $ALVO (nenhuma é impressa)"
}

# api <método> <caminho> <apikey> <bearer> [corpo-json]  (a chave vai por stdin, não por argumento)
api() {
  curl -sS -X "$1" -K - ${5:+-d "$5"} <<EOF
url = "$API_URL$2"
header = "apikey: $3"
header = "Authorization: Bearer $4"
header = "Content-Type: application/json"
EOF
}

json_campo() { python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get(sys.argv[1]) or "")
except Exception: print("")' "$1"; }

so_email_de_teste() {
  local e achou=0
  for e in $EMAILS_DE_TESTE; do [ "$e" = "$1" ] && achou=1; done
  [ "$achou" = 1 ] || falhou "só gero código para os e-mails de teste: $EMAILS_DE_TESTE"
  [ "$(psql_ -c "select count(*) from auth.users u join public.usuario p on p.id = u.id where lower(u.email) = '$1' and not p.demonstracao;")" = 1 ] \
    || falhou "a conta $1 não existe neste banco: rode montar antes (o código nunca cria conta)"
}

# O código de uma vez só (a mesma chamada de e-mail+código do app). Sai em stdout, para quem o pediu.
gerar_codigo() {
  api POST /auth/v1/admin/generate_link "$SR_KEY" "$SR_KEY" "{\"type\":\"magiclink\",\"email\":\"$1\"}" | json_campo email_otp
}

codigo() {
  local email="${1:-}"
  [ -n "$email" ] || falhou "uso: codigo <e-mail de teste>"
  so_email_de_teste "$email"
  carregar_chaves
  local otp
  otp=$(gerar_codigo "$email")
  [ -n "$otp" ] || falhou "o Auth não devolveu código para $email"
  echo "Código de entrada de $email ($ALVO): $otp"
  echo "Vale uma vez e por até 1 hora. Digite na tela agora; não guarde em arquivo. Se pedir código de novo no app, peça outro aqui."
}

# Entra pelo Auth como cada conta (verify, como o app) e busca pelo REST como a casa: o caminho do Prisma, sem tela.
# Cada login gasta um código novo (invalida o que o Prisma tiver pedido): rode antes de passar o código a ele.
http() {
  echo "▸ http ($ALVO): login pelo Auth das 4 contas e a busca pelo REST como a casa"
  carregar_chaves
  local e otp resp acesso quem tipo casa_token=""
  for e in $EMAILS_DE_TESTE; do
    so_email_de_teste "$e"
    otp=$(gerar_codigo "$e"); [ -n "$otp" ] || falhou "sem código para $e"
    acesso=""
    for tipo in email magiclink; do
      resp=$(api POST /auth/v1/verify "$ANON_KEY" "$ANON_KEY" "{\"type\":\"$tipo\",\"email\":\"$e\",\"token\":\"$otp\"}")
      acesso=$(printf '%s' "$resp" | json_campo access_token)
      [ -n "$acesso" ] && break
      otp=$(gerar_codigo "$e")
    done
    [ -n "$acesso" ] || falhou "o verify não entregou sessão para $e"
    quem=$(api GET /auth/v1/user "$ANON_KEY" "$acesso" | json_campo email)
    [ "$quem" = "$e" ] || falhou "a sessão de $e não é de $e"
    ok "$e entrou (verify type=$tipo) e /auth/v1/user confere"
    [ "$e" = busca-casa@frila.test ] && casa_token="$acesso"
  done
  local f_garcom resp_busca
  f_garcom=$(psql_ -c "select id from public.funcao where nome = 'garçom' and ativo;")
  resp_busca=$(api POST /rest/v1/rpc/buscar_profissionais "$ANON_KEY" "$casa_token" "{\"estabelecimento_id\":\"$CASA_ESTAB\",\"funcao_id\":\"$f_garcom\"}")
  printf '%s' "$resp_busca" | python3 -I -c 'import json,sys
d = json.load(sys.stdin)
if "itens" not in d: sys.exit("a busca pelo REST não devolveu itens: " + str(d.get("code") or d.get("message") or d)[:200])
print("    garçom no Plano Piloto pelo REST:", " > ".join(i["nome"] + " (" + i["distancia_faixa"] + ")" for i in d["itens"]) or "(ninguém)")' \
    || falhou "a busca pelo REST falhou"
  ok "casa entrou e buscou pelo REST"
}

case "$COMANDO" in
  montar)   montar ;;
  conferir) checar_migracoes; conferir ;;
  http)     checar_migracoes; http ;;
  codigo)   codigo "$ARG1" ;;
  estado)   checar_migracoes; recursos; resumo ;;
esac
