-- Denúncia vinculada à chamada direta (CD-S13, contrato 0.2.71, cartão AGkBFg9a).
--
-- 1. Coluna chamada_id em public.ocorrencia referenciando public.chamada(id) on delete set null.
-- 2. public.denunciar aceita chamada_id opcional (UUID default null).
-- 3. Se chamada_id for informado: valida que a chamada existe e envolve tanto o denunciante
--    quanto o alvo (alvo_tipo + alvo_id). Se for inexistente ou de terceiros, recusa com
--    422 campo_invalido (details: chamada_id).
-- 4. Sigilo RN15: grava apenas a referência chamada_id em ocorrencia, nunca o recado ou texto.

select set_config('lock_timeout', '2s', true);

alter table public.ocorrencia
  add column if not exists chamada_id uuid references public.chamada(id) on delete set null;

create index if not exists idx_ocorrencia_chamada_id on public.ocorrencia(chamada_id) where chamada_id is not null;

drop function if exists public.denunciar(text, uuid, text, text, uuid, uuid, uuid);

create or replace function public.denunciar(
  alvo_tipo  text,
  alvo_id    uuid,
  motivo     text,
  relato     text,
  chave      uuid,
  turno_id   uuid default null,
  midia_id   uuid default null,
  chamada_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_tipo    text := denunciar.alvo_tipo;
  v_alvo    uuid := denunciar.alvo_id;
  v_motivo  text := btrim(denunciar.motivo);
  v_relato  text := btrim(denunciar.relato);
  v_chave   uuid := denunciar.chave;
  v_turno   uuid := denunciar.turno_id;
  v_midia   uuid := denunciar.midia_id;
  v_chamada uuid := denunciar.chamada_id;
  v_usuario uuid;
  v_estab   uuid;
  v_t_prof  uuid;
  v_t_estab uuid;
  v_c_prof  uuid;
  v_c_estab uuid;
  v_oc      public.ocorrencia%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  if v_chave is null then
    perform public.erro(422, 'campo_obrigatorio', 'chave');
  end if;

  select * into v_oc from public.ocorrencia o
   where o.autor_id = v_uid and o.chave_cliente = v_chave and o.tipo = 'denuncia';
  if found then
    return jsonb_build_object('ocorrencia_id', v_oc.id, 'tipo', 'denuncia',
                              'criada_em', v_oc.criada_em,
                              'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em));
  end if;

  if v_tipo is null then
    perform public.erro(422, 'campo_obrigatorio', 'alvo_tipo');
  end if;
  if v_alvo is null then
    perform public.erro(422, 'campo_obrigatorio', 'alvo_id');
  end if;
  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;
  if v_relato is null or v_relato = '' then
    perform public.erro(422, 'campo_obrigatorio', 'relato');
  end if;
  if v_tipo not in ('profissional', 'estabelecimento') then
    perform public.erro(422, 'campo_invalido', 'alvo_tipo');
  end if;
  if not (v_motivo = any (enum_range(null::public.motivo_denuncia)::text[])) then
    perform public.erro(422, 'campo_invalido', 'motivo');
  end if;
  if char_length(v_relato) < 10 then
    perform public.erro(422, 'campo_invalido', 'relato');
  end if;

  if v_tipo = 'estabelecimento' then
    select e.id into v_estab from public.estabelecimento e where e.id = v_alvo;
    if v_estab is null then
      perform public.erro(404, 'nao_encontrado');
    end if;
    if exists (select 1 from public.membro_estabelecimento m
                where m.estabelecimento_id = v_estab and m.usuario_id = v_uid) then
      perform public.erro(422, 'campo_invalido', 'alvo_id');
    end if;
  else
    select p.usuario_id into v_usuario from public.profissional p where p.id = v_alvo;
    if v_usuario is null then
      perform public.erro(404, 'nao_encontrado');
    end if;
    if v_usuario = v_uid then
      perform public.erro(422, 'campo_invalido', 'alvo_id');
    end if;
  end if;

  -- Validação de mídia quando informada (contrato 0.2.54)
  if v_midia is not null then
    if v_tipo = 'estabelecimento' then
      if not exists (
        select 1 from privado.midia m
         where m.id = v_midia
           and m.estabelecimento_id = v_estab
           and m.tipo = 'foto_perfil'
      ) then
        perform public.erro(422, 'campo_invalido', 'midia_id');
      end if;
    else
      if not exists (
        select 1 from privado.midia m
         where m.id = v_midia
           and m.dono_usuario_id = v_usuario
           and m.estabelecimento_id is null
           and m.tipo = 'foto_perfil'
      ) then
        perform public.erro(422, 'campo_invalido', 'midia_id');
      end if;
    end if;
  end if;

  -- Validação de chamada quando informada (contrato 0.2.71, CD-S13)
  if v_chamada is not null then
    select c.profissional_id, c.estabelecimento_id into v_c_prof, v_c_estab
      from public.chamada c
     where c.id = v_chamada;

    if not found
       or not (
         (v_tipo = 'estabelecimento'
            and v_c_estab = v_estab
            and exists (select 1 from public.profissional p
                         where p.id = v_c_prof and p.usuario_id = v_uid))
         or
         (v_tipo = 'profissional'
            and v_c_prof = v_alvo
            and exists (select 1 from public.membro_estabelecimento m
                         where m.estabelecimento_id = v_c_estab and m.usuario_id = v_uid))
       ) then
      perform public.erro(422, 'campo_invalido', 'chamada_id');
    end if;
  end if;

  if v_turno is not null then
    select p.profissional_id, v.estabelecimento_id into v_t_prof, v_t_estab
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga v    on v.id = p.vaga_id
     where t.id = v_turno;

    if not found
       or not (
         (v_estab is not null
            and v_t_estab = v_estab
            and exists (select 1 from public.profissional p
                         where p.id = v_t_prof and p.usuario_id = v_uid))
         or
         (v_usuario is not null
            and exists (select 1 from public.profissional p
                         where p.id = v_t_prof and p.usuario_id = v_usuario)
            and exists (select 1 from public.membro_estabelecimento m
                         where m.estabelecimento_id = v_t_estab and m.usuario_id = v_uid))
       ) then
      perform public.erro(404, 'nao_encontrado');
    end if;
  end if;

  insert into public.ocorrencia (
    tipo, turno_id, usuario_id, estabelecimento_id, autor_id,
    motivo, relato, chave_cliente, criada_em, midia_id, chamada_id
  ) values (
    'denuncia', v_turno, v_usuario, v_estab, v_uid,
    v_motivo::public.motivo_denuncia, v_relato, v_chave, privado.agora(), v_midia, v_chamada
  )
  on conflict (autor_id, chave_cliente) do nothing
  returning * into v_oc;

  if v_oc.id is null then
    select * into v_oc from public.ocorrencia o
     where o.autor_id = v_uid and o.chave_cliente = v_chave and o.tipo = 'denuncia';
  else
    perform pgmq.send('email', jsonb_build_object('tipo', 'denuncia', 'ocorrencia_id', v_oc.id));
  end if;

  return jsonb_build_object(
    'ocorrencia_id', v_oc.id,
    'tipo', 'denuncia',
    'criada_em', v_oc.criada_em,
    'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em)
  );
end $$;

comment on function public.denunciar(text, uuid, text, text, uuid, uuid, uuid, uuid) is
  'Registra denúncia contra a outra parte (RF26, RN13, RN15, UC17, CD-M07, CD-S13), opcionalmente vinculada a midia_id ou chamada_id, e enfileira o e-mail à Equipe Frila na fila email, só com o id (RN15). Idempotente pela chave do app. Devolve o Protocolo com prazo de 5 dias úteis.';

revoke execute on function public.denunciar(text, uuid, text, text, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.denunciar(text, uuid, text, text, uuid, uuid, uuid, uuid) to authenticated, service_role;
