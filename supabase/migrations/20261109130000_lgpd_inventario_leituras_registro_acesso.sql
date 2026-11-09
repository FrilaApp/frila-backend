-- Migração: 20261109130000_lgpd_inventario_leituras_registro_acesso.sql
-- Escopo: B-T2c, filho do LGPD-J6 R11 (cartão HAWhzOJ4). Inventário das leituras do registro de acessos
-- (Decreto 8.771/2016, art. 13, III): o momento, a duração, a identidade do funcionário ou do responsável
-- designado e o "arquivo acessado" (texto literal do decreto, conferido pela Bússola no Planalto em 08/11/2026).
-- Desenho: ADR-002, seção "Leitura do registro" (frila-documentacao #205). Brief: orquestracao/briefs/B-T2c-*.md.
--
-- O que muda:
--   · nenhum papel de API (anon, authenticated, service_role) toca direto em privado.registro_acesso nem em
--     privado.registro_acesso_recente. O service_role tinha SELECT, INSERT e DELETE desde a 20261108030000; quem
--     grava e apaga são funções security definer (o consumidor e a limpeza), que não dependem desses grants;
--   · a leitura passa só por privado.ler_registros_acesso(conta, desde, ate, responsável, motivo), que devolve as
--     linhas da conta no período e grava 1 linha em privado.registro_acesso_leitura, mesmo quando volta vazia;
--   · quem pode chamar (art. 13, I): só o service_role, além do dono (postgres). Para o postgres a regra é de
--     processo: lê só pela função, e leitura direta vira ocorrência anotada (ADR-002);
--   · como a pessoa é identificada (art. 13, II): pelo responsável declarado em cada leitura (o login individual
--     de quem lê, nunca a conta técnica), guardado junto com os papéis técnicos da sessão.
-- Prazo de guarda do inventário (Bússola, 08/11/2026): 5 anos contados do fim de cada leitura, sem FK para a conta
-- lida. Base: LGPD art. 7º, II e art. 16, I (o inventário cumpre o Decreto 8.771, art. 13, III) e art. 6º, X
-- (prestação de contas). O decreto não fixa prazo: os 5 anos são inferência do time, o mesmo prazo do turno.
-- A limpeza é privado.limpar_inventario_leituras_registro_acesso. Ela não entra aqui em
-- privado.executar_retencao_diaria, porque o #459 (20261109102000) reescreve essa rotina: a chamada entra depois
-- dele, numa linha (a primeira linha só vence em 2031).

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Ninguém da API lê nem escreve direto no registro
-- ─────────────────────────────────────────────────────────────────────────────
revoke all on table privado.registro_acesso from public, anon, authenticated, service_role;
revoke all on table privado.registro_acesso_recente from public, anon, authenticated, service_role;

comment on table privado.registro_acesso is
  'Registros de acesso a aplicação de internet (Marco Civil, Lei 12.965/2014, art. 5º VIII e art. 15): conta, IP da borda (cf-connecting-ip) e data e hora do 1º uso em cada (conta, IP, hora). Sem user_agent e sem porta de origem (o PostgREST não recebe porta confiável; resíduo R9, Decreto 8.771 art. 15-A). Sob sigilo, por 6 meses contados da linha, inclusive depois da exclusão da conta (privado.limpar_registros_acesso; LGPD art. 16, I), salvo guarda legal (privado.registro_acesso_guarda, MCI art. 15, § 2º). Base legal: LGPD art. 7º, II (cumprimento do art. 15 do Marco Civil; controladora é a empresa) para a guarda, e art. 7º, IX (segurança da conta e apuração de fraude) para o uso interno. Gravado por privado.consumir_registro_acesso. Nenhum papel de API lê nem escreve direto: a leitura é só por privado.ler_registros_acesso, que grava cada leitura no inventário privado.registro_acesso_leitura (Decreto 8.771, art. 13, III). Entrega a terceiro só por ordem judicial.';

comment on table privado.registro_acesso_recente is
  'Os (conta, IP, balde) já gravados nas últimas 3 horas, para o pre-request não emitir de novo. É estado de deduplicação, não registro: o consumidor apaga o que passa de 3 horas. Mesmos dados de privado.registro_acesso (conta e IP), sob o mesmo sigilo: nenhum papel de API lê direto, e não há função de leitura dela (Decreto 8.771, art. 13, III).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. O inventário das leituras
-- ─────────────────────────────────────────────────────────────────────────────
create table privado.registro_acesso_leitura (
  id              bigint generated always as identity primary key,
  papel_sessao    text not null,
  papel_chamada   text,
  responsavel     text not null,
  arquivo         text not null,
  conta           uuid not null,
  desde           timestamptz not null,
  ate             timestamptz not null,
  motivo          text not null,
  linhas          integer not null,
  inicio          timestamptz not null,
  fim             timestamptz not null,
  constraint registro_acesso_leitura_responsavel check (char_length(responsavel) between 1 and 80 and responsavel = btrim(responsavel)),
  constraint registro_acesso_leitura_arquivo check (arquivo = 'privado.registro_acesso'),
  constraint registro_acesso_leitura_motivo check (char_length(motivo) between 1 and 200 and motivo = btrim(motivo)),
  constraint registro_acesso_leitura_linhas check (linhas >= 0),
  constraint registro_acesso_leitura_periodo check (ate > desde),
  constraint registro_acesso_leitura_duracao check (fim >= inicio)
);
create index registro_acesso_leitura_conta on privado.registro_acesso_leitura (conta);

alter table privado.registro_acesso_leitura enable row level security;
revoke all on table privado.registro_acesso_leitura from public, anon, authenticated, service_role;

comment on table privado.registro_acesso_leitura is
  'Inventário das leituras do registro de acessos (Decreto 8.771/2016, art. 13, III: o momento, a duração, a identidade do funcionário ou do responsável designado e o arquivo acessado; o motivo é decisão nossa). Uma linha por chamada de privado.ler_registros_acesso, mesmo quando a leitura volta vazia. Guarda referência e motivo, nunca cópia das linhas lidas (RN15). Só a função escreve; nenhum papel de API lê nem escreve direto. Prazo de guarda: 5 anos contados do fim de cada leitura, inclusive depois da exclusão da conta lida (sem FK), por privado.limpar_inventario_leituras_registro_acesso. Base legal: LGPD art. 7º, II e art. 16, I (cumprimento do Decreto 8.771, art. 13, III) e art. 6º, X (prestação de contas à ANPD e ao titular: quem leu e por quê). Para o advogado: o decreto não fixa prazo; os 5 anos são inferência do time (Bússola, 08/11/2026), o mesmo prazo do turno.';
comment on column privado.registro_acesso_leitura.papel_sessao is
  'session_user da leitura: o papel técnico que abriu a conexão (authenticator pelo PostgREST, postgres pelo painel ou psql). Não identifica a pessoa; quem identifica é responsavel.';
comment on column privado.registro_acesso_leitura.papel_chamada is
  'O papel ativo de quem chamou (o SET ROLE da sessão, como o service_role que o PostgREST assume); nulo quando a sessão não trocou de papel.';
comment on column privado.registro_acesso_leitura.responsavel is
  'Identidade de quem leu (art. 13, II e III): o login individual do funcionário ou do responsável designado, declarado em cada leitura. Nunca o nome de um papel do banco (a função recusa). Dado pessoal do funcionário, com a finalidade única de prestar contas da leitura.';
comment on column privado.registro_acesso_leitura.arquivo is
  'O arquivo acessado (art. 13, III): a tabela lida. Hoje só privado.registro_acesso.';
comment on column privado.registro_acesso_leitura.conta is
  'A conta cujos registros foram lidos (auth.users.id), sem chave estrangeira: o inventário sobrevive à exclusão da conta, como o registro.';
comment on column privado.registro_acesso_leitura.desde is
  'Início do período pedido (inclusivo).';
comment on column privado.registro_acesso_leitura.ate is
  'Fim do período pedido (exclusivo).';
comment on column privado.registro_acesso_leitura.motivo is
  'Por que leu: o motivo ou o número da ordem, para localizá-la fora do banco. Nunca o conteúdo da ordem, nome, fato ou dado de terceiro.';
comment on column privado.registro_acesso_leitura.linhas is
  'Quantas linhas a leitura devolveu. É contagem, não cópia.';
comment on column privado.registro_acesso_leitura.inicio is
  'Momento da leitura (clock_timestamp no começo da função, UTC). O relógio é o real, não o do produto: o inventário presta contas do que aconteceu de fato.';
comment on column privado.registro_acesso_leitura.fim is
  'Fim da leitura (clock_timestamp depois de ler). A duração é fim - inicio.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. A função de leitura
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.ler_registros_acesso(
  p_conta       uuid,
  p_desde       timestamptz,
  p_ate         timestamptz,
  p_responsavel text,
  p_motivo      text
) returns table (usuario_id uuid, ip inet, acessado_em timestamptz)
language plpgsql volatile
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_inicio      timestamptz := clock_timestamp();
  v_responsavel text := btrim(p_responsavel);
  v_motivo      text := btrim(p_motivo);
  v_linhas      integer;
begin
  -- Recusa antes de ler: sem quem e sem por quê, nada sai.
  if v_responsavel is null or v_responsavel = '' then
    perform public.erro(422, 'responsavel_obrigatorio', 'informe o login de quem lê');
  end if;
  if char_length(v_responsavel) > 80
     or exists (select 1 from pg_catalog.pg_roles r where r.rolname = lower(v_responsavel)) then
    perform public.erro(422, 'responsavel_invalido', 'o responsável é a pessoa que lê, não um papel do banco');
  end if;
  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'motivo_obrigatorio', 'informe o motivo ou o número da ordem');
  end if;
  if char_length(v_motivo) > 200 then
    perform public.erro(422, 'motivo_invalido', 'o motivo tem até 200 caracteres: a referência, não o conteúdo');
  end if;
  if p_conta is null then
    perform public.erro(422, 'conta_obrigatoria', 'informe a conta');
  end if;
  if p_desde is null or p_ate is null or p_ate <= p_desde then
    perform public.erro(422, 'periodo_invalido', 'o período precisa de início e fim, com o fim depois do início');
  end if;

  return query
    select r.usuario_id, r.ip, r.acessado_em
      from privado.registro_acesso r
     where r.usuario_id = p_conta
       and r.acessado_em >= p_desde
       and r.acessado_em < p_ate
     order by r.acessado_em;
  get diagnostics v_linhas = row_count;

  insert into privado.registro_acesso_leitura
    (papel_sessao, papel_chamada, responsavel, arquivo, conta, desde, ate, motivo, linhas, inicio, fim)
  values
    (session_user, nullif(current_setting('role', true), 'none'), v_responsavel, 'privado.registro_acesso',
     p_conta, p_desde, p_ate, v_motivo, v_linhas, v_inicio, clock_timestamp());
