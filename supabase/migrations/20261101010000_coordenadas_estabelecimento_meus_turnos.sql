-- Coordenadas exatas do estabelecimento em meus_turnos (Cartão 72 · RN06, RN22, v1.1 · Contrato 0.2.47)
--
-- Exposição de `vaga.ponto` (latitude/longitude) em `privado.turno_em_json` consumido por
-- `public.meus_turnos` e `privado.meus_dados`.
--
-- Regras de visibilidade e LGPD (opção mais restritiva):
-- 1. Membro do estabelecimento da vaga: lê as coordenadas de sua própria vaga normalmente.
-- 2. Profissional do turno:
--    - Turno confirmado (`posicao.estado = 'confirmada'`): coordenadas visíveis para deslocamento,
--      geofencing no Android e check-in geolocalizado a até 200m (LGPD art. 7º, V — execução de contrato).
--    - Turno cumprido verificado (`posicao.estado = 'cumprida'` e `verificacao = 'verificado'`):
--      coordenadas preservadas como prova da prestação do serviço (LGPD art. 7º, VI — exercício regular de direitos).
--    - Turno cancelado ou presença não verificada: coordenadas retornam NULO, respeitando o princípio
--      da necessidade e minimização (LGPD art. 6º, III).
-- 3. Terceiros: nunca têm acesso a turnos alheios via `meus_turnos` (lista vazia ou erro 403).

create or replace function privado.turno_em_json(turno uuid, autor uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id',         t.id,
    'posicao_id', t.posicao_id,
    'vaga', jsonb_build_object(
      'id',                    v.id,
      'funcao',                f.nome,
      'local',                 v.local,
      'regiao_administrativa', v.regiao_administrativa,
      'ponto',                 case
                                 -- 1. Membro do estabelecimento da vaga: lê coordenadas da própria casa
                                 when exists (
                                   select 1 from public.membro_estabelecimento m
                                    where m.estabelecimento_id = v.estabelecimento_id
                                      and m.usuario_id = autor
                                 )
                                   and v.ponto is not null
                                   then privado.ponto_em_json(v.ponto)
                                 -- 2. Profissional alocado no turno:
                                 --    - Visível enquanto confirmado (futuro / em andamento, LGPD art. 7º, V)
                                 --    - Visível se cumprido e presença verificada (LGPD art. 7º, VI)
                                 when privado.usuario_do_profissional(p.profissional_id) = autor
                                   and (
                                     p.estado = 'confirmada'
                                     or (p.estado = 'cumprida' and t.verificacao = 'verificado')
                                   )
                                   and v.ponto is not null
                                   then privado.ponto_em_json(v.ponto)
                                 -- 3. Nos demais casos (cancelado, não verificado, ou terceiros): nulo (LGPD art. 6º, III)
                                 else null
                               end,
      'inicio_em',             v.inicio_em,
      'fim_em',                v.fim_em,
      'valor_centavos',        v.valor_centavos),
    'contraparte', case
      when privado.usuario_do_profissional(p.profissional_id) = autor
        then privado.estabelecimento_publico(v.estabelecimento_id)
        else privado.perfil_publico_profissional(p.profissional_id) end,
    'contato_visivel_ate',     p.fim_em + interval '7 days',
    'a_caminho_em',            t.a_caminho_em,
    'checkin_em',              t.checkin_em,
    'checkin_tipo',            t.checkin_tipo,
    'checkin_distancia_m',     t.checkin_distancia_m,
    'checkin_confirmado_em',   t.checkin_confirmado_em,
    'checkout_em',             t.checkout_em,
    'checkout_distancia_m',    t.checkout_distancia_m,
    'verificacao',             t.verificacao,
    'valor_acordado_centavos', t.valor_acordado_centavos,
    'pode_avaliar',            privado.pode_avaliar(t.id, autor),
    'estado',                  p.estado,
    'avaliacao',               (
      select jsonb_build_object(
        'turno_id',  a.turno_id,
        'resposta',  a.resposta,
        'criada_em', a.criada_em
      )
      from public.avaliacao a
      where a.turno_id = t.id
        and a.alvo_tipo = case
          when privado.usuario_do_profissional(p.profissional_id) = autor then 'estabelecimento'
          else 'profissional'
        end
    ),
    'cancelamento',            case
                                 when p.estado = 'cancelada'
                                   then privado.cancelamento_do_turno(p.id)
                                 else null
                               end)
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v    on v.id = p.vaga_id
    join public.funcao f  on f.id = v.funcao_id
   where t.id = turno
$$;

comment on function privado.turno_em_json(uuid, uuid) is
  'Turno no schema do contrato (RF09, RF10, RN06, RN22, Cartão 72, contrato 0.2.47). Expõe vaga.ponto sob regras estritas de visibilidade LGPD (art. 7º, V e VI).';

revoke execute on function privado.turno_em_json(uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.turno_em_json(uuid, uuid) to service_role;

comment on function public.meus_turnos(timestamptz, timestamptz, uuid) is
  'Turnos do chamador como profissional, ou da casa quando vem estabelecimento_id (RF13, UC13, Cartão 72, contrato 0.2.47). vaga.ponto exposto sob regras de visibilidade. Sem telefone: o contato sai por contato_do_turno.';
