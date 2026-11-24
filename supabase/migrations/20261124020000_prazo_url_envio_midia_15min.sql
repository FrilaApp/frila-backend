-- B-102 (Fase 1): a URL de envio da mídia vale 15 minutos, e não mais 2 horas.
--
-- O token da `upload_url` fica no caminho de uma requisição e pode aparecer em log de
-- infraestrutura; encurtar o prazo reduz a janela em que um token vazado ainda serve. O fluxo
-- dos apps (pedir a URL e enviar em seguida, com prazos de rede de 15 s e 60 s) cabe em 15 min.
--
-- Recria `public.solicitar_upload_midia` igual à definição vigente
-- (20261108080000_enviar_midia_token_de_uso_unico.sql), trocando só os dois
-- `interval '2 hours'` por `interval '15 minutes'`: o `upload_expira_em` gravado e o `expira_em`
-- devolvido. Assinatura, `security definer set search_path = ''`, escada da URL e token não mudam.
-- `privado.consumir_token_upload` não muda: ele já compara com `upload_expira_em`.

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
      encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), privado.agora() + interval '15 minutes');
  v_url := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'enviar_midia_function_url' limit 1),
    nullif(current_setting('frila.enviar_midia_function_url', true), ''),
    (select replace(decrypted_secret, '/despachar', '/enviar-midia')
       from vault.decrypted_secrets where name = 'edge_function_url' limit 1),
    'http://127.0.0.1:54321/functions/v1/enviar-midia');
  return jsonb_build_object('midia_id',v_id,
    'upload_url', v_url || '?midia_id=' || v_id || '&token=' || v_token,
    'expira_em',privado.agora() + interval '15 minutes');
end $$;
