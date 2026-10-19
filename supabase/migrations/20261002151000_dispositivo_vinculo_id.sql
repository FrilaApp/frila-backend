-- Vínculo do aparelho com a conta no push e no registro de dispositivo (RN15, 0.2.30).
-- Cartão FmgMnRx4.
--
-- O push leva tipo e ids do destino, e até a 0.2.29 não dizia para quem era. Num
-- aparelho em que uma conta sai e outra entra, o aviso mandado à primeira e
-- entregue depois da troca chegava ao app sem nada que o distinguisse.
--
-- O vinculo_id é um UUID opaco:
--   - gerado no primeiro registro do token FCM;
--   - mantido no registro repetido pela mesma conta;
--   - regenerado quando o token passa de uma conta para outra;
--   - encerrado na saída (remover_dispositivo): o registro seguinte gera novo id.

alter table public.dispositivo
  add column vinculo_id uuid not null default gen_random_uuid();

comment on column public.dispositivo.vinculo_id is
  'Vínculo opaco do aparelho com a conta (RN15, 0.2.30). Muda na troca de conta e na remoção/re-registro; estável no registro repetido da mesma conta.';

create or replace function public.registrar_dispositivo(
  token_fcm  text default null,
  plataforma text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid        uuid := (select auth.uid());
  v_agora      timestamptz := privado.agora();
  v_plataforma public.plataforma;
  v_token      text;
  v_disp       public.dispositivo%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  if registrar_dispositivo.token_fcm is null
     or pg_catalog.btrim(registrar_dispositivo.token_fcm) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'token_fcm');
  end if;

  v_token := pg_catalog.btrim(registrar_dispositivo.token_fcm);

  if pg_catalog.length(v_token) < 20 then
    perform public.erro(422, 'campo_invalido', 'token_fcm');
  end if;

  if registrar_dispositivo.plataforma is null
     or pg_catalog.btrim(registrar_dispositivo.plataforma) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'plataforma');
  end if;

  if not registrar_dispositivo.plataforma
         = any (pg_catalog.enum_range(null::public.plataforma)::text[]) then
    perform public.erro(422, 'campo_invalido', 'plataforma');
  end if;

  v_plataforma := registrar_dispositivo.plataforma::public.plataforma;

  -- Grava ou atualiza mantendo unicidade pelo token_fcm.
  -- Se o aparelho já estava registrado para outra conta, troca o dono e gera novo vinculo_id (RN15, 0.2.30).
  -- Se o mesmo aparelho for reenviado pela mesma conta, preserva o vinculo_id existente.
  insert into public.dispositivo (usuario_id, token_fcm, plataforma, atualizado_em, vinculo_id)
  values (v_uid, v_token, v_plataforma, v_agora, gen_random_uuid())
  on conflict (token_fcm) do update
    set usuario_id    = excluded.usuario_id,
        plataforma    = excluded.plataforma,
        atualizado_em = excluded.atualizado_em,
        vinculo_id    = case
          when public.dispositivo.usuario_id = excluded.usuario_id then public.dispositivo.vinculo_id
          else gen_random_uuid()
        end
  returning * into v_disp;

  return pg_catalog.jsonb_build_object(
    'plataforma',    v_disp.plataforma,
    'atualizado_em', v_disp.atualizado_em,
    'vinculo_id',    v_disp.vinculo_id
  );
end $$;

comment on function public.registrar_dispositivo(text, text) is
  'Registra ou atualiza o token de push do aparelho (RF06, RNF02, RN15). Idempotente: mesmo token atualiza a data e transfere de conta em caso de troca de dono no mesmo aparelho. Retorna {plataforma, atualizado_em, vinculo_id} conforme o contrato Dispositivo 0.2.30. Exige conta ativa.';

revoke execute on function public.registrar_dispositivo(text, text) from public, anon;
grant  execute on function public.registrar_dispositivo(text, text) to authenticated;
