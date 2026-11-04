-- As três operações da verificação de identidade (RN14), contrato 0.2.50.
-- Cartão 86CC7PW3 · requisitos `frila-docs/requisitos/verificacao-progressiva-rn14.md`.
--
-- `minha_identidade_status`, `solicitar_upload_verificacao` e `confirmar_envio_verificacao`.
-- A tabela, o HMAC do documento e o expurgo de mídia vêm de
-- `20261104110000_verificacao_identidade.sql`; esta migração só acrescenta a porta do app.
--
-- O que estas funções NÃO fazem, e é de propósito:
--   · Não criam exigência. Quem abre exigência de nível 2 é a moderação, em apuração de
--     denúncia grave (RN13), por `privado.exigir_verificacao` — que não é chamada pelo app
--     e fica fora do contrato 0.2.50.
--   · Não decidem nada sobre a conta. A análise é humana, e vencer prazo não tem
--     consequência automática (RN13, LGPD art. 20).
--   · Não devolvem evidência. O contrato não expõe `documento_hmac`, caminho no Storage
--     nem score (VP-71): o cliente vê estado, motivo e prazo.
--
-- A URL assinada de upload é gerada aqui, em SQL, e não por Edge Function, porque o
-- contrato pede que `solicitar_upload_verificacao` devolva as URLs na mesma resposta. O
-- formato do token foi MEDIDO contra o Storage local (POST /storage/v1/object/upload/sign):
-- cabeçalho `{"alg":"HS256"}`, carga
-- `{"url":"<bucket>/<caminho>","upsert":false,"scope":"upload","iat":…,"exp":…}`, assinado
-- em HMAC-SHA256 com o segredo JWT do projeto, e validade padrão de 7200 s — as duas horas
-- que o contrato declara.

-- ── 1. Assinatura do token de upload ──────────────────────────────────────────

create or replace function privado.base64url(p_bytes bytea)
returns text
language sql
immutable
set search_path = ''
as $$
  -- `encode` quebra linha a cada 76 caracteres e usa o alfabeto padrão; JWT exige uma
  -- linha só, alfabeto URL e sem preenchimento.
  select rtrim(translate(replace(encode(p_bytes, 'base64'), E'\n', ''), '+/', '-_'), '=');
$$;

comment on function privado.base64url(bytea) is
  'Base64 no alfabeto URL, sem preenchimento e sem quebra de linha, como o JWT exige.';

revoke execute on function privado.base64url(bytea) from public, anon, authenticated;

