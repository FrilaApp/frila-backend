-- Upload da foto pela Edge Function enviar-midia, com token opaco de uso único (contrato 0.2.63).
--
-- Antes, `solicitar_upload_midia` assinava a URL do Storage à mão com `storage_jwt_secret`, o
-- segredo JWT legado, que também assina tokens de `service_role`. O Lince Codex foi contrário
-- a guardar esse segredo no banco (orquestracao/retornos/gates-ativacao-B-C-lince-fb89.md), e
-- o dono decidiu (08/11/2026): a `upload_url` passa a apontar para a Edge Function
-- `enviar-midia`, que recebe o JPEG e o grava no caminho que esta RPC reservou, usando a
-- API do Storage (createSignedUploadUrl + uploadToSignedUrl) com a credencial de serviço que
-- só existe no ambiente da função.
--
-- O token: 32 bytes aleatórios (64 hex), entregues só na `upload_url`. O banco guarda o
-- SHA-256 dele, o prazo (2 h) e quando foi usado. `privado.consumir_token_upload` o consome
-- num único UPDATE condicional (`... and upload_usado_em is null ... returning`): dois envios
-- simultâneos com o mesmo token disputam a mesma linha e só um volta com o caminho (o outro
-- espera a trava e então não casa mais). Mesmo defeito evitado no #427.
--
-- O consumo revalida o que a RPC conferiu, porque o envio chega sem sessão: a mídia segue
-- `enviando`, o prazo não venceu, a conta do titular continua ativa, quem pediu continua
-- membro da casa (foto da casa) e o recurso `foto_de_perfil` continua ligado.
--
-- `privado.token_de_upload_storage` continua existindo: a RN14 (`solicitar_upload_documentos`)
-- ainda a usa e fica para um segundo passo. Nenhuma assinatura de RPC muda.

select set_config('lock_timeout', '2s', true);

-- ── 1. O token na mídia ───────────────────────────────────────────────────────

alter table privado.midia
  add column upload_token_hash text,
  add column upload_expira_em  timestamptz,
  add column upload_usado_em   timestamptz;

comment on column privado.midia.upload_token_hash is
  'SHA-256 (hex) do token opaco de uso único da upload_url (contrato 0.2.63). O token em si nunca é guardado.';
comment on column privado.midia.upload_expira_em is
  'Até quando o token de envio vale: 2 h depois de solicitar_upload_midia.';
comment on column privado.midia.upload_usado_em is
  'Quando a Edge Function enviar-midia consumiu o token. Preenchido, o token não vale mais.';

create unique index midia_upload_token_hash_unico on privado.midia (upload_token_hash)
  where upload_token_hash is not null;

-- ── 2. solicitar_upload_midia devolve a URL da enviar-midia ───────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.solicitar_upload_midia 0.2.62

create or replace function public.solicitar_upload_midia(tipo text, mime text, bytes bigint, estabelecimento_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := privado.usuario_midia(true);
  v_id uuid := gen_random_uuid();
  v_path text := 'perfil/' || v_id || '.jpg';
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
  v_url text;
begin
  if tipo is distinct from 'foto_perfil' then perform public.erro(422,'midia_invalida','tipo_indisponivel'); end if;
  if mime is distinct from 'image/jpeg' then perform public.erro(422,'midia_invalida','formato'); end if;
  if bytes is null or bytes <= 0 or bytes > 5242880 then perform public.erro(422,'midia_invalida','tamanho'); end if;
  if estabelecimento_id is not null then
    if not privado.eh_membro(estabelecimento_id) then perform public.erro(403,'sem_permissao'); end if;
  else
    perform privado.exigir_perfil('profissional');
  end if;
  insert into privado.midia(id,dono_usuario_id,estabelecimento_id,dono_tipo,tipo,storage_path,mime,bytes,
                            upload_token_hash,upload_expira_em)
    values (v_id,v_uid,estabelecimento_id,case when estabelecimento_id is null then 'profissional' else 'estabelecimento' end,
      tipo,v_path,mime,bytes,
      encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), privado.agora() + interval '2 hours');
  v_url := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'enviar_midia_function_url' limit 1),
    nullif(current_setting('frila.enviar_midia_function_url', true), ''),
    (select replace(decrypted_secret, '/despachar', '/enviar-midia')
       from vault.decrypted_secrets where name = 'edge_function_url' limit 1),
    'http://127.0.0.1:54321/functions/v1/enviar-midia');
  return jsonb_build_object('midia_id',v_id,
    'upload_url', v_url || '?midia_id=' || v_id || '&token=' || v_token,
    'expira_em',privado.agora() + interval '2 hours');
end $$;

-- ── 3. O consumo atômico, para a Edge Function ────────────────────────────────

create function privado.consumir_token_upload(p_midia_id uuid, p_token text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caminho text;
begin
  if p_midia_id is null or p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    return null;
  end if;

  -- Um UPDATE só: quem perde a disputa espera a trava da linha e, reavaliado o WHERE depois
  -- do commit do vencedor, não casa mais (`upload_usado_em` preenchido). Nunca dois caminhos.
  update privado.midia m
     set upload_usado_em = privado.agora(),
         atualizado_em   = privado.agora()
   where m.id = p_midia_id
     and m.upload_token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
     and m.upload_usado_em is null
     and m.upload_expira_em > privado.agora()
     and m.estado = 'enviando'
     and exists (select 1 from public.usuario u where u.id = m.dono_usuario_id and u.estado = 'ativa')
     and (m.estabelecimento_id is null or exists (
           select 1 from public.membro_estabelecimento me
            where me.estabelecimento_id = m.estabelecimento_id and me.usuario_id = m.dono_usuario_id))
     and coalesce((select bool_or(c.foto_de_perfil) from privado.configuracao_app c), false)
  returning m.storage_path into v_caminho;

  return v_caminho;
end $$;

comment on function privado.consumir_token_upload(uuid, text) is
  'Consome, numa operação atômica, o token de uso único da upload_url (contrato 0.2.63) e devolve o caminho reservado no Storage, ou NULL se o token não vale (errado, vencido, já usado, mídia fora de enviando, conta não ativa, fora da casa ou recurso desligado). Chamada só pela Edge Function enviar-midia.';

revoke all on function privado.consumir_token_upload(uuid, text) from public, anon, authenticated;
grant execute on function privado.consumir_token_upload(uuid, text) to service_role;
