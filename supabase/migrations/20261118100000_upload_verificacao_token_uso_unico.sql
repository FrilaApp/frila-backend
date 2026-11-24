-- Primitiva privada para o upload de documentos da RN14 com token opaco de uso único.
--
-- Esta migração é deliberadamente aditiva: a RPC pública ainda não emite estes tokens e
-- o upload vigente continua intacto. O corte para a Edge Function acontece em outro PR.
-- Cada parte de uma verificação tem um único slot; reemitir troca o hash nesse slot e
-- invalida o token anterior. O token em claro nunca entra no banco.

select set_config('lock_timeout', '2s', true);

create table privado.upload_verificacao_identidade (
  id              uuid primary key default gen_random_uuid(),
  verificacao_id  uuid not null references privado.verificacao_identidade(id) on delete cascade,
  parte           text not null constraint upload_verificacao_parte_valida
                    check (parte in ('frente', 'verso', 'selfie')),
  storage_path    text not null constraint upload_verificacao_storage_path_nao_vazio
                    check (btrim(storage_path) <> ''),
  token_hash      text not null constraint upload_verificacao_token_hash_valido
                    check (token_hash ~ '^[0-9a-f]{64}$'),
  expira_em       timestamptz not null,
  usado_em        timestamptz,

  constraint upload_verificacao_parte_unica unique (verificacao_id, parte),
  constraint upload_verificacao_token_hash_unico unique (token_hash)
);

comment on table privado.upload_verificacao_identidade is
  'Slot privado do token opaco de upload de cada parte da verificação de identidade. Guarda somente SHA-256, prazo e consumo; nunca o token em claro.';
comment on column privado.upload_verificacao_identidade.parte is
  'Parte fechada da evidência RN14: frente, verso ou selfie. Há um único slot por verificação e parte.';
comment on column privado.upload_verificacao_identidade.token_hash is
  'SHA-256 hexadecimal do token opaco de 32 bytes. Reemitir substitui o hash e invalida o token anterior.';
comment on column privado.upload_verificacao_identidade.usado_em is
  'Instante em que a Edge Function consumiu o token. Preenchido, o token não vale novamente.';

alter table privado.upload_verificacao_identidade enable row level security;
revoke all on table privado.upload_verificacao_identidade
  from public, anon, authenticated, service_role;

create function privado.consumir_token_upload_verificacao(p_upload_id uuid, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_destino jsonb;
begin
  if p_upload_id is null or p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    return null;
  end if;

  -- Um UPDATE condicional faz o consumo e a revalidação na mesma trava de linha. Depois
  -- do commit do vencedor, uma segunda conexão reavalia usado_em e não recebe destino.
  update privado.upload_verificacao_identidade u
     set usado_em = privado.agora()
    from privado.verificacao_identidade v
    join public.usuario conta on conta.id = v.usuario_id
   where u.id = p_upload_id
     and u.verificacao_id = v.id
     and u.token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
     and u.usado_em is null
     and u.expira_em > privado.agora()
     and v.status = 'pendente'
     and conta.estado <> 'anonimizada'
     and u.storage_path = case u.parte
           when 'frente' then v.storage_path_frente
           when 'verso'  then v.storage_path_verso
           when 'selfie' then v.storage_path_selfie
         end
  returning jsonb_build_object(
    'bucket', 'documentos-identidade',
    'storage_path', u.storage_path,
    'parte', u.parte
  ) into v_destino;

  return v_destino;
end $$;

comment on function privado.consumir_token_upload_verificacao(uuid, text) is
  'Consome atomicamente o token opaco de uma parte da RN14 e devolve bucket, caminho e parte, ou NULL. Revalida prazo, uso único, verificação pendente, conta não anonimizada e o caminho vigente da parte. Conta suspensa continua válida durante a apuração.';

revoke all on function privado.consumir_token_upload_verificacao(uuid, text)
  from public, anon, authenticated;
grant execute on function privado.consumir_token_upload_verificacao(uuid, text)
  to service_role;
