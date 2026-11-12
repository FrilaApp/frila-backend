-- Migração: 20261111200000_gerar_codigo_checkin.sql
-- Escopo: B-CHECKIN-BACK, PR5 (contrato 0.2.68, `gerarCodigoCheckin`; plano em
-- orquestracao/retornos/B-CHECKIN-BACK-plano.md, seção 2, PR5).
--
-- A casa gera ou revê o código de check-in do turno. Só membro do estabelecimento dono do turno
-- gera; o profissional recebe 403, como no confirmar_checkin_manual. A chave checkin_por_codigo
-- desligada para a casa responde 403 recurso_desligado antes de qualquer escrita (RN46).
--
-- O código: dentro da validade, o mesmo; vencido, um novo, de 6 dígitos sorteados por
-- extensions.gen_random_bytes, sem viés de módulo. Gerar não zera os erros do profissional e funciona
-- no bloqueio temporário; o caminho encerrado (6ª errada) recusa com 409 codigo_bloqueado. Não guarda
-- quem gerou e não manda push. O valor vencido é apagado pelo job de cada minuto (D4, PR3).
--
-- Decisões que valem aqui (plano e Forja, 08/11/2026):
--   · `for update` no turno antes de ler o estado: duas chamadas da casa ao mesmo tempo não sorteiam
--     dois códigos;
--   · a validade sai de privado.regra_checkin_codigo com coalesce(…, 300): sem a linha da regra, vale o
--     padrão, como em privado.registrar_erro_codigo (R1 do Lince no #458);
--   · o código nunca sai num erro (R2 do Lince no #458): o DETAIL de uma restrição que falha numa linha
--     de privado.checkin_codigo ("Failing row contains (…)") traria os 6 dígitos. As escritas capturam a
--     classe 23 inteira (integrity_constraint_violation, e não só check_violation, porque o
--     not_null_violation também traz a linha) e reerguem o mesmo SQLSTATE com a mesma mensagem, que
--     só nomeia a tabela e a restrição, sem o DETAIL;
--   · a janela é a do check-in (privado.exigir_janela), pelo relógio do servidor; a conta de
--     demonstração a atravessa (D9).

create function public.gerar_codigo_checkin(turno_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid      uuid := (select auth.uid());
  v_agora    timestamptz := privado.agora();
  v_pos      public.posicao%rowtype;
  v_estab    uuid;
  v_t        public.turno%rowtype;
  v_c        privado.checkin_codigo%rowtype;
  v_validade integer;
  v_sorteio  bigint;
  v_estado   text;
  v_mensagem text;
  -- O maior múltiplo de 1 000 000 abaixo de 2^32: sortear abaixo dele e tirar o resto não tem viés.
  c_teto_sem_vies constant bigint := 4294000000;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- Conta anonimizada (RF25): 401. Conta suspensa: 403 conta_suspensa.
  perform privado.exigir_conta_ativa();

  if gerar_codigo_checkin.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  select p.* into v_pos
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = gerar_codigo_checkin.turno_id;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  v_estab := privado.estabelecimento_da_vaga(v_pos.vaga_id);

  -- Bloqueio entre o profissional e a casa (RF26): o turno some para os dois lados.
  if privado.bloqueado_com_estabelecimento(privado.usuario_do_profissional(v_pos.profissional_id), v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- RF20: o código é a casa atestando a presença. O profissional que o gerasse leria o próprio código.
  if not privado.eh_membro(v_estab) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- RN46: com a chave desligada para a casa, nada é escrito.
  perform privado.exigir_recurso_para('checkin_por_codigo', v_estab);

  select * into v_t from public.turno t where t.id = gerar_codigo_checkin.turno_id for update;

  if v_t.checkin_em is null then
    perform public.erro(409, 'checkin_pendente');
  end if;

  if v_t.verificacao = 'verificado' then
    perform public.erro(409, 'checkin_ja_confirmado');
  end if;

  if privado.estado_do_codigo(v_t.id) = 'encerrado' then
    perform public.erro(409, 'codigo_bloqueado', 'encerrado');
  end if;

  perform privado.exigir_janela(v_agora, v_pos.inicio_em, v_pos.fim_em);

  begin
    insert into privado.checkin_codigo (turno_id) values (v_t.id) on conflict (turno_id) do nothing;
    select * into v_c from privado.checkin_codigo c where c.turno_id = v_t.id for update;

    if v_c.codigo is null or v_c.expira_em <= v_agora then
      v_validade := coalesce((select r.validade_s from privado.regra_checkin_codigo r), 300);
      loop
        v_sorteio := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;
        exit when v_sorteio < c_teto_sem_vies;
      end loop;

      update privado.checkin_codigo c
         set codigo    = lpad((v_sorteio % 1000000)::text, 6, '0'),
             gerado_em = v_agora,
             expira_em = v_agora + make_interval(secs => v_validade)
       where c.turno_id = v_t.id
      returning * into v_c;
    end if;
  exception when integrity_constraint_violation then
    -- Sem o DETAIL, que traria a linha e o código. A mensagem só nomeia a tabela e a restrição.
    get stacked diagnostics v_estado = returned_sqlstate, v_mensagem = message_text;
    raise exception using errcode = v_estado, message = v_mensagem;
  end;

  return jsonb_build_object(
    'turno_id',           v_t.id,
    'codigo',             v_c.codigo,
    'expira_em',          v_c.expira_em,
    -- Pelo relógio do servidor, para baixo: a tela nunca mostra validade que o servidor já não dá.
    'segundos_restantes', greatest(0, least(300, floor(extract(epoch from v_c.expira_em - v_agora))::integer)));
end $$;

comment on function public.gerar_codigo_checkin(uuid) is
  'Check-in por código (contrato 0.2.68, RN22, RN46): o membro da casa dona do turno gera ou revê o código de 6 dígitos que o profissional lê. Dentro da validade (privado.regra_checkin_codigo.validade_s, padrão 300 s) devolve o mesmo; vencido, sorteia outro. Não zera os erros do profissional, gera no bloqueio temporário e recusa com 409 codigo_bloqueado (encerrado) depois da 6ª errada. Com a chave checkin_por_codigo desligada para a casa, 403 recurso_desligado antes de qualquer escrita. Trava o turno (for update). O código só sai nesta resposta: não é gravado com quem gerou, não vai em push, e um erro de restrição na escrita sai sem o DETAIL que traria a linha. Janela: a do check-in, pelo relógio do servidor; a conta de demonstração a atravessa, e para a revisão da loja falta ligar a chave para a casa de demonstração (D9).';

revoke execute on function public.gerar_codigo_checkin(uuid) from public, anon;
grant  execute on function public.gerar_codigo_checkin(uuid) to authenticated;
