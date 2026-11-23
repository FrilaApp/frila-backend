-- O estado do check-in por código e a chave por estabelecimento (contrato 0.2.68; PR2 do plano).
-- Desenho: frila-docs, arquitetura/desenho-checkin-por-codigo-v1.2.md, seções 4 e 8. O DDL de
-- referência e as regras de LGPD estão na Modelagem, frila-docs #198, "Check-in por código".
--
-- Só `privado`: nenhuma função de `public` muda, e nenhuma resposta da API ganha campo. As
-- RPCs que usam estas tabelas vêm depois: fazer_checkin com sinais (PR4),
-- gerar_codigo_checkin (PR5) e validar_codigo_checkin (PR6). A guarda de 90 dias, a limpeza
-- do valor vencido e a anonimização vêm no PR3.
--
-- O que nunca entra aqui (regras da Bússola, 08/11): coordenada, a distância da leitura em
-- metros, os sinais do aparelho, o motivo da recusa e quem da casa gerou o código.

select set_config('lock_timeout', '2s', true);

-- ── 1. A chave, global e por estabelecimento (RN46; leitura 6 do desenho) ─────
-- O piloto liga o código só nas casas de teste, e privado.recurso é global. O recurso vale
-- para um turno quando a chave global está ligada E a casa do turno está na lista. Fechado
-- por padrão: sem a linha, desligado. Casa de pessoa jurídica (não MEI) ou casa de teste da equipe
-- entra por migração. Casa de pessoa física ou MEI, não: o insert em recurso_estabelecimento é feito
-- no Prod por quem opera (service_role), e o registro de quem ligou, quando e qual casa fica fora do
-- repositório (LGPD, art. 6º, III; AGENTS.md: "Nunca: commitar ... dado pessoal real"; Bússola, 08/11).

insert into privado.recurso (chave, ligado) values ('checkin_por_codigo', false)
  on conflict (chave) do nothing;

create table privado.recurso_estabelecimento (
  chave              text not null references privado.recurso(chave),
  estabelecimento_id uuid not null references public.estabelecimento(id) on delete cascade,
  primary key (chave, estabelecimento_id)
);
alter table privado.recurso_estabelecimento enable row level security;
revoke all on table privado.recurso_estabelecimento from public, anon, authenticated;
comment on table privado.recurso_estabelecimento is
  'Estabelecimentos em que uma chave de privado.recurso vale (RN46). Hoje só o check-in por código lê esta lista; as outras chaves seguem globais. Guarda só a chave e o estabelecimento. Para casa de pessoa física ou MEI, é dado do contratante, com a finalidade de ligar o piloto.';
comment on column privado.recurso_estabelecimento.chave is
  'A chave de privado.recurso que vale para a casa.';
comment on column privado.recurso_estabelecimento.estabelecimento_id is
  'A casa em que a chave vale. Sai com o estabelecimento, em cascata.';

