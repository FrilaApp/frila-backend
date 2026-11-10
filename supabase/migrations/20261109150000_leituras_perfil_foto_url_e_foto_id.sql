-- As leituras de perfil projetam foto_url e foto_id (contrato 0.2.54, cartão ZgK6KacD).
--
-- O contrato declara `PerfilPublico.foto_url` e `foto_id`, opcionais, e as três leituras que
-- devolvem um PerfilPublico (`perfil_publico`, `candidatos_da_vaga` e `detalhe_chamada`) não os
-- projetavam: a foto aprovada existia em `privado.midia` e nenhuma leitura a entregava.
--
-- Os dois campos saem juntos, ou nenhum sai (ausente, e o resto do perfil responde como antes),
-- e só quando TODAS estas condições valem:
--   1. o recurso `foto_de_perfil` está ligado (`privado.configuracao_app.foto_de_perfil`, a mesma
--      chave que `solicitar_upload_midia` confere; `privado.recurso` não tem essa linha);
--   2. existe foto `aprovada` do titular em `privado.midia`;
--   3. o titular da foto (`dono_usuario_id`) não está suspenso (RN13) nem com a conta encerrada
--      (RF25): `usuario.estado = 'ativa'`;
--   4. o leitor tem vínculo de leitura. Foto de profissional: contratante membro de uma casa com
--      o profissional na equipe de confiança, com candidatura em vaga da casa ou com turno. Foto
--      de estabelecimento: profissional com candidatura, chamada ou turno com a casa.
--   5. o Storage assinou: sem o segredo `storage_jwt_secret` no Vault a foto NÃO sai, e a leitura
--      do perfil continua funcionando. Falhar a leitura inteira por causa de uma miniatura seria
--      um modo de falha pior que o defeito corrigido.
--
-- `foto_url` é a URL assinada por 1 hora da MINIATURA (`perfil/<midia_id>_thumb.jpg`, gerada por
-- `moderar-midia`), no formato que o Storage emite: `/object/sign/<bucket>/<caminho>?token=` com
-- token HS256 `{url, scope: 'download', iat, exp}` (medido em 08/11/2026 contra o Storage local).
-- O caminho do arquivo original (`storage_path`) nunca sai (RN15).
--
-- O vínculo de foto NÃO inclui chamada direta quando o leitor é contratante e a foto é de
-- profissional, porque é assim que o contrato 0.2.54 o define; `contratante_com_vinculo_leitura`,
-- do perfil rico, inclui. A assimetria está de propósito e vai para decisão do produto.
--
-- Nenhuma assinatura pública muda; as três funções só ganham as chaves opcionais.

select set_config('lock_timeout', '2s', true);

-- ── 1. Token de leitura do Storage ────────────────────────────────────────────
create or replace function privado.token_de_leitura_storage(
  p_bucket   text,
  p_caminho  text,
  p_segundos integer default 3600
) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_segredo    text;
  v_cabecalho  text;
  v_carga      text;
  v_agora      bigint;
begin
  select decrypted_secret into v_segredo
    from vault.decrypted_secrets where name = 'storage_jwt_secret' limit 1;
  -- Diferente do token de upload: aqui a ausência do segredo devolve nulo, e quem chama omite a
  -- foto. Leitura de perfil não pode cair por causa de URL de miniatura.
  if v_segredo is null or btrim(v_segredo) = '' then return null; end if;

  v_agora := floor(extract(epoch from privado.agora()))::bigint;
  v_cabecalho := privado.base64url(convert_to('{"alg":"HS256"}', 'utf8'));
  v_carga := privado.base64url(convert_to(
    json_build_object(
      'url',   p_bucket || '/' || p_caminho,
      'scope', 'download',
      'iat',   v_agora,
      'exp',   v_agora + greatest(p_segundos, 1)
    )::text, 'utf8'));

  return v_cabecalho || '.' || v_carga || '.'
         || privado.base64url(extensions.hmac(v_cabecalho || '.' || v_carga, v_segredo, 'sha256'));
end $$;
comment on function privado.token_de_leitura_storage(text, text, integer) is
  'Token de leitura assinado para o Storage (HS256 com storage_jwt_secret do Vault), no formato de POST /storage/v1/object/sign medido em 08/11/2026. Nulo quando o segredo falta (cartão ZgK6KacD).';
revoke execute on function privado.token_de_leitura_storage(text, text, integer) from public, anon, authenticated;
grant  execute on function privado.token_de_leitura_storage(text, text, integer) to service_role;

