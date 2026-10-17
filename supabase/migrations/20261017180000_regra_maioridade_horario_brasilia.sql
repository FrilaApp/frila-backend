-- contrato: corpo-sem-mudanca-de-superficie public.criar_conta 0.2.44
--
-- Correção da regra de maioridade (RN20) no servidor:
-- Substitui `current_date` (UTC) por `(privado.agora() at time zone 'America/Sao_Paulo')::date`.
--
-- Motivo:
-- Em servidores configurados com UTC (padrão Supabase/cloud), entre 21h e 24h do fuso
-- de Brasília ('America/Sao_Paulo'), o dia UTC já virou (00h-03h UTC do dia seguinte).
-- Com `current_date`, um usuário que completa 18 anos no dia seguinte era indevidamente
-- aceito até 3 horas antes de atingir a maioridade legal.
--
-- Além disso, no cálculo `hoje - interval '18 years'`, quem nasceu em 29/02 em ano
-- bissexto completa 18 anos em 01/03 em ano não bissexto (paridade com CadastroViewModel do app).

alter table public.usuario drop constraint maior_de_idade;
alter table public.usuario add constraint maior_de_idade
  check (nascimento <= ((privado.agora() at time zone 'America/Sao_Paulo')::date - interval '18 years')) not valid;
alter table public.usuario validate constraint maior_de_idade;

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
  v_uid         uuid := (select auth.uid());
  v_email       text;
  v_linha       public.usuario%rowtype;
  v_hoje_sp     date;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

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

  -- Diretriz 1.2: o nome aparece para a contraparte no turno e no perfil público.
  if not privado.texto_aceitavel(criar_conta.nome) then
    perform public.erro(422, 'campo_invalido', 'nome');
  end if;

  if criar_conta.telefone is null then
    perform public.erro(422, 'campo_obrigatorio', 'telefone');
  end if;
  if criar_conta.nascimento is null then
    perform public.erro(422, 'campo_obrigatorio', 'nascimento');
  end if;
  if criar_conta.termos_versao is null or btrim(criar_conta.termos_versao) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'termos_versao');
  end if;

  v_hoje_sp := (privado.agora() at time zone 'America/Sao_Paulo')::date;
  if criar_conta.nascimento > (v_hoje_sp - interval '18 years') then
    perform public.erro(422, 'menor_de_idade');
  end if;

  if criar_conta.telefone !~ '^\+[1-9][0-9]{7,14}$' then
    perform public.erro(422, 'campo_obrigatorio', 'telefone');
  end if;

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
      perform public.erro(409, 'conta_existente', 'email_em_uso');
  end;

  return public.conta_em_json(v_linha);
end $$;

comment on function public.criar_conta(public.perfil_conta, text, text, date, text) is
  'Cria a conta do produto depois que o código do e-mail foi confirmado. Perfil fixo (RN25), maioridade verificada em horário de Brasília (RN20), aceite registrado, e o nome passa pelo filtro da diretriz 1.2.';

revoke execute on function public.criar_conta(public.perfil_conta, text, text, date, text)
  from public, anon;
grant  execute on function public.criar_conta(public.perfil_conta, text, text, date, text)
  to authenticated;
