-- B-116: IP real do visitante da web no registro de acesso (Marco Civil, art. 15; ADR-002 "Acesso pela versão web").
-- O Worker da web (frila-web) fala com a API do Supabase; para o banco, o cf-connecting-ip dessas chamadas é o IP do
-- Worker, não o do visitante. O Worker passa o IP que ELE recebeu em três cabeçalhos assinados com HMAC-SHA256:
--   x-frila-ip-visitante   o texto CRU do CF-Connecting-IP recebido (IPv4 ou IPv6 literal, sem normalizar)
--   x-frila-ip-carimbo     segundos Unix (UTC), inteiro
--   x-frila-ip-assinatura  v1;k=<id>;<hex>  (v1 = versão do formato; <id> = chave [a-z0-9]{1,16}; hex = 64 minúsculos)
-- Mensagem assinada (UTF-8): v1|<ip cru>|<carimbo>|<uid>, com uid = sub do token DAQUELA chamada. A chave é o texto do
-- segredo em UTF-8 (64 hex minúsculos NÃO decodificados; só esse formato vale como chave), guardado no Vault como ip_visitante_hmac_<id> (uma entrada por chave; apagar a entrada retira a chave).
-- Sem assinatura válida o IP gravado é o do cf-connecting-ip, como antes: um IP forjado nunca entra.
-- Esta migração recria requisicao.conferir_limite() inteira (cópia da de 20261108110000_lgpd_registro_acessos_borda,
-- a vigente) mudando só a obtenção de v_ip. O segredo no Vault é passo manual do roteiro, nunca da migração.

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. O que é uma chave: o ÚNICO predicado, para a leitura e para o exists não divergirem
-- ─────────────────────────────────────────────────────────────────────────────
-- Só vale como chave o valor que, depois do btrim de espaço, tabulação e quebras de linha (colar com \n é comum), é o
-- formato do roteiro: 64 hex minúsculos (openssl rand -hex 32). Qualquer outro valor (vazio, branco Unicode como VT, FF,
-- NBSP e BOM, curto, maiúsculas, com espaço no meio) não é chave: o .trim() do Worker e o btrim do banco discordam
-- nesses brancos, e uma chave previsível deixaria qualquer um calcular o HMAC (Lince AG e Lince Codex, B-116).
create or replace function privado.chave_ip_visitante(p_valor text) returns text
language sql immutable parallel safe
set search_path = ''
as $$
  select case when btrim(p_valor, E' \t\r\n') ~ '^[0-9a-f]{64}$' then btrim(p_valor, E' \t\r\n') end
$$;

comment on function privado.chave_ip_visitante(text) is
  'B-116: o valor do Vault (ip_visitante_hmac_<id>) como chave do HMAC, ou NULL se não for 64 hex minúsculos depois do btrim de espaço, tab, CR e LF. Predicado único da leitura da chave e do exists que decide chave_desconhecida x sem_segredo.';