-- ── 2. A projeção da foto ─────────────────────────────────────────────────────
-- Exatamente um entre p_profissional e p_estabelecimento. Devolve `{foto_id, foto_url}` ou `{}`.
create or replace function privado.foto_de_perfil_projecao(
  p_profissional    uuid,
  p_estabelecimento uuid,
  p_leitor          uuid
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_m       privado.midia;
  v_vinculo boolean;
  v_caminho text;
  v_token   text;
  v_base    text;
begin
  if p_leitor is null or (p_profissional is null) = (p_estabelecimento is null) then
    return '{}'::jsonb;
  end if;

  if not coalesce((select bool_or(c.foto_de_perfil) from privado.configuracao_app c), false) then
    return '{}'::jsonb;
  end if;

  if p_profissional is not null then
    select m.* into v_m
      from privado.midia m
      join public.profissional p on p.usuario_id = m.dono_usuario_id
     where p.id = p_profissional
       and m.dono_tipo = 'profissional' and m.tipo = 'foto_perfil' and m.estado = 'aprovada'
     limit 1;
  else
    select m.* into v_m
      from privado.midia m
     where m.estabelecimento_id = p_estabelecimento
       and m.dono_tipo = 'estabelecimento' and m.tipo = 'foto_perfil' and m.estado = 'aprovada'
     limit 1;
  end if;
  if not found then return '{}'::jsonb; end if;

  -- RN13 e RF25: o titular precisa estar ativo.
  if not exists (select 1 from public.usuario u where u.id = v_m.dono_usuario_id and u.estado = 'ativa') then
    return '{}'::jsonb;
  end if;

  if p_profissional is not null then
    v_vinculo := exists (
      select 1
        from public.membro_estabelecimento me
       where me.usuario_id = p_leitor
         and (
           exists (select 1 from public.equipe_confianca ec
                    where ec.estabelecimento_id = me.estabelecimento_id
                      and ec.profissional_id = p_profissional)
           or exists (select 1 from public.candidatura c
                        join public.posicao pos on pos.id = c.posicao_id
                        join public.vaga v on v.id = pos.vaga_id
                       where v.estabelecimento_id = me.estabelecimento_id
                         and c.profissional_id = p_profissional)
           or exists (select 1 from public.posicao pos
                        join public.vaga v on v.id = pos.vaga_id
                       where v.estabelecimento_id = me.estabelecimento_id
                         and pos.profissional_id = p_profissional)
         ));
  else
    v_vinculo := exists (
      select 1
        from public.profissional pr
       where pr.usuario_id = p_leitor
         and (
           exists (select 1 from public.candidatura c
                     join public.posicao pos on pos.id = c.posicao_id
                     join public.vaga v on v.id = pos.vaga_id
                    where v.estabelecimento_id = p_estabelecimento
                      and c.profissional_id = pr.id)
           or exists (select 1 from public.chamada ch
                       where ch.estabelecimento_id = p_estabelecimento
                         and ch.profissional_id = pr.id)
           or exists (select 1 from public.posicao pos
                        join public.vaga v on v.id = pos.vaga_id
                       where v.estabelecimento_id = p_estabelecimento
                         and pos.profissional_id = pr.id)
         ));
  end if;
  if not v_vinculo then return '{}'::jsonb; end if;

  v_caminho := replace(v_m.storage_path, '.jpg', '_thumb.jpg');
  v_token := privado.token_de_leitura_storage('midia-perfil', v_caminho, 3600);
  if v_token is null then return '{}'::jsonb; end if;

  v_base := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'storage_url' limit 1),
    nullif(current_setting('frila.storage_url', true), ''),
    'http://127.0.0.1:54321/storage/v1');

  return jsonb_build_object(
    'foto_id',  v_m.id,
    'foto_url', rtrim(v_base, '/') || '/object/sign/midia-perfil/' || v_caminho || '?token=' || v_token);
end $$;
comment on function privado.foto_de_perfil_projecao(uuid, uuid, uuid) is
  'As chaves foto_id e foto_url do PerfilPublico (contrato 0.2.54), ou {}: recurso foto_de_perfil ligado, foto aprovada, titular ativo (RN13, RF25), vínculo de leitura e segredo do Storage presente. Nunca devolve storage_path (cartão ZgK6KacD).';