create or replace function privado.token_de_upload_storage(
  p_bucket   text,
  p_caminho  text,
  p_segundos integer default 7200
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_segredo    text;
  v_cabecalho  text;
  v_carga      text;
  v_assinatura text;
  v_agora      bigint;
begin
  -- O segredo JWT do projeto mora no Vault, como os demais (`agendador_secret`,
  -- `documento_pepper`). Ausente é erro, e não token vazio: um token inválido devolveria
  -- URL que o app tenta e falha, e o motivo só apareceria no log do Storage.
  select decrypted_secret into v_segredo
    from vault.decrypted_secrets
   where name = 'storage_jwt_secret'
   limit 1;

  if v_segredo is null or btrim(v_segredo) = '' then
    raise exception 'segredo_ausente' using errcode = 'P0002',
      detail = 'configure o segredo storage_jwt_secret no Vault antes de emitir URL de upload';
  end if;

  -- `extract(epoch)` do relógio do produto: em teste, `privado.agora()` é sobreposto, e o
  -- token tem de nascer com o mesmo relógio que o resto da transação.
  v_agora := floor(extract(epoch from privado.agora()))::bigint;

  -- Cabeçalho sem `typ`, exatamente como o Storage emite. O verificador aceita os dois,
  -- mas copiar o formato medido evita depender de uma tolerância que pode mudar.
  v_cabecalho := privado.base64url(convert_to('{"alg":"HS256"}', 'utf8'));
  v_carga     := privado.base64url(convert_to(
    json_build_object(
      'url',    p_bucket || '/' || p_caminho,
      'upsert', false,
      'scope',  'upload',
      'iat',    v_agora,
      'exp',    v_agora + greatest(p_segundos, 1)
    )::text, 'utf8'));

  v_assinatura := privado.base64url(
    extensions.hmac(v_cabecalho || '.' || v_carga, v_segredo, 'sha256'));

  return v_cabecalho || '.' || v_carga || '.' || v_assinatura;
end $$;

comment on function privado.token_de_upload_storage(text, text, integer) is
  'Token de upload assinado para o Storage, no mesmo formato que POST /storage/v1/object/upload/sign emite (medido em 04/11/2026). Segredo storage_jwt_secret do Vault; ausente é erro. Validade padrão de 7200 s, as duas horas do contrato 0.2.50.';

revoke execute on function privado.token_de_upload_storage(text, text, integer) from public, anon, authenticated;
grant  execute on function privado.token_de_upload_storage(text, text, integer) to service_role;

create or replace function privado.url_de_upload_de_verificacao(
  p_caminho  text,
  p_segundos integer default 7200
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_base text;
begin
  -- Mesma escada do `20261103120000_vault_urls_edge_functions.sql`: Vault primeiro, GUC
  -- de compatibilidade depois, e o endereço local por último, para o ambiente de
  -- desenvolvimento não precisar de segredo nenhum.
  v_base := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'storage_url' limit 1),
    nullif(current_setting('frila.storage_url', true), ''),
    'http://127.0.0.1:54321/storage/v1'
  );

  return rtrim(v_base, '/')
         || '/object/upload/sign/documentos-identidade/' || p_caminho
         || '?token=' || privado.token_de_upload_storage('documentos-identidade', p_caminho, p_segundos);
end $$;

comment on function privado.url_de_upload_de_verificacao(text, integer) is
  'URL assinada de upload no bucket privado documentos-identidade. Base do Storage: segredo storage_url do Vault, GUC frila.storage_url, ou 127.0.0.1:54321 em desenvolvimento.';

revoke execute on function privado.url_de_upload_de_verificacao(text, integer) from public, anon, authenticated;
grant  execute on function privado.url_de_upload_de_verificacao(text, integer) to service_role;

-- ── 2. O estado, em JSON do contrato ──────────────────────────────────────────

