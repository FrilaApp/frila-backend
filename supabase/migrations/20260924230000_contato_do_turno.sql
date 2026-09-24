-- `contato_do_turno`: o telefone, com prazo.
--
-- RLS filtra linha, não coluna. O telefone mora em `usuario`, numa linha que a outra
-- parte pode ler por outros motivos; é por isso que o contato sai por uma função, e não
-- por uma política. A base legal é a execução do contrato (LGPD, art. 7º, V) — e
-- execução de contrato tem começo e fim.
--
-- Três portas, todas fechadas por padrão:
--
--   antes da confirmação   404, porque ainda não há contrato a executar
--   fora do turno          404, para quem não é nenhum dos dois lados
--   depois de 7 dias       403 `contato_expirado`, que é o prazo virando resposta
--
-- Os dois primeiros são 404 e não 403 de propósito: um 403 confirmaria que aquele turno
-- existe para quem não deveria saber.

-- ── O outro lado, quando quem pergunta é a casa ───────────────────────────────
--
-- Simétrico a `privado.contato_do_estabelecimento`, que nasceu com o `candidatar`. O
-- nome é o da pessoa, e não o do estabelecimento: do lado de cá há gente, não marca.
create or replace function privado.contato_do_profissional(posicao uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'nome',         u.nome,
    'telefone',     u.telefone,
    'whatsapp_url', 'https://wa.me/' || replace(u.telefone, '+', ''),
    'visivel_ate',  p.fim_em + interval '7 days')
    from public.posicao p
    join public.profissional pr on pr.id = p.profissional_id
    join public.usuario u       on u.id = pr.usuario_id
   where p.id = posicao
$$;

comment on function privado.contato_do_profissional(uuid) is
  'Contato do profissional confirmado numa posição, para a casa (RN10). O prazo é o fim previsto do turno mais 7 dias.';

-- ── contato_do_turno ──────────────────────────────────────────────────────────

create or replace function public.contato_do_turno(turno_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_pos    public.posicao%rowtype;
  v_estab  uuid;
  v_dono   uuid;
  v_sou_prof boolean;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if contato_do_turno.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  select p.* into v_pos
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = contato_do_turno.turno_id;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Sem confirmação não há contrato a executar, e sem contrato a base legal não existe.
  if v_pos.estado not in ('confirmada', 'cumprida') then
    perform public.erro(404, 'nao_encontrado');
  end if;

  v_estab := privado.estabelecimento_da_vaga(v_pos.vaga_id);
  v_sou_prof := privado.usuario_do_profissional(v_pos.profissional_id) = v_uid;
  v_dono := privado.usuario_do_profissional(v_pos.profissional_id);

  -- Quem não é nenhum dos dois lados não fica sabendo que este turno existe.
  if not v_sou_prof and not privado.eh_membro(v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- RF26. O bloqueio entre as partes fecha o contato nos dois sentidos, e responde o
  -- mesmo 404: quem bloqueou alguém não recebe prova de que a outra parte continua ali.
  if privado.bloqueado_com_estabelecimento(case when v_sou_prof then v_uid else v_dono end,
                                           v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- RN10, pelo relógio do produto. O prazo é o mesmo que `meus_turnos` publica em
  -- `contato_visivel_ate`, para que a tela não precise pedir o contato só para
  -- descobrir se pode.
  if privado.agora() > v_pos.fim_em + interval '7 days' then
    perform public.erro(403, 'contato_expirado');
  end if;

  return case when v_sou_prof
              then privado.contato_do_estabelecimento(v_pos.vaga_id)
              else privado.contato_do_profissional(v_pos.id) end;
end $$;

comment on function public.contato_do_turno(uuid) is
  'Contato da outra parte do turno (RF11, RN10). Só depois da confirmação e só até 7 dias depois do fim; depois disso, 403 contato_expirado. Antes da confirmação, fora do turno ou com bloqueio entre as partes, 404.';

revoke execute on function public.contato_do_turno(uuid) from public, anon;
grant execute on function public.contato_do_turno(uuid) to authenticated;
