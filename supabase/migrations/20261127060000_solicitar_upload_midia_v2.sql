-- B-102 (Fase 2, fatia a): `public.solicitar_upload_midia_v2`, o pedido de envio da foto com o token FORA da URL.
--
-- A v1 devolve `upload_url` com `&token=<64 hex>` na query, e o log do gateway grava o caminho inteiro com a query
-- (medido no Supabase local: o token aparece em `metadata.request.path`; um cabeçalho personalizado, não). A v2 devolve a
-- `upload_url` só com `midia_id` e o token no campo `upload_token`; o app o manda no cabeçalho `X-Upload-Token` do PUT para
-- `enviar-midia`. Contrato 0.2.119 (frila-docs#309): mudança de forma do 200 não cabe na v1, vira operação nova.
--
-- Mesma entrada, mesmas recusas e mesma validade da `solicitar_upload_midia` (corpo de 20261124020000, 15 min): o
-- `upload_url` é a única diferença e `upload_token` o único campo novo. A resposta não traz `upload_url_miniatura`
-- (descontinuado na 0.2.57). A v1 NÃO muda e segue valendo, sem aviso de descontinuação, até a versão mínima do app subir.
-- O token continua opaco (32 bytes) e só o seu SHA-256 vai ao banco; `privado.consumir_token_upload` não muda.
-- A `enviar-midia` ler o cabeçalho `X-Upload-Token` é a fatia (b), em outro PR.

create or replace function public.solicitar_upload_midia_v2(tipo text, mime text, bytes bigint, estabelecimento_id uuid default null)
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
      encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), privado.agora() + interval '15 minutes');
  v_url := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'enviar_midia_function_url' limit 1),
    nullif(current_setting('frila.enviar_midia_function_url', true), ''),
    (select replace(decrypted_secret, '/despachar', '/enviar-midia')
       from vault.decrypted_secrets where name = 'edge_function_url' limit 1),
    'http://127.0.0.1:54321/functions/v1/enviar-midia');
  return jsonb_build_object('midia_id',v_id,
    'upload_url', v_url || '?midia_id=' || v_id,
    'upload_token', v_token,
    'expira_em',privado.agora() + interval '15 minutes');
end $$;

comment on function public.solicitar_upload_midia_v2(text, text, bigint, uuid) is
  'Pede a URL e o token para enviar uma foto, com o token fora da URL (contrato 0.2.119, B-102 fase 2). Mesmas regras da solicitar_upload_midia; a upload_url leva só o midia_id e o token vem em upload_token, para o cabeçalho X-Upload-Token do PUT para enviar-midia.';

revoke all on function public.solicitar_upload_midia_v2(text, text, bigint, uuid) from public, anon;
grant execute on function public.solicitar_upload_midia_v2(text, text, bigint, uuid) to authenticated;