end $$;

comment on function privado.ler_registros_acesso(uuid, timestamptz, timestamptz, text, text) is
  'Única leitura de privado.registro_acesso (Decreto 8.771/2016, art. 13, III). Devolve as linhas da conta no período [desde, ate) e grava 1 linha no inventário privado.registro_acesso_leitura (papéis técnicos da sessão, responsável, arquivo acessado, conta, período, motivo, quantas linhas, início e fim), mesmo quando volta vazia. Recusa sem ler (422): responsavel_obrigatorio, responsavel_invalido (acima de 80 caracteres ou nome de papel do banco), motivo_obrigatorio, motivo_invalido (acima de 200), conta_obrigatoria, periodo_invalido. Quem chama (art. 13, I): só o service_role e o dono. Não é API: o esquema privado não está exposto no PostgREST.';
revoke all on function privado.ler_registros_acesso(uuid, timestamptz, timestamptz, text, text) from public, anon, authenticated;
grant execute on function privado.ler_registros_acesso(uuid, timestamptz, timestamptz, text, text) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. A limpeza do inventário (5 anos contados do fim da leitura)
-- ─────────────────────────────────────────────────────────────────────────────
create index registro_acesso_leitura_fim on privado.registro_acesso_leitura (fim);

create or replace function privado.limpar_inventario_leituras_registro_acesso(
  p_anos   integer default 5,
  p_limite integer default 1000
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limite_data timestamptz;
  v_total       integer := 0;
  v_lote        integer;
  v_lotes       integer := 0;
  -- Teto por execução: 100 lotes, como em privado.limpar_registros_acesso. O que sobrar sai na rodada seguinte.
  c_teto_lotes  constant integer := 100;
begin
  -- Piso de 5 anos (Bússola, 08/11/2026): nenhum parâmetro encurta.
  if p_anos is null or p_anos < 5 then
    p_anos := 5;
  end if;
  if p_limite is null or p_limite < 1 then
    p_limite := 1000;
  end if;
  v_limite_data := privado.agora() - make_interval(years => p_anos);

  loop
    delete from privado.registro_acesso_leitura l
     where l.id = any (array(
       select x.id
         from privado.registro_acesso_leitura x
        where x.fim <= v_limite_data
        order by x.fim
        limit p_limite
        for update skip locked));
    get diagnostics v_lote = row_count;
    v_total := v_total + v_lote;
    v_lotes := v_lotes + 1;
    exit when v_lote < p_limite or v_lotes >= c_teto_lotes;
  end loop;

  return v_total;
end $$;

comment on function privado.limpar_inventario_leituras_registro_acesso(integer, integer) is
  'Expurga do inventário das leituras (privado.registro_acesso_leitura) as linhas cuja leitura terminou há mais de 5 anos, inclusive de conta excluída, em lotes com SKIP LOCKED e teto de 100 lotes por execução. Piso de 5 anos que nenhum parâmetro encurta (Bússola, 08/11/2026; para o advogado: o Decreto 8.771 não fixa prazo, e os 5 anos são inferência do time). Ainda não é chamada por privado.executar_retencao_diaria: entra lá depois do #459, que reescreve a rotina.';
revoke all on function privado.limpar_inventario_leituras_registro_acesso(integer, integer) from public, anon, authenticated;
grant execute on function privado.limpar_inventario_leituras_registro_acesso(integer, integer) to service_role;