revoke all on function privado.chave_ip_visitante(text) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Avaliação pura: devolve o IP a gravar e, se o cabeçalho não valeu, o motivo curto
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.avaliar_ip_do_acesso(p_headers json, p_uid uuid, out p_ip text, out p_motivo text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cf      text := p_headers ->> 'cf-connecting-ip';
  v_visit   text := p_headers ->> 'x-frila-ip-visitante';
  v_carimbo text := p_headers ->> 'x-frila-ip-carimbo';
  v_assin   text := p_headers ->> 'x-frila-ip-assinatura';
  v_partes  text[];
  v_inet    inet;
  v_v4      inet;
  v_segredo text;
  v_esperada text;
begin
  p_ip := v_cf;

  -- Nenhum dos três: o caminho de sempre (apps móveis), sem motivo e sem custo novo.
  if v_visit is null and v_carimbo is null and v_assin is null then
    return;
  end if;

  -- Os três juntos e bem formados. A máscara (/) é recusada: o cabeçalho é um IP, não uma rede.
  v_partes := regexp_match(coalesce(v_assin, ''), '^v1;k=([a-z0-9]{1,16});([0-9a-f]{64})$');
  if v_visit is null or v_carimbo is null or v_assin is null
     or v_partes is null
     or v_carimbo !~ '^[0-9]{1,12}$'
     or strpos(v_visit, '/') > 0
     or not pg_input_is_valid(v_visit, 'inet') then
    p_motivo := 'formato';
    return;
  end if;

  -- Janela de 60 s (passado e futuro) no relógio REAL do banco: o frila.agora congelado dos testes não pode afrouxá-la.
  if abs(extract(epoch from clock_timestamp()) - v_carimbo::bigint) > 60 then
    p_motivo := 'carimbo_vencido';
    return;
  end if;

  -- IP reservado (o Pseudo IPv4 da Cloudflare em "Overwrite Headers" reescreve o IPv6 do visitante para 240.0.0.0/4):
  -- guardar seria guardar lixo. Para ::ffff:a.b.c.d vale a regra do IPv4 embutido.
  v_inet := v_visit::inet;
  if family(v_inet) = 6 and v_inet << '::ffff:0.0.0.0/96'::inet then
    v_v4 := '0.0.0.0'::inet + (v_inet - '::ffff:0.0.0.0'::inet);
  elsif family(v_inet) = 4 then
    v_v4 := v_inet;
  end if;
  if (v_v4 is not null and (v_v4 <<= '0.0.0.0/8'::inet or v_v4 <<= '10.0.0.0/8'::inet or v_v4 <<= '127.0.0.0/8'::inet
                            or v_v4 <<= '169.254.0.0/16'::inet or v_v4 <<= '172.16.0.0/12'::inet
                            or v_v4 <<= '192.168.0.0/16'::inet or v_v4 <<= '240.0.0.0/4'::inet))
     or (v_v4 is null and (v_inet <<= '::/128'::inet or v_inet <<= '::1/128'::inet
                           or v_inet <<= 'fc00::/7'::inet or v_inet <<= 'fe80::/10'::inet)) then
    p_motivo := 'ip_reservado';
    return;
  end if;

  -- Só vale como chave o que privado.chave_ip_visitante aceita (64 hex minúsculos); o mesmo predicado decide a leitura e
  -- o exists. Outro valor é como chave ausente: sem_segredo se nenhuma entrada vale, chave_desconhecida se há outra.
  select privado.chave_ip_visitante(s.decrypted_secret) into v_segredo
    from vault.decrypted_secrets s
   where s.name = 'ip_visitante_hmac_' || v_partes[1]
   limit 1;
  if v_segredo is null then
    p_motivo := case when exists (select 1 from vault.decrypted_secrets s
                                   where starts_with(s.name, 'ip_visitante_hmac_')
                                     and privado.chave_ip_visitante(s.decrypted_secret) is not null)
                     then 'chave_desconhecida' else 'sem_segredo' end;
    return;
  end if;

  -- O HMAC é sobre o TEXTO CRU do cabeçalho, antes de qualquer conversão (inet::text reescreve IPv6). A comparação é
  -- entre os resumos SHA-256 dos dois hex, para não vazar por tempo onde o texto diverge.
  v_esperada := encode(extensions.hmac(convert_to('v1|' || v_visit || '|' || v_carimbo || '|' || p_uid::text, 'UTF8'),
                                       convert_to(v_segredo, 'UTF8'), 'sha256'), 'hex');
  if extensions.digest(convert_to(v_esperada, 'UTF8'), 'sha256') is distinct from
     extensions.digest(convert_to(v_partes[2], 'UTF8'), 'sha256') then
    p_motivo := 'assinatura_invalida';
    return;
  end if;

  p_ip := v_visit;
exception
  -- Defeito aqui nunca derruba a requisição nem muda o IP: cai no cf-connecting-ip, com o motivo 'erro_interno'.
  when others then
    p_ip := v_cf;
    p_motivo := 'erro_interno';
end $$;

comment on function privado.avaliar_ip_do_acesso(json, uuid) is
  'B-116: dado o request.headers e o sub da chamada, devolve o IP a registrar (o cabeçalho assinado x-frila-ip-visitante se tudo vale; senão o cf-connecting-ip) e, quando um cabeçalho x-frila-ip-* veio e não valeu, o motivo curto (formato, carimbo_vencido, ip_reservado, chave_desconhecida, sem_segredo, assinatura_invalida, erro_interno). Pura: não emite nada. Quem chama é privado.ip_do_acesso.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. O que o pre-request chama: o IP e, por amostragem, a falha do cabeçalho
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.ip_do_acesso(p_headers json, p_uid uuid) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ip     text;
  v_motivo text;
begin
  select a.p_ip, a.p_motivo into v_ip, v_motivo from privado.avaliar_ip_do_acesso(p_headers, p_uid) a;
  -- A falha vira mensagem lógica só com o motivo (sem IP, sem cabeçalho), AMOSTRADA em 1 de 20: o pre-request não
  -- escreve (GET é transação só leitura), então não há deduplicação, e uma conta autenticada poderia inflar o WAL do
  -- slot mandando cabeçalho inválido a cada requisição. A decisão de usar o cf-connecting-ip não depende da amostra.
  -- O alerta de falhas conta, portanto, ~20x menos eventos do que aconteceram.
  if v_motivo is not null and random() < 0.05 then
    perform pg_logical_emit_message(false, 'frila_registro_acesso_falha', v_motivo);
  end if;
  return v_ip;
end $$;

comment on function privado.ip_do_acesso(json, uuid) is
  'B-116: devolve o IP a registrar para a requisição (ver privado.avaliar_ip_do_acesso) e emite, em 1 de 20 das falhas de cabeçalho, frila_registro_acesso_falha com só o motivo. A contagem de falhas do consumidor é, por isso, AMOSTRADA (~1/20). Chamada só por requisicao.conferir_limite, quando algum cabeçalho x-frila-ip-* existe.';

revoke all on function privado.avaliar_ip_do_acesso(json, uuid) from public, anon, authenticated;
revoke all on function privado.ip_do_acesso(json, uuid) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. O pre-request: igual ao vigente, mudando só a obtenção de v_ip
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function requisicao.conferir_limite() returns void
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_papel    text := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role';
  v_metodo   text := coalesce(current_setting('request.method', true), '');
  v_cab      text;
  v_ip       text;
  v_em       timestamptz;
  v_janela   timestamptz;
  v_contagem int;
begin
  if v_uid is null or v_papel is distinct from 'authenticated' then
    return;
  end if;

  -- Registro de acessos (Marco Civil art. 15), antes do retorno do GET para cobrir a leitura. Só lê tabelas: com a
  -- coleta ligada, na 1ª requisição de cada (conta, IP, hora) que ainda não está em registro_acesso_recente, emite
  -- uma mensagem lógica NÃO transacional, que vale no GET só leitura e sobrevive à requisição que falha (sem fsync
  -- próprio). Fica aqui, e não numa função à parte, para não somar uma chamada com troca de GUC a cada requisição.
  begin
    if exists (select 1 from privado.registro_acesso_coleta c where c.unica and c.ligada) then
      -- O cf-connecting-ip, que a borda não deixa forjar; X-Forwarded-For, x-real-ip e true-client-ip, nunca (M1). Só a
      -- web (B-116) tem outro caminho: o IP que o Worker recebeu, assinado por HMAC (privado.ip_do_acesso). Sem cabeçalho
      -- x-frila-ip-*, nada muda: a chamada à função só acontece quando o texto dos cabeçalhos o menciona.
      v_cab := nullif(current_setting('request.headers', true), '');
      v_ip := case when strpos(v_cab, 'x-frila-ip-') > 0 then privado.ip_do_acesso(v_cab::json, v_uid)
                   else v_cab::json ->> 'cf-connecting-ip' end;
      if v_ip is not null and pg_input_is_valid(v_ip, 'inet') then
        v_em := privado.agora();
        if not exists (select 1 from privado.registro_acesso_recente r
                        where r.usuario_id = v_uid and r.ip = v_ip::inet
                          and r.balde = privado.balde_registro_acesso(v_em)) then
          perform pg_logical_emit_message(false, 'frila_registro_acesso',
            v_uid::text || ' ' || host(v_ip::inet) || ' ' || to_char(v_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
        end if;
      end if;
    end if;
  exception
    -- Nunca derruba a requisição. A falha vira outra mensagem, só com o SQLSTATE (RN15), que o consumidor conta.
    -- query_canceled não entra: um statement_timeout ou cancelamento da requisição segue o caminho normal.
    when others then
      begin
        perform pg_logical_emit_message(false, 'frila_registro_acesso_falha', sqlstate);
      exception when others then
        null;
      end;
  end;

  if v_metodo in ('', 'GET', 'HEAD')
     or current_setting('transaction_read_only') = 'on' then
    return;
  end if;

  v_janela := date_trunc('minute', privado.agora());

  insert into privado.escrita_por_conta as e (usuario_id, janela, contagem)
  values (v_uid, v_janela, 1)
  on conflict (usuario_id) do update
     set contagem = case when e.janela = excluded.janela then e.contagem + 1 else 1 end,
         janela   = excluded.janela
  returning e.contagem into v_contagem;

  if v_contagem > privado.limite_de_escrita_por_minuto() then
    perform public.erro(429, 'limite_excedido');
  end if;
end $$;

comment on function requisicao.conferir_limite() is
  'db_pre_request do PostgREST: registra o acesso da conta autenticada (Marco Civil art. 15), inclusive no GET: com privado.registro_acesso_coleta ligada, emite uma mensagem lógica não transacional (conta, IP, data e hora em UTC) na 1ª requisição de cada (conta, IP, hora), que privado.consumir_registro_acesso grava; erro no registro nunca derruba a requisição. O IP é o cf-connecting-ip ou, nas chamadas da web com cabeçalhos x-frila-ip-* assinados por HMAC e válidos, o IP que o Worker recebeu (B-116, privado.ip_do_acesso). Depois conta as escritas da conta no minuto e recusa com 429 limite_excedido acima de privado.limite_de_escrita_por_minuto() (RNF07, cartão kT7NhMGV).';
