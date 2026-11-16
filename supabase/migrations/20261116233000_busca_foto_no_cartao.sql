-- Busca de profissionais, PR 3 (B-027.h; contrato 0.2.90, frila-documentacao #262 e07eb45): a foto aprovada vai
-- no cartão da busca (decisão do Cauê, pedido 2026-11-16-13, CD-B07), e o vínculo pela busca, com o aceite dos
-- Termos 1.1, passa a abrir também a foto no perfil_publico (no PR 2 ele só abria o perfil rico).
--
--   1. privado.profissional_na_busca_do_leitor(profissional, leitor): o fato "este profissional está na busca
--      deste contratante" num lugar só: o leitor é membro de uma casa, aceitou os Termos 1.1, as chaves
--      busca_profissionais e chamada_direta estão ligadas e o profissional ligou "Aceito chamadas diretas"
--      (com ou sem pausa, como o caso 5 de privado.contratante_com_vinculo_leitura), com conta ativa e da
--      mesma população (demonstração não vaza para real nem o contrário). O leitor vem por parâmetro, nunca de
--      auth.uid(): a ler-midia chama o resolvedor como service_role, sem sessão.
--   2. privado.vinculo_de_leitura_da_foto ganha esse caso na foto de PROFISSIONAL. É o ÚNICO ponto que decide a
--      foto: a projeção (perfil_publico, candidatos_da_vaga, detalhe_chamada, o cartão) e o resolvedor do link
--      (privado.resolver_link_leitura_midia, que reconfere a cada leitura, no 1 h de vida do link) o usam.
--      Foto de estabelecimento não muda. A regra do recurso foto_de_perfil, da foto aprovada e do titular ativo
--      segue em privado.foto_legivel, que esta migração não toca; bloqueio (RF26) segue no resolvedor.
--   3. privado.cartao_profissional ganha foto_url e foto_id por privado.foto_do_cartao, que confere o mesmo que a
--      projeção do perfil (foto aprovada, recurso foto_de_perfil, titular ativo e o vínculo da foto acima), lendo
--      o leitor de auth.uid(). Sem foto aprovada, ou com o recurso desligado: as duas chaves AUSENTES, como no
--      PerfilPublico. A lista de campos continua explícita. A função passa de STABLE para VOLATILE (grava o hash
--      do link); o único chamador, buscar_profissionais, já é volátil e é chamado por POST.
--   3b. O link do cartão é REUSADO, não cunhado a cada página (parecer do Lince Opus, I1: o cursor reenviado
--      gravava até 20 linhas por requisição). O banco guarda só o SHA-256 do token (B-020), então "reusar" é
--      derivar o MESMO token: HMAC-SHA256 de (mídia, leitor, janela de 30 min) com uma chave PRÓPRIA do link,
--      derivada da chave do cursor da busca (HMAC de 'link-foto-cartao' com ela), que vive só no banco: cursor e
--      link não compartilham a chave. Dentro da janela o mesmo (mídia, leitor) tem o mesmo token e o insert não faz nada
--      (on conflict); o link vence no fim da janela seguinte, então o que se devolve vale de 30 a 60 min. Perto de
--      vencer (menos de 30 min), a janela seguinte dá um token novo. O resolvedor da ler-midia não muda: lê o
--      mesmo hash, a mesma validade e o mesmo teto de 120 GETs por token; como o token é o mesmo na janela, o teto
--      passa a valer por (mídia, leitor, janela), não por página.
--      A assinatura não muda, então a buscar_profissionais do PR 3 (20261116230000) segue valendo como está.
--   Não muda: privado.foto_legivel, a projeção, o resolvedor, as RPCs públicas.

select set_config('lock_timeout', '2s', true);

-- ── 1. O profissional está na busca deste contratante ─────────────────────────
create function privado.profissional_na_busca_do_leitor(p_profissional uuid, p_leitor uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_profissional is not null and p_leitor is not null
     and privado.recurso_ligado('busca_profissionais')
     and privado.recurso_ligado('chamada_direta')
     and exists (select 1 from public.membro_estabelecimento me where me.usuario_id = p_leitor)
     and privado.aceitou_termos(p_leitor, privado.termos_minimos_da_busca())
     and exists (select 1
                   from public.profissional_preferencia_chamada pc
                   join public.profissional pr on pr.id = pc.profissional_id
                   join public.usuario u on u.id = pr.usuario_id
                  where pc.profissional_id = p_profissional
                    and pc.aceita_chamadas
                    and u.estado = 'ativa'
                    and coalesce(u.demonstracao, false)
                        = coalesce((select l.demonstracao from public.usuario l where l.id = p_leitor), false))
$$;
comment on function privado.profissional_na_busca_do_leitor(uuid, uuid) is
  'O profissional está na busca deste contratante (0.2.90): o leitor é membro de uma casa e aceitou os Termos 1.1, as chaves busca_profissionais e chamada_direta estão ligadas, e o profissional ligou "Aceito chamadas diretas" (com ou sem pausa), conta ativa, mesma população. O leitor vem por parâmetro (a ler-midia roda sem sessão). Abre a foto, como o caso 5 abre o perfil rico.';
revoke all on function privado.profissional_na_busca_do_leitor(uuid, uuid) from public, anon, authenticated;
grant execute on function privado.profissional_na_busca_do_leitor(uuid, uuid) to service_role;

-- ── 2. O vínculo de leitura da foto (corpo de 20261114003000, mais o caso da busca) ─
create or replace function privado.vinculo_de_leitura_da_foto(
  p_profissional    uuid,
  p_estabelecimento uuid,
  p_leitor          uuid
) returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when p_leitor is null or (p_profissional is null) = (p_estabelecimento is null) then false
    when p_profissional is not null then exists (
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
         ))
       -- 0.2.90: o profissional na busca ("Aceito chamadas diretas") abre a foto para o contratante que aceitou os Termos 1.1.
       or privado.profissional_na_busca_do_leitor(p_profissional, p_leitor)
    else exists (
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
         ))
  end