revoke execute on function privado.foto_de_perfil_projecao(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.foto_de_perfil_projecao(uuid, uuid, uuid) to service_role;

-- ── 3. public.perfil_publico ──────────────────────────────────────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.perfil_publico 0.2.68
create or replace function public.perfil_publico(id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid       uuid := (select auth.uid());
  v_prof_user uuid;
  v_perfil    jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'anonimizada') then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- 1. Perfil profissional
  v_prof_user := privado.usuario_do_profissional(perfil_publico.id);
  if v_prof_user is not null then
    -- RF26: bloqueio nos dois sentidos entre quem chama e o profissional,
    -- ou entre o profissional e qualquer estabelecimento do qual quem chama é membro.
    if exists (
      select 1 from public.bloqueio b
       where (b.autor_id = v_uid and b.bloqueado_id = v_prof_user)
          or (b.autor_id = v_prof_user and b.bloqueado_id = v_uid)
    ) or exists (
      select 1 from public.membro_estabelecimento m
       where m.usuario_id = v_uid
         and privado.bloqueado_com_estabelecimento(v_prof_user, m.estabelecimento_id)
    ) then
      perform public.erro(404, 'nao_encontrado');
    end if;

    v_perfil := privado.perfil_publico_profissional(perfil_publico.id)
                || privado.foto_de_perfil_projecao(perfil_publico.id, null, v_uid);

  -- 2. Perfil de estabelecimento
  elsif exists (select 1 from public.estabelecimento e where e.id = perfil_publico.id) then
    -- RF26: bloqueio com qualquer membro do estabelecimento nos dois sentidos.
    if privado.bloqueado_com_estabelecimento(v_uid, perfil_publico.id) then
      perform public.erro(404, 'nao_encontrado');
    end if;

    v_perfil := privado.estabelecimento_publico(perfil_publico.id)
                || privado.foto_de_perfil_projecao(null, perfil_publico.id, v_uid);
  end if;

  -- 3. Id que não é profissional nem estabelecimento (ou não encontrado)
  if v_perfil is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  return v_perfil;
end $$;

-- ── 4. public.candidatos_da_vaga ──────────────────────────────────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.candidatos_da_vaga 0.2.68
create or replace function public.candidatos_da_vaga(vaga_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid   uuid := (select auth.uid());
  v_estab uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('contratante');

  if candidatos_da_vaga.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  select estabelecimento_id into v_estab
    from public.vaga
   where id = candidatos_da_vaga.vaga_id;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if not privado.eh_membro(v_estab) then
    perform public.erro(403, 'sem_permissao');
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'candidatura_id', c.id,
             'profissional',   privado.perfil_publico_profissional(c.profissional_id)
                                 || privado.foto_de_perfil_projecao(c.profissional_id, null, v_uid),
             'da_equipe',      exists(
                                 select 1
                                   from public.equipe_confianca ec
                                  where ec.estabelecimento_id = v_estab
                                    and ec.profissional_id = c.profissional_id
                               ),
             'criada_em',      c.criada_em)
           order by c.criada_em, c.id)
      from public.candidatura c
      join public.posicao x on x.id = c.posicao_id
     where x.vaga_id = candidatos_da_vaga.vaga_id
       and c.estado = 'pendente'
       and not privado.bloqueado_com_estabelecimento(
             privado.usuario_do_profissional(c.profissional_id),
             v_estab)), '[]'::jsonb);
end $$;

-- ── 5. public.detalhe_chamada ─────────────────────────────────────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.detalhe_chamada 0.2.68

