-- `privado.turnos_exportacao`: consulta consolidada de turnos para exportação em CSV e PDF
-- (cartão pd7zOS5P · US20, RF22, RN09, RN17, UC13).
--
-- Devolve os turnos realizados e confirmados do período para quem chama, nos dois perfis:
--   - Profissional: contraparte é o nome do estabelecimento;
--   - Contratante: contraparte é o nome do profissional alocado (RN17).
--
-- ── LGPD e dados pessoais (RN15) ───────────────────────────────────────────────
--
-- Apenas os campos autorizados pela RN17 são expostos: data, função, horários registrados,
-- valor acordado e contraparte. Nenhum dado pessoal adicional (telefone, e-mail, CPF/CNPJ,
-- endereço ou distância de check-in) sai no relatório.
--
-- ── Imutabilidade e segurança ──────────────────────────────────────────────────
--
-- A função é `stable`: apenas lê o histórico e não realiza qualquer escrita.
-- Acesso restrito exclusivamente ao `service_role`.

create or replace function privado.turnos_exportacao(
  p_usuario             uuid,
  p_de                  timestamptz,
  p_ate                 timestamptz,
  p_estabelecimento_id  uuid default null
)
returns table (
  turno_id                uuid,
  data                    date,
  funcao                  text,
  inicio_em               timestamptz,
  fim_em                  timestamptz,
  checkin_em              timestamptz,
  checkout_em             timestamptz,
  valor_acordado_centavos bigint,
  contraparte             text,
  verificacao             public.verificacao_turno
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_prof uuid;
begin
  if p_usuario is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if not exists (select 1 from public.usuario u where u.id = p_usuario) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if p_de is null then
    perform public.erro(422, 'campo_obrigatorio', 'de');
  end if;

  if p_ate is null then
    perform public.erro(422, 'campo_obrigatorio', 'ate');
  end if;

  if p_de > p_ate then
    perform public.erro(422, 'campo_invalido', 'de');
  end if;

  if p_estabelecimento_id is not null then
    if not exists (
      select 1
        from public.membro_estabelecimento m
       where m.estabelecimento_id = p_estabelecimento_id
         and m.usuario_id = p_usuario
    ) then
      perform public.erro(403, 'sem_permissao');
    end if;

    return query
      select t.id as turno_id,
             (p.inicio_em at time zone 'America/Sao_Paulo')::date as data,
             f.nome as funcao,
             p.inicio_em,
             p.fim_em,
             t.checkin_em,
             t.checkout_em,
             t.valor_acordado_centavos,
             u.nome as contraparte,
             t.verificacao
        from public.turno t
        join public.posicao p         on p.id = t.posicao_id
        join public.vaga v            on v.id = p.vaga_id
        join public.funcao f          on f.id = v.funcao_id
        join public.profissional prof on prof.id = p.profissional_id
        join public.usuario u         on u.id = prof.usuario_id
       where v.estabelecimento_id = p_estabelecimento_id
         and p.inicio_em >= p_de
         and p.inicio_em <= p_ate
       order by p.inicio_em asc, t.id asc;
  else
    select pr.id into v_prof
      from public.profissional pr
     where pr.usuario_id = p_usuario;

    if v_prof is null then
      return;
    end if;

    return query
      select t.id as turno_id,
             (p.inicio_em at time zone 'America/Sao_Paulo')::date as data,
             f.nome as funcao,
             p.inicio_em,
             p.fim_em,
             t.checkin_em,
             t.checkout_em,
             t.valor_acordado_centavos,
             e.nome as contraparte,
             t.verificacao
        from public.turno t
        join public.posicao p         on p.id = t.posicao_id
        join public.vaga v            on v.id = p.vaga_id
        join public.funcao f          on f.id = v.funcao_id
        join public.estabelecimento e on e.id = v.estabelecimento_id
       where p.profissional_id = v_prof
         and p.inicio_em >= p_de
         and p.inicio_em <= p_ate
       order by p.inicio_em asc, t.id asc;
  end if;
end $$;

comment on function privado.turnos_exportacao(uuid, timestamptz, timestamptz, uuid) is
  'Turnos do período para exportação em CSV ou PDF (RF22, RN17, UC13). Sem dado pessoal além do que a RN17 exige (RN15).';

revoke execute on function privado.turnos_exportacao(uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated;
grant  execute on function privado.turnos_exportacao(uuid, timestamptz, timestamptz, uuid) to service_role;