create or replace function privado.status_verificacao_em_json(p_usuario uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_linha  record;
  v_selo   boolean;
begin
  -- A linha que vale é a mais recente: o histórico de apuração fica, e o estado atual é o
  -- último episódio. Ausência de linha é `nao_exigida`, que é o estado inicial de toda
  -- conta (RN14: nenhuma conta nasce `pendente`).
  select v.status, v.motivo, v.prazo_envio_ate
    into v_linha
    from privado.verificacao_identidade v
   where v.usuario_id = p_usuario
   order by v.solicitado_em desc, v.id desc
   limit 1;

  -- O selo vem depois, e NÃO se usa `found` daqui para diante: `found` vale pela última
  -- consulta, e a linha de `public.profissional` falta em quem ainda não informou o ponto
  -- base. Medido em 04/11/2026: com `found` depois desta consulta, uma verificação em
  -- análise era devolvida como `nao_exigida` para quem não tinha a linha do profissional.
  select coalesce(p.identidade_verificada, false) into v_selo
    from public.profissional p
   where p.usuario_id = p_usuario;

  if v_linha.status is null then
    return jsonb_build_object(
      'status_verificacao',    'nao_exigida',
      'motivo',                null,
      'prazo_envio_ate',       null,
      'identidade_verificada', coalesce(v_selo, false)
    );
  end if;

  return jsonb_build_object(
    'status_verificacao',    v_linha.status,
    'motivo',                v_linha.motivo,
    'prazo_envio_ate',       v_linha.prazo_envio_ate,
    'identidade_verificada', coalesce(v_selo, false)
  );
end $$;

comment on function privado.status_verificacao_em_json(uuid) is
  'StatusVerificacao do contrato 0.2.50 para uma conta: estado, motivo, prazo e selo. Sem linha na tabela, devolve nao_exigida — o estado inicial de toda conta. Nunca devolve evidência (VP-71).';

revoke execute on function privado.status_verificacao_em_json(uuid) from public, anon, authenticated;
grant  execute on function privado.status_verificacao_em_json(uuid) to service_role;

-- ── 3. Guarda comum das três operações ────────────────────────────────────────

create or replace function privado.conta_de_profissional_que_chama()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_perfil public.perfil_conta;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  select u.perfil into v_perfil
    from public.usuario u
   where u.id = v_uid and u.estado <> 'anonimizada';

  -- Conta encerrada ou anonimizada não lê nem escreve verificação (RF25, RNF08), e a
  -- recusa é 401 antes de qualquer leitura, como nas demais funções desde a 0.2.44.
  if v_perfil is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- Conta SUSPENSA passa, e isto é deliberado: o nível 2 da RN14 existe justamente para a
  -- apuração de denúncia grave (RN13), e é a conta sob apuração que precisa enviar o
  -- documento para restabelecer o status regular. Recusar aqui fecharia a porta na cara de
  -- quem o fluxo foi feito para atender. O contrato 0.2.50 só declara o 401 de conta
  -- encerrada ou anonimizada e nada diz sobre suspensa; se produto quiser recusar a
  -- suspensa, isso muda no contrato primeiro.

  -- A guarda olha o PERFIL da conta, e não a existência de `public.profissional`. Medido
  -- em 04/11/2026: `public.criar_conta('profissional', …)` cria só a linha de
  -- `public.usuario`; a de `public.profissional` nasce depois, quando a pessoa informa o
  -- ponto base. Exigir a segunda aqui daria 403 a quem acabou de se cadastrar, e o
  -- contrato 0.2.50 diz que toda conta tem resposta, com `nao_exigida` de estado inicial.
  if v_perfil <> 'profissional' then
    -- Verificação de identidade é do profissional. Contratante tem o nível 4, que é outro
    -- assunto e não passa por estas funções (RF21).
    perform public.erro(403, 'sem_permissao');
  end if;

  return v_uid;
end $$;

comment on function privado.conta_de_profissional_que_chama() is
  'Guarda comum das operações de verificação de identidade: 401 sem token ou com conta não ativa, 403 sem_permissao para quem não é profissional. Devolve o id da conta. Olha o perfil da conta, não a linha de public.profissional, que só nasce quando a pessoa informa o ponto base.';

-- `authenticated` NÃO executa função de `privado`, e não precisa: as três RPCs de
-- `public` são SECURITY DEFINER e rodam como o dono, que é quem chama esta guarda. Conceder
-- aqui alargaria a superfície autenticada sem necessidade, e é o que os testes 480 e 785
-- cobram do schema inteiro.
revoke execute on function privado.conta_de_profissional_que_chama() from public, anon, authenticated;
grant  execute on function privado.conta_de_profissional_que_chama() to service_role;

-- ── 4. minha_identidade_status ────────────────────────────────────────────────

create or replace function public.minha_identidade_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  v_uid := privado.conta_de_profissional_que_chama();
  return privado.status_verificacao_em_json(v_uid);
end $$;

comment on function public.minha_identidade_status() is
  'Estado da verificação de identidade do profissional autenticado (RN14, contrato 0.2.50). Leitura sem efeito colateral. Toda conta tem resposta: nao_exigida é o estado inicial.';

revoke execute on function public.minha_identidade_status() from public, anon;
grant  execute on function public.minha_identidade_status() to authenticated;

-- ── 5. solicitar_upload_verificacao ───────────────────────────────────────────

create or replace function public.solicitar_upload_verificacao(documento_tipo text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid      uuid;
  v_tipo     text := lower(btrim(coalesce(solicitar_upload_verificacao.documento_tipo, '')));
  v_linha    record;
  v_id       uuid;
  v_prefixo  text;
  v_segundos integer := 7200;
  v_expira   timestamptz;
  v_partes   jsonb := '[]'::jsonb;
  v_parte    text;
begin
  v_uid := privado.conta_de_profissional_que_chama();

  -- O contrato 0.2.50 fecha o catálogo em rg e cnh. A tabela aceita `cin` desde
  -- `20261104110000`, para a moderação registrar o que receber; a porta do app é mais
  -- estreita que a tabela de propósito, e quem alargar uma tem de alargar a outra.
  if v_tipo not in ('rg', 'cnh') then
    -- `campo_invalido` com `details` do campo é o padrão do contrato para valor recusado
    -- pela regra (tabela de erros, 422). Código próprio por operação obrigaria o app a
    -- aprender uma string nova por tela.
    perform public.erro(422, 'campo_invalido', 'documento_tipo');
  end if;

  select v.id, v.status, v.nivel, v.motivo, v.prazo_envio_ate
    into v_linha
    from privado.verificacao_identidade v
   where v.usuario_id = v_uid
   order by v.solicitado_em desc, v.id desc
   limit 1;

  -- Aceita `nao_exigida` (sem linha, começo voluntário do selo), `pendente` (exigência
  -- aberta) e `rejeitada` (envio novo depois de recusa). Análise em curso ou verificação
  -- aprovada recusam, com o motivo no `details` — é o que o cliente mostra.
  if v_linha.id is not null and v_linha.status in ('em_analise', 'aprovada') then
    perform public.erro(409, 'verificacao_indisponivel', v_linha.status::text);
  end if;

  if v_linha.id is null or v_linha.status = 'rejeitada' then
    -- Começo voluntário, ou envio novo depois de recusa: nasce nível 3 (selo). O nível 2
    -- só existe por exigência da moderação, que escreve a linha antes de o app chegar
    -- aqui — e nesse caso o `pendente` do bloco de baixo é o que vale.
    insert into privado.verificacao_identidade (usuario_id, nivel, status, documento_tipo)
    values (v_uid, 3, 'pendente', v_tipo)
    returning id into v_id;
  else
    v_id := v_linha.id;
    update privado.verificacao_identidade
       set documento_tipo = v_tipo
     where id = v_id;
  end if;

  -- Caminho por conta e por verificação: a política de escrita do bucket confere o
  -- primeiro segmento contra o `auth.uid()` de quem envia, então o prefixo é a conta.
  v_prefixo := v_uid::text || '/' || v_id::text;
  v_expira  := privado.agora() + make_interval(secs => v_segundos);

  foreach v_parte in array array['frente', 'verso', 'selfie'] loop
    v_partes := v_partes || jsonb_build_array(jsonb_build_object(
      'parte', v_parte,
      'url',   privado.url_de_upload_de_verificacao(
                 v_prefixo || '/' || v_parte || '.jpg', v_segundos)
    ));
  end loop;

  -- Os caminhos ficam na linha para o expurgo saber o que apagar, e o prazo de expurgo
  -- nasce junto: 15 dias corridos é o teto preventivo de quem envia e não tem desfecho.
  -- Sem isto o `check verificacao_midia_tem_prazo` recusaria a escrita, e é bom que
  -- recuse: caminho gravado sem prazo é foto sem data de validade.
  update privado.verificacao_identidade
     set storage_path_frente = v_prefixo || '/frente.jpg',
         storage_path_verso  = v_prefixo || '/verso.jpg',
         storage_path_selfie = v_prefixo || '/selfie.jpg',
         expurgo_midia_em    = privado.agora() + interval '15 days'
   where id = v_id;

  return jsonb_build_object('expira_em', v_expira, 'partes', v_partes);
end $$;

comment on function public.solicitar_upload_verificacao(text) is
  'Emite as URLs assinadas de upload das evidências da verificação de identidade (RN14, contrato 0.2.50), válidas por 2 h, no bucket privado documentos-identidade. Aceita nao_exigida, pendente e rejeitada; em_analise e aprovada recusam com 409 verificacao_indisponivel. Pedir de novo antes de confirmar devolve URLs novas.';

revoke execute on function public.solicitar_upload_verificacao(text) from public, anon;
grant  execute on function public.solicitar_upload_verificacao(text) to authenticated;

-- ── 6. confirmar_envio_verificacao ────────────────────────────────────────────

create or replace function public.confirmar_envio_verificacao()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid;
  v_linha  record;
  v_parte  text;
  v_caminho text;
begin
  v_uid := privado.conta_de_profissional_que_chama();

  select v.id, v.status, v.storage_path_frente, v.storage_path_verso, v.storage_path_selfie
    into v_linha
    from privado.verificacao_identidade v
   where v.usuario_id = v_uid
   order by v.solicitado_em desc, v.id desc
   limit 1;

  if v_linha.id is null or v_linha.storage_path_frente is null then
    perform public.erro(409, 'verificacao_indisponivel', 'sem_envio_solicitado');
  end if;

  -- A trava é por lista fechada, e não por exceção: só `pendente` e `em_analise` seguem.
  -- Sem isto, uma verificação `rejeitada` (que tem `respondido_em` preenchido e pode ter
  -- os caminhos de mídia do episódio anterior) chegaria ao `update` para `em_analise` e
  -- violaria o `check verificacao_desfecho_datado` — o app receberia 500 no lugar de uma
  -- recusa de regra. Depois de rejeitada, o caminho é pedir o upload de novo, que abre
  -- episódio novo.
  if v_linha.status = 'aprovada' then
    perform public.erro(409, 'verificacao_indisponivel', 'aprovada');
  end if;

  if v_linha.status not in ('pendente', 'em_analise') then
    perform public.erro(409, 'verificacao_indisponivel', 'sem_envio_solicitado');
  end if;

  -- Idempotente: confirmar de novo com a análise já em curso devolve o mesmo estado e não
  -- reabre nada. Repetição de rede não pode reiniciar a contagem da moderação.
  if v_linha.status = 'em_analise' then
    return privado.status_verificacao_em_json(v_uid);
  end if;

  -- Confere que cada parte chegou ao bucket. `storage.objects` é o índice do Storage: se
  -- a linha não está lá, o arquivo não subiu. A recusa diz QUAL parte falta, porque
  -- "incompleto" sem a parte obriga o app a adivinhar o que pedir de novo.
  foreach v_parte in array array['frente', 'verso', 'selfie'] loop
    v_caminho := case v_parte
                   when 'frente' then v_linha.storage_path_frente
                   when 'verso'  then v_linha.storage_path_verso
                   else               v_linha.storage_path_selfie
                 end;

    if v_caminho is null
       or not exists (select 1 from storage.objects o
                       where o.bucket_id = 'documentos-identidade'
                         and o.name = v_caminho) then
      perform public.erro(422, 'evidencia_incompleta', v_parte);
    end if;
  end loop;

  update privado.verificacao_identidade
     set status = 'em_analise'
   where id = v_linha.id;

  return privado.status_verificacao_em_json(v_uid);
end $$;

comment on function public.confirmar_envio_verificacao() is
  'Confirma o envio das evidências e move a verificação para em_analise (RN14, contrato 0.2.50). Confere no Storage que frente, verso e selfie chegaram; falta de parte é 422 evidencia_incompleta com a parte no details. Sem envio solicitado ou já aprovada, 409 verificacao_indisponivel. Idempotente em em_analise. A análise seguinte é humana (RN13).';

revoke execute on function public.confirmar_envio_verificacao() from public, anon;
grant  execute on function public.confirmar_envio_verificacao() to authenticated;
