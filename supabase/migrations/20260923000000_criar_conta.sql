-- A conta: aceite dos termos e a RPC que cria o usuário.
--
-- A entrada é pelo Supabase Auth, com um código de uso único no e-mail. Quando o
-- código é confirmado, existe uma linha em `auth.users` e uma sessão — mas ainda não
-- existe conta no produto. `criar_conta` é o passo que falta: grava o perfil (RN25), o
-- nome, o telefone, a data de nascimento e o aceite dos termos.

-- ── O aceite ───────────────────────────────────────────────────────────────────
--
-- Guardar "aceitou" como booleano não serve para nada: a pergunta que a LGPD e a App
-- Store fazem é *o que* a pessoa aceitou e *quando*. Versão e instante, ou o registro
-- não vale como registro.
--
-- `not null` porque toda conta nasce por `criar_conta`, que sempre os grava. É a
-- última linha de defesa: nenhuma conta existe sem consentimento registrado.

alter table public.usuario
  add column termos_versao   text        not null,
  add column termos_aceite_em timestamptz not null;

comment on column public.usuario.termos_versao is
  'Versão dos termos de uso e da política de privacidade que a pessoa aceitou no cadastro. Guardar só um booleano não responde o que ela aceitou.';
comment on column public.usuario.termos_aceite_em is
  'Instante do aceite, pelo relógio do produto (privado.agora()).';

-- ── criar_conta ────────────────────────────────────────────────────────────────

create or replace function public.criar_conta(
  perfil        public.perfil_conta,
  nome          text,
  telefone      text,
  nascimento    date,
  termos_versao text
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_email text;
  v_linha public.usuario%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- Idempotência pela chave natural: a conta já existe para esta credencial.
  -- Reenviar o mesmo cadastro devolve a conta gravada; tentar cadastrar com dados
  -- diferentes é conflito, não sobrescrita — o perfil não muda (RN25) e o resto é
  -- trabalho de `atualizar_perfil`.
  select * into v_linha from public.usuario u where u.id = v_uid;
  if found then
    if v_linha.perfil is distinct from criar_conta.perfil then
      perform public.erro(409, 'conta_existente', 'perfil_divergente');
    end if;
    return public.conta_em_json(v_linha);
  end if;

  if criar_conta.nome is null or length(btrim(criar_conta.nome)) < 2 then
    perform public.erro(422, 'campo_obrigatorio', 'nome');
  end if;
  if criar_conta.telefone is null then
    perform public.erro(422, 'campo_obrigatorio', 'telefone');
  end if;
  if criar_conta.nascimento is null then
    perform public.erro(422, 'campo_obrigatorio', 'nascimento');
  end if;
  -- A App Store e a LGPD pedem o aceite registrado, e o cartão manda recusar sem ele.
  if criar_conta.termos_versao is null or btrim(criar_conta.termos_versao) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'termos_versao');
  end if;

  -- RN20 conferida aqui para devolver o código do contrato. O CHECK da tabela é a
  -- última linha de defesa e levantaria 23514, que o app não sabe ler.
  if criar_conta.nascimento > (current_date - interval '18 years') then
    perform public.erro(422, 'menor_de_idade');
  end if;

  if criar_conta.telefone !~ '^\+[1-9][0-9]{7,14}$' then
    perform public.erro(422, 'campo_obrigatorio', 'telefone');
  end if;

  -- O e-mail vem da conta já confirmada pelo código, nunca da tela: é o único dado
  -- aqui que o Auth já provou pertencer a quem está chamando.
  select u.email into v_email from auth.users u where u.id = v_uid;
  if v_email is null then
    perform public.erro(401, 'nao_autenticado', 'sem_email_confirmado');
  end if;

  begin
    insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                                termos_versao, termos_aceite_em)
    values (v_uid, criar_conta.perfil, btrim(criar_conta.nome), criar_conta.telefone,
            v_email, criar_conta.nascimento,
            btrim(criar_conta.termos_versao), privado.agora())
    returning * into v_linha;
  exception
    when unique_violation then
      -- O índice parcial de e-mail: outra conta ativa já usa este endereço.
      perform public.erro(409, 'conta_existente', 'email_em_uso');
  end;

  return public.conta_em_json(v_linha);
end $$;

comment on function public.criar_conta(public.perfil_conta, text, text, date, text) is
  'Cria a conta do produto depois que o código do e-mail foi confirmado. Perfil fixo (RN25), maioridade verificada (RN20), aceite registrado.';

-- Molda a resposta no schema `Usuario` do contrato. Separada porque `criar_conta` e a
-- leitura do próprio perfil devolvem a mesma coisa, e duas cópias divergem.
create or replace function public.conta_em_json(u public.usuario)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'id',         u.id,
    'perfil',     u.perfil,
    'nome',       u.nome,
    'telefone',   u.telefone,
    'email',      u.email,
    'nascimento', u.nascimento,
    'estado',     u.estado)
$$;

revoke execute on function public.conta_em_json(public.usuario) from public, anon, authenticated;

revoke execute on function public.criar_conta(public.perfil_conta, text, text, date, text)
  from public, anon;
grant  execute on function public.criar_conta(public.perfil_conta, text, text, date, text)
  to authenticated;

-- ── minha_conta ────────────────────────────────────────────────────────────────
--
-- O app precisa saber, ao abrir, se a conta já foi criada — senão manda para o
-- cadastro quem já cadastrou.

create or replace function public.minha_conta()
returns jsonb
language plpgsql
-- Sem `stable`: ela chama `public.erro`, que é volátil por levantar exceção. Rotular
-- de estável é mentir para o planejador, e o lint reprova — foi assim que este ficou
-- vermelho antes de chegar ao PR.
security definer set search_path = ''
as $$
declare
  v_linha public.usuario%rowtype;
begin
  if (select auth.uid()) is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  select * into v_linha from public.usuario u where u.id = (select auth.uid());
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  return public.conta_em_json(v_linha);
end $$;

revoke execute on function public.minha_conta() from public, anon;
grant  execute on function public.minha_conta() to authenticated;