$$;
comment on function privado.vinculo_de_leitura_da_foto(uuid, uuid, uuid) is
  'Vínculo de leitura da foto (contrato 0.2.54 e 0.2.90): foto de profissional, para contratante de casa com equipe, candidatura, turno ou, desde a 0.2.90, o profissional na busca (com os Termos 1.1 aceitos); foto de estabelecimento, para profissional com candidatura, chamada ou turno (B-020). Usado pela projeção e pelo resolvedor do link.';

-- ── 2b. O link do cartão: o mesmo token dentro da janela de 30 min ────────────
create function privado.cunhar_link_foto_cartao(p_midia_id uuid, p_leitor uuid)
returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_janela bigint := floor(extract(epoch from privado.agora()) / 1800);
  v_chave  bytea;   -- chave PRÓPRIA do link do cartão, derivada da do cursor (usos separados)
  v_token  text;
  v_n      int;
begin
  if p_midia_id is null or p_leitor is null then return null; end if;
  -- Como em cunhar_link_leitura_midia: em transação só-leitura o INSERT do hash falharia; ali o link não sai.
  if current_setting('transaction_read_only') = 'on' then return null; end if;
  select extensions.hmac(convert_to('link-foto-cartao', 'UTF8'), k.chave, 'sha256') into v_chave
    from privado.chave_cursor_busca k limit 1;
  if v_chave is null then return null; end if;

  v_token := encode(extensions.hmac(
               convert_to('foto-cartao|' || p_midia_id || '|' || p_leitor || '|' || v_janela, 'UTF8'), v_chave, 'sha256'), 'hex');

  -- Vence no fim da janela seguinte: quem lê na janela recebe de 30 a 60 min de validade.
  insert into privado.midia_link_leitura (token_hash, midia_id, leitor_id, expira_em)
  values (encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), p_midia_id, p_leitor,
          to_timestamp((v_janela + 2) * 1800))
  on conflict (token_hash) do nothing;
  get diagnostics v_n = row_count;

  -- A limpeza dos vencidos só roda quando entrou linha nova (o reenvio do cursor não grava nem apaga nada).
  if v_n > 0 then
    delete from privado.midia_link_leitura l
     where l.token_hash in (select v.token_hash from privado.midia_link_leitura v
                             where v.expira_em <= privado.agora()
                             limit 500 for update skip locked);
  end if;

  return privado.url_ler_midia() || '?midia_id=' || p_midia_id || '&token=' || v_token;
end $$;
comment on function privado.cunhar_link_foto_cartao(uuid, uuid) is
  'Link de leitura da foto para o cartão da busca: o token é o HMAC da (mídia, leitor, janela de 30 min) com uma chave própria do link (derivada da do cursor), então o mesmo cartão relido na janela devolve o mesmo link sem gravar outra linha, e o link vale de 30 a 60 min. O teto de 120 GETs da ler-midia vale por token, ou seja, por (mídia, leitor, janela). Não confere vínculo: quem chama confere antes (privado.foto_do_cartao).';
