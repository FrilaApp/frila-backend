-- A vaga dentro de `Turno` não levava `origem`: o contrato já tem `VagaResumo.origem` (0.2.55, "ausente vale
-- `publicacao`"), mas `privado.turno_em_json` montava `vaga` sem a chave. No app, toda vaga direta
-- (`chamada_direta`) parecia vaga normal, e a tela de cancelar do profissional não tinha como distinguir.
--
-- Corpo de 20261126120000 com uma linha a mais: `'origem', v.origem` no objeto `vaga`. Vale para `meus_turnos` e para a
-- exportação (`privado.meus_dados`, coleção `turnos`), que usam esta função. Sem mudança de assinatura, de contrato nem
-- de RPC pública.

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
    'confirmado_em', p.confirmado_em,
    'vaga', jsonb_build_object(
      'id',                    v.id,
      'origem',                v.origem,
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
        -- 0.2.89: o nome segue o leitor (`autor`), não `auth.uid()`. A exportação (`privado.meus_dados`) roda pelo
        -- service_role, sem JWT; sem isto o nome saía curto ("Maria L.") para o contratante com turno (#519).
        else privado.perfil_publico_profissional(p.profissional_id)
             || jsonb_build_object('nome', privado.nome_do_profissional_para(p.profissional_id, autor)) end,
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
  'Turno com confirmado_em para janela simétrica do aviso a caminho (0.2.106); mantém coordenadas, cancelamento e avaliação. O nome da contraparte profissional segue o leitor `autor` (0.2.89, #519), não o JWT. A vaga leva `origem` (VagaResumo.origem, 0.2.55): sem a chave o app lê a vaga direta como publicação.';
revoke execute on function privado.turno_em_json(uuid, uuid) from public, anon, authenticated;
grant execute on function privado.turno_em_json(uuid, uuid) to service_role;