create or replace function public.detalhe_chamada(chamada_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid         uuid := (select auth.uid());
  v_c           public.chamada%rowtype;
  v_v           public.vaga%rowtype;
  v_f           public.funcao%rowtype;
  v_e           public.estabelecimento%rowtype;
  v_prof        public.profissional%rowtype;
  v_eh_prof     boolean := false;
  v_eh_membro   boolean := false;
  v_dist_m      double precision;
  v_faixa       text := null;
  v_conta_nova  boolean;
  v_outra_parte jsonb;
  v_res         jsonb;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
  -- Conta anonimizada (excluída) é 401 e suspensa é 403, pela mesma porta das outras RPCs (RF25,
  -- RN13). O JWT pode seguir válido depois da exclusão: a recusa tem de vir do banco.
  perform privado.exigir_conta_ativa();
  if detalhe_chamada.chamada_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'chamada_id');
  end if;

  select * into v_c from public.chamada where id = detalhe_chamada.chamada_id;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;

  select * into v_v from public.vaga where id = v_c.vaga_id;
  select * into v_f from public.funcao where id = v_v.funcao_id;
  select * into v_e from public.estabelecimento where id = v_c.estabelecimento_id;
  select * into v_prof from public.profissional where id = v_c.profissional_id;

  if v_prof.usuario_id = v_uid then v_eh_prof := true; end if;
  if privado.eh_membro(v_c.estabelecimento_id) then v_eh_membro := true; end if;

  -- Apenas as partes autorizadas e sem bloqueio mútuo (RF26)
  if (not v_eh_prof and not v_eh_membro)
     or privado.bloqueado_com_estabelecimento(v_prof.usuario_id, v_c.estabelecimento_id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Conta nova se estabelecimento não tem turnos cumpridos/verificados
  v_conta_nova := not exists (
    select 1 from public.turno t
      join public.posicao pos on pos.id = t.posicao_id
      join public.vaga vg on vg.id = pos.vaga_id
     where vg.estabelecimento_id = v_c.estabelecimento_id
       and pos.estado = 'cumprida'
       and t.verificacao = 'verificado'
  );

  if v_eh_prof then
    v_outra_parte := privado.estabelecimento_publico(v_c.estabelecimento_id)
                     || privado.foto_de_perfil_projecao(null, v_c.estabelecimento_id, v_uid);
    if v_prof.ponto_base is not null and v_v.ponto is not null then
      v_dist_m := extensions.st_distance(v_prof.ponto_base, v_v.ponto);
      if v_dist_m <= 5000 then v_faixa := 'ate_5_km';
      elsif v_dist_m <= 15000 then v_faixa := 'de_5_a_15_km';
      else v_faixa := 'mais_de_15_km'; end if;
    end if;
  else
    v_outra_parte := privado.perfil_publico_profissional(v_c.profissional_id)
                     || privado.foto_de_perfil_projecao(v_c.profissional_id, null, v_uid);
  end if;

  v_res := jsonb_build_object(
    'id',                     v_c.id,
    'vaga_id',                v_c.vaga_id,
    'profissional_id',        v_c.profissional_id,
    'estabelecimento_id',     v_c.estabelecimento_id,
    'estado',                 v_c.estado,
    'recado',                 v_c.recado,
    'motivo_recusa',          v_c.motivo_recusa,
    'expira_em',              v_c.expira_em,
    'respondida_em',          v_c.respondida_em,
    'criada_em',              v_c.criada_em,
    'funcao',                 jsonb_build_object('id', v_f.id, 'nome', v_f.nome, 'categoria', v_f.categoria),
    'inicio_em',              v_v.inicio_em,
    'fim_em',                 v_v.fim_em,
    'valor_centavos',         v_v.valor_centavos,
    'outra_parte',            v_outra_parte,
    'tipo_estabelecimento',   v_e.tipo,
    'conta_nova',             v_conta_nova,
    'regiao_administrativa',  v_v.regiao_administrativa,
    'distancia_faixa',        v_faixa,
    'inclui_refeicao',        v_v.inclui_refeicao,
    'inclui_transporte',      v_v.inclui_transporte,
    'exige_material_proprio', v_v.exige_material_proprio
  );

  -- Endereço e ponto só liberados com estado = 'aceita' (RN36). Nunca telefone.
  if v_c.estado = 'aceita' then
    v_res := v_res || jsonb_build_object(
      'local',             v_v.local,
      'ponto',             privado.ponto_em_json(v_v.ponto),
      'responsavel_local', v_v.responsavel_local
    );
  end if;

  return v_res;
end $$;

-- Os privilégios das três funções não mudam: `create or replace` os preserva.
comment on function public.perfil_publico(uuid) is
  'Perfil público de profissional ou estabelecimento por id. Profissional ganha campos ricos da F2 se quem lê tem vínculo legítimo; foto_url e foto_id (0.2.54) só com vínculo de leitura, recurso ligado, foto aprovada e titular ativo. Devolve 404 para id inexistente e para bloqueio mútuo.';
comment on function public.candidatos_da_vaga(uuid) is
  'Modo seleção: lista os candidatos pendentes na ordem de chegada (RN06) com flag da_equipe (0.2.38), projeção de perfil rico (0.2.53) e foto_url/foto_id do candidato (0.2.54, mesmas condições de perfil_publico), ocultando profissionais com bloqueio mútuo com o estabelecimento.';
comment on function public.detalhe_chamada(uuid) is
  'A chamada por inteiro (0.2.56), para as duas partes. A outra parte vem com foto_url/foto_id (0.2.54) quando as condições de perfil_publico valem.';