create function privado.recurso_ligado_para(p_chave text, p_estabelecimento uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select privado.recurso_ligado(p_chave)
     and exists (select 1 from privado.recurso_estabelecimento r
                  where r.chave = p_chave and r.estabelecimento_id = p_estabelecimento)
$$;
comment on function privado.recurso_ligado_para(text, uuid) is
  'Se a chave vale para o estabelecimento: ligada em privado.recurso e a casa em privado.recurso_estabelecimento. Sem uma das duas, desligada (RN46).';
revoke all on function privado.recurso_ligado_para(text, uuid) from public, anon, authenticated;
grant execute on function privado.recurso_ligado_para(text, uuid) to service_role;

-- VOLATILE, e não STABLE: chama public.erro, que é volátil, e o lint da CI acusa a
-- função estável que chama uma volátil (#455).
create function privado.exigir_recurso_para(p_chave text, p_estabelecimento uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not privado.recurso_ligado_para(p_chave, p_estabelecimento) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
end $$;
comment on function privado.exigir_recurso_para(text, uuid) is
  'Recusa com 403 sem_permissao (recurso_desligado) quando a chave não vale para o estabelecimento (RN46). Chamada antes de qualquer escrita.';
revoke all on function privado.exigir_recurso_para(text, uuid) from public, anon, authenticated;
grant execute on function privado.exigir_recurso_para(text, uuid) to service_role;

-- ── 2. Os números ajustáveis, numa linha só ───────────────────────────────────
-- As 3 tentativas erradas por bloqueio, os 2 bloqueios até fechar e a faixa suspeita de 150
-- a 200 m são decisões fechadas do texto aprovado e ficam no código.

create table privado.regra_checkin_codigo (
  unica            boolean primary key default true
                   constraint regra_uma_linha check (unica),
  validade_s       integer not null default 300
                   constraint validade_de_2_a_5_min check (validade_s between 120 and 300),
  bloqueio_s       integer not null default 300
                   constraint bloqueio_de_2_a_5_min check (bloqueio_s between 120 and 300),
  raio_validacao_m integer not null default 100
                   constraint raio_ate_100_m check (raio_validacao_m between 1 and 100),
  precisao_ruim_m  integer not null default 100
                   constraint precisao_ruim_positiva check (precisao_ruim_m > 0)
);
insert into privado.regra_checkin_codigo default values;
alter table privado.regra_checkin_codigo enable row level security;
revoke all on table privado.regra_checkin_codigo from public, anon, authenticated;
comment on table privado.regra_checkin_codigo is
  'Os números ajustáveis do check-in por código (decisão do JP, 08/11), numa linha só. Mudar é uma migração. Não guarda dado pessoal.';
comment on column privado.regra_checkin_codigo.validade_s is
  'Quanto vale um código gerado, em segundos. Faixa aprovada de 2 a 5 minutos; inicial 5.';
comment on column privado.regra_checkin_codigo.bloqueio_s is
  'Quanto dura o bloqueio da leitura depois da 3ª tentativa errada, em segundos. Faixa aprovada de 2 a 5 minutos; inicial 5.';
comment on column privado.regra_checkin_codigo.raio_validacao_m is
  'Distância máxima, sobre a distância medida e sem desconto pela imprecisão, para o código valer. No máximo 100 m (decisão do JP).';
comment on column privado.regra_checkin_codigo.precisao_ruim_m is
  'Imprecisão informada pelo aparelho a partir da qual a precisão é ruim, um dos sinais suspeitos (resposta do JP à leitura 5: 100 m, ajustável no piloto). PENDENTE do JP (D5): se precisao_m nulo conta como ruim; quem decide o nulo é o fazer_checkin (PR4), não esta coluna.';

-- ── 3. O caminho do código num turno ──────────────────────────────────────────

create table privado.checkin_codigo (
  turno_id        uuid primary key references public.turno(id) on delete cascade,
  codigo          text,
  gerado_em       timestamptz,
  expira_em       timestamptz,
  codigo_exigido  boolean not null default false,
  confianca_baixa boolean not null default false,
  erros           integer not null default 0,
  bloqueado_ate   timestamptz,
  encerrado_em    timestamptz,
  constraint codigo_seis_digitos check (codigo ~ '^[0-9]{6}$'),
  -- A validade nunca é nula e nunca passa do teto da regra (5 min); sem o `is not null`, o CHECK
  -- daria nulo e passaria (B1 do Lince no #458).
  constraint codigo_com_validade check (
    codigo is null or (gerado_em is not null and expira_em is not null
                       and expira_em > gerado_em and expira_em <= gerado_em + interval '300 seconds')),
  constraint erros_no_teto check (erros between 0 and 6),
  -- De mão dupla: a 6ª errada encerra, e só ela. Quem escreve grava as duas colunas no mesmo update.
  constraint encerrado_no_teto check ((erros = 6) = (encerrado_em is not null))
);
alter table privado.checkin_codigo enable row level security;
revoke all on table privado.checkin_codigo from public, anon, authenticated;
comment on table privado.checkin_codigo is
  'O check-in por código num turno (0.2.68): o código em vigor, o contador de tentativas erradas, o bloqueio, e duas marcas para a medição do piloto. Nasce no primeiro uso do caminho e sai 90 dias depois do mais tarde entre o fim do turno e o fim da contestação (LGPD, PR3). Não guarda quem gerou o código.';
comment on column privado.checkin_codigo.codigo is
  'Os 6 dígitos que a casa mostra. Vale só durante a validade (a validação confere expira_em) e sai do banco ao validar, ao gerar outro ou em até 1 minuto depois de vencer. Nunca sai em erro, log, aviso, resposta de terceiros, telemetria nem exportação. Essa garantia é das RPCs, e não do banco: o detalhe de um CHECK que falha nesta linha (Failing row contains) traz o código, e por isso gerar_codigo_checkin e validar_codigo_checkin capturam o check_violation e respondem sem o detalhe.';
comment on column privado.checkin_codigo.turno_id is
  'O turno do caminho do código. Apagar o turno apaga o estado e as tentativas, em cascata.';
comment on column privado.checkin_codigo.gerado_em is
  'Quando a casa gerou o código em vigor. Vai para a tentativa como codigo_gerado_em, para medir o tempo entre gerar e ler.';
comment on column privado.checkin_codigo.expira_em is
  'Até quando o código vale, pelo relógio do servidor.';
comment on column privado.checkin_codigo.codigo_exigido is
  'O servidor pediu a casa por sinal suspeito no check-in. Não diz qual sinal; os sinais do aparelho não são gravados. Sai na exportação do profissional (MeusDados).';
comment on column privado.checkin_codigo.confianca_baixa is
  'O código foi validado sem posição. Até uma decisão registrada, só alimenta a medição do piloto: não entra em taxa, avaliação, ordenação, despacho nem suspensão. Não sai nas respostas operacionais; só na exportação do profissional.';
comment on column privado.checkin_codigo.erros is
  'Tentativas erradas no turno, de 0 a 6. Código novo não zera. A 3ª bloqueia a leitura; a 6ª, o segundo bloqueio, fecha o caminho do código.';
comment on column privado.checkin_codigo.bloqueado_ate is
  'Até quando a leitura está bloqueada depois da 3ª tentativa errada. As leituras nesse intervalo não contam.';
comment on column privado.checkin_codigo.encerrado_em is
  'Quando a 6ª tentativa errada fechou o caminho do código para o turno. Daí em diante, vale a confirmação manual.';

-- ── 4. As tentativas ──────────────────────────────────────────────────────────

create table privado.checkin_codigo_tentativa (
  id               bigint generated always as identity primary key,
  turno_id         uuid not null references privado.checkin_codigo(turno_id) on delete cascade,
  em               timestamptz not null,
  resultado        text not null
                   constraint tentativa_resultado check (resultado in ('aceita', 'recusada')),
  faixa            text not null
                   constraint tentativa_faixa check (faixa in ('ate_100_m', 'acima_de_100_m', 'sem_posicao')),
  codigo_gerado_em timestamptz,
  constraint aceita_com_codigo_e_perto check (
    resultado = 'recusada' or (codigo_gerado_em is not null and faixa <> 'acima_de_100_m'))
);
create index checkin_codigo_tentativa_turno on privado.checkin_codigo_tentativa (turno_id, em);
alter table privado.checkin_codigo_tentativa enable row level security;
revoke all on table privado.checkin_codigo_tentativa from public, anon, authenticated;
comment on table privado.checkin_codigo_tentativa is
  'Cada leitura do código que contou como tentativa: a hora, o resultado e a faixa da distância. Não guarda os metros, a coordenada, o motivo da recusa, os sinais nem quem gerou o código (regras da Bússola, 08/11). Sai com a linha de privado.checkin_codigo, em cascata. Sai na exportação do profissional.';
comment on column privado.checkin_codigo_tentativa.em is
  'Hora da leitura, pelo relógio do servidor. Com codigo_gerado_em, mede o tempo entre gerar e ler.';
comment on column privado.checkin_codigo_tentativa.resultado is
  'aceita ou recusada, sem o motivo.';
comment on column privado.checkin_codigo_tentativa.faixa is
  'A faixa da distância medida na leitura, nunca os metros: até 100 m, acima de 100 m ou sem posição.';
comment on column privado.checkin_codigo_tentativa.codigo_gerado_em is
  'Quando foi gerado o código em vigor no momento da leitura. Nulo se não havia código em vigor.';

-- ── 5. O contador e as leituras do estado ─────────────────────────────────────

create function privado.faixa_da_leitura(p_distancia_m integer) returns text
language sql immutable set search_path = '' as $$
  select case when p_distancia_m is null then 'sem_posicao'
              when p_distancia_m <= 100 then 'ate_100_m'
              else 'acima_de_100_m' end
$$;
comment on function privado.faixa_da_leitura(integer) is
  'A faixa da distância de uma leitura do código (MeusDados.checkins_por_codigo): ate_100_m, acima_de_100_m ou sem_posicao. Os metros não são gravados.';
revoke all on function privado.faixa_da_leitura(integer) from public, anon, authenticated;
grant execute on function privado.faixa_da_leitura(integer) to service_role;

create function privado.estado_do_codigo(p_turno uuid) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select case when c.encerrado_em is not null then 'encerrado'
                when c.bloqueado_ate > privado.agora() then 'temporario'
                else 'aberto' end
      from privado.checkin_codigo c where c.turno_id = p_turno), 'aberto')
$$;
comment on function privado.estado_do_codigo(uuid) is
  'O caminho do código no turno: aberto, temporario (bloqueio depois da 3ª errada) ou encerrado (depois da 6ª). Turno sem linha está aberto.';
revoke all on function privado.estado_do_codigo(uuid) from public, anon, authenticated;
grant execute on function privado.estado_do_codigo(uuid) to service_role;

-- Conta uma tentativa errada e devolve o que a leitura responde: invalido (422
-- codigo_invalido), temporario (409 codigo_bloqueado, a 3ª) ou encerrado (409, a 6ª). Durante
-- o bloqueio e depois de encerrado, não conta e devolve o estado. A 6ª grava erros e
-- encerrado_em no mesmo update, como o CHECK encerrado_no_teto exige.
create function privado.registrar_erro_codigo(p_turno uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  c_erros_por_bloqueio constant integer := 3;   -- decisão do JP (08/11)
  c_bloqueios          constant integer := 2;   -- o 2º bloqueio fecha o caminho
  v_teto  integer := c_erros_por_bloqueio * c_bloqueios;
  v_agora timestamptz := privado.agora();
  v_c     privado.checkin_codigo;
begin
  insert into privado.checkin_codigo (turno_id) values (p_turno) on conflict (turno_id) do nothing;
  select * into v_c from privado.checkin_codigo c where c.turno_id = p_turno for update;

  if v_c.encerrado_em is not null then return 'encerrado'; end if;
  if v_c.bloqueado_ate > v_agora then return 'temporario'; end if;

  update privado.checkin_codigo c
     set erros         = c.erros + 1,
         bloqueado_ate = case when c.erros + 1 = c_erros_por_bloqueio
                              -- Sem a linha da regra, vale o padrão de 5 min: o bloqueio nunca some.
                              then v_agora + make_interval(secs => coalesce((select r.bloqueio_s
                                                                               from privado.regra_checkin_codigo r), 300))
                              else c.bloqueado_ate end,
         encerrado_em  = case when c.erros + 1 = v_teto then v_agora end
   where c.turno_id = p_turno
  returning * into v_c;

  return case when v_c.encerrado_em is not null then 'encerrado'
              when v_c.erros = c_erros_por_bloqueio then 'temporario'
              else 'invalido' end;
end $$;
comment on function privado.registrar_erro_codigo(uuid) is
  'Conta uma tentativa errada do código no turno e devolve invalido, temporario (a 3ª, que bloqueia por regra_checkin_codigo.bloqueio_s) ou encerrado (a 6ª, que fecha o caminho). No bloqueio e depois de encerrado, não conta. Código novo não zera o contador.';
revoke all on function privado.registrar_erro_codigo(uuid) from public, anon, authenticated;
grant execute on function privado.registrar_erro_codigo(uuid) to service_role;