revoke execute on function privado.cunhar_link_foto_cartao(uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.cunhar_link_foto_cartao(uuid, uuid) to service_role;

-- A foto do cartão: as mesmas condições da projeção do perfil (foto_de_perfil_projecao), com o link acima.
create function privado.foto_do_cartao(p_profissional uuid, p_leitor uuid)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_m   privado.midia;
  v_url text;
begin
  if p_profissional is null or p_leitor is null then return '{}'::jsonb; end if;
  select m.* into v_m
    from privado.midia m
    join public.profissional p on p.usuario_id = m.dono_usuario_id
   where p.id = p_profissional
     and m.dono_tipo = 'profissional' and m.tipo = 'foto_perfil' and m.estado = 'aprovada'
   limit 1;
  if not found then return '{}'::jsonb; end if;
  if not privado.foto_legivel(v_m) then return '{}'::jsonb; end if;
  if not privado.vinculo_de_leitura_da_foto(p_profissional, null, p_leitor) then return '{}'::jsonb; end if;
  v_url := privado.cunhar_link_foto_cartao(v_m.id, p_leitor);
  if v_url is null then return '{}'::jsonb; end if;   -- transação só-leitura: as duas chaves saem juntas ou nenhuma
  return jsonb_build_object('foto_id', v_m.id, 'foto_url', v_url);
end $$;
comment on function privado.foto_do_cartao(uuid, uuid) is
  'foto_id e foto_url do CartaoProfissional (contrato 0.2.90), ou {}: foto aprovada, recurso foto_de_perfil ligado, titular ativo e o vínculo de leitura da foto (que inclui a busca com os Termos 1.1). O link é o do cartão, reusado na janela de 30 min.';
revoke execute on function privado.foto_do_cartao(uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.foto_do_cartao(uuid, uuid) to service_role;

-- ── 3. O cartão da busca com a foto (corpo de 20261116210000, mais a projeção) ──
create or replace function privado.cartao_profissional(
  p_profissional uuid, p_funcao uuid, p_faixa smallint, p_cobre boolean, p_com_horario boolean
)
returns jsonb
language sql volatile security definer set search_path = ''
as $$
  select jsonb_build_object(
    'id', p.id,
    'nome', privado.nome_curto(u.nome),
    -- O serviço da função buscada (ServicoNoPerfil).
    'servico', (select jsonb_strip_nulls(jsonb_build_object(
                         'unidade',            s.unidade,
                         'valor_centavos',     s.valor_centavos,
                         'valor_max_centavos', s.valor_max_centavos,
                         'horas_incluidas',    s.horas_incluidas,
                         'minimo_horas',       s.minimo_horas,
                         'minimo_pessoas',     s.minimo_pessoas,
                         'ate_pessoas',        s.ate_pessoas,
                         'duracao_tipica_h',   s.duracao_tipica_h,
                         'descricao_pacote',   s.descricao_pacote,
                         'inclui',             s.inclui,
                         'leva_material',      s.leva_material))
                       || jsonb_build_object(
                            'funcao', jsonb_build_object(
                              'id', f.id, 'nome', f.nome, 'categoria', f.categoria,
                              'formato_padrao', f.formato_padrao, 'grupo_busca', f.grupo_busca,
                              'dica_perfil', f.dica_perfil, 'exemplo_perfil', f.exemplo_perfil),
                            'especialidades', coalesce((select jsonb_agg(jsonb_build_object(
                                                                 'id', e.id, 'funcao_id', e.funcao_id,
                                                                 'nome', e.nome, 'ativo', e.ativo) order by e.nome)
                                                          from public.profissional_servico_especialidade se
                                                          join public.especialidade e on e.id = se.especialidade_id
                                                         where se.profissional_id = s.profissional_id
                                                           and se.funcao_id = s.funcao_id), '[]'::jsonb))
                  from public.profissional_servico s join public.funcao f on f.id = s.funcao_id
                 where s.profissional_id = p.id and s.funcao_id = p_funcao),
    'regioes', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'numero', r.numero,
                                                             'nome', r.nome, 'ativo', r.ativo) order by r.id)
                           from public.profissional_regiao pr
                           join public.regiao_administrativa r on r.id = pr.regiao_id
                          where pr.profissional_id = p.id), '[]'::jsonb),
    'atende_todo_df', p.atende_todo_df,
    'distancia_faixa', case p_faixa when 1 then 'ate_5_km' when 2 then 'de_5_a_15_km' else 'mais_de_15_km' end,
    'reputacao', privado.reputacao_profissional(p.id)
  ) || case when p_com_horario then jsonb_build_object('disponivel_no_horario', p_cobre) else '{}'::jsonb end
    -- A foto aprovada, se houver (0.2.90, CD-B07): as MESMAS condições da projeção do perfil (recurso foto_de_perfil, foto
    -- aprovada, titular ativo, vínculo), com o link da ler-midia reusado na janela de 30 min. Sem foto: '{}', e as chaves ficam ausentes.
    || privado.foto_do_cartao(p.id, (select auth.uid()))
    from public.profissional p
    join public.usuario u on u.id = p.usuario_id
   where p.id = p_profissional
$$;
comment on function privado.cartao_profissional(uuid, uuid, smallint, boolean, boolean) is
  'CartaoProfissional de buscar_profissionais (contrato 0.2.88 e 0.2.90, CD-B07), por lista explícita de campos: id, nome curto, o serviço da função, regiões, todo o DF, faixa de distância, reputação com denominador, com horário o selo da grade e, desde a 0.2.90, a foto aprovada (foto_url e foto_id, as condições do perfil; ausentes sem foto). Nunca contato, ponto base nem nascimento (CD-S03). Volátil: a projeção grava o hash do link.';
